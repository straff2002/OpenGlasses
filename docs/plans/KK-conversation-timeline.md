# Plan KK — The Conversation Timeline (what was said stays in front of the model after it leaves the request)

**Status:** 🚧 P0 run and P1's deterministic core built 2026-11-03. P2, the summary pass, and P3, the
notes in the request, built 2026-11-04. P4, the device pass and the re-run, is owed.
- P0 found that one sentence telling the model to search recovers most of the gap. That sentence now ends
  the omission note whenever `brain` can be called.
- It also found the timeline closes the rest only when coverage is complete, so P2 covers the open run
  after every reply instead of waiting for 5,000 tokens, and P3 covers two turns ahead once turns are
  leaving, so the next request finds them covered.
- P3 puts the notes in every budgeted cloud request. They replace the omission note only when they
  cover everything the request left out; otherwise the note stays and says the notes are partial.
- The four owner decisions were taken on 2026-11-04 (see the end).

Drafted from a code read of main at `c567b5cb5`.

**Track:** App-wide for Direct mode on cloud models, Field Assist first: a long job is where an early
reading or decision is most likely to leave the request.
**Related:** Plan [FM](FM-conversation-context-and-field-continuity.md) (the ChatGPT request budget and its
rule that compaction never removes saved messages), Plan [GB](GB-field-test-round-3.md) P5
(`APIHistoryBudget`, `PromptLayout`, job floors), Plan [DK](DK-protected-conversation-recall-index.md)
(the recall index), Plan [FK](FK-memory-quality-and-continuity-benchmarks.md) (the benchmark this plan feeds),
Plan [FJ](FJ-live-wearer-memory-continuity.md) (Live modes, which this plan does not touch).

---

## Why

We bound every cloud request, which is right: GB P5 exists because a job's history was being re-sent and
billed in full on every tool round. But the two bounds have no summary behind them. When a message leaves the
request, the model gets a one-line note that some older messages were left out, and nothing about what they
said.

The model can look. `brain` with action `recall` searches past conversations, and `memory_search` searches
stored facts. Looking only helps when the model knows there is something to find. A decision from forty
messages ago that it no longer holds is not something it can decide to search for.

## Findings

Read from the code on 2026-11-03. How often this costs a wearer a wrong answer has **not** been measured;
that is P0.

1. **API routes drop at about 14k tokens and summarise at 80k.** `APIHistoryBudget.select` drops the oldest
   complete exchanges from the request copy down to `defaultAllowance = 14_000`. The compactors only run over
   `maxEstimatedTokens = 80_000` of in-memory history (`LLMService.swift:365`). Between the two, older
   exchanges leave with only `omissionNote`.
2. **ChatGPT routes never summarise.** They skip the compactors by design (FM), and
   `RequestContextBudget.build` drops old exchanges with the same kind of note.
3. **The LLM summariser is behind Agent Mode.** Without it, the 80k path keeps extracted signals and drops the
   rest.
4. **The summariser is weak when it does run.** Each message is cut to 500 characters, the result is capped at
   300 words, and it reads the in-memory history, where tool output sits beside what the wearer said.
5. **`compressedSummary` is half-wired.** Only the Agent Mode path writes it. `replayMessages` puts it in front
   of the *whole* thread on resume, so the model gets a summary of messages it is also getting in full.
   `ConversationStore.truncate` leaves it in place, so an edit or regenerate can keep a summary of text the
   wearer has removed.
6. **A useful split already exists.** `ConversationThread.messages` holds the wearer's words and the replies,
   not tool results, so the source this plan needs is already saved. It carries stable ids and timestamps, is
   already encrypted, and goes when the thread goes.

## Outcome

On a long conversation, the model always holds a short, dated, in-order account of everything earlier in the
same conversation, however much has left the request. Recent messages stay word for word. The saved transcript
is never changed. If an account cannot be produced, the wearer gets exactly today's behaviour and the note still
says messages are missing.

**Done means** P0's benchmark, run again on the same fixture, shows old-detail recall up, wrong and outdated
answers not up, and the extra cost per turn within the bound P0 sets.

## What this does not do

- **No conversation across threads.** Each thread and each job stays its own. Job floors keep working: a new job
  on a thread sees nothing from before its floor. Other conversations remain reachable through `brain` recall.
- **No change to the request budgets.** Allowances, the protected current turn and the exchange seams stay.
- **Not a record.** The timeline is never evidence. Readings and procedure state keep living in `FieldSession`;
  saved messages stay the transcript. Nothing is deleted or rewritten to make room.
- **Live modes and on-device models are out.** Gemini Live, OpenAI Realtime, MLX and Apple Intelligence keep
  their own paths. `Local` models cannot run backgrounded anyway.

## Design

**Where it lives.** A new optional field on `ConversationThread`, so encryption, the save guards, retention and
`deleteThread` all cover it, and an older saved thread decodes unchanged. No new store, so no new
`DataStoreRegistry` row. `compressedSummary` stops being written; an existing value still decodes and stops being
prepended once a thread has entries.

```swift
struct TimelineEntry: Codable, Equatable, Sendable {
    let id: String
    let firstMessageID: String
    let lastMessageID: String
    let startedAt: Date
    let endedAt: Date
    let tier: Tier              // .chunk or .merged
    let text: String
}
```

**What it reads.** Saved messages only, by id, in order. Tool output is left out on purpose: a result matters
here if it was said to the wearer, and then it is in a reply. This is the difference from the current summariser.

**When it runs.** After the reply is accepted, never in the turn's way, the same place `MemoryLoopService.enrich`
runs. A pass starts when the messages the request no longer carries, minus those already covered, pass about
5k estimated tokens. One pass per thread at a time. Never while the store is locked.

**Which messages have left.** The saved thread and the in-memory history have no shared ids, so this is counted
from the tail: a request that kept K user turns means the thread's last K user messages are live, and everything
before them is eligible. Replay, the injected summary and turns that never saved must each have a test. When the
count is doubtful, overlap: **a gap is the defect, and an overlap only wastes a few tokens.**

**Tiers.** Two: chunks, and merged entries when four chunks are waiting. A phone conversation is much shorter than
a month of desktop use, so a third tier earns nothing.

**What the model sees.** One block, oldest first, dated, capped at about 1,500 estimated tokens, labelled as notes.
The label drafted here (*These are notes, not a record*) made the model distrust its own recall results in P0, so
P3 reworded it (see P3's As built). It replaces the omission note when coverage is complete; when there is a gap the note
stays and says so. Entries before the job floor are never rendered, and a chunk never spans a floor. The floor is
an index into in-memory history today, so its date needs capturing where it moves.

**Acceptance.** A pure policy decides whether a summary is kept: non-empty, complete (not cut off at the token
limit), within its size bound, and plain text. Corrections keep only the corrected value ("it was 52, not 25").
A deterministic check then lists the numbers-with-units, part numbers and model or serial numbers in the chunk's
*user* messages; any the summary lost are appended word for word. A technician's figures are the one thing a
paraphrase must not lose, and this check needs no model to trust.

**Failure.** A failed or refused summary leaves the range uncovered and is retried on a later turn with backoff.
The message is never lost, because it was never touched.

**Cost.** The block sits in the volatile tail through `requestSystemParts`, the seam the note already uses, so it
is uncached and is paid on every tool round. Its size is bounded, and P0 measures it. Dropping the oldest exchange
one at a time also moves the history prefix on every turn over budget, so little of the history reaches the prompt
cache; cutting in batches would help and is decision 2.

## Safety and privacy rules

- **Destination.** A summary goes only through `medicalInferenceModel`, to the model answering this thread, and is
  counted in `UsageStore` and bound by the spend caps. No cheaper model is chosen, because that would be a new
  destination for the wearer's words.
- **HIPAA.** Off, and the note stays (decision 3).
- **Untrusted text.** The block quotes the wearer and earlier replies, so it stays labelled as notes and never reads
  as an instruction.
- **Logging.** `PrivacyLog` gets counts and sizes only. Entry text never reaches a log, a support report or
  `JobTranscriptExport`. The on-device Prompt Inspector may show it, as it shows memory today.
- **Edit and regenerate.** `truncate` drops every entry that overlaps a removed message, and the range is
  summarised again. The same fix closes finding 5 for `compressedSummary`.
- **Erasure.** A thread delete takes the entries with it. A *person* erasure leaves thread text in place today
  (`eraseConversations` says so in its receipt) and removes matching turns from the recall index. The timeline would
  go on re-sending that name on every turn, so it counts as a derived index: entries that match are dropped first,
  before their source, under the coordinator's existing rule. `SubjectErasureTests` extended to prove it.
- **Fixtures.** Invented jobs only, no manual figures and no tester content.

## Phases

All in one PR apart from the device pass, as usual.

### P0 — Measure the gap first

Headless, plus a live probe on the two keys the owner tests with (ChatGPT, Claude API).

- An invented long job and a long everyday conversation, about 150 messages each, with 40 planted details:
  readings, part numbers, a moved appointment, which option won. Some have lookalike wrong values or a later
  correction.
- Questions that do not hint at memory ("what do I order?"), scored strictly: one exact answer. A wrong value, an
  outdated value and "X or Y" all count as misses; "I don't have that" is a miss counted separately, because it is
  the safe failure. Eight recent details act as controls.
- Baseline on current main, with tool calls logged so `brain` recall gets its due.
- **If baseline already recalls well through `brain` recall, stop here** and take the smaller fix: tell the model
  to search when the omission note appears. This is a real possible outcome.
- Fixture and scorer land under FK's structure, so FK inherits them.

**Run 2026-11-03 on gpt-6-luna** (Responses at Automatic, through the API-key route), about US$1.80 in all. The
harness, fixtures and scorer are in `Scripts/timeline-recall-bench/`, kept together so FK can take them as
they are.

Setup:
- Both fixtures put all 40 old details outside the 14k window and all 8 controls inside it.
- Six arms:
  - **A**: today's layout.
  - **B**: A plus one sentence in the omission note telling the model to search with `brain` recall.
  - **C**: the whole conversation, with no budget.
  - **D**: A plus the timeline as P1 specifies it.
  - **E**: D with the newest omitted run summarised too, so coverage is complete.
  - **F**: D plus B's sentence.

| Old details correct (of 40) | A | B | C | D | E | F |
|---|---|---|---|---|---|---|
| Field job | 7, 4, 8 | 29, 33, 33 | 39, 39 | 27, 28 | 40, 40 | 29, 30 |
| Everyday | 17, 19, 15 | 35, 36, 36 | 40, 40 | 38, 36 | 40, 40 | 39, 40 |

Reading the table:
- **Run-to-run spread is about ±2**, so differences of 3 or less are noise.
- **Field C's one miss is a refusal to read back an access code**, which happens in every arm.
- **Controls were 8 of 8 everywhere** except one E run (6 of 8).
- **Almost every miss is a decline, the safe failure.** The only outdated answers came from D.

What the runs show:
- **Today the model rarely searches.** On the field job it answers from what it can see. On the everyday
  conversation it often calls `brain` with action `query`, which searches stored memory, not conversations.
- **B's sentence alone takes recall from 6 to 32 (field) and 17 to 36 (everyday)** with no rise in wrong
  answers. It costs about one extra model call per question.
- **B stops short of the ceiling** by about 8 (field) and 4 (everyday). The causes: questions it doesn't search
  for, keyword misses, and, on the field job, refusing a correct recall result it says it "can't verify".
- **D, built to P1's rules, is no better than B, and it is the one arm that gave outdated answers.** P1 leaves
  an open run of omitted messages uncovered until it reaches 5,000 estimated tokens. At the probe, that run
  held 16 (field) and 13 (everyday) of the 40 details. With a timeline present, the model seldom searched that
  run. A summarised "7 pm" was answered as current because the move to 7:45 sat in the uncovered run.
- **E, with coverage complete, matched the ceiling on all four runs** and needed fewer calls than B. Its block
  was about 1,170 (field) and 680 (everyday) tokens. Summarising a chunk cost about 4k tokens in and 0.5k out.
- **The timeline's label made the field job worse when combined with B's sentence (F).** "Notes, not a record"
  seems to make the model distrust its own recall results.

Limits of the run:
- **It used 9 tools and a short prompt, not the app's 60+ and its full prompt.** The field job had no job
  record. Both probably make B look better than it would in the app.
- **Replies were lengthened so that 150 messages pass 14k.** At realistic spoken length, a thread of text alone
  passes it after roughly 200 messages. In live use, tool results in the history bring that point closer.
- **Every planted value was in the wearer's own words**, which favours keyword recall and the detail check.
- **Arm E was complete only at the first request of each probe.** A tool result could push one more exchange
  out than the timeline covered, and the note stayed off: in the everyday runs that happened in 33 and 28
  of 48 probes, one exchange each time. E still scored 40 of 40, so the finding stands; the harness now
  keeps the note in any round where more has left than the timeline covers.
- **D's and E's timelines were built with the detail check as it stood**, before the fixes in this PR
  (trade units such as K and microns, a value inside a hyphenated code, a changed sign). A value the check
  missed then could have been lost from a summary without being restored.
- **Scoring was re-checked after review.** An answer naming both values is now counted correct only when
  it sets the competing one aside, and each hand call is bound to the answer it was made on. Re-scoring
  every run moved two side-run rows (reasoning off) by one or two and none of the numbers above.

**Outcome.**
- **Not the stop condition.** B does not reach the ceiling.
- **B's sentence is worth shipping on its own.** Shipped in the same PR (owner, 2026-11-03), word for word:
  `APIHistoryBudget.recallSentence` ends the omission note on the API routes and the ChatGPT one, only when
  the request declares `brain` and the model may call it. A vault-only job (which seals `brain`), a request
  without tools and the tool loop's wrap-up keep the note as it was.
- **The timeline is worth P2 and P3 only with complete coverage.** The open run has to be covered before a
  block is rendered: summarised at request time, or with a far smaller minimum. A chunk whose later
  correction is still uncovered must never be shown alone.
- **The label needs rewording** so it doesn't undercut recall results.

The run also found a P1 defect, fixed in the same PR. The detail check joined a code to the next word ("A44 on"
read as "a44on"), so codes the summary had kept were restored again as lost.

### P1 — Deterministic core

Pure and table-tested: `TimelineEntry`, the coverage calculation (tail count, gaps, overlaps, floors), chunk
selection, merge decisions, the acceptance policy with the detail check, the renderer and its cap, and
invalidation on truncate and erasure. Older threads decode unchanged.

**As built (2026-11-03).** Everything is in `Services/Memory/Timeline/` and nothing calls it outside the
store fixes below.

- `ConversationThread.timeline` holds the entries; a thread saved without it decodes as nil.
- `TimelineCoverage.compute` takes an optional `historyUserTurns`. Without it, a turn that never reached the
  saved thread opens a gap. With it, the count is also read from the head and the reading that covers more
  wins, including when the request kept more turns than the thread holds. The caller must count real user
  turns, not tool results, which travel as user messages on some providers. The turn being answered is held
  back only when the caller names its saved message (`answeringMessageID`): the last saved user message is
  not assumed to be it, because unsaved turns are exactly when it is not. An open run waits for 5,000 estimated tokens. A closed hole (an uncovered run with covered
  messages after it) is returned whatever its size, so it cannot block later chunks. An entry that starts
  before the floor covers nothing, because it is never rendered.
- `TimelineMergePlanner` merges only runs whose spans meet, because a merged span over a hole would hide the
  hole from coverage.
- `TimelineSummaryAcceptance` (closed `Rejection` set), `TimelineDetailCheck` (user messages only; lost
  values come back as the whole sentence under `Said word for word:`), `TimelineRenderer` (oldest dropped
  first to fit 1,500 estimated tokens; `hasGap` says whether the omission note must stay) and
  `TimelineInvalidation`.
- Store: `truncate` drops overlapping entries and clears `compressedSummary`. `dropTimelineEntries(naming:)`
  removes, across all threads, entries naming a person and any `compressedSummary` naming them. It returns
  nil while the store is locked or its read failed. A person erasure calls it before its receipt; the receipt
  stays unsupported because the thread text is left, and says the notes were dropped.
- For P2: the summary pass reads thread text the erasure left in place, so a re-summary can bring an erased
  name back. The pass needs the ledger's erased names, or a check against them, before an entry is kept.
  (P2 took neither: see its As built.)

### P2 — The summary pass

`completeStateless`-style seam so the pass is testable without a model, the policy gate with named skip reasons in
the style of `RelationEnrichmentPolicy`, backoff, usage and spend-cap wiring. Retire the 500-character,
300-word path and stop writing `compressedSummary`.

**As built (2026-11-04).** The pass runs after every accepted reply, typed or spoken, beside
`MemoryLoopService.enrich`. It is started and never awaited. Nothing reads its notes yet.

- `TimelinePassPolicy` is the gate. Its named skip reasons are: setting off, HIPAA mode, no model, an
  on-device model, no request reading, store locked or after a failed read, thread not the active one, a
  pass already running for the thread, backing off, spend cap, and nothing eligible. Only the reasons a
  log reader needs to tell a quiet feature from a broken one are logged. A reached cap stops the pass
  even when the wearer agreed to go past it for their own turns, because nobody is asked about the pass.
  It is never moved to a cheaper model. `TimelinePassBackoff` skips 1, 2, 4, then at most 8 passes after
  failures in a row, and a success clears it.
- `Config.conversationTimelineEnabled` is on by default and not behind Agent Mode. Settings › Everyday
  › Memory has a "Remember Earlier in Long Conversations" row with the line "Uses the same AI as the
  conversation, and counts in Usage." In Medical Compliance mode the row shows off, cannot be changed,
  and says so. The Memory parent switch never turns it on in that mode.
- `LLMService.completeTimelineSummary` is the seam. It sends one buffered, tools-off request to
  `medicalInferenceModel(requested: activeModel)`, the model answering the conversation. It records usage
  as any turn does, and reads how the reply ended so a reply cut off at its limit is refused. It never
  touches `conversationHistory`. `completeStateless` empties the history and restores it afterwards, so
  a turn that starts during the call would lose its messages. `completeStateless` itself was left as it
  is (see below).
- `TimelineRequestReading` is what the last cloud request carried: real user turns kept, real user turns
  in the history, and the job floor's date. It is taken where each request copy is built: the API
  budget, Groq, small context and the Responses budget. A real turn is a plain-text user message that
  is not one of the app's notes. The app's notes all start with "[" (or are the two re-ask lines). The
  count errs low, so a mistake is an overlap, never a gap. A turn answered on the phone leaves no
  reading, and the pass skips. `JobHistoryFloor` now records when the turn that set the floor started.
  The pass moves that date back to the question that opened the job.
- `TimelineSummaryPass` computes coverage with no minimum, so the open run is covered after every
  reply (P0's main finding). It writes at most three 8k chunks and one merge per pass, so an old long
  thread catches up over several replies. The model sees only the chunk's user and assistant messages
  with their times, fenced and labelled as quoted data (`TimelineSummaryPrompt`). The rules ask for plain
  dated lines, oldest first. Figures and codes stay exactly as written, and a correction keeps only the
  latest value and says what it replaced. A summary is kept only if `TimelineSummaryAcceptance` keeps it,
  and `TimelineDetailCheck` then restores any lost figures. Merges go through the same seam, acceptance
  and check, over the merged span's user messages. Notes from before the job floor are never merged.
- `ConversationStore.saveTimelineChunk` and `applyTimelineMerge` check everything again at save time:
  the store is open, the thread exists, both ends of the span still exist in order, nothing already
  covers the span, and a merge's sources are unchanged. A refused write is logged by reason. It does not
  count as a model failure, so it does not cause a backoff. `appendMessage` returns the saved id, which
  is how a turn names the question it answered.
- **Erasure.** P1 left a gap here: the pass would summarise an erased person's name back from the thread
  text the erasure leaves. P2 does not keep a list of erased names, because that list would keep the
  data the erasure removed. Instead, `dropTimelineEntries(naming:)` now clears a matching entry in place:
  same id, span and dates, empty text, `redacted: true`. A thread saved before this decodes unchanged.
  Coverage still counts a cleared span as covered, so it is never summarised again. The renderer never
  shows a cleared entry, and the merge planner never merges into it or across it. The receipt now says
  the notes "are cleared". `SubjectErasureTests` runs the pass after an erasure and finds no name.
- **The edge.** An edit or regenerate that removes part of a cleared span drops the cleared entry like
  any other. That range can then be summarised again, from thread text that may still name the person.
  That text is the wearer's own record, and the erasure receipt already says it was left in place.
- **Retired.** The "500-character, 300-word path" was `summarizeMessages`. It was the Agent Mode LLM
  compactor's summariser (`compressContextWindowWithLLM`), and it was the only place that wrote
  `compressedSummary`. All three are gone: the compactor, its summariser and
  `ConversationStore.updateCompressedSummary`. So is `LLMService.conversationStore`, which nothing else
  used. Agent Mode now uses the same in-memory 80k heuristic compaction as everyone else, and that
  compaction is unchanged. `compressedSummary` still decodes, `truncate` and erasure still clear it, and
  `replayMessages` still prepends it, which is P3's to change.
- **Logging.** `PrivacyLog` conversation events record counts, sizes, durations and reasons only:
  `timelineSummarised`, `timelineMerged`, `timelineSummaryFailed`, `timelinePassSkipped`,
  `timelineSaveRefused` and `timelineRedacted`. A test runs the pass with invented names and checks
  that none of them reach a log line.
- **Left for P3.** The block in requests, the label's wording, the Prompt Inspector and `replayMessages`.
  P3 also has to decide what a `new_topic` clear means for the timeline. That clear empties the model's
  history but not the thread, so the earlier messages become eligible and are summarised.
- **Found, not fixed.** `completeStateless` is unsafe for one of its existing callers. A tool error in
  Agent Mode starts the skill-evolution analyser in a detached task, and that task calls
  `completeStateless`. If the turn's tool loop is still running, the call empties the history while the
  loop appends to it. When the call restores the snapshot, it discards whatever the loop added. The fix
  is to move those callers to a seam like this one. That is not trivial, so it is reported here rather
  than done in this PR. Calls nested inside a turn (the planner and recall summaries) stay safe, and
  their requests no longer overwrite the timeline reading.

### P3 — Into the request

API routes through `requestSystemParts`, ChatGPT through `RequestContextBudget.build` so the block counts against
its allowance (and the same accounting for API routes), Groq and small-context routes checked one by one. Prompt
Inspector shows the block. `replayMessages` stops the double summary on resume.

**As built (2026-11-04).** `TimelineRequestBlock` (pure, table-tested) decides, per request copy, whether the
block goes in and what it does to the note. `LLMService` only glues it to each route.

- **Where it belongs.** Coverage is `TimelineCoverage.compute` with this copy's own counts: real user turns
  kept and in the history, the question being answered, the floor and the thread's entries. Only entries that
  cover a message this copy left out are shown. An entry that reaches into the request (a merge, or a note
  written ahead, below) is shown for the part that left: an overlap, never a gap. Cleared entries and entries
  before the floor are never shown.
- **Replace or keep the note.** The block replaces the omission note only when everything that left is
  covered, the cap dropped no entry, and the thread holds at least as many left-out turns as the history's own
  omitted part does. That last check guards the counting: a turn the history holds but the thread never saved,
  or a stale question id, would otherwise make a message that left look live and hide a gap. Otherwise the
  note stays (with P0's search sentence when `brain` is declared and callable, as before) and gains
  `partialNotesSentence`: "Some of them are not in the notes on earlier messages that follow." The block comes
  after it. A covered chunk followed by an uncovered run is never shown without that sentence.
- **Not rendered** when the setting is off, in HIPAA mode (decision 3: the note stays), on an on-device model,
  with no thread or no showable entry, or when nothing was left out. Each has a named reason
  (`TimelineRequestBlock.Skip`), with `nothingCovered` for "something left, no entry covers it" and `noRoom`
  for the ChatGPT fallback below.
- **The question being answered.** `AppState` remembers the saved question of the turn in flight and names
  it to the request only while it is still the newest user message of the active thread, so a leftover id
  names nothing. The count check above catches any that slips through.
- **The source.** `LLMService.timelineThreadSource` is a closure `AppState` sets. It returns the active thread's
  messages (reduced to ids, roles, times and sizes), its entries and the question id, or nil when there is no
  thread or the store is locked. The service never holds the store.
- **Covering ahead.** Coverage after the reply was not enough: each new turn pushes the oldest kept exchange
  out, and a tool round can push one more, so the next request almost always found one uncovered exchange and
  the block could never replace the note. Once a request has left turns out after the floor
  (`TimelineRequestReading.omittedUserTurns`, new), the pass also summarises the two oldest turns it still kept
  (`TimelineSummaryPass.lookaheadUserTurns`), as their own chunk, after what has left. A conversation that fits
  is never summarised ahead. Each exchange is still summarised once; the cost is only the last two of a
  conversation that ends there.
- **Routes, one by one.**
  - *Anthropic, Chat Completions, the OpenAI Responses API route:* through `requestSystemParts`, in the
    volatile tail (uncached by design). `requestHistory` reserves the block's room before `APIHistoryBudget.select`:
    the whole candidate block at its largest, recall clause included, capped at 1,500. Then
    `historyAllowance` takes it off the allowance (never below half the allowance; an allowance of 0, trimming
    off, reserves nothing). What was actually omitted decides what is shown, rendered to the size reserved, so
    the block can be smaller than reserved but never larger. The Responses API route's own capacity guard is a
    second layer; if it cuts more, its plain note says so.
  - *Gemini REST:* its history is budgeted by `APIHistoryBudget`, but its single system string never carried
    the omission note: a gap there was silent. It now goes through `requestSystemParts` with no volatile tail,
    so the note and the block sit at the end of the system instruction, set after the tools so the recall
    clause follows `brain` (`declaresRecall` now reads `functionDeclarations`).
  - *ChatGPT:* through `RequestContextBudget.build`, whose new `workingContext` closure is asked for the note,
    the block, or both, at every count the loop tries. The block is inside the estimate and counts against the
    allowance, and the text sent is the one for the `removed` count actually returned. If even the protected
    turn alone will not fit beside the block, the plain note is tried before the turn fails (`noRoom`): the
    timeline is never why a turn fails. ChatGPT ignores the small-context setting for its history, so it
    carries the block whatever that setting says.
  - *Groq:* no block, and no reading, so no pass. Its copy is a fixed six-message tail, not the budget, with no
    note today, and the free tier's per-minute token limit (the 413 path) is exactly what an uncached ~1.5k
    block on every tool round would trip. Notes it could never show would spend the wearer's tokens for nothing.
  - *Small context* (any route): no block and no reading, for the same reason. The setting exists to fit inside
    a few thousand tokens; its copy is clipped text without tool messages, not a suffix the count can read.
  - *On-device models and Live modes:* untouched.
- **The label**, verbatim, with the last sentence only when `brain` is declared and callable:
  "Earlier in this conversation: notes written as older messages left this request. The saved conversation is
  unchanged. Lines under "Said word for word:" are the wearer's exact words. Current job state takes
  precedence over older conversation. Exact wording can be looked up with brain, action recall." It
  describes, never instructs. The benchmark's label (`Scripts/timeline-recall-bench/timeline.py`) matches it
  for P4's re-run.
- **Prompt Inspector.** A section, "Earlier in This Conversation", shows the last request's block and says in
  plain words whether it replaced the note, followed it, or why there was none. `lastTimelineDecision` is held
  in memory for this view only.
- **Resume.** `replayMessages` no longer prepends the legacy `compressedSummary` once a thread has any entry; it
  still decodes, and `truncate` and erasure still clear it. With no entries the old behaviour stands, and no
  block is shown, so one span is never described twice. Within a session a summary already in the history is
  always the first message, so the budget drops it before anything else (tested: replay, then the budget, then
  the block, each span once).
- **`new_topic` and other clears.** A completed new topic already starts a new saved thread (the reset
  coordinator's `startSavedThread`), so the old thread is no longer active and neither the pass nor the block
  reads it. What remains is every clear that leaves the thread open: a model or persona switch, and a new topic
  with conversation history off (no thread, so nothing). `clearHistory` now records the time
  (`JobHistoryFloor.historyCleared`); it rides in the reading as `clearedAt`, and `timelineFloor(in:)` (one
  function for the pass and the block) starts the timeline at the later of the job floor and the clear. A clear
  is not moved back to the question before it, which belongs to what was cleared. It lives in memory, like the
  job floor, because it describes the in-memory history: a relaunch, or the job flow bringing a job's thread
  back, replays the whole thread into the history (`historyReplaced` forgets the clear), and the timeline then
  follows what the history holds. A side effect: after a model switch the pass no longer summarises the
  conversation from before the switch.
- **Found, not changed.** During a running job, a new topic starts a new thread, and the job's next turn
  brings the job's thread back with its whole history (`JobThreadPolicy` `.useBoundThread`). That predates this
  plan; the timeline follows the replayed history.
- **Logging.** One `timelineInRequest` conversation event per request that left something out: entries shown,
  estimated tokens, and `replacedNote`, `withNote` or the skip reason. Never the text. The block's text exists
  only in the request and in the inspector's in-memory copy.
- **For P4 to check on a device.** That the block replaces the note in the steady state of a long
  conversation (the look-ahead working), and how often a tool round still leaves the note with the partial
  sentence; that a long job thread resumed after a relaunch shows the block and no legacy summary; a model
  switch mid-thread (no notes from before it); a new job on the same thread (no notes from before the floor);
  the Prompt Inspector's section; Gemini and Anthropic requests with the block in place; per-turn cost and the
  cached share with the block in the volatile tail; and P0's benchmark re-run with the new label.

### P4 — Device pass and re-run

Run P0 again on the same fixture and record both results here. One real long conversation on a phone: a locked
phone mid-pass, a kill during a pass, edit and regenerate, resume, and a new job on the same thread.

## Owner decisions

Taken 2026-11-04, each as recommended: 1 on for everyone with a setting to turn it off; 2 no batch cutting
in this plan; 3 off in HIPAA mode; 4 no tool to read a span's original words.

1. **Outside Agent Mode?** Everything autonomous sits behind that switch, and the LLM summariser does today.
   **Recommended: on for everyone**, because the Field Assist technician is the one this is for and no new
   destination is involved: the same words already went to that provider in the same conversation. It does spend
   their tokens, so it appears in Usage and a setting turns it off.
2. **Cut history in batches?** Letting the request grow to the allowance, then cutting well below it, would leave
   the history prefix stable for several turns and could save more than the timeline costs, but changes GB P5's
   tested behaviour. **Recommended: not in this plan's PR**; decide from P0's cache numbers.
3. **HIPAA mode.** **Recommended: off for now**, with the note saying messages are missing. A local-only pass cannot
   run in the background, and a medical summary needs its own review.
4. **A tool to read the original words of a span?** It would let the model go from an entry straight to the exact
   messages, but `brain` recall may already do enough. **Recommended: leave out**, and revisit if P4 shows the model
   knows a detail exists and cannot get it.
