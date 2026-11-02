// Runs the page-world document PiP shim without WebKit: node --test Tests/document-picture.mjs
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const script = readFileSync(new URL('../PadCore/Sources/PadCore/Scripts/picture.js', import.meta.url), 'utf8');

function page() {
  class MediaSession { setActionHandler() {} }
  const window = { MediaSession, open: () => Object.assign(new EventTarget(), { closed: false }) };
  window.top = window;
  const navigator = { userActivation: { isActive: false }, mediaSession: new MediaSession() };
  runInNewContext(script, { window, navigator, Event, EventTarget, DOMException,
    setTimeout(callback, delay) { if (delay === 0) queueMicrotask(callback); } });
  return { window, navigator };
}

test('a page without a registered handler can fall back to video PiP', async () => {
  const { window } = page();
  assert.equal(await window.__egluEnterPicture(), false);
});

test('a handler that does not open a document can fall back to video PiP', async () => {
  const { window, navigator } = page();
  navigator.mediaSession.setActionHandler('enterpictureinpicture', () => {});
  assert.equal(await window.__egluEnterPicture(), false);
});

test('a supported handler opens a document without a user click', async () => {
  const { window, navigator } = page();
  navigator.mediaSession.setActionHandler('enterpictureinpicture', async () => {
    await Promise.resolve();
    await window.documentPictureInPicture.requestWindow();
  });
  assert.equal(await window.__egluEnterPicture(), true);
  assert.ok(window.documentPictureInPicture.window);
});

test('a disabled site handler can fall back to video PiP', async () => {
  const { window, navigator } = page();
  navigator.mediaSession.setActionHandler('enterpictureinpicture', () => assert.fail());
  navigator.mediaSession.setActionHandler('enterpictureinpicture', null);
  assert.equal(await window.__egluEnterPicture(), false);
});

test('an existing document picture is not replaced automatically', async () => {
  const { window, navigator } = page();
  navigator.userActivation.isActive = true;
  const manual = await window.documentPictureInPicture.requestWindow();
  navigator.userActivation.isActive = false;
  navigator.mediaSession.setActionHandler('enterpictureinpicture', () => assert.fail());
  assert.equal(await window.__egluEnterPicture(), false);
  assert.equal(window.documentPictureInPicture.window, manual);
});
