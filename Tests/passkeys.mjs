#!/usr/bin/env node
// Runs PadCore's passkey scripts (Scripts/passkeys.js in the page's world,
// Scripts/passkeys-bridge.js in eGlu's) against stand-ins for WebKit's
// credential objects and the app's handler, each script in a world of its
// own sharing the window's events, as WebKit has them. What goes to the app,
// what the page gets back, and what is left to WebKit. Tests/passkeys.html
// runs the same scripts in the real app (Tests/passkeys-rehearsal.py).
//
//   node Tests/passkeys.mjs
//
// Needs nothing beyond Node. Nothing here ships in the app.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (name) => fs.readFileSync(path.join(root, 'PadCore/Sources/PadCore/Scripts', name), 'utf8');
const pageScript = read('passkeys.js'), bridgeScript = read('passkeys-bridge.js');

const results = [];
// `ok` may be a promise of one, for a check that waits.
const check = (name, ok, detail = '') => results.push({ name, ok, detail: String(detail) });
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const b64 = (bytes) => Buffer.from(bytes).toString('base64url');

/// A page with WebKit's credential objects, passkeys.js in its world and the
/// bridge in eGlu's. `answer(message)` is the app: what it replies. `host` is
/// the frame's; `handsOff`, the hosts the app writes in (Scripts.handsOff);
/// `bridgeFirst`, WebKit running eGlu's world's script before the page's.
function page(answer = () => null, { top = true, ancestors = [], timers = null, activation = undefined, host = 'example.com',
  handsOff = [], bridgeFirst = false } = {}) {
  const written = (script) => script.replace('/*HANDS_OFF*/[]', JSON.stringify(handsOff));
  const events = new EventTarget();
  const sent = [], native = [];
  // Node's own buffers, which its WebCrypto gives back: one realm's, as a page has.
  const shared = { CustomEvent, DOMException, TextEncoder, TextDecoder, atob, btoa, crypto: webcrypto, setTimeout, clearTimeout, console, ArrayBuffer, Uint8Array, URL };
  const own = vm.createContext({ ...shared, ...(timers || {}), location: { hostname: host } });
  vm.runInContext(`
    // As var, so they are the window's own, as WebKit's are.
    var CredentialsContainer = class CredentialsContainer {};
    CredentialsContainer.prototype.get = function get() { return __native('get', arguments[0]); };
    CredentialsContainer.prototype.create = function create() { return __native('create', arguments[0]); };
    var PublicKeyCredential = class PublicKeyCredential {};
    PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
    PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
    PublicKeyCredential.getClientCapabilities = () => Promise.resolve({ 'extension:largeBlob': true, 'extension:credProps': true, relatedOrigins: true });
    var AuthenticatorAttestationResponse = class AuthenticatorAttestationResponse {};
    var AuthenticatorAssertionResponse = class AuthenticatorAssertionResponse {};
    var navigator = { credentials: new CredentialsContainer() };
  `, own);
  own.window = own;
  own.__native = (kind, options) => { native.push({ kind, options }); return Promise.resolve('native'); };
  own.addEventListener = events.addEventListener.bind(events);
  own.dispatchEvent = events.dispatchEvent.bind(events);

  const listeners = {};
  const document = {
    activeElement: null,
    addEventListener(type, f) { (listeners[type] = listeners[type] || []).push(f); },
  };
  const ours = vm.createContext({ ...shared, document, requestAnimationFrame: (f) => setTimeout(f, 0),
    location: { ancestorOrigins: ancestors, hostname: host }, navigator: { userActivation: activation } });
  ours.window = ours;
  ours.top = top ? ours : {};
  ours.addEventListener = events.addEventListener.bind(events);
  ours.dispatchEvent = events.dispatchEvent.bind(events);
  ours.webkit = { messageHandlers: { egluPasskeys: { postMessage(message) {
    sent.push(message);
    return Promise.resolve(answer(message));
  } } } };
  // In either order, as WebKit runs the two worlds' scripts in no set order.
  if (bridgeFirst) vm.runInContext(written(bridgeScript), ours);
  vm.runInContext(written(pageScript), own);
  if (!bridgeFirst) vm.runInContext(written(bridgeScript), ours);
  // `isTrusted`: as WebKit marks the person's own input; a page's events are not.
  const fire = (type, target, isTrusted = true) => (listeners[type] || []).forEach((f) => f({ target, isTrusted }));
  return { own, ours, sent, native, fire, run: (code) => vm.runInContext(code, own) };
}

const field = (autocomplete) => ({
  tagName: 'INPUT', isConnected: true,
  getAttribute: (name) => (name === 'autocomplete' ? autocomplete : null),
  getBoundingClientRect: () => ({ left: 10, top: 20, width: 200, height: 30 }),
});

// What passkeys.js sends: the request in JSON, bytes as base64url.
{
  const p = page(() => ({ error: 'NotAllowedError', message: 'no' }));
  await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1, 2, 3]), rpId: 'example.com',
    allowCredentials: [{ type: 'public-key', id: new Uint8Array([0xfb, 0xff]), transports: ['usb'] }], userVerification: 'required' } })`).catch(() => {});
  const get = p.sent[0];
  check('a sign-in goes to the app', get && get.kind === 'get' && get.challenge === 'AQID' && get.rpId === 'example.com'
    && get.conditional === false && get.userVerification === 'required', JSON.stringify(get));
  check('its credentials as base64url, with their transports', get && get.allowCredentials[0].id === '-_8' && get.allowCredentials[0].transports[0] === 'usb');
  check('with a token of its own', get && typeof get.token === 'string' && get.token.length > 10);

  await p.run(`navigator.credentials.create({ publicKey: { challenge: new Uint8Array([9]), rp: { name: 'Example' },
    user: { id: new Uint8Array([1]), name: 'ann', displayName: 'Ann' }, pubKeyCredParams: [{ type: 'public-key', alg: -8 }, { type: 'public-key', alg: -7 }],
    authenticatorSelection: { requireResidentKey: true, authenticatorAttachment: 'platform' }, attestation: 'direct' } })`).catch(() => {});
  const create = p.sent[1];
  check('a new passkey goes to the app', create && create.kind === 'create' && create.rp.id === null && create.user.id === 'AQ'
    && create.user.name === 'ann' && create.user.displayName === 'Ann', JSON.stringify(create));
  check('its algorithms, attachment, resident key and attestation', create && create.algorithms.join() === '-8,-7'
    && create.authenticatorAttachment === 'platform' && create.residentKey === 'required' && create.attestation === 'direct');
}

// The frames a request's frame is in: the bridge's to say, never the page's.
{
  const p = page(() => null, { top: false, ancestors: ['https://example.com'] });
  p.own.dispatchEvent(new CustomEvent('eglu-passkeys-ask', { detail: JSON.stringify({ kind: 'get', token: 'forged', challenge: 'AA', ancestors: ['https://fake.com'] }) }));
  await tick(5);
  check('the bridge names the frames as WebKit has them', p.sent[0] && p.sent[0].ancestors.join() === 'https://example.com', JSON.stringify(p.sent[0]));
  const top = page(() => null);
  await top.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })`).catch(() => {});
  check('the page itself is in none', top.sent[0] && Array.isArray(top.sent[0].ancestors) && top.sent[0].ancestors.length === 0);
}

// Whether the frame was just clicked: the bridge's to say, never the page's.
{
  const clicked = page(() => null, { activation: { isActive: true } });
  clicked.own.dispatchEvent(new CustomEvent('eglu-passkeys-ask', { detail: JSON.stringify({ kind: 'create', token: 't', activated: false }) }));
  const idle = page(() => null, { activation: { isActive: false } });
  idle.own.dispatchEvent(new CustomEvent('eglu-passkeys-ask', { detail: JSON.stringify({ kind: 'create', token: 't', activated: true }) }));
  const none = page(() => null);
  none.own.dispatchEvent(new CustomEvent('eglu-passkeys-ask', { detail: JSON.stringify({ kind: 'create', token: 't', activated: true }) }));
  await tick(5);
  check('the bridge says whether the frame was just clicked', clicked.sent[0] && clicked.sent[0].activated === true
    && idle.sent[0] && idle.sent[0].activated === false && none.sent[0] && none.sent[0].activated === false,
    JSON.stringify([clicked.sent[0], idle.sent[0], none.sent[0]]));
}

// A sign-in asked for without the person: none, and nothing sent.
{
  const p = page(() => ({ error: 'NotAllowedError', message: 'no' }));
  const quiet = await p.run(`navigator.credentials.get({ mediation: 'silent', publicKey: { challenge: new Uint8Array(1) } })`);
  check('mediation silent gives null and asks the app nothing', quiet === null && p.sent.length === 0);
}

// Only public keys.
{
  const p = page(() => ({ error: 'NotAllowedError', message: 'no' }));
  await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1),
    allowCredentials: [{ type: 'public-key', id: new Uint8Array([1]) }, { type: 'other', id: new Uint8Array([2]) }] } })`).catch(() => {});
  check('a credential of another type is left out', p.sent[0] && p.sent[0].allowCredentials.length === 1 && p.sent[0].allowCredentials[0].id === 'AQ');
  const none = await p.run(`navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1), name: 'a' },
    pubKeyCredParams: [{ type: 'other', alg: -7 }] } }).catch((e) => e.name)`);
  check('a list of key types with no public key in it is refused', none === 'NotSupportedError' && p.sent.length === 1);
  await p.run(`navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1), name: 'a' },
    pubKeyCredParams: [{ type: 'other', alg: -8 }, { type: 'public-key', alg: -7 }] } })`).catch(() => {});
  check('only the public key types are sent', p.sent[1] && p.sent[1].algorithms.join() === '-7');
}

// Called off while PRF's key is being made: nothing reaches the app.
{
  const p = page(() => null);
  p.own.__abort = new AbortController();
  const pending = p.run(`navigator.credentials.get({ signal: __abort.signal, publicKey: { challenge: new Uint8Array(1), extensions: { prf: { eval: { first: new Uint8Array(1) } } } } }).catch((e) => e.name)`);
  p.own.__abort.abort();
  check('aborted before it is sent, it never is', await pending === 'AbortError' && p.sent.filter((m) => m.kind !== 'cancel').length === 0,
    JSON.stringify(p.sent));
}

// The site's timeout: past it, a no, and the sheet called off; held between
// 15 seconds and 10 minutes; none for a request from under the field.
{
  const delays = [];
  const timers = { setTimeout: (f, ms) => { delays.push(ms); return setTimeout(f, 0); }, clearTimeout };
  const p = page((m) => (m.kind === 'cancel' ? true : new Promise(() => {})), { timers });
  const late = await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1), timeout: 1000 } }).catch((e) => e.name)`);
  check('past its timeout a request is refused, and called off at the app', late === 'NotAllowedError'
    && p.sent[1] && p.sent[1].kind === 'cancel' && p.sent[1].token === p.sent[0].token, JSON.stringify(p.sent));
  check('a timeout too short is held to 15 seconds', delays[0] === 15000, delays.join());
  p.run(`navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1), name: 'a' }, timeout: 3600000 } })`).catch(() => {});
  await tick(5);
  check('one too long, to 10 minutes', delays[1] === 600000, delays.join());
  p.run(`navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(1), timeout: 1000 } })`);
  p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })`).catch(() => {});
  await tick(5);
  check('none from under the field, nor without a timeout', delays.length === 2, delays.join());
  const answered = page(() => ({ kind: 'get', id: 'AQ', clientDataJSON: 'e30', authenticatorData: 'Aw', signature: 'BA', userHandle: null }), { timers });
  const got = await answered.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1), timeout: 60000 } }).then((c) => c.type, (e) => e.name)`);
  await tick(5);
  check('an answer in time stands', got === 'public-key' && answered.sent.every((m) => m.kind !== 'cancel'), got);
}

// Bytes made in another frame of the page, with its own ArrayBuffer.
{
  const p = page(() => null);
  p.own.__foreign = vm.runInNewContext('({ buffer: new Uint8Array([1, 2, 3]).buffer, view: new Uint8Array([4, 5, 6, 7]).subarray(1, 3) })');
  const result = await p.run(`navigator.credentials.get({ publicKey: { challenge: __foreign.buffer,
    allowCredentials: [{ type: 'public-key', id: __foreign.view }] } }).then(() => 'sent', (e) => e.name)`);
  check('an ArrayBuffer or a view from another frame is taken', p.sent[0] && p.sent[0].challenge === 'AQID'
    && p.sent[0].allowCredentials[0].id === 'BQY', result + ' ' + JSON.stringify(p.sent[0]));
  const wrong = await p.run(`navigator.credentials.get({ publicKey: { challenge: 'text' } }).catch((e) => e.name)`);
  check('anything else is still a TypeError', wrong === 'TypeError');
}

// An answer is the app's only with the bridge's secret, told at document
// start: a page's own event with a pending token is let go.
{
  const reply = { kind: 'get', id: 'AQ', clientDataJSON: 'e30', authenticatorData: 'Aw', signature: 'BA', userHandle: null };
  for (const bridgeFirst of [false, true]) {
    const p = page(() => reply, { bridgeFirst });
    p.own.addEventListener('eglu-passkeys-ask', (event) => {
      const asked = JSON.parse(event.detail);
      p.own.dispatchEvent(new CustomEvent('eglu-passkeys-answer', { detail: JSON.stringify({ token: asked.token, secret: 'guess',
        reply: { ...reply, id: 'RkFLRQ' } }) }));
      p.own.dispatchEvent(new CustomEvent('eglu-passkeys-answer', { detail: JSON.stringify({ token: asked.token, reply: { ...reply, id: 'RkFLRQ' } }) }));
    });
    const got = await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } }).then((c) => c.id, (e) => e.name)`);
    check(`a forged answer is let go, the app's taken (${bridgeFirst ? "eGlu's world first" : "the page's first"})`, got === 'AQ', got);
  }
  const p = page(() => reply);
  let heard = 0;
  p.own.addEventListener('eglu-passkeys-hello', () => { heard++; });
  p.own.dispatchEvent(new CustomEvent('eglu-passkeys-ready'));
  check('a later "ready" of the site\'s gets no secret', heard === 0);
}

// Nothing of eGlu's in a frame of a hands-off host, in either world.
{
  const p = page(() => null, { host: 'accounts.google.com', handsOff: ['accounts.google.com'], top: false });
  const got = await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })`);
  check('a hands-off frame keeps WebKit\'s own navigator.credentials', got === 'native' && p.sent.length === 0
    && p.run(`!CredentialsContainer.prototype[Symbol.for('eglu.passkeys')]`));
  check('and eGlu\'s world puts nothing there', p.ours.__egluPasskeys === undefined);
  const sub = page(() => null, { host: 'sub.accounts.google.com', handsOff: ['accounts.google.com'] });
  check('nor in one below it', await sub.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })`) === 'native');
  const other = page(() => ({ error: 'NotAllowedError', message: 'no' }), { host: 'notaccounts.google.com', handsOff: ['accounts.google.com'] });
  await other.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })`).catch(() => {});
  check('a host that only ends the same way is not one', other.sent.length === 1);
}

// Anything but a public key is WebKit's, as it was.
{
  const p = page();
  const got = await p.run(`navigator.credentials.get({ password: true })`);
  const made = await p.run(`navigator.credentials.create({ password: { id: 'a', password: 'b' } })`);
  check('a stored password is left to WebKit', got === 'native' && made === 'native' && p.native.length === 2 && p.sent.length === 0);
}

// What the page gets back.
{
  const reply = { kind: 'get', id: 'AQ', clientDataJSON: b64(Buffer.from('{}')), authenticatorData: 'Aw', signature: 'BA', userHandle: 'BQ', attachment: 'platform' };
  const p = page(() => reply);
  const c = await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1]) } })`);
  const proto = p.run('PublicKeyCredential.prototype'), response = p.run('AuthenticatorAssertionResponse.prototype');
  check('a credential of the page\'s own kind', Object.getPrototypeOf(c) === proto && Object.getPrototypeOf(c.response) === response);
  check('its bytes as ArrayBuffers', c.rawId.byteLength === 1 && new Uint8Array(c.response.userHandle)[0] === 5 && c.type === 'public-key'
    && c.authenticatorAttachment === 'platform');
  let wrote = true;
  try { c.toJSON = () => 1; } catch (e) { wrote = false; }
  check('its methods can be replaced, as a native credential\'s', wrote && c.toJSON() === 1);
  let held = true;
  try { c.id = 'other'; } catch (e) { held = false; }
  check('its data is read-only', c.id === 'AQ', held);
  check('toJSON in the standard shape', (() => { const fresh = page(() => reply); return fresh.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1]) } })`)
    .then((x) => { const j = x.toJSON(); return j.response.signature === 'BA' && j.response.userHandle === 'BQ' && j.rawId === 'AQ'; }); })());
}

// Refusals: a TypeError as a TypeError, the rest as DOMExceptions.
{
  const p = page((m) => (m.kind === 'get' ? { error: 'TypeError', message: 'A challenge is required.' } : { error: 'SecurityError', message: 'x' }));
  const typeError = await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(0) } }).catch((e) => e)`);
  const security = await p.run(`navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1), name: 'a' } } }).catch((e) => e)`);
  check('a TypeError is one', typeError instanceof p.run('TypeError') && typeError.message === 'A challenge is required.');
  check('a SecurityError is a DOMException', security instanceof DOMException && security.name === 'SecurityError');
  const quiet = await p.run(`navigator.credentials.create({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(1) } }).catch((e) => e.name)`);
  check('a passkey made quietly is refused without asking', quiet === 'NotAllowedError' && p.sent.length === 2);
  const none = page(() => null);
  const nothing = await none.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } }).catch((e) => e.name)`);
  check('no answer is a no', nothing === 'NotAllowedError');
}

// Under the field: Wait never settles, an abort calls it off at the app.
{
  const p = page((m) => (m.kind === 'cancel' ? true : { error: 'Wait', message: '' }));
  let settled = false;
  p.own.__abort = new AbortController();
  p.run(`navigator.credentials.get({ mediation: 'conditional', signal: __abort.signal, publicKey: { challenge: new Uint8Array([1]) } })`)
    .then(() => { settled = 'resolved'; }, (e) => { settled = e.name; });
  await tick(20);
  check('a request under the field says so', p.sent[0] && p.sent[0].conditional === true);
  check('with nothing to offer it waits', settled === false);
  p.own.__abort.abort();
  await tick(20);
  check('aborted, it is refused and called off at the app', settled === 'AbortError' && p.sent[1] && p.sent[1].kind === 'cancel' && p.sent[1].token === p.sent[0].token);
}

// PRF: salts sent as base64url; results opened with the page's own key.
{
  let prfKey;
  const p = page(async (m) => {
    if (m.kind !== 'create') return null;
    prfKey = m.prfKey;
    // The app's side, as PasskeyReply.prf seals it.
    const subtle = webcrypto.subtle;
    const mine = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const theirs = await subtle.importKey('raw', Buffer.from(m.prfKey, 'base64url'), { name: 'ECDH', namedCurve: 'P-256' }, false, []);
    const bits = await subtle.deriveBits({ name: 'ECDH', public: theirs }, mine.privateKey, 256);
    const base = await subtle.importKey('raw', bits, 'HKDF', false, ['deriveKey']);
    const key = await subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode('eglu-prf') },
      base, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
    const iv = webcrypto.getRandomValues(new Uint8Array(12));
    const box = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(JSON.stringify({ first: b64([7, 7]) }))));
    const raw = new Uint8Array(await subtle.exportKey('raw', mine.publicKey));
    return { kind: 'create', id: 'AQ', clientDataJSON: 'e30', attestationObject: 'oA', transports: ['internal'], attachment: 'platform',
      prf: { enabled: true, sealed: { key: b64(raw), box: b64([...iv, ...box]) } } };
  });
  const c = await p.run(`navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1), name: 'a' },
    extensions: { prf: { eval: { first: new Uint8Array([1, 2]) } } } } })`);
  check('the salts go as base64url, with a one-time key', p.sent[0].prf.eval.first === 'AQI' && p.sent[0].prf.eval.second === null
    && Buffer.from(prfKey, 'base64url').length === 65);
  const prf = c.getClientExtensionResults().prf;
  check('the results, opened in the page', prf.enabled === true && new Uint8Array(prf.results.first).join() === '7,7');
  check('as base64url in toJSON', c.toJSON().clientExtensionResults.prf.results.first === 'Bwc');
  const refused = await p.run(`navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1), allowCredentials: [{ id: new Uint8Array([1]), type: 'public-key' }],
    extensions: { prf: { evalByCredential: { Ag: { first: new Uint8Array(1) } } } } } }).catch((e) => e.name)`);
  check('salts for a passkey not allowed are refused in the page', refused === 'SyntaxError' && p.sent.length === 1);
}

// What the page is told it can do.
{
  const p = page();
  const capabilities = await p.run('PublicKeyCredential.getClientCapabilities()');
  check('a platform authenticator and passkeys under the field', await p.run('PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()')
    && await p.run('PublicKeyCredential.isConditionalMediationAvailable()'));
  check('capabilities: WebKit\'s extensions it doesn\'t carry are off, PRF on', capabilities['extension:largeBlob'] === false
    && capabilities['extension:credProps'] === true && capabilities['extension:prf'] === true && capabilities.relatedOrigins === false
    && capabilities.conditionalGet === true && capabilities.hybridTransport === true);
}

// In once, and nothing of eGlu's in the page's world.
{
  const p = page();
  const first = p.run('CredentialsContainer.prototype.get');
  p.run(pageScript);
  check('a second copy changes nothing', p.run('CredentialsContainer.prototype.get') === first);
  check('no global of the app\'s in the page\'s world', p.run(`typeof webkit === 'undefined' && typeof __egluPasskeys === 'undefined'`));
}

// The bridge: a field message is its own, the field's place only for a field marked for passkeys.
{
  const p = page(() => true);
  p.own.dispatchEvent(new CustomEvent('eglu-passkeys-ask', { detail: JSON.stringify({ kind: 'field', token: 'x', rect: { x: 0, y: 0, width: 9, height: 9 } }) }));
  await tick(5);
  check('the page can\'t speak for the field', p.sent.length === 0);
  p.fire('focusin', field('username'));
  await tick(5);
  check('a field not marked for passkeys says nothing', p.sent.length === 0);
  const marked = field('username webauthn');
  p.fire('focusin', marked);
  await tick(5);
  const said = p.sent[0];
  check('a field marked for passkeys says where it is', said && said.kind === 'field' && said.rect.x === 10 && said.rect.height === 30, JSON.stringify(said));
  check('a focus says it is no click', said && said.clicked === false);
  p.fire('mousedown', marked);
  await tick(5);
  check('a click in the field says so', p.sent[1] && p.sent[1].kind === 'field' && p.sent[1].clicked === true, JSON.stringify(p.sent[1]));
  p.fire('mousedown', marked, false);
  await tick(5);
  check('a page\'s own mousedown is no click', p.sent[2] && p.sent[2].kind === 'field' && p.sent[2].clicked === false, JSON.stringify(p.sent[2]));
  p.sent.splice(1, 2);
  p.fire('focusout', marked);
  await tick(5);
  check('and when it lets go', p.sent[1] && p.sent[1].kind === 'field' && p.sent[1].rect === null);
  p.ours.document.activeElement = marked;
  const asked = p.ours.__egluPasskeys.field();
  check('the app can ask where it is', asked && asked.y === 20);
  const off = page(() => true);
  off.fire('focusin', Object.assign(field('username webauthn'), { disabled: true }));
  off.fire('focusin', Object.assign(field('username webauthn'), { readOnly: true }));
  await tick(5);
  check('a field that can\'t be typed in says nothing', off.sent.length === 0);
  const listing = page(() => true);
  listing.ours.document.baseURI = 'https://account.apple.com/sign-in';
  listing.ours.document.querySelectorAll = (selector) => (selector.includes('[allow]') ? [
    { getAttribute: (name) => ({ allow: 'publickey-credentials-get', src: '/x' })[name] },
    { getAttribute: (name) => ({ allow: 'camera *', src: 'https://idmsa.apple.com/frame?x=1' })[name] },
  ] : []);
  const frames = listing.ours.__egluPasskeys.frames();
  check('the page\'s frame elements: what each allows, and its src\'s origin', frames.length === 2
    && frames[0].allow === 'publickey-credentials-get' && frames[0].src === 'https://account.apple.com'
    && frames[1].src === 'https://idmsa.apple.com', JSON.stringify(frames));
  const framed = page(() => true, { top: false });
  framed.fire('focusin', marked);
  await tick(5);
  check('a frame says nothing of its fields', framed.sent.length === 0);
}

let failed = 0;
for (const r of results) {
  const ok = !!(await r.ok);
  if (!ok) failed++;
  console.log(`${ok ? 'ok ' : 'NO '} ${r.name}${r.detail && !ok ? ': ' + r.detail : ''}`);
}
console.log(failed ? `FAILED ${failed} of ${results.length}` : `PASSED ${results.length}`);
process.exit(failed ? 1 : 0);
