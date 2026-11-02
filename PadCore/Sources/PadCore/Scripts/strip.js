// The page under the iPhone Duo's strip (Docs/iPhoneDuoDesign.md §9).
//
// Closed, the Duo keeps a strip down one side of the window for its status
// bar and the system's bar, and the page runs on under it to the window's
// edge (Browser.placeUnderStrip). The page's pictures, colours and
// backgrounds stay where the page puts them, seen through the strip's
// glass. Its running text wraps at the strip's edge, so no line runs under
// it. What can be pressed is moved out from under the strip's items.
//
// The strip is taken only in bands (DuoLayout.Strip): the status bar with
// Back and Forward at its top, New Tab and Tabs at its foot. Between them it
// is empty, and there what can be pressed keeps its place. Above and below a
// band the edge of the room for it slants (the ramp), so a button slides
// aside as it scrolls up towards the items, and back as it scrolls clear of
// them: the room is a trapezoid, not a step.
//
// What moves is the smallest group round a button, a link or a field that
// stands apart from the rest of its row (a header's buttons, a row's "…"),
// with the things close beside it (a header's three icons go together, the
// gaps between them kept), and only as far as there is room beside them: it
// never goes over what is next to it. A bar the page fixes in the window
// whose buttons have no room beside them makes room in its row instead, as
// its row lays itself out (a header's search beside a row of tabs). A group
// the page fixes in the window moves by where it stands. One that scrolls
// with the page moves as it scrolls, by a CSS animation on the page's
// scroll, which WebKit runs with the scrolling rather than a script's frame
// behind it. Nothing is moved that the page animates or moves itself, nor
// anything in a row that scrolls sideways (a carousel), which a swipe brings
// out from under the strip.
//
// Nothing it does lays the page out again while the page moves: what
// changed would show as a jump under the finger. It looks at the page
// only once a scroll has stopped, never takes the room it gave away to
// measure again, and measures what it moved by holding just those boxes
// in place, which reflows nothing.
//
// It runs in the app's own content world. The app calls set() with the
// strip in the page view's points, or null when the page no longer runs
// under one (Page.strip).
(() => {
  'use strict';
  if (window.__egluStrip) return;

  // On each group moved, its number: its rule in the sheet goes by it.
  const MARK = 'data-eglu-strip';
  // On each block of text, and each fixed bar's row, given room at the strip's side.
  const ROOM = 'data-eglu-strip-room';
  const PRESSABLE = [
    'a[href]', 'button', 'input:not([type="hidden"])', 'select', 'textarea', 'summary', 'label[for]',
    '[role="button"]', '[role="link"]', '[role="tab"]', '[role="menuitem"]', '[role="checkbox"]',
    '[role="switch"]', '[role="searchbox"]', '[role="combobox"]', '[onclick]',
    '[contenteditable=""]', '[contenteditable="true"]', '[tabindex]:not([tabindex="-1"])',
  ].join(',');
  // A group wider than this share of the window is a row of its own, which
  // has no room beside it to move into.
  const WIDE = 0.6;
  // Room kept between a group moved aside and what it moves towards, in CSS pixels.
  const GAP = 8;
  // What stands this close beside a group moves along with it.
  const CLUSTER = 40;
  // A move shorter than this, when more is needed, is no help: it is left out.
  const LEAST = 12;
  // A group's row: what is no more than this much taller than the group.
  const ROW = (height) => height * 2.5 + 24;
  // A group with more inside than this is a part of the page, not a few controls.
  const MOST = 150;
  // At most one look at the page in this many milliseconds.
  const PACE = 600;
  // A look waits until the page has been still this long.
  const STILL = 300;
  // Looks that change nothing come further apart, up to this: a page that
  // changes all the time (GitHub's) isn't looked at all the time.
  const SLOWEST = 5000;
  // What draws itself, whatever its style: its box is what it shows.
  const DRAWN = /^(IMG|SVG|VIDEO|CANVAS|IFRAME|INPUT|BUTTON|SELECT|TEXTAREA|PICTURE|OBJECT|EMBED|svg)$/;
  // Text that is not laid out as text on the page.
  const UNSEEN = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TEXTAREA|OPTION|TITLE)$/;
  const scrolled = typeof CSS !== 'undefined' && !!CSS.supports &&
    CSS.supports('animation-timeline: scroll()') && CSS.supports('animation-range: 0px 1px');

  let strip = null;
  // The sheets: the room given (text and rows), and the groups moved.
  // Sheets made by the script and adopted by the document: a <style> added
  // to the page is refused where its Content-Security-Policy allows no
  // inline style (DuckDuckGo's), and a constructed sheet is not.
  const roomSheet = new CSSStyleSheet();
  const moveSheet = new CSSStyleSheet();
  const written = new Map();
  let numbers = new WeakMap();
  let count = 0;
  let marked = new Set();
  // The room given, kept from look to look: each text block or bar's row,
  // with the page's own padding on the strip's side, read before any was
  // added, and how much more it has.
  let given = new Map();
  // Blocks padding only made wider (a box as wide as what is in it): left as they are from then on.
  let refused = new WeakSet();
  // When the page last scrolled.
  let lastScroll = 0;
  // Groups inside a shadow root (a chat widget's button), which the sheets
  // don't reach: moved by their own style, set by the script.
  let inlined = new Set();
  // Groups inside something sticky, inside a box that scrolls by itself, or
  // fixed inside something that moves: moved by script, from where they
  // stand, as anything scrolls.
  let tracked = [];
  // The strip in the page's CSS pixels at the last look.
  let measure = null;
  let timer = 0;
  let last = 0;
  // How long to wait after the last look when only the page's own changes call for one.
  let pace = PACE;
  let frame = 0;
  let idle = 0;
  let watched = null;
  const range = document.createRange();

  // MARK: The strip, in the page's pixels

  // The strip as the page's layout viewport sees it: WebKit may show a wide
  // page scaled down, or zoomed in and moved along.
  function measured() {
    const view = window.visualViewport;
    const scale = view && view.scale > 0 ? view.scale : 1;
    const left = view ? view.offsetLeft : 0;
    const top = view ? view.offsetTop : 0;
    const width = view ? view.width : window.innerWidth;
    const right = strip.side !== 'left';
    const inset = strip.width / scale;
    return {
      right,
      width,
      left,
      // The safe area's edge, beside the strip.
      edge: right ? left + width - inset : left + inset,
      bands: strip.bands.map(([a, b]) => [top + a / scale, top + b / scale]),
      ramp: Math.max(1, strip.ramp / scale),
    };
  }

  // How much of the way aside a box from `top` to `bottom` must be: all of
  // it beside a band, none where the strip is empty, and on the slant
  // between in proportion.
  function cover(m, top, bottom) {
    let most = 0;
    for (const [a, b] of m.bands) {
      if (top < b && bottom > a) return 1;
      const away = top >= b ? top - b : a - bottom;
      most = Math.max(most, 1 - away / m.ramp);
    }
    return most;
  }

  // How far a box reaches past the safe area's edge, under the strip.
  const into = (m, r) => (m.right ? r.right - m.edge : m.edge - r.left);
  // Whether a box is in the window at all, from side to side: a drawer
  // parked past the window's edge is not under the strip.
  const inView = (m, r) => r.left < m.left + m.width - 1 && r.right > m.left + 1;
  // The page's padding on the strip's side, and the property that holds it.
  const side = (m) => (m.right ? 'padding-right' : 'padding-left');

  // What a node shows, from side to side: an element's box where it paints
  // (a background, a border, a picture, a control), else the text and the
  // painted boxes in it; a line of text's own extent. Not what is there
  // only for VoiceOver (text in a box a pixel wide) or parked out of the
  // window: Apple's header's icons each hold such a label. Nil for nothing
  // shown.
  // What boxes show, as found in this look: a row's boxes are looked at for
  // each group in it.
  let shownCache = new Map();
  function extent(node) {
    if (shownCache.has(node)) return shownCache.get(node);
    const r = extentNow(node);
    shownCache.set(node, r);
    return r;
  }

  function extentNow(node) {
    if (node.nodeType === Node.TEXT_NODE) return textExtent(node);
    if (node.nodeType !== Node.ELEMENT_NODE) return null;
    const box = node.getBoundingClientRect();
    if (box.width < 1 || box.height < 1) return null;
    if (paints(node)) return box;
    const shown = { left: Infinity, right: -Infinity, top: Infinity, bottom: -Infinity };
    // Past what isn't laid out at all (a closed menu's hundred links), through what is laid out round nothing.
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (inner) => inner.nodeType !== Node.ELEMENT_NODE || inner.getClientRects().length ? NodeFilter.FILTER_ACCEPT
        : getComputedStyle(inner).display === 'contents' ? NodeFilter.FILTER_SKIP : NodeFilter.FILTER_REJECT,
    });
    let looked = 0;
    for (let inner = walker.nextNode(); inner; inner = walker.nextNode()) {
      // Too much inside to look through: its box is what it shows.
      if (++looked > 400) return box;
      let r = null;
      if (inner.nodeType === Node.TEXT_NODE) {
        r = textExtent(inner);
      } else if (DRAWN.test(inner.tagName) || paints(inner)) {
        r = inner.getBoundingClientRect();
        if (r.width <= 1 || r.height <= 1) r = null;
      }
      if (!r || r.right < 0 || r.left > window.innerWidth) continue;
      shown.left = Math.min(shown.left, r.left);
      shown.right = Math.max(shown.right, r.right);
      shown.top = Math.min(shown.top, r.top);
      shown.bottom = Math.max(shown.bottom, r.bottom);
    }
    if (!(shown.right - shown.left >= 1)) return null;
    return { ...shown, width: shown.right - shown.left, height: shown.bottom - shown.top };
  }

  // A box as far as the boxes round it that clip what overflows them let it
  // show, from side to side: DuckDuckGo's selects are wider than what holds
  // them, their own arrow cut off, and what shows ends short of the strip.
  function visible(node, r) {
    let left = r.left;
    let right = r.right;
    for (let up = node.parentElement, n = 0; up && up !== document.body && n < 8; up = up.parentElement, n++) {
      const x = getComputedStyle(up).overflowX;
      if (x === 'visible') continue;
      const clip = up.getBoundingClientRect();
      left = Math.max(left, clip.left);
      right = Math.min(right, clip.right);
    }
    return right - left >= 1 ? { left, right, top: r.top, bottom: r.bottom, width: right - left, height: r.height } : null;
  }

  // A line of text's extent, unless the box it is in is a pixel or less, or unseen.
  function textExtent(text) {
    const parent = text.parentElement;
    if (!/\S/.test(text.data) || !parent || UNSEEN.test(parent.tagName)) return null;
    const holder = parent.getBoundingClientRect();
    if (holder.width <= 1 || holder.height <= 1) return null;
    const style = getComputedStyle(parent);
    if (style.visibility === 'hidden' || style.opacity === '0') return null;
    range.selectNodeContents(text);
    const r = range.getBoundingClientRect();
    return r.width >= 1 && r.height >= 1 ? r : null;
  }

  function paints(node) {
    if (DRAWN.test(node.tagName)) return true;
    const style = getComputedStyle(node);
    if (style.backgroundImage !== 'none' || style.boxShadow !== 'none') return true;
    if (!/^(transparent|rgba\(.*,\s*0\))$/.test(style.backgroundColor)) return true;
    return ['Left', 'Right', 'Top', 'Bottom'].some((edge) =>
      parseFloat(style[`border${edge}Width`]) > 0 && !/^(transparent|rgba\(.*,\s*0\))$/.test(style[`border${edge}Color`]));
  }

  // A box's children as laid out: through any that are laid out round
  // nothing (display: contents), to what is in them.
  function* laidOut(parent) {
    for (const child of parent.childNodes) {
      if (child.nodeType === Node.ELEMENT_NODE && getComputedStyle(child).display === 'contents') {
        yield* laidOut(child);
      } else {
        yield child;
      }
    }
  }

  // MARK: Running text

  // The block a line of text is laid out in: its nearest box that is not inline.
  function lineBlock(node) {
    for (let up = node; up && up !== document.body && up !== document.documentElement; up = up.parentElement) {
      const display = getComputedStyle(up).display;
      if (display !== 'inline' && display !== 'contents') return up;
    }
    return null;
  }

  // The room text blocks need. A block given room already keeps it, its
  // need worked out again from its box, which the padding doesn't change,
  // and the page's own padding: taking the padding away to measure would
  // wrap its lines anew and move the page under the reader. Its room only
  // grows: a block that slides past the strip's edge and back (GitHub's
  // home page moves its text about) would otherwise have its lines wrapped
  // anew, and the page laid out again, at every look. Then the blocks of
  // running text whose lines newly reach under the strip, each given that
  // much more padding at the strip's side, so their lines end at its edge.
  // Not text in a control or a group that moves (a button's label), nor
  // text in a row that scrolls sideways or in something typed in. The
  // outermost such block only: the blocks inside it wrap with it.
  function rooms(m) {
    for (const [node, room] of [...given]) {
      if (!node.isConnected) {
        given.delete(node);
        continue;
      }
      if (room.kind !== 'text') continue;
      const box = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      const border = parseFloat(m.right ? style.borderRightWidth : style.borderLeftWidth) || 0;
      const reach = Math.ceil(m.right ? box.right - border - room.pad - m.edge : m.edge - box.left - border - room.pad);
      if (reach + room.widen > room.extra) {
        room.extra = reach + room.widen;
        room.fresh = true;
      }
    }
    const found = new Map();
    const looked = new Set();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let text = walker.nextNode(); text; text = walker.nextNode()) {
      const parent = text.parentElement;
      if (!parent || looked.has(parent) || UNSEEN.test(parent.tagName) || !/\S/.test(text.data)) continue;
      looked.add(parent);
      const r = parent.getBoundingClientRect();
      if (r.width < 1 || into(m, r) < 1 || !inView(m, r)) continue;
      const block = lineBlock(parent);
      if (!block || found.has(block) || given.has(block) || refused.has(block)) continue;
      const box = block.getBoundingClientRect();
      const style = getComputedStyle(block);
      // Text kept on one line takes the padding too: where its box clips it, its ellipsis comes sooner.
      if (box.width < 40 || block.isContentEditable) continue;
      const control = block.closest(PRESSABLE);
      if (control && control.getBoundingClientRect().width <= WIDE * m.width) continue;
      if (sideways(block)) continue;
      const pad = parseFloat(m.right ? style.paddingRight : style.paddingLeft) || 0;
      const border = parseFloat(m.right ? style.borderRightWidth : style.borderLeftWidth) || 0;
      const reach = m.right ? box.right - border - pad - m.edge : m.edge - box.left - border - pad;
      if (reach >= 1) found.set(block, { kind: 'text', pad, extra: Math.ceil(reach), widen: 0, box, sized: false, fresh: true });
    }
    for (const [block, room] of found) {
      let inside = false;
      for (let up = block.parentElement; up && !inside; up = up.parentElement) inside = found.has(up) || given.has(up);
      if (!inside) given.set(block, room);
    }
  }

  // Whether a node is in a row that scrolls sideways (a carousel).
  function sideways(node) {
    for (let up = node.parentElement; up && up !== document.body; up = up.parentElement) {
      const x = getComputedStyle(up).overflowX;
      if ((x === 'auto' || x === 'scroll') && up.scrollWidth > up.clientWidth + 1) return true;
    }
    return false;
  }

  // The room given, as rules: each block's padding at the strip's side, and
  // its box sized to hold it where padding alone made it wider. Written
  // only when it changed, as anything written lays the page out again.
  function writeRoom(m) {
    const rules = [];
    for (const [node, room] of given) {
      const who = `[${ROOM}="${number(node)}"]`;
      rules.push(`${who}{${side(m)}:${(room.pad + room.extra).toFixed(1)}px !important` +
        `${room.sized ? ';box-sizing:border-box !important' : ''}}`);
    }
    return write(roomSheet, rules.join('\n'));
  }

  // The room given, laid out: a block new to it that grew wider for its
  // padding (a width the page set, outside its padding) is sized to hold
  // it; one that still grows (a box as wide as what is in it) gets none.
  function giveRoom(m) {
    for (const node of given.keys()) {
      const n = String(number(node));
      if (node.getAttribute(ROOM) !== n) node.setAttribute(ROOM, n);
    }
    if (writeRoom(m)) {
      for (let pass = 0; pass < 2; pass++) {
        let changed = false;
        for (const [node, room] of given) {
          if (!room.fresh || node.getBoundingClientRect().width <= room.box.width + 1) continue;
          if (room.sized) {
            given.delete(node);
            refused.add(node);
            node.removeAttribute(ROOM);
          } else {
            room.sized = true;
          }
          changed = true;
        }
        if (!changed) break;
        writeRoom(m);
      }
    }
    for (const room of given.values()) room.fresh = false;
    for (const node of document.querySelectorAll(`[${ROOM}]`)) if (!given.has(node)) node.removeAttribute(ROOM);
  }

  function number(node) {
    let n = numbers.get(node);
    if (!n) {
      n = ++count;
      numbers.set(node, n);
    }
    return n;
  }

  // MARK: Groups

  // The group round something that can be pressed: the boxes round it, from
  // itself out, while each is no wider than a group and no taller than its
  // row; and the row it stands in, where a wider box stopped the climb. An
  // inline link is moved by the block it is in, if that is a group: never
  // on its own out of a line of text.
  function group(m, node, r) {
    let mover = node;
    let box = r;
    while (mover && getComputedStyle(mover).display === 'inline') {
      mover = mover.parentElement;
      if (!mover || mover === document.body) return null;
      box = mover.getBoundingClientRect();
    }
    if (!mover || box.width > WIDE * m.width || box.width < 1 || box.height < 1) return null;
    const tallest = ROW(box.height);
    const chain = [{ mover, box }];
    let row = null;
    for (let up = 0; up < 6; up++) {
      const parent = mover.parentElement;
      if (!parent || parent === document.body || parent === document.documentElement) break;
      const p = parent.getBoundingClientRect();
      if (p.width > WIDE * m.width) {
        row = parent;
        break;
      }
      if (p.height > tallest) break;
      // Smaller than what it holds: overflowing, or laid out round nothing.
      if (p.width < box.width - 1 || p.height < box.height - 1) break;
      mover = parent;
      box = p;
      chain.push({ mover, box });
    }
    return { chain, row };
  }

  // How the group goes along as the page scrolls: 'fixed' with the window,
  // 'page' with the page's own scroll, 'sticky' or 'tracked' (in a box that
  // scrolls by itself, or fixed inside something that moves) by script, or
  // null in a row that scrolls sideways.
  function anchor(mover, rootScrolls) {
    let how = null;
    for (let node = mover; node && node !== document.documentElement; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node !== mover) {
        const x = style.overflowX;
        const y = style.overflowY;
        if ((x === 'auto' || x === 'scroll') && node.scrollWidth > node.clientWidth + 1) return null;
        // Fixed inside something that moves it or holds it: not fixed in the window.
        if (how === 'fixed' && (style.transform !== 'none' || style.filter !== 'none' || style.perspective !== 'none' ||
            /paint|layout|strict|content/.test(style.contain) || (style.backdropFilter && style.backdropFilter !== 'none'))) {
          how = 'tracked';
        }
        if (!how && (y === 'auto' || y === 'scroll') && node.scrollHeight > node.clientHeight + 1 &&
            (node !== document.body || !rootScrolls)) {
          how = 'tracked';
        }
      }
      if (!how && style.position === 'fixed') how = 'fixed';
      if (!how && style.position === 'sticky') how = 'sticky';
    }
    // A page that doesn't scroll (one window tall, or scrolled by its own box) stands where it is.
    return how || (rootScrolls ? 'page' : 'fixed');
  }

  // Whether the page itself scrolls up and down.
  function rootScrolls() {
    const root = document.documentElement;
    let overflow = getComputedStyle(root).overflowY;
    if (overflow === 'visible') overflow = getComputedStyle(document.body).overflowY;
    if (overflow === 'hidden' || overflow === 'clip') return false;
    return (document.scrollingElement || root).scrollHeight > window.innerHeight + 1;
  }

  // Whether moving the group would move what the page places by another
  // box: moved, the group becomes what its fixed and absolutely placed
  // insides, its own included (a link's ::after over its card), are placed
  // by. And whether the page moves or animates it already, which the move
  // would take over.
  function untouchable(mover) {
    const own = getComputedStyle(mover);
    if (own.animationName !== 'none' || (own.translate && own.translate !== 'none')) return true;
    if (mover.getAnimations && mover.getAnimations().length) return true;
    const placed = own.position !== 'static';
    for (const pseudo of ['::before', '::after']) {
      const position = getComputedStyle(mover, pseudo).position;
      if (position === 'fixed' || (position === 'absolute' && !placed)) return true;
    }
    const inside = mover.getElementsByTagName('*');
    if (inside.length > MOST) return true;
    for (const node of inside) {
      const position = getComputedStyle(node).position;
      if (position === 'fixed') return true;
      if (position !== 'absolute' || placed) continue;
      let held = false;
      for (let up = node.parentElement; up && up !== mover; up = up.parentElement) {
        const style = getComputedStyle(up);
        if (style.position !== 'static' || style.transform !== 'none') {
          held = true;
          break;
        }
      }
      if (!held) return true;
    }
    return false;
  }

  // Whether a neighbour can move along with a group: a box of its own,
  // free to move, going along with the page as the group does.
  function joins(node, how, rootScrolling) {
    const display = getComputedStyle(node).display;
    if (display === 'inline' || display === 'contents' || display === 'none') return false;
    return !untouchable(node) && anchor(node, rootScrolling) === how;
  }

  // What is beside the group, on the side away from the strip, level with
  // it in its row: the boxes and text beside it, and beside each box round
  // it up to its row's height. Those close beside it join it, nearest
  // first, while they can move and the whole stays no wider than a group;
  // the first that doesn't is how far the group can go. The group's reach
  // and room are measured by what it shows, not its box: a cell's link at
  // the far end of a wide cell.
  function room(m, mover, box, how, taken, rootScrolling) {
    const shown = visible(mover, extent(mover) || box) || box;
    const tallest = ROW(box.height);
    const beside = [];
    let node = mover;
    const consider = (child, depth) => {
      if (child === node || (child.contains && child.contains(mover))) return;
      const r = extent(child);
      if (!r) return;
      const level = Math.min(r.bottom, box.bottom) - Math.max(r.top, box.top);
      if (level < Math.min(r.height, box.height) * 0.3) return;
      // On the strip's side of the group: not in the way.
      if (m.right ? r.left >= shown.right - 1 : r.right <= shown.left + 1) return;
      const element = child.nodeType === Node.ELEMENT_NODE ? child : null;
      // Reaching under the group: what it stands on (a search field under its buttons).
      const behind = m.right ? r.right > shown.left + 1 : r.left < shown.right - 1;
      // A row that draws nothing of its own, too wide to move along,
      // reaching behind the group, or that can't move itself: what is in
      // it, one by one (Apple's header's list, its search and its bag
      // beside the menu at the end; the bag's item, whose badge hangs from
      // outside it, and the bag inside it, which can move).
      if (element && depth < 3 && !paints(element) &&
          (behind || r.width > WIDE * m.width || (element.children.length && untouchable(element)))) {
        for (const inner of laidOut(element)) consider(inner, depth + 1);
        return;
      }
      // Under the group, painted: what it stands on.
      if (behind) return;
      beside.push({ node: element, text: element ? null : child, r });
    };
    for (let up = 0; up < 8 && node.parentElement; up++) {
      const parent = node.parentElement;
      for (const child of laidOut(parent)) consider(child, 0);
      if (parent === document.body) break;
      if (parent.getBoundingClientRect().height > tallest) break;
      node = parent;
    }
    beside.sort((a, b) => (m.right ? b.r.right - a.r.right : a.r.left - b.r.left));
    const members = [mover];
    const union = { left: shown.left, right: shown.right, top: box.top, bottom: box.bottom };
    let limit = m.right ? m.left + GAP : m.left + m.width - GAP;
    let blocker = null;
    for (const { node: next, text, r } of beside) {
      const gap = m.right ? union.left - r.right : r.left - union.right;
      // Under the group as it has grown: what it stands on.
      if (gap < -1) continue;
      const width = Math.max(union.right, r.right) - Math.min(union.left, r.left);
      if (gap <= CLUSTER && next && !clashes(next, taken) && width <= WIDE * m.width && joins(next, how, rootScrolling)) {
        members.push(next);
        union.left = Math.min(union.left, r.left);
        union.right = Math.max(union.right, r.right);
        union.top = Math.min(union.top, r.top);
        union.bottom = Math.max(union.bottom, r.bottom);
        continue;
      }
      limit = m.right ? Math.max(limit, r.right) : Math.min(limit, r.left);
      blocker = next || text;
      break;
    }
    const space = m.right ? union.left - limit - GAP : limit - union.right - GAP;
    return { members, union, reach: into(m, shown), space, blocker };
  }

  // What the page marks as pressable only by its cursor (a div with a click
  // handler, as naver's cards' "…"), in the window under the strip: the
  // strip's column looked at every 30 pixels down, along its middle, and
  // what is at each place and round it up to a few boxes, if the page
  // gives it a pointing hand. Only what is in the window: the rest is
  // found as it scrolls into it.
  function pointed(m) {
    const found = new Set();
    const xs = [m.right ? (m.edge + m.left + m.width) / 2 : (m.left + m.edge) / 2];
    for (let y = 15; y < window.innerHeight; y += 30) {
      for (const x of xs) {
        let node = document.elementFromPoint(x, y);
        // Into open shadow roots: a chat widget's button is drawn in one.
        while (node && node.shadowRoot) {
          watchRoot(node.shadowRoot);
          const inner = node.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === node) break;
          node = inner;
        }
        for (let up = 0; node && up < 4 && node !== document.body; up++, node = node.parentElement) {
          if (found.has(node)) break;
          // In a shadow root the document's query doesn't reach: what can be pressed there by its kind too.
          if (getComputedStyle(node).cursor === 'pointer' || (inShadow(node) && node.matches(PRESSABLE))) {
            found.add(node);
            break;
          }
        }
      }
    }
    return found;
  }

  // Whether a node is, holds or is inside one already moving: moved again, it would go twice as far.
  function clashes(node, taken) {
    for (const other of taken) if (other === node || other.contains(node) || node.contains(other)) return true;
    return false;
  }

  // Whether a row lays the group out: nothing from the group up to it placed outside the flow.
  function laidIn(mover, row) {
    for (let node = mover; node && node !== row; node = node.parentElement) {
      if (/absolute|fixed/.test(getComputedStyle(node).position)) return false;
    }
    return true;
  }

  // Whether a row stands beside the strip's top band when the page is at its
  // top: a page's own header, which the page shows first, under the status bar.
  function atTop(m, row) {
    const band = m.bands[0];
    return !!band && band[0] <= 1 && row.getBoundingClientRect().top + window.scrollY < band[1];
  }

  // The groups to move, rightmost first (leftmost beside a strip on the
  // left), each with what moves along with it and how far it can go; and
  // the rows of bars that make the room themselves, by flexing.
  function plan(m) {
    const scrolling = rootScrolls();
    const found = new Map();
    for (const node of [...document.querySelectorAll(PRESSABLE), ...pointed(m)]) {
      const whole = node.getBoundingClientRect();
      if (whole.width < 1 || whole.height < 1 || into(m, whole) < 1) continue;
      const r = visible(node, whole);
      if (!r || into(m, r) < 1 || !inView(m, r) || r.width > WIDE * m.width) continue;
      const g = group(m, node, r);
      if (!g) continue;
      const top = g.chain[g.chain.length - 1].mover;
      if (!found.has(top)) found.set(top, g);
    }
    // A group inside another moves with it.
    for (const top of [...found.keys()]) {
      for (let up = top.parentElement; up; up = up.parentElement) {
        if (found.has(up)) {
          found.delete(top);
          break;
        }
      }
    }
    const order = [...found.values()].sort((a, b) => {
      const ra = a.chain[0].box;
      const rb = b.chain[0].box;
      return m.right ? rb.right - ra.right : ra.left - rb.left;
    });
    const taken = new Set();
    const groups = [];
    const widened = new Set();
    // Whether padding a row would carry along something slid already, which
    // would then move twice (Apple's search and bag, slid with its menu);
    // one placed absolutely in it (the country banner's ✕) stays put.
    const carries = (row) => [...taken].some((node) => row.contains(node) && laidIn(node, row));
    let more = false;
    for (const g of order) {
      // The widest box round it that can move: one round something the page
      // places from outside it can't, and then what is inside it may.
      let pick = null;
      for (let i = g.chain.length - 1; i >= 0 && !pick; i--) {
        const { mover } = g.chain[i];
        if (!clashes(mover, taken) && !untouchable(mover) && getComputedStyle(mover).visibility !== 'hidden') pick = g.chain[i];
      }
      if (!pick) continue;
      const how = anchor(pick.mover, scrolling);
      if (!how) continue;
      const near = room(m, pick.mover, pick.box, how, taken, scrolling);
      if (near.reach < 1) continue;
      // A bar's row laid out by flex or grid makes the room itself, its
      // buttons flexing together inside the safe area, the gaps between
      // them its own: a bar the page fixes or makes sticky, as far as it
      // reaches where it stands, and the page's header at its top, beside
      // the status bar, all the way (GitHub's). Only for a group the row
      // lays out: one placed absolutely in it (Apple's menu button) doesn't
      // move with the row's padding, and slides with its neighbours instead.
      const row = g.row;
      if (row && !given.has(row) && !refused.has(row) && laidIn(pick.mover, row) && !carries(row) &&
          /flex|grid/.test(getComputedStyle(row).display) &&
          row.getBoundingClientRect().height <= ROW(pick.box.height) &&
          (how === 'fixed' || how === 'sticky' || (how === 'page' && atTop(m, row)))) {
        const needed = how === 'page' ? near.reach : near.reach * cover(m, near.union.top, near.union.bottom);
        if (needed >= 1) {
          const style = getComputedStyle(row);
          given.set(row, {
            kind: 'row', pad: parseFloat(m.right ? style.paddingRight : style.paddingLeft) || 0,
            extra: Math.ceil(needed + GAP), widen: 0, box: row.getBoundingClientRect(), sized: false, fresh: true,
          });
          more = true;
          continue;
        }
      }
      let push = Math.max(0, Math.min(near.reach, near.space));
      // Kept from moving far enough by a block of text given room already:
      // the text gives a little more, kept from look to look, and the group
      // moves the whole way.
      const short = Math.ceil(near.reach - push);
      if (short >= 1 && near.blocker && !widened.has(near.blocker)) {
        const block = lineBlock(near.blocker.nodeType === Node.TEXT_NODE ? near.blocker.parentElement : near.blocker);
        const wrap = block && given.get(block);
        if (wrap && wrap.kind === 'text') {
          wrap.widen += short;
          wrap.extra += short;
          wrap.fresh = true;
          widened.add(near.blocker);
          more = true;
          continue;
        }
      }
      if (push < Math.min(near.reach, LEAST)) continue;
      for (const member of near.members) taken.add(member);
      groups.push({ members: near.members, union: near.union, push, how, lead: pick.box.top });
    }
    return { groups, more };
  }

  // MARK: Looking at the page

  function look() {
    timer = 0;
    if (!strip || !document.body || document.hidden) return;
    // Never while the page moves: what changed then would show as a jump under the finger.
    const moving = Date.now() - lastScroll;
    if (moving < STILL) {
      timer = setTimeout(look, STILL - moving + 20);
      return;
    }
    last = Date.now();
    watch();
    watchRoots();
    adopt();
    const m = measured();
    measure = m;
    shownCache = new Map();
    const before = written.get(roomSheet) + written.get(moveSheet);
    // What was moved, back in its place for the measuring.
    hold(true);
    unInline();
    rooms(m);
    giveRoom(m);
    let planned = plan(m);
    if (planned.more) {
      giveRoom(m);
      planned = plan(m);
    }
    hold(false);
    move(m, planned.groups);
    // Holding on to nothing of the page's.
    range.setStart(document, 0);
    range.collapse(true);
    shownCache = new Map();
    pace = before === written.get(roomSheet) + written.get(moveSheet) ? Math.min(pace * 2, SLOWEST) : PACE;
    follow();
  }

  // The groups moved, held in their places, or let go again, each by its
  // own style: a translate lays nothing out, so holding them reflows
  // nothing; and no transition of the page's carries them back meanwhile.
  // What the page had in their style comes back as it was.
  const held = new Map();
  function hold(on) {
    if (!on) {
      for (const [node, saved] of held) {
        node.style.removeProperty('translate');
        node.style.removeProperty('transition');
        if (saved) node.style.setProperty('transition', saved.value, saved.priority);
      }
      held.clear();
      return;
    }
    for (const node of marked) {
      if (inlined.has(node) || held.has(node)) continue;
      const value = node.style.getPropertyValue('transition');
      held.set(node, value ? { value, priority: node.style.getPropertyPriority('transition') } : null);
      node.style.setProperty('transition', 'none', 'important');
      node.style.setProperty('translate', 'none', 'important');
    }
  }

  // The script's sheets among the document's, last, as the page may have replaced the list.
  function adopt() {
    const adopted = document.adoptedStyleSheets;
    if (adopted.includes(roomSheet) && adopted.includes(moveSheet)) return;
    document.adoptedStyleSheets = [...adopted.filter((sheet) => sheet !== roomSheet && sheet !== moveSheet),
      roomSheet, moveSheet];
  }

  // A sheet's rules, written only when they changed; whether they did.
  function write(sheet, text) {
    if (written.get(sheet) === text) return false;
    written.set(sheet, text);
    sheet.replaceSync(text);
    return true;
  }

  // The groups moved, as rules: by where they stand, by the page's scroll,
  // or by a property the script sets as they scroll.
  function move(m, groups) {
    const sign = m.right ? -1 : 1;
    const scrollTop = window.scrollY;
    const rules = [];
    const moving = new Set();
    const tracking = [];
    for (const g of groups) {
      const by = g.push * sign;
      let rule = null;
      if (g.how === 'fixed') {
        const now = by * cover(m, g.union.top, g.union.bottom);
        if (Math.abs(now) >= 0.5) rule = `translate:${now.toFixed(1)}px 0 !important`;
      } else if (g.how === 'page' && scrolled) {
        const keyframes = slant(m, g.union, by, scrollTop);
        if (keyframes) {
          const name = `eglu-strip-${number(g.members[0])}`;
          rules.push(`@keyframes ${name}{${keyframes.frames}}`);
          rule = `animation:${name} linear both !important;animation-timeline:scroll(root block) !important;` +
            `animation-range:${keyframes.from}px ${keyframes.to}px !important`;
        }
      } else {
        rule = 'translate:var(--eglu-strip,0px) 0 !important';
        // Where the group's top is from its first member's, which is what is measured as it scrolls.
        tracking.push({ nodes: g.members, height: g.union.bottom - g.union.top, above: g.lead - g.union.top, push: by, by: NaN });
      }
      if (!rule) continue;
      const shadowed = g.members.some(inShadow);
      if (shadowed && g.how === 'fixed') {
        for (const member of g.members) member.style.setProperty('translate', rule.slice(10, rule.indexOf(' !')), 'important');
      } else if (shadowed && !tracking.some((one) => one.nodes === g.members)) {
        tracking.push({ nodes: g.members, height: g.union.bottom - g.union.top, above: g.lead - g.union.top, push: by, by: NaN });
      }
      for (const member of g.members) {
        if (shadowed) inlined.add(member);
        else rules.push(`[${MARK}="${number(member)}"]{${rule}}`);
        moving.add(member);
      }
    }
    for (const node of marked) {
      if (moving.has(node)) continue;
      node.removeAttribute(MARK);
      node.style.removeProperty('--eglu-strip');
    }
    for (const node of moving) {
      const n = String(number(node));
      if (node.getAttribute(MARK) !== n) node.setAttribute(MARK, n);
    }
    marked = moving;
    tracked = tracking;
    const text = rules.join('\n');
    write(moveSheet, text);
  }

  // A group that scrolls with the page, as keyframes on the page's scroll:
  // at each scroll where its top or bottom meets a band or the end of a
  // band's slant, how far aside it is, and between those, half way along,
  // where two slants may meet. Nil where it never moves.
  function slant(m, union, push, scrollTop) {
    const height = union.bottom - union.top;
    // The scroll at which the group's top is at `top` in the window.
    const at = (top) => scrollTop + union.top - top;
    const marks = new Set();
    for (const [a, b] of m.bands) {
      for (const top of [b + m.ramp, b, a - height, a - height - m.ramp]) marks.add(Math.max(0, Math.round(at(top))));
    }
    const scrolls = [...marks].sort((x, y) => x - y);
    const from = scrolls[0];
    const to = scrolls[scrolls.length - 1];
    if (to - from < 1) return null;
    const samples = [];
    for (let i = 0; i < scrolls.length; i++) {
      samples.push(scrolls[i]);
      if (i + 1 < scrolls.length) samples.push((scrolls[i] + scrolls[i + 1]) / 2);
    }
    let moves = false;
    const frames = samples.map((scroll) => {
      const top = union.top - (scroll - scrollTop);
      const by = push * cover(m, top, top + height);
      if (Math.abs(by) >= 0.5) moves = true;
      const offset = ((scroll - from) / (to - from)) * 100;
      return `${offset.toFixed(3)}%{translate:${by.toFixed(1)}px 0}`;
    }).join('');
    return moves ? { frames, from, to } : null;
  }

  // The groups moved by script, from where each stands now: its first
  // member's place says where the whole group is.
  function follow() {
    frame = 0;
    if (!measure) return;
    for (const one of tracked) {
      const top = one.nodes[0].getBoundingClientRect().top - one.above;
      const by = one.push * cover(measure, top, top + one.height);
      if (Math.abs(by - one.by) < 0.5) continue;
      one.by = by;
      for (const node of one.nodes) {
        if (inlined.has(node)) node.style.setProperty('translate', `${by.toFixed(1)}px 0`, 'important');
        else node.style.setProperty('--eglu-strip', by.toFixed(1) + 'px');
      }
    }
  }

  // What was moved in shadow roots, back in its place, at once.
  function unInline() {
    for (const node of inlined) {
      const value = node.style.getPropertyValue('transition');
      const priority = node.style.getPropertyPriority('transition');
      node.style.setProperty('transition', 'none', 'important');
      node.style.removeProperty('translate');
      void node.getBoundingClientRect();
      node.style.removeProperty('transition');
      if (value) node.style.setProperty('transition', value, priority);
    }
    inlined = new Set();
  }

  const inShadow = (node) => node.getRootNode() !== document;

  function clear() {
    clearTimeout(timer);
    clearTimeout(idle);
    if (frame) cancelAnimationFrame(frame);
    timer = 0;
    idle = 0;
    frame = 0;
    for (const node of marked) {
      node.removeAttribute(MARK);
      node.style.removeProperty('--eglu-strip');
    }
    for (const node of given.keys()) node.removeAttribute(ROOM);
    hold(false);
    unInline();
    marked = new Set();
    given = new Map();
    refused = new WeakSet();
    tracked = [];
    measure = null;
    for (const sheet of [roomSheet, moveSheet]) write(sheet, '');
    document.adoptedStyleSheets = document.adoptedStyleSheets.filter((sheet) => sheet !== roomSheet && sheet !== moveSheet);
    if (watched) {
      watched.mutations.disconnect();
      watched.sizes.disconnect();
      watched = null;
    }
  }

  // MARK: When to look again

  // Soon, but no sooner than the pace allows after the last look. What the
  // person does (a tap, a scroll ended, the window's size) calls for a look
  // at the usual pace; the page's own changes at the pace its last looks
  // earned, which slows while they change nothing.
  function soon(delay = 0, eager = true) {
    if (!strip) return;
    const wait = Math.max(delay, last + (eager ? PACE : pace) - Date.now(), 0);
    if (timer) {
      if (!eager) return;
      clearTimeout(timer);
    }
    timer = setTimeout(look, wait);
  }

  // The page's changes: what it adds and takes away, a class or a menu
  // opened, its size, the window's, the fonts and pictures coming in, a
  // tap that may open something, and each scroll once it has stopped (a
  // header the page hides as it scrolls). Not the page's inline styles,
  // which a page's own animations change at every frame.
  function watch() {
    if (watched) return;
    const mutations = new MutationObserver((records) => {
      if (records.length) soon(0, false);
    });
    mutations.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'hidden', 'open'],
    });
    const sizes = new ResizeObserver(() => soon(0, false));
    sizes.observe(document.documentElement);
    sizes.observe(document.body);
    watched = { mutations, sizes, roots: new WeakSet() };
  }

  // The shadow roots hung on the page's body (a chat widget's), and those
  // the strip's column was looked into, watched as the page is: what they
  // draw comes after the page, unseen by its watch.
  function watchRoots() {
    for (const child of document.body.children) if (child.shadowRoot) watchRoot(child.shadowRoot);
  }

  function watchRoot(root) {
    if (!watched || watched.roots.has(root)) return;
    watched.roots.add(root);
    watched.mutations.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'hidden', 'open'] });
  }

  window.addEventListener('resize', () => soon());
  if (window.visualViewport) window.visualViewport.addEventListener('resize', () => soon());
  window.addEventListener('load', () => soon());
  document.addEventListener('DOMContentLoaded', () => soon());
  document.addEventListener('visibilitychange', () => soon());
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => soon());
  // A tap may open or close something, which may come in over a second.
  document.addEventListener('click', () => {
    soon(350);
    setTimeout(() => soon(), 1200);
  }, true);
  // The page's own scroll is what moves under the finger: a box scrolling
  // by itself (Apple's galleries turn on their own) doesn't hold looks back.
  document.addEventListener('scroll', (event) => {
    if (!strip) return;
    if (tracked.length && !frame) frame = requestAnimationFrame(follow);
    if (event.target !== document && event.target !== document.scrollingElement) return;
    lastScroll = Date.now();
    clearTimeout(idle);
    idle = setTimeout(() => soon(), STILL);
  }, { capture: true, passive: true });

  function set(next) {
    const was = strip;
    strip = next && Array.isArray(next.bands) && next.width > 0 ? next : null;
    // None, or a strip on another side or of another width: what was given
    // and moved for the old one goes, once. Its bands alone changing (the
    // status bar and the strip's items come in one by one as the page
    // shows) leaves the text's room as it is: the next look moves what
    // needs moving, and nothing is laid out again meanwhile.
    if (!strip || (was && (was.side !== strip.side || was.width !== strip.width))) clear();
    if (strip) soon();
  }

  // What the last look did, for Diagnostics and tests.
  Object.defineProperty(window, '__egluStrip', { value: Object.freeze({ set }), configurable: false });
})();
