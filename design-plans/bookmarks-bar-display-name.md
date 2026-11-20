# The bookmarks bar is shown as "Bookmarks Bar" everywhere

Written against: commit `c2346e1f` on `main`, which includes the Bookmark Manager (PR #179, `Shared/BookmarkManagerView.swift`).

## Evidence chain

- Surface: the Bookmark Manager (`Shared/BookmarkManagerView.swift`), shown as a sheet on the Mac (`Mac/Sources/BrowserView.swift`, `model.bookmarkManagerShown`) and as a page sheet on iPhone and iPad (`App/Sources/Browser.swift`, `openBookmarkManager()`).
- Problem: the same object, the space's bookmarks bar, is shown with two capitalizations. The manager's side list and its title on a phone read "Bookmarks bar", next to the sibling row "Other Bookmarks" and above the manager's own empty-state heading "The Bookmarks Bar Is Empty". The user's screenshots of the phone show "Bookmarks bar" as the large title and in the side list.
- Design evidence: no design document governs this. The contract is the product's own naming of the bar: every other user-facing string for it is title case "Bookmarks Bar": `Mac/Sources/TopTabBar.swift` (help, accessibility label and "Close Bookmarks Bar"), `Mac/Sources/Sidebar.swift` (lines near 708 and 1278 to 1295: "Remove from Bookmarks Bar", "Move to Bookmarks Bar", "In the Bookmarks Bar", "Separate from Bookmarks Bar", "Add to Bookmarks Bar", and the Clear button's help), `App/Sources/SideTabs.swift` ("Remove from Bookmarks Bar", "Add to Bookmarks Bar", the Clear label), `App/Sources/TopTabs.swift` ("Show Bookmarks Bar", "Hide Bookmarks Bar", the accessibility label), and the manager's own `"The Bookmarks Bar Is Empty"`. Only the two display calls below use "Bookmarks bar".
- Owner: `Bookmark.label` in `PadCore/Sources/PadCore/Bookmarks.swift` (`if Bookmarks.isBar(self) { return BrowserText.localized("Bookmarks bar") }`) and `BookmarkManagerView.title(of:)` in `Shared/BookmarkManagerView.swift` (`case .bar: return BrowserText.localized("Bookmarks bar")`).
- Scope and affected surfaces: the manager's side list row, its list title (the large title on a phone, the header over the list on a Mac), Move to targets ("Bookmarks bar › Docs"), search-result paths; and every other place that shows `Bookmark.label` for the bar: the new tab page's bar tile and its folder header on iPhone and iPad (`App/Sources/StartPage.swift`, `folders.last?.label`, move targets), and the Mac new tab's tiles (`Shared/StartTiles.swift`, `Text(item.label)`).
- Uncertainty: none about the name. The stored folder title is a different thing and must not change (see Preserve).

## Design decision

Show the bar's name as "Bookmarks Bar", as every menu, button and help text in the app already names it. Change only the display string. The folder's stored title, `Bookmarks.barName` ("Bookmarks bar", Chromium's own name), stays: it is how a bar imported from Chrome is recognized, and `Bookmarks.isBar` already compares names without regard to case.

## Reuse

- `BrowserText.localized(_:)` with PadCore's `Localizable.strings` (`PadCore/Sources/PadCore/Resources/en.lproj` and `ko.lproj`), as the current call does.
- The Korean name already chosen for the bar: "책갈피 막대" (currently under the key `"Bookmarks bar"` in `ko.lproj`).
- Exemplar: `Mac/Sources/TopTabBar.swift`, which already says "Bookmarks Bar".

No new primitive is needed.

## Changes

1. `PadCore/Sources/PadCore/Bookmarks.swift`, `Bookmark.label`
   - Change: `BrowserText.localized("Bookmarks bar")` becomes `BrowserText.localized("Bookmarks Bar")`.
   - Preserve: `Bookmarks.barName = "Bookmarks bar"`, `Bookmarks.isBar`, the export's `<H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>` (`BookmarkFile.export` writes `barName`), and the doc comment's meaning (the stored title stays Chromium's).
   - Verify: a space's bar reports `label == "Bookmarks Bar"` in English and "책갈피 막대" in Korean.
2. `Shared/BookmarkManagerView.swift`, `title(of:)`
   - Change: `case .bar: return BrowserText.localized("Bookmarks bar")` becomes `BrowserText.localized("Bookmarks Bar")`.
   - Preserve: `"Other Bookmarks"` and every other title.
   - Verify: the side list shows "Bookmarks Bar" above "Other Bookmarks"; Move to shows "Bookmarks Bar › Docs".
3. `PadCore/Sources/PadCore/Resources/en.lproj/Localizable.strings` and `ko.lproj/Localizable.strings`
   - Change: replace the entry `"Bookmarks bar" = "Bookmarks bar";` with `"Bookmarks Bar" = "Bookmarks Bar";` in `en.lproj`, and `"Bookmarks bar" = "책갈피 막대";` with `"Bookmarks Bar" = "책갈피 막대";` in `ko.lproj`. Nothing else calls the old key once steps 1 and 2 are done; confirm with `grep -rn 'localized("Bookmarks bar")' PadCore Shared App Mac`, which must print nothing.
   - Preserve: the files' alphabetical placement (next to `"Bookmark Manager"`).
   - Verify: `BrowserTextTests` still passes.
4. `PadCore/Tests/PadCoreTests/BookmarksBarTests.swift` and `PadCore/Tests/PadCoreTests/BookmarkFileTests.swift`
   - Change: the assertions on the bar's `label` expect "Bookmarks Bar": `BookmarksBarTests.swift` line 29 (`XCTAssertEqual(space.bar?.label, "Bookmarks bar")`), and `BookmarkFileTests.swift` lines 61, 73 and 116 (`read.items.map(\.label)` beginning with `"Bookmarks bar"`).
   - Preserve: every assertion on `title`, on `Bookmark(folder: "Bookmarks bar", …)` fixtures, on `Bookmarks.isBar` (including the "Bookmarks Bar" spelling test), and `BookmarkManagerTests` (it asserts `title`, not `label`).
   - Verify: those tests pass with the new expectation.

## Scope

- Inherit: the Bookmark Manager on Mac, iPhone and iPad; the new tab page's bar tile and folder header (iPhone, iPad, Mac).
- Verify: search in the manager still finds the bar's contents by "bookmarks bar" in any case and still never lists the bar itself (`Bookmarks.matching`); importing a Chrome export still merges into the existing bar.
- Exclude: the stored title `Bookmarks.barName`; the HTML export's folder name; the string catalog key `"Bookmarks Bar"` used by the Mac and iPad menus (its missing Korean translation is a separate matter); any other label.

## Validation

- Product: open the Bookmark Manager in a space with a bar; the bar reads "Bookmarks Bar" in the side list, in the title on a phone, in the header over the list on a Mac, in Move to and in search-result paths; with the device in Korean it reads "책갈피 막대".
- Interface: Mac sheet; iPhone (compact: the folder list, then the bar's list with its large title); iPad (two columns); the new tab page with the bar tile and inside the bar folder. A space with no bar yet: the side list still shows "Bookmarks Bar" and the empty state "The Bookmarks Bar Is Empty".
- System: the display name comes from the one existing owner (`Bookmark.label` and the manager's `title(of:)`), with no second spelling added anywhere.
- Repository: `cd PadCore && swift test` → all tests pass. `xcodebuild -project eGlu.xcodeproj -scheme "eGlu Mac" -configuration Debug build` and the same for scheme `eGlu` with an iOS Simulator destination → BUILD SUCCEEDED with no new warnings.

## Stop conditions

- Stop if `Shared/BookmarkManagerView.swift` is missing or `title(of:)` no longer names the bar: the manager has changed and this plan is stale.
- Stop if any code compares `label` (not `title`) against "Bookmarks bar" to find the bar: the change would then be behavioural, not only presentational.
- Stop if the user has since chosen sentence case ("Bookmarks bar", "Other bookmarks") for these names: then the other strings move instead, which is a different plan.

## Design documentation

- After acceptance and validation: none. The repository has no design document to record it in.
