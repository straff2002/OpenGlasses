# Plan FN — Individual manual removal from installed vaults

Status: 🚧 PR1 (headless core) implemented. PR2 (UI + live-session invalidation) pending.

PR1 built §1 in full, the §3 import fix, and the parts of §2 that are retrieval-side: the removal
operation and its journal, the checked namespace-scoped document delete, per-vault serialisation of
import / re-index / removal / uninstall, launch-time recovery of an interrupted removal, and the
availability check that stops an in-flight retrieval publishing a manual that has gone. PR2 owns the
**Remove manual…** action and its confirmation, the active-session refresh, staged-figure and
citation invalidation, and the vault-guide copy.

**Corrections to the *Current behavior* section, verified against the code (2026-09-21):**

- `DocumentStore.forget` does not merely "return no error" — it swallows SQLite's error entirely
  (`exec` discards the result), so a refused delete was indistinguishable from a successful one.
  The checked form added in PR1 propagates, scopes to a namespace and verifies the rows are gone.
- The cleanup gap is slightly wider than described: the import UI gates the sync on `hasDocuments`,
  and so does the **Re-index manuals** button, so a manifest re-imported with no manuals had no
  route to reconciliation at all. `VaultImporter.needsDocumentSync(manifest:)` is the fix.
- `VaultImporter.installReporting` could not install a vault whose two documents name the same
  bundled original: the copy loop failed on the second one. Fixed in PR1, since the shared-original
  rule in §1 is unreachable otherwise.
- Export needed no change. `VaultExporter` reads the manifest through `VaultRegistry`, which reads
  the registry directory, so a reduced manifest is what it exports once the registry is reloaded.

## Outcome

Max can remove the SLP99 installation manual directly in Custom Vaults without editing a manifest on his computer or re-importing the vault. Once removal succeeds, new retrievals cannot return that manual, including after restarting the app or tapping Re-index manuals. The service manual and the rest of the vault continue working.

The guarantee is removal from the installed vault and its retrieval index. It does not erase passages already sent to a model, existing chat messages or session records, independently imported copies, or facts copied into core reference files. The UI must explain this without claiming the model has forgotten the material.

## Current behavior and relevant code

- `VaultManagerView.swift` lists manuals and offers Re-index manuals, but deletion targets whole vaults only.
- `DocumentsView.swift` deliberately excludes vault namespaces from its deletion interface.
- `VaultImporter.installReporting` copies source material into a private baseline and persists the installed manifest separately in `_registry`.
- `VaultImporter.syncDocuments` diffs the manifest against `VaultDocumentLedger`, forgetting indexed documents that were dropped. The import UI only invokes it when `hasDocuments` is true, leaving a cleanup gap when the last manual is removed from an imported manifest.
- `DocumentStore.forget` deletes document and chunk rows, but currently returns no error or confirmation of persistent deletion.
- `FieldSessionService` retains an active vault and can stage manual figures; refreshing `VaultRegistry` alone does not invalidate that session's state.

## Product decisions

1. Add a destructive **Remove manual…** action for each manual in an installed user vault. Use a dedicated manual row/detail action so it cannot be confused with deleting the whole vault.
2. Confirm with the manual title and vault name: “Remove this manual from this device's vault and search index? Existing conversations and core reference files are unchanged. Importing a vault containing this manual again can restore it.”
3. Removal updates the installed manifest, ledger, index and installed files. Treat this as an explicit installation-management operation, distinct from editing core reference overlays. Do not alter the user's original import folder or bundled/signed pack content.
4. Preserve the vault ID, version, other documents and core-file overlays. Export reflects the reduced manual list. An explicit later re-import is authoritative and may restore the manual; no persistent exclusion policy is introduced in this slice.
5. Allow removal of installed user content even if the Team entitlement has expired. Keep import/re-index entitlement requirements unchanged.
6. Do not silently erase chat history or end a job. Refresh the active vault and clear affected pending source material. Explain that starting a fresh conversation is necessary for a clean test without earlier quotations.

## Implementation

### 1. Centralize removal and persistence

Add an async removal operation in the vault service layer, addressed by vault ID and manifest document file identity, never title alone. It must work for indexed, unindexed and partially indexed manuals.

- Resolve the installed manifest and validate that the target belongs to a user-installed vault. Reuse path validation and reject paths escaping the vault.
- Serialize removal with import, sync and uninstall for the same vault. Indexing yields while running, so disabling a UI button alone is insufficient to prevent a deleted manual being ingested again.
- Introduce checked, transactional document deletion in `DocumentStore`, scoped to the expected vault namespace. SQL failures must propagate; success must mean both document metadata and chunks are absent.
- Persist a small pending-removal record before changing durable state. Exclude pending targets from retrieval and source opening until cleanup completes. Recover pending removals before making the affected vault available after launch.
- Atomically save the reduced installed manifest, remove the matching index entry and ledger entry, and delete the installed document. Delete its optional original PDF only if no remaining document references that path. Apply the same shared-reference check to document files and recognition checkpoints.
- Clear the pending record only after every required cleanup step succeeds. Make retries idempotent. If cleanup fails, show a retryable error and keep the target unavailable instead of reporting full success.
- Handle absent/corrupt ledger information explicitly: do not guess document identity from a display title or report that the index is clean without verifying it. Surface a repair requirement if ownership cannot be established.

Keep the recovery mechanism limited to this operation; avoid redesigning all vault persistence.

### 2. Refresh retrieval and active state

- Reload installed manifests and invalidate cached vault stores after the effective manual list changes.
- Refresh the active session's vault representation without losing job identity, observations or audit history.
- Invalidate pending passages, staged figures and source viewers for the removed document. Old citations should display “Manual removed from this vault” rather than resolve an obsolete file.
- Prevent in-flight retrieval/indexing from delivering removed material after removal completes. Use the shared operation coordination plus a final document-availability check before publishing results.
- Trace text chat, realtime tool responses and manual-page rendering consumers during implementation; apply invalidation to all paths holding retrieved material.

### 3. Wire the UI and adjacent cleanup

- Show removal progress and disable conflicting actions for the affected vault. Report success only after durable cleanup completes; retain other manuals and their counts.
- Support removing the final manual, leaving a valid vault with zero reference documents.
- Fix the import path to reconcile previously indexed manuals even when the new manifest has no documents. Cleanup-only reconciliation should not require permission to ingest new manuals.
- Verify that export uses the updated installed manifest and excludes removed files; re-import of that export must not restore them.
- Update the vault guide with the in-app removal flow, re-import restoration behavior and the distinction between manual retrieval, core references and conversation history. Update the baseline-management comments to document this explicit deletion operation.

## Verification

Add focused tests using temporary vault directories and a real test document store where persistence matters:

- Remove installation manual from a two-manual vault: its rows, chunks, manifest/ledger entries and files disappear; service manual remains retrievable.
- Restart/reload and run re-index: removed manual stays absent. Export and re-import the reduced vault: it stays absent.
- Remove the last manual, an unindexed manual and a partially indexed manual. Repeat removal to verify idempotency.
- Re-import a manifest with zero manuals: old indexed passages are cleared.
- Delete a document with an original PDF; preserve source/checkpoint files still used by another document.
- Inject manifest, database and file failures and interruption between persistence steps: no false success, no retrieval of pending removals, and successful retry/recovery.
- Race removal with indexing and retrieval: neither can republish or recreate the removed manual after completion.
- Verify namespace/path boundaries and that unrelated vaults and personal documents remain intact.
- Verify active-session refresh and stale citation handling; preserve chat/session history.
- Verify expired-entitlement deletion and explicit re-import restoration.

Run the relevant vault import/export, ledger, retrieval and document-store suites, then build the iOS target. On device/simulator, import a two-manual fixture with unique phrases, retrieve each, remove one, and confirm in a fresh conversation that only the remaining manual supplies evidence. Repeat after app restart and re-index. Do not use a model's generic answer alone as proof of index removal; inspect retrieved document IDs as well.

## Acceptance criteria

- Max can remove one manual through the app without re-importing or deleting the whole vault.
- A completed removal leaves no retrievable passages or openable installed source for that document.
- Removal survives restart, re-index and export; only an explicit import containing the manual restores it.
- Failures are visible and recoverable, and unrelated vault content continues working.
- The UI accurately distinguishes future retrieval removal from existing conversation and core-reference content.
