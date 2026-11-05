# Web engines in eGlu for Mac

This document describes the implemented contracts for a Mac engine plugin. It is for an engineer who knows Swift and their engine, including someone considering Chromium through
CEF. It describes the source in this checkout. The signatures in `EngineSplitPlan.md` section 5 are earlier sketches. Where support or behavior is not specified, this document says
so.

## 1. Packages, ownership and build selection

The interface is `Mac/` and the `Shared/` sources it compiles. It owns windows, spaces, tabs, settings, permissions, and the product `Page`. A plugin owns engine objects and
translates engine callbacks into contracts. Plugins receive hosts and dependencies. They do not call `Session.shared` or import app sources.

| Package or target | Responsibility |
| --- | --- |
| `WebEngineKit/WebEngineCore` | Foundation value types and protocols for navigation, scripts, data and services. |
| `WebEngineKit/WebEngineAppKit` | Mac page, view, UI, factory and extension contracts. |
| `WritingServiceKit` | Grammar engine and service contracts. |
| `DocumentServiceKit` | Byte-based document reading contract. |
| `WebKitEngine/WebKitSupport` | WebKit stores, downloads, rules, hidden pages, SVG drawing and script transport. |
| `WebKitEngine/WebKitMacPlugin` | Mac WebKit page, view, delegates and services. |
| `WebKitEngine/WebKitExtensions` | Extension runtime and the WebKit page factory that wires it to pages. |
| `EnginePlugins/HarperPlugin` | `HarperGrammarEngine`, using Harper through `Engines`. |
| `EnginePlugins/DocumentsPlugin` | `EnginesDocumentReader`, using anydoc and pdf-inspector through `Engines`. |
| `PadCore` | Product policies, scripts, filter parsing and other shared logic. |

The contracts and support packages declare macOS 26 and iOS 17 deployment targets. The Mac page and extension implementations use AppKit. `WebKitEngine/Package.swift` uses Swift 6
except for `WebKitExtensions`, which explicitly uses Swift 5. That exception preserves the concurrency behavior of code moved from the Mac app. The iPhone and iPad app still uses
WebKit directly and links `WebKitSupport`. Replacing the Mac engine does not replace the iOS engine.

### Composition

There is no runtime plugin loader, plugin registry or engine-selection preference. Selection is source construction plus package products linked when building the app.
`project.yml:54` defines the `MacApp` template used by both Mac targets. Its dependencies currently include the three WebKit products and the Harper and Documents products.

`Mac/Sources/EngineComposition.swift:10` contains the WebKit-specific composition:

- `makePageEngine()` returns `AppPageEngine(factory: pageFactory)` as `any MacPageEngine`.
- `pageFactory` is a `WebKitMacPageFactory`. Its closures defer runtime and capture lookups until needed.
- `makeExtensionRuntime()` returns `WebKitExtensionRuntime`, with `ExtensionHost.shared`, storage, page configuration access and app error construction.
- `storage`, `browserAnswers` and `scriptAnswers` provide contract-typed helpers also used by static app calls.
- `pageCapture` supplies screen-capture queries and page release through `WebExtensionPageCapture`.
- Other members provide scheme registration, worker invalidation, archive helpers, diagnostics, metadata, auth checks and native transport.

Replacing only `makePageEngine()` is insufficient to remove the WebKit dependency. A replacement composition must also answer the other `EngineComposition` members used by the app.
The contract packages do not define one plugin-construction protocol covering these members. Their concrete WebKit casts and helper calls belong in the composition file, not in
callers.

`Mac/Sources/MacPageEngine.swift:10` is an app protocol, not an external plugin protocol. `AppPageEngine` wraps each factory-created `WebMacPage` in the app's `Page`. It forwards
rasterizing, rules, downloads and spelling to the factory. It keeps product work in the app: store-removal bookkeeping, starting `ContentBlocker`, and starting `Extensions`.

`Mac/Sources/Plugins.swift` separately selects the other two plugin kinds:

| App dependency | Current selection |
| --- | --- |
| `WritingChecker.engine: any GrammarEngine` | `HarperGrammarEngine()` |
| `DocumentSource.reader: any DocumentReader` | `EnginesDocumentReader()` |
| `PluginLicences.text` | `HarperGrammarEngine.licences`, covering both `Engines` consumers. |

### Launch order

`Session` owns one `MacPageEngine` and gives that same engine to `Pages`. The order in `Mac/Sources/Session.swift:99` and `:183` is:

1. Make the selected page engine through `EngineComposition.makePageEngine()`.
2. Construct `Pages(engine:)`.
3. Open the workspace and read preferences.
4. On `start`, enter `startWorkspaceServices` if the workspace is usable.
5. Sweep pending website-store removals through the engine.
6. Prune history, then snapshots, then start page memory monitoring.
7. Start content blocking through the engine.
8. Start extensions through the engine, passing `afterLaunch`.
9. Start Elsewhere writing checks and, when enabled and available, sync.
10. Back in `start`, apply writing preferences, start the writing menu and check Apple Intelligence availability.

The DEBUG hosted-test path skips workspace services. Keep engine construction free of eager `ContentBlocker.shared` or `SiteIcons.shared` access. Those objects ask
`Session.shared.engine` for their dependencies. The current composition uses deferred closures to preserve first-use order.

### Engine boundary and its enforcement

The boundary: no `import WebKit` or `import Engines` in `Mac/` or `Shared/`, and the web engine plugin's modules (`WebKitExtensions`, `WebKitMacPlugin`, `WebKitSupport`)
imported only in `Mac/Sources/EngineComposition.swift` (which today imports `WebKitExtensions` and `WebKitSupport`; `WebKitExtensions` reaches `WebKitMacPlugin` itself). Harper and Documents are imported in `Mac/Sources/Plugins.swift`, their composition point. Engine types stay in their
packages; the app sees contracts, Foundation and AppKit values.

The build enforces it. Both Mac targets run an "Engine boundary" build phase before compiling (`project.yml`, the `MacApp` template's `preBuildScripts`), which runs:

```sh
cd "$SRCROOT"
/usr/bin/python3 Tests/engine-inventory.py --strict
```

`--strict` scans only imports and exits 1 on an `import WebKit` or `import Engines` in `Mac/` or `Shared/`, or an import of one of the web engine plugin's modules in either
outside the composition point (`COMPOSITION_FILES` in `Tests/engine-inventory.py`). Each offending line is printed as an Xcode error at its file and line, so the build stops
there. The rest of the inventory (types in declarations, reach-ins, private calls) is reported by the script without `--strict` and does not fail the build. A plugin for another
engine changes `COMPOSITION_FILES` only if its composition point is another file, and names its own modules where the WebKit plugin's are named.

## 2. Making and connecting a page

### Factory and sources

Implement `WebMacPageFactory` in `WebEngineKit/Sources/WebEngineAppKit/WebMacPageFactory.swift:15`. It is a main-actor class protocol. Its complete requirements are:

```swift
var svgRasterizer: any WebSVGRasterizer { get }
var spaceStores: any WebSpaceStores { get }
func ruleListStore() -> (any WebRuleListStore)?
func makePage(space: UUID, source: WebMacPageSource) -> any WebMacPage
func downloadStarter(space: UUID) -> any WebDownloadStarting
func spellingFollows(writing: Bool, pages: [any WebMacPage])
```

`makePage` is synchronous and does not throw. Its sources are:

| `WebMacPageSource` | Meaning and WebKit behavior |
| --- | --- |
| `.space` | A fresh page using the named space's store and extension controller. |
| `.tab(URL?)` | A tab's page. WebKit first checks whether the URL needs a loaded extension's configuration; otherwise it uses the space configuration. |
| `.child(any WebChildRequest)` | A child made from the engine's request inside the call that requested it. |
| `.supplied(any ExtensionPageConfiguration)` | An extension configuration passed through the app unchanged. Only the matching engine interprets it. |

The URL in `.tab` selects configuration. The app performs loading or restoration afterwards. WebKit's factory is in `WebKitExtensions`, because it must install the extension UI
delegate before the ordinary UI adapter. For `.child` and `.supplied`, it checks for its own opaque implementation types. Passing requests or configurations from a different engine
is not supported.

### `WebMacPage`

`WebEngineKit/Sources/WebEngineAppKit/WebMacPage.swift:47` defines the main-actor page protocol. It inherits `WebRequestLoading`, whose commands are `load(_ request: URLRequest)`
and `loadFile(_:allowingReadAccessTo:)`. The page exposes these objects and values:

| Member | Required answer |
| --- | --- |
| `contentView: NSView` | The engine's own view. |
| `state: PageState` | The current engine state, without product navigation rules. |
| `isExtensionPage: Bool` | Whether this page was made as an extension page. |
| `traits: Set<WebTrait>` | Capabilities reported by the plugin. Default: empty. |
| `swipe: (any WebSwipe)?` | Edge and rubber-band control. Default: nil. |
| `coordinates: (any WebPageCoordinates)?` | Page-to-screen coordinate conversion. Default: nil. |
| `scripting: any WebPageScripting` | App script installation and evaluation. |
| `channels: any WebMessageChannels` | App message transport in the specified worlds. |
| `ruleListTarget: any WebRuleListTarget` | Replacement of this page's compiled rule lists. |
| `services` | One object conforming to all nine service protocols listed below. |

Its other commands are `goBack()`, `goForward()`, `stopLoading()`, `reload()` and `reloadFromOrigin()`. It must also implement `connect`, `stopObserving`, `hiddenPage`,
`takeSnapshot` and `tearDown`. `makePicturePage(from:size:)` has a default implementation returning nil. There is no public `WebEnginePage` or `WebEngineMacPage` protocol matching
the plan's sketch.

`Page.init` retains the engine page, channels, services and rule target. It then calls this once, supplying itself in all six roles (`Mac/Sources/Page.swift:242`):

```swift
func connect(policy: any WebNavigationPolicy,
             navigation: any WebNavigationEvents,
             ui: any WebPageUIEvents,
             presenter: any WebDialogPresenter,
             state: any WebPageStateEvents,
             view: any WebPageViewEvents)
```

After connecting, the app opens feature channels. WebKit retains its adapters and observations, but holds their app recipients weakly. A plugin must avoid keeping the product page
alive through callback recipients. The reference implementation delivers callbacks directly, without adding a task or queue turn.

### State and observation

`PageState` has `url`, `title`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward` and `hasOnlySecureContent`. It is `Sendable` and `Equatable`
(`WebEngineCore/PageState.swift`). The contract does not specify a progress range or a separate initial-state event. The app reads `state` when notified.

Notify `WebPageStateEvents` synchronously on the main actor where the change occurs:

| Callback | State that changed |
| --- | --- |
| `titleOrAddressChanged()` | Title or URL. |
| `loadingChanged()` | Loading state. |
| `progressChanged()` | Estimated progress. |
| `backOrForwardChanged()` | Either history direction. |
| `secureContentChanged()` | Secure-content state. |

These are separate from navigation lifecycle callbacks. WebKit observes seven properties and maps them into these five callbacks. The app's `Page.canGoBack` adds replacement
history to the engine's `canGoBack`. `Page.goBack()` first consumes a replaced page when the engine cannot go back, then uses the engine command. Do not implement that product rule
inside a plugin. The app also keeps retry policy, crash counting, history recording and navigation preparation.

### Navigation decisions

`WebNavigationPolicy` is in `WebEngineCore/WebNavigation.swift:88`. Both methods take a nonescaping reply and require exactly one reply before returning:

```swift
func decideNavigation(_ navigation: WebNavigation,
                      reply: @MainActor (WebNavigationDecision) -> Void)
func decideResponse(_ response: WebResponse,
                    reply: @MainActor (WebResponseDecision) -> Void)
```

Both decision enums contain `.allow`, `.cancel` and `.download`. There is no `.openExternal` decision. The app cancels first and handles an external link itself. Do not suspend for
permission, defer the policy to another turn or let the engine proceed before the answer. WebKit cancels if its policy is absent or returns without replying, and guards against
duplicate answers.

Preserve every field when translating an engine request:

| `WebNavigation` field | Meaning |
| --- | --- |
| `request: URLRequest` | Whole request, including HTTP method, body, headers and request settings. |
| `sourceOrigin: WebOrigin` | `.tuple(scheme:host:port:)` or `.opaque`; port 0 means the scheme's default. |
| `sourceIsMainFrame: Bool?` | nil when the engine cannot identify the source frame. |
| `targetIsMainFrame: Bool?` | Optional target-frame information, not an invented true or false. |
| `kind: WebNavigationKind` | `.link`, `.form`, `.formResubmission`, `.history`, `.reload`, `.other` or `.unknown(Int)`. |
| `modifiers: WebModifiers` | Independent `command`, `shift`, `option` and `control` bits. |
| `buttonNumber: Int` | Raw button number. No portable button enumeration is defined. |
| `requestsDownload: Bool` | The engine's download request flag. |
| `isServerRedirect: Bool` | Whether this is a server redirect. |
| `contentRuleRedirect: WebContentRuleRedirect?` | A separate content-rule redirect fact. Its `originalSite` may itself be nil. |

A nil `contentRuleRedirect` means no such redirect was reported. A non-nil value with nil `originalSite` means a marked redirect whose source the app must obtain from its pending
site. WebKit obtains redirect facts through guarded private selectors. The contract does not specify a substitute when another engine cannot report them. The app's existing
button-number interpretation is retained; no cross-engine normalization is defined.

`WebResponse` retains a Foundation `URLResponse`, `isForMainFrame` and `canShowMIMEType`. Use `HTTPURLResponse` when HTTP status and headers are available. The app reads its
case-insensitive header lookup and status directly.

### Navigation lifecycle and children

Report the main frame's lifecycle in order through `WebNavigationEvents`:

| Callback | Required information |
| --- | --- |
| `navigationStarted(url:)` | The address the engine now shows. |
| `navigationRedirected(url:)` | The current address after a provisional server redirect. |
| `navigationCommitted(url:)` | The address of the new document replacing the old one. |
| `navigationFinished()` | Load finished. |
| `navigationFailed(_:provisional:)` | `WebLoadError` and whether it failed before commit. |
| `contentProcessEnded()` | The content process ended and the page is blank. |
| `navigationBecameDownload(_:)` | A download the app must take over inside this callback. |

`WebLoadError` contains `kind`, `domain`, `code` and `failingURL`. Its kinds are `.cancelled`, `.interrupted` and `.other`. The app suppresses failure UI for the first two. WebKit
maps URL cancellation to `.cancelled`, WebKit errors 102 and 204 to `.interrupted`, and other failures to `.other`. There are no navigation IDs, document IDs or frame handles in
the implemented contracts.

When a site requests a window, call `WebPageUIEvents.childRequested(_:)` synchronously. `WebChildRequest` carries `navigation` and `features: WebWindowFeatures`, with optional
`width` and `height`. Keep the engine's child configuration privately in the request implementation. The app accepts by making a page through `.child(request)` and returning its
`WebEngineSurface` before the callback returns. Returning nil rejects the request. There are no `accept()` or `reject()` methods. The plugin returns the accepted child to its
engine inside the original engine call, preserving the opener relationship. Do not queue child creation.

### Scripts and message channels

`WebPageScripting` is in `WebEngineCore/WebPage.swift:17`. It has `removeAllUserScripts()`, `addUserScript(source:injectionTime:forMainFrameOnly:world:)`, and
`addFilterScripts(blocker:scriptlets:)`. Injection is `.atDocumentStart` or `.atDocumentEnd`. User scripts apply to future documents; installation alone does not evaluate them in
the current document. The app separately evaluates features enabled in a document already loaded.

`evaluateJavaScript(_:world:completionHandler:)` evaluates source. `callAsyncJavaScript(_:arguments:world:completionHandler:)` calls a body with `[String: Any]` arguments. There is
also an `async throws -> Any?` overload of `callAsyncJavaScript`. Evaluations target the main frame. Values and errors pass through as Foundation values. The callback forms accept
an optional `Result<Any, any Error>` completion handler. The protocol defines no subframe evaluation or stale-document handle check.

`WebWorld.app` is the app's isolated script world; `.page` is the page's world. WebKit uses the named `eGlu` world for `.app`. Filter blocker scripts run at document start in the
app world; scriptlets run at document start in the page world, both in the main frame. The app checks HandsOff and feature policy before guarded reads, writes and script
installation. Navigation, find, printing and snapshots are not all prohibited by HandsOff. A plugin must preserve the requested world. Running an app-world script in the page world
is not an equivalent implementation. There is no implemented automatic app fallback when `.isolatedScripts` is missing.

Implement `WebMessageChannels` with a `bridgeScript` and both `open` overloads:

```swift
func open(_ channel: String, in world: WebWorld,
          handler: @escaping WebMessageHandler)
func open(_ channel: String, in world: WebWorld,
          replying handler: @escaping WebMessageReplyHandler)
```

The app prefixes each script using the transport with `bridgeScript` in that script's world. The script API is `globalThis.egluBridge.version` (1), `post(channel, body)` and
`request(channel, body)`. `post` sends a message; `request` supplies the reply as a promise result. WebKit's bridge is defined once as an own property of each world's global
object. Its missing-channel behavior is a `TypeError` from the underlying handler lookup.

Each `WebMessage` carries `channel`, `world`, `isMainFrame`, `origin` and `body: WebJSON`. Frame information is only the main-frame flag and origin, not a frame ID. The engine
records the world, frame flag and origin. Never trust JSON fields for those facts. `WebJSON` supports null, booleans, numbers, strings, arrays and string-keyed objects. Its
`foundation` conversion preserves the app's existing parsers; unsupported input values become `.null`. Feature handlers still perform their own origin, site, run and settings
checks. Extension capture uses its runtime's separate sender checks, not this generic message authority.

Handlers run synchronously from the engine callback on the main actor. A replying handler receives `reply(WebJSON?)` and must reply once, either immediately or later. nil resolves
with JavaScript `undefined`. WebKit ignores a second reply. There is no channel-registration token, close method or unregister method. Cancellation of pending replies on
navigation, world destruction or teardown is not specified by this protocol. The WebKit implementation leaves that lifecycle to WebKit, as the plan's step 6 record notes.

### Views, UI and lifetime

The app exposes the engine view to window hosts as `WebEngineSurface`, with `view: NSView` and `focus()`. `PageWebKitSurface` is the app's neutral implementation despite its
historical name. It returns `enginePage.contentView` and makes that view its window's first responder. Hosts place, constrain, size and move the actual view between windows. Key
events, the responder chain and appearance remain the engine view's responsibility.

`WebPageViewEvents` lets the app handle scrolls and swipes before the engine; true consumes the event. `prepareSwipe()` runs during connection; false asks the engine to enable its
own history gestures. `movedToWindow()` runs after the view's own move handling. Its `menus` object implements `WebPageMenus`. The plugin supplies `WebContextMenu`: an action
target, its open-link item identifier, title lookups and extension-item classification. The app changes the native `NSMenu` and can forward an existing engine item's action. The
contract's comments mention WebKit, but its exported types are AppKit types.

`WebPageUIEvents` also reports `closeRequested()`, `contextMenuOpening(link:)` and `scrollNotHandled(_:)`. Without element-link information, report nil. The app then has no
linked-file URL for its Handoff item. Only an engine reporting `.correlatedUnusedWheelEvents` should report unused scrolls.

`WebDialogPresenter` answers alerts, confirms, prompts and file panels through callbacks. The title context is the asking frame's host string, empty if absent, not a `WebFrame`.
Answers may wait: the app holds one background-tab dialog until the tab is shown. The app cancels that dialog on navigation or teardown. WebKit with no presenter completes an
alert, answers false to confirm, and nil to prompt or file selection. Every engine-side dialog request must receive its answer once.

The app's teardown order (`Mac/Sources/Page.swift:299`) is explicit:

1. Stop measuring, cancel its held dialog, dismiss the Apple Passwords card, and close picture and Peek pages.
2. Call `stopObserving()`.
3. Stop the app's swipe.
4. Remove user scripts, then remove blocking lists through the rule target.
5. Release extension capture for an extension page.
6. Call engine `tearDown()`, then clear the product host.

Engine `tearDown()` stops loading, detaches delegates and removes the view. It does not replace the explicit script and rule removal above. The current contract does not promise
universal cancellation of outstanding operations or reuse after teardown. Downloads already adopted by the app have their own lifetime. Page, factory, UI and most service
operations are main-actor operations. The callback-thread exceptions for rule compilation, native connections, grammar and document work are described below.

## 3. Services, storage, history and blocking

### Required services and optional capabilities

`WebMacPage.services` requires all of these protocols on one object; none is optional:

| Protocol | Required behavior |
| --- | --- |
| `WebFind` | `find(_:backwards:caseSensitive:wraps:found:)`; report whether a match exists. |
| `WebZoom` | Read and write `pageZoom`; read pinch `magnification`. Both use 1 for actual size or no magnification. |
| `WebMediaCapture` | `isCapturing` covers camera or microphone, live or muted. |
| `WebUserAgent` | Read and write `customUserAgent`; nil means the engine's default. |
| `WebPrinting` | `printOperation(with:) -> NSPrintOperation`, ready to run for the page's current layout. |
| `WebDeveloperTools` | `show(_:) -> Bool` for `.inspector`, `.console` or `.elementSelection`; false if unavailable. |
| `WebBackForward` | `currentEntry: AnyObject?`, used only for stable entry identity. |
| `WebRestoration` | Read and write opaque `restorationData: Any?` for the same engine. |
| `WebDownloadStarting` | Page-session download and resume operations. |

Find, zoom, capture, user agent and developer tools are in `WebEngineCore/WebPageServices.swift`. Printing is in `WebEngineAppKit/WebPrinting.swift`, as it uses AppKit's
print types; history, restoration and downloads are in `WebEngineCore/WebBackForward.swift`, `WebRestoration.swift` and `WebDownloads.swift`. Returning false from developer tools invokes the app's existing fallback message; it does not hide the menu. The current contract has no unsupported-printing result and no general service-availability query.

`WebTrait` declares six traits. Current app behavior is narrower than the plan's general capability-hiding goal:

| Trait or optional object missing | Current app behavior |
| --- | --- |
| `.rubberBandControl`, `.correlatedUnusedWheelEvents` or `swipe` | `PageSwipe.works(on:)` returns false. `prepareSwipe()` returns false, requesting the engine's own gestures. |
| `coordinates` | Apple Passwords cannot place its field card; the placement guard returns. |
| `makePicturePage` returns nil | The app cannot make the document picture window. |
| `.isolatedScripts` | No app trait check suppresses script features. |
| `.documentPictureInPicture` or `.videoPictureInPicture` | No app trait check hides or suppresses the picture scripts. |
| `.contextMenuElement` | No direct app trait check. A nil link omits the linked-file Handoff item. |

Do not advertise an unsupported trait. Empty traits alone do not disable all unsupported features. There is no extension-support trait or general extension-availability property.

`WebSwipe` exposes `pinnedEdges`, `isInFullscreen` and `setRubberBandingEnabled(_:)` using `WebPageEdge` values. It must answer synchronously before the engine handles the scroll.
`WebPageCoordinates.screenRect(of:zoom:)` maps a CSS rectangle from the page's top left into screen coordinates. The caller supplies page zoom times magnification. Return nil while
the view has no window.

`WebPicturePage` is an optional child surface, connected to `WebPicturePageEvents`. It reports navigation decisions, window requests, close and process termination.
`decidePictureNavigation` requires its Bool reply before returning. Its teardown detaches delegates and removes the view without stopping the load, allowing the site's pagehide
behavior when released.

`takeSnapshot(with:completionHandler:)` returns an `NSImage?` and error asynchronously through a main-actor callback. `WebSnapshotOptions` contains optional `rect`, `width` and
`afterScreenUpdates`; nil preserves engine defaults. No image format, pixel scale or unsupported-snapshot error is specified by the protocol.

### Space stores, history and restoration

`WebSpaceStores` owns persistent website data per space UUID. Pages, hidden transcript pages, extension controllers and download retries must use their intended space's session.
WebKit keeps one `WKWebsiteDataStore` object per space until forgotten, using that space's identifier on disk. It does not expose that object to the app.

`isMade(_:)` reports whether the store was made this run. `forget(_:)` releases and empties the store's current data. `prepareForRemoval()` readies the engine for disk removals.
`remove(_:removed:)` reports true once disk removal succeeds. The app's `Stores` records pending IDs in `stores.erasing`, waits two seconds after erasure and retries at launch. It
skips stores made this run and removes a pending marker only after success. The app removes a space's extensions and data before asking the engine to erase its store.

`WebBackForward.currentEntry` must return the same object for the same held history entry. The app compares entry identity with `===` and object-keyed maps. Do not allocate a new
wrapper for each read of the same entry. There is no contract for enumerating or importing a complete engine back-forward list. Product history remains in
`Shared/HistoryRecorder.swift`.

`WebRestoration.restorationData` is opaque `Any?`, not necessarily `Data`. WebKit passes through `interactionState`. `Page` ignores nil assignments. `Pages` retains state in memory
for a matching space and URL, then gives it to a newly made page. If the restored page has no URL, the app loads the tab's recorded URL. Disk snapshots save restoration values only
when they are `Data` (`Shared/Stores.swift:111`). Sign-in and extension pages do not save their restoration state to disk (`Mac/Sources/Pages.swift:164`). The snapshot files have
no engine tag or version. Cross-engine session migration is not supported.

### Downloads, hidden pages and SVG

`WebDownload` carries `originalURL`, `originalRequest`, the engine's `Progress`, a weak delegate and `cancel(_:)`. Cancellation returns optional resume `Data` through a main-actor
callback. `WebDownloadDelegate` decides a destination URL or nil, then receives finish or failure with optional resume data. After `navigationBecameDownload`, the app's Downloads
owns the download independently of the page. WebKit installs its wrapper as the native download delegate immediately, before forwarding to the app.

`WebDownloadStarting` supplies `canStartDownloads`, `keepingSessionAlive()`, `startDownload(using:completionHandler:)` and `resumeDownload(fromResumeData:completionHandler:)`. A
page starter uses that page's sign-ins and becomes unavailable after its session is gone. A space starter remains available and owns the session needed for a retry.
`keepingSessionAlive()` returns a starter retaining the existing session for one asynchronous operation; it makes no new page. The app uses this for Handoff fetches so the session
survives the fetch. Check `canStartDownloads` first. The start and resume signatures have no explicit start-failure result. Resume bytes are engine-specific; portability is not
specified.

`WebHiddenPage` is a one-read page beside the visible page, in the same store. `WebMacPage.hiddenPage(ruleLists:allows:)` (`WebEngineAppKit/WebMacPage.swift:69`) receives compiled lists and an `allows(URL?) -> Bool` policy.
`begin(_:within:)` returns true on commit, or false on failure, refusal or timeout. `callInAppWorld(_:arguments:)` runs in its main frame and app world. `stop()` ends the page and
answers false to a waiting `begin`. WebKit checks the supplied rule for main-frame navigation, refuses downloads, suspends media and puts its transparent view below the visible
view. The app's `Unseen` keeps HandsOff, the allowed site and patience policy. Concurrent `begin` calls are not specified; WebKit replaces its one waiter, so callers use it once.

`WebSVGRasterizer.png(of:side:dark:)` returns a centered square PNG with transparency, or nil when drawing fails. The contract describes a three-second draw limit. WebKit uses a
lazily created nonpersistent page, forces the SVG's requested light or dark look, draws to canvas and returns PNG bytes. Its three-second timer covers image decoding; initial page
readiness has no separate deadline. `SiteIcons` owns image conversion and asks for light and dark variants when needed.

### Content rules accepted by a plugin

`WebRuleListStore.compile(forIdentifier:encodedRules:completionHandler:)` receives encoded rules, not raw filter-list sources. Today those rules are WebKit content-blocker JSON
produced by PadCore's `BlockingRule`, `ContentBlocking.json`, `RulePlanner` and `FilterConverter`. Those types remain in `PadCore/Sources/PadCore/ContentBlocking.swift`, contrary
to the early section 5.5 sketch. A plugin implementing blocking must accept that format and implement or translate its behavior. There is no engine-neutral filter-source input or
alternate format negotiation.

| Encoded part | Fields and values generated by the current model |
| --- | --- |
| Top level | An ordered JSON array of objects containing `trigger` and `action`. |
| Trigger | `url-filter`, optional `url-filter-is-case-sensitive`, `resource-type`, `load-type`, `load-context`, `if-domain`, `unless-domain`. |
| Action | `type`: `block`, `ignore-previous-rules` or `css-display-none`; hiding also has `selector`. |
| Exceptions | `ignore-previous-rules` undoes earlier matching rules in its own list. Preserve order and list boundaries. |
| Top-level document allowance | The planner appends an allowance for `resource-type: ["document"]`, `load-context: ["top-frame"]`. |

`WebRuleList` is an engine-owned compiled object with an `identifier`. `lookUp` returns a cached list or an error through its callback. Compilation and lookup callbacks run on the
engine's callback thread, with no actor hop promised. `removeOld(withPrefix:keeping:)` starts removing matching obsolete lists without waiting for each removal.
`WebRuleListTarget.replaceAll(with:)` removes all current lists, then adds the given lists in order; an empty array only removes. Use lists from the same plugin. WebKit rejects a
foreign compiled-list type.

The app's `ContentBlocker` keeps downloads, folders, preferences, conversion, publication and live-page updates. `PageBlocking` applies no lists on HandsOff or disabled sites.
Returning nil from factory `ruleListStore()` disables the app's compiled-list build path; it does not hide blocker settings or disable separately injected scripted filters. For
scripted filters, implement the separate `addFilterScripts` world and timing rules above.

## 4. Writing and document plugins

These are separate plugin kinds. Replacing the web engine does not require replacing them. Their source contracts are
`WritingServiceKit/Sources/WritingServiceKit/GrammarService.swift` and `DocumentServiceKit/Sources/DocumentServiceKit/DocumentReader.swift`.

### Grammar

`GrammarEngine: Sendable` has synchronous `makeService(_:) throws -> any GrammarService`, `rules() throws -> [WritingRule]`, and `canCheck: Bool`. Making a service must be quick;
dictionary preparation waits for warm-up or linting. `GrammarService` is a reference type and `Sendable`, so the app can discard stale answers by service identity. Its four methods
are `nonisolated(nonsending)`, asynchronous and throwing:

- `configure(_ configuration: WritingConfiguration)`.
- `warmUp()`.
- `lint(_ text: String) -> [WritingIssue]`.
- `ignore(context: String)`.

There is no provider ID, availability method or shutdown method on the service. `WritingConfiguration` has optional `dialect`, rule overrides and dictionary words. `WritingDialect`
is American, British, Canadian, Australian or Indian, with those raw strings. `WritingRule` has `id`, `label`, `description`, `group` and `isOnByDefault`. `WritingIssue` has
`start`, `end`, `rule`, `kind`, `message`, `priority`, `suggestions` and `context`. Offsets are UTF-16 code units in the exact lint input. The stable `context` is passed to
`ignore(context:)`. Suggestions are `.replace(String)`, `.insert(String)` or `.remove`. The Codable forms of rules, suggestions and issues are also used by the app; preserve them.

`HarperGrammarEngine` maps these values to one `Engines.Grammar` actor per service. It forwards configuration, warm-up, lint and ignore without changing their order.
`WritingChecker` keeps language filtering, preference changes, the chain of configuration changes and stale-result checks. `spellingFollows(writing:pages:)` lets the web plugin
coordinate its native spell checking with the app's writing feature. No generic native-spelling availability result is defined.

### Documents

`DocumentReader: Sendable` has synchronous throwing methods, called by the document source's concurrent work:

```swift
func detect(_ bytes: Data) throws -> DocumentKind?
func markdown(_ bytes: Data, kind: DocumentKind?) throws
    -> (kind: DocumentKind?, markdown: String)
func pdfPages(_ bytes: Data, pages: [Int]?) throws -> DocumentPages
```

`DocumentKind` is `doc`, `docx`, `odt`, `pdf`, `ppt`, `pptx`, `rtf`, `epub`, `excel`, `ods`, `odp` or `csv`. `DocumentPages` contains `pageCount`, optional `title`, `author` and
`created`, `pages`, `withTables` and `withColumns`. Each nested `DocumentPages.Page` has a zero-based `page`, `markdown`, `needsOCR` and optional `reason`. The protocol does not
specify the format of `created` or extra page-selection semantics. `DocumentReadError` carries a `kind` and `message`. Kinds are `needsOCR`, `unsupported`, `malformed`,
`encrypted`, `resourceLimit`, `missingPart`, `io`, `panic`, `tooLarge` and `unknown`.

`EnginesDocumentReader` maps `Engines.Documents` values and converts `EngineError` to `DocumentReadError`, retaining kind and message. Other errors pass through unchanged. The
reader works on bytes only. Authenticated fetching remains a page-session download, outside this contract.

## 5. Extensions

### Runtime and app host

`WebExtensionRuntime` is the plugin-owned execution contract (`WebEngineAppKit/WebExtensionRuntime.swift:4`). `ExtensionRuntimeHost` is the app-owned answer contract
(`WebEngineAppKit/ExtensionRuntimeHost.swift:4`). The app supplies `ExtensionHost.shared`, whose conformances are distributed across `Mac/Sources/Extension*Host.swift`.
`Extensions` retains the runtime and keeps the catalog, choices, verdicts, notifications, installation UI and presentation. The runtime keeps controllers, contexts, grants,
workers, engine pages, dispatch and execution state. Most calls and callbacks stay inline on the main actor. An explicit async method or permission wait may suspend.

The runtime composes these parts. Each name has a same-named contract file under `WebEngineAppKit/`:

| Runtime part | App host part | Work crossing the contract |
| --- | --- | --- |
| `WebExtensionStorage` | `ExtensionStorageHost`, inherited through `ExtensionInstallHost` | Package and prepared paths, records path, app-owned roots; synchronous nonisolated preparation. |
| `WebExtensionMetadata` | `ExtensionMetadataHost` | Icons, manifest facts, package names, options, new-tab and side-panel addresses. |
| `WebExtensionCompatibility` | `ExtensionCompatibilityHost` | Source scans, API measurement, trials, check stamps and plain evidence. The app decides verdicts. |
| `WebExtensionControllers` | `ExtensionControllerHost` | Load/unload, loaded membership, address classification, site access and cookie grants. |
| `WebExtensionWorkers` | `ExtensionWorkerHost` | Stamps, stale-worker clearing, revive/restart and recovery events. |
| `WebExtensionEvidenceRuntime` | `ExtensionEvidenceHost` | Evidence dictionaries, deduplicated problems and sanitized error records. Contract file: `WebExtensionEvidence.swift`. |
| `WebExtensionCleanup` | `ExtensionCleanupHost` | Durable clearing, package and space removal, page closure and pending cleanup. |
| `WebExtensionInstallExecution` | `ExtensionInstallHost` | Download, archive checks, update verification, keeping/loading, trials, folder snapshots, ZIP and checksum. |
| `WebExtensionRuntimeAnswers` | `ExtensionRuntimeAnswerHost` | Keep-awake lifetime; runtime dispatch uses host consent, language detection and color sampling. |
| `WebExtensionScriptAnswers` | `ExtensionScriptHost` | Generated scripting files, user-script lists, changes, worlds, containment and pruning. |
| `WebExtensionBrowserAnswers` | `ExtensionBrowserAnswerHost` | Popup paths, tab lookup, favicons; browser dispatch uses page and pane snapshots and panel operations. |
| `WebExtensionPermissions` | `ExtensionPermissionHost` | Press dates and typed permission prompts, including an opaque presentation target. |
| `WebExtensionAdapters` | `ExtensionBrowserHost` | Inline address/loading notifications and popup membership. |
| `WebExtensionDiagnostics` | `ExtensionDiagnosticHost` | Runtime report lines, page diagnostics and app-provided verdict lines. |
| `WebExtensionDispatch` | `ExtensionDispatchHost` | Tab/action/command operations, options, panes, accessibility checks, capture and controller callbacks. |

The host also composes `ExtensionAuxiliaryPageHost` and `ExtensionCaptureHost`. Their definitions are in `WebExtensionSurface.swift` and `ExtensionCaptureHost.swift`. They answer
camera/microphone questions, display-capture decisions, view lending and return, consent and recording-indicator state. The app chooses sheet windows and owns the recording
indicator and Stop presentation. The plugin owns capture sender checks, tokens, grants and engine-specific capture execution.

The public runtime protocols expose the operations the app calls. They do not require another engine to implement WebKit's private dispatcher or controller-delegate methods. For
example, `WebExtensionRuntimeAnswers` exports `releaseKeepAwake(_:)`; its WebKit implementation has additional private dispatch operations.

### Values, identities and opaque objects

The boundary carries no `WKWebView`, controller, context, permission or match-pattern type. It does carry Foundation and AppKit values, contract objects and opaque handles:

| Type or value | Meaning |
| --- | --- |
| Extension `String` ID plus space `UUID` | Runtime lookup scope. One extension enabled in two spaces has separate runtime state. |
| Tab, space and popup `UUID` | App identity. The plugin owns any mapping to its engine's identities. |
| `ExtensionBrowserWorkspace`, `ExtensionBrowserSpace`, `ExtensionBrowserTab` | Value snapshots of ordering, selection, URL, title and pinned state. |
| `ExtensionBrowserWindow`, `ExtensionBrowserFocus` | Window frames, state, visibility and focus. |
| `ExtensionBrowserPage` | A live `any WebMacPage` plus held and displayed URLs, never the product `Page`. A frozen tab has only its record. |
| `ExtensionPageConfiguration` | Empty marker protocol for an engine-owned configuration passed through unopened. |
| `ExtensionPermissionTarget` | Empty marker protocol interpreted only by the app to choose presentation. |
| `WebExtensionCommand.Identity` | Context UUID plus command string. A command retained across a context replacement must not execute in the new context. |
| `WebExtensionAction` | Icon, label, badge text and enabled state for one render. |
| `WebExtensionInstallation` | Catalog copy with source, site access, spaces, grants, folder, warning override and cookie choice. |
| `WebExtensionEvidence`, `WebExtensionErrorRecord` | Sanitized runtime facts, without page text or raw error messages. |
| `WebExtensionInstallArchive` | Opaque archive object with version, grants, permissions, sites, name/icon and version checking. |
| `WebExtensionStorageEnvironment` | Extension root and temporary root supplied by the app. |

`ExtensionBrowserHost` owns tab/window operations, including product Back and the refusal to close a space or make a private window. It supplies deferred extension-ID and
configuration closures when opening a tab, preserving lookup timing. Workspace observations arrive on the subscription's next main-queue turn; page and focus callbacks remain
inline. The WebKit runtime must not insert another scheduling turn. After waits, runtime slices recheck current installations where their operations require it.

`WebExtensionSurface` extends `WebEngineSurface` with extension ID, space, URL, focus, `measure()`, `close()` and `onClose`. `ExtensionPanePage` pairs the surface with its name and
icon; `ExtensionPaneSource` defers entry lookup and page creation. The app owns popup and side-panel presentation, timers and focus restoration. The plugin owns the auxiliary page
and its delegates.

`WebNativeConnection` is separate from the composed runtime. It exposes `onMessage`, `onEnd`, `start()`, `send(_:)` and `stop()` for length-prefixed JSON transport.
`WebExtensionNativeTransport.nativeConnection(program:origin:)` constructs one without starting it. Callbacks run on the transport's read and termination queues; callers choose
actor hops. Keeping the connection keeps its transport. No WebKit type crosses this contract. The current composition uses it for Apple Passwords' helper connection.

### A plugin without extensions

There is no built-in empty runtime, optional runtime property or extension availability switch. The current composition always makes a `WebExtensionRuntime`, and `Extensions.start`
still performs app-owned catalog and startup work. A build without extension execution must supply a contract implementation and replace the WebKit-specific composition helpers.
The exact complete no-extension behavior is not specified or tested as an app configuration here.

The contracts provide absent answers for the corresponding queries:

- `isLoaded`, `asks`, `hasNewTabPage`, `isNewTabPage`, `popupShows`, `webAccessible`, `revive` and `restart` can report false.
- Icons, options/new-tab/side-panel URLs, actions, commands, `sidePanelSource`, tab lookup and opening can return nil when absent.
- `externalListings`, runtime evidence, popup paths and permission presses can be empty collections.
- Notification and teardown operations need no engine work if there is no runtime state.
- Throwing install or script operations can report an explicit unsupported error. There is no standardized unsupported-extension error.

These return shapes are not a supplied no-extension implementation. Nonoptional path, archive and script results still require implementations, and nonthrowing load operations must
report failure rather than claim execution. Do not copy the tests' fatal errors into a production fallback. The interface does not automatically hide the extension catalog,
settings or store UI based on runtime availability.

### WebKit compatibility code a Chromium build leaves out

`PadCore/Sources/PadCore/Scripts/extension-shim.js` exists to adapt Chrome APIs to WebKit's extension runtime. `ExtensionStorage` passes it into prepared extension copies through
PadCore's preparation code. `WebKitExtensionRuntimeAnswers` receives the shim's messages and `WebKitExtensionDispatcher` routes its API names. `WebKitExtensionControllerDelegate`
translates WebKit controller questions into runtime and host operations. The answers include worker wake/revive, offscreen pages, contexts, tabs, panels, scripting, user scripts,
permissions, idle/power, capture and auth. Unknown dispatcher APIs throw the app-supplied unanswered error.

Plan section 5.8 says a Chromium build leaves out this shim and its answers, adding only what eGlu itself needs. It does not require a second implementation of the WebKit
compatibility layer. The historical `Mac/Sources/ExtensionAnswers.swift` now contains contract forwarding and the app's `Unanswered` error, not the old answer switch. Its
forwarding calls still compile as app code unless that composition is changed. The generic `egluBridge` for app scripts is separate and still needs an engine implementation. Full
Chromium extension parity, CEF integration and CEF packaging are not specified by these contracts.

## 6. Implementing another engine

Use this order to satisfy the current Mac app's dependencies:

1. Create a package that depends on `WebEngineCore` and `WebEngineAppKit`. Keep engine types inside that package.
2. Implement the space-session owner and `WebMacPageFactory`, including SVG, optional rule store, retry downloads and spelling coordination.
3. Implement `WebMacPage` with its own `NSView`, state, required services, script transport and rule target. Use empty traits and nil optional objects only for capabilities actually absent.
4. Implement connection and direct state/lifecycle delivery. Preserve synchronous policy replies and child construction inside engine callbacks.
5. Implement both script worlds, main-frame evaluation, channel metadata and replies. Preserve the app's HandsOff decisions and supplied script timing.
6. Implement stable history identity, same-engine restoration, adopted-download lifetime, hidden pages, snapshots, dialogs and native menus.
7. Supply the extension runtime and all composition answers, either with engine execution or explicit absent/unsupported behavior. Preserve the separate native transport if the build keeps Apple Passwords support.
8. Replace WebKit construction and imports in `EngineComposition.swift`, and replace the Mac template's WebKit product dependencies in `project.yml`. Keep Harper and Documents in `Plugins.swift` unless replacing those plugin kinds too.
9. Regenerate the Xcode project as the repository requires after project changes. Keep the iOS app's `WebKitSupport` dependency separate.
10. Verify contract behavior and Mac composition. The package fakes below are examples, not a completed alternative-engine build.

There is no documented CEF adapter in this repository. Plan section 8 records expected Chromium integration work, including an engine view hosted in the app's AppKit windows.
Engine startup, renderer communication, distribution and packaging remain the new plugin's responsibility.

### What the fakes demonstrate

These tests import contracts and can answer their interfaces without importing WebKit in those test files:

| File | Example |
| --- | --- |
| `WebEngineKit/Tests/WebEngineCoreTests/WebNavigationTests.swift` | `RequestLoader` accepts requests and distinct file read-access URLs. |
| `WebEngineKit/Tests/WebEngineCoreTests/WebNavigationEventsTests.swift` | `DownloadEvents` retains an adopted fake `Download` independently of its producer. |
| `WebEngineKit/Tests/WebEngineCoreTests/WebMessagesTests.swift` | `MessageChannels` preserves worlds, inline handler delivery and a deferred reply. |
| `WebEngineKit/Tests/WebEngineAppKitTests/WebEngineSurfaceTests.swift` | `FakeSurface` focuses its actual `NSView`. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionMetadataInterfaceTests.swift` | `FakeMetadata` answers metadata and detached package-name reads. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionCompatibilityInterfaceTests.swift` | `FakeCompatibility` uses catalog identities and plain evidence. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionControllersInterfaceTests.swift` | `FakeControllers` implements load membership and grants by extension ID and space. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionPermissionsInterfaceTests.swift` | Fake runtime, host and opaque target answer permissions without engine objects. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionScriptAnswersInterfaceTests.swift` | `FakeScriptAnswers` supplies paths, lists and worlds. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionComposedRuntimeInterfaceTests.swift` | `DispatchFakeRuntime` conforms to the entire composed runtime and exercises a small subset. |
| `WebKitEngine/Tests/WebKitExtensionsTests/ExtensionDispatchFixtureHost.swift` | `DispatchFixtureHost` conforms to the composed app host, delegating browser work and recording calls. |

The composed runtime fake deliberately traps on unused operations. These are conformance and focused behavior examples, not production implementations. The surrounding
`WebKitEngine` test target still depends on WebKit implementations. `WebKitMacPageFactoryTests` uses real WebKit types with injected nonpersistent stores and callbacks. The hosted
Mac page tests also test WebKit pages and use `Tests/MacPage/PageWebKitForTests.swift` for direct inspection. No complete fake `WebMacPage` build configuration replacing WebKit is
present in `project.yml`. Thus the plan's full fake-engine app-build goal is not established by these package fakes.

### What is not promised

Plan section 1 excludes runtime plugin loading, a Chromium implementation, cross-engine sign-in/history/session migration, feature parity, and a new engine abstraction for iPhone
or iPad. The implemented contracts also do not promise a stable binary plugin ABI, portable serialized engine state, arbitrary frame evaluation or an automatic UI fallback for
every missing capability. The protocol surface can be implemented without exposing engine types, but a build must still satisfy the current composition and required services.

## 7. WebKit implementation map

Paths in the implementation column below are relative to `WebKitEngine/Sources/`. Core contract files are under `WebEngineKit/Sources/WebEngineCore/`; Mac and extension contracts
are under `WebEngineKit/Sources/WebEngineAppKit/`.

| Contract or value | WebKit implementation and file |
| --- | --- |
| `WebMacPageFactory`, `WebMacPageSource` | `WebKitMacPageFactory`, `WebKitExtensions/WebKitMacPageFactory.swift`. |
| `WebMacPage`, `PageState`, `WebPageStateEvents` | `WebKitMacPage`, `WebKitMacPlugin/WebKitMacPage.swift`. |
| `WebRequestLoading`, `WebNavigationPolicy`, `WebNavigation`, `WebResponse` | `WebKitNavigationAdapter`, `WebKitMacPlugin/WebKitNavigationAdapter.swift`. |
| `WebNavigationEvents`, `WebLoadError` | Same navigation adapter, including error classification and download adoption. |
| `WebChildRequest`, `WebWindowFeatures` | `WebKitChildRequest`, `WebKitMacPlugin/WebKitChildRequest.swift`. |
| `WebPageUIEvents`, `WebDialogPresenter` | `WebKitUIAdapter`, `WebKitMacPlugin/WebKitUIAdapter.swift`; app supplies the recipients. |
| `WebPageViewEvents`, `WebPageMenus`, `WebContextMenu` | `WebKitPageView`, `WebKitMacPlugin/WebKitPageView.swift`; menu policy is app-owned. |
| `WebPageScripting`, `WebInjection`, `WebWorld` | `WebKitPageScripts`, `WebKitMacPlugin/WebKitPageScripts.swift`. |
| `WebMessageChannels`, `WebMessage`, `WebJSON`, `WebOrigin` | `WebKitMessageChannels`, `WebKitMacPlugin/WebKitMessageChannels.swift`. |
| `egluBridge` | `WebKitSupport/WebKitScriptBridge.swift` and `WebKitSupport/Scripts/eglu-bridge.js`. |
| Filter-script installation | `WebKitSupport/WebKitFilterScripts.swift`. |
| `WebTrait` | `WebKitMacPage.traits`, `WebKitMacPlugin/WebKitMacPage.swift`. |
| `WebFind`, `WebZoom`, `WebMediaCapture`, `WebUserAgent` | `WebKitPageServices`, `WebKitMacPlugin/WebKitPageServices.swift`. |
| `WebPrinting`, `WebDeveloperTools`, `WebDeveloperTool` | Same page-services implementation. |
| `WebBackForward`, `WebRestoration` | Same page-services implementation; native item and interaction state pass through. |
| `WebSwipe`, `WebPageCoordinates`, `WebPageEdge` | `WebKitPageInteraction`, `WebKitMacPlugin/WebKitPageInteraction.swift`. |
| `WebPicturePage`, `WebPicturePageEvents` | `WebKitPicturePage`, `WebKitMacPlugin/WebKitPicturePage.swift`. |
| `WebSnapshotOptions` | `WebKitMacPage.takeSnapshot`, `WebKitMacPlugin/WebKitMacPage.swift`. |
| `WebSpaceStores` | `WebKitSpaceStores` and `WebKitStores`, `WebKitSupport/WebKitStores.swift`. |
| `WebDownload`, `WebDownloadDelegate` | `WebKitDownload`, `WebKitSupport/WebKitDownload.swift`. |
| `WebDownloadStarting` | `WebKitPageServices` for pages; `WebKitDownloadStarter`, `WebKitSupport/WebKitDownloadStarter.swift`, for kept or retry sessions. |
| `WebHiddenPage` | `WebKitHiddenPage`, `WebKitSupport/WebKitHiddenPage.swift`. |
| `WebSVGRasterizer` | `WebKitSVGRaster`, `WebKitSupport/WebKitSVGRaster.swift`. |
| `WebRuleList`, `WebRuleListStore`, `WebRuleListTarget` | `WebKitRuleList`, `WebKitRuleListStore`, `WebKitRuleListTarget`, `WebKitSupport/WebKitContentRules.swift`. |
| `WebExtensionRuntime` | `WebKitExtensionRuntime`, `WebKitExtensions/WebKitExtensionRuntime.swift`, forwarding to its parts. |
| `ExtensionBrowserHost` translation | `ExtensionTabs`, `ExtensionTab`, `SpaceWindow` in `WebKitExtensions/ExtensionTabs.swift`; popup adapters in `ExtensionPopupWindow.swift` in the same directory. |
| `ExtensionPageConfiguration` | `WebKitExtensionPageConfiguration`, `WebKitExtensions/WebKitExtensionPageConfiguration.swift`. |
| `WebExtensionStorage` | `ExtensionStorage`, `WebKitExtensions/ExtensionStorage.swift`. |
| `WebExtensionMetadata` | `WebKitExtensionMetadata`, `WebKitExtensions/WebKitExtensionMetadata.swift`. |
| `WebExtensionCompatibility` | `WebKitExtensionCompatibility`, `WebKitExtensions/WebKitExtensionCompatibility.swift`; `ExtensionTable.swift` and `ExtensionTrial.swift` in the same directory. |
| `WebExtensionControllers` | `WebKitExtensionControllers`, `WebKitExtensions/WebKitExtensionControllers.swift`. |
| `WebExtensionWorkers` | `ExtensionWorkers`, `WebKitExtensions/ExtensionWorkers.swift`. |
| `WebExtensionEvidenceRuntime` | `WebKitExtensionEvidence`, `WebKitExtensions/WebKitExtensionEvidence.swift`. |
| `WebExtensionCleanup` | `WebKitExtensionCleanup`, `WebKitExtensions/WebKitExtensionCleanup.swift`; clearing page in `ExtensionBlankPage.swift` in the same directory. |
| `WebExtensionInstallExecution`, `WebExtensionInstallArchive` | `WebKitExtensionInstallExecution`, `WebKitExtensions/WebKitExtensionInstallExecution.swift`. |
| `WebExtensionRuntimeAnswers` | `WebKitExtensionRuntimeAnswers`, `WebKitExtensions/WebKitExtensionRuntimeAnswers.swift`; transports in `ExtensionNative.swift` and `ExtensionSocket.swift` in the same directory. |
| `WebExtensionScriptAnswers` | `WebKitExtensionScriptAnswers`, `WebKitExtensions/WebKitExtensionScriptAnswers.swift`. |
| `WebExtensionBrowserAnswers` | `WebKitExtensionBrowserAnswers`, `WebKitExtensions/WebKitExtensionBrowserAnswers.swift`. |
| `WebExtensionPermissions` | `WebKitExtensionPermissions`, `WebKitExtensions/WebKitExtensionPermissions.swift`. |
| `WebExtensionAdapters` | `WebKitExtensionAdapters`, `WebKitExtensions/WebKitExtensionAdapters.swift`. |
| `WebExtensionDiagnostics` | `WebKitExtensionDiagnostics`, `WebKitExtensions/WebKitExtensionDiagnostics.swift`. |
| `WebExtensionDispatch` | `WebKitExtensionRuntime` methods; controller callbacks in `WebKitExtensions/WebKitExtensionControllerDelegate.swift`; shim routing in `WebKitExtensions/WebKitExtensionDispatcher.swift`. |
| `WebExtensionAction`, `WebExtensionCommand` | `WebKitExtensionActions`, `WebKitExtensionCommands`, `WebKitExtensions/ExtensionAction.swift`; key application in `ExtensionKeys.swift` in the same directory. |
| `WebExtensionSurface`, `ExtensionPanePage`, `ExtensionPaneSource` | `ExtensionSurface`, `WebKitExtensions/ExtensionSurface.swift`; side-panel lookup in `ExtensionSidePanel.swift` in the same directory. |
| Auxiliary-page and capture host calls, `WebExtensionPageCapture` | `ExtensionCaptureRuntime`, `ExtensionPageDelegate`, `WebKitExtensions/ExtensionCapture.swift`; `ExtensionOffscreen.swift` and `WebKitMacPageFactory.swift` in the same directory. |
| Auth dispatch using host operations | `WebKitExtensionAuth`, `WebKitExtensions/ExtensionAuth.swift`. |
| `WebNativeConnection`, `WebExtensionNativeTransport` | `HostPipe` conformance and `WebKitExtensionNativeConnection`, `WebKitExtensions/WebKitExtensionNativeConnection.swift`; pipe in `ExtensionNative.swift` in the same directory. |
| `WebEngineSurface` for a product page | App-owned `Mac/Sources/PageWebKitSurface.swift`, outside the plugin; picture and extension surfaces implement it in the files above. |
| `ExtensionRuntimeHost` and its host parts | App-owned `Mac/Sources/ExtensionHost.swift` and `Mac/Sources/Extension*Host.swift`, not WebKit implementations. |

The other plugin kinds have no WebKit implementation:

| Contract | Implementation |
| --- | --- |
| `GrammarEngine`, `GrammarService` | `HarperGrammarEngine`, private `HarperGrammarService`, `EnginePlugins/Sources/HarperPlugin/HarperGrammarEngine.swift`. |
| `DocumentReader` | `EnginesDocumentReader`, `EnginePlugins/Sources/DocumentsPlugin/EnginesDocumentReader.swift`. |

## 8. Differences from the plan

The step records describe most signature changes from the sketches. Use the implemented names and behavior above when writing a plugin.

| Plan statement | Current code |
| --- | --- |
| Build fails on engine-boundary violations. | Done in step 13: the "Engine boundary" build phase runs `--strict`, which also checks that the web engine plugin's modules are imported only in `EngineComposition.swift`. |
| Step 12n says no file outside `EngineComposition.swift` imports a plugin module. | True for the web engine plugin's modules; `Mac/Sources/Plugins.swift` imports `HarperPlugin` and `DocumentsPlugin`, the composition point of those two plugin kinds. |
| Section 5 sketches `WebEnginePage`, `WebEngineMacPage`, optional services, frame/document/navigation IDs and async message handlers. | Implemented page is `WebMacPage`; services are required; frame metadata has no handles; navigation uses inline replies; message handlers use callbacks. |
| A child is accepted or rejected with methods on its request. | The app constructs a child synchronously through the factory and returns its surface, or nil. The request has no such methods. |
| Navigation and teardown cancel pending script replies; teardown is generally idempotent. | No generic pending-reply cancellation or idempotence requirement is stated in the current page/channel protocols. WebKit handles message lifetime. |
| Section 5.5 moves rule planning and conversion into the plugin and gives it list sources and policy. | The step 10 record explicitly retains PadCore conversion. Plugins receive WebKit-format encoded rules. |
| Every engine reports support and the interface hides missing features. | Only swipe has explicit trait gating. Other optional objects and nil results provide limited fallbacks; services and the extension runtime are required. |
| Section 1 requires a fake-engine Mac build and interface tests without WebKit. | Focused contract fakes exist, including the composed extension runtime. No complete replacement-engine app configuration is present. |
| Section 5.8 leaves out `ExtensionAnswers.swift` in a Chromium build. | The old WebKit switch moved to the plugin. The app file now forwards through contracts and still needs composition answers. |
| Section 5 sketches asynchronous document reading and a larger grammar service. | Documents are synchronous byte operations; grammar uses `GrammarEngine` plus four async service methods, with `context` for ignore. |

The plan's earlier counts, validation runs and behavior observations are historical evidence. They are not a promise that another engine already builds or that installed extensions
have been tested end to end through these contracts.
