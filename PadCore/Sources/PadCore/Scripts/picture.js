// Document Picture-in-Picture for WebKit, which has none (DocumentPicture.swift):
// `documentPictureInPicture` as Chrome has it, written on window.open. The
// window it opens is a blank page at DocumentPicture.marker, same-origin
// and in this page's own process, so the page can move its own elements
// into it, live videos included, as Google Meet does. The app sees the
// marker and floats that window above every other (PictureWindow.swift).
// Goes into the page's own world, at document start, on the sites
// DocumentPicture lists, and only on the Mac.
(function () {
  'use strict';
  if ('documentPictureInPicture' in window) return;
  const marker = 'eglu-picture';
  // window.open as it is before the site's scripts run, in case one wraps it.
  const openWindow = window.open.bind(window);
  // The window open now, if any: one at a time, as in Chrome.
  let current = null;
  // The site's handler for MediaSession's "enterpictureinpicture", which
  // WebKit refuses to take; the app calls it when the tab is left mid-call.
  let enterHandler = null;
  // Whether the app is calling that handler right now: Chrome lets it open
  // the window without a click, and WebKit grants the app's call one anyway.
  let calledByApp = false;
  const building = Symbol('building');

  const notAllowed = (message) => new DOMException(message, 'NotAllowedError');

  class DocumentPictureInPictureEvent extends Event {
    #window;
    constructor(type, init) {
      super(type, init);
      if (!init || !init.window) throw new TypeError("Failed to construct 'DocumentPictureInPictureEvent': required member window is undefined.");
      this.#window = init.window;
    }
    get window() { return this.#window; }
  }

  class DocumentPictureInPicture extends EventTarget {
    #onenter = null;

    constructor(token) {
      if (token !== building) throw new TypeError('Illegal constructor');
      super();
    }

    get window() {
      return current && !current.closed ? current : null;
    }

    get onenter() { return this.#onenter; }
    set onenter(handler) {
      if (this.#onenter) this.removeEventListener('enter', this.#onenter);
      this.#onenter = typeof handler === 'function' ? handler : null;
      if (this.#onenter) this.addEventListener('enter', this.#onenter);
    }

    async requestWindow(options) {
      options = options ?? {};
      if (window.top !== window) throw notAllowed('Opening a PiP window is only allowed from a top-level browsing context');
      const active = navigator.userActivation ? navigator.userActivation.isActive : true;
      if (!active && !calledByApp) throw notAllowed('Document PiP requires user activation');
      const size = (value) => {
        const number = Number(value ?? 0);
        if (!Number.isFinite(number) || number < 0) throw new RangeError('The width and height must be finite numbers, zero or greater');
        return Math.round(number);
      };
      const width = size(options.width);
      const height = size(options.height);
      if ((width > 0) !== (height > 0)) throw new RangeError('The width and height must both be set, or neither');
      // The window open now closes first, and the site hears its pagehide
      // before it hears of the new one, so it takes its elements home first.
      let closed = null;
      if (current && !current.closed) {
        const old = current;
        closed = new Promise((done) => {
          old.addEventListener('pagehide', done, { once: true });
          setTimeout(done, 1000);
        });
        old.close();
      }
      let address = 'about:blank#' + marker;
      if (options.disallowReturnToOpener) address += '&noreturn';
      if (options.preferInitialWindowPlacement) address += '&initial';
      const features = width ? `popup,width=${width},height=${height}` : 'popup';
      // Opened before any wait, while the click lasts.
      const opened = openWindow(address, '_blank', features);
      if (!opened) throw notAllowed('The PiP window could not be opened');
      current = opened;
      opened.addEventListener('pagehide', () => {
        if (current === opened) current = null;
      }, { once: true });
      if (closed) await closed;
      // As the spec has it: the promise resolves, and enter fires in a task after.
      setTimeout(() => {
        if (current === opened) picture.dispatchEvent(new DocumentPictureInPictureEvent('enter', { window: opened }));
      }, 0);
      return opened;
    }
  }

  const picture = new DocumentPictureInPicture(building);
  const hidden = (value) => ({ value, writable: true, configurable: true, enumerable: false });
  Object.defineProperty(window, 'DocumentPictureInPicture', hidden(DocumentPictureInPicture));
  Object.defineProperty(window, 'DocumentPictureInPictureEvent', hidden(DocumentPictureInPictureEvent));
  Object.defineProperty(window, 'documentPictureInPicture', { get: () => picture, configurable: true, enumerable: true });

  // MediaSession's handler for leaving the tab: kept here, where WebKit would throw.
  const session = window.MediaSession && window.MediaSession.prototype;
  const setActionHandler = session && session.setActionHandler;
  if (setActionHandler) {
    Object.defineProperty(session, 'setActionHandler', hidden(function (action, handler) {
      if (action === 'enterpictureinpicture') {
        enterHandler = typeof handler === 'function' ? handler : null;
        return;
      }
      return setActionHandler.call(this, action, handler);
    }));
  }

  // What the app calls when the tab is left: the site's handler, if it has
  // one and no window is open. Answers whether a window opened, once the
  // handler is done (or three seconds have passed), so a handler that waits
  // before asking for its window is still the app's call when it asks.
  Object.defineProperty(window, '__egluEnterPicture', {
    value: async function () {
      if (!enterHandler || (current && !current.closed)) return false;
      calledByApp = true;
      try {
        const done = enterHandler.call(navigator.mediaSession, { action: 'enterpictureinpicture' });
        await Promise.race([done, new Promise((wait) => setTimeout(wait, 3000))]);
      } catch (error) {
        setTimeout(() => { throw error; }, 0);
      } finally {
        calledByApp = false;
      }
      return !!(current && !current.closed);
    },
    writable: false, configurable: false, enumerable: false,
  });
})();
