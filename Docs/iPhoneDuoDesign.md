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
| The bands | Where the strip is taken, top to bottom, in the page's points: the status bar's and the cameras' occlusion regions, and the strip's items' frames (`UIBarButtonItem.frame(in:)`), each 8 points further out, merged where they touch. The system draws the strip outside the app's windows, and no API places its overflow (…): it is taken as one more item 23 points under Forward, as measured on the iOS 27.2 simulator | `Browser.stripCover`, `StripItems.frames`, `DuoLayout.stripBands` |
| The slant | Beside a band, a group is moved all the way; 44 points (a finger) or more away, not at all; between, in proportion | `strip.js` `cover` |
| Text | Each block of running text whose lines reach past the safe area's edge gets that much more padding on the strip's side, the outermost block only; a block that grows wider for it is sized to hold it (`box-sizing`), and one that still grows gets none, for the page's life. The room is kept from look to look and only grows: its need is worked out from the block's box and the page's own padding, read once, never by taking the padding away to measure, which rewrapped the text and moved the page under the finger (GitHub, 2 November 2026: a jump of a line every 0.3 s while scrolling). Not a button's label, nor text in a row that scrolls sideways or in something typed in. Asked for on 2 November 2026 in place of re-wrapping text along the slant as it scrolls, which would lay the page out at every frame, move words between lines under the reader and shift the page | `strip.js` `textBlocks`, `giveRoom` |
| What moves | The smallest group round a link, button, field or anything the page gives a pointing hand (sampled down the strip's column, into open shadow roots), climbing while no wider than 60% of the window and no taller than its row. Its level neighbours within 40 pixels join it and move by the same amount, so a header's icons keep their gaps. It goes only as far as the room before the next neighbour, 8 pixels kept; a block of text in the way wraps sooner to give the rest; a fixed bar's flex or grid row gives padding when a group in it has no room (naver's search beside its tabs). Measured by what boxes show: the text and painted boxes in them, not labels for VoiceOver a pixel wide, not what their clipping ancestors hide. Not an inline link in a line of text, not a group the page animates or translates, not one whose moving would change what its placed insides hang from, not anything in a row that scrolls sideways | `strip.js` `group`, `room`, `extent`, `visible`, `untouchable`, `anchor` |
| Bars that flex | A bar's row laid out by flex or grid makes the room itself, by padding on the strip's side, its buttons flexing together inside the safe area: a bar the page fixes or makes sticky, and the page's header at its top (GitHub's, beside the status bar). Only for a group the row lays out, and only if the padding carries nothing slid already: a button placed absolutely in the row (Apple's menu) slides, with its neighbours, as a cluster | `strip.js` `plan`, `laidIn`, `atTop` |
| How it moves | `translate`, from constructed stylesheets the document adopts, by a number on each group (`data-eglu-strip`): a `<style>` would be refused where a page's Content-Security-Policy allows no inline style (DuckDuckGo's). Fixed in the window: by where it stands. Scrolling with the page: keyframes on `scroll(root block)` with a range in pixels of scroll, which WebKit runs with the scroll. Sticky, in a box that scrolls by itself, or fixed inside something that moves: by script at each frame of a scroll. Inside a shadow root (Channel's chat button), which the sheets don't reach: its own style, set by the script | `strip.js` `look`, `move`, `slant`, `follow` |
| When it looks | Only once the page's own scroll has been still 300 ms (a box scrolling by itself doesn't count), so nothing changes under the finger. Then: the strip told, a tap (350 ms and 1.2 s later, for a menu or a widget coming in), a scroll once it stops (for a header the page hides), the window's size, at most every 600 ms; the page's own changes (nodes, classes, sizes, shadow roots on the body and those sampled, fonts, the load) at a pace that doubles, up to 5 s, while looks change nothing. What was moved is measured by holding just those boxes in place with their own style, which reflows nothing; the sheets are written only when their rules change. A new strip side or width starts over; new bands alone don't | `strip.js` `soon`, `watch`, `look`, `hold` |
| Cost | On github.com in the iOS 27.2 simulator: the first look about 500 ms, then 10 to 30 ms. Before the rework of 2 November 2026 every look took 130 to 880 ms there, three times a second, which kept the page from answering taps after a scroll | |

Tried on the iOS 27.2 simulator, closed: apple.com (header icons and country banner), naver.com (header, search box buttons, cards' "…" passing the bands), channel.io (sticky header's three controls, the chat button out from under New Tab and Tabs), news.ycombinator.com (titles and links wrapping, login out from under the camera), html.duckduckgo.com (text wrapping under its Content-Security-Policy, its clipped selects left alone).

Machine learning, considered and not used: which elements can be pressed is in the page itself (links, buttons, fields, roles, `onclick`, `tabindex`, a pointing hand), read in a few milliseconds and the same on every device. Apple's on-device model (FoundationModels) took 2 to 4 seconds an answer on this Mac, would move buttons seconds after the page shows, and is not on every Duo; Core ML has no model for this and nothing to train one on. There is no "Core AI" framework in the iOS 27.2 SDK.

Not done: a carousel's last card can stay partly under the strip's items, since only a swipe moves it; a wide control in a fixed bar that is not a flex or grid row (Channel's wide "ask by chat" label) keeps its end under the strip; a page zoomed in by pinching is measured as it stands, not followed as it pans; the open Duo's Split View, where the strip stands beside one app, is untested.

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
