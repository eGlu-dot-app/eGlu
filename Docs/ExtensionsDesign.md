# Extensions design: Chrome extensions in eGlu for Mac

Status: a plan, researched on 21 October 2026, with its open questions decided the same day (section 9). Built so far, on 21 October: the parts that are plain logic, in PadCore with their tests: the CRX3 check (`CRXFile`), ids, store addresses, versions and update replies (`ExtensionStore`), manifests and the API table (`ExtensionManifest`), reading an extension's code (`ExtensionScan`), its errors and the verdict (`ExtensionCheck`), and the hands-off rules (`ExtensionPolicy`). In the Mac app, phase 0's core: a controller per space, installing from a store page or a file, the tab and window objects with their events, the first-seconds check, an Extensions menu, and the app out of the sandbox with its data copied over (`Mac/Sources/Extensions.swift`, `ExtensionTabs.swift`, `LeavingTheSandbox.swift`). Tried on macOS 27.0.1 with a test extension: it loads, its content script runs, cookies and Google's sign-in are denied to it, and an error in its worker is read as the side panel it lacks. Phase 1: every package unpacked into a prepared folder with the shim first in its worker, scripts and pages (`ExtensionPreparation`, `Scripts/extension-shim.js`); the shim carrying Search's messaging, port and worker fixes (Chrome 148's answer rules, the channel between an extension's pages, relays, `clients.matchAll`, the worker's WebSocket, ports to desktop apps, Chrome's user agent) and telling the app of uncaught errors; the app answering it (`ExtensionAnswers.swift`: offscreen documents, `runtime.getContexts`, `management.getSelf`, waking and reviving the worker), native messaging to desktop apps (`ExtensionNative.swift`), and a worker WebKit failed to start taken up again. Tested in `Tests/extension-shim.mjs` and with test extensions. Phase 2: the Chrome Web Store page's "Add to eGlu" button (`StoreButton.swift`), the daily update check, an update tried before it takes the old version's place and asked about when it wants more (`ExtensionUpdates.swift`), Load Unpacked and Reload, and removal from a space or from eGlu clearing what the extension kept there, on a list kept until done. Tried with Dark Reader from the store. Phase 3: the puzzle button and its list on the sidebar's address row or at the end of the tabs along the top, the list in the order the person drags it to, each extension pressed from it, with its badge (`ExtensionBar.swift`; pinned buttons were dropped on 21 October), the popup in a pane of glass as Handoff's at the corner nearest the buttons (`ExtensionPopup.swift`), the side panel beside the page's card (`ExtensionSidePanel.swift`), extensions' items in the page's menu and their commands in the menu bar, and Settings › Extensions (`ExtensionSettings.swift`); audited by Codex and Gemini, their findings fixed (WebKit's popup closed and its page's address used, surfaces closed before their extension unloads and with their window, "When I Click It" taking grants back as WebKit allows, the side panel's click granting the page, narrow windows). Phase 4: this Mac's table measured once a macOS build by a test extension that asks for everything (`ExtensionTable.swift`: 18 namespaces and 28 members of `tabs` on 27.0.1), what an extension lacks read against it; its content scripts, popup and settings page tried on a copy in a controller that keeps nothing (`ExtensionTrial.check`); the problems it runs into kept on the Mac without their words (`ExtensionRecords`); the tried list (`ExtensionTried`, shipped empty); This Looks Wrong and Report a Problem (`ExtensionReport.swift`); audited by Codex and Gemini, their findings fixed (the copy's website store thrown away with it, only a Chrome API's path ever kept from an error, errors known again by a fingerprint, results kept per macOS build, eGlu and shim, an incompatible extension unloaded, its spaces kept). Phase 5: the list of Chrome Web Store extensions and the spaces they are on in, between Macs through iCloud, in encrypted fields, end to end with Advanced Data Protection (section 6, "What was built"). Phase 6: the words: the README's Chrome extensions on the Mac, Privacy and Mac app sections, PRIVACY.md's Mac section, Docs/Requirements.md, Settings › iCloud's wording for a DMG, and Validation's section 18; checked against the code by Codex and Gemini. Not yet: the shims' other native answers (bookmarks, history, downloads, notifications and the rest of section 1's list), the list's sync tried between two Macs. It is for the Mac app (target "eGlu Mac", macOS 26 and later), distributed as a Developer ID signed DMG; the app won't be on the Mac App Store. Extensions are not planned for iPhone and iPad; section 6 answers what iCloud could carry to them anyway. The Mac app is in progress in another worktree (`Mac/Sources`); paths there are marked "mac". Paths in Search are at `upstream/main`.

Six questions:

1. Can eGlu for Mac run Chrome extensions, and from what?
2. How do extensions fit spaces, windows and tabs?
3. Where do extensions come from, and what does a DMG change?
4. How does eGlu know an extension works, right after it is installed?
5. What does it change in eGlu's promises?
6. If iCloud sync carried extensions, could the iPhone and iPad use the ones installed on the Mac?

Short answers: yes, through Apple's `WKWebExtension` API, in code written for eGlu's spaces from the start, with the extension support of Search, the Mac browser eGlu began as a fork of, as the reference whose fixes are carried over one by one; one extension controller per space, each space one window to extensions; from the Chrome Web Store, with a DMG taking App Review out and the app leaving the sandbox; three checks, at install, in the first seconds and in use, reporting what was seen apart from what is only suspected; the "only three things" promise and PRIVACY.md change; and iCloud can carry the list of extensions between Macs, but the iPhone and iPad would need a runtime of their own, which App Review is unlikely to accept as Search's is built.

## 1. The starting point: Search

Search (github.com/driceroland/Search, MIT, Office Commun) is on this repository's `upstream` remote. eGlu's LICENSE is the same file, so its notice already covers copying Search's code. Search runs Chrome extensions on `WKWebExtension` from macOS 15.4, about 10,400 lines in 16 files under `Sources/Search/`, built over 133 commits.

| Part | What Search does | Where |
| --- | --- | --- |
| Store button | A script on chromewebstore.google.com hides "Switch to Chrome" and copies the grey button as "Add to Search"; the id comes from the tab's address, never the page. A bar shows if the copy fails. Settings also takes a pasted link or id | `StoreRelay.swift:4`, `ExtensionsUI.swift:39`, `:229` |
| Download and check | `clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx3`; the CRX3 header's id must match, and one RSA proof whose key hashes to the id must verify | `Crx.swift:38`, `:107` |
| Unpack and prepare | `ditto -x -k`, refusing any symlink; then the shim rewrites the manifest and scripts in the extension's folder | `Crx.swift:149`, `ExtensionShims.swift:53` |
| Load | One controller for the app; one context per extension with a fixed `uniqueIdentifier` and `baseURL = chrome-extension://<id>/`; manifest permissions and sites granted at load; other extensions' pages and `file:` denied | `Extensions.swift:155`, `:462`, `:470` |
| Permissions | One plain-words list at install; WebKit's per-address prompts refused, as Chrome never shows them; `permissions.request` and match-pattern requests asked as window sheets, remembering the click that led to them | `Extensions.swift:1181`, `:1537`, `:1548`; commit `0e343a9` |
| Tabs and windows | `ExtensionTab` over Search's tab, `ExtensionWindow` over a window; Combine on the tab list drives open, close, move, activate and property events | `Extensions.swift:344`, `:1636`, `:1721` |
| Interface | A puzzle button in the tab bar and sidebar, pins, a right-click menu; options pages in a tab | `Extensions.swift:1776`, `:978` |
| Popup | Search's own NSPopover, 25 to 800 points wide and up to 600 tall, because WebKit's own popup lost messages to the worker | `ExtensionPopup.swift:6`, `:69` |
| Updates | An hourly timer checks when the last check is over 20 hours old; a new version is checked again, and asks first if it wants more | `Extensions.swift:983` |
| Remove | Unload, delete files, `controller.removeData`, then localStorage, IndexedDB and caches cleared through a stand-in page, since `removeData` doesn't reach them; a pending list survives a crash | `Extensions.swift:813`, `:854` |
| Shims | JavaScript put first in every worker, background script, content script and extension page, which fills in what WebKit lacks and answers through `runtime.sendNativeMessage("search", …)` | `ExtensionShims.swift:53`, `:378` |
| Recovery | A background that fails to load is revived after 2 seconds; a wake retries `loadBackgroundContent` three times with an 8-second limit; a page whose ping goes unanswered revives it; a revive reloads the same context at most once a minute | `Extensions.swift:706`, `ExtensionShims.swift:3948` |

What the shims fill in, natively answered: bookmarks, history, downloads (with polled change events), a real side panel, offscreen documents (a hidden web view), tab groups, fonts, management (itself only), notifications (title and message), text to speech, `identity.launchWebAuthFlow` (sign-in in a tab, or out of sight for 60 seconds), idle, power, browsing data, sessions, top sites, system info, user scripts. Stubs answer for privacy, proxy, content settings, omnibox and declarative content. Refused: tab capture, page capture, debugger, push messaging, `identity.getAuthToken`. About 100 missing members of namespaces WebKit has are added, and messaging, ports, workers and request rules get Chrome's behaviour where WebKit's differs (`ExtensionShims.swift:1446` to `:2410`).

Limits to carry over knowingly:

- Events on the namespaces the shims add (bookmarks, history, notifications) aren't implemented, apart from those polled. Swift can push to an extension through a native messaging port, as Search does for native hosts (`ExtensionNative.swift:87`), so they can be added.
- Recovery uses two private WebKit methods, `_backgroundWebView` and `_webExtensionController:didCreateBackgroundWebView:` (`ExtensionWorkerRecovery.swift:73`, `Extensions.swift:1573`). A DMG may use them; any macOS update may remove them. They stay behind a check, with the public-API revive as the fallback.
- Some stubs answer and do nothing (`contentSettings.set`, `ExtensionShims.swift:1634`), and the request-rule rewrite drops rules WebKit refuses (`:2333`): an extension can look fine and do less.
- Still open upstream: WebKit never sends SameSite=Lax cookies from extension pages; user scripts fail under strict page CSP (GitHub); Vimium C's keys; Loom's tab capture (`ROADMAP.md:48`, `:83`, `:88`).
- Search has no compatibility check: Settings says "couldn't start" and counts warnings (`ExtensionsUI.swift:217`). Section 4 is new work.

### How Search is used

eGlu's extension code is written fresh, shaped for spaces from the start (decided 21 October). Search is the reference, not the base:

- **Its fixes are carried over one by one.** Its 133 extension commits are read before writing the part each one touches, and `Docs/ExtensionsFromSearch.md` lists each with what was done: taken, taken changed, or not needed (with why). New upstream commits are read the same way as they land.
- **Parts with nothing of Search's tab model in them can be copied close to as they are**, under the MIT notice eGlu's LICENSE already carries: the CRX3 check (`Crx.swift`), the store page script (`StoreRelay.swift`), the shim's fixes to messaging, ports and workers (`ExtensionShims.swift:412` to `:1006`, `:2787` to `:2840`), the native WebSocket (`ExtensionSocket.swift`). Strings that name Search change: "Add to Search", `application = "search"` (`ExtensionShims.swift:27`), the power assertion's name (`:4162`).
- **Parts built on one window and one store are written again:** the controller, the tab and window following, the shim's native answers (which find tabs by index and window frame), popups, the side panel, settings.
- **Not needed:** private tabs, Search's bench, its passkey relay.

More is written before anything runs than a port would need; in return there is no single-window code to unpick.

## 2. How extensions fit eGlu for Mac

### One controller per space

eGlu gives every space its own `WKWebsiteDataStore(forIdentifier:)` (`App/Sources/Stores.swift:17`, mac `Page.swift:226`) and has no shared default store and no private tabs. Search has one controller on its default store; its roadmap names one per space as the way to extensions per space, put off on 24 September (`ROADMAP.md:87`, commit `1ab7e61`). Apple's documentation allows "one or more extension controller instances" ([WKWebExtensionController](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller)).

- One `WKWebExtensionController` per space: `Configuration(identifier: space.id)`, `defaultWebsiteDataStore` the space's store. A website store alone does not keep extensions apart: a controller sees every tab given to it and keeps one store of extension data ([configuration header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtensionControllerConfiguration.h)).
- An extension is installed once (its files) and turned on per space. Each space's context has its own storage and sign-ins: a password manager signed in to work in one space and personal in another.
- Search keeps its own state by extension id alone: the recovery list (`ExtensionWorkerRecovery.swift:43`, where a second context with the same id replaces the first), side-panel state and optional grants (`ExtensionShims.swift:3439`, `:3554`). eGlu keys all of it by space and extension from the start; this is where copying Search's code as it is would leak between spaces.
- mac `Page.configuration(space:)` sets `webExtensionController` before the view exists, as Search's tabs do (`Tab.swift:95`).
- Search starts extensions one after another, 400 ms apart, because starting all at once failed some workers (`Extensions.swift:201`). With several spaces, one queue covers every controller.

Not yet tried by anyone found: several controllers in one app on macOS 26. Phase 0 tests it.

### A space is a window

In eGlu for Mac, every window showing a space lists all the space's tabs (mac `Sidebar.swift:245`, `TopTabBar.swift:26`); only the tab on screen is the window's own (mac `WindowModel.swift:19`). Chrome's model is windows that each hold their own tabs. So, to extensions, each space is one window, which is what the person sees too:

| WebKit asks | eGlu answers |
| --- | --- |
| Windows | One per space: all its tabs, in the space's order, pinned first |
| Focused window | The space's, when the key window shows the space; none otherwise |
| Active tab | The tab on screen in the key window, or in the window that last showed the space |
| A tab's web view | The page's, or `nil` for a tab frozen off screen (mac `Pages.swift:13`), like a discarded tab in Chrome |
| `tabs.create` | A tab in the space, loaded at once even off screen, since extensions open tabs in the background and wait for them |
| `windows.create`, normal | A new eGlu window on the space, with the new tab; to the extension it is the space's window, not a new one. Stated as a limitation |
| `windows.create`, popup | A small window of its own, of type popup, as Search makes them (`Extensions.swift:1437`): the case extensions use most (a password manager's pop-out) |
| The action's tab | The tab in the window where the button was clicked or the key pressed, passed to `performAction(for:)` |

- A window switching space changes nothing for either space's tabs; the old space's window loses focus and the new one's gains it.
- Two Mac windows on one space are one extension window. Extensions that count windows see one.
- eGlu for Mac has no split view yet (`splitTab` does nothing, mac `WindowModel.swift:532`); when it has, both panes are selected tabs and the one with the keys is active.

What Search assumes, which eGlu's code does differently, so those parts aren't copied:

- The shim names a tab by its index and its window's frame, and the front window is the context for every native call; `windowId` 1 is written in (`ExtensionShims.swift:390`, `:3478`, `:3560`). These become tab and window ids.
- Search swaps a window's row of tabs on a space switch, so extensions see parked tabs as closed (`Spaces.swift:199`). Per-space controllers don't.
- About 70 calls into Search's own model (Tab, Browser, settings keys, palette, shortcuts) move to `Session`, `WindowModel` and `Pages`.

### Extension pages

- An extension page in a tab needs a web view made from `context.webViewConfiguration`. mac `Page.init` installs a fresh `WKUserContentController` and the space's store (`Page.swift:211`), so extension pages take their own path, as Search's do (`Browser.swift:3851`, `Extensions.swift:1683`).
- They get none of the app's page scripts, and their browsing state is never written to disk when the tab is frozen, as a sign-in page's isn't (mac `Pages.swift:97`): a password manager's page shows the vault. They aren't recorded for open-tab sync.
- `AppLink` treats any scheme besides http, https, about, data, blob, file and javascript as another app's and cancels the load (`PadCore/Sources/PadCore/AppLink.swift:17`); the scheme of a loaded extension is let through.

### Hands-off

Google's sign-in stays untouched on the Mac too (mac `Page.swift:71`, `:313`; `PadCore/Sources/PadCore/HandsOff.swift:15`):

- Every context denies `*://*.accounts.google.com/*`. A denied site beats one granted, `<all_urls>` included ([WebExtensionContext.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtensionContext.cpp) `permissionState`).
- A click on an extension's button grants that tab before the denied list is read, so on a hands-off tab `shouldGrantPermissionsOnUserGesture` returns false and the button is off.
- The shims' own native answers check hands-off too. Search's `browsingData` deletes website data, cookies included, straight from Swift (`ExtensionShims.swift:4180`, `:4467`), past every denial above; it leaves alone what `HandsOff.covers(cookieDomain:)` covers, or refuses.
- A `.google.com` cookie, the kind accounts.google.com receives (`HandsOff.covers(cookieDomain:)`, `HandsOff.swift:28`), can be read through `chrome.cookies` by an extension let on any Google host. So the first release denied the `cookies` permission to every extension. Since 2 November 2026 it is denied until the person allows it for that one extension (`ExtensionPolicy.heldPermissions`, `Extensions.setReadsCookies`): its settings have an Allow cookies switch, which says it reaches the sign-ins of every site the extension may read, Google's included, in every space; an extension's own `permissions.request` for cookies asks the same. Until then the check's row says "Can't read cookies until you allow them in its settings". Grammarly is why: it learns whether you are signed in from its grammarly.com cookies (`grauth`, `csrf-token`), and without them says key features are missing. Leaving only Google's cookies out, through the shim, still waits until it is shown that no extension can reach WebKit's own cookie calls past the shim (a page or frame of its own gets a fresh `chrome`).
- `identity.launchWebAuthFlow` opens a provider's sign-in, often accounts.google.com, in a tab: a page like any other, with nothing put into it.

### Permissions and spaces

- **Install sheet:** what it asks for, in plain words; what it may read: On All Sites (offered first when the manifest asks for it), or When I Click It, which grants the tab on each click; where: This Space, or All Spaces, new ones included. It says that each space keeps its own sign-in to the extension.
- **Later:** `permissions.request` asks in a window sheet, as Search does; WebKit's per-address prompts are refused, as Chrome never shows them. Site access changes in Settings, as Chrome's does: On All Sites, On Specific Sites, When I Click It.
- **Saving:** granted and denied permissions are the app's to save (the context header says so), in their own file keyed by space and extension, not in the synced workspace.

### Where extensions show

The sidebar's top row is full (the window's buttons, the sidebar button, back, forward, reload; mac `Sidebar.swift:74`), and its address row holds the address and the … button (mac `Sidebar.swift:28`).

| Place | What |
| --- | --- |
| Tabs in the sidebar | The puzzle button on the address row, after the … button. No pinned buttons (decided 21 October 2026): an extension is used from the list |
| Tabs along the top | The puzzle button at the end of the top tab bar (mac `TopTabBar.swift:33`) |
| Sidebar hidden (⌃⌘S) | No bar is on screen (mac `BrowserView.swift:36`). A popup opened by its key or from the command bar comes from the page card's top corner. A popover opened from the sidebar while it peeks keeps it out: the peek's guard (mac `WindowModel.swift:423`) waits for extension popovers as it does for the … menu |
| The puzzle button's panel | Three pages, so using an extension and setting it up never share a row (decided 21 October 2026). Use: the extensions on in this space as glass tiles, four to a row, as pinned tabs are, each clicked to open it, its badge on its corner, a warning mark on another; dragged to reorder; a secondary click for its menu, a long press for its page in Manage. Manage: every extension with its switch for this space before its chevron, the whole row one target; other Macs' to add; adding. One extension: Use in This Space, Site Access, Version (clicked to copy), its options, Reload, Hide Warnings for This Version (Try Again and Hide Warnings for one that can't run), Report a Problem, and removal last. A row says nothing while its extension works; one that can't run here says "Incompatible", with a warning triangle where its switch was. Right after an install the panel opens by itself |
| Popup | A pane of glass at the page card's corner nearest the buttons, as Handoff's stands: the extension's icon, name and ×, then its page, whose corners (10) the pane's (20) run beside, 10 in. Sized as Chrome sizes popups (25×25 to 800×600), never past the card; unseen until measured; it takes the keys, and Esc or × gives them back to the page. Its page is the one WebKit opened for the tab, in eGlu's own view, WebKit's closed at once (Search's) |
| Side panel | Beside the page card (mac `BrowserView.swift:146`), as Search's `SidePanel.swift`: 360 wide, down to 240 to leave the page 320, unseen in a window too narrow for that. One asked for a tab not on screen opens when it is |
| Menus | The extension's context menu items in the page's menu, which WebKit adds itself (adding them again showed each twice in Search), taken out on Google's sign-in; commands in the menu bar, with no keys unless the person gives them, since ⌘ shortcuts belong to the page |
| Settings | An Extensions pane (mac `SettingsView.swift:38`): every extension, its status, its site access, and its switch in each space, grouped by space as pinned tabs are |

## 3. Where extensions come from

- **The Chrome Web Store**, as Search does: its store page button, a pasted link, the CRX3 check. Two additions: Google's publisher proof, which Chromium requires for store installs (a proof whose key's SHA-256 is `61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf`, [verifier_formats.cc](https://chromium.googlesource.com/chromium/src/+/main/extensions/common/verifier_formats.cc)), and ECDSA proofs, which Search ignores.
- **Load Unpacked**, for developers, as Search does: a folder copied in, its id the SHA-256 of its path, as Chrome does (`Extensions.swift:593`).
- **Not** Firefox Add-ons or Microsoft's store at first: Firefox items are often Manifest V2; Microsoft's redirects to plain HTTP (tested 21 October 2026).

Google's terms let people download items "for use in connection with Google Chrome" and forbid access "through any automated means" ([terms](https://ssl.gstatic.com/chrome/webstore/intl/en/gallery_tos.html), 1.2 and 3.3). Brave, Vivaldi, Opera, Edge, Orion and Search install from the store, and no action by Google against them was found. Not reviewed by a lawyer.

### What a DMG changes

- **No App Review.** Notarization checks the app's signature and scans it for malware before release; it doesn't look at what JavaScript the app loads later ([Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)).
- **The app leaves the sandbox** (decided 21 October). eGlu for Mac is sandboxed today, for the Mac App Store (mac `Config/eGluMac.entitlements`), where it won't go. Search, also a DMG, isn't sandboxed either (hardened runtime only).
  - What it gives: native messaging can start a desktop app's helper (1Password, Bitwarden), which Search finds in `~/Library/Application Support/<browser>/NativeMessagingHosts` (`ExtensionNative.swift:24`) and a sandboxed child process couldn't run; unpacking with `ditto` works.
  - What it costs: the app's own process runs outside the sandbox. WebKit's web content processes keep their own.
  - The entitlements file loses `app-sandbox` and keeps the hardened runtime; `network.client` and the file entitlements go with the sandbox, the camera and microphone stay as hardened-runtime ones, and iCloud keeps its container under a Developer ID profile. The comment that says the sandbox is for the Mac App Store goes too.
  - It moves the data. The workspace, preferences and filter lists live under the process's Application Support (mac `Session.swift:66`), which is inside the container when sandboxed and in the home folder when not, and WebKit's stores move with it. The first unsandboxed launch finds the old container and moves what is in it, once, keeping the container until the move is done. Anyone running a sandboxed build now (the Mac app is unreleased) is the only one it touches.
  - The Mac app is being built in another worktree. Whoever builds it should know the sandbox is going before writing code that leans on the container.
- **iCloud still works.** CloudKit is available to Developer ID apps with a provisioning profile ([Apple](https://developer.apple.com/help/account/reference/supported-capabilities-macos); the page read badly, to confirm). Settings › iCloud's wording for a copy that can't sync ("A copy from the App Store, or one built with your team, syncs", mac `SettingsView.swift:132`) changes for a DMG.
- **Service workers.** The entitlement WebKit asks of iOS browsers for service workers is checked only in WebKit's iOS network process ([NetworkProcessIOS.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/ios/NetworkProcessIOS.mm)); none was found on macOS.
- **The app's own updates** are separate from extension updates: Sparkle 2 with EdDSA signatures is what Orion and Arc use (Gemini's report, unverified); Search has its own updater.

### Install, update, remove

- **Three places, not one folder.** The verified original, as downloaded, never changes. The prepared copy, which the shim rewrites (`ExtensionShims.swift:53`), is made from it for each version and each shim version. What changes while the extension runs, such as the user scripts Search writes into the extension's own folder (`_search/userscripts.json`, `ExtensionShims.swift:4017`), lives per space beside the space's data. An update makes a new prepared copy; the old one goes once no space uses it. A failed load keeps the old version and says why.
- **Where it came from** is kept: the store, with Google's proof, or unpacked. An unpacked extension can never replace a store one, or take its data and permissions.
- **Updates:** Search's daily check (`response=updatecheck`, the `<updatecheck>` reply), a new version signed by the same key, asking again if it wants more. A switch in Settings stops the checks, and Check Now runs one.
- **Turned off in a space:** its context unloads and its data stays. **Removed from a space:** its data there is deleted: `removeData(ofTypes:from:)`, then the stand-in page for localStorage, IndexedDB and caches, as Search does (`Extensions.swift:854`), on the pending list until done; it can't be installed in that space again until the list is empty. **Uninstalled:** the same in every space, then the files.
- **A space removed:** its contexts unload, its extension data is deleted, its controller is let go, and only then is its website store erased, since WebKit won't remove a store anything still holds (`App/Sources/Stores.swift:23`).

## 4. Knowing whether an extension works

An extension that installs has shown only that it installs. Orion's most common complaint is extensions that install with no error and then do nothing ([Orion feedback](https://orionfeedback.org/d/8144)). eGlu checks three times. What it saw and what it only suspects are reported apart, and nothing says a feature works unless that feature was tried. Marked "tested" below: tried on 21 October 2026 on this Mac (macOS 27.0.1, Xcode 27.1) with a small host app and probe extensions, outside the repository.

### What this Mac's WebKit has: measured, not listed

- **WebKit drops what it doesn't support, silently.** It keeps a fixed list of permissions and skips every other one with no error ([WebExtension.cpp](https://github.com/WebKit/WebKit/blob/f9e29ca8792a/Source/WebKit/UIProcess/Extensions/WebExtension.cpp), around line 1643). So the manifest's permissions minus `requestedPermissions` and `optionalPermissions` after load is what WebKit didn't take, which is how DuckDuckGo checks ([classifier](https://github.com/duckduckgo/apple-browsers/blob/8cf517657257/SharedPackages/WebExtensions/Sources/WebExtensions/APICompatibility/WebExtensionAPICompatibilityClassifier.swift)). Tested: on macOS 27.0.1 it dropped `sidePanel`, `offscreen`, `bookmarks`, `identity`, `tabGroups`, `history`, `downloads`, `idle`, `webRequestBlocking` and `topSites`. eGlu's shims, written after Search's, answer most of these, so the shims' list is read on top.
- **A kept permission doesn't promise its namespace.** Tested: `notifications` stayed in `requestedPermissions` and `chrome.notifications` was undefined, being behind a WebKit flag that is off ([UnifiedWebPreferences.yaml](https://github.com/WebKit/WebKit/blob/f9e29ca8792a/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml), around line 7251). Trunk turned `offscreen` on in August; 27.0.1 still drops it. Trunk is not what ships.
- **So eGlu asks its own Mac.** A hidden test extension, built into the app, asks for every permission WebKit keeps and lists every namespace and member it gets (tested: 18 namespaces, 28 members of `tabs`). It runs once per macOS build and the answer is kept. With the shims' list (what eGlu's shims answer, kept beside them, marked native, shim, part, stub or refused), that is the table every check compares against. No hand-kept list of WebKit's support goes stale.
- **Existing tools don't do this.** Apple's `safari-web-extension-packager` (the converter) checks manifest keys against the installed Safari, not the JavaScript, and flags some that work; it needs Xcode, so it is for building eGlu's tried list, not for people's Macs. Mozilla's addons-linter checks against Firefox. MDN's compatibility data has Safari 27 but is wrong in places (it marks `tabs.move` unsupported; WebKit has it) and describes Safari, not a host with shims (all tested or read 21 October 2026).

### At install: reading it (under a second)

- **The manifest:** permissions, background type, content scripts and their worlds, request rule sets, side panel, `oauth2`, `omnibox`, overrides. `WKWebExtension.errors` lists what WebKit found wrong while parsing; some is harmless (tested: a missing `description` is reported), and eGlu keeps a short list of those to ignore.
- **The code:** every `.js` and `.mjs` file and inline script searched for the namespaces and members that nothing answers on this Mac, neither WebKit nor a shim: `.tabCapture`, `?.tabCapture`, `["tabCapture"]`. Not only after `chrome.`: bundlers rename it (`e.tabCapture`), and the namespaces' names are distinctive. A name that is also a web API (`history`) counts only beside one of its members (`history.search`). A short list of web APIs nothing answers (`EyeDropper`) is named the same way, at bare uses only. Strings and known polyfills (webextension-polyfill names 26 namespaces in its metadata) are skipped.
- **What it gives:** notes, never a verdict. An unguarded use becomes "May not work: <feature>". A use inside `typeof`, `if (…)`, `&&` or `?.` gives no note, since the extension is asking, but doesn't count as fine either: a test is not proof of a fallback. Reading misses names made at run time (`chrome[name]`), `eval`, code fetched from servers, and stubs that answer and do nothing.

### In the first seconds: watching it start (5 to 10 seconds)

The person's extension starts as usual, its first tabs and welcome pages included. The checks of its popup, options page and content scripts run on a copy, in a throwaway non-persistent controller, so nothing they do lands in the person's spaces, the copy's requests to open tabs or windows are refused without touching the real one's, and a click on the real button right away opens the real popup.

| Step | How |
| --- | --- |
| 1. Watch | The real context's `errors` and its `errorsDidUpdateNotification`, observed from before `controller.load`, not after as Search does now (`Extensions.swift:490`) |
| 2. Start the background | `loadBackgroundContent(completionHandler:)`, with eGlu's own limit of 5 seconds. Tested: it finished in 0.1 to 0.8 seconds when the worker was fine, and never called back when a service worker threw while starting, while `errors` gained code 6, `backgroundContentFailedToLoad`. A background page with the same throw loaded and kept running. So the notification, not the callback, says it failed; a timeout alone is "not known yet" until recovery has also failed |
| 3. Settle | 2 seconds after the last errors notification |
| 4. Content scripts | Only for extensions whose scripts match most sites: on the copy, a hidden web view loads a small page with `loadHTMLString(_:baseURL:)` and a matching `https://` base address, so nothing goes to the network. Tested: injected after 1.1 seconds. WebKit has no "injected" callback, so no error from a content-script file is the pass. Scripts for one site are not tried on a fake page |
| 5. Popup | On the copy, in a view made from the copy's own configuration, as eGlu's popup pane is, waiting for its load to finish, up to 5 seconds. A timeout is "not known yet". No click is faked |
| 6. Options page | The same, from the copy's `context.webViewConfiguration` |

**Script errors come to eGlu on macOS 27.** WebKit reports uncaught exceptions, unhandled promise rejections, exceptions in event listeners and `console.error` calls into `context.errors`, as code 7, with the file, line and column, from the service worker, the popup and content scripts alike (tested; [commit dde2f84](https://github.com/WebKit/WebKit/commit/dde2f8447714d9b0d6a627f759b5bc201b390126), [Safari 27 notes](https://developer.apple.com/documentation/safari-release-notes/safari-27-release-notes)). This is the main signal after install. On macOS 26 it may not exist: the test extension logs one `console.error` on purpose to find out. Without it, eGlu's shim, which runs first in every worker and page, catches `error` and `unhandledrejection` itself, as Search's does (`ExtensionShims.swift:3411`).

**Telling a real problem from noise.** `console.error` arrives as code 7 too (tested: a success message logged with it counted as an error). So a problem is only an error whose wording points at an API, the patterns DuckDuckGo uses: "is not an object (evaluating '", "is not a function. (In '", "Can't find variable: ", "Invalid call to ". Each becomes a kind (missing, stubbed, wrong arguments) and an API path. A Proxy the shim puts around `chrome` and `browser` records which missing namespace was read (tested: calls still go through it), and still returns `undefined`, so the extension's own feature tests behave as they would without it; a read alone is never a problem, only the name to give a later `TypeError` from minified code. Reads of `runtime.lastError` are ignored.

### In use: keeping watch

- `errorsDidUpdateNotification` for as long as the extension runs. The status changes only on a new error of a known kind, a background that keeps dying, a call to the desktop app (`connectNative`) that fails, or a rule set WebKit refused (an ad blocker can look fine and block less). Checked again after an update of the extension, eGlu or macOS.
- Records stay on the Mac (`Extensions/records.json`, `ExtensionRecords`): the extension and its version, the eGlu, macOS and shim versions, where it happened (its worker, its popup, a content script, another page), the API, the kind, how often, first and last time. At most 200 an extension, for 30 days, and gone with the extension. Never arguments, page text, addresses or the error's own words, which can hold an address or an account name.
- The puzzle button shows one dot for something new; the extension's row says what doesn't work. No repeated notices.
- Hide Warnings for This Version (once called This Looks Wrong) keeps the person's own verdict until the extension updates. Report a Problem shows what would be sent, lets the person add words, and copies or saves it for them to send. Nothing goes on its own.

### What the person reads

Decided 21 October 2026: a row says nothing while its extension works. Words appear only when something doesn't.

| Seen | In the row (the puzzle button's list, Settings › Extensions) | In its help, and in a report |
| --- | --- | --- |
| Still checking, or started and its checks passed | Nothing | "Checked: starting up, a test page and its popup. Its features haven't all been tried." Any notes from reading follow, as "May not work: record a tab" |
| An error of a known kind, at start or in use, or a check that failed | "Some Features Don't Work", in orange | The feature, as "Can't open its side panel" |
| A call to its desktop app failed | "Some Features Don't Work" | "Can't reach the Bitwarden app." |
| The background didn't answer in time | "Couldn't Start", in orange; its switch stays | "eGlu tried starting it again." |
| Code 6 again within a minute of being started afresh, WebKit refusing the package, or the tried list saying it doesn't work | "Incompatible", a warning triangle in the switch's place: turned off wherever it was on (what it stored is kept) and can't be turned on, for this version | The same |
| Not enough to say (only scripts for one site, timeouts) | Nothing | |
| On the tried list for this version, working | Nothing | "Tried by eGlu on version 2.3", with what was tried |

Hide Warnings for This Version, or Try Again and Hide Warnings for an incompatible one (in the row's … menu, and in Settings), hides an extension's warnings and gives an incompatible one its switch back, off, for the version it is now; an update brings them back, and Show Its Warnings Again undoes it. Report a Problem… shows the whole report in a sheet: the extension, its version and where it came from, eGlu's and macOS's versions, what the checks found, and the problems kept on the Mac. The person adds their words and copies or saves it; eGlu sends nothing.

Only the tried list says a feature works, because only there was the feature used. Reading alone never changes the status.

Three, as expected and not yet tried:

- **uBlock Origin Lite:** request rules, offscreen, scripting, user scripts (its [manifest](https://github.com/gorhill/uBlock/blob/master/platform/mv3/chromium/manifest.json)). Started Fine if it starts and the popup loads, since the shims answer offscreen; Some Features Don't Work if WebKit refused some of its rules, with the number. Whether it blocks well is for the tried list.
- **Bitwarden:** side panel and offscreen, both answered by the shims, and optional native messaging ([manifest](https://github.com/bitwarden/clients/blob/main/apps/browser/src/manifest.v3.json)). "Can't reach the Bitwarden app" shows only if it tries and fails, so someone without the desktop app sees nothing about it.
- **Grammarly:** its manifest couldn't be fetched. Signing in may go through `identity`, which the shims answer only for `launchWebAuthFlow`; whether it works shows in use.

One tried by hand, not yet on the tried list:

- **Mesurer** 0.2.7 (25 October 2026, [evidence](ExtensionCompatibilityEvidence-2026-10-25.md)): it declares no content scripts and injects its toolbar with `scripting`, so the shim is given an entry of its own on the hosts it asked for, and goes in front of the files `scripting.executeScript` injects, which a click-only grant reaches too; its colour tool's `EyeDropper` is answered by the Mac's `NSColorSampler`. Inspecting, X-ray, guides, the colour and screenshots work; recording a tab can't (`tabCapture`). It goes on the tried list once distances and notes, its other main features, have been tried too.

Two password managers tried in a test copy on macOS 27.0.1, 26 October 2026, from the store's archives:

- **iCloud Passwords** 3.4.0: its worker stopped as it started, at `webNavigation.onHistoryStateUpdated`, which WebKit lacks, so it never asked for Apple's helper; its popup stopped at `chrome.privacy`. With the shim's fills it starts and asks for the helper. macOS then kills the helper: `PasswordManagerBrowserExtensionHelper` carries a parent launch constraint that admits only a browser signed with `com.apple.developer.web-browser.public-key-credential`, or one of a fixed list of browsers by signing identifier and team (Chrome, Edge, Firefox, Arc and Dia, Brave, Orion and others), and AMFI kills it under any other ("Launch Constraint Violation", the same with ad hoc, Apple Development and Developer ID signatures). It can work once eGlu is signed with that entitlement, the one passkeys wait on. Until then the extension's port closes as soon as it opens; eGlu's check reads that only as "Can't use runtime.connectNative", since the helper did start before it was killed.
- **Bitwarden** 2026.10.0, from the store: its worker stopped at `chrome.scripting.ExecutionWorld`, an enum WebKit lacks. With the fill it starts, but its pages' `runtime.connect` was refused ("No runtime.onConnect listeners found") before its worker had a listener, where Chrome closes the port; with the shim holding a listener from the worker's first moment it reads Started Fine, its popup and a test page checked. Its popup's "Tab not found" came from the trial's pages, which are in no tab, and no longer counts. The Bitwarden app wasn't on that Mac.
- **1Password** 8.12.42.36: its worker stopped at `chrome.notifications`, then at `storage.managed`; with the fills it starts, loads its core, and asks for the 1Password app (not installed on that Mac, so not tried further). It reads the Chrome version and opens its popup to unlock only for 149 or later, so eGlu now says 156.

The tried list ships with each release (`ExtensionTried.shipped`, empty until an extension has been tried by hand on eGlu): Chrome Web Store id, a version range, the verdict and what was tried, made by eGlu's developers with the same checks, the packager and their own hands. Search's author tried popups one by one in 37 store extensions (commit `ace649a`); that list is the place to start. MDN's data (CC0) can ride along as notes on single members, never as a verdict. No server: the list changes with the app, and looking an extension up in it happens on the Mac, so the list of what someone installed never leaves it.

## 5. What it changes in eGlu's promises

| Where | Today | With extensions |
| --- | --- | --- |
| README.md:18 | Asks the internet for only three things | Four, the fourth only once an extension is installed: the Chrome Web Store, for the file and a daily check that names the installed extensions to Google |
| README.md, Known limitations | No extensions | What works, what doesn't, and why |
| PRIVACY.md | Collects nothing; never reads your cookies | eGlu still collects nothing, but an extension reads the sites you let it and can send what it reads anywhere, their cookies too if you allow it; the install sheet and its settings say so |
| Docs/Requirements.md | | One controller per space, the hands-off denials and native checks, the CRX check, the compatibility records staying on the Mac |

## 6. iCloud, the iPhone and the iPad

The question: if iCloud sync carried Chrome extensions, could the iPhone and iPad use the ones installed on the Mac?

**Between Macs, yes: the list of extensions syncs, and each Mac installs for itself. To the iPhone and iPad, it is possible in WebKit but unlikely to pass App Review as Search's support is built**: the iPhone and iPad would need an extension runtime of their own, which nothing in this plan builds; 2.5.2 forbids downloading code that changes the app's features; and 4.7.2 forbids offering native APIs to plug-ins without Apple's permission, which is what Search's shims do, answering extensions from the app's Swift code. A version for them would have to be a plain one, with no shims, and still face 2.5.2 and 4.7.4 (an index with links).

### What could be synced

| Sync | For | Against |
| --- | --- | --- |
| **The list**: each extension's id, version, where it came from, and which spaces it is on in | Small records. Each Mac downloads from the store and checks Google's signature itself. Nothing is copied. Safari does the same: only on and off syncs, and each device installs its own copy ([Apple](https://developer.apple.com/documentation/safariservices/syncing-safari-web-extensions-across-devices-and-platforms)) | Each Mac names its extensions to Google. Versions can differ for a while. Unpacked extensions can't follow |
| **The files**, as CloudKit assets | One download from Google | 1 to 25 MB each (Dark Reader 0.85 MB, uBlock Origin Lite 9.1, 1Password 18.0, Bitwarden 24.9, measured 21 October 2026), uploaded again with each update and counted against the person's iCloud; every device likely downloads every file; Google's terms (3.5) forbid copying an item without its developer's permission |
| **Permissions** | Fewer questions on the second Mac | Answers given on one Mac, for its sites, are not the person's answer on another; the second Mac's sheet starts from them and asks |
| **Extension data** (making `storage.sync` sync) | What the name promises | The app can't read or write an extension's storage: WebKit gives only the size of its data and a way to delete it ([WKWebExtensionDataRecord.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebExtensionDataRecord.h)). The ways in are WebKit's private database file, or patching each extension's `storage.sync` through the shim. Never `storage.local`, which can hold a vault and tokens |

### How it would sit in today's sync

- New record types, `Extension` and `ExtensionUse` (one per extension and space, pointing at the space's `cloudID`), not new fields on `Space`: the desktop Chrome extension saves `Space` records whole from its own list of fields (`Extension/src/cloudkit.js:154`), so fields it doesn't know would be wiped.
- The app and the desktop extension skip record types they don't know (`App/Sources/Sync.swift:434`, `Extension/src/model.js:64`), so they keep working. But a client that skips them can't delete them: a space removed on an older app or in the desktop extension leaves its `ExtensionUse` records behind. Apps that know the types remove `ExtensionUse` records whose space is gone, after the space's deletion has arrived, never before (records can arrive out of order).
- All their fields in `encryptedValues`, which Advanced Data Protection encrypts end to end ([Apple](https://support.apple.com/en-us/102651)). Today's sync writes plain fields (`Sync.swift:418`) so that the desktop extension can read them (`Docs/SyncDesign.md:152`); it never needs to read these. Random record names, not extension ids: names stay readable to Apple. The list is sensitive in itself: it can show a password manager, accessibility tools, religious or political ones.

### What was built (phase 5)

- `Extension` (store id, name, site access) and `ExtensionUse` (its record, a space's iCloud id) in `SyncModel.swift`, every field in `encryptedValues` (`SyncKind.isEncrypted`), record names random. Only Chrome Web Store extensions are listed.
- A Mac sends only its own changes, from the list it last sent (`SyncPlan.publish`, the list kept in `sync.json`): one it added gets a record, or another Mac's for the same store id; one it removed loses its record and uses; its switches add and remove uses. What only other Macs have is left alone, so a Mac that hasn't installed something never takes it from the others.
- Another Mac's change is followed (`SyncPlan.follow`): removed there, removed here with what it kept, as Chrome's sync does; turned on or off in a space there, the same here, when it is installed here.
- One not on this Mac is offered in the puzzle button's list, "On Your Other Macs": Add downloads it and checks Google's signature here, and this Mac's own sheet asks, starting from the other Mac's site access; Not on This Mac stops the offer. Nothing is installed unasked.
- Every app that knows the types carries them through its mirror untouched (the iPhone and iPad too), and removes a space's uses when the space's deletion arrives (`SyncPlan.uses(ofRemoved:)`), not before; the last 500 removed spaces are remembered, so a use that comes later goes too.
- What following another Mac changes here isn't sent back: nothing is sent while it is applied, and the list as it then is becomes what was last sent. A switch for a space that hasn't arrived waits for it. Joining takes up the other Macs' spaces for the extensions this Mac has before its own list is first sent. Two Macs that added the same extension at once, offline, make two records; both are read as one.
- An extension that can't run on one Mac (Incompatible) is unloaded there with its spaces kept, so the other Macs don't turn it off.
- One added from On Your Other Macs goes on in the spaces it is on in there too, besides those its sheet chose, so this Mac's choice turns nothing off on the others.
- A device that ran an older build had skipped these record types and moved past them: on its first launch with this one, sync fetches the zone again from the start, once, keeping what was waiting to be sent (`Sync.schema`).
- What can still be seen without the fields: how many records there are and when they change. An extension's store page is left out of the open tabs other devices see (`SyncPlan.isShareable`), since it would name the extension in plain words.
- Before a release: the two record types, with their encrypted fields, deployed from CloudKit's development schema to production (CloudKit Console), as new record types need. Not tried between two Macs yet: the test copy has no iCloud container.

### What differs on iPhone and iPad, for the record

| | Mac | iPhone and iPad |
| --- | --- | --- |
| Persistent backgrounds (Manifest V2) | Run | Refused at load ([WebExtensionContextCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm)); every store item is Manifest V3 since 31 August 2026 |
| `windows.create`, `update`, `remove` | Yes | Missing ([WebExtensionAPIWindowsCocoa.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/Extensions/API/Cocoa/WebExtensionAPIWindowsCocoa.mm)) |
| Native messaging | To a desktop app's helper, through the app | To eGlu only |
| Service workers | No entitlement found | `com.apple.developer.web-browser`, which the App Store build has (`Config/eGlu.entitlements`) |
| App Review | None (DMG) | 2.5.2 and 4.7 ([guidelines](https://developer.apple.com/app-store/review/guidelines/)); Orion installs Chrome and Firefox extensions on iOS, and its request to sync them has been open since November 2022 ([orionfeedback.org/d/3614](https://orionfeedback.org/d/3614)); no iOS browser that syncs installed web extensions was found |

## 7. Plan

| Phase | Ships | Main files (mac) | Size |
| --- | --- | --- | --- |
| 0. The core, and the shape | Behind a debug switch: eGlu's own controller per space loading one store extension from a file, the sandbox gone and the data moved; the answers below; `Docs/ExtensionsFromSearch.md` started | `Extensions.swift`, `ExtensionTabs.swift`, `Crx.swift` (copied); `Page`, `Pages`, `Session`, the entitlements | L |
| 1. Spaces | Every space's controller, state keyed by space and extension, a space as a window, extension pages on their own path, hands-off in denials and in native answers, `cookies` denied (since 2 November: until the person allows it for the extension) | `Extensions.swift`, `ExtensionTabs.swift`, `ExtensionShims.swift` (written, with Search's messaging and worker fixes copied); `WindowModel` | L |
| 2. Install, update, remove | The store button, the publisher proof, originals, prepared copies and per-space data apart, updates, removal with the stand-in cleanup | `Crx.swift`, `ExtensionStore.swift`; `App/Sources/Stores.swift` | M |
| 3. Interface | Puzzle button, pins, popover, side panel, options, menus, the install sheet, Settings › Extensions | `ExtensionBar.swift`, `SidePanel.swift`; `Sidebar`, `TopTabBar`, `BrowserView`, `SettingsView`, `Menus`, `WindowModel` | L |
| 4. Compatibility | The test extension and its table, the reading, the first-seconds checks on a copy, the records, the words, the tried list, This Looks Wrong, Report a Problem | `ExtensionCheck.swift`, a test extension in the app's resources; PadCore for the scanner and the error patterns, which are pure logic and get unit tests | L |
| 5. iCloud list | `Extension` and `ExtensionUse` records between Macs, with orphan removal | `App/Sources/Sync.swift`, `PadCore/.../SyncModel.swift` | M |
| 6. Words | README, PRIVACY.md, Requirements.md, Settings › iCloud's wording for a DMG, a Validation section | Docs, mac `SettingsView.swift` | S |

Sizes are relative to each other, not estimates of time.

Phase 0 answers, before anything else is built on it:

1. Do two controllers with two identifiers keep `storage.local` and sign-ins apart on macOS 26? Does the same extension in two spaces survive reload, recovery and removal in one without touching the other?
2. Where do originals, prepared copies and per-space data live, given that the shim rewrites files and user scripts are written at run time?
3. Out of the sandbox: where each kind of data moves (workspace, preferences, filter lists, WebKit's stores, the iCloud sync state), and does the first launch move it all and keep sync working?
4. Do the private recovery methods still exist on macOS 26 and 27?
5. Do the app's own `removeAllUserScripts` and `removeAllContentRuleLists` leave extensions' scripts and rules alone, as WebKit's source says (`RemoveWebExtensions::No`, [WebUserContentControllerProxy.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/UserContent/WebUserContentControllerProxy.h))?
6. Does denying `*.accounts.google.com` keep an `<all_urls>` content script out, after a redirect, in frames, and after a click on the button?
7. Does macOS 26 report script errors as code 7, as 27 does? The host app and probe extensions used for section 4 are a starting point.
8. How much memory do five extensions take in three spaces?

Answered so far, on macOS 27.0.1 only, with the test extension (macOS 26 is not on hand):

- 1, in part: two spaces keep `storage.local` apart (each space's mark differs). Sign-ins, reload, recovery and removal are not tried yet.
- 2: the original stays as it came, `Extensions/<id>/<version>.zip`, beside its prepared folder, `Extensions/<id>/<version>/`, which is made again when the shim changes (a stamp in `_eglu/stamp`); a new version takes the old one's place and its files go. Per-space data is WebKit's, in `WebKit/<bundle id>/WebExtensions/<space id>`. User scripts written at run time are not built yet.
- 5: yes; the app's script resets leave the extension's content script running.
- 6, in part: a direct load of `accounts.google.com` keeps the `<all_urls>` content script out. Redirects, frames and the button are not tried yet.
- 7, for 27: uncaught errors in the worker, a promise nobody catches included, come as code 7 with file, line and column. The shim reports the same errors itself, for where WebKit doesn't.

Messaging on 27, with the shim and without it (`-extensionsWithoutShim`, a debug switch), against Chrome 148's rules ([developer.chrome.com](https://developer.chrome.com/docs/extensions/develop/concepts/messaging)), in a classic worker and in a module one:

| A content script's message | Chrome 148 | WebKit alone | With the shim |
| --- | --- | --- | --- |
| Answered late by a second listener that returned true | The answer | The answer: Search's fix isn't needed on 27, kept for 26, not checked here | The answer |
| Answered by nobody | `undefined`, `lastError` "The message port closed before a response was received." | `undefined`, no `lastError` | As Chrome |
| Answered with `sendResponse()` | `null` | `undefined` | `null` |
| A listener's promise rejects | The sender's call fails with its message | The sender is never called back | As Chrome: the gate answers a failure marked as one, which the sender's shim makes `lastError` or a rejection |

- `chrome` and `browser` are one object in WebKit.
- A module worker imports the shim before its own imports run; its lines stay where they were. A classic worker has the shim's text in front, so WebKit's line numbers in it are later by the shim's lines (16 became 242 in the test extension). Nothing shows them yet; whatever does will take that off.
- Tried in both worker kinds: an offscreen document is made, answers a content script's message, and hears one its worker sent, relayed between the pages; `runtime.getContexts`, `management.getSelf` and `clients.matchAll` answer.
- Not yet: scripts an extension injects with `scripting.executeScript` run without the shim (and would see a marked failure as an object); the relay for frames inside an offscreen document.

## 8. Risks, most likely first

1. **Extensions that fail quietly.** Mitigation: section 4, and the tried list.
2. **Several controllers**, never tried by Search, and Search's state keyed by extension id. Mitigation: phase 0; the fallback is one controller for the app, with extensions shared across spaces, as Search has it.
3. **Private WebKit methods** gone in a macOS update. Mitigation: a check, and the public revive.
4. **Meeting Search's bugs again**, since the code is fresh. Its shims are 4,900 lines and still changing. Mitigation: each part is written after reading Search's commits that touch it, `Docs/ExtensionsFromSearch.md` records what was taken, and new upstream commits are read as they land.
5. **Leaving the sandbox** losing data. Mitigation: the move in phase 0, the container kept until it is done, before anyone outside development has a build.
6. **Google** objecting to downloads from its store. Mitigation: Load Unpacked stays; the download is one module.
7. **Leaks between spaces.** Mitigation: a controller per space, state keyed by space, a phase 0 test.
8. **Hands-off** broken through an extension, its cookies or a shim. Mitigation: denials, no grant on click, checks in native answers, no `cookies` permission unless the person allows it for one extension, told it reaches Google's sign-in cookies, tests.
9. **The list in iCloud** read by Apple, or left behind by older clients. Mitigation: `encryptedValues`, random record names, orphan removal.

## 9. Decisions

Decided on 21 October 2026, by the app's owner except where marked.

| # | Question | Decided | Not chosen |
| --- | --- | --- | --- |
| 1 | Build on Search's extension code, or write it fresh | Written fresh, shaped for spaces from the start; Search's fixes carried over commit by commit, and the parts with no tab model in them copied (section 1) | Porting Search's code and changing it for spaces |
| 2 | The sandbox for the DMG | Off, as Search ships. The app won't be on the Mac App Store. Password managers reach their desktop apps; native helpers and unpacking work; the data moves once (section 3) | Staying sandboxed |
| 3 | Site access at install | Chosen in the install sheet: On All Sites, offered first when the extension asks for it, or When I Click It; changed later in Settings, as Chrome has it | Safari's: asked site by site |
| 4 | `chrome.cookies` | Denied to every extension in the first release, decided by Claude at the owner's request. Google's sign-in cookies (`.google.com`) can't be kept out otherwise until filtering through the shim is shown to hold, and few popular extensions need cookies; those that do are told why in their row. Filtering is the next step if phase 1 shows an extension can't get past the shim. Changed on 2 November 2026 at the owner's request: the person's choice for each extension, off until allowed, the hands-off promise for cookies narrowed to eGlu's own code and to extensions not allowed them (Grammarly's sign-in needs them) | Allowed with the shim filtering, from the start; or allowed, with the hands-off promise narrowed to eGlu's own code |
| 5 | iCloud | The list of extensions syncs between Macs; nothing for the iPhone and iPad now | An iPhone and iPad runtime without shims, with App Review asked first |

## Sources

Research by Claude agents (Search's code, the codebase, the WebKit API, install and policy, Chromium's source, the compatibility check with a test host on macOS 27.0.1, iCloud and iOS), Codex (the codebase, the web, a design for the compatibility check, reviews of both plans), and Gemini (other browsers' extension interfaces, Mac distribution, reviews of both plans). Every review finding was checked against the code before it changed the plan. Search at `upstream/main` 6294b6a (18 October 2026); WebKit trunk at f9e29ca (21 October 2026); Chromium at 1263d01e (21 October 2026).
