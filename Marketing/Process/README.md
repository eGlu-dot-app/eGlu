# Making the App Store screenshots and previews

How eGlu's App Store pictures and videos are made, from an empty simulator to App Store Connect. What each picture and video is for is in [Assets.md](Assets.md). The scripts are in [`Marketing/AppStore/source/`](../AppStore/source/); their own notes are in that folder's [README](../AppStore/source/README.md).

## The steps at a glance

| Step | Script | What it does |
|---|---|---|
| 1. Demo pages | `source/site/build.py`, `site/*.src.html` | Builds the made-up web apps the shots show (Forma, Margin, Lanes, Post, Week) and their icons. Served on this Mac, so no real account or site appears. |
| 2. Demo workspace | `source/demo.py` | Writes the spaces the shots start from (Studio, Client, Personal) into a simulator's app data, with their tabs, pinned tabs and bookmarks, and puts the demo sites' icons in the app's icon cache. |
| 3. One shot's state | `source/state.py` | Changes that workspace into one shot's state: which space, which tab, split or not, the command bar open, and so on. |
| 4. Capture | `source/cap.sh` (or the older `shot.sh`), `source/ready.py` | Quits the app, applies the state, relaunches, and saves a simulator screenshot once the page has finished drawing. |
| 5. Frame | `source/render.mjs` with `frame.html` and `frames*.json` | Puts each capture in its device frame with its headline and writes the final PNGs, opaque, at App Store sizes. |
| 6. Duo | `source/duo-inner.py`, `duo-outer.py`, `frames-duo-*.json` | The iPhone Duo's two screens (see "iPhone Duo" below). |
| 7. Videos | `source/tighten.py`, `source/preview.sh` | Cuts the waiting out of a screen recording, then converts it to App Store's preview format. |
| 8. Upload | `source/asc.py` | Sends text, screenshots, previews and the build to App Store Connect. |

## Before starting

- **Simulators:** iPad Pro 13-inch (M5) and iPhone 17 Pro Max, plus the iPhone Duo for its set. Xcode 27 has no Simulator app (Device Hub instead), so shots are taken with `xcrun simctl io <device> screenshot`.
- **Python with Pillow:** `/usr/bin/python3` has no Pillow. Run `render.mjs`, `ready.py` and the Duo scripts with `PATH=/opt/anaconda3/bin:$PATH`.
- **Playwright and WebKit** for `render.mjs`: point `PLAYWRIGHT` at a Playwright whose WebKit build is installed. A wrapper with `executablePath` set avoids downloading another WebKit.
- **Device frames:** `source/bezels.sh` fetches Apple's device artwork into `source/bezels/`. It is licensed for this use but not committed.
- **Font:** headlines are set in ABC Areal, installed in `~/Library/Fonts`.

## 1. Demo pages

`site/*.src.html` are the sources; `python3 site/build.py` writes the `*.html` the app opens. Serve the folder on port 8765 (`python3 -m http.server 8765` in `site/`). The demo workspace opens them under different loopback host names (`mail.localhost`, `week.localhost`, `board.localhost`, `127.0.0.1` and so on) so each site keeps its own icon without a machine-specific LAN address.

## 2. Demo workspace

```sh
C=$(xcrun simctl get_app_container <device> net.taehee.safience.MarketingQA data)
python3 Marketing/AppStore/source/demo.py "$C" iphone   # or ipad
```

Use a separate Debug simulator app with bundle `net.taehee.safience.MarketingQA`, never the production app container. Launch with `EGLU_ISOLATED_QA=1` and `EGLU_DATA_ROOT` pointing to the QA container's `Library/Application Support/Safience` directory. `cap.sh` sets these through `SIMCTL_CHILD_` variables. Seed before capturing, mark onboarding answered in the QA defaults, and disable sync, intelligence, content blocking and the local developer bar. The latest capture provenance and build constraints are in the source folder's README.

- **Studio** (teal): Post and Week pinned, Forma and Margin open, on iPad also Lanes; 21 bookmarks for the start page's grid.
- **Client** (orange): Post pinned; Lanes (dark), Margin and Forma open.
- **Personal** (indigo): one empty tab.

History is keyed by space id, and the app deletes a missing space's history at launch: running `demo.py` again wipes History. To trim tabs later, edit `workspace.json` instead.

Settings the shots need, written before launching:

```sh
xcrun simctl spawn <device> defaults write net.taehee.safience.MarketingQA preferences -data <hex of {"address":"automatic","searchSuggestions":false,"intelligence":false,"iCloudSync":false,"blocksContent":false,"developerLocal":false}>
```

Without them the address shows `localhost/...` with a not-secure sign, and search suggestions fill the command bar. Set `AppleLanguages` to `en-US` and `AppleKeyboards` to `en_US` and emoji, so no other language's key shows on the keyboard. On iPhone, override the status bar with `xcrun simctl status_bar <device> override --time 9:41 --cellularMode active --cellularBars 4 --operatorName ''`, so every shot matches.

## 3 and 4. Each shot's state and capture

```sh
Marketing/AppStore/source/cap.sh <device> <shot> <out.png> [ready mode | seconds]
```

`<shot>` is one of `state.py`'s: `hero`, `split`, `client`, `start`, `palette`, `notes`. On the iPad 13-inch, the fourth argument is `ready.py`'s mode, which waits until the page has drawn; elsewhere, a number of seconds to wait. Captures go to `raw-current/ipad/` and `raw-current/iphone/`, which are committed so frames can be re-rendered without the app.

Some shots need a hand on the simulator after the state is set:
- **Command bar** (`04-palette`): open it and type; the iPad's on-screen keyboard shows, since Device Hub has no hardware-keyboard switch.
- **Trackpad View** (iPhone `02-desktop-view`): turn it on from the page's menu, then tap the minimap to move the view. A two-finger drag goes to the page instead.
- **App icon** (when a set shows Settings › App icon): open it from the command bar's "app icon" row.

Simulator swipes shorter than about 80 points land as taps, and the first tap after a launch is often lost.

## 5. Framing

```sh
PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node Marketing/AppStore/source/render.mjs frames.json
PLAYWRIGHT=/absolute/path/to/playwright/index.mjs node Marketing/AppStore/source/render.mjs frames-iphone.json
```

Each `frames*.json` names the output folder, the size, the device frame and, per picture, the capture and its headline (`s`, with `<br>` for the line break). The iPhone list also writes the 6.3-inch set, scaled from the 6.9-inch frames. App Store Connect rejects PNGs with transparency; `render.mjs` flattens them. Rules for the copy: ABC Areal, and callouts kept well inside the picture's edges (about 150 px or more on the iPhone's 1320).

Re-rendering unchanged frames can shift a pixel or two (the iPad hero especially); keep the committed PNGs and take only the frames that changed.

## 6. iPhone Duo

The Duo needs Xcode 27.1 and its iPhone Duo simulator, with the app built against the iOS 27.1 SDK. Device Hub sets the pose (open or closed), which only a person can do.

- Open (inner screen): landscape, 2853 by 2007, framed by `frames-duo-inner.json` with Apple's "Inner Open Landscape" frame.
- Closed (outer screen): 1398 by 2034, captured with `xcrun simctl io <device> --display=1 screenshot`, framed by `frames-duo-outer.json`.

`duo-inner.py` and `duo-outer.py` made stand-in pictures from iPad and iPhone captures before a Duo simulator existed. Use them only if real captures are impossible, and never present their output as the Duo.

## 7. Previews (videos)

1. Record the simulator: `xcrun simctl io <device> recordVideo raw.mov`, and go through the scene.
2. Take the waiting out: `python3 source/tighten.py raw.mov tight.mov [hold seconds] [max seconds]` keeps the motion and shortens still stretches to a short hold.
3. Convert: `source/preview.sh tight.mov previews/iPhone-6.9.mp4 iphone` (or `previews/iPad-13.mp4 ipad`). It writes 30 frames a second H.264 with a silent stereo track (App Store Connect requires one), 886 by 1920 for iPhone and 1200 by 1600 for iPad, 15 to 30 seconds long.

## 8. Uploading

`source/asc.py` uses the App Store Connect API key, given as `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` (never committed). It works on the newest version in App Store Connect.

| Command | Sends |
|---|---|
| `asc.py state` | Nothing; prints what the version has. |
| `asc.py text` | Subtitle, promotional text, description, keywords and App Review notes from `../metadata.md`. It does not send the name or What's New: change those by hand in App Store Connect (the version's page for What's New, App Information for the name). |
| `asc.py screenshots` | Every PNG of iPhone 6.9-inch (`iPhone-6.9/`), iPhone 6.3-inch (`iPhone-6.3/`) and iPad 13-inch (the PNGs in `Marketing/AppStore/`), replacing what is there. |
| `asc.py previews` | `previews/iPhone-6.9.mp4` and `previews/iPad-13.mp4`. |
| `asc.py build <number>` | Puts that build on the version. This sends a version waiting for review back to Prepare for Submission. |

The Duo set goes up as one `APP_IPHONE_DUO` set (inner pictures, then outer, at most 10). The `asc.py` on main does not list it yet; add `'APP_IPHONE_DUO'` to `SETS` with both folders before uploading Duo pictures.

Uploading changes the live listing's draft: do it only when releasing.
