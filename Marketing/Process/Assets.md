# What each picture and video is for

The App Store shows the first three pictures in search results, so they carry the main ideas: web apps in their desktop versions, a space for each client, and the iPad's or iPhone's own strength. How they are made is in [README.md](README.md).

## iPad 13-inch (`Marketing/AppStore/*.png`, 2064 by 2752)

Also used for every smaller iPad size.

| File | Headline | Role | Captured state |
|---|---|---|---|
| `01-hero.png` | Keep desktop web apps in separate client spaces. | The first impression: a real desktop web app on iPad, in a coloured space. | `hero`: Studio, Forma (the design tool) open. |
| `02-split.png` | Open a design and its notes side by side in one window. | Working the way people do on a Mac: two tabs at once. | `split`: Forma and Margin in Split View. |
| `03-spaces.png` | Each space has its own sign-ins and colour. | Why spaces matter: a client's accounts kept apart from yours. | `client`: the orange Client space, Lanes in dark. |
| `04-palette.png` | Find a tab, a space or a command from the address bar. | Speed: one place to find and do everything. | `palette`: the command bar open with typed words and rows. |
| `05-bookmarks.png` | Keep bookmarks and folders inside each space. | The start page: each space's own bookmarks as a grid. | `start`: a new tab in Studio. |

## iPhone 6.9-inch (`iPhone-6.9/`, 1320 by 2868) and 6.3-inch (`iPhone-6.3/`, 1206 by 2622)

The 6.3-inch set is the 6.9-inch set scaled, not a separate capture.

| File | Headline | Role | Captured state |
|---|---|---|---|
| `01-hero.png` | The address bar is at the bottom, within reach of your thumb. | The phone's own layout: one hand. | `hero` on iPhone. |
| `02-desktop-view.png` | Desktop sites with a trackpad, zoom and Exit always in reach. | Trackpad View: a desktop web app on a phone, the screen as a trackpad. | Trackpad View on, the view moved with the minimap. |
| `03-spaces.png` | Each space has its own sign-ins and colour. | The same promise as on iPad. | `client`. |
| `04-palette.png` | Find a tab, a space or a command from the address bar. | Speed on the phone. | `palette`. |
| `05-bookmarks.png` | Keep bookmarks and folders inside each space. | The start page on the phone. | `start`. |

## iPhone Duo (`iPhone-Duo-inner/`, `iPhone-Duo-outer/`)

Uploaded together as one set, the inner pictures first. Check that they were taken on the Duo simulator before uploading (see README, "iPhone Duo").

| File | Headline | Role |
|---|---|---|
| `iPhone-Duo-inner/01-hero.png` | Unfold it for the desktop version of your web apps. | Open, the Duo is wide enough for the iPad layout. |
| `iPhone-Duo-inner/02-split.png` | A design and its notes in one window. Drag the divider for room. | Split View on the open Duo. |
| `iPhone-Duo-inner/03-spaces.png` | Every space keeps its own sign-ins, colour and bookmarks. | Spaces. |
| `iPhone-Duo-inner/04-palette.png` | Tabs, spaces and commands in one search. | The command bar. |
| `iPhone-Duo-inner/05-bookmarks.png` | Bookmarks for every space, synced through iCloud. | Bookmarks and sync. |
| `iPhone-Duo-outer/01-folded.png` | Folded, the bar sits under your thumb. | Closed, the phone layout. |
| `iPhone-Duo-outer/02-spaces.png` | Every space keeps its own sign-ins, colour and bookmarks. | Spaces, closed. |
| `iPhone-Duo-outer/03-bookmarks.png` | Bookmarks for every space, synced through iCloud. | Bookmarks, closed. |

## Previews (`previews/`)

| File | Size | Role |
|---|---|---|
| `iPad-13.mp4` | 1200 by 1600, 15 to 30 s | Plays first on the iPad product page, before the pictures: shows a desktop web app answering the trackpad and keyboard, then spaces. |
| `iPhone-6.9.mp4` | 886 by 1920, 15 to 30 s | The same on iPhone: the bar under the thumb and Trackpad View. |

Both previews were recaptured from checkpoint `b94e7e5` on 2026-10-26 with isolated synthetic data. The iPad preview shows Split View resizing, command-bar typing, spaces and bookmarks. The iPhone preview shows the bottom bar, Trackpad View, minimap movement, zoom controls, Exit and spaces. Capture constraints and measured export properties are in `Marketing/AppStore/source/README.md` and `source/raw-current/manifest.json`.

## Text (`Marketing/AppStore/metadata.md`)

Name, subtitle, promotional text (changeable without review), description, keywords and What's New, each with App Store Connect's length limit in its heading. `asc.py text` sends the subtitle, promotional text, description, keywords and review notes; the name and What's New are entered by hand in App Store Connect.

## Brand (`Marketing/Brand/`)

The eGlu icon and symbol as SVG, for the website, press and anywhere outside the app. See its own README.
