#!/usr/bin/env node
// The iPhone Duo's strip script (PadCore/Scripts/strip.js) against a page
// beside a strip on the right, 60 px wide, with bands at its top and foot:
// what can be pressed is placed clear of the whole column, the strip's
// empty middle too, on its own or in a list, before it scrolls in; where it
// stands from side to side never changes while the page scrolls a frame at
// a time; a control that comes in where it shows, once the page has come
// in, glides aside (at once under Reduce Motion); a header laid out anew
// after an early touch glides to its new place; a layer the page fixes is
// moved by the strip's width; a row the page takes out leaves the rest of
// its list in place; and nothing is laid out while the page moves.
//
//   node Tests/strip.mjs              Chromium
//   node Tests/strip.mjs webkit       Playwright's WebKit, closest to Safari
//
// Needs Playwright (npm i -D playwright, or PLAYWRIGHT=/path/to/playwright
// for one installed elsewhere). Nothing here ships in the app.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const engine = process.argv[2] || 'chromium';
const playwright = await import(process.env.PLAYWRIGHT || 'playwright');
const source = fs.readFileSync(path.join(root, 'PadCore/Sources/PadCore/Scripts/strip.js'), 'utf8');

const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail: String(detail) });

const WIDTH = 390;
const HEIGHT = 700;
const STRIP = { side: 'right', width: 60, bands: [[0, 120], [560, 700]], known: true };
const EDGE = WIDTH - STRIP.width;

const rows = Array.from({ length: 30 }, (_, i) =>
  `<div class="row"><span>Row ${i + 1}</span><button>Act</button></div>`).join('');
const html = `<!doctype html>
<meta name="viewport" content="width=device-width">
<style>
  html { scrollbar-width: none; }
  body { margin: 0; font: 16px/1.4 -apple-system, system-ui, sans-serif; }
  header { display: flex; justify-content: space-between; align-items: center; height: 48px; padding: 0 8px; background: #eee; }
  header nav { display: flex; gap: 12px; }
  p { margin: 16px 12px; }
  .row { display: flex; justify-content: space-between; align-items: center; height: 56px; padding: 0 8px; border-bottom: 1px solid #ddd; }
  .row button { width: 44px; height: 32px; }
  #fab { position: fixed; right: 16px; bottom: 300px; width: 48px; height: 48px; border-radius: 24px; }
  .late { position: relative; height: 50px; }
  .late a { position: absolute; right: 10px; top: 10px; width: 44px; height: 30px; display: block; background: #cde; }
  .card { display: flex; justify-content: space-between; margin: 12px; }
  .card a { display: block; width: 44px; height: 30px; background: #cde; }
</style>
<header><b>Logo</b><nav><a href="#">Docs</a><a href="#">Sign in</a></nav></header>
<p>${'Running text that wraps at the strip and runs on for a few lines. '.repeat(6)}</p>
<main>
  <aside class="card"><span>A pick</span><a href="#">Open</a></aside>
  <p>${'A line between. '.repeat(8)}</p>
  <figure class="card"><span>A note</span><a href="#">Read</a></figure>
  <p>${'A line between. '.repeat(8)}</p>
  <aside class="card"><span>Another pick</span><a href="#">Open</a></aside>
  <p>${'A line between. '.repeat(8)}</p>
  <figure class="card"><span>Another note</span><a href="#">Read</a></figure>
</main>
<section>${rows}</section>
<button id="fab">+</button>`;

const browser = await playwright[engine].launch();

// A page beside the strip, told it once loaded; `early` touches it first,
// as a finger on a slow phone does before the script has looked.
async function open({ early = false, reducedMotion = 'no-preference', body = html } = {}) {
  const context = await browser.newContext({ viewport: { width: WIDTH, height: HEIGHT }, hasTouch: true, reducedMotion });
  const page = await context.newPage();
  await page.route('http://strip.test/', (route) => route.fulfill({ body, contentType: 'text/html' }));
  await page.addInitScript({ content: source });
  await page.goto('http://strip.test/');
  if (early) {
    await page.evaluate(() => {
      // WebKit on the Mac makes no TouchEvent: an event with no touches, as the script reads it.
      for (const type of ['touchstart', 'touchend']) {
        let event;
        try {
          event = new TouchEvent(type, { touches: [] });
        } catch {
          event = new Event(type);
          Object.defineProperty(event, 'touches', { value: [] });
        }
        window.dispatchEvent(event);
      }
    });
  }
  await page.evaluate((strip) => window.__egluStrip.set(strip), STRIP);
  await idle(page);
  return { context, page };
}

// Until the script has nothing left to do, the page still.
async function idle(page) {
  await page.waitForTimeout(400);
  await page.waitForFunction(() => {
    const s = window.__egluStrip.state();
    return s.slices > 0 && s.pending === 0;
  }, null, { timeout: 10000 });
  await page.waitForTimeout(400);
}

// Whether the page comes to `test` within a few seconds.
const comes = (page, test) => page.waitForFunction(test, null, { timeout: 5000 }).then(() => true, () => false);

// Each row's button, from side to side, in the window.
const buttons = (page) => page.$$eval('.row button', (all) => all.map((b) => {
  const r = b.getBoundingClientRect();
  return { left: r.left, right: r.right, top: r.top };
}));

try {
  // Placed before it shows, the whole column, the empty middle too.
  {
    const { context, page } = await open();
    const cards = await page.$$eval('.card a', (all) => all.map((a) => {
      const r = a.getBoundingClientRect();
      return { top: Math.round(r.top), right: Math.round(r.right) };
    }));
    // Clear of the strip's bands at its top and foot by more than a finger, where the old slant moved nothing.
    const middle = cards.filter((card) => card.top > 180 && card.top < 480);
    check('a control in the strip\'s empty middle is placed beside the strip', middle.length && middle.every((card) => card.right <= EDGE),
      JSON.stringify(cards));
    check('a control on its own, anywhere down the strip, is placed beside it', cards.every((card) => card.right <= EDGE), JSON.stringify(cards));
    const below = (await buttons(page)).filter((b) => b.top > HEIGHT + 100 && b.top < HEIGHT * 2.5);
    check('rows below the window are placed before they show', below.length && below.every((b) => b.right <= EDGE + 0.5),
      JSON.stringify(below.map((b) => Math.round(b.right))));
    check('nothing left under the strip in the window', (await page.evaluate(() => window.__egluStrip.leftovers())).length === 0,
      JSON.stringify(await page.evaluate(() => window.__egluStrip.leftovers())));
    const text = await page.$eval('p', (p) => p.getBoundingClientRect().right - parseFloat(getComputedStyle(p).paddingRight));
    check('running text ends its lines at the strip\'s edge', Math.abs(text - EDGE) < 1, Math.round(text));
    const header = await page.$eval('header nav a:last-child', (a) => a.getBoundingClientRect().right);
    check('the header\'s row is laid out clear of the strip', header <= EDGE, Math.round(header));
    const fab = await page.$eval('#fab', (b) => b.getBoundingClientRect().right);
    check('a fixed button is moved by the strip\'s width', Math.abs(fab - (WIDTH - 16 - STRIP.width)) < 1, Math.round(fab));

    // Down the page a window at a time, still a moment at each, as a person reads: nothing left at any.
    const left = [];
    for (let y = 0; ; y += HEIGHT * 0.8) {
      const at = await page.evaluate((top) => {
        scrollTo({ top, behavior: 'instant' });
        return scrollY;
      }, y);
      await page.waitForTimeout(900);
      left.push(...(await page.evaluate(() => window.__egluStrip.leftovers())).map((one) => `${Math.round(at)}:${one.name}`));
      if (at < y - 1) break;
    }
    await page.evaluate(() => scrollTo({ top: 0, behavior: 'instant' }));
    await page.waitForTimeout(900);
    check('nothing left under the strip anywhere down the page', left.length === 0, left.join(' '));
    const rows = await buttons(page);
    const columns = new Set(rows.map((b) => Math.round(b.left)));
    check('the list\'s rows keep one column', columns.size === 1 && rows.every((b) => b.right <= EDGE), [...columns].join(','));

    // A frame at a time down the page and back, as a finger scrolls.
    const most = await page.evaluate(async () => {
      const nodes = [...document.querySelectorAll('.row button, .card a, #fab, header nav a')];
      const lefts = () => nodes.map((node) => node.getBoundingClientRect().left);
      const frame = () => new Promise((done) => requestAnimationFrame(done));
      const far = document.scrollingElement.scrollHeight - innerHeight;
      let last = lefts();
      let worst = 0;
      let frames = 0;
      for (const way of [1, -1]) {
        for (let y = 12; y <= far; y += 12) {
          scrollTo({ top: way > 0 ? y : far - y, behavior: 'instant' });
          await frame();
          frames++;
          const now = lefts();
          now.forEach((x, i) => { worst = Math.max(worst, Math.abs(x - last[i])); });
          last = now;
        }
      }
      return { worst, frames };
    });
    check('nothing moves from side to side while the page scrolls', most.frames > 100 && most.worst < 0.5, JSON.stringify(most));
    const state = await page.evaluate(() => window.__egluStrip.state());
    check('nothing laid out while the page moved, nothing thrown', state.unsteady === 0 && state.failures === 0, JSON.stringify(state));

    // Once the page has come in, a control coming in where it shows glides there.
    await page.evaluate(() => scrollTo({ top: 0, behavior: 'instant' }));
    await page.waitForTimeout(2600);
    await page.evaluate(() => {
      const late = document.createElement('div');
      late.className = 'late';
      late.innerHTML = '<a href="#">Late</a>';
      document.querySelector('p').after(late);
    });
    const came = await comes(page, () => document.querySelector('.late a').getAnimations().length > 0);
    const glide = came ? await page.$eval('.late a', (a) => {
      const timing = a.getAnimations()[0].effect.getComputedTiming();
      return { duration: timing.duration, fill: timing.fill };
    }) : 'never moved';
    check('a control shifted where it shows glides there', glide.duration === 240 && glide.fill === 'forwards', JSON.stringify(glide));
    await page.waitForTimeout(500);
    const late = await page.$eval('.late a', (a) => a.getBoundingClientRect().right);
    check('and holds beside the strip once it has', late <= EDGE + 0.5, Math.round(late));
    await context.close();
  }

  // A row the page takes out of a list: the other rows keep their place, in every frame.
  {
    const list = Array.from({ length: 12 }, (_, i) => `<div class="row"><span>Row ${i + 1}</span><button>Act</button></div>`).join('');
    const { context, page } = await open({ body: `<!doctype html><style>body { margin: 0; }
      .row { display: flex; justify-content: space-between; height: 56px; padding: 0 8px; }
      .row button { width: 44px; height: 32px; }</style><section>${list}</section><div style="height: 2000px"></div>` });
    const kept = await page.evaluate(async () => {
      const lefts = () => [...document.querySelectorAll('.row button')].map((b) => Math.round(b.getBoundingClientRect().left));
      const before = [...new Set(lefts())];
      document.querySelectorAll('.row')[3].remove();
      const seen = new Set();
      for (const end = performance.now() + 1200; performance.now() < end;) {
        await new Promise((done) => requestAnimationFrame(done));
        for (const left of lefts()) seen.add(left);
      }
      return { before, seen: [...seen] };
    });
    check('a row taken out leaves the rest of its list where it was', kept.before.length === 1 && kept.before[0] < WIDTH - 8 - 44 &&
      kept.seen.length === 1 && kept.seen[0] === kept.before[0], JSON.stringify(kept));
    await context.close();
  }

  // Under Reduce Motion, there at once.
  {
    const { context, page } = await open({ reducedMotion: 'reduce' });
    await page.waitForTimeout(2600);
    await page.evaluate(() => {
      const late = document.createElement('div');
      late.className = 'late';
      late.innerHTML = '<a href="#">Late</a>';
      document.querySelector('p').after(late);
    });
    const came = await comes(page, () => document.querySelector('.late a').getAnimations().length > 0);
    const held = came ? await page.$eval('.late a', (a) => a.getAnimations()[0].playState) : 'never moved';
    check('under Reduce Motion it is there at once', held === 'paused', held);
    await context.close();
  }

  // Touched before the script looked: the header row laid out anew in place, its insides gliding there.
  {
    const { context, page } = await open({ early: true });
    const state = await page.evaluate(() => window.__egluStrip.state());
    const header = await page.$eval('header nav a:last-child', (a) => a.getBoundingClientRect().right);
    check('after an early touch the header is still laid out clear of the strip', state.settled && header <= EDGE, `${Math.round(header)} ${JSON.stringify(state)}`);
    check('and what is in it glided there', state.glides > 0, state.glides);
    check('nothing laid out while the page moved, after an early touch', state.unsteady === 0 && state.failures === 0);
    await context.close();
  }
} finally {
  await browser.close();
}

let failed = 0;
for (const { name, ok, detail } of results) {
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok || !detail ? '' : `: ${detail}`}`);
}
console.log(`${results.length - failed} of ${results.length} passed (${engine})`);
process.exit(failed ? 1 : 0);
