// eGlu's measuring tool, grown from element-pick.js. Run once in the app's
// own world with callAsyncJavaScript: everything it draws is one canvas in a
// closed shadow root over the page (never part of the page's styles or
// queries), and everything it says goes through egluBridge on egluMeasure to
// the app's panel. It resolves when the tool ends, and while it runs it takes
// the click (with the presses that make it) and Esc, ⌥ held, G, R and X from
// the page, and nothing else: a key typed into a field is the field's.
// The app's guide and ruler settings come in as the `guides` argument, with
// `run`, the number its messages carry; in a test there may be none.
const cfg = typeof guides === "undefined" ? {} : Object.assign({}, guides);
const run = cfg.run || 0;

let selected = null;
let hover = null;
let alt = false;
let guidesOn = !!cfg.guidesOn;
let rulersOn = !!cfg.rulers;
let xrayOn = !!cfg.xray;
// The app's Pick Colour on a touch screen: the next tap says where it is,
// for the app to read the pixel under it, and selects nothing.
let sampling = false;
let frame = 0;
let observer = null;
const pins = new Map(); // note id -> {element, number, name}
const refs = new Map(); // ref -> element the panel can pin a note to
let refCount = 0;
// What the last frame drew, for the tests (state()), which can't look inside.
let drawn = { columns: [], ticks: { x: 0, y: 0 }, firstTick: { x: -1, y: -1 }, gaps: [], pinned: 0 };
const tell = (message) => {
  const bridge = globalThis.egluBridge;
  if (bridge) {
    try { bridge.post("egluMeasure", Object.assign({ run }, message)); } catch (_) {}
  }
};

const host = document.createElement("div");
// The host's own style, so the page's rules for a div never move or hide it.
host.style.cssText =
  "all:initial!important;position:fixed!important;inset:0!important;" +
  "pointer-events:none!important;z-index:2147483647!important";
const root = host.attachShadow({ mode: "closed" });
const style = document.createElement("style");
style.textContent =
  ":host{all:initial}canvas{position:fixed;inset:0;pointer-events:none}";
const canvas = document.createElement("canvas");
root.append(style, canvas);
document.documentElement.appendChild(host);

// The element under a point, never the overlay's (its pointer-events are none).
const under = (x, y) => {
  const element = document.elementFromPoint(x, y);
  return element && element !== host ? element : null;
};

// A name as a selector can hold it: React's ids (":r1:") and Tailwind's
// classes ("md:flex", "w-1/2") have characters a selector must escape.
const escaped = (name) => (typeof CSS !== "undefined" && CSS.escape ? CSS.escape(name) : name);

// The element a note's name finds, or null: a name from an earlier run, or
// one whose element the page has since drawn again.
const found = (name) => {
  try {
    return name ? document.querySelector(name) : null;
  } catch (_) {
    return null;
  }
};

// The name a note's element is known by: its #id, or up to four levels of
// tag.class:nth-of-type(n) from the nearest ancestor with an id, or from body.
const nameOf = (element) => {
  if (!element) return "";
  if (element.id) return "#" + escaped(element.id);
  const parts = [];
  let node = element;
  while (node && node !== document.documentElement && parts.length < 4) {
    if (node.id) { parts.unshift("#" + escaped(node.id)); break; }
    if (node === document.body) { parts.unshift("body"); break; }
    let part = node.tagName.toLowerCase();
    const first = typeof node.className === "string" ? node.className.trim().split(/\s+/)[0] : "";
    if (first) part += "." + escaped(first);
    const parent = node.parentElement;
    if (parent) {
      const siblings = Array.from(parent.children).filter((each) => each.tagName === node.tagName);
      if (siblings.length > 1) part += ":nth-of-type(" + (siblings.indexOf(node) + 1) + ")";
    }
    parts.unshift(part);
    node = parent;
  }
  return parts.join(" ");
};

const edges = (box) => {
  const style = getComputedStyle(box);
  const px = (name) => parseFloat(style[name]) || 0;
  const border = box.getBoundingClientRect();
  const margin = {
    top: px("marginTop"), right: px("marginRight"), bottom: px("marginBottom"), left: px("marginLeft"),
  };
  const padding = {
    top: px("paddingTop"), right: px("paddingRight"), bottom: px("paddingBottom"), left: px("paddingLeft"),
  };
  const line = {
    top: px("borderTopWidth"), right: px("borderRightWidth"), bottom: px("borderBottomWidth"), left: px("borderLeftWidth"),
  };
  return { style, border, margin, padding, line };
};

// What the panel shows of the selected element (1.2): its boxes, layout,
// type and colours, its name, and its first words for the note an assistant gets.
const detailsOf = (element) => {
  const { style, border, margin, padding, line } = edges(element);
  const family = (style.fontFamily || "").split(",")[0].replace(/^["']|["']$/g, "").trim();
  return {
    kind: "details",
    tag: element.tagName.toLowerCase(),
    id: element.id || "",
    classes: String(element.className && element.className.baseVal === undefined ? element.className : "")
      .trim().split(/\s+/).filter(Boolean).slice(0, 3),
    width: border.width, height: border.height,
    x: border.x, y: border.y,
    margin, padding, border: line,
    display: style.display,
    gap: { row: style.rowGap, column: style.columnGap },
    font: {
      family, size: style.fontSize, weight: style.fontWeight,
      lineHeight: style.lineHeight, letterSpacing: style.letterSpacing,
    },
    color: style.color,
    background: style.backgroundColor,
    radius: style.borderRadius,
    name: nameOf(element),
    text: (element.innerText || "").trim().replace(/\s+/g, " ").slice(0, 40),
    ref: (refCount += 1),
  };
};

// The distances between two boxes: between their facing sides, or the four
// insets when one holds the other.
const distanceBetween = (a, b) => {
  const one = a.getBoundingClientRect();
  const two = b.getBoundingClientRect();
  const inner = (p, q) =>
    p.left >= q.left && p.right <= q.right && p.top >= q.top && p.bottom <= q.bottom;
  if (inner(one, two) || inner(two, one)) {
    const inside = inner(one, two) ? one : two;
    const outside = inner(one, two) ? two : one;
    return {
      inside: true,
      insets: {
        top: inside.top - outside.top, right: outside.right - inside.right,
        bottom: outside.bottom - inside.bottom, left: inside.left - outside.left,
      },
    };
  }
  const dx = two.left >= one.right ? two.left - one.right : (one.left >= two.right ? one.left - two.right : 0);
  const dy = two.top >= one.bottom ? two.top - one.bottom : (one.top >= two.bottom ? one.top - two.bottom : 0);
  return { inside: false, dx, dy };
};

// A container's gaps between its children, to fill in purple: for each pair
// of children beside each other with none between them, the strip between
// their margin boxes, which is the gap the container's `gap` makes.
const gapBoxes = (element) => {
  const { style } = edges(element);
  if (!/flex|grid/.test(style.display)) return [];
  const boxes = Array.from(element.children).map((each) => {
    const { border, margin } = edges(each);
    return {
      left: border.left - margin.left, right: border.right + margin.right,
      top: border.top - margin.top, bottom: border.bottom + margin.bottom,
    };
  }).filter((b) => b.right > b.left && b.bottom > b.top);
  const row = parseFloat(style.rowGap) || 0;
  const column = parseFloat(style.columnGap) || 0;
  const widest = Math.max(row, column, 4) * 3 + 8;
  const found = [];
  for (let i = 0; i < boxes.length; i += 1) {
    for (let j = 0; j < boxes.length; j += 1) {
      if (i === j) continue;
      const a = boxes[i];
      const b = boxes[j];
      const others = boxes.filter((c, k) => k !== i && k !== j);
      // Beside each other in a row: the horizontal strip between them where they overlap.
      if (b.left >= a.right && b.left - a.right > 0 && b.left - a.right <= widest) {
        const top = Math.max(a.top, b.top);
        const bottom = Math.min(a.bottom, b.bottom);
        const between = others.some((c) => c.left < b.left && c.right > a.right && c.bottom > top && c.top < bottom);
        if (bottom > top && !between) found.push({ x: a.right, y: top, w: b.left - a.right, h: bottom - top });
      }
      // One above the other: the vertical strip.
      if (b.top >= a.bottom && b.top - a.bottom > 0 && b.top - a.bottom <= widest) {
        const left = Math.max(a.left, b.left);
        const right = Math.min(a.right, b.right);
        const between = others.some((c) => c.top < b.top && c.bottom > a.bottom && c.right > left && c.left < right);
        if (right > left && !between) found.push({ x: left, y: a.bottom, w: right - left, h: b.top - a.bottom });
      }
    }
  }
  return found;
};

let distant = null; // the element the distance lines reach, while shown

const postDistance = (other) => {
  if (!selected || !other || other === selected) {
    if (distant) tell({ kind: "distance", gone: true });
    distant = null;
    return;
  }
  // Said once for each element reached, not once a move.
  if (distant && distant.element === other) return;
  const said = distanceBetween(selected, other);
  distant = { element: other, said };
  tell(Object.assign({ kind: "distance", target: nameOf(other) }, said));
};

const schedule = () => {
  if (frame) return;
  frame = requestAnimationFrame(() => {
    frame = 0;
    draw();
  });
};

const box = (context, rect, fill, line) => {
  if (fill) {
    context.fillStyle = fill;
    context.fillRect(rect.left, rect.top, rect.width, rect.height);
  }
  if (line) {
    context.strokeStyle = line;
    context.lineWidth = 2;
    context.strokeRect(rect.left, rect.top, rect.width, rect.height);
  }
};

// A number in its own colour, kept inside the window.
const label = (context, text, x, y, fill = "#0a84ff") => {
  context.font = "11px -apple-system, sans-serif";
  const width = context.measureText(text).width;
  const left = Math.min(window.innerWidth - width - 6, Math.max(6, x));
  const base = Math.min(window.innerHeight - 4, Math.max(16, y));
  context.fillStyle = fill;
  context.fillRect(left - 4, base - 14, width + 8, 16);
  context.fillStyle = "#fff";
  context.fillText(text, left, base - 3);
};

const draw = () => {
  const ratio = window.devicePixelRatio || 1;
  const w = window.innerWidth;
  const h = window.innerHeight;
  if (canvas.width !== Math.round(w * ratio) || canvas.height !== Math.round(h * ratio)) {
    canvas.width = Math.round(w * ratio);
    canvas.height = Math.round(h * ratio);
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
  }
  const context = canvas.getContext("2d");
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  context.clearRect(0, 0, w, h);
  drawn = { columns: [], ticks: { x: 0, y: 0 }, firstTick: { x: -1, y: -1 }, gaps: [], pinned: 0 };

  // The column and row guides, from the app's settings (G).
  if (guidesOn) {
    const count = Math.max(1, Math.round(cfg.columns || 12));
    const gutter = Math.max(0, cfg.gutter || 0);
    const margin = Math.max(0, cfg.margin || 0);
    const width = (w - margin * 2 - gutter * (count - 1)) / count;
    context.fillStyle = "rgba(255,59,48,.10)";
    for (let i = 0; i < count; i += 1) {
      const x = margin + i * (width + gutter);
      drawn.columns.push(x);
      if (width > 0) context.fillRect(x, 0, width, h);
      if (gutter > 0 && i < count - 1) {
        context.fillStyle = "rgba(255,59,48,.18)";
        context.fillRect(x + width, 0, gutter, h);
        context.fillStyle = "rgba(255,59,48,.10)";
      }
    }
    const every = Math.max(1, cfg.row || 8);
    context.strokeStyle = "rgba(255,59,48,.35)";
    context.lineWidth = 1;
    context.setLineDash([4, 3]);
    for (let y = every; y < h; y += every) {
      context.beginPath();
      context.moveTo(0, y + 0.5);
      context.lineTo(w, y + 0.5);
      context.stroke();
    }
    context.setLineDash([]);
  }

  // X-ray: the boxes of the elements on screen drawn thinly, so the
  // structure shows (X); at most 2000 of them, however long the page.
  if (xrayOn) {
    context.strokeStyle = "rgba(175,82,222,.6)";
    context.lineWidth = 1;
    let outlined = 0;
    for (const element of document.body ? document.body.querySelectorAll("*") : []) {
      if (outlined >= 2000) break;
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0 || rect.bottom < 0 || rect.right < 0 || rect.top > h || rect.left > w) continue;
      outlined += 1;
      context.strokeRect(rect.left, rect.top, rect.width, rect.height);
    }
  }

  // The selected element's margin, padding and content boxes, and its gaps.
  if (selected && selected.isConnected) {
    const { border, margin, padding, line } = edges(selected);
    box(context, {
      left: border.left - margin.left, top: border.top - margin.top,
      width: border.width + margin.left + margin.right, height: border.height + margin.top + margin.bottom,
    }, "rgba(246,178,107,.45)", null);
    box(context, {
      left: border.left + line.left, top: border.top + line.top,
      width: border.width - line.left - line.right, height: border.height - line.top - line.bottom,
    }, "rgba(147,196,125,.45)", null);
    box(context, {
      left: border.left + line.left + padding.left, top: border.top + line.top + padding.top,
      width: border.width - line.left - line.right - padding.left - padding.right,
      height: border.height - line.top - line.bottom - padding.top - padding.bottom,
    }, "rgba(111,168,220,.35)", null);
    box(context, border, null, "#0a84ff");
    context.fillStyle = "rgba(175,82,222,.5)";
    drawn.gaps = gapBoxes(selected);
    for (const gap of drawn.gaps) context.fillRect(gap.x, gap.y, gap.w, gap.h);
    label(context, Math.round(border.width) + " × " + Math.round(border.height),
          border.left, border.top - 6);
  }

  // The distance lines, to the element under the pointer with ⌥ held, or to
  // the last element tapped (distant is set by postDistance).
  if (selected && distant && distant.element && distant.element.isConnected) {
    const one = selected.getBoundingClientRect();
    const two = distant.element.getBoundingClientRect();
    const said = distant.said;
    const red = "#d70040";
    context.strokeStyle = red;
    context.lineWidth = 1;
    context.setLineDash([3, 3]);
    const line = (x1, y1, x2, y2, text) => {
      context.beginPath();
      context.moveTo(x1, y1);
      context.lineTo(x2, y2);
      context.stroke();
      label(context, text, (x1 + x2) / 2, (y1 + y2) / 2, red);
    };
    if (said.inside) {
      const top = said.insets.top, right = said.insets.right, bottom = said.insets.bottom, left = said.insets.left;
      const inner = one.left >= two.left && one.top >= two.top ? one : two;
      const outer = inner === one ? two : one;
      if (top > 0) line(inner.left + inner.width / 2, outer.top, inner.left + inner.width / 2, inner.top, Math.round(top) + "px");
      if (bottom > 0) line(inner.left + inner.width / 2, inner.bottom, inner.left + inner.width / 2, outer.bottom, Math.round(bottom) + "px");
      if (left > 0) line(outer.left, inner.top + inner.height / 2, inner.left, inner.top + inner.height / 2, Math.round(left) + "px");
      if (right > 0) line(inner.right, inner.top + inner.height / 2, outer.right, inner.top + inner.height / 2, Math.round(right) + "px");
    } else {
      // Along the band the two share, or from the selected box's middle.
      if (said.dx > 0) {
        const from = two.left >= one.right ? one.right : two.right;
        const to = two.left >= one.right ? two.left : one.left;
        const top = Math.max(one.top, two.top);
        const bottom = Math.min(one.bottom, two.bottom);
        const y = bottom > top ? (top + bottom) / 2 : one.top + one.height / 2;
        line(from, y, to, y, Math.round(said.dx) + "px");
      }
      if (said.dy > 0) {
        const from = two.top >= one.bottom ? one.bottom : two.bottom;
        const to = two.top >= one.bottom ? two.top : one.top;
        const left = Math.max(one.left, two.left);
        const right = Math.min(one.right, two.right);
        const x = right > left ? (left + right) / 2 : one.left + one.width / 2;
        line(x, from, x, to, Math.round(said.dy) + "px");
      }
    }
    context.setLineDash([]);
  }

  // The element under the pointer, outlined with its size.
  if (hover && hover.isConnected && hover !== selected) {
    const rect = hover.getBoundingClientRect();
    box(context, rect, "rgba(10,132,255,.10)", "#0a84ff");
    label(context, Math.round(rect.width) + " × " + Math.round(rect.height), rect.left, rect.top - 6);
  }

  // The notes pinned to their elements: a numbered dot at each one's top
  // left, kept inside the window and clear of the rulers.
  context.setLineDash([]);
  const edge = (rulersOn ? 18 : 0) + 9;
  for (const pin of pins.values()) {
    // An element the page drew again is found again by its name.
    if (!pin.element.isConnected) {
      const again = found(pin.name);
      if (!again) continue;
      pin.element = again;
    }
    drawn.pinned += 1;
    const rect = pin.element.getBoundingClientRect();
    const x = Math.min(w - 9, Math.max(edge, rect.left));
    const y = Math.min(h - 9, Math.max(edge, rect.top));
    context.fillStyle = "#ff9f0a";
    context.beginPath();
    context.arc(x, y, 9, 0, Math.PI * 2);
    context.fill();
    context.fillStyle = "#1d1d1f";
    context.font = "bold 10px -apple-system, sans-serif";
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(String(pin.number), x, y + 0.5);
    context.textAlign = "start";
    context.textBaseline = "alphabetic";
  }

  // The rulers, top and left: ticks every 10 CSS pixels, numbers every 100,
  // counted from the page's own left and top edge at the current scroll.
  // The first tick is the first ten past the scroll, whatever it is.
  if (rulersOn) {
    context.fillStyle = "rgba(30,30,30,.82)";
    context.fillRect(0, 0, w, 18);
    context.fillRect(0, 0, 18, h);
    context.fillStyle = "#fff";
    context.strokeStyle = "rgba(255,255,255,.7)";
    context.lineWidth = 1;
    context.font = "9px -apple-system, sans-serif";
    const left = Math.floor(window.scrollX);
    const top = Math.floor(window.scrollY);
    for (let x = (10 - ((left % 10) + 10) % 10) % 10; x < w; x += 10) {
      const at = left + x;
      const tall = ((at % 100) + 100) % 100 === 0;
      if (drawn.firstTick.x < 0) drawn.firstTick.x = x;
      drawn.ticks.x += 1;
      context.beginPath();
      context.moveTo(x + 0.5, tall ? 6 : 12);
      context.lineTo(x + 0.5, 18);
      context.stroke();
      if (tall && at >= 0) context.fillText(String(at), x + 3, 8);
    }
    for (let y = (10 - ((top % 10) + 10) % 10) % 10; y < h; y += 10) {
      const at = top + y;
      const tall = ((at % 100) + 100) % 100 === 0;
      if (drawn.firstTick.y < 0) drawn.firstTick.y = y;
      drawn.ticks.y += 1;
      context.beginPath();
      context.moveTo(tall ? 6 : 12, y + 0.5);
      context.lineTo(18, y + 0.5);
      context.stroke();
      if (tall && at >= 0) {
        context.save();
        context.translate(9, y + 3);
        context.rotate(-Math.PI / 2);
        context.fillText(String(at), 0, 0);
        context.restore();
      }
    }
  }
};

const watch = () => {
  if (observer) observer.disconnect();
  observer = null;
  if (selected && selected.parentElement) {
    observer = new MutationObserver(schedule);
    observer.observe(selected.parentElement, { childList: true, subtree: true, attributes: true });
  }
};

const move = (event) => {
  hover = under(event.clientX, event.clientY);
  if (alt && selected) postDistance(hover);
  schedule();
};

const pick = (element) => {
  selected = element;
  distant = null;
  const details = detailsOf(element);
  refs.set(details.ref, element);
  watch();
  tell(details);
  schedule();
};

// A point as the app needs it to find it in its own points (DeveloperMode).
const point = (x, y) => {
  const vv = window.visualViewport;
  return {
    kind: "point", x, y,
    viewportX: vv ? vv.offsetLeft : 0, viewportY: vv ? vv.offsetTop : 0,
    viewportWidth: vv ? vv.width : window.innerWidth,
  };
};

// The overlay back after a colour's picture is taken.
let unhide = 0;
const sampled = () => {
  clearTimeout(unhide);
  canvas.style.visibility = "";
  schedule();
};

// What a click or a tap at a point does: a colour's point while sampling;
// on touch, the next element after a selection gives the distance, tapped
// again it takes the selection; otherwise it selects.
const chose = (x, y, touch) => {
  if (sampling) {
    // The page's own pixel, not the tool's tints over it: the overlay is
    // put away until the app has its picture (sampled), or a moment.
    sampling = false;
    canvas.style.visibility = "hidden";
    clearTimeout(unhide);
    unhide = setTimeout(sampled, 1500);
    requestAnimationFrame(() => requestAnimationFrame(() => tell(point(x, y))));
    return;
  }
  const element = under(x, y);
  if (!element) return;
  if (touch && selected && element !== selected && (!distant || distant.element !== element)) {
    postDistance(element);
    schedule();
    return;
  }
  pick(element);
};

const take = (event) => {
  event.preventDefault();
  event.stopImmediatePropagation();
};

// A click with a mouse or a trackpad.
const click = (event) => {
  take(event);
  chose(event.clientX, event.clientY, false);
};

// A finger that moved, or a second finger, is a scroll or a pinch: the page
// keeps it, and nothing is chosen.
let touch = null;
const touched = (event) => {
  const first = event.touches[0];
  touch = event.touches.length === 1 && first ? { x: first.clientX, y: first.clientY, moved: false } : null;
  if (touch) { hover = under(touch.x, touch.y); schedule(); }
};
const touchMoved = (event) => {
  const first = event.touches[0];
  if (!touch || !first || event.touches.length > 1) { touch = null; return; }
  if (Math.hypot(first.clientX - touch.x, first.clientY - touch.y) > 10) touch.moved = true;
};
const touchEnded = (event) => {
  const one = event.changedTouches && event.changedTouches[0];
  const tapped = touch && !touch.moved && one;
  touch = null;
  if (!tapped) return;
  // The tap's click and its presses never come: the page hears none of it.
  take(event);
  chose(one.clientX, one.clientY, true);
};

// A field the person is typing in: G, R and X are its letters there.
const typing = (event) => {
  const target = event.composedPath ? event.composedPath()[0] : event.target;
  if (!target || target.nodeType !== 1) return false;
  return target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName);
};

const shown = () => tell({ kind: "shown", guides: guidesOn, rulers: rulersOn, xray: xrayOn });

const key = (event) => {
  if (event.key === "Escape") {
    take(event);
    finish();
    return;
  }
  if (event.key === "Alt") {
    alt = true;
    if (selected && hover) { postDistance(hover); schedule(); }
    return;
  }
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey || typing(event)) return;
  const lower = event.key.toLowerCase();
  if (lower !== "g" && lower !== "r" && lower !== "x") return;
  take(event);
  if (lower === "g") guidesOn = !guidesOn;
  if (lower === "r") rulersOn = !rulersOn;
  if (lower === "x") xrayOn = !xrayOn;
  // The panel's switches follow, and the rulers' is kept for next time.
  shown();
  schedule();
};

const lift = (event) => {
  if (event.key !== "Alt") return;
  alt = false;
  distant = null;
  tell({ kind: "distance", gone: true });
  schedule();
};

// Listened for on the window, capturing, which comes before the document
// and every element: a listener of the page's there or later along never
// hears what is taken (only one the page put on the window before the tool
// started can, and nothing in a page can come before that).
const listeners = [];
const listen = (type, handler, options) => {
  window.addEventListener(type, handler, options);
  listeners.push([type, handler, options]);
};

let ended = false;
const finish = () => {
  if (ended) return;
  ended = true;
  for (const [type, handler, options] of listeners) window.removeEventListener(type, handler, options);
  if (observer) observer.disconnect();
  if (frame) cancelAnimationFrame(frame);
  host.remove();
  if (window.__egluMeasure === handle) window.__egluMeasure = undefined;
  tell({ kind: "ended" });
  resolve();
};

let resolve;
const done = new Promise((end) => { resolve = end; });

// The app's handle on a running tool: stop it, give it new settings, pin a
// note to an element it has seen (notes, pinned by their number), or have
// the next tap say its point for a colour.
const handle = {
  stop: finish,
  // What the tool is showing, as __egluJSON.drawn() says the JSON view's:
  // for its tests, which cannot look inside a closed shadow root.
  state: () => ({
    on: true, run, guides: guidesOn, rulers: rulersOn, xray: xrayOn, sampling,
    overlay: canvas.style.visibility !== "hidden",
    selected: !!selected, hover: !!hover, pins: pins.size, alt,
    columns: drawn.columns, ticks: drawn.ticks, firstTick: drawn.firstTick, gaps: drawn.gaps, pinned: drawn.pinned,
  }),
  settings: (next) => {
    Object.assign(cfg, next);
    if (typeof next.rulers === "boolean") rulersOn = next.rulers;
    if (typeof next.guidesOn === "boolean") guidesOn = next.guidesOn;
    if (typeof next.xray === "boolean") xrayOn = next.xray;
    schedule();
  },
  pin: (id, ref, number) => {
    const element = refs.get(ref);
    if (element) pins.set(id, { element, number, name: nameOf(element) });
    schedule();
  },
  unpin: (id) => {
    pins.delete(id);
    schedule();
  },
  sampleNext: () => {
    sampling = true;
  },
  sampled,
};
// The tab's notes from an earlier run, their dots pinned again by name.
for (const note of cfg.notes || []) {
  const element = found(note.name);
  if (element) pins.set(note.id, { element, number: note.number, name: note.name });
}

// A run left by an earlier start ends first: one tool on a page.
if (window.__egluMeasure && window.__egluMeasure.stop) window.__egluMeasure.stop();
window.__egluMeasure = handle;

listen("mousemove", move, true);
// The presses that make a click are the tool's too: a canvas or a board
// would start a drag or a tool on them. A finger's are left to the page,
// which scrolls with them.
for (const type of ["pointerdown", "pointerup", "mousedown", "mouseup", "auxclick", "dblclick"]) {
  listen(type, (event) => { if (event.pointerType !== "touch") take(event); }, true);
}
listen("click", click, true);
listen("touchstart", touched, { capture: true, passive: true });
listen("touchmove", touchMoved, { capture: true, passive: true });
listen("touchend", touchEnded, { capture: true, passive: false });
listen("keydown", key, true);
listen("keyup", lift, true);
listen("scroll", schedule, { capture: true, passive: true });
listen("resize", schedule, false);
// A page put away (another address, the back-forward cache) ends the tool:
// it never comes back with the overlay and nothing to end it.
listen("pagehide", finish, true);
schedule();

return await done;
