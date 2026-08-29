# Plan DK — Protected Conversation Recall Index

**Status:** 🚧 P0–P3 implementation complete (2026-08-30); full suite and Release simulator gates
are green, with oldest-supported-phone footprint and lifecycle smoke evidence still required.
**Origin:** 2026-08-26 adversarial review finding 2 (High).
**Priority:** P0 privacy remediation; ship before expanding recall or conversation-lock features.

This plan makes conversation recall obey the same confidentiality, lock, deletion, and retention
semantics as `ConversationStore`. The source of truth stays the encrypted conversation store; the
search index is disposable derived state, never a second durable plaintext store.

**Implementation checkpoint (2026-08-30):** production composition uses
`ConversationRecallCoordinator` and SQLite `:memory:` only; launch/unlock retries legacy DB/WAL/SHM
removal and fails closed; lock or iOS protected-data loss cancels the detached rebuild and drops the
handle; typed search states and post-persistence append/truncate/thread-delete projection events are
wired. The fresh-index path uses one prepared statement and transaction. The focused recall suite is
green (32 tests plus the opt-in performance harness); the full suite passed 3,743 tests with zero
failures and four environment-gated skips; the Release simulator build passed. Simulator benchmark
test durations were approximately 12 ms / 72 ms / 305 ms at 1k / 10k / 50k turns. Still owed before
marking DK fully verified: run the same harness and protected-data lock/unlock smoke on the oldest
supported physical phone and record footprint. Explicit edit/import/store-replacement entry points
remain future mutation work because those source APIs do not exist. OpenGlasses has no app-account
logout; provider OAuth sign-out does not own conversation data and is intentionally not coupled to
recall lifecycle.

---

## Problem and verified path

`ConversationIndex` opens `Documents/conversation_index.sqlite`, enables WAL, and writes every turn's
full text to an FTS5 table — with no file-protection attribute or backup exclusion, while
`ConversationStore.save()` itself writes with `.completeFileProtection`. `OpenGlassesApp` configures
and backfills that index independently of the conversation lock, and `ConversationStore.indexMessage`
indexes every appended message without checking `encryption.isEnabled` or `isLocked`. Deleting a
thread or truncating messages updates `ConversationStore` but does not remove corresponding FTS rows:
the index has `delete(id:)` and `clear()` APIs, but **nothing calls them**. This defeats the
protection users reasonably infer from encrypted or biometrically locked conversations and leaves
deleted text in the database, WAL, or SHM files.

Two lifecycle wrinkles worth designing for, not just the leak:

- **Unlock never re-indexes.** The launch backfill runs only when `count() == 0`, and
  `ConversationStore.unlock()` reloads threads without touching the index. A store that starts locked
  therefore never backfills its history; only post-unlock messages get indexed. Coverage is
  inconsistent as well as unprotected — P1's rebuild-on-unlock fixes both.
- Neither `MemoryRecallCoreTests` nor `MemoryRecallServiceTests` asserts that delete/truncate removes
  index rows, so the gap has no regression tripwire today.

Relevant seams:

- `OpenGlasses/Sources/Services/Memory/ConversationIndex.swift`
- `OpenGlasses/Sources/Services/Memory/RecallService.swift`
- `OpenGlasses/Sources/Services/ConversationStore.swift`
- recall setup/backfill in `OpenGlasses/Sources/App/OpenGlassesApp.swift`
- `OpenGlassesTests/MemoryRecallCoreTests.swift`
- `OpenGlassesTests/MemoryRecallServiceTests.swift`

## Decisions and invariants

1. Production recall uses an **in-memory FTS5 index**. Stock SQLite FTS is not encrypted, and iOS file
   protection alone does not enforce the app's biometric conversation lock.
2. The index exists only while the conversation store is unlocked and available. Locking destroys
   the database connection; searching while locked returns a typed locked result, never stale hits.
3. The index is a projection of the current source of truth. Delete, truncate, edit, import, restore,
   and encryption-state changes update or rebuild it through one coordinator.
4. No production fallback may silently reopen a file-backed plaintext index if memory allocation or
   rebuild fails. Recall becomes temporarily unavailable and conversations remain usable.
5. Tests may inject a temporary file URL to exercise SQLite behavior, but that initializer must not be
   reachable from the production composition root.

---

## P0 — Remove the legacy plaintext artifact 🔴

1. Before recall setup, close any legacy index and delete all three possible files:
   `conversation_index.sqlite`, `conversation_index.sqlite-wal`, and
   `conversation_index.sqlite-shm`.
2. Put migration in a versioned `RecallIndexMigration`, not an ad hoc launch snippet. Record completion
   only after all existing artifacts are absent. Retry on next unlock/launch if a file is busy.
3. If deletion fails, disable recall, show a content-free diagnostics item, and do not open or backfill
   the old database. Conversation use must continue.
4. Remove the default `Documents` path from the production initializer. Use SQLite's `:memory:` URI or
   an equivalent injected connection factory.
5. Apply complete file protection to any migration marker or content-free recall metadata and exclude
   it from backups.

Deletion on flash storage cannot prove physical overwriting. Release notes/security documentation
must state that the update removes discoverable app artifacts on first launch but cannot retroactively
guarantee forensic erasure of prior device snapshots or backups.

**Tests.** Migration removes DB/WAL/SHM; partial failure is retried; recall remains disabled while an
artifact cannot be removed; production factory opens memory-only SQLite; the app never creates a
conversation-index file under Documents/Library during an integration test.

## P1 — Lock-aware index lifecycle 🔴

Add a main-actor `ConversationRecallCoordinator` with explicit states:

```text
locked → rebuilding(progress) → ready
   ↑           │                 │
   └────────── lock/failure ─────┘
```

1. The coordinator observes the authoritative `ConversationStore` lock transition rather than reading
   global state opportunistically.
2. On successful unlock, create a fresh in-memory index and backfill from the decrypted snapshot on a
   bounded background task. Publish progress without exposing content.
3. Keep search unavailable until the snapshot is internally consistent. Do not return partial results
   that omit older threads without telling the caller.
4. On lock, logout, protected-data-unavailable notification, or store replacement: cancel rebuild,
   close the SQLite handle, clear pending decrypted turns, and transition to `locked`.
5. `RecallService` returns a typed `.locked`, `.rebuilding`, `.ready(hits)`, or `.unavailable` result.
   Tool/UI adapters turn those into honest user messages and never bypass the coordinator.
6. Bound rebuild memory and batch inserts. If the corpus is too large, keep conversations accessible,
   expose recall unavailable, and record only counts/timing in diagnostics.

**Tests.** Locked search yields no rows; unlock triggers one rebuild; a lock during rebuild cancels and
destroys the index; unlock again starts from a clean snapshot; no decrypted `IndexedTurn` remains in a
queued closure after lock; rebuild failure does not affect conversation reads.

## P2 — Projection integrity for mutations 🟠

Make store mutations emit typed, ordered projection events after durable source-of-truth success:

- `.messageUpsert(threadID, message)`
- `.messageDelete(threadID, messageIDs)`
- `.threadDelete(threadID)`
- `.storeReplaced(snapshotVersion)`
- `.lockStateChanged`

1. Extend the index's existing (currently uncalled) `delete(id:)`/`clear()` with a
   `delete(threadID:)` and a batched `delete(messageIDs:)`; do not search then delete one row at a
   time.
2. `ConversationStore.deleteThread` emits `threadDelete` only after `save()` succeeds. If persistence
   fails, neither source nor projection should claim deletion.
3. `truncate(from:in:)` captures removed message ids and deletes those exact rows. Editing/regenerating
   a message uses upsert for the replacement.
4. Imports, recovery/salvage, and full-store replacement request one atomic rebuild rather than a long
   sequence of ambiguous deltas.
5. Assign a monotonically increasing in-process projection version. Search results include the version
   so a caller can reject a result produced before its mutation completed.
6. Keep event payloads in memory and scoped to the coordinator; do not introduce a plaintext queue.

**Tests.** Delete-thread removes all hits; truncate removes only the suffix; edit replaces searchable
text; save failure leaves projection unchanged; rapid delete/search is ordered; store replacement
cannot mix old and new rows; duplicate upserts stay idempotent.

## P3 — Performance and product behavior 🟡

1. Benchmark rebuild at representative 1k/10k/50k-turn corpora on the oldest supported phone. Capture
   elapsed time and peak memory, never text.
2. Rebuild recent threads first only if the UI clearly reports a partial state; the default remains
   all-or-nothing readiness for simpler privacy and correctness semantics.
3. Add an optional “Clear recall cache” control that destroys and rebuilds the in-memory projection.
   It must not imply conversation deletion.
4. Update the conversation-lock and memory settings copy: recall is unavailable while locked and the
   searchable projection is rebuilt in memory after unlock.

**Implementation evidence (2026-08-30).** `ConversationRecallPerformanceTests` is an opt-in harness
for 1k/10k/50k turns. Set `DK_RECALL_BENCHMARK` and `DK_RECALL_BENCHMARK_TURNS` in the physical-device
test scheme or simulator launch environment. The iPhone 17 Pro simulator completed those cases in
approximately 12 ms, 72 ms, and 305 ms of test time respectively after the fresh-index prepared-
statement optimization. Simulator memory is not a jetsam budget, so the oldest-phone run remains the
release evidence for retained footprint rather than substituting a desktop number.

---

## Rollout, rollback, and exit criteria

Roll out P0 and P1 together behind a memory-index feature flag default-on. A rollback may disable
recall entirely; it must never restore the file-backed plaintext implementation. P2 follows before
claiming delete/truncate parity. P3 performance thresholds decide whether incremental unlocked-session
maintenance is sufficient or whether an encrypted-search design deserves a separate plan.

Complete when:

- no production path creates a persistent database containing conversation text;
- legacy DB/WAL/SHM artifacts are removed or recall fails closed with a visible diagnostic;
- recall returns no content before successful unlock and closes immediately on lock;
- delete, truncate, edit, import, and store replacement have regression coverage;
- a filesystem integration test proves no recall index survives relaunch; and
- the full unit suite and a Release build are green.

Coordinate content-free lifecycle logging with [[DM-privacy-safe-production-logging]].
