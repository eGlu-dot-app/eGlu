# Safience UX remediation plan

Date: 2026-10-23 · Revised after PR review

Safience should make a clear promise: **keep client work separate, keep work recoverable, and always show the next useful action.** The existing quiet chrome and focus on web apps support that promise. The largest gaps are in state changes, recovery, and access to essential controls.

Fix the shared behavior behind the findings before polishing individual screens. The prepared integration makes remote unpin preserve local work. Workspace recovery, cross-space caches, stale restoration and rich-text drafts are the next release blockers.

**Integration status:** fixes and conflict resolutions are committed locally, with all six PR heads preserved as ancestors. Publishing and merging must use **`taehee-pd`**. They are blocked because the GitHub connector requires approval for writes while this session's approval policy is `never`; the local CLI's network verification also failed. Remote main and the six open PRs are unchanged. The complete branch is saved in `ReviewArtifacts/Safience-PR-integration-2026-10-23.bundle`; see the [review record](PRReview-2026-10-23.md) for the resume procedure. “Implemented” below means implemented in that prepared integration, not on remote main.

## Scope and evidence

The supplied `safience-ux-audit(1).md`, dated October 22, contains 67 observations against `e20789c0312104f356c972b92add5178041371f2`, also the remote main baseline when this review began. The root checkout remains an older `edc7df0` with existing signing, project and scheme edits. Integration and tests used an isolated checkout; those local edits were preserved.

All original source links and line anchors in N1–N10 refer to **e20789c**, as historical evidence. The reviewed integration includes PRs #43–#48 and the fixes below. New paths refer to that integrated source. See [the PR review record](PRReview-2026-10-23.md) for exact PR heads, scope, findings and validation limits.

Evidence labels:

- **Probed:** a small executable called the real PadCore APIs against synthetic data in a temporary directory. This verifies the stated logic, not the complete app UI.
- **Source-confirmed:** the relevant caller and implementation were read. The trigger may still need runtime testing.
- **Runtime risk:** the implementation permits the outcome, but timing or platform behavior needs a device test.

The review checked the original audit's key paths and investigated adjacent persistence, sync, history, and account boundaries. It does not claim to have independently reproduced all 67 original observations. No live visual score or accessibility certification is assigned. No Safience app was running on the available UI surfaces, and the simulator probe failed with `CoreSimulatorService connection became invalid` / `Connection refused`. The repository's App Store hero was inspected only as a historical design reference, not current UI evidence.

The initial design-review and design-consultation pass informed the plan. The follow-up applies apple-native-ui, write-swift, better-ui, 12-principles-of-animation, ux-audit, better-writing and ui-skills-root to the native platforms. Web-only recipes are not imposed on system controls. Application fixes are now included; runtime verification remains separate from source review.

## Changes from the PR review

- Reviewed all 48 PRs' inventory and all 69 historical review threads. Deep source review covers the six open PRs, their existing review threads, and the combined result; historical PRs were not all re-audited line by line. #6 was already closed without merging and superseded by #7.
- Integrate #43–#47 before #48, which depends on #46. Preserve #48's icon-only space button when resolving #47's overlap, and retain both bookmarks and toast state when resolving #43/#45.
- **N5 implemented:** remote unpin preserves the local tab, page URL, title and selection. Regression tests also verify repeated application and no resurrection of the removed pin. Two-device editing remains a manual acceptance check.
- **N8 partially addressed:** page, day and range history clearing now disclose hidden visits and cross-device scope; deleting a page asks first. Durable completion and failure reporting remain N10.
- **T7 addressed in source by #43:** bookmarks leave the tab list for a temporary panel. Added modal accessibility semantics, focus on Close and an escape action. Keyboard, VoiceOver and small-window behavior still need a native run.
- **D4 partially addressed by #45:** copy, bookmark and blocking feedback has announcements. Toast text now grows with Dynamic Type, and blocking feedback describes the setting. Download, error and sync announcements remain open.
- **O9 changes scope under #47:** release builds hide Diagnostics. Debug builds still need a visible dismissal; support guidance must stop promising an unavailable release shortcut.
- New fixes: History results use the latest visit within the filter; cancelled pinned-button presses reset; pinned-list timing and button scale are quieter; copied links clean dotted hosts; automatic PiP ranks visible video area; privacy copy admits partial-address suggestion requests.

Validation: 479 XCTest tests and 68 Swift Testing tests passed with five baseline CRX key-generation tests excluded after `SecKeyCreateRandomKey` failed with OSStatus -50. Targeted reruns cover sync, history, tracking and video policy. Five Node PiP behavior tests pass. The new History/Tracking regression tests fail on the pre-fix code and pass with the fixes. Direct SDK type checks cover iOS Debug/Release and macOS. Full Xcode builds, simulator, VoiceOver and the bridge browser run remain blocked by environment restrictions; no rendered verification is claimed.

## Ten additional findings from the initial pass

Priority is a proposed release decision, separate from the original audit's Nielsen severity. **P0** blocks a release until resolved or disproved because it threatens retained work or client boundaries. **P1** belongs in the next remediation release. Frequency is not known.

### N1. A failed workspace read can turn into deletion of valid history

**P0 · Probed core chain; source-confirmed startup integration.** `WorkspaceFile.read` returns nil for both a missing file and a read/decode failure. Both Session implementations replace nil with a new workspace. Startup then prunes history to the new workspace's space IDs; valid old history becomes orphaned and is deleted. Snapshot pruning also discards old tab caches. A subsequent successful workspace save can overwrite the original unreadable file.

Evidence: [Workspace.swift:720](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/PadCore/Sources/PadCore/Workspace.swift#L720), `App/Sources/Session.swift:80`, `Mac/Sources/Session.swift:80`, `Shared/HistoryRecorder.swift:171`, `PadCore/Sources/PadCore/HistoryStore.swift:387`.

Probe: malformed workspace → nil → fresh space identity; existing history entries after startup-style `keepSpaces`: **1 → 0**. This does not imply that cookie stores are swept on every failed read; `Stores.sweep` removes only stores already queued for deletion.

Fix: return distinct missing, loaded, unreadable, and unsupported-format outcomes. Enter recovery mode on failure. Preserve the source file and last known good backup, suspend history/snapshot pruning and sync reconciliation, and offer retry or explicit recovery. Only a confirmed first launch creates a fresh workspace automatically.

Acceptance: malformed, permission-denied, and future-schema files never trigger pruning or overwriting; recovery preserves the original bytes and old space identities.

### N2. Workspace changes look saved even when persistence fails

**P1 · Source-confirmed; additional Mac ordering risk.** iOS and Mac use `try?` for workspace writes. The visible workspace changes immediately, but write failure is never reported. On Mac, delayed snapshots write on a global concurrent queue while `saveNow` writes separately; an already-running older write may race the latest write. Atomic file replacement prevents partial JSON, not stale snapshots winning.

Evidence: [iOS Session.swift:155](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/App/Sources/Session.swift#L155), [Mac Session.swift:173](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/Mac/Sources/Session.swift#L173).

Fix: acknowledge durable writes, serialize them, track the latest committed revision, and retain a dirty state until success. Show a persistent, nonmodal “Changes haven't been saved on this device” status with Retry and an export/recovery route. Keep local-save status distinct from iCloud status.

Acceptance: disk-full and permission failures remain visible; a controlled out-of-order completion cannot replace a newer workspace; quitting after an edit preserves the latest acknowledged revision.

### N3. Moving a tab retains state and images from its previous space

**P0 · Source-confirmed cache gap; visible exposure needs runtime verification.** `Pages.moved` tears down the page and clears in-memory interaction state, but leaves disk interaction state. iOS also retains preview and frozen-image caches. `page(for:in:)` subsequently reads disk state using only the unchanged tab ID, while preview fallbacks can show the previous space's image. This undermines the client-isolation expectation. It is not evidence that WebKit cookies are shared between spaces.

Evidence: [iOS Pages.swift:208](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/App/Sources/Pages.swift#L208), `App/Sources/Pages.swift:42`, `App/Sources/Pages.swift:90`, [Mac Pages.swift:66](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/Mac/Sources/Pages.swift#L66), `Shared/Stores.swift:77`.

Moving also tears down a live page without explaining that it reloads under another space's sign-in. A saved URL cannot restore an unsaved editor's JavaScript state.

Fix: define moving as an account-boundary transition. Offer “Open a Copy in [space]” as the safe alternative; explain reload before a destructive move. Invalidate all images and interaction state, including delayed callbacks. Namespace caches by space and tab, with a generation guard so an old asynchronous snapshot cannot repopulate the cache after invalidation.

Acceptance: freeze a synthetic Client A page, move it to B, and inspect tab overview, thaw, Back, relaunch, and late snapshot completion. No A preview or saved navigation state is restored in B.

### N4. Remote deletion preserves the last space's local sign-ins and tabs

**P1 · Probed identity retention; source-confirmed deletion branch.** If a remotely deleted space is the last local space, `applyMirror` calls `keepAsNew`, not `Session.removeSpace`. It clears cloud identity and bookmarks but preserves the local space UUID and open tabs. Because `Stores.erase` and Mac extension-space cleanup are not called in that branch, it is not equivalent to deleting the space's local data.

Evidence: [Sync.swift:804](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/Shared/Sync.swift#L804), `PadCore/Sources/PadCore/SyncModel.swift:708`, `Shared/Stores.swift:19`. The existing `testALastSpaceRemovedElsewhereStaysWithoutWhatWasRemoved` explicitly retains open tabs.

Probe: local store identity **unchanged**, tabs **retained**, cloud identity cleared.

Fix: create a genuinely fresh replacement space with a new local UUID before removing the deleted one. Apply the same cleanup policy as ordinary deletion, including extension data. If product policy instead preserves a local copy, make that an explicit, visible retention choice and revise deletion promises accordingly. Never silently rename retained data into apparent deletion success.

Acceptance: remote deletion on a device with one space and on a device with several spaces has the same documented data outcome; offline replay and relaunch do not resurrect the deleted cloud identity.

### N5. Unpinning on one device closes the working tab on another

**Status: implemented in this integration; native cross-device acceptance remains.** The evidence below describes the original defect.

**P0 · Probed core chain; source-confirmed Session integration.** `applyPinned` reports missing remote pins as tabs to close. `applyMirror` immediately calls `session.closeTab` for them, including tabs currently shown. This couples a synced shortcut change to destruction of a live local page, despite the product's stated local-open-tab model.

Evidence: [SyncModel.swift:667](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/PadCore/Sources/PadCore/SyncModel.swift#L667), `Shared/Sync.swift:802`, `PadCore/Tests/PadCoreTests/SyncModelTests.swift:115`.

Probe: removing the remote pin queued the selected tab for closure; applying the same close operation changed open tabs from **1 → 0**. Unsaved web-editor loss still requires a runtime fixture.

Fix: separate a pin's synced membership from the local browsing session. Remote unpin should convert an existing local tab into an ordinary tab and preserve its live page. Remove only the shortcut representation when no local session exists. Show a quiet state change if needed; do not ask a remote device to decide whether local work may be discarded.

Acceptance: unpin remotely while editing a synthetic form, in a split, and in a second window. The local page, input, selection, and split remain usable.

### N6. Turning on sync silently merges unrelated spaces with the same name

**P1 · Probed; product-policy gap.** `SyncPlan.join` falls back to a trimmed, case-insensitive name match when cloud identity cannot match. It adopts the remote appearance and joins bookmarks and pins. Two spaces named “Work” may represent different clients. The implementation intentionally does this, but the user is not asked to resolve the ambiguity.

Evidence: [SyncModel.swift:722](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/PadCore/Sources/PadCore/SyncModel.swift#L722), `Shared/Sync.swift:219`, `PadCore/Tests/PadCoreTests/SyncModelTests.swift:139`.

Probe: “Work” and “ work ” produced **one space with both sets of bookmarks** and the remote cloud identity. Cookie stores do not merge in this probe.

Fix: treat matching cloud IDs as identity; names are suggestions only. Preview name collisions and offer Keep Separate or Merge, defaulting to separation. Retain stable IDs through disable/re-enable and explain which items sync.

Acceptance: identical names, renamed spaces, repeated sync enablement, and duplicate imported folders never cause an unreviewed identity merge.

### N7. Changing Apple Accounts automatically rejoins retained workspace data

**P1 · Source-confirmed automatic path; account-switch outcome needs device testing.** Account-change handling resets the sync mirror while keeping the workspace, then calls `joinSoon`. The next join includes eligible retained spaces, bookmarks, and pins. History has a separate account-aware upload cutoff, but workspace data lacks an equivalent explicit choice about uploading retained data to the new account.

Evidence: [Sync.swift:674](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/Shared/Sync.swift#L674), `Shared/Sync.swift:219`, `Shared/HistoryCloud.swift:302`, `Shared/HistoryCloud.swift:319`.

Fix: account identity is a sync boundary. Pause workspace upload after a detected change, retain local work, and ask whether to keep it local or join it to the current account. Make this a resumable sync state, not a transient alert. Do not silently delete local data on sign-out.

Acceptance: with two dedicated test accounts, switch while online, offline, and with sync disabled. No old-account workspace data uploads before the new-account choice. Verify history independently.

### N8. Clear History omits its cross-device consequence at the point of action

**P1 · Source-confirmed.** The clearing sheet names time and space and says that site data stays. It does not say that, with history sync enabled, the clearing propagates to other devices. Settings does describe this, but the user may clear history long after reading Settings. This extends X5's scope problem to another destructive action.

Evidence: [HistoryView.swift:358](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/Shared/HistoryView.swift#L358), `Shared/HistoryCloud.swift:138`, `Shared/HistoryCloud.swift:159`.

Fix: show the effective scope beside the final action: space, time range, and “all devices syncing history” when applicable. Offline clearing should say it is queued for those devices. Avoid adding a device-only option unless the sync data model can honor it without reimporting cleared entries.

Acceptance: the confirmation remains accurate with either sync switch off, with sync still joining, offline, and after a delayed remote visit arrives.

### N9. An import whose destination disappears reports “Already There”

**P1 · Probed return-value ambiguity; asynchronous trigger needs integration test.** Bookmark parsing runs off the main thread. If the destination space is removed in another window or through sync before completion, `Workspace.importBookmarks` returns zero. Session interprets zero as all bookmarks already being present, even though the destination no longer exists.

Evidence: [Session.swift:243](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/App/Sources/Session.swift#L243), `App/Sources/Session.swift:265`, `PadCore/Sources/PadCore/Workspace.swift:698`.

Probe: importing to an unknown space returns **0**, the same result as a duplicate-only import.

Fix: use a typed import result with added, duplicates, unreadable, empty, cancelled, and destination-missing cases. Revalidate destination identity after parsing; preserve the parsed result long enough to offer another space. Reuse this model for O1 and O7 instead of fixing only their button labels.

Acceptance: delete or rename the destination during a delayed import. A deletion offers a destination choice; a rename uses the current name; no false success is shown.

### N10. History storage errors look like empty history or completed deletion

**P1 · Source-confirmed; fault injection needed.** History store initialization can fail into nil. Reads return empty arrays on error. Writes suppress errors and advance the view revision; Clear History dismisses immediately without awaiting durable deletion. A person cannot distinguish no history from unavailable history, or a successful clear from a failed one.

Evidence: [HistoryRecorder.swift:25](https://github.com/taehee-pd/Safience/blob/e20789c0312104f356c972b92add5178041371f2/Shared/HistoryRecorder.swift#L25), `Shared/HistoryRecorder.swift:197`, `Shared/HistoryRecorder.swift:247`, `Shared/HistoryView.swift:372`.

Fix: expose store availability and typed read/write outcomes. Show an unavailable state with Retry; acknowledge clearing only after the transaction commits. On failure, keep the user's request available and explain that the history remains. This is a separate user-facing contract from saving the workspace in N2.

Acceptance: simulate database-open, locked-database, and write failures. No History appears only after a successful empty query; a failed clear never claims completion.

## Four further findings from historical PR review

### N11. Rich-text drafts are missing from the freezer's safety check

**P0 · Source-confirmed; actual editor loss needs a native fixture.** PR #1's historical comment still applies: `PadCore/Sources/PadCore/Scripts/bridge.js`, `unsaved()`, checks only inputs and textareas. Nonempty contenteditable editors can be treated as safe to freeze. W0 must define conservative draft detection, including editor/shadow-root boundaries, and explicitly define what memory pressure is allowed to discard. Do not equate reopening a URL with recovering a draft.

Acceptance: enter text and rich content in synthetic editors, switch tabs past the live-tab limit and return. Normal freezing preserves the draft; forced process loss has an honest recovery limit.

### N12. Relaunch can restore an older navigation snapshot

**P1 · Source-confirmed; runtime restoration behavior unverified.** PR #1's stale-snapshot comment remains relevant. Both `App/Sources/Pages.swift` and `Mac/Sources/Pages.swift`, `page(for:in:)`, restore disk state before consulting the saved URL and load that URL only when WebKit reports no URL. A prior frozen state can survive a later live navigation. Fix alongside N3: version snapshots by space, tab and navigation revision; consume/invalidate stale state and serialize read/delete against pending writes.

Acceptance: freeze A, thaw, navigate to B, quit while live, relaunch. B returns; an old snapshot neither replaces B nor restores A across a space move.

### N13. Closing the onboarding window leaves the welcome lock held

**P1 · Source-confirmed on iPad multiwindow.** PR #10's comment remains: `Browser.welcoming` is cleared only by the welcome completion/dismissal path; `Browser.disconnect()` does not release ownership. Closing the presenting scene can prevent other windows from showing unfinished onboarding until relaunch. Use a weak presenting-window owner, release it on disconnect and let an eligible foreground window resume. Couple finishing setup to N2's acknowledged initial save.

Acceptance: open two windows during first launch, close the one presenting Welcome, and complete setup in the remaining window without restarting.

### N14. Partial-address suggestions require an explicit privacy policy

**P1 · Source-confirmed.** PR #9's privacy comment remains mechanically true: `Autocomplete.suggestionsURL` excludes text recognized as an address, but a prefix such as `private` can be sent before `private.corp` is complete. The false “an address never does” promise has been corrected in Settings and PRIVACY.md. W0/W6 must decide whether remote suggestions require an explicit search mode or opt-in; string heuristics cannot guarantee a future address stays private. Until then, the documented local-only route is turning search engine suggestions off.

Acceptance: use a recording suggestion-provider fixture while entering private names slowly; requests match the chosen policy, and local suggestions remain available with remote suggestions disabled.

## Corrections to the original audit's interpretation

The original audit is useful and unusually clear about static evidence. It should become a tracking input, not a list of 67 independently implemented fixes.

1. **Reach alone is not the right priority.** Data loss, client-boundary violations, destructive scope, and being unable to navigate take precedence over frequent cosmetic friction. Accessibility barriers to essential tasks belong in that same early release gate.
2. **Do not equate a smaller frame with a proven WCAG failure.** Inspect actual hit regions and overlap. Keep a 44 × 44 pt touch target policy for Safience's iOS controls, but distinguish that native policy from WCAG's CSS pixel criteria. WCAG 2.5.5 is AAA; WCAG 2.2's 2.5.8 is AA and has a 24 CSS pixel minimum with exceptions. [W3C 2.5.5](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html), [W3C 2.5.8](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html).
3. **X7 has the right usability concern and the wrong specific shortcut criterion.** Control-Option conflicts need testing with VoiceOver, but WCAG 2.1.4 addresses character-only shortcuts. Preserve Safience's page-first keyboard contract; provide accessible menu routes and an alternate/remappable browser shortcut profile rather than reclaiming the web app's Command keys. [W3C 2.1.4](https://www.w3.org/WAI/WCAG21/Understanding/character-key-shortcuts.html).
4. **A toast is not recovery.** Reopening a URL does not recover a live editor, authentication state, or JavaScript heap. Define what Undo restores and how long the actual view remains alive. Never promise complete restoration that WebKit cannot supply.
5. **The deletion wording fix depends on deletion semantics.** X5's promise cannot be made consistent until N4's last-space exception and N8's history scope are resolved.
6. **Downloads need a cross-platform contract.** The Mac already exposes progress, unlike iOS, but its failure handler drops the error and resume data; the failed row is disabled. Include Mac retry/cancel/error detail in D1/D10's remediation rather than building an iOS-only solution.
7. **Keep uncertain findings uncertain.** VoiceOver traversal, translucent contrast, hit-region overlap, and interaction latency require a running app. Static counts and historical marketing screenshots are not evidence of a tested accessibility result. Use Accessibility Inspector and real assistive technology tasks as Apple recommends. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

## Proposed product and design rules

This is a proposed direction for the remediation work, not an approved visual redesign. Preserve the native typography and recognizable workspace layout; replace fixed sizing and ad hoc states with shared rules.

| Area | Proposed rule | User outcome |
|---|---|---|
| Identity | Keep the current space's name or accessible label available in every browsing layout, including a single-space setup. | People know which client's context they are using. |
| Navigation | Address/search, tabs, spaces, and a way to restore hidden chrome remain reachable by touch and assistive technology. | Compactness never traps the user. |
| Typography | Use semantic text styles or scaled custom styles. Allow rows and sheets to grow; compact typography must have a usable large-text layout. | Larger Text works throughout the browser. |
| Surfaces | Quiet neutral chrome. Use space color for identity and emphasis; keep action text on a contrast-verified surface. Page tint sits behind an opacity-controlled control surface. | Pages remain the focus without sacrificing legibility. |
| Interaction | Use one semantic action definition for menus, command results, buttons, shortcuts, and accessibility actions. Labels name the next action and expose current state. | The same command means the same thing everywhere. |
| Geometry | Base spacing on 4 pt increments; distinguish icon size from hit area. iOS touch controls have nonoverlapping 44 pt minimum targets; preserve appropriate Mac density. | Controls become easier to use without making every icon larger. |
| Focus and selection | Selection, keyboard focus, hover, and pressed state are distinguishable, with shape/outline and accessibility state as well as color. | People can predict what Return or activation will do. |
| Feedback | Loading, waiting, partial, failed, cancelled, and completed are distinct states. Long-running work stays findable after its sheet closes. | Silence and failure are never mistaken for success. |
| Destruction | Show the affected space, item count, device scope, and what cannot be restored. Reversible actions get a usable Undo; irreversible data erasure gets confirmation. | People understand the consequence before committing. |
| Motion | Animate changes of position or state when it explains them. Reduce Motion replaces nonessential travel with immediate changes or a simple fade. | The UI remains understandable without animation. |
| Language | Short action labels; one name per concept; human descriptions for icons and permissions. Add string catalogs before large copy work. | Clear wording scales across platforms and languages. |

Two deliberate tradeoffs deserve prototype validation:

- Keep a visible space control even with one space. It consumes a little chrome but makes Safience's defining feature discoverable and the current account context legible.
- Make active operations and Recently Closed directly reachable. This introduces secondary UI, but recovers work and avoids unexplained sheets appearing minutes later. Show activity only when relevant; do not create a permanent dashboard.

### Shared implementation contracts

Build small reusable contracts alongside the first vertical fixes. Avoid a large rewrite before shipping safety improvements.

| Contract | Required information | First consumers |
|---|---|---|
| Action presentation | Stable action ID, current label, availability/reason, selected state, shortcut, accessibility label, destructive scope. | Space menu, tab menu, command bar, Mac menu bar. |
| Operation result | Operation ID, phase, originating window/space/tab, progress when known, typed outcome, allowed recovery actions. | Import, downloads, extension checks, Handoff. |
| Data status | Local persistence status separate from sync account, queued work, last successful sync, and error. | Recovery screen, Settings, subtle persistent status. |
| Destructive action policy | Local versus synced effect, preview of loss, undo capability, commit point, cleanup acknowledgement. | Close/reset/move tabs, delete spaces, clear history, remove extensions. |
| Page state | Attempted URL distinct from committed URL; classified failure; origin-bound recovery actions; accessible announcement. | Main page, popup, split pane. |
| Visual tokens | Text roles, surfaces and paired foregrounds, control target sizes, focus/selection styles, motion choices. | iOS and Mac platform adapters. |

Reuse `PadCore` for pure state and policy, `Shared` for appropriate cross-platform presentation and services, and platform adapters for UIKit/AppKit behavior. Keep cookies isolated, preserve hands-off sign-in hosts, and keep Command shortcuts available to web apps as the repository requires. Add no telemetry service to measure the work.

## Workstreams and acceptance criteria

### W0. Protect work and define data ownership

Owner roles: core/storage engineer plus sync engineer; product/design reviews consequence wording.

Resolve N1–N8 and N10 with explicit persistence, identity, deletion, and restore rules. Add one policy for closing, resetting a pinned tab, closing a group, and moving between spaces. Keep pinned reset a named action. Provide Recently Closed and group Undo where the implementation can genuinely support them. Confirm multi-tab closure when live state cannot be retained. Do not hold every closed heavy tab indefinitely; choose a documented retention limit and degrade honestly.

**Done when:** interrupted startup cannot destroy retained records; a remote pin change cannot close live work; moving tabs cannot reuse old-space caches; local and remote deletion agree; rejected writes remain visible. Two-device tests include offline replay, a last remaining space, and account changes. Existing tests that encode the undesired product policy are deliberately revised.

### W1. Keep navigation reachable and understandable

Owner roles: browser UI engineer plus interaction designer.

Always expose space management, including New Space in Settings. Hiding the top tabs retains a minimal address/navigation bar and a visible Show Tabs control. Give iPad an All Tabs route with overflow count. Give the command bar an explicit Go/Search row and Cancel, with no click-through dismissal. Keep tabs ahead of a large bookmark collection, or collapse bookmarks with an obvious count. When a split cannot fit, show its existence and a Switch Pane/Exit Split action. Put loading state on every address-bar layout.

**Done when:** a touch-only user can create a second space, hide and restore tabs, reach an overflow tab, cancel a command, and recover a narrow split. Repeat with a hardware keyboard removed mid-session, Larger Text, and VoiceOver. Same action labels agree in menus and command results.

### W2. Make status and recovery truthful

Owner roles: browser/service engineers plus content design.

Introduce typed operation and page-state results through complete user journeys. Downloads get persistent activity, Cancel, Retry/Resume when supported, and a finished file that remains available after a cancelled export picker. Preserve origin window/space context; if it disappears, move the operation to a findable activity list instead of presenting over an arbitrary window. Indeterminate downloads do not show fabricated percentages.

Popups use the same loading, failure, sign-in fallback, and security-description contract as main pages. Keep attempted and committed addresses distinct; offer host-specific recovery without bypassing TLS protections. HTTP authentication shows retry context and an insecure-connection warning when applicable. External-app refusals remain discoverable without allowing repeated modal harassment.

Handoff distinguishes no readable content, extraction failure, file-write failure, model timeout, and organized success. Background page dialogs need bounded, origin-bound pending requests or visible suppression, not unbounded alert queues; discard stale requests after navigation or tab closure.

**Done when:** offline, cancelled, declined, partially completed, and failed operations are distinguishable; recovery remains reachable after navigation or window closure; no success label is derived only from a zero count or nil value. Status changes are announced without stealing ongoing focus.

### W3. Establish accessible shared controls

Owner roles: design-system/UI engineer plus accessibility reviewer.

Implement scalable type, foreground/surface pairs, touch geometry, semantic buttons and accessibility actions, adjustable split controls, and distinct focus/selection styles. Resolve contrast against the composited background rather than selecting white text by color name. Provide an opaque safe fallback for tinted or translucent controls. Apply meaningful icon names and expose selected/disabled states.

Preserve page-first shortcuts. Audit actual conflicts with VoiceOver, Full Keyboard Access, and supported keyboard layouts before selecting an alternate browser profile. Every essential command must have a navigable UI route regardless of shortcut choice.

**Done when:** main tasks work at the largest supported accessibility text size with no clipped action; light/dark and increased-contrast variants meet the chosen contrast targets; a touch-only and screen-reader user can activate tabs and all recovery controls. Pointer hover is supplemental, never the only explanation.

### W4. Make Desktop View operable without memorizing gestures

Owner roles: iPhone interaction engineer plus accessibility reviewer.

Add a short first-use explanation and an always-reachable help/control strip: Exit, zoom in/out/reset, keyboard, and supported secondary-click action. Distinguish desktop site rendering from trackpad interaction. Show whether typing has a focused destination. Remember minimap placement and offer collapse/hide. Provide feedback for unavailable gestures and reduce routine haptic noise.

Do not claim a complete VoiceOver solution from a few labels. Prototype semantic focus and activation with WebKit first. If direct operation cannot be made reliable, make standard accessible browsing the default and show an explicit mode choice with a safe exit; document the remaining limitation. Never silently place a VoiceOver user into an unusable mode.

**Done when:** click, drag, scroll, zoom, typing, and exit have discoverable routes; gesture alternatives work with single-pointer input where appropriate; VoiceOver testing establishes the supported mode contract. Right-click feedback does not imply a native menu exists when only a site's custom menu can open.

### W5. Make Mac extension management a coherent workflow

Owner roles: Mac engineer plus permissions/content reviewer.

Route every removal through the same scope and confirmation policy. Present human permission categories, affected sites, and named space scope on install and escalation. Decide whether “all spaces” includes future spaces and make storage and wording agree. Attach sheets to the initiating window, including Settings with no browser window open.

Return structured update results: current, updated, failed, declined, deferred, and busy. Remember a declined version and offer Check Again rather than daily repeated prompts. Show incompatibility reasons and next actions inline, disable unavailable Use actions with a reason, and keep management reachable even when an action is disabled. Show popup preparation immediately; hidden narrow side panels must offer reveal/resize guidance. Remove local shortcut overrides that conflict with standard app commands. Review Mac bookmark import as a real capability gap rather than burying it in cosmetic shortcut changes.

**Done when:** install, permission change, update, failure, removal, and recovery work from all entry points and with no browser window. Keyboard and assistive-technology users can manage disabled or incompatible extensions. Cancellation never broadens permissions or destroys extension data.

### W6. Complete onboarding, language, and product promises

Owner roles: product designer/content owner plus app engineer.

Use N9's import outcome model in onboarding, Settings, and start-page entry points. Offer Choose Another File after failure and name the destination on success. Rename Skip to Skip Setup and make per-step skipping explicit. Validate empty space names without displaying a value that was not saved. Refresh default-browser status on return to the app while respecting API availability and rate limits; use truthful unknown-state copy on older systems.

Group Settings around Browsing, Spaces, Privacy and Sync, Accessibility and Input, and Advanced/Support, with searchable anchors and a separate shortcut reference. Diagnostics gets a visible dismissal and a plain explanation. Add English/Korean catalogs and pluralization infrastructure before expanding copy; use pseudolocalization and Korean input tests. Replace obsolete open-tab-sync and command-palette claims in README, requirements, help, and store assets from the verified release build.

**Done when:** a first-time user can skip, retry import, create another space later, and understand what syncs without reading the README. UI, commands, help, and store claims describe the same release and capabilities.

## Build order and dependencies

| Stage | Work | Exit gate |
|---|---|---|
| 0. Establish release baseline (integration prepared) | Choose the implementation branch containing the audited features; preserve unrelated edits; create a tracking ledger; capture reproducible UI states when a device is available. | Each finding has revision, evidence status, owner role, and acceptance test. No claim that stale store screenshots prove current UI. |
| 1. Stop loss and dead ends | W0's P0s first. In small independent changes, fix T1/T2 navigation escape, O1 import retry, and M1 destructive bypass. Include basic semantics and readable controls in those fixes. | Recovery never prunes valid data; remote unpin preserves live work; cross-space cache invalidation passes; essential navigation and import retry are reachable. |
| 2. Build shared behavior through real flows | Introduce W3 tokens/semantics and W1 action presentation; migrate W2 errors, downloads, and operation results. Finish W0's deletion, sync-join, and persistence status policies. | A complete create/browse/fail/recover/close/reopen flow works on iPhone, iPad, and Mac. No false-success states in migrated paths. |
| 3. Finish specialized experiences | W4 Desktop View and W5 extensions consume the same actions, feedback, and permission rules. W6 completes setup, settings structure, catalogs, and wording. | Mode alternatives, multiwindow ownership, extension permissions, and setup recovery pass their task checks. |
| 4. Validate and publish matching claims | Run the interaction/accessibility matrix, two-device scenarios, regressions, and release documentation checks. Replace screenshots from the final build. | No unresolved P0; every remaining P1 has an explicit disposition; release claims match verified behavior. |

Dependencies: W0 defines the data consequences that W2 and W6 describe. W3 establishes controls before W1/W4/W5 duplicate new UI. W2's operation results feed import, Handoff, downloads, and extension updates. W6's string catalog can start early, while final copy follows the settled behavior. These are work packages, not a commitment to run separate agents or teams.

Keep PRs small and vertically complete: one behavior, its relevant state transitions, platform adapters, meaningful tests, and changelog entry. Do not ship a generic framework without a working consumer, or fix each button independently around the same broken state model.

## Traceability for all 67 original observations

Each original ID has one primary workstream below. Cross-workstream dependencies are described above. These assignments are not claims that every item has been reproduced.

| Primary workstream | Original audit IDs | Additional IDs |
|---|---|---|
| W0 Work and data ownership | X5, X8, X9 | N1, N2, N3, N4, N5, N6, N7, N8, N10, N11, N12, N14 |
| W1 Navigation | X4, T1, T2, T3, T4, T6, T7, T8 | — |
| W2 Status and recovery | O5, D1, D2, D3, D5, D6, D7, D8, D9, D10, D11 | — |
| W3 Accessible controls | X1, X2, X7, X10, X11, X12, O3, T5, T9, D4, P4 | — |
| W4 Desktop View and phone | P1, P2, P3, P5, P6, P7, P8, P9, P10 | — |
| W5 Mac extensions | M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M12, M13 | — |
| W6 Setup and language | X3, X6, X13, X14, O1, O2, O4, O6, O7, O8, O9, D12 | N9, N13 |

Small cosmetic items such as P8/P10 can accompany the relevant surface change. A standalone aesthetic redesign, new analytics, and changes to web pages' own UI are outside this remediation plan. Korean translation sequencing is a product-priority choice; catalogs, pluralization, and layout readiness should not wait for it.

## Validation and release gates

Use synthetic client data and test accounts. Do not run destructive scenarios against the developer's actual workspace or iCloud data.

| Layer | Scenarios | Required evidence |
|---|---|---|
| PadCore policy tests | Corrupt/unreadable workspace outcomes; name collisions; remote unpin; last-space replacement; missing import destination; destructive scope and undo metadata. | Tests assert the intended user outcome, including policy changes to existing tests. |
| Storage and service integration | Failed writes; ordered save/quit; history clear transaction failure; late snapshot callbacks; download cancellation/export cancellation; partial extension update. | Fault-injected runs show correct durable state and truthful UI outcomes. |
| Native task tests | First launch → failed import → retry; create second space; hide/restore chrome; overflow tabs; narrow split; loading popup; download/save; close group/recover; extension management from Settings alone. | Fresh screenshots at each important state plus observed interaction results. |
| Accessibility | Largest text sizes, light/dark, increased contrast, Reduce Motion/Transparency, VoiceOver, Full Keyboard Access, Switch Control/Voice Control where supported. | Essential tasks completed without gesture-only or shortcut-only paths; measured actual hit regions and composited contrast. |
| Input and layout | Touch-only iPad, keyboard/trackpad iPad, narrow/resized windows, phone portrait/landscape, keyboard presentation, Korean IME and long names. | Focus and selection survive transitions; no clipping, hidden exits, or accidental neighboring targets. |
| Sync and multiwindow | Two devices, offline edits, delayed deletions, one versus several spaces, account switch, two windows, owner window closed mid-operation. | State and visible consequence agree across devices; client boundaries remain intact. |
| Product regression | Existing page-first input, hands-off sign-in, Figma trackpad/keyboard, freeze/thaw, site modes, ad blocking, Handoff. | Relevant `Validation/CHECKLIST.md` flows continue to pass; no extra script or cookie access on hands-off hosts. |

Run `swift test` in PadCore after policy changes and the existing bridge tests after input/script changes. Build both apps and run the affected native checks. Do not add tests that merely assert a new label; test the failure or transition that caused the misleading label.

For moderated validation, use concrete tasks and record completion, wrong turns, and recoverability. These are proposed release targets, not measured current metrics:

- Every critical task is completable without knowing a shortcut or hidden gesture.
- No tested failure path claims success; no tested remote shortcut change closes local work.
- No tested space transition restores a different space's cached image or interaction state.
- Every destructive action communicates the effective scope before commitment.
- Every long-running task is findable, with recovery appropriate to its actual state.

If a web app's unsaved state cannot be restored after process death, say so. Do not present reopening the URL as complete Undo. If Desktop View cannot provide reliable assistive-technology operation, ship an explicit supported alternative and record the limitation rather than marking P3 fixed.

## Evidence recorded in this review

Five isolated probes compiled and ran successfully against the audited PadCore revision:

```text
N1 corrupt workspace read is nil: true; new local space identity: true;
   history entries after launch-style keepSpaces: 1 -> 0
N5 remote unpin queued active tab for close: true;
   open tabs after applyMirror-style close: 0
N4 deleted last space keeps local store identity: true;
   tabs retained: 1; cloud identity cleared: true
N6 same-name join resulting spaces: 1; mixed bookmark count: 2;
   adopts remote identity: true
N9 missing import destination returns: 0, identical to duplicate-only import
```

These initial probes reproduce the original baseline; N5 has since changed and is covered by regression tests. The other probes remain evidence of unresolved behavior. The full app, CloudKit delivery, and visual accessibility matrix remain to be exercised during implementation. The temporary probe used only synthetic example-domain URLs and temporary files.

**Release status: Block.** The reviewed PR integration and first fixes are ready at the source/logic level; N1, N3 and N11 still threaten work or client boundaries. Finish those, then validate N5 with two devices. Native build/runtime and accessibility evidence remain release gates. The PR review record lists the exact verification performed and the remaining limitations.
