#!/usr/bin/env node
// Runs PadCore's shim for Chrome extensions (Scripts/extension-shim.js)
// against a stand-in for WebKit's extension APIs, which behaves where it
// matters as WebKit does: the first onMessage listener's return is the
// answer (macOS 26, as Search found), a promise returned is waited for, and
// a reply that never came is undefined with no error (macOS 27 too). On 27
// a promise that fails never reaches the sender at all; the shim's gate
// never returns one.
// Chrome's side is Chrome 148's, from developer.chrome.com's messaging page.
//
//   node Tests/extension-shim.mjs
//
// Needs nothing beyond Node. Nothing here ships in the app.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const shim = fs.readFileSync(path.join(root, 'PadCore/Sources/PadCore/Scripts/extension-shim.js'), 'utf8');

const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail: String(detail) });
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

/// A world with WebKit's APIs as an extension's background, page or
/// content script has them, the shim run in it `times` times.
function world({ protocol = 'chrome-extension:', apis = true, times = 1, reply, background = false, lastError, channel = false, page = '/page.html', nativeReply, i18n = {}, extra = {}, scripting, permissions = [], namespaces = {}, worker = false, runtimeExtra = {}, events = null, manifestExtra = {}, prototype = false } = {}) {
  const native = [];
  const event = () => {
    const listeners = [];
    return {
      listeners,
      addListener(f) { listeners.push(f); },
      removeListener(f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
      hasListener(f) { return listeners.includes(f); },
      // WebKit's rule: the first listener's return decides.
      deliver(message, sender = { id: 'sender' }) {
        return new Promise((resolve, reject) => {
          let answered = false;
          const sendResponse = (value) => { if (!answered) { answered = true; resolve(value); } };
          let first;
          listeners.forEach((listener, i) => {
            const result = listener(message, sender, sendResponse);
            if (i === 0) first = result;
          });
          if (first === true) return;
          if (first && typeof first.then === 'function') { first.then(sendResponse, reject); return; }
          sendResponse(undefined);
        });
      },
    };
  };
  const target = new EventTarget();
  const chrome = apis ? {
    runtime: {
      id: 'abcdefghijklmnopabcdefghijklmnop',
      onMessage: event(),
      onMessageExternal: event(),
      sendMessage: async (message) => (reply ? reply(message) : undefined),
      sendNativeMessage: async (application, message) => { native.push({ application, message }); return nativeReply ? nativeReply(message) : { value: null }; },
      getURL: (path) => 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/' + path,
      getManifest: () => ({ background: { service_worker: 'bg.js' }, permissions, ...manifestExtra }),
      ...runtimeExtra,
    },
    tabs: { sendMessage: async () => undefined },
    i18n,
    ...(scripting ? { scripting } : {}),
    ...namespaces,
  } : undefined;
  if (chrome && lastError) chrome.runtime.lastError = lastError;
  // runtime.sendMessage on the prototype, where WebKit keeps it: the shim
  // reaches past its own wrapper there for eGlu's envelopes.
  if (chrome && prototype) {
    const { sendMessage } = chrome.runtime;
    delete chrome.runtime.sendMessage;
    Object.setPrototypeOf(chrome.runtime, { sendMessage });
  }
  // A timer's throw reaches the world's error event, as in a browser.
  const timer = (f, ms) => setTimeout(() => {
    try { f(); } catch (error) { target.dispatchEvent(Object.assign(new Event('error'), { error })); }
  }, ms);
  const origin = protocol === 'chrome-extension:' ? 'chrome-extension://abcdefghijklmnopabcdefghijklmnop' : 'https://example.com';
  const globals = {
    setTimeout: timer, clearTimeout, EventTarget, DOMException, URL,
    location: { protocol, origin, pathname: page, href: origin + page },
    addEventListener: target.addEventListener.bind(target),
    ...extra,
  };
  if (chrome) { globals.chrome = chrome; globals.browser = chrome; }
  // A service worker: what the shim takes for one.
  if (worker) { globals.__isWorker = true; globals.ServiceWorkerGlobalScope = class { static [Symbol.hasInstance](x) { return !!(x && x.__isWorker); } }; }
  if (channel) globals.BroadcastChannel = BroadcastChannel;
  const context = vm.createContext(globals);
  if (background) {
    context.document = {};
    chrome.extension = { getBackgroundPage: () => vm.runInContext('globalThis', context) };
  }
  // The events the extension's code names, as ExtensionPreparation fills them in.
  const filled = events ? shim.replace('/*__EGLU_EVENTS__*/[]', JSON.stringify(events)) : shim;
  for (let i = 0; i < times; i++) vm.runInContext(filled, context, { filename: 'extension-shim.js' });
  return { context, chrome, native, target, run: (code) => vm.runInContext(code, context) };
}

// Missing language detection is supplied locally, including content-script callers.
{
  const result = { isReliable: true, languages: [{ language: 'en', percentage: 100 }] };
  const w = world({ nativeReply: (message) => ({ value: message.api === 'i18n.detectLanguage' ? result : null }) });
  const detect = w.run('chrome.i18n.detectLanguage');
  check('missing i18n.detectLanguage is supplied', typeof detect === 'function');
  if (typeof detect === 'function') {
    check('language detection promise preserves the Chrome result', JSON.stringify(await detect('A synthetic English paragraph.')) === JSON.stringify(result));
    const callback = await new Promise((done) => detect('Text', done));
    check('language detection supports callback callers', JSON.stringify(callback) === JSON.stringify(result));
    check('only supplied text is passed to the language endpoint', w.native.filter((n) => n.message.api === 'i18n.detectLanguage').every((n) => n.message.args.length === 1 && typeof n.message.args[0] === 'string'));
    const sent = w.native.length;
    const invalid = await detect({ text: 'not a string' }).then(() => false, (e) => e.name === 'TypeError');
    check('invalid language input rejects without sending native data', invalid && w.native.length === sent);
    const invalidCallback = await new Promise((done) => detect(null, () => done(w.chrome.runtime.lastError?.message)));
    check('invalid callback language input exposes lastError only during callback', typeof invalidCallback === 'string' && w.chrome.runtime.lastError === undefined);

  }
  const native = () => Promise.resolve(result);
  const given = world({ i18n: { detectLanguage: native } });
  check('native i18n.detectLanguage is retained', given.run('chrome.i18n.detectLanguage') === native);
  const worker = world({ background: true, nativeReply: () => ({ value: result }) });
  const sender = { id: worker.chrome.runtime.id, url: 'https://synthetic.invalid/page' };
  const envelope = { __egluCall: { space: 'i18n', method: 'detectLanguage', args: ['Synthetic text'] } };
  const answered = await worker.chrome.runtime.onMessage.deliver(envelope, sender);
  check('same-extension content script can detect only supplied text', JSON.stringify(answered?.value) === JSON.stringify(result));
  const before = worker.native.length;
  await worker.chrome.runtime.onMessage.deliver(envelope, { id: 'another-extension', url: sender.url });
  check('another extension cannot use the private language relay', worker.native.length === before);
  const denied = await worker.chrome.runtime.onMessage.deliver({ __egluCall: { space: 'tabs', method: 'query', args: [{}] } }, sender);
  check('language relay does not grant a content script tab APIs', typeof denied?.error === 'string');
  const content = world({ protocol: 'https:', reply: (message) => message.__egluCall ? { value: result } : undefined });
  const contentDetect = content.run('chrome.i18n.detectLanguage');
  check('content scripts receive the language method', typeof contentDetect === 'function');
  if (typeof contentDetect === 'function') {
    check('content detection uses its worker instead of native messaging', JSON.stringify(await contentDetect('Text')) === JSON.stringify(result) && content.native.length === 0);
  }
}

// The Mac's colour sampler stands in for Chromium's EyeDropper: a pick
// answers a colour, a cancel rejects as AbortError, and a world that has
// its own keeps it.
{
  const w = world({ nativeReply: (message) => ({ value: message.api === 'eyeDropper.open' ? '#336699' : null }) });
  check('an extension page gets an EyeDropper', w.run('typeof EyeDropper === "function"'));
  const picked = await w.run('new EyeDropper().open()');
  check('a pick answers a colour as Chrome\'s does', picked?.sRGBHex === '#336699', JSON.stringify(picked));
  check('the pick asked eGlu', w.native.some((n) => n.message.api === 'eyeDropper.open' && n.message.args.length === 0), JSON.stringify(w.native));
  const cancel = world({ nativeReply: () => ({ error: 'AbortError' }) });
  const reason = await cancel.run('new EyeDropper().open()').then(() => 'resolved', (e) => e);
  check('a cancel rejects with a DOMException named AbortError', reason instanceof DOMException && reason.name === 'AbortError', String(reason && reason.name || reason));
  class OwnDropper { open() { return Promise.resolve({ sRGBHex: '#000000' }); } }
  const already = world({ extra: { EyeDropper: OwnDropper } });
  check('an existing EyeDropper is kept', already.run('EyeDropper') === OwnDropper
    && await already.run('new EyeDropper().open().then((c) => c.sRGBHex)') === '#000000');
  const content = world({ protocol: 'https:', reply: (message) => message.__egluCall ? { value: '#a1b2c3' } : undefined });
  check('a content script has the picker too', content.run('typeof EyeDropper === "function"'));
  const relayed = await content.run('new EyeDropper().open()');
  check('its pick goes through the worker, not native messaging', relayed?.sRGBHex === '#a1b2c3' && content.native.length === 0, JSON.stringify(relayed));
  const worker = world({ background: true, nativeReply: () => ({ value: '#102030' }) });
  const sender = { id: worker.chrome.runtime.id, url: 'https://synthetic.invalid/page' };
  const envelope = { __egluCall: { space: 'eyeDropper', method: 'open', args: [] } };
  const answered = await worker.chrome.runtime.onMessage.deliver(envelope, sender);
  check('a content script\'s pick reaches the sampler', answered?.value === '#102030', JSON.stringify(answered));
  const before = worker.native.length;
  await worker.chrome.runtime.onMessage.deliver(envelope, { id: 'another-extension', url: sender.url });
  check('another extension cannot ask for a pick', worker.native.length === before);
}

// An abort while the sampler is open answers at once, as AbortError.
{
  const w = world({ nativeReply: () => new Promise(() => {}) });
  const controller = new AbortController();
  w.context.signal = controller.signal;
  const pending = w.run('new EyeDropper().open({ signal })').then(() => 'resolved', (e) => e);
  controller.abort();
  const reason = await Promise.race([pending, new Promise((r) => setTimeout(() => r('still open'), 200))]);
  check('an abort during a pick rejects at once with AbortError', reason instanceof DOMException && reason.name === 'AbortError', String(reason && reason.name || reason));
}

// chrome.scripting puts the shim in front of the files it injects, so a
// click-only grant's injection gets the stand-ins too.
{
  const calls = [];
  const scripting = { executeScript: async (injection) => { calls.push(injection); return [{ result: 'ran' }]; } };
  const worker = world({ background: true, scripting });
  const result = await worker.run('chrome.scripting.executeScript({ target: { tabId: 1 }, files: ["content.js"] })');
  check('injected files get the shim first', JSON.stringify(calls[0]?.files) === JSON.stringify(['_eglu/shim.js', 'content.js']), JSON.stringify(calls[0]));
  check('the injection answers as it did', result?.[0]?.result === 'ran', JSON.stringify(result));
  await worker.run('chrome.scripting.executeScript({ target: { tabId: 1 }, files: ["page.js"], world: "MAIN" })');
  check('the page\'s own world gets no shim', JSON.stringify(calls[1]?.files) === JSON.stringify(['page.js']), JSON.stringify(calls[1]));
  await worker.run('chrome.scripting.executeScript({ target: { tabId: 1 }, func: () => 1 })');
  check('a function injection is left as it is', calls[2] && !('files' in calls[2]), JSON.stringify(calls[2]));
  await worker.run('chrome.scripting.executeScript({ target: { tabId: 1 }, files: ["/_eglu/shim.js", "a.js"] })');
  check('a shim already named is not added twice', JSON.stringify(calls[3]?.files) === JSON.stringify(['/_eglu/shim.js', 'a.js']), JSON.stringify(calls[3]));
}

// A page's own world: no extension APIs, nothing left behind.
{
  const w = world({ apis: false });
  check('a world without extension APIs is left as it was', w.run('typeof __egluShim === "undefined" && typeof requestIdleCallback === "undefined"'));
}

// Run twice, as when two content script entries match one page: once.
{
  const w = world({ times: 2 });
  check('the shim runs once in a world', w.run('__egluShim === true'));
  const webkit = w.chrome.runtime.onMessage.listeners;
  check('a page with no listener has none of WebKit\'s', webkit.length === 0, webkit.length);
  const f = () => undefined;
  w.run('chrome.runtime.onMessage').addListener(f);
  w.run('chrome.runtime.onMessage').addListener(() => undefined);
  check('one of WebKit\'s behind its listeners', webkit.length === 1, webkit.length);
  w.run('chrome.runtime.onMessage').removeListener(f);
  check('still there while one is left', webkit.length === 1, webkit.length);
}
{
  const w = world();
  const f = () => undefined;
  w.run('chrome.runtime.onMessage').addListener(f);
  w.run('chrome.runtime.onMessage').removeListener(f);
  check('gone with the last', w.chrome.runtime.onMessage.listeners.length === 0);
}
{
  const w = world({ background: true });
  check('the background\'s is there from the start', w.chrome.runtime.onMessage.listeners.length === 1);
  const f = () => undefined;
  w.run('chrome.runtime.onMessage').addListener(f);
  w.run('chrome.runtime.onMessage').removeListener(f);
  check('and stays', w.chrome.runtime.onMessage.listeners.length === 1);
}

// Between the extension's pages, on their channel (Search's): a page with
// nothing to say steps aside until the worker has spoken, and a page's
// message reaches its other pages, which WebKit doesn't bring it to.
{
  const options = { background: false, channel: true };
  const pageA = world({ ...options, page: '/options.html' });
  const bg = world({ background: true, channel: true, page: '/bg.js' });
  pageA.run('chrome.runtime.onMessage').addListener(() => undefined);
  bg.run('chrome.runtime.onMessage').addListener(() => undefined);
  await tick(20);
  const started = Date.now();
  const pageAnswer = pageA.chrome.runtime.onMessage.deliver({ about: 'nothing' });
  await tick(5);
  await bg.chrome.runtime.onMessage.deliver({ about: 'nothing' });
  const reply = await Promise.race([pageAnswer, new Promise((r) => setTimeout(() => r('still waiting'), 3000))]);
  check('a page with nothing to say waits for the worker, then says nothing', reply === undefined && Date.now() - started < 3000, String(reply));
  // The worker answers, late: the page waits until it has, then says nothing.
  bg.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { if (message && message.slow) { setTimeout(() => respond('slow answer'), 400); return true; } });
  const slowAsked = Date.now();
  const pageSide = pageA.chrome.runtime.onMessage.deliver({ slow: 1 });
  await tick(5);
  const workerSide = await bg.chrome.runtime.onMessage.deliver({ slow: 1 });
  const pageSaid = await Promise.race([pageSide, new Promise((r) => setTimeout(() => r('still waiting'), 3000))]);
  check('a page steps aside until a slow answer has gone, then says nothing', workerSide === 'slow answer' && pageSaid === undefined
    && Date.now() - slowAsked >= 400 && Date.now() - slowAsked < 3000, workerSide + ' / ' + String(pageSaid));
  const pageB = world({ ...options, page: '/popup.html' });
  const seen = [];
  pageB.run('chrome.runtime.onMessage').addListener((message) => { seen.push(message); });
  await tick(20);
  pageA.run('chrome.runtime').sendMessage({ sync: 1 }).catch(() => {});
  await tick(150);
  check('a page\'s message reaches the extension\'s other pages', seen.some((m) => m && m.sync === 1), JSON.stringify(seen));
  // And its answer comes back to the sender, which WebKit brought nothing.
  pageB.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { if (message && message.ask) { setTimeout(() => respond('from B'), 20); return true; } });
  const relayedReply = await pageA.run('chrome.runtime').sendMessage({ ask: 1 });
  check('a relayed message\'s answer reaches its sender', relayedReply === 'from B', String(relayedReply));
  const asked = Date.now();
  const none = await pageA.run('chrome.runtime').sendMessage({ nobody: 1 });
  check('one nobody answers doesn\'t wait long', none === undefined && Date.now() - asked < 1500, String(Date.now() - asked));
}

// A message for a tab whose own page is the extension's: Chrome brings it
// to that page (NordPass's sign-in page is told so where to go next);
// WebKit brings it to content scripts alone, so the worker hands it on.
{
  const id = 'abcdefghijklmnopabcdefghijklmnop';
  const app = 'chrome-extension://' + id + '/app.html#/login';
  const handed = [];
  // Each world its own: the shim wraps what it is given.
  const tabs = () => ({ sendMessage: async () => undefined, get: async (tabId) => ({ id: tabId, url: tabId === 4 ? app : 'https://example.com/' }) });
  const getAllFrames = async ({ tabId }) => [{ frameId: 0, url: tabId === 4 ? app : 'https://example.com/' }];
  const w = world({ background: true, prototype: true, permissions: ['tabs', 'webNavigation'], namespaces: { tabs: tabs(), webNavigation: { getAllFrames } },
    reply: (m) => { if (m && m.__egluToFrame) handed.push(m.__egluToFrame); return undefined; } });
  await w.run('chrome.tabs').sendMessage(4, { type: 'OPEN', url: 'https://sign-in.invalid/' });
  check('a message for a tab showing the extension\'s own page is handed to that page',
    handed.length === 1 && handed[0].tabId === 4 && handed[0].urls.includes(app), JSON.stringify(handed));
  await w.run('chrome.tabs').sendMessage(5, { type: 'OPEN' });
  check('one for a website\'s tab goes to its content scripts alone', handed.length === 1, JSON.stringify(handed));
  const quiet = world({ background: true, prototype: true, namespaces: { tabs: tabs(), webNavigation: { getAllFrames: async () => [] } },
    reply: (m) => { if (m && m.__egluToFrame) handed.push(m.__egluToFrame); return undefined; } });
  await quiet.run('chrome.tabs').sendMessage(4, { type: 'OPEN' });
  check('the tab\'s own address is enough when its frames don\'t list it', handed.length === 2 && handed[1].urls.includes(app), JSON.stringify(handed));

  // The page in that tab takes it; the same page in another tab doesn't.
  const page = (tabId) => {
    const seen = [];
    const p = world({ page: '/app.html#/login', prototype: true,
      reply: (m) => m && m.__egluCall && m.__egluCall.method === 'getCurrent' ? { value: { id: tabId } } : undefined });
    p.run('chrome.runtime.onMessage').addListener((m) => { seen.push(m); });
    return { p, seen };
  };
  const inTab = page(4), elsewhere = page(6);
  const sender = { id, url: 'chrome-extension://' + id + '/bg.js' };
  for (const { p } of [inTab, elsewhere]) p.chrome.runtime.onMessage.deliver({ __egluToFrame: { tabId: 4, urls: [app], message: { type: 'OPEN' } } }, sender);
  await tick(50);
  check('the tab\'s own page hears it', inTab.seen.some((m) => m && m.type === 'OPEN'), JSON.stringify(inTab.seen));
  check('the same page in another tab doesn\'t', !elsewhere.seen.some((m) => m && m.type === 'OPEN'), JSON.stringify(elsewhere.seen));
}

// The same, end to end over the pages' channel, which is how a tab's own
// page hears the worker: WebKit brings it nothing the worker sends.
{
  const id = 'abcdefghijklmnopabcdefghijklmnop';
  const app = 'chrome-extension://' + id + '/app.html#/login';
  const tabs = { sendMessage: async () => undefined, get: async (tabId) => ({ id: tabId, url: app }) };
  const worker = world({ background: true, channel: true, prototype: true, page: '/bg.js', namespaces: { tabs, webNavigation: { getAllFrames: async () => [] } } });
  const page = (tabId, answer) => {
    const seen = [];
    const p = world({ channel: true, prototype: true, page: '/app.html#/login',
      reply: (m) => m && m.__egluCall && m.__egluCall.method === 'getCurrent' ? { value: { id: tabId } } : undefined });
    p.run('chrome.runtime.onMessage').addListener((m, sender, respond) => { seen.push(m); if (answer) { respond(answer); } });
    return seen;
  };
  const inTab = page(4), elsewhere = page(6);
  await tick(30);
  const asked = Date.now();
  const reply = await worker.run('chrome.tabs').sendMessage(4, { type: 'OPEN', url: 'https://sign-in.invalid/' });
  await tick(30);
  check('over the channel, the page in the tab named hears it', inTab.some((m) => m && m.type === 'OPEN'), JSON.stringify(inTab));
  check('the same page in another tab doesn\'t', !elsewhere.some((m) => m && m.type === 'OPEN'), JSON.stringify(elsewhere));
  check('and the sender isn\'t kept waiting when it answers nothing', reply === undefined && Date.now() - asked < 2000, String(Date.now() - asked));
  const answering = page(7, 'from the page');
  await tick(30);
  const t7 = { sendMessage: async () => undefined, get: async (tabId) => ({ id: tabId, url: app }) };
  const worker7 = world({ background: true, channel: true, prototype: true, page: '/bg.js', namespaces: { tabs: t7, webNavigation: { getAllFrames: async () => [] } } });
  const answered = await worker7.run('chrome.tabs').sendMessage(7, { type: 'ASK' });
  check('a page\'s answer comes back to the worker', answered === 'from the page' && answering.some((m) => m && m.type === 'ASK'), String(answered));
}

// A frame in a website has no pages' channel. Its native answer still
// counts while pages on that channel say they have nothing to answer.
{
  const id = 'abcdefghijklmnopabcdefghijklmnop';
  const app = 'chrome-extension://' + id + '/embedded.html';
  const frame = world({ channel: true, prototype: true, page: '/embedded.html',
    extra: { window: { top: { location: { origin: 'https://example.com' } } } },
    reply: (m) => m && m.__egluCall && m.__egluCall.method === 'getCurrent' ? { value: { id: 8 } } : undefined });
  frame.run('chrome.runtime.onMessage').addListener((m, sender, respond) => {
    setTimeout(() => respond(m.empty ? undefined : 'from the frame'), 600);
    return true;
  });
  const worker = world({ background: true, channel: true, prototype: true, page: '/bg.js',
    namespaces: {
      tabs: { sendMessage: async () => undefined, get: async (tabId) => ({ id: tabId, url: 'https://example.com' }) },
      webNavigation: { getAllFrames: async () => [{ frameId: 0, url: 'https://example.com' }, { frameId: 1, url: app }] },
    },
    reply: (m) => m && m.__egluToFrame
      ? frame.chrome.runtime.onMessage.deliver(m, { id, url: 'chrome-extension://' + id + '/bg.js' }) : undefined });
  const answer = await worker.run('chrome.tabs').sendMessage(8, { ask: true });
  check('a framed page\'s native answer is waited for beyond the channel\'s first moment', answer === 'from the frame', String(answer));
  const started = Date.now();
  const empty = await worker.run('chrome.tabs').sendMessage(8, { empty: true });
  check('a framed page\'s empty native answer is waited for too', empty === null && Date.now() - started >= 600,
    String(empty) + ' in ' + (Date.now() - started) + ' ms');
}

// What WebKit lacks, filled in.
{
  const w = world();
  check('Symbol.dispose and asyncDispose are there', w.run('typeof Symbol.dispose === "symbol" && typeof Symbol.asyncDispose === "symbol"'));
  const idle = await new Promise((resolve) => w.run('requestIdleCallback')((deadline) => resolve(deadline)));
  check('requestIdleCallback calls back with time to spare', idle.didTimeout === false && idle.timeRemaining() > 0 && idle.timeRemaining() <= 50);
  let called = false;
  const id = w.run('requestIdleCallback')(() => { called = true; });
  w.run('cancelIdleCallback')(id);
  await tick(10);
  check('cancelIdleCallback cancels', !called);
}

// onMessage, by Chrome's rule.
{
  const w = world();
  const onMessage = w.run('chrome.runtime.onMessage');
  onMessage.addListener(() => undefined);
  onMessage.addListener((message, sender, respond) => { setTimeout(() => respond('later'), 5); return true; });
  check('a later listener that returns true answers', await w.chrome.runtime.onMessage.deliver('ping') === 'later');
}
{
  const w = world();
  const onMessage = w.run('chrome.runtime.onMessage');
  onMessage.addListener(() => undefined);
  onMessage.addListener(async () => 'from a promise');
  check('a later listener that returns a promise answers', await w.chrome.runtime.onMessage.deliver('ping') === 'from a promise');
}
{
  const w = world();
  const onMessage = w.run('chrome.runtime.onMessage');
  onMessage.addListener((message, sender, respond) => { respond('first'); });
  onMessage.addListener((message, sender, respond) => { respond('second'); return true; });
  check('only the first answer counts', await w.chrome.runtime.onMessage.deliver('ping') === 'first');
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { respond(); });
  check('an empty answer is null', await w.chrome.runtime.onMessage.deliver('ping') === null);
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => {
    const answer = { ok: true };
    respond(answer);
    answer.ok = false;
  });
  const reply = await w.chrome.runtime.onMessage.deliver('ping');
  check('an answer goes as it was when given', reply?.ok === true, JSON.stringify(reply));
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { respond({ then: (yes, no) => no(new Error('x')) }); });
  const reply = await w.chrome.runtime.onMessage.deliver('ping').then((r) => r, () => 'rejected');
  check('an answer with a then goes as JSON, not as a promise', reply !== 'rejected' && typeof reply?.then !== 'function', JSON.stringify(reply));
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { const a = {}; a.a = a; respond(a); });
  const reply = await w.chrome.runtime.onMessage.deliver('ping');
  check('an answer that isn\'t JSON fails', typeof reply?.__egluFailed === 'string', JSON.stringify(reply));
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener(() => ({ get then() { throw new Error('getter'); } }));
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { respond('later listener'); });
  const reply = await w.chrome.runtime.onMessage.deliver('ping');
  check('a return whose then throws fails, and the rest still run', reply?.__egluFailed === 'getter', JSON.stringify(reply));
  await tick(5);
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener(async () => {});
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { setTimeout(() => respond('later'), 5); return true; });
  check('an async listener that returns nothing answers null first, as in Chrome 148', await w.chrome.runtime.onMessage.deliver('ping') === null);
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener(async () => { throw new Error('nope'); });
  const reply = await w.chrome.runtime.onMessage.deliver('ping');
  check('a rejection is answered as a failure, not a failed promise', reply?.__egluFailed === 'nope', JSON.stringify(reply));
}
{
  const w = world();
  w.run('chrome.runtime.onMessageExternal').addListener(async () => { throw new Error('nope'); });
  check('to another extension it is null', await w.chrome.runtime.onMessageExternal.deliver('ping') === null);
}
{
  const w = world();
  w.run('chrome.runtime.onMessage').addListener(() => { throw new Error('thrown'); });
  w.run('chrome.runtime.onMessage').addListener((message, sender, respond) => { respond('too late'); });
  const reply = await w.chrome.runtime.onMessage.deliver('ping');
  check('a throw fails it, first', reply?.__egluFailed === 'thrown', JSON.stringify(reply));
  await tick(5);
  check('and is passed on to the error watch', w.native.some((n) => n.message.args[1] === 'thrown'), JSON.stringify(w.native));
}
{
  const w = world();
  const onMessage = w.run('chrome.runtime.onMessage');
  const f = () => undefined;
  onMessage.addListener(f);
  check('hasListener sees the extension\'s listener', onMessage.hasListener(f) && onMessage.hasListeners());
  onMessage.removeListener(f);
  check('removeListener takes it away', !onMessage.hasListener(f));
  check('nobody answering is undefined', await w.chrome.runtime.onMessage.deliver('ping') === undefined);
}

// sendMessage with a callback and no reply: lastError, as in Chrome.
{
  const w = world();
  const seen = await new Promise((resolve) => w.run('chrome.runtime').sendMessage('ping', (reply) => {
    resolve({ reply, error: w.run('chrome.runtime.lastError && chrome.runtime.lastError.message') });
  }));
  check('no reply sets lastError for the callback', seen.reply === undefined && /message port closed/.test(seen.error), JSON.stringify(seen));
  check('lastError is gone after the callback', w.run('chrome.runtime.lastError') === undefined);
}
{
  const w = world({ reply: () => 'pong' });
  const reply = await new Promise((resolve) => w.run('chrome.runtime').sendMessage('ping', resolve));
  check('a reply reaches the callback', reply === 'pong');
  check('without a callback, a promise as before', await w.run('chrome.runtime').sendMessage('ping') === 'pong');
}
{
  const w = world({ reply: () => null });
  const seen = await new Promise((resolve) => w.run('chrome.runtime').sendMessage('ping', (reply) => {
    resolve({ reply, error: w.run('chrome.runtime.lastError') });
  }));
  check('an empty answer sets no lastError', seen.reply === null && seen.error === undefined, JSON.stringify(seen));
}
{
  const w = world({ reply: () => ({ __egluFailed: 'nope' }) });
  const error = await new Promise((resolve) => w.run('chrome.runtime').sendMessage('ping', (reply) => {
    resolve(reply === undefined && w.run('chrome.runtime.lastError.message'));
  }));
  check('a failure is lastError for the callback', error === 'nope', error);
  const rejected = await w.run('chrome.runtime').sendMessage('ping').then(() => 'resolved', (e) => e.message);
  check('and a rejection without one', rejected === 'nope', rejected);
}
{
  const native = { message: 'WebKit\'s own' };
  const w = world({ lastError: native });
  await new Promise((resolve) => w.run('chrome.runtime').sendMessage('ping', resolve));
  check('WebKit\'s own lastError is put back', w.run('chrome.runtime.lastError') === native);
}

// Members and namespaces WebKit leaves out, read at the top of a worker:
// one missing is a TypeError that stops the whole worker. iCloud
// Passwords' worker listens to these webNavigation events as it starts;
// 1Password's to chrome.notifications; both read chrome.privacy.
// What threw is the result, as in WebKit, where it stops the worker.
const attempt = (f) => { try { return f(); } catch (e) { return `${e.name}: ${e.message}`; } };
{
  const onBeforeNavigate = { addListener() {} };
  const w = world({ background: true, namespaces: { webNavigation: { onBeforeNavigate, getAllFrames: async () => [] } } });
  const started = attempt(() => w.run(`(() => {
    chrome.webNavigation.onBeforeNavigate.addListener(() => {});
    chrome.webNavigation.onHistoryStateUpdated.addListener(() => {});
    chrome.webNavigation.onTabReplaced.addListener(() => {});
    return "started";
  })()`));
  check('a worker listening to webNavigation events WebKit lacks gets past them', started === 'started', started);
  check('WebKit\'s own webNavigation members are kept', w.run('chrome.webNavigation.onBeforeNavigate') === onBeforeNavigate);
  check('webNavigation\'s enums are there', attempt(() => w.run('chrome.webNavigation.TransitionType.FORM_SUBMIT')) === 'form_submit'
    && attempt(() => w.run('chrome.webNavigation.TransitionQualifier.FORWARD_BACK')) === 'forward_back');
  check('no webNavigation is made where WebKit gives none', world().run('chrome.webNavigation') === undefined);
}
{
  const executeScript = async () => [];
  const w = world({ background: true, scripting: { executeScript } });
  check('a worker reading scripting\'s enums gets them (Bitwarden)', attempt(() => w.run('chrome.scripting.ExecutionWorld.ISOLATED')) === 'ISOLATED'
    && attempt(() => w.run('chrome.scripting.StyleOrigin.USER')) === 'USER');
}
{
  // WebKit's words for a tab it holds no web view for: one not loaded yet.
  const refused = () => Promise.reject(new Error('Invalid call to webNavigation.getAllFrames(). Tab not found.'));
  const frames = [{ frameId: 0, parentFrameId: -1, url: 'https://example.com/' }];
  const tabs = { sendMessage: async () => undefined, get: async (id) => { if (id === 9) throw new Error('No tab with id: 9.'); return { id }; } };
  // A callback is called with nothing when WebKit refuses, as WebKit does.
  const getAllFrames = ({ tabId }, callback) => {
    const answer = tabId === 1 ? Promise.resolve(frames) : refused();
    if (typeof callback !== 'function') return answer;
    answer.then(callback, () => callback(undefined));
  };
  const w = world({ background: true, namespaces: { tabs, webNavigation: { getAllFrames } } });
  const nav = w.run('chrome.webNavigation');
  check('a loaded tab\'s frames are WebKit\'s', await nav.getAllFrames({ tabId: 1 }) === frames);
  const unloaded = await nav.getAllFrames({ tabId: 2 }).then((list) => list, (e) => e.message);
  check('a tab whose page isn\'t loaded has no frames, not an error', Array.isArray(unloaded) && unloaded.length === 0, unloaded);
  const gone = await nav.getAllFrames({ tabId: 9 }).then(() => 'answered', (e) => e.message);
  check('a tab that isn\'t there is still refused', /Tab not found/.test(gone), gone);
  const byCallback = await new Promise((done) => nav.getAllFrames({ tabId: 2 }, done));
  check('and through a callback', Array.isArray(byCallback) && byCallback.length === 0);
  // iCloud Passwords' start, every tab's frames in turn: it gets past an unloaded one.
  const seen = await w.run(`(async () => {
    const seen = [];
    for (const id of [2, 1]) for (const frame of await chrome.webNavigation.getAllFrames({ tabId: id })) seen.push(id + ":" + frame.frameId);
    return seen.join(",");
  })()`).catch((e) => e.message);
  check('a worker listing every tab\'s frames gets past one not loaded', seen === '1:0', seen);
}
{
  const onChanged = { addListener() {} };
  const w = world({ background: true, namespaces: { storage: { local: {}, onChanged } } });
  const started = attempt(() => w.run('chrome.storage.managed.onChanged.addListener(() => {}), "started"'));
  check('a worker listening to managed storage gets past it', started === 'started', started);
  if (started === 'started') {
    check('managed storage holds nothing', JSON.stringify(await w.run('chrome.storage.managed').get(null)) === '{}');
    check('and says so through a callback', JSON.stringify(await new Promise((done) => w.run('chrome.storage.managed').get(['policy'], done))) === '{}');
    check('asked by name, nothing', JSON.stringify(await w.run('chrome.storage.managed').get('policy')) === '{}');
    const defaults = { enabled: true, server: 'https://example.com' };
    const given = await w.run('chrome.storage.managed').get(defaults);
    check('asked with defaults, the defaults', JSON.stringify(given) === JSON.stringify(defaults) && given !== defaults, JSON.stringify(given));
    const byCallback = await new Promise((done) => w.run('chrome.storage.managed').get(defaults, done));
    check('and through a callback', JSON.stringify(byCallback) === JSON.stringify(defaults), JSON.stringify(byCallback));
  }
  check('WebKit\'s own storage members are kept', w.run('chrome.storage.onChanged') === onChanged);
}
{
  // A .wasm of the extension's own, which WebKit serves untyped: compiled
  // whole. A website's is left to WebKit's streaming.
  const WebAssembly = {
    instantiateStreaming: async () => 'streamed', compileStreaming: async () => 'streamed',
    instantiate: async (bytes) => 'whole ' + bytes.byteLength, compile: async (bytes) => 'whole ' + bytes.byteLength,
  };
  const response = (url) => ({ url, arrayBuffer: async () => new ArrayBuffer(3) });
  const w = world({ background: true, extra: { WebAssembly } });
  w.context.own = response('chrome-extension://abcdefghijklmnopabcdefghijklmnop/core.wasm');
  w.context.site = response('https://example.com/core.wasm');
  check('the extension\'s own .wasm is compiled whole', await w.run('WebAssembly.instantiateStreaming(Promise.resolve(own))') === 'whole 3'
    && await w.run('WebAssembly.compileStreaming(own)') === 'whole 3');
  check('a website\'s is streamed as before', await w.run('WebAssembly.instantiateStreaming(site)') === 'streamed');
}
{
  const w = world({ background: true, permissions: ['privacy'] });
  const saving = attempt(() => w.run('chrome.privacy.services.passwordSavingEnabled'));
  check('a worker gets privacy\'s settings', typeof saving === 'object', saving);
  if (typeof saving === 'object') {
  check('privacy\'s password saving reads as off, and not eGlu\'s to change',
    JSON.stringify(await saving.get({})) === JSON.stringify({ value: false, levelOfControl: 'not_controllable' }));
  const byCallback = await new Promise((done) => saving.get({}, done));
  check('and the same through a callback', byCallback?.value === false);
  const refused = await saving.set({ value: false }).then(() => 'set', (e) => e.message);
  check('a change is refused', /can't be changed/.test(refused), refused);
  const lastError = await new Promise((done) => saving.set({ value: false }, () => done(w.chrome.runtime.lastError?.message)));
  check('as lastError for a callback, there only while it runs', /can't be changed/.test(lastError) && w.chrome.runtime.lastError === undefined);
  check('clearing it is nothing to refuse', await saving.clear({}) === undefined);
  const other = await w.run('chrome.privacy.websites.thirdPartyCookiesAllowed').get({}).then(() => 'answered', (e) => e.message);
  check('a setting eGlu has no word on says so rather than make one up', /isn't available/.test(other), other);
  // iCloud Passwords' settings, as its worker and popup start.
  const ran = w.run(`(async () => {
    const s = chrome.privacy.services;
    s.passwordSavingEnabled && s.passwordSavingEnabled.onChange.addListener(() => {});
    s.autofillCreditCardEnabled && s.autofillCreditCardEnabled.onChange.addListener(() => {});
    chrome.privacy.network.webRTCIPHandlingPolicy.onChange.addListener(() => {});
    const got = await s.autofillAddressEnabled.get({});
    return got.levelOfControl === "not_controllable" ? "left alone" : "set";
  })()`);
  check('a password manager reading privacy settings gets past them', await ran === 'left alone');
  }
  check('no privacy namespace without its permission', world({ background: true }).run('chrome.privacy') === undefined);
  const own = { services: {} };
  check('WebKit\'s own privacy, if it has one, is kept', world({ permissions: ['privacy'], namespaces: { privacy: own } }).run('chrome.privacy') === own);
}
{
  const w = world({ background: true, permissions: ['notifications'] });
  const started = attempt(() => w.run(`(() => {
    chrome.notifications.onClicked.addListener(() => {});
    chrome.notifications.onButtonClicked.addListener(() => {});
    chrome.notifications.onClosed.addListener(() => {});
    return "started";
  })()`));
  check('a worker listening to notifications gets past them', started === 'started', started);
  if (started === 'started') {
  check('a notification asked for is given the id it named', await w.run('chrome.notifications').create('saved', { type: 'basic', title: 't', message: 'm' }) === 'saved');
  const made = await new Promise((done) => w.run('chrome.notifications').create({ type: 'basic', title: 't', message: 'm' }, done));
  check('or one of its own, through a callback', typeof made === 'string' && made.length > 0, made);
  check('the permission level reads denied', await w.run('chrome.notifications').getPermissionLevel() === 'denied');
  check('notifications ask eGlu nothing', !w.native.some((n) => String(n.message?.api).startsWith('notifications')));
  }
  check('no notifications namespace without its permission', world({ background: true }).run('chrome.notifications') === undefined);
}

// Search's list of members WebKit leaves out.
{
  const content = world({ protocol: 'https:' });
  check('a content script reads runtime\'s enums (GPTZero)', content.run('chrome.runtime.OnInstalledReason.INSTALL') === 'install'
    && content.run('chrome.runtime.PlatformOs.MAC') === 'mac');
  const w = world({ background: true, namespaces: { windows: { getCurrent: async () => ({}) }, declarativeNetRequest: { updateDynamicRules: async () => {} } } });
  check('a worker listens to windows.onBoundsChanged (Session Buddy)', attempt(() => { w.run('chrome.windows.onBoundsChanged.addListener(() => {})'); return 'ok'; }) === 'ok');
  check('windows\' enums are there', w.run('chrome.windows.WindowState.MAXIMIZED') === 'maximized' && w.run('chrome.windows.CreateType.POPUP') === 'popup');
  const refused = await w.run('chrome.declarativeNetRequest').updateStaticRules({ rulesetId: 'a', disableRuleIds: [1] }).then(() => 'done', (e) => e.message);
  check('what eGlu doesn\'t do is refused, not answered as done', /isn't available in eGlu/.test(refused), refused);
  check('declarativeNetRequest\'s constants are there', w.run('chrome.declarativeNetRequest.RuleActionType.UPGRADE_SCHEME') === 'upgradeScheme'
    && w.run('chrome.declarativeNetRequest.ResourceType.XMLHTTPREQUEST') === 'xmlhttprequest');
  check('tabs\' zoom reads as Chrome\'s default', (await w.run('chrome.tabs').getZoomSettings()).mode === 'automatic');
  const asked = [];
  const t = world({ background: true, namespaces: { tabs: { sendMessage: async () => undefined, query: async (q) => { asked.push(q); return [{ id: 1 }]; } } } });
  await t.run('chrome.tabs').getAllInWindow(7);
  await t.run('chrome.tabs').getSelected(7);
  await t.run('chrome.tabs').getAllInWindow();
  check('the old tab getters ask for the window named', JSON.stringify(asked) === '[{"windowId":7},{"active":true,"windowId":7},{"currentWindow":true}]', JSON.stringify(asked));
}

// Tabs as Chrome describes them: an extension with "tabs" sees addresses WebKit blanks (Search).
{
  const blank = (id, index) => ({ id, index, windowId: 1, url: '', title: '' });
  const tabsEvents = { onCreated: null, onUpdated: null };
  const event = () => { const l = []; return { l, addListener: (f) => l.push(f), removeListener: (f) => l.splice(l.indexOf(f), 1), hasListener: (f) => l.includes(f) }; };
  const updated = event(), created = event();
  // Where each tab is now, as WebKit's tabs.get says.
  const now = { 5: blank(5, 0), 6: blank(6, 1), 7: { id: 7, index: 2, windowId: 1 }, 8: blank(8, 4) };
  const w = world({ background: true, permissions: ['tabs'], namespaces: { tabs: {
      sendMessage: async () => undefined, get: async (id) => now[id],
      query: async () => [blank(5, 0), blank(6, 1), { id: 7, index: 2, windowId: 1, url: 'https://kept.example/', title: 'Kept' }, blank(8, 3)],
      onUpdated: updated, onCreated: created,
    }, windows: { getAll: async () => [{ id: 1, tabs: [blank(5, 0)] }] } },
    nativeReply: (m) => ({ value: m.api === 'tabs.describe' ? m.args[0].map((i) => ({ url: 'https://site' + i + '.example/', title: 'Site ' + i })) : null }) });
  const found = await w.run('chrome.tabs').query({});
  check('a blank tab gets its address and title', found[0].url === 'https://site0.example/' && found[1].title === 'Site 1' && found[2].url === 'https://kept.example/',
    JSON.stringify(found));
  check('a tab that has moved since is left as WebKit gave it', found[3].url === '', JSON.stringify(found[3]));
  check('every tab has groupId -1', found.every((t) => t.groupId === -1));
  const asked = w.native.filter((n) => n.message.api === 'tabs.describe').map((n) => n.message.args[0]);
  check('tabs without an address or an icon are asked about, by place', JSON.stringify(asked) === '[[0,1,2,3]]', JSON.stringify(asked));
  const windows = await w.run('chrome.windows').getAll({ populate: true });
  check('a window\'s tabs are filled too', windows[0].tabs[0].url === 'https://site0.example/');
  const heard = [];
  w.run('chrome.tabs').onUpdated.addListener((id, info, tab) => heard.push(info.url + ' ' + tab.url));
  updated.l[0](5, { status: 'loading', url: '' }, blank(5, 0));
  await tick(); await tick();
  check('onUpdated\'s blanked address is filled', heard[0] === 'https://site0.example/ https://site0.example/', JSON.stringify(heard));
  const popupTab = { id: 9, index: 0, windowId: 2, url: '', title: '' };
  const inPopup = world({ background: true, permissions: ['tabs'], namespaces: { tabs: { sendMessage: async () => undefined, query: async () => [popupTab], get: async () => popupTab },
    windows: { getAll: async (q) => q && q.windowTypes ? [{ id: 1, type: 'normal' }] : [{ id: 1 }, { id: 2 }] } },
    nativeReply: (m) => ({ value: m.api === 'tabs.describe' ? [{ url: 'https://wrong.example/' }] : null }) });
  const popupSeen = await inPopup.run('chrome.tabs').query({});
  check('a popup window\'s tab isn\'t described by the space\'s place', popupSeen[0].url === '' && !inPopup.native.some((n) => n.message.api === 'tabs.describe'));
  const panelAsk = world({ background: true, namespaces: { tabs: { sendMessage: async () => undefined, get: async () => popupTab },
    windows: { getAll: async () => [{ id: 1, type: 'normal' }] } } });
  const refusedPanel = await panelAsk.run('chrome.sidePanel').setOptions({ tabId: 9, path: 'p.html' }).then(() => 'set', (e) => e.message);
  check('a popup window\'s tab gets no side panel', /No tab with id: 9/.test(refusedPanel) && !panelAsk.native.some((n) => n.message.api === 'sidePanel.setOptions'), refusedPanel);
  // A listener that waits for a later event doesn't hold that event back.
  let loaded;
  const waitedFor = new Promise((resolve) => { loaded = resolve; });
  let waited = false;
  w.run('chrome.tabs').onCreated.addListener(async () => { await waitedFor; waited = true; });
  w.run('chrome.tabs').onUpdated.addListener((id, info) => { if (info.status === 'complete') loaded(); });
  created.l[0](blank(6, 1));
  updated.l[0](6, { status: 'complete' }, blank(6, 1));
  updated.l[1](6, { status: 'complete' }, blank(6, 1));
  for (let i = 0; i < 6; i++) await tick();
  check('an async listener waiting for a later event gets it', waited === true);
  const plain = world({ background: true, namespaces: { tabs: { sendMessage: async () => undefined, query: async () => [blank(5, 0)] } } });
  const unseen = await plain.run('chrome.tabs').query({});
  check('without "tabs" nothing is filled and nothing asked', unseen[0].url === '' && !plain.native.some((n) => n.message.api === 'tabs.describe'));
}

// A permissions.request WebKit refuses for want of a click is asked of eGlu (Search).
{
  const w = world({ background: true, namespaces: { permissions: { request: async () => { throw new Error('Must be called during a user gesture.'); } } },
    nativeReply: (m) => ({ value: m.api === 'permissions.afterClick' ? true : null }) });
  const granted = await w.run('chrome.permissions').request({ permissions: ['bookmarks'], origins: ['https://figma.com/*'] });
  const sent = w.native.find((n) => n.message.api === 'permissions.afterClick');
  check('a refused request for want of a click is asked of eGlu', granted === true
    && JSON.stringify(sent?.message.args) === '[["bookmarks"],["https://figma.com/*"]]', JSON.stringify(sent?.message));
  const other = world({ background: true, namespaces: { permissions: { request: async () => { throw new Error('Unknown permission'); } } } });
  const refused = await other.run('chrome.permissions').request({ permissions: ['x'] }).then(() => 'granted', (e) => e.message);
  check('any other refusal stays WebKit\'s', refused === 'Unknown permission' && !other.native.some((n) => n.message.api === 'permissions.afterClick'));
}

// chrome.userScripts through WebKit's registered content scripts (Search).
{
  const registered = [];
  let saved = [];
  // eGlu's list, changed in one go as ExtensionAnswers does (userScripts.change).
  const change = ({ add = [], update = [], remove = [] }) => {
    let next = saved.slice();
    for (const a of add) { if (next.some((s) => s.id === a.id)) return { error: "Duplicate script id '" + a.id + "'" }; next.push(a); }
    for (const u of update) { const at = next.findIndex((s) => s.id === u.id); if (at < 0) return { error: 'missing' }; next[at] = { ...next[at], ...u }; }
    next = next.filter((s) => !remove.includes(s.id));
    saved = next;
    return { value: next };
  };
  const scripting = {
    // WebKit's own: refuses a pattern it can't read.
    registerContentScripts: async (scripts) => {
      for (const s of scripts) if (registered.some((r) => r.id === s.id)) throw new Error('Duplicate');
      if (scripts.some((s) => s.matches.includes('bad'))) throw new Error('Invalid match pattern');
      registered.push(...scripts);
    },
    unregisterContentScripts: async (filter) => { for (const id of filter.ids) { const at = registered.findIndex((r) => r.id === id); if (at >= 0) registered.splice(at, 1); } },
    getRegisteredContentScripts: async () => registered.slice(),
    executeScript: async (details) => [{ result: details.files[0] }],
  };
  const answers = (m) => m.api === 'userScripts.change' ? change(m.args[0])
    : { value: m.api === 'userScripts.file' ? '_eglu/us-' + m.args[0].id + '-' + m.args[0].js.map((j) => j.code).join('') + '.js' : m.api === 'userScripts.list' ? saved : null };
  // WebKit's onConnect, one entry for each listener.
  const onConnect = { l: new Set(), addListener(f) { this.l.add(f); }, removeListener(f) { this.l.delete(f); }, hasListener(f) { return this.l.has(f); } };
  const w = world({ background: true, permissions: ['userScripts', 'scripting'], namespaces: { scripting }, nativeReply: answers, runtimeExtra: { onConnect } });
  await tick();
  const us = w.run('chrome.userScripts');
  check('userScripts is there for an extension that asks', typeof us?.register === 'function' && us.ExecutionWorld.USER_SCRIPT === 'USER_SCRIPT');
  await us.register([{ id: 'one', matches: ['https://example.com/*'], js: [{ code: 'x()' }], world: 'USER_SCRIPT' }]);
  check('a user script is registered as a content script from its file', registered.length === 1 && registered[0].id === 'eglu-us-one'
    && registered[0].js[0] === '_eglu/us-one-x().js' && registered[0].world === 'ISOLATED', JSON.stringify(registered));
  check('and kept by eGlu', saved.length === 1 && saved[0].id === 'one');
  const again = await us.register([{ id: 'one', matches: ['*://*/*'], js: [{ code: 'y()' }] }]).then(() => 'registered', (e) => e.message);
  check('a second script under the same id is refused', /Duplicate script id/.test(again) && registered.length === 1, again);
  check('getScripts lists them', JSON.stringify((await us.getScripts()).map((s) => s.id)) === '["one"]');
  const refused = await us.update([{ id: 'one', matches: ['bad'], js: [{ code: 'z()' }] }]).then(() => 'updated', (e) => e.message);
  check('an update WebKit refuses leaves the script as it was', /Invalid match pattern/.test(refused) && registered.length === 1
    && registered[0].js[0] === '_eglu/us-one-x().js' && saved[0].js[0].code === 'x()', JSON.stringify([refused, registered, saved]));
  await us.update([{ id: 'one', js: [{ code: 'w()' }] }]);
  check('an update takes the old one\'s place', registered.length === 1 && registered[0].js[0] === '_eglu/us-one-w().js' && saved[0].js[0].code === 'w()');
  await Promise.all([us.register([{ id: 'two', js: [{ code: 'a()' }] }]), us.register([{ id: 'three', js: [{ code: 'b()' }] }])]);
  check('two registered at once are both kept', JSON.stringify(saved.map((s) => s.id)) === '["one","two","three"]', JSON.stringify(saved.map((s) => s.id)));
  // The worker's start registered it from the list before the page could.
  const realRegister = scripting.registerContentScripts;
  scripting.registerContentScripts = async (scripts) => { registered.push(...scripts); throw new Error('Duplicate script id'); };
  await us.register([{ id: 'four', js: [{ code: 'c()' }] }]);
  scripting.registerContentScripts = realRegister;
  check('a script the worker registered first stays in the list', saved.some((s) => s.id === 'four'), JSON.stringify(saved.map((s) => s.id)));
  await us.unregister();
  check('unregister takes it away', registered.length === 0 && saved.length === 0);
  const heard = [];
  w.run('chrome.runtime').onUserScriptMessage.addListener((m, sender, respond) => { heard.push(m); respond('ok'); });
  const own = { id: w.chrome.runtime.id, url: 'https://example.com/', tab: { id: 3 } };
  const reply = await w.chrome.runtime.onMessage.deliver({ __egluUserScript: true, message: { hi: 1 } }, own);
  check('a user script\'s message reaches onUserScriptMessage', JSON.stringify(heard) === '[{"hi":1}]' && reply === 'ok', JSON.stringify([heard, reply]));
  await w.chrome.runtime.onMessage.deliver({ __egluUserScript: true, message: { hi: 2 } }, { id: 'another', url: 'https://example.com/' });
  check('another extension\'s is not heard', heard.length === 1);
  const page = world({ permissions: ['userScripts', 'scripting'], namespaces: { scripting }, nativeReply: answers });
  const pageHeard = [];
  page.run('chrome.runtime').onUserScriptMessage.addListener((m) => { pageHeard.push(m); });
  await page.chrome.runtime.onMessage.deliver({ __egluUserScript: true, message: { hi: 3 } }, { id: page.chrome.runtime.id, url: 'https://example.com/', tab: { id: 3 } });
  check('a page listening only for user scripts hears them', JSON.stringify(pageHeard) === '[{"hi":3}]', JSON.stringify(pageHeard));
  const connect = w.run('chrome.runtime').onConnect;
  const listener = () => {};
  const before = onConnect.l.size;
  connect.addListener(listener);
  connect.addListener(listener);
  const known = connect.hasListener(listener) && onConnect.l.size === before + 1;
  connect.removeListener(listener);
  check('an onConnect listener is one listener, by its own name', known && !connect.hasListener(listener) && onConnect.l.size === before);
  check('no userScripts without its permission', world({ background: true, namespaces: { scripting: { registerContentScripts: async () => {} } } }).run('chrome.userScripts') === undefined);
}

// chrome.identity: an extension's sign-in through its provider's page (Search).
{
  check('no identity namespace without its permission', world({ background: true }).run('chrome.identity') === undefined);
  const w = world({ background: true, permissions: ['identity'], nativeReply: (m) => ({ value: m.api === 'identity.launchWebAuthFlow' ? 'https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/cb?code=1' : null }) });
  const identity = w.run('chrome.identity');
  check('the redirect address is the extension\'s own chromiumapp.org', identity.getRedirectURL('/cb') === 'https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/cb'
    && identity.getRedirectURL() === 'https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/');
  const answer = await identity.launchWebAuthFlow({ url: 'https://provider.example/auth', interactive: true });
  const sent = w.native.find((n) => n.message.api === 'identity.launchWebAuthFlow');
  check('a sign-in is asked of eGlu with what the extension gave', answer.endsWith('code=1') && sent?.message.args[0].interactive === true
    && sent?.message.args[0].url === 'https://provider.example/auth', JSON.stringify(sent?.message));
  const viaCallback = await new Promise((resolve) => identity.launchWebAuthFlow({ url: 'https://provider.example/auth' }, resolve));
  check('a sign-in answers a callback too', typeof viaCallback === 'string' && viaCallback.endsWith('code=1'));
  const token = await identity.getAuthToken({ interactive: true }).then(() => 'given', (e) => e.message);
  check('Chrome\'s Google sign-in is refused', /Google account/.test(token), token);
  check('no profile is signed in', JSON.stringify(await identity.getProfileUserInfo()) === '{"email":"","id":""}');
}

// declarativeNetRequest rules put the way WebKit takes them (Search).
{
  const rules = { dynamic: [], session: [] };
  const added = [];
  // WebKit's own: refuses a rule it can't read by index, as WebKit says it.
  const updater = (kind) => async (options = {}) => {
    const adding = options.addRules || [];
    const bad = adding.findIndex((r) => r.action?.type === 'modifyHeaders' && r.action.requestHeaders?.[0]?.header === 'x-unknown');
    if (bad >= 0) throw new Error(`Rule with id ${adding[bad].id} is invalid: rule at index ${bad} can't be read`);
    added.push(adding);
    const gone = new Set(options.removeRuleIds || []);
    rules[kind] = rules[kind].filter((r) => !gone.has(r.id)).concat(adding);
  };
  const w = world({ background: true, namespaces: { declarativeNetRequest: {
    updateDynamicRules: updater('dynamic'), updateSessionRules: updater('session'),
    getDynamicRules: async () => rules.dynamic.slice(), getSessionRules: async () => rules.session.slice(),
    isRegexSupported: async () => undefined,
  } } });
  const dnr = w.run('chrome.declarativeNetRequest');
  const userJS = { id: 5, priority: 1, action: { type: 'redirect', redirect: { url: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/install.html' } },
    condition: { regexFilter: '^https?://(?:www\\.)?example\\.(?:com|org)/.*\\.user\\.js$', resourceTypes: ['main_frame'] } };
  await dnr.updateDynamicRules({ addRules: [userJS] });
  const made = rules.dynamic;
  const matches = (url) => made.some((r) => new RegExp(r.condition.regexFilter).test(url));
  check('a pattern with | and (?: becomes rules WebKit can read (Tampermonkey)', made.length === 2
    && made.every((r) => !/\||\(\?:/.test(r.condition.regexFilter)), JSON.stringify(made.map((r) => r.condition.regexFilter)));
  check('the rules made match what the pattern matched, and no more', matches('https://www.example.org/a.user.js') && matches('http://example.com/b.user.js')
    && !matches('https://example.net/a.user.js') && !matches('https://www.example.com/a.js'));
  check('a redirect to its own file goes by path', made.every((r) => r.action.redirect.extensionPath === '/install.html' && !r.action.redirect.url));
  check('the extension sees its own rule, not those made of it', JSON.stringify((await dnr.getDynamicRules()).map((r) => r.id)) === '[5]');
  const got = (await dnr.getDynamicRules())[0];
  const gotMatches = (url) => new RegExp(got.condition.regexFilter).test(url);
  check('its rule read back matches all it matched', gotMatches('https://www.example.org/a.user.js') && gotMatches('http://example.com/b.user.js')
    && !gotMatches('https://example.net/a.user.js'), got.condition.regexFilter);
  await dnr.updateDynamicRules({ removeRuleIds: [5] });
  check('taking its rule away takes those made of it', rules.dynamic.length === 0, JSON.stringify(rules.dynamic.map((r) => r.id)));
  await dnr.updateDynamicRules({ addRules: [got] });
  check('and the rule read back goes in as the same rules', rules.dynamic.length === 2 && matches('https://www.example.org/a.user.js') && matches('http://example.com/b.user.js'),
    JSON.stringify(rules.dynamic.map((r) => r.condition.regexFilter)));
  await dnr.updateDynamicRules({ removeRuleIds: [5] });
  const first = { id: 1, action: { type: 'block' }, condition: { urlFilter: 'a' } };
  const high = { id: 1000000033, action: { type: 'block' }, condition: { urlFilter: 'b' } };
  await dnr.updateDynamicRules({ addRules: [first, high] });
  check('an extension\'s own rule with an id like a made one is its own', JSON.stringify((await dnr.getDynamicRules()).map((r) => r.id)) === '[1,1000000033]');
  await dnr.updateDynamicRules({ removeRuleIds: [1] });
  check('and stays when the other goes', JSON.stringify(rules.dynamic.map((r) => r.id)) === '[1000000033]');
  await dnr.updateDynamicRules({ removeRuleIds: [1000000033] });

  const everywhere = { id: 7, action: { type: 'redirect', redirect: { extensionPath: '/strictblock.html' } },
    condition: { regexFilter: '^https?://.*', requestDomains: ['bad.example'], resourceTypes: ['main_frame'] } };
  const blocked = { id: 8, action: { type: 'block' }, condition: { regexFilter: '^https?://.*', requestDomains: ['bad.example'] } };
  await dnr.updateSessionRules({ addRules: [everywhere, blocked] });
  check('a redirect WebKit would carry out on every site is left out (uBlock Origin Lite)', JSON.stringify(rules.session.map((r) => r.id)) === '[8]',
    JSON.stringify(rules.session.map((r) => r.id)));

  const unknownHeader = { id: 10, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'x-unknown', operation: 'set', value: '1' }] }, condition: { urlFilter: 'a' } };
  const plain = { id: 11, action: { type: 'block' }, condition: { urlFilter: 'ads' } };
  const done = await dnr.updateDynamicRules({ addRules: [unknownHeader, plain] }).then(() => 'done', (e) => e.message);
  check('a rule WebKit refuses is left out, the others go in', done === 'done' && JSON.stringify(rules.dynamic.map((r) => r.id)) === '[11]', done);
  const unknownType = { id: 12, action: { type: 'block' }, condition: { urlFilter: 'x', resourceTypes: ['webtransport'] } };
  await dnr.updateDynamicRules({ addRules: [unknownType] });
  check('a rule only for types WebKit has no name for is left out', !rules.dynamic.some((r) => r.id === 12));
  const supported = await dnr.isRegexSupported({ regex: '(' });
  check('isRegexSupported always answers', supported && supported.isSupported === false, JSON.stringify(supported));
  const called = await new Promise((resolve) => dnr.getDynamicRules((r) => resolve(r)));
  check('the rules are read with a callback too', Array.isArray(called) && called.length === 1);
}

// Small differences from Chrome's: menus, storage, groupId.
{
  const made = [], stored = [];
  const onUpdated = { listeners: null, list: [], addListener(f) { this.list.push(f); }, removeListener(f) { this.list = this.list.filter((g) => g !== f); }, hasListener(f) { return this.list.includes(f); } };
  delete onUpdated.listeners;
  const w = world({ background: true, namespaces: {
    contextMenus: { create: (props) => { made.push(props); return 1; }, update: () => {} },
    storage: { local: { set: async (items) => { if (Object.getPrototypeOf(items) === null) throw new Error('Object expected'); stored.push(items); } } },
    tabs: { sendMessage: async () => undefined, query: async () => [{ id: 1, index: 0 }, { id: 2, index: 1, groupId: 7 }], get: async (id) => ({ id, index: 0 }), onUpdated },
  } });
  w.run('chrome.contextMenus').create({ id: 'a', contexts: ['browser_action', 'launcher', 'page'] });
  check('a menu item for the old button goes in the button\'s menu, none for a launcher', JSON.stringify(made[0].contexts) === '["action","page"]', JSON.stringify(made[0]));
  const bare = await w.run('(async () => { const o = Object.create(null); o.a = 1; await chrome.storage.local.set(o); return "set"; })()').catch((e) => e.message);
  check('an item with no prototype is stored', bare === 'set' && stored[0].a === 1, bare);
  const tabs = await w.run('chrome.tabs').query({});
  check('every tab has a groupId, -1 in no group', tabs[0].groupId === -1 && tabs[1].groupId === 7);
  const seen = [];
  w.run('chrome.tabs').onUpdated.addListener((id, change, tab) => seen.push(tab.groupId));
  onUpdated.list[0](1, {}, { id: 1, index: 0 });
  check('and the tab an event hands its listener too', seen[0] === -1);
}

// Ports between the extension's own ends: WebKit hands a message on twice
// (seen on 27.0.1); numbered, it is heard once. The popup's port comes with
// no tab (Passbolt).
{
  const ev = () => { const list = []; return { list, addListener(f) { list.push(f); }, removeListener(f) { const i = list.indexOf(f); if (i >= 0) list.splice(i, 1); }, hasListener(f) { return list.includes(f); } }; };
  const own = 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/';
  const pair = (sender) => {
    const a = { name: 'popup', onMessage: ev(), onDisconnect: ev() }, b = { name: 'popup', onMessage: ev(), onDisconnect: ev(), sender };
    // Every message twice, as WebKit delivers it once per world.
    a.postMessage = (m) => { for (let i = 0; i < 2; i++) for (const f of [...b.onMessage.list]) f(m, b); };
    b.postMessage = (m) => { for (let i = 0; i < 2; i++) for (const f of [...a.onMessage.list]) f(m, a); };
    return [a, b];
  };
  const popupSender = { id: 'abcdefghijklmnopabcdefghijklmnop', url: own + 'popup.html', frameId: 0, tab: { id: 5, index: NaN, url: own + 'popup.html' } };
  const [a, b] = pair(popupSender);
  const onConnect = ev();
  const page = world({ runtimeExtra: { connect: () => a, onConnect: ev() } });
  const worker = world({ worker: true, runtimeExtra: { connect: () => ({}), onConnect } });
  const workerHeard = [], pageHeard = [];
  let seenSender = null;
  worker.run('chrome.runtime').onConnect.addListener((port) => {
    seenSender = port.sender;
    port.onMessage.addListener((m) => { workerHeard.push(m); port.postMessage({ reply: m }); });
  });
  const port = page.run('chrome.runtime').connect({ name: 'popup' });
  port.onMessage.addListener((m) => pageHeard.push(m));
  for (const f of [...onConnect.list]) f(b);
  port.postMessage('state?');
  check('a message between the extension\'s own ends is heard once', JSON.stringify(workerHeard) === '["state?"]', JSON.stringify(workerHeard));
  check('and its answer once', JSON.stringify(pageHeard) === '[{"reply":"state?"}]', JSON.stringify(pageHeard));
  check('the popup\'s port comes with no tab, as in Chrome', seenSender && seenSender.url === popupSender.url && !('tab' in seenSender), JSON.stringify(seenSender));
  // A content script's port is the website's: left as it is.
  const site = { id: 'abcdefghijklmnopabcdefghijklmnop', url: 'https://example.com/', frameId: 0, tab: { id: 6, index: 0, url: 'https://example.com/' } };
  const plain = { name: 'cs', sender: site, onMessage: ev(), onDisconnect: ev(), postMessage: (m) => { plain.sent = m; } };
  let csPort = null;
  worker.run('chrome.runtime').onConnect.addListener((p) => { if (p.name === 'cs') { csPort = p; p.postMessage('hi'); } });
  for (const f of [...onConnect.list]) f(plain);
  check('a content script\'s port goes as it is', csPort === plain && plain.sent === 'hi' && plain.sender.tab.id === 6);
}

// chrome.idle and chrome.power, the Mac's (ExtensionAnswers).
{
  const ticks = [];
  const w = world({ background: true, permissions: ['idle', 'power'], extra: { setInterval: (f, ms) => { ticks.push(ms); return 1; } },
    nativeReply: (m) => ({ value: m.api === 'idle.queryState' ? 'locked' : null }) });
  check('idle asks the Mac', await w.run('chrome.idle').queryState(60) === 'locked'
    && w.native.some((n) => n.message.api === 'idle.queryState' && n.message.args[0] === 60));
  check('idle\'s state and event are there', w.run('chrome.idle.IdleState.LOCKED') === 'locked'
    && attempt(() => { w.run('chrome.idle.onStateChanged.addListener(() => {})'); return 'ok'; }) === 'ok' && ticks[0] === 15000);
  await w.run('chrome.power').requestKeepAwake('display');
  check('power asks the Mac', w.native.some((n) => n.message.api === 'power.requestKeepAwake' && n.message.args[0] === 'display'));
  const stopped = [];
  const v = world({ background: true, permissions: ['idle'], extra: { setInterval: () => 7, clearInterval: (t) => stopped.push(t) } });
  const f = () => {};
  v.run('chrome.idle').onStateChanged.addListener(f);
  v.run('chrome.idle').onStateChanged.removeListener(f);
  check('idle stops asking once nobody listens', JSON.stringify(stopped) === '[7]', JSON.stringify(stopped));
  check('no idle or power without their permissions', world({ background: true }).run('chrome.idle') === undefined && world({ background: true }).run('chrome.power') === undefined);
}
// The popup: no current tab, and among the popup views, as in Chrome. Which
// pane shows a page eGlu says (surface.kind); a side panel has no current
// tab either, but isn't a popup, and a popup's page in a tab is a tab.
{
  const unindexed = { id: 9, index: NaN, url: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html' };
  const open = (page, kind, current) => world({ page, extra: { document: {} }, manifestExtra: { action: { default_popup: 'popup.html' } },
    nativeReply: (m) => ({ value: m.api === 'surface.kind' ? kind : null }),
    namespaces: { tabs: { sendMessage: async () => undefined, getCurrent: async () => current, get: async (id) => ({ id }) },
      extension: { getViews: () => [] }, windows: { getCurrent: async () => ({ id: 7 }) } } });
  const popup = open('/popup.html', 'popup', unindexed);
  check('the manifest\'s popup page is a popup view from its first line', popup.run('chrome.extension.getViews({ type: "popup" }).length') === 1);
  check('but not one asked for by another window or a tab', popup.run('chrome.extension.getViews({ type: "popup", windowId: 123456 }).length') === 0
    && popup.run('chrome.extension.getViews({ tabId: 4 }).length') === 0 && popup.run('chrome.extension.getViews({ windowId: -2 }).length') === 1);
  check('the popup has no current tab', await popup.run('chrome.tabs').getCurrent() === undefined);
  check('and is a view of its own window by its id', popup.run('chrome.extension.getViews({ type: "popup", windowId: 7 }).length') === 1);
  await tick();
  check('and is among the popup views', popup.run('chrome.extension.getViews({ type: "popup" }).length') === 1
    && popup.run('chrome.extension.getViews({ type: "tab" }).length') === 0);
  const panel = open('/panel.html', 'sidePanel', unindexed);
  await tick();
  check('a side panel has no current tab, and isn\'t a popup', await panel.run('chrome.tabs').getCurrent() === undefined
    && panel.run('chrome.extension.getViews({ type: "popup" }).length') === 0);
  const inTab = open('/popup.html', 'popup', { id: 3, index: 2 });
  await tick();
  check('the popup\'s page in a tab of the row is no popup, whatever eGlu would say of its address', inTab.run('chrome.extension.getViews({ type: "popup" }).length') === 0
    && !inTab.native.some((n) => n.message.api === 'surface.kind')
    && (await inTab.run('chrome.tabs').getCurrent()).id === 3);
}

// runtime.getPlatformInfo applied to no object (Vimium C): applied to runtime.
{
  const w = world({ background: true });
  // WebKit's function reads as native code; a Proxy does too.
  check('getPlatformInfo applied to nothing is applied to runtime', w.run(`(() => { let got; new Proxy(function getPlatformInfo(cb) { cb(this === chrome.runtime); }, {}).apply(0, [(r) => { got = r; }]); return got; })()`) === true);
  check('the extension\'s own getPlatformInfo applied as it was', w.run(`(() => { let got; (function getPlatformInfo(cb) { cb(this === chrome.runtime); }).apply(0, [(r) => { got = r; }]); return got; })()`) === false);
  check('any other function applied as it was', w.run(`(function other() { return this === undefined || this === globalThis; }).apply(null, [])`) === true);
}

// A function to inject, from the extension's page in a website's frame:
// written as a file of its own (scripting.file) and injected by path.
{
  const injected = [];
  const w = world({ background: true, scripting: { executeScript: async (details) => { injected.push(details); return [{ result: 3 }]; } },
    nativeReply: (m) => ({ value: m.api === 'scripting.file' ? '_eglu/script-ab.js' : null }) });
  const own = { id: w.chrome.runtime.id, url: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/frame.html', tab: { id: 4 } };
  const call = { __egluCall: { space: 'scripting', method: 'executeScript', args: [{ target: { tabId: 4 }, __egluFunction: '(a, b) => a + b', args: [1, 2] }] } };
  const reply = await w.chrome.runtime.onMessage.deliver(call, own);
  const asked = w.native.find((n) => n.message.api === 'scripting.file');
  check('a frame page\'s function goes to eGlu as source and arguments', asked && asked.message.args[0] === '(a, b) => a + b' && JSON.stringify(asked.message.args[1]) === '[1,2]');
  check('and is injected from the file eGlu wrote, the shim in front', injected[0] && JSON.stringify(injected[0].files) === '["_eglu/shim.js","_eglu/script-ab.js"]'
    && injected[0].target.tabId === 4 && !('func' in injected[0]), JSON.stringify(injected));
  check('its result comes back', JSON.stringify(reply && reply.value) === '[{"result":3}]', JSON.stringify(reply));
  const site = { id: w.chrome.runtime.id, url: 'https://example.com/', tab: { id: 4 } };
  const denied = await w.chrome.runtime.onMessage.deliver(call, site);
  check('a content script gets no injection', denied && /isn't available to content scripts/.test(denied.error) && injected.length === 1);
}

// A worker's listeners, held from its first moment (ExtensionPreparation's
// event list). WebKit's stand-in events here: one that refuses a listener
// as too late once told to, and keeps the filter it was given.
{
  const webkitEvent = () => {
    const listeners = [];
    return {
      started: false, filters: [],
      addListener(f, filter) { if (this.started) throw new Error('Invalid call to runtime.onConnect.addListener(). Listeners must be added during startup.'); listeners.push(f); this.filters.push(filter); },
      removeListener(f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
      hasListener(f) { return listeners.includes(f); },
      fire(...args) { for (const f of [...listeners]) f(...args); },
      count() { return listeners.length; },
    };
  };
  const port = () => ({ disconnected: false, disconnect() { this.disconnected = true; } });
  {
    const onConnect = webkitEvent();
    const w = world({ worker: true, runtimeExtra: { onConnect }, events: ['runtime.onConnect'] });
    check('a named event has WebKit\'s listener from the first moment', onConnect.count() === 1);
    const early = port();
    onConnect.fire(early);
    check('a port with nobody listening is closed, as in Chrome', early.disconnected);
    const heard = [];
    w.run('chrome.runtime').onConnect.addListener((p) => heard.push(p));
    const later = port();
    onConnect.fire(later);
    check('a port with a listener is heard, and left open', heard[0] === later && !later.disconnected);
    onConnect.started = true;
    const late = [];
    const added = attempt(() => { w.run('chrome.runtime').onConnect.addListener((p) => late.push(p)); return 'added'; });
    check('a listener WebKit refuses as too late is taken', added === 'added', added);
    const third = port();
    onConnect.fire(third);
    check('and hears what comes after', late[0] === third && heard[1] === third);
  }
  {
    const onCompleted = webkitEvent();
    const w = world({ worker: true, namespaces: { webNavigation: { onCompleted, getAllFrames: async () => [] } }, events: [] });
    const filter = { url: [{ hostSuffix: 'example.com' }] };
    w.run('chrome.webNavigation').onCompleted.addListener(() => {}, filter);
    check('a listener\'s filter stays WebKit\'s', onCompleted.filters.includes(filter) && onCompleted.count() === 1);
    onCompleted.started = true;
    const added = attempt(() => { w.run('chrome.webNavigation').onCompleted.addListener(() => {}); return 'added'; });
    check('an event the code doesn\'t name takes a late listener without a throw', added === 'added', added);
  }
  {
    const onConnect = webkitEvent();
    world({ background: true, runtimeExtra: { onConnect }, events: ['runtime.onConnect'] });
    check('an extension page holds no stand-in', onConnect.count() === 0);
  }
  {
    // macOS 26: WebKit refuses late listeners. A late one with a filter isn't
    // heard (the stand-in can't hold to it); a plain one is, and counts.
    const onCompleted = webkitEvent();
    const w = world({ worker: true, namespaces: { webNavigation: { onCompleted, getAllFrames: async () => [] } }, events: ['webNavigation.onCompleted'] });
    onCompleted.started = true;
    const heard = [];
    const filtered = (d) => heard.push('filtered ' + d.url), plain = (d) => heard.push('plain ' + d.url);
    w.run('chrome.webNavigation').onCompleted.addListener(filtered, { url: [{ hostEquals: 'example.com' }] });
    w.run('chrome.webNavigation').onCompleted.addListener(plain);
    onCompleted.fire({ url: 'https://unrelated.test/' });
    check('a late listener with a filter isn\'t handed every site\'s events', JSON.stringify(heard) === '["plain https://unrelated.test/"]', JSON.stringify(heard));
    check('a late listener counts as there', w.run('chrome.webNavigation').onCompleted.hasListener(plain) && w.run('chrome.webNavigation').onCompleted.hasListeners());
  }
}

// Errors nobody caught, told to eGlu: from the extension's own pages
// and worker, not from content scripts.
{
  const w = world();
  w.target.dispatchEvent(Object.assign(new Event('error'), {
    error: new TypeError("undefined is not an object (evaluating 'chrome.sidePanel.open')"), filename: 'bg.js', lineno: 7,
  }));
  w.target.dispatchEvent(Object.assign(new Event('unhandledrejection'), { reason: new Error('chrome.offscreen is undefined') }));
  await tick();
  const sent = w.native.map((n) => n.message);
  check('an uncaught error is reported', w.native[0]?.application === 'eglu' && sent[0]?.api === 'report'
    && /sidePanel/.test(sent[0]?.args[1]) && sent[0]?.args[2] === 'bg.js' && sent[0]?.args[3] === 7, JSON.stringify(sent[0]));
  check('an unhandled rejection is reported', sent[1]?.args[0] === 'rejection' && /offscreen/.test(sent[1]?.args[1]), JSON.stringify(sent[1]));
}
{
  const w = world({ protocol: 'https:' });
  w.target.dispatchEvent(Object.assign(new Event('error'), { error: new Error('the page\'s own') }));
  await tick();
  check('a content script reports nothing', w.native.length === 0, w.native.length);
}

// Chrome's old FileSystem API on an origin private file system, here one in
// memory: OPFS writes nothing until a writable closes.
{
  let failWrites = false, gate = null, failName = null;
  const fail = (name) => new DOMException(name, name);
  const dirOf = () => ({ kind: 'directory', children: new Map() });
  const handle = (node, name) => node.kind === 'file' ? fileHandle(node, name) : dirHandle(node, name);
  const fileHandle = (node, name) => ({
    kind: 'file', name,
    async getFile() { return new File([node.data], name); },
    async createWritable({ keepExistingData } = {}) {
      let buffer = keepExistingData ? node.data.slice() : new Uint8Array(0), open = true;
      return {
        async write(chunk) {
          const { position = 0, data } = chunk instanceof Blob ? { data: chunk } : chunk;
          if (gate) await gate;
          if (failWrites || name === failName) throw fail('QuotaExceededError');
          const bytes = new Uint8Array(await data.arrayBuffer());
          const next = new Uint8Array(Math.max(buffer.length, position + bytes.length));
          next.set(buffer); next.set(bytes, position); buffer = next;
        },
        async truncate(size) { buffer = buffer.slice(0, size); },
        async close() { if (!open) throw fail('InvalidStateError'); open = false; node.data = buffer; },
        async abort() { open = false; },
      };
    },
  });
  const dirHandle = (node, name) => ({
    kind: 'directory', name,
    async getDirectoryHandle(n, { create } = {}) {
      let c = node.children.get(n);
      if (c && c.kind !== 'directory') throw fail('TypeMismatchError');
      if (!c) { if (!create) throw fail('NotFoundError'); c = dirOf(); node.children.set(n, c); }
      return dirHandle(c, n);
    },
    async getFileHandle(n, { create } = {}) {
      let c = node.children.get(n);
      if (c && c.kind !== 'file') throw fail('TypeMismatchError');
      if (!c) { if (!create) throw fail('NotFoundError'); c = { kind: 'file', data: new Uint8Array(0) }; node.children.set(n, c); }
      return fileHandle(c, n);
    },
    async removeEntry(n, { recursive } = {}) {
      const c = node.children.get(n);
      if (!c) throw fail('NotFoundError');
      if (c.kind === 'directory' && c.children.size && !recursive) throw fail('InvalidModificationError');
      node.children.delete(n);
    },
    async *entries() { for (const [n, c] of [...node.children]) yield [n, handle(c, n)]; },
    async *keys() { for (const n of [...node.children.keys()]) yield n; },
  });
  const disk = dirOf();
  class ProgressEvent extends Event { constructor(type, init) { super(type); Object.assign(this, init); } }
  class Element { setAttribute() {} }
  class HTMLAnchorElement extends Element {
    constructor() { super(); this.link = ''; this.clicked = []; }
    get href() { return this.link; }
    set href(v) { this.link = v; }
    click() { this.clicked.push(this.link); }
  }
  const w = world({ extra: { document: {}, navigator: { storage: { getDirectory: async () => dirHandle(disk, '') } },
    ProgressEvent, Element, HTMLAnchorElement, File, Blob, DOMException } });
  const call = (f) => new Promise((resolve, reject) => f(resolve, reject));
  const fs = await call((ok, no) => w.run('requestFileSystem')(1, 0, ok, no));
  const write = async (name, text) => {
    const entry = await call((ok, no) => fs.root.getFile(name, { create: true }, ok, no));
    const writer = await call((ok, no) => entry.createWriter(ok, no));
    await new Promise((resolve) => { writer.onwriteend = resolve; writer.write(new Blob([text])); });
    return entry;
  };
  const read = async (name) => {
    const entry = await call((ok, no) => fs.root.getFile(name, {}, ok, no));
    return (await call((ok, no) => entry.file(ok, no))).text();
  };
  const left = () => [...disk.children.get('persistent').children.keys()].sort().join();
  await write('final.png', 'old');
  const draft = await write('draft.png', 'new');
  failWrites = true;
  const failed = await call((ok, no) => draft.copyTo(fs.root, 'final.png', ok, no)).then(() => 'copied', (e) => e.name);
  failWrites = false;
  check('a copy that fails over a file leaves the file as it was', failed === 'QuotaExceededError' && await read('final.png') === 'old'
    && left() === 'draft.png,final.png', failed + ' ' + left());
  failName = 'final.png';
  const lastStep = await call((ok, no) => draft.copyTo(fs.root, 'final.png', ok, no)).then(() => 'copied', (e) => e.name);
  failName = null;
  check('a copy that fails at the last step leaves the file and nothing staged', lastStep === 'QuotaExceededError' && await read('final.png') === 'old'
    && left() === 'draft.png,final.png', lastStep + ' ' + left());
  await call((ok, no) => draft.copyTo(fs.root, 'final.png', ok, no));
  check('a copy over a file replaces it once whole', await read('final.png') === 'new' && left() === 'draft.png,final.png', left());
  await write('other.png', 'other');
  await call((ok, no) => draft.moveTo(fs.root, 'other.png', ok, no));
  check('a move over a file replaces it and the source goes', await read('other.png') === 'new' && left() === 'final.png,other.png', left());
  const entry = await call((ok, no) => fs.root.getFile('final.png', {}, ok, no));
  const writer = await call((ok, no) => entry.createWriter(ok, no));
  let open;
  gate = new Promise((resolve) => { open = resolve; });
  const events = [];
  for (const type of ['abort', 'write', 'writeend', 'error']) writer.addEventListener(type, () => events.push(type));
  writer.write(new Blob(['aborted']));
  await tick(5);
  writer.abort();
  open(); gate = null;
  await tick(5);
  const link = new HTMLAnchorElement();
  link.href = entry.toURL();
  link.click();
  await tick(10);
  check('a link clicked as its filesystem: address is set opens the file', link.clicked.length === 1 && link.clicked[0].startsWith('blob:'), JSON.stringify(link.clicked));
  check('an aborted write leaves the file as it was', await read('final.png') === 'new' && events.join() === 'abort,writeend', events.join() + ' ' + await read('final.png'));
}

const failed = results.filter((r) => !r.ok);
for (const r of results) console.log(`${r.ok ? 'ok  ' : 'FAIL'} ${r.name}${r.ok || !r.detail ? '' : `: ${r.detail}`}`);
console.log(failed.length ? `FAILED ${failed.length} of ${results.length}` : `PASSED ${results.length}`);
process.exit(failed.length ? 1 : 0);
