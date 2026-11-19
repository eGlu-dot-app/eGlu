# Contributing

Small, focused changes are the easiest to take: one thing per pull request, readable start to finish. For anything bigger, open an issue first to say what you want to change and why.

## Building and testing

- Open `eGlu.xcodeproj` in Xcode 26 or later. Your team ID goes in `Config/Local.xcconfig`, which git ignores (see README).
- After adding or removing a file, run `xcodegen` at the root and commit the regenerated project with your change.
- `cd PadCore && swift test`: the app's logic, on macOS or Linux.
- `xcodebuild -scheme 'eGlu Command Bar Motion Tests' -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test`: command-bar input, animation interruption and Reduce Motion, without loading browser data.
- `node Tests/bridge.mjs`: the script that goes into pages, in a browser (needs Playwright).
- On an iPad, [Validation/CHECKLIST.md](Validation/CHECKLIST.md) covers what only a device can show.
- Builds clean: no warnings you introduced.

## What keeps eGlu what it is

- **The page gets the input.** A key or a gesture the system takes from a page is a bug, unless iPadOS keeps it for itself. The browser's own shortcuts are ⌃⌥ only.
- **Hands off Google's sign-in.** On a host in `HandsOff.swift`, no script of ours runs, no JavaScript is called and no cookie is read. Calls into pages go through `Page.swift` only (each app's, and `Shared/PageShared.swift`, the half they share), and `PolicyTests` reads the source to keep it that way.
- **A site's needs go in its adapter** (`PadCore/Sources/PadCore/Adapters.swift`), not in the app.
- **No dependencies beyond Apple's frameworks**, with two exceptions: Sparkle, in eGlu Mac Direct, to update the app; and the Rust engines in `Engines/` (Harper for grammar, anydoc and pdf-inspector for documents), built from source, pinned, and making no network call. Nothing else: no other Swift packages, Rust crates or npm packages in the app. XcodeGen and Playwright are tools for developers, not part of the app.
- **Nothing leaves the iPad** but the pages you open: no analytics, no telemetry, no server.
- **Comments say why**, not what the next line does. Read a couple of files before adding a new one. No force-unwraps on anything that can plausibly fail.
- **No real key or token anywhere**: in code, a test, an issue or a pasted log. `gitleaks git --pre-commit --staged` with the repository's `.gitleaks.toml` catches most before a commit.
- **A change that fixes or adds something adds its line** under Unreleased in [CHANGELOG.md](CHANGELOG.md).

## Where the old name stays

eGlu was called Safience up to 1.0.7. What people already have, or what lives outside this repository, keeps that name, because renaming it would lose their data or break a service:

| Kept | Why |
| --- | --- |
| The bundle identifier `net.taehee.safience`, and what is made from it: the iCloud container, Handoff's activity type, the dragged tab's type, the logs' subsystem | The App Store app, iCloud data and macOS permissions are tied to it |
| The folders `Application Support/Safience`, `Caches/Safience` and `Safience Migration`, and `.safience-migration` | Where people's workspace, history, site icons and native messaging hosts already are; an interrupted move from the sandbox resumes by these names |
| The `"safience"` key in the extension records | Records kept before the rename are still read (`ExtensionRecords.Record.CodingKeys`) |
| The addresses `taehee-pd/Safience`, `taehee-pd/eGlu`, `eGlu-browser/eGlu` and `eGlu-dot-apps/eGlu`; the repository is now `eGlu-dot-app/eGlu` | GitHub redirects each of them there. Macs on 1.0.7 and earlier look for updates at `taehee-pd/Safience`, and eGlu Mac Direct builds from the rename to eGlu (24 October 2026) up to the move to `eGlu-dot-app` at `taehee-pd/eGlu`. Never create a repository or an organization under any of these old names: it would take the address and end its redirect, and those Macs would stop getting updates |
| The Sparkle key's and the notary profile's keychain names, `safience-notary.env`, `SAFIENCE_NOTARY_ENV`, the "Safience Developer ID" profile | They are on the releasing Mac and in the developer portal |
| CHANGELOG entries up to 1.0.7 and the dated reviews in `Docs/` | They record what was |

## Reporting a bug

Open an issue with what you did, what you expected, what happened instead, your iPad and its iPadOS version, and the site. A screenshot of the Diagnostics panel (⌃⌥D) on the page helps with anything about the trackpad or the keyboard.
