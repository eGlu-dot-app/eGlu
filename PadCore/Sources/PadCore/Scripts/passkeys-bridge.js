// The app's side of passkeys.js, in eGlu's own world, where its channel is
// and a page can't look (Mac/Sources/Passkeys.swift). A request the page's
// script dispatches is handed over as it is (the frame it comes from is
// WebKit's to say, not the event's), and the answer dispatched back for the
// page's script to pick up. From Search (github.com/driceroland/Search, MIT,
// PasskeyRelay.bridge in its Passkeys.swift).
//
// In the page itself it also says where the sign-in field is while it has
// the keyboard: a field marked for passkeys (autocomplete="… webauthn", as
// the standard asks of a page that offers them there), so the app can show
// the passkeys it holds for the site under it. Only where it is, never what
// is typed in it.
(function () {
  // Nothing of eGlu's in a frame of a hands-off host (passkeys.js says why).
  var handsOff = /*HANDS_OFF*/[], host = location.hostname.toLowerCase().replace(/\.+$/, '');
  if (handsOff.some(function (h) { return host === h || host.slice(-h.length - 1) === '.' + h; })) return;
  // The app's channel, through egluBridge, which the app puts in front of
  // this script (Page.bridged): never window.webkit itself.
  var bridge = globalThis.egluBridge, channel = 'egluPasskeys';
  if (!bridge || window.__egluPasskeys) return;
  function request(body) {
    try { return Promise.resolve(bridge.request(channel, body)); } catch (e) { return Promise.reject(e); }
  }
  var asked = 'eglu-passkeys-ask', answered = 'eglu-passkeys-answer';

  // The secret every answer carries, told to passkeys.js once, at document
  // start, before the site's scripts run: it says "ready" when it starts,
  // this says "hello" when it starts and to the first "ready", and its
  // "ack" ends that, so a later "ready" of the site's is never answered.
  var bytes = new Uint8Array(16), secret = '', told = false;
  crypto.getRandomValues(bytes);
  for (var i = 0; i < bytes.length; i++) secret += (bytes[i] + 256).toString(16).slice(1);
  function hello() { window.dispatchEvent(new CustomEvent('eglu-passkeys-hello', { detail: secret })); }
  window.addEventListener('eglu-passkeys-ack', function () { told = true; });
  window.addEventListener('eglu-passkeys-ready', function () { if (!told) hello(); });
  hello();

  window.addEventListener(asked, function (event) {
    var message;
    try { message = JSON.parse(event.detail); } catch (e) { return; }
    if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
    // The field's word is this script's alone.
    if (message.kind === 'field') return;
    // The frames this one is in, and whether it has just been clicked, as
    // WebKit has them, never as the page wrote.
    if (message.kind !== 'cancel') {
      message.ancestors = ancestors();
      message.activated = activated();
    }
    function answer(reply) {
      window.dispatchEvent(new CustomEvent(answered, { detail: JSON.stringify({ token: message.token, secret: secret, reply: reply }) }));
    }
    request(message).then(function (reply) {
      if (message.kind !== 'cancel') answer(reply);
    }, function () {
      if (message.kind !== 'cancel') answer(null);
    });
  });

  function activated() {
    var activation = navigator.userActivation;
    return !!(activation && activation.isActive);
  }

  function ancestors() {
    var list = location.ancestorOrigins;
    return list ? Array.prototype.slice.call(list) : null;
  }

  function forPasskeys(element) {
    if (!element || element.tagName !== 'INPUT' || element.disabled || element.readOnly || element.type === 'hidden') return false;
    var tokens = String(element.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
    return tokens.indexOf('webauthn') >= 0;
  }
  // Where the field is, in the page's points from the view's top left corner.
  function place(element) {
    var r = element.getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height };
  }
  // `clicked`: the field was clicked since last told, which may ask macOS's
  // question for passkeys (Passkeys.field). Only a click of the person's
  // counts: WebKit marks it trusted, and a page's own event never is.
  var field = null, pending = 0, clicked = false;
  function tell() {
    pending = 0;
    var rect = field && field.isConnected ? place(field) : null;
    request({ kind: 'field', token: '', rect: rect, clicked: clicked }).catch(function () {});
    clicked = false;
  }
  function soon() {
    if (!pending) pending = requestAnimationFrame(tell);
  }

  // What the app asks: where the field is, when its passkeys for the site
  // come in after the field already had the keyboard; and, when a frame of
  // the page asks for a passkey, what the page's frame elements allow
  // (their allow attributes, and the origins of their src).
  window.__egluPasskeys = {
    field: function () {
      var focused = document.activeElement;
      return forPasskeys(focused) ? place(focused) : null;
    },
    frames: function () {
      return Array.prototype.map.call(document.querySelectorAll('iframe[allow], frame[allow]'), function (frame) {
        var src = null;
        try { src = new URL(frame.getAttribute('src') || '', document.baseURI).origin; } catch (e) {}
        return { allow: frame.getAttribute('allow') || '', src: src };
      });
    }
  };

  if (window.top !== window) return;
  document.addEventListener('focusin', function (event) {
    if (!forPasskeys(event.target)) return;
    field = event.target;
    soon();
  }, true);
  // A click in the field the list was closed over brings it back.
  document.addEventListener('mousedown', function (event) {
    if (!forPasskeys(event.target)) return;
    field = event.target;
    if (event.isTrusted === true) clicked = true;
    soon();
  }, true);
  document.addEventListener('focusout', function (event) {
    if (event.target !== field) return;
    field = null;
    soon();
  }, true);
  // The list follows the field as the page moves under it.
  window.addEventListener('scroll', function () { if (field) soon(); }, true);
  window.addEventListener('resize', function () { if (field) soon(); });
})();
