// The Chrome Web Store, made to work for eGlu for Mac
// (Docs/ExtensionsDesign.md, section 3). Copied from Search's StoreRelay
// (github.com/driceroland/Search, MIT), with eGlu's names.
//
// The store sees a browser that isn't Chrome and says so: a banner asking to
// "Switch to Chrome", and an "Add to Chrome" button that stays grey. On the
// store's pages the banner goes and the grey button is replaced by an "Add
// to eGlu" one, the button people already look for. What gets installed
// is read from the tab's own address by the app, never from anything the
// page says; the page only asks, and the install sheet still stands between
// the asking and the installing.
//
// Run in the app's own world, where the page's scripts can't reach it. The
// store's markup is generated and its class names change between releases,
// so nothing here leans on them: the store's own button is the disabled one
// that names Chrome, and the banner is the small block around the one
// enabled button that does.
(function () {
  if (location.hostname !== 'chromewebstore.google.com' || window.__egluStore) return;
  var state = { installed: [], busy: null };
  var post = function (message) {
    try { globalThis.egluBridge.post('egluStore', message); } catch (e) {}
  };

  // The address as the app reads it (ExtensionStore.id(ofPage:)).
  function pageID() {
    var m = location.pathname.match(/^\/detail\/(?:[^\/]+\/)?([a-p]{32})(?:\/|$)/);
    return m ? m[1] : null;
  }

  // On screen: the store keeps the pages it has left, hidden, beside the one it shows.
  function visible(element) { return element.offsetParent !== null || element.getClientRects().length > 0; }

  function theirs() {
    var buttons = document.querySelectorAll('button[disabled]');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      if (!b.dataset.eglu && visible(b) && /chrome/i.test(b.textContent || '')) return b;
    }
    return null;
  }

  // From the banner's own button up, as far as it goes without taking in
  // the header beside it: short, and holding no install button.
  function bannerOf(button) {
    var box = null, up = button.parentElement;
    while (up && up !== document.body) {
      // Never a whole page or a section of one.
      if (/^(C-WIZ|MAIN|HEADER|BODY|HTML)$/.test(up.tagName)) break;
      if (up.querySelector('button[disabled], button[data-eglu]')) break;
      if ((up.innerText || '').length > 160) break;
      box = up;
      up = up.parentElement;
    }
    return box;
  }

  function hideBanner() {
    // And the floating "Switch to Chrome?" card, known by the Chrome logo it
    // carries in any language: it sits right over the button.
    var cards = document.querySelectorAll('[role="dialog"]');
    for (var c = 0; c < cards.length; c++) {
      if (!cards[c].dataset.eglu && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
        cards[c].style.display = 'none';
        cards[c].dataset.eglu = 'promo';
      }
    }
    var buttons = document.querySelectorAll('button:not([disabled])');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      if (b.dataset.eglu || !visible(b) || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
      var box = bannerOf(b);
      if (box && !box.dataset.eglu) {
        box.style.display = 'none';
        box.dataset.eglu = 'banner';
      }
    }
  }

  // The words only, so the button keeps the store's own shape and colour.
  function label(button, text) {
    var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
    var node, last = null;
    while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
    if (last) last.nodeValue = text; else button.textContent = text;
  }

  // Each button says what it is for: the extension of the page it was put on.
  function render(ours) {
    var id = ours.dataset.egluId || null;
    var installed = !!id && state.installed.indexOf(id) >= 0;
    var busy = !!id && state.busy === id;
    label(ours, installed ? 'Added to eGlu' : (busy ? 'Adding…' : 'Add to eGlu'));
    ours.disabled = installed || busy;
  }

  function mend() {
    hideBanner();
    var id = pageID();
    if (!id) { renderAll(); return; }
    var original;
    while ((original = theirs()) && original.parentNode) {
      var ours = original.cloneNode(true);
      ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
        ours.removeAttribute(name);
      });
      ours.dataset.eglu = 'add';
      ours.dataset.egluId = id;
      original.dataset.eglu = 'theirs';
      original.style.display = 'none';
      original.parentNode.insertBefore(ours, original.nextSibling);
      post({ placed: id });
    }
    renderAll();
  }

  // The store keeps the pages it has left, hidden, beside the one it shows.
  function renderAll() {
    var mine = document.querySelectorAll('button[data-eglu="add"]');
    for (var i = 0; i < mine.length; i++) render(mine[i]);
  }

  // Caught on the window, before the store's own handlers, which listen on
  // the document, can see the click at all.
  window.addEventListener('click', function (e) {
    var mine = e.target && e.target.closest && e.target.closest('button[data-eglu="add"]');
    if (!mine) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    // The page it was put on, which the app checks against the tab's address.
    if (!mine.disabled) post({ add: mine.dataset.egluId || '' });
  }, true);

  window.__egluStore = {
    state: function (next) {
      state = next || state;
      renderAll();
    }
  };

  // The store is one page that rewrites itself: whatever it redraws, mend
  // again. A timer rather than a frame: a tab out of sight gets no frames.
  var queued = false;
  // Back and forward within it show a page it kept by turning it visible,
  // not by adding it: that is watched too.
  var again = function () {
    if (queued) return;
    queued = true;
    setTimeout(function () { queued = false; mend(); }, 60);
  };
  new MutationObserver(again).observe(document.documentElement,
    { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'hidden', 'aria-hidden', 'class'] });
  window.addEventListener('popstate', again);
  mend();
})();
