# Plan BT — Reading Companion

**Status: ✅ All phases shipped (P1–P4, 2026-07-16) — session core, live mode, Q&A wiring,
review remediation, stats/HUD surface, reference-copy alignment; headless throughout. Device
smoke still owed and remains the real gate (OCR quality, thresholds, battery — plus the e-reader
glare pass).** A continuous *reading session* vertical: the glasses
read along with a physical book or e-reader, answer questions grounded in **what the
reader has actually seen**, and turn each session into retention artifacts (recap, study
deck) and reading stats. Every primitive already exists in this codebase — OCR (Plan A),
`FrameGate` keyframes (AT), Study Mode (deck/flashcards/quiz), Brain ingestion, the live
voice loop; the plan is the session-state layer that stitches them. Market signal: this
exact vertical is appearing as standalone products and as community teleprompter hacks,
i.e. demand is validated; OpenGlasses ships it as a mode, not a separate app.

**Design principle — spoiler safety by construction:** the assistant's grounding corpus
is *only the pages captured this-and-prior sessions of this book*. Questions are answered
from the read-so-far store, never from model world-knowledge about the book (the prompt
says so explicitly, and the context builder physically cannot include unread text).

## P1 / PR1 — Session core (pure, headless) — ✅ shipped

**As-built notes:**
- `PageTurnDetector` reads one `FrameGate` signal two ways rather than adding a second
  comparison: a **send** is the change (candidate opens, clock restarts), a **drop** is the
  stillness. One threshold for both halves, so no frame can be neither. It runs its own gate
  (`hammingThreshold: 3`, no heartbeat, **adaptive off** — the adaptive path widens the drop
  window in static scenes, and a book on a table is the most static scene there is, so it would
  have swallowed the page turns). Heartbeat sends are ignored defensively in case a caller
  injects a gate that has one.
- `ReadingSessionStore` dedups on **two** signals, not just the planned dHash: the hash catches a
  re-look whose OCR came out differently, the normalised text catches a re-look from a new angle
  whose hash therefore drifted. Text matching needs ≥40 chars, else "OCR found nothing" would
  read as "same page". Hash distance is tight (2 of 64) on purpose — a missed duplicate just
  repeats a page, a false one silently drops a page the reader did read.
- `pageIndex` is **book-scoped**, so page numbers run across sessions (Tuesday continues Monday).
  It's capture order, not the printed page number, which we have no way to know.
- `ReadingContextBuilder` returns `nil` rather than a rule with no pages under it — a spoiler rule
  with no evidence invites exactly the world-knowledge answer it's there to prevent. Verbatim
  pages are capped at ⅔ of the budget so a long current page can't starve the condensed history;
  the current page always ships, truncated if that's the only way. Dropped pages are declared in
  the block, never silently omitted.
- Blank-OCR pages stay in the store (a page really was turned — the pace stats want it) but are
  skipped by the builder; the resulting gap in numbering is the honest record of the OCR miss.
- Thresholds are init parameters, not `Config` yet — P1 has no live caller to read `Config` from.
  P2 wires them; the P3 device pass stays data-only as planned.


- `PageTurnDetector` (pure): consumes the existing `FrameGate` signal (`SendReason
  .distinct` keyframes over dHash, `Vision/FrameGate.swift`) plus a stability window — a
  page turn is a large visual change followed by ~1s of stillness; motion blur and hand
  occlusion frames are rejected by the stability check, not sent to OCR. Fixture-image
  tests (page A → blur → page B).
- `ReadingSessionStore`: one session = book id (user-named or cover-shot), ordered page
  captures (`pageIndex, text, capturedAt, dHash`), dedup by hash (looking back at an
  already-read page must not duplicate), stats derived not stored (pages/session,
  minutes, pace, session count per book). JSON file persistence, injectable directory
  (house test pattern).
- `ReadingContextBuilder` (pure): builds the turn context from the store — recency-window
  of full page text + summaries of older pages (reuse the compression pattern from
  conversation history), hard-capped for the local-model budget; prompt block states the
  spoiler rule.
- Tests: detector state machine, store dedup/ordering/stats, context budget + windowing,
  spoiler rule presence.

## P2 / PR2 — Live session mode + Q&A wiring — ✅ shipped

**As-built notes:**
- **No `.reading` classifier section — the plan's one wrong call.** A question mid-book is "who is
  she?" or "why did he do that?", which matches no keyword list, so a keyword-gated section would
  miss the primary use case. The codebase had already hit this exact wall with playbooks and
  answered it (`OpenGlassesApp.swift`: *"the classifier never sets `.playbook` (mid-playbook
  utterances — 'done', 'next' — match no keyword list), and `playbookContext()` already returns nil
  when no playbook is active"*). The live session is the signal; P1's builder already returns nil
  with no pages. So `ReadingCompanionService.promptContext()` follows the house
  `promptContext()` shape and is injected unconditionally in `buildSystemPrompt`, next to the
  field-assist vault and active-project blocks. Zero classifier changes.
- **Injected in `buildSystemPrompt`, not threaded as a parameter.** That function is on *every*
  path (the lean on-device prompt calls it), so one line covers local, cloud and cloud-agent. The
  threaded-parameter shape the plan implied would have inherited two live gaps where
  `weatherContext` is silently dropped — `sendMessage`'s on-device branch and `sendViaLocalAgent`'s
  cloud-agent branch. Those gaps are pre-existing and left alone here; worth a follow-up.
- **Presence rides `CaptionPresenceGate`, not `LoopThrottle`.** Reading is a continuous
  user-started stream, and the gate's own doc already describes this reader exactly: *"a user who
  explicitly turned captions on may be silently reading them (idle by voice, but engaged), so
  presence must not pause on mere idle."* A motionless, silent reader is `.idle`; only `.away`
  (disconnected/backgrounded, so no frames anyway) suspends. A tick multiplier would have throttled
  the reader for reading.
- **The brain gets the activity, never the prose.** The plan said "session content feeds
  `BrainStore.ingest`", but the brain is a graph of the reader's *real* life ("who works at Acme",
  "when did I last see Alice") and `BrainRelationExtractor` is pattern-based with no way to tell a
  novel's characters from real people — ingesting pages would file Bilbo alongside their
  colleagues, silently, and surface him answering a real question later. Only
  `"Read N page(s) of <book>."` is ingested. The pages stay in `ReadingSessionStore`, which is
  where they belong.
- **Unreadable captures are counted, not stored** — superseding P1's "blank pages stay in the
  store" note. A settled view OCR can't read is as likely a wall the reader glanced at as a
  glare-blown page; filing it inflates their page count and wrecks the pace stats, and it grounds
  nothing either way. `unreadableCaptures` is the counter to watch on the P3 device pass. The
  builder still skips blanks defensively.
- One LLM call yields both artifacts: the deck's `summary.overview` + `keyPoints` *is* the spoken
  recap. `StudyService.makeDeck` gained an optional `systemPrompt:` so reading can scope the model
  to the sitting's pages — a model that recognises the book will otherwise quiz the reader on
  chapters they haven't reached. Recap falls back to a model-free `ReadingRecapBuilder` line when
  generation fails, so ending a session offline still works.
- Recap saves through `ContextualNoteStore` (typed API + tags), which the BQ `.note` adapter
  already indexes — rather than the `saved_notes` key, where a "Reading:" note would have been
  indexed by nothing (that adapter filters on the meeting-summary title prefix).
- `where_was_i` works with no live session and needs no model, so picking a book back up answers
  instantly and offline.


- `ReadingCompanionService`: session lifecycle (start/pause/end via voice or UI), frames
  from the existing `CameraService.framePublisher` → detector → OCR (the Plan A
  `ReadingAccessibilityTool` Vision path) → store. Presence-aware (Plan W throttle) and
  battery-conscious: between page turns the camera idles at the gate's heartbeat rate.
- Voice Q&A: a `.reading` classifier section injects the `ReadingContextBuilder` block
  into the turn (same pattern as the BQ-era weather pre-fetch — hand the model data, don't
  ask it to act); works with local and cloud models.
- "Where was I?" — session-resume recap spoken on session start (last page summary +
  position).
- End-of-session: recap spoken + saved as a note; **study deck generated from session
  pages** via the existing `StudyStore.saveDeck` (flashcards/quiz over what was read —
  not the whole book).
- Session content feeds `BrainStore.ingest` (native-first, per house rule) and surfaces
  in the BQ Spotlight index as a new content type (default on; text is the reader's own
  captured pages).

## P2.1 — Review remediation (2026-07-16) — ✅ shipped

A multi-angle adversarial review of P1+P2 confirmed ten findings; all fixed in one PR:
- **Gemini Live got the reading context** — the tool was declared there but the corpus/spoiler
  rule never reached its instruction, so Live-mode book questions were answered from world
  knowledge. Injected in `buildSystemInstruction` (refreshes on connect/reconnect; the rule is
  present from session start). OpenAI Realtime declares no tools, so it was never exposed.
- **`end()` recap is deterministic and immediate** — it awaited LLM deck generation *after*
  tearing down state, inside the router's 30s tool timeout; a slow model ate the recap and a
  retry answered "no session running". Deck now builds in a background task
  (`deckGenerationTask`); the spoken recap no longer carries the deck overview.
- **HIPAA position** — `reading_session` added to `hipaaDisabledTools` + a service-level start
  guard (a "book" can be a patient chart); the store applies complete file protection + backup
  exclusion under `hipaaMode` for data captured before the mode was enabled.
- **Camera lifecycle** — `start()` surfaces `startStreaming` failures instead of announcing
  "I'll follow along" over a dead camera; `end()` stops a stream the session started (unless
  another consumer is live — `otherStreamConsumersActive` seam); mid-session stream death now
  triggers one restart attempt and, failing that, `streamInterrupted` surfaces in status/end;
  reading added to `LivePreviewView`'s keep-streaming list.
- **Store integrity** — hash-only dedup restricted to the last 8 pages (a 9×8-dhash collision
  between dense prose pages silently dropped a real page; text corroboration still corpus-wide),
  `dedupDropCount` diagnostic added; `pageIndex` is max+1 (count collided after deleting a
  non-terminal session) with a `capturedAt` sort tiebreaker; page appends coalesce into a 60s
  checkpoint (lifecycle events persist immediately) instead of rewriting the whole corpus per
  page turn on the main actor.
- **Book identity** — spoken titles resolve against the shelf (exact slug, then leading-article
  stripped) so "Hobbit" continues "The Hobbit" instead of forking a second corpus; deliberately
  no substring matching ("Dune" must not collapse into "Dune Messiah").
- **Smaller**: Spotlight donates a 500-char excerpt (was the full corpus, re-hashed every
  foreground); `pagesThisSession` is derived, not stored; pace line grammar/rounding
  ("1 minute", seconds from the true pace); context truncation no longer degenerates to a bare
  "[pN]…" on an unbroken token; explicit `status` tool case.

## P3 / PR3 — Polish + HUD — ✅ shipped (with P4, one PR)

**As-built notes:**
- Stats surface: `ReadingStatsView` (Settings → Reading, the `DeckListView` precedent) — per-book
  pages/sittings/time/pace/streak/last-read, swipe-to-delete books, per-sitting history, and the
  P4 attach-a-copy controls. `ReadingStreaks.current` is pure (calendar + today injected); a
  streak survives until a full day is missed — reading yesterday but not yet today still counts.
- HUD: `ReadingHUDCard.notification` (pure) → `GlassesDisplayService.showNotification` on session
  start and "where was I?". Transient by design: it flashes over whatever card is held (Now/Next,
  launcher) and the display restores itself, so reading never manages display state. Safe no-op
  without display hardware. A held interactive `HUDScreen` was rejected — it would suppress other
  ambient content until manually ended.
- Detector knobs are Config-backed (`readingHammingThreshold`/`readingStabilityWindowSeconds`/
  `readingMinimumFrameInterval`, defaults 3 / 1.0s / 0.5s) via a `makeDetector` seam set in
  `configure(...)` — the device pass retunes with `defaults write`, no rebuild; tests keep fixed
  defaults because they never call configure. Code-only knobs, the `frameDedup*` posture.
- The e-reader glare/contrast pass itself remains device-gated and owed — the knobs are its
  prerequisite, not its substitute.

## P4 / PR4 — Reference copy alignment — ✅ shipped (with P3, one PR)

**As-built notes:**
- `BookAlignmentIndex`: word-shingle voting (3-gram, non-distinctive shingles > 8 occurrences
  dropped from the index), densest-cluster with the *modal* start inside the winning window — the
  window's lowest vote could sit up to `clusterTolerance` early when a repeated phrase precedes
  the true site. Case/punctuation-insensitive matching; slices return the book's own text.
- Reference = a `BookReference` pointer into the Plan O `DocumentStore` (`fullText(documentId:)`,
  the teleprompter precedent) persisted in its own `references.json` — the P1 sessions schema is
  untouched and no text is duplicated. If the user forgets the document, alignment quietly stops.
- `PageCapture` gains optional `alignedStart/alignedWordCount/alignedConfidence`; raw OCR is
  always kept (dedup compares raw; alignment stays re-runnable). Old data decodes unchanged.
- The index builds off-main at session start (`alignmentPreparation`); pages captured before it's
  ready stay unaligned — raw OCR grounding, exactly as without a reference. Attach takes effect
  next session.
- Progress derives from stored alignments (`alignedFrontier` / `wordCount` persisted at attach),
  so "where was I?" says "about 34% through" offline, without loading the book.
- Attach supports **PDF** (PDFKit; no OCR, so scanned PDFs yield nothing), **EPUB**, and UTF-8
  text, via file import or picking an existing DocumentStore document. EPUB is dependency-free:
  `BookFileExtractor` owns a minimal read-only ZIP reader (`ZipArchiveReader` — central-directory
  walk, stored + deflate via the system Compression framework; no ZIP64/encryption/CRC), walks
  `container.xml` → OPF manifest+spine for reading order (archive-order HTML fallback when the
  manifest is malformed), and strips XHTML to text (`HTMLTextStripper`). Fixtures in tests are
  real ZIP bytes built by a stored-entry writer, plus a Compression-framework deflate round-trip.
- Spoiler safety verified structurally in tests: canonical text one word past the camera-proven
  frontier does not appear in the block.
- **Small-hole interpolation:** one bounded inference exists, added deliberately: a hole smaller
  than ~800 words flanked by aligned captures from the *same sitting* counts as covered — the
  camera witnessed the sitting's continuity and merely blinked on a page (blur, empty OCR, a
  false dedup drop). Holes between sittings never interpolate, however small (no continuity
  evidence across time — that's the assertion's job), and nothing can exceed the frontier since
  both flanks are camera-proven. Covered regions (asserted + captured + interpolated,
  `coveredRanges`) are what retrieval searches.
- **Catch-up ("I've read up to here"):** beyond that one bounded case, the corpus is
  *witnessed-or-asserted*, never inferred.
  A reader who starts the app mid-book (or reads offline between sittings — captures at chapters
  1–3, a gap at 4–9, captures at 10+) can assert the earlier stretch as read: `assertedReadUpTo`
  is a single monotonic high-water mark on `BookReference`, **clamped to the camera frontier** so
  it only ever fills in behind what the camera proved, never ahead. Unasserted holes behind the
  frontier are detected (`unconfirmedGap`) and surfaced to the model as an instruction to *ask*
  ("did you read that part away from the glasses?") rather than wrongly answer "that hasn't come
  up yet" — confirmation is one voice line (`caught_up` tool action, or the button in the stats
  view). Asserted regions are grounded by retrieval, not inclusion: `BookAlignmentIndex.retrieve`
  (deterministic keyword-window scoring, position-clamped to the mark, capped at a quarter of the
  block budget) pulls the passages most relevant to the current turn, which `buildSystemPrompt`
  now passes through. Auto-backfill from position alone was rejected: the frontier proves where
  the reader *is*, not that they read linearly — a skipped middle must stay unanswerable until
  the reader says otherwise.

### Original plan (for reference, planned 2026-07-16)

The user can supply their own copy of the book (PDF/EPUB, imported through the Plan O
`DocumentStore` path — no second import pipeline) and the companion aligns each camera
capture to its position in that canonical text. This vertical is appearing elsewhere with
exactly this shape, and it earns its place on three merits:

- **It attacks THE named risk from the cheap side.** *Locating* a noisy capture in the
  canonical text needs only a few distinctive word sequences to survive the OCR;
  *grounding* on that capture needs the whole page to survive. Once located, the corpus
  entry is upgraded to the clean file text — bad OCR stops poisoning Q&A, recaps and
  decks, and only has to be good enough to say where the reader is.
- **True position.** `pageIndex` is capture order — a proxy invented because the camera
  can't know the printed page. Alignment gives real pages/chapters, "you're 34% through",
  and a sharper "where was I".
- **Passive detection gets margin.** The explicit-capture escape hatch becomes much less
  likely to be needed when a half-readable capture still matches.

**Spoiler safety stays structural — the load-bearing rule:** the camera remains the *sole
authority on the reading frontier*. The file never expands what the model may see; it only
substitutes cleaner text for pages the camera already proved were read. The context builder
clips file text at the furthest camera-matched position. No match → the raw capture stays,
exactly as today.

Shape (house style):
- `BookAlignment` (pure): normalized OCR text + chunked canonical text → best-match
  position with a confidence score. Shingle/n-gram overlap, deterministic, no LLM, no
  clock; fixture-tested headless (clean page, noisy page, ambiguous page, no-match).
- `ReadingSessionStore` gains an optional per-book reference (document id + per-page
  alignment: matched range, confidence); captures keep their raw OCR so alignment is
  re-runnable and reversible.
- `ReadingContextBuilder` prefers aligned canonical text over raw OCR per page, hard-clipped
  at the frontier; `ReadingRecapBuilder`/stats surface true position when a reference exists.
- Edge (thin): "attach a copy" flow reusing the existing document import UI.

Boundaries: upload-only (the user's own copy), processed on-device, **never fetch book text
from the web**; fully optional — no file means today's behavior unchanged; rendering or
reading the book *from the file* stays out of scope (below). Sequencing: planned now,
urgency decided by the P3 device pass — if raw OCR proves fine, P4 is a position/progress
feature; if it's as noisy as feared, P4 is the rescue and jumps the queue.

## Explicitly out of scope
- Reading the book *from a file* — no e-reader surface. A user-supplied copy is a P4
  alignment reference for camera-grounded reading, never a display or TTS source.
- Full-book knowledge (summaries of unread chapters, reviews) — violates the spoiler rule.
  P4 does not soften this: file text past the camera frontier never enters context.
- Text-to-speech of the page (Plan A's reading tool already does read-aloud on demand).

## Risks / escape hatches
- OCR quality on curved book pages in ambient light is THE risk — P1/P2 ship regardless
  (they're store/wiring); if page OCR is too noisy on device, the fallback posture is
  explicit capture ("read this page") instead of passive page-turn detection, which
  reuses everything except the detector trigger.
- Long-session battery: gate heartbeat + presence throttle bound it; measure in the P3
  device pass.

## Verification
Headless: detector fixtures, store round-trips, context budget, deck generation from
fixture pages + full suite + Release green. Device: one 20-minute physical-book session
(page turns detected, Q&A grounded, recap + deck correct) and one e-reader session
(glare/contrast), battery + thermal noted.

**As shipped (P1 + P2):** 77 headless tests — detector state machine + fixture sequence
(page → smear → hand → page), store dedup/ordering/stats/round-trip, context budget +
windowing + spoiler rule, recap/deck-source/deck-prompt, the full frame → OCR → store
pipeline through injected seams, tool actions, and the Spotlight adapter. Release green.

**Device smoke still owed, and it is the real gate** — P2 has no verified runtime surface.
Everything above proves the wiring given *fixture* frames; none of it proves Vision can
read a curved paperback in lamplight, which the plan itself names as THE risk. Specifically
unproven until a device runs it: OCR quality on real pages, whether `hammingThreshold: 3`
and the 1s stability window match real page turns (watch `unreadableCaptures` — a high
count against a real book means tuning, not a quiet reader), and long-session battery/thermals.
