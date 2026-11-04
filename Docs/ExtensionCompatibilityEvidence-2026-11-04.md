# Extension compatibility changes

Date: 4 November 2026. Runtime: macOS 27.0.1. Builds use the installed Xcode toolchain and SDK. Changes are local and have not been published.

## 1Password

- Normalize extension schemes and host names before looking up their configurations or loading their pages. The resource path, query, and fragment keep their original case and encoding.
- Reserve extension URL schemes inside the browser even when the extension is missing or disabled. They never reach macOS's external app URL handler.
- `tabs.update` replaces the web view within the same tab when moving between a website and an extension page. It uses the existing page replacement mechanism.
- Treat a refused native host as a desktop app connection failure. It is not evidence that `runtime.connectNative` is unavailable. Successful host responses clear the connection warning.
- Explain missing registrations, missing executables, and refused connections with recovery instructions. The 1Password warning also describes signing in to the extension separately.
- Trial contexts deliberately cannot create tabs or windows. Their resulting errors no longer claim that the real browser cannot manage tabs.

The installed 1Password package, version 8.12.44.33, was tested in a temporary app with a separate bundle identifier and data directory. Visual inspection confirmed that the actual 1Password tutorial loaded inside the browser at its extension URL. The extension detail showed a plain language desktop connection warning. No account or vault data was supplied.

At the initial test, the local Chrome native host registration pointed to `/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport`, which was absent. The follow-up repair below restores it. 1Password requires the browser to be trusted in its desktop app; see [1Password's additional browser instructions](https://support.1password.com/additional-browsers/).

### Desktop helper repair

- Restored 1Password 8.12.44 from its [official Mac download](https://1password.com/downloads/mac/). Its signature verifies as AgileBits Inc., team `2BUA8C4S2C`; Gatekeeper accepts its notarized Developer ID signature.
- Confirmed that the real `1Password-BrowserSupport` executable now exists at the registered location.
- The installer initially removed the stale Chrome host manifest. Added a browser-owned registration at `~/Library/Application Support/Safience/NativeMessagingHosts/com.1password.1password.json`, which eGlu already reads. It allows only the installed 1Password extension origin, `chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/`. After desktop integration was enabled, 1Password also recreated its Chrome registrations.
- The installed `/Applications/eGlu.app` has a valid, stapled Developer ID signature. No browser signature verification, vault protection, or desktop browser approval was bypassed.
- After the user unlocked 1Password and approved `/Applications/eGlu.app`, verified its code signing trust entry and the live native connection. The installed eGlu process launched `1Password-BrowserSupport` as its own child. 1Password's browser helper log records the extension connection, three validated requests, and three messages forwarded to its connected desktop app. The connection remained open for over two minutes without an extension disconnect.
- This verifies native messaging with the installed browser and the real desktop app. Account autofill and vault contents were not inspected. The installed browser has not been replaced with the local compatibility build.

Repair record: [installation and registration checks](Validation/ExtensionCompatibility-2026-11-04/onepassword-helper-repair.json).

### Autofill and Apple Account passkeys

- The user reported that selecting 1Password's suggestion on `account.apple.com` left the email field empty. The sign-in page was a full tab with an email step followed by a password step.
- After reloading that tab following the desktop connection repair, the user confirmed that autofill worked. This is user verification of autofill, not verification of a completed Apple Account sign-in. No credentials or vault contents were inspected.
- 1Password documents that Apple Account passkeys cannot be supplied by third-party password managers: [1Password staff explanation](https://www.1password.community/1password-at-home-31/saving-apple-id-as-passkey-1704). This is an Apple Account restriction, not evidence that all 1Password passkeys or Chromium authentication APIs are unavailable.
- Added English and Korean help in 1Password's toolbar detail and Settings detail: reload the page if autofill stops after connecting the desktop app, and use Apple's passkey option or a password for Apple Account sign-in. These are help notes, separate from the extension's API compatibility verdict.
- A separate WebKit runtime test exposed `navigator.credentials`, `PublicKeyCredential`, conditional mediation, and client capabilities. The installed 1Password MAIN-world script installed its credential hook in that test. A successful account passkey assertion was not performed.
- A synthetic cross-origin iframe test using the actual 1Password content script successfully filled dummy data. Exact startup storage calls and packaged `build.info` fetches, with and without the extension's custom request header, also passed. These checks do not substitute for account sign-in tests.

## Added native API coverage

These are partial implementations of 14 namespaces, not a complete Chromium runtime. Existing WebKit implementations take precedence.

| Namespace | Implemented operations | Limits |
| --- | --- | --- |
| `bookmarks` | Read, search, create, update, move, remove, remove trees; mutation events | One space's bookmarks; fixed roots; no creation date or import events |
| `history` | Search, visits, add URLs, delete URLs, ranges and all history; visit events | One space; existing sign-in and credential exclusions; coarse transition metadata |
| `downloads` | Real GET/POST downloads, progress, search, cancel, resume from server data, reveal, file icons, file removal, activity removal and lifecycle events | One space; no pause, automatic file opening, subfolder selection, forced overwriting, or hidden controls; some query filters are unsupported |
| `notifications` | macOS text/list notifications, update, clear, permission checks, listing, clicks, buttons and explicit close events | OS permission required; image/progress templates and some notification events are unavailable; notification expiry cannot be observed reliably |
| `sessions` | Read and restore recently closed tabs; change events | One space; no other-device sessions or full Chrome window/session metadata |
| `topSites` | Most visited pages | One space's retained history |
| `search` | Search the configured engine in the current tab, a new tab, or a new window | Numeric tab targeting is unsupported; windows follow the existing space model |
| `browsingData` | Capability settings and clearing caches, local storage, IndexedDB, service workers, history and finished download activity | One space; all time; protected sign-in data remains excluded; no cookie/password removal or origin filters |
| `fontSettings` | List installed font families | Cannot change website fonts |
| `system.cpu` | Processor description and cumulative usage | Read only; feature flags are not enumerated |
| `system.memory` | Total and available memory | Read only |
| `system.display` | Display bounds, work areas, names, DPI and primary display | Read only; no layout changes or display events |
| `system.storage` | Mounted volume names, types and capacities | Read only; no eject or capacity change events |
| `tts` | Installed voices, speech, queueing, stop, pause, resume, status and basic speech events | macOS voices; native rate/pitch ranges; no extension-provided speech engine |

Native events use ports scoped to an extension, space, and listening page. Background subscriptions survive worker suspension and wake the worker when needed. A popup's subscriptions do not replace the background's. Queues are bounded and removed when the extension unloads.

Download identifiers persist across launches. Older saved activity remains readable. Downloads use the space's website store, and redirects from extension downloads cannot reach protected sign-in hosts. Removing activity retains files; removing a file is a separate API operation.

## Unsupported capabilities

Known platform limits use fixed English and Korean descriptions. Examples include individual tab recording, Chrome's debugging protocol, MHTML capture, Google extension push messaging, Chrome's signed-in account token service, ChromeOS features, and unavailable browser settings. Calls return rejected promises or callback `runtime.lastError`. The compatibility table lists supported members of partial namespaces explicitly and does not claim unknown members work.

Chrome reference: [API documentation](https://developer.chrome.com/docs/extensions/reference/api), [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [downloads](https://developer.chrome.com/docs/extensions/reference/api/downloads), [notifications](https://developer.chrome.com/docs/extensions/reference/api/notifications).

## Validation

- Full PadCore suite: 711 XCTest tests and 175 Swift Testing tests passed. Later focused extension/download checks passed, including an additional legacy download decoding test.
- JavaScript shim suite: 223 assertions passed.
- macOS build passed. iOS Simulator SDK build passed for the shared code changes.
- The synthetic runtime fixture passed 30 checks in each of two spaces, 60 live assertions in total. It exercises real bookmark/history operations, downloaded file bytes and removal, live native events, system information, font and voice enumeration, notification permission/error behavior, protected data refusal, tab conversion, and browsing data removal. Both results pages displayed `API checks: 30/30 passed`.
- Signed 1Password desktop integration was verified separately with the installed browser after the helper repair and user approval, as described above.
- The user confirmed Apple Account autofill after a page reload. Account sign-in completion and general 1Password passkey authentication remain unverified.
- Notification delivery authorization, visible notification actions, actual speech playback, worker suspension recovery, and authenticated downloads were not exercised.
- New and changed warning strings were checked in English and Korean. The repository-wide localization script still reports existing untranslated entries outside this change.

Reproduce the runtime checks with a built app:

```sh
zsh Validation/mac-extension-compatibility.sh /absolute/path/to/eGlu.app
```

The script keeps its temporary report, steps, and application log for inspection, then terminates only its own test app. It does not open or modify the existing browser profile.

Saved results: [check summary](Validation/ExtensionCompatibility-2026-11-04/checks.txt), [runtime report](Validation/ExtensionCompatibility-2026-11-04/report.txt), [per-space assertions](Validation/ExtensionCompatibility-2026-11-04/report.txt.steps).
