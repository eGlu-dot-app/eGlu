#!/usr/bin/env node
// The measuring tool (PadCore/Scripts/measure.js) against a real page: a
// click selects and posts the element's details, the page hears none of the
// click however it listens, ⌥ and a second tap give distances, G/R/X and Esc
// do the tool's own jobs (but not in a field), the gaps, the 40 px between
// two boxes, the guides' columns and the rulers at any scroll are where they
// should be, stop() and a page put away end it as Esc does, and a note's
// selector finds its element.
//
//   node Tests/measure.mjs              Chromium
//   node Tests/measure.mjs webkit       Playwright's WebKit, closest to Safari
//
// Needs Playwright (npm i -D playwright, or PLAYWRIGHT=/path/to/playwright
// for one installed elsewhere). Nothing here ships in the app.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const engine = process.argv[2] || 'chromium';
const playwright = await import(process.env.PLAYWRIGHT || 'playwright');
const source = fs.readFileSync(path.join(root, 'WebKitEngine/Sources/WebKitSupport/Scripts/eglu-bridge.js'), 'utf8')
  + '\n' + fs.readFileSync(path.join(root, 'PadCore/Sources/PadCore/Scripts/measure.js'), 'utf8');


const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript' };
const server = http.createServer((request, response) => {
  const file = path.join(root, decodeURIComponent(new URL(request.url, 'http://x').pathname));
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(response);
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;

const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail: String(detail) });
const browser = await playwright[engine].launch();

// A page with the tool running: the app's handler stand-in keeps what it
// says, a counter counts the page's own clicks, and the run's promise is
// kept to await the ending.
const open = async () => {
  const page = await browser.newPage();
  page.on('pageerror', (error) => check('no errors on the page', false, error.message));
  await page.goto(`${base}/Tests/measure.html`);
  await page.evaluate(`window.__said = []; window.__clicks = 0;
    document.addEventListener('click', () => { window.__clicks += 1; });
    window.webkit = { messageHandlers: { egluMeasure: { postMessage: (m) => window.__said.push(m) } } };
    window.__guides = JSON.stringify({ columns: 12, gutter: 24, margin: 0, row: 8, rulers: true });`);
  return page;
};
// The body the app runs: the file is an async function's body (callAsyncJavaScript).
const start = (page) => page.evaluate((body) => {
  window.__done = new Function('guides', 'return (async () => {' + body + '})()')(JSON.parse(window.__guides));
}, source);
const state = (page) => page.evaluate(`window.__egluMeasure ? window.__egluMeasure.state() : null`);
const said = (page) => page.evaluate(`window.__said`);

try {
  // The overlay: a host under the document element in a closed shadow root.
  {
    const page = await open();
    await start(page);
    const host = await page.evaluate(`(() => {
      const host = document.documentElement.lastElementChild;
      return { isDiv: host && host.tagName === 'DIV', closed: host && host.shadowRoot === null };
    })()`);
    check('the overlay is a closed shadow host', host.isDiv && host.closed, JSON.stringify(host));
    const on = await state(page);
    check('the tool runs', on && on.on === true && on.rulers === true, JSON.stringify(on));
    await page.close();
  }

  // Hovering marks the element under the pointer without taking a click;
  // a click selects it, says its details, and the page never hears it.
  {
    const page = await open();
    await start(page);
    const box = await page.locator('.inner.primary').boundingBox();
    await page.mouse.move(box.x + 10, box.y + 10);
    await page.waitForTimeout(80);
    let st = await state(page);
    check('hover marks the element under the pointer', st.hover === true, JSON.stringify(st));
    await page.mouse.click(box.x + 10, box.y + 10);
    await page.waitForTimeout(80);
    const messages = await said(page);
    const details = messages.find((m) => m.kind === 'details');
    check('a click selects and posts details', !!details && details.tag === 'button'
          && details.width > 0 && details.padding && details.padding.top === 8
          && details.margin && details.margin.top === 4
          && details.font && details.font.size === '15px'
          && details.color === 'rgb(255, 255, 255)'
          && /#outer button\.inner:nth-of-type\(1\)/.test(details.name), JSON.stringify(details));
    check('the page never heard the click', await page.evaluate('window.__clicks') === 0);
    await page.close();
  }

  // ⌥ held, the element under the pointer gives the distance.
  {
    const page = await open();
    await start(page);
    const one = await page.locator('.inner.primary').boundingBox();
    const two = await page.locator('#aside').boundingBox();
    await page.mouse.click(one.x + 10, one.y + 10);
    await page.mouse.move(two.x + 10, two.y + 10);
    await page.keyboard.down('Alt');
    await page.mouse.move(two.x + 11, two.y + 11);
    await page.waitForTimeout(80);
    let messages = await said(page);
    let distance = messages.filter((m) => m.kind === 'distance').pop();
    check('⌥ gives the distance', !!distance && !distance.inside && distance.dy > 0,
          JSON.stringify(distance));
    await page.keyboard.up('Alt');
    await page.waitForTimeout(50);
    messages = await said(page);
    check('⌥ lifted ends the distance', messages.filter((m) => m.kind === 'distance').pop().gone === true);
    await page.close();
  }

  // A selection inside another: the four insets.
  {
    const page = await open();
    await start(page);
    const outer = await page.locator('#outer').boundingBox();
    const inner = await page.locator('.inner.primary').boundingBox();
    await page.mouse.click(outer.x + 5, outer.y + 2);
    await page.mouse.move(inner.x + 10, inner.y + 10);
    await page.keyboard.down('Alt');
    await page.mouse.move(inner.x + 11, inner.y + 11);
    await page.waitForTimeout(80);
    const messages = await said(page);
    const distance = messages.filter((m) => m.kind === 'distance').pop();
    check('one inside another gives the insets', !!distance && distance.inside === true
          && distance.insets && distance.insets.left > 0 && distance.insets.top > 0,
          JSON.stringify(distance));
    await page.close();
  }

  // G, R and X flip the guides, rulers and x-ray; Esc ends the tool.
  {
    const page = await open();
    await start(page);
    await page.keyboard.press('g');
    await page.keyboard.press('r');
    await page.keyboard.press('x');
    await page.waitForTimeout(50);
    let st = await state(page);
    check('G, R and X are the tool\'s', st.guides === true && st.rulers === false && st.xray === true,
          JSON.stringify(st));
    await page.keyboard.press('Escape');
    await page.waitForTimeout(80);
    const messages = await said(page);
    check('Esc ends the tool and says so', messages.some((m) => m.kind === 'ended'));
    check('the overlay goes', await page.evaluate(`document.documentElement.lastElementChild.tagName`) === 'BODY');
    check('the run resolves', await page.evaluate(`window.__done.then(() => 'resolved')`) === 'resolved');
    await page.close();
  }

  // The app's own handle: settings pushed, a note pinned, stop() ends.
  {
    const page = await open();
    await start(page);
    const box = await page.locator('.inner.primary').boundingBox();
    await page.mouse.click(box.x + 10, box.y + 10);
    await page.waitForTimeout(60);
    const ref = (await said(page)).find((m) => m.kind === 'details').ref;
    await page.evaluate(`window.__egluMeasure.pin('n1', ${ref}, 1)`);
    await page.waitForTimeout(50);
    let st = await state(page);
    check('a note pins to its element', st.pins === 1, JSON.stringify(st));
    await page.evaluate(`window.__egluMeasure.unpin('n1'); window.__egluMeasure.settings({ row: 4 })`);
    await page.waitForTimeout(50);
    st = await state(page);
    check('a note unpins and settings take', st.pins === 0, JSON.stringify(st));
    await page.evaluate(`window.__egluMeasure.stop()`);
    await page.waitForTimeout(60);
    check('stop() ends the tool', (await said(page)).some((m) => m.kind === 'ended'));
    await page.close();
  }

  // Element under the pointer is never the overlay's own: hovers after the
  // tool started still find page elements.
  {
    const page = await open();
    await start(page);
    const box = await page.locator('#aside').boundingBox();
    await page.mouse.move(box.x + 5, box.y + 5);
    await page.waitForTimeout(80);
    const st = await state(page);
    check('the overlay never covers the page', st.hover === true, JSON.stringify(st));
    await page.close();
  }
  // The plan's fixed layout: the 300 by 200 box's details, the row's two
  // 12 px gaps (none drawn over the middle child), the flex row's own gap
  // between the children's margins, and 40 px between the two boxes.
  {
    const page = await open();
    await start(page);
    // At (dx, dy) in the element: the row is picked in a gap, off its children.
    const click = async (selector, dx = 2, dy = 2) => {
      const box = await page.locator(selector).boundingBox();
      await page.mouse.click(box.x + dx, box.y + dy);
      await page.waitForTimeout(60);
    };
    await click('#box');
    let details = (await said(page)).filter((m) => m.kind === 'details').pop();
    check('the box is 300 by 200 with 16 px padding',
      details.width === 300 && details.height === 200 && details.padding.top === 16 && details.padding.left === 16,
      JSON.stringify(details));
    await click('#row', 16, 20);
    let st = await state(page);
    check('a flex row\'s 12 px gaps, one between each two children',
      st.gaps.length === 2 && st.gaps.every((gap) => Math.round(gap.w) === 12), JSON.stringify(st.gaps));
    const outer = await page.locator('#outer').boundingBox();
    await page.mouse.click(outer.x + 5, outer.y + 2);
    await page.waitForTimeout(60);
    st = await state(page);
    check('a gap is the gap, not the children\'s margins with it',
      st.gaps.length === 1 && Math.round(st.gaps[0].w) === 16, JSON.stringify(st.gaps));
    await click('#one');
    const two = await page.locator('#two').boundingBox();
    await page.mouse.move(two.x + 10, two.y + 10);
    await page.keyboard.down('Alt');
    await page.mouse.move(two.x + 11, two.y + 11);
    await page.mouse.move(two.x + 12, two.y + 12);
    await page.waitForTimeout(80);
    const distances = (await said(page)).filter((m) => m.kind === 'distance');
    check('the two boxes are 40 px apart', distances.length && distances[distances.length - 1].dx === 40,
      JSON.stringify(distances));
    check('a distance is said once for each element reached', distances.length === 1, JSON.stringify(distances));
    await page.keyboard.up('Alt');
    await page.close();
  }

  // Guides: 12 columns with a 24 px gutter at a known width.
  {
    const page = await open();
    await page.setViewportSize({ width: 1000, height: 700 });
    await start(page);
    await page.keyboard.press('g');
    await page.waitForTimeout(60);
    const st = await state(page);
    const width = (1000 - 24 * 11) / 12;
    const right = st.columns.length === 12 && st.columns.every((x, i) => Math.abs(x - i * (width + 24)) < 0.01);
    check('12 columns stand where they should', right, JSON.stringify(st.columns));
    await page.close();
  }

  // Rulers at any scroll: an odd one still has its ticks, the first at the
  // next ten.
  {
    const page = await open();
    await start(page);
    await page.evaluate(() => window.scrollTo(0, 101));
    await page.waitForTimeout(80);
    const st = await state(page);
    check('rulers have ticks at an odd scroll', st.ticks.y > 10 && st.firstTick.y === 9, JSON.stringify(st));
    await page.close();
  }

  // The page hears none of a click, nor its presses, however it listens:
  // capturing on the document, bubbling on the window, or capturing on the
  // window once the tool has begun.
  {
    const page = await open();
    await page.evaluate(`window.__heard = [];
      for (const type of ['pointerdown', 'mousedown', 'mouseup', 'click', 'keydown']) {
        document.addEventListener(type, (e) => window.__heard.push('document ' + e.type + (e.key ? ':' + e.key : '')), true);
        window.addEventListener(type, (e) => window.__heard.push('window ' + e.type + (e.key ? ':' + e.key : '')));
      }`);
    await start(page);
    await page.evaluate(`for (const type of ['pointerdown', 'mousedown', 'mouseup', 'click', 'keydown'])
      window.addEventListener(type, (e) => window.__heard.push('late ' + e.type + (e.key ? ':' + e.key : '')), true);`);
    const box = await page.locator('#box').boundingBox();
    await page.mouse.click(box.x + 5, box.y + 5);
    await page.keyboard.press('g');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(60);
    const heard = await page.evaluate('window.__heard');
    check('no listener of the page\'s hears the click, G or Esc', heard.length === 0, JSON.stringify(heard));
    await page.close();
  }

  // A field keeps its letters, and ⇧G is the page's.
  {
    const page = await open();
    await start(page);
    await page.focus('#field');
    await page.keyboard.type('grx');
    await page.waitForTimeout(40);
    let st = await state(page);
    const value = await page.evaluate(() => document.querySelector('#field').value);
    check('G, R and X typed into a field are the field\'s', value === 'grx' && !st.guides && st.rulers && !st.xray,
      JSON.stringify({ value, st }));
    await page.evaluate(() => document.activeElement.blur());
    await page.evaluate(`window.__shifted = 0; document.addEventListener('keydown', (e) => { if (e.key === 'G') window.__shifted += 1; })`);
    await page.keyboard.press('Shift+G');
    st = await state(page);
    check('⇧G is the page\'s', (await page.evaluate('window.__shifted')) === 1 && !st.guides, JSON.stringify(st));
    await page.close();
  }

  // R tells the panel, whose switch the rulers follow too, and the run's
  // number goes with what it says.
  {
    const page = await open();
    await page.evaluate(`window.__guides = JSON.stringify({ columns: 12, gutter: 24, margin: 0, row: 8, rulers: true, run: 7 })`);
    await start(page);
    await page.keyboard.press('r');
    await page.waitForTimeout(40);
    const told = (await said(page)).filter((m) => m.kind === 'shown').pop();
    check('R tells the panel', told && told.rulers === false && told.run === 7, JSON.stringify(told));
    await page.evaluate(`window.__egluMeasure.settings({ rulers: true, guidesOn: true, xray: true })`);
    const st = await state(page);
    check('the panel\'s switches move the page\'s', st.rulers && st.guides && st.xray, JSON.stringify(st));
    await page.evaluate(`window.__egluMeasure.stop()`);
    await page.waitForTimeout(40);
    const ended = (await said(page)).find((m) => m.kind === 'ended');
    check('the ending says its run', ended && ended.run === 7, JSON.stringify(ended));
    await page.close();
  }

  // Esc leaves nothing behind; a page put away ends the tool too.
  {
    const page = await open();
    await start(page);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(40);
    const left = await page.evaluate(`({ last: document.documentElement.lastElementChild.tagName, handle: typeof window.__egluMeasure })`);
    check('Esc leaves no overlay and no handle', left.last === 'BODY' && left.handle === 'undefined', JSON.stringify(left));
  }
  {
    const page = await open();
    await start(page);
    await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true })));
    await page.waitForTimeout(40);
    check('a page put away ends the tool', (await said(page)).some((m) => m.kind === 'ended')
      && await page.evaluate(`window.__done.then(() => 'resolved')`) === 'resolved');
    await page.close();
  }

  // Pick Colour on a touch screen: the next click says its point, and selects nothing.
  {
    const page = await open();
    await start(page);
    await page.evaluate(`window.__egluMeasure.sampleNext()`);
    const box = await page.locator('#box').boundingBox();
    await page.mouse.click(box.x + 30, box.y + 40);
    await page.waitForTimeout(40);
    const messages = await said(page);
    const at = messages.find((m) => m.kind === 'point');
    check('a sampled click says its point', at && Math.round(at.x) === Math.round(box.x + 30) && at.viewportWidth > 0,
      JSON.stringify(at));
    check('and selects nothing', !messages.some((m) => m.kind === 'details') && !(await state(page)).selected);
    check('the overlay is away for the picture', (await state(page)).overlay === false);
    await page.evaluate(`window.__egluMeasure.sampled()`);
    check('and back once it is taken', (await state(page)).overlay === true);
    await page.close();
  }

  // Names a selector has to escape still find their element.
  {
    const page = await open();
    await start(page);
    const named = async (selector) => {
      const box = await page.locator(selector).boundingBox();
      await page.mouse.click(box.x + 2, box.y + 2);
      await page.waitForTimeout(40);
      const name = (await said(page)).filter((m) => m.kind === 'details').pop().name;
      const found = await page.evaluate((n) => { try { return document.querySelector(n) !== null; } catch (_) { return false; } }, name);
      return { name, found };
    };
    const react = await named('[id=":r1:"]');
    check('a React id is a selector that finds it', react.found, JSON.stringify(react));
    const tailwind = await named('.md\\:flex');
    check('Tailwind classes are a selector that finds it', tailwind.found, JSON.stringify(tailwind));
    await page.close();
  }
  // Notes from an earlier run pin again by their elements' names, and a
  // dot whose element the page drew again finds it again.
  {
    const page = await open();
    await page.evaluate(`window.__guides = JSON.stringify({ rulers: false, run: 2,
      notes: [{ id: 'a', name: '#box', number: 1 }, { id: 'b', name: '#nowhere', number: 2 }] })`);
    await start(page);
    let st = await state(page);
    check('an earlier run\'s notes pin again where their elements are', st.pins === 1, JSON.stringify(st));
    const box = await page.locator('#two').boundingBox();
    await page.mouse.click(box.x + 2, box.y + 2);
    await page.waitForTimeout(40);
    const ref = (await said(page)).filter((m) => m.kind === 'details').pop().ref;
    await page.evaluate(`window.__egluMeasure.pin('c', ${ref}, 3)`);
    await page.evaluate(() => { const old = document.querySelector('#two'); old.replaceWith(old.cloneNode(true)); });
    await page.waitForTimeout(80);
    st = await state(page);
    check('a dot finds its element drawn again', st.pins === 2 && st.pinned === 2, JSON.stringify(st));
    await page.close();
  }
} finally {
  await browser.close();
  server.close();
}

let failed = 0;
for (const { name, ok, detail } of results) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail && !ok ? ' - ' + detail : ''}`);
  if (!ok) failed += 1;
}
console.log(`${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
