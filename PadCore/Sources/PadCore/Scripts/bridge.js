// The app's side of every page, but a hands-off one (HandsOff.swift).
//
// It runs at document start in the app's own content world, in the main
// frame only. The page can't see its variables or call it; what the page
// sees is only what a Mac's WebKit would show it: wheel events with the
// pointer's position and the keys held, Tab and the arrows when the system
// would otherwise keep them, and a stylesheet.
//
// The app calls in through window.__eglu (Page.swift): wheel() for every
// step of a trackpad scroll or pinch, key() for a relayed key, pointer() and
// type() for the iPhone's desktop view, which moves a cursor of its own,
// callouts() when a site's own menus are turned on or off,
// unsaved() before a tab is frozen, state() for Diagnostics. It hears back through the
// "eglu" message handler: where the focus is, whether there is a
// password field, whether WebKit's own wheel events are arriving, the
// cursor the page asks for under the pointer, and the icons it names.
(() => {
  'use strict';
  if (window.__eglu) return;

  const config = window.__egluConfig || {};
  delete window.__egluConfig;

  // A second guard behind the app's own: it never puts this script on a
  // hands-off host, and if it ever did, the script would do nothing there.
  const handsOff = config.handsOff || ['accounts.google.com'];
  const host = location.hostname.toLowerCase().replace(/\.+$/, '');
  if (handsOff.some((h) => host === h || host.endsWith('.' + h))) return;

  const post = (message) => {
    try { window.webkit.messageHandlers.eglu.postMessage(message); } catch (_) {}
  };

  // MARK: Style

  function addStyle(css) {
    if (!css) return null;
    const style = document.createElement('style');
    style.textContent = css;
    const place = () => (document.head || document.documentElement).prepend(style);
    if (document.documentElement) {
      place();
    } else {
      new MutationObserver((_, observer) => {
        if (!document.documentElement) return;
        observer.disconnect();
        place();
      }).observe(document, { childList: true });
    }
    return style;
  }
  addStyle(config.css);

  // The rule for a site that keeps its own context menus (OwnMenus), in a
  // style of its own, so it can come and go while the page is up: the
  // setting is changed from the page's menu, and a web app shouldn't have
  // to load again for it. The app hands the rule over, or nothing.
  let ownMenus = addStyle(config.callouts);
  function callouts(css) {
    if (ownMenus) ownMenus.textContent = css || '';
    else ownMenus = addStyle(css);
  }

  // MARK: Where the pointer is

  // A point in the web view, in points from its top left, as the place on
  // the page under it. The visual viewport says how many CSS pixels a point
  // is (WebKit may have scaled a wide desktop page down to fit) and where
  // the visible part sits; clientX and clientY are measured from the layout
  // viewport, as on a Mac.
  function clientPoint(x, y, viewWidth) {
    const vv = window.visualViewport;
    const width = vv ? vv.width : window.innerWidth;
    const scale = viewWidth > 0 ? width / viewWidth : 1;
    return {
      x: (vv ? vv.offsetLeft : 0) + x * scale,
      y: (vv ? vv.offsetTop : 0) + y * scale,
    };
  }

  // The element under a point, through open shadow roots and into frames of
  // the same origin, with the point in that element's own document. A frame
  // from another origin can't be reached from here, so the event goes to the
  // frame's element; a hands-off frame, such as Google's sign-in button, is
  // always another origin.
  function hitTest(cx, cy) {
    let doc = document;
    let view = window;
    let x = cx;
    let y = cy;
    let element = doc.elementFromPoint(x, y);
    for (let depth = 0; element && depth < 8; depth++) {
      while (element.shadowRoot) {
        const inner = element.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === element) break;
        element = inner;
      }
      if (element.tagName !== 'IFRAME' && element.tagName !== 'FRAME') break;
      let inner = null;
      try { inner = element.contentDocument; } catch (_) {}
      if (!inner) break;
      const box = element.getBoundingClientRect();
      x -= box.left + element.clientLeft;
      y -= box.top + element.clientTop;
      doc = inner;
      view = element.contentWindow;
      element = doc.elementFromPoint(x, y);
    }
    return { element: element || doc.documentElement, x, y, view };
  }

  // MARK: Wheel

  // When WebKit's own wheel events last arrived: a plain one (two-finger
  // scroll) and one with ctrlKey (a pinch, should WebKit ever send them).
  // While they arrive, the bridge's own would be the same scroll twice, so
  // it stands aside (see WheelMode.auto).
  const recent = { plain: -1e9, ctrl: -1e9 };
  const counts = { trusted: 0, bridged: 0 };
  let reported = -1e9;
  window.addEventListener('wheel', (event) => {
    if (!event.isTrusted) return;
    const now = performance.now();
    recent[event.ctrlKey ? 'ctrl' : 'plain'] = now;
    counts.trusted += 1;
    if (now - reported > 250) {
      reported = now;
      post({ kind: 'wheel', trusted: counts.trusted });
    }
  }, { capture: true, passive: true });

  const quiet = 150;

  // m: { x, y, width, dx, dy, ctrl, alt, shift, meta, guard, force, reach }
  // guard 'scroll' stands aside for WebKit's plain wheel events, 'pinch' for
  // its ctrl ones. Returns 'native' when it stood aside, 'handled' when the
  // page took the event, 'scrolled' when it didn't and the bridge scrolled
  // what a browser would, 'ignored' when there was nothing to scroll. With
  // `reach`, a scroll up or down that has nothing under the pointer to move
  // goes to what can take it further along the pointer's column (reach). An
  // event with a sideways part that nothing used comes back 'free', whatever
  // its vertical part did: the page left it and nothing scrolls that way,
  // which is when a Mac's browsers take a swipe sideways for back and
  // forward, and the app does too (TrackpadSwipe).
  function wheel(m) {
    const now = performance.now();
    if (!m.force && now - recent[m.guard === 'pinch' ? 'ctrl' : 'plain'] < quiet) return 'native';
    const point = clientPoint(m.x, m.y, m.width);
    const hit = hitTest(point.x, point.y);
    const Wheel = hit.view.WheelEvent || WheelEvent;
    const event = new Wheel('wheel', {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: hit.view,
      detail: 0,
      clientX: hit.x,
      clientY: hit.y,
      screenX: point.x + (window.screenX || 0),
      screenY: point.y + (window.screenY || 0),
      deltaX: m.dx || 0,
      deltaY: m.dy || 0,
      deltaZ: 0,
      deltaMode: 0,
      ctrlKey: !!m.ctrl,
      altKey: !!m.alt,
      shiftKey: !!m.shift,
      metaKey: !!m.meta,
    });
    counts.bridged += 1;
    if (!hit.element.dispatchEvent(event)) return 'handled';
    // A wheel with ctrlKey zooms in a desktop browser; the page didn't take
    // it, and the page's zoom stays where it is (ZoomLock).
    if (m.ctrl) return 'ignored';
    const moved = scrollFrom(hit.element, m.dx || 0, m.dy || 0);
    const reached = !!m.reach && !!m.dy && !moved.y && !moved.overY && reach(point, m.dy, hit.element.ownerDocument);
    if (m.dx && !moved.x && !moved.keptX) return 'free';
    return moved.x || moved.y || reached ? 'scrolled' : 'ignored';
  }

  // MARK: Scrolling, as a browser does when the page doesn't take the wheel

  // What an element is inside, as the page is laid out. What a page puts in
  // a component's slot is inside whatever the component keeps round the
  // slot, a scroller as often as not, and not inside the component alone.
  function parentOf(node) {
    if (node.assignedSlot) return node.assignedSlot;
    if (node.parentElement) return node.parentElement;
    const root = node.getRootNode && node.getRootNode();
    return root && root.host ? root.host : null;
  }

  // Whether the body is a box of its own to scroll. The window takes the
  // body's overflow for its own only while the root's is left as it is.
  // With any set on the root (`html, body { overflow-x: hidden }`, as many a
  // page has), a body with a height of its own scrolls inside itself, and
  // the document has nothing left to scroll.
  function bodyScrolls(doc) {
    if (!doc.body || doc.body === doc.scrollingElement) return false;
    const root = doc.defaultView.getComputedStyle(doc.documentElement);
    return root.overflowX !== 'visible' || root.overflowY !== 'visible';
  }

  // Where the way up from an element ends: at the document, which is
  // scrolled as the window is, and at a body that is no box of its own.
  function isOutermost(element, doc) {
    if (element === doc.documentElement || element === doc.scrollingElement) return true;
    return element === doc.body && !bodyScrolls(doc);
  }

  // Whether the element is one that scrolls up and down at all, with room to go or at its end.
  function scrollsY(element, style) {
    return /^(auto|scroll|overlay)$/.test(style.overflowY) && element.scrollHeight > element.clientHeight + 1;
  }

  // `style` is the element's computed style, read once by the caller for
  // both axes: this runs for every ancestor of what is under the pointer,
  // on every wheel event.
  function canScroll(element, axis, delta, style) {
    if (!delta) return false;
    const overflow = axis === 'y' ? style.overflowY : style.overflowX;
    if (!/^(auto|scroll|overlay)$/.test(overflow)) return false;
    if (axis === 'y') {
      if (element.scrollHeight <= element.clientHeight + 1) return false;
      return delta > 0 ? element.scrollTop + element.clientHeight < element.scrollHeight - 1 : element.scrollTop > 0;
    }
    if (element.scrollWidth <= element.clientWidth + 1) return false;
    return delta > 0 ? element.scrollLeft + element.clientWidth < element.scrollWidth - 1 : element.scrollLeft > 0;
  }

  // Whether the element is a scroller that keeps a scroll from carrying on
  // to the ones around it (overscroll-behavior: contain or none).
  function contains(axis, style) {
    const overflow = axis === 'y' ? style.overflowY : style.overflowX;
    if (!/^(auto|scroll|overlay)$/.test(overflow)) return false;
    const behaviour = axis === 'y' ? style.overscrollBehaviorY : style.overscrollBehaviorX;
    return behaviour === 'contain' || behaviour === 'none';
  }

  // At once, whatever scroll-behavior the page set: each wheel step is a
  // small move of its own, and smooth scrolling every one of them lags.
  function move(target, left, top) {
    try {
      target.scrollBy({ left, top, behavior: 'instant' });
    } catch (_) {
      target.scrollBy(left, top);
    }
  }

  // Whether a scroller snaps to its parts along an axis, and must: sections
  // the height of the window, a row of cards, a feed of short films.
  function snaps(style, axis) {
    const type = style.scrollSnapType || '';
    if (!type.includes('mandatory')) return false;
    return (axis === 'y' ? /(^|\s)(y|block|both)(\s|$)/ : /(^|\s)(x|inline|both)(\s|$)/).test(type);
  }

  // What has been scrolled toward the next part of each scroller that snaps.
  const strokes = new WeakMap();

  // A scroller that snaps goes a part at a time. Moved by the small steps a
  // wheel comes in, WebKit takes each step on to the next part: ten steps
  // of a stroke went through five parts, and one stroke was the end of the
  // page. So the steps of a stroke are added up, the scroller is sent on
  // once they come to something, and the rest of that stroke is let go by,
  // its glide too: a stroke is a turn, as a key's press is. It is sent on
  // by most of its own size: one part where the parts fill it (a page of
  // sections), a few where they are small (a row of cards). One turn a
  // stroke whichever way: a second scroll begun on the same scroller ends
  // the first where it has got to, so a scroller that snaps both ways goes
  // the way the stroke first went and not a little of each.
  function turn(target, axis, delta, size) {
    const now = performance.now();
    let stroke = strokes.get(target);
    if (!stroke) {
      stroke = { x: { sum: 0, last: -1e9 }, y: { sum: 0, last: -1e9 }, last: -1e9, spent: false };
      strokes.set(target, stroke);
    }
    const along = stroke[axis];
    const idle = now - stroke.last;
    const own = now - along.last;
    stroke.last = now;
    along.last = now;
    // The same stroke going on after its turn.
    if (stroke.spent && idle < 200) return;
    stroke.spent = false;
    if (own > 250 || (along.sum > 0) !== (delta > 0)) along.sum = 0;
    along.sum += delta;
    if (Math.abs(along.sum) < 40) return;
    // Far enough to be nearer the next part than the one it is on, whichever way a browser picks.
    const step = Math.sign(along.sum) * Math.max(40, size * 0.6);
    stroke.x.sum = 0;
    stroke.y.sum = 0;
    stroke.spent = true;
    try {
      target.scrollBy(axis === 'y' ? { top: step, behavior: 'smooth' } : { left: step, behavior: 'smooth' });
    } catch (_) {
      target.scrollBy(axis === 'y' ? 0 : step, axis === 'y' ? step : 0);
    }
  }

  // Moves a scroller, or the window, by a wheel's step: at once where it
  // scrolls freely, and a part at a time along an axis it snaps on. `style`
  // is the scroller's own, the root's for the window.
  function go(target, style, left, top, width, height) {
    const turnsX = !!left && snaps(style, 'x');
    const turnsY = !!top && snaps(style, 'y');
    if (turnsX) turn(target, 'x', left, width);
    if (turnsY) turn(target, 'y', top, height);
    const freeX = turnsX ? 0 : left;
    const freeY = turnsY ? 0 : top;
    if (freeX || freeY) move(target, freeX, freeY);
  }

  function documentCanScroll(doc, axis, delta) {
    if (!delta) return false;
    const view = doc.defaultView;
    const root = doc.scrollingElement || doc.documentElement;
    const rootStyle = view.getComputedStyle(doc.documentElement);
    const bodyStyle = doc.body ? view.getComputedStyle(doc.body) : null;
    const hidden = (style) => style && (axis === 'y' ? style.overflowY : style.overflowX) === 'hidden';
    if (hidden(rootStyle) || (hidden(bodyStyle) && !/^(auto|scroll)$/.test(axis === 'y' ? rootStyle.overflowY : rootStyle.overflowX))) return false;
    if (axis === 'y') {
      const max = root.scrollHeight - view.innerHeight;
      return delta > 0 ? view.scrollY < max - 1 : view.scrollY > 0;
    }
    const max = root.scrollWidth - view.innerWidth;
    return delta > 0 ? view.scrollX < max - 1 : view.scrollX > 0;
  }

  // Scrolls the nearest element under the pointer that can still go that
  // way, each axis on its own, then the document: scroll chaining, as in
  // every desktop browser. Says which of the two axes moved anything,
  // whether a scroller that moved nothing sideways kept the scroll all the
  // same (overscroll-behavior, which is also how a page says a swipe
  // sideways is not for going back), and whether the pointer is over
  // anything that scrolls up and down at all (`overY`), at its end or not.
  function scrollFrom(start, dx, dy) {
    let leftX = dx;
    let leftY = dy;
    const moved = { x: false, y: false, keptX: false, overY: false };
    const doc = start.ownerDocument;
    for (let element = start; element && (leftX || leftY); element = parentOf(element)) {
      if (isOutermost(element, doc)) break;
      const style = element.ownerDocument.defaultView.getComputedStyle(element);
      if (scrollsY(element, style)) moved.overY = true;
      const x = canScroll(element, 'x', leftX, style) ? leftX : 0;
      const y = canScroll(element, 'y', leftY, style) ? leftY : 0;
      if (x || y) {
        go(element, style, x, y, element.clientWidth, element.clientHeight);
        if (x) moved.x = true;
        if (y) moved.y = true;
      }
      if (leftX && !x && contains('x', style)) moved.keptX = true;
      if (x || (leftX && contains('x', style))) leftX = 0;
      if (y || (leftY && contains('y', style))) leftY = 0;
    }
    const x = documentCanScroll(doc, 'x', leftX) ? leftX : 0;
    const y = documentCanScroll(doc, 'y', leftY) ? leftY : 0;
    // A document with somewhere to go, either way, is something that scrolls.
    if (documentCanScroll(doc, 'y', 1) || documentCanScroll(doc, 'y', -1)) moved.overY = true;
    if (leftX && !x && /^(contain|none)$/.test(doc.defaultView.getComputedStyle(doc.documentElement).overscrollBehaviorX)) {
      moved.keptX = true;
    }
    if (x || y) {
      const view = doc.defaultView;
      go(view, view.getComputedStyle(doc.documentElement), x, y, view.innerWidth, view.innerHeight);
      if (x) moved.x = true;
      if (y) moved.y = true;
    }
    return moved;
  }

  // In the desktop view on a phone the pointer is wherever the finger's last
  // move left it, and pushed against the view's top or bottom it is on
  // whatever bar the page keeps there: a chat's field, an app's header.
  // Nothing under it scrolls, and on a computer nothing would. Here the
  // push was to bring up what is further along, and there is no moving the
  // pointer on to it, so the scroll goes to what can take it in the
  // pointer's own column, the nearest first. Only up and down, and only
  // asked for where the pointer is over nothing that scrolls that way at
  // all (wheel): a list at its end has the scroll, and keeps it. `own` is
  // the document the pointer is in, which had the scroll before this.
  function reach(point, dy, own) {
    const vv = window.visualViewport;
    const top = vv ? vv.offsetTop : 0;
    const height = vv ? vv.height : window.innerHeight;
    const rows = [];
    for (let row = 0; row < 12; row += 1) rows.push(top + height * (row + 0.5) / 12);
    rows.sort((one, other) => Math.abs(one - point.y) - Math.abs(other - point.y));
    // Most rows are over the same few things: each is asked once.
    const seen = new Set([own]);
    for (const y of rows) {
      const hit = hitTest(point.x, y);
      const doc = hit.element.ownerDocument;
      for (let element = hit.element; element && !seen.has(element); element = parentOf(element)) {
        seen.add(element);
        if (isOutermost(element, doc)) break;
        const style = doc.defaultView.getComputedStyle(element);
        if (canScroll(element, 'y', dy, style)) {
          go(element, style, 0, dy, element.clientWidth, element.clientHeight);
          return true;
        }
      }
      // Then the document what was found is in, where that is another
      // than the pointer's: a frame's, in a page that keeps its matter in
      // a frame under a bar of its own, or the page's, round a frame the
      // pointer is in.
      if (seen.has(doc)) continue;
      seen.add(doc);
      if (documentCanScroll(doc, 'y', dy)) {
        const view = doc.defaultView;
        go(view, view.getComputedStyle(doc.documentElement), 0, dy, view.innerWidth, view.innerHeight);
        return true;
      }
    }
    return false;
  }

  // MARK: Keys

  function deepActive() {
    let element = document.activeElement;
    for (let depth = 0; element && depth < 8; depth++) {
      if (element.shadowRoot && element.shadowRoot.activeElement) {
        element = element.shadowRoot.activeElement;
        continue;
      }
      if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
        let inner = null;
        try { inner = element.contentDocument; } catch (_) {}
        if (inner && inner.activeElement) {
          element = inner.activeElement;
          continue;
        }
      }
      break;
    }
    return element;
  }

  const textTypes = /^(|text|search|url|tel|email|password|number|date|datetime-local|month|time|week)$/;

  function editable(element) {
    if (!element) return false;
    if (element.isContentEditable) return true;
    if (element.tagName === 'TEXTAREA') return !element.readOnly && !element.disabled;
    if (element.tagName === 'INPUT') {
      return textTypes.test((element.getAttribute('type') || '').toLowerCase()) && !element.readOnly && !element.disabled;
    }
    return false;
  }

  // A field someone can see. Pages that handle their own keys often keep the
  // focus in a field of a pixel or two, or a transparent one, to catch typing
  // and the clipboard; the arrows are the page's there, not the cursor's.
  function shown(element) {
    const box = element.getBoundingClientRect();
    const style = element.ownerDocument.defaultView.getComputedStyle(element);
    return box.width >= 4 && box.height >= 4 && style.visibility !== 'hidden' && Number(style.opacity) > 0.05;
  }

  const tabbable = 'a[href], area[href], button, input, select, textarea, iframe, summary, [tabindex], [contenteditable]';

  function focusables(doc) {
    const view = doc.defaultView;
    const all = Array.from(doc.querySelectorAll(tabbable)).filter((element) => {
      if (element.tabIndex < 0 || element.matches(':disabled')) return false;
      if (element.hasAttribute('contenteditable') && !element.isContentEditable && element.tabIndex === 0
          && !/^(a|area|button|input|select|textarea|iframe|summary)$/i.test(element.tagName)) return false;
      if (element.tagName === 'INPUT' && (element.getAttribute('type') || '').toLowerCase() === 'hidden') return false;
      if (element.closest('[inert]')) return false;
      const style = view.getComputedStyle(element);
      if (style.visibility === 'hidden' || style.display === 'none') return false;
      return element.getClientRects().length > 0;
    });
    const ordered = all.filter((e) => e.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
    return ordered.concat(all.filter((e) => e.tabIndex === 0));
  }

  // What Tab does when the page lets it: the next field in tab order, round
  // to the first after the last, its text selected as a browser selects it.
  function moveFocus(from, backwards) {
    const doc = (from && from.ownerDocument) || document;
    const list = focusables(doc);
    if (!list.length) return false;
    let at = list.indexOf(from);
    if (at < 0 && from) {
      // Not in the list: in a shadow root, or something focused by script.
      // Its place is where it sits in the document, its host's for a shadow
      // root, so the next is the first field after that, not the page's first.
      let mark = from;
      while (mark && mark.getRootNode() !== doc) mark = mark.getRootNode().host || null;
      if (mark) {
        const after = list.findIndex((e) => e !== mark && (mark.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING));
        at = backwards
          ? (after < 0 ? list.length : after)
          : (after < 0 ? list.length - 1 : after - 1);
      }
    }
    const next = at < 0
      ? list[backwards ? list.length - 1 : 0]
      : list[(at + (backwards ? -1 : 1) + list.length) % list.length];
    next.focus();
    if (next.tagName === 'INPUT' && textTypes.test((next.getAttribute('type') || '').toLowerCase())) {
      try { next.select(); } catch (_) {}
    }
    return true;
  }

  const legacyCodes = { Tab: 9, Enter: 13, Escape: 27, Backspace: 8, Delete: 46,
    ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 };

  // A typed character's code and keyCode, as a US keyboard's: KeyA and 65 for
  // "a", Digit1 and 49 for "1"; 0 and the character for anything else.
  function charCodes(key) {
    if (/^[a-z]$/i.test(key)) return { code: 'Key' + key.toUpperCase(), legacy: key.toUpperCase().charCodeAt(0) };
    if (/^[0-9]$/.test(key)) return { code: 'Digit' + key, legacy: key.charCodeAt(0) };
    if (key === ' ') return { code: 'Space', legacy: 32 };
    return { code: key, legacy: 0 };
  }

  function keyEvent(view, type, m) {
    const Keyboard = view.KeyboardEvent || KeyboardEvent;
    const event = new Keyboard(type, {
      key: m.key,
      code: m.code || m.key,
      bubbles: true,
      cancelable: true,
      composed: true,
      view,
      shiftKey: !!m.shift,
      altKey: !!m.alt,
      ctrlKey: !!m.ctrl,
      metaKey: !!m.meta,
    });
    // keyCode and which can't be given to the constructor; older code
    // still reads them.
    const code = legacyCodes[m.key] || (Array.from(m.key).length === 1 ? charCodes(m.key).legacy : 0);
    for (const name of ['keyCode', 'which']) {
      try { Object.defineProperty(event, name, { get: () => code }); } catch (_) {}
    }
    return event;
  }

  // m: { key: 'Tab' | 'ArrowUp' | 'Enter' | 'a' | ..., code, shift, alt, ctrl, meta }
  // The key goes to the focused element as keydown and keyup. When the page
  // doesn't take it, it does what a browser would: Tab moves the focus, an
  // arrow outside a text field scrolls, and in a field Return, Backspace and
  // a character edit it. Returns 'handled' or 'default'.
  function key(m) {
    const target = deepActive() || document.body || document.documentElement;
    const view = target.ownerDocument.defaultView;
    const doc = target.ownerDocument;
    const proceed = target.dispatchEvent(keyEvent(view, 'keydown', m));
    // One character, whatever its length in JavaScript's units: an emoji is two.
    const printable = Array.from(m.key).length === 1;
    if (proceed && (printable || m.key === 'Enter')) {
      target.dispatchEvent(keyEvent(view, 'keypress', m));
    }
    if (proceed) {
      if (m.key === 'Tab') {
        moveFocus(target, !!m.shift);
      } else if (editable(target) && printable && !m.ctrl && !m.meta) {
        doc.execCommand('insertText', false, m.key);
      } else if (editable(target) && (m.key === 'Backspace' || m.key === 'Delete')) {
        doc.execCommand(m.key === 'Backspace' ? 'delete' : 'forwardDelete', false);
      } else if (editable(target) && m.key === 'Enter') {
        // A field sends its form, as Return does; a text area and
        // anything content-editable take a new line.
        if (target.tagName === 'INPUT') {
          if (target.form && target.form.requestSubmit) target.form.requestSubmit();
        } else {
          doc.execCommand(target.tagName === 'TEXTAREA' ? 'insertLineBreak' : 'insertParagraph', false);
        }
      } else if (!editable(target) && m.key.startsWith('Arrow')) {
        const step = m.alt ? view.innerHeight * 0.875 : 40;
        const dx = m.key === 'ArrowLeft' ? -step : m.key === 'ArrowRight' ? step : 0;
        const dy = m.key === 'ArrowUp' ? -step : m.key === 'ArrowDown' ? step : 0;
        scrollFrom(target, dx, dy);
      }
    }
    target.dispatchEvent(keyEvent(view, 'keyup', m));
    reportFocus();
    return proceed ? 'default' : 'handled';
  }

  // MARK: The iPhone's desktop view

  // The phone has no pointer. In its desktop view the app moves a cursor of
  // its own over the page, as a trackpad would, and its moves, presses and
  // clicks come here to reach the page as a Mac's mouse does: pointer
  // events, then mouse events, then click. Script events, which a page can
  // tell from a real mouse's (isTrusted), and a few pages ignore.
  let over = null;
  let pressed = null;
  let mouseless = false;

  function lineage(node) {
    const list = [];
    for (let at = node; at; at = parentOf(at)) {
      if (at.nodeType === 1) list.push(at);
    }
    return list;
  }

  function mouseEvent(view, kind, type, hit, point, m, related) {
    const init = {
      bubbles: !/enter|leave/.test(type),
      cancelable: !/enter|leave/.test(type),
      composed: true,
      view,
      detail: m.detail || 0,
      clientX: hit.x,
      clientY: hit.y,
      screenX: point.x + (window.screenX || 0),
      screenY: point.y + (window.screenY || 0),
      button: m.button || 0,
      buttons: m.buttons || 0,
      relatedTarget: related || null,
      ctrlKey: !!m.ctrl, altKey: !!m.alt, shiftKey: !!m.shift, metaKey: !!m.meta,
    };
    if (kind === 'pointer') {
      const Pointer = view.PointerEvent || PointerEvent;
      return new Pointer(type, Object.assign(init, {
        pointerId: 1, pointerType: 'mouse', isPrimary: true, width: 1, height: 1,
        pressure: init.buttons ? 0.5 : 0,
      }));
    }
    const Mouse = view.MouseEvent || MouseEvent;
    return new Mouse(type, init);
  }

  // :hover, for the cursor the app moves. A page's hover styles answer
  // only the engine's own pointer, which a phone hasn't got, so each of
  // its :hover rules is copied once with :hover as an attribute, which the
  // elements under the cursor get. The copies sit in a style element of
  // the bridge's own, after the page's; media queries asking for a pointer
  // that hovers are answered yes there, as a Mac answers them. A style
  // sheet from another origin can't be read, so its hover styles stay
  // off; a shadow root's aren't copied.
  const hoverMark = 'data-eglu-hover';
  const hoverCopies = new WeakMap();
  let hovered = [];

  function hoverMedia(prelude) {
    return prelude
      .replace(/\(\s*(any-)?hover\s*:\s*hover\s*\)/gi, '(min-width: 0px)')
      .replace(/\(\s*(any-)?pointer\s*:\s*fine\s*\)/gi, '(min-width: 0px)')
      .replace(/\(\s*(any-)?hover\s*:\s*none\s*\)/gi, '(max-width: 0px)')
      .replace(/\(\s*(any-)?pointer\s*:\s*coarse\s*\)/gi, '(max-width: 0px)');
  }

  function copyHoverRules(rules, out) {
    for (const rule of Array.from(rules)) {
      if (rule.styleSheet) {
        try { copyHoverRules(rule.styleSheet.cssRules, out); } catch (_) {}
        continue;
      }
      const inner = rule.cssRules;
      const nested = [];
      if (inner && inner.length) copyHoverRules(inner, nested);
      if (rule.selectorText !== undefined) {
        if (rule.selectorText.includes(':hover')) {
          out.push(rule.selectorText.replace(/:hover\b/g, '[' + hoverMark + ']') + '{' + rule.style.cssText + '}');
        }
        if (nested.length) out.push(rule.selectorText + '{' + nested.join('') + '}');
      } else if (nested.length) {
        const text = rule.cssText;
        out.push(hoverMedia(text.slice(0, text.indexOf('{'))) + '{' + nested.join('') + '}');
      }
    }
  }

  // The copies for a document, made again for a sheet only when its
  // number of rules changed: the page added some, as script-made styles do.
  function copyHover(doc) {
    let state = hoverCopies.get(doc);
    if (!state) {
      state = { style: null, counts: new Map(), texts: new Map() };
      hoverCopies.set(doc, state);
    }
    const sheets = Array.from(doc.styleSheets).concat(Array.from(doc.adoptedStyleSheets || []));
    let changed = false;
    for (const sheet of sheets) {
      if (state.style && sheet.ownerNode === state.style) continue;
      let rules;
      try { rules = sheet.cssRules; } catch (_) { continue; }
      if (!rules || state.counts.get(sheet) === rules.length) continue;
      state.counts.set(sheet, rules.length);
      const out = [];
      try { copyHoverRules(rules, out); } catch (_) {}
      state.texts.set(sheet, out.join('\n'));
      changed = true;
    }
    for (const sheet of Array.from(state.texts.keys())) {
      if (!sheets.includes(sheet)) {
        state.texts.delete(sheet);
        state.counts.delete(sheet);
        changed = true;
      }
    }
    // Nothing new since the copy that is in the page: this runs each time
    // the cursor crosses into another element, and putting every sheet's
    // copy together again to compare was a page's worth of text each time.
    if (!changed && state.style && state.style.isConnected) return;
    const text = Array.from(state.texts.values()).filter(Boolean).join('\n');
    if (!text) return;
    if (!state.style) {
      state.style = doc.createElement('style');
      state.style.setAttribute('data-eglu', 'hover');
    }
    if (changed || state.style.textContent !== text) state.style.textContent = text;
    if (!state.style.isConnected) (doc.head || doc.documentElement).appendChild(state.style);
  }

  function markHover(lineup) {
    for (const element of hovered) {
      if (!lineup.includes(element)) element.removeAttribute(hoverMark);
    }
    const docs = new Set();
    for (const element of lineup) {
      if (!element.hasAttribute(hoverMark)) element.setAttribute(hoverMark, '');
      docs.add(element.ownerDocument);
    }
    hovered = lineup;
    for (const doc of docs) copyHover(doc);
  }

  // Over, out, enter and leave as the cursor goes from one element to the
  // next, so hover menus open and close; and the hover styles with them.
  function crossTo(element, hit, point, m) {
    if (element === over) return;
    const view = hit.view;
    const before = over && over.isConnected ? lineage(over) : [];
    const after = lineage(element);
    if (before.length) {
      const old = before[0];
      old.dispatchEvent(mouseEvent(old.ownerDocument.defaultView, 'pointer', 'pointerout', hit, point, m, element));
      old.dispatchEvent(mouseEvent(old.ownerDocument.defaultView, 'mouse', 'mouseout', hit, point, m, element));
      for (const left of before.filter((e) => !after.includes(e))) {
        left.dispatchEvent(mouseEvent(left.ownerDocument.defaultView, 'pointer', 'pointerleave', hit, point, m, element));
        left.dispatchEvent(mouseEvent(left.ownerDocument.defaultView, 'mouse', 'mouseleave', hit, point, m, element));
      }
    }
    element.dispatchEvent(mouseEvent(view, 'pointer', 'pointerover', hit, point, m, before[0]));
    element.dispatchEvent(mouseEvent(view, 'mouse', 'mouseover', hit, point, m, before[0]));
    for (const entered of after.filter((e) => !before.includes(e)).reverse()) {
      entered.dispatchEvent(mouseEvent(entered.ownerDocument.defaultView, 'pointer', 'pointerenter', hit, point, m, before[0]));
      entered.dispatchEvent(mouseEvent(entered.ownerDocument.defaultView, 'mouse', 'mouseenter', hit, point, m, before[0]));
    }
    over = element;
    markHover(after);
  }

  // What a press gives the focus to, as a browser does: the field or the
  // control under it, or nothing, and a field's caret where it was pressed.
  function focusFor(element, hit) {
    const focusable = element.closest(tabbable + ', [tabindex]');
    const active = deepActive();
    if (focusable && !focusable.disabled) {
      if (focusable !== active) focusable.focus({ preventScroll: true });
      if (focusable.isContentEditable && hit.view.document.caretRangeFromPoint) {
        const range = hit.view.document.caretRangeFromPoint(hit.x, hit.y);
        const selection = hit.view.getSelection();
        if (range && selection) {
          selection.removeAllRanges();
          selection.addRange(range);
        }
      }
    } else if (active && active !== document.body && active.blur) {
      active.blur();
    }
  }

  function commonAncestor(a, b) {
    const others = lineage(b);
    return lineage(a).find((e) => others.includes(e)) || null;
  }

  // m: { type: 'move' | 'down' | 'up' | 'click' | 'context', x, y, width,
  //      button, buttons, detail, shift, alt, ctrl, meta }
  // x and y are in the web view's points, as for wheel(). A click is a press
  // and a release in place; a second or third (detail 2, 3) adds dblclick on
  // the second. 'context' is a press of the right button. Returns 'handled'
  // when the page cancelled the press, 'default' otherwise.
  function pointer(m) {
    const point = clientPoint(m.x, m.y, m.width);
    const hit = hitTest(point.x, point.y);
    const target = hit.element;
    const view = hit.view;
    const send = (kind, type, init) => target.dispatchEvent(mouseEvent(view, kind, type, hit, point, init));
    crossTo(target, hit, point, m);
    if (m.type === 'move') {
      send('pointer', 'pointermove', m);
      if (!mouseless) send('mouse', 'mousemove', m);
      return 'default';
    }
    if (m.type === 'click') {
      const outcome = pointer(Object.assign({}, m, { type: 'down' }));
      pointer(Object.assign({}, m, { type: 'up' }));
      return outcome;
    }
    if (m.type === 'context') {
      const right = { button: 2, buttons: 2, detail: 1 };
      pointer(Object.assign({}, m, right, { type: 'down' }));
      const kept = !target.dispatchEvent(mouseEvent(view, 'mouse', 'contextmenu', hit, point, Object.assign({}, m, right)));
      pointer(Object.assign({}, m, right, { type: 'up', buttons: 0 }));
      post({ kind: 'context', kept });
      return kept ? 'handled' : 'default';
    }
    const button = m.button || 0;
    if (m.type === 'down') {
      const held = Object.assign({}, m, { button, buttons: button === 2 ? 2 : 1, detail: m.detail || 1 });
      // A cancelled pointerdown keeps the mouse events from the page, as in a browser.
      mouseless = !send('pointer', 'pointerdown', held);
      const proceed = mouseless ? false : send('mouse', 'mousedown', held);
      if (proceed && !mouseless && button === 0) focusFor(target, hit);
      pressed = { element: target, button };
      reportFocus();
      return mouseless || !proceed ? 'handled' : 'default';
    }
    if (m.type === 'up') {
      const released = Object.assign({}, m, { button, buttons: 0, detail: m.detail || 1 });
      send('pointer', 'pointerup', released);
      if (!mouseless) send('mouse', 'mouseup', released);
      mouseless = false;
      const from = pressed;
      pressed = null;
      if (from && from.button === button && button === 0 && from.element.isConnected) {
        const clicked = commonAncestor(from.element, target);
        if (clicked) {
          clicked.dispatchEvent(mouseEvent(clicked.ownerDocument.defaultView, 'mouse', 'click', hit, point, released));
          if (released.detail === 2) {
            clicked.dispatchEvent(mouseEvent(clicked.ownerDocument.defaultView, 'mouse', 'dblclick', hit, point, released));
          }
        }
      }
      reportFocus();
      return 'default';
    }
    return 'ignored';
  }

  // m: { text, back }
  // What the phone's keyboard typed in the desktop view: `back` characters
  // taken away, then `text`, as the keyboard's own field changed (a Korean
  // syllable is typed by replacing the one before it). In a field it is
  // edited as typing edits it; on the rest of the page each new character is
  // a key, for the page's own shortcuts, and a replacement is not. Returns
  // 'typed', 'keys' or 'ignored'.
  function type(m) {
    const text = m.text || '';
    const back = m.back || 0;
    const target = deepActive();
    if (!text) {
      for (let i = 0; i < back; i++) key({ key: 'Backspace', code: 'Backspace' });
      return back ? 'keys' : 'ignored';
    }
    if (target && editable(target)) {
      if (!back && Array.from(text).length === 1) {
        key({ key: text, code: charCodes(text).code });
        return 'typed';
      }
      const doc = target.ownerDocument;
      for (let i = 0; i < back; i++) doc.execCommand('delete', false);
      doc.execCommand('insertText', false, text);
      return 'typed';
    }
    if (back) return 'ignored';
    for (const character of Array.from(text)) key({ key: character, code: charCodes(character).code });
    return 'keys';
  }

  // MARK: Reports

  let editing = null;
  function reportFocus() {
    const element = deepActive();
    const now = !!element && editable(element) && shown(element);
    if (now === editing) return;
    editing = now;
    post({ kind: 'focus', editing: now });
  }
  document.addEventListener('focusin', () => setTimeout(reportFocus, 0), true);
  document.addEventListener('focusout', () => setTimeout(reportFocus, 0), true);

  // A secondary click's contextmenu event, once every listener has heard it:
  // whether the page kept the menu to itself (preventDefault), as Figma does
  // for its own. The app offers a link's menu at a secondary click only where
  // the page has none (Page.linkMenu). Only the real thing: the events the
  // desktop view's cursor makes up are answered where they are made.
  window.addEventListener('contextmenu', (event) => {
    if (!event.isTrusted) return;
    setTimeout(() => post({ kind: 'context', kept: event.defaultPrevented }), 0);
  }, true);

  // A password field makes a sign-in page wherever it is (SignIn.swift).
  let password = null;
  let pending = 0;
  function checkPassword() {
    pending = 0;
    const present = !!document.querySelector('input[type="password" i]');
    if (present === password) return;
    password = present;
    post({ kind: 'password', present });
  }
  // Off screen only while the page is still coming in, past the time before
  // its visit may go to iCloud (HistoryCloud.settle): a tab opened behind
  // may draw its sign-in form late. After that, a tab kept live may go on
  // changing for hours: it is looked at again when it shows.
  const loaded = Date.now();
  function soon() {
    if (pending || (document.hidden && Date.now() - loaded > 30000)) return;
    pending = setTimeout(checkPassword, 400);
  }
  function watch() {
    checkPassword();
    new MutationObserver(soon).observe(document.documentElement, {
      childList: true, subtree: true, attributes: true, attributeFilter: ['type'],
    });
    document.addEventListener('visibilitychange', soon);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', watch, { once: true });
  } else {
    watch();
  }

  // MARK: The cursor the page asks for

  // WebKit on iPad shows the system pointer whatever cursor a page sets,
  // but for the text beam over text. A page's own cursor image (Figma
  // draws even its arrow) is drawn by the app instead (Pointer.swift):
  // here the cursor under the pointer is read, its image drawn once to a
  // PNG, and the app told whenever it changes. 'none' hides the pointer;
  // any other keyword leaves the system's.
  const largestCursor = 128;

  // `cursor` as getComputedStyle gives it: images, each a url() or an
  // image-set() with an optional hotspot, then a keyword, comma separated:
  // url("data:…") 4 4, auto. A data URL can hold brackets and quotes, so
  // the value is read a character at a time rather than split.
  function parseCursor(value) {
    const text = String(value || '');
    const images = [];
    let i = 0;
    const space = () => { while (i < text.length && /\s/.test(text[i])) i++; };
    const starts = (word) => text.slice(i, i + word.length).toLowerCase() === word;
    const quoted = () => {
      const quote = text[i++];
      let out = '';
      while (i < text.length && text[i] !== quote) {
        if (text[i] === '\\' && i + 1 < text.length) i++;
        out += text[i++];
      }
      i++;
      return out;
    };
    const url = () => {
      space();
      let out = '';
      if (text[i] === '"' || text[i] === "'") {
        out = quoted();
      } else {
        while (i < text.length && text[i] !== ')') out += text[i++];
        out = out.trim();
      }
      space();
      if (text[i] === ')') i++;
      return out;
    };
    for (;;) {
      space();
      const candidates = [];
      if (starts('url(')) {
        i += 4;
        candidates.push({ url: url(), density: 1 });
      } else if (starts('image-set(') || starts('-webkit-image-set(')) {
        i += starts('image-set(') ? 10 : 18;
        while (i < text.length) {
          space();
          let source = null;
          if (starts('url(')) {
            i += 4;
            source = url();
          } else if (text[i] === '"' || text[i] === "'") {
            source = quoted();
          }
          // The rest of this choice: its density (2x, 2dppx, 192dpi), a type().
          let rest = '';
          let depth = 0;
          while (i < text.length && !(depth === 0 && (text[i] === ',' || text[i] === ')'))) {
            if (text[i] === '(') depth++;
            if (text[i] === ')') depth--;
            rest += text[i++];
          }
          const found = /(\d*\.?\d+)(x|dppx|dpi|dpcm)\b/i.exec(rest);
          let density = 1;
          if (found) {
            const n = Number(found[1]);
            const unit = found[2].toLowerCase();
            density = unit === 'dpi' ? n / 96 : unit === 'dpcm' ? n * 2.54 / 96 : n;
          }
          if (source && density > 0) candidates.push({ url: source, density });
          if (text[i] === ',') {
            i++;
            continue;
          }
          if (text[i] === ')') i++;
          break;
        }
      } else {
        break;
      }
      space();
      const hotspot = /^(-?\d*\.?\d+)(?:px)?\s+(-?\d*\.?\d+)(?:px)?/.exec(text.slice(i, i + 64));
      let x = 0;
      let y = 0;
      if (hotspot) {
        x = Number(hotspot[1]);
        y = Number(hotspot[2]);
        i += hotspot[0].length;
      }
      if (candidates.length) images.push({ candidates, x, y });
      space();
      if (text[i] !== ',') break;
      i++;
    }
    const keyword = text.slice(i).replace(/^[\s,]+/, '').trim().toLowerCase() || 'auto';
    return { images, keyword };
  }

  // Of an image set, the one at the screen's density or the nearest above
  // it, as a browser picks.
  function pick(candidates) {
    const want = window.devicePixelRatio || 1;
    const sorted = candidates.slice().sort((a, b) => a.density - b.density);
    return sorted.find((c) => c.density >= want) || sorted[sorted.length - 1];
  }

  // One image of a cursor, drawn to a PNG at the screen's density, so the
  // app gets a picture it can show whatever the page gave (an SVG, an image
  // set). Null when it can't be: it didn't load, it is bigger than a cursor
  // may be, or it comes from another site that doesn't let it be read.
  function drawCursor(image) {
    const choice = pick(image.candidates);
    return new Promise((resolve) => {
      const picture = new Image();
      if (/^https?:/i.test(choice.url)) picture.crossOrigin = 'anonymous';
      picture.onload = () => {
        const width = (picture.naturalWidth || 32) / choice.density;
        const height = (picture.naturalHeight || 32) / choice.density;
        if (!(width > 0 && height > 0) || width > largestCursor || height > largestCursor) {
          resolve(null);
          return;
        }
        const scale = Math.min(Math.max(window.devicePixelRatio || 1, 1), 3);
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(width * scale));
        canvas.height = Math.max(1, Math.round(height * scale));
        try {
          canvas.getContext('2d').drawImage(picture, 0, 0, canvas.width, canvas.height);
          resolve({
            image: canvas.toDataURL('image/png'),
            width,
            height,
            scale,
            x: Math.min(Math.max(image.x, 0), width),
            y: Math.min(Math.max(image.y, 0), height),
          });
        } catch (_) {
          resolve(null);
        }
      };
      picture.onerror = () => resolve(null);
      picture.src = choice.url;
    });
  }

  // What the app hears for a cursor value: the first of its images that
  // can be drawn, with an id of its own, or else its keyword.
  // Ids start from a number of this document's own, so a document's id is
  // never another's: one from the back-forward cache comes back with ids
  // the app may still have pictures for, and must not get another page's.
  let nextCursor = Math.floor(Math.random() * 2 ** 30) * 2 ** 20 + 1;
  async function resolveCursor(value) {
    const parsed = parseCursor(value);
    for (const image of parsed.images) {
      const drawn = await drawCursor(image);
      if (drawn) return Object.assign({ id: nextCursor++ }, drawn);
    }
    return { keyword: parsed.keyword };
  }

  // Each value is looked at once; its picture goes to the app once, and
  // after that its id stands for it. Both are forgotten together past 64
  // values (the set of pictures sent would otherwise only grow), so an id
  // sent alone is always one of the last 65 pictures sent, which the app
  // always keeps (Pointer.show).
  const cursorReports = new Map();
  const sentPictures = new Set();
  let cursorValue = null;
  function showCursor(value) {
    if (value === cursorValue) return;
    cursorValue = value;
    let report = cursorReports.get(value);
    if (!report) {
      if (cursorReports.size > 64) {
        cursorReports.clear();
        sentPictures.clear();
      }
      report = resolveCursor(value);
      cursorReports.set(value, report);
    }
    Promise.resolve(report).then((done) => {
      cursorReports.set(value, done);
      if (cursorValue !== value) return;
      if (done.id && sentPictures.has(done.id)) {
        post({ kind: 'cursor', id: done.id });
        return;
      }
      if (done.id) sentPictures.add(done.id);
      post(Object.assign({ kind: 'cursor' }, done));
    });
  }

  // What is under the pointer, read once a frame at most: the innermost
  // element, through open shadow roots.
  let cursorElement = null;
  let cursorFrame = 0;
  function checkCursor() {
    cursorFrame = 0;
    const element = cursorElement;
    if (!element || !element.isConnected) return;
    let value = 'auto';
    try {
      value = element.ownerDocument.defaultView.getComputedStyle(element).cursor || 'auto';
    } catch (_) {}
    showCursor(value);
  }
  function checkSoon() {
    if (!cursorFrame) cursorFrame = requestAnimationFrame(checkCursor);
  }
  // The page's cursor is read again every so often, but only while the
  // pointer is over the page: no timer runs in a page nobody points at.
  let cursorTimer = 0;
  function watchCursor(on) {
    if (on && !cursorTimer) {
      cursorTimer = setInterval(() => { if (cursorElement) checkSoon(); }, 400);
    } else if (!on && cursorTimer) {
      clearInterval(cursorTimer);
      cursorTimer = 0;
    }
  }
  function pointerOver(event) {
    // A finger on the glass has no cursor; a trackpad or a mouse does.
    if (event.pointerType && event.pointerType !== 'mouse') return;
    // The event's own target, but for one inside a shadow root, which the
    // window hears as the root's host: only then is the whole path asked
    // for, since this runs on every move of the pointer.
    let first = event.target;
    if (first && first.shadowRoot && event.composedPath) {
      const path = event.composedPath();
      if (path.length) first = path[0];
    }
    cursorElement = first && first.nodeType === 1 ? first : event.target;
    watchCursor(true);
    checkSoon();
  }
  if (config.cursor !== false) {
    for (const type of ['pointerover', 'pointermove', 'pointerdown', 'pointerup']) {
      window.addEventListener(type, pointerOver, { capture: true, passive: true });
    }
    window.addEventListener('pointerout', (event) => {
      if (event.pointerType && event.pointerType !== 'mouse') return;
      if (event.relatedTarget) return;
      cursorElement = null;
      watchCursor(false);
      showCursor('auto');
    }, { capture: true, passive: true });
    // A page changes its cursor without the pointer moving too: a key picks
    // another tool in Figma. So it is read again after a key, and every so
    // often while the pointer is over the page (watchCursor).
    for (const type of ['keydown', 'keyup']) {
      window.addEventListener(type, () => { if (cursorElement) checkSoon(); }, { capture: true, passive: true });
    }
  }

  // MARK: The site's icon

  // The icons the page names, best first, for its pinned tab and its
  // bookmarks (SiteIcons.swift fetches the first that loads). Apple's touch
  // icons are the big ones; a plain icon can be 16 pixels; /favicon.ico is
  // the one every site had before <link> did. An SVG can't be shown by the
  // app, and a mask icon is a single colour, so neither is named.
  function siteIcons() {
    const found = [];
    for (const link of document.querySelectorAll('link[rel][href]')) {
      const rel = String(link.rel || '').toLowerCase().split(/\s+/);
      const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
      if (!touch && !rel.includes('icon')) continue;
      if (rel.includes('mask-icon')) continue;
      const href = link.href;
      if (!/^(https?:|data:image\/)/i.test(href)) continue;
      const type = String(link.type || '').toLowerCase();
      const svg = type.includes('svg') || /^data:image\/svg/i.test(href) || /\.svg([?#]|$)/i.test(href);
      const sizes = String(link.getAttribute('sizes') || '').toLowerCase().split(/\s+/);
      const size = Math.min(Math.max(0, ...sizes.map((each) => parseInt(each, 10) || 0)), 512);
      // The site's own icon first, as browsers show it: a drawing, then one
      // for any size (an .ico of several), then its largest picture, then an
      // alternate; Apple's touch icon (a square for a Home Screen) after them,
      // and a speck under 32 pixels after that.
      let score;
      if (touch) score = 1000 + size;
      else if (svg) score = 3000;
      else if (sizes.includes('any')) score = 2600;
      else if (size && size < 32) score = 500 + size;
      else score = (rel.includes('alternate') ? 1500 : 2000) + size;
      // One for a dark screen, or for another kind of screen, after the rest:
      // the icon kept is the one for a light screen.
      const media = String(link.media || '').toLowerCase();
      const scheme = /prefers-color-scheme/.test(media);
      if ((scheme && /prefers-color-scheme:\s*dark/.test(media)) || (media && !scheme && !window.matchMedia(media).matches)) {
        score -= 2900;
      }
      found.push({ href, score });
    }
    found.sort((a, b) => b.score - a.score);
    const urls = found.map((icon) => icon.href);
    if (/^https?:$/.test(location.protocol)) urls.push(location.origin + '/favicon.ico');
    return Array.from(new Set(urls)).slice(0, 6);
  }
  let iconsSent = '';
  function reportIcons() {
    const urls = siteIcons();
    const key = urls.join(' ');
    if (!urls.length || key === iconsSent) return;
    iconsSent = key;
    post({ kind: 'icons', urls });
  }
  // Native history metadata reads capture the visit and account scope at
  // work start. Never send an unbound description from a delayed document message.
  window.addEventListener('load', () => setTimeout(reportIcons, 300), { once: true });

  // Scripts.bridge inserts the shared read-only draft probe here, inside
  // this closure and after the hands-off guard. The Mac calls it directly.
  /*DRAFT_PROBE*/
  function unsaved() { return egluHasDraft(handsOff); }

  function state() {
    return {
      userAgent: navigator.userAgent,
      platform: navigator.platform,
      trusted: counts.trusted,
      bridged: counts.bridged,
      editing: !!editing,
      password: !!password,
      adapter: config.adapter || '',
    };
  }

  post({ kind: 'hello', userAgent: navigator.userAgent, adapter: config.adapter || '' });

  Object.defineProperty(window, '__eglu', {
    value: Object.freeze({ wheel, key, pointer, type, callouts, unsaved, state, clientPoint, hitTest, parseCursor, siteIcons }),
  });
})();
