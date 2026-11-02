# iPhone Duo design: the outer display, the inner display and the fold

Status: researched on 21 October 2026 from Apple's documentation, Human Interface Guidelines and Tech Talks for iPhone Duo (see Sources), with the code read the same day. Nothing is built. The point sizes here are third parties' figures until step 0 measures them in Xcode 27.1's iPhone Duo simulator; Apple publishes none. iPhone Duo reaches customers on 23 October 2026, and its screenshots are required for submissions from April 2027.

Three asks:

1. On the outer display (closed), the address bar and the space button (the profile selector) are at the bottom of the display, and the rest of the controls are in a strip on the right.
2. On the inner display (open), eGlu is almost the same as on iPadOS.
3. Open and half folded, with the tabs in a sidebar and the sidebar shown, the sidebar fills the left half of the display.

| Ask | Answer |
|---|---|
| Outer display | A new layout for a compact-width window that has a vertical bar: one row at the bottom (space, address), the other tools in the system's vertical bar on the side the system names. Section 3 |
| Inner display | The iPad layout already comes, since the layout follows the width class. What is missing is what follows the device type instead: commands, settings and shortcuts that an iPhone never shows. Section 4 |
| Half folded | The sidebar's width follows the fold's reserved region, from the window's edge to the fold; the page starts after it. Section 5 |

## 1. What Apple says

| Topic | What Apple says | Where |
|---|---|---|
| Size classes | The outer display has the size classes of other iPhones: compact width, regular height in portrait; compact both ways in landscape. The inner display is regular width and regular height. Lay out by size class, not by `userInterfaceIdiom` or interface orientation. iPhone Duo has no idiom of its own | Tech Talk 111461; Group Lab |
| Orientation | The outer display honours the supported orientations; the inner display does not | Tech Talk 111461 |
| Screens | Don't use `UIScreen.main`; read the window scene's screen, or better the view's bounds and traits | Tech Talk 111461; Prepare page |
| SDK | Built with the iOS 26 SDK, an app sits centred with empty space around it when open, and beside the status bar when closed. With the iOS 27 SDK it fills most of the inner display but keeps clear of the status bar on the right. With the iOS 27.1 SDK it fills the display, and toolbars and tab bars stand vertically below the status bar | Prepare page |
| Vertical bars | On the outer display, and on the inner display in landscape, navigation bars, toolbars and tab bars move to one side, sharing the strip with the status bar and the Dynamic Island. Only the inner display in portrait keeps horizontal bars | HIG, Vertical controls |
| Which side | The side the system names (`verticalBarEdge` in UIKit). In Split View the app on the left has its controls on the left. The strip stays on the same hardware side in right-to-left languages | HIG; Tech Talk 111462 |
| Custom bars | Only the bars of navigation containers move. Content of a custom `UIToolbar`, `UINavigationBar` or `UITabBar` is not considered; a custom bar reads `verticalBarEdge` and the reserved regions and places itself | Overview; Tech Talk 111462; Group Lab |
| `verticalBarEdge` | The system's preferred edge, whether or not a vertical bar is showing. Unspecified on hardware without a vertical bar, and in a size class or orientation that uses none | UIKit reference |
| Items in the strip | An item with a symbol goes vertical; a text-only item or a custom view stays horizontal. Give each item a symbol and a title (the title is used in the overflow menu). Top of the strip: primary navigation (Back, Close), then prominent actions; the system leaves a gap between the top bar's items and the bottom bar's | HIG; Overview |
| Overflow | Items that don't fit go into the system's overflow menu, from the bottom up unless `visibilityPriority` says otherwise. Keep the ellipsis for that menu, and move an app's own overflow menu into it (`additionalOverflowItems`) | HIG; Tech Talk 111462 |
| Opting out | `preferredVerticalBarBehavior` returning disabled turns the vertical bar off (Calculator, a video player). A stable choice, not toggled with a view's state; changing it moves the status bar from one axis to the other | UIKit reference |
| The fold | Partly open, the fold is a division reserved region that splits the inner display; fully open, it is inactive. `UIView.reservedRegions(kind: .division)` returns the active ones, each frame in the view's own points with its margins included. UIKit runs `updateConstraints()` again when the regions read there change | UIKit reference, `UIView.ReservedRegion` |
| Around the fold | Keep controls out of the fold; scrolling content may cross it. Favour small adjustments over rearrangement. Alerts, menus and sheets move aside by themselves | HIG, Reserved regions; Tech Talk 111466 |
| Hinge angle | `UIHingeInteraction` reports the hinge's status and angle, for interactions and effects. For layout, use reserved regions | Tech Talk 111464 |
| Windows | Each window is a scene, as on iPad. New windows can be made only on the inner display, and whether they can changes as the device opens and closes; `UIWindowSceneActivationAction` hides itself when they can't. Folding and unfolding resizes the same scene, typing and all | Tech Talk 111464; Group Lab |
| Testing | Device Hub in Xcode 27.1 has an iPhone Duo simulator that opens, closes, folds and turns | Tech Talk 111461 |

All the new APIs are iOS 27.1 and later, so they go behind `#available(iOS 27.1, *)`; the deployment target stays iOS 17.

## 2. What eGlu has

**The layout follows the window's width class.** `Browser.refreshChrome()` sets `model.phone` from `traitCollection.horizontalSizeClass == .compact` (`Browser.swift:615`), registered for the trait's changes at `Browser.swift:325`. So the Duo closed already gets the phone bar at the bottom (`PhoneBar`), and open gets the iPad's bars or sidebar. Comments name the Duo there and in `PhoneBar.swift:5` and `SiteMode.swift:8`.

**Some checks follow the device type**, and don't change as the Duo opens:

| Where | What an iPhone idiom does there |
|---|---|
| `Menus.swift:23` (`Device.phone`) | Hides keyboard shortcuts; `offers()` hides the tab bar, focus page, Split View and site mode commands; offers fewer Settings sections (`SettingsAnchor.isOffered(phone:)`); says "iPhone" |
| `SettingsView.swift:28` | Shows Desktop View's cursor speed and "The address bar shows"; hides Window › Tabs (Horizontal or Vertical), Show tab bar or sidebar, Trackpad and keyboard, Shortcuts |
| `Welcome.swift:216`, `Suggestions.swift:510`, `Spaces.swift:231` | The welcome's text, commands in suggestions, "View on iOS" |
| `Page.swift:487` | The mobile user agent's `pad:` flag |
| `Page.swift:682` | `touchFirst` |
| `Page.swift:1553` | The context menu's wait for the pointer |

`UIApplication.shared.supportsMultipleScenes` decides whether New Window and Open in New Window show (`Menus.swift:33`, `Bars.swift:211`, `SideTabs.swift:728`, `SideTabs.swift:779`): true on the Duo, also when closed, where Apple says new windows can't be made.

**Other rules by size:**

- Split View shows two panes when the stage is at least 728 points wide (`2 * 360 + SplitDivider.width`, `Browser.swift:1021`).
- Desktop sites go to windows at least 600 by 500 points (`SiteMode.swift:12`), chosen per navigation from the window's size (`Page.swift:686`), so a resize changes the next page, not this one.
- The command bar is at most 680 points wide, 16% down the window (`Browser.swift:554`, `Browser.swift:576`).
- The sidebar is 248 points wide (`SideTabs.width`, `SideTabs.swift:24`), pinned to the safe area's leading edge (`Browser.swift:409-414`).

**The window's root is `Browser`** itself (`AppDelegate.swift:40`), with no navigation controller, so no system bar of any kind. All bars are SwiftUI views hosted in UIKit (`Browser.embed`).

**Tests** use third parties' Duo sizes: folded 466 by 678, open 626 by 890 (`PadCore/Tests/PadCoreTests/CloudAndSiteModeTests.swift:6-11`). The App Store's Duo screenshots are stand-ins made from an iPhone and an iPad (`Marketing/AppStore/source/README.md`).

**Measured** on 21 October 2026 in Xcode 27.1's iPhone Duo simulator (iOS 27.1), with eGlu built with the iOS 27.1 SDK and no system bars, read from Settings › Diagnostics (`Diagnostics.lines(forWindow:)`):

| Measure | Closed, upright |
|---|---|
| Window and screen | 466 by 678 points (the third parties' figure holds) |
| Size classes | width compact, height regular; idiom phone |
| Safe area | top 0, left 0, bottom 34, right 84: the status bar's strip arrives as a right inset even with no system bar in the app |
| `verticalBarEdge` | trailing |
| Occlusion regions | the camera, 37 by 37 at (399.7, 29.3); the status bar's strip, 84 by 174 at (382, 0) |
| Division region (the fold) | none |
| Hinge | closed, 0° |
| `supportsMultipleScenes` | true |
| Main menu | built: UIKit asks for it on the Duo (`Menus.built`) |
| New Window | succeeds while closed: a second scene comes up in place of the first, no error. Apple says new windows can't be made on the outer display; recheck on a device |

Not measured yet: open, half-folded and in Split View need the Duo folded by hand in Device Hub. Turned: `devicectl device orientation set` and `rotate` report landscape on the Duo, but it reads portrait again at once.

## 3. The outer display

### When

A window that is compact width and whose `verticalBarEdge` names a side. Only hardware with a vertical bar names one, so an iPhone keeps today's phone bar. This also covers eGlu as one of two apps in Split View on the inner display, with the strip on the side the system names: the left for the app on the left. The trait is registered alongside the width class at `Browser.swift:325`.

### The bar at the bottom

One row: the address (with its star and reload), as wide as the rest allows; a pinned tab's button before it. The space button stood before the address until 2 November 2026, when the user asked for it in the tabs' sheet only, as on any iPhone (`TabOverview`'s `SpaceHeading`). While an address is typed, the address and Cancel, over the keyboard, as now. 6 + 44 + 6 = 56 points instead of 104, so more of the page shows. The swipe up for the tabs and the swipe sideways for the tab beside stay on this bar (`BarSwipe`, `Browser.slidBar`). The page runs under its blur, as under the phone bar now.

### The strip at the side

Back and Forward at the top; New Tab and Tabs at the bottom, the tab count as the item's badge; the page menu's items in the system's overflow menu, which keeps the ellipsis. Back and Tabs at high visibility priority, so they are the last to overflow when the strip is short (landscape, the keyboard, picture in picture).

How, recommended: the system's own vertical bar. `Browser` goes into a `UINavigationController` with its navigation bar hidden, and its tools become `toolbarItems` with symbols and titles. The toolbar shows only in this layout. The status bar, the Dynamic Island growing for Live Activities, overflow, and Split View's sides then come from the system, as in Apple's apps. Unknown until step 1: whether the system puts a toolbar's items in the strip when the navigation bar is hidden. If not, a strip of eGlu's own, placed by `verticalBarEdge`, the safe area and the camera's occlusion region.

Found in step 1 (21 October 2026, the Duo closed, in the simulator), all three tried in one build:

| Variant | What showed |
|---|---|
| A: navigation bar hidden, `toolbarItems` | The items do go in the strip, but all at its foot: the flexible space between groups collapses on the vertical axis, so Back and Forward sit just above New Tab and Tabs. No overflow button: `additionalOverflowItems` is the navigation item's, and with the bar hidden it doesn't show |
| B: navigation bar shown, Back and Forward as `navigationItem.leadingItemGroups`, New Tab and Tabs as `toolbarItems` | As asked: Back and Forward at the top of the strip under the status bar, the system's overflow (…) under them with the extra items, New Tab and Tabs (its count as a badge) at the foot. The shown navigation bar adds a top safe area inset of 24 points, which the page has to go under |
| C: no system bar, a guide from `layoutGuide(for: .bar(onEdge: .trailing, extent: 52))` | A 52-point column on the right from below the status bar to above the home indicator: a workable place for a strip of eGlu's own |

Chosen: B. The strip is the system's; the page runs to the top of the window past the navigation bar's 24 points.

The page stops at the strip; `Page.obscure` covers only the bottom today (`Page.swift:911`).

## 4. The inner display

The iPad layout comes already, with the iPad's bars, the sidebar and the command bar. Work:

- **Device type to width class.** The checks in section 2 that hide iPad features follow the window's width class (or the device having a vertical bar) instead of the idiom, so the Duo open has Split View, the tab bar and sidebar commands, keyboard shortcuts and the Horizontal or Vertical tabs setting. `Page.swift:487`, `:682` and `:1553` are read case by case: the Duo has a touch screen and no trackpad, so these may stay as they are.
- **New windows.** New Window and Open in New Window through `UIWindowSceneActivationAction`, or a check that hides them when the system can't make a window (the Duo closed).
- **Landscape.** The status bar stands in a strip on the right. Recommended: the iPad's bars stay along the top, beside the strip, as on iPadOS. The other way, as Apple's own apps do: back, forward and reload move into the vertical bar in landscape.
- **Sizes.** Measured in step 0, then the tests' sizes, the 600 by 500 rule and the 728-point Split View rule checked against them. On the third parties' figures, portrait (626 wide) shows one pane, and landscape (about 950) two, but one with the sidebar shown.

Found on 22 October 2026, the Duo open flat in the simulator:

| Measure | Value |
|---|---|
| Window | 951 × 669, width and height regular |
| Safe area | right 84, bottom 34 |
| `verticalBarEdge` | trailing: the status bar in a strip on the right, 84 × 124 |
| Fold | a division region 40 × 669 at x 455.5, margins 20 each side, inactive while flat |
| Split View | one pane with the sidebar shown (about 610 points of page), two with it put away |

Chosen then: the strip's tools stand beside the open window too (closed and open alike), with the iPad's bars still along the top; there Tabs shows or hides the tab bar or sidebar. The sidebar against the fold waits for a half fold, when the fold's region is active.

## 5. Folded, with the sidebar

### When

An active division region taller than wide (folded like a book, the fold running top to bottom), while the sidebar is shown (`sideShown`: tabs in a sidebar, not put away, not phone-width). Read in `Browser.updateConstraints()`, so UIKit calls it again when the fold comes or goes.

### What changes

- The sidebar's width: from its leading edge to the fold's frame's leading edge, which includes Apple's margins, in place of the fixed 248 (`Browser.swift:413`). The page's card starts at the fold's trailing edge; the fold itself shows the window's ground.
- In right-to-left languages the sidebar is on the right, so it fills the right half.
- Folded like a laptop (the fold running across), and fully open: 248, as now.
- The change animates as the device folds, the sidebar growing into the half and back.
- In about 470 points the sidebar's rows, pinned tiles and bookmarks get wider; checked that each fills the width rather than staying at 248 (the `GeometryReader` at `SideTabs.swift:234`).
- The command bar, centred today, would sit on the fold: it goes into one half (section 8, decision 6).

The width from the fold's frame is a pure function, so it goes in `PadCore`, tested on any machine with Swift, with `Browser` passing it the frames.

## 6. Plan

| Step | What | Done when |
|---|---|---|
| 0 | Build with Xcode 27.1 and the iOS 27.1 SDK; in the Duo simulator, closed, open, folded both ways, turned and in Split View, note the window's size, size classes, `verticalBarEdge`, safe area insets, the fold's and the cameras' regions, and where the status bar is | A table of the measured values in this note, replacing the third parties' |
| 1 | Try the system vertical bar: `Browser` in a navigation controller, its bar hidden, a few `toolbarItems` | The items stand in the strip on the outer display, or the custom strip is chosen |
| 2 | The outer display's layout (section 3) | Closed, turned, and as either app in Split View, the bar and strip as described, typing and swipes as before |
| 3 | Device type to width class, and new windows (section 4) | Open, the Duo has the iPad's commands, settings and shortcuts; closed, no New Window |
| 4 | The sidebar to the fold (section 5), the width function in `PadCore` with tests | Folded like a book, the sidebar fills its half; like a laptop and fully open, 248 |
| 5 | Tests' sizes, `Validation/CHECKLIST.md` §8, `Docs/Requirements.md` rows, the README's iPhone section, the CHANGELOG, Duo screenshots from the simulator in place of the stand-ins | Each checked against the simulator |

## 7. Risks, most likely first

1. **A hidden navigation bar may keep the toolbar out of the strip.** Step 1 shows it; the custom strip is the fallback, with the status bar, the camera and the Dynamic Island to keep clear of by hand.
2. **The measured sizes move the thresholds.** The 600 by 500 desktop rule, the 728-point Split View rule and the sidebar's 248 were set without the Duo's real points.
3. **Desktop sites in half a window.** Folded, the page has about half the window but gets the site the window's size asks for, as the sidebar already makes it today. Zoom fits a narrow page (`Docs/Requirements.md`), so this is likely fine, and step 0 shows it.
4. **What the inner display's idiom is**, Apple doesn't say. Section 4's change works either way, which is why it follows the width class.
5. **Nothing here runs on Linux.** Steps 0 to 4 need a Mac with Xcode 27.1; only the `PadCore` function's tests run anywhere.

## 8. Decisions for you

1. **The strip**: the system's vertical bar (recommended) or one of eGlu's own.
2. **The page menu on the outer display**: in the system's overflow menu (recommended, as Apple asks), its own item in the strip with another symbol, or beside the address at the bottom.
3. **The strip's order**: Back and Forward at the top; New Tab, Tabs and the overflow at the bottom (recommended).
4. **The inner display in landscape**: the iPad's bars along the top, beside the status bar's strip (recommended, closest to iPadOS), or back, forward and reload in the vertical bar, as Apple's apps.
5. **iPad-only settings on the Duo**: offered closed and open (recommended, since Apple asks for the same functions on both displays), or only while open.
6. **The command bar when folded**: in the page's half (recommended, where what it finds opens), or the sidebar's half.
7. **Beyond the three asks**: Split View's two panes dividing at the fold, and the tabs along the top keeping off it; now, or later.

## 9. The page under the strip

Asked on 2 November 2026: on the Duo closed, the strip showed the page's edge stretched across it (a picture of its last 8 points, blurred by the stretch). Instead the page runs on under the strip to the window's edge: its pictures, colours and backgrounds under the strip's glass, its running text wrapping at the strip's edge, and what can be pressed moving out from under the strip's items. The room for what can be pressed is a trapezoid, not a column: the strip is taken only where its items stand, and between them it is empty, so a button slides aside as it scrolls up towards the items and back as it scrolls clear of them.

References, for their mechanics only (no code taken): DuoWide (github.com/hyungchulc/duowide), a Safari userscript that lays pages out across the whole outer display and moves links, buttons and fields out from under the strip; Brim (x.com/joogps/status/2114766532656202021), a browser that uses the full width and Apple Intelligence to clear what is under the camera.

| Part | What it does | Where |
|---|---|---|
| When | Where the strip's ground used to be drawn: a phone-width window with a strip, the page edge to edge (not a card, not beside a split, not the desktop view, not the start page) and not a hands-off page, which gets no scripts | `Browser.placeUnderStrip` |
| The page's reach | The stack's side constraint goes past the safe area by the strip's width, so the stage and the page reach the window's edge; a sideways swipe's next tab comes from the window's edge. The save, split and banner rows above the page keep their content clear of the strip (`safeAreaRegions = .container`) | `ChromeConstraints.reachUnderStrip` |
| No safe area for the page | The page view reports no safe area on the strip's side, so `env(safe-area-inset-right)` is 0 and every page lays itself out to the window's edge; the script makes the room the same way for all. Pages that kept clear by themselves did it twice over: Apple's header set its search and bag apart from its menu by the strip's width again (seen in DuoWide too). The scroll bar still keeps beside the strip | `PageView.safeAreaInsets` |
| The bands | Where the strip is taken, top to bottom, in the page's points: the status bar's and the cameras' occlusion regions, and the strip's items' frames (`UIBarButtonItem.frame(in:)`), each 8 points further out, merged where they touch. The system draws the strip outside the app's windows, and no API places its overflow (…): it is taken as one more item 23 points under Forward, as measured on the iOS 27.2 simulator. An item the system gives no place for makes the whole strip one band (`known: false`): build 1.1.0.45 moved nothing on the Duo itself, most likely because these frames came back empty there and an empty list read as an empty strip. The simulator, too, places Back, Forward and the overflow only a moment after the strip shows, and returns no occlusion regions at all; without them the strip above the topmost item is taken as the status bar's. Measured on layout passes only; a page's own changes, several times a second while it scrolls, reuse the last measure. Each new measure is logged (category `strip`) and shown in Developer Diagnostics | `Browser.stripCover`, `StripItems.frames`, `DuoLayout.stripBands` |
| The slant | Beside a band, a group is moved all the way; 44 points (a finger) or more away, not at all; between, in proportion | `strip.js` `cover` |
| Text | Each block of running text whose lines reach past the safe area's edge gets that much more padding on the strip's side, in its own style (the page's value put back when the room goes), the outermost block only; a block that grows wider for it is sized to hold it (`box-sizing`), and one that still grows gets none. Given while the page is still coming in (before the first touch, or 2.5 s after its load); after that only to blocks wholly below the window, so nothing shown moves, and one that needs room while it shows waits until it is below the window. Never taken away to measure: that rewrapped the text and moved the page under the finger (GitHub, 2 November 2026: a jump of a line every 0.3 s while scrolling, measured frame by frame in a recording from the Duo). Not a button's label, nor text in a row that scrolls sideways or in something typed in. Asked for on 2 November 2026 in place of re-wrapping text along the slant as it scrolls | `strip.js` `textRoom`, `give`, `checkGiven` |
| What moves | Links, buttons, fields, roles, `onclick` and `tabindex` (no guessing by cursor) that an `IntersectionObserver` finds in the strip's column, a window above and below it too. The box round each, climbing while no wider than 60% of the window and no taller than its row; the controls level with it within 64 pixels join it and move by the same amount, so a header's icons keep their gaps (Apple's search and bag, 61 apart, with its menu). It moves the whole way or not at all; running text in the way gives more room first while it may still be laid out (Apple's country banner's ✕). Measured by what boxes show, not labels for VoiceOver a pixel wide, not what clipping ancestors hide. Not an inline link in a line of text, not a group the page animates or transforms, not one under a box the page moves or turns (AG Grid's rows), not anything sticky, in a box that scrolls by itself, or in a row that scrolls sideways | `strip.js` `lookAt`, `group`, `room`, `extent`, `untouchable`, `anchor` |
| Bars that flex | The page's header at its top, beside the status bar (GitHub's), laid out by flex or grid, makes the room itself by padding on the strip's side, its buttons flexing together inside the safe area. Only while the page is still coming in, and only for a group the row lays out; a row given room has the controls near it looked at again | `strip.js` `lookAt`, `laidIn`, `atTop` |
| Layers | Asked for on 2 November 2026: use the page's layers (z-index) and draw what floats or sticks only inside the safe area. What is topmost at each place down the strip's column, as the page stacks it, into shadow roots however deep (Channel's chat card), and the box round it the page fixes in the window or makes sticky. A layer is drawn inside the safe area whatever the bands: a small one (a FAB, a chat button, a menu) moved by the strip's width, its margin from the window's edge kept, as far as the window allows on its other side; a wide one (a bar, a sheet) given padding on the strip's side with its width kept (`box-sizing: border-box`), its ground still under the glass. A fixed layer is out of the page's flow, so it is placed whenever the page is still; a sticky one's padding only while the page is still coming in. A control still under the strip in a padded layer (one placed absolutely, which the padding doesn't move) moves the whole way. Never the page's body, which a dialog fixes to stop the page scrolling behind it; a layer coming in by its own animation is looked at once that ends | `strip.js` `layerOf`, `placeLayer`, `probeLayers` |
| Boxes of controls | Asked for on 2 November 2026: "containers that wrap the interactable elements fit the safe area width" (a tab list, a composer card, naver's search box). The outermost box round something under the strip, up to six up, that draws itself (a background, a border) or is a control itself (a field, a full-width button), wider than a group, no taller than half the window: it ends at the safe area's edge, its insides laying themselves out inside it. One inset from the window's edges by a margin on the strip's side, with a greatest width so it can't grow past its row; one as wide as the window (a header's ground) by padding, its ground still under the glass. What was given room or moved inside it before gives it back. The observer watches the four boxes round each control too, so a tab list whose tabs don't reach the strip is found. Only where the page may still be laid out (before the first touch, or below the window) | `strip.js` `container`, `narrow`, `lookAtBox` |
| Lists | Asked for on 2 November 2026: "rows in the same table have to get same width". Three to forty boxes alike (the same kind, most of their classes the same) in one parent, each no taller than a few lines, are a list's rows: the box standing where a group stands in its row (alike, as deep, nearest from side to side) is found in each, and they move as one group, by where the list as a whole stands, so the rows keep one width and their controls one column, never row by row. Every row moves as far as the farthest needs: a row whose text is in the way has that text end where the list leaves room, in one go (its block's padding set so; also a line whose own block had no room, as a title beside its row's "…"), and the list is looked at again. Where some row still can't make the room, the list moves as far as all its rows allow, together; a row with hardly any room stays where it is. A row moved on its own before comes back to move with the list | `strip.js` `listOf`, `standing`, `moveList`, `widen` |
| How it moves | The script's own Web Animations on `translate`, which leave the page's `animation` and `transition` alone and reach into shadow roots (Channel's chat button) with no style sheet. Scrolling with the page: a view timeline on each member (`ViewTimeline`), whose progress is where it stands in the window, so content added above it doesn't throw it off; keyframes at each band's edges and slants, which WebKit runs with the scroll. Fixed in the window: held where it stands. Probed on the simulator: progress was (window height − top) ÷ (window height + height), as the specification has it | `strip.js` `animate`, `slope` |
| When it works | Never while a finger is on the page or within 300 ms of the page's own scroll; in slices of 4 ms, each started just after a frame is drawn, the page's own work between. Nothing is measured again while the page moves, and what was moved is never measured again. A new strip side or width starts over; new bands re-key the animations and look again at what was left | `strip.js` `pump`, `work`, `schedule` |
| Cost | On github.com in the iOS 27.2 simulator: slices of 1 ms or less once the page has come in; the first, during the load, about 110 ms, nearly all of it GitHub's own layout forced by the first read. Layout written while the page moved or a finger was on it: none (counted). Before 2 November 2026 every look took 130 to 880 ms there, three times a second | `strip.js` `state` |

Designed anew on 2 November 2026 after the Duo showed the old script moving nothing and the scroll still jumping: two independent Codex designs, one leaning on WebKit's own insets and per-site rules, one on per-element moves that can't lay the page out while it scrolls; the second was chosen.

Tried on the iOS 27.2 simulator, closed: apple.com (header icons and country banner), naver.com (header, search box buttons, cards' "…" passing the bands), github.com signed out (header), channel.io (its sticky header padded, its chat card in a nested shadow root moved whole), and the test pages in `Tests/StripPages` built with shadcn/ui, Radix and AG Grid (`npm run build && npm run serve`): a dashboard like GitHub's signed in, its chat button moved into the safe area; Radix's primitives, the sticky bar padded; and AG Grid. Also with `-stripUnplaced YES` (debug builds), which drops the items' frames as the Duo itself seems to: every control under the strip moves by its whole width.

### Patterns still to treat

Surveyed by Codex on 2 November 2026 (common sites and component libraries against the script as it then stood), treatments designed here. None is built yet; most need the page to be still and may lay the page out only where it may be (before the first touch, or below the window), like the rest.

| Pattern | What goes wrong beside the strip | Treatment |
|---|---|---|
| Chat composers and search fields that appear or grow while the keyboard is up | New work waits while the keyboard is up, so Send or the clear button stays under the strip while typing | On focus, place the focused field's own layer or box at once (a fixed composer by its layer, a box by `narrow`): the keyboard coming is a change the person made, and the field is what they look at |
| Tables, carousels, tab and chip rows that scroll sideways | Their last column, card or tab can't scroll clear of the strip; arrows stay where they are | End room inside the scroller: `scroll-padding` on its strip side (snapping stops inside the safe area, no layout), and an end spacer the strip's width (only its scroll width grows). Arrows outside the track are controls like any other |
| Panels that scroll by themselves (a chat's history, Notion's side panels, Radix Scroll Area) | Their controls pass behind the strip's items as the panel scrolls; the page's scroll doesn't move them | Treat the panel as a page of its own: bands in the panel's box, view timelines whose source is the panel (a view timeline takes the nearest scroller), the trapezoid inside it |
| Sticky table headers, sticky first columns, pinned action columns | A header cell moved alone leaves its column; pinned actions stay under the strip | A column is a list: the header cell and the body cells standing under it move as one group; pinned columns (AG Grid's) by their own scroller's box, rows placed by transforms read from the grid's row model where it says (`row-index`) |
| Lists drawn as needed (TanStack, react-window, AG Grid) | Rows placed by transforms are left; reused rows keep old moves | Narrow the list's scroller (`narrow`) before it draws, so it lays its rows out inside the safe area itself; never move its rows |
| Dialogs, sheets, drawers | Children with a fixed width or a scroller of their own keep actions under the strip | A dialog (`role=dialog`, `aria-modal`, `<dialog>`) opening is placed whole as a layer, and its insides get `max-width: 100%`; its close button moves the whole way (as now) |
| Embedded frames (YouTube, maps, ads) | Their controls, out of reach of the page's script, stay under the strip | Narrow the frame as a box: embeds lay themselves out to their frame. Same-site frames could get the script themselves later |
| Video players | Native controls can't be reached; custom bars split if one button moves | Narrow the `<video>` or the player's box; a control bar is a box of controls and is narrowed whole |
| Sliders | The thumb's end of the track stays under the strip | A box holding a slider (`role=slider`, `input[type=range]`) counts as a box of controls even when it draws nothing |
| Pagination | Next and Last stay under the strip in a crowded row | A `nav` holding `aria-current="page"` or next/previous is a box of controls: narrowed whole |
| Widgets shown by a class or an attribute (Bootstrap's collapse, Radix kept mounted) | A control looked at while hidden is never looked at again | Watch `class`, `hidden`, `open`, `aria-expanded` and `data-state` too, and look again at what changed |
| Listboxes, trees, grids with an active descendant | Their items aren't in the script's list of what can be pressed | Add `option`, `radio`, `treeitem`, `gridcell`, `menuitemradio`, `menuitemcheckbox` |
| Pinch zoom, desktop-width pages | Nothing new is worked out while pinched in | Keep waiting while pinched (the person is looking closely), but work while a desktop page sits at its own scale |
| Canvas apps (Figma), full-screen scroll-snap pages | What they paint can't be found or moved | Where a canvas or one snapped section fills most of the window, the page stops at the strip as a rectangle (the native safe area): the one case Design A's mode fits |
| Pages that move by themselves, Reduce Motion | The trapezoid adds sideways motion | Under Reduce Motion, groups move the whole way and hold, with no slant |
| Big pages and busy feeds | A whole subtree's controls are queried in one go | Query added subtrees in slices, capped, the rest at the next slice |

Machine learning, considered and not used: which elements can be pressed is in the page itself (links, buttons, fields, roles, `onclick`, `tabindex`, a pointing hand), read in a few milliseconds and the same on every device. Apple's on-device model (FoundationModels) took 2 to 4 seconds an answer on this Mac, would move buttons seconds after the page shows, and is not on every Duo; Core ML has no model for this and nothing to train one on. There is no "Core AI" framework in the iOS 27.2 SDK.

Not done: a list one of whose rows can't make the room moves only as far as that row allows (aligned, but partly under the strip's items then); AG Grid's pinned column stays under the strip, its rows placed by transforms; a slider whose thumb sits in a transformed box keeps its end under the strip; a carousel's last card can stay partly under the strip's items, since only a swipe moves it;  a wide sticky bar that comes in after the first touch keeps its ends under the strip; nothing new is worked out while the page is pinched in or the keyboard is up; view timelines stop at the scroll's ends, so a moved group doesn't follow the elastic bounce (WebKit's source, not seen on the Duo); the Duo itself, and the open Duo's Split View, are untested.

## Sources

Apple, read on 21 October 2026:

- Human Interface Guidelines, Designing for iPhone Duo: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
- Preparing your app for iPhone Duo: https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
- Three steps to make your app shine on iPhone Duo: https://developer.apple.com/iphone-duo/prepare/
- Prepare and submit your apps for iPhone Duo: https://developer.apple.com/news/?id=kkphp5qo
- Tech Talk 111461, Prepare your app for iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111461/
- Tech Talk 111462, Raise the bar with iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111462/
- Tech Talk 111463, Strike a pose with adaptive layouts on iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111463/
- Tech Talk 111464, Leverage multiple displays and scenes on iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111464/
- Tech Talk 111466, Design for iPhone Duo: https://developer.apple.com/videos/play/tech-talks/111466/
- iPhone Duo Group Lab summary: https://developer.apple.com/forums/thread/847644
- `UIView.ReservedRegion`: https://developer.apple.com/documentation/uikit/uiview/reservedregion
- `reservedRegions(kind:options:)`: https://developer.apple.com/documentation/uikit/uiview/reservedregions(kind:options:)
- `verticalBarEdge`: https://developer.apple.com/documentation/uikit/uitraitcollection/verticalbaredge
- `preferredVerticalBarBehavior`: https://developer.apple.com/documentation/uikit/uiviewcontroller/preferredverticalbarbehavior
- `UIHingeInteraction`: https://developer.apple.com/documentation/uikit/uihingeinteraction

Code, read the same day: `App/Sources/Browser.swift`, `PhoneBar.swift`, `SideTabs.swift`, `Menus.swift`, `SettingsView.swift`, `Page.swift`, `AppDelegate.swift`, `PadCore/Sources/PadCore/SiteMode.swift`, `Preferences.swift`, `PadCore/Tests/PadCoreTests/CloudAndSiteModeTests.swift`, `Marketing/AppStore/source/README.md`, `Validation/CHECKLIST.md`.
