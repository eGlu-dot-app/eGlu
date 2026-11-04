# Engine split: implementation plan (eGlu for Mac)

Status: planned on 4 November 2026 at commit 75fcca2, narrowed to the Mac app and validated the same day. Claude wrote the draft. Codex (gpt-6.1-sol) read the repository over two rounds, corrected the draft and sketched the contracts, then validated the Mac plan in two independent runs. Gemini researched what a Chromium engine would face and then checked that research against primary sources. Section 11 records the validation and what it changed. Steps 0 and 1 were built and committed on 4 November 2026 (cf0049e6, 7.3); steps 2 and 3 the same day (6f21a0fc, 7.4); step 4a the same day (8fca31ff, 7.5); step 4b the same day (0ad0afee, 7.6); step 4c the same day (2c3e5680, 7.7); step 4d the same day (52081355, 7.8); step 5 the same day (7.9); step 6 the same day (55ee7e38, 7.10); step 7a the same day (7.11). The decisions left open are in section 9.

**Scope:** eGlu for Mac only (`Mac/`, and the `Shared/` and PadCore code it compiles). The iPad and iPhone app is out of scope. It still compiles `Shared/` and PadCore, so it must keep building and behaving the same; it adopts nothing new (section 4).

## 1. Goal

eGlu for Mac talks to its engines only through contracts. Each engine is a plugin:

| Plugin | Engine | Where |
|---|---|---|
| WebKit plugin | WebKit (`WKWebView`), with eGlu's WebKit-specific tweaks | This repository, the default |
| Harper plugin | Harper grammar, through the `Engines` package | This repository |
| Documents plugin | anydoc and pdf-inspector, through the `Engines` package | This repository |
| Chromium plugin | Chromium, through CEF | Someone else's, later (section 8) |

Someone who wants a Chromium eGlu for Mac writes a Chromium plugin against the contracts and builds the Mac app with it instead of the WebKit plugin.

**Done means:**
- No file the Mac app compiles (`Mac/`, `Shared/`) imports WebKit or `Engines`. A check fails the build if one does.
- eGlu Mac and eGlu Mac Direct build and behave as before with the WebKit, Harper and Documents plugins.
- A build configuration of the Mac app that links a fake engine instead of the WebKit plugin builds and runs the interface's tests. This shows the contracts are complete without WebKit.
- `Docs/WebEngine.md` explains the contracts well enough that someone can write a plugin without reading the interface's code.
- The iPad and iPhone app still builds and passes its tests at every step.

**Not goals:**
- Anything for the iPad and iPhone app beyond keeping it building.
- Loading plugins while the app runs. The plugin is chosen when the app is built.
- Building a Chromium plugin. That is a separate project (section 8).
- Carrying sign-ins, history state or saved sessions from one engine to another.
- Making every engine do everything. Each plugin says what it supports, and the interface hides what is missing.

## 2. Words

Three names in the code already sound like "engine" or "adapter". New names must not clash with them.

| Word in this plan | Means | Not to confuse with |
|---|---|---|
| Web engine | What draws pages: WebKit today | PadCore's `Engine`, the search engines (`PadCore/Sources/PadCore/Engine.swift`) |
| `Engines` package | Harper and the document readers, in Rust (`Engines/`) | |
| Plugin | An implementation of the contracts | PadCore's `Adapters`, a site's own settings (`PadCore/Sources/PadCore/Adapters.swift`) |
| Contracts | The protocols and value types plugins implement, in new packages | |
| Interface | `Mac/` and the `Shared/` code the Mac compiles: windows, tabs, sidebar, settings, and the Mac's `Page` | |
| Engine state | What the engine itself reports (WebKit's `canGoBack`) | Product state, which `Page` adds rules to (going back past a replaced page) |

## 3. What the code has today

Counts are at commit 75fcca2, for the Mac app. Section 11 says how each was checked.

**Size and spread**

| Fact | Evidence |
|---|---|
| 36 files in `Mac/` and 9 in `Shared/` import WebKit. Both apps compile `Shared/` | `grep '^import WebKit'`; `project.yml:46`, `:49` |
| The Mac's extension files come to 9,348 lines, UI included. They are the largest WebKit-only part | `Mac/Sources/Extension*.swift` |
| The Mac's `Page` is 1,798 lines. `Shared/PageShared.swift` adds an `extension Page` that both apps' `Page` classes share | `Mac/Sources/Page.swift:139`, `Shared/PageShared.swift:158` |
| 86 lines in 18 files outside `Mac/Sources/Page.swift` name `page.view` (a `WKWebView`): `ApplePasswords.swift` 13, `WindowModel.swift` 11, `Popup.swift` 10, `Pages.swift` 8, `LittleWindow.swift` 8, `Peek.swift` 6, `PageShared.swift` 5, and 11 more. Local aliases (`let view = page.view`) add more that this count misses | `grep -E '\bpage\??\.view\b'` over `Mac/Sources` and `Shared` |
| `Engines` is imported by seven Mac files and three shared ones. `WritingChecker` builds Harper's `Grammar` itself and checks stale results by its identity; `HandoffDocumentSource` reads documents through it; About lists its licences | `Mac/Sources/{About,EgluApp,SettingsView,WindowModel}.swift`, `Mac/Sources/Writing/{WritingHandler,Panel/PopupPanel,Elsewhere/ElsewhereChecker}.swift`, `Shared/Writing/{WritingChecker,WritingLists}.swift`, `Shared/HandoffDocumentSource.swift`; `Shared/Writing/WritingChecker.swift:83`, `:102` |

**Seams that leak WebKit**

| Fact | Evidence |
|---|---|
| `PageHost`, the seam between a page and its window, passes `WKWebViewConfiguration`, `WKNavigationAction`, `WKWindowFeatures`, and a `WKWebView` back | `Mac/Sources/Page.swift:22` |
| Hosts put the web view itself into their windows and focus it | `Mac/Sources/Popup.swift:111`, `Mac/Sources/LittleWindow.swift:135` |
| "Go back past a replaced page" is decided in three callers, each reading WebKit's `canGoBack` and `Session.shared`. One more caller reads WebKit's `canGoBack` on purpose, for a different question | `WindowModel.swift:309`, `:579`; `ExtensionTabs.swift:287`; `PageSwipe.swift:211`, `:215`; `WindowModel.swift:445` |
| `Page.load(_ URL)` and `reload(byHand:)` do more than WebKit's calls: they reset navigation state, grant file access (`loadFileURL`), retry failures and reset crash counting. Three callers reload from origin on WebKit directly | `Mac/Sources/Page.swift:454`, `:624`, `:627`, `:634`; `Mac/Sources/DeveloperBar.swift:226`, `Mac/Sources/Menus.swift:365`, `Mac/Sources/WindowModel.swift:1148` |
| The navigation decision reads the mouse button and modifier keys (⌘-click to a new tab), the redirect's kind (a server's or an extension rule's, with the original address), the HTTP method and headers. It answers synchronously | `Mac/Sources/Page.swift:844`, `:569`, `:1472`, `:1545` |
| `Page` acts on WebKit's lifecycle: commit, finish, provisional and committed failures, the web process ending, and a script closing the window | `Mac/Sources/Page.swift:1618`, `:1645`, `:1666`, `:1688`, `:1733` |
| `Page` offers find, printing, writable zoom, device sizes with their user agent, JavaScript dialogs (one held for a background tab), file panels, and camera and microphone state (which keeps a page from freezing) | `Mac/Sources/Page.swift:854`, `:886`, `:892`, `:1122`, `:1737`, `:1770`, `:1783`, `:688`, `:1388` |
| WebKit's public `WKFrameInfo` has no frame or document identifier: only main frame or not, the request, the security origin and the web view | macOS 27.2 SDK, `WebKit.framework/Headers/WKFrameInfo.h:46` to `:58` |
| Private WebKit calls: `_pinnedState` and `_setRubberBandingEnabled:` for the swipe; `_isRedirect`, `_originalURL`, `_isContentExtensionRedirect`; picture in picture; developer extras; the inspector; display capture; the context menu's element and unused wheel events | `Mac/Sources/PageSwipe.swift`, `Mac/Sources/Page.swift:1448`, `:1468`, `Mac/Sources/ExtensionCapture.swift`, `Mac/Sources/ExtensionOffscreen.swift`, `Mac/Sources/WebInspector.swift` |

**Scripts and messages**

| Fact | Evidence |
|---|---|
| PadCore's sources import no WebKit (one test does), but its content-blocking rules use WebKit's rule format | `PadCore/Sources/PadCore/ContentBlocking.swift:3`; `PadCore/Tests/PadCoreTests/ContentBlockingTests.swift:4` |
| Page scripts reach WebKit directly: four of PadCore's (`bridge.js` is iPad only) and two written inline in Swift | `extension-store.js:22`, `measure.js:30`, `extension-shim.js:2807` (as `root.webkit`), `writing.js:272` in `PadCore/Sources/PadCore/Scripts/`; `Mac/Sources/PasswordWatch.swift:28`, `Mac/Sources/ApplePasswords.swift:171`; `Mac/Sources/Page.swift:133` |
| Each message handler checks more than where a message came from: the store button checks the store address and the extension clicked; Measure its run; Writing HandsOff and the writing setting; extension capture the extension's controller, space and context | `Mac/Sources/StoreButton.swift:27`, `Shared/Measure/MeasureHandler.swift:20`, `Mac/Sources/Writing/WritingHandler.swift:27`, `Mac/Sources/ExtensionCapture.swift:169` |
| `extension-shim.js` runs in several worlds: extension pages (where its capture call lives), content scripts and workers | `Mac/Sources/Extensions.swift:455`; `PadCore/Sources/PadCore/ExtensionPreparation.swift:458`, `:467`, `:533` |
| The iPad loads the same `writing.js` and `measure.js` | `App/Sources/Page.swift:525`, `:1108` |

**Code around the page**

| Fact | Evidence |
|---|---|
| History keeps WebKit's own back-forward items as identities | `Shared/HistoryRecorder.swift:505` |
| Each space has a persistent website data store, erased and cleaned up at start | `Shared/Stores.swift:20`, `:31`, `:50` |
| The Mac makes hidden web views of its own: transcript reading, SVG drawing (which site icons depend on), download retries, extension popups, offscreen documents, sign-in windows, trial checks, picture in picture; the recording indicator moves web views between windows | `Shared/PageShared.swift:38`, `Shared/SVGRaster.swift:85`, `Shared/SiteIcons.swift:269`, `Shared/DownloadActivity.swift:144`, `Mac/Sources/ExtensionPopup.swift:26`, `Mac/Sources/ExtensionOffscreen.swift`, `Mac/Sources/ExtensionAuth.swift:203`, `Mac/Sources/ExtensionTrial.swift`, `Mac/Sources/PictureWindow.swift:44`, `Mac/Sources/RecordingIndicator.swift:37` |
| Handoff downloads files through the page's own web view, so they carry its sign-in | `Shared/HandoffFetch.swift:15`, `Shared/HandoffDocumentSource.swift:32` |
| Apple Passwords checks the frame and world of each message and converts page coordinates to the screen using zoom and magnification | `Mac/Sources/ApplePasswords.swift:233`, `:551` |
| `ContentBlocker` reads the app's folders and preferences and tells live pages when lists change; `Session` starts it | `Shared/ContentBlocker.swift:110`, `:138`, `:378`; `Mac/Sources/Session.swift:163` |
| `Pages` makes concrete `Page`s and asks extensions for their configuration; `Unseen` and `PageBlocking` in `PageShared.swift` take the app's `Page` or read `Session.shared` | `Mac/Sources/Pages.swift:35`; `Shared/PageShared.swift:38`, `:230` |

**Rules, build and tests**

| Fact | Evidence |
|---|---|
| HandsOff guards scripts, reading a page and changing it. It does not guard navigation, find, printing or snapshots. Its tests check the source text, not every call | `Mac/Sources/Page.swift:854`, `:892`, `:928`, `PadCore/Tests/PadCoreTests/ScriptAndPolicyTests.swift:246` |
| A test bans four cookie API spellings in `App`, `Mac`, `Shared` and `PadCore/Sources`. New package folders would escape it | `ScriptAndPolicyTests.swift:223` |
| `Shared/` is compiled into each app, not built as a module. A plugin outside the repository cannot import anything declared there | `project.yml:49` |
| WebKit code reaches `Session.shared` directly | `Mac/Sources/ExtensionTabs.swift:57`, `Mac/Sources/Page.swift:408` |
| The app builds in Swift 5 language mode; the iOS app targets iOS 17 | `project.yml:18`, `:8` |
| The Mac has one test target, Site Icons Tests, which compiles `Shared/SiteIcons.swift` and `Shared/SVGRaster.swift`. The crash tests are iOS only. Nothing tests the Mac's `Page` against a real `WKWebView` | `project.yml:137`, `:142`; `Tests/Crashes/project.yml:11` |
| The Mac app ships only as a Developer ID DMG, outside the sandbox with the hardened runtime. Default signing has no team and asks for iCloud | `README.md:449`; `Config/Signing.xcconfig:17`, `Config/Mac.xcconfig:12` |

## 4. Layers and rules

| Layer | Holds | May import |
|---|---|---|
| Interface (`Mac/`, `Shared/`) | Windows, tab UI, sidebar, settings, the hosts, the Mac's `Page` | The contracts, PadCore, AppKit and SwiftUI. Not WebKit, not `Engines` |
| Core (PadCore) | Logic, HandsOff and other policies, filter lists, page scripts | Foundation |
| Contracts (new packages) | Foundation-only value types and protocols, plus an AppKit target for the page's view | Foundation, AppKit |
| Plugins | WebKit, Harper and Documents plugins in this repository; a Chromium plugin elsewhere | The contracts and their own engine |

**Rules:**
- The interface never imports WebKit or `Engines`. A check reports this from phase 0 and fails the build at the end.
- Plugins never reach `Session.shared` or other app globals. The interface hands them what they need. A package can never import from `Shared/` or either app.
- HandsOff is decided in PadCore and the interface, before a plugin is called, for every operation it covers today. The contracts' documentation lists which operations those are.
- Two contracts, not one. Hosts talk to the product `Page`. `Page` talks to the smaller engine page. The engine page reports engine state; `Page` adds product rules (going back past a replaced page, retries, crash counting). Product features (Peek, Handoff, Writing, Measure) are built from engine operations, not added to the contract.
- A rule that several callers repeat moves into `Page` once, so a plugin never has to know it.
- Each contract is written together with its WebKit implementation, its fake and its tests, one feature at a time. No contract is declared ahead of the code that uses it.
- Every step changes no behaviour, keeps both Mac schemes building, and passes the tests.

**The iPad and iPhone app while this happens:**
- It keeps calling WebKit itself. It does not adopt the contracts.
- Shared WebKit helpers move into a WebKit package target that builds for both macOS 26 and iOS 17 (`WebKitSupport`). The Mac's AppKit and extension code goes into a Mac-only target (`WebKitMacPlugin`). The iOS app depends only on `WebKitSupport`, and calls its types directly, as it calls WebKit now. Nothing is copied.
- What in `Shared/` needs the app itself (`Page`, `Session.shared`) cannot move into a package. `PageShared.swift`'s `extension Page`, `Unseen` and `PageBlocking` stay in each app; only helpers that take a view, a store or a policy value move out.
- When a shared script changes its transport (`writing.js`, `measure.js`), the iOS `Page` installs a small `egluBridge` that maps to its existing handlers, so the iPad behaves as before.
- When a shared contract replaces something both apps use (Harper through `WritingChecker`, documents through `HandoffDocumentSource`, rasterizing through `SiteIcons`), the iOS callers get the smallest change that keeps them building: `App/Sources/{AppDelegate,LicencesView,SettingsView,WritingHandler}.swift`.

## 5. The contracts

Sketches, signatures only. Exported declarations would be `public`, with explicit `public init`s, since Swift does not export synthesized initializers. The packages build in Swift 6 language mode whatever the app's mode. All four sketches type-check with Swift 6.4.2, and a throwaway WebKit-backed page implements the page and view contracts, all five services included, with no errors or warnings (section 11). Each piece is finished in the step that uses it (section 7), so these signatures will change as they meet the code.

### 5.1 Packages

Packages appear only when their phase begins.

| Package | Targets | Holds |
|---|---|---|
| `WebEngineKit` | `WebEngineCore` (Foundation), `WebEngineAppKit` (AppKit) | The page contract (5.2) and the view contract (5.3) |
| `WebKitEngine` | `WebKitSupport` (macOS 26 and iOS 17), `WebKitMacPlugin` (macOS) | Shared WebKit helpers; the Mac's WebKit page, `PageView`, private calls, rule compiling, the extension runtime |
| `WritingServiceKit` | one | The grammar contract (5.6) |
| `DocumentServiceKit` | one | The documents contract (5.7) |
| `HarperPlugin`, `DocumentsPlugin` | one each | The `Engines` implementations, owning `Engines`' types and thread |

### 5.2 The page contract

```swift
import Foundation

/// What the engine reports. Product rules (going back past a replaced
/// page) are Page's, not the engine's.
struct PageState: Sendable, Equatable {
    let url: URL?
    let title: String?
    let isLoading: Bool
    let estimatedProgress: Double
    let canGoBack: Bool
    let canGoForward: Bool
    let hasOnlySecureContent: Bool
}
enum WebReload: Sendable { case normal, origin }
@MainActor protocol WebNavigationCommands: AnyObject {
    var state: PageState { get }
    func load(_ request: URLRequest)
    func loadFile(_ url: URL, readAccess: URL)
    func reload(_ mode: WebReload)
    func stop()
    func back()
    func forward()
}

indirect enum WebJSON: Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([WebJSON]), object([String: WebJSON])
}
enum WebWorld: Sendable { case app, page }
enum WebOrigin: Sendable, Equatable {
    case tuple(scheme: String, host: String, port: Int)
    case opaque
}
/// Made by the plugin. WebKit has no frame or document identifiers, so the
/// WebKit plugin numbers main-frame documents by commits and keeps the
/// WKFrameInfo behind each handle. Until a plugin can tell when a
/// subframe's document changes, evaluate accepts main-frame handles only.
struct WebFrameHandle: Sendable, Hashable { let raw: UInt64 }
struct WebDocumentID: Sendable, Hashable { let raw: UInt64 }
struct WebFrame: Sendable {
    let handle: WebFrameHandle
    let document: WebDocumentID
    let isMainFrame: Bool
    let origin: WebOrigin
}

enum WebInjection: Sendable { case documentStart, documentEnd }
struct WebScript: Sendable {
    let id: String
    let source: String
    let world: WebWorld
    let injection: WebInjection
    let mainFrameOnly: Bool
}
struct WebMessage: Sendable {
    let channel: String
    let frame: WebFrame
    let world: WebWorld
    let body: WebJSON
}
typealias WebMessageHandler =
    @MainActor @Sendable (WebMessage) async throws -> WebJSON

struct WebNavigationID: Sendable, Hashable { let raw: UInt64 }
enum WebNavigationKind: Sendable {
    case link, form, formResubmission, history, reload, other
}
struct WebModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let command = WebModifiers(rawValue: 1)
    static let shift = WebModifiers(rawValue: 2)
    static let option = WebModifiers(rawValue: 4)
    static let control = WebModifiers(rawValue: 8)
}
enum WebMouseButton: Sendable { case primary, middle, secondary }
enum WebRedirect: Sendable {
    case server
    case contentRule(original: URL?)
}
struct WebNavigation: Sendable {
    let id: WebNavigationID
    let request: URLRequest
    let source: WebFrame?
    let targetIsMainFrame: Bool
    let kind: WebNavigationKind
    let modifiers: WebModifiers
    let button: WebMouseButton?
    let redirect: WebRedirect?
    let requestsDownload: Bool
}
struct WebResponse: Sendable {
    let navigation: WebNavigationID?
    let url: URL
    let status: Int?
    let mimeType: String?
    let headers: [String: String]
    let isMainFrame: Bool
    let canDisplay: Bool
}
struct WebLoadError: Error, Sendable {
    enum Kind: Sendable { case cancelled, network, security, blocked, interrupted, other }
    let kind: Kind
    let domain: String
    let code: Int
    let url: URL?
    let message: String
}
enum WebNavigationDecision: Sendable {
    case allow, cancel, download, openExternal(URL)
}
enum WebResponseDecision: Sendable { case allow, cancel, download }

@MainActor protocol WebPageEvents: AnyObject {
    func stateChanged(_ state: PageState)
    /// Answered at once; it cannot wait for the person.
    func decideNavigation(_ navigation: WebNavigation) -> WebNavigationDecision
    func decideResponse(_ response: WebResponse) -> WebResponseDecision
    /// Where a load started from, and each server redirect: Page keeps
    /// the address it was loading from (`loadingFrom`, Page.swift:1610).
    func started(_ navigation: WebNavigationID?, from url: URL?)
    func redirected(_ navigation: WebNavigationID?, from url: URL?)
    func committed(_ navigation: WebNavigationID?, document: WebDocumentID)
    func finished(_ navigation: WebNavigationID?)
    func failed(_ navigation: WebNavigationID?, error: WebLoadError, provisional: Bool)
    func processEnded()
    func closeRequested()
    /// The host accepts or rejects before this returns: WebKit needs the
    /// child's view back from the same call.
    func requestedChild(_ request: any WebChildRequest)
    /// A navigation became a download. The host takes it over and it
    /// outlives the page (Downloads.shared.adopt, Page.swift:1605).
    func downloadStarted(_ download: any WebDownload)
}
@MainActor protocol WebDownload: AnyObject {
    var originalURL: URL? { get }
    func cancel() async -> Data?
}
@MainActor protocol WebChildRequest: AnyObject {
    var navigation: WebNavigation { get }
    var requestedWidth: Double? { get }
    var requestedHeight: Double? { get }
    func accept() throws -> any WebEnginePage
    func reject()
}

/// Traits a plugin has or lacks. Things the host calls are services below.
enum WebTrait: Sendable, Hashable {
    case isolatedScripts, correlatedUnusedWheelEvents, rubberBandControl
    case documentPictureInPicture, videoPictureInPicture
}
@MainActor protocol WebFind: AnyObject {
    func find(_ text: String, backwards: Bool, caseSensitive: Bool) async -> Bool
}
@MainActor protocol WebZoom: AnyObject {
    var pageZoom: Double { get set }
    var magnification: Double { get }
}
@MainActor protocol WebDialogs: AnyObject {
    var presenter: (any WebDialogPresenter)? { get set }
}
@MainActor protocol WebDialogPresenter: AnyObject {
    func alert(_ message: String, from frame: WebFrame) async
    func confirm(_ message: String, from frame: WebFrame) async -> Bool
    func prompt(_ message: String, default text: String?, from frame: WebFrame) async -> String?
    func openFiles(multiple: Bool, directories: Bool) async -> [URL]?
}
@MainActor protocol WebMediaCapture: AnyObject {
    var isCapturing: Bool { get }
}
@MainActor protocol WebUserAgent: AnyObject {
    var custom: String? { get set }
}

@MainActor protocol WebEnginePage: WebNavigationCommands {
    var traits: Set<WebTrait> { get }
    var events: (any WebPageEvents)? { get set }
    func replaceScripts(_ scripts: [WebScript]) throws
    func evaluate(_ body: String, arguments: [String: WebJSON],
                  world: WebWorld, frame: WebFrame?) async throws -> WebJSON
    func register(channel: String, world: WebWorld,
                  handler: @escaping WebMessageHandler) throws -> UUID
    func unregister(_ registration: UUID)
    func download(_ url: URL, into folder: URL) async throws -> URL
    var find: (any WebFind)? { get }
    var zoom: (any WebZoom)? { get }
    var dialogs: (any WebDialogs)? { get }
    var mediaCapture: (any WebMediaCapture)? { get }
    var userAgent: (any WebUserAgent)? { get }
    func tearDown()
}
```

How it behaves:
- `replaceScripts` applies to the next documents. `evaluate` runs in the main-frame document the handle belongs to, or fails if that document has gone. Handlers keep their own origin checks (`Mac/Sources/ApplePasswords.swift:237`).
- `decideNavigation` and `decideResponse` answer synchronously, as WebKit's delegate already does in eGlu (`Mac/Sources/Page.swift:1472`, `:1563`) and as CEF's navigation callback does. A decision that needs the person (another app's link) cancels first and asks afterwards, as today.
- A child request is accepted or rejected inside `requestedChild`. The WebKit plugin keeps the accepted child and returns its view from `createWebViewWith` (`Mac/Sources/Page.swift:1692`), which keeps the opener tie. A request not answered by then is rejected.
- `download` fetches with the page's own session (Handoff, download retries).
- Public WebKit does not say whether a navigation is a redirect, or an extension rule's. The WebKit plugin fills `redirect` with the private calls `Mac/Sources/Page.swift:569` makes today.
- `tearDown` can be called more than once. It cancels what the page still owns: pending replies, `download` fetches, and an open dialog, which gets its cancel answer. A download already handed over through `downloadStarted` is the host's and keeps going. A dialog held for a background tab (`Mac/Sources/Page.swift:1770`) stays the host's to hold.
- A plugin that cannot keep the app's scripts in their own world leaves out `.isolatedScripts` and refuses `.app` scripts. It never runs them in the page's world instead.
- Still to design in their phases: printing, the context menu's element, developer tools, picture in picture, history entry identities, restoration data, snapshots.

### 5.3 The page's view

Hosts place, size, move and focus the engine's own `NSView` through `Page.surface`; no caller needs `acceptsFirstMouse` yet.

```swift
import AppKit

@MainActor protocol WebEngineSurface: AnyObject {
    /// The engine's own view, which the host places, sizes and moves
    /// between windows. Key events, the responder chain, appearance and
    /// data detectors stay the view's.
    var view: NSView { get }
    func focus()
}

/// What the Mac's plugin hands the host: a page and its view together.
/// A child accepted through WebChildRequest is one too.
@MainActor protocol WebEngineMacPage: WebEnginePage, WebEngineSurface {}
```

### 5.4 Page scripts and messages

The scripts that reach WebKit directly move to one shim, `globalThis.egluBridge`, which each plugin installs before the feature scripts, in each world and frame it is allowed in:
- PadCore's `extension-store.js:22`, `measure.js:30`, `writing.js:272`.
- The two inline scripts, `PasswordWatch.swift:28` and `ApplePasswords.swift:171`.
- In `extension-shim.js`, only its capture branch (`:2807`). The rest of the shim is the WebKit extension runtime, which a Chromium build leaves out (5.8).
- `bridge.js` (iPad only) keeps calling WebKit.

```typescript
interface EgluBridge {
  readonly version: 1;
  post(channel: string, body: JsonValue): void;
  request(channel: string, body: JsonValue): Promise<JsonValue>;
}
```

- The WebKit plugin maps each channel to a script message handler. A Chromium plugin wraps `cefQuery`'s callbacks in promises.
- Frame, document, world and origin come from the plugin's own record of where the script runs, never from the message's JSON. In CEF that needs renderer-process code or the DevTools Protocol: its message router alone does not prove which world a message came from.
- Each Swift handler keeps the checks it makes today (section 3): the bridge only adds where the message came from.
- Extension capture's authority (the extension's controller, space and context) stays inside the WebKit plugin. The generic message carries none of it.
- Navigation, a world going away, unregistering and teardown cancel pending replies.

### 5.5 Content blocking

First, split rule compiling from the app's own work: `ContentBlocker` today also reads the app's folders and preferences and updates live pages. Then the plugin gets the filter-list sources (fixed revisions) and the policy: which lists are on, which sites are excluded, and HandsOff.

| Code today | Goes to |
|---|---|
| `FilterLists.swift`: the catalogue, attributions, defaults | PadCore |
| `ScriptedFilters.swift`: procedural filters and domain matching | PadCore, for any plugin to use |
| `BlockingRule`, `ContentBlocking.json` (`ContentBlocking.swift:260`), `RulePlanner` | WebKit plugin (`WebKitSupport`) |
| `FilterConverter` (`ContentBlocking.swift:550`, not a file of its own) | WebKit plugin first; its parsing can be pulled out for other plugins later |
| `Shared/ContentBlocker.swift`'s compiling | `WebKitSupport`; its folders, preferences and page updates stay in the app |

### 5.6 The grammar contract

```swift
struct WritingConfiguration: Sendable {
    let dialectID: String?
    let rules: [String: Bool]
    let words: [String]
}
struct WritingRule: Sendable {
    let id: String
    let label: String
    let description: String
    let group: String
    let isOnByDefault: Bool
}
enum WritingSuggestion: Sendable {
    case replace(String), insert(String), remove
}
struct WritingIssue: Sendable {
    var start: Int
    var end: Int
    let rule: String
    let kind: String
    let message: String
    let priority: Int
    let suggestions: [WritingSuggestion]
    let ignoreToken: String
}
/// A class or an actor, so WritingChecker can still drop answers from a
/// service it has since replaced (`WritingChecker.swift:83`).
protocol GrammarService: AnyObject, Sendable {
    nonisolated var providerID: String { get }
    func isAvailable() async -> Bool
    func rules() async throws -> [WritingRule]
    func configure(_ configuration: WritingConfiguration) async throws
    func warmUp() async throws
    func lint(_ text: String) async throws -> [WritingIssue]
    func ignore(token: String) async throws
    func shutDown() async
}
```

- Ranges stay in UTF-16, and Harper's rule keys stay as they are (`Engines/Sources/Engines/Grammar.swift:28`). Changes are applied in the order they were made, as today.
- Language filtering and the check for stale results stay in `WritingChecker` and its callers (`ElsewhereChecker.swift:285`).
- Mac files that change: `Shared/Writing/WritingChecker.swift`, `Shared/Writing/WritingLists.swift`, `Mac/Sources/Writing/WritingHandler.swift`, `Mac/Sources/Writing/Elsewhere/ElsewhereChecker.swift`, `Mac/Sources/Writing/Panel/PopupPanel.swift`, `Mac/Sources/SettingsView.swift`, `Mac/Sources/EgluApp.swift`, `Mac/Sources/WindowModel.swift`. About's licence list comes from the plugins (`Mac/Sources/About.swift`).

### 5.7 The documents contract

Converting works on bytes only; fetching a file with the page's sign-in is the page's `download` (5.2).

```swift
import Foundation

/// The same kinds as Engines' DocumentFormat (Documents.swift:6).
enum DocumentKind: String, Sendable {
    case doc, docx, odt, pdf, ppt, pptx, rtf, epub, excel, ods, odp, csv
}
struct DocumentPage: Sendable {
    /// 0-based, as Engines' pages are.
    let page: Int
    let markdown: String
    let needsOCR: Bool
    let reason: String?
}
/// What Handoff shows of a PDF besides its pages
/// (HandoffDocumentSource.swift:376 to :380).
struct DocumentPages: Sendable {
    let pageCount: Int
    let title: String?
    let author: String?
    let created: String?
    let pages: [DocumentPage]
    let withTables: [Int]
    let withColumns: [Int]
}
protocol DocumentReader: Sendable {
    func detect(_ bytes: Data) async throws -> DocumentKind?
    func markdown(_ bytes: Data, kind: DocumentKind?) async throws -> String
    func pdfPages(_ bytes: Data, pages: [Int]?) async throws -> DocumentPages
}
```

It follows `Engines/Sources/Engines/Documents.swift:5` to `:27`, `:35`, `:48` and `:66`.

### 5.8 Extensions

Two contracts, one in each direction:
- `WebExtensionRuntime`, owned by the plugin: installing, running, and the runtime's state.
- `ExtensionBrowserHost`, owned by the app: what an extension does to spaces, windows and tabs, and the permission prompts. CEF knows nothing of eGlu's "one extension window per space" (`Mac/Sources/ExtensionTabs.swift:6`), so the plugin asks the host.

A Chromium build leaves out `extension-shim.js` and `ExtensionAnswers.swift`, which exist to make WebKit behave like Chrome, and adds back only what eGlu itself needs.

## 6. The hard parts, ranked

| # | Part | Why it is hard | Approach |
|---|---|---|---|
| 1 | Extensions | 9,348 lines that depend on per-space controllers, tab and window mapping, permission grants, worker shims, custom schemes, capture and hidden views. Chromium runs Chrome extensions itself | Split into a plugin-owned runtime and an app-owned browser host (5.8), last |
| 2 | Everything a page does besides navigating | Find, printing, zoom and magnification, dialogs, file panels, capture state, user agents, the context menu, developer tools, picture in picture. Capability flags cannot be called | Optional services on the engine page (5.2), each one when its feature moves |
| 3 | Opener tie and document picture in picture | WebKit needs a child page made with the configuration it hands over, inside the same call | Synchronous acceptance (5.2) |
| 4 | Script isolation and trust | Scripts run at document start, in a world the page cannot see; handlers check frame, world and more. WebKit has no frame or document identifiers; CEF has no app-side isolated-world call | Plugin-made handles and document numbers (5.2); each handler keeps its checks (5.4) |
| 5 | Storage, history and restoration | Per-space stores, deferred deletion, WebKit's back-forward items as history identities, WebKit's own restoration data | Restoration data tagged with the engine and a format version; history identities through the plugin. Switching engines does not promise to keep sessions |
| 6 | Content blocking | PadCore's rules are WebKit's format; `ContentBlocker` mixes compiling with the app's work. CEF blocks per request | Split compiling from the app (5.5), then hand plugins sources and policy |
| 7 | Swipe | The swipe needs unused-wheel acknowledgements and rubber-band control, which only private WebKit calls give | A trait a plugin may lack; a Chromium build can use Chromium's own swipe |

## 7. Phases

Each step is one or more pull requests, and none changes behaviour. Each feature's contract is written with its WebKit implementation, its fake and its tests together. Only one change at a time touches `Mac/Sources/Page.swift`, `Shared/PageShared.swift` and `project.yml`.

| Step | What | Needs | Ends with |
|---|---|---|---|
| 0. Inventory | A script that lists, for the Mac app's sources, tests and scripts (Swift string scripts included): WebKit and `Engines` imports, `page.view` reach-ins and their aliases, WebKit types in signatures, private selectors, hidden web views, and `webkit.messageHandlers`. The import check, reporting only. The cookie test widened to the new package folders | | The inventory checked in; the checks running |
| 1. Page state and navigation | The first pull request (7.1) | 0 | Mac hosts read state and navigate through `Page` |
| 2. Pages made through a factory | Every one of the eight places that makes a page asks one factory, `MacPageEngine`, which `Session` owns and `Pages` is given; the factory also sweeps the stores and starts content blocking and extensions at launch, in the same order as today. `PageState` moves into `WebEngineKit` (`WebEngineCore`); building the WebKit configuration moves into `WebKitEngine` (`WebKitMacPlugin`). The factory stays in the app for now: it makes the app's `Page` | 1 | Tests with a spy factory show `Pages` makes every tab's page through it. The hosts that make pages of their own (little windows, Peek, pop-ups, extension pop-ups, extension sign-in) ask `Session.shared.engine`, which the tests check is the app's factory. The factory still returns real WebKit pages: a fake engine cannot make a `Page` until step 4 moves WebKit out of it. (The whole app built with the fake comes at step 13) |
| 3. The view | 5.3 in `WebEngineKit` (`WebEngineAppKit`); `Page.surface`, an adapter around its own `PageView`, so hosts place, size, move and focus `surface.view` instead of `page.view`. Apple Passwords' coordinates, the recording indicator, the inspector and child-page returns stay on WebKit until their steps | 2 | No host reaches into `page.view` to show or focus it |
| 4. Navigation lifecycle and policy | In four slices, each its own pull request: 4a, the decision on a navigation (`WebNavigation`, `WebNavigationPolicy` with a synchronous reply, `WebKitNavigationAdapter` in `WebKitMacPlugin` as the web view's navigation delegate, passing every callback it does not handle on to `Page`); 4b, the decision on a response; 4c, start, redirect, commit, finish, failures and the process ending; 4d, file loads and removing what the adapter still passes on. `PageHost` already has WebKit types only in child creation | 2 | Navigation policy and lifecycle in `WebKitMacPlugin`; child creation, dialogs and the context menu stay for steps 5 and 7 |
| 5. Child pages | Synchronous acceptance; Peek, little windows, pop-ups, document PiP | 3, 4 | `PageHost.page(_:open:for:features:)` gone, and with it `PageHost`'s last WebKit types |
| 6. Scripts and messages | `egluBridge` (5.4), with the iOS adapter; Writing, Measure, Store, Passwords handlers on channels | 4 | No Mac script calls `webkit.messageHandlers` but the extension runtime's |
| 7. Page services | Find, zoom, dialogs and file panels, capture state, user agent, then printing, context menu, developer tools | 3, 4 | The developer bar and menus use services |
| 8. Storage, history, restoration | Per-space stores; history identities; restoration data | 4 | `HistoryRecorder` and `Stores` free of WebKit types |
| 9. Hidden pages and downloads | Transcript reader, SVG rasterizing (with `SiteIcons` and Site Icons Tests moved to an injected rasterizer), download retries, Handoff fetches, the recording indicator | 3, 4, 8 | No hidden `WKWebView` made outside the plugin, except the extension runtime's (offscreen documents, sign-in windows, trials), which move in step 12 |
| 10. Content blocking | 5.5 | 4 | `ContentBlocker`'s compiling in `WebKitSupport` |
| 11. Writing and documents | 5.6 and 5.7 | 6 | The Mac interface no longer imports `Engines` |
| 12. Extensions and private calls | 5.8; the swipe, inspector and PiP calls behind traits; `Session.shared` handed in | 3 to 10 | No WebKit left in the Mac interface |
| 13. Enforce and document | The import check fails the build; the Mac app built with the fake engine runs the interface's tests; `Docs/WebEngine.md` | 11, 12 | Section 1's "done" |

Steps 10 and 11 can run beside steps 5 to 9, since they touch other files.

**A gate outside the plan:** before anyone promises a Chromium plugin, a CEF spike must show what Alloy style's extension support covers, and whether an Alloy-style CEF view behaves inside eGlu's windows (section 8). It can happen at any time after step 3.

**Every step runs:** PadCore's tests (`swift test` in `PadCore/`), the page-script tests (`Tests/*.mjs`), the Site Icons tests, the Mac page tests (7.1), and builds of eGlu Mac and eGlu Mac Direct. The iOS app (scheme eGlu) is also built and its crash tests run, because it compiles the same `Shared/` and PadCore. A step that changes how pages behave is also tried on apple.com, naver.com, channel.io, news.ycombinator.com and DuckDuckGo. The fake shows the contracts can be used; it does not show that opener ties or isolation work, which only the WebKit plugin's tests can.

### 7.1 The first pull request

The first pull request touches no `Shared/` file and no iOS file (`project.yml:79`: the iOS app compiles `App/` and `Shared/` only).

**Adds:**
- In `Mac/Sources/Page.swift`, without a new package yet: a `state` snapshot of WebKit's own values, and commands that pass straight to WebKit (`back`, `forward`, `stop`, `reload(.normal)` and `reload(.origin)`).
- On `Page`, product state on top: `canGoBack` that includes going back past a replaced page, and `goBack()` that does what `Mac/Sources/WindowModel.swift:579` does today: only when WebKit cannot go back does it try the replacement, and otherwise it goes back in WebKit. (`Session.wentBackPastReplacement` does not check that itself, `Mac/Sources/Session.swift:389`.) The callers' copies of that rule go.
- A Mac test target hosted in eGlu Mac (7.2).

**Changes:**
- `Mac/Sources/WindowModel.swift:302` (`refresh`): title, loading, progress, history and secure content come from `state` and `Page`. Zoom stays as it is until step 7. The display-address fallback, failure and status stay.
- `Mac/Sources/WindowModel.swift:578` to `:596`: back, forward and stop call `Page`.
- `Mac/Sources/LittleWindow.swift:120` to `:271`, `Mac/Sources/Peek.swift:73` to `:99`, `Mac/Sources/Popup.swift:134` to `:173`: state reads and navigation call `Page`.
- `Mac/Sources/DeveloperBar.swift:226`, `Mac/Sources/Menus.swift:365`, `Mac/Sources/WindowModel.swift:1148`: reload from origin calls `Page`'s raw `reload(.origin)`, not the product's `reload(byHand:)`, which does more.
- `project.yml` and the generated `eGlu.xcodeproj`: the test target and its scheme.

**Proves no change:**
- `state` against WebKit's own properties, field by field.
- Product `canGoBack` and `goBack()` against the old callers' rule, including a restored replacement being used up, and a replaced tab that later has WebKit history of its own (it must go back in WebKit, not use the replacement). The transient hosts (little windows, Peek, pop-ups) get fresh tab identities that are never replaced (`Mac/Sources/LittleWindow.swift:59`, `Mac/Sources/Peek.swift:44`, `Mac/Sources/Popup.swift:33`), so for them the rule answers no and changes nothing; a test keeps it so.
- The windows still hear of changes from the same KVO observations (`Mac/Sources/Page.swift:372` to `:385`) and the zoom notice (`:889`); a computed `state` adds no timing of its own.

**Leaves alone:** `Page.load(_ URL)` and `reload(byHand:)`; URL reads elsewhere (`BrowserView`, `Pages`, `ApplePasswords`, `StoreButton`, the extension files), which move with their steps; `WindowModel.swift:445`, which asks WebKit's own question on purpose; the swipe and the extension tabs.

### 7.2 Mac page tests

- A macOS test target depending on eGlu Mac, with `TEST_HOST = $(BUILT_PRODUCTS_DIR)/eGlu.app/Contents/MacOS/eGlu`, `BUNDLE_LOADER = $(TEST_HOST)` and `@testable import eGluMac` (`project.yml:62`). Debug builds are testable.
- A local test configuration: ad-hoc signing, the local entitlements (no iCloud), and the hardened runtime off for the test host, applied to the embedded Dock tile too.
- `EGLU_DATA_ROOT` set before launch, so the app's workspace, sync and migration stay out of the way (`Mac/Sources/Session.swift:58`, `:65`, `Mac/Sources/LeavingTheSandbox.swift:18`).
- That is not enough on its own: start-up still reads the standard preferences, sweeps the persistent website stores and prunes snapshots (`Mac/Sources/Session.swift:88`, `:159`, `:161`; `Shared/Stores.swift:35`). The test host therefore gets a bundle identifier of its own (so its preferences, website data and caches are its own) and a launch argument that skips start-up services.
- `Session.shared` keeps state between tests (the replaced tabs, `Mac/Sources/Session.swift:379`). Tests reset it through a test-only hook and wait for start-up to finish before they begin.
- Tests make a `Page` with a non-persistent configuration (`Mac/Sources/Page.swift:301`) and wait for navigations asynchronously.

### 7.3 What was built (4 November 2026)

Steps 0 and 1, committed as cf0049e6. Built by subagents and checked by Claude: Gemini wrote step 0, Codex wrote step 1's code, a Claude subagent wrote the test target; Codex (`/codex review`, twice) and Gemini reviewed the whole diff.

| Step | Files | Result |
|---|---|---|
| 0 | `Tests/engine-inventory.py` (`--check` reports, `--strict` fails on WebKit or `Engines` in `Mac/` or `Shared/`, `--write` writes `Docs/EngineInventory.md`), `Tests/test_engine_inventory.py` (12 tests), the cookie test widened to the new package folders | All pass. Reach-ins into `page.view` in app code, by the final script: 107 lines in 18 files at 75fcca2, 69 in 17 after step 1 |
| 1, code | `Mac/Sources/Page.swift`: `PageState`, `state`, `canGoBack`, `goBack()`, `goForward()`, `stopLoading()`, `reloadFromOrigin()`. Callers moved in `WindowModel.swift`, `LittleWindow.swift`, `Peek.swift`, `Popup.swift`, `DeveloperBar.swift`, `Menus.swift` | eGlu Mac, eGlu Mac Direct and eGlu (iOS) build; no new warnings |
| 1, tests | Target and scheme "eGlu Mac Page Tests" (`Tests/MacPage/`), a "Test" build configuration in `project.yml`, DEBUG-only start-up changes in `Mac/Sources/EgluApp.swift` and `Mac/Sources/Session.swift` | 19 tests pass against a real `WKWebView`. The real data folder's 1,113 entries were identical before and after each run |

Where the build differs from 7.1 and 7.2:
- The raw commands are named after WebKit's (`goForward()`, `stopLoading()`, `reloadFromOrigin()`), not `forward()`, `stop()` and `reload(.origin)`, so they never read as the product's `reload(byHand:)`.
- `Page.canGoBack` exists but nothing calls it yet: `WindowModel.refresh()` keeps its record-based expression, word for word, and the swipe and extension tabs keep theirs until their steps.
- The test host's own bundle identifier needs a build configuration ("Test"), since a scheme cannot set one. Every target gets that configuration; Debug and Release are unchanged. XcodeGen drops the IDE-only `ProvisioningStyle` attribute for eGlu Mac and the Dock tile, whose `CODE_SIGN_STYLE` settings are unchanged.
- Tests are detected by XCTest's own `XCTestConfigurationFilePath`, not a launch argument; `StartUpTests` fails if XCTest stops setting it. Under tests the app skips its start-up services and its first window, and refuses to run unless `EGLU_DATA_ROOT` is set and its identifier ends in `.pagetests`.
- The replacement tests use `Session.replacePage`, which makes a page with the space's lasting store under the test identifier's `~/Library/WebKit` folder. Each run's leftovers there are removed after it.

Known gaps: the inventory misses WebKit types on the continuation lines of multi-line signatures, and its comment and string stripping has edge cases (raw strings, `//` inside JavaScript strings). Separately, and older than this work: an `EGLU_DATA_ROOT` exported in the shell that runs `xcodebuild` is written into any build's `Info.plist` (`Mac/Info.plist:5`), so a normal build made that way would use that folder.

### 7.4 Steps 2 and 3 (4 November 2026)

Built on top of cf0049e6, not yet committed. Codex wrote both steps' code, each in a worktree of its own (`codex exec`, allowed to write only there); a Claude subagent wrote step 2's hosted tests; Claude wrote step 3's, merged the work, ran every check and read every diff; `/codex review` and Gemini reviewed the whole of it.

| Step | What | Result |
|---|---|---|
| 2 | `Mac/Sources/MacPageEngine.swift` (`MacPageSource`, `MacPageEngine`, `AppWebKitEngine`), owned by `Session` and given to `Pages`; the eight places that made a `Page`, and `ExtensionAuth`'s configuration, ask it; `Page.init` takes its configuration; `Session.startWorkspaceServices` calls it for the stores, content blocking and extensions, in the same order. New packages: `WebEngineKit` (`WebEngineCore`: `PageState`) and `WebKitEngine` (`WebKitMacPlugin`: `WebKitConfiguration.make`, with the private-call guards) | 7 hosted tests (`PageEngineTests`); 3 package tests |
| 3 | `WebEngineKit` gains `WebEngineAppKit` (`WebEngineSurface`: `view`, `focus()`); `Page.surface` (`PageWebKitSurface`) is the page's own `PageView`; the window, pop-ups, little windows, Peek (through `PageSurface`), Apple Passwords and the window's split-view clicks place, constrain, check and focus `surface.view`, with the same windows and timing | 5 hosted tests (`PageSurfaceTests`); 1 package test |

All three schemes build with no new warnings; the 31 hosted tests and the package tests pass; the real data folder was identical before and after each run. Reach-ins into `page.view` in app code: 69 after step 1, 57 after step 3.

Where the build differs from the plan:
- `WebEngineSurface` has no `acceptsFirstMouse`: nothing needs it (the only first-mouse overrides are PictureWindow's own views).
- `Shared/PageShared.swift` is untouched: the hidden transcript reader moves with the other hidden pages in step 9.
- The factory stays in the app (it makes the app's `Page`); `Session`'s initializer stays private, so tests give a spy factory to a `Pages` of their own.
- Still on WebKit's view, by design until their steps: Apple Passwords' coordinates, the recording indicator, the inspector, child-page returns, the extension pop-up's own web view, restoration and URL reads.

Reviews: `/codex review` found no defects. Gemini (gemini-3.8-flash-high, which saw the diff cut off past 120 KB) reported eight findings; Claude checked each at its line and none held.

### 7.5 Step 4a (4 November 2026)

Built on top of 6f21a0fc and committed as 8fca31ff. Codex designed the slice (read-only), then wrote it in a worktree of its own; a Claude subagent wrote the hosted tests; Claude merged, fixed, built and tested; `/codex` and Gemini (gemini-4-argon-high) reviewed it.

- `WebEngineCore` gains the navigation contract: `WebNavigation` (the request kept whole, the source origin, `targetIsMainFrame: Bool?`, `WebNavigationKind` with `.unknown`, modifiers, the raw button number, the download flag, a server redirect and an extension rule's redirect as separate facts), `WebNavigationDecision` and `WebNavigationPolicy`, whose reply is synchronous and exactly once.
- `WebKitMacPlugin` gains `WebKitNavigationAdapter`, the web view's navigation delegate. It translates each `WKNavigationAction` (the private redirect calls moved here from `Page`, comment and all), asks `Page`, and passes every other callback on to `Page` unchanged (responses, downloads, the lifecycle). The swipe's and context menu's private callbacks are the UI delegate's and keep their route.
- `Page` implements `WebNavigationPolicy`: the old decision, branch for branch, over the contract; cancelling still comes before opening another app, a Peek or the colour-hint retry. `PageHistory` takes a plain navigation kind; the iOS app keeps its WebKit-typed entry point.
- Changes on review: the adapter cannot answer WebKit twice after a late reply; it reads `sourceFrame` as optional (WebKit can leave it nil for loads the app starts, and the adapter now reads it on every navigation); its forwarding checks it is on the main thread; it never passes any form of the decision on a navigation to the legacy delegate (WebKit asks the `preferences:` form first); and two rules are written down: the adapter must not outlive `Page`, and a port of 0 in `WebOrigin` is the scheme's default.
- Reviews: `/codex` found nothing. Gemini found every branch, side effect, redirect rule, history mapping and teardown matching the old code, and five adapter-level hazards; two were already fixed, three are fixed or written down as above.

Result: all three schemes build with no new warnings; 14 package tests, stable over repeated runs once a flaky back-and-forward test was rewritten; 41 hosted tests, twice in a row (10 new: `PageNavigationPolicyTests`, among them 1,344 combinations checked against `NewTabClick`). The test host never had a file of the real data folder open (13 `lsof` samples). Not covered: links to other apps, extension sign-ins and rule redirects, extension pages, the colour-hint retry on real websites, Peek from pinned tabs, and real ⌘- and middle-clicks from WebKit.

Found on the way, older than this work and not fixed (4a keeps behaviour as it was): `Page` takes `buttonNumber == 2` as the middle button, but WebKit's `buttonNumber` appears to report the middle button as 4 and the right as 2 (read from WebKit's code on this Mac, not tried with a mouse). If so, a middle-click on a link opens it in place instead of in a new tab.

### 7.6 Step 4b (4 November 2026)

Built on top of 8fca31ff and committed as 0ad0afee. Codex wrote the slice in a worktree of its own from a design Claude gave it, with a line-by-line map of the old callback to the new code; a Claude subagent wrote the hosted tests; Claude merged, fixed, built and tested; `/codex` and Gemini reviewed it.

- `WebEngineCore` gains the response contract: `WebResponse` (Foundation's `URLResponse` kept whole, so header lookups and the status read as before; whether it is for the main frame; whether the engine can show its type), `WebResponseDecision` (`allow`, `cancel`, `download`), and `decideResponse` on `WebNavigationPolicy`, with the same synchronous, exactly-once reply as the decision on a navigation.
- `WebKitNavigationAdapter` decides responses the way it decides navigations: it describes each `WKNavigationResponse`, asks `Page`, answers WebKit once, cancels when there is no policy or no reply, and ignores a late reply. It never passes the response decision on to `Page`. The download callbacks and the lifecycle still go to `Page` unchanged.
- `Page.decideResponse` is the old callback, branch for branch: the colour-hint retry still cancels before it loads again, now through the adapter's `load` (the same view and request); the page's kind, its status and the download rule are unchanged.
- Changes on review and testing: a local name that shadowed the response is now `http`; `forwardingTarget(for:)` now also refuses both decision selectors, as `responds(to:)` already did. WebKit hands a custom scheme's response to the navigation delegate as a plain `URLResponse`, without the status or headers the test handler gave it, so the package tests check those only when the response is HTTP.
- Reviews: `/codex` (codex exec, gpt-6.1-sol, read-only) found nothing. Gemini (gemini-3.8-flash-high; Argon's quota had run out) passed it with two changes, both made as above, and a third concern the new tests cover.

Result: all three schemes build with no new warnings; 21 package tests (8 and 13), three runs each; 52 hosted tests, twice in a row (11 new: `PageResponsePolicyTests`). The test host never had a file of the real data folder open (18 and 16 `lsof` samples, which saw its own scratch files). Not covered: the colour-hint retry on a real website, hosts eGlu leaves alone (`HandsOff`), a real download to disk, a real HTTP status through WebKit, and a `Content-Disposition` with leading spaces (the old check did not trim them either, and still does not).

### 7.7 Step 4c (4 November 2026)

Built on top of 0ad0afee and committed as 2c3e5680. Codex wrote the slice in a worktree of its own from a design Claude gave it, and compared every moved line with the old code; a Claude subagent wrote the hosted tests; Claude merged, built and tested; `/codex` and Gemini reviewed it.

- `WebEngineCore` gains `WebNavigationEvents`, what happens to the main frame's load, reported in order: started and redirected (with the address the engine shows), committed (with the new address), finished, failed (with `provisional` for a load that never committed) and the content process ending. It also gains `WebLoadError`: the engine sorts a failure as `cancelled`, `interrupted` or `other` and keeps its domain, code and failing address. Navigation and document identifiers wait until a slice needs them; nothing in `Page` used WebKit's `WKNavigation`.
- `WebKitNavigationAdapter` now implements WebKit's seven lifecycle callbacks and reports each at once to `Page`, which it holds weakly, like the policy. `loadError` sorts WebKit's errors as `Page` did: `NSURLErrorCancelled` is `cancelled`; WebKit's 102 (a policy change interrupted the load) and 204 (a plug-in handles it) are `interrupted`. Only the download callbacks still go to `Page` as WebKit's own.
- `Page` implements `WebNavigationEvents` with the old bodies, line for line. The commit takes the event's address where it read the web view's (nothing before those reads can change it); the title and the back-forward item are still read from its own view. A failure is quiet unless its kind is `other`, where the old code tested WebKit's domains and codes. The seven WebKit callbacks and `failed(_:)` are gone from `Page`.
- Reviews: `/codex` (codex exec, gpt-6.1-sol, read-only) found nothing. Gemini (gemini-3.8-flash-high) passed it with no findings.

Result: all three schemes build with no new warnings; 27 package tests (9 and 18), three runs each, the offline WebKit loads among them; 68 hosted tests, twice in a row (16 new: `PageLifecycleTests`). Among the new tests, a page's content process is killed for real, three times: the page reloads in a new process twice and then waits with its message. The test kills only the process WebKit names for the test's own page, after checking that the program is WebKit's content process; WebKit's own testing call for this is refused from the test host. The test host never had a file of the real data folder open (22 and 14 `lsof` samples). Not covered: a server redirect and a real cancelled or interrupted load through WebKit, what a commit closes (picture in picture, a pending dialog), what a finish learns of a website, and the extension check that reads the address being loaded from.

Found on the way, older than this work and not changed: a commit does not clear `exhausted` (only loading and reloading do); a form's failed sending shows the reason without the host, because the load state forgets the failed address before the message is made.

### 7.8 Step 4d (4 November 2026)

Built on top of 2c3e5680. Codex wrote the slice in a worktree of its own from a design Claude gave it; a Claude subagent wrote the hosted tests; Claude merged, fixed, built and tested; `/codex` and Gemini reviewed it. Step 4 is done with it.

- `WebEngineCore`: `WebRequestLoading` gains `loadFile(_:allowingReadAccessTo:)`; `WebDownload` (only its address so far; section 5.2's `cancel()` waits for its slice) and `WebNavigationEvents.navigationBecameDownload(_:)`, reported before the engine's callback returns, since the host must take the download over in that call.
- `WebKitMacPlugin`: `WebKitDownload` keeps WebKit's own `WKDownload` for the app's Downloads until step 9. The adapter implements both "became a download" callbacks and the file load, and with nothing left for `Page` its forwarding is gone (`legacy`, `responds(to:)`, `forwardingTarget(for:)`): it is the web view's whole navigation delegate. Codex listed every method `Page` implements that WebKit could call on a navigation delegate first: only the two download callbacks were left; the context menu's and unused wheel events' private callbacks are the UI delegate's.
- `Page` loads a site or a file through the adapter, hands a download to Downloads in `navigationBecameDownload`, and is now only WebKit's UI delegate.
- Changes on review and testing: the Mac app did not build, as `ExtensionPageDelegate` (an extension page's UI delegate, which passes the rest on to `Page`) still asked for a navigation delegate too; it now asks for a UI delegate only (`/codex` found the same). WebKit cannot turn a custom scheme's response into a download (it stops the load with its error 102), so the package test for a response download uses a `data:` address. Gemini found a package test writing its file into the source tree; it now writes into a folder of its own in the temporary folder, which it also gives as the read access, so that address differs from the file's.
- Reviews: `/codex` found the build error above and nothing else. Gemini (gemini-3.8-flash-high) passed it with three changes to the tests, all made as above.

Result: all three schemes build with no new warnings; 32 package tests (11 and 21), three runs each; 73 hosted tests, twice in a row (5 new: `PageDownloadAndFileTests`). The download tests never let a file be written: each download gets a delegate that answers "nowhere" before WebKit asks, the tests require the test data root, and nothing in `~/Downloads` changed. The test host never had a file of the real data folder open (26 and 23 `lsof` samples). Not covered: a link's download through WebKit (a custom scheme's link is another app's here, and a website's would need a server), a download that saves a file, file bookmarks.

Found on the way, older than this work: WebKit lets a file opened with read access to itself read the other files in its folder and below it, not the one file only, as `Page.request(_:)`'s comment says; only the folder above is refused. The test checks that limit. One change in 4d: a load after `tearDown()` now does nothing, since the adapter lets go of the view; before, it loaded into the torn-down view.

### 7.9 Step 5 (4 November 2026)

Built on top of 52081355. Codex wrote the step in a worktree of its own from a design Claude gave it, while 4d was being tested; a Claude subagent wrote the hosted tests; Claude merged, built and tested; `/codex` and Gemini reviewed it.

- `WebEngineCore` gains `WebChildRequest` (the `WebNavigation` that asked and `WebWindowFeatures`, the width and height asked for) and `WebNavigation.sourceIsMainFrame`. The host accepts a request by making the child from it, through its engine, before the call returns, and rejects it by making none. Section 5.2's `accept()` and `reject()` wait until the app's page is the engine's own.
- `WebKitMacPlugin` gains `WebKitChildRequest`, which keeps the configuration WebKit handed over: the child must be made with it, in the same call, to keep `window.opener`.
- `PageHost.page(_:open:for:features:) -> WKWebView?` is now `page(_:openChild:) -> Page?`, and `PageHost` has no WebKit types left. `MacPageSource.child(_:)` makes the child from the request's configuration, as `.supplied` did; `.supplied` stays for the extension runtime's tabs. `Page`'s `createWebViewWith` makes one request and reads the extension-page rule, another app's link, document picture in picture and Open Link in Peek from it; the WebKit-typed `site(sending:)` is gone. Peek, little windows, pop-ups, tabs and the picture window take the request where they took WebKit's configuration and features, and the hosts return the child page where they returned its view.
- One intended change: the picture-in-picture check read WebKit's `sourceFrame` as never nil, which would crash where WebKit gives none; it now reads it as optional and treats a missing frame as not the main frame.
- Reviews: `/codex` found nothing. Gemini (gemini-3.8-flash-high) passed it, asking for a test that `Pages.adopt(tab:space:child:)` hands the factory the request it was given; it is in `PageEngineTests`, with a test request the spy factory now accepts.

Result: all three schemes build with no new warnings (one old warning moved down a line by an import); 37 package tests (13 and 24), three runs each; 81 hosted tests, twice in a row (8 new: 7 in `PageChildTests`, 1 in `PageEngineTests`). The test host never had a file of the real data folder open (25 and 18 `lsof` samples). The new hosted tests open real windows from a page's script: the host is asked once, with the address and size; the child it makes is the window WebKit shows and keeps `window.opener`; a host that makes none rejects it (`window.open` returns null); another app's link never reaches the host. Not covered: a website opening an extension's page (needs an installed extension), Open Link in Peek, document picture in picture, and the real hosts' choices between a tab, a Peek, a pop-up and a little window, which make real windows (a little window brings the app forward).

Found on the way, older than this work: WebKit refuses a top-level `data:` load in a window a site opens, so a site opening a `data:` window leaves an empty tab.

### 7.10 Step 6 (4 November 2026)

Built on top of 86d8c880 (step 5, merged with main). Codex wrote the step in a worktree of its own from a design Claude gave it; a Claude subagent wrote the hosted tests; Claude merged, fixed, built and tested; Codex and Gemini reviewed it.

- `WebEngineCore` gains the channel contract (5.4): `WebJSON`, with Foundation's form both ways so the handlers parse a body word for word; `WebWorld` (`app`, `page`); `WebMessage` (the channel, the world, whether it came from the main frame, the frame's origin and the body, each as the engine recorded it, never as the body says); and `WebMessageChannels` (`bridgeScript`, and `open` for a channel a script posts to or one it asks, in a world).
- `WebKitEngine` gains a target, `WebKitSupport`, built for macOS 26 and iOS 17, with WebKit's `egluBridge` (`Scripts/eglu-bridge.js`: `version`, `post` and `request`, each exactly WebKit's own `postMessage` to the handler of that name, which throws the same `TypeError` for a channel not open). `WebKitMacPlugin` gains `WebKitMessageChannels`: one script message handler per channel, which hands each message over at once, as WebKit called the app's handlers.
- The Mac's five handlers (Writing, Measure as `MeasureChannel`, the Web Store's button, the password watch, Apple Passwords' sign-in box) take `WebMessage`s with every check they made, rewritten one for one; none is a WebKit type now. `Page` opens their channels in the app's world, in the same order and under the same conditions, and puts the bridge in front of each script that uses it (the password watch, writing.js, Apple Passwords' sign-in box, the store's button, measure.js), where and when each runs.
- `writing.js`, `measure.js` and `extension-store.js` call `egluBridge`, each keeping its own error handling. The iOS app links `WebKitSupport` and puts the same bridge in front of writing.js and measure.js; its handlers stay WebKit's. `Shared/Measure/MeasureHandler.swift`, now the iOS app's alone, moved to `App/Sources/`, unchanged.
- Where the build differs from the plan: handlers are called synchronously with a reply callback, not `async throws` (5.2), so every message, and every reply Writing gives at once, keeps its order and timing; there is no unregistering, no frame handle and no document number yet, since nothing uses them; the bridge goes in front of each script instead of being installed alone, since three of the scripts are also run into the document already up (turning writing or Apple Passwords on, the measuring tool), which a script of its own at document start might not have reached; and `extension-shim.js`'s capture branch stays on WebKit's handler, as the extension runtime's, since `ExtensionCapture` reads the extension's controller, space and context from WebKit's own message (step 12).
- One difference that cannot be seen: measure.js swallowed nothing when the handler was there and `postMessage` threw; it now catches a throw. The audit of its seven messages found only plain JSON, which never throws.
- Changes on review and testing: the bridge took a page element with the id `egluBridge`, which is a named property of the window in every world, the app's included, for itself already defined; it then stayed undefined, and the password watch's first post threw before it began to watch (Codex). It now looks only for its own property; a package test with such an element fails without the change and passes with it. Handing the channels method references gave five new warnings in the app's Swift 5 mode; they are closures now. The inventory lists the tests' deliberate reads of WebKit's handlers apart, as it does for reach-ins.
- Reviews: Codex (gpt-6.1-sol, read-only, the diff inlined) found the named-element problem above and nothing else. Gemini (gemini-3.8-flash-high) passed it with no findings.

Result: all three schemes build with no new warnings; 51 package tests (19 and 32), three runs each; 95 hosted tests, twice in a row (14 new: `PageChannelTests`); PadCore's 741 tests; the page-script tests as before the step (writing.mjs 69 of 70, the one failure older than this work and the same; measure.mjs 39 of 39; the rest unchanged). The test host never had a file of the real data folder open (37 and 28 `lsof` samples). The inventory's app scripts reach WebKit's handlers in 2 lines, the iPad's `bridge.js` and the extension runtime's capture, where there were 7; its total is 549 where it was 568. Not covered: the store's button on the Chrome Web Store and Apple Passwords' messages (each needs its site, and Apple Passwords Apple's helper: only that their channels are open is checked), a hands-off page, an extension's page, Writing's actions that write (a dictionary word, a rule turned off), the iOS app run (it is built, and carries the bridge's script), and the iOS crash tests.

Found on the way, older than this work: measure.js says nothing when it starts; its first word comes with a key (G, R or X) or a click. The plan's 5.4 says navigation and teardown cancel pending replies; `WebKitMessageChannels` leaves that to WebKit, as the app's handlers did.

### 7.11 Step 7a (4 November 2026)

Built on top of 55ee7e38. Step 7 is two slices: 7a, the page's services, with developer tools (planned as a slice of their own, 7c, and built in the same run); 7b, the UI delegate (7.12). Codex wrote 7a in a worktree of its own from a design Claude gave it; a Claude subagent wrote the hosted tests; Claude merged, fixed, built and tested; Codex and Gemini reviewed it.

- `WebEngineCore` gains services (5.2): `WebFind` (backwards, case, wrapping, an answer whether there is a match), `WebZoom` (`pageZoom`, read and written; `magnification`, read), `WebMediaCapture` (`isCapturing`: the camera or the microphone, live or muted), `WebUserAgent` (`customUserAgent`), and `WebDeveloperTools` (`show` the inspector, the console or element selection, false where the engine cannot). `WebEngineAppKit` gains `WebPrinting` (`printOperation(with:)`, ready to run).
- `WebKitMacPlugin` gains `WebKitPageServices`, which does each of these with the page's view as `Page` and `WebInspector` did, line for line: WebKit's `printOperation` with its view's frame set to the view's bounds, and the private Web Inspector calls, each asked first.
- `Page` keeps one services object, and its find, zoom, capture checks (`mustStay`, `appWentBehind`), device sizes, printing, the measuring tool's window size and `showDeveloperTool` go through it. `WindowModel.refresh` reads `page.pageZoom`; Apple Passwords places its card from the page's surface and `pageZoom` times `magnification`; the developer bar reads `page.state.url` and, with the menus and `WindowModel`, opens developer tools through `Page.showDeveloperTool`. The developer bar, the menus and `WebInspector.swift` (now only the toast's words) import no WebKit.
- Where the build differs from the plan: the services are not optional on the page yet; the WebKit plugin has them all, and a plugin without one comes with step 13's fake. `Page.find`'s answer is now `@MainActor @Sendable`, as the service hands it on; WebKit already answered on the main thread.
- Changes on review and testing: WebKit reads an empty string back, not nil, once its own user agent is back; the service reads that as nil, as its contract says (nothing in the app reads it back). The package test for developer tools opened WebKit's real inspector, which would put a window on screen; it now uses a stand-in inspector, and a second test checks that this WebKit has the three verbs, without performing them. The find tests passed even with the direction dropped (Codex); a test with two matches now fails without it.
- Reviews: Codex (gpt-6.1-sol, read-only, the diff inlined) found two minor points: the find tests' gap above, and that the user agent read back as nil for an empty string, which is the change above, kept on purpose. Gemini (gemini-3.8-flash-high) passed it with no findings.

Result: all three schemes build with no new warnings; 61 package tests (19 and 42), three runs each; 102 hosted tests, twice in a row (7 new: `PageServicesTests`); PadCore's 741 tests. The test host never had a file of the real data folder open (32 and 26 `lsof` samples). Reach-ins into `page.view` in app code: 55 before the slice, 43 after; the inventory's total is 530. Not covered: printing and developer tools through a real page (each opens a panel or a window; the package tests cover them, the inspector through a stand-in), the window's zoom readout (a real window), a page with the camera or the microphone, and a typed zoom in the window's field.

## 8. What a Chromium plugin would face

Gemini researched these on 4 November 2026, then checked each claim against primary sources in a second run. Gemini's own web search failed once during that run, so its verdicts are claims. The column "Claude" says what Claude checked itself.

| # | Claim | Gemini's verdict and sources | Claude |
|---|---|---|---|
| 1 | CEF is the only realistic way to put Chromium in a Swift Mac app without maintaining a Chromium fork (as Arc did). Swift needs an Objective-C++ or C++ shim; CEF's C API works from Swift with manual reference counting | Confirmed. [CEF include/](https://github.com/chromiumembedded/cef/tree/master/include), [cef_base_capi.h](https://github.com/chromiumembedded/cef/blob/master/include/capi/cef_base_capi.h), [Swift C++ interop](https://www.swift.org/documentation/cxx-interop/) | Not checked |
| 2 | The Alloy bootstrap was removed at M128. Under the Chrome bootstrap, each browser is Chrome or Alloy style. Full Chrome extension support is Chrome style only; windowless rendering is Alloy only | Confirmed. [Issue 3685](https://github.com/chromiumembedded/cef/issues/3685), [issue 3681](https://github.com/chromiumembedded/cef/issues/3681), [issue 3859](https://github.com/chromiumembedded/cef/issues/3859) | Confirmed: `cef_types_runtime.h` (master, read 4 November 2026) and a web search |
| 3 | **On the Mac, a Chrome-style browser cannot be a child of the app's own `NSView`.** Giving a parent view forces Alloy style. Chrome style needs a window CEF makes (its default window or its Views framework), and a Chrome-style CEF window holds at most one Chrome-style browser | "Wrong" as the plan first asked it: it cannot. [cef_types_mac.h](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h) | Confirmed: `cef_types_mac.h:151` to `:152` says "Alloy style will always be used if windowless_rendering_enabled is true or if parent_view is provided"; `cef_types_runtime.h` gives the rest |
| 4 | A CEF app needs five helper apps (Helper, GPU, Renderer, Plugin, Alerts) and the framework bundle, signed from the inside out; the hardened runtime needs `allow-jit` and `allow-unsigned-executable-memory`. It adds about 70 to 100 MB to the download | Confirmed. [Issue 2744](https://github.com/chromiumembedded/cef/issues/2744), [Apple: hardened runtime](https://developer.apple.com/documentation/security/hardened_runtime) | Not checked |
| 5 | Official CEF builds play no H.264 or AAC. Adding them means building from source (`proprietary_codecs`, `ffmpeg_branding="Chrome"`) and taking patent licences from Via LA | Confirmed. [CEF automated build setup](https://bitbucket.org/chromiumembedded/cef/wiki/AutomatedBuildSetup.md), [Via LA AVC](https://www.via-la.com/licensing-programs/avc-h-264/) | Not checked |
| 6 | Chromium ships security fixes weekly; CEF's builds follow in one to three days, sometimes up to a week | Confirmed. [Chrome releases](https://chromereleases.googleblog.com/), [CEF builds](https://cef-builds.spotifycdn.com/index.html) | Not checked |
| 7 | No app-side call runs a script in an isolated world; it takes renderer-process code or the DevTools Protocol. The message router can be bound only in the isolated world's context, so `cefQuery` is not visible to the page | Confirmed. [cef_frame.h](https://github.com/chromiumembedded/cef/blob/master/include/cef_frame.h), [cef_message_router.h](https://github.com/chromiumembedded/cef/blob/master/include/wrapper/cef_message_router.h), [issue 3867](https://github.com/chromiumembedded/cef/issues/3867) | Not checked |
| 8 | Blocking is per request (`OnBeforeResourceLoad`), with element hiding by injected CSS. `declarativeNetRequest` exists only for extensions, not for the app | Confirmed. [cef_resource_request_handler.h](https://github.com/chromiumembedded/cef/blob/master/include/cef_resource_request_handler.h) | Not checked |
| 9 | No public API for rubber-band state or unused wheel events. Chromium's own swipe can be turned off (`--overscroll-history-navigation=0`), but unused scrolls are not handed back | Confirmed. [Issue 3764](https://github.com/chromiumembedded/cef/issues/3764), [content_switches.cc](https://source.chromium.org/chromium/chromium/src/+/main:content/public/common/content_switches.cc) | Not checked |
| 10 | Snapshots go through the DevTools Protocol (`Page.captureScreenshot`), since AppKit's own drawing of a GPU-composited view comes back empty. DevTools replaces Web Inspector | Confirmed. [cef_browser.h](https://github.com/chromiumembedded/cef/blob/master/include/cef_browser.h) | Not checked |
| 11 | Each space can have its own storage: a request context with its own cache folder, made and released while the app runs | Confirmed. [cef_request_context.h](https://github.com/chromiumembedded/cef/blob/master/include/cef_request_context.h) | Not checked |
| 12 | Sparkle updates a CEF app, but each Chromium update is a large delta (30 to 60 MB), and the helpers must quit before the swap | Confirmed. [Sparkle delta updates](https://sparkle-project.org/documentation/delta-updates/) | Not checked |
| 13 | Prior art: Firefox's `BrowserKit` (`Engine`, `EngineView`, `EngineSession`, a session delegate); Arc's Swift UI on its own Chromium layer, not CEF; wry (Tauri) leaves out content blocking, extensions and isolated worlds | Confirmed. [firefox-ios WebEngine](https://github.com/mozilla-mobile/firefox-ios/wiki/How-to-work-on-the-WebEngine-project), [wry](https://github.com/tauri-apps/wry) | Not checked |

**What this means for the plan:**
- In eGlu's own windows, a Chromium plugin is Alloy style. The view contract (5.3), where the plugin hands over an `NSView` and the host places it, fits that.
- Chrome extensions in a Chromium eGlu would be partial at best in Alloy style, unless that build gives up eGlu's AppKit windows for CEF's. So extensions stay a WebKit plugin feature (decision 2), and the interface must work with no extensions at all.
- The rest fits the contracts as traits and services: isolation is possible with renderer code (`.isolatedScripts`); storage per space maps to request contexts (step 8); snapshots must be asynchronous; the swipe trait is absent and Chromium's own swipe is used.
- A Chromium eGlu also takes on about 70 to 100 MB more per download, five helper apps, JIT entitlements, weekly security releases, and codec builds from source with licences.
- The gate before anyone promises a Chromium plugin is now narrower: a spike must show what Alloy style's extension support covers, and whether an Alloy-style CEF view behaves inside eGlu's windows (moving between windows as the recording indicator and Peek do, full screen, focus).

## 9. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| 1 | Where a Chromium plugin lives | Its own repository. eGlu's rule is no dependencies beyond Apple's frameworks, Sparkle and its own `Engines`, and CEF would break that rule. Codex notes this is a policy choice, not something the code forces |
| 2 | Extensions: put them behind the contracts, or keep them as a WebKit-only capability | Keep them WebKit-only until step 12, then split them into a runtime and a browser host (5.8), with the interface working when there are none. A Chromium plugin inside eGlu's windows is Alloy style, where Chrome extensions are partial at best (section 8, row 3), so full parity there is not a goal |
| 3 | How the iOS app lives with shared changes | It depends on `WebKitSupport` and calls its types directly; app-specific pieces of `PageShared.swift` stay in each app; shared scripts get an iOS `egluBridge` (section 4). Copying shared files into `App/` would leave every later fix to be made twice |
| 4 | Names | `WebEngineKit`, `WebKitEngine` (`WebKitSupport`, `WebKitMacPlugin`), `WritingServiceKit`, `DocumentServiceKit`, `HarperPlugin`, `DocumentsPlugin`, `egluBridge`. None clashes with PadCore's `Engine`, its `Adapters` or the `Engines` package |
| 5 | Start with the first pull request (7.1) | Yes: it is small, adds a Mac test target the app lacks, and changes no behaviour |

## 10. How this plan was made

| Step | Who | Result |
|---|---|---|
| Survey and draft | Claude | Counts, the draft layers, phases and first contract |
| Round 1 | Codex, reading the repository | Corrected counts; Mac is DMG-only; HandsOff does not cover navigation; PadCore's rules and scripts are WebKit's; no cookie access; Harper needs its own contract; `Shared/` is not a module; two contracts |
| Research | Gemini | First version of section 8 |
| Round 2 | Codex, with Gemini's research | `egluBridge`; where content blocking goes; extensions as two contracts; the page and grammar contracts; the first pull request |
| Mac only | Claude, at the product owner's request | iPad and iPhone parts dropped; the iOS app kept building; the documents engine added |
| Validation | Codex (two independent runs), Gemini, Claude | Section 11 |
| Steps 0 and 1 | Gemini, Codex, a Claude subagent; reviewed by `/codex review` and Gemini; checked by Claude | 7.3 |

## 11. Validation

Done on 4 November 2026, on the Mac-only plan, at commit 75fcca2. No app was built or run.

### 11.1 How

| Check | By | Method |
|---|---|---|
| Every file and line the plan cites | Claude | A script that resolves each cited path and prints the cited line, read by hand (`check_citations.py` in the session's scratchpad) |
| The facts in section 3 and the first pull request | Codex, run A | Read the plan, then the code, without Claude's conclusions |
| The contracts, phases and iOS coexistence | Codex, run B | The same, separately |
| Every P1 finding of both runs | Claude | Read at the cited line before accepting it |
| The contract sketches | Claude | `swiftc -typecheck -swift-version 6` (Swift 6.4.2, macOS 27.2 SDK, target macOS 26) on the sketches copied out of this file by a script, then with a throwaway `WKWebView`-backed page implementing them: frame handles and document numbers, navigation IDs, modifiers and buttons, lifecycle events, errors, child requests, dialogs and file panels, find, zoom, capture state and user agent. Run on the first sketch and again on the revised one |
| The Chromium research | Gemini, then Claude | Gemini checked each claim against primary sources; Claude read the CEF headers that decide the plan |
| The revision | Codex, run B resumed | Re-read the revised plan and the code; rated each earlier P1 resolved, partly or not, and looked for new problems. Claude read every new P1 at its line |

### 11.2 What it found and what changed

| # | Finding | From | Severity | Change |
|---|---|---|---|---|
| 1 | The page contract had no view: nothing for hosts to place, size or focus | Codex B | P1 | 5.3; step 3 |
| 2 | Lifecycle events (commit, finish, failures, process ending, close) were missing; `PageState` cannot replace them | Codex B | P1 | Events in 5.2; step 4 |
| 3 | Find, printing, zoom, magnification, dialogs, file panels, capture state, user agent and developer tools had no callable contract; capability flags were not enough | Codex B | P1 | Optional services in 5.2; step 7; flags renamed traits |
| 4 | Navigation lost the mouse button, modifier keys and the kind of redirect | Codex B, Claude | P1 | `WebModifiers`, `WebMouseButton`, `WebRedirect` |
| 5 | A child page must be accepted inside the same call, or WebKit loses the opener tie | Codex B, Claude (conformance) | P1 | Stated in 5.2 |
| 6 | WebKit has no public frame or document identifier, so `WebFrame.id` and `documentID` could not be filled | Claude (conformance, SDK header) | P1 | Plugin-made handles and document numbers |
| 7 | Comparing product `canGoBack` with WebKit's would fail by design for a replaced tab | Codex A | P1 | Engine state and product state split (sections 2, 4, 7.1) |
| 8 | `load` and `reload(byHand:)` do more than WebKit's calls; replacing them would change behaviour | Codex A | P1 | Left alone in 7.1; raw origin reload kept raw |
| 9 | Two inline Swift scripts also call WebKit's message handlers | Codex A | P1 | 5.4 and section 3 |
| 10 | `extension-shim.js` runs in several worlds; extension capture needs more authority than frame, world and origin | Codex B | P1 | Only its capture branch moves; authority stays in the plugin (5.4) |
| 11 | Shared scripts changing transport would break the iPad | Codex B | P1 | iOS `egluBridge` adapter (section 4) |
| 12 | One package target cannot hold both AppKit code and what the iOS app needs | Codex B | P1 | `WebKitSupport` and `WebKitMacPlugin` |
| 13 | Moving `SVGRaster` breaks `SiteIcons` and the Site Icons Tests target | Codex B | P1 | Injected rasterizer, in step 9 |
| 14 | Contracts declared before the code that uses them would be redone; the fake build needs pages made through a factory | Codex B | P1 | Each contract written with its WebKit implementation and fake (section 4); step 2 |
| 15 | `Engines` is imported by seven Mac files, not five | Codex A | P2 | Corrected |
| 16 | History identities, per-space stores, download retries, Handoff fetches, site icons, the recording indicator and Apple Passwords were missing from the inventory | Codex A | P2 | Section 3, steps 8 and 9 |
| 17 | The first pull request's call sites could not reach "no `WKWebView` in hosts" | Codex A | P2 | Its goal narrowed to state and navigation |
| 18 | The hosted test target was unspecified (signing, entitlements, data folder) | Codex A | P2 | 7.2 |
| 19 | `GrammarService` allowed value types, which would break `WritingChecker`'s stale-answer check | Codex B | P2 | `AnyObject` service |
| 20 | `ContentBlocker` and `DocumentSource` mix engine work with the app's own | Codex B | P2 | Split first (5.5, 5.7) |
| 21 | The cookie test would not see new package folders | Codex A | P3 | Widened in step 0 |
| 22 | The four bare file names in the first pull request matched files in both apps | Claude (citation script) | P3 | Full paths |
| 23 | On the Mac, a Chrome-style CEF browser cannot sit in the app's own view; a parent view forces Alloy style, with partial extension support | Gemini, confirmed by Claude in CEF's headers | P1 for a Chromium plugin | Section 8; decision 2; the gate narrowed |
| 24 | Gemini's first research gave Japan's iOS version wrongly (since dropped with the iOS parts) and overstated Alloy style's lack of extension support | Claude, Codex | P3 | Corrected |
| 25 | The page's `zoom` service and `WebZoom`'s own `zoom` collided when one class implements both, as a plugin naturally would | Claude (type-check) | P2 | `WebZoom.pageZoom` |
| 26 | The documents sketch used `Data` without importing Foundation | Claude (type-check) | P3 | Fixed |
| 27 | Redirect provenance has no public WebKit API | Claude (conformance) | P3 | Stated in 5.2; the private calls stay in the plugin |

The re-check of the revision rated 10 of the earlier P1s resolved and 4 partly (the view, navigation metadata, page services, the fake build), and found these:

| # | Finding | Severity | Change |
|---|---|---|---|
| 28 | "`goBack()` tries the replacement first" reversed today's order: the replacement is used only when WebKit cannot go back | P1 | 7.1 now says so, with a test for a replaced tab that later has its own history |
| 29 | `EGLU_DATA_ROOT` does not keep the test host away from the standard preferences, the persistent stores and snapshots | P1 | 7.2: its own bundle identifier, a launch argument that skips start-up services, a reset hook |
| 30 | Step 2 promised the whole app built with the fake before anything was extracted | P1 | Step 2 ends with a factory test; the whole fake build moves to step 13 |
| 31 | Step 13 could come before step 11 removed `Engines` | P1 | Step 13 needs 11 and 12 |
| 32 | Teardown cancelling downloads would stop downloads the app has taken over | P1 | `downloadStarted` hands them to the host; teardown cancels only what the page owns |
| 33 | The documents contract dropped the page count, title, author and date that Handoff shows, and had the wrong kinds | P1 | `DocumentPages`; the kinds of `DocumentFormat`; 0-based pages |
| 34 | Nothing tied a page to its view | P2 | `WebEngineMacPage` (5.3) |
| 35 | The address a load came from, kept at its start and at each server redirect, had no event | P2 | `started` and `redirected` events |
| 36 | Step 4 removed `PageHost`'s WebKit types before step 5 removed the child signature; step 5 also needs the view | P2 | Step 4 keeps child creation; step 5 needs 3 and 4 |
| 37 | Step 9's end state included the extension runtime's hidden views, which move in step 12 | P2 | Step 9 excludes them |
| 38 | Numbering only main-frame commits cannot tell when a subframe's document changes | P2 | `evaluate` takes main-frame handles only, for now; handlers keep their origin checks |
| 39 | A dialog open at teardown had no defined answer | P2 | It gets its cancel answer; a held background dialog stays the host's |

Checked and found right: every line the plan cites; the counts of WebKit imports (36 and 9), extension lines (9,348), `Page` lines (1,798) and `page.view` lines (86 in 18 files); that navigation decisions are synchronous today; that the transient hosts never meet the replaced-page rule; that the first pull request touches no file the iOS app compiles.

### 11.3 Not verified

- No build or test was run of the app; the plan's steps are untested.
- Not designed yet, by choice: printing, the context menu's element, developer tools, picture in picture, history identities, restoration data and snapshots (5.2). The re-check rated the page services "partly" for this reason; each is designed in its step.
- The revision after the re-check (findings 28 to 39) was checked by Claude at the cited lines and by the type-check, not by a third Codex run.
- The type-check covers the sketches' shape under Swift 6, not their behaviour. The conformance page was a throwaway, not a WebKit plugin.
- The rows of section 8 marked "Not checked": Gemini's verdicts with sources, not read by Claude.
- What Alloy style's extension support covers, and how an Alloy-style CEF view behaves in eGlu's windows: only a spike can answer them.
