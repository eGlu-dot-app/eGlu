# eGlu performance audit: enriched findings and open PR coverage

**Audited November 4, 2026.** Audited main revision: [75fcca22f0ae46e36cc60360f000cdf620449abc](https://github.com/eGlu-dot-app/eGlu/commit/75fcca22f0ae46e36cc60360f000cdf620449abc). All six open PR heads were fetched and checked again before audit delivery. Main and PR source files were not edited. This documentation-only publication preserves the audit's findings; no product fix, PR, review comment or issue was created.

**Evidence:** [Download the benchmark source, logs and reproduction instructions](PerformanceAuditEvidence-2026-11-04.zip).

## Summary

- **The history issue remains the first main-branch priority.** None of the open PRs fixes it. The original 10,000-page maintenance measurement remains 31 to 33 seconds, compared with 0.760 seconds on a fixture copy with a matching composite index.
- **PR #170 adds a separate, high-priority scaling risk.** Its iPad bookmark rows rebuild the entire bookmark-to-tab map per row. Repeating that expression for 1,000 rows costs 136 ms; 3,000 rows cost 1.10 seconds in a component benchmark. Computing the same map once takes 0.34 and 0.99 ms respectively. These are not measured UI frame times.
- **Two open PRs address newly examined hot paths:** #167 moves extension source scanning off the main actor; #169 avoids repeated WebKit snapshots during scrolling. Neither fixes synchronous snapshot-file operations in finding 2.
- **Sync is now measured rather than only suspected:** a single bookmark rename costs 30.1 ms for the core synchronous pipeline at 10,000 bookmarks, before CloudKit submission, persistence and rendering.

## Priority and evidence

| ID | Priority | Scope | Finding | Evidence | Open PR coverage |
|---|---|---|---|---|---|
| 1 | P1 | Main, shared | History maintenance delays history results | 10k pages: 31 to 33 s; indexed copy: 0.760 s | None |
| 8 | P1 for large bars | PR #170 only | Rebuild bookmark/tab map for each iPad bar row | 1k rows: 136 ms; 3k: 1.10 s | Introduced by #170; not in main |
| 2 | P2 | Main, shared | Synchronous snapshot-file operations on UI paths | 4k files: 20.3 ms invalidation; queued-write stress: 29 to 72 ms | None; #169 concerns a different snapshot path |
| 3 | P2 | Main, shared | Broad empty/short history queries and obsolete queued work | 10k pages: 12 to 17 ms per query | None |
| 4 | P2, runtime severity unmeasured | Main, shared | Cold icon reads/image preparation during rendering | Direct main-actor disk path | #166 is documentation/tests, not a fix |
| 5 | P2 | Main, shared | Full sync reconstruction/stamping for one bookmark edit | 10k bookmarks: 30.1 ms | None |
| 6 | P2 | Main, Mac | Extension JavaScript scanning during load on the main actor | 1 MiB synthetic source: 128 ms, excluding ZIP I/O | #167 addresses scanning isolation and deduplication; residual I/O remains |
| 7 | P2 candidate | Main, iOS | Repeated page snapshots during scrolling/touch | Call paths and scheduling verified; no device timing | #169 directly addresses this path |

P1 indicates the highest-priority scaling problems identified, not a release-blocking policy. P2 indicates smaller or workload-dependent responsiveness risks. Findings 1, 2, 3, 5, 6 and 8 include component measurements. Findings 4 and 7 have verified code paths but unmeasured runtime severity. No synthetic timing is presented as an app frame, startup or real-user measurement.

## Open PR assessment

This is performance-focused review of relevant source changes, not approval of each PR's functional correctness or security. PR descriptions and reported tests are context, not tests rerun by this audit. Compare #168 against #167, its actual base; do not count the inherited scanner fix twice.

| PR and pinned head | What it changes for this audit | Assessment |
|---|---|---|
| [#170](https://github.com/eGlu-dot-app/eGlu/pull/170), [551622d](https://github.com/eGlu-dot-app/eGlu/commit/551622df68580b17dba56dfb9e965e1010598ed1) | Adds bookmark-backed pinned rows, `barTabs`, `isInBar` and `home` lookups | New repeated full-tree work, measured in finding 8. Mac parent lookup is already hoisted, but row helpers can reconstruct it again. Does not change history/snapshot/icon implementations or the sync stamping algorithm. |
| [#169](https://github.com/eGlu-dot-app/eGlu/pull/169), [a007b22](https://github.com/eGlu-dot-app/eGlu/commit/a007b22698a1bb06656f0f99ba995c6b90813ff2) | Changes iPhone Duo layout, colour sampling and adds `strip.js` | Directly reduces finding 7's snapshot workload. Does not change `PageSnapshotFiles`, so finding 2 remains. New DOM processing has useful throttles, but its 4 ms budget is not a hard cap; see below. |
| [#168](https://github.com/eGlu-dot-app/eGlu/pull/168), [e27fffb](https://github.com/eGlu-dot-app/eGlu/commit/e27fffb039480ad219f810be28d6a8995a392c08) | Per-extension cookie choice, stacked on #167 | No independent fix for findings 1 to 5. A changed choice restarts the extension in each loaded space; unchanged choices return early. Treat this as user-triggered reload work, not a continuous background loop. |
| [#167](https://github.com/eGlu-dot-app/eGlu/pull/167), [164cf96](https://github.com/eGlu-dot-app/eGlu/commit/164cf96899bc0e1539029bd83400a795ebe5b4fe) | Extension messaging, source scanning and popup sizing | Addresses the main scanner CPU path in finding 6: detached utility work, in-flight deduplication and cached results keyed by version/missing API set. Store-download CRX verification also moves off-main. `firstLook` still reads the archive/manifest synchronously. |
| [#166](https://github.com/eGlu-dot-app/eGlu/pull/166), [fa4e878](https://github.com/eGlu-dot-app/eGlu/commit/fa4e8787a71ca542b8b50c255c44dd6c0ae2adee) | Favicon persistence documentation and a 500-icon import test | No production change. The test checks durability and one announcement, not cold lookup latency or cache memory. Finding 4 remains. |
| [#97](https://github.com/eGlu-dot-app/eGlu/pull/97), [3a06fc8](https://github.com/eGlu-dot-app/eGlu/commit/3a06fc87da267283aeaf639f9c617f462318a73d) | Entitlement-gated Mac passkeys and bridge scripts | No fix for the ranked findings. Reviewed activation and request lifecycle: scripts/relay are gated and timeouts are request-specific, not an always-running polling interval. Entitled runtime behavior was not tested. |

### Additional PR #169 watchpoint: bounded work has unbounded substeps

[`strip.js`](https://github.com/eGlu-dot-app/eGlu/blob/a007b22698a1bb06656f0f99ba995c6b90813ff2/PadCore/Sources/PadCore/Scripts/strip.js#L1223-L1394) pauses for touch/scroll activity, skips hidden documents, batches work through animation frames, and gives `work` a 4 ms slice. Those are meaningful safeguards. However, `observeIn` executes `querySelectorAll(PRESSABLE)` and loops over all matches before checking the deadline again. Initial scans and a large inserted subtree can therefore exceed a slice. This is a static risk, not a demonstrated regression. The script already exposes `__egluStrip.state().longest`, `calm` and failure counts for measurement. Read those after a large-DOM load and mutation burst; do not invoke `leftovers()` while measuring normal cost because that diagnostic itself scans the DOM. Frame scheduling alone does not guarantee that geometry reads cannot force layout.

## Main-branch findings

## 1. History maintenance: wrong index shape plus full refresh

**Scenario:** Launch with a substantial retained history, browse while history is being imported, or perform maintenance. History results can remain unavailable even though the browser's main thread itself is not blocked by the database actor.

**Code evidence:**
- [HistoryStore.refresh, lines 677 to 706](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/HistoryStore.swift#L677-L706) requests the last ten visits and last non-null search for each page, ordered by time.
- [Schema, lines 744 to 757](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/HistoryStore.swift#L744-L757) provides `(space,time)` and `(space,page)` separately, not `(space,page,time)`.
- The fixture query plans choose `visits_by_time (space=?)` for both ordered per-page queries. Pages with fewer than ten visits, or no search term, require scanning the space's visits. Repeating this for every page produces approximately quadratic work for this dataset.
- [prune, lines 646 to 666](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/HistoryStore.swift#L646-L666) refreshes **every** page, even with no expired visits. Refresh also deletes and reinserts its unchanged FTS text.
- [Mac startup](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Session.swift#L157-L168) and [iOS startup](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/App/Sources/Session.swift#L105-L115) schedule pruning. [HistoryRecorder](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/HistoryRecorder.swift#L233-L247) limits it using an in-memory timestamp, so a fresh process schedules it again. [Reads await the write chain](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/HistoryRecorder.swift#L423-L434).

**Measurement:** One space, 10,000 unique pages, one recent link visit per page, no expired data and no saved search terms. Production `prune(.forever)` took 33.438 s. Reopened baseline with `.month` took 31.000 s. On a database copy with only `CREATE INDEX audit_visits_by_page_time ON visits(space,page,time DESC)`, the same production `.month` prune took 0.760 s, about 41 times faster. The product source was not patched. Initial batch merge also took 30.668 s, showing the refresh cost affects imports, not only pruning.

**Remediation:** Add a migrated composite index matching the per-page ordered queries. Separately avoid rebuilding unchanged FTS entries during retention/frecency maintenance. Preserve time-dependent ranking semantics rather than simply skipping score refresh. Batch maintenance so reads need not wait behind an entire long transaction.

## 2. Snapshot work blocks navigation and tab restoration

**Code evidence:** [Mac Pages.page](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Pages.swift#L12-L54) and [iOS Pages.page](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/App/Sources/Pages.swift#L38-L80) are main-actor paths. They obtain a token and consume saved state synchronously. [PageSnapshotFiles](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/PageSnapshotFiles.swift#L25-L75) uses one serial queue for encoding/writes, token checks, state reads/decode/deletion, and invalidation. Its synchronous calls must wait for earlier queued work. [Navigation invalidates snapshots](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Pages.swift#L137-L148); each invalidation enumerates the whole snapshot directory and parses file names, even when the tab has no snapshot there.

**Measurement:** Median of 25 invalidations against 100 / 1,000 / 4,000 cached files: 0.50 / 3.73 / 20.31 ms. Consuming state behind 20 queued 1 MB writes blocked the caller for 29 to 72 ms. This is a stress test of the synchronization contract, not a claim that every tab switch queues 20 writes. In the app the wait may occur earlier at token acquisition, which uses the same queue.

**Remediation:** Keep generation/token validation cheap and separate from disk serialization. Track per-tab snapshot paths instead of scanning the directory. Restore/consume state asynchronously while preserving the current once-only restore, stale-token rejection and deletion guarantees. Moving the same synchronous call into an inherited main-actor Task would not solve the problem.

## 3. Short autocomplete queries do too much database work

**Code evidence:** [HistoryStore.search, lines 205 to 241](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/HistoryStore.swift#L205-L241) joins FTS even for an empty query. Terms under three normalized scalars use leading-wildcard `LIKE` over title, URL words and summary. All matches are ranked without a matching ranking index. A limit of 12 limits returned rows, not inspected rows. The fixture plan uses a temporary B-tree for ordering.

[SuggestionSources.recall](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/SuggestionSources.swift#L117-L127) starts history work without the remote suggestion path's debounce. Cancellation suppresses obsolete answers but is checked only after the database request returns; the SQLite stepping path does not cooperatively cancel old queries. This matters especially when many requests accumulate behind maintenance.

**Measurement:** Seven warm release calls per query, 10,000 pages, limit 12: empty 16.922 ms; `d` 12.970 ms; `de` 12.242 ms; `design` 2.256 ms; absent long term 0.119 ms. Similar descriptions and broadly matching titles intentionally stress common short queries. These run off the main actor, so the demonstrated problem is database work and suggestion latency, not a directly measured typing freeze.

**Remediation:** Give empty queries a direct indexed top-pages path without FTS. Coalesce history requests before starting SQLite work, reject cancelled requests before execution, and choose a bounded short-query strategy that preserves required substring semantics. Do not silently remove short Korean search support.

## 4. Cold icons perform synchronous disk work during rendering

**Code evidence:** [SiteIcons](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/SiteIcons.swift#L32-L40) is main-actor isolated. [image/needsLightGround](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/SiteIcons.swift#L110-L134) reach [stored](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/SiteIcons.swift#L176-L193), which tries multiple cache locations, reads bytes and constructs platform images synchronously. [Mac tab rendering](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/TopTabBar.swift#L134-L148) and [iOS icon refresh](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/App/Sources/TabRow.swift#L60-L73) use this API. First dark-shape classification also rasterizes/inspects the icon on this path. NSImage may defer some decoding until drawing, so image construction alone does not establish immediate full decoding.

**Impact:** Cold launch or first exposure to many saved sites can combine many small disk operations on the UI thread. In-memory positive and negative caches mitigate later lookups. Runtime severity and retained image-cache size were not measured; this is not a demonstrated leak.

**Remediation:** Make render-time lookup memory-only. Load and prepare disk icons off-main, coalesce requests per key, then publish completion on the main actor. Preserve negative caching and use a bounded image cache if allocations show material growth.

## 5. One syncable edit rebuilds and stamps the whole workspace

**Scenario:** Rename a bookmark, reorder synced items, or edit a synced space in a large workspace. This requires sync to be running/joined. Ordinary unsynced navigation is not the measured scenario.

**Verified path:** [`Sync.changed → queueChanges → commit`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Shared/Sync.swift#L439-L464) runs in the main-actor `Sync` class. [`SyncPlan.records`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/SyncModel.swift#L452-L510) reconstructs records, and [`SyncPlan.stamp`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/SyncCRDT.swift#L349-L410) unions/sorts record IDs and compares fields, including unchanged records.

**Measurement:** One flat, joined space; rename one middle bookmark against an already-stamped mirror. Nine release iterations, each starting from the same baseline. The runner asserts exactly one changed record and no space resurrection.

| Bookmarks | Change detection + record reconstruction, median | Stamping + settle, median | Total measured pipeline, median |
|---:|---:|---:|---:|
| 100 | 0.045 ms | 0.191 ms | 0.238 ms |
| 1,000 | 0.398 ms | 1.972 ms | 2.404 ms |
| 10,000 | 4.720 ms | 23.927 ms | 30.101 ms |

Component medians need not add to the median total. This is not CloudKit latency or total `Session.change` latency. The measured work is synchronous on the production UI path; 30 ms is enough work to exceed a 16.7 ms frame interval, but this audit did not measure actual dropped frames.

**Direction:** Track changed records/subtrees and preserve unchanged record representations rather than regenerating and comparing everything. Alternatively, evaluate ordered background work over immutable snapshots. Do not simply debounce CRDT stamping: ordering, deletion/resurrection semantics, clock updates and immediate local edits must remain correct. The existing position algorithm and precomputed position maps are safeguards, not the source of a newly claimed quadratic algorithm. No open PR replaces this full-workspace stamping path.

## 6. Extension code scans consume main-actor CPU during loading

**Verified path:** [`Extensions.load`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Extensions.swift#L489-L526) awaits off-main preparation, then resumes on the main actor and calls [`firstLook`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Extensions.swift#L711-L732). That reads the archive/manifest and calls [`notes`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Extensions.swift#L765-L786), extracting JavaScript and calling `ExtensionScan.uses`. Loading into another space repeats the work. `measureTable` can scan again.

[`ExtensionScan.uses`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/PadCore/Sources/PadCore/ExtensionScan.swift#L55-L113) tokenizes the whole input before considering the missing-API set. Even an empty set does not avoid scanning.

| Synthetic JavaScript bytes | Scan median, 3 calls |
|---:|---:|
| 4,092 | 0.506 ms |
| 262,119 | 30.264 ms |
| 1,048,575 | 128.310 ms |

The input repeats a small benign function and requests no missing APIs; the runner asserts zero findings. This isolates CPU cost, not a real extension's startup time. ZIP reads/decompression, WebKit loading and allocation peaks are excluded. No several-second real-extension freeze was measured here.

**PR-aware direction:** #167 already moves `notes` into a detached utility task, caches by version/missing APIs, coalesces identical in-flight scans, and rejects superseded keys. Do not duplicate that work. Its `firstLook` archive/manifest disk read is still synchronous; profile that remaining part after the PR. An empty-missing-set early return can also avoid unnecessary tokenization entirely, including background CPU, if the scan's output contract stays unchanged. `addFromFile` remains a separate main-actor file-read/verification path; store-download verification is improved by #167.

## 7. Page-colour snapshots are scheduled during iPhone scrolling/touch

**Verified main behavior:** [`sampleFootSoon`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/App/Sources/Page.swift#L1402-L1422) requests quick sampling every 250 ms while movement continues, followed by exact sampling. [`sampleFoot`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/App/Sources/Page.swift#L1325-L1375) calls `sampleStrip`, may render the hierarchy for an exact result, and otherwise requests a WebKit snapshot. [`touched`](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/App/Sources/Page.swift#L1424-L1435) schedules three additional colour passes, cancelling the prior touch sequence. The active work depends on footer/strip visibility and page state.

This creates repeated work for a decorative colour feature while the user is interacting. An asynchronous completion handler does not establish that snapshot setup/compositing is free, but this review does not establish its main-thread duration either. **This is a candidate supported by scheduling evidence, not a measured frame-rate regression.**

**PR-aware direction:** [#169's sampling path](https://github.com/eGlu-dot-app/eGlu/blob/a007b22698a1bb06656f0f99ba995c6b90813ff2/App/Sources/Page.swift#L1288-L1409) first asks page styles, defers picture sampling while a finger is down or the view decelerates, and falls back to exact imagery when still. Validate gradients/canvas content and hands-off pages as well as plain backgrounds. This improves WebKit image capture, not snapshot-file restoration or invalidation in finding 2.

## 8. PR #170: bookmark-bar lookup is reconstructed per row

**This finding is not present on current main.** It applies to PR head `551622df68580b17dba56dfb9e965e1010598ed1`.

**Verified path:** [`BarBookmarkRow.body`](https://github.com/eGlu-dot-app/eGlu/blob/551622df68580b17dba56dfb9e965e1010598ed1/App/Sources/SideTabs.swift#L616-L644) calls `space.barTabs[item.id]` for each row. [`Space.barTabs`](https://github.com/eGlu-dot-app/eGlu/blob/551622df68580b17dba56dfb9e965e1010598ed1/PadCore/Sources/PadCore/Workspace.swift#L178-L209) is computed, not cached: it traverses the bar IDs and scans tabs to build a dictionary. The [row list uses a VStack](https://github.com/eGlu-dot-app/eGlu/blob/551622df68580b17dba56dfb9e965e1010598ed1/App/Sources/SideTabs.swift#L63-L74), not a LazyVStack.

For R evaluated rows, B bookmarks in the bar and T tabs, the lookup pattern costs approximately O(R × (B + T)), before icon loading, text/layout or drawing. The Mac parent already hoists its map, so it would be wrong to attribute the exact iPad loop to Mac. However, [Mac rows](https://github.com/eGlu-dot-app/eGlu/blob/551622df68580b17dba56dfb9e965e1010598ed1/Mac/Sources/Sidebar.swift#L577-L605) call `isAwayFromHome`, which reaches `home → isInBar → barTabs` and then bookmark lookup; open rows can reintroduce repeated work.

**Measurement:** Release benchmark importing the unmodified PadCore package extracted from that exact PR. Flat bar, 100 open bookmark-linked tabs, one lookup per row, three-call medians. Both compared paths assert exactly 100 matches.

| Bar rows | Recompute dictionary per row | Same dictionary computed once per pass |
|---:|---:|---:|
| 100 | 5.271 ms | 0.092 ms |
| 1,000 | 136.134 ms | 0.335 ms |
| 3,000 | 1,103.820 ms | 0.986 ms |

These measure the repeated expression, not SwiftUI body evaluation, actual scrolling, or a complete fixed PR. Collapsed folders and fewer evaluated rows reduce total work. The comparison hoists existing computation; no product code was patched.

**Direction:** Compute the bar/tab lookup and bookmark home URLs once for a view update and pass the needed values to rows, including accessibility labels and away-from-home checks. Consider lazy row construction separately for large bars. Preserve duplicate-bookmark handling, first-tab selection, folder visibility and invalidation when tabs/bookmarks change. A global cache without invalidation is not an equivalent fix.

## Additional history scaling evidence

These are new measurements at smaller sizes. The original 10,000-page results are retained unchanged and were not rerun or averaged into the new samples.

| Unique pages, one recent visit each | Prune with nothing expired | Empty search | `de` search | `design` search |
|---:|---:|---:|---:|---:|
| 1,000 | 155.537 ms, median of 3 | 1.217 ms | 1.202 ms | 0.477 ms |
| 3,000 | 2,486.225 ms, median of 3 | 3.173 ms | 2.981 ms | 1.133 ms |
| 10,000, original run | 33,438 ms, one call | 16.922 ms | 12.242 ms | 2.256 ms |

Search columns use seven-call medians. All fixtures use one space, similar titles/descriptions, no saved search terms, and limit 12. Queries return matching rows; data is not user history. The measurements support superlinear maintenance growth for this workload, but do not establish a universal exponent or predict times for a 100,000-page real database. SQLite plan choice, visit distribution, cache state and hardware matter. The index-copy experiment in finding 1 is the stronger causal evidence.

## Coverage and risks not promoted to measured defects

| Area | Verified safeguards / behavior | Remaining evidence gap |
|---|---|---|
| External writing checks | [ElsewhereChecker](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Writing/Elsewhere/ElsewhereChecker.swift#L130-L168) polls text, caret and geometry at 4 Hz while watching. [AX](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Writing/Elsewhere/FrontField.swift#L466-L490) uses a 250 ms messaging timeout and a 2-second pause after qualifying failures. Linting is debounced and stale results are rejected. | Cross-process text/geometry reads still occur on the main actor. No AX IPC/CPU profile on large documents or unresponsive apps; no claim that polling itself is unacceptable. |
| Writing geometry | [FieldGeometry](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Writing/Elsewhere/FieldGeometry.swift#L17-L42) splits multiline ranges and has recursion guards. | Repeated geometry queries across many lints and Chromium fallback traversal may be costly. Needs actual app/document measurements, not a loop-count guess. |
| WebKit lifetime and memory | [Mac freezing](https://github.com/eGlu-dot-app/eGlu/blob/75fcca22f0ae46e36cc60360f000cdf620449abc/Mac/Sources/Pages.swift#L100-L174) accounts for onscreen/protected tabs and memory pressure. Page teardown removes scripts/handlers and stops loading; relay references are weak. | A live-view policy is not a byte budget. Frozen interaction states remain in memory as well as on disk; icon dictionaries also retain entries. Measure app and WebContent-process allocations across repeated open/freeze/reopen/close cycles before claiming a leak. |
| Page scripts | Content blocking uses incremental mutations, cached matchers, adaptive delay and hidden-document throttling. Writing uses debounce and polling rather than linting every mutation. | No dynamic-page, infinite-scroll or battery profile. Existing throttles reduce risk but do not prove low cost on every site. |
| Persistence | Workspace saves are debounced/offloaded. History writes are serialized outside the main actor. | Off-main work can still delay dependent reads, as finding 1 shows. No general claim that all persistence blocks UI. |
| CloudKit/network | Sync bookkeeping was measured without network access. | No energy, bandwidth, rate-limit, retry, server-latency or multi-device timing measurements. |

## Fix validation and tradeoffs

These are proposed acceptance checks for future work, not checks run by this audit. At 60 Hz a whole frame has about 16.7 ms; at 120 Hz about 8.3 ms. Individual helpers should consume only part of that budget. Choose device-specific targets rather than treating this VM's times as release thresholds.

| Work item | Relative scope | What should prove it works | Important constraint |
|---|---|---|---|
| History composite index | Small migration, high leverage | Explain plans use the composite index; compare 1k/3k/10k fixtures; searches remain usable around maintenance | Extra index costs disk/write work; preserve existing databases and all retention modes |
| Avoid unchanged FTS rebuilds / batch maintenance | Medium | FTS rows change only when indexed text changes; expired visits/pages disappear; frecency changes correctly with time | Do not silently make rankings stale or expose inconsistent partial maintenance |
| Snapshot UI-path I/O | Medium to large | Cold restore and navigation do not synchronously wait for queued disk writes; exact-once restore and stale-token tests still pass | Keep sign-in/extension privacy exclusions and generation ordering |
| Short-query handling | Medium | Empty query avoids FTS; obsolete requests are discarded before SQLite work; short substring queries keep expected matches | Preserve Korean and other short non-Latin searches |
| Icon loading | Medium | Cold many-site display has no per-row disk reads; warm reads remain memory-only; imports still notify correctly | Avoid duplicate fetches, cache races and broken legacy migration |
| Incremental sync bookkeeping | Medium to large | Single-record edits no longer require full reconstruction; unchanged and deleted records reconcile identically | CRDT clocks, resurrection and ordering are correctness-critical |
| Extension scan, coordinated with #167 | Mostly proposed already | One scan per key across spaces; no scan on main actor; superseded results discarded; empty API set does no lexer work | Profile remaining synchronous archive/manifest and file-install work separately |
| iPhone sampling, coordinated with #169 | Proposed already | Trace snapshot requests while scrolling/decelerating; preserve colour correctness after settling; record strip script longest slices | Respect hands-off pages; do not trade a main-process capture spike for an unbounded DOM scan |
| PR #170 bar lookups | Small to medium | One derived map per view update; near-linear scaling as row count grows; same row/tab/home results | Mac parent already hoists one lookup; remove indirect row recomputation too |

## Method, reproducibility and limits

- Main source inspection covered startup/service wiring, tab lifecycle, snapshot persistence, history/search, sync, icons, extensions, writing and page scripts. PR review targeted changed performance-sensitive paths, not marketing assets or every generated UI fixture.
- All measurements are release-mode standalone components. The original main-package benchmark and the new PR #170 benchmark built successfully. No full app build or product test suite was run.
- Environment: ARM64 macOS 26.6.2 VM, 12 CPUs, 16 GiB RAM, Swift 6.3.3. No iOS hardware was measured. Most measurements are warm calls; this is not a cold-start benchmark. Small sample sizes describe these fixtures, not population percentiles.
- The original report and baseline logs are preserved. The original macOS `sample` capture came from a subsequently stopped larger history-seeding run, not the running browser. No Instruments trace was captured.
- New logs: `enrichment.log`, `extension-scan.log`, `pr170-benchmark.log`. The evidence archive contains harness source, reproduction instructions, original logs/query plans/sample, and new logs. It excludes generated databases, copied product source and build output.
- `README.md` explains fixture shape, assertions, exact commands, absolute-path adjustments and how to extract the pinned PR package. No account secrets or real browsing data were used.
- No fix was implemented or merged. PR coverage above means code-level proposed coverage, not measured post-merge performance. Heads were unchanged on the final remote check.
