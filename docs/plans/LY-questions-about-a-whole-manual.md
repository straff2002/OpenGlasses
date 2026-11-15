# Plan LY — Questions About a Whole Manual (read every section, and every note cites its page)

**Status:** 📝 Drafted 2026-11-15 — nothing implemented.
**Track:** Manuals, for Field Assist and My Manuals alike. Direct mode first; Gemini Live and OpenAI
Realtime hand the work to the phone.
**Builds on:**
- `VaultRetriever`: its `Passage.citation`, attached by the app and never written by the model, and
  `passageLine`, which numbers passages `[1]`, `[2]` with a `Source:` line under each.
- `ManualPassageLimit` (four passages for prose, six for clause-numbered books and table rows) and
  `VaultRetriever.boundedOutcome` (the 12,000-character budget and its omitted-passages notice).
- `DocumentStore`'s reading-order access to a document's chunks (`pageTexts(documentId:)`,
  `reconstructedText(documentId:overlapCharacters:)`).
- `VaultOnlyPolicy`, `FieldToolProfile`, `ModelPricing`, `SpendCapPolicy`, `AIFeature`.

**Sits beside:** Plan [KK](KK-conversation-timeline.md)'s `TimelineSummaryPass` and Plan
[LQ](LQ-what-we-talked-about.md)'s conversation notes, which also write notes in pieces and merge
them; `MeetingSummaryTool`. Nothing they decided changes here (§10).

---

## Trigger

Some questions are about all of a document, not the part of it that sounds most like the question:
- *"List every caution in this manual."*
- *"Every fault code that mentions the pressure switch."*
- *"What does this manual say about the condensate pump, everywhere?"*
- *"Which of my manuals cover R-454B?"*

Retrieval hands the model four passages (six for a code book or a table), the best by the ranking.
For *"list every caution"* the model sees four of perhaps thirty and answers from them. The answer
sounds complete. Nothing in it says three quarters of the cautions weren't looked at.
`boundedOutcome` already owns up to passages the character budget dropped; nothing owns up to
passages that were never retrieved, because retrieval was never meant to read everything.

## Outcome

- **Asked for.** *"Go through the whole manual and list every caution"* gets, on a long manual,
  *"That's a long read: about 18 steps and 3 minutes. Shall I start?"*. On yes, the phone shows
  progress (*"Reading sections 12–14 of 40: Venting"*), and the glasses hear one line halfway and one at
  the end.
- **The answer.** A list, each point followed by its pages, opened by a tap. On the glasses a short
  summary: *"I found 23 cautions in 14 sections. The list is on your phone."*
- **Every point is traceable.** Each one comes from a note that cited passages the model was actually
  shown. A point that cited nothing real is dropped, and the answer says how many were.
- **What wasn't read is said.** When a limit is reached, or a step fails, the answer ends with
  *"I read pages 1–212 of 340. Pages 213–340 weren't read."*, never silence.
- **Offered, not imposed.** *"What cautions does the manual give about venting?"* is answered from
  retrieval as today. If it looks like an all-of question, the answer ends with *"That's from four
  passages. Want me to go through the whole manual?"*.
- **A literal term across the library.** *"Which of my manuals mention R-454B?"* is answered by
  checking every passage of every manual for the term, with no model calls: *"Three of your seven
  manuals mention R-454B: …"*, each with its pages.
- **Cancel** (*"stop"*, or **Stop** on the card) ends every call at once and keeps what was finished,
  marked as partial.

## What exists, and what doesn't

**Exists (verified against `main` on 2026-11-15):**
- `VaultRetriever` (`OpenGlasses/Sources/Services/Vault/VaultRetriever.swift`): `Passage.citation` is
  built by the app from title, page and figure; `passageLine(_:_:)` renders `[n] text` then
  `Source: citation`; `promptBlock` and `toolResult` wrap them; `boundedOutcome(_:characterLimit:)`
  keeps whole passages to 12,000 characters and adds a notice for the ones it dropped;
  `isContentsList(_:)` recognises a table of contents.
- `ManualPassageLimit` (`Vault/ManualPassageLimit.swift`): 4 for prose, 6 for clause-numbered
  documents, table rows and CJK or Arabic-script documents.
- `DocumentStore` (`Services/RAG/DocumentStore.swift`) reads a document's chunks in `chunk_index`
  order without their vectors (`pageTexts(documentId:)`), and `reconstructedText` drops the overlap
  between chunks (`DocumentChunker`'s `overlapChars`). Row passages are filtered out of both
  (`notTableRow`), so a table is read once, as its page.
- `ManualLookupTool` (`Services/NativeTools/ManualLookupTool.swift`) searches the active vault, or in a
  personal library the manuals selected for the chat.
- `VaultOnlyPolicy` (`Services/FieldAssist/VaultOnlyPolicy.swift`): a sealed job runs only its kept
  tools; a guard test fails on any tool in neither list. `FieldToolProfile` lists the field tools.
- `KeptChains` and `ChainRunner` run rule chains step by step. Not used here: a chain is a few lookups
  in a fixed order, not a reading.
- `ModelPricing.estimate` and `SpendCapPolicy` / `SpendCapConfirmation` (`Services/Usage/`).
- `TimelineSummaryPass` (`Services/Memory/Timeline/TimelineSummaryPass.swift`) writes model notes over
  chunks of at most `TimelineCoverage.maximumChunkTokens` (8,000) and merges them; its notes don't
  cite the messages they came from. `TimelineRenderer.estimatedTokens` is the shared estimate.
- `MeetingSummaryTool` builds a meeting summary from ambient captions by keyword rules, with no model.
- `LiveInjectionEnvelope` (`Services/Live/LiveInjection.swift`) puts a note into a live session.

**Doesn't exist:** reading a whole document; notes checked against their sources; a merge with
bookkeeping; a notice of what wasn't read; a cost estimate before a long piece of model work; an
all-of question detector.

## Design

### 1 · When it runs (`WholeReadTrigger`, pure)

- **Asked for:** the wearer says to read the whole thing (*"go through the whole manual"*, *"read all
  of it"*, *"check every page"*), or taps **Read the whole manual** under an answer. The model can call
  the tool `manual_read_all` with the question and the manuals; the tool description says to call it
  only when the wearer asks for the whole manual, or accepts the offer.
- **Offered:** a pure detector (`AllOfQuestion.detect`) marks a turn whose words ask for all of
  something: *every, all the, each, list all, everywhere, any mention, which manuals, how many times*,
  with a noun after them. When retrieval answers such a turn, the reply ends with the offer. It never
  starts a read by itself (decision 1).
- **The lexical fast path.** When the thing asked about is a literal term (`CodeTokenizer.isCodeLike`:
  a refrigerant, a fault code, a part number, a model) and the question only asks *where* or *which*,
  every passage of every chosen manual is checked for it as a whole token, in reading order. No model
  call, no estimate needed. That counts as reading everything, because everything was checked. The
  model is used only if the wearer then asks what those passages say.

### 2 · What is read, in what order (`ManualSections`, pure)

- The chosen manuals: the one the turn is about (the job's unit manual, or the one named), else the
  manuals selected for the chat, else, for a library question, all of them (decision 2).
- Each manual's chunks in `chunk_index` order, overlap removed, contents-list chunks skipped,
  table-row passages skipped (the table is read as part of its page), a `diagram` chunk read as its
  caption and words.
- Each chunk becomes a numbered passage, counted across the whole selection in reading order, so each
  manual is one run of numbers. The number maps to the passage's `citation`.
- A **section** is a run of passages from one manual under the same heading (`Passage.section`).

### 3 · Groups (`ReadingGroups.pack`, pure)

Sections are packed in reading order into groups of at most `groupTokens` of passage text, estimated
with `TimelineRenderer.estimatedTokens`. A section larger than a group is split between passages;
a passage is never split. `groupTokens` is the smaller of 6,000 and a quarter of the chosen model's
request context. Each group is one model call.

### 4 · Notes and the check (`NoteParser`, pure)

Each group's call is given the question and its passages, numbered as in §2, and asked for one note
per line, each ending with the numbers of the passages it comes from (`[12]`, `[12][14]` or `[12–14]`),
or a single `NONE`.

The parser:
- reads `[n]`, `[n][m]` and ranges up to 20 wide (a wider range isn't a citation and is ignored);
- **removes every number that isn't one of this group's passages**, and **drops a note left with no
  number**, counting both (`foreignNumbers`, `uncitedNotes`);
- drops the last line of a reply that was cut off at its token limit, because it stopped mid-way;
- keeps the group each note came from.

So every note that survives traces to a passage the model was shown, and the app, not the model,
knows what that passage's page is.

### 5 · Merging (`NoteMerge`, pure bookkeeping)

- When all the notes fit the answer's budget (`notesTokens`, 6,000 by default), they go to the answer
  as they are.
- Otherwise they are merged in batches that fit one call: the model combines duplicates and drops
  notes that don't help the question. A merged note must cite only numbers carried by the notes in its
  batch, checked by the same parser, and combining two notes keeps every number of both.
- At most three merge rounds. Notes that still don't fit are cut fairly: taken in turns from each
  group (every group's first note, then every group's second), so every part of the manual keeps a
  voice. The answer says how many notes were left out.

### 6 · The answer, and its citations

The last call gets the question and the surviving notes, each with its numbers, and writes the answer
citing `[n]`. The app then:
- removes any number in the answer that isn't in the notes, and counts it;
- renders each cited number as its passage's citation (manual title, page, figure), the way
  `passageLine` does today, so a page in the answer is always one the app attached;
- adds the not-read notice (§7) and the dropped-notes count.

On the phone the answer is a list with tappable pages (the citation is a door, as Plan
[EK](EK-manual-structure-and-figures.md) made it). Spoken, it's a summary of one or two sentences
and *"the list is on your phone"*. A list of five points or fewer is read out in full.

### 7 · Limits, failures, cancelling (`WholeReadLimits`, `NotReadNotice`, pure)

- **Limits per question:** at most 400 sections, 250,000 tokens of passages, and 60 model calls.
  Reaching one stops the reading at that point of the reading order.
- **A failed call** is retried once. If it fails again its sections are recorded as not read and the
  other groups go on.
- **The notice** is built from the plan and the failures: *"I read pages 1–212 of 340. Pages 213–340
  weren't read."*, or *"Pages 88–95 couldn't be read."*, per manual. It is part of every answer that
  has one, on the phone and spoken.
- **Cancel** cancels the task group, which cancels every call in flight. What was finished is kept and
  the answer is marked partial with the notice.
- **Calls run two at a time**, so a provider's per-minute limit (`PerMinuteFit`) isn't tripped.

### 8 · Cost, shown first (`WholeReadEstimate`, pure)

From the plan: calls, tokens in (passages plus the fixed prompt per call), tokens out (the reply cap
per call), a price from `ModelPricing.estimate`, and a time from the measured median call time.
- Under 6 calls it just starts.
- At 6 or more the phone shows *"About 18 steps, roughly 3 minutes"* and the estimated cost, priced from
  the wearer's own model price table (`ModelPricingEditorView`), with **Start** and **Not now**. Spoken:
  steps and minutes, no cost.
- The spend cap applies to the whole read up front: if the estimate would cross it, `SpendCapPolicy`
  decides, as for any turn.

### 9 · Modes, models and the background

- **Direct mode** runs it as described.
- **Gemini Live and OpenAI Realtime:** the tool returns at once with *"Started reading on the phone.
  I'll tell you when it's done."* The read runs on the phone with the wearer's Direct-mode model, not
  the realtime model. When it finishes, a one-line result goes into the live session through
  `LiveInjectionEnvelope`, and the list is on the phone and in a notification.
- **Models too small for it:** the Apple on-device model, and a local model with a request context
  under 16,000 tokens, refuse with *"That needs a larger model than the one on this phone."* The
  lexical fast path still works offline.
- **A sealed vault-only job** keeps the tool (it reads only the vault), so `VaultOnlyPolicy` lists it
  as kept.
- **The phone locking.** A read the wearer started runs as a user-started continued-processing task
  (iOS 26's `BGContinuedProcessingTask`), with the system's progress, so a few minutes with the phone
  in a pocket don't kill it (decision 5). If the system ends it, what finished is kept and the notice
  says the rest wasn't read.

### 10 · The same core for long transcripts

The checked-notes core is about *a long text, read in order, with every note citing where it came
from*. A meeting is one. Today `MeetingSummaryTool` picks out decisions and action items by keywords.
A later phase (P5) can give it a model-written summary on the same core: the ambient captions cut into
numbered stretches by time, each note citing stretches, the app rendering the times (*"at 10:42"*).

KK's timeline and LQ's conversation notes stay exactly as decided. KK writes notes for the thread's
own requests, where a citation adds nothing the model uses. LQ decided the note reads the timeline and
never the whole transcript again. This plan doesn't reopen either.

## Decisions for Greig

1. **Asked for, or detected?** *Recommended:* it runs only when asked for (or the offer is accepted);
   a detected all-of question gets the offer after the normal answer. *Alternative:* start
   automatically on a detected question, which spends money and minutes on a misread turn.
2. **Which manuals by default.** *Recommended:* the manual the turn is about, else the chat's
   selected manuals, else all of them for a library question, with the estimate shown whenever more
   than one manual is read. *Alternative:* always ask which manuals, which adds a turn every time.
3. **The limits.** *Recommended:* 400 sections, 250,000 tokens of passages and 60 calls a question;
   6,000-token groups; two calls at a time; three merge rounds. Revisit after P3's measurements.
4. **Live modes.** *Recommended:* hand the read to the phone and tell the live session when it's done.
   *Alternative:* refuse in live modes, which is simpler and leaves the wearer to switch modes.
5. **Running with the phone locked.** *Recommended:* a continued-processing task for reads the
   wearer started, so it carries on in a pocket with the system's progress shown. *Alternative:* run
   only in the foreground and stop on lock, saying what wasn't read.
6. **Keeping the result.** *Recommended:* the answer stays in the conversation like any reply, and
   **Save as note** is offered; no cache of notes per question in this plan. *Alternative:* cache the
   group notes by manual and question, which rarely hits because questions differ.

## Phases

### P0 — the deterministic core (headless, fake model)

`AllOfQuestion`, `WholeReadTrigger`, `ManualSections`, `ReadingGroups`, `NoteParser`, `NoteMerge`
bookkeeping and the fair cut, `WholeReadLimits`, `NotReadNotice`, `WholeReadEstimate`, the lexical fast
path (`WholeManualScan`), and `WholeReadRunner`, which drives a `NotesModel` protocol so tests supply a
fake.

Tests:
- `AllOfQuestionTests`: a corpus of about 40 turns that should and shouldn't be all-of questions.
- `ManualSectionsTests`: reading order across two manuals, overlap removed, a contents list and row
  passages skipped, a diagram read as its caption, numbering continuous across manuals.
- `ReadingGroupsTests`: packing under the budget, a section split between passages, a passage larger
  than a group kept whole in its own group.
- `NoteParserTests`: single numbers, pairs and ranges; a number from another group removed; a note left
  uncited dropped and counted; a range wider than 20 ignored; `NONE`; the last line of a cut-off reply
  dropped.
- `NoteMergeTests`: duplicates combined with the union of numbers; a merged note citing a number not in
  its batch dropped; three rounds then the fair cut, each group keeping its first note.
- `NotReadNoticeTests`: a limit reached mid-manual, a failed group, two manuals, nothing missed (no
  notice).
- `WholeReadEstimateTests`: calls and tokens from a plan; under 6 calls no prompt.
- `WholeManualScanTests`: a code-like term found as a whole token only, across manuals, with pages.
- `WholeReadRunnerTests` with the fake model: a full run; a failure retried then recorded; cancelling
  mid-run stops every call and keeps finished notes; the answer's foreign numbers removed; citations
  rendered by the app.

### P1 — wiring (headless, plus a simulator UI test)

`manual_read_all` (classified in `VaultOnlyPolicy` and `FieldToolProfile`, titled in `ActivityTitler`),
the three prompts, the real `NotesModel` over `LLMService` for each provider, the spend cap, the offer
line after an all-of answer, the phone's progress card and result sheet, the spoken lines, Stop, and
`AIFeature.wholeManualRead`. A UI test runs a read against the fake model and checks the progress card,
the list with pages and the not-read notice.

### P2 — live modes and the background

The hand-off from Gemini Live and OpenAI Realtime, the result injected when done, the notification, the
continued-processing task.

### P3 — measurement

A local answer key of all-of questions over the manuals a developer holds (skipped when they're absent,
like the existing calibration tests; nothing from them is committed). For each question: the share of
known items found, how many notes were dropped as uncited or foreign, calls, tokens, time and cost per
provider. The limits in decision 3 are set from it.

### P4 — device pass (owed)

On the phone: a long manual read to the end; one stopped part-way; one that hits a limit; the phone
locked during a read; a live-mode hand-off; the lexical fast path offline.

### P5 — later, only if P4 goes well: meeting summaries on the same core

`MeetingSummaryTool` gains a model-written summary over numbered caption stretches, each point with its
time. HIPAA mode and the diarisation switch keep their current rules.

## Risks

- **A model that writes plausible numbers.** The parser drops every number outside the group, and the
  answer step drops every number outside the notes, so a wrong page can't reach the wearer through a
  citation. A note can still misread its passage; the page is one tap away for that reason.
- **Cost and time.** Shown before starting at 6 calls or more, capped per question, under the spend cap.
- **A detector that misfires.** It only ever offers.
- **Silent incompleteness**, the problem this plan exists for, is answered by the not-read notice on
  every answer that needs one.

## Out of scope

- Changing top-k retrieval, the evidence gate or `ManualPassageLimit`. Normal questions are unchanged.
- Reading documents that aren't manuals (web pages, the wearer's general document library).
- Summarising a whole manual unasked, or at import.
- KK's timeline and LQ's notes (§10).
