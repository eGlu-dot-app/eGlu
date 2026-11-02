# App Store screenshots

The current iPad and iPhone screenshots and previews were recaptured on 2026-10-27 (Asia/Seoul) from main checkpoint `0ac99c1593fe9fe23e31831f4c5de8505d128987`. They show the native interface in a separate QA app with fresh synthetic spaces, including the latest pinned-icon styling, compact glass Trackpad View controls and SwiftUI Trackpad View help sheet. Forma, Margin, Lanes, Post and Week are repository demo pages served locally. Their pages and original icons are preserved.

## Current coverage

| Folder | Output size | Capture provenance |
| --- | --- | --- |
| `Marketing/AppStore/` | 2064 x 2752 | Current native iPad Pro 13-inch (M5) simulator, iPadOS 27.0. |
| `Marketing/AppStore/iPhone-6.9/` | 1320 x 2868 | Current native iPhone 17 Pro Max simulator, iOS 27.0. |
| `Marketing/AppStore/iPhone-6.3/` | 1206 x 2622 | Existing renderer's scaled derivative of the current 6.9-inch set. This is not a separate 6.3-inch device capture. |
| `Marketing/AppStore/iPhone-Duo-inner/` | Historical stand-ins | Archived iPad-based composites. Not current Duo posture captures; excluded from current coverage. |
| `Marketing/AppStore/iPhone-Duo-outer/` | Historical stand-ins | Archived shortened iPhone composites. Not current Duo posture captures; excluded from current coverage. |
| `Marketing/AppStore/previews/iPad-13.mp4` | 1200 x 1600, 16.17 s | Current native iPad recording: resize Split View, type in the command bar, switch spaces and open a Studio bookmark in a new tab. |
| `Marketing/AppStore/previews/iPhone-6.9.mp4` | 886 x 1920, 27.77 s | Current native iPhone recording: bottom bar, glass Trackpad View controls, minimap, zoom, help sheet, Exit, command bar and Client space. |

No current folded/unfolded Duo capture is claimed. This run did not have a usable Duo runtime and did not validate its postures, hinge transitions, system strip or viewport behavior. Do not present the archived Duo images as current capture evidence.

## Capture build

The checkout uses iOS 27.1 APIs, while the available SDK and capture runtimes are 27.0. A separate build copy guarded the unavailable 27.1-only layout and diagnostic branches in `Browser.swift`, `Diagnostics.swift` and `PhoneBar.swift`. Those branches do not run on these 27.0 devices. No app-source compatibility changes are part of this refresh, and no Duo behavior is inferred from this build.

The Debug simulator build used Xcode 27 RC, local Engines, `CODE_SIGNING_ALLOWED=NO` and `PRODUCT_BUNDLE_IDENTIFIER=net.taehee.safience.MarketingQA`. Its native capture dimensions are 2064 x 2752 on iPad and 1320 x 2868 on iPhone.

## Files and reproduction

| File | Purpose |
| --- | --- |
| `raw-current/ipad/`, `raw-current/iphone/` | Current unframed native captures. Five feature shots plus a notes reference per platform. |
| `raw-current/manifest.json` | Device coverage, QA provenance, source checkpoint, image/video hashes and export validation. |
| `site/` | Original synthetic demo pages and icons, served on port 8765 with distinct loopback hosts. Lanes now uses `board.localhost`, not a machine-specific LAN address. |
| `frame.html`, `frames.json`, `frames-iphone.json` | Existing frame layout, current capture inputs and current feature copy. The iPhone frame list also emits the scaled 6.3-inch set. |
| `render.mjs` | Renders the existing HTML frames in WebKit, writes opaque PNGs and creates the declared scaled derivatives. |
| `bezels/`, `bezels.sh` | Apple's licensed local device artwork. The current run reused existing local iPad/iPhone artwork; these ignored assets are not redistributed. |
| `demo.py`, `state.py`, `cap.sh` | Seed and select synthetic states. `cap.sh` defaults to the separate MarketingQA bundle and launches with isolated QA variables. Only override `EGLU_CAPTURE_BUNDLE` with another disposable QA bundle. |
| `shot.sh` | Older production-bundle helper. Not used for this refresh; do not use against a real app container. |
| `tighten.py`, `preview.sh` | Shorten simulator recordings and encode the two current App Store previews. |
| `frames-duo-*.json`, `duo-*.py` | Historical stand-in production files. They are not inputs to the current render. |
| `asc.py` | App Store Connect uploader. Local capture/render verification does not authorize an upload. Current screenshot sets are iPad 13-inch and iPhone 6.9/6.3 only. |

The captures used bundle `net.taehee.safience.MarketingQA`, `EGLU_ISOLATED_QA=1`, and `EGLU_DATA_ROOT` set to the QA bundle's own `Library/Application Support/Safience` directory. Sync, search suggestions, intelligence, content blocking and the local developer bar were off. Welcome and writing prompts were marked answered in QA defaults. Local HTTP pages correctly show an unsecured-site indicator while the address is being edited. No signed-in user site, production app container, Apple Account or real workspace was captured.

After seeding the QA data with `demo.py`, `cap.sh` selected each native state. The command-bar captures required typing `space` and showing the software keyboard. The iPhone Trackpad View capture was taken after entering through the page menu and tapping the minimap. The tracked raw PNGs make framing reproducible without reopening the app.

With matching Playwright/WebKit installed and the licensed bezels present:

```sh
PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node Marketing/AppStore/source/render.mjs frames.json
PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node Marketing/AppStore/source/render.mjs frames-iphone.json
```

The renderer's inputs are `raw-current`, not the historical `raw`, `raw-iphone` or Duo composites. All current framed PNGs were opened for visual review. Pixel dimensions and opacity were checked after rendering. No App Store upload was performed.

The existing frame layout, copy and SF Pro font stack are unchanged. The process document specifies ABC Areal, but that font was not installed for this run.

## Preview reproduction

Record the QA simulator with `xcrun simctl io <device> recordVideo --codec=h264 raw.mov`, then follow the native interactions listed in Current coverage. Stop with SIGINT. Raw and tightened movies are local intermediates, not repository assets.

```sh
python3 Marketing/AppStore/source/tighten.py ipad-raw.mov ipad-tight.mov 1.2
Marketing/AppStore/source/preview.sh ipad-tight.mov Marketing/AppStore/previews/iPad-13.mp4 ipad
python3 Marketing/AppStore/source/tighten.py iphone-raw.mov iphone-tight.mov 0.8
Marketing/AppStore/source/preview.sh iphone-tight.mov Marketing/AppStore/previews/iPhone-6.9.mp4 iphone
```

The iPhone preview ends on the loaded Client board. The iPad preview ends on the loaded Forma page after opening it from Studio bookmarks. Both exports were visually reviewed and checked with FFprobe and FFmpeg: 30 fps H.264 High, yuv420p, silent stereo AAC at 48 kHz, within 15 to 30 seconds, with MP4 fast-start metadata. `raw-current/manifest.json` records their measured properties and SHA-256 hashes.
