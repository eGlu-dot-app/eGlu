# A folder's swipe action is named as its menu names it

Written against: commit `c2346e1f` on `main`, which includes the Bookmark Manager (PR #179, `Shared/BookmarkManagerView.swift`).

## Evidence chain

- Surface: the Bookmark Manager's list on iPhone and iPad (`Shared/BookmarkManagerView.swift`, the `row(_:path:)` function; its `.swipeActions` are compiled for iOS only, under `#if os(iOS)`).
- Problem: swiping a folder's row offers "Edit", while the same row's context menu offers "Rename…" for a folder. Both open the same sheet, titled "Rename Folder" (`Editor.heading`). For a bookmark, the swipe says "Edit" while the menu says "Edit…".
- Design evidence: the row's own context menu in the same file names the action `item.isFolder ? String(localized: "Rename…") : String(localized: "Edit…")`; the editor's heading for a folder is "Rename Folder". The app's other sheet with swipe actions keeps the ellipsis on a swipe that opens something more: `Shared/HistoryView.swift`, `.swipeActions { Button("Delete…", systemImage: "trash", role: .destructive) { … } }`.
- Owner: `BookmarkManagerView.row(_:path:)`, the `.swipeActions` block: `Button("Edit", systemImage: "pencil") { editor = .edit(item) }`.
- Scope and affected surfaces: the manager's list rows on iPhone and iPad, in a folder's contents and in search results.
- Uncertainty: none.

## Design decision

Name the swipe action exactly as the row's context menu names it: "Rename…" for a folder and "Edit…" for a bookmark. One action, one name, wherever it is reached from, and the ellipsis says a sheet follows, as History's swipe does.

## Reuse

- The context menu's existing expression in the same file: `item.isFolder ? String(localized: "Rename…") : String(localized: "Edit…")`.
- Existing catalog keys with Korean translations in `Shared/Resources/Localizable.xcstrings`: `"Rename…"` ("이름 변경…") and `"Edit…"` ("편집…").
- Exemplar: `Shared/HistoryView.swift` swipe action "Delete…".

No new primitive or string is needed.

## Changes

1. `Shared/BookmarkManagerView.swift`, `row(_:path:)`, the `.swipeActions` block under `#if os(iOS)`
   - Change: `Button("Edit", systemImage: "pencil") { editor = .edit(item) }` becomes `Button(item.isFolder ? String(localized: "Rename…") : String(localized: "Edit…"), systemImage: "pencil") { editor = .edit(item) }`.
   - Preserve: the action (`editor = .edit(item)`), the pencil symbol, the order (Delete first, then this), the Delete swipe as it is, and the context menu.
   - Verify: swiping a folder shows "Rename…"; swiping a bookmark shows "Edit…"; each opens the same sheet as before.
2. `Shared/Resources/Localizable.xcstrings`
   - Change: if the key `"Edit"` is no longer used anywhere after step 1 (check with `grep -rn '"Edit"' --include='*.swift' App Mac Shared`), remove its entry, which was added only for this swipe action. If it is still used elsewhere, leave it.
   - Preserve: every other entry and the file's formatting.
   - Verify: the catalog is still valid JSON (`python3 -c "import json; json.load(open('Shared/Resources/Localizable.xcstrings'))"`).

## Scope

- Inherit: the manager's list on iPhone and iPad.
- Verify: the context menu's labels are unchanged; the Mac build, where swipe actions are not compiled, is unaffected.
- Exclude: the Delete swipe action's label (it asks first only for a folder with something in it or several items, so whether it carries an ellipsis is a separate decision); the new tab page's tile menus; History.

## Validation

- Product: on iPhone, open the manager, open a folder that holds a subfolder and a bookmark, and swipe each row from the right: the subfolder offers "Rename…" and the bookmark "Edit…"; each opens its sheet ("Rename Folder", "Edit Bookmark"). With the device in Korean they read "이름 변경…" and "편집…".
- Interface: iPhone (compact) and iPad (regular) lists, a folder's contents and search results; a long folder name does not affect the swipe button's label.
- System: the swipe reuses the context menu's labels; no third wording is added.
- Repository: `xcodebuild -project eGlu.xcodeproj -scheme eGlu -configuration Debug -destination 'platform=iOS Simulator,name=<an available iPhone>' build` → BUILD SUCCEEDED with no new warnings; the same for scheme `eGlu Mac` → BUILD SUCCEEDED.

## Stop conditions

- Stop if the row's context menu no longer names the action "Rename…" / "Edit…": the source of truth has moved and the swipe should follow the new one, which needs a new look.
- Stop if the swipe action no longer opens the editor (`editor = .edit(item)`): this plan is about its name only.

## Design documentation

- After acceptance and validation: none. The repository has no design document to record it in.
