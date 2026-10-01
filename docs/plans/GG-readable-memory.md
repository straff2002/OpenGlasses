# Plan GG — Readable Memory (what it knows about me, one fact at a time)

**Status:** ✅ Shipped 2026-10-01 — P0–P3 built in one PR (contracts, provenance migration, the
persona-erasure fix, Forget and Correct across every store with tombstones, the Memory screen, the
`my_memory` voice tool). **Owed on device:** the Memory screen with VoiceOver and the largest
Dynamic Type sizes, and a spoken forget on the glasses (confirmation prompt, the several-matches
hand-off notification). **Not buildable here:** the gateway copy can only be queued for deletion
(the bridge has no delete), and live-session snapshot invalidation waits for Plan FJ, which is
unbuilt — the forgetter's invalidation hook is where it plugs in. See *Implementation notes*.
**Relation to Plan [DX](DX-private-memory-timeline.md):** DX (drafted 2026-08-29, unbuilt) is the full
memory control surface: federated timeline, conversation search, export. GG is **its first
shippable cut**, narrowed to facts about the wearer, grouped the way people think about them, with
Correct and Forget that reach every copy. GG adopts DX's invariants unchanged (existing stores stay
authoritative, no copied memory database, forget means source deletion, locked sources fail
closed, browsing never widens agent recall) and builds DX P0's contracts, the fact half of DX P1 and
the fact routes of DX P3. DX P2 (conversation search) and export stay with DX.
**Related:** Plans AX ([memory-taxonomy](memory-taxonomy.md)), AY ([memory-recall](memory-recall.md)),
EN (brain edges with supersession), [FJ](FJ-live-wearer-memory-continuity.md) (live snapshots must
drop forgotten facts), [FK](FK-memory-quality-and-continuity-benchmarks.md) (deletion benchmarks),
W03.2 subject erasure.

---

## Trigger

"What do you know about me?" has no good answer today. Facts live in four places, the only
editable view is the agent's free-prose `memory.md`, and a wrong fact ("your sister lives in
Wellington") can only be removed by hunting for it.

## Outcome

- By voice: "What do you know about me?", "What do you know about Maria?", "Forget that my sister
  lives in Wellington", "Actually she lives in Nelson."
- On the phone: a **Memory** screen listing individual facts grouped as **People & family**,
  **Places**, **Preferences**, **Unfinished things** and **Other**, each with where it came from, when,
  **Correct** and **Forget**.
- Forget removes the fact from every store that holds it and says honestly where a copy may remain.

## What exists today (verified 2026-10-01)

| Store | What it holds | Delete today |
|---|---|---|
| `SemanticMemoryStore` (`semantic_memory.sqlite`, table `memories`: `key_name`, `value`, `topic`, `namespace`, `created_at`, `expires_at`, `embedding`) | key→value facts, global or per persona; `detectTopic` already buckets into people/places/preferences/health/work/finance/learning/general; diary observations | `forget(_:)`, `clearAll`, `purge…` |
| `BrainStore` (`brain.sqlite`: `entities`, `edges` with `source_ref`, `session_id`, `state`, `superseded_at`; `needs`; `project_memory`) | people, relations, open needs; a corrected edge is **superseded, never deleted** (Plan EN) | `forget(entityName:)` only (a whole person) |
| `AgentDocumentStore` `memory.md` | model-written prose about the wearer | `removeLines(containing:)` (text match) |
| `ObjectMemoryStore` (UserDefaults), `SaveLocationTool` (`saved_locations`) | where things are | per object / per label |

Writes arrive by `[REMEMBER: k = v]` tags (`SemanticMemoryStore.parseAndExecuteCommands`),
`BrainStore.shared.ingest` (reading, badge scan, social context, meetings, memory loop), and
tools (`brain`, `memory_search`, `object_memory`, `save_location`). `pushToGateway` copies each
remembered fact to a connected OpenClaw gateway (`OpenClawBridge.storeMemory`); the bridge has no
delete call. `SubjectErasureCoordinator` erases a **person** across stores in dependency order with
`ErasureReceipt`s (`remotePending` for the gateway copy). `InsightsView` is a read-only usage recap.
No provenance column exists in `memories`.

**Suspected bug found while auditing (verify in P0):** `SubjectErasureCoordinator.eraseSemanticMemory`
selects keys from the **global** `memories` cache and calls `forget(_:)`, which deletes from the
**active persona's** namespace when a persona is active — so a global fact can survive a person
erasure made while a persona is selected. P0 adds a failing test first, then fixes it.

## Design

**`MemoryFact`** (value type, DX's `MemoryTimelineItem` narrowed): `id` = `(store, recordID)`,
`text` (rendered sentence), `group`, `origin` (`toldMe`, `inferred`, `fromAddOn(id)`,
`fromMeeting`, `fromScan`, `imported`, `legacyUnknown`), `sourceRef` (thread id, meeting title,
add-on id), `createdAt`, `capabilities` (`correct`, `forget`).

**`MemoryFactGrouper`** (pure): semantic `topic` → group (`people` → People & family; `places` →
Places; `preferences` → Preferences; others → Other); brain person entities and their edges →
People & family; open `needs` and unfinished project notes → Unfinished things; object memory and
saved locations → Places. Health-topic facts stay in their own **Health** sub-section, collapsed
by default.

**`MemoryFactSource`** adapters (DX's protocol shape): `SemanticFactSource`, `BrainFactSource`,
`AgentNotesFactSource` (each `memory.md` line is a fact with `legacyUnknown` origin),
`PlacesFactSource`. `MemoryFactRepository` merges pages by `(createdAt, id)`; a locked or failing
source shows a status row, never stale rows.

**Provenance at write time.** `memories` gains `origin` and `source_ref` columns (migration; old
rows become `legacyUnknown`, never guessed). Each write path passes its origin. Brain edges already
carry `source_ref`.

**Forget = `MemoryFactForgetter`** (built on `SubjectErasureCoordinator`, new
`ErasureSubject.memoryFact(MemoryFactID)`), in dependency order:
1. live provider snapshots (FJ's invalidation hook) and the recall/insight caches;
2. the authoritative row: the semantic row (its embedding is in the same row, so it goes with it),
   or the brain edge **including its superseded predecessors for the same claim** — a forgotten
   fact must not survive as history;
3. matching `memory.md` lines — shown in the confirmation first, since this is text matching;
4. the gateway copy: `remotePending` with a queued forget request, and the receipt says so;
5. conversation transcripts are **not** memory. The result says: "It's still in the conversation
   where you said it. Delete that conversation to remove it there," with a link.
Success is reported only after a re-read confirms the local row is gone (DX rule 6).

**Correct.** Semantic: upsert the same key with the new value, re-embed, `origin = toldMe`.
Brain: the wrong edge is **deleted** (not superseded — it was never true) and the corrected edge
written with `origin = toldMe`; a correction must never leave the wrong fact readable as history.
`memory.md`: replace the line.

**Voice.** A native tool `my_memory` (`list`, `about`, `forget`, `correct`):
- "What do you know about me?" → counts per group and the three most recent facts in one or two
  sentences, then "The full list is in Memory on your phone." Never reads Health facts aloud unless
  asked about health directly.
- Forget and Correct must resolve **exactly one** fact; two or more candidates → "I found two; I've
  put them on your phone" (a notification opens the screen filtered). Forget goes through
  `HighImpactToolPolicy` `.confirm(summary:)` ("Forget 'your sister lives in Wellington'?").
- Glasses only speak; the list, detail and bulk actions live on the phone.

**Screen.** Settings → Intelligence → **Memory** (and from the everyday surface): search field,
groups, fact rows (text, source chip, date), swipe Forget, tap for detail with Correct. The empty
state teaches "Say 'remember that…'". Strings localised; no plan letters in copy. Under HIPAA mode
the screen sits behind the existing app lock like other clinical surfaces.

## Phases (one PR each)

**P0 — Contracts and the erasure fix (pure).** `MemoryFact`, `MemoryFactGrouper`, source protocol,
repository merge, provenance enum, `memories` migration, the persona-namespace erasure fix.
Tests: `MemoryFactGrouperTests` (every topic and brain kind lands in one group),
`MemoryFactRepositoryTests` (stable merge, a locked source shows status and no rows),
`SemanticMemoryProvenanceMigrationTests` (legacy rows → `legacyUnknown`),
`SubjectErasureTests.testGlobalFactErasedWhilePersonaActive` (fails before the fix).

**P1 — Forget and Correct everywhere.** `MemoryFactForgetter`, correction paths per store, brain
edge delete-with-history. Tests: `MemoryFactForgetterTests` (each store; receipt truthfulness;
gateway `remotePending`; transcript note), `BrainFactCorrectionTests` (wrong edge unreadable after
correct), FK deletion cases promoted to required.

**P2 — Memory screen.** Views, search, detail, swipe actions, VoiceOver order (origin before
actions), Dynamic Type. Tests: presentation-model tests; UI checks on device.

**P3 — Voice.** `my_memory` tool, disambiguation hand-off notification, confirmation.
Tests: `MyMemoryToolTests` (one match, many matches, none; Health not read unprompted;
forget requires confirmation).

## Risks

- **Text-matched prose.** `memory.md` lines can mention a fact in passing; the confirmation shows
  the lines before removal.
- **Gateway copies.** There is no delete on the bridge; the honest receipt is the mitigation until
  the gateway grows one.
- **Model re-learns.** A forgotten fact can be re-inferred from a later conversation. P1 keeps a
  content-free digest tombstone per forgotten fact (like `ToolDefinitionDigestStore`) so inferred
  writes of the same fact are dropped; told-me writes still win.

## Decisions for Greig

1. Confirm GG as DX's first cut (DX keeps conversation search and export). *Recommended.*
2. Tombstones to stop re-inference of forgotten facts — yes (recommended) or no.
3. Should forgetting a fact offer to delete the originating conversation in the same step?
   *Recommend offer, never automatic.*
4. Diary observations (inferred) in the list: shown under Other with an "inferred" badge
   (recommended) or hidden.
5. Voice summary length: counts + three recent facts (recommended).

## Implementation notes (2026-10-01)

Decisions taken (Greig: the plan's recommendations): GG is DX's first cut; tombstones yes; forgetting
*offers* to delete the originating conversation, never automatically; inferred diary observations
under Other with an "inferred" badge; voice summary = counts + three recent facts.

Where the code differed from this plan:

- **The erasure bug was wider than suspected.** `eraseSemanticMemory` scanned only the shared
  cache, so under a persona the shared row survived (as suspected) *and* no persona's own facts were
  ever reached, whichever persona was active. Both are fixed — the walk now searches every namespace
  and deletes per namespace — with `SubjectErasureTests.testGlobalFactErasedWhilePersonaActive` and
  `testPersonaScopedFactsAreErasedWhicheverPersonaIsActive` written first and seen failing.
- **Confirmation is in the tool, not `HighImpactToolPolicy`.** That floor only runs with agent mode
  off and sees only the model's arguments; the confirmation has to name the *resolved* fact. The
  tool resolves exactly one fact, then asks through `ToolConfirmationCoordinator` in both modes, and
  fails closed without one.
- **A fact forget is not written to the erasure ledger.** A ledger replay would delete the fact
  again after the wearer re-told it. The tombstone is what keeps it from returning, and it yields to
  the wearer's own word. `ErasureSubject.memoryFact` carries the confirmed note lines and the gateway
  key; most stores answer "not held here", and the transcript is reported unsupported with the
  reason, never claimed erased.
- **Provenance of reply tags.** The model emits the same `[REMEMBER…]` tag whether asked or not, so
  the utterance it answered decides: an explicit request ("remember…", "don't forget…",
  "actually, …") is `toldMe`; everything else, including the memory review and background agent
  tasks, is `inferred`. Brain edges gained an `origin` column outside the versioned migration (no
  backfill; NULL reads as `legacyUnknown`), and every brain write path now names its origin.
- **Places** come from object memory and a new `SavedLocationStore` over the existing
  `saved_locations` preference; saved places are not in the subject walk, so the forgetter removes
  them itself and adds the receipt.
- **The voice tool reads no wider than recall.** Another persona's facts, and the assistant's notes
  outside agent mode, are left out of what `my_memory` tells the model; the phone screen shows all.
- **Entry points:** Settings → AI & Personality (beside the User Memory switch) and the features
  list beside Insights. A My Day entry was left for a design call.
- **FK:** unbuilt, so there were no benchmark deletion cases to promote; `MemoryFactForgetterTests`
  checks each store's deletion and re-reads from disk instead.
- **FJ hook:** FJ is unbuilt, so there is no live snapshot to drop yet; the gateway-echo cache is the
  one in-memory projection, and it is purged on forget and filtered on every gateway sync.

## Out of scope

Conversation search and export (DX), HUD browsing, cloud sync of memory, importing memories, and
face or voice enrolments (their own screens already manage them).
