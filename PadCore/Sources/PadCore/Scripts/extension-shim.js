// eGlu's shim for Chrome extensions (Docs/ExtensionsDesign.md).
//
// Put first in an extension's worker, its background scripts, its content
// scripts and its pages (ExtensionPreparation.swift), it mends where
// WebKit's extension APIs behave unlike Chrome's, adds what WebKit lacks
// and eGlu answers, and tells eGlu of the errors nobody caught.
// Most of it follows Search's (github.com/driceroland/Search, MIT, Office
// Commun, its ExtensionShims.swift), each part saying so; what eGlu
// took is listed in Docs/ExtensionsFromSearch.md.
(() => {
  const root = globalThis;
  const chrome = root.chrome || root.browser;
  // A page's own world, where an extension's MAIN-world script runs with
  // this before it, has no extension APIs: nothing to mend there, and
  // nothing may be left there for a page to see. (Search)
  const ours = (() => { try { return !!(chrome && chrome.runtime && chrome.runtime.id); } catch (e) { return false; } })();
  if (!ours || root.__egluShim) return;
  Object.defineProperty(root, "__egluShim", { value: true });
  const runtime = chrome.runtime;
  // Taken now, not looked up at each use: a sandbox that later locks the
  // globals away (MetaMask's LavaMoat) would break the shim's own code that
  // needs them. (Search)
  const { URL, Blob, DOMException, Event, MessageEvent, CloseEvent, BroadcastChannel } = root;
  // Every namespace WebKit gives this world, taken now: a sandbox that later
  // locks the globals away (MetaMask's LavaMoat) would break the shim's own
  // code that needs them. (Search)
  const spaces = new Set(Object.keys(chrome));
  // On a web page this is a content script: only Chrome's behaviour is
  // mended there, no API Chrome doesn't give content scripts either.
  const inContent = typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol);
  // One of the extension's pages in a frame of a website: Vimium's bar, a
  // password manager's list under a field. WebKit runs it in the website's
  // process, which it trusts with no more than a content script: one call
  // to tabs, windows or scripting, and WebKit takes the process for
  // compromised and ends it. Chrome gives such a frame everything, so here
  // the worker makes those calls for it (see __egluCall). (Search)
  const embedded = !inContent && typeof window !== "undefined" && window.top !== window && (() => {
    try { const a = location.ancestorOrigins; if (a && a.length) return [...a].some((o) => o !== location.origin); } catch (e) {}
    try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
  })();
  const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
  // The extension's background, whichever WebKit runs: its worker, or its
  // page, which it picks when a manifest names scripts as well. (Search)
  const background = worker || (!inContent && typeof document !== "undefined" && (() => {
    try { return typeof chrome.extension?.getBackgroundPage === "function" && chrome.extension.getBackgroundPage() === root; }
    catch (e) { return false; }
  })());
  const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
  const hasWorker = !!(manifest.background && (manifest.background.service_worker || manifest.background.scripts || manifest.background.page));

  // Bitwarden's bundled TypeScript uses these as computed class keys before
  // it registers disposable resources: defined before any extension code
  // runs, Symbol.for keeping the key shared by its frames. (Search)
  for (const name of ["dispose", "asyncDispose"]) {
    if (root.Symbol[name] === undefined) Object.defineProperty(root.Symbol, name, { value: root.Symbol.for("Symbol." + name) });
  }

  // WebKit took requestIdleCallback back out after a page-load regression
  // (bug 287681), leaving Proton Pass's form detection without it. Chrome's
  // longest idle deadline is 50 ms; this gives the whole of it. (Search)
  if (typeof root.requestIdleCallback !== "function" || typeof root.cancelIdleCallback !== "function") {
    const idle = new Map();
    let last = 0;
    root.requestIdleCallback = (callback) => {
      const id = ++last;
      idle.set(id, setTimeout(() => {
        if (!idle.delete(id)) return;
        const start = Date.now();
        callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
      }, 1));
      return id;
    };
    root.cancelIdleCallback = (id) => {
      const timer = idle.get(id);
      if (timer === undefined) return;
      idle.delete(id);
      clearTimeout(timer);
    };
  }

  // WebKit finds an extension's APIs through the chrome and browser globals
  // when it delivers an event. A sandbox that locks every global away
  // (MetaMask's LavaMoat) cuts it off. Made fixed accessors, they can't be
  // taken away, and a replacement that still carries the APIs is taken;
  // one that hides them (a Proxy, as Proton Pass puts there) isn't. (Search)
  for (const key of ["browser", "chrome"]) {
    // SingleFile installs its own browser getter: browser is left open for it.
    if (key === "browser" && runtime.id === "mpiodijhokgodhhofbcjdecpffjipkle") continue;
    const d = Object.getOwnPropertyDescriptor(root, key);
    if (!d || !d.configurable) continue;
    let value = root[key];
    const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
    try {
      Object.defineProperty(root, key, { configurable: false, enumerable: d.enumerable, get: () => value, set: (v) => { if (carries(v)) value = v; } });
    } catch (e) {}
  }

  // WebKit's namespace and event objects are wrappers it doesn't keep
  // alive: once no script holds one, the next chrome.runtime is a fresh
  // object without what was set on it. So what is touched here is held for
  // good, and a member is set as an own property, which takes the place of
  // the prototype's method of the same name. (Search)
  const kept = new Set([chrome, runtime]);
  for (const space of spaces) { try { const ns = chrome[space]; if (ns && typeof ns === "object") kept.add(ns); } catch (e) {} }
  try { Object.defineProperty(root, "__egluKept", { value: kept }); } catch (e) {}
  const put = (target, key, value) => {
    if (target && (typeof target === "object" || typeof target === "function")) kept.add(target);
    try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); }
    catch (e) { try { target[key] = value; } catch (e2) {} }
  };
  // Set for the callback, then as it was: WebKit's own, if it had one.
  const withLastError = (error, callback) => {
    const before = Object.getOwnPropertyDescriptor(runtime, "lastError");
    put(runtime, "lastError", { message: String(error && error.message || error) });
    try { callback(); } finally {
      try { if (before) Object.defineProperty(runtime, "lastError", before); else delete runtime.lastError; } catch (e) {}
    }
  };
  // runtime's methods as its own, bound, so code that takes one off it
  // still calls WebKit's on the object it came from. (Search)
  {
    const names = new Set();
    for (let o = runtime; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
    for (const name of names) {
      if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
      let f; try { f = runtime[name]; } catch (e) { continue; }
      if (typeof f === "function") put(runtime, name, f.bind(runtime));
    }
  }

  // All but one: WebKit hands out runtime.getPlatformInfo afresh at each
  // read, past anything put in its place, and a copy called with another
  // `this` never calls back. Vimium C's worker asks for it as
  // getPlatformInfo.apply(0, [callback]) and waits for the answer before
  // it takes a single connection: its options page stayed blank and its
  // keys did nothing. A copy applied to no object (0, null, undefined) is
  // applied to runtime, only through apply, which is how such code calls
  // it. (Search)
  {
    const apply = Function.prototype.apply;
    // WebKit's own, not a function of the extension's that happens to have
    // the name: WebKit's reads as native code.
    const source = Function.prototype.toString;
    const webKits = (f) => { try { return /\[native code\]/.test(source.call(f)); } catch (e) { return false; } };
    try {
      Object.defineProperty(Function.prototype, "apply", {
        value: ({ apply(that, args) {
          if ((that === null || (typeof that !== "object" && typeof that !== "function"))
              && typeof this === "function" && this.name === "getPlatformInfo" && webKits(this)) that = runtime;
          return Reflect.apply(apply, this, [that, args]);
        } }).apply, configurable: true, writable: true, enumerable: false,
      });
    } catch (e) {}
  }

  // eGlu itself, through native messaging to "eglu": it hears of
  // errors here, and answers the APIs WebKit lacks.
  const native = (api, args) =>
    runtime.sendNativeMessage("eglu", { api, args: JSON.parse(JSON.stringify(args ?? [])) })
      .then((reply) => {
        if (reply && reply.error) throw new Error(reply.error);
        return reply ? reply.value : undefined;
      });
  // Chrome's APIs take a callback last, or return a promise without one.
  const call = (api) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const promise = native(api, args);
    if (!callback) return promise;
    promise.then((value) => callback(value), (error) => withLastError(error, callback));
  };
  // An event of the shim's own, as Chrome's events look.
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (f) => { if (typeof f === "function") listeners.add(f); }, removeListener: (f) => listeners.delete(f),
      hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0,
      listeners,
    };
  };

  // Errors nobody caught, in the worker and the extension's own pages, told
  // to eGlu, which keeps only those whose words name an API
  // (ExtensionError) and never the words themselves. Not from a content
  // script, where the page's own errors arrive too. macOS 27 tells the app
  // of them itself; this is how it hears where it doesn't.
  if (!inContent && typeof root.addEventListener === "function") {
    const report = (kind, error, file, line) => {
      try { native("report", [kind, String(error && error.message || error), String(file || ""), Number(line) || 0]).catch(() => {}); } catch (e) {}
    };
    root.addEventListener("error", (e) => report("error", e.error || e.message, e.filename, e.lineno));
    root.addEventListener("unhandledrejection", (e) => report("rejection", e.reason, "", 0));
  }

  // WebKit gives a worker the user agent of the last web page that set one,
  // Safari's, not the Chrome one an extension expects. Code that picks its
  // path by it takes the Safari one: Bitwarden's asks a Safari app for a
  // reply thousands of times a second. Its pages too: an extension reads it
  // to pick a code path, a download, a welcome page. (Search)
  if (!inContent && typeof navigator !== "undefined" && !/ Chrome\//.test(navigator.userAgent || "")) {
    const given = "__EGLU_CHROME__";
    const version = /^\d+(\.\d+){3}$/.test(given) ? given : "140.0.0.0";
    const chromeUA = String(navigator.userAgent).replace(/ Version\/[\d.]+.*$/, "").replace(/ Safari\/[\d.]+$/, "") + " Chrome/" + version + " Safari/537.36";
    const proto = typeof WorkerNavigator !== "undefined" && worker ? WorkerNavigator.prototype : typeof Navigator !== "undefined" ? Navigator.prototype : null;
    try {
      if (proto) {
        Object.defineProperty(proto, "userAgent", { get: () => chromeUA, configurable: true });
        Object.defineProperty(proto, "appVersion", { get: () => chromeUA.replace(/^Mozilla\//, ""), configurable: true });
        Object.defineProperty(proto, "vendor", { get: () => "Google Inc.", configurable: true });
        if (!("userAgentData" in navigator)) {
          const major = version.split(".")[0];
          const brands = [{ brand: "Chromium", version: major }, { brand: "Google Chrome", version: major }, { brand: "Not.A/Brand", version: "99" }];
          const low = { brands, mobile: false, platform: "macOS" };
          const mac = (chromeUA.match(/Mac OS X (\d+)[_.](\d+)(?:[_.](\d+))?/) || []).slice(1).map((n) => n || "0").join(".") || "10.15.7";
          const high = {
            architecture: "arm", bitness: "64", model: "", platformVersion: mac, wow64: false,
            fullVersionList: brands.map((b) => ({ brand: b.brand, version: b.version === major ? version : b.version + ".0.0.0" })),
            uaFullVersion: version,
          };
          const pick = (hints) => Object.assign({}, low, ...(Array.isArray(hints) ? hints : []).filter((h) => h in high).map((h) => ({ [h]: high[h] })));
          const data = Object.assign({}, low, { getHighEntropyValues: (hints) => Promise.resolve(pick(hints)), toJSON: () => low });
          Object.defineProperty(proto, "userAgentData", { get: () => data, configurable: true });
        }
      }
    } catch (e) {}
  }

  // A script a worker imports that isn't there: Chrome throws at once.
  // WebKit goes looking for it first, and while it does, runs the promises
  // already waiting: code that notes "still starting" until its first
  // promise settles (Tampermonkey) then thinks startup is over, and refuses
  // its own listeners. The extension's files are known, so a missing one is
  // refused as Chrome refuses it, and an empty one (Tampermonkey's test.js)
  // isn't fetched at all. (Search)
  const scripts = /*__EGLU_SCRIPTS__*/null;
  const moduleWorker = worker && manifest.background && manifest.background.type === "module";
  if (worker && !moduleWorker && Array.isArray(scripts) && typeof root.importScripts === "function") {
    const shipped = new Set(), empty = new Set();
    for (const p of scripts) p.startsWith("-") ? empty.add(p.slice(1)) : shipped.add(p);
    const load = root.importScripts.bind(root);
    root.importScripts = (...urls) => {
      const wanted = [];
      for (const u of urls) {
        let url; try { url = new URL(u, location.href); } catch (e) { wanted.push(u); continue; }
        const path = decodeURIComponent(url.pathname);
        if (url.origin === location.origin && empty.has(path)) continue;
        if (url.origin === location.origin && !shipped.has(path) && path !== "/_eglu/shim.js") {
          throw new DOMException("Failed to execute 'importScripts' on 'WorkerGlobalScope': The script at '" + url.href + "' failed to load.", "NetworkError");
        }
        wanted.push(u);
      }
      if (wanted.length) return load(...wanted);
    };
  }

  // The static routing API of Chrome's service workers (the install event's
  // addRoutes): a speed-up, so nothing is lost without it. (Search)
  // WebKit's install event is a plain ExtendableEvent, with no InstallEvent
  // to give it to: Stylus's install handler threw. (Search)
  const Install = root.InstallEvent || root.ExtendableEvent;
  if (typeof Install === "function" && Install.prototype && !Install.prototype.addRoutes) {
    Install.prototype.addRoutes = () => Promise.resolve();
  }

  // clients.matchAll() in an extension's worker: Chrome lists the
  // extension's own pages that are open. WebKit lists none, so an extension
  // that checks whether its popup is open before sending it news always
  // hears no: 1Password's popup stays on "connecting to the app" for ever.
  // eGlu knows which pages are open, so they are added to the list; a
  // message posted to one reaches it through a channel the pages listen on,
  // as a message from the worker. The other way round, a page reaches the
  // worker through navigator.serviceWorker, which no worker controls here,
  // so a page is given one that posts to the worker over the same channel.
  // A port handed over with a message can't cross the channel: it stays
  // with its sender, and what is posted to the one the other side is given
  // comes back over the channel to it. (Search)
  const clientsChannel = typeof BroadcastChannel === "function" && !inContent && !embedded ? new BroadcastChannel("eglu-clients") : null;
  if (clientsChannel) {
    // The ports a page handed over, kept on its side, and the stand-ins
    // the other side was given: what is posted on either goes over the
    // channel to the other, so a port carries both ways.
    const heldPorts = new Map(), standIns = new Map();
    const handOver = (transfer) => (Array.isArray(transfer) ? transfer : (transfer && transfer.transfer) || [])
      .filter((p) => typeof MessagePort === "function" && p instanceof MessagePort)
      .map((port) => {
        const key = Math.random().toString(36).slice(2);
        heldPorts.set(key, port);
        port.onmessage = (e) => clientsChannel.postMessage({ toPort: key, data: e.data });
        return key;
      });
    const answered = (data) => {
      if (typeof data.port === "string") {
        const port = heldPorts.get(data.port);
        if (port) port.postMessage(data.data);
        return true;
      }
      if (typeof data.toPort === "string") {
        const port = standIns.get(data.toPort);
        if (port) port.postMessage(data.data);
        return true;
      }
      return false;
    };
    const messageFrom = (source, data, keys) => {
      const ports = (Array.isArray(keys) ? keys : []).map((key) => {
        const pair = new MessageChannel();
        pair.port1.onmessage = (e) => clientsChannel.postMessage({ port: key, data: e.data });
        standIns.set(key, pair.port1);
        return pair.port2;
      });
      const message = new MessageEvent("message", { data, ports, origin: location.origin });
      if (source) Object.defineProperty(message, "source", { value: source });
      return message;
    };
    if (worker && root.clients && typeof root.clients.matchAll === "function") {
      const matchAll = root.clients.matchAll.bind(root.clients);
      // A page is known by its address, here and on the message it sends.
      const client = (p) => ({
        id: "eglu-" + p.url, url: p.url, type: "window", frameType: "top-level",
        visibilityState: p.visible ? "visible" : "hidden", focused: !!p.focused,
        postMessage: (data, transfer) => { try { clientsChannel.postMessage({ url: p.url, data, ports: handOver(transfer) }); } catch (e) {} },
        focus() { return Promise.resolve(this); },
        navigate: () => Promise.resolve(null),
      });
      put(root.clients, "matchAll", async (options) => {
        const found = [...await matchAll(options)];
        const type = (options && options.type) || "window";
        if (type !== "window" && type !== "all") return found;
        let pages = [];
        try { pages = (await native("clients.pages", [])) || []; } catch (e) {}
        const listed = new Set(found.map((c) => c.url));
        return found.concat(pages.filter((p) => p && typeof p.url === "string" && !listed.has(p.url)).map(client));
      });
      clientsChannel.onmessage = ({ data }) => {
        if (!data || answered(data) || typeof data.from !== "string") return;
        root.dispatchEvent(messageFrom(client({ id: data.from, url: data.from }), data.data, data.ports));
      };
    } else if (!background && typeof navigator !== "undefined" && navigator.serviceWorker) {
      const container = navigator.serviceWorker;
      const script = manifest.background && manifest.background.service_worker;
      const controller = script && !container.controller ? {
        scriptURL: new URL(script, location.origin + "/").href, state: "activated", onstatechange: null, onerror: null,
        postMessage: (data, transfer) => { try { clientsChannel.postMessage({ from: location.href, data, ports: handOver(transfer) }); } catch (e) {} },
        addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => true,
      } : null;
      clientsChannel.onmessage = ({ data }) => {
        if (!data || answered(data) || data.url !== location.href) return;
        try { container.dispatchEvent(messageFrom(controller, data.data, data.ports)); } catch (e) {}
      };
      // Only the controller: `ready` is left as WebKit has it, since a
      // made-up registration has none of a real one's methods.
      if (controller) {
        kept.add(container);
        let own = controller;
        try { Object.defineProperty(container, "controller", { configurable: true, get: () => own }); } catch (e) {}
        // A page that, told a worker controls it, loads a script of its own
        // the extension doesn't ship counts on that worker's fetch handler
        // to make it, as Chrome lets it: Stylus's popup writes in <script
        // src="data?…"> for its first data. WebKit's worker never sees an
        // extension page's requests, the script fails, and the page, sure it
        // has its data, stopped there: a blank popup. Such a page is told no
        // worker controls it, which sends it the way Chrome's pages go
        // without one, and `ready` brings it the stand-in to talk to the
        // worker through. The failed script is parser-inserted, so this
        // comes before the page's next one. (Search)
        const shipped = new Set((Array.isArray(scripts) ? scripts : []).map((p) => p.replace(/^-/, "")));
        const registration = {
          active: controller, installing: null, waiting: null, scope: location.origin + "/",
          update() { return Promise.resolve(this); }, unregister: () => Promise.resolve(false),
          addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => true,
        };
        if (typeof document !== "undefined" && typeof document.addEventListener === "function") document.addEventListener("error", (e) => {
          const element = e.target;
          if (!own || !element || element.tagName !== "SCRIPT" || !element.src) return;
          let url; try { url = new URL(element.src); } catch (x) { return; }
          if (url.origin !== location.origin || shipped.has(decodeURIComponent(url.pathname))) return;
          own = null;
          try { Object.defineProperty(container, "ready", { configurable: true, get: () => Promise.resolve(registration) }); } catch (x) {}
        }, true);
      }
    }
  }

  // WebKit runs an extension's worker on its web process's main thread, and
  // a worker's WebSocket waits there for the main thread to set up its
  // channel, for itself, for ever: the worker and every page of the
  // extension freeze. 1Password opens one as a sign-in succeeds. So a
  // worker's socket is made by eGlu (ExtensionSocket.swift) and its
  // frames come and go over a native port. (Search)
  if (worker && typeof root.WebSocket === "function" && typeof runtime.connectNative === "function") {
    const connectNative = runtime.connectNative.bind(runtime);
    const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
    const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
    const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
    class WebSocket extends EventTarget {
      #port; #state = 0; #queue = Promise.resolve(); #origin; #hello;
      constructor(url, protocols) {
        super();
        let parsed;
        try { parsed = new URL(url, location.href); } catch (e) { throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError"); }
        if (parsed.protocol === "http:") parsed.protocol = "ws:";
        if (parsed.protocol === "https:") parsed.protocol = "wss:";
        if (!/^wss?:$/.test(parsed.protocol) || parsed.hash) throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError");
        const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
        Object.defineProperty(this, "url", { value: parsed.href, enumerable: true });
        this.#origin = parsed.origin;
        this.protocol = ""; this.extensions = ""; this.binaryType = "blob"; this.bufferedAmount = 0;
        this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
        this.#hello = { open: this.url, protocols: list, userAgent: navigator.userAgent };
        this.#connect();
      }
      // WebKit drops what a worker posts on a port it has only just
      // opened, without a word either way. So the opening is said again,
      // on the same port, until eGlu answers anything at all.
      #connect() {
        const port = connectNative("eglu.socket");
        let ready = false, tries = 0;
        this.#port = port;
        const again = () => {
          if (ready || this.#state === 3) return;
          if (tries++ >= 20) { this.#fire("error"); this.#closed(1006, "", false); return; }
          try { port.postMessage(this.#hello); } catch (e) {}
          setTimeout(again, 100 * Math.min(tries, 5));
        };
        port.onMessage.addListener((m) => {
          if (!ready) ready = true;
          if (m && m.ready === true) return;
          this.#take(m);
        });
        port.onDisconnect.addListener(() => {
          if (this.#state === 3) return;
          this.#fire("error");
          this.#closed(1006, "", false);
        });
        again();
      }
      get readyState() { return this.#state; }
      #fire(type, init) {
        let e;
        if (type === "message") e = new MessageEvent("message", init);
        else if (type === "close" && typeof CloseEvent === "function") e = new CloseEvent("close", init);
        else { e = new Event(type); if (init) for (const k in init) Object.defineProperty(e, k, { value: init[k] }); }
        const handler = this["on" + type];
        if (typeof handler === "function") { try { handler.call(this, e); } catch (error) { setTimeout(() => { throw error; }); } }
        this.dispatchEvent(e);
      }
      #closed(code, reason, wasClean) {
        this.#state = 3;
        try { this.#port.disconnect(); } catch (e) {}
        this.#fire("close", { code, reason, wasClean });
      }
      #take(m) {
        if (!m || this.#state === 3) return;
        if ("opened" in m) {
          // Closed while connecting: it goes no further.
          if (this.#state !== 0) return;
          this.protocol = m.opened; this.#state = 1; this.#fire("open");
        }
        else if ("text" in m) this.#fire("message", { data: m.text, origin: this.#origin });
        else if ("binary" in m) {
          const buffer = decode(m.binary);
          this.#fire("message", { data: this.binaryType === "arraybuffer" ? buffer : new Blob([buffer]), origin: this.#origin });
        }
        else if ("failed" in m) this.#fire("error");
        else if ("closed" in m) this.#closed(m.closed, m.reason || "", !!m.clean);
      }
      send(data) {
        if (this.#state === 0) throw new DOMException("WebSocket is still in CONNECTING state.", "InvalidStateError");
        if (this.#state !== 1) return;
        const post = (message) => { try { this.#port.postMessage(message); } catch (e) {} };
        if (typeof data === "string") { this.#queue = this.#queue.then(() => post({ send: data })); return; }
        const bytes = data instanceof ArrayBuffer ? Promise.resolve(new Uint8Array(data))
          : ArrayBuffer.isView(data) ? Promise.resolve(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
          : data instanceof Blob ? data.arrayBuffer().then((b) => new Uint8Array(b))
          : Promise.resolve(null);
        this.#queue = this.#queue.then(() => bytes).then((b) => b ? post({ sendBinary: encode(b) }) : post({ send: String(data) }));
      }
      close(code, reason) {
        if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
          throw new DOMException("The close code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
        }
        if (this.#state >= 2) return;
        this.#state = 2;
        const message = { close: code === undefined ? 1000 : code, reason: reason === undefined ? "" : String(reason) };
        this.#queue = this.#queue.then(() => { try { this.#port.postMessage(message); } catch (e) {} });
      }
    }
    for (const [k, v] of Object.entries(states)) { Object.defineProperty(WebSocket, k, { value: v }); Object.defineProperty(WebSocket.prototype, k, { value: v }); }
    Object.defineProperty(root, "WebSocket", { value: WebSocket, configurable: true, writable: true });
  }

  // The same loss meets a worker's port to an app on the Mac: what it posts
  // in its first moments never reaches the app. iCloud Passwords says hello
  // to its helper that way, and without the helper's answer asks for the
  // code again and again. So on such a port, what the extension posts is
  // held until eGlu says the port has arrived, asked on the same port,
  // and then sent in order. WebKit won't let connectNative be replaced in a
  // worker, so this is done on what every port shares, found through a port
  // to eGlu itself; the question and the answer are kept from the
  // extension's listeners, and never reach the app. (Search)
  if (worker && typeof runtime.connectNative === "function") {
    let found = null;
    try { found = runtime.connectNative("eglu"); found.disconnect(); } catch (e) {}
    const portProto = found && Object.getPrototypeOf(found);
    const eventProto = found && found.onMessage && Object.getPrototypeOf(found.onMessage);
    if (portProto && eventProto && typeof portProto.postMessage === "function" && typeof eventProto.addListener === "function") {
      // Ports that go to the extension's own pages or tabs, not an app.
      const toPages = new WeakSet();
      for (const space of [runtime, chrome.tabs]) {
        const connect = space && space.connect;
        if (typeof connect !== "function") continue;
        put(space, "connect", (...args) => { const port = connect.apply(space, args); try { toPages.add(port); } catch (e) {} return port; });
      }
      const post = portProto.postMessage, add = eventProto.addListener, remove = eventProto.removeListener, has = eventProto.hasListener;
      const word = (m) => !!m && typeof m === "object" && "__egluNative" in m;
      const ports = new WeakMap();
      const start = (port) => {
        const state = { held: [] };
        let tries = 0;
        const flush = () => { const list = state.held; state.held = null; for (const m of list || []) post.call(port, m); };
        const again = () => {
          if (!state.held) return;
          // Unanswered, they go anyway: no worse than before.
          if (tries++ >= 20) { flush(); return; }
          try { post.call(port, { __egluNative: "here?" }); } catch (e) {}
          setTimeout(again, 100 * Math.min(tries, 5));
        };
        add.call(port.onMessage, (m) => {
          if (m && m.__egluNative === "here" && state.held) flush();
          // WebKit keeps a worker only while it has posted on an open port
          // in the last two minutes. eGlu's word now and then is
          // answered on the port, so a worker holding a port to an app
          // stays, as in Chrome.
          if (m && m.__egluNative === "alive") { try { post.call(port, { __egluNative: "beat" }); } catch (e) {} }
        });
        add.call(port.onDisconnect, () => { state.held = null; });
        again();
        return state;
      };
      put(portProto, "postMessage", function (message) {
        let state = ports.get(this);
        if (!state) {
          const toApp = !toPages.has(this) && this.sender == null && typeof this.name === "string" && !/^eglu(\.|$)/.test(this.name);
          state = toApp ? start(this) : { held: null };
          ports.set(this, state);
        }
        if (state.held) { state.held.push(message); return; }
        return post.call(this, message);
      });
      // Every event shares this prototype, so every listener goes behind
      // one that lets the question and the answer pass by: one for each
      // function, whatever event object it is added on, so it is found
      // again on a fresh wrapper of the same event; and every argument
      // passed on, a filter included (webRequest, webNavigation).
      const wrappers = new WeakMap();
      const wrapper = (f) => {
        let w = wrappers.get(f);
        if (!w) { w = function (m, ...rest) { if (word(m)) return; return f.call(this, m, ...rest); }; wrappers.set(f, w); }
        return w;
      };
      put(eventProto, "addListener", function (f, ...rest) {
        if (kept.has(this) || typeof f !== "function") return add.call(this, f, ...rest);
        return add.call(this, wrapper(f), ...rest);
      });
      put(eventProto, "removeListener", function (f, ...rest) {
        return remove.call(this, (typeof f === "function" && wrappers.get(f)) || f, ...rest);
      });
      put(eventProto, "hasListener", function (f, ...rest) {
        return has.call(this, (typeof f === "function" && wrappers.get(f)) || f, ...rest);
      });
    }
  }

  // Who has something to say about a message, told between the extension's
  // worker and its own pages on a channel they share (one origin): each
  // says, as soon as its listeners have run, whether it answers or lets the
  // message pass, and the sender says so of what it sends. A page with
  // nothing to say can then stay silent only as long as someone else may
  // still answer (see the end of dispatch). A page in a website's frame is
  // on the website's side of the channel and takes no part. (Search)
  const channel = !inContent && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("eglu-messages") : null;
  const me = Math.random().toString(36).slice(2);
  const peers = new Set();
  const verdicts = new Map();
  const waiting = new Set();
  const present = new Set();
  // Pages that are there but didn't hear the last message sent to all:
  // WebKit doesn't bring every message to every page. Not waited for until
  // they say something about one they heard.
  const deaf = new Set();
  // A message is known by its JSON; a long one by a fingerprint of it.
  const fingerprint = (text) => {
    let a = 0x811c9dc5, b = 0x01000193;
    for (let i = 0; i < text.length; i++) { const c = text.charCodeAt(i); a = Math.imul(a ^ c, 16777619); b = Math.imul(b ^ c, 2246822507); }
    return "#" + (a >>> 0).toString(36) + (b >>> 0).toString(36) + text.length.toString(36);
  };
  const keyOf = (message) => {
    try { const k = JSON.stringify(message); return k === undefined ? null : k.length < 4000 ? k : fingerprint(k); } catch (e) { return null; }
  };
  const tell = (message, verdict, heard) => {
    const key = channel && keyOf(message);
    if (key) channel.postMessage({ key, from: background ? "worker" : me, verdict, heard, at: Date.now() });
  };
  // WebKit hands none of the extension's pages a message its worker or
  // another of its pages sent, and Bitwarden's sync and passkey window wait
  // on those. So each also goes over the channel, and a page that didn't
  // hear it from WebKit takes it from there. Each message's copies are
  // paired by count, keyed on all of it, and only with what the extension's
  // own pages and worker sent: one WebKit delivered cancels one relayed copy
  // still to come, and one relayed cancels a late one from WebKit. A content
  // script's message, however alike, is never taken for one, and an
  // unpaired copy is forgotten after a few seconds. (Search)
  const relayKey = (message) => { try { const text = JSON.stringify(message); return text === undefined ? null : text; } catch (e) { return null; } };
  const ownPlace = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
  const fromOwnPages = (sender) => !!sender && sender.id === runtime.id && typeof sender.url === "string" && !!ownPlace
    && (sender.url + "/").startsWith(ownPlace.replace(/\/$/, "") + "/");
  const heardNatively = new Map(), heardRelayed = new Map();
  const count = (map, key, by) => {
    const now = Date.now();
    for (const [k, v] of map) if (now - v.at > 5000) map.delete(k);
    const n = ((map.get(key) || {}).n || 0) + by;
    if (n > 0) { if (map.size > 200) map.clear(); map.set(key, { n, at: now }); } else map.delete(key);
  };
  const pending = (map, key) => { const v = map.get(key); return !!v && Date.now() - v.at <= 5000 && v.n > 0; };
  let deliverRelayed = null, relaying = false;
  // A relayed message's answer comes back over the channel to its sender,
  // which takes it if WebKit brought none (see the sendMessage below).
  const relays = new Map();
  const relay = (message) => {
    if (!channel) return null;
    const id = me + ":" + Math.random().toString(36).slice(2);
    try { channel.postMessage({ relay: message, from: me, url: location.href, id }); } catch (e) { return null; }
    return id;
  };
  // Only a page that listens for messages is waited for: one that doesn't
  // never hears them, so never says anything about them.
  let listening = false;
  const join = () => { if (channel && !background && !listening) { listening = true; channel.postMessage({ hello: true, from: me, where: location.pathname }); } };
  const leave = () => { if (channel && !background && listening) { listening = false; channel.postMessage({ bye: true, from: me }); } };
  if (channel) {
    channel.onmessage = ({ data }) => {
      if (!data || data.from === me) return;
      if (data.relay !== undefined) {
        const key = relayKey(data.relay);
        if (!background && deliverRelayed) setTimeout(() => {
          if (key && pending(heardNatively, key)) { count(heardNatively, key, -1); return; }
          if (key) count(heardRelayed, key, 1);
          relaying = true;
          let answer;
          try { answer = deliverRelayed(data.relay, { id: runtime.id, url: data.url, origin: location.origin }); } finally { relaying = false; }
          if (answer && typeof data.id === "string") {
            channel.postMessage({ answering: data.id, from: me });
            // An empty answer goes back too for a tab's message, which has
            // one page to wait for, not every page that might answer.
            const forTab = !!(data.relay && typeof data.relay === "object" && data.relay.__egluToFrame);
            answer.then((value) => { if (value !== undefined || forTab) channel.postMessage({ answered: data.id, value, from: me }); });
          }
        }, 50);
        return;
      }
      if (typeof data.answering === "string" || typeof data.answered === "string") {
        const waiter = relays.get(data.answering || data.answered);
        if (waiter) data.answered ? waiter.answer(data.value) : waiter.answering();
        return;
      }
      // The pages that listen, as they come and go.
      if (!background && data.hello) {
        const known = peers.has(data.from);
        peers.add(data.from);
        if (!known && listening) channel.postMessage({ hello: true, from: me, where: location.pathname });
        return;
      }
      if (data.bye) { peers.delete(data.from); waiting.forEach((check) => check()); return; }
      // A popup that closes is thrown away without a word; so a page left
      // waiting asks who is still there.
      if (data.roll) { if (listening && !background) channel.postMessage({ here: true, from: me, to: data.from }); return; }
      if (data.here) { if (data.to === me) present.forEach((hear) => hear(data.from)); return; }
      if (typeof data.key !== "string") return;
      const now = Date.now();
      for (const [k, v] of verdicts) { if (now - v.at > 30000) verdicts.delete(k); else break; }
      const entry = verdicts.get(data.key) || { at: now, worker: null, pages: new Map() };
      verdicts.delete(data.key);
      verdicts.set(data.key, entry);
      entry.at = now;
      if (data.from === "worker") entry.worker = data;
      else { peers.add(data.from); if (data.heard) deaf.delete(data.from); entry.pages.set(data.from, data); }
      waiting.forEach((check) => check());
    };
    if (!background) try { root.addEventListener("pagehide", () => leave()); } catch (e) {}
  }
  // What a runtime.sendMessage call sends, and whether to this extension:
  // Chrome takes (extensionId?, message, options?), a string first being an
  // id only when an options object, or a third argument, doesn't say the
  // second is one. (Search)
  const messageOf = (args) => {
    const options = args[1];
    const isOptions = options == null || (typeof options === "object" && !Array.isArray(options)
      && Object.keys(options).every((key) => key === "includeTlsChannelId"));
    const explicit = args.length >= 3 || (args.length === 2 && typeof args[0] === "string" && !isOptions);
    return { message: args[explicit ? 1 : 0], own: !explicit || !args[0] || args[0] === runtime.id };
  };
  // Who sent a message from the extension's popup, as Chrome says it: no
  // tab. WebKit carries a page's messages only when it can name the tab the
  // page is in, so the popup is one, at no place in the window's row (its
  // index comes as NaN), its own page at the top. (Search)
  const untabbed = (sender) => {
    const tab = sender && sender.tab;
    if (!tab || tab.index >= 0 || sender.frameId || tab.url !== sender.url || !String(sender.url).startsWith(ownPlace)) return sender;
    const plain = { ...sender };
    delete plain.tab;
    return plain;
  };
  // The tab an extension's page is in, asked once (see __egluToFrame).
  let ownTab = null;

  // What one of the extension's pages or its worker posts to another before
  // their port has opened, at once after connect or from inside onConnect,
  // WebKit hands on once for each end's world: between two of the
  // extension's own, twice, and four times from its popup (seen on macOS
  // 27.0.1). iCloud Passwords' popup asks its worker for its state that
  // way, and was answered twice. So between the extension's own ends every
  // message goes numbered by the end that sends it, and a number already
  // heard is let go by. A content script's port, or an app's, goes as it
  // is. The popup's port comes with no tab, as its messages do (untabbed):
  // Passbolt's worker turns a port with a tab away, and its popup stayed
  // empty. (Search)
  if (!inContent && typeof runtime.connect === "function" && runtime.onConnect && typeof runtime.onConnect.addListener === "function") {
    const numbered = new WeakSet();
    // Set on the port itself, not with `put`, which holds what it touches
    // for good: a port is the extension's to let go. Its onMessage is held
    // by what is set here, so it isn't made afresh without it.
    const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
    const number = (port) => {
      const event = port && port.onMessage, post = port && port.postMessage;
      if (!event || typeof event.addListener !== "function" || typeof post !== "function" || numbered.has(port)) return port;
      numbered.add(port);
      const me = Math.random().toString(36).slice(2);
      let sent = 0;
      const heard = new Map(), listeners = new Set();
      event.addListener.call(event, (message, ...rest) => {
        const tag = message && typeof message === "object" ? message.__egluPort : null;
        if (Array.isArray(tag)) {
          if (tag[1] <= (heard.get(tag[0]) || 0)) return;
          heard.set(tag[0], tag[1]);
          message = message.message;
        }
        // The port numbered, not the one WebKit hands the listener, which
        // may be another object for the same port.
        for (const f of [...listeners]) { try { f(message, port, ...rest.slice(1)); } catch (e) { setTimeout(() => { throw e; }); } }
      });
      set(port, "onMessage", event);
      set(port, "postMessage", (message) => post.call(port, { __egluPort: [me, ++sent], message }));
      set(event, "addListener", (f) => { if (typeof f === "function") listeners.add(f); });
      set(event, "removeListener", (f) => { listeners.delete(f); });
      set(event, "hasListener", (f) => listeners.has(f));
      set(event, "hasListeners", () => listeners.size > 0);
      return port;
    };
    const connect = runtime.connect;
    // Only a port to the extension itself: another extension would hear the
    // numbered wrapper, not the message.
    put(runtime, "connect", (...args) => {
      const port = connect.apply(runtime, args);
      return typeof args[0] === "string" && args[0] !== runtime.id ? port : number(port);
    });
    const onConnect = runtime.onConnect;
    const add = onConnect.addListener.bind(onConnect), remove = onConnect.removeListener.bind(onConnect), has = onConnect.hasListener.bind(onConnect);
    const wrapped = new WeakMap();
    // A content script's port comes from the website's address.
    const fromOwn = (port) => !!port && !!port.sender && String(port.sender.url).startsWith(ownPlace);
    put(onConnect, "addListener", (listener, ...rest) => {
      if (typeof listener !== "function") return add(listener, ...rest);
      let w = wrapped.get(listener);
      if (!w) {
        w = (port) => {
          const given = port && port.sender, sender = untabbed(given);
          port = fromOwn(port) ? number(port) : port;
          // WebKit makes a port's sender afresh at each look, over anything
          // set on the port: the port is seen through a proxy.
          if (sender !== given) {
            port = new Proxy(port, { get: (target, key) => {
              if (key === "sender") return sender;
              const value = target[key];
              return typeof value === "function" ? value.bind(target) : value;
            } });
          }
          return listener(port);
        };
        wrapped.set(listener, w);
      }
      return add(w, ...rest);
    });
    put(onConnect, "removeListener", (listener) => remove(wrapped.get(listener) || listener));
    put(onConnect, "hasListener", (listener) => has(wrapped.get(listener) || listener));
  }

  // Several onMessage listeners: WebKit (on macOS 26, as Search found; 27
  // already waits) takes the first one's return, usually undefined, as the
  // answer. Chrome's rule, as of Chrome 148: the first listener to answer,
  // fail or throw decides; an answer comes by sendResponse after returning
  // true, or by a promise; an empty one is null; a throw or a rejection
  // fails the sender's call. So the extension's listeners are gathered
  // behind one of WebKit's that follows it, and answers WebKit with a
  // promise. (Search) That promise never fails: when one does, WebKit
  // (27.0.1) never calls the sender back. A failure is an answer marked as
  // one instead, which the sender's shim turns back into lastError or a
  // rejection (replied, below); to another extension, which has no shim of
  // eGlu's, it is null. An answer of the extension's own that looks
  // like the mark reads as a failure too: at worst a call fails.
  const failure = "__egluFailed";
  const gathered = new Set();
  let attachForUserScripts = null;
  const gather = (target, eager, internal) => {
    if (!target || typeof target.addListener !== "function" || gathered.has(target)) return;
    gathered.add(target);
    kept.add(target);
    const add = target.addListener.bind(target);
    const remove = typeof target.removeListener === "function" ? target.removeListener.bind(target) : () => {};
    const listeners = new Set();
    // A promise when this world has something to say, or nothing.
    const dispatch = (message, sender, local = false) => {
      if (internal && !local && !background && !relaying && fromOwnPages(sender)) {
        const k = relayKey(message);
        if (k && pending(heardRelayed, k)) { count(heardRelayed, k, -1); return undefined; }
        if (k) count(heardNatively, k, 1);
      }
      let settle;
      const answer = new Promise((resolve) => { settle = resolve; });
      let answered = false;
      let keep = false;
      const failWith = (error) => {
        let words = "Error";
        try { words = String(error && typeof error.message === "string" ? error.message : error); } catch (e) {}
        answered = true;
        settle(internal ? { [failure]: words } : null);
      };
      // As Chrome sends it, as JSON, taken when it is given: changed
      // afterwards, it goes as it was; not JSON, it fails.
      const respond = (value) => {
        if (answered) return;
        let copy;
        try {
          const json = value === undefined ? undefined : JSON.stringify(value);
          copy = json === undefined ? null : JSON.parse(json);
        } catch (e) { return failWith(e); }
        answered = true;
        settle(copy);
      };
      const fail = (error) => { if (!answered) failWith(error); };
      // Nothing to say, after all: undefined, which the sender reads as no answer.
      const silent = () => { if (!answered) { answered = true; settle(undefined); } };
      const run = (listener, payload, from) => {
        let result, then;
        try {
          result = listener(payload, from, respond);
          then = result !== true && result ? result.then : undefined;
        } catch (e) { fail(e); setTimeout(() => { throw e; }); return false; }
        if (result === true) return true;
        if (typeof then !== "function") return false;
        try { then.call(result, respond, fail); } catch (e) { fail(e); }
        return true;
      };
      if (internal && message && typeof message === "object") {
        // Only the worker answers its pages' question whether it runs.
        if (message.__egluPing === true) {
          if (background) respond("pong"); else setTimeout(silent, 15000);
          return answer;
        }
        // eGlu's own envelopes come from this extension only: another
        // extension could otherwise speak as a frame of its own; and a tab's
        // message for a frame only from its own pages and worker, never a
        // content script.
        const fromHere = !!(sender && sender.id === runtime.id);
        if ((message.__egluToFrame || message.__egluCall) && !fromHere) return undefined;
        if (message.__egluToFrame && !fromOwnPages(sender)) return undefined;
        // A tab's message, handed on by the worker (see alsoFramed): taken
        // by the page it names, framed or the tab's own, in the tab it
        // names; every other page lets it pass without answering, as it
        // would a message not for it.
        if (message.__egluToFrame) {
          const to = message.__egluToFrame;
          const viaChannel = relaying;
          if (background || !(to.urls || []).includes(location.href)) {
            // Its channel copy wants no word from a page it isn't for.
            if (background || viaChannel) return undefined;
            setTimeout(silent, 10000);
            return answer;
          }
          if (!ownTab) ownTab = Promise.resolve(Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __egluCall: { space: "tabs", method: "getCurrent", args: [] } }))
            .then((reply) => reply && reply.value ? reply.value.id : null, () => null);
          ownTab.then((id) => {
            if (id !== to.tabId) return viaChannel ? silent() : setTimeout(silent, 10000);
            let held = false;
            for (const listener of [...listeners]) if (run(listener, to.message, sender)) held = true;
            if (!held) silent();
          });
          return answer;
        }
        // A call one of the extension's pages in a website's frame can't
        // make itself (see embedded), made here for it, and only for one
        // of its pages: a content script gets no more than Chrome gives it.
        // A user script's message (chrome.userScripts' USER_SCRIPT world),
        // from this extension's own: for runtime.onUserScriptMessage, never
        // onMessage.
        if (message.__egluUserScript === true) {
          const heard = runtime.onUserScriptMessage && runtime.onUserScriptMessage.listeners;
          if (!fromHere || !heard) return undefined;
          let held = false;
          for (const listener of [...heard]) if (run(listener, message.message, sender)) held = true;
          return held || answered ? answer : undefined;
        }
        if (message.__egluCall) {
          if (!background) { setTimeout(silent, 15000); return answer; }
          const { space, method, args } = message.__egluCall;
          // Language detection accepts supplied text only. Content scripts may
          // use it without gaining access to any page, tab or native API.
          if (space === "i18n" && method === "detectLanguage") {
            Promise.resolve().then(() => native("i18n.detectLanguage", args))
              .then((value) => respond({ value }), (e) => respond({ error: String(e && e.message || e) }));
            return answer;
          }
          // Picking a colour reads nothing of the page's, so a content
          // script may ask for it, like language detection.
          if (space === "eyeDropper" && method === "open") {
            Promise.resolve().then(() => native("eyeDropper.open", []))
              .then((value) => respond({ value }), (e) => respond({ error: String(e && e.message || e) }));
            return answer;
          }
          // The extension's own address, as a string: URL's origin of a
          // chrome-extension: address is "null" by the URL standard.
          const own = !!sender && typeof sender.url === "string" && !!ownPlace && sender.url.startsWith(ownPlace);
          if (!own) { respond({ error: "chrome." + space + " isn't available to content scripts" }); return answer; }
          if (space === "tabs" && method === "getCurrent") { respond({ value: sender.tab }); return answer; }
          let ns; try { ns = chrome[space]; } catch (e) {}
          if (!ns || typeof ns[method] !== "function") { respond({ error: "chrome." + space + "." + method + " isn't available" }); return answer; }
          Promise.resolve().then(async () => {
            if (space === "scripting" && method === "executeScript" && args && args[0] && typeof args[0].__egluFunction === "string") {
              const { __egluFunction, args: given, ...details } = args[0];
              if (details.files) throw new Error("Cannot specify both 'func' and 'files'");
              const file = await native("scripting.file", [__egluFunction, given || []]);
              return ns[method]({ ...details, files: [file] });
            }
            return ns[method](...(args || []));
          }).then((value) => respond({ value }), (e) => respond({ error: String(e && e.message || e) }));
          return answer;
        }
      }
      const from = untabbed(sender);
      for (const listener of [...listeners]) if (run(listener, message, from)) keep = true;
      if (internal && !local && !inContent) tell(message, keep || answered ? "answers" : "passes", true);
      if (keep || answered) {
        // Once it has its answer, those who stepped aside may say nothing.
        if (internal && !local && !inContent) answer.then(() => tell(message, "settled", true));
        return answer;
      }
      if (local || !internal) return undefined;
      // Nothing here answers it. In Chrome that leaves the question to the
      // extension's other pages and its worker; WebKit takes the first
      // reply from any of them, an empty one from a page that only listens
      // for something else included, which would arrive before the worker's
      // real answer. So a page that has nothing to say steps aside, and
      // says nothing only once everyone else has had ample time, or as soon
      // as the worker and every other open page have said they let it pass
      // too. (Search)
      if (!background && !inContent) {
        const received = Date.now();
        const key = channel && keyOf(message);
        let check = () => {}, roll = null;
        const done = () => { waiting.delete(check); clearTimeout(late); clearTimeout(roll); };
        const late = setTimeout(() => { done(); silent(); }, 10000);
        // Without the channel (a page in a website's frame), only the wait.
        if (key) {
          // Only what was said about this message, not an identical one a while ago.
          const fresh = (said) => said && said.at >= received - 2000;
          check = () => {
            const entry = verdicts.get(key);
            if (answered || !entry) return;
            const workerSaid = entry.worker;
            const said = [...peers].filter((id) => !deaf.has(id) || entry.pages.has(id)).map((id) => entry.pages.get(id));
            // Someone has answered and it has gone: nothing to wait for.
            if ([workerSaid, ...said].some((p) => fresh(p) && p.verdict === "settled")) { done(); silent(); return; }
            // Someone is answering: wait for them to say it has gone, however
            // long that takes, so this page's nothing never comes first.
            if ([workerSaid, ...said].some((p) => fresh(p) && p.verdict === "answers")) { clearTimeout(late); return; }
            // With no background, nobody is to be heard from there.
            if ((hasWorker && !fresh(workerSaid)) || said.some((p) => !fresh(p))) return;
            done();
            silent();
          };
          waiting.add(check);
          check();
          // Still waiting on someone after a moment: those who don't say
          // they are here within a second are gone, and those who do but
          // have said nothing about this message didn't hear it.
          roll = setTimeout(() => {
            if (answered) return;
            const heard = new Set();
            const hear = (id) => heard.add(id);
            present.add(hear);
            channel.postMessage({ roll: true, from: me });
            setTimeout(() => {
              present.delete(hear);
              for (const id of [...peers]) if (!heard.has(id)) peers.delete(id);
              const entry = verdicts.get(key);
              for (const id of peers) { const p = entry && entry.pages.get(id); if (!p || p.at < received - 2000) deaf.add(id); }
              check();
            }, 1000);
          }, 200);
        }
        return answer;
      }
      return undefined;
    };
    // Only while there is a listener: a page with none says nothing, as it
    // would without the shim. The background's is WebKit's from the start:
    // a worker may add listeners only while it starts, and WebKit wakes it
    // for an event only if it knows a listener for it. (Search)
    let attached = false;
    const attach = () => { if (!attached) { attached = true; add(dispatch); } };
    // runtime.onMessage's carries user scripts' messages too (see above):
    // there while onUserScriptMessage has a listener, whatever onMessage has.
    if (internal && eager) attachForUserScripts = attach;
    const userListening = () => !!(internal && runtime.onUserScriptMessage && runtime.onUserScriptMessage.listeners
      && runtime.onUserScriptMessage.listeners.size);
    put(target, "addListener", (f) => {
      if (typeof f !== "function") return;
      listeners.add(f);
      if (internal && eager) { join(); deliverRelayed = (m, s) => dispatch(m, s, true); }
      attach();
    });
    put(target, "removeListener", (f) => {
      listeners.delete(f);
      if (internal && eager && !listeners.size) leave();
      if (attached && !listeners.size && !(background && eager) && !userListening()) { attached = false; remove(dispatch); }
    });
    put(target, "hasListener", (f) => listeners.has(f));
    put(target, "hasListeners", () => listeners.size > 0);
    if (background && eager) attach();
  };

  // A reply that never came, asked for with a callback: Chrome calls back
  // with lastError set; WebKit calls back with nothing and no error, and
  // code that pings a tab to see whether its script is there waits for
  // ever. An empty answer is null, from the gate above, as in Chrome, and
  // sets nothing. A failure marked as one by the gate is lastError, or a
  // rejection when there is no callback. (Search)
  const isFailure = (reply) => reply !== null && typeof reply === "object" && typeof reply[failure] === "string";
  const replied = (promise, callback, gone) => {
    const settled = Promise.resolve(promise);
    if (!callback) return settled.then((reply) => { if (isFailure(reply)) throw new Error(reply[failure]); return reply; });
    settled.then(
      (reply) => isFailure(reply) ? withLastError(new Error(reply[failure]), () => callback())
        : reply === undefined ? withLastError(new Error(gone), () => callback())
        : callback(reply),
      (error) => withLastError(error, () => callback()));
  };

  // WebKit can lose a worker without knowing, its process stopped along
  // with a tab's, and then answers every message with nothing, for good.
  // So after a message, a page asks the worker itself (its shim answers) at
  // most every few seconds; asked three times, then once more after waking
  // it, and only then is the extension taken up afresh. (Search)
  let heard = 0;
  let checkWorker = () => {};
  if (typeof document !== "undefined" && !inContent && !background && hasWorker) {
    let asking = false;
    checkWorker = () => {
      if (asking || Date.now() - heard < 5000) return;
      asking = true;
      const ping = Object.getPrototypeOf(runtime).sendMessage;
      const ask = () => Promise.race([ping.call(runtime, { __egluPing: true }), new Promise((r) => setTimeout(() => r("late"), 15000))]).catch(() => undefined);
      const pause = (ms) => new Promise((w) => setTimeout(w, ms));
      const tries = [() => ask(), () => pause(1000).then(ask), () => pause(1000).then(ask),
        () => native("background.wake", []).catch(() => {}).then(() => pause(1000)).then(ask)];
      const attempt = (i, last) => i >= tries.length || last === "pong" ? Promise.resolve(last) : tries[i]().then((r) => attempt(i + 1, r));
      const started = Date.now();
      attempt(0).then((r) => {
        // Any real answer from the worker meanwhile says it runs, too.
        if (r === "pong" || heard >= started) heard = Math.max(heard, Date.now());
        else native("background.revive", []).catch(() => {});
      }).finally(() => { asking = false; });
    };
  }

  for (const ns of new Set([chrome, root.browser].filter(Boolean))) {
    const rt = ns.runtime;
    if (rt && typeof rt.sendMessage === "function") {
      const proto = Object.getPrototypeOf(rt);
      const send = (proto && typeof proto.sendMessage === "function" ? proto.sendMessage : rt.sendMessage).bind(rt);
      put(rt, "sendMessage", (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const { message, own } = messageOf(args);
        const ours = !!(message && typeof message === "object" && Object.keys(message).some((k) => k.startsWith("__eglu")));
        // Never heard back by the one that sends it, so said for it.
        if (!inContent && own) tell(message, "passes");
        checkWorker();
        let answer = Promise.resolve(send(...args)).then((r) => { if (r !== undefined) heard = Date.now(); return r; });
        const relayed = !inContent && own && !ours && message !== undefined ? relay(message) : null;
        if (relayed) {
          // A page that took the relayed copy says so at once, and answers
          // when it has one: what WebKit brought wins; when it brought
          // nothing, a page's answer does, if one said it would within a
          // moment (a page that lets it pass says nothing).
          let saidSo = false, answered, gotAnswer = false, wake = () => {};
          const waiter = {
            answering: () => { saidSo = true; wake(); },
            answer: (value) => { if (!gotAnswer) { gotAnswer = true; answered = value; wake(); } },
          };
          relays.set(relayed, waiter);
          const native = answer;
          answer = native.then(async (r) => {
            if (r !== undefined) return r;
            const waitFor = (ms, until) => new Promise((done) => {
              if (until()) return done();
              wake = () => { if (until()) done(); };
              setTimeout(done, ms);
            });
            await waitFor(300, () => saidSo || gotAnswer);
            if (saidSo && !gotAnswer) await waitFor(30000, () => gotAnswer);
            return gotAnswer ? answered : undefined;
          }).finally(() => relays.delete(relayed));
        }
        return replied(answer, callback, "The message port closed before a response was received.");
      });
    }
    const tabs = ns.tabs;
    if (tabs && typeof tabs.sendMessage === "function") {
      const send = tabs.sendMessage.bind(tabs);
      // A message for a tab reaches only its content scripts in WebKit. In
      // Chrome it reaches the extension's own pages in that tab too, framed
      // or the tab's own: 1Password's sign-in banner is framed, and
      // NordPass's sign-in page, a tab of its own, is told by a message to
      // its tab where to go next. So the worker hands it to those pages as
      // well, and the first answer from either wins. (Search)
      const alsoFramed = (answer, tabId, message, options) => {
        if (typeof tabId !== "number") return answer;
        const nav = chrome.webNavigation;
        const wanted = options && typeof options.frameId === "number" ? options.frameId : null;
        const frames = nav && typeof nav.getAllFrames === "function"
          ? Promise.resolve(nav.getAllFrames({ tabId })).then((list) => list || [], () => []) : Promise.resolve([]);
        // The tab's own page, as the tab says, should its frames leave it out.
        const top = (wanted === null || wanted === 0) && typeof tabs.get === "function"
          ? Promise.resolve(tabs.get(tabId)).then((tab) => tab && tab.url, () => null) : Promise.resolve(null);
        const framed = Promise.all([frames, top]).then(([list, url]) => {
          const urls = list.filter((f) => f.url && f.url.startsWith(ownPlace) && (wanted === null || f.frameId === wanted)).map((f) => f.url);
          if (typeof url === "string" && url.startsWith(ownPlace) && !urls.includes(url)) urls.push(url);
          if (!urls.length) return undefined;
          const envelope = { __egluToFrame: { tabId, urls, message } };
          // A framed page hears the worker from WebKit; a tab's own page
          // doesn't (see relay), so it goes over the pages' channel too.
          const natively = Promise.resolve(Object.getPrototypeOf(runtime).sendMessage.call(runtime, envelope)).catch(() => undefined);
          const relayed = relay(envelope);
          if (!relayed) return natively;
          return new Promise((resolve) => {
            // Pages that might take it say so in the first moment, then
            // answer, if only with nothing (one in another tab, at once).
            // The first real answer wins; nothing once every page that
            // spoke has answered and the moment to speak has passed.
            // Embedded pages have no channel, so wait for the native reply too.
            let claims = 1, open = true, done = false;
            const finish = (value) => { if (!done) { done = true; relays.delete(relayed); resolve(value); } };
            const answered = (value) => { if (value !== undefined) finish(value); else if (--claims <= 0 && !open) finish(undefined); };
            relays.set(relayed, {
              answering: () => { claims++; },
              answer: answered,
            });
            natively.then(answered);
            setTimeout(() => { open = false; if (claims <= 0) finish(undefined); }, 300);
            setTimeout(() => finish(undefined), 30000);
          });
        }, () => undefined);
        return new Promise((resolve, reject) => {
          let left = 2, failed = null;
          const none = () => { if (--left === 0) failed ? reject(failed) : resolve(undefined); };
          answer.then((v) => v !== undefined ? resolve(v) : none(), (e) => { failed = e; none(); });
          framed.then((v) => v !== undefined ? resolve(v) : none(), () => none());
        });
      };
      put(tabs, "sendMessage", (tabId, message, options, callback) => {
        if (typeof options === "function") { callback = options; options = undefined; }
        const p = Promise.resolve(options === undefined ? send(tabId, message) : send(tabId, message, options));
        return replied(background ? alsoFramed(p, tabId, message, options) : p, callback, "Could not establish connection. Receiving end does not exist.");
      });
    }
    // browser is the same as chrome in WebKit; if it isn't, its events are
    // gathered too, only when listened to.
    gather(rt && rt.onMessage, ns === chrome, true);
    gather(rt && rt.onMessageExternal, ns === chrome, false);
  }

  // Google Translate uses this API in its worker, popup and content script.
  // WebKit exposes i18n without detectLanguage. The native answer performs
  // bounded on-device language recognition and receives only this string.
  if (chrome.i18n && typeof chrome.i18n.detectLanguage !== "function") {
    const detect = (text, callback) => {
      const answer = (async () => {
        if (typeof text !== "string") throw new TypeError("i18n.detectLanguage requires a string");
        if (!inContent && !embedded) return native("i18n.detectLanguage", [text]);
        const reply = await runtime.sendMessage({ __egluCall: { space: "i18n", method: "detectLanguage", args: [text] } });
        if (!reply) throw new Error("i18n.detectLanguage had no answer from the extension's background");
        if (reply.error) throw new Error(reply.error);
        return reply.value;
      })();
      if (typeof callback !== "function") return answer;
      answer.then((value) => callback(value), (error) => withLastError(error, callback));
    };
    put(chrome.i18n, "detectLanguage", detect);
    if (root.browser && root.browser !== chrome && root.browser.i18n
        && typeof root.browser.i18n.detectLanguage !== "function") put(root.browser.i18n, "detectLanguage", detect);
  }

  // Chromium's EyeDropper, which Mesurer's colour tool uses to take a colour
  // off the page. No web API of WebKit's samples a colour on screen, so the
  // Mac's own sampler answers (ExtensionAnswers). A cancel rejects with a
  // DOMException named AbortError, as Chrome's picker does.
  if (typeof root.EyeDropper !== "function") {
    const abort = () => new DOMException("The user aborted a selection.", "AbortError");
    const pick = async () => {
      if (!inContent && !embedded) return { sRGBHex: await native("eyeDropper.open", []) };
      const reply = await runtime.sendMessage({ __egluCall: { space: "eyeDropper", method: "open", args: [] } });
      if (!reply) throw new Error("EyeDropper had no answer from the extension's background");
      if (reply.error) throw new Error(reply.error);
      return { sRGBHex: reply.value };
    };
    const open = async (options) => {
      const signal = options && options.signal;
      try {
        if (signal && signal.aborted) throw abort();
        if (!signal) return await pick();
        // The Mac's sampler can't be closed from here: an abort answers at
        // once, and a colour picked after it is dropped.
        const aborted = new Promise((_, reject) => signal.addEventListener("abort", () => reject(abort()), { once: true }));
        return await Promise.race([pick(), aborted]);
      } catch (error) {
        throw /AbortError/.test(String(error && error.message || error)) ? abort() : error;
      }
    };
    put(root, "EyeDropper", class EyeDropper { open(options) { return open(options); } });
  }

  // WebKit serves an extension's .wasm files without the application/wasm
  // type, so compiling one as it streams in fails. Most code falls back to
  // fetching it whole; some has no fallback and stops: 1Password's core
  // then says "WASM is not initialized". The extension's own files are
  // compiled whole from the start. (Search)
  if (root.WebAssembly && typeof WebAssembly.instantiateStreaming === "function") {
    const own = (r) => r && typeof r.url === "string" && /^(chrome|webkit)-extension:/.test(r.url);
    const instantiate = WebAssembly.instantiateStreaming.bind(WebAssembly);
    WebAssembly.instantiateStreaming = async (source, imports) => {
      const response = await source;
      return own(response) ? WebAssembly.instantiate(await response.arrayBuffer(), imports) : instantiate(response, imports);
    };
    if (typeof WebAssembly.compileStreaming === "function") {
      const compile = WebAssembly.compileStreaming.bind(WebAssembly);
      WebAssembly.compileStreaming = async (source) => {
        const response = await source;
        return own(response) ? WebAssembly.compile(await response.arrayBuffer()) : compile(response);
      };
    }
  }

  // Files injected through chrome.scripting get the shim in front, in the
  // same world. A click-only grant (activeTab) lets such an injection run
  // where no content script of the manifest's can, so the manifest's entry
  // for the shim (ExtensionPreparation) doesn't reach it. The shim runs
  // once in a world (__egluShim); the page's own world is left alone.
  if (!inContent) {
    for (const scripting of new Set([chrome && chrome.scripting, root.browser && root.browser.scripting])) {
      if (!scripting || typeof scripting.executeScript !== "function") continue;
      const execute = scripting.executeScript.bind(scripting);
      put(scripting, "executeScript", (injection, ...rest) => {
        const files = injection && Array.isArray(injection.files) ? injection.files : null;
        const named = (file) => String(file).replace(/^\.?\/+/, "");
        if (files && files.length && injection.world !== "MAIN" && !files.some((file) => named(file) === "_eglu/shim.js")) {
          injection = Object.assign({}, injection, { files: ["_eglu/shim.js", ...files] });
        }
        return execute(injection, ...rest);
      });
    }
  }

  // Answered here, a callback last or a promise without one.
  const answered = (f) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const answer = (async () => f(...args))();
    if (!callback) return answer;
    answer.then((value) => callback(value), (error) => withLastError(error, callback));
  };
  // Something eGlu doesn't do, refused the way Chrome refuses what it can't:
  // a rejection, or lastError for a callback; never a yes that did nothing.
  const refuse = (what) => answered(() => { throw new Error(what + " isn't available in eGlu"); });

  // Members Chrome has on namespaces WebKit has too, that WebKit leaves
  // out. Plenty are read at the top of a worker, an event to listen to or
  // an enum, where one missing member is a TypeError that stops the whole
  // worker before it has done anything: iCloud Passwords' stopped at
  // webNavigation.onHistoryStateUpdated, before it reached the Passwords
  // app. These events never fire here. (Search)
  const fill = (name, members) => {
    const target = chrome[name];
    if (!target) return;
    for (const [key, value] of Object.entries(members)) {
      let there;
      try { there = target[key]; } catch (e) {}
      if (there === undefined) put(target, key, value);
    }
  };
  const enumOf = (...values) => Object.fromEntries(values.map((v) => [v.toUpperCase().replace(/[-.]/g, "_").replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), v]));
  // runtime's enums, constants a content script reads as its code starts
  // too, where WebKit gives them to the worker only: GPTZero's stopped on
  // OnInstalledReason. (Search)
  fill("runtime", {
    OnInstalledReason: enumOf("install", "update", "chrome_update", "shared_module_update"),
    OnRestartRequiredReason: enumOf("app_update", "os_update", "periodic"),
    PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformNaclArch: { ARM: "arm", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
    RequestUpdateCheckStatus: enumOf("throttled", "no_update", "update_available"),
    ContextType: { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT",
      SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" },
  });

  if (inContent) {
    // A content script reads an extension page's frame as
    // webkit-masked-url://hidden/, src and attribute alike, even one of its
    // own extension's that it put there itself. Chrome gives the address
    // back, and code that posts to the frame with that address as the
    // target origin throws instead. So an address of this extension that
    // its scripts set is what src gives them back, and only that. (Search)
    if (root.HTMLIFrameElement) {
      const given = new WeakMap();
      const remember = (frame, value) => {
        const address = String(value);
        if (ownPlace && address.startsWith(ownPlace)) given.set(frame, address); else given.delete(frame);
      };
      const proto = HTMLIFrameElement.prototype;
      const d = Object.getOwnPropertyDescriptor(proto, "src");
      if (d && d.get && d.set && d.configurable) {
        Object.defineProperty(proto, "src", Object.assign({}, d, {
          get() {
            const shown = d.get.call(this);
            return given.has(this) && shown.startsWith("webkit-masked-url:") ? given.get(this) : shown;
          },
          set(value) { remember(this, value); d.set.call(this, value); },
        }));
        const setAttribute = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function (name, value) {
          if (this instanceof HTMLIFrameElement && String(name).toLowerCase() === "src") remember(this, value);
          return setAttribute.apply(this, arguments);
        };
        const getAttribute = Element.prototype.getAttribute;
        Element.prototype.getAttribute = function (name) {
          const shown = getAttribute.apply(this, arguments);
          if (this instanceof HTMLIFrameElement && String(name).toLowerCase() === "src" && given.has(this)
            && typeof shown === "string" && shown.startsWith("webkit-masked-url:")) return given.get(this);
          return shown;
        };
      }
    }
    return;
  }

  // In a website's frame, everything WebKit keeps to the extension's own
  // process goes through the worker instead. What stays direct is what
  // WebKit lets a content script call too. (Search)
  if (embedded) {
    const direct = new Set(["runtime", "storage", "i18n", "extension", "permissions", "dom", "test"]);
    const ask = (space, method, args) => {
      while (args.length && args[args.length - 1] === undefined) args.pop();
      // A function can't cross the message: its source goes, and the worker
      // injects it from a file of the extension's own (scripting.file). (Search)
      if (space === "scripting" && method === "executeScript" && typeof (args[0] && args[0].func) === "function") {
        args = [{ ...args[0], func: undefined, __egluFunction: args[0].func.toString() }, ...args.slice(1)];
      }
      let payload;
      try { payload = JSON.parse(JSON.stringify(args)); } catch (e) { return Promise.reject(e); }
      return Promise.resolve(Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __egluCall: { space, method, args: payload } })).then((reply) => {
        if (!reply) throw new Error("chrome." + space + "." + method + " had no answer from the extension's background");
        if (reply.error) throw new Error(reply.error);
        return reply.value;
      });
    };
    // Some members WebKit answers from the object itself, ahead of anything
    // set on it (windows.create, update and remove). Put there, ours reads
    // back as WebKit's, and the call still ends the process. A namespace
    // like that is given through a stand-in chrome instead, which has ours
    // for those members and WebKit's own objects for the rest, so listeners
    // still go on WebKit's events. (Search)
    const stand = new Map();
    for (const space of spaces) {
      if (direct.has(space)) continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      const mine = new Map();
      const own = (name, value) => { put(ns, name, value); mine.set(name, value); };
      for (const name of names) {
        if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
        let f; try { f = ns[name]; } catch (e) { continue; }
        if (typeof f !== "function") continue;
        // A port can't be carried over: one that closes at once, as
        // Chrome's does when nothing answers, rather than a dead process.
        if (name === "connect") {
          own(name, (...args) => {
            const port = { name: (args.find((a) => a && typeof a === "object") || {}).name || "", sender: undefined,
              postMessage: () => {}, disconnect: () => {}, onMessage: event(), onDisconnect: event() };
            setTimeout(() => withLastError(new Error("Could not establish connection. Receiving end does not exist."), () => {
              for (const f of [...port.onDisconnect.listeners]) f(port);
            }));
            return port;
          });
          continue;
        }
        own(name, (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = ask(space, name, args);
          // A message nobody in the tab answered reads as Chrome says it.
          if (space === "tabs" && name === "sendMessage") return replied(answer, callback, "Could not establish connection. Receiving end does not exist.");
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
      const lost = new Map([...mine].filter(([name, value]) => ns[name] !== value));
      if (!lost.size) continue;
      stand.set(space, new Proxy(ns, {
        get: (target, key) => lost.has(key) ? lost.get(key) : Reflect.get(target, key),
        defineProperty: (target, key, d) => lost.has(key) && "value" in d ? (lost.set(key, d.value), true) : Reflect.defineProperty(target, key, d),
      }));
    }
    // Set through the fixed accessors above, which take a replacement that
    // still carries the APIs; on browser too, the same object in WebKit.
    if (stand.size) {
      const standIn = new Proxy(chrome, { get: (target, key) => stand.has(key) ? stand.get(key) : Reflect.get(target, key) });
      try { root.chrome = standIn; } catch (e) {}
      try { if (root.browser) root.browser = standIn; } catch (e) {}
    }
  }

  // Native messaging the extension asked for only as an optional
  // permission, which the preparation gave it outright for the shim's way
  // to eGlu: Chrome asks the person before granting it, and so does
  // eGlu, which keeps the answer (ExtensionAnswers, permissions.native).
  const added = /*__EGLU_ADDED__*/[];
  if (added.includes("nativeMessaging") && (manifest.optional_permissions || []).includes("nativeMessaging") && chrome.permissions) {
    const ns = chrome.permissions;
    const split = (p) => {
      const list = (p && p.permissions) || [];
      const rest = { ...(p || {}), permissions: list.filter((x) => x !== "nativeMessaging") };
      const empty = !rest.permissions.length && !(rest.origins && rest.origins.length);
      return { asks: list.includes("nativeMessaging"), rest, empty };
    };
    for (const [name, action] of [["request", "request"], ["contains", "has"], ["remove", "remove"]]) {
      const original = typeof ns[name] === "function" ? ns[name].bind(ns) : null;
      if (!original) continue;
      put(ns, name, (p, callback) => {
        const { asks, rest, empty } = split(p);
        const answer = (async () => {
          if (asks) {
            const yes = await native("permissions.native", [action]);
            if (!yes && action !== "remove") return false;
          }
          return empty ? true : original(rest);
        })();
        if (typeof callback !== "function") return answer;
        answer.then((value) => callback(value), (error) => withLastError(error, callback));
      });
    }
  }

  // A permissions.request from a press on the extension's button that
  // WebKit refuses for want of the press, the extension having awaited
  // something first (Figma): eGlu, which saw the press, asks the same
  // question within ten seconds of it (ExtensionAnswers). WebKit's own is
  // called at once, while the press still counts. (Search)
  if (!inContent && chrome.permissions && typeof chrome.permissions.request === "function") {
    const ns = chrome.permissions;
    const request = ns.request.bind(ns);
    put(ns, "request", (p, callback) => {
      let first;
      try { first = Promise.resolve(request(p)); } catch (e) { first = Promise.reject(e); }
      const answer = first.catch((e) => /user gesture/i.test(String(e && e.message))
        ? native("permissions.afterClick", [(p && p.permissions) || [], (p && p.origins) || []]) : Promise.reject(e));
      if (typeof callback !== "function") return answer;
      answer.then((value) => callback(value), (error) => withLastError(error, callback));
    });
  }

  // Whole namespaces WebKit lacks, answered by eGlu (ExtensionAnswers).
  const define = (name, methods, events = [], extra = {}) => {
    if (chrome[name]) return;
    const api = Object.assign({}, extra);
    for (const m of methods) api[m] = call(name + "." + m);
    for (const e of events) api[e] = event();
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  define("offscreen", ["createDocument", "closeDocument", "hasDocument"], [],
    { Reason: new Proxy({}, { get: (_, key) => String(key) }) });
  // Only what the extension itself is, never another's.
  define("management", ["getSelf", "get"], ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]);

  // Members Chrome has on namespaces WebKit has too, that WebKit leaves
  // out, filled in for the worker and the extension's pages (fill, above).
  fill("webNavigation", {
    onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(), onTabReplaced: event(),
    TransitionType: enumOf("link", "typed", "auto_bookmark", "auto_subframe", "manual_subframe", "generated",
      "start_page", "form_submit", "reload", "keyword", "keyword_generated"),
    TransitionQualifier: enumOf("client_redirect", "server_redirect", "forward_back", "from_address_bar"),
  });
  // Bitwarden's worker reads scripting.ExecutionWorld as it starts.
  fill("scripting", {
    ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" },
    StyleOrigin: { AUTHOR: "AUTHOR", USER: "USER" },
  });
  // The rest of Chrome's members WebKit leaves out, from Search's list: an
  // event that never fires, a constant, or an answer that is true here.
  // What eGlu doesn't do is refused, never answered as done. (Search)
  fill("runtime", {
    onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
    onBrowserUpdateAvailable: event(), onConnectNative: event(), onUserScriptConnect: event(), onUserScriptMessage: event(),
    // eGlu checks the store itself (ExtensionUpdates).
    requestUpdateCheck: answered(() => ({ status: "no_update" })),
    // Chrome's restarts are for ChromeOS kiosks; elsewhere they do nothing.
    restart: () => {}, restartAfterDelay: answered(() => undefined),
    getPackageDirectoryEntry: refuse("runtime.getPackageDirectoryEntry"),
  });
  // A page that listens only for user scripts' messages hears them.
  if (runtime && runtime.onUserScriptMessage && runtime.onUserScriptMessage.listeners) {
    const heard = runtime.onUserScriptMessage, addHeard = heard.addListener;
    heard.addListener = (f) => { addHeard(f); if (attachForUserScripts) attachForUserScripts(); };
  }
  fill("extension", {
    getURL: (path) => runtime.getURL(path), ViewType: { TAB: "tab", POPUP: "popup" },
    sendRequest: (...args) => runtime.sendMessage(...args), onRequest: event(), onRequestExternal: event(),
    getExtensionTabs: () => [], setUpdateUrlData: () => {},
  });
  fill("tabs", {
    TabStatus: enumOf("unloaded", "loading", "complete"), MutedInfoReason: enumOf("user", "capture", "extension"),
    WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    ZoomSettingsMode: enumOf("automatic", "manual", "disabled"), ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" },
    MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2, TAB_INDEX_NONE: -1,
    getZoomSettings: answered(() => ({ mode: "automatic", scope: "per-origin", defaultZoomFactor: 1 })),
    setZoomSettings: refuse("tabs.setZoomSettings"),
    onZoomChange: event(), onSelectionChanged: event(), onActiveChanged: event(), onHighlightChanged: event(),
  });
  if (chrome.tabs && typeof chrome.tabs.query === "function") {
    fill("tabs", {
      getSelected: answered(async (windowId) => (await chrome.tabs.query(typeof windowId === "number" ? { active: true, windowId } : { active: true, currentWindow: true }))[0]),
      getAllInWindow: answered((windowId) => chrome.tabs.query(typeof windowId === "number" ? { windowId } : { currentWindow: true })),
    });
  }
  // Session Buddy's worker listens to onBoundsChanged inside a try, and
  // stopped short of its button's listener. A window's bounds are read when
  // asked for instead.
  fill("windows", {
    onBoundsChanged: event(),
    CreateType: enumOf("normal", "popup", "panel"), WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    WindowState: { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" },
  });
  // Every extension is a tile in the puzzle panel, which is eGlu's toolbar.
  fill("action", {
    getUserSettings: answered(() => ({ isOnToolbar: true })), onUserSettingsChanged: event(),
    setBadgeTextColor: answered(() => undefined), getBadgeTextColor: answered(() => [255, 255, 255, 255]),
  });
  const resourceTypes = enumOf("main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
    "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other");
  fill("webRequest", {
    OnBeforeRequestOptions: { BLOCKING: "blocking", REQUEST_BODY: "requestBody", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
    OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnHeadersReceivedOptions: { BLOCKING: "blocking", RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
    OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnErrorOccurredOptions: { EXTRA_HEADERS: "extraHeaders" },
    ResourceType: resourceTypes, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
    handlerBehaviorChanged: answered(() => undefined), onActionIgnored: event(),
  });
  fill("declarativeNetRequest", {
    GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_SESSION_RULES: 5000,
    MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
    MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
    DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
    getAvailableStaticRuleCount: answered(() => 30000), getDisabledRuleIds: answered(() => []),
    updateStaticRules: refuse("declarativeNetRequest.updateStaticRules"), testMatchOutcome: refuse("declarativeNetRequest.testMatchOutcome"),
    onRuleMatchedDebug: event(),
    RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
      MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
    ResourceType: resourceTypes, HeaderOperation: enumOf("append", "set", "remove"),
    DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
    RequestMethod: enumOf("connect", "delete", "get", "head", "options", "patch", "post", "put", "other"),
    UnsupportedRegexReason: { SYNTAX_ERROR: "syntaxError", MEMORY_LIMIT_EXCEEDED: "memoryLimitExceeded" },
  });
  const contextTypes = enumOf("all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
    "launcher", "browser_action", "page_action", "action");
  fill("contextMenus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
  fill("menus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
  // webRequest listeners with what WebKit refuses a whole listener over,
  // added with what it takes: no ws:// or wss:// pattern (Chrome watches
  // sockets too); no "webtransport" or "webbundle" type, which Chrome's
  // ResourceType lists (AdBlock asks for every type in it, so its worker
  // stopped as it started and nothing was blocked); only the extra options
  // WebKit reads (blocking needs a policy-installed extension in Chrome's
  // MV3 too). One added too late is refused without a throw: a listener
  // for every request can't wait behind a stand-in. (Search)
  if (chrome.webRequest) for (const key of Object.keys(chrome.webRequest)) {
    const target = chrome.webRequest[key];
    if (!/^on[A-Z]/.test(key) || !target || typeof target.addListener !== "function") continue;
    const add = target.addListener.bind(target);
    put(target, "addListener", (listener, filter, spec) => {
      if (filter && Array.isArray(filter.urls)) {
        const urls = filter.urls.filter((u) => !/^wss?:/i.test(u));
        if (!urls.length) return;
        filter = { ...filter, urls };
      }
      if (filter && Array.isArray(filter.types)) {
        const types = filter.types.filter((t) => t !== "webtransport" && t !== "webbundle");
        if (!types.length) return;
        filter = { ...filter, types };
      }
      const late = (e) => { if (!/startup/i.test(String(e && e.message))) throw e; };
      try {
        if (!Array.isArray(spec)) return add(listener, filter);
        const kept = spec.filter((s) => s === "requestHeaders" || s === "responseHeaders" || s === "requestBody");
        try { return add(listener, filter, kept); } catch (e) { if (/startup/i.test(String(e && e.message))) throw e; return add(listener, filter); }
      } catch (e) { late(e); }
    });
  }

  {
    // Rules WebKit can't carry out, a header it doesn't know how to set,
    // say, are refused one by one, where Chrome would take them all. The rest
    // still go in: one rule eGlu can't honour shouldn't cost an extension
    // every other rule, or its startup. What is left out is said in the
    // extension's console. (Search)
    const dnr = chrome.declarativeNetRequest;
    // Before WebKit sees them, rules are put the way it takes them: a
    // redirect to one of the extension's own files by path rather than by
    // address, and without the resource types it has no name for.
    const unknownTypes = new Set(["webtransport", "webbundle", "object"]);
    const base = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
    const misread = (r) => {
      const c = r && r.condition, type = r && r.action && r.action.type;
      return !!(c && typeof c.regexFilter === "string" && c.requestDomains !== undefined
        && (type === "redirect" || type === "modifyHeaders"));
    };
    const mendRule = (rule) => {
      if (!rule || typeof rule !== "object") return rule;
      const r = { ...rule, action: rule.action && { ...rule.action }, condition: rule.condition && { ...rule.condition } };
      const redirect = r.action && r.action.redirect;
      if (redirect && typeof redirect.url === "string" && base && redirect.url.startsWith(base)) {
        r.action.redirect = { extensionPath: "/" + redirect.url.slice(base.length) };
      }
      const c = r.condition;
      if (c && Array.isArray(c.resourceTypes)) {
        c.resourceTypes = c.resourceTypes.filter((t) => !unknownTypes.has(t));
        if (!c.resourceTypes.length) return null;
      }
      if (c && Array.isArray(c.excludedResourceTypes)) c.excludedResourceTypes = c.excludedResourceTypes.filter((t) => !unknownTypes.has(t));
      // A pattern beside a list of sites: WebKit drops the list and takes
      // the rule for every address its pattern matches (see
      // ExtensionPreparation.misreadByWebKit). A redirect or a header
      // change of that shape is left out rather than carried out
      // everywhere: uBlock Origin Lite's strict blocking, `^https?://.*`
      // for thousands of named sites, sent every page to its warning (#709).
      if (misread(r)) {
        try { console.warn("declarativeNetRequest: " + r.action.type + " rule " + r.id + " left out, WebKit would take its pattern for every site, not the ones it names"); } catch (x) {}
        return null;
      }
      return r;
    };
    if (dnr && typeof dnr.isRegexSupported === "function") {
      const original = dnr.isRegexSupported.bind(dnr);
      put(dnr, "isRegexSupported", (options, callback) => {
        const p = Promise.resolve(original(options)).then((r) => r || { isSupported: false, reason: "syntaxError" },
          () => ({ isSupported: false, reason: "syntaxError" }));
        if (typeof callback !== "function") return p;
        p.then((r) => callback(r));
      });
    }
    // WebKit's rules take a narrow kind of regular expression: no `|` and
    // no `(?:`. Tampermonkey's rule for .user.js links has both, so a
    // script couldn't be installed from a link. A pattern that can be
    // written without them, matching exactly the same addresses, becomes
    // that many rules; one that can't (a choice inside a repeated group, a
    // look-around) is left out as before. Nothing is widened: every rule
    // matches what its pattern matched.
    const expandRegex = (source, limit = 24) => {
      let i = 0;
      // An atom repeated a counted number of times, a{2,4}, written out
      // as a a a? a?: the same strings, without the braces WebKit refuses.
      const counted = (atom) => {
        const m = /^\{(\d+)(,(\d*))?\}/.exec(source.slice(i));
        if (!m) return atom;
        const least = Number(m[1]), most = m[2] === undefined ? least : m[3] === "" ? null : Number(m[3]);
        if (most === null || most < least || most > 12) return null;
        i += m[0].length;
        return atom.repeat(least) + (atom + "?").repeat(most - least);
      };
      const alternatives = () => {
        let options = [""];
        const all = [];
        while (i < source.length) {
          const c = source[i];
          if (c === "\\") {
            const kind = source[i + 1];
            const size = kind === "x" ? 4 : kind === "c" ? 3
              : kind === "u" ? (source[i + 2] === "{" ? source.indexOf("}", i) + 1 - i : 6) : 2;
            if (size < 2 || /[1-9]/.test(kind || "")) return null;
            const t = source.slice(i, i + size);
            i += size;
            const piece = counted(t);
            if (piece === null) return null;
            options = options.map((o) => o + piece);
            continue;
          }
          if (c === "[") {
            let j = i + 1;
            if (source[j] === "^") j++;
            if (source[j] === "]") j++;
            while (j < source.length && source[j] !== "]") { if (source[j] === "\\") j++; j++; }
            const t = source.slice(i, j + 1);
            i = j + 1;
            const piece = counted(t);
            if (piece === null) return null;
            options = options.map((o) => o + piece);
            continue;
          }
          if (c === "|") { all.push(...options); options = [""]; i++; continue; }
          if (c === ")") break;
          if (c === "(") {
            i++;
            if (source.startsWith("?:", i)) i += 2;
            else if (source[i] === "?") return null;
            const inner = alternatives();
            if (inner === null || source[i] !== ")") return null;
            i++;
            if (/^[*+?{]/.test(source[i] || "")) {
              if (inner.length > 1 || source[i] === "{") return null;
              options = options.map((o) => o + "(" + inner[0] + ")");
              continue;
            }
            options = options.flatMap((o) => inner.map((x) => o + x));
            if (options.length > limit) return null;
            continue;
          }
          i++;
          const piece = /[.\w/:-]/.test(c) ? counted(c) : c;
          if (piece === null) return null;
          options = options.map((o) => o + piece);
        }
        all.push(...options);
        return all.length > limit ? null : all;
      };
      const out = alternatives();
      return out === null || i !== source.length ? null : out;
    };
    // The rules made from one are kept out of sight: the extension sees its
    // own, and taking it away takes them too. Their ids come from the
    // rule's own, so nothing has to be remembered, a relaunch, a worker
    // started afresh or a second page all know which they are.
    const madeBase = 1000000000, madeStride = 32;
    const madeIds = (id) => Number.isInteger(id) && id >= 1 && id < 30000000
      ? Array.from({ length: madeStride - 1 }, (_, k) => madeBase + id * madeStride + k + 1) : [];
    const madeFrom = (id, present) => {
      if (!Number.isInteger(id) || id <= madeBase) return null;
      const offset = id - madeBase, k = offset % madeStride, from = (offset - k) / madeStride;
      return k && present.has(from) ? from : null;
    };
    // A rule is one made from another only when it is that rule but for
    // its pattern: an extension's own rule whose id happens to fall in the
    // range stays its own.
    const canonical = (v) => Array.isArray(v) ? "[" + v.map(canonical).join(",") + "]"
      : v && typeof v === "object" ? "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canonical(v[k])).join(",") + "}"
      : JSON.stringify(v);
    const shape = (r) => canonical({ ...r, id: 0, condition: { ...(r.condition || {}), regexFilter: "" } });
    const families = (all) => {
      const byId = new Map(all.map((r) => [r.id, r]));
      const present = new Set(byId.keys());
      const parentOf = new Map(), children = new Map();
      for (const r of [...all].sort((a, b) => a.id - b.id)) {
        const from = madeFrom(r.id, present);
        if (from === null || shape(r) !== shape(byId.get(from))) continue;
        parentOf.set(r.id, from);
        children.set(from, (children.get(from) || []).concat(r));
      }
      // The extension's own rule as it gave it: its pattern again one
      // that matches what all of its parts match.
      const whole = (r) => {
        const kids = children.get(r.id);
        if (!kids) return r;
        const regexFilter = "(?:" + [r, ...kids].map((x) => x.condition.regexFilter).join("|") + ")";
        return { ...r, condition: { ...r.condition, regexFilter } };
      };
      return { parentOf, whole };
    };
    const spread = (name, rule, taken) => {
      const c = rule && rule.condition;
      const pattern = c && c.regexFilter;
      if (typeof pattern !== "string" || !/\||\(\?:|\{\d/.test(pattern)) return [rule];
      const substitution = rule.action && rule.action.redirect && rule.action.redirect.regexSubstitution;
      if (typeof substitution === "string" && /\\[1-9]/.test(substitution)) return [rule];
      const patterns = expandRegex(pattern);
      if (!patterns || !patterns.length) return [rule];
      const ids = madeIds(rule.id);
      // An id past what the scheme holds, or one already an extension's
      // own: this rule isn't written out, and is left out as before.
      if (patterns.length > 1 && (ids.length < patterns.length - 1 || ids.slice(0, patterns.length - 1).some((id) => taken.has(id)))) return [rule];
      return patterns.map((regexFilter, k) => ({ ...rule, id: k === 0 ? rule.id : ids[k - 1], condition: { ...c, regexFilter } }));
    };
    const rawGet = {};
    for (const [get, name] of [["getSessionRules", "updateSessionRules"], ["getDynamicRules", "updateDynamicRules"]]) {
      if (!dnr || typeof dnr[get] !== "function") continue;
      const original = dnr[get].bind(dnr);
      rawGet[name] = () => Promise.resolve(original()).then((r) => r || []);
      put(dnr, get, (filter, callback) => {
        if (typeof filter === "function") { callback = filter; filter = undefined; }
        const p = rawGet[name]().then((all) => {
          const { parentOf, whole } = families(all);
          const own = all.filter((r) => !parentOf.has(r.id)).map(whole);
          const ids = filter && Array.isArray(filter.ruleIds) ? new Set(filter.ruleIds) : null;
          return ids ? own.filter((r) => ids.has(r.id)) : own;
        });
        if (typeof callback !== "function") return p;
        p.then((r) => callback(r), (e) => withLastError(e, callback));
      });
    }
    if (dnr) for (const name of ["updateSessionRules", "updateDynamicRules"]) {
      if (typeof dnr[name] !== "function") continue;
      const original = dnr[name].bind(dnr);
      put(dnr, name, (options = {}, callback) => {
        const ready = (rawGet[name] ? rawGet[name]() : Promise.resolve([])).catch(() => []).then((all) => {
          const present = new Set(all.map((r) => r.id));
          const { parentOf } = families(all);
          if (options && Array.isArray(options.removeRuleIds)) {
            const gone = new Set(options.removeRuleIds);
            const extra = all.map((r) => r.id).filter((id) => gone.has(parentOf.get(id)));
            if (extra.length) options = { ...options, removeRuleIds: options.removeRuleIds.concat(extra) };
          }
          if (options && Array.isArray(options.addRules)) {
            const leaving = new Set(options.removeRuleIds || []);
            const taken = new Set([...present].filter((id) => !leaving.has(id) && !leaving.has(parentOf.get(id))));
            options.addRules.forEach((r) => r && taken.add(r.id));
            options = { ...options, addRules: options.addRules.map(mendRule).filter(Boolean).flatMap((r) => spread(name, r, taken)) };
          }
        });
        const attempt = async (opts, left) => {
          try { return await original(opts); }
          catch (e) {
            // WebKit builds one content blocker of an extension's rules,
            // and it can't hold rules for some sites beside rules for all
            // but some: Tampermonkey's rule for any .user.js link, all but
            // its own sites, kept every other rule from loading. The
            // all-but rules are left out, as a refused rule is.
            if (/Unable to load declarativeNetRequest rules/.test(String(e && e.message)) && Array.isArray(opts.addRules) && left > 0) {
              const excluding = (r) => { const c = r && r.condition; return !!(c && (c.excludedRequestDomains || c.excludedInitiatorDomains || c.excludedDomains)); };
              const narrowing = (r) => { const c = r && r.condition; return !!(c && (c.requestDomains || c.initiatorDomains || c.domains)); };
              if (opts.addRules.some(excluding) && opts.addRules.some(narrowing)) {
                for (const rule of opts.addRules.filter(excluding)) {
                  const kind = rule && rule.action && rule.action.type || "?";
                  try { console.warn("declarativeNetRequest: " + kind + " rule " + (rule && rule.id) + " left out, it excludes sites beside rules for given sites, which WebKit can't load together"); } catch (x) {}
                }
                return attempt({ ...opts, addRules: opts.addRules.filter((r) => !excluding(r)) }, left - 1);
              }
            }
            const at = /rule at index (\d+)/.exec(String(e && e.message));
            if (!at || !Array.isArray(opts.addRules) || left <= 0) throw e;
            const index = Number(at[1]);
            const rule = opts.addRules[index];
            try { console.warn("declarativeNetRequest: rule " + (rule && rule.id) + " left out, " + e.message); } catch (x) {}
            return attempt({ ...opts, addRules: opts.addRules.filter((_, i) => i !== index) }, left - 1);
          }
        };
        const p = ready.then(() => attempt(options, 100));
        if (typeof callback !== "function") return p;
        p.then(() => callback(), (e) => withLastError(e, callback));
      });
    }
  }

  // Small differences from Chrome that stop code that expects Chrome's.
  // (Search)
  // A menu item for the old toolbar button or an app launcher: the
  // button's menu now, and no launcher at all, where WebKit refuses both.
  for (const name of ["contextMenus", "menus"]) {
    const menus = chrome[name];
    if (!menus || typeof menus.create !== "function" || typeof menus.update !== "function") continue;
    const mend = (props) => {
      if (!props || !Array.isArray(props.contexts)) return props;
      const contexts = [...new Set(props.contexts.map((c) => c === "browser_action" || c === "page_action" ? "action" : c).filter((c) => c !== "launcher"))];
      return { ...props, contexts: contexts.length ? contexts : ["page"] };
    };
    const create = menus.create.bind(menus), update = menus.update.bind(menus);
    put(menus, "create", (props, ...rest) => create(mend(props), ...rest));
    put(menus, "update", (id, props, ...rest) => update(id, mend(props), ...rest));
  }
  // An item made with Object.create(null): Chrome stores it, WebKit throws
  // that an object is expected.
  for (const area of ["local", "sync", "session"]) {
    const store = chrome.storage && chrome.storage[area];
    if (!store || typeof store.set !== "function") continue;
    const set = store.set.bind(store);
    put(store, "set", (items, ...rest) => set(items && typeof items === "object" && Object.getPrototypeOf(items) === null ? Object.assign({}, items) : items, ...rest));
  }
  // Tabs as Chrome describes them. Every tab has a groupId, -1 in no
  // group, which code tests before anything else; eGlu has no tab groups.
  // An extension with "tabs" sees every tab's address, title and icon, as
  // in Chrome, where WebKit shows them only on sites it has host access
  // to: a tab manager's list was blank. eGlu fills in what WebKit left
  // blank, by the tab's place in the space (ExtensionAnswers,
  // tabs.describe); another extension's pages stay blank. (Search)
  if (chrome.tabs) {
    const tabs = chrome.tabs;
    const seesTabs = [...(manifest.permissions || []), ...(manifest.optional_permissions || [])].includes("tabs");
    const isTab = (t) => t && typeof t === "object" && typeof t.id === "number";
    // The space's one window, as WebKit numbers it; asked each time, as
    // cheap as a question to WebKit is.
    const getAllWindows = chrome.windows && typeof chrome.windows.getAll === "function" ? chrome.windows.getAll.bind(chrome.windows) : null;
    const spaceWindow = () => getAllWindows
      ? Promise.resolve(getAllWindows({ windowTypes: ["normal"] })).then((all) => all && all[0] ? all[0].id : null, () => null)
      : Promise.resolve(null);
    // WebKit's own, for whether a tab is still where it was.
    const where = typeof tabs.get === "function" ? tabs.get.bind(tabs) : null;
    // Mends in place; a promise only when eGlu has to be asked.
    const mend = (list) => {
      const found = list.filter(isTab);
      for (const t of found) if (t.groupId === undefined) try { t.groupId = -1; } catch (e) {}
      const candidates = seesTabs && where ? found.filter((t) => (!t.url || !t.favIconUrl) && t.index >= 0 && t.index < 1e6) : [];
      if (!candidates.length) return null;
      // By place in the space's window: a popup window's tab
      // (ExtensionPopupWindow) has a place of its own, not the space's.
      return spaceWindow().then((id) => {
        const blind = candidates.filter((t) => t.windowId === id);
        return blind.length ? native("tabs.describe", [blind.map((t) => t.index)]).then((info) => [blind, info]) : [blind, []];
      }).then(async ([blind, info]) => {
        // eGlu finds a tab by its place: a tab that has moved since, or
        // whose place another took, is left as WebKit gave it.
        const still = await Promise.all(blind.map((t) => Promise.resolve(where(t.id)).then(
          (now) => !!now && now.index === t.index && now.windowId === t.windowId, () => false)));
        blind.forEach((t, i) => {
          const d = info && info[i];
          if (!d || !still[i]) return;
          try {
            if (d.url && !t.url) t.url = d.url;
            if (d.title && !t.title) t.title = d.title;
            if (d.favIconUrl && !t.favIconUrl) t.favIconUrl = d.favIconUrl;
          } catch (e) {}
        });
      }, () => {});
    };
    // A window's tabs, when it came with them; never the window, which has
    // a numeric id too but no place in a row.
    const tabsIn = (value) => Array.isArray(value) ? value.flatMap(tabsIn)
      : value && Array.isArray(value.tabs) ? value.tabs : isTab(value) && typeof value.index === "number" ? [value] : [];
    const mendResult = (target, name) => {
      const original = target && typeof target[name] === "function" ? target[name].bind(target) : null;
      if (!original) return;
      put(target, name, (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const answer = Promise.resolve(original(...args)).then(async (value) => { await mend(tabsIn(value)); return value; });
        if (!callback) return answer;
        answer.then((value) => callback(value), (error) => withLastError(error, callback));
      });
    };
    for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate", "move", "reload"]) mendResult(tabs, name);
    if (seesTabs) for (const name of ["get", "getAll", "getCurrent", "getLastFocused", "create"]) mendResult(chrome.windows, name);
    // Listeners given a tab: the tab is mended before they see it. An event
    // held for that holds back the ones after it, so they still arrive in
    // WebKit's order.
    let held = null;
    const mendArgs = (target, positions, told) => {
      if (!target || typeof target.addListener !== "function") return;
      const add = target.addListener.bind(target), remove = target.removeListener.bind(target), has = target.hasListener.bind(target);
      const wrapped = new WeakMap();
      const wrap = (f) => {
        let w = wrapped.get(f);
        if (w) return w;
        const state = new Map();
        w = function (...args) {
          const run = () => { if (told) told(args, state); return f.apply(this, args); };
          const pending = mend(positions.map((i) => args[i]));
          if (!pending && !held) return run();
          // The listener's own promise isn't waited for: one that waits for
          // a later event would hold that event back for good.
          const turn = Promise.all([held, pending]).then(() => { run(); }).catch((e) => { setTimeout(() => { throw e; }); });
          held = turn;
          turn.then(() => { if (held === turn) held = null; });
        };
        wrapped.set(f, w);
        return w;
      };
      put(target, "addListener", (f, ...rest) => typeof f === "function" ? add(wrap(f), ...rest) : add(f, ...rest));
      put(target, "removeListener", (f) => remove((typeof f === "function" && wrapped.get(f)) || f));
      put(target, "hasListener", (f) => has((typeof f === "function" && wrapped.get(f)) || f));
    };
    mendArgs(tabs.onCreated, [0]);
    // What changed, in onUpdated's changeInfo. Without host access WebKit
    // blanks url and title there ("") and leaves favIconUrl out, and a tab
    // manager reads them there. A blanked one is filled from the tab; one
    // left out is added when it differs from what this listener last saw.
    const told = seesTabs ? (args, state) => {
      const info = args[1], tab = args[2];
      if (!info || typeof info !== "object" || !isTab(tab) || !tab.url) return;
      const before = state.get(tab.id);
      const fill = (key, changed) => {
        const value = tab[key];
        if (value && (info[key] === "" || (info[key] === undefined && changed))) try { info[key] = value; } catch (e) {}
      };
      fill("url", before ? before.url !== tab.url : info.status === "loading");
      fill("title", !!before && before.title !== tab.title);
      fill("favIconUrl", !!before && before.favIconUrl !== tab.favIconUrl);
      state.set(tab.id, { url: tab.url, title: tab.title, favIconUrl: tab.favIconUrl });
    } : null;
    mendArgs(tabs.onUpdated, [2], told);
    // Given no tab, but in line behind the ones that are.
    if (seesTabs) for (const name of ["onActivated", "onHighlighted", "onMoved", "onRemoved", "onAttached", "onDetached", "onReplaced"]) mendArgs(tabs[name], []);
  }
  // Storage an administrator's policy sets. eGlu has no policies, so it
  // holds nothing; 1Password's worker listens to it as it starts. Asked
  // with defaults (an object), the defaults are the answer, as Chrome's.
  const unset = (keys) => keys && typeof keys === "object" && !Array.isArray(keys) ? { ...keys } : {};
  fill("storage", {
    managed: { get: answered(unset), getBytesInUse: answered(() => 0), onChanged: event() },
    AccessLevel: { TRUSTED_CONTEXTS: "TRUSTED_CONTEXTS", TRUSTED_AND_UNTRUSTED_CONTEXTS: "TRUSTED_AND_UNTRUSTED_CONTEXTS" },
  });

  // A tab whose page isn't loaded (frozen, or not shown since eGlu
  // started) has no web view, and WebKit refuses to list its frames: "Tab
  // not found". iCloud Passwords lists every tab's frames as its worker
  // starts, and stopped at the first such tab, leaving the tabs after it
  // unwatched. It has no frames loaded, so it is answered with none; a tab
  // that isn't there at all is still refused.
  {
    const nav = chrome.webNavigation, tabs = chrome.tabs;
    if (nav && typeof nav.getAllFrames === "function" && tabs && typeof tabs.get === "function") {
      const getAllFrames = nav.getAllFrames.bind(nav), get = tabs.get.bind(tabs);
      put(nav, "getAllFrames", answered(async (details) => {
        try { return await getAllFrames(details); } catch (error) {
          if (!/tab not found/i.test(String(error && error.message))) throw error;
          const there = await Promise.resolve().then(() => get(details && details.tabId)).then((tab) => !!tab, () => false);
          if (there) return [];
          throw error;
        }
      }));
    }
  }

  // A whole namespace WebKit lacks, for an extension that asks for its
  // permission, as Chrome gives it only then.
  const asks = (permission) => [...(manifest.permissions || []), ...(manifest.optional_permissions || [])].includes(permission);
  const add = (name, api) => {
    if (chrome[name] || !asks(name)) return;
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  // Chrome's own settings. Password managers read them as they start, and
  // ask the browser to stop offering to save and fill passwords: iCloud
  // Passwords' worker and popup stopped at chrome.privacy. eGlu for Mac
  // saves and fills none itself, so those read as off. None is eGlu's to
  // hand an extension: each says it can't be changed, and a change is
  // refused. The rest are there, so code that reaches for one doesn't
  // stop, but say they aren't available rather than make up a value.
  {
    const off = new Set(["autofillAddressEnabled", "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled"]);
    const setting = (path, value) => ({
      get: answered(() => {
        if (value === undefined) throw new Error(`privacy.${path} isn't available in eGlu`);
        return { value, levelOfControl: "not_controllable" };
      }),
      set: answered(() => { throw new Error(`privacy.${path} can't be changed in eGlu`); }),
      clear: answered(() => undefined),
      onChange: event(),
    });
    const group = (prefix, names) => Object.fromEntries(names.map((n) => [n, setting(`${prefix}.${n}`, prefix === "services" && off.has(n) ? false : undefined)]));
    add("privacy", {
      services: group("services", ["alternateErrorPagesEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled",
        "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled", "safeBrowsingExtendedReportingEnabled",
        "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
      network: group("network", ["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
      websites: group("websites", ["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled", "hyperlinkAuditingEnabled",
        "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled", "thirdPartyCookiesAllowed", "topicsEnabled"]),
      IPHandlingPolicy: enumOf("default", "default_public_and_private_interfaces", "default_public_interface_only", "disable_non_proxied_udp"),
    });
  }
  // WebKit keeps the notifications permission and gives no namespace
  // (27.0.1); 1Password's worker listens to its events as it starts, and
  // stopped there. Nothing is shown yet. A notification asked for is given
  // its id, so a flow that waits on one goes on, and the permission level
  // reads denied, which an extension that checks first finds.
  {
    let made = 0;
    add("notifications", {
      create: answered((id) => typeof id === "string" && id ? id : `eglu-${++made}`),
      update: answered(() => false), clear: answered(() => false), getAll: answered(() => ({})),
      getPermissionLevel: answered(() => "denied"),
      onClicked: event(), onButtonClicked: event(), onClosed: event(), onPermissionLevelChanged: event(), onShowSettings: event(),
      TemplateType: enumOf("basic", "image", "list", "progress"), PermissionLevel: enumOf("granted", "denied"),
    });
  }

  // chrome.idle and chrome.power, the Mac's own (ExtensionAnswers), which
  // WebKit lacks. 1Password and Bitwarden lock their vaults by idle when
  // the Mac goes idle or its screen locks; without it they never did. The
  // state is asked every 15 seconds while anyone listens, the way Chrome
  // notices it on its own. (Search)
  {
    const changed = event(), listen = changed.addListener, unlisten = changed.removeListener;
    let every = 60, state = "active", timer = null;
    changed.addListener = (f) => {
      listen(f);
      if (timer || !changed.listeners.size) return;
      timer = setInterval(() => native("idle.queryState", [every]).then((now) => {
        if (now === state) return;
        state = now;
        for (const g of [...changed.listeners]) { try { g(now); } catch (e) { setTimeout(() => { throw e; }); } }
      }).catch(() => {}), 15000);
    };
    // Nobody left to tell: the asking stops.
    changed.removeListener = (f) => {
      unlisten(f);
      if (timer && !changed.listeners.size) { clearInterval(timer); timer = null; }
    };
    add("idle", {
      queryState: call("idle.queryState"), getAutoLockDelay: call("idle.getAutoLockDelay"),
      setDetectionInterval: (seconds) => { every = Math.max(15, Number(seconds) || 60); },
      onStateChanged: changed, IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" },
    });
  }
  add("power", {
    requestKeepAwake: call("power.requestKeepAwake"), releaseKeepAwake: call("power.releaseKeepAwake"),
    reportActivity: call("power.reportActivity"), Level: { SYSTEM: "system", DISPLAY: "display" },
  });
  // chrome.identity, which WebKit lacks: an extension's sign-in through its
  // provider's page (launchWebAuthFlow), in a tab in front, or out of sight
  // for a flow that doesn't ask to be interactive, as Chrome runs one. The
  // answer is the address the page heads for on the extension's own
  // https://<id>.chromiumapp.org/, which is never loaded (ExtensionAuth).
  // eGlu has no Google account signed in: getAuthToken is refused. (Search)
  add("identity", {
    launchWebAuthFlow: call("identity.launchWebAuthFlow"),
    getRedirectURL: (path = "") => "https://" + runtime.id + ".chromiumapp.org/" + String(path).replace(/^\//, ""),
    getAuthToken: answered(() => { throw new Error("getAuthToken needs a Google account signed in to Chrome, which eGlu doesn't have"); }),
    getProfileUserInfo: answered(() => ({ email: "", id: "" })),
    getAccounts: answered(() => []),
    removeCachedAuthToken: answered(() => undefined), clearAllCachedAuthTokens: answered(() => undefined),
    onSignInChanged: event(),
    AccountStatus: { SYNC: "SYNC", ANY: "ANY" },
  });

  // chrome.userScripts, which WebKit lacks (27.0.1): Tampermonkey's and
  // Violentmonkey's scripts, carried out through WebKit's registered
  // content scripts. eGlu writes each into a file of the extension's, as
  // content scripts come from files, wrapped so the globs Chrome takes are
  // honoured and, for Chrome's USER_SCRIPT world, so its messages reach
  // onUserScriptMessage rather than the extension's onMessage
  // (ExtensionAnswers, userScripts.*). The list is kept by eGlu for the
  // space, and registered again whenever the worker starts. (Search)
  if (asks("userScripts") && !chrome.userScripts && chrome.scripting && typeof chrome.scripting.registerContentScripts === "function") {
    const scripting = chrome.scripting;
    const tag = "eglu-us-";
    const content = async (script) => ({
      id: tag + script.id,
      matches: script.matches && script.matches.length ? script.matches : ["*://*/*"],
      excludeMatches: script.excludeMatches || [],
      js: [await native("userScripts.file", [script])],
      runAt: script.runAt || "document_idle",
      allFrames: !!script.allFrames,
      world: script.world === "MAIN" ? "MAIN" : "ISOLATED",
      persistAcrossSessions: false,
    });
    const registered = async () => (await scripting.getRegisteredContentScripts()).filter((s) => s.id.startsWith(tag));
    const list = () => native("userScripts.list", []).then((l) => l || []);
    // eGlu changes the list in one go: two contexts registering at once
    // both keep theirs. One change at a time from here, too.
    const change = (what) => native("userScripts.change", [what]);
    let turn = Promise.resolve();
    const inTurn = (f) => (...args) => {
      const run = turn.then(() => f(...args));
      turn = run.catch(() => {});
      return run;
    };
    const sync = async () => {
      const want = await list();
      const have = new Set((await registered()).map((s) => s.id));
      const missing = want.filter((s) => !have.has(tag + s.id));
      if (!missing.length) return;
      const scripts = await Promise.all(missing.map(content));
      // Two starts of the worker racing each other: the later one takes
      // the registration over.
      await scripting.registerContentScripts(scripts).catch(async (e) => {
        if (!/duplicate/i.test(String(e && e.message))) throw e;
        await scripting.unregisterContentScripts({ ids: scripts.map((s) => s.id) }).catch(() => {});
        await scripting.registerContentScripts(scripts);
      });
      // A page may have taken one out of the list meanwhile: what is no
      // longer listed doesn't stay registered.
      const listed = new Set((await list()).map((s) => tag + s.id));
      const gone = scripts.map((s) => s.id).filter((id) => !listed.has(id));
      if (gone.length) await scripting.unregisterContentScripts({ ids: gone }).catch(() => {});
    };
    const pick = (filter, l) => filter && Array.isArray(filter.ids) ? l.filter((s) => filter.ids.includes(s.id)) : l;
    const api = {
      register: inTurn(async (scripts) => {
        const made = await Promise.all(scripts.map(content));
        // Into the list first, where a taken id is refused; out again if
        // WebKit refuses them.
        await change({ add: scripts });
        try { await scripting.registerContentScripts(made); } catch (e) {
          // The worker, starting, may have registered them from the list
          // first (sync): they are there, and stay in the list.
          const there = new Set((await registered().catch(() => [])).map((s) => s.id));
          if (/duplicate/i.test(String(e && e.message)) && made.every((s) => there.has(s.id))) return;
          await change({ remove: scripts.map((s) => s.id) }).catch(() => {});
          throw e;
        }
      }),
      update: inTurn(async (scripts) => {
        const l = await list();
        const before = scripts.map((s) => {
          const old = l.find((o) => o.id === s.id);
          if (!old) throw new Error("Script with id '" + s.id + "' does not exist");
          return old;
        });
        // The new ones made before the old ones go, and the old ones put
        // back if WebKit refuses the new.
        const made = await Promise.all(before.map((old, i) => content({ ...old, ...scripts[i] })));
        const was = await Promise.all(before.map(content));
        await scripting.unregisterContentScripts({ ids: made.map((s) => s.id) }).catch(() => {});
        try { await scripting.registerContentScripts(made); } catch (e) {
          await scripting.registerContentScripts(was).catch(() => {});
          throw e;
        }
        await change({ update: scripts });
      }),
      unregister: inTurn(async (filter) => {
        const gone = pick(filter, await list());
        const ids = (await registered()).map((s) => s.id).filter((id) => gone.some((g) => tag + g.id === id));
        if (ids.length) await scripting.unregisterContentScripts({ ids });
        await change({ remove: gone.map((s) => s.id) });
      }),
      getScripts: async (filter) => pick(filter, await list()),
      configureWorld: (properties) => native("userScripts.world", [properties || {}]),
      getWorldConfigurations: () => native("userScripts.worlds", []),
      resetWorldConfiguration: (worldId) => native("userScripts.world", [{ worldId, reset: true }]),
      execute: async (injection) => {
        const file = await native("userScripts.file", [{ id: "execute-" + Date.now(), js: injection.js || [], world: injection.world }]);
        return scripting.executeScript({ target: injection.target, files: [file], world: injection.world === "MAIN" ? "MAIN" : "ISOLATED",
          injectImmediately: !!injection.injectImmediately });
      },
    };
    const callbacks = Object.fromEntries(Object.entries(api).map(([k, f]) => [k, (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    }]));
    const userScripts = { ...callbacks, ExecutionWorld: { MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" } };
    put(chrome, "userScripts", userScripts);
    if (root.browser && root.browser !== chrome && !root.browser.userScripts) put(root.browser, "userScripts", userScripts);
    // In turn with this context's own changes, as one of them.
    if (background) inTurn(sync)().catch((e) => { try { console.warn("userScripts: " + e.message); } catch (x) {} });
    // A user script's port comes named with eGlu's mark (see the file's
    // wrapper): for onUserScriptConnect, never onConnect's own listeners.
    const onConnect = runtime.onConnect, toUser = runtime.onUserScriptConnect;
    if (onConnect && typeof onConnect.addListener === "function" && toUser && toUser.listeners) {
      const marker = "eglu-us:";
      const add = onConnect.addListener.bind(onConnect), remove = onConnect.removeListener.bind(onConnect);
      const wrapped = new Map();
      try {
        add((port) => {
          if (!String(port.name).startsWith(marker)) return;
          const view = Object.create(port, { name: { value: port.name.slice(marker.length) } });
          for (const f of [...toUser.listeners]) f(view);
        });
      } catch (e) {}
      // One wrapper for each listener, as the extension knows it by that.
      put(onConnect, "addListener", (listener) => {
        if (typeof listener !== "function") return add(listener);
        let w = wrapped.get(listener);
        if (!w) {
          w = (port) => { if (!String(port.name).startsWith(marker)) return listener(port); };
          wrapped.set(listener, w);
        }
        return add(w);
      });
      put(onConnect, "removeListener", (listener) => remove(wrapped.get(listener) || listener));
      if (typeof onConnect.hasListener === "function") {
        const has = onConnect.hasListener.bind(onConnect);
        put(onConnect, "hasListener", (listener) => has(wrapped.get(listener) || listener));
      }
    }
  }

  // Chrome's old FileSystem API, which WebKit never had: requestFileSystem,
  // entries, FileWriter and `filesystem:` URLs. Extensions still save to it:
  // GoFullPage writes every capture there and shows, copies and downloads it
  // by a `filesystem:<origin>/persistent/...` URL it builds itself. So it is
  // rebuilt on the origin private file system: PERSISTENT and TEMPORARY are
  // the folders "persistent" and "temporary" at its root, so a filesystem: URL
  // and the file it names have the same path. WebKit can't load that scheme,
  // so where such a URL is handed to something that loads it is swapped for
  // the file: a blob: URL in an image, a link or fetch; a data: URL for a
  // download or a new tab, which eGlu loads outside this page. The
  // extension's pages only: a worker has no DOM to mend, and a content
  // script shares the page's origin. (Search)
  (() => {
    if (root.requestFileSystem || root.webkitRequestFileSystem || typeof document === "undefined"
        || !(root.navigator && navigator.storage && navigator.storage.getDirectory)) return;

    const TEMPORARY = 0, PERSISTENT = 1;
    const kinds = ["temporary", "persistent"];
    // Chrome answers with DOMExceptions whose name says what went wrong; the
    // legacy code comes with the name (NotFoundError is 8, and so on).
    const fail = (name, message) => new DOMException(message || name, name);
    const asError = (e) => e instanceof DOMException ? e : fail(e && e.name || "InvalidStateError", e && e.message || String(e));
    // Chrome calls back later, never in the same turn, success or not.
    // A callback that throws is reported as uncaught, not as a rejection.
    const invoke = (f, v) => { try { f(v); } catch (e) { setTimeout(() => { throw e; }); } };
    const settle = (promise, success, error) => {
      promise.then((v) => { if (typeof success === "function") invoke(success, v); },
        (e) => { if (typeof error === "function") invoke(error, asError(e)); });
    };

    // Paths are kept as their segments; "/a/b" is ["a", "b"].
    const segments = (base, path) => {
      path = String(path ?? "");
      const out = path.startsWith("/") ? [] : base.split("/").filter(Boolean);
      for (const part of path.split("/")) {
        if (!part || part === ".") continue;
        if (part === "..") out.pop(); else out.push(part);
      }
      return out;
    };
    const join = (segs) => "/" + segs.join("/");

    const top = [];
    const folder = (type) => top[type] || (top[type] = navigator.storage.getDirectory()
      .then((d) => d.getDirectoryHandle(kinds[type], { create: true })));
    const walk = async (type, segs, create = false) => {
      let dir = await folder(type);
      for (const name of segs) dir = await dir.getDirectoryHandle(name, { create });
      return dir;
    };
    // The handle at a path, whichever kind it is, or null.
    const lookup = async (type, segs) => {
      if (!segs.length) return folder(type);
      const dir = await walk(type, segs.slice(0, -1));
      const name = segs[segs.length - 1];
      try { return await dir.getFileHandle(name); } catch (e) {
        if (e.name !== "TypeMismatchError") { if (e.name === "NotFoundError") return null; throw e; }
      }
      return dir.getDirectoryHandle(name);
    };
    const need = async (type, segs) => {
      const handle = await lookup(type, segs).catch((e) => { if (e.name === "NotFoundError") return null; throw e; });
      if (!handle) throw fail("NotFoundError", "A requested file or directory could not be found.");
      return handle;
    };

    // OPFS files come without a type; a blob: URL or download wants one.
    const types = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
      svg: "image/svg+xml", pdf: "application/pdf", txt: "text/plain", html: "text/html", json: "application/json",
      mp4: "video/mp4", webm: "video/webm" };
    const typed = (file) => {
      const type = file.type || types[(file.name.split(".").pop() || "").toLowerCase()] || "";
      return type === file.type ? file : new File([file], file.name, { type, lastModified: file.lastModified });
    };

    // blob: URLs already made, by "<type>:<path>", so the same file set on an
    // image twice gets the same URL, and at once. Changing a file drops its.
    const made = new Map();
    const forget = (type, path) => {
      for (const [key, url] of made) {
        const [t, p] = [Number(key[0]), key.slice(2)];
        if (t === type && (p === path || p.startsWith(path === "/" ? "/" : path + "/"))) {
          made.delete(key);
          Promise.resolve(url).then((u) => { if (u) setTimeout(() => URL.revokeObjectURL(u), 60000); }, () => {});
        }
      }
    };

    const systems = [];
    const system = (type) => systems[type] || (systems[type] = (() => {
      const fs = { name: location.host + ":" + (type ? "Persistent" : "Temporary") };
      fs.root = new DirectoryEntry(fs, type, "/");
      return fs;
    })());

    class Entry {
      constructor(fs, type, path) {
        Object.defineProperty(this, "_type", { value: type });
        this.filesystem = fs;
        this.fullPath = path;
        this.name = path === "/" ? "" : path.split("/").pop();
      }
      get _segs() { return segments("/", this.fullPath); }
      toURL() {
        return "filesystem:" + location.origin + "/" + kinds[this._type]
          + (this.fullPath === "/" ? "/" : this._segs.map(encodeURIComponent).map((s) => "/" + s).join(""));
      }
      toInternalURL() { return this.toURL(); }
      getParent(success, error) {
        settle(Promise.resolve(new DirectoryEntry(this.filesystem, this._type, join(this._segs.slice(0, -1)))), success, error);
      }
      getMetadata(success, error) {
        settle((async () => {
          const handle = await need(this._type, this._segs);
          if (handle.kind === "directory") return { modificationTime: new Date(), size: 0 };
          const file = await handle.getFile();
          return { modificationTime: new Date(file.lastModified), size: file.size };
        })(), success, error);
      }
      remove(success, error) {
        settle((async () => {
          const segs = this._segs;
          if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
          const handle = await need(this._type, segs);
          // Not recursive: a directory with something in it is refused, as in
          // Chrome. WebKit says UnknownError there, Chrome InvalidModificationError.
          await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1]).catch((e) => {
            throw handle.kind === "directory" && e.name !== "NotFoundError" ? fail("InvalidModificationError", "The directory is not empty.") : e;
          });
          forget(this._type, this.fullPath);
        })(), success, error);
      }
      moveTo(parent, name, success, error) { settle(this._transfer(parent, name, true), success, error); }
      copyTo(parent, name, success, error) { settle(this._transfer(parent, name, false), success, error); }
      async _transfer(parent, name, move) {
        if (!(parent instanceof DirectoryEntry)) throw fail("TypeMismatchError", "The parent is not a directory.");
        name = name == null || name === "" ? this.name : String(name);
        if (!name || name.includes("/") || name === "." || name === "..") throw fail("EncodingError", "Invalid name.");
        const from = this._segs, to = [...parent._segs, name];
        const same = parent._type === this._type;
        if (!from.length) throw fail("InvalidModificationError", "The root directory cannot be moved or copied.");
        if (same && (join(to) === this.fullPath || join(to).startsWith(this.fullPath + "/")))
          throw fail("InvalidModificationError", "An entry cannot be moved or copied onto or into itself.");
        const handle = await need(this._type, from);
        const into = await need(parent._type, parent._segs);
        if (into.kind !== "directory") throw fail("NotFoundError");
        // What is already there is replaced if it is a file over a file, or an
        // empty directory over a directory; otherwise Chrome refuses.
        const there = await lookup(parent._type, to).catch(() => null);
        if (there) {
          if (there.kind !== handle.kind) throw fail("InvalidModificationError", "An entry of another kind is in the way.");
          if (there.kind === "directory") for await (const _ of there.keys()) throw fail("InvalidModificationError", "The directory in the way is not empty.");
        }
        // Over something already there, the entry arrives under a name of
        // its own first, and replaces it only once whole: a copy that fails
        // leaves what was there as it was.
        const staging = there ? ".eglu-" + Math.random().toString(36).slice(2) : name;
        let moved = false;
        if (move && same && typeof handle.move === "function") {
          try { await handle.move(into, staging); moved = true; } catch (e) {}
        }
        if (!moved) {
          // A copy that fails leaves nothing of itself: under its own
          // name, or under the new one, where nothing was before.
          try { await copy(handle, into, staging); } catch (e) {
            await into.removeEntry(staging, { recursive: true }).catch(() => {});
            throw e;
          }
        }
        if (there) {
          forget(parent._type, join(to));
          const staged = handle.kind === "file" ? await into.getFileHandle(staging) : await into.getDirectoryHandle(staging);
          if (typeof staged.move === "function") {
            await into.removeEntry(name, { recursive: there.kind === "directory" });
            await staged.move(into, name);
          } else {
            // No moving here: a file is written over in place, which OPFS
            // keeps whole or not at all as the writable closes; a directory
            // in the way is an empty one. The staged copy goes either way.
            try {
              if (handle.kind === "file") {
                const w = await (await into.getFileHandle(name)).createWritable();
                try { await w.write(await staged.getFile()); await w.close(); } catch (e) { await w.abort().catch(() => {}); throw e; }
              } else {
                await into.removeEntry(name);
                await copy(staged, into, name);
              }
            } finally {
              await into.removeEntry(staging, { recursive: true }).catch(() => {});
            }
          }
        }
        if (move && !moved) await (await walk(this._type, from.slice(0, -1))).removeEntry(from[from.length - 1], { recursive: true });
        if (move) forget(this._type, this.fullPath);
        const Kind = this.isDirectory ? DirectoryEntry : FileEntry;
        return new Kind(parent.filesystem, parent._type, join(to));
      }
    }
    const copy = async (handle, into, name) => {
      if (handle.kind === "file") {
        const w = await (await into.getFileHandle(name, { create: true })).createWritable();
        await w.write(await handle.getFile());
        return w.close();
      }
      const dir = await into.getDirectoryHandle(name, { create: true });
      for await (const [child, h] of handle.entries()) await copy(h, dir, child);
    };

    class DirectoryEntry extends Entry {
      get isFile() { return false; }
      get isDirectory() { return true; }
      createReader() { return new DirectoryReader(this); }
      getFile(path, options, success, error) { settle(this._get(path, options, "file"), success, error); }
      getDirectory(path, options, success, error) { settle(this._get(path, options, "directory"), success, error); }
      async _get(path, options, kind) {
        const create = !!(options && options.create), exclusive = !!(options && options.exclusive);
        const segs = segments(this.fullPath, path);
        if (!segs.length) {
          if (kind === "file") throw fail("TypeMismatchError", "The root is a directory.");
          if (create && exclusive) throw fail("InvalidModificationError", "The directory already exists.");
          return this.filesystem.root;
        }
        const dir = await walk(this._type, segs.slice(0, -1)).catch((e) => {
          throw e.name === "TypeMismatchError" ? fail("NotFoundError") : e;
        });
        const name = segs[segs.length - 1];
        if (create && exclusive) {
          const there = await lookup(this._type, segs).catch(() => null);
          if (there) throw fail("InvalidModificationError", "The entry already exists.");
        }
        await (kind === "file" ? dir.getFileHandle(name, { create }) : dir.getDirectoryHandle(name, { create }));
        const Kind = kind === "file" ? FileEntry : DirectoryEntry;
        return new Kind(this.filesystem, this._type, join(segs));
      }
      removeRecursively(success, error) {
        settle((async () => {
          const segs = this._segs;
          if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
          await need(this._type, segs);
          await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1], { recursive: true });
          forget(this._type, this.fullPath);
        })(), success, error);
      }
    }

    // Chrome hands a directory's entries over in batches, then an empty one to
    // say it's done; callers loop until they see it.
    class DirectoryReader {
      constructor(dir) { this._dir = dir; this._left = null; }
      readEntries(success, error) {
        settle((async () => {
          const dir = this._dir;
          if (!this._left) {
            const handle = await need(dir._type, dir._segs);
            this._left = [];
            for await (const [name, h] of handle.entries()) {
              const Kind = h.kind === "file" ? FileEntry : DirectoryEntry;
              this._left.push(new Kind(dir.filesystem, dir._type, join([...dir._segs, name])));
            }
          }
          return this._left.splice(0, 100);
        })(), success, error);
      }
    }

    class FileEntry extends Entry {
      get isFile() { return true; }
      get isDirectory() { return false; }
      file(success, error) {
        settle((async () => {
          const handle = await need(this._type, this._segs);
          if (handle.kind !== "file") throw fail("TypeMismatchError");
          return typed(await handle.getFile());
        })(), success, error);
      }
      createWriter(success, error) {
        settle((async () => {
          const handle = await need(this._type, this._segs);
          if (handle.kind !== "file") throw fail("TypeMismatchError");
          return new FileWriter(this, handle, (await handle.getFile()).size);
        })(), success, error);
      }
    }

    // One write or truncate at a time, each a writable opened on the file as it
    // is and closed (OPFS commits on close), with Chrome's events around it:
    // writestart, write, writeend, or error then writeend.
    class FileWriter extends EventTarget {
      constructor(entry, handle, length) {
        super();
        Object.defineProperty(this, "_entry", { value: entry });
        Object.defineProperty(this, "_handle", { value: handle });
        Object.defineProperty(this, "_token", { value: null, writable: true });
        Object.defineProperty(this, "_writable", { value: null, writable: true });
        this.readyState = 0; this.position = 0; this.length = length; this.error = null;
        this.onwritestart = this.onprogress = this.onwrite = this.onabort = this.onerror = this.onwriteend = null;
      }
      _fire(type, loaded, total) {
        const event = new ProgressEvent(type, { lengthComputable: true, loaded, total });
        this.dispatchEvent(event);
        const handler = this["on" + type];
        if (typeof handler === "function") handler.call(this, event);
      }
      _run(size, work, after) {
        if (this.readyState === 1) throw fail("InvalidStateError", "A write is already in progress.");
        this.readyState = 1; this.error = null;
        const run = this._token = {};
        setTimeout(async () => {
          if (this._token !== run) return;
          this._fire("writestart", 0, size);
          try {
            const w = await this._handle.createWritable({ keepExistingData: true });
            this._writable = w;
            // Aborted on the way, the writable is let go unclosed: OPFS
            // keeps the file as it was.
            const aborted = () => { if (this._token !== run) throw fail("AbortError", "The write was aborted."); };
            try { aborted(); await work(w); aborted(); await w.close(); } catch (e) { await w.abort().catch(() => {}); throw e; }
            finally { if (this._writable === w) this._writable = null; }
            if (this._token !== run) return;
            after();
            forget(this._entry._type, this._entry.fullPath);
            this.readyState = 2;
            this._fire("progress", size, size);
            this._fire("write", size, size);
          } catch (e) {
            if (this._token !== run) return;
            this.error = asError(e);
            this.readyState = 2;
            this._fire("error", 0, size);
          }
          this._fire("writeend", this.readyState === 2 ? size : 0, size);
        });
      }
      write(data) {
        if (!(data instanceof Blob)) throw new TypeError("Failed to execute 'write' on 'FileWriter': parameter 1 is not of type 'Blob'.");
        const at = this.position;
        this._run(data.size, (w) => w.write({ type: "write", position: at, data }), () => {
          this.position = at + data.size;
          this.length = Math.max(this.length, this.position);
        });
      }
      truncate(size) {
        size = Math.max(0, Number(size) || 0);
        this._run(0, (w) => w.truncate(size), () => {
          this.length = size;
          this.position = Math.min(this.position, size);
        });
      }
      seek(offset) {
        if (this.readyState === 1) throw fail("InvalidStateError", "A write is in progress.");
        offset = Number(offset) || 0;
        if (offset < 0) offset = Math.max(0, this.length + offset);
        this.position = Math.min(offset, this.length);
      }
      abort() {
        if (this.readyState !== 1) return;
        this._token = null;
        const w = this._writable;
        this._writable = null;
        if (w) w.abort().catch(() => {});
        this.readyState = 2;
        this.error = fail("AbortError", "The write was aborted.");
        this._fire("abort", 0, 0);
        this._fire("writeend", 0, 0);
      }
    }
    for (const [k, v] of [["INIT", 0], ["WRITING", 1], ["DONE", 2]]) {
      Object.defineProperty(FileWriter, k, { value: v });
      Object.defineProperty(FileWriter.prototype, k, { value: v });
    }

    const requestFileSystem = (type, size, success, error) => {
      type = Number(type);
      settle(type === TEMPORARY || type === PERSISTENT
        ? folder(type).then(() => system(type))
        : Promise.reject(fail("InvalidModificationError", "Unknown file system type.")), success, error);
    };

    // filesystem:<this origin>/<persistent|temporary>/<path>, or null.
    const parse = (url) => {
      const s = String(url);
      if (!s.startsWith("filesystem:")) return null;
      const m = /^filesystem:([^/]+:\/\/[^/]+)\/(temporary|persistent)(\/[^?#]*)?/i.exec(s);
      if (!m || m[1] !== location.origin) return null;
      let segs;
      try { segs = segments("/", (m[3] || "/").split("/").map(decodeURIComponent).join("/")); } catch (e) { return null; }
      return { type: kinds.indexOf(m[2].toLowerCase()), segs };
    };
    const resolveURL = (url, success, error) => {
      settle((async () => {
        const at = parse(url);
        if (!at) throw fail(String(url).startsWith("filesystem:") ? "SecurityError" : "EncodingError", "Not a filesystem: URL of this origin.");
        const handle = await need(at.type, at.segs);
        const fs = system(at.type);
        if (!at.segs.length) return fs.root;
        return new (handle.kind === "file" ? FileEntry : DirectoryEntry)(fs, at.type, join(at.segs));
      })(), success, error);
    };

    const fileAt = async (url) => {
      const at = parse(url);
      if (!at) throw fail("NotFoundError");
      const handle = await need(at.type, at.segs);
      if (handle.kind !== "file") throw fail("NotFoundError");
      return typed(await handle.getFile());
    };
    // The blob: URL now standing for a filesystem: URL, made once per file.
    const blobURL = (url) => {
      const at = parse(url);
      if (!at) return Promise.reject(fail("NotFoundError"));
      const key = at.type + ":" + join(at.segs);
      if (!made.has(key)) {
        const p = fileAt(url).then((file) => { const u = URL.createObjectURL(file); made.set(key, u); return u; });
        made.set(key, p);
        p.catch(() => { if (made.get(key) === p) made.delete(key); });
      }
      return Promise.resolve(made.get(key));
    };
    const ready = (url) => { const at = parse(url); const u = at && made.get(at.type + ":" + join(at.segs)); return typeof u === "string" ? u : null; };
    const dataURL = (url) => fileAt(url).then((file) => new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(file);
    }));

    const define = (target, key, value) => {
      try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
    };
    define(root, "TEMPORARY", TEMPORARY);
    define(root, "PERSISTENT", PERSISTENT);
    define(root, "requestFileSystem", requestFileSystem);
    define(root, "webkitRequestFileSystem", requestFileSystem);
    define(root, "resolveLocalFileSystemURL", resolveURL);
    define(root, "webkitResolveLocalFileSystemURL", resolveURL);
    // Code for this API asks for quota first; OPFS has its own, so any is granted.
    const quota = {
      requestQuota: (size, success, error) => settle(Promise.resolve(size), success, error),
      queryUsageAndQuota: (success, error) => settle(navigator.storage.estimate().then((e) => [e.usage || 0, e.quota || 0]),
        (v) => typeof success === "function" && success(v[0], v[1]), error),
    };
    if (!navigator.webkitPersistentStorage) define(navigator, "webkitPersistentStorage", quota);
    if (!navigator.webkitTemporaryStorage) define(navigator, "webkitTemporaryStorage", quota);
    for (const [name, Kind] of [["FileSystemEntry", Entry], ["FileSystemDirectoryEntry", DirectoryEntry],
      ["FileSystemFileEntry", FileEntry], ["FileSystemDirectoryReader", DirectoryReader]]) {
      // WebKit has these for dropped files; its instanceof checks keep its own.
      if (!root[name]) define(root, name, Kind);
    }
    if (!root.FileWriter) define(root, "FileWriter", FileWriter);

    // Where a filesystem: URL is loaded. An image or link gets the blob: URL
    // once it's made (at once when it already was, so a src set again stays
    // put), and reads back the filesystem: URL, as in Chrome. A file that
    // isn't there leaves the URL as it was, so the image fails as it would.
    const shown = new WeakMap();
    const hook = (proto, prop) => {
      const d = proto && Object.getOwnPropertyDescriptor(proto, prop);
      if (!d || !d.set || !d.get) return;
      Object.defineProperty(proto, prop, Object.assign({}, d, {
        get() {
          const value = d.get.call(this), was = shown.get(this);
          return was && was.blob === value ? was.url : value;
        },
        set(value) {
          const url = typeof value === "string" ? value : null;
          if (!url || !url.startsWith("filesystem:") || !parse(url)) { shown.delete(this); return d.set.call(this, value); }
          const now = ready(url);
          if (now) { shown.set(this, { url, blob: now }); return d.set.call(this, now); }
          const was = { url, blob: null, ready: null };
          shown.set(this, was);
          was.ready = blobURL(url).then((blob) => {
            if (shown.get(this) !== was) return;
            was.blob = blob;
            d.set.call(this, blob);
          }, () => { if (shown.get(this) === was) { shown.delete(this); d.set.call(this, url); } });
        },
      }));
    };
    hook(root.HTMLImageElement && HTMLImageElement.prototype, "src");
    hook(root.HTMLAnchorElement && HTMLAnchorElement.prototype, "href");
    // A link given a filesystem: address and clicked at once, as a download
    // is made (a.href = entry.toURL(); a.click()): clicked once its blob:
    // address is in, not on the address it had before.
    if (root.HTMLAnchorElement) {
      const click = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        const was = shown.get(this);
        if (was && !was.blob && was.ready) { was.ready.then(() => click.call(this)); return; }
        return click.call(this);
      };
    }
    // React and templates set the attribute, not the property.
    const setAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
      if (typeof value === "string" && value.startsWith("filesystem:")) {
        const n = String(name).toLowerCase();
        if ((n === "src" && this instanceof HTMLImageElement) || (n === "href" && this instanceof HTMLAnchorElement)) {
          this[n] = value;
          return;
        }
      }
      return setAttribute.call(this, name, value);
    };

    if (typeof root.fetch === "function") {
      const fetch = root.fetch;
      root.fetch = function (input, init) {
        const url = typeof input === "string" ? input : input instanceof URL ? input.href : null;
        if (!url || !url.startsWith("filesystem:") || !parse(url)) return fetch.apply(this, arguments);
        return fileAt(url).then((file) => new Response(file, { status: 200, headers: { "Content-Type": file.type || "application/octet-stream", "Content-Length": String(file.size) } }),
          () => { throw new TypeError("Load failed"); });
      };
    }

    // eGlu downloads and opens tabs from outside this page, where a blob:
    // URL of this page means nothing: those get the file itself, as a data: URL.
    const swap = (space, method, urls) => {
      const ns = chrome[space];
      const original = ns && ns[method];
      if (typeof original !== "function") return;
      put(ns, method, function (options, ...rest) {
        const list = options && urls(options);
        if (!list || !list.some((u) => typeof u === "string" && parse(u))) return original.call(this, options, ...rest);
        const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
        const p = Promise.all(list.map((u) => typeof u === "string" && parse(u) ? dataURL(u) : u)).then((done) => {
          const copy = Object.assign({}, options, { url: Array.isArray(options.url) ? done : done[0] });
          return original.call(this, copy, ...rest);
        });
        if (!callback) return p;
        p.then((v) => callback(v), (e) => withLastError(e, callback));
      });
    };
    const one = (o) => typeof o.url === "string" ? [o.url] : Array.isArray(o.url) ? o.url : null;
    swap("downloads", "download", one);
    swap("tabs", "create", one);
    swap("windows", "create", one);
  })();

  // Screen recording (ExtensionCapture). Chrome's picker is eGlu's
  // question, then the Mac's own; the stream id it hands back is an id eGlu
  // gives once, which getUserMedia in the extension's page turns into the
  // stream. desktopCapture only for an extension that asks for it, as in
  // Chrome: Awesome Screenshot records with getDisplayMedia when there is
  // no desktopCapture. (Search)
  const recorder = !inContent && !worker && typeof navigator !== "undefined" && !!navigator.mediaDevices
    && typeof root.MediaDevices === "function";
  // Only an extension's own page, at the top: eGlu checks that too.
  const captureChannel = (() => {
    try { return recorder && !embedded && window.top === window ? root.webkit.messageHandlers.egluCapture : null; } catch (e) { return null; }
  })();
  const askCapture = (op, body) => captureChannel
    ? Promise.resolve(captureChannel.postMessage(Object.assign({ op }, body)))
    : Promise.resolve({ error: "NotAllowedError", message: "Recording isn't available here" });
  const refused = (reply) => new DOMException(String(reply && reply.message || "Permission denied"), String(reply && reply.error || "NotAllowedError"));
  // What WebKit's getDisplayMedia takes: no min, no exact.
  const displayVideo = (v) => {
    if (!v || typeof v !== "object") return true;
    const out = {};
    for (const k of ["width", "height", "frameRate"]) {
      const x = v[k] ?? (v.mandatory && v.mandatory["max" + k[0].toUpperCase() + k.slice(1)]);
      if (typeof x === "number") out[k] = { max: x };
      else if (x && typeof x === "object") {
        const y = {};
        if (x.max !== undefined) y.max = x.max;
        if (x.ideal !== undefined) y.ideal = x.ideal;
        if (Object.keys(y).length) out[k] = y;
      }
    }
    return Object.keys(out).length ? out : true;
  };
  // A stream recorded for an id nobody will take (its chooseDesktopMedia
  // cancelled): stopped, not left recording until the minute is up.
  let dropHeld = () => {};
  if (recorder) {
    const P = root.MediaDevices.prototype;
    const realGUM = P.getUserMedia, realGDM = P.getDisplayMedia;
    const held = new Map();
    dropHeld = (token) => {
      const stream = held.get(token);
      if (!stream) return;
      held.delete(token);
      stream.getTracks().forEach((t) => t.stop());
    };
    // Called by eGlu alone (ExtensionCapture.record). WebKit counts an
    // app's call as a click, and only until its first await, so the
    // page's own getDisplayMedia — kept before any of the extension's
    // code ran — is called at once.
    if (typeof realGDM === "function") {
      Object.defineProperty(root, Symbol.for("eglu.capture"), { value: (token, video) => {
        let started;
        try { started = realGDM.call(navigator.mediaDevices, { video: video == null ? true : video, audio: false }); }
        catch (e) { return Promise.resolve({ error: e.name, message: String(e.message) }); }
        return started.then((stream) => {
          held.set(token, stream);
          // An id never taken is stopped, not left recording.
          setTimeout(() => {
            if (held.get(token) !== stream) return;
            held.delete(token);
            stream.getTracks().forEach((t) => t.stop());
          }, 60000);
          return { ok: true };
        }, (e) => ({ error: e.name, message: String(e.message) }));
      } });
    }
    // Chrome's desktop and tab constraints, which WebKit would read as a
    // plain camera request.
    const desktopId = (c) => {
      if (!c || typeof c !== "object") return null;
      const m = c.mandatory || c;
      return /^(desktop|screen|window|tab)$/.test(String(m.chromeMediaSource || "")) ? String(m.chromeMediaSourceId || "") : null;
    };
    // Chrome's older constraints (mandatory, optional, goog…) in the
    // standard form.
    const standard = (t) => {
      if (!t || typeof t !== "object" || !(t.mandatory || t.optional)) return t;
      const out = {};
      for (const [k, v] of Object.entries(t)) if (k !== "mandatory" && k !== "optional") out[k] = v;
      const set = (name, part, v) => { const x = out[name] && typeof out[name] === "object" ? out[name] : {}; x[part] = v; out[name] = x; };
      const read = (k, v, strong) => {
        const m = /^(min|max)(Width|Height|FrameRate|AspectRatio)$/.exec(k);
        if (m) return set(m[2][0].toLowerCase() + m[2].slice(1), m[1], v);
        if (k === "sourceId" || k === "deviceId") return set("deviceId", strong ? "exact" : "ideal", v);
        const goog = { googEchoCancellation: "echoCancellation", googAutoGainControl: "autoGainControl", googNoiseSuppression: "noiseSuppression" }[k];
        if (goog) out[goog] = v;
      };
      for (const [k, v] of Object.entries(t.mandatory || {})) read(k, v, true);
      for (const o of t.optional || []) for (const [k, v] of Object.entries(o || {})) read(k, v, false);
      return Object.keys(out).length ? out : true;
    };
    const take = async (id, c) => {
      let stream = held.get(id);
      if (!stream && id) {
        const reply = await askCapture("consume", { token: id, video: displayVideo(c.video) });
        if (!reply || !reply.ok) throw refused(reply);
        stream = held.get(id);
      }
      held.delete(id);
      if (!stream) throw refused();
      // The sound of a screen or a tab alone: WebKit records none.
      if (desktopId(c.video) === null) {
        stream.getTracks().forEach((t) => t.stop());
        throw new DOMException("eGlu can't record the sound of a screen or a tab", "NotFoundError");
      }
      const [track] = stream.getVideoTracks();
      const want = displayVideo(c.video);
      if (track && want !== true) try { await track.applyConstraints(want); } catch (e) {}
      // The microphone beside the screen, as Chrome gives it in one call:
      // asked as any microphone is, and the whole call refused without it.
      const mic = c.audio && desktopId(c.audio) === null ? c.audio : null;
      if (mic) {
        try {
          const reply = await askCapture("lend", {});
          if (captureChannel && (!reply || !reply.ok)) throw refused(reply);
          const sound = await realGUM.call(navigator.mediaDevices, { audio: standard(mic) });
          sound.getAudioTracks().forEach((t) => stream.addTrack(t));
        } catch (e) {
          stream.getTracks().forEach((t) => t.stop());
          throw e;
        }
      }
      return stream;
    };
    put(P, "getUserMedia", function (c) {
      const asked = c || {};
      const id = desktopId(asked.video) ?? desktopId(asked.audio);
      if (id !== null) return take(id, asked);
      const self = this;
      // An offscreen document is lent to the pill first (see
      // ExtensionCapture, "lend"); one not made to record is refused.
      return askCapture("lend", {}).then((reply) => {
        if (captureChannel && (!reply || !reply.ok)) throw refused(reply);
        return realGUM.call(self, { audio: standard(asked.audio), video: standard(asked.video) });
      });
    });
    if (typeof realGDM === "function") {
      put(P, "getDisplayMedia", function (c) {
        const asked = c || {};
        const surface = asked.video && typeof asked.video === "object" ? String(asked.video.displaySurface || "") : "";
        return askCapture("display", { video: displayVideo(asked.video), surface }).then((reply) => {
          const stream = reply && reply.ok && held.get(reply.token);
          if (!stream) throw refused(reply);
          held.delete(reply.token);
          return stream;
        });
      });
    }
    // Chrome's older callback form, which Loom still records with.
    const legacy = function (c, ok, fail) {
      navigator.mediaDevices.getUserMedia(c).then(ok, (e) => { if (typeof fail === "function") fail(e); });
    };
    // WebKit's own, where it has them, too: they would take Chrome's
    // desktop constraints for a camera.
    for (const name of ["getUserMedia", "webkitGetUserMedia"]) put(root.Navigator.prototype, name, legacy);
  }
  {
    let asked = 0;
    const cancelled = new Set();
    add("desktopCapture", {
      chooseDesktopMedia: (sources, tab, cb) => {
        const f = typeof tab === "function" ? tab : cb;
        const id = ++asked;
        const done = (token) => {
          if (cancelled.has(id)) return dropHeld(token);
          if (typeof f === "function") f(token || "", { canRequestAudioTrack: false });
        };
        // From a page: asked and recorded there at once, so a cancelled
        // picker is an empty id, as in Chrome. From the worker, which has
        // nothing to record in: an id for one of its pages to use.
        const given = worker || background || !captureChannel
          ? native("capture.grant", [sources || []])
          : askCapture("choose", { sources: sources || [] }).then((r) => (r && r.ok ? r.token : ""));
        Promise.resolve(given).then(done, () => done(""));
        return id;
      },
      cancelChooseDesktopMedia: (id) => { cancelled.add(id); },
      DesktopCaptureSourceType: { SCREEN: "screen", WINDOW: "window", TAB: "tab", AUDIO: "audio" },
    });
  }

  // The popup is a page of eGlu's own, which WebKit knows as a tab at no
  // place in the window's row (ExtensionSurface). Chrome has no current tab
  // in a popup or a side panel, and lists the popup among the popup views;
  // extensions lay themselves out by that: Bitwarden and Proton Pass
  // otherwise fill the pane as if in a tab. Which pane shows the page,
  // popup or side panel, eGlu says (surface.kind): WebKit's tab is the same
  // for both, and the popup's page may be opened in a tab too. (Search)
  if (typeof document !== "undefined" && !background && !embedded) {
    // Known at once for the manifest's popup page, as pages lay themselves
    // out before any answer can come back (getViews is synchronous); then
    // settled: a page in a tab of the row is no popup, whatever its
    // address, and one in no place is eGlu's popup or side panel, which
    // eGlu tells apart (surface.kind). (Search)
    let popup = (() => {
      try {
        const action = manifest.action || manifest.browser_action || {};
        return !!action.default_popup && new URL(action.default_popup, runtime.getURL("")).pathname === location.pathname;
      } catch (e) { return false; }
    })();
    const placed = (t) => !!t && t.index >= 0 && t.index < 1e6;
    const tabs = chrome.tabs;
    if (tabs && typeof tabs.getCurrent === "function") {
      const getCurrent = tabs.getCurrent.bind(tabs);
      Promise.resolve(getCurrent()).then((t) => {
        if (placed(t)) { popup = false; return; }
        return native("surface.kind", [location.href]).then((kind) => { popup = kind === "popup"; });
      }).catch(() => {});
      const current = () => Promise.resolve(getCurrent()).then((t) => t && !placed(t) ? undefined : t);
      put(tabs, "getCurrent", (callback) => {
        const p = current();
        if (typeof callback !== "function") return p;
        p.then((t) => callback(t), (e) => withLastError(e, callback));
      });
    }
    const extension = chrome.extension;
    if (extension && typeof extension.getViews === "function") {
      const getViews = extension.getViews.bind(extension);
      // The popup's own window, the one it opened over, once WebKit says
      // which: one asked for by another window's id, or by a tab's, isn't
      // the popup.
      let ownWindow = null;
      if (chrome.windows && typeof chrome.windows.getCurrent === "function") {
        Promise.resolve(chrome.windows.getCurrent()).then((w) => { if (w && typeof w.id === "number") ownWindow = w.id; }).catch(() => {});
      }
      const anyPlace = (p) => (p.windowId === undefined || p.windowId === -2 || p.windowId === ownWindow) && p.tabId === undefined;
      const views = (properties = {}) => {
        properties = properties || {};
        let list = [...(getViews(properties) || [])];
        if (popup && properties.type === "tab") list = list.filter((v) => v !== root);
        if (popup && (!properties.type || properties.type === "popup") && anyPlace(properties) && !list.includes(root)) list.push(root);
        return list;
      };
      put(extension, "getViews", views);
      // WebKit's getViews and chrome.extension may both ignore a
      // redefinition without a word. Then the page's code is handed a
      // `chrome` of its own, built on WebKit's, whose extension answers
      // getViews and passes everything else on (taken by the fixed accessor
      // above, as it carries the APIs); its answers differ from WebKit's
      // only in the popup.
      if (extension.getViews !== views) {
        const bound = new Map();
        const ownExtension = Object.create(extension);
        for (const key of Object.getOwnPropertyNames(extension)) {
          if (key === "getViews") continue;
          Object.defineProperty(ownExtension, key, { configurable: true, enumerable: true, get: () => {
            const v = extension[key];
            if (typeof v !== "function") return v;
            if (!bound.has(key)) bound.set(key, v.bind(extension));
            return bound.get(key);
          } });
        }
        Object.defineProperty(ownExtension, "getViews", { value: views, configurable: true, writable: true, enumerable: true });
        const ownChrome = Object.create(chrome);
        Object.defineProperty(ownChrome, "extension", { value: ownExtension, configurable: true, writable: true, enumerable: true });
        for (const key of ["chrome", "browser"]) {
          try { if (root[key] === chrome) root[key] = ownChrome; } catch (e) {}
        }
      }
    }
  }

  // A tab number the extension knows, as eGlu can find the tab: its
  // place in the window and its address, as WebKit tells them. (Search's
  // tabs.describe)
  // A tab's place in the space's window, which eGlu finds it by. A popup
  // window's tab (ExtensionPopupWindow) has no place there, nor a side
  // panel: refused, never taken for the space's tab at its index.
  const place = async (tabId) => {
    if (typeof tabId !== "number" || !chrome.tabs || typeof chrome.tabs.get !== "function") return null;
    let t = null;
    try { t = await chrome.tabs.get(tabId); } catch (e) { return null; }
    if (!t) return null;
    if (chrome.windows && typeof chrome.windows.getAll === "function") {
      const normal = await Promise.resolve(chrome.windows.getAll({ windowTypes: ["normal"] })).catch(() => null);
      if (normal && normal[0] && t.windowId !== normal[0].id) throw new Error("No tab with id: " + tabId + ".");
    }
    return { index: t.index, url: t.url || "" };
  };
  // The side panel, eGlu's (ExtensionSidePanel.swift).
  if (!chrome.sidePanel) {
    const placed = (api) => (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const answer = (async () => {
        const options = args[0] && typeof args[0] === "object" ? { ...args[0] } : {};
        if (typeof options.tabId === "number") options.__place = await place(options.tabId);
        return native(api, [options]);
      })();
      if (!callback) return answer;
      answer.then((value) => callback(value), (error) => withLastError(error, callback));
    };
    put(chrome, "sidePanel", {
      setOptions: placed("sidePanel.setOptions"), getOptions: placed("sidePanel.getOptions"),
      setPanelBehavior: call("sidePanel.setPanelBehavior"), getPanelBehavior: call("sidePanel.getPanelBehavior"),
      open: placed("sidePanel.open"), close: placed("sidePanel.close"),
      onOpened: event(), onClosed: event(),
    });
  }
  // The popup its button opens, set for every tab, told to eGlu, whose
  // pane shows it (ExtensionPopup.swift); one set for a single tab is
  // WebKit's alone.
  for (const name of ["action", "browserAction"]) {
    const ns = chrome[name];
    if (!ns || typeof ns.setPopup !== "function") continue;
    const set = ns.setPopup.bind(ns);
    put(ns, "setPopup", (details, ...rest) => {
      try { if (details && details.tabId === undefined) native("action.popup", [String(details.popup || "")]).catch(() => {}); } catch (e) {}
      return set(details, ...rest);
    });
  }
  if (typeof runtime.getContexts !== "function") put(runtime, "getContexts", call("runtime.getContexts"));

  // A worker's listeners, held from its first moment. WebKit before macOS
  // 27 throws for a listener a worker adds once it has started, where
  // Chrome takes it; and on any macOS, a page that connects before the
  // worker has an onConnect listener is thrown at ("No runtime.onConnect
  // listeners found"), where Chrome only closes the port: Bitwarden's
  // pages, as its worker starts. So for every event the extension's code
  // names (ExtensionPreparation.eventList), the worker has one listener of
  // WebKit's from the start, and a later one joins the list behind it; a
  // port that comes with nobody behind it is closed, as in Chrome. Events
  // it doesn't name still take late listeners without a throw; they just
  // aren't heard. Requests are left alone: a listener for every one would
  // wake the worker for every request. runtime.onMessage has its own
  // (gather, above). (Search)
  if (worker) {
    const named = new Set(/*__EGLU_EVENTS__*/[]);
    for (const space of spaces) {
      if (space === "webRequest") continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const keys = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => keys.add(k));
      for (const key of keys) {
        if (!/^on[A-Z]/.test(key) || (space === "runtime" && /^onMessage/.test(key))) continue;
        let target; try { target = ns[key]; } catch (e) { continue; }
        // The shim's own events take any listener as they are.
        if (!target || typeof target.addListener !== "function" || target.listeners) continue;
        const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
        // Those WebKit took, and those it refused as too late.
        const direct = new Set(), late = new Set();
        const port = space === "runtime" && /^onConnect/.test(key);
        if (named.has(space + "." + key)) {
          try {
            add(function (...args) {
              if (port && !late.size && !direct.size) { try { args[0].disconnect(); } catch (e) {} return; }
              let answer;
              for (const f of [...late]) { try { const r = f(...args); if (r !== undefined) answer = r; } catch (e) { setTimeout(() => { throw e; }); } }
              return answer;
            });
          } catch (e) {}
        }
        // A filter given with a listener (webNavigation's) stays WebKit's. One
        // refused as too late with a filter isn't heard: the stand-in can't
        // hold to the filter, and would hand it every site's events.
        put(target, "addListener", (listener, ...rest) => {
          try { const r = add(listener, ...rest); direct.add(listener); return r; }
          catch (e) {
            if (!/startup/i.test(String(e && e.message))) throw e;
            if (!rest.some((x) => x !== undefined)) late.add(listener);
          }
        });
        put(target, "removeListener", (listener) => { late.delete(listener); direct.delete(listener); try { remove(listener); } catch (e) {} });
        const had = target.hasListener.bind(target);
        put(target, "hasListener", (listener) => late.has(listener) || had(listener));
        put(target, "hasListeners", () => late.size > 0 || direct.size > 0);
      }
    }
  }
})();
