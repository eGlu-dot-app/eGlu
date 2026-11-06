# eGlu for Mac built with a fake engine

Status: specification only, written on 5 November 2026 at commit 5228f9f9 for the last piece of step 13 (`EngineSplitPlan.md` 7.31). Nothing here is built. The product owner chose to leave the build for later and to have it written down so that anyone can build it. Two parts were tried in scratch copies, outside the repository: the `project.yml` change of section 4, taken from this document's text, was generated with XcodeGen 2.46.0 and its targets compared with today's (4.2 says what was compared), not compiled; and the package manifest of 5.1 was built and its test target run with `swift test` against the real `WebEngineKit` and `PadCore`, with one probe file in place of the fakes. Everything else is from reading the code at that commit. Where this document chooses something the code does not settle, it says so and why. Claude wrote it; Codex (gpt-6.1-sol, read-only, reading the repository) and Gemini (gemini-3.8-flash-high, given the document and fourteen of the files it cites) reviewed it. Of Codex's nine findings, eight held at their lines and are fixed here (the storage's isolation, a kept download session's lifetime, the factory's records keeping pages alive, restoration as `Data`, a refused response leaving the page loading, the hidden page's deadline, evidence callbacks, testing a `precondition`); the ninth, that the data folder check does not check where the folder is, is true of the page tests too and is a note in section 10. Of Gemini's five, one held (the storage's isolation, as Codex); the others contradicted the code or the generated project.

Read `Docs/WebEngine.md` first: it describes the contracts this build implements. This document says what to add, where, and what each fake does.

## 1. What it is, and when it is done

Plan section 1 asks for "a build configuration of the Mac app that links a fake engine instead of the WebKit plugin" that "builds and runs the interface's tests", to show the contracts are complete without WebKit.

The build is a second Mac app made from the same `Mac/` and `Shared/` sources, with a fake engine package in place of `WebKitEngine`, its own composition file, and its own test target. It is never shipped, archived or signed for distribution. Its pages draw nothing and run no JavaScript: tests play the engine's part through the fake's driver methods (section 5.3).

It is done when all of these hold:

1. The scheme `eGlu Mac Fake Engine` builds in the configuration `FakeEngine`, its "Engine boundary" phase passing.
2. The built app links nothing from WebKit or `WebKitEngine` (the checks in section 8).
3. Its tests pass twice in a row: `StartUpTests`, `PageWritingTests` and `PageSurfaceTests` from `Tests/MacPage` unchanged, and the new interface tests of section 7.
4. The fake package's own tests pass three runs in a row (`swift test` in `FakeEngine/`).
5. Every existing check still passes as before: the three schemes build with the same twelve warnings, the 141 hosted tests, the package tests, PadCore, Site Icons, the page-script tests, `Tests/test_engine_inventory.py`.
6. The test app never opens a file in `~/Library/Application Support/Safience` (`lsof` samples, as for the page tests).
7. The plan gets a 7.x section, `Docs/WebEngine.md` section 6 says the build exists, and `Docs/EngineInventory.md` is regenerated.

What it does not show: opener ties, script isolation, real loading, content rules matching real pages, extension execution. Only the WebKit plugin's tests and the hosted tests can show those (plan section 7, "Every step runs").

## 2. Choices made here

| Choice | Why |
| --- | --- |
| A configuration of its own, `FakeEngine` (type debug) | An app target writes its module to `Build/Products/<configuration>/eGluMac.swiftmodule` (seen in this Mac's DerivedData). Built in Debug or Test, the fake app would overwrite the module the WebKit targets and their tests read. Its own configuration gives it its own products folder. |
| Module name stays `eGluMac` | Test files then compile in both test targets unchanged (`@testable import eGluMac`). |
| Product name `eGluFakeEngine`, identifier `net.taehee.safience.fakeengine.pagetests` | The identifier must end in `.pagetests`: `Mac/Sources/EgluApp.swift` refuses to host tests otherwise, and `StartUpTests` checks the suffix. A name of its own keeps its preferences and caches apart from the WebKit test host's. |
| Composition file `Mac/FakeEngine/EngineComposition.swift` | Inside `Mac/`, so the boundary check scans it and it cannot import WebKit. The same type name, `EngineComposition`, so no call site changes. |
| No Dock tile plug-in in the fake app | Nothing tested needs it, and the plug-in's Test signing is the WebKit test host's (`net.taehee.safience.pagetests.docktile`). |
| Harper and Documents stay | The request replaces the web engine only. `Mac/Sources/Plugins.swift` is unchanged, so the fake app still links `Engines` through `EnginePlugins`, and `PageWritingTests` needs them. |
| One package `FakeEngine`, one library product `FakeMacEngine` | One module is enough; it depends on `WebEngineCore`, `WebEngineAppKit` and `PadCore` only. |
| A runtime with no extensions, not a working fake extension engine | The app always makes a runtime (`Extensions.runtime`); the contracts allow absent answers (`WebEngine.md`, "A plugin without extensions"). A fake that runs extensions would be a second extension engine. |
| Pages are scripted, not rendered | The interface's logic is what is tested; rendering is the engine's. |

The owner may change any of these; sections 4 to 7 follow from them.

## 3. Files

| Path | New or changed | What it holds |
| --- | --- | --- |
| `FakeEngine/Package.swift` | New | The package (section 5.1). |
| `FakeEngine/Sources/FakeMacEngine/*.swift` | New | The fakes (sections 5.2 to 5.6). |
| `FakeEngine/Tests/FakeMacEngineTests/*.swift` | New | The fakes' own tests (section 7.4). |
| `Mac/FakeEngine/EngineComposition.swift` | New | The fake build's composition (section 6). |
| `Tests/FakeEngine/FakePageTestSupport.swift` | New | `PageTestCase` for the fake build (section 7.1). |
| `Tests/FakeEngine/*Tests.swift` | New | The interface tests (section 7.3). |
| `project.yml` | Changed | Configuration, package, templates, two targets, one scheme (section 4). |
| `eGlu.xcodeproj` | Regenerated | `xcodegen` in the repository's root, committed as generated. |
| `Tests/engine-inventory.py`, `Tests/test_engine_inventory.py` | Changed | A composition file per engine (section 4.3). |
| `Docs/EngineSplitPlan.md`, `Docs/WebEngine.md`, `Docs/EngineInventory.md` | Changed | As in section 1, item 7. |

`.gitignore` already ignores `.build/`, so the package's build folder stays out.

## 4. The project

### 4.1 `project.yml`

Five changes. The text below is what was generated in the scratch copy.

1. A configuration, after `Test: debug`:

```yaml
  FakeEngine: debug
```

2. A package, after `WebKitEngine`:

```yaml
  FakeEngine:
    path: FakeEngine
```

3. The `MacApp` template splits in two: `MacInterface`, what every Mac build of the interface has, and `MacApp`, the WebKit build's additions. `MacInterface` excludes both composition files; `MacApp` adds WebKit's back. XcodeGen appends a target's lists to its template's, and a template may use another template (both seen in the generated project).

```yaml
targetTemplates:
  MacInterface:
    type: application
    platform: macOS
    configFiles:
      Debug: Config/Mac.xcconfig
      Release: Config/Mac.xcconfig
      Test: Config/Mac.xcconfig
      FakeEngine: Config/Mac.xcconfig
    sources:
      - path: Mac
        excludes:
          - DockTile/**
          - FakeEngine/**
          - Sources/EngineComposition.swift
      - path: Shared
    dependencies:
      - package: PadCore
      - package: WritingServiceKit
      - package: DocumentServiceKit
      - package: EnginePlugins
        product: HarperPlugin
      - package: EnginePlugins
        product: DocumentsPlugin
      - package: WebEngineKit
        product: WebEngineCore
      - package: WebEngineKit
        product: WebEngineAppKit
    preBuildScripts:
      - name: Engine boundary
        basedOnDependencyAnalysis: false
        script: |
          cd "$SRCROOT"
          /usr/bin/python3 Tests/engine-inventory.py --strict
    settings:
      base:
        PRODUCT_NAME: eGlu
        PRODUCT_MODULE_NAME: eGluMac
        INFOPLIST_FILE: Mac/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        ASSETCATALOG_COMPILER_APPICON_NAME: eGlu
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        ENABLE_PREVIEWS: NO
        COMBINE_HIDPI_IMAGES: YES
  MacApp:
    templates: [MacInterface]
    sources:
      - path: Mac/Sources/EngineComposition.swift
    dependencies:
      - package: WebKitEngine
        product: WebKitMacPlugin
      - package: WebKitEngine
        product: WebKitExtensions
      - package: WebKitEngine
        product: WebKitSupport
      - target: eGlu Dock Tile
        embed: true
        codeSign: true
        copy:
          destination: plugins
```

Keep the comments the current template has, on the lines they describe.

4. Two targets, before `schemes:`:

```yaml
  eGlu Mac Fake Engine:
    templates: [MacInterface]
    sources:
      - path: Mac/FakeEngine
    dependencies:
      - package: FakeEngine
        product: FakeMacEngine
    settings:
      base:
        PRODUCT_NAME: eGluFakeEngine
        PRODUCT_BUNDLE_IDENTIFIER: net.taehee.safience.fakeengine.pagetests
        EGLU_DATA_ROOT: $(OBJROOT)/eGluFakeEngineData
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        DEVELOPMENT_TEAM: ""
        MAC_ENTITLEMENTS: Config/eGluMacLocal.entitlements
        MAC_PROFILE: ""
        ENABLE_HARDENED_RUNTIME: NO
  eGlu Mac Fake Engine Tests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/FakeEngine
      - path: Tests/MacPage/StartUpTests.swift
      - path: Tests/MacPage/PageWritingTests.swift
      - path: Tests/MacPage/PageSurfaceTests.swift
    dependencies:
      - target: eGlu Mac Fake Engine
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.taehee.safience.fakeengine.pagetests.tests
        GENERATE_INFOPLIST_FILE: YES
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/eGluFakeEngine.app/Contents/MacOS/eGluFakeEngine
        BUNDLE_LOADER: $(TEST_HOST)
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        DEVELOPMENT_TEAM: ""
        ENABLE_HARDENED_RUNTIME: NO
```

The test target depends on the app alone, as `eGlu Mac Page Tests` does: that target imports `WebKitMacPlugin`, `WebEngineCore` and the rest with only `eGlu Mac` listed, and finds them in the products folder. Listing the fake package in the test target too would link a second copy of it into the test bundle.

The fake app's settings are in `base`, for every configuration, because it is only ever a test host: its own identifier, its own data folder (written into its Info.plist through `Mac/Info.plist`'s `EGLU_DATA_ROOT`, which `Session.dataRootOverride` reads), ad-hoc signing, no iCloud, no hardened runtime (which would refuse to load the ad-hoc test bundle). These are the WebKit test host's Test settings with a new name and folder.

5. A scheme, at the end:

```yaml
  eGlu Mac Fake Engine:
    build:
      targets:
        eGlu Mac Fake Engine Tests: [test]
    test:
      config: FakeEngine
      targets:
        - eGlu Mac Fake Engine Tests
      environmentVariables:
        EGLU_DATA_ROOT: $(OBJROOT)/eGluFakeEngineData
      commandLineArguments:
        "-ApplePersistenceIgnoreState YES": true
```

Then run `xcodegen` in the repository's root and commit `eGlu.xcodeproj` with `project.yml`.

### 4.2 What was compared in the scratch copy

- `eGlu Mac` and `eGlu Mac Direct`: the same 133 source files as the committed project, the same packages linked (WebKit's three among them), the Dock tile embedded, the "Engine boundary" phase.
- `eGlu Mac Fake Engine`: the same 133 files except `Mac/FakeEngine/EngineComposition.swift` in place of `Mac/Sources/EngineComposition.swift`; linked `PadCore`, `WritingServiceKit`, `DocumentServiceKit`, `HarperPlugin`, `DocumentsPlugin`, `WebEngineCore`, `WebEngineAppKit`, `FakeMacEngine` and nothing of WebKit's; no Dock tile; the boundary phase.
- The `FakeEngine` configuration defines `DEBUG`, with `-Onone` and testability, as Debug and Test do. The scheme's test action uses it and sets `EGLU_DATA_ROOT`.

Not checked: compiling, linking, running. The iPhone app and the Dock tile have no configuration file for `FakeEngine`; the fake scheme never builds them.

### 4.3 The boundary check

Today `Tests/engine-inventory.py` lets one file, `Mac/Sources/EngineComposition.swift`, import the WebKit plugin's modules. With two composition files, each may import only its own engine's modules:

```python
PLUGIN_IMPORT_RE = re.compile(
    r"^\s*(?:@\w+\s+)*import\s+(WebKitExtensions|WebKitMacPlugin|WebKitSupport|FakeMacEngine)\b")
# Each composition point, and the plugin modules it alone may import.
COMPOSITION_FILES = {
    "Mac/Sources/EngineComposition.swift": {"WebKitExtensions", "WebKitMacPlugin", "WebKitSupport"},
    "Mac/FakeEngine/EngineComposition.swift": {"FakeMacEngine"},
}
```

In `run_imports` and `run_inventory`, stop skipping composition files; keep a plugin import only when `finding.detail not in COMPOSITION_FILES.get(rel_path, set())`. Also scan `FakeEngine/Sources` in `--strict` for `import WebKit`, so the fake package can never take WebKit in. Add to `test_plugin_imports_only_at_the_composition_point`: the fake composition importing `FakeMacEngine` passes; it importing `WebKitExtensions` fails; `Mac/Sources/EngineComposition.swift` importing `FakeMacEngine` fails; a file in `FakeEngine/Sources` importing WebKit fails. The message printed for an offending line stays as it is.

## 5. The fake engine package

### 5.1 `FakeEngine/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FakeEngine",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FakeMacEngine", targets: ["FakeMacEngine"])
    ],
    dependencies: [
        .package(path: "../WebEngineKit"),
        .package(path: "../PadCore")
    ],
    targets: [
        .target(name: "FakeMacEngine", dependencies: [
            .product(name: "WebEngineCore", package: "WebEngineKit"),
            .product(name: "WebEngineAppKit", package: "WebEngineKit"),
            .product(name: "PadCore", package: "PadCore")
        ]),
        .testTarget(name: "FakeMacEngineTests", dependencies: ["FakeMacEngine"])
    ],
    swiftLanguageModes: [.v6]
)
```

`PadCore` is needed because the composition's `name(in:manifest:fallback:)` and `icon(in:manifest:)` take PadCore's `ExtensionManifest`. Nothing in the package imports WebKit, and it depends on nothing in `WebKitEngine`, its tests included.

### 5.2 Rules every fake keeps

These come from the contracts' comments and from what `WebKitMacPage` and its adapters do.

- Everything is `@MainActor`, except `FakeExtensionStorage` (5.6), whose class and `init` are nonisolated because the composition makes it in a `nonisolated static let`, as WebKit's `ExtensionStorage` is; and `WebExtensionStorage.prepare` and `WebExtensionMetadata.packageName`, which the contracts make `nonisolated`.
- Every type the composition names is `public`, with a `public init`.
- The six receivers handed to `WebMacPage.connect` are held weakly. WebKit's adapters hold them weakly (`WebKitNavigationAdapter`, `WebKitUIAdapter`, `WebKitPageView.events`, `stateEvents`); `Page` is most of them and owns the engine page, so a strong reference would keep every page alive. `view.menus` is kept strongly by the view ("Kept by the view").
- `decideNavigation` and `decideResponse` are answered before the call returns. The fake asks, then checks with `precondition` that exactly one reply came. WebKit's adapter cancels when no reply came; the fake fails instead, because in a test a missing reply is a bug in `Page`.
- A child page is made inside the call that handed over the request (`WebChildRequest`, `WebMacPageSource.child`).
- `state` is updated before the event that reports it, as WebKit's observation is.
- Engine events reach the receivers on a later main-queue turn than the call that caused them, never inside `load(_:)`, `goBack()` and the like. WebKit never calls back inside them either.
- Use `precondition`, never `assert`, for these checks, and no `#if DEBUG` anywhere in the package. Xcode builds packages without the app's `DEBUG` in the Test configuration (plan 7.24), so expect the same in `FakeEngine`; whether it also builds them optimised there, which would silence `assert`, was not checked.
- Nothing writes a file except where a section below says so. No download writes a file or touches `~/Downloads`.

### 5.3 Pages: `FakeMacPageFactory` and `FakeMacPage`

**`FakeMacPageFactory: WebMacPageFactory`**

| Member | Fake |
| --- | --- |
| `svgRasterizer` | One `FakeSVGRasterizer`: `png(of:side:dark:)` returns a transparent PNG `side` pixels square drawn with `NSBitmapImageRep`, or nil when `side` is 0 or less. |
| `spaceStores` | One `FakeSpaceStores` (5.4). |
| `ruleListStore()` | One `FakeRuleListStore` (5.4), the same object each time. |
| `makePage(space:source:)` | A new `FakeMacPage`. Records `(space, source, page)` in `made`, in order, with the page held weakly: the factory lives as long as the process, and a strong record would keep every page and its view alive, which the lifetime tests (`PageHiddenTests`, `pageLetGo`) would catch. `.child(request)` keeps the request on the page (`madeFrom`). `.supplied(configuration)` makes an extension page when the configuration is a `FakeExtensionPageConfiguration` whose `isExtensionPage` is true. `.space` and `.tab(_)` make ordinary pages. |
| `downloadStarter(space:)` | A `FakeDownloadStarter` for the space (5.4); `canStartDownloads` always true. |
| `spellingFollows(writing:pages:)` | Records `(writing, pages)` in `spelling`, the pages weakly, as `made`. |

**`FakeMacPage: WebMacPage`**

| Member | Fake |
| --- | --- |
| `contentView` | One `FakePageView`, an `NSView` whose `acceptsFirstResponder` is true, made with the page and the same object for its life. |
| `traits`, `swipe`, `coordinates`, `makePicturePage` | The protocol's defaults: no traits, nil, nil, nil. `Page` then takes its paths for an engine without them. |
| `state` | A stored `PageState`, at first no address, no title, not loading, progress 0, no back or forward, not secure-only. Changed only by the driver and by the default load. |
| `isExtensionPage` | From the source, as above. |
| `scripting` | A `FakePageScripting` (5.4). |
| `channels` | A `FakeMessageChannels` (5.4). |
| `ruleListTarget` | A `FakeRuleListTarget` (5.4). |
| `services` | One `FakePageServices` conforming to all nine services (5.4). |
| `load(_:)`, `loadFile(_:allowingReadAccessTo:)` | Records the request, or the file and its read-access address, in `requests`. When `autoLoads` is true (the default), runs the default load (below) for the address. |
| `goBack()`, `goForward()` | Moves in the fake's history when it can, and runs the default load with the kind `.history`. |
| `reload()`, `reloadFromOrigin()` | Records which, and runs the default load of the address shown with the kind `.reload`. |
| `stopLoading()` | Records it. With a load under way: drops its remaining steps, sets `isLoading` false, reports `navigationFailed` with the kind `.cancelled` (domain `NSURLErrorDomain`, code `NSURLErrorCancelled`), provisional when it had not committed. |
| `connect(...)` | Keeps the receivers as in 5.2 and starts reporting. |
| `stopObserving()` | No more state events; `state` still changes. |
| `hiddenPage(ruleLists:allows:)` | A `FakeHiddenPage` (5.4), recorded in `hiddenPages`. |
| `takeSnapshot(with:completionHandler:)` | On the next turn, a blank `NSImage` the size of `options.rect` or of the view's bounds, or `(nil, error)` when that size is empty. Records the options. |
| `tearDown()` | Drops pending steps and the receivers, removes the view from its superview, sets `isTornDown`. Driver calls afterwards fail a `precondition`. |

**The default load**, one step a main-queue turn:

1. Ask `decideNavigation` with a `WebNavigation` for the request: source origin `.opaque`, both frames main, the kind given (`.other` for a load), no modifiers, button 0, no download asked for, not a redirect, no content-rule redirect. `.cancel` ends it with no event (WebKit starts nothing). `.download` hands a new `FakeDownload` to `navigationBecameDownload` and ends.
2. Set `url`, `isLoading` true, progress 0.1; fire `loadingChanged`, `titleOrAddressChanged`, `progressChanged`; then `navigationStarted(url:)`.
3. Ask `decideResponse` with an `HTTPURLResponse` (status 200, `Content-Type: text/html`) for http and https addresses, a plain `URLResponse` with the type `text/html` otherwise; main frame; can show. `.cancel`: the load ends, so set `isLoading` false and fire `loadingChanged` first (`Page.navigationFailed` ignores an interrupted load and changes nothing itself), then report `navigationFailed` with the kind `.interrupted`, the domain the string `"WebKitErrorDomain"` and the code 102, provisional. `.download`: hand a `FakeDownload` to `navigationBecameDownload`, then end the load the same way. (That WebKit fails the load this way after a response is refused is from its error codes as the adapter sorts them, not from a test here. Check it against `PageResponsePolicyTests` and `PageDownloadAndFileTests` before relying on it.)
4. Commit: push a history entry (not for `.history` or `.reload`), set the title (below), `canGoBack` and `canGoForward`; fire `titleOrAddressChanged`, `backOrForwardChanged`; then `navigationCommitted(url:)`.
5. Finish: progress 1, `isLoading` false; fire `progressChanged`, `loadingChanged`; then `navigationFinished()`.

The title is the text of the first `<title>` of a `data:text/html` address, percent-decoded (what `PageTestCase.address(_:)` makes), or `titles[url]` when a test set one, or nil.

**The driver**, public methods tests use to play the engine. Each checks that the page is connected and not torn down, and acts at once, on the caller's turn:

| Method | What it does |
| --- | --- |
| `navigate(_ navigation: WebNavigation) -> WebNavigationDecision` | Asks the policy, checks one reply came, returns it. Starts nothing. |
| `respond(_ response: WebResponse) -> WebResponseDecision` | The same for a response. |
| `start(_ url: URL)`, `redirect(to url: URL)`, `commit(title: String?)`, `finish()` | Steps 2, a server redirect (`url` changes, `titleOrAddressChanged`, `navigationRedirected`), 4 and 5 of the default load, alone. |
| `fail(_ error: WebLoadError, provisional: Bool)` | `isLoading` false, `loadingChanged`, `navigationFailed`. |
| `endProcess()` | Clears `url`, title and loading; fires the state events; `contentProcessEnded()`. |
| `becomeDownload(_ download: FakeDownload)` | `navigationBecameDownload`. |
| `requestChild(_ request: FakeChildRequest) -> (any WebEngineSurface)?` | Calls `childRequested`. When a surface comes back, checks that its view is the `contentView` of a page the factory made from this very request in this call, as WebKit requires of the web view it is handed. |
| `deliver(_ message: WebMessage)`, `deliver(_ message: WebMessage, reply: @escaping (WebJSON?) -> Void)` | Calls the handler opened for the message's channel and world; fails a `precondition` when none is open (a page script would get a TypeError). |
| `alert(_:host:)`, `confirm(_:host:)`, `prompt(_:defaultText:host:)`, `openFiles(allowsMultiple:allowsDirectories:)` | Ask the presenter; each returns an object the test reads the answer from once `done` was called, and checks `done` was called at most once. |
| `closeFromScript()`, `openContextMenu(link: URL?)` | `closeRequested()`, `contextMenuOpening(link:)`. |
| `setMagnification(_:)`, `setCapturing(_:)`, `findableText` | Values the services answer from. |

**History.** A list of `FakeHistoryEntry` objects (address and title) and an index. `services.currentEntry` is the entry shown, the same object while it is held. `restorationData` reads `Data`: a property list of a format marker (`"engine": "fake"`), the entries' addresses and titles, and the index. It must be `Data`, because `Pages` hands it to `Snapshots.save(state:url:using:)`, which keeps only `Data` (`Shared/Stores.swift`); anything else would be lost when a tab is frozen. Set, it decodes that format, replaces the list and loads the entry shown; any other value is ignored, as `WebRestoration` allows ("to give back to a page of the same engine").

### 5.4 Services, scripts, rules, downloads, stores, hidden pages

| Type | Contract | Fake |
| --- | --- | --- |
| `FakePageServices` | `WebFind` | `found` hears, on the next turn, whether `findableText` contains the text (case as asked); false for empty text. Records each call. |
| | `WebZoom` | `pageZoom` stored, 1 at first; `magnification` from the driver, 1 at first. |
| | `WebMediaCapture` | `isCapturing` from the driver, false at first. |
| | `WebUserAgent` | `customUserAgent` stored, nil at first. |
| | `WebPrinting` | `NSPrintOperation(view: contentView, printInfo: info)`. |
| | `WebDeveloperTools` | `show(_:)` records the tool and returns false. |
| | `WebBackForward`, `WebRestoration` | As in "History" above. |
| | `WebDownloadStarting` | The session is the page's `contentView`, as it is the web view in WebKit's `WebKitPageServices`. The services hold it weakly; `canStartDownloads` is true while it lives, which tearing the page down does not end: letting go of the page and of every kept starter does. `keepingSessionAlive()` returns a starter that holds the view strongly (itself when already kept). `startDownload` and `resumeDownload` hand a new `FakeDownload` to the handler on the next turn while the session lives, and record the request or the data. `PageHiddenTests.testAKeptSessionOutlivesItsPageAndOneNotKeptDoesNot` is the rule. |
| `FakePageScripting` | `WebPageScripting` | Records user scripts (source, time, main frame only, world), filter scripts and every evaluation and call (source or body, arguments, world). Answers each with `answers[source]` when set, else `.success(NSNull())`, on the next turn; the `async` call returns the same. `removeAllUserScripts` empties the record and counts the call. |
| `FakeMessageChannels` | `WebMessageChannels` | `bridgeScript` is a fixed comment line, `"// fake egluBridge\n"`. `open` keeps each handler by channel and world; opening the same pair twice fails a `precondition`. |
| `FakeRuleList` | `WebRuleList` | Its identifier and the rules' text. |
| `FakeRuleListStore` | `WebRuleListStore` | Lists by identifier, in memory. `compile` makes and keeps one; `lookUp` answers the kept one or nil, both on the next turn. `removeOld(withPrefix:keeping:)` removes the others with the prefix and records the call. |
| `FakeRuleListTarget` | `WebRuleListTarget` | Records each `replaceAll` with its identifiers, in order. |
| `FakeDownload` | `WebDownload` | Its request and address; `progress` a `Progress` of one unit; `delegate` weak. `cancel` answers nil on the next turn. Driver: `askDestination(response:filename:)` asks the delegate and returns what it said without creating the file; `finishDownload()`, `failDownload(_:resumeData:)`. |
| `FakeDownloadStarter` | `WebDownloadStarting` | As the page's, for a space; records the space. |
| `FakeSpaceStores` | `WebSpaceStores` | A set of spaces whose store is made, filled by `makePage`. `isMade`, `forget` (records and removes), `prepareForRemoval` (counts), `remove` (records, then `removed(true)` on the next turn). Nothing on disk. |
| `FakeHiddenPage` | `WebHiddenPage` | `begin` answers false at once when `allows(url)` is false. Otherwise it races `beginAnswer` (true at first, given on the next turn; nil never answers) against `limit`, and answers once: false when the limit passes first, so a limit of zero always answers false (`PageHiddenTests` expects that). `callInAppWorld` records the body and arguments and returns `appWorldAnswer`. `stop()` makes a waiting `begin` answer false. Keeps the rule lists it was given. |
| `FakeChildRequest` | `WebChildRequest` | A `navigation` and `features` given by the test. |
| `FakeExtensionPageConfiguration` | `ExtensionPageConfiguration` | `isExtensionPage`. |

### 5.5 The extension runtime: `FakeExtensionRuntime`

One `public final class` conforming to `WebExtensionRuntime`, which is every slice below. Its `init` takes `host: any ExtensionRuntimeHost` (the app's, as WebKit's runtime is given; the fake uses only its evidence callback), `storage: any WebExtensionStorage`, `browserAnswers: FakeBrowserAnswers`, `scriptAnswers: FakeScriptAnswers`, `refused: @escaping (WebExtensionInstallRefusal) -> any Error` and `unanswered: @escaping (String) -> any Error`, as WebKit's runtime is given the app's error types. "No engine" below means `refused(.notChecked(FakeExtensionRuntime.noEngine))`, with `noEngine` a localised sentence such as "This build of eGlu has no extension engine."

Nothing is ever loaded, so every query about a loaded extension answers that there is none.

| Slice | Members and answers |
| --- | --- |
| `WebExtensionStorage` | Forwards to `storage` (`prepare` is `nonisolated`). |
| `WebExtensionMetadata` | `icon(of:)`, `icon(of:in:)`, `optionsPageURL`, `newTabPageURL`, `sidePanelDefaultPath`: nil. `hasNewTabPage`, `isNewTabPage`: false. `forgetIcon`: nothing. `manifestFacts`: WebKit's rule, which needs no engine: cookies offered when the optional permissions have `cookies`; native required when the permissions have `nativeMessaging`; native optional when only the optional ones do. `packageName(at:fallback:)` (`nonisolated`): the fallback, no facts. |
| `WebExtensionCompatibility` | `readCode`, `measureTable`, `checkCopy`, `forgetCheck`: nothing, and no evidence is reported. `checkStamp(_:)`: the version given. `currentFailures`: empty. |
| `WebExtensionControllers` | `isLoaded`: false. `extensionID(for:)`: nil. `load`: false. `unload`, `setSiteAccess`: nothing. `setReadsCookies`: calls `changed` for no space. |
| `WebExtensionWorkers` | `forgetWorkersIfChanged`, `workersChanged`: nothing. `revive`, `restart`: false. |
| `WebExtensionEvidenceRuntime` | `evidence`, `lacking`, `recorded`: stored, empty at first. `recordOnce`: WebKit's rule (at most 500 a key; the text's `fingerprint` inserted, true when new). `readRecords`, `pruneRecords`, `saveRecords`, `note`: nothing. `records(of:)`: empty. `update` and `record`: WebKit's rule (`WebKitExtensionEvidence`). `update` does nothing when `evidence[space][id]` is absent; otherwise it applies the change and records the result. `record` stores the value there, then calls `host.extensionEvidenceChanged(seen, id, in: space)` before returning, which is how the app keeps its warnings and unread marks (`Mac/Sources/ExtensionEvidenceHost.swift`). |
| `WebExtensionCleanup` | `remove`, `removePackages`, `forgetLeftOver`, `removeSpace`, `closePages`: nothing; nothing is deleted. `forget`: a finished `Task`. `cleared`: true. |
| `WebExtensionInstallExecution` | `download`, `readArchive`, `describeOffer`, `verifyUpdate`, `keepArchive`, `trial`, `snapshot`, `zipped`: throw "no engine". `unload`, `removeOtherVersions`: nothing (WebKit's `removeOtherVersions` deletes folders; the fake must not). `loadReplacement`: calls `completion(item.spaces.isEmpty)` once; returns the result of `.finished`, or false for `.restore`. `loadNew`: calls `didLoad()`, returns `item.spaces.isEmpty`. `sha256`: `FakeExtensionRuntime.checksum`. |
| `WebExtensionRuntimeAnswers` | `releaseKeepAwake`: nothing. |
| `WebExtensionScriptAnswers` | Forwards to `scriptAnswers`. |
| `WebExtensionBrowserAnswers` | Forwards to `browserAnswers`. |
| `WebExtensionPermissions` | `permissionPresses`: reads and writes `FakeExtensionRuntime.pressed`, one static dictionary for the process, as WebKit's is. |
| `WebExtensionAdapters` | `addressChanged`, `loadingChanged`: nothing. `popupShows`: false. |
| `WebExtensionDiagnostics` | `diagnosticTableLines`, `diagnosticLines`: empty. `diagnosticPageLine`: `"page \(number): fake engine"`. Static `words` and `note`: WebKit's, which need no engine (`words`: empty unless enabled, else ": " and the first 240 characters; `note`: appends the line to `outputPath + ".steps"` when a path is given; only the extension report's debug switch sets one). |
| `WebExtensionDispatch` | `keepsCookiesBack`, `isLoaded`, `asks`, `webAccessible`: false. `openTab`, `permissionIcon`, both `commands`, `action`, `sidePanelSource`: nil. `externalListings`: empty. `displayCaptureDecision`: 0 (none, as WebKit's for a view that records nothing). `errorRecovery`: no installation, not restarting. `startTabs`, `openOptions`, `perform`, `applyKeys`, `run` (none of its closures is called), `forgetCapture`, `releaseCapture`, `watchCapture`, `forgetRecords`: nothing. |

Static helpers on `FakeExtensionRuntime`, all without an engine, copied from WebKit's plugin so stored values compare the same:

- `fingerprint(_:)`: FNV-1a over the UTF-8 bytes, 64 bits, offset `0xCBF2_9CE4_8422_2325`, prime `0x0000_0100_0000_01B3`, written in base 36 (`WebKitExtensionEvidence.fingerprint`).
- `checksum(_:)`: SHA-256 in lowercase hex, through CryptoKit (`WebKitExtensionInstallExecution.checksum`).
- `words(_:enabled:)`, `note(_:outputPath:)`: as above (`WebKitExtensionDiagnostics`).
- `pressed`: `[String: Date]`, empty at first.

These four are product rules that sit in the WebKit plugin today. Moving them to `PadCore` or `WebEngineAppKit`, so both plugins share one copy, is a separate change the owner may prefer to copying.

### 5.6 Storage, answers and the native transport

| Type | Contract | Fake |
| --- | --- | --- |
| `FakeExtensionStorage` | `WebExtensionStorage`, `Sendable` | A nonisolated `public final class` with one `let`, the environment closure, and a nonisolated `public init(environment: @escaping @MainActor @Sendable () -> WebExtensionStorageEnvironment)`, as WebKit's `ExtensionStorage`; its three path members are `@MainActor`, as the protocol declares. `package(id, version)`: `root/id/version.zip`. `prepared(id, version)`: `root/id/version`. `recordsFile`: `root/records.json`. `prepare` (`nonisolated`): throws `CocoaError(.featureUnsupported)`. Nothing is written: installs fail before any of these is used. |
| `FakeBrowserAnswers` | `WebExtensionBrowserAnswers` | `popupPaths` stored, empty. `tab(at:in:)`, `favIconURL(for:)`: nil. |
| `FakeScriptAnswers` | `WebExtensionScriptAnswers` | `init(unanswered:)`. `kept(name, id, space)`: a path under the temporary folder, `eglu-fake/<space>/<id>/<name>`, never written. `scriptingFile`, `userScriptFile`, `changeUserScripts`, `setUserScriptWorld`: throw `unanswered("No extension engine.")`. `userScripts`: an empty array. `userScriptWorlds`: empty. `pruneUserScripts`: nothing. |
| `FakeNativeTransport` | `WebExtensionNativeTransport` | Makes a `FakeNativeConnection`. |
| `FakeNativeConnection` | `WebNativeConnection` | `start()` throws `CocoaError(.featureUnsupported)`; `send` throws the same; `stop()` nothing; `onMessage` and `onEnd` stored and never called. No process is started. |

## 6. The composition file

`Mac/FakeEngine/EngineComposition.swift` answers every member `Mac/Sources/EngineComposition.swift` has, with the same names and types, so no call site changes. The app's calls of each are listed in section 9. This is the whole file, as far as reading the code can settle it; the compiler has the last word on isolation details.

```swift
import AppKit
import FakeMacEngine
import PadCore
import WebEngineAppKit

/// The fake engine build's engine and extension runtime
/// (Docs/FakeEngineBuild.md): the members of Mac/Sources/EngineComposition.swift,
/// answered without WebKit.
@MainActor
enum EngineComposition {
    static func makePageEngine() -> any MacPageEngine {
        AppPageEngine(factory: pageFactory)
    }

    static let pageFactory = FakeMacPageFactory()

    /// No page records the screen.
    static let pageCapture = WebExtensionPageCapture(screen: { _ in false }, release: { _ in })

    static func makeExtensionRuntime() -> any WebExtensionRuntime {
        FakeExtensionRuntime(host: ExtensionHost.shared, storage: storage, browserAnswers: concreteBrowserAnswers,
                             scriptAnswers: concreteScriptAnswers,
                             refused: { Extensions.Refused($0) },
                             unanswered: { Extensions.Unanswered(why: $0) })
    }

    nonisolated static let storage: any WebExtensionStorage = FakeExtensionStorage(environment: {
        ExtensionHost.shared.extensionStorageEnvironment
    })
    private static let concreteBrowserAnswers = FakeBrowserAnswers()
    private static let concreteScriptAnswers = FakeScriptAnswers(unanswered: { Extensions.Unanswered(why: $0) })
    static var browserAnswers: any WebExtensionBrowserAnswers { concreteBrowserAnswers }
    static var scriptAnswers: any WebExtensionScriptAnswers { concreteScriptAnswers }
    static var pressed: [String: Date] {
        get { FakeExtensionRuntime.pressed }
        set { FakeExtensionRuntime.pressed = newValue }
    }

    // The WebKit plugin's values, kept so the app's rules read the same.
    static let scheme = "chrome-extension"
    static let workersKey = "extensionWorkers"
    static let shimApplication = "eglu"
    static let largestFolder = 512 * 1024 * 1024
    static let mostFiles = 65_000
    static let authNotLoaded = "Authorization page could not be loaded."

    static func registerScheme() {}
    static func workersChanged() {}
    static func fingerprint(_ text: String) -> String { FakeExtensionRuntime.fingerprint(text) }
    static func zipped(_ folder: URL) async throws -> Data {
        throw Extensions.Refused.notChecked(FakeExtensionRuntime.noEngine)
    }
    static func sha256(_ data: Data) -> String { FakeExtensionRuntime.checksum(data) }
    static func words(_ text: String?, enabled: Bool) -> String { FakeExtensionRuntime.words(text, enabled: enabled) }
    static func note(_ line: String, outputPath: String?) { FakeExtensionRuntime.note(line, outputPath: outputPath) }
    static func appName(ofHost host: String) -> String { host }
    static func name(in archive: Data, manifest: ExtensionManifest, fallback: String) -> String { fallback }
    static func icon(in archive: Data, manifest: ExtensionManifest) -> NSImage? { nil }
    static func authOwner(of url: URL?) -> String? { nil }

    private static let nativeTransport: any WebExtensionNativeTransport = FakeNativeTransport()
    static func nativeConnection(program: URL, origin: String) -> any WebNativeConnection {
        nativeTransport.nativeConnection(program: program, origin: origin)
    }

    static func sweepStores() { Stores.sweep(in: pageFactory.spaceStores) }
}
```

Why some members are as they are:

- `pageFactory` stays a stored `FakeMacPageFactory` (not `any WebMacPageFactory`) so the fake build's tests can read its records (`made`, `spelling`) without a cast.
- `makeExtensionRuntime()` makes no page factory and touches neither `Session.shared` nor `ContentBlocker.shared`: the real one's closures exist to keep first uses in their old order (`WebEngine.md`, "Launch order"), and the fake has nothing to defer.
- `scheme` keeps the WebKit plugin's value: `Extensions.scheme` sorts addresses in the app, and the fake must not change which addresses count as extension pages.
- `appName(ofHost:)` returns the host as it is. WebKit's names a few password managers. At 5228f9f9 no file in `Mac/` calls the app's `Extensions.appName(ofHost:)`; WebKit's runtime calls its own copy, and the fake runtime has nothing to name.
- `authNotLoaded` keeps WebKit's text: it is the error an extension's sign-in call gets (`Mac/Sources/ExtensionAuth.swift`).

## 7. Tests

### 7.1 `Tests/FakeEngine/FakePageTestSupport.swift`

Defines `class PageTestCase: XCTestCase`, the same name as `Tests/MacPage/PageTestSupport.swift`'s, so shared files compile in either target. It imports `XCTest`, `FakeMacEngine`, `WebEngineCore` and `@testable import eGluMac`, never WebKit.

| Member | As in the WebKit support | Fake build's version |
| --- | --- | --- |
| `setUp`, `tearDown` | Wait for start-up, `Session.shared.resetForTests()`, tear down pages made, close tabs opened | The same, word for word. |
| `waitForStartUp()` | `LaunchState.shared.ready && Session.shared.started` | The same. |
| `makePage(tab:space:)` | A page in a store that keeps nothing | `Page(tab:space:enginePage:)` with `EngineComposition.pageFactory.makePage(space: space, source: .space)`. No `configuration:` argument. |
| `openTab()` | A tab in the workspace's first space, adopted as a child | The same, with `session.pages.adopt(tab:space:child:)` given a `FakeChildRequest`. |
| `livePage(_:)`, `address(_:)` | | The same. |
| `load(_:_:)`, `waitForPage(_:titled:)` | | The same; the fake's default load gives the title. |
| `waitUntil(_:_:timeout:condition:)` | Watches the WebKit view's values | The condition takes the `Page`; looks again every 10 ms on the main actor, up to the timeout (10 s). |
| `engine(_ page: Page) -> FakeMacPage` | | `page.enginePage as! FakeMacPage`. Allowed: the boundary covers `Mac/` and `Shared/`, not `Tests/`. |
| `Page.view` | `PageWebKitForTests.swift`: the `WebKitPageView` | An extension in this file: `var view: NSView { enginePage.contentView }`. Shared files that use the view only as an `NSView` then compile unchanged; any that read WebKit's values from it do not, which is the point. |

### 7.2 Files shared unchanged

- `Tests/MacPage/StartUpTests.swift` (4 tests): hosting, data folder, identifier suffix, no window. It passes in the fake build only with section 4's identifier and data folder.
- `Tests/MacPage/PageWritingTests.swift` (7 tests): uses `makePage`, `load` and the plugins only. Expected to compile and pass as it is; not tried.
- `Tests/MacPage/PageSurfaceTests.swift` (5 tests): uses `page.view` only for its superview, frame, window and first responder, so it compiles against 7.1's `Page.view`. Expected to pass; not tried.

No other hosted test file compiles without WebKit: each reads WebKit's own values through `Page.view` (title, back list and the like), or uses `Page.world`, `PageView` or `PageWebKitForTests`, directly or through `waitUntil`.

### 7.3 New interface tests, against the fake

The hosted tests check two things at once: what `Page`, `Pages` and `Session` decide, and that WebKit reports what they need. The fake build repeats the first half. The split below is from the tests' names and files; confirm each when writing it.

| Hosted file (tests) | Repeat with the fake | Stays WebKit's |
| --- | --- | --- |
| `PageEngineTests` (8) | A tab's page asked for once; a moved tab's again; adopt passes the child request; a supplied configuration keeps its extension flag (`FakeExtensionPageConfiguration`); tab and space sources make ordinary pages; Session uses the composition's factory | The space's WebKit configuration; adopt passing a WebKit configuration |
| `PageStateTests` (6) | All six, through `start`, `commit`, `finish` and history | |
| `PageBackTests` (6) | All six: going back past a replaced page is the app's rule | |
| `PageLifecycleTests` (16) | The twelve on what the page shows as loads start, redirect, commit, fail and the content process ends, and when it reloads by itself | The four "real" ones, through WebKit's adapter |
| `PageNavigationPolicyTests` (10) | New-tab clicks taken or allowed, every navigation after one, plain navigations, subframes, no target frame, a download answered first, a link clicked in the page | What the adapter itself decides; a link into a frame |
| `PageResponsePolicyTests` (11) | Answered once before returning, the shown kind and status, the status waiting for the commit, attachments and what cannot be shown as downloads, subframes, non-HTTP, any letter case, a host not asked again | A data page and a frame loaded through WebKit |
| `PageChildTests` (7) | The host asked once, the size given, the host's child is the window shown (`requestChild`'s check), marked opened, no child rejects, Pages adopts the child, another app's link never reaches the host | |
| `PageChannelTests` (14) | Password fields heard, writing's card open and closed, lints answered later, the measuring tool's channel, a body that is no object, a frame's messages: all by `deliver` | The bridge and channels in the app's world, the page's world seeing none, an unopened channel's TypeError |
| `PageContentRulesTests` (4) | A page with no lists from a blocker with none; the hidden page given its lists; the engine, the blocker and a page sharing one store | A list hiding an element on the next load |
| `PageDownloadAndFileTests` (5) | Read access no wider than the file (`loadFile`'s record); a download taken over by Downloads; only a page that showed nothing closing for its download; a save answer becoming the tab's download | The adapter being the whole navigation delegate |
| `PageHiddenTests` (8) | All eight, with `FakeHiddenPage`, the starters and the rasterizer | |
| `PageServicesTests` (7) | Empty text answering false at once, zoom's steps and typed zoom, magnification being the engine's, no camera or microphone, the phone's user agent and back | Find finding the words on a real page |
| `PageSharedTests` (8) | Address and title from the state; a call in the app's world; filter scripts in the main frame only and none for a site with none; the space stores and Stores asking the contract; spelling following writing | Handoff's article read by JavaScript |
| `PageStorageTests` (6) | History keeping the engine's entries, a web app's pages a visit each, restoration bringing a page back, a frozen tab's back list, a tab's page in its space's store, erasing a fresh space's store | |
| `PageSurfaceTests` (5) | Shared unchanged (7.2) | |
| `PageUIDelegateTests` (6) | An alert held then answered, a confirm and a prompt cancelled, window close reaching its host, the context menu's link | The view's UI delegate being the adapter |
| `PageCommandTests` (2) | Stop ending a load under way; reload from origin recorded | That WebKit loads the same document again |
| `PageSmokeTests` (1) | Two pages loaded | |

Also new, with no hosted counterpart:

- Launch: `Session.shared.engine` is `EngineComposition.makePageEngine()`'s kind (`AppPageEngine` over `FakeMacPageFactory`); `Extensions.shared.runtime` is a `FakeExtensionRuntime`.
- No extensions: with an empty catalog the runtime reports nothing loaded, no commands, no actions; an install from a file fails with the "no engine" refusal's words; nothing is written under the test run's data folder by trying. Do not call `Extensions.shared.start` in these tests: it starts the store button and update checks, which the hosted path leaves off.
- Teardown order: `Page.tearDown()` stops observation, removes user scripts, removes the rule lists from the target and tears the engine page down, in that order (`Mac/Sources/Page.swift`, `tearDown`).

### 7.4 The package's own tests

`FakeEngine/Tests/FakeMacEngineTests`, run with `swift test` in `FakeEngine/`, three runs in a row. One test per rule in 5.2: receivers weak (a released receiver hears nothing and the page does not keep it); the reply count (a failed `precondition` stops the whole test run, so put the counting in a small function that returns the count, test that, and keep the `precondition` on its result in the driver); events after `load(_:)` returns, never inside it; state set before its event; the child-made-from-this-request check; the default load's order for `.allow`, `.cancel` and `.download`; history and restoration round trip; rule store compile and look up; hidden page `allows`, `limit` and `stop`; every extension slice's absent answers; `checksum` and `fingerprint` equal to known values; no file written (a temporary folder stays empty).

## 8. Checking that no WebKit is linked

After building the scheme:

```bash
xcodebuild -project eGlu.xcodeproj -scheme "eGlu Mac Fake Engine" -configuration FakeEngine -destination 'platform=macOS' -derivedDataPath <scratch folder> build-for-testing
```

```bash
otool -L "<scratch folder>/Build/Products/FakeEngine/eGluFakeEngine.app/Contents/MacOS/eGluFakeEngine" | grep -i webkit
```

```bash
nm -a "<scratch folder>/Build/Products/FakeEngine/eGluFakeEngine.app/Contents/MacOS/eGluFakeEngine" | grep -E 'WebKitMacPlugin|WebKitExtensions|WebKitSupport|_OBJC_CLASS_\$_WK'
```

Both should print nothing. A match from a `PadCore` or app name that merely contains "WebKit" is not a link; look at what matched. Also list `Contents/Frameworks`: nothing from WebKit or `WebKitEngine`. AppKit may load WebKit on its own for some services while the app runs; that is not this build linking it, and is not a failure (speculation: not observed here).

## 9. What the app calls on the composition

Every member the fake must answer, and who calls it, at commit 5228f9f9:

| Member | Called from |
| --- | --- |
| `makePageEngine()` | `Session.init`; the hosted `PageEngineTests`, `PageStorageTests` |
| `makeExtensionRuntime()` | `Extensions.runtime` |
| `pageFactory` | The composition itself; the hosted tests (`PageEngineTests`, `PageWebKitForTests`) |
| `pageCapture` | `Page.extensionIsCapturing`, `Page.releaseExtensionCapture` |
| `storage` | `Extensions.storage` |
| `scriptAnswers`, `browserAnswers`, `pressed`, `appName(ofHost:)` | `Mac/Sources/ExtensionAnswers.swift` |
| `scheme`, `registerScheme()`, `workersKey`, `workersChanged()`, `fingerprint`, `largestFolder`, `mostFiles`, `zipped`, `sha256`, `shimApplication`, `words`, `note` | `Mac/Sources/Extensions.swift` |
| `name(in:manifest:fallback:)`, `icon(in:manifest:)` | `Mac/Sources/ExtensionAsk.swift` |
| `authNotLoaded`, `authOwner(of:)` | `Mac/Sources/ExtensionAuth.swift` |
| `nativeConnection(program:origin:)` | `Mac/Sources/ExtensionNativeConnection.swift` |
| `sweepStores()` | `Mac/Sources/ExtensionCleanupHost.swift` |

To list them again at a later commit: `grep -rn "EngineComposition\." Mac Shared Tests/MacPage`.

## 10. Running the tests safely

The same rules as the page tests, with the fake's names:

- Only through the scheme, which sets `EGLU_DATA_ROOT`; the app refuses to host tests without it and the `.pagetests` identifier.
- That refusal checks only that a root is given and the identifier's suffix (`Mac/Sources/EgluApp.swift`, `Session.dataRootOverride`), not where the root is: any absolute path is taken, and `StartUpTests` sees a wrong one only after start-up has opened it. The WebKit page tests rest on the same check. So keep both `EGLU_DATA_ROOT` values (the target's and the scheme's) a folder under `$(OBJROOT)`. Making the app refuse a root inside `~/Library/Application Support/Safience` or `~/Downloads` before start-up would be a change to the app, separate from this build.
- While the tests run, sample `lsof` on the test host and check nothing under `~/Library/Application Support/Safience` is open.
- Afterwards remove the test app's preferences (`defaults delete net.taehee.safience.fakeengine.pagetests`, then the plist in `~/Library/Preferences`), its `Caches`, `HTTPStorages`, `Saved Application State` and, if one appeared, its `WebKit` folder under `~/Library` for that identifier. A `WebKit` folder should not appear at all; if it does, find out why.
- Never drive windows by coordinates. Never stop a process the run did not start.

## 11. Order of work

Each step one commit, all checks of section 1 run at each, as for the plan's steps:

1. The boundary check for two composition files and the fake package's folder, with its tests (4.3).
2. The fake package's page side and its tests (5.1 to 5.4, 7.4).
3. The extension runtime, storage, answers and native transport, with their tests (5.5, 5.6).
4. The composition file and the project (6, 4.1); regenerate; build; the link checks (8).
5. The test target, its support file and the three shared files (7.1, 7.2); run.
6. The interface tests of 7.3, a few hosted files at a time.
7. The plan's 7.x section, `WebEngine.md` section 6, the inventory regenerated. Whether the fake scheme joins "Every step runs" is the owner's choice.

## 12. Traps

- XcodeGen joins lists: a target cannot remove a template's source. That is why `MacInterface` excludes both composition files and each Mac target adds its own.
- The module file collision of section 2 is silent: a fake build in Debug or Test would break the WebKit tests' build only later, and only sometimes.
- `WebMacPageSource.supplied` reaches the fake factory only from tests: the fake runtime makes no extension pages.
- `WebMacPageSource` is not `Sendable` (it carries `any WebChildRequest`), so Swift 6 refuses it in a `static let`; the scratch probe hit this. Keep sources in main-actor instances, such as the factory's `made`.
- `WebExtensionDiagnostics` has two `static` requirements; the runtime type implements them itself.
- `WebExtensionStorage` and `WebExtensionMetadata` are `Sendable` with one `nonisolated` member each; in Swift 6 mode the fake's stored state must allow that.
- `Session` is one per process and opens the workspace. Tests give pages of their own to `Pages`, never make a second `Session` (`Mac/Sources/Session.swift`, `init`).
- Do not touch `ContentBlocker.shared` or `SiteIcons.shared` while making the engine: both ask `Session.shared.engine` for their parts.
- The hosted test path skips the workspace services, so sweeping, content blocking and extensions do not start in the fake build's tests either. Test them by calling the engine's members, not by launching the services.
