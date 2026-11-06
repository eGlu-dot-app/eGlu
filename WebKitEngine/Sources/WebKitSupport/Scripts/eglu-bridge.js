// egluBridge for WebKit (Docs/EngineSplitPlan.md 5.4): eGlu's scripts talk to
// the app through it, never through window.webkit themselves. Each channel is a
// script message handler of the same name in this world. post and request
// behave exactly as webkit.messageHandlers[channel].postMessage does: a channel
// not open here throws a TypeError, and request's promise is WebKit's own.
//
// Defined once per world and document, as the window's own property: only
// that counts as already there. A page element with the id "egluBridge" is a
// named property of the window in every world, this one included, and must
// neither stop the bridge from being defined nor stand in for it.
(() => {
  if (Object.prototype.hasOwnProperty.call(globalThis, "egluBridge")) return;
  const handler = (channel) => globalThis.webkit.messageHandlers[channel];
  Object.defineProperty(globalThis, "egluBridge", {
    value: Object.freeze({
      version: 1,
      post(channel, body) { handler(channel).postMessage(body); },
      request(channel, body) { return handler(channel).postMessage(body); },
    }),
  });
})();
