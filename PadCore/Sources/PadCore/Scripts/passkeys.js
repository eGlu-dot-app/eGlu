// eGlu's passkeys, in the page's own world, before anything of the site's
// runs (Mac/Sources/Passkeys.swift): navigator.credentials answers requests
// for a public key from the app, and anything else it is asked (a stored
// password) as it always did. Only in a build signed with Apple's passkey
// entitlement for browsers; without it this script is never put in a page.
//
// It has to be in the page's own world to stand in for the page's functions,
// and nothing of eGlu's is there for a page to find: no window.webkit, no
// global of its own. Requests go to the app's side as events on the window,
// picked up by passkeys-bridge.js in eGlu's world, which hands them over as
// they are: the frame a request comes from is WebKit's to say, not the
// event's.
//
// Taken from Search (github.com/driceroland/Search, MIT, PasskeyRelay.page in
// its Passkeys.swift), with eGlu's names. On the prototype: WebKit makes
// navigator.credentials anew whenever nothing holds it, and what was set on
// the old one goes with it.
(function () {
  // It goes into every frame, and a frame of a hands-off host (Google's
  // sign-in, inside another site) gets nothing of eGlu's: the app writes the
  // hosts in (HandsOff.hosts), and this is the first thing the script does.
  var handsOff = /*HANDS_OFF*/[], host = location.hostname.toLowerCase().replace(/\.+$/, '');
  if (handsOff.some(function (h) { return host === h || host.slice(-h.length - 1) === '.' + h; })) return;
  if (!window.PublicKeyCredential || !window.CredentialsContainer) return;
  var proto = CredentialsContainer.prototype;
  // In once, marked on the prototype rather than on the window. The mark
  // holds navigator.credentials too: held, WebKit keeps it.
  var mark = Symbol.for('eglu.passkeys');
  if (proto[mark]) return;
  try { Object.defineProperty(proto, mark, { value: navigator.credentials }); } catch (e) { return; }
  var nativeGet = proto.get, nativeCreate = proto.create;
  var refused = 'The operation either timed out or was not allowed.';
  var asked = 'eglu-passkeys-ask', answered = 'eglu-passkeys-answer';
  // WebCrypto as it is now, before the site's own scripts run: the PRF
  // results come back sealed for a key made here (PasskeyReply.prf).
  var subtle = window.crypto && crypto.subtle, sealing = null;
  if (subtle) sealing = {
    generate: subtle.generateKey.bind(subtle), exportKey: subtle.exportKey.bind(subtle),
    importKey: subtle.importKey.bind(subtle), deriveBits: subtle.deriveBits.bind(subtle),
    deriveKey: subtle.deriveKey.bind(subtle), decrypt: subtle.decrypt.bind(subtle)
  };
  // And what reads and writes them, as it is now too.
  var utf8 = new TextEncoder(), text = new TextDecoder();
  var encodeText = utf8.encode.bind(utf8), decodeText = text.decode.bind(text);
  var parse = JSON.parse, stringify = JSON.stringify;
  var dispatch = window.dispatchEvent.bind(window), listen = window.addEventListener.bind(window);
  var later = window.setTimeout.bind(window), stop = window.clearTimeout.bind(window);
  var Custom = window.CustomEvent;

  // An ArrayBuffer told by its tag, so one made in another frame of the
  // page, with that frame's ArrayBuffer, counts too.
  var tag = Function.prototype.call.bind(Object.prototype.toString);
  function bytes(source) {
    if (tag(source) === '[object ArrayBuffer]') return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    throw new TypeError('Expected an ArrayBuffer or a view of one.');
  }
  function encode(source) {
    var b = bytes(source), s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function decode(value) {
    var s = (value || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }
  // The PRF extension's salts, and what the passkey derived from them.
  function prfValues(v) {
    return { first: encode(v.first), second: v.second !== undefined ? encode(v.second) : null };
  }
  function prfInput(extensions, allowed) {
    var prf = extensions && extensions.prf;
    if (!prf) return null;
    var out = {};
    if (prf.eval) out.eval = prfValues(prf.eval);
    if (prf.evalByCredential) {
      // As the standard has it: salts for particular passkeys need the list
      // of them, and every one of them has to be on it.
      if (!allowed || !allowed.length) throw new DOMException('evalByCredential needs allowCredentials.', 'NotSupportedError');
      var ids = Array.prototype.map.call(allowed, function (c) { return encode(c.id); });
      out.byCredential = {};
      Object.keys(prf.evalByCredential).forEach(function (id) {
        if (!id || ids.indexOf(id) < 0) throw new DOMException('evalByCredential names a credential allowCredentials does not.', 'SyntaxError');
        out.byCredential[id] = prfValues(prf.evalByCredential[id]);
      });
    }
    return out;
  }
  function prfOutput(reply, made, binary) {
    var out = {};
    if (made) out.enabled = !!reply.enabled;
    if (reply.first) {
      var value = binary ? decode : function (s) { return s; };
      out.results = { first: value(reply.first) };
      if (reply.second) out.results.second = value(reply.second);
    }
    return out;
  }

  // Credentials of another type than a public key are left out, as the
  // standard has it.
  function descriptors(list) {
    return Array.prototype.filter.call(list || [], function (c) { return c.type === undefined || c.type === 'public-key'; })
      .map(function (c) { return { id: encode(c.id), transports: Array.prototype.slice.call(c.transports || []) }; });
  }
  function aborted(signal) {
    return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
  }
  // Data as read-only, as a native credential's are; methods (`hidden`)
  // writable, as a native credential's are on its prototype: libraries put
  // their own on the object. GitHub's webauthn-json sets toJSON on what get()
  // returns, which a read-only one turned into a TypeError (Search's #407).
  function define(target, values, hidden) {
    Object.keys(values).forEach(function (k) {
      Object.defineProperty(target, k, { value: values[k], enumerable: !hidden, configurable: true, writable: !!hidden });
    });
    return target;
  }

  function credential(reply, extensions) {
    var response, made = reply.kind === 'create';
    if (made) {
      response = Object.create(AuthenticatorAttestationResponse.prototype);
      define(response, { clientDataJSON: decode(reply.clientDataJSON), attestationObject: decode(reply.attestationObject) });
      define(response, {
        getTransports: function () { return (reply.transports || []).slice(); },
        getAuthenticatorData: function () { return decode(reply.authenticatorData); },
        getPublicKey: function () { return reply.publicKey ? decode(reply.publicKey) : null; },
        getPublicKeyAlgorithm: function () { return reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7; }
      }, true);
    } else {
      response = Object.create(AuthenticatorAssertionResponse.prototype);
      define(response, {
        clientDataJSON: decode(reply.clientDataJSON),
        authenticatorData: decode(reply.authenticatorData),
        signature: decode(reply.signature),
        userHandle: reply.userHandle ? decode(reply.userHandle) : null
      });
    }
    // A passkey from the Mac is always one the site can find without naming
    // it; the site may have asked whether it is.
    var results = {};
    if (made && extensions && extensions.credProps && reply.attachment === 'platform') results.credProps = { rk: true };
    // PRF outputs are bytes: made afresh for each caller, base64url in JSON.
    var prf = extensions && extensions.prf && reply.prf ? reply.prf : null;
    var attachment = reply.attachment || null;
    var jsonResults = parse(stringify(results));
    if (prf) jsonResults.prf = prfOutput(prf, made, false);
    var json = { id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: attachment, clientExtensionResults: jsonResults };
    json.response = made
      ? { clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, authenticatorData: reply.authenticatorData,
          transports: (reply.transports || []).slice(), publicKeyAlgorithm: reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7 }
      : { clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature };
    if (made && reply.publicKey) json.response.publicKey = reply.publicKey;
    if (!made && reply.userHandle) json.response.userHandle = reply.userHandle;
    var result = Object.create(PublicKeyCredential.prototype);
    define(result, { id: reply.id, rawId: decode(reply.id), type: 'public-key', authenticatorAttachment: attachment, response: response });
    return define(result, {
      getClientExtensionResults: function () {
        var copy = parse(stringify(results));
        if (prf) copy.prf = prfOutput(prf, made, true);
        return copy;
      },
      toJSON: function () { return parse(stringify(json)); }
    }, true);
  }

  // A secret the bridge gives at document start, before any of the site's
  // scripts can listen (passkeys-bridge.js): an answer without it is not the
  // app's, whoever dispatched it. Whichever of the two scripts WebKit runs
  // first, one of "ready" and "hello" finds the other listening. Every script
  // of the site's runs after both, a <script> in the head included. Only an
  // extension's content script in the page's world may run before and hear
  // it, and one there can stand in for navigator.credentials itself, as
  // password managers do; no channel between two worlds is hidden from it.
  var secret = null;
  listen('eglu-passkeys-hello', function (event) {
    if (secret !== null || typeof event.detail !== 'string' || !event.detail) return;
    secret = event.detail;
    dispatch(new Custom('eglu-passkeys-ack'));
  });
  dispatch(new Custom('eglu-passkeys-ready'));

  var waiting = {};
  listen(answered, function (event) {
    var data;
    try { data = parse(event.detail); } catch (e) { return; }
    if (!data || secret === null || data.secret !== secret) return;
    var done = waiting[data.token];
    if (!done) return;
    delete waiting[data.token];
    done(data.reply);
  });
  function ask(message) {
    return new Promise(function (resolve) {
      if (message.kind === 'cancel') resolve(true); else waiting[message.token] = resolve;
      dispatch(new Custom(asked, { detail: stringify(message) }));
    });
  }

  // A one-time key pair for a request's PRF results; the private half never
  // leaves this script.
  function prfKeys() {
    if (!sealing) return Promise.resolve(null);
    return sealing.generate({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']).then(function (pair) {
      return sealing.exportKey('raw', pair.publicKey).then(function (raw) { return { pair: pair, raw: encode(raw) }; });
    }, function () { return null; });
  }
  function unseal(prf, keys) {
    if (!prf || !prf.sealed || !keys) return Promise.resolve(prf ? { enabled: prf.enabled } : null);
    var box = new Uint8Array(decode(prf.sealed.box));
    return sealing.importKey('raw', decode(prf.sealed.key), { name: 'ECDH', namedCurve: 'P-256' }, false, [])
      .then(function (theirs) { return sealing.deriveBits({ name: 'ECDH', public: theirs }, keys.pair.privateKey, 256); })
      .then(function (bits) { return sealing.importKey('raw', bits, 'HKDF', false, ['deriveKey']); })
      .then(function (base) {
        return sealing.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: encodeText('eglu-prf') },
          base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
      })
      .then(function (key) { return sealing.decrypt({ name: 'AES-GCM', iv: box.slice(0, 12) }, key, box.slice(12)); })
      .then(function (plain) {
        var results = parse(decodeText(plain));
        return { enabled: prf.enabled, first: results.first, second: results.second };
      }, function () { return { enabled: prf.enabled }; });
  }

  // How long a request with a sheet may wait, held between these, as other
  // browsers hold the site's timeout; with none, until it is answered.
  var shortest = 15000, longest = 600000;

  function send(request, signal, extensions, timeout) {
    if (signal && signal.aborted) return Promise.reject(aborted(signal));
    request.token = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
    return (request.prf ? prfKeys() : Promise.resolve(null)).then(function (keys) {
      // Called off while the key was being made.
      if (signal && signal.aborted) throw aborted(signal);
      if (keys) request.prfKey = keys.raw;
      return new Promise(function (resolve, reject) {
        if (signal) signal.addEventListener('abort', function () {
          ask({ kind: 'cancel', token: request.token });
          reject(aborted(signal));
        }, { once: true });
        // The site's timeout: past it the request is over, as the standard
        // has it, and its sheet is called off. Not one from under the field,
        // which waits as long as the page does.
        var timer = 0;
        if (!request.conditional && typeof timeout === 'number' && timeout > 0) {
          timer = later(function () {
            ask({ kind: 'cancel', token: request.token });
            reject(new DOMException(refused, 'NotAllowedError'));
          }, Math.min(Math.max(timeout, shortest), longest));
        }
        ask(request).then(function (reply) {
          stop(timer);
          // Nothing to offer under the field here: it waits, as it does while
          // nobody picks one, until the page lets it go.
          if (reply && reply.error === 'Wait') return;
          if (!reply || reply.error) {
            var name = (reply && reply.error) || 'NotAllowedError';
            var message = (reply && reply.message) || refused;
            return reject(name === 'TypeError' ? new TypeError(message) : new DOMException(message, name));
          }
          unseal(reply.prf, keys).then(function (prf) {
            if (prf) reply.prf = prf; else delete reply.prf;
            resolve(credential(reply, extensions));
          });
        }, function () { reject(new DOMException(refused, 'NotAllowedError')); });
      });
    });
  }

  function replace(target, name, value) {
    try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true }); } catch (e) {}
  }

  replace(proto, 'get', function get(options) {
    if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
    var signal = options.signal, pk = options.publicKey, request;
    // A sign-in asked for without the person (mediation: "silent"): a
    // passkey always needs them, so there is none to give, as the standard
    // has it, and nothing comes up.
    if (options.mediation === 'silent') {
      return signal && signal.aborted ? Promise.reject(aborted(signal)) : Promise.resolve(null);
    }
    // From under the name field: offered there, answered once you pick.
    var underField = options.mediation === 'conditional';
    try {
      request = {
        kind: 'get', conditional: underField, challenge: encode(pk.challenge), rpId: pk.rpId || null,
        allowCredentials: descriptors(pk.allowCredentials),
        userVerification: pk.userVerification || 'preferred',
        prf: prfInput(pk.extensions, pk.allowCredentials)
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, signal, pk.extensions, pk.timeout);
  });

  replace(proto, 'create', function create(options) {
    if (!options || !options.publicKey) return nativeCreate.apply(this, arguments);
    var pk = options.publicKey, selection = pk.authenticatorSelection || {}, request;
    // Only public keys: a list that names none the standard knows can't be made.
    var params = Array.prototype.filter.call(pk.pubKeyCredParams || [], function (p) { return p && p.type === 'public-key'; });
    if ((pk.pubKeyCredParams || []).length && !params.length) {
      return Promise.reject(new DOMException('No supported key type was asked for.', 'NotSupportedError'));
    }
    // A passkey made quietly after a password sign-in: not something this
    // browser does yet, so the site hears no, as it would if you had said it.
    if (options.mediation === 'conditional') return Promise.reject(new DOMException(refused, 'NotAllowedError'));
    try {
      request = {
        kind: 'create', challenge: encode(pk.challenge),
        rp: { id: (pk.rp && pk.rp.id) || null },
        user: { id: encode(pk.user.id), name: String(pk.user.name), displayName: pk.user.displayName ? String(pk.user.displayName) : '' },
        algorithms: params.map(function (p) { return p.alg; }),
        excludeCredentials: descriptors(pk.excludeCredentials),
        authenticatorAttachment: selection.authenticatorAttachment || null,
        residentKey: selection.residentKey || (selection.requireResidentKey ? 'required' : 'discouraged'),
        userVerification: selection.userVerification || 'preferred',
        attestation: pk.attestation || 'none',
        prf: prfInput(pk.extensions, null)
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, options.signal, pk.extensions, pk.timeout);
  });

  // What this browser can and can't do, for the pages that ask first:
  // passkeys from the Mac, a phone or a key, under the field too, and none
  // of what WebKit would have answered for itself.
  var P = PublicKeyCredential;
  replace(P, 'isUserVerifyingPlatformAuthenticatorAvailable', function () { return Promise.resolve(true); });
  replace(P, 'isConditionalMediationAvailable', function () { return Promise.resolve(true); });
  var nativeCapabilities = P.getClientCapabilities;
  if (typeof nativeCapabilities === 'function') {
    replace(P, 'getClientCapabilities', function () {
      function ours(c) {
        c = Object.assign({}, c);
        Object.keys(c).forEach(function (k) { if (k.indexOf('extension:') === 0 && k !== 'extension:credProps') c[k] = false; });
        c['extension:prf'] = true;
        return Object.assign(c, {
          conditionalCreate: false, conditionalGet: true, conditionalMediation: true, relatedOrigins: false,
          signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false,
          hybridTransport: true, passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true
        });
      }
      return nativeCapabilities.call(P).then(ours, function () { return ours({}); });
    });
  }
})();
