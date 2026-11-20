# Validating on a real iPad

What the tests in `Tests/` can't show: a real trackpad, a real keyboard, real sign-ins, real memory. Turn on the Diagnostics panel first (⌃⌥D, or Settings › Show diagnostics); most checks below read from it.

Last run: 2026-10-02, iPad Pro 13-inch (M5) on iPadOS 27.0, built with Xcode 27.0; Safari 27.0 on macOS 27.0. Results are under each section.

The panel's lines:

| Line | Reads |
|---|---|
| 1 | The site adapter, desktop or mobile pages, heavy or light |
| 2 | Page zoom, WebKit's scrolling, the scroll view's own pinch |
| 3 | Whether the page's `navigator.userAgent` is the Mac Safari string the app sends |
| 4 | Pinch steps, ⌘ zoom steps, wheel events bridged, and bridged events held back because WebKit sent its own |
| 5 | WebKit's own wheel events the page received, and the last bridged outcome |
| 6 | The wheel bridge mode, keys sent to the page, keys relayed, whether the focus is in a text field |
| 7 | Live and frozen tabs, and how many times this page's process ended |
| 8 | The cursor: the page's own picture (its size and hotspot), none, or the system's pointer |
| 9 | Ad blocking: on or off for this page, and the lists' rule count and dates |

## 1. Figma zooms on a synthetic ctrl+wheel (Mac Safari)

The pinch bridge rests on this, so check it first.

1. On a Mac, Safari › Settings › Advanced › Show features for web developers.
2. Open a Figma design file in Safari and click once on the canvas.
3. Develop › Show JavaScript Console, paste all of [figma-ctrl-wheel.js](figma-ctrl-wheel.js), press Return.

- [x] It prints `PASS: Figma zooms on a synthetic ctrl+wheel.` and the canvas zooms in, then back out.
- [ ] If it prints `LOOK:`, the zoom couldn't be read: the canvas should still zoom in and out.
- [x] Note `strength` and `pinchFactor`. Strength 1 means the zoom follows the pinch; `pinchFactor` is what Figma's adapter needs for it to (`Adapters.swift`).

Result: PASS. Figma took all 10 events and zoomed from 1.00 to 1.415: strength 0.50, pinchFactor 199. Measured one event at a time, Figma in Safari zooms by e^(−deltaY/200) for events up to 30, and less for bigger ones. The first version of the script asked for 1.5 and printed FAIL; it now passes at 1.1.

The same works inside the app: connect the iPad to the Mac, open the file in eGlu, and pick its page under Safari's Develop › (your iPad). Every page in the app is inspectable.

## 2. Trackpad and keyboard in Figma

Open a design file in eGlu, with a Magic Keyboard or a trackpad.

- [ ] Line 1 says Figma, desktop pages, heavy. Line 3 says Mac Safari.
- [ ] Hovering layers and frames highlights them; clicking selects; dragging moves.
- [ ] Pinching on the trackpad zooms the canvas around the pointer, not the whole page. Line 2 stays at zoom 1.00; line 4's pinch count goes up.
- [ ] ⌘ and two fingers zoom too.
- [ ] Two fingers pan the canvas. On line 5, if WebKit's own wheel events stay at 0, the bridge is doing the panning (line 4's bridged count goes up); if they go up, WebKit sends them itself and the bridge stands aside. Either way, note which.
- [ ] A quick two-finger flick keeps gliding for a moment, as on a Mac (only when the bridge does the panning).
- [ ] Figma's own cursors show, not the iPad's round pointer: its arrow on the canvas, and the frame, pen, comment and color picker tools' cursors, and the rotated arrows on a selection's corners and edges. Line 8 names the picture's size and hotspot. Over a panel's text or a field, the iPad's beam shows instead, as WebKit chooses.
- [ ] While dragging a layer, the cursor follows the pointer without jumping; after letting go, it doesn't blink to the iPad's pointer.
- [ ] With Settings › Show pages' own cursors off, the iPad's pointer is back everywhere.
- [ ] A secondary click (two-finger click) shows Figma's menu, and only Figma's.
- [ ] ⌘-click on a layer selects it and opens no tab.
- [ ] ⌘Z and ⇧⌘Z undo and redo in Figma. ⌘C, ⌘V copy and paste layers. ⌘F opens Figma's own find. ⌘D duplicates.
- [ ] Arrow keys nudge a selected layer; ⇧ and an arrow nudge by 10. Tab selects the next layer. If either doesn't reach Figma, turn on Settings › Tab and arrow keys › Send to the page first, and check again; note which setting works.
- [ ] Two fingers swiping sideways never goes back a page.
- [ ] Long-pressing a link or image with a finger shows no callout.
- [ ] Switch to another app and back, or click another Stage Manager window and back: typing a Figma shortcut works at once, without clicking the page first.
- [ ] On iPadOS 26, the menu bar shows the app's Go, Tabs, Spaces and Window menus, all on ⌃⌥, and none of the system's File, Edit, Format, View or Help. Hold ⌘: the shortcut list shows no ⌘ shortcut of the app's.

## 3. Sign-in, for every tool you use

For each tool, sign in from a fresh space (Spaces › New Space…, so nothing is signed in yet) with each method it offers. The address bar should show on every sign-in page with the host in bold.

Edit the rows to your own list of tools.

| Tool | Google | Email and password | SSO | Address bar on sign-in | Notes |
|---|---|---|---|---|---|
| Figma | | | | | |
| Google Workspace (Drive, Docs) | | n/a | | | |
| Slack | | | | | |
| Notion | | | | | |
| Linear | | | | | |
| Miro | | | | | |
| Jira / Confluence | | | | | |

For each:

- [ ] A sign-in in a pop-up opens over the page as a sheet with its address on top, and closes by itself when done.
- [ ] On accounts.google.com, line 1 says hands-off, nothing injected, and line 3 says the user agent is not read there.
- [ ] If Google refuses ("This browser or app may not be secure", or Error 403: disallowed_useragent), a banner says so and points to email or SSO; Go Back returns to the tool's sign-in page.
- [ ] After signing in, quit the app (swipe it away) and open it again: still signed in.
- [ ] Two spaces signed in to two different accounts of the same tool stay apart.
- [ ] Passkey buttons are expected to fail: passkeys are out of scope (see README).

## 4. Memory, with a large Figma file

1. Open the heaviest Figma file you have (a design system, a file with many pages and images). Note how long it takes to become usable.
2. Open three more tabs: Slack, Notion, and a second Figma file.
3. Switch between them while watching line 7.

- [ ] The first file stays live while you visit Slack and come back (no reload, same view).
- [ ] Opening the second Figma file freezes the first: going back shows its picture at once, then the file loads again underneath.
- [ ] More than two light tabs off screen freeze, oldest first (Settings › Light tabs kept open changes the number).
- [ ] A tab with something typed but not sent (a message half written in Slack) doesn't freeze.
- [ ] If the file runs out of memory, the tab reloads by itself and line 7's process ends count goes up. After three in a minute, a banner offers Reload instead of reloading again.
- [ ] With Xcode's Instruments (Activity Monitor template, the iPad as target), note the peak memory of the `com.apple.WebKit.WebContent` process for the file. This is the number iPadOS limits, and no setting can raise it.

## 5. Windows

- [ ] ⌃⌥N opens a second window (Stage Manager or Split View). Each window shows its own tab; choosing a tab that the other window shows brings that window forward.
- [ ] A tab's menu (long press or secondary click on it) › Open in New Window moves it there.
- [ ] Close the app and open it again: each window comes back with its space and tab.

## 6. With Apple's browser entitlement

On a build signed with it (README › With Apple's browser entitlement).

- [ ] eGlu's Settings › Default browser › Make eGlu the Default Browser opens Settings › Apps › Default Apps; choose Browser App › eGlu. Back in eGlu's Settings, it says eGlu is your default browser.
- [ ] With eGlu the default browser, a link tapped in Messages or Mail opens in a new tab and shows at once: with eGlu on a page, with Settings open (it goes), with the tabs' tiles open (they go as the page comes), with a pinned tab on screen, and after eGlu was closed from the app switcher or left in the background for hours. A page's own alert stays up, the new page under it.
- [ ] A link tapped in Mail, Notes or Slack opens in eGlu, in a new tab after the one on screen, which stays as it was.
- [ ] On a site that offers passkeys (Google, GitHub, Figma if offered), signing in with a passkey shows the system's passkey sheet and signs in.
- [ ] Creating a passkey on a site saves it in the Passwords app.
- [ ] The key button above the keyboard lists the site's own passwords without searching, and a verification code field offers the code.
- [ ] Share Page (⌃⌥S, or the tab's menu) shows the share sheet with Add to Home Screen; the icon it adds opens the page.
- [ ] On a page opened at an address with `?id=7&utm_source=letter&fbclid=x`: the share sheet's Copy, the page's menu's Copy Link (… on iPhone, the tab's menu on iPad), a link's Copy Link and Share…, and the tab overview's Copy Link all give the address with `id=7` alone. A YouTube link shared from its app (`?si=…`) and an X post's (`?s=20&t=…`) lose those; `?t=42` on YouTube stays.
- [ ] A site with a service worker (an offline-capable web app) registers it: Diagnostics or the site itself says so.

## 7. Compact tabs, pinned tabs, bookmarks, spaces

- [ ] One row: the space's button in its colour, back and forward, pinned icons, tabs at one width, + and ⌘. The tab on screen shows a close button, its host with the name that matters in bold, the key badge on a sign-in page, the star and reload; it alone is in Liquid Glass.
- [ ] Clicking another tab only goes to it: no tab changes width. Going to a pinned tab keeps it an icon, unless its page is a sign-in page.
- [ ] Clicking the tab on screen: its host turns into the address, selected, in place, then the field widens over the other tabs without moving them; typing replaces it; Return goes; a click on the page or Escape takes the field back into the tab the same way, and the tab is as it was.
- [ ] Settings › The tab you are on shows › Its title: the tab shows the page's title, and its host on a sign-in page.
- [ ] With Settings › Show the tab bar off, the row still shows on a sign-in page and on a new tab.
- [ ] Split: a tab's menu › Open in Split View puts it beside the tab on screen, both as one tab in the row; a click in either pane moves the keys, the glass half and the coloured ring to it; the two pages are cards with the frame's corners and gap; the divider drags, settles in the middle with a tap when let go near it, and a double tap centres it; the + button's menu › New Tab in Split View opens a new tab beside, typed into; closing a pane leaves the other full width; the split comes back the same after relaunch.
- [ ] Drag to split (iPadOS 27): a tab dragged from the row along the top onto the page shows Open on the Left and Open on the Right; the side under the finger grows to the pane, ringed in the space's colour, with a tick; let go there and it opens on that side with the keys; over a split it takes that side's place; the other pane's tab carried across swaps them; let go in the middle, nothing changes; the same from the sidebar; under Reduce Motion the sides change in place.
- [ ] With the Korean keyboard, typing github.com in the command bar and pressing Return goes to github.com, the last letter included.
- [ ] Pin a tab from its menu: it becomes an icon at the front. Go elsewhere in it, then close it (⌃⌥W): it stays, and opening it shows its pinned page again. In a space whose only tab is pinned, closing it shows the space's start page, not a blank one. Unpin puts it back among the others.
- [ ] Pin vercel.com and mobbin.com, in light and dark: each tile shows its icon over a faint glow, on screen and off (Vercel's black disc whole; Mobbin's M black in the light, white in the dark).
- [ ] Pin notion.so, news.ycombinator.com, figma.com, github.com, google.com and discord.com; open three, then close one of them (⌃⌥W) and relaunch. In the sidebar and the top row (iPad and Mac), light and dark: each tile's icon is the same mark on the same glow whether its tab is on screen, open behind or closed, and does not change as you go from tile to tile, nor on the Mac in a window behind; only the tile on screen has tinted glass, and only its glow drifts. White marks (Hacker News's Y, Discord's) are still clear on a tile with untinted glass. On iPhone, hold the pinned button: every row of the list shows its icon as the button does, the tab on screen's included, with no change as the button grows into its row; the row under the finger still glows and is tinted, and in the dark the light round its icon is not washed out to white.
- [ ] Import Chrome's export, then Safari's ZIP (Settings › Apps › Safari › Export › Bookmarks), into one space: the grid on a new tab shows them, the second import of the same file adds nothing, and another space's grid stays empty.
- [ ] The star adds and takes away the page; a bookmark's menu opens it in a new tab or deletes it; ⌃⌥K finds bookmarks by name.
- [ ] Tabs in a sidebar (iPad and Mac): Bookmarks over New Tab brings the bookmarks out over the list as a card with ✕, not as rows among the tabs; a tap on one opens it in the tab on screen and the card goes; ⌘-click (a keyboard and trackpad on iPad) opens it in a new tab and the card stays; a folder opens in place; ✕, Escape, a tap outside the card or on the page, and another space each put it away; light and dark.
- [ ] A toast at the page's top right, in Liquid Glass, for about two seconds: Copy Link (⌃⌥⇧C on iPad, ⇧⌘C on the Mac, the page menu, a tab's or a bookmark's menu, a link's) says Link Copied; the star or ⌃⌥⇧D says Added to or Removed from Bookmarks; Allow or Block Ads on This Site says so; another copy at once replaces it; taps and clicks go through it; VoiceOver reads it; on iPhone it is below the status bar.
- [ ] Space Settings changes the name, colour and icon at once in the bar; Settings › Spaces › Edit reorders, and ⌃⌥↑ ⌃⌥↓ follow the new order.

- [ ] Settings has nothing written under App icon, Desktop View, Trackpad and keyboard, Diagnostics or Shortcuts, and nothing under Default browser once eGlu is the default. The filter lists' credits show beside each list, in Ads and trackers › Filter lists.
- [ ] Settings › App icon: Engineer's globe looks the size of the other icons' globes, with clear room under the title bar and over the icon's bottom edge.
- [ ] Settings › App icon and the Home Screen, light, dark and tinted: the default icon, eGlu, is the white glass "e" globe with its cursor on a blue ground (near-black in dark, its e blue and its cursor white); Globe, first after it, is the oval globe in pale blue on a sky-blue oval, its rim ridged on the left, with a dark navy cursor; Punk's spray can leans in as the pointer with its cap toward the globe; Astro's pointer is a glass shuttle with a glowing flame; each still reads as a pointer at the Home Screen's size.
- [ ] Settings › App icon: choosing Designer changes the Home Screen icon after the system's notice; choosing eGlu puts the app's own back. Updating from 1.0.7 or earlier with the default icon shows eGlu; choosing Globe brings back the old look. With Diazo, Lilac, Oxide, Citrus or Midnight chosen in an earlier build (the names Designer, Vista, Hardcover, Punk and Astro had then), note what the Home Screen shows after the update; nothing is ringed in Settings, and choosing the icon again there sets it. Designer is a globe in lines of one weight with square anchor points at its left, right and bottom, a light blue square of the same size at its top and two light blue handles out level from it, each ending in a dot, under the pen tool, in Settings and on the Home Screen. Punk is the globe sprayed in black on an acid-lime wall in light and in lime on black in dark, with a chrome spray can in the lower right leaning toward it, cut off by the icon's edge and solid (the wall doesn't show through it), in Settings and on the Home Screen.

## 8. iPhone, iPhone Duo, iCloud

- [ ] On an iPhone, the bars are at the bottom: the address with the menu beside it (no star in the address, no downloads button: … has Bookmark This Page and Downloads), and under it back and forward on one capsule at the left, + on a larger capsule in the middle of the screen, faintly in the space's colour, and the tabs (with their count) at the right. At the top of the tabs, the space's button with its name: another space chosen there shows that space's tabs, and New Space… or Space Settings… puts the tabs away first. On an iPhone SE or mini, and in an iPad window a third of the screen wide, + is still in the middle and nothing overlaps. Tapping the address types a new one, the address selected, with the bar above the keyboard; Return goes.
- [ ] A site's mobile version loads (the page names an iPhone); it scrolls and pinches with a finger. Menu › Request Desktop Site loads the desktop version, and the site keeps it next time.
- [ ] A long page (a Wikipedia entry, a news story) scrolled to its end: its last line and the links at its foot come up over the bar, and nothing of it stays under. The bar is still over the page while it scrolls, the page showing through its blur.
- [ ] A page that only fills the window: google.com (its foot with Settings, Privacy and Terms), a sign-in page, a chat with its field at the bottom (chatgpt.com, claude.ai), an editor with tools at the bottom (excalidraw.com). Its bottom row shows above the bar and takes a tap; the bar has the colour of the page's last points. It may show under the bar for a third of a second as the page comes in. From such a page to a long one (a search from google.com) the page runs under the bar again, and its end still scrolls clear.
- [ ] A site's own menu over the page (the ☰ on theverge.com, apple.com, a news site's): a moment after it opens, the bar's wash takes the menu's colour, and the page's again once it closes.
- [ ] With the keyboard up in a page's own field at the bottom (a chat), the field stays above the keyboard, and when the keyboard goes the page is as it was. Turned sideways and back, the same.
- [ ] The tabs button shows the space's tabs as a grid; a tap goes to one, × closes one, + opens a new tab.
- [ ] With more pinned tabs than the dock at the bottom of the tabs has room for (ten on a Pro Max), the dock scrolls sideways, and an icon half out at either end is cut along the dock's rounded end, nothing of it past the outline.
- [ ] Turned sideways, an iPhone keeps the bars at the bottom (a Pro Max turns to the iPad's row) and keeps mobile sites.
- [ ] On an iPhone Duo: folded, the bars are at the bottom and sites are mobile; unfolded, the iPad's row comes back and sites load as desktop on the next page. Folding or unfolding mid-typing carries what is typed over to the other field, the cursor at its end.
- [ ] On an iPhone Duo closed: the strip beside the screen has back and forward at its top, … under them with the page's menu, and + and the tabs (with their count) at its foot; the bar at the bottom is one row, the space and the address, and the page starts at the top of the screen. Behind the strip the page's edge goes on across it: beside a coloured header the header's colour, beside a gradient (apple.com/family-sharing) the gradient, beside a white page white; below it the bar's ground. It follows the page as it scrolls, eased, and the strip's buttons stay readable on it. On a site's start page and in Desktop View the strip has the window's own colour. Typing an address hides the space and the strip moves + into its …. The tabs from the strip while an address is typed end the typing; + or anything else from the strip with the tabs out puts them away first, and the tabs again only puts them away. A sideways swipe on the bar brings the next tab's row in from the strip's edge, not from under it. The tabs' Done stays clear of the strip.
- [ ] On an iPhone Duo open, upright and turned: the same tools stand in the strip beside the status bar, the iPad's bars along the top with nothing above them; Tabs in the strip shows the tab bar, and again hides it; with Settings › Window › Tabs › In a Sidebar, the strip has no Tabs.
- [ ] On an iPhone Duo opened like a book, with the tabs in a sidebar: the sidebar reaches the fold and the page starts past it; closed and opened again, the same.
- [ ] In the iPhone's tabs, touch and hold a card, then move it: the tab goes there, in the iPad's row and sidebar too. A quick sideways swipe still closes a card.
- [ ] An iPhone with a keyboard attached: the command bar's rows show their keys, and Settings has Keyboard (the Tab and arrow keys), Shortcuts and Known limitations; with the keyboard gone, none of them.
- [ ] In Desktop View on iPhone, a pinch past the closest or the farthest zoom gives a little and springs back as the fingers let go.
- [ ] Settings › iCloud › Sync Spaces and Bookmarks on two devices with the same account: a space of the same name joins with both devices' bookmarks; a bookmark added on one shows on the other within a minute; a space removed on one goes on the other; tabs and sign-ins don't move.
- [ ] Signed out of iCloud, Settings says to sign in.

## 9. ⌘-click

On any site with links (a news site, GitHub), with the trackpad:

- [ ] ⌘-click on a link opens it in a new tab after the one on screen, which stays as it was. Two more ⌘-clicks put their tabs after the first, in order.
- [ ] ⌘⇧-click on a link opens it and goes to it.
- [ ] With a mouse, the middle button opens the link behind.
- [ ] A link that opens a new window by itself (Slack's, Notion's) opens behind with ⌘ and in front without it.
- [ ] ⌘-click on a search button (Google's, Wikipedia's) opens the results in a new tab; ⌘-click on a form that sends something (a comment's Post) sends it once, in place.
- [ ] A plain click on a link still goes there in place.

## 10. Ads and trackers

- [ ] A news site with ads (a newspaper's home page) shows no ad slots, and loads no Google Tag Manager or Analytics (Web Inspector's Network tab, or line 9 of Diagnostics says "on here").
- [ ] Menu › Allow Ads on This Site loads it again with its ads; Block Ads on This Site takes them away again; the choice stays for the site after a relaunch.
- [ ] accounts.google.com: line 9 says "off here", and line 1 "hands-off, nothing injected".
- [ ] Settings › Ads and trackers off: ads come back on every site from the next page; on again, they go.
- [ ] After four days with the app opened, Settings › Ads and trackers › Filter lists shows lists dated within the last week.
- [ ] Korean sites: on m.dcinside.com's gallery list no "AD" line shows under the heading and no "광고" row at the foot of the list; on clien.net no empty grey block sits between the notice board and the first list. With YousList off in Filter lists, both come back after a reload.
- [ ] Filter lists: EasyList, EasyPrivacy, YousList and the Adblock Warning Removal List are on; KoreanList is on too on a device set to Korean or to the Korea region, and a regional list on a device in its language. Each row names the list's authors and licence.
- [ ] Turning a list on that doesn't ship (EasyList Cookie List) says "Getting ready…", then its date and rule count within a minute; the Rules count in Settings goes up. In Airplane Mode it says "Not downloaded yet", and it comes after the app is opened again with a network.
- [ ] With the Cookie List on, a site with a cookie banner (a European newspaper) shows none after a reload.
- [ ] A page that opens an advertiser's window at a tap (a streaming or download site) opens none.
- [ ] Diagnostics' ad blocking line counts the filters kept for scripts. On a site with none of its own (example.com) Web Inspector shows no `blocker.js` or `scriptlets.js` among the page's scripts.
- [ ] A clean install: within a minute Settings shows the rule count, and Xcode's memory gauge stays under about 200 MB while the lists are made (it was over 300 MB).
- [ ] A site whose filters hide by what an element says (target.com's search results, signed out: the tiles marked "Sponsored"): the tiles are gone, more of them go as the page is scrolled and loads more, and scrolling stays smooth. In Web Inspector's Timelines, `blocker.js` shows as a millisecond or two after each batch the page adds, not tens.
- [ ] Turning a list off and on again quickly in Filter lists says "Getting ready…" at most once, and the Rules count is the same as before.

## 11. Address bar suggestions

In a space with a few tabs, a pinned tab and bookmarks, on iPad in each layout (Settings › Window › Tabs) and on an iPhone. On iPad the field is the command bar, floating over the page (section 16); on iPhone it is in the bar at the bottom:

- [ ] On an iPhone, the app closed from the app switcher and opened again: the first tap on the address brings the keyboard up with the address selected, and the bar stays where it is until the keyboard comes, then rides up over it. It never sits at the foot of the screen with its tools cut off. The second tap is as quick as it was. With a keyboard with keys attached, the bar makes room a moment after the first tap.
- [ ] Typing "fig" with figma.com open in a tab shows it first, "fig" plain and "ma.com…" in bold, its title under it and "Open Tab" at the end; Return goes to that tab rather than loading the page again.
- [ ] A pinned tab says "Pinned Tab", a bookmark "Bookmark", and "new" offers New Tab and New Space, with their keys drawn as keys on iPad and "Command" at the end on iPhone; choosing New Tab opens one, the command bar open for it.
- [ ] After a moment, Google's suggestions show under the first row, marked "Google"; choosing one searches for it. With Settings › Search engine set to DuckDuckGo or Bing they come from it and say so; with Kagi there are none.
- [ ] ↓ from the field chooses the first row, ↑ from it goes back to the field, and Return with no row chosen sends what was typed, as before. A tap or a click on a row takes it.
- [ ] Korean: typing 피그마 shows Google's suggestions while the last syllable is still being composed, and Return sends the whole word.
- [ ] Typing figma.com/ sends nothing to Google (Web Inspector's Network tab on the app shows no suggestqueries request), and Settings › Search engine suggestions off sends nothing at all while tabs and bookmarks still show.
- [ ] Escape, Cancel, a tap on the page, or going to another tab takes the rows away with the field. On iPhone the rows sit just above the bar and scroll when the keyboard leaves them little room.
- [ ] With Apple Intelligence on (iOS or iPadOS 26): "share this page" offers Share Page…, "탭 고정" and "pin this" Pin or Unpin Tab, "광고 차단" Block or Allow Ads on This Site, "email" an open Gmail tab, and a few words about a tab's subject that share no word with its title (a Figma file's topic) offer that tab, each a few seconds after typing stops, with sparkles beside its source. Two letters, or figma.com, never wait on the model.
- [ ] A plain web search typed with tabs and bookmarks open ("weather tomorrow", "lasagna recipe", "how to center a div") gets no row with sparkles, however long one waits; the rows with sparkles are as many as fit, none to five, never three every time.
- [ ] With Settings › Search engine suggestions off and Apple Intelligence on, searches marked Apple Intelligence show instead of Google's; with Airplane Mode on, they still do.
- [ ] Settings › Suggest with Apple Intelligence off: no sparkles. With Apple Intelligence off in the Settings app, on iOS 18, or on a device without it, Settings › Search has no Suggest with Apple Intelligence switch and says nothing of Apple Intelligence, and the app starts as before.

## 12. The phone bar's swipe, and a link's menu

On an iPhone, in a space with three tabs or more:

- [ ] A drag to the left on the bar brings the next tab in from the right, its page and its address both following the finger; letting go past halfway, or with a flick, goes to it, and short of that springs back.
- [ ] At the last tab a drag to the left moves a little and springs back; at the first, a drag to the right.
- [ ] A swipe up on the bar still shows the tabs, and while an address is typed a sideways drag only moves the text's caret.
- [ ] In Desktop View a sideways drag on the bar does nothing.
- [ ] A long press on a link lifts it with a menu under its address: Open in New Tab goes to it in a new tab, Open in Background adds a tab (the count goes up, with a tap felt) and stays, Copy Link puts the address on the clipboard, Share… opens the share sheet. A tap on the lifted link goes there in the same tab.
- [ ] On iPad at full width, a long press with a finger on a link on a plain page (a Wikipedia article) shows the same menu, and so does a secondary click with the trackpad, a moment after the click.
- [ ] On iPad, a secondary click on a link in a page with a context menu of its own (a file in Figma's file browser, a message in a web mail app, a row in GitHub's file list where the site has none) shows only the page's menu where it has one, never both.
- [ ] In Figma, on the canvas and in the file browser, a long press with a finger and a secondary click show only Figma's own menus.
- [ ] On accounts.google.com a long press on a link shows no menu of the app's.

## 13. Sites with their own menus, pictures, swipes, find

Sites with their own menus:

- [ ] Settings › Link menu › Sites with their own menus lists the built-in sites, each with a switch, and Add takes an address (`https://www.example.com/app` becomes example.com) and refuses a word that isn't one.
- [ ] On a plain page, the page's menu has Use This Site's Own Menus; after it, a long press on a link there shows nothing, the site is under Your sites in Settings, and the menu says Show Link Menu on This Site, which undoes it.
- [ ] With Figma's switch off in Settings, a long press on a link in Figma's file browser shows the app's menu; with it on again, only Figma's.
- [ ] In Google Docs, Notion, Linear and Slack, a secondary click and a long press show only the app's own menus; on google.com's results a link still has the link menu.

Pictures:

- [ ] A long press on a picture that isn't a link lifts it with Share…, Save to Photos, Copy and the rest; Save to Photos asks once to add to Photos and the picture is there afterwards.
- [ ] A long press on a picture that is a link shows the link's menu with Save to Photos at the bottom.
- [ ] On iPad, a secondary click with the trackpad on a picture in a page with its own context menu shows only the page's menu. (Not checked in the simulator, which has no pointer to click with.)

Back and forward by a swipe:

- [ ] On iPhone, a finger dragged in from the left edge slides the page before in, and from the right edge the page after.
- [ ] On iPad, on a desktop page with a page to go back to, a finger dragged in from the page's left edge brings an arrow in; letting go once it has filled goes back, and before that does nothing. With nowhere to go back to, no arrow shows and the page gets the drag.
- [ ] On iPad with a trackpad, on a plain page (a Wikipedia article reached from another), two fingers to the right bring the arrow in from the left and go back; two fingers to the left go forward.
- [ ] In Figma, on the canvas, two fingers sideways pan the canvas and never go back, however far and however often. The same in Miro, Google Sheets and a map.
- [ ] On a page with a row that scrolls sideways (a carousel, a wide table), two fingers sideways over the row scroll it, and a swipe that reaches the row's end doesn't go back. A new swipe begun at the row's end does, as in Safari on a Mac, and so does one away from the row.
- [ ] In a split view, each pane goes back by a drag from its own left edge.
- [ ] ⌘ with two fingers still zooms, and ⇧ with a mouse wheel scrolls sideways without going back.

The cursor at the page's top and bottom, in the iPhone's Desktop View:

- [ ] One finger down moves the cursor to the bottom of the page, and what the finger moves after that scrolls the page down; the cursor stays at the bottom. The same upward: at the top, the page scrolls up.
- [ ] With the cursor already at the bottom, a flick down scrolls and glides on, and a touch stops it. A flick that only gets the cursor to the bottom doesn't glide.
- [ ] Sideways along the bottom, and back up from it, scroll nothing.
- [ ] Zoomed in with a pinch, the view follows the cursor to the desktop's bottom first, and only then does the page scroll.
- [ ] Touch and hold, then drag past the top or the bottom: the page scrolls while the button is held.
- [ ] In Figma, the cursor pushed against the top or the bottom pans the canvas, as two fingers do.
- [ ] On a page laid out as an app (a chat, a mail client: a bar of its own at the top or the bottom, and a list between them that scrolls by itself), the cursor pushed against the bottom rests on the page's bar and the list scrolls down all the same; against the top, up. Two fingers with the cursor on the bar do the same.
- [ ] With the cursor over a list that is at its end, pushing on scrolls nothing else on the page.
- [ ] On a long page with a frame in it that has nothing to scroll (the page's own, or another site's: a video's player, a map), the cursor left over the frame and pushed against the bottom scrolls the page.
- [ ] A page that scrolls inside its body (`html, body { height: 100%; overflow-x: hidden }`, as many a React app has) scrolls with two fingers and with the cursor at the bottom.
- [ ] A page of full-screen sections that snap (`scroll-snap-type: y mandatory`) goes one section a stroke, not to its end.
- [ ] A PDF in Desktop View scrolls with two fingers and with the cursor pushed against the bottom or the top.

Pull to load again, and find:

- [ ] On iPhone, at the top of a page, a pull down shows the spinner and loads the page again; the spinner goes when the page is back.
- [ ] On iPad, on a desktop page, and in the iPhone's Desktop View, a drag down does nothing of the kind.
- [ ] Find on Page (⌃⌥F, or the page's menu) shows the find bar; a word typed is counted and marked, and the arrows go from one to the next. After the bar is closed, ⌘F in Figma is Figma's again.

## 14. Links for other apps

- [ ] A `tel:` or `mailto:` link, and a link with an app's own scheme, opens that app at once when tapped.
- [ ] On a site with an "Open in app" button (instagram.com or youtube.com on an iPhone, with the app installed): the button asks "Open in Another App?", naming the site; Open goes to the app, and coming back, no empty tab has been left behind.
- [ ] Cancel, then the button again: it asks again. A second Cancel, and it asks no more until the page is loaded again.
- [ ] A link to Instagram or YouTube in a search's results opens the app, as in Safari (a universal link, which WebKit opens itself).
- [ ] With the app not installed, Open says that nothing on the device opens the link.
- [ ] A page that tries another app by itself as it loads (an ad's redirect to the App Store) only asks; nothing opens without Open.

## 15. The phone bar in the page's colour

On an iPhone, with the system in Dark Mode and again in Light Mode:

- [ ] Over a white page the bar fades to white and its controls are dark; over a dark page it fades to dark and they are light. Neither depends on the system's appearance.
- [ ] Over a page with a coloured ground (a navy footer, a yellow banner) the bar takes that colour.
- [ ] Scrolling from a light part of a page to a dark one turns the bar over as the dark part comes under it, eased and without a flash, and scrolling stays smooth.
- [ ] A new tab's start page has the system's own ground: dark in Dark Mode.
- [ ] In Desktop View the bar goes by the page under it in the same way.
- [ ] On iPad, with the tabs along the top, the row stands on the space's colour and the page is a card 5 points in, light or dark as the system is whatever the page's colour; with a split, the half on screen in the row sits inside its pair's ground, its glass's rim showing all round.

## 16. The command bar

On iPad with a keyboard, in a workspace with two spaces, a few tabs in each and bookmarks:

- [ ] ⌘T makes a new tab and the command bar comes up over it, in the middle a little down from the top, empty, with rows under headings: Open Tabs, Spaces, Commands (each with its keys drawn as keys), Settings, Bookmarks. The + button does the same.
- [ ] An address or a search typed there and Return loads in the new tab. ↓ to an open tab and Return goes to that tab, and the new, empty tab is gone from the row. Typing never brings up another space's tabs, history or bookmarks; another space's name goes to that space. Escape leaves the new tab, with the start page.
- [ ] On a page, ⌘T, then "reload" and Reload Page: the page reloads and no empty tab is left. The same with Pin or Unpin Tab (the page's tab is pinned) and Settings (Settings opens over the page).
- [ ] Typing narrows the rows; "tab" lists every command with Tab in its name before Google's suggestions; a command taken runs (Reload Page, Settings, Pin or Unpin Tab).
- [ ] A click on the address in the tab on screen, and ⌃⌥L, open the bar holding the page's address, selected, with no rows; typing replaces it and Return loads in that tab. In the separate layout a click on the address bar does the same.
- [ ] ⌃⌥K opens the bar empty with everything listed and makes no tab. ⌃⌥K or ⌘T while the bar is already open starts it over. With Settings › Show the tab bar off, no bar comes out while typing.
- [ ] With a keyboard attached and an address being typed, drag the window to phone width, or back to full width: the typing ends, and the keys go to the page at once (the arrow keys scroll it) with no tap on the page.
- [ ] "change icon" offers App Icon marked Settings; taking it opens Settings with App icon's heading just under the title bar, in the accent colour for a moment, with or without the on-screen keyboard up. "ad blocker", "search engine", "shortcuts" and "sync" go to their sections. On iPhone "cursor speed" goes to Desktop View, and no Trackpad or Shortcuts part is offered.
- [ ] A click on the page, on the start page's bookmarks or on another tab puts the bar away, and the click does what it would have. The page under the bar still scrolls with two fingers.
- [ ] With the on-screen keyboard (no hardware keyboard), the bar's rows end above the keyboard and scroll.
- [ ] The bar is Liquid Glass on iPadOS 26 and later (the page shows through, bent at its edges) and blurred material on iPadOS 18. Its tint is the row of tabs' colour: on a site with a dark top (a dark theme-color) the bar is dark with light words. Settings › Appearance › Liquid Glass moved to clear and to tinted makes the bar clearer and more opaque, on iPhone's rows too. ⌘T pressed twice makes one new tab, not two. Reduce Motion: the bar only fades. Reduce Transparency: it is solid. VoiceOver reads a command's row as its name and its keys in words.
- [ ] ⇧⌘T after closing an empty new tab reopens the last page closed, not the empty tab.

On an iPhone:

- [ ] + makes a new tab, gives a light tap, and opens the field over the keyboard with everything listed over it, under the same headings, commands without keys. Cancel leaves the new tab with the start page.
- [ ] The page's menu (…) › Commands lists everything without making a tab.

## 17. Handoff

With Settings › Handoff on, and Claude, ChatGPT or Gemini installed:

- [ ] On an iPhone the page's menu (…) ends in a row of three: Find, Share, Handoff, with Copy Link over it. With Handoff off in Settings the row is Find and Share. On an iPad the tab's menu has Copy Link and then Handoff Page… after Share Page, and ⌃⌥H and the command bar run it.
- [ ] On a device with Apple Intelligence, Handoff on an article (a Wikipedia entry, a blog post) shows a sheet from the bottom: Handoff, "Give an assistant this page's context.", and three steps with a line down their side. The first (The context is one file) is ticked; the second (Apple Intelligence organises it) has its sparkles in the space's colour, moving, and a card under it with a page under a magnifying glass, "Reading this page…" and "This takes a few seconds."; the third (You ask in the app you choose) is grey, its share symbol in the middle of its mark. Then the second is ticked and its card shows a newspaper in the space's colour, "This is an article" and "You'll share all of its text.", the third takes the colour and a tap is felt. The Share button is dimmed and does nothing until then; after, it opens the share sheet. The share sheet never opens by itself, however long the sheet is left. Swiping the sheet down ends the handoff and no share sheet comes. With Reduce Motion on, nothing on the sheet moves but fades.
- [ ] At the largest text size the sheet scrolls, and Share can be reached.
- [ ] The card names the page rightly: a megaphone and "This is a landing page", "You'll share its main sections." on linear.app; a window and "This is a web app", "You'll share what's on the page." on excalidraw.com; a list and "This is a list of links", "You'll share one line per item." on a page of search results (duckduckgo.com, npmjs.com/search); a play button and "This is a media page", "You'll share its description." on a video at vimeo.com; a globe and "This page is ready", "You'll share all of its text." on a repository at github.com.
- [ ] With a sentence selected on an article, the card's second line is "Your selection goes first.", and the file has "The reader selected this on the page:" and the sentence as a quotation before the page's text.
- [ ] On a device without Apple Intelligence (an iPhone 14, any device before iOS 26), or with Apple Intelligence off in the Settings app: no Handoff in the page's menu, the tab's menu, the menu bar or the command bar, ⌃⌥H does nothing, Settings has no Handoff section, and Settings › Shortcuts does not list it. Turn Apple Intelligence on and come back to the app: all of it is there.
- [ ] In Low Power Mode, the same sheet comes up: the second step is "eGlu organises it" with a list for its mark and no sparkles, its card goes from "Reading this page…" to what the page is within a second, and Share is dimmed only until then. The file has no summary line.
- [ ] With VoiceOver on, Share is read as dimmed while the page is read, and what the page turned out to be is spoken when it is ready.
- [ ] The share sheet's header names a Text Document with the page's title. Save to Files, then open the file: the title, `Source:` with the address, "About this file, written by eGlu and not by the page:" (the kind of page, what follows, and a summary said to be the page's claim where the model answered), "From the page:" (its description, what it declares, the heading that was on screen, what was set aside), then the page's text. "About this file" begins with "Read:" and a time ending in Z, and `Source:` has no `utm_` or `fbclid` in it for a page opened from a newsletter or an advertisement.
- [ ] A maker's page for a phone (apple.com/iphone) has "Not in this file: the site's foot …" with a count, "… large pictures have no description", marks such as `[^4]` in its text with the notes they point to at the file's end, and no `.m3u8` address. A video at youtube.com has "[Video: …, 53:57]" where the player is, "Its title where it is shared:" where the title shown was translated, and "What the recording says is not in this file". A shop's page at a Korean store (brand.naver.com) has a summary in Korean that names what the page sells, each sold-out link once, and its notices under "Set aside, Footer".
- [ ] A landing page (linear.app, stripe.com, apple.com/iphone) goes as "landing page": a long list of short lines ends in "[… more characters here.]", every paragraph of some length is there whole, and a pricing or questions section is whole and named after "Whole:". A tool with little to read (excalidraw.com, squoosh.app) goes as "web app". A repository on GitHub goes whole, with no kind named. A news site's front page goes whole or, where most of it is headlines with a link each, as a list of links.
- [ ] An article with comments under it (a blog post, a news story) has its text whole and "Set aside, Comments: … characters, starting …" under "From the page"; the comments are not in the text, and a sharing bar or newsletter box is not there at all.
- [ ] A web app scrolled part of the way down (a board, a long form) begins with what was on screen, then "[On screen down to here. The rest of the page follows.]". An article scrolled down says "On screen when shared:" and the heading that was there.
- [ ] A list of search results goes as "list of links", one line a result: its title as a link, then the start of what it says. A video's page goes as "video or audio page", with "It declares: published …, length …" where the page says so. A job posting that declares itself (jobs.lever.co, jobs.ashbyhq.com, wanted.co.kr/wd/…) goes as "job posting", whole, with "It declares: … employer …, full time, pay …, closes …" where the page says so, and the card says "This is a job posting", "You'll share the whole posting."; a board's search (wanted.co.kr/wdlist) does not. A posting at job-boards.greenhouse.io/<company>/jobs/<number>, which declares nothing, goes as "job posting" too, with "Set aside, Apply for this job: …" (and "Voluntary Self Identification" where the form has it) under "From the page" and no form fields in its text; so does one job's page on a myworkdayjobs.com board. The company's list of jobs on either goes as "page" or "list of links". A discussion (a question at stackoverflow.com) and a product page go whole, as "page" or "article": their kinds are not told yet (`Handoff.builtKindsInUse`).
- [ ] On an iPad, a video at youtube.com that has a transcript: Handoff without pressing anything. The page does not move and no panel shows; the sheet's card ends on "You'll share its transcript too."; the same for a video with chapters, whose transcript is in a panel with two tabs; the file has "What the recording says is at the end, under "Transcript", as the site's own transcript has it" and `## Transcript` with paragraphs that each begin with a time. With "Show transcript" already open, it is read and stays open. With the chapters panel open, that panel stays as it was and the transcript still comes, some seconds later (from the video's page loaded out of sight, as on an iPhone).
- [ ] On an iPhone, the same video at m.youtube.com: the sheet stays on "Reading this page…" for up to 14 seconds, then shows the transcript line, and the file has the transcript. Nothing is heard, the page does not change, and no second tab shows in the tab overview. With the sheet swiped down while it waits, nothing more is loaded (no sound, no new tab). A video with no transcript gives a file that says so, within the same time.
- [ ] On an iPhone, a long entry at en.wikipedia.org with its sections shut: the file has what is under each heading, not only the first paragraph, and for a very long one "The page went on past the 100,000 characters read" with "Headings past where it was read to: …" under "From the page".
- [ ] On an iPad, a post at blog.naver.com (one frame): the file has the post's text. Selecting a sentence in the post first puts it under "The reader selected this on the page:".
- [ ] A page of documentation with coloured code (docusaurus.io/docs/installation, fasterthanli.me): each block of code is fenced with its language, one line of code a line.
- [ ] A document at docs.google.com on an iPhone, with the "Open in the app" sheet up: the file has the document's text and "The page had a sheet over it when it was read". A sheet in the editor on an iPad (docs.google.com/spreadsheets) says "Most of what this page shows is drawn by the page and is not text".
- [ ] A shop's page for one thing (11st.co.kr, ikea.com): "It declares: a product, "…": price …" with the product's name, and the colour or size picked on the page marked "[chosen]" in the text.
- [ ] A board's post of a line with replies (clien.net): the replies are in the text, not under "Set aside, Comments", and the board's drawer of every other board is not in the file.
- [ ] Picked from the share sheet, Claude, ChatGPT and Gemini each open with the file attached and "URL: …" and "Question:" as the message, the question left for you to write. Settings › Handoff has its switch and no question field. Note which of them drop the file or the words.
- [ ] Time from the tap on Handoff to "Reading the page…" turning to its result, on an iPhone: note the seconds, with and without a picture (a page with under 1,500 characters of text is looked at too, on iOS 27).
- [ ] On accounts.google.com Handoff is not in the menu, and ⌃⌥H does nothing.
- [ ] A PDF or a picture open in a tab: the sheet's card says "Nothing to read here" and "You'll share the page's address.", and Share opens the share sheet with "URL: …" and "Question:" alone.


## 18. Chrome extensions on a Mac

On the signed DMG, not a build run from Xcode, and on each macOS the release names (26 has not been tried yet). Two spaces, Work and Personal.

- [ ] Dark Reader's page on the Chrome Web Store shows Add to eGlu. It downloads, and the sheet asks what it reads, In This Space or In All Spaces, and On All Sites It Asks For or When I Click It. After Add, the puzzle button's list opens by itself with Dark Reader in it under "In Work", on, with nothing under its name.
- [ ] Dark Reader darkens example.com in Work only. In Personal it is in the list, off, and the page stays light.
- [ ] The puzzle button shows the extensions on in the space as glass tiles, four to a row, names under them; a tile darkens under the pointer and gives a little as it is pressed. Click one: the panel closes and its popup opens in a pane at the page's corner nearest the puzzle button, at its own size, and takes the keys; Esc, ×, another tab and another space put it away, and the keys go back to the page. Drag a tile before another: the order holds after a relaunch, in Manage Extensions and in Settings › Extensions. Right-click a tile, or hold it: its options, or its page.
- [ ] Manage Extensions: each row's switch is just before its chevron, and the whole row, switch included, highlights under the pointer; the row opens the extension's page (Use in This Space, Site Access, Version, which copies its number and says "Copied", Report a Problem…, removal last). Back comes back the way it went.
- [ ] Bitwarden, with the Bitwarden desktop app installed and unlocked: the extension unlocks with the app (biometrics), and fills a sign-in on a site. Its side panel opens beside the page.
- [ ] Bitwarden's Report a Problem… says Started Fine; its popup opens, signs in, and fills a sign-in on a site.
- [ ] Passbolt: its popup shows its content (not empty).
- [ ] NordPass's vault, or Bitwarden's passkey window: opens as a small window of its own with the extension's name at the top, not as a tab; closing it, or the extension closing it, leaves the space's window as it was; turning the extension off closes it.
- [ ] 1Password or Bitwarden set to lock when the Mac is idle or locked: lock the screen (⌃⌘Q) for a minute, unlock: the extension asks to unlock. Its popup is laid out as a popup, not a full page.
- [ ] 1Password, with the 1Password app: its popup says it is connected to the app.
- [ ] 1Password, locked: its button in a site's sign-in field opens its popup to unlock. Its Report a Problem… doesn't say Couldn't Start.
- [ ] iCloud Passwords, only on a build signed with the passkey entitlement (`com.apple.developer.web-browser.public-key-credential`; without it macOS kills Apple's helper as eGlu starts it), with passwords in the Passwords app: its popup asks for the six-digit code the Mac shows, and once paired it offers a saved password on that site's sign-in page and fills it. Its Report a Problem… doesn't say Couldn't Start.
- [ ] uBlock Origin Lite: ads on a news site are blocked in the space it is on in, not in the other.
- [ ] uBlock Origin Lite, a minute after launch: pages still show; none turns into its strict-blocking warning. A known-bad site it warns about shows its warning page in the tab, not a blank one.
- [ ] Norma (or another blocker that sends a site to its own page): a blocked site shows the extension's block page in the same tab, with the site's name; Back and the address bar behave; a site it doesn't block loads.
- [ ] Tampermonkey: a link to a `.user.js` script opens Tampermonkey's install page.
- [ ] Tampermonkey: a script installed from its page runs on the sites it names, and still does after quitting and reopening eGlu; in the other space, where Tampermonkey is on without it, it doesn't.
- [ ] GoFullPage: a capture of a long page opens in its editor, and downloads as PNG and PDF.
- [ ] An extension that signs in through its provider's page (Claude in Chrome, for one): its sign-in opens in a tab in front, and once you sign in the tab closes and the extension is signed in. Closing the tab instead leaves it signed out. Quit and reopen eGlu: one that restores its sign-in by itself (Claude in Chrome) does so with no tab showing.
- [ ] Figma's extension: its sign-in tab closes by itself once you sign in, and the extension is signed in.
- [ ] Figma's extension: its button's request for more access asks you once (Allow, Don't Allow); Allow gives it, and its permissions page shows it given.
- [ ] A tab manager with only "tabs" (OneTab, Session Buddy): its list shows every tab's address, title and icon, and follows a tab that goes elsewhere; an extension's own page in a tab shows blank to another extension.
- [ ] claude.ai with Claude in Chrome on in the space: its sign-in finishes in the extension. On a site no extension lists, `typeof chrome` in Web Inspector's console is "undefined".
- [ ] AdBlock blocks ads; Stylus's popup and its manager page show their content; Vimium C's options page opens and its keys (j, k, f) work on a page; an extension's text in Korean shows as it should on a page in EUC-KR.
- [ ] Sign in to a site in Work with an extension that keeps a sign-in of its own (Bitwarden): Personal's copy of it is signed out.
- [ ] A website can't open an extension's own page it isn't meant to see: on any site, a link or `location.href` to `chrome-extension://<Bitwarden's id>/popup/index.html` does nothing. A sign-in that returns to its extension (NordPass) still opens its page in a new tab.
- [ ] Split View, typing in one page: an extension making the other page of the split active (tabs.update) leaves the keys in the page you are typing in.
- [ ] Load Unpacked a folder, add a permission to its manifest, Reload: eGlu asks first; Don't Reload keeps the version loaded.
- [ ] Settings › Extensions › an extension with commands › Keyboard Shortcuts: each command shows None; Use Its Suggestion gives the manifest's key, which then shows beside the command in the Extensions menu and works on a page; Clear takes it away; ⌘T or a key of eGlu's own menus is refused with its name; another extension's key asks Use It Here first.
- [ ] An extension that replaces the new tab page (Momentum): the first ⌘T after adding it asks "Show … in new tabs?"; Keep It shows its page in a new tab with the address ready to type in, and every ⌘T after; Don't Allow keeps the command bar. Settings › General › New tabs show switches between them.
- [ ] Loom or Screencastify: its first recording asks "Let … record your screen?", then the Mac's own picker; while it records, a pill at the foot of the screen says so, and its Stop ends the recording. Started again within a minute of its button, it isn't asked again; Settings › Extensions › Take Back makes it ask again. An extension refused once isn't asked again until eGlu is reopened.
- [ ] Update an extension (or Reload an unpacked one), quit and reopen eGlu: it starts as the new version (its Report a Problem… says Started Fine). A site that works offline (its own service worker) still loads after the reopen.
- [ ] Only on a build signed with the passkey entitlement: Settings › General › Passwords has Apple Passwords under sign-in boxes. Turned on, a site's sign-in box offers Connect Apple Passwords…; the code Apple's helper shows, typed in the card, connects it, and the box lists your Apple accounts for that site; picking one fills it (Touch ID may ask). On a build without the entitlement, Settings has no Passwords section and nothing comes up under sign-in boxes.
- [ ] accounts.google.com: no extension's content script runs (Dark Reader leaves it light), no extension's items are in the page's menu, and clicking an extension in the list grants it nothing there.
- [ ] An extension that can't run on this Mac shows "Incompatible", with a warning triangle where its switch was; its … menu has Try Again and Hide Warnings, which brings the switch back, off, and Show Its Warnings Again undoes it. A tile dimmed on a page says why under the pointer.
- [ ] Report a Problem… shows the report in full, names no site and no account, and Copy and Save… work. Nothing is sent.
- [ ] Remove from This Space, then on again: its settings in that space are gone, the other space's are not. Remove from eGlu asks first.
- [ ] Settings › Extensions: each extension's site access and its switch in each space; Check Now lists what happened to each extension; it never says "up to date" after a failed or declined check, and a declined version isn't asked about again until you check for updates again. The site access choices read "All Sites It Asks For" and "When I Click It" here, in the install sheet and in the puzzle panel alike.
- [ ] Two Macs signed in to the same iCloud, sync on: an extension added on one is offered on the other under On Your Other Macs; Add shows that Mac's own sheet, and it goes on in the spaces it is on in on the first Mac too. Turned off in a space on one, it goes off on the other. Removed on one, it goes from the other. Don't Offer on This Mac stops an offer. In the CloudKit Console, the Extension and ExtensionUse records' fields are encrypted and their names say nothing about the extension; an open Chrome Web Store page isn't in the other devices' lists of open tabs.
- [ ] Mesurer (Chrome Web Store), installed with Add to eGlu: the install sheet reads "Started Fine" and "May not work: record a tab."
- [ ] Mesurer on example.com, a long article and a web app, from Extensions › Toggle Mesurer: its toolbar shows on the page.
- [ ] Mesurer's Select & Inspect: a clicked heading shows its box and size; clicked text shows its font, size, weight and line height.
- [ ] Mesurer's distances: holding Option over another element draws lines with distances; a flex container shows its gap and padding.
- [ ] Mesurer's guides: a guide drops where dragged and stays; its layout guides show a grid, with rulers top and left.
- [ ] Mesurer's notes: an arrow, a pen stroke and text are drawn, moved, resized and rotated; ⌘Z and ⇧⌘Z undo and redo them while it is on.
- [ ] Mesurer's Sample color opens the Mac's own colour loupe and shows the picked colour as hex, rgb and oklch; Esc cancels it with nothing picked.
- [ ] Mesurer's X-ray outlines every block; Screenshot captures a dragged region; Screen record does nothing.
- [ ] Mesurer's responsive preview shows the page at several widths; a pinned comment copies as text with the element's selector; after a reload its settings are still there.
- [ ] Narrow window (640 points), sidebar wide: the side panel narrows; narrower still, a notice in its place says it is open, with Widen Window and Close Side Panel.

## 19. Peek and little windows on a Mac

Two spaces, Work and Personal; Figma pinned in Work and signed in there only.

- [ ] A site's Sign in with Google or Apple button (on a site that opens it as a pop-up): the sign-in opens in a Peek over the tab, at the size the site asked for, the tab dimmed behind it; it closes by itself once signed in, the site is signed in, and the keys are the page's again.
- [ ] In the pinned Figma tab, a link to github.com opens in a Peek, nearly the card's size; a link to help.figma.com stays in the tab; ⌘-click on the GitHub link still opens a tab behind. Settings › General › Links › Open other sites from pinned tabs in Peek off: the link goes in the tab, as before.
- [ ] A link's menu has Open Link in Peek after Open Link in New Tab; chosen, the link opens in a Peek over the tab. Not on accounts.google.com, nor in a Peek or a little window.
- [ ] A Peek goes with a click on the dimmed card beside it, its ×, and ⌘W, which leaves the tab open. A pop-up the Peek's page opened goes with it. Another tab and back: the Peek is where it was. Closing the tab closes it.
- [ ] ⌃⌥O, or the Peek's expand button: its page is a tab right after the one it came from, on screen, as it was in the Peek (scrolled, signed in, a form half filled), with no reload, and History (⌘Y) lists it; a sign-in page it was on is not listed. From an ordinary tab, the split button puts it beside that tab in Split View; from a pinned tab the button isn't there.
- [ ] Back in the Peek's header shows once it has gone on to a second page, and goes back.
- [ ] With eGlu the default browser, a link clicked in Slack, Mail or Messages opens in a little window over the app in front, in the space of the browser window in front, signed in as that space is; the window's ground is that space's colour, its close, minimise and zoom buttons on the header's line, and its header drags the window. A second link opens a second little window, a step down and along.
- [ ] In a little window, ⌃⌥O, or the expand button: the page is a tab of a browser window showing that space, as it was, with no reload, and in History; the little window goes. The arrow beside it lists the spaces; Personal opens the page there, afresh and signed out of what only Work is signed in to.
- [ ] ⌃⌥N: an empty little window with its address field taking the keys; an address or a search, and Return, go there. A click on the address, or ⌘L, shows the whole address to change; Escape leaves it as it was.
- [ ] In a little window, ⌘W and ⇧⌘W close it and no browser tab; ⌘R reloads it; ⇧⌘C copies its link; a ⌘-click opens a tab of its space in a browser window behind; a pop-up opens over it in a window of its own.
- [ ] Settings › General › Links › Links from other apps open in A New Tab: a link from Slack opens in a new tab of the window in front, as before.
- [ ] Light and dark, Reduce Transparency, and VoiceOver: the Peek reads as "Peek" with its buttons named, and Escape from VoiceOver closes it.

## 20. The engines

On a device, not a simulator, each platform: an iPhone or iPad, and a Mac. The engines make no network call, so run these with Wi-Fi off.

- [ ] The app starts: Xcode's console has the DEBUG line "engines linked: N grammar rules" with no error after it.
- [ ] On iPhone and iPad, Settings › Acknowledgements, the last row of Settings' list, opens at once as a page of its own with that title; on the Mac, eGlu › About eGlu shows Apple's About window with the same text scrolling under the version, and Settings › General has no Licences button. Each is a scrolling text with Harper, anydoc and pdf-inspector named at the top, then each licence's crates with their copyright notices and the licence's full text, the Mozilla Public License's last with where its crates' source is. It scrolls to the bottom and back without stalling.
- [ ] Force-quit and relaunch: the app starts as quickly as before the engines were linked, and runs no warmer.
- [ ] On iPhone and iPad, with the largest text size (Settings › Accessibility › Display & Text Size › Larger Text) and in dark mode: Settings › Acknowledgements keeps its text inside the page, wrapped and readable, and still scrolls without stalling; the back button goes back to Settings. On the Mac, in dark mode, the About window's text is light on dark.

## 21. Grammar in pages (Mac)

On a Mac, Wi-Fi on or off (the check never leaves the Mac).

- [ ] A fresh eGlu: Settings › Writing has Check Grammar and Spelling in Pages off, and English, Rules, Dictionary and Sites greyed out until it is turned on.
- [ ] English lists American, British, Canadian, Australian and Indian. Rules lists Harper's rules under its own groups; a rule switched from its default shows a dot, VoiceOver reads the dot, and Restore Defaults puts every rule back.
- [ ] Dictionary: a word added shows in the list and in `~/Library/Application Support/Safience/Writing/dictionary.txt`, one word a line, sorted; Remove takes it out of both. Where Harper Desktop has a dictionary, Add Harper Desktop's Words brings its words in, then greys out.
- [ ] Quit and open eGlu again: the switch, the dialect, the rules changed and the words are as they were left.
- [ ] With Settings › Writing off, type "the the cat" in a textarea on a page: nothing is underlined. Turn Check Grammar and Spelling in Pages on: the same words get "the the" underlined.
- [ ] The underline sits on the words themselves: in a textarea and in a contenteditable editor (a web app's reply box), a repeated word or a misspelling is marked a moment after typing stops, and in a long paragraph only the English lines are marked.
- [ ] Click an underlined word, or rest the caret in it: a card beside the word names the problem in words ("Word Choice", not "WordChoice") and lists suggestions, the first one filled in with ⌃⌥G beside it. The card keeps the field's focus: ⌘Z and typing still reach the field. Esc, a click outside, or typing anywhere closes it, and Esc while it is closed still reaches the page. In dark mode the card is dark, with no border or square box around its rounded corners.
- [ ] Choose a suggestion: the words are replaced on the page, and the page's own Undo (the site's, or WebKit's) takes it back — in a plain textarea and in an editor like Notion's or a comment box. With the card open, ⌃⌥G takes the first suggestion; with it closed, ⌃⌥G does nothing.
- [ ] The card's Ignore stops marking that same problem; Add to Dictionary (on a spelling mark) lists the word in Settings › Writing › Dictionary and stops marking it everywhere; Turn Off This Rule unticks the rule in Settings › Writing › Rules.
- [ ] Type with the underlines up: they move with the words where they still fit; paste over an underlined word and its mark goes with the word. On scroll, resize, and in a scrolled sidebar the marks stay on the words. A field left for another field goes clean.
- [ ] Nothing is marked in a password, email, URL, phone or number field, in a one-time-code field, in a readonly or disabled field, in a field or an editor under spellcheck="false", in CodeMirror, Monaco or Ace, on accounts.google.com, or in a PDF or an image.
- [ ] A site's page menu has Turn Grammar Checking Off for This Site; choose it and the field being typed in loses its underlines at once, the site is listed in Settings › Writing › Sites, and the menu then says Check Grammar on This Site, which brings checking back to the open page without a reload. docs.google.com is never checked, and its page menu has neither.
- [ ] While it is on, WebKit's own spellcheck squiggles are off in fields, in pages already open too (Edit › Spelling and Grammar › Check Spelling While Typing is unticked); turned off in Settings › Writing, they come back as they were.
- [ ] Edit › Spelling and Grammar: Check Grammar and Spelling in Pages is at the top, ticked while checking is on, and choosing it turns checking on and off as Settings › Writing's switch does. Accept Writing Suggestion (⌃⌥G) under it is greyed out unless a card is open. Under them are the Mac's own items; with a page's field focused, Check Spelling While Typing is ticked or not as WebKit has it, and greyed out where System Settings › Keyboard › Text Input turns spell checking off for every app.
- [ ] With a page open and its field focused, turn Check Grammar and Spelling in Pages on in Settings: the field is checked without a reload. Turn it off: the underlines and the card go at once; on again: they come back.
- [ ] Settings › Writing: the dialect follows the check (US English marks "colour", British marks "color"); an unticked rule stops marking; a word taken out of the dictionary is marked again. ⌃⌥G is listed beside Accept Writing Suggestion in the command bar and Settings › Shortcuts.
- [ ] With checking on, quit and open eGlu again: the first field typed in is checked at once, with no change to Settings first.

## 22. Asking about grammar checking

- [ ] A new iPad (delete the app first): the welcome's Writing step shows, and each of its buttons does what it says.
- [ ] An iPad updated from a build without the question: the small sheet shows once, and never again after either button.
- [ ] "Skip Setup" on the welcome, then relaunch: the small sheet shows.
- [ ] A Mac's first launch of the version: the sheet shows on the first window only; answering either way, it never shows again, and "Check My Writing" turns on Settings › Writing.
- [ ] The Mac's "In other apps too" checkbox (with task 03) asks for Accessibility.
- [ ] Settings › Writing turns checking on and off whatever the answer was, and the question never comes back on its own.
## 23. Grammar in pages (iPad and iPhone)

On iPhone and iPad, Wi-Fi on or off (the check never leaves the device).

- [ ] A fresh eGlu: Settings › Writing is off. Type "the the cat" in a textarea on a page: nothing is underlined. Turn Check Grammar on: the same words get "the the" underlined.
- [ ] The underline sits on the words themselves: in a textarea and in a contenteditable editor, a repeated word or a misspelling is marked a moment after typing stops, and in a long paragraph only the English lines are marked.
- [ ] Tap an underlined word, or rest the caret in it: a card beside the word names the problem in words and lists suggestions, the first one filled in, each button big enough for a finger. With the touch keyboard up, the card stays inside the visible part of the page (below the word's line, above it when there is no room below, shorter and scrolling when there is room on neither side), on iOS 26 too. The card keeps the field's focus; Esc, a tap outside, or typing anywhere closes it.
- [ ] Choose a suggestion: the words are replaced on the page, and the page's own Undo (the site's, or WebKit's) takes it back. With a hardware keyboard and the card open, ⌃⌥G takes the first suggestion; with it closed, ⌃⌥G does nothing.
- [ ] The card's Ignore stops marking that same problem; Add to Dictionary (on a spelling mark) lists the word in Settings › Writing › Dictionary and stops marking it everywhere; Turn Off This Rule unticks the rule in Settings › Writing › Rules.
- [ ] Nothing is marked in a password, email, URL, phone or number field, in a one-time-code field, in a readonly or disabled field, in a field or an editor under spellcheck="false", in CodeMirror, Monaco or Ace, on accounts.google.com, or in a PDF or an image. On iPhone, nothing is marked in Desktop View, and leaving it marks the page's fields again, on a site set to Request Desktop Site too (which doesn't load again on leaving).
- [ ] A site's page menu has Turn Grammar Checking Off for This Site: with text typed into a plain textarea, choose it; the underlines go at once and the text stays (no reload), the site is listed in Settings › Writing › Sites, and the menu then says Check Grammar on This Site, which brings checking back to the open page. docs.google.com is never checked.
- [ ] iOS's own spellcheck is untouched: its marks are still there while checking is on.
- [ ] Settings › Writing on iPhone and iPad has the on/off switch, the five dialects, the rules, the dictionary and the sites list, everything but the switch greyed out while it is off, and nothing about other apps.
- [ ] A fresh install's welcome has the Writing step between Bookmarks and its last page: "Check My Writing" turns checking on, "Not Now" does not, and Settings › Writing changes it after.
- [ ] Answer the Writing step, then quit before the welcome's last page and open eGlu again: the welcome comes back without the Writing step.
- [ ] A workspace from before the update: the first run of the build asks the same question once in a small sheet that can't be swiped away. Not Now answers it; the sheet never asks again, and is never shown over the welcome or another sheet.
## 24. Grammar in other apps (Mac)

On a Mac, with Settings › Writing › Check Grammar and Spelling in Pages on. Each check is in TextEdit (plain and rich text), Notes, Messages, Slack and Discord; Mail's compose for the write-back. Nothing here is checked while Harper Desktop runs.

- [ ] With Check Grammar and Spelling in Pages off, Check in Other Apps is greyed out and the section's footer says to turn page checking on first.
- [ ] Turning on Settings › Writing › In Other Apps › Check in Other Apps asks for Accessibility once (System Settings' own prompt). Until it is allowed, the pane says to allow eGlu in System Settings › Privacy & Security › Accessibility, and the button opens that page. Allowing it starts the checking without relaunching eGlu.
- [ ] Type "teh cat sat" in TextEdit (plain and rich text), Notes, Messages, a Slack and a Discord message field: "teh" is underlined in each, a moment after typing stops, and not while the caret is still in the word. A word after "😀" and a word after Korean text ("한국어 teh") are underlined at the right place.
- [ ] Click or arrow into an underlined word and rest the caret there: a panel beside it names the problem and lists suggestions, with ⌃⌥G hinted on the first. Typing in the word, or switching back to the app with the caret already in it, opens nothing. The field keeps its focus: the panel never takes the keyboard.
- [ ] With the field on a second display, the panel opens beside the word on that display, inside it, clear of the menu bar and the Dock.
- [ ] Choose a suggestion in TextEdit, Notes and Mail's compose: the word is replaced, and the app's own ⌘Z undoes it. In rich text, a bold word stays bold. In Slack and Discord the word is replaced (⌘Z as far as the app allows), and no message is sent. With the panel open, ⌃⌥G takes the first suggestion; with it closed, or on a lint with no suggestion, ⌃⌥G reaches the app being used instead.
- [ ] Type, scroll the field's window, or move it: the underlines vanish at once and come back right on the words a beat after everything is still. Switching to another app clears them; coming back to the field draws them again.
- [ ] Nothing is underlined in a password field, in eGlu's own windows, or in an app unticked in the list. With Harper Desktop running, nothing is checked and the pane says it is checking other apps.
- [ ] Untick an app in the list: its fields are clean. Tick it again and they are checked. An app not in the list is checked only while Check New Apps is on; once you have typed in it, it is listed, and ticking it there checks it. An app of the curated list that isn't installed isn't listed.
- [ ] The section's footer says an app turned off is still watched for a text field in use, to list it. Control-click an app you typed in that isn't curated, choose Remove from List: it leaves the list, and comes back only once you use a text field in it again, off unless Check New Apps is on. Control-click Mail after unticking it: Remove from List ticks it again, and Mail stays listed; at its default, Remove from List is greyed out.
- [ ] Turn Check in Other Apps off: every underline in other apps is gone and no field is read again.
- [ ] With checking running, turn eGlu off in System Settings › Privacy & Security › Accessibility: within a few seconds the underlines are gone, and Settings › Writing says to allow eGlu again. Turn it back on: checking starts again without a relaunch.

## 25. Developer mode

On a Mac and an iPad, with a server running (`npx vite` or `python3 -m http.server 8000`).

- [ ] Typing "local" in the command bar lists the server with its process's name; opening `localhost:8000` shows the developer bar with the whole address, its port and 200; a missing path shows 404.
- [ ] On the Mac, the bar's Inspector, Console and Select Element buttons open WebKit's inspector at that part; Reload from Origin reloads without the cache. The tools' keys (⌃⌥, and ⌥⌘ after Settings › Developer › Developer Tools' Keys) do the same.
- [ ] The page's menu's "Turn Developer Mode On for This Site" on `https://example.com`, then off again; "Turn Developer Mode Off" for `localhost:8000`, then on.
- [ ] Take a Picture of an Element: a card's picture lands on the clipboard and pastes into Preview.
- [ ] `https://api.github.com/repos/eGlu-dot-apps/eGlu` shows formatted and folded; the Raw button shows it as it comes. Settings › Developer › Format JSON off: it shows as it comes.
- [ ] On the Mac, the bar's Size menu puts the page at an iPhone's or an iPad's size with that device's user agent: a responsive site's layout changes, and Full puts it back.
- [ ] On the iPad: the bar shows at the top of the page with the address, status and buttons; an element's picture shares through the sheet; a JSON page shows formatted. Safari on a Mac inspects the iPad's page from its Develop menu.
- [ ] The status after a 404, then a server that isn't running: the failed page shows no status. Back to the 404 page and forward again: each shows its own status.
- [ ] On the Mac, with a Peek up, the Developer menu's items and keys act on the Peek's page; with a little window in front, on its page.
- [ ] On the Mac, the toast, the find bar (⌘F) and an extension's popup stand below the bar, never over its buttons.
- [ ] A server listening on ::1 only (`python3 -m http.server --bind ::1 8001`) is listed for "local"; a local server that redirects elsewhere is listed, and nothing follows the redirect.
- [ ] The Size menu checks the size the page is at, and its icon is that device; an iPad size in a short window keeps the page's top.
- [ ] On a JSON page, Raw stays on the bar while the text shows, and brings the view back. On an iPad in Slide Over (a phone-width window), the page's menu has Show Raw JSON and Inspect from Safari on a Mac.
- [ ] On an iPhone: no developer bar on `localhost:8000`, no Developer menu, keys or command-bar rows, and no Developer group in Settings (only Developer diagnostics, in a build from Xcode). A JSON page still shows formatted.
- [ ] The bar's menu turns developer mode off for the site: a secondary click on the Mac's bar or its Size menu, a long press on the iPad bar's address. Each says so in a toast, and the bar goes.
- [ ] With VoiceOver, the bar's buttons say their names, the address is a button, and a picture's toast lets Save or Share be pressed.

## 26. Measuring tool

On a Mac and an iPad. ⌃⌥M (or Measure in developer mode's bar) starts it; Esc ends it.

- [ ] On the Mac: the marketing page (eglu.app) and a web app (Figma or Linear). An element's size, padding and gaps in the panel's card match Safari's Web Inspector's. Clicking selects (the page takes no click): content, padding, border and margin boxes draw, and gap boxes on a flex or grid row.
- [ ] With ⌥ held, the element under the pointer shows the distance to the selected one, each side; a selection inside another shows the four insets. ⌥ lifted clears it.
- [ ] On the iPad: tap an element, then tap another for the distance.
- [ ] The fields: 12-column guides over the page's width (G switches them), rulers along the top and left in page pixels (R), X outlines every border box thinly.
- [ ] Pick Colour: on the Mac the loupe reads anywhere on screen; on the iPad, the pixel under the next tap (a green, a red and a P3 photo's colour match Digital Color Meter's sRGB). The card shows the swatch and copies its hex and rgb() on click.
- [ ] ⌘+ zooms in: the sizes and distances stay in CSS pixels.
- [ ] Add Note… on three different elements: three numbered dots pin at their top-left corners; the panel lists them, a note edits in place, × takes one away (its dot goes). Copy for an Assistant pastes as plain text naming the page, the viewport, and each element's name, place, size, the note and how it looks.
- [ ] On accounts.google.com the tool does not start (the keys and the bar's button do nothing).
- [ ] Notes stay when the tool ends (Esc) and comes back on the same page, their dots where they were; another page or closing the tab takes them away. Copy for an Assistant reads "Page:", "Window: … by …, at …%", then the notes, a blank line between each.
- [ ] A board or a canvas (Figma, a whiteboard): while measuring, a click or a drag on it starts nothing of the page's. On the iPad, scrolling and pinching the page select nothing.
- [ ] Rulers at any scroll show their ticks; R on the page and the panel's Rulers switch agree, and the choice stays for the next run.
- [ ] With Handoff's panel up, the measuring panel stands above it, not over it; both move by their top rows. On the iPhone, Measure from the command bar: the card stays above the bar at the bottom. On an iPad in Slide Over, the page's menu has Measure.
- [ ] Back and forward while measuring: the page that comes back has no overlay left on it. A tab closed while measuring frees its page (Activity Monitor's WebKit processes go down).

## 27. Enhanced Handoff: documents

On a Mac and an iPad, with Handoff on (Settings › Handoff).

- [ ] A text PDF (a paper with two columns and a table) in the tab: the file has its headings, its columns in order and its table.
- [ ] A scanned PDF: its pages are read, and the file says they were read from pictures of them.
- [ ] A PDF behind a sign-in (a bank statement, a course's PDF): it is fetched with the sign-in and read.
- [ ] Links to a `.docx`, an `.xlsx` and a `.pptx`: the link's menu has Handoff Linked File; the file has the deck's speaker notes and each sheet as a table.
- [ ] Downloads: a finished `.docx` row has Handoff, and the file has the document.
- [ ] A file chosen (File › Handoff File… on the Mac, Handoff File on iPad) and, on the Mac, one dropped on the Handoff pane: the file has its contents.
- [ ] A JSON address (https://api.github.com/repos/eGlu-dot-apps/eGlu) in the tab: the file has it formatted, keys sorted.
- [ ] A ZIP with a PDF, a `.docx` and a picture: the first two are read under their names, and the picture is named as not read.
- [ ] A password-protected PDF and a 300 MB file: the guide says why each can't be read, and the address goes alone.
- [ ] A page as before: an article in the tab still hands off exactly as it did.
- [ ] On a new tab and on Google's sign-in page: File › Handoff File… (⌃⌥⇧H) on the Mac, and Handoff File beside Downloads in the page's menu on iPad, still open the chooser. On the sign-in page a link's menu has no Handoff Linked File.
- [ ] On the Mac, a right-click on a link, a picture and an empty part of a page: each menu opens as before, and Console shows no exception from it.
- [ ] A long workbook past the file's limit: the file stops where a sheet ends and names the sheets left out under "From the file".
- [ ] A ZIP with another ZIP inside it: the inner one is named as not opened; a ZIP with a scanned PDF inside says which of its pages were read from pictures.
- [ ] Hand off a PDF in a tab, go on in the tab to an article, and hand that off: the article's file is a page's, with no PDF's pages or facts in it.

## 28. Enhanced Handoff: pictures and recordings

On a Mac and an iPhone, with Handoff on (Settings › Handoff).

- [ ] A photo with location data in its EXIF handed off: the file has its date and camera, and no place anywhere.
- [ ] A screenshot of a chat handed off: the file has the text read in it.
- [ ] On macOS or iOS 27 with Apple Intelligence: a photo's file has a description, marked as the on-device model's that can be wrong.
- [ ] A news article with large pictures without `alt`: up to four are read, and the file's about lines say how many it read on this device and that the model's words can be wrong.
- [ ] In Low Power Mode the same article: no descriptions, the text in the pictures only, the model not asked.
- [ ] A 5-minute `.m4a` and a 20-minute `.mp4` handed off: both have transcripts; the second says the first 15 minutes were transcribed, and the guide showed "Transcribing the recording: N of M minutes" as it went.
- [ ] The first recording asks for speech recognition where the system asks, and only then; a recording a later one needs no asking.
- [ ] A recording in a language speech recognition on the device can't hear: the file says so instead of a transcript.
- [ ] With the device in a language speech recognition can't hear on the device but English can be: an English recording is transcribed, and the file says "in English".
- [ ] A recording from Downloads, one chosen and, on the Mac, one dropped on the pane: each is transcribed (before, a recording not fetched from a tab failed at once). A link to an `.m4a` has Handoff Linked File, and the choosers offer recordings.
- [ ] A `.m4a` played in a tab: the guide shows the speech model being got, where it is, and the minutes as they are transcribed.
- [ ] A 40-minute recording on a slow device: the guide is ready by about 90 seconds, with what was heard by then, and the transcript says it goes on.
- [ ] On iOS 17 or 18 (SFSpeechRecognizer): the speech recognition question left unanswered past 90 seconds does not hold the guide; it goes with the recording's facts.

Results, Mac:

Results, iPhone:
## 29. App icon on a Mac

eGlu Mac or eGlu Mac Direct, kept in the Dock (its menu › Options › Keep in Dock). The Dock loads the app's Dock tile plug-in when the app is put in the Dock and at login: after installing the first build that has it, take eGlu out of the Dock and put it back, or log out and in.

- [ ] Settings › General › App Icon, after Default browser: eGlu, Globe, Designer, Engineer, Signal, Vista, Hardcover, Punk and Astro, as on iPhone and iPad, each with its name under it; eGlu is ringed in the accent colour on a fresh eGlu, the ring as far from the icon at its corners as at its sides. No icon has a dark rim at its corners, and their corners are as round as other apps' in the Dock. In light and in dark (System Settings › Appearance) each picture is that icon's light or dark look, and the same icon on the Home Screen looks alike. The note under them says Finder and Spotlight keep showing eGlu's own icon.
- [ ] Choose Vista: the ring moves, and the Dock tile and eGlu › About eGlu show Vista at once; note what the app switcher (⌘-Tab) shows. Choose eGlu: the app's own is back in each.
- [ ] With Vista chosen, turn the Mac from light to dark and back: the Dock tile follows, with eGlu open and with it quit.
- [ ] Quit eGlu with Vista chosen: the tile stays Vista. Open eGlu: Vista (the app's own may show while it starts). Choose eGlu, quit: the app's own. Choose Astro, quit at once: Astro.
- [ ] Finder, Spotlight and the Apps view show eGlu's own icon whatever is chosen: macOS has no other icon for an app, and changing the app's own file would break its signature.
- [ ] With System Settings › Appearance › Icon & widget style on Dark, Clear or Tinted: eGlu's own takes the style; note what a chosen icon shows (eGlu gives the Dock its light picture in a light Mac and its dark one in a dark Mac, whatever the style).
- [ ] ⌘T, "change icon" or "dock icon": App Icon is offered under Settings; taking it opens Settings › General with App Icon in view, from a closed Settings window and from one open on another pane.
- [ ] VoiceOver reads each icon by its name, the chosen one as selected; Tab with keyboard navigation on reaches each, and Space chooses it.
- [ ] A release (Release/mac.sh) signs the plug-in in Contents/PlugIns with Developer ID and the hardened runtime, `codesign --verify --deep --strict` passes, and notarisation accepts it.

## 30. Handoffs in History

On a Mac and an iPhone or iPad, with Handoff on (Settings › Handoff).

- [ ] Hand off an article and pick an app: History (⌘Y, ⌃⌥Y) has it under Today with Handoff's mark, the page's name and its site, a row of its own beside the page's visit.
- [ ] Hand off a file you choose (Handoff File…): its row has the file's name and, under it, the Markdown file's.
- [ ] Put the guide away, or close the share sheet without picking an app: no row. A page that goes as its address alone: no row.
- [ ] Choose a handoff's row: on iPhone and iPad the share sheet opens with the Markdown file and the URL and Question lines; on the Mac Quick Look shows the file. The file is the one that went the first time.
- [ ] Hand off two pages one after the other: both rows still offer their own files.
- [ ] Filter › Show › Handoffs: handoffs alone, and the filter's icon is filled; Pages: pages alone. Words from a handoff's name in the search: it shows under Handoffs.
- [ ] A handoff's Delete from History… (its menu, or a swipe): the row goes, and on the Mac its folder goes from `~/Library/Application Support/Safience/Handoffs`.
- [ ] Clear… › The Last Hour: the last hour's handoffs go with their folders, older ones stay. A day's Clear takes that day's.
- [ ] With Sync history on: a handoff never shows in History on the other device; Clear… › Today there takes today's handoffs here too.
- [ ] Quit, delete one handoff's `.md` in Finder and put a stray folder in `Handoffs`, then open eGlu: that row and the stray folder are gone.
- [ ] Settings › History › One Day, with a handoff from before yesterday: it goes, with its file.

Results, Mac:

Results, iPhone or iPad:

## 31. Passkeys on a Mac, once Apple grants the entitlement

Not before: nothing here can be tried until Apple has granted `com.apple.developer.web-browser.public-key-credential`, the capability is on for the app's identifier on developer.apple.com, and `PASSKEYS=1 Release/profile.py` has made and installed the profile (which it refuses to do while the capability is off). Then a DMG from `PASSKEYS=1 Release/mac.sh`, which refuses to build if the profile doesn't grant it. On a Mac signed in to iCloud Keychain, with a passkey or two in Passwords, and an iPhone nearby.

Before that, a Debug build's rehearsal tries the page's side and the checks with made-up passkeys: `python3 Tests/passkeys-rehearsal.py <test copy>` (its top says how to build the copy), and `--native` for a build without them.

- [ ] The DMG opens, without a warning, on a Mac that has never run eGlu. (An app signed with an entitlement its profile doesn't grant is one macOS won't open.)
- [ ] The first site that asks for a passkey brings up macOS's question whether eGlu may use passkeys, once; the answer is kept in System Settings › Privacy & Security, where eGlu is listed (note the pane's name here).
- [ ] passkeys.io: Create a passkey brings up the Mac's sheet with Touch ID, and the passkey is in Passwords afterwards; signing out and in with it works.
- [ ] webauthn.io: Register and Authenticate, with Authenticator Attachment Platform, then Cross-Platform with an iPhone over the QR code, then a security key (USB, NFC if there is one). With Discoverable Credential required, then discouraged. Advanced Settings › PRF, where offered: registration says PRF is supported and authentication returns its output.
- [ ] github.com › Settings › Password and authentication: Add a passkey, then sign out and Sign in with a passkey; GitHub's second step with a passkey too.
- [ ] A site that offers your passkey under its sign-in field (github.com/login, passkeys.io): clicking the name field lists the site's passkeys under it, each with its account and where it is kept; typing still goes in the field; picking one brings up the Mac's sheet for that passkey alone and signs in. A click elsewhere puts the list away; a click in the field brings it back. Another tab, another window, or eGlu behind another app: no list, no sheet.
- [ ] Quit eGlu (and once, force quit it) with such a sign-in page open, open it again: passkeys still work on every site, without restarting the Mac.
- [ ] Google: accounts.google.com is hands-off, so it gets none of eGlu's passkey scripts and keeps WebKit's own, which Search found refuses sites other than the app's associated domains. Note what happens on Google's "Use your passkey" (the system's sheet, or a refusal), and that a Google account with a passkey can still sign in another way. Whether eGlu's passkeys should go into Google's sign-in is a decision to take, as it would break the hands-off rule.
- [ ] A passkey inside a frame: Apple's sign-in at account.apple.com (a frame from idmsa.apple.com, whose frame element allows `publickey-credentials-get`) signs in with a passkey; if it is refused, note the frame element's `allow` attribute. A frame of another site asking for one is refused (webauthn.io's iframe test, if offered, or Tests/passkeys.html served on two hosts).
- [ ] With Bitwarden and with 1Password installed and their apps unlocked: a site's passkey button, and the list under the field. Note whether the extension's own list, the Mac's sheet, or nothing comes up, and whether quitting eGlu with the page open leaves passkeys working (Search's `a868137`, not taken yet, is about this).
- [ ] `defaults write net.taehee.safience passkeyRelay -bool NO` and a relaunch: eGlu's list under the field is gone and pages have WebKit's own `navigator.credentials` (a site's passkey button then fails, as without the entitlement). `defaults delete net.taehee.safience passkeyRelay` puts eGlu's back.
- [ ] A build without the entitlement (`ICLOUD=1 Release/mac.sh`, or one from Xcode): pages have WebKit's own `navigator.credentials`, no list comes under a sign-in field, and passkey buttons fail as they do today. In Console, the app's log says nothing in the Passkeys category.
