// Runs the shipped selection script with synthetic viewport/video state.
// Native PiP presentation still needs a Mac with WebKit.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';

const swift = readFileSync(new URL('../PadCore/Sources/PadCore/DocumentPicture.swift', import.meta.url), 'utf8');
const body = swift.match(/public static let float = """\n([\s\S]*?)\n    """/)[1];
const run = new (Object.getPrototypeOf(async function () {}).constructor)(
  'anyPlaying', 'document', 'getComputedStyle', 'innerWidth', 'innerHeight', 'window', body);

function video(left, top, width, height, extra = {}) {
  const item = {
    paused: false, ended: false, readyState: 3, volume: 1, muted: false,
    webkitAudioDecodedByteCount: 1, style: { visibility: 'visible', opacity: '1' },
    getBoundingClientRect: () => ({ left, top, width, height, right: left + width, bottom: top + height }),
    async requestPictureInPicture() { item.chosen = true; },
    addEventListener(type, listener) { item[type] = listener; },
    ...extra,
  };
  return item;
}

const select = (videos, anyPlaying = false) => run(anyPlaying,
  { querySelectorAll: () => videos, pictureInPictureElement: null }, item => item.style, 1000, 700, {});

test('a larger offscreen video cannot replace the visible video', async () => {
  const offscreen = video(0, -900, 1280, 720), visible = video(0, 0, 640, 360);
  assert.equal(await select([offscreen, visible]), true);
  assert.equal(offscreen.chosen, undefined);
  assert.equal(visible.chosen, true);
});

test('rank by visible intersection rather than the full video rectangle', async () => {
  const partial = video(900, 0, 1280, 720), visible = video(0, 0, 640, 360);
  await select([partial, visible]);
  assert.equal(partial.chosen, undefined);
  assert.equal(visible.chosen, true);
});

test('hidden and transparent videos are not candidates', async () => {
  for (const style of [{ visibility: 'hidden', opacity: '1' }, { visibility: 'visible', opacity: '0' }]) {
    assert.equal(await select([video(0, 0, 640, 360, { style })]), false);
  }
});

test('sound, paused state and the site opt-out still govern eligibility', async () => {
  const muted = video(0, 0, 640, 360, { muted: true });
  assert.equal(await select([muted]), false);
  assert.equal(await select([muted], true), true);
  assert.equal(await select([video(0, 0, 640, 360, { paused: true })], true), false);
  assert.equal(await select([video(0, 0, 640, 360, { disablePictureInPicture: true })], true), false);
});

test('a rejected PiP request reports failure', async () => {
  const item = video(0, 0, 640, 360, { async requestPictureInPicture() { throw new Error('unavailable'); } });
  assert.equal(await select([item]), false);
});

const sinkBody = swift.match(/public static let sink = """\n([\s\S]*?)\n    """/)[1];
const sink = new (Object.getPrototypeOf(async function () {}).constructor)('document', 'window', sinkBody);

test('an existing manually opened picture is left alone', async () => {
  const item = video(0, 0, 640, 360);
  let exits = 0;
  const document = { pictureInPictureElement: item, async exitPictureInPicture() { exits++; } };
  assert.equal(await run(false, document, () => item.style, 1000, 700, {}), false);
  assert.equal(item.chosen, undefined);
  await sink(document, {});
  assert.equal(exits, 0);
});

test('returning restores only the video floated automatically', async () => {
  const item = video(0, 0, 640, 360), window = {};
  let exits = 0;
  const document = { querySelectorAll: () => [item], pictureInPictureElement: null,
    async exitPictureInPicture() { exits++; } };
  await run(false, document, () => item.style, 1000, 700, window);
  document.pictureInPictureElement = item;
  await sink(document, window);
  assert.equal(exits, 1);
  assert.equal(window.__egluFloated, null);
  await sink(document, window);
  assert.equal(exits, 1);
});

test('a video reopened manually is no longer owned by automatic PiP', async () => {
  const item = video(0, 0, 640, 360), window = {};
  let exits = 0;
  const document = { querySelectorAll: () => [item], pictureInPictureElement: null,
    async exitPictureInPicture() { exits++; } };
  await run(false, document, () => item.style, 1000, 700, window);
  item.leavepictureinpicture();
  document.pictureInPictureElement = item;
  await sink(document, window);
  assert.equal(exits, 0);
});
