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
// band the room for it slants (the ramp), so a button slides aside as it
// scrolls up towards the items, and back as it scrolls clear of them: the
// room is a trapezoid, not a step. Where the app couldn't find where the
// items stand, the whole strip is one band.
//
// What moves is a button, a link or a field, with the box round it while
// that box is no more than a few controls (a header's icons in their own
// list go together), and the controls close beside it, the gaps between
// them kept; it moves the whole way or not at all, never over what is next
// to it. Running text in its way gives a little more room first, where it
// may still be laid out (Apple's country banner's ✕). Each moves by an
// animation on its own place in the window (a view timeline), which WebKit
// runs as the page scrolls: nothing is measured or written then.
// Nothing is moved that the page animates or transforms itself, or that
// sits in a box that scrolls by itself or sideways (a carousel).
//
// What the page floats or sticks over itself is a layer of its own, found
// by what is topmost down the strip's column as the page stacks it
// (z-index), into shadow roots however deep: a box the page fixes in the
// window or makes sticky. A layer is drawn inside the safe area whatever
// the bands, the trapezoid being for what scrolls under the strip: a small
// one (a FAB, a chat button, a menu) moved by the strip's width, its margin
// kept; a wide one (a bar, a sheet) given padding on the strip's side, its
// ground still running on under the glass.
//
// Nothing it does lays the page out while a finger is on it or the page
// moves, and it works in slices of a few milliseconds, the page's own work
// between. What it lays out (text's room, a header's row) it writes while
// the page is still coming in, before the first touch; after that only
// where the page is below the window, so nothing shown moves.
//
// It runs in the app's own content world. The app calls set() with the
// strip in the page view's points, or null when the page no longer runs
// under one (Page.strip).
(() => {
  'use strict';
  if (window.__egluStrip) return;

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
  // Controls this close beside a group, in CSS pixels, move with it, the
  // gaps between them kept (Apple's search and bag beside its menu, each in
  // a box of its own, 61 apart).
  const CLUSTER = 64;
  // A group's row: what is no more than this much taller than the group.
  const ROW = (height) => height * 2.5 + 24;
  // A group with more inside than this is a part of the page, not a few controls.
  const MOST = 150;
  // A scroll or a touch this recent holds the work back, in milliseconds.
  const STILL = 300;
  // The work's slice, in milliseconds: then the page's own turn.
  const SLICE = 4;
  // After the page's load, this long, or until the first touch, what shows
  // may still be laid out anew: the page is still coming in.
  const SETTLE = 2500;
  // What draws itself, whatever its style: its box is what it shows.
  const DRAWN = /^(IMG|SVG|VIDEO|CANVAS|IFRAME|INPUT|BUTTON|SELECT|TEXTAREA|PICTURE|OBJECT|EMBED|svg)$/;
  // Text that is not laid out as text on the page.
  const UNSEEN = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TEXTAREA|OPTION|TITLE)$/;
  const timelines = typeof ViewTimeline === 'function' && typeof Element.prototype.animate === 'function';

  let strip = null;
  // The strip in the page's CSS pixels, as last measured.
  let m = null;
  // Told anew with other bands: what was looked at and left is looked at again.
  let generation = 0;
  let settled = false;
  let touches = 0;
  let lastMove = 0;
  let timer = 0;
  let slices = 0;
  let longest = 0;
  // Writes made while the page moved or a finger was on it: none, by design.
  let unsteady = 0;
  // The longest slice once the page has come in.
  let calm = 0;
  // Slices a page's own state threw off, and the last error.
  let failures = 0;
  let failed = '';
  // The room given, each text block's or bar row's padding at the strip's
  // side, in its own style, with what the page had there before.
  let given = new Map();
  let refused = new WeakSet();
  // Blocks that need room while they show: given it once below the window.
  let deferred = new Set();
  // The groups moved, each member with its animation; a member's group.
  let groups = new Set();
  // Each list moved as one, by the box holding its rows.
  let lists = new Map();
  let moved = new WeakMap();
  const ours = new WeakSet();
  // Each control looked at in this generation, moved or not; each layer.
  let tried = new WeakMap();
  let layered = new WeakMap();
  // The boxes round controls given to the observer.
  let boxes = new WeakSet();
  // Controls the observer finds reaching under the strip, a window above
  // and below included; those still to look at.
  const near = new Set();
  const pending = new Set();
  // What the page added, to look through; whether all of it is to be looked at again.
  let added = [];
  let rescan = false;
  let swept = false;
  let rebands = false;
  // The text walked so far, and the parts added since, to walk next.
  let walker = null;
  let textRoots = [];
  // Whether the whole page's text is being walked (a rescan).
  let walking = false;
  // Controls still to give the observer, a slice at a time; the column it watches.
  let observing = [];
  let column = '';
  // When the layers were last looked for, and whether the page changed since.
  let probed = 0;
  let probeDue = false;
  let observer = null;
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
      top,
      scale,
      // The window's height as the page's view timelines see it.
      height: window.innerHeight,
      // The safe area's edge, beside the strip.
      edge: right ? left + width - inset : left + inset,
      bands: strip.bands.map(([a, b]) => [top + a / scale, top + b / scale]),
      ramp: Math.max(1, strip.ramp / scale),
    };
  }

  // How much of the way aside a box from `top` to `bottom` must be: all of
  // it beside a band, none where the strip is empty, and on the slant
  // between in proportion.
  function cover(top, bottom) {
    let most = 0;
    for (const [a, b] of m.bands) {
      if (top < b && bottom > a) return 1;
      const away = top >= b ? top - b : a - bottom;
      most = Math.max(most, 1 - away / m.ramp);
    }
    return most;
  }

  // How far a box reaches past the safe area's edge, under the strip.
  const into = (r) => (m.right ? r.right - m.edge : m.edge - r.left);
  // Whether a box is in the window at all, from side to side: a drawer
  // parked past the window's edge is not under the strip.
  const inView = (r) => r.left < m.left + m.width - 1 && r.right > m.left + 1;

  // What a node shows, from side to side: an element's box where it paints
  // (a background, a border, a picture, a control), else the text and the
  // painted boxes in it; a line of text's own extent. Not what is there
  // only for VoiceOver (text in a box a pixel wide) or parked out of the
  // window: Apple's header's icons each hold such a label. Nil for nothing
  // shown. Kept for the slice: a row's boxes are looked at for each group in it.
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
    const walk = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (inner) => inner.nodeType !== Node.ELEMENT_NODE || inner.getClientRects().length ? NodeFilter.FILTER_ACCEPT
        : getComputedStyle(inner).display === 'contents' ? NodeFilter.FILTER_SKIP : NodeFilter.FILTER_REJECT,
    });
    let looked = 0;
    for (let inner = walk.nextNode(); inner; inner = walk.nextNode()) {
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

  // MARK: Room: running text, and bars' rows

  // The block a line of text is laid out in: its nearest box that is not inline.
  function lineBlock(node) {
    for (let up = node; up && up !== document.body && up !== document.documentElement; up = up.parentElement) {
      const display = getComputedStyle(up).display;
      if (display !== 'inline' && display !== 'contents') return up;
    }
    return null;
  }

  // Whether a node is in a row that scrolls sideways (a carousel).
  function sideways(node) {
    for (let up = node.parentElement; up && up !== document.body; up = up.parentElement) {
      const x = getComputedStyle(up).overflowX;
      if ((x === 'auto' || x === 'scroll') && up.scrollWidth > up.clientWidth + 1) return true;
    }
    return false;
  }

  // Whether a node is inside a block given room already, which its lines wrap with.
  function inGiven(node) {
    for (let up = node.parentElement; up && up !== document.body; up = up.parentElement) if (given.has(up)) return true;
    return false;
  }

  // Whether what is laid out at `top` may be laid out anew now: anywhere
  // while the page is still coming in, then only below the window, where
  // nothing shown moves for it.
  const layable = (top) => !settled || top > m.height + 40;

  // The block a line of text runs in, and the room its lines need at the
  // strip's side so they end at its edge: not text in a control or a group
  // that moves (a button's label), in a row that scrolls sideways, or in
  // something typed in; nor a block inside one given room already. Nil for
  // one that needs none.
  function textRoom(text) {
    const parent = text.parentElement;
    if (!parent || UNSEEN.test(parent.tagName) || !/\S/.test(text.data)) return null;
    const r = parent.getBoundingClientRect();
    if (r.width < 1 || into(r) < 1 || !inView(r)) return null;
    const block = lineBlock(parent);
    if (!block || given.has(block) || refused.has(block) || moved.has(block)) return null;
    const box = block.getBoundingClientRect();
    // Text kept on one line takes the padding too: where its box clips it, its ellipsis comes sooner.
    if (box.width < 40 || block.isContentEditable || inGiven(block)) return null;
    const control = block.closest(PRESSABLE);
    if (control && control.getBoundingClientRect().width <= WIDE * m.width) return null;
    if (sideways(block)) return null;
    const style = getComputedStyle(block);
    const pad = parseFloat(m.right ? style.paddingRight : style.paddingLeft) || 0;
    const border = parseFloat(m.right ? style.borderRightWidth : style.borderLeftWidth) || 0;
    const reach = m.right ? box.right - border - pad - m.edge : m.edge - box.left - border - pad;
    return reach >= 1 ? { block, room: { kind: 'text', pad, extra: Math.ceil(reach), width: box.width, top: box.top } } : null;
  }

  const sideProperty = () => (m.right ? 'padding-right' : 'padding-left');

  // A block's or a row's room, written in its own style, over what the page
  // had there, which comes back when the room goes.
  function give(node, room) {
    const property = sideProperty();
    room.property = property;
    room.saved = keep(node, [property, 'box-sizing']);
    room.sized = false;
    room.fresh = true;
    if (busy()) unsteady++;
    node.style.setProperty(property, `${(room.pad + room.extra).toFixed(1)}px`, 'important');
    given.set(node, room);
  }

  // What the page has in a node's own style for these properties.
  const keep = (node, properties) => properties.map((property) =>
    [property, { value: node.style.getPropertyValue(property), priority: node.style.getPropertyPriority(property) }]);

  function restore(node, room) {
    for (const [property, saved] of room.saved) {
      node.style.removeProperty(property);
      if (saved.value) node.style.setProperty(property, saved.value, saved.priority);
    }
  }

  // The room just given, laid out: a block that grew wider for its padding
  // (a width the page set, outside its padding) is sized to hold it; one
  // that still grows (a box as wide as what is in it) gets none. Put right
  // only where it may be laid out anew: one scrolled into view meanwhile
  // waits until it is below the window again.
  function checkGiven() {
    for (const [node, room] of given) {
      if (!room.fresh) continue;
      if (!node.isConnected) {
        // Its own style back, should the page put it back in.
        restore(node, room);
        given.delete(node);
        continue;
      }
      const box = node.getBoundingClientRect();
      if (box.width <= room.width + 1) {
        room.fresh = false;
      } else if (!layable(box.top)) {
        continue;
      } else if (!room.sized) {
        room.sized = true;
        node.style.setProperty('box-sizing', 'border-box', 'important');
      } else {
        restore(node, room);
        given.delete(node);
        refused.add(node);
      }
    }
  }

  // MARK: Groups

  // The group round something that can be pressed: the boxes round it, from
  // itself out, while each is no wider than a group and no taller than its
  // row; and the row it stands in, where a wider box stopped the climb. An
  // inline link is moved by the block it is in, if that is a group: never
  // on its own out of a line of text.
  function group(node, r) {
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

  // A transform that moves or turns what it holds, as opposed to one that
  // only puts it on a layer of its own (translateZ(0)).
  function shifts(style) {
    for (const property of ['translate', 'rotate', 'scale']) if (style[property] && style[property] !== 'none') return true;
    const t = style.transform;
    if (!t || t === 'none') return false;
    const n = t.slice(t.indexOf('(') + 1, -1).split(',').map(Number);
    if (t.startsWith('matrix3d')) return !(n[0] === 1 && n[1] === 0 && n[4] === 0 && n[5] === 1 && n[12] === 0 && n[13] === 0);
    return !(n[0] === 1 && n[1] === 0 && n[2] === 0 && n[3] === 1 && n[4] === 0 && n[5] === 0);
  }

  // How the group goes along as the page scrolls: 'fixed' with the window,
  // 'page' with the page's own scroll, 'sticky'; or null where it can't be
  // moved by its place in the window: in a box that scrolls by itself or
  // sideways, under a box the page moves itself, or fixed inside a box that
  // holds it. Nor a box that scrolls by itself, moved whole.
  function anchor(mover, rootScrolls) {
    let how = null;
    for (let node = mover; node && node !== document.documentElement; node = node.parentElement) {
      const style = getComputedStyle(node);
      const x = style.overflowX;
      const y = style.overflowY;
      if ((x === 'auto' || x === 'scroll') && node.scrollWidth > node.clientWidth + 1) return null;
      if ((y === 'auto' || y === 'scroll') && node.scrollHeight > node.clientHeight + 1 &&
          (node !== document.body || !rootScrolls)) return null;
      if (node !== mover) {
        if (shifts(style)) return null;
        if (how === 'fixed' && (style.transform !== 'none' || style.filter !== 'none' || style.perspective !== 'none' ||
            /paint|layout|strict|content/.test(style.contain) || (style.backdropFilter && style.backdropFilter !== 'none'))) {
          return null;
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
    if (own.animationName !== 'none' || shifts(own)) return true;
    if (mover.getAnimations && mover.getAnimations().some((animation) => !ours.has(animation))) return true;
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

  // Whether a node is, holds or is inside one moved already: moved again, it would go twice as far.
  function clashes(node) {
    if (moved.has(node)) return true;
    for (let up = node.parentElement; up; up = up.parentElement) if (moved.has(up)) return true;
    for (const one of groups) for (const member of one.members) if (node.contains(member.node)) return true;
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
  function atTop(row) {
    const band = m.bands[0];
    return !!band && band[0] <= m.top + 1 && row.getBoundingClientRect().top + window.scrollY < band[1];
  }

  // How far what a row lays out reaches past the safe area's edge: its
  // farthest box or line (GitHub's avatar, beyond its inbox).
  function rowReach(row) {
    let reach = 0;
    for (const child of laidOut(row)) {
      const r = extent(child);
      if (r) reach = Math.max(reach, into(r));
    }
    return reach;
  }

  // A header's row given room at the strip's side for all it lays out
  // there, its farthest button the gap from the safe area's edge, whichever
  // button was looked at first; more where it has some and something still
  // reaches under the strip (a button come late). Never more than the
  // strip is wide. Whether it was given room.
  function padRow(row, reach) {
    const needed = Math.max(reach, rowReach(row));
    if (needed < 1) return false;
    const had = given.get(row);
    const most = Math.ceil((m.right ? m.left + m.width - m.edge : m.edge - m.left) + GAP);
    const extra = Math.min(most, Math.ceil(needed + GAP) + (had ? had.extra : 0));
    if (had && extra <= had.extra + 0.5) return false;
    const width = row.getBoundingClientRect().width;
    const style = getComputedStyle(row);
    const room = had || { kind: 'row', pad: parseFloat(m.right ? style.paddingRight : style.paddingLeft) || 0, extra, width };
    const was = room.extra;
    return inPlace(row, () => {
      if (had) {
        had.extra = extra;
        had.fresh = true;
        row.style.setProperty(had.property, `${(had.pad + extra).toFixed(1)}px`, 'important');
      } else {
        give(row, room);
      }
      // A row whose width is set outside its padding holds it inside instead.
      if (row.getBoundingClientRect().width > width + 0.5) {
        room.sized = true;
        row.style.setProperty('box-sizing', 'border-box', 'important');
      }
    }, () => {
      if (had) {
        had.extra = was;
        row.style.setProperty(had.property, `${(had.pad + was).toFixed(1)}px`, 'important');
        if (!had.sized) row.style.removeProperty('box-sizing');
      } else {
        restore(row, room);
        given.delete(row);
      }
      refused.add(row);
    });
  }

  // A write that lays out what is inside `node`, made at once where the
  // page may be laid out anew (layable). Once it has settled, in the
  // window, it stands only where `node` keeps its place and its height:
  // what is in it moves along it, and nothing round it moves. One that
  // doesn't is taken back before it is drawn. Whether it stands.
  function inPlace(node, write, undo) {
    const before = node.getBoundingClientRect();
    if (layable(before.top)) {
      write();
      return true;
    }
    const holder = node.parentElement;
    const held = holder ? holder.getBoundingClientRect().height : 0;
    write();
    const after = node.getBoundingClientRect();
    if (Math.abs(after.top - before.top) < 0.5 && Math.abs(after.height - before.height) < 0.5 &&
        (!holder || Math.abs(holder.getBoundingClientRect().height - held) < 0.5)) {
      return true;
    }
    undo();
    return false;
  }

  // What is beside the group, on the side away from the strip, level with
  // it in its row: the boxes and text beside it, and beside each box round
  // it up to its row's height. Its own neighbours in the box it is in join
  // it where they hold something to press and can move too (the icons in a
  // header's list), nearest first, while the whole stays no wider than a
  // group; the first that doesn't, or anything else, is how far the group
  // can go. The group's reach and room are measured by what it shows, not
  // its box: a cell's link at the far end of a wide cell.
  function room(mover, box, how, rootScrolling) {
    const full = extent(mover) || box;
    const shown = visible(mover, full) || box;
    // Cut off by a box round it at a place under the strip: moved, it stays
    // cut off there, the box's edge where it was. Not cut off by the
    // window's edge (Apple's ✕, its box past it), which moving it uncovers.
    const clipped = into(shown) >= 1 && (m.right
      ? shown.right < full.right - 1 && shown.right < m.left + m.width - 1
      : shown.left > full.left + 1 && shown.left > m.left + 1);
    const tallest = ROW(box.height);
    const beside = [];
    let node = mover;
    const consider = (child, depth, sibling) => {
      if (child === node || (child.contains && child.contains(mover))) return;
      const r = extent(child);
      if (!r) return;
      // Within its row's height: whether level with the group is told as the group grows.
      if (Math.min(r.bottom, box.top + tallest) - Math.max(r.top, box.bottom - tallest) <= 0) return;
      // On the strip's side of the group: not in the way.
      if (m.right ? r.left >= shown.right - 1 : r.right <= shown.left + 1) return;
      const element = child.nodeType === Node.ELEMENT_NODE ? child : null;
      // Reaching under the group: what it stands on (a search field under its buttons).
      const behind = m.right ? r.right > shown.left + 1 : r.left < shown.right - 1;
      // A row that draws nothing of its own, too wide to move along,
      // reaching behind the group, or that can't move itself: what is in
      // it, one by one (Apple's header's list, its search and its bag
      // beside the menu at the end).
      if (element && depth < 3 && !paints(element) &&
          (behind || r.width > WIDE * m.width || (element.children.length && untouchable(element)))) {
        for (const inner of laidOut(element)) consider(inner, depth + 1, false);
        return;
      }
      if (behind) return;
      beside.push({ node: element, text: element ? null : child, r, sibling: sibling && !!element });
    };
    for (let up = 0; up < 8 && node.parentElement; up++) {
      const parent = node.parentElement;
      for (const child of laidOut(parent)) consider(child, 0, up === 0);
      if (parent === document.body) break;
      if (parent.getBoundingClientRect().height > tallest) break;
      node = parent;
    }
    beside.sort((a, b) => (m.right ? b.r.right - a.r.right : a.r.left - b.r.left));
    const members = [mover];
    const union = { left: shown.left, right: shown.right, top: box.top, bottom: box.bottom };
    let limit = m.right ? m.left + GAP : m.left + m.width - GAP;
    let blocker = null;
    for (const { node: next, text, r, sibling } of beside) {
      // Level with the group as it has grown (a taller member reaches what the first didn't).
      const level = Math.min(r.bottom, union.bottom) - Math.max(r.top, union.top);
      if (level < Math.min(r.height, union.bottom - union.top) * 0.3) continue;
      const gap = m.right ? union.left - r.right : r.left - union.right;
      // Under the group as it has grown: what it stands on.
      if (gap < -1) continue;
      const width = Math.max(union.right, r.right) - Math.min(union.left, r.left);
      if (next && (sibling || gap <= CLUSTER) && width <= WIDE * m.width && (next.matches(PRESSABLE) || next.querySelector(PRESSABLE)) &&
          !clashes(next) && !untouchable(next) && anchor(next, rootScrolling) === how) {
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
    const space = clipped ? -1 : m.right ? union.left - limit - GAP : limit - union.right - GAP;
    return { members, union, reach: into(union), space, blocker: clipped ? null : blocker };
  }

  // A control the observer found under the strip: the group round it moved
  // aside, its bar's row given room, or nothing, once a generation. One in
  // a layer the page floats or sticks over itself has its layer drawn
  // inside the safe area first (placeLayer); what is still under the strip
  // then (a bar's ✕ placed absolutely, which the bar's padding doesn't
  // move) moves the whole way, wherever it stands.
  function lookAt(control, scrolling) {
    if (!control.isConnected || tried.get(control) === generation || clashes(control)) return;
    tried.set(control, generation);
    const layer = layerOf(control);
    if (layer) {
      placeLayer(layer);
      if (clashes(control)) return;
    }
    const whole = control.getBoundingClientRect();
    if (whole.width < 1 || whole.height < 1) return;
    const r = visible(control, whole);
    if (!r || into(r) < 1 || !inView(r)) return;
    // A box holding it that draws itself (a card, a search box), or the
    // control itself where it is as wide as a row (a field, a slider):
    // the box ends at the safe area's edge instead, while it may be laid
    // out anew. A wide one that may not stays as it is.
    if (!layer) {
      const box = container(control);
      if (box && narrow(box)) return;
    }
    if (r.width > WIDE * m.width) return;
    const g = group(control, r);
    if (!g) return;
    // The widest box round it that can move: one round something the page
    // places from outside it can't, and then what is inside it may.
    let pick = null;
    for (let i = g.chain.length - 1; i >= 0 && !pick; i--) {
      const { mover } = g.chain[i];
      if (!clashes(mover) && !given.has(mover) && !untouchable(mover) && getComputedStyle(mover).visibility !== 'hidden') {
        pick = g.chain[i];
      }
    }
    if (!pick) return;
    const how = anchor(pick.mover, scrolling);
    if (!how) return;
    const around = room(pick.mover, pick.box, how, scrolling);
    if (around.reach < 1) return;
    // The page's header at its top, beside the status bar, laid out by flex
    // or grid, makes the room itself, its buttons flexing together inside
    // the safe area, the gaps between them its own (GitHub's). Only for a
    // group the row lays out: one placed absolutely in it doesn't move
    // with the row's padding.
    const row = g.row;
    if (!layer && how === 'page' && row && !refused.has(row) && !inGiven(row) &&
        (!given.has(row) || given.get(row).kind === 'row') &&
        laidIn(pick.mover, row) && /flex|grid/.test(getComputedStyle(row).display) &&
        row.getBoundingClientRect().height <= ROW(pick.box.height) && atTop(row) && padRow(row, around.reach)) {
      // The row laid out anew may have made room for what was left.
      generation++;
      for (const one of near) pending.add(one);
      return;
    }
    if (!timelines || (how === 'sticky' && !layer)) return;
    // In a list or a table: its rows' controls move as one column (asked
    // for on 2 November 2026: "rows in the same table have to get same
    // width").
    if (how === 'page' && !layer && moveList(pick, around, scrolling)) return;
    // The whole way or not at all: part of the way leaves it under the strip still.
    const full = !!layer;
    const needed = !full && how === 'fixed' ? around.reach * cover(around.union.top, around.union.bottom) : around.reach;
    if (needed < 1) return;
    if (around.space < needed - 1) {
      // Kept from it by running text given room already, which may be laid
      // out anew still: the text gives a little more, and the group is
      // looked at again once it has (Apple's country banner's ✕).
      if (widen(around, needed)) {
        tried.delete(control);
        pending.add(control);
      }
      return;
    }
    const one = {
      how: full ? 'fixed' : how, full, reach: around.reach, top: around.union.top,
      height: around.union.bottom - around.union.top, members: [],
    };
    for (const node of around.members) {
      const box = node.getBoundingClientRect();
      one.members.push({ node, offset: box.top - around.union.top, height: box.height, animation: null });
      moved.set(node, one);
    }
    groups.add(one);
    animate(one);
  }

  // MARK: Boxes that hold controls

  // The box to end at the safe area's edge for something under the strip:
  // the outermost round it, up to a few, that draws itself (a background,
  // a border: a card, a tab list, a search box) or is a control itself,
  // wider than a group, reaching under the strip, and no taller than half
  // the window (a section of the page is not a box of controls). Not in a
  // layer, which is placed whole, nor in a row that scrolls sideways.
  function container(start) {
    let best = null;
    for (let up = start, n = 0; up && up !== document.body && up !== document.documentElement && n < 6; up = up.parentElement, n++) {
      const r = up.getBoundingClientRect();
      if (r.height > m.height * 0.5) break;
      if (r.width > WIDE * m.width && into(r) >= 1 && (up.matches(PRESSABLE) || paints(up))) best = up;
    }
    if (!best || sideways(best) || given.has(best) || refused.has(best) || inGiven(best)) return null;
    return best.matches(PRESSABLE) || best.querySelector(PRESSABLE) ? best : null;
  }

  // A box the observer found reaching under the strip (one round controls).
  function lookAtBox(box) {
    if (!box.isConnected || tried.get(box) === generation || clashes(box)) return;
    tried.set(box, generation);
    if (layerOf(box)) return;
    const found = container(box);
    if (found) narrow(found);
  }

  // A box of controls ended at the safe area's edge, its insides laying
  // themselves out inside it: one that stands apart from the window's
  // edges (a card) by a margin on the strip's side, kept from growing past
  // its row by a greatest width as well; one as wide as the window (a
  // header's ground) by padding instead, its ground still under the glass.
  // Whatever was given room or moved inside it before gives it back. Where
  // it may be laid out anew, or where it keeps its height (inPlace);
  // whether it was.
  function narrow(box) {
    const r = box.getBoundingClientRect();
    const style = getComputedStyle(box);
    const reach = Math.ceil(m.right ? r.right - m.edge : m.edge - r.left);
    if (reach < 1) return false;
    const bleeds = r.left <= m.left + 1 && r.right >= m.left + m.width - 1;
    let room;
    const done = inPlace(box, () => {
      if (bleeds) {
        const pad = parseFloat(m.right ? style.paddingRight : style.paddingLeft) || 0;
        room = { kind: 'box', pad, extra: reach, width: r.width, top: r.top };
        give(box, room);
        room.sized = true;
        box.style.setProperty('box-sizing', 'border-box', 'important');
      } else {
        const property = m.right ? 'margin-right' : 'margin-left';
        const margin = (parseFloat(m.right ? style.marginRight : style.marginLeft) || 0) + reach;
        room = { kind: 'box', property, saved: keep(box, [property, 'max-width']), fresh: false, sized: true };
        if (busy()) unsteady++;
        box.style.setProperty(property, `${margin}px`, 'important');
        box.style.setProperty('max-width', `calc(100% - ${margin}px)`, 'important');
        given.set(box, room);
      }
    }, () => {
      restore(box, room);
      given.delete(box);
      refused.add(box);
    });
    if (!done) return false;
    // What was done inside it for the old width goes: it is all inside the safe area now.
    for (const [node, room] of [...given]) {
      if (node !== box && box.contains(node)) {
        restore(node, room);
        given.delete(node);
      }
    }
    for (const one of [...groups]) if (one.members.some((member) => box.contains(member.node))) drop(one);
    generation++;
    for (const control of near) pending.add(control);
    return true;
  }

  // MARK: Lists

  // Whether two boxes are rows alike: the same kind, and most of their
  // classes the same (one may be marked as chosen).
  function alike(a, b) {
    if (a.tagName !== b.tagName) return false;
    const x = new Set(a.classList);
    const y = new Set(b.classList);
    if (!x.size && !y.size) return true;
    let both = 0;
    for (const name of x) if (y.has(name)) both++;
    return both / (x.size + y.size - both) >= 0.6;
  }

  // The list a group stands in: its row, the nearest box round it no
  // taller than a few lines whose parent holds two or more others like
  // it, and those rows, up to MOST_ROWS of them. Nil outside a list.
  const MOST_ROWS = 40;
  function listOf(mover, height) {
    let row = mover;
    for (let up = 0; up < 6; up++, row = row.parentElement) {
      const parent = row.parentElement;
      if (!parent || parent === document.body || parent === document.documentElement) return null;
      if (row.getBoundingClientRect().height > Math.max(ROW(height), 120)) return null;
      const rows = [...parent.children].filter((child) => child === row || alike(child, row));
      if (rows.length >= 3) return rows.length > MOST_ROWS ? null : { parent, row, rows };
    }
    return null;
  }

  // How deep a node is in its row.
  function depthIn(row, node) {
    let depth = 0;
    for (let at = node; at && at !== row; at = at.parentElement) depth++;
    return depth;
  }

  // The box in another row standing where `node` stands in its own: one
  // like it, as deep in the row, the nearest to it from side to side
  // (a row may hold a divider the first one doesn't).
  function standing(row, node, depth, center) {
    if (depth === 0) return alike(row, node) ? row : null;
    let best = null;
    let nearest = Infinity;
    for (const at of row.getElementsByTagName(node.tagName)) {
      if (!alike(at, node) || depthIn(row, at) !== depth) continue;
      const r = at.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      const off = Math.abs((r.left + r.right) / 2 - center);
      if (off < nearest) {
        nearest = off;
        best = at;
      }
    }
    return best;
  }

  // A group in a list's row, with the boxes standing where its members
  // stand in every other row, moved as one: all by as far as the farthest
  // reaches, by where the list as a whole stands, so the rows keep one
  // width and their controls one column. Each row's own neighbours must
  // leave the room. A list met again (a row added) takes the new rows in.
  // False where it isn't a list, or a row hasn't the room.
  function moveList(pick, around, scrolling) {
    const list = listOf(pick.mover, pick.box.height);
    if (!list || !around.members.every((node) => list.row.contains(node))) return false;
    const marks = around.members.map((node) => {
      const r = node.getBoundingClientRect();
      return { node, depth: depthIn(list.row, node), center: (r.left + r.right) / 2 };
    });
    const one = lists.get(list.parent);
    const taking = [];
    const alones = [];
    const back = () => {
      for (const alone of alones) {
        for (const member of alone.members) moved.set(member.node, alone);
        groups.add(alone);
        animate(alone);
      }
    };
    for (const row of list.rows) {
      const nodes = marks.map(({ node, depth, center }) => (row === list.row ? node : standing(row, node, depth, center)))
        .filter(Boolean);
      if (!nodes.length) continue;
      // A row moved on its own before the list was found (its text left it
      // room sooner) comes back to its place, to move with the list, and
      // goes aside again on its own if the list can't.
      for (const node of nodes) {
        const alone = moved.get(node);
        if (alone && alone !== one && ![...lists.values()].includes(alone)) {
          drop(alone);
          alones.push(alone);
        }
      }
      if (nodes.some((node) => moved.has(node) && moved.get(node) !== one)) continue;
      if (nodes.every((node) => moved.get(node) === one && one)) continue;
      taking.push(nodes);
    }
    if (!taking.length) {
      back();
      return !!one;
    }
    // Each row's room, from what is beside it there.
    let reach = one ? one.reach : 0;
    const boxes = [];
    for (const nodes of taking) {
      const box = nodes[0].getBoundingClientRect();
      const near = room(nodes[0], box, 'page', scrolling);
      reach = Math.max(reach, into(near.union));
      boxes.push({ nodes, near });
    }
    if (reach < 1) {
      back();
      return !!one;
    }
    // Looked at once for the whole list: its rows' own looks would only do it again.
    for (const { nodes } of boxes) for (const node of nodes) tried.set(node, generation);
    // Every row moves as far as the farthest needs, those clear of the
    // strip too. Rows kept from it by their text, while that text may be
    // laid out anew, have it end where the list leaves room, and the list
    // is looked at again then. Where a row still can't, the list moves as
    // far as its rows all allow, together: one width rather than rows on
    // their own. A row with hardly any room stays where it is.
    const short = boxes.filter(({ near }) => near.space < reach - 1);
    if (short.length && short.filter(({ near: around }) => widen(around, reach)).length) {
      back();
      generation++;
      for (const control of near) pending.add(control);
      return true;
    }
    const moving = boxes.filter(({ near }) => near.space >= reach * 0.25);
    const push = Math.min(reach, ...moving.map(({ near }) => near.space));
    if (!moving.length || push < 1) {
      back();
      return true;
    }
    const group = one || { how: 'page', reach: push, top: 0, height: 0, members: [] };
    group.reach = one ? Math.min(one.reach, push) : push;
    for (const { nodes } of moving) {
      for (const node of nodes) {
        group.members.push({ node, offset: 0, height: 0, animation: null });
        moved.set(node, group);
        tried.set(node, generation);
      }
    }
    // The list's top and foot as it stands now: the moves are sideways, so its members' tops are their own.
    group.members = group.members.filter((member) => member.node.isConnected);
    const tops = group.members.map((member) => member.node.getBoundingClientRect());
    group.top = Math.min(...tops.map((r) => r.top));
    group.height = Math.max(...tops.map((r) => r.bottom)) - group.top;
    group.members.forEach((member, i) => {
      member.offset = tops[i].top - group.top;
      member.height = tops[i].height;
    });
    lists.set(list.parent, group);
    groups.add(group);
    animate(group);
    return true;
  }

  // MARK: Layers

  // The layer a node is drawn in above the page's own: the nearest box
  // round it the page fixes in the window or makes sticky, through shadow
  // roots to their hosts. Nil for the page itself; never its body, which a
  // dialog fixes to keep the page from scrolling behind it.
  function layerOf(node) {
    for (let up = node; up && up !== document.body && up !== document.documentElement;) {
      const position = getComputedStyle(up).position;
      if (position === 'fixed' || position === 'sticky') return { root: up, how: position };
      const home = up.getRootNode();
      up = up.parentElement || (home instanceof ShadowRoot ? home.host : null);
    }
    return null;
  }

  // A layer that floats or sticks over the page drawn inside the safe area,
  // whatever the bands: a small one (a FAB, a chat button, a menu) moved by
  // the strip's width, its margin from the window's edge kept, as far as
  // the window allows on its other side; a wide one (a bar, a sheet) given
  // padding on the strip's side, its own width kept, so what is in it lays
  // itself out inside the safe area while its ground runs on under the
  // strip's glass. A fixed layer is out of the page's flow, so its padding
  // moves nothing else; a sticky one is in it, so its padding only while
  // the page is still coming in. One coming in by an animation of the
  // page's is looked at again once that ends.
  function placeLayer({ root, how }) {
    if (layered.get(root) === generation || given.has(root) || refused.has(root) || clashes(root)) return;
    layered.set(root, generation);
    const r = root.getBoundingClientRect();
    if (r.width < 1 || r.height < 1 || into(r) < 1 || !inView(r)) return;
    const own = getComputedStyle(root);
    // The page moves it by this property already.
    if (own.translate && own.translate !== 'none') return;
    if (root.getAnimations().some((animation) => !ours.has(animation) && animation.playState === 'running')) {
      layered.delete(root);
      probeDue = true;
      schedule(400);
      return;
    }
    const width = m.right ? m.left + m.width - m.edge : m.edge - m.left;
    if (r.width > WIDE * m.width) {
      const pad = parseFloat(m.right ? own.paddingRight : own.paddingLeft) || 0;
      const extra = Math.ceil((m.right ? r.right - m.edge : m.edge - r.left) - pad);
      if (extra < 1) return;
      const room = { kind: 'layer', pad, extra, width: r.width, top: r.top };
      const write = () => {
        give(root, room);
        room.sized = true;
        root.style.setProperty('box-sizing', 'border-box', 'important');
      };
      // A bar stuck in the flow of the page, once it has settled, only
      // where its height stays: the page's rows under it would move.
      if (how !== 'sticky') write();
      else inPlace(root, write, () => {
        restore(root, room);
        given.delete(root);
        refused.add(root);
      });
      return;
    }
    const push = Math.min(width, m.right ? r.left - m.left - GAP : m.left + m.width - GAP - r.right);
    if (push < into(r) - 0.5) return;
    const one = { how: 'fixed', full: true, reach: push, top: r.top, height: r.height, members: [] };
    one.members.push({ node: root, offset: 0, height: r.height, animation: null });
    moved.set(root, one);
    groups.add(one);
    animate(one);
  }

  // The page's layers down the strip's column, as the page stacks them
  // (z-index): what is topmost at each place, into the shadow roots it is
  // drawn in however deep the page hangs them (Channel's chat button), and
  // the layer it belongs to. At most once a second, when the page changed.
  function probeLayers() {
    probed = performance.now();
    probeDue = false;
    const x = m.right ? (m.edge + m.left + m.width) / 2 : (m.left + m.edge) / 2;
    const seen = new Set();
    for (let y = 12; y < m.height; y += 24) {
      let node = document.elementFromPoint(x, y);
      while (node && node.shadowRoot) {
        watchRoot(node.shadowRoot);
        const inner = node.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === node) break;
        node = inner;
      }
      if (!node || seen.has(node)) continue;
      seen.add(node);
      const layer = layerOf(node);
      if (layer) placeLayer(layer);
    }
  }

  // Running text in a group's way gives a little more room where it may
  // still be laid out (twice at most): the block given room round it, its
  // own or one it wraps in (a line under a title, in the title's box), or,
  // where its lines end short of the strip by themselves (a title in a
  // row, beside its "…"), its own block, given room for this. Whether it did.
  function widen(around, needed) {
    const blocker = around.blocker;
    const own = blocker && lineBlock(blocker.nodeType === Node.TEXT_NODE ? blocker.parentElement : blocker);
    let block = own;
    while (block && block !== document.body && !given.has(block)) block = block.parentElement;
    if ((!block || block === document.body) && own && !refused.has(own) && !own.isContentEditable && !moved.has(own)) {
      const box = own.getBoundingClientRect();
      if (!layable(box.top)) return false;
      const style = getComputedStyle(own);
      give(own, { kind: 'text', pad: parseFloat(m.right ? style.paddingRight : style.paddingLeft) || 0, extra: 0, width: box.width, top: box.top });
      block = own;
    }
    const wrap = block && given.get(block);
    if (!wrap || wrap.kind !== 'text' || (wrap.widened || 0) >= 2) return false;
    const box = block.getBoundingClientRect();
    if (!layable(box.top)) return false;
    // Its lines end where the group, moved the whole way, still keeps the
    // gap from them: its padding set to that in one go, as its lines may
    // wrap anywhere (another line of it, longer, then in the way).
    const style = getComputedStyle(block);
    const border = parseFloat(m.right ? style.borderRightWidth : style.borderLeftWidth) || 0;
    const limit = m.right ? around.union.left - needed - GAP : around.union.right + needed + GAP;
    const total = Math.ceil(m.right ? box.right - border - limit : limit - box.left - border);
    // As narrow as that already: something else is in the way.
    if (total <= wrap.pad + wrap.extra + 0.5) return false;
    wrap.widened = (wrap.widened || 0) + 1;
    wrap.extra = total - wrap.pad;
    wrap.fresh = true;
    wrap.width = box.width;
    block.style.setProperty(wrap.property, `${(wrap.pad + wrap.extra).toFixed(1)}px`, 'important');
    return true;
  }

  // MARK: Moving

  // A group's members moved, each by an animation of its own: one that
  // holds where a group the page fixes in the window stands, or one on the
  // member's own place in the window as the page scrolls, which WebKit runs
  // with the scrolling.
  function animate(one) {
    const sign = m.right ? -1 : 1;
    for (const member of one.members) {
      if (member.animation) member.animation.cancel();
      member.animation = null;
      let animation = null;
      if (one.how === 'fixed') {
        // Where it stands now: the move is sideways, so its top is its own (the window may have changed).
        if (member === one.members[0] && member.node.isConnected) one.top = member.node.getBoundingClientRect().top - member.offset;
        const by = sign * one.reach * (one.full ? 1 : cover(one.top, one.top + one.height));
        if (Math.abs(by) < 0.5) continue;
        const frame = { translate: `${by.toFixed(1)}px 0` };
        animation = member.node.animate([frame, frame], { duration: 1000, fill: 'both' });
        animation.pause();
      } else {
        const frames = slope(one, member, sign);
        if (!frames) continue;
        animation = member.node.animate(frames, { timeline: new ViewTimeline({ subject: member.node, axis: 'block' }), fill: 'both' });
      }
      ours.add(animation);
      member.animation = animation;
    }
  }

  // A member's keyframes over its view timeline: at each place in the
  // window where the group's top or foot meets a band or the end of a
  // band's slant, or where the slants of two bands meet, how far aside it
  // is, and half way between. The timeline's progress is where the member is in the
  // window: 0 with its top at the window's foot, 1 with its foot at the
  // window's top. Nil where it never moves.
  function slope(one, member, sign) {
    const H = m.height;
    const h = Math.max(1, member.height);
    // The group's top in the window, and the member's progress there.
    const progress = (top) => (H - (top + member.offset)) / (H + h);
    const tops = new Set([H - member.offset, -h - member.offset]);
    for (const [a, b] of m.bands) for (const top of [b + m.ramp, b, a - one.height, a - one.height - m.ramp]) tops.add(top);
    for (let i = 0; i + 1 < m.bands.length; i++) tops.add((m.bands[i][1] + m.bands[i + 1][0] - one.height) / 2);
    const sorted = [...tops].filter((top) => {
      const p = progress(top);
      return p >= 0 && p <= 1;
    }).sort((x, y) => x - y);
    const samples = [];
    for (let i = 0; i < sorted.length; i++) {
      samples.push(sorted[i]);
      if (i + 1 < sorted.length) samples.push((sorted[i] + sorted[i + 1]) / 2);
    }
    let moves = false;
    const frames = samples.map((top) => {
      const by = sign * one.reach * cover(top, top + one.height);
      if (Math.abs(by) >= 0.5) moves = true;
      return { offset: progress(top), translate: `${by.toFixed(1)}px 0` };
    }).sort((x, y) => x.offset - y.offset);
    return moves ? frames : null;
  }

  function drop(one) {
    for (const member of one.members) {
      if (member.animation) member.animation.cancel();
      moved.delete(member.node);
    }
    groups.delete(one);
  }

  // MARK: Finding what to look at

  // What can be pressed in a part of the page, and in the shadow roots on
  // its body (a chat widget's), given to the observer, which says which
  // reach under the strip.
  function observeIn(root) {
    if (root.nodeType === Node.ELEMENT_NODE && root.matches(PRESSABLE)) observe(root);
    for (const node of root.querySelectorAll(PRESSABLE)) observe(node);
  }

  // A control, and the few boxes round it, which may reach under the strip
  // where it doesn't (a tab list round its tabs).
  function observe(control) {
    observing.push(control);
    for (let up = control.parentElement, n = 0; up && up !== document.body && n < 4; up = up.parentElement, n++) {
      if (boxes.has(up)) break;
      boxes.add(up);
      observing.push(up);
    }
  }

  function watchRoots() {
    for (const child of document.body.children) if (child.shadowRoot) watchRoot(child.shadowRoot);
  }

  function watchRoot(root) {
    if (!watched || watched.roots.has(root)) return;
    watched.roots.add(root);
    watched.mutations.observe(root, { childList: true, subtree: true });
    observeIn(root);
  }

  // The observer looks at the strip's column only, a window above and below
  // it too, so what scrolls in is looked at before it comes.
  function begin() {
    m = measured();
    observeColumn();
    const mutations = new MutationObserver((records) => {
      for (const record of records) {
        if (record.removedNodes.length) swept = true;
        for (const node of record.addedNodes) {
          if (node.nodeType === Node.ELEMENT_NODE) added.push(node);
          // Text put into a box already there: the box, for its text and controls.
          else if (node.nodeType === Node.TEXT_NODE && node.parentElement) added.push(node.parentElement);
        }
      }
      if (added.length > 400) {
        added = [];
        rescan = true;
      }
      schedule();
    });
    watched = { mutations, roots: new WeakSet() };
    rescan = true;
  }

  // The observer over the strip's column, from the safe area's edge to the
  // window's, as wide as the window is now; made anew when that changes.
  function observeColumn() {
    if (observer) observer.disconnect();
    const shy = m.right ? Math.max(0, Math.floor(m.edge - m.left)) : 0;
    const shyRight = m.right ? 0 : Math.max(0, Math.floor(m.left + m.width - m.edge));
    column = `${shy}|${shyRight}`;
    observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          near.add(entry.target);
          pending.add(entry.target);
        } else {
          near.delete(entry.target);
        }
      }
      schedule();
    }, { rootMargin: `100% -${shyRight}px 100% -${shy}px` });
  }

  // MARK: The work, in slices

  // Whether a finger is on the page or it has just moved.
  const busy = () => touches > 0 || performance.now() - lastMove < STILL;

  // Each slice starts just after a frame is drawn, when the page is laid
  // out already: what it reads then costs nothing more, where a read
  // between frames would lay out the page's own changes then and there.
  function schedule(delay = 0) {
    if (!strip || timer) return;
    timer = setTimeout(() => requestAnimationFrame(() => setTimeout(pump, 0)), delay);
  }

  function pump() {
    timer = 0;
    if (!strip || !observer || !document.body || document.hidden) return;
    if (busy()) {
      schedule(STILL);
      return;
    }
    const start = performance.now();
    m = measured();
    // Zoomed in, or the keyboard up, the window shows part of the page, and
    // its timelines aren't the window's: nothing new until it is all back.
    const view = window.visualViewport;
    if (view && (Math.abs(view.offsetTop) > 1 || Math.abs(view.height - window.innerHeight) > 1)) {
      schedule(1000);
      return;
    }
    // The window grew or shrank under the same strip: the observer's column with it.
    const shy = m.right ? Math.max(0, Math.floor(m.edge - m.left)) : 0;
    const shyRight = m.right ? 0 : Math.max(0, Math.floor(m.left + m.width - m.edge));
    if (`${shy}|${shyRight}` !== column) {
      observeColumn();
      rescan = true;
    }
    shownCache = new Map();
    let more = false;
    try {
      more = work(start + SLICE);
    } catch (error) {
      // A page that throws the work off (a node gone mid-look): the slice
      // ends, and the work goes on with the next rather than stopping.
      failures++;
      failed = String(error && error.stack || error).slice(0, 300);
      more = true;
    }
    shownCache = new Map();
    range.setStart(document, 0);
    range.collapse(true);
    slices++;
    if (settled) calm = Math.max(calm, performance.now() - start);
    longest = Math.max(longest, performance.now() - start);
    if (more) schedule(0);
    // The layers looked for again once a second has passed since the last time.
    else if (probeDue) schedule(Math.max(0, 1000 - (performance.now() - probed)));
  }

  // One slice of the work, until `until`; whether more is left. The page
  // as it changed first, then the strip's new bands, the controls found,
  // and the text, which is the longest.
  function work(until) {
    const due = () => performance.now() < until;
    checkGiven();
    const scrolling = rootScrolls();
    if (rescan) {
      rescan = false;
      added = [];
      if (!watched.started) {
        watched.started = true;
        watched.mutations.observe(document.documentElement, { childList: true, subtree: true });
      }
      observeIn(document);
      watchRoots();
      walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      walking = true;
      probeDue = true;
      textRoots = [];
      if (!due()) return true;
    }
    while (observing.length && due()) observer.observe(observing.pop());
    if (observing.length) return true;
    while (added.length && due()) {
      const node = added.shift();
      if (!node.isConnected) continue;
      observeIn(node);
      textRoots.push(node);
      probeDue = true;
    }
    if (probeDue && performance.now() - probed > 1000 && due()) probeLayers();
    if (swept) {
      swept = false;
      for (const one of [...groups]) if (!one.members.every((member) => member.node.isConnected)) drop(one);
      watchRoots();
    }
    if (rebands) {
      rebands = false;
      for (const one of groups) animate(one);
      for (const control of near) pending.add(control);
    }
    // While the whole page's text is first walked, it comes first: a
    // control kept from moving by text gives that text more room, which it
    // must have been given to begin with.
    while (pending.size && !walking && due()) {
      const control = pending.values().next().value;
      pending.delete(control);
      if (control.matches(PRESSABLE)) lookAt(control, scrolling);
      else lookAtBox(control);
    }
    if (pending.size && !walking) return true;
    // Running text: what needs room found first, then all of it written.
    const found = [];
    while ((walker || textRoots.length) && due()) {
      const text = walker && walker.nextNode();
      if (!text) {
        const next = textRoots.shift();
        walker = next && next.isConnected ? document.createTreeWalker(next, NodeFilter.SHOW_TEXT) : null;
        continue;
      }
      const need = textRoom(text);
      if (need && !found.some((one) => one.block === need.block || one.block.contains(need.block))) found.push(need);
    }
    for (const block of [...deferred]) {
      if (!due()) break;
      deferred.delete(block);
      if (!block.isConnected || given.has(block)) continue;
      const text = [...block.childNodes].find((node) => node.nodeType === Node.TEXT_NODE && /\S/.test(node.data)) ||
        document.createTreeWalker(block, NodeFilter.SHOW_TEXT).nextNode();
      const need = text && textRoom(text);
      if (need) found.push(need);
    }
    for (const { block, room } of found) {
      if (given.has(block) || inGiven(block)) continue;
      if (layable(room.top)) give(block, room);
      else deferred.add(block);
    }
    // The text all walked: the controls are looked at again, or for the
    // first time, the text now able to give a little more.
    if (walking && !walker && !textRoots.length) {
      walking = false;
      generation++;
      for (const control of near) pending.add(control);
    }
    // Blocks left for later are looked at again once the page has stopped (touchend).
    return !!walker || textRoots.length > 0 || pending.size > 0 || [...given.values()].some((room) => room.fresh);
  }

  // MARK: Told where the strip is

  function clear() {
    clearTimeout(timer);
    timer = 0;
    for (const one of [...groups]) drop(one);
    for (const [node, room] of given) restore(node, room);
    given = new Map();
    refused = new WeakSet();
    deferred = new Set();
    groups = new Set();
    lists = new Map();
    moved = new WeakMap();
    tried = new WeakMap();
    layered = new WeakMap();
    boxes = new WeakSet();
    near.clear();
    pending.clear();
    added = [];
    observing = [];
    column = '';
    probed = 0;
    probeDue = false;
    walker = null;
    textRoots = [];
    if (observer) observer.disconnect();
    if (watched) watched.mutations.disconnect();
    observer = null;
    watched = null;
    m = null;
  }

  function set(next) {
    const was = strip;
    strip = next && Array.isArray(next.bands) && next.width > 0 ? next : null;
    if (!strip) {
      clear();
      return;
    }
    // On another side, or of another width: what was given and moved for the old one goes, once.
    if (!was || was.side !== strip.side || was.width !== strip.width || !observer) {
      clear();
      generation++;
      if (document.body) begin();
    } else if (JSON.stringify(was.bands) !== JSON.stringify(strip.bands) || was.ramp !== strip.ramp) {
      // Its bands alone: the groups move by the new ones, and what was left is looked at again.
      generation++;
      rebands = true;
    }
    schedule();
  }

  // What the person does holds the work back: a finger on the page, the
  // page's own scroll. The first touch ends the page's coming in.
  addEventListener('touchstart', (event) => {
    touches = event.touches.length;
    settled = true;
  }, { capture: true, passive: true });
  for (const type of ['touchend', 'touchcancel']) {
    addEventListener(type, (event) => {
      touches = event.touches.length;
      lastMove = performance.now();
      // A tap may have opened a menu or a sheet.
      probeDue = true;
      schedule(STILL);
    }, { capture: true, passive: true });
  }
  document.addEventListener('scroll', (event) => {
    if (event.target !== document && event.target !== document.scrollingElement) return;
    lastMove = performance.now();
  }, { capture: true, passive: true });
  const resized = () => {
    lastMove = performance.now();
    if (!m || !strip) return;
    // The window's height is what the moved groups' keyframes are worked out from.
    if (measured().height !== m.height) rebands = true;
    schedule(STILL);
  };
  addEventListener('resize', resized);
  if (window.visualViewport) window.visualViewport.addEventListener('resize', resized);
  const ready = () => {
    if (strip && !observer) begin();
    schedule();
  };
  // While the page comes in, its styles and fonts change what was looked
  // at too soon (a control laid out before its sheet came): looked at again.
  const again = () => {
    probeDue = true;
    if (!settled && observer) {
      generation++;
      for (const control of near) pending.add(control);
    }
    schedule();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready);
  const settle = () => setTimeout(() => {
    settled = true;
  }, SETTLE);
  // Put in after the load (the window learnt of the strip late): from now.
  if (document.readyState === 'complete') settle();
  addEventListener('load', () => {
    settle();
    again();
  });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(again);
  document.addEventListener('visibilitychange', () => schedule());

  // How it stands, for Diagnostics and tests.
  const state = () => ({
    strip: !!strip, settled, generation, near: near.size, pending: pending.size, groups: groups.size,
    given: given.size, deferred: deferred.size, slices, longest: Math.round(longest * 10) / 10, calm: Math.round(calm * 10) / 10, unsteady, failures, failed,
  });

  // What can be pressed and still shows under one of the strip's items,
  // in the window, for tests (StripTour): each one's tag, name, the test
  // page's pattern round it (data-pattern) and its box, as drawn.
  function leftovers() {
    if (!strip) return [];
    const now = measured();
    const found = [];
    const roots = [document];
    for (let i = 0; i < roots.length; i++) {
      for (const node of roots[i].querySelectorAll('*')) {
        if (node.shadowRoot) roots.push(node.shadowRoot);
        if (!node.matches(PRESSABLE)) continue;
        const r = node.getBoundingClientRect();
        // A link as wide as a card, its picture under the glass, stays (WIDE).
        if (r.width < 1 || r.height < 1 || r.bottom <= 0 || r.top >= now.height || r.width > WIDE * now.width) continue;
        const reach = now.right ? r.right - now.edge : now.edge - r.left;
        if (reach < 1 || !now.bands.some(([a, b]) => r.top < b && r.bottom > a)) continue;
        // Shown there, not behind something else nor cut off.
        const x = now.right ? Math.min(r.right - 1, now.edge + reach / 2) : Math.max(r.left + 1, now.edge - reach / 2);
        const y = Math.min(Math.max(r.top + r.height / 2, 1), now.height - 1);
        const hit = roots[i].elementFromPoint ? roots[i].elementFromPoint(x, y) : document.elementFromPoint(x, y);
        if (!hit || (hit !== node && !node.contains(hit))) continue;
        const pattern = node.closest('[data-pattern]');
        const name = (node.getAttribute('aria-label') || node.textContent || node.getAttribute('title') || '').trim().replace(/\s+/g, ' ');
        found.push({
          tag: node.tagName.toLowerCase(), name: name.slice(0, 24), pattern: pattern ? pattern.dataset.pattern : '',
          box: [r.left, r.top, r.right, r.bottom].map(Math.round), reach: Math.round(reach),
        });
      }
    }
    return found;
  }
  Object.defineProperty(window, '__egluStrip', { value: Object.freeze({ set, state, leftovers }), configurable: false });
})();
