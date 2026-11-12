# Plan LQ — What We Talked About (a short note of each finished conversation, kept with memory, one tap back to it)

**Status:** 📝 Drafted 2026-11-12. Nothing built. The [decisions](#decisions-for-greig-open) below are
recommendations and are still open.
**Track:** Everyday assistant — memory and recall. Every mode that saves a conversation thread (voice, Chat
tab, live modes that write to the store), the Memory screen, `session_search` and the recall index.
**Builds on:** Plan [KK](KK-conversation-timeline.md) (`ConversationThread.timeline`, `TimelineSummaryPass`,
`TimelinePassPolicy`, person erasure that clears a note rather than removing it), Plan
[GG](GG-readable-memory.md) (the Memory screen, `MemoryFact`, `MemoryFactForgetter`, "Delete that
conversation" after a forget), Plan [LN](LN-memory-manners.md) (`MemoryWritePolicy`,
`MemoryInstructionCheck`; drafted, not built), `RelationEnrichmentPolicy`, `ConversationRecallCoordinator`,
`JobThreadPolicy.conversationIdleGap`.
**Sits beside:** Plan [LE](LE-evening-check-in.md) (could read these notes later; not in this plan), Plan
[LM](LM-background-and-notification-foundation.md) (the background wake a deferred note could use, P4).

---

## Trigger

The question was: does Avenkin take a summary of each conversation and add it to what it knows, with a way
back to where it came from? Partly. Facts said during a turn are saved and carry the conversation's id. But:

1. **There is no note of the conversation as a whole.** The "summary" a thread gets when it ends is the first
   few words of up to three user messages joined with dots. It is not written by a model, and it is only shown
   on the Chat list, the watch and Siri, and searched by `session_search`. "What did we decide about the plumber
   last week?" finds a thread only if those words were in a title, that prefix, or a message.
2. **A thread that is replaced, rather than ended, gets no summary at all.** `startThread` replacing an open
   thread runs `onThreadLeft` but not `endThread`, so the summary is never written.
3. **Memory has no way back.** A saved fact knows which conversation it came from, but the Memory screen
   only uses that to offer "Delete that conversation" after a forget. There is no "open the conversation this
   came from", which is the first thing a wearer wants when a fact looks wrong.

## Outcome

- A voice conversation about a leaking tap goes quiet for 30 minutes. The next voice turn starts a new
  conversation, as today. Afterwards, without the wearer waiting on it, the old one gets a short note:
  *"Leaking kitchen tap: decided to call the plumber Thursday; washer size is 15 mm."*
- A week later: "What did we decide about the tap?" → `session_search` finds the conversation by its note,
  even though the wearer never said "decide", and answers from it.
- The Chat list shows that one-line note under the conversation's title in place of the word-prefix summary.
  The watch and Siri show it too.
- Memory › a fact › **From this conversation: "Leaking kitchen tap", 5 Nov** → opens the conversation to read.
  Reading it does not make it the open conversation. The next voice turn still starts where it would have.
- Memory › **Conversations** (collapsed, like Health) lists the notes, newest first. Each one opens its
  conversation. Forget a note and it's gone and isn't written again. The existing offer to delete the
  conversation follows, as for any forgotten fact.
- With HIPAA mode on, no note is written and the word-prefix summary stays. Nothing is sent.
- On a phone an organisation manages, its profile can switch notes off. The switch then shows as set by
  that organisation, no notes are written, and nothing is sent. Removing the profile puts back what the
  wearer had chosen.
- A conversation where the wearer only said "what time is it" twice gets no note.
- Notes never quote a manual page, a web page or an email at length. A conversation where the wearer
  mentioned their neighbour's diagnosis gets a note that leaves the diagnosis out (LN's rule).

## What exists, and what doesn't

**Exists (checked against `main` at f8f881991):**
- `ConversationThread` (in `ConversationStore.swift`) has `summary: String?` and `compressedSummary: String?`,
  and `timeline: [TimelineEntry]?` (Plan KK). The store is a JSON file (`Documents/conversations.json`),
  encrypted with ChaCha20-Poly1305 when encryption is on, capped at 200 threads (`trimOldThreads`), and listed
  in `DataStoreRegistry` as `.conversationThreads` (`completeUntilFirstUserAuthentication`, backup-excluded,
  retention by the wearer's history setting, `deleteThread(_:)` as the per-subject delete).
- `ConversationStore.endThread()` writes a title and `summary` from `generateSummary(from:)`, which is a
  heuristic over user-message prefixes ("Purely local — no LLM call needed"), then calls `onThreadLeft`.
  `startThread` calls `onThreadLeft(replaced)` for a thread it replaces, without `endThread`. The idle-gap
  end (`JobThreadPolicy.Resolution.endIdleThread`, `conversationIdleGap` = 30 min, voice turns only, never a
  thread a job or debrief owns) and "start fresh" (`ConversationContinuity.startFresh`) go through
  `endThread`. `OpenGlassesApp` sets `onThreadLeft` to `BrainStore.shared.distill(sessionID:)`, and that is
  its only use.
- `summary` is read by `ChatListView`, `ChatThreadView`, `WatchConnectivityManager`, `SiriContentAdapters`
  and `SessionSearchTool`. `SessionSearchTool` scores threads by keyword over title, summary and messages,
  skips the active thread, and returns `Summary: …` lines. It does not filter by persona.
- `TimelineSummaryPass` writes model notes about older turns of the **active** thread for that thread's own
  request. `TimelinePassPolicy.decide` refuses, each with a named reason, when the setting is off
  (`Config.conversationTimelineEnabled`, default on, not behind Agent Mode), HIPAA mode is on, there is no
  model, the model is on the phone, the turn built no cloud request, the store is not writable, the thread is
  not active, a pass is running, the thread is backing off, or a spend cap is reached. Person erasure clears
  timeline entries naming the person (`dropTimelineEntries(naming:)`), marking them `redacted` so the pass
  cannot write the name back.
- `RelationEnrichmentPolicy.decide` (Agent Mode, `Config.brainEnrichmentEnabled`, HIPAA off, a cloud provider)
  gates the brain's one network pass. `isOnDevice(_:)` is the shared "inference on the phone" test, because
  on-device inference cannot run in the background.
- Facts carry their conversation in two different places. `SemanticMemoryStore.parseAndExecuteCommands`
  passes the thread id as `sourceRef` on `[REMEMBER…]` writes. `MemoryLoopService` (Agent Mode `saveFact`)
  calls `BrainStore.ingest(text:sourceRef: "memory-loop", sessionID: activeThreadId)`, and the brain stores the
  thread in the `edges.session_id` column. **`BrainStore.Edge` does not read `session_id`**, and
  `BrainFactSource` maps `edge.sourceRef` (here "memory-loop", or a book's title) into `MemoryFact.sourceRef`.
  `MemoryFact.sourceRef` is documented as "the conversation thread, meeting title, book or add-on".
- `MemoryFactForgetter.plan(for:)` treats `sourceRef` as a thread only when it matches a live thread id, and
  `MemoryView` then offers "Delete that conversation". `MemoryFactDetailView` shows "Came from" (the
  origin), kind, date and persona. It has no link to a conversation.
- `ChatThreadView(threadId:)` **activates the thread when it appears** (`resumeIfNeeded` →
  `appState.activateConversationThread`), asking first only when a job owns another conversation.
- `ConversationRecallCoordinator` keeps an in-memory FTS index of user/assistant turns, rebuilt on unlock
  (`.conversationRecallIndex`, `processMemoryOnly`). It is fed by `ConversationRecallProjectionEvent`.
- Organisation profiles (Plan [CT](CT-org-configuration-profiles.md)) move settings only through `SettingKey`, an
  allow-list in which each key declares the one way it may move. Agent Mode, face recognition, the
  interpreter, Instant Replay and cloud dictation are `.ceiling(pinnedTo: false)`: a profile may switch them
  off, never on. `Config` reads them through `PolicyEnvelope.bool(_:stored:)`, which clamps on read and never
  overwrites the wearer's own value. The setter refuses while `PolicyEnvelope.isLocked(_:)`, and the control
  shows locked with the organisation named. `.orgPolicyDidChange` is posted when a profile is applied or
  removed. Neither the timeline switch nor anything about conversation history is a `SettingKey` today.
- `SubjectErasureCoordinator.eraseConversations`: `.conversationThread(id)` deletes the thread; `.person`
  leaves thread text, clears timeline notes naming them, and says so in the receipt.

**Doesn't exist:**
- A model-written note of a finished conversation, or anything that writes one for a replaced thread.
- A way from a Memory fact to the conversation it came from, or a way to open a conversation to read it
  without making it the open conversation.
- Any digest text in recall: the FTS index and `session_search` see turns, titles and the word-prefix summary.

## Design

### 1 · The note, and where it lives (`ConversationDigest`, on the thread)

`ConversationThread.digest: ConversationDigest?` — optional, so every saved thread decodes unchanged.

```
ConversationDigest
  headline: String            // one line, ≤ 90 characters
  points: [Point]             // ≤ 5; each ≤ 160 characters
  coversThroughMessageID: String
  writtenAt: Date
  tier: cloud | onDevice      // which kind of model wrote it, for the log and the badge
  redacted: Bool?             // set by a forget or a person erasure: never written again
Point
  kind: decided | learned | toDo | askedAbout
  text: String
```

It lives on the thread for the reason KK put `timeline` there. Encryption, the save guards, the 200-thread
cap, the retention setting, `deleteThread`, `deleteAllThreads` and the `.conversationThreads` registry record
all cover it without new code. There is no second store to register, protect, export or forget. The note is
derived from the thread, so it goes when the thread goes. The registry record's notes gain one line saying
the thread carries a model-written digest.

The note is not a fact and does not go into `SemanticMemoryStore` or `BrainStore`. It is never pushed to the
gateway. It stays local like the thread it describes.

### 2 · When a note is written

On `onThreadLeft`, beside `BrainStore.distill`, not in `endThread`. `onThreadLeft` is the one seam every way
of leaving a thread already goes through: an end, the idle gap, start fresh, and a replace. The pass runs
after the new conversation's turn has been answered. Nobody waits on it.

A thread qualifies when (pure, `ConversationDigestEligibility`):
- it has at least two user turns and 200 characters of conversational text (`TimelineSummaryPass.isConversational`);
- it has no digest, or messages after `coversThroughMessageID` (a resumed conversation left again gets one
  rewrite, from the old note plus the new turns);
- `redacted` is not set;
- no Field Assist session, open or ended, names it as its `conversationThreadId`, and it is not the debrief
  thread ([decision 2](#decisions-for-greig-open)). `jobTitle` is not enough: `applyThreadTitle` sets it only
  once the job has a reference, and `applyJobTitle` leaves it nil on a thread the technician renamed. A
  normal job end calls `endThread`, so `onThreadLeft` does fire for a job's thread. Only the
  access-withdrawal path deletes the thread without it. This check, rather than the seam, is what keeps
  job threads out, and the backlog applies the same check.

**Backlog.** A thread that qualified but was not written (no network, the phone locked, an on-device model
while backgrounded, a spend cap) is picked up by `ConversationDigestBacklog` (pure): eligible, not active,
quiet for at least `conversationIdleGap`, newest first, at most 20 a day. It runs when the app comes to the
foreground, one thread at a time. Only threads left after the feature ships are picked up
([decision 7](#decisions-for-greig-open)).

### 3 · What the model is given (no second copy of the timeline)

`ConversationDigestInput.build(thread:budget:) -> Request?` (pure):
- The thread's timeline entries, which are already model notes of its older turns, dated. Redacted entries
  are left out. The digest reads the timeline. It never summarises the whole transcript again.
- Then the conversational messages after the last timeline coverage, oldest dropped first to fit the budget.
- **Processed text is not the wearer's.** On a turn whose `toolNames` include an untrusted-output tool
  (`PromptInjectionPolicy.isUntrustedOutput`: web and news, camera text and scans, saved memory, translation,
  ambient audio, places, the gateway and MCP tools),
  only the wearer's message is sent, not the reply. The reply carries the page's words. This is LN §3's rule,
  applied before the call instead of after.
- No images, tool bodies, sources or system messages.

The prompt (ours, short) asks for a JSON object: a headline, and up to five points that are what was decided,
what was learned, what is still to do, or what was asked about. It says to name no other person's health,
beliefs or money. It says not to quote, and to leave out anything said by someone other than the wearer.

The digest never goes into the thread's own requests (the timeline does that job) and is not appended to
`compressedSummary`. Each covers a different thing: the timeline is the thread's memory of itself, the
digest is how other conversations find it.

### 4 · What is kept of the answer (`ConversationDigestAcceptance`, pure)

- Shape: valid JSON, finished normally, headline present and in length, ≤ 5 points, known kinds.
- **No copying.** A point or headline that shares a run of 12 or more words with any one message is dropped.
  A note is never a way to carry a manual's or an email's text out of the conversation.
- **LN's gate.** Each point and the headline go through `MemoryWritePolicy.decide(…, origin: .inferred,
  destination: .local)` and `MemoryInstructionCheck`. A sensitive point about another person is dropped, so
  is a sensitive inferred point about the wearer (LN §2), and so is an instruction-shaped one (LN §3). A
  point is dropped whole, never rewritten vaguer. Drops are counted in `PrivacyLog` by category only.
- If the headline is dropped, there is no digest and the word-prefix summary stays.

### 5 · Whether a call is made (`ConversationDigestPolicy`, pure, in the style of `TimelinePassPolicy`)

In order, each refusal named from a closed set that is safe to log:

1. **No organisation profile pins it off** (`orgPinnedOff`, §9). Checked first and named on its own, so a
   log reader can tell a company's choice from the wearer's.
2. **The setting is on.** `Config.conversationDigestsEnabled`, default on, beside the timeline switch in
   `EverydaySettingsScreen`. Not behind Agent Mode ([decision 1](#decisions-for-greig-open)): it sends the wearer's
   words to the model those words already went to, once per conversation, like the timeline.
3. **HIPAA mode is off.** No note at all under HIPAA, on-device included. A medical conversation's note needs
   its own review (KK decision 3's reasoning).
4. **A model is configured.**
5. **The destination is the same.** The active provider is the one that answered the thread's last turn
   (new `ConversationThread.lastAnswerProvider: String?`, written when a reply is saved). A wearer who
   switched provider since then gets no note for that thread (`providerChanged`;
   [decision 4](#decisions-for-greig-open)).
6. **An on-device model runs only in the foreground.** `RelationEnrichmentPolicy.isOnDevice(provider)` while
   backgrounded → `deferred`, which leaves the thread in the backlog. It is not a refusal
   ([decision 3](#decisions-for-greig-open)).
7. **The store is open and writable**, and the thread still exists.
8. **No pass is running for the thread**, and it is not backing off (`TimelinePassBackoff`, reused).
9. **No spend cap is reached** (`TimelinePassPolicy.isAtSpendCap`, reused; never moves to a cheaper model,
   which would be a new destination). The daily backlog cap is the backlog's, not a policy reason.

The call goes through the same structured-completion seam the brain uses (`completeStructured`), injected as a
closure so tests never touch the network.

### 6 · How notes are found again (recall, without a standing prompt block)

- **`session_search`** scores the headline and points the way it scores `summary` today, and returns
  `Note: …` with the points and the conversation's date. When a thread has no digest, it falls back to
  `summary`. The text goes back inside the same `PromptInjectionPolicy` envelope as saved memory: a note was
  written by a model from text that may have come from outside.
- **The recall index** gains one row per digest (new projection event `.digestUpsert(threadID:)`, and
  `.threadDelete` removes it). A recall hit on a digest names its thread, as a turn hit does. Rebuilt on
  unlock like the rest of the index, never on disk.
- **No standing block.** Notes are not added to every prompt. LN's manners hold: a past conversation comes
  up when the wearer asks or a tool finds it ([decision 5](#decisions-for-greig-open)).
- **Chat list, watch, Siri** show `digest.headline` when there is one, `summary` otherwise. `summary` is still
  written, so a thread with no note (HIPAA, short, no model) looks the same as today.

### 7 · The way back (Memory screen)

**"From this conversation."** `MemoryFact` gains `conversationThreadID: String?`, set by the adapters, and
the one place that resolves it:
- semantic facts: `sourceRef`, when it names a thread;
- brain relations: `BrainStore.Edge` gains `sessionID`, read from the existing `session_id` column;
  `BrainFactSource` maps it (today it maps `edge.sourceRef`, which is "memory-loop" or a book);
- everything else: nil.

`MemoryScreenModel` keeps it only when the thread is still in `ConversationStore.threads`, the same check
`MemoryFactForgetter.plan(for:)` makes today. The forget plan then reads the resolved field instead of
re-deriving it, so one rule decides both. `MemoryFactDetailView` shows a row: **From this conversation**, its
title and date. A deleted or trimmed thread shows no row.

**Reading is not resuming.** `ChatThreadView` gains `activation: .onAppear | .onSend` (default `.onAppear`, so
the Chat tab is unchanged). Memory opens a conversation with `.onSend`: it shows the thread, and only typing a
message activates it, through the same `activateThread()` and its job question. Without this, checking where a
fact came from would quietly make a week-old conversation the one the next voice turn joins.

**Conversations group.** `ConversationDigestFactSource` lists threads with a digest as `MemoryFact`s (store
`.conversationDigest`, kind `.conversationDigest`, origin `.inferred`, text = headline). They sit in a new
`MemoryFactGroup.conversations`, collapsed by default, newest first ([decision 6](#decisions-for-greig-open)).
The detail view shows the points and **Open the conversation**. Capabilities: forget, but no correct, because
the note is derived and an edited note would no longer describe the thread. Forget clears the digest's text,
sets `redacted` and keeps `coversThroughMessageID`, so it is not written again. Then the existing "Delete that
conversation" offer follows.

All new copy goes in the string catalog, with no plan letters.

### 8 · Forgetting and erasure

- `.conversationThread(id)`: the thread is deleted, and the digest with it. The recall row goes with
  `.threadDelete`.
- `.person`: `dropDigestPoints(naming:)` beside `dropTimelineEntries(naming:)`. Points naming the person are
  cleared, and a headline naming them clears the whole digest with `redacted` set. The receipt wording
  extends KK's ("…its notes naming them are cleared instead").
- `.memoryFact` (a forgotten fact): the forget sheet lists digest points that mention it, found the way
  `MemoryNoteMatcher` finds note lines, with the same "Also remove these" toggle. A note does not keep a fact
  the wearer asked to forget.
- Retention and the 200-thread cap need nothing new: the digest is part of the thread.

### 9 · An organisation can switch notes off

`SettingKey.conversationDigestsEnabled` is declared `.ceiling(pinnedTo: false)`, the same way as
`instantReplayEnabled`. `Config.conversationDigestsEnabled` reads through `PolicyEnvelope.bool`, and its setter
refuses while the key is locked. The Settings switch renders locked, naming the organisation, through the
path every other locked key uses. An organisation can switch notes off on its phones and never on: writing
notes about a person's conversations is the person's choice, not the employer's.

While pinned off:
- `ConversationDigestPolicy` refuses with `orgPinnedOff` (§5, reason 1). Its conditions read
  `PolicyEnvelope.isLocked(.conversationDigestsEnabled)` directly, so the reason is not reported as the
  wearer's `settingOff`.
- The backlog does not run. A pin that arrives (`.orgPolicyDidChange`) while it is running stops it before
  the next thread, because each call is decided afresh. A call already in flight finishes, and its note is
  still put through the same check before it is saved, so it is dropped.
- Notes that already exist are a separate question ([decision 9](#decisions-for-greig-open)). A pin never
  deletes anything: clamp on read is the rule, so removing the profile changes nothing but the switch.

This is independent of the job-thread rule (§2). Job threads never get notes, managed or not. The pin is for
an organisation that wants no notes at all on its phones, including the technician's own chats in the van.
Pinning the timeline switch is not part of this plan.

## Decisions for Greig (open)

1. **Gate.** *Recommended:* its own switch, default on, not behind Agent Mode, like the timeline (KK
   decision 1): same destination, one call per conversation, nothing done on the wearer's behalf.
   Alternative: behind Agent Mode, per the rule that autonomous work lives there. Notes would then be
   missing for most wearers.
2. **Job and debrief threads.** *Recommended:* none. The work record is the job's summary, and a job's thread
   is full of employer and manual content. Alternative: include them, with the copying check as the only
   guard.
3. **On-device models.** *Recommended:* write the note in the foreground, and leave it in the backlog while
   backgrounded. Alternative: cloud only, so a wearer on Apple's on-device model never gets notes.
4. **A provider switched since the conversation.** *Recommended:* no note for that thread. The words would go
   somewhere they never went. Alternative: use the active provider (simpler, and the wearer did choose it).
5. **Standing prompt use.** *Recommended:* none; recall on demand only. Alternative: carry the last
   conversation's note into the next one when it starts within a day ("carry on with the tap").
6. **A Conversations group on the Memory screen.** *Recommended:* yes, collapsed. It is the "what it knows from
   our conversations" view the question asked for. Alternative: notes only on the Chat list, and Memory
   carries just the "From this conversation" link.
7. **Older conversations.** *Recommended:* only conversations left after the feature ships, so there is no
   first-run spend over 200 threads. Alternative: a "Write notes for older conversations" button beside
   the switch, under the daily cap.
8. **Facts from notes.** *Recommended:* none. Per-turn writers already save facts, and a second inferred
   writer doubles the risk of false memories. Alternative: offer a note's to-do points as reminders, one tap
   each.
9. **Notes that already exist when an organisation pins notes off.** *Recommended:* they stay, in Memory and
   in recall. They were written before the pin, from the wearer's own conversations, and a profile only ever
   clamps, never deletes. Alternative: hide them from recall and the Memory screen while the pin is in force,
   still without deleting them.

## Phases

LQ P0 can be built now. P1 needs LN P0 (`MemoryWritePolicy`, `MemoryInstructionCheck`) merged first. If LN
is still unbuilt, P1 waits, and it does not ship its own copy of LN's gate.

### P0 — the pure core (headless)
`ConversationDigest` (Codable, old threads decode), `ConversationDigestEligibility`, `ConversationDigestInput`,
`ConversationDigestAcceptance` (shape and copying, not yet LN's gate), `ConversationDigestPolicy`,
`ConversationDigestBacklog`. Tests:
- a thread saved before the field decodes;
- every policy reason, in order;
- on-device and backgrounded gives `deferred`, not a skip;
- a resumed thread qualifies once per new tail;
- a job thread never qualifies, including one with no job number and one the technician renamed;
- the input reads timeline entries and the tail, leaves out redacted entries and replies after untrusted
  tools, and fits its budget;
- a 12-word quoted run drops its point;
- the backlog orders by date and caps per day;
- an organisation pin refuses with `orgPinnedOff` ahead of every other reason.

### P1 — written and forgotten (headless, after LN P0)
`lastAnswerProvider` written on reply save. `ConversationStore.saveDigest(_:for:)` with the save guards
(locked, thread gone, redacted, organisation pin). `ConversationDigestPass` hung on `onThreadLeft` beside `distill`, with a
`Summarise` seam, backoff and `PrivacyLog` lines that never carry text. Backlog run on foreground. LN's gate
in acceptance. Settings switch, and `SettingKey.conversationDigestsEnabled` as a ceiling with its locked
control (§9). Erasure (§8) and the registry note. Tests:
- leave by end, by idle gap and by replace: each writes once;
- HIPAA writes nothing and sends nothing;
- a switched provider writes nothing;
- a neighbour's diagnosis point is dropped and the rest kept;
- a forgotten note is not rewritten after a resume;
- person erasure clears points naming them;
- deleting a thread leaves no digest anywhere;
- with the key pinned off: no call is made, the setter is refused, a call in flight when the pin arrives
  saves nothing, and removing the profile restores the wearer's own value. The `SettingKey` lists in
  `SettingsVisibilityPolicyTests` include the new key.

### P2 — found again (headless)
`session_search` scoring and output with the envelope. The recall-index digest row and its delete. Chat
list, watch and Siri read the headline, falling back to `summary`. Tests:
- "what did we decide about the tap" finds the thread by its note alone;
- the active thread is still skipped;
- a deleted thread's digest row is gone from the index;
- the watch payload carries the headline.

### P3 — the way back (headless, plus a UI test on the simulator)
`MemoryFact.conversationThreadID` and `Edge.sessionID`. The forget plan reads the resolved field. "From this
conversation" row. `ChatThreadView` activation mode. Conversations group, its forget, and the string catalog.
Tests:
- a semantic fact and an Agent-Mode brain fact both resolve to their thread;
- a book fact resolves to none;
- a deleted thread gives no row;
- opening from Memory leaves `activeThreadId` unchanged until a message is sent;
- forgetting a note sets `redacted` and offers the conversation's delete.

### P4 — device pass (owed)
With the glasses: a voice conversation ended by the idle gap while the phone is in a pocket gets its note (a
cloud model), or after the next unlock (an on-device model). Ask for it a day later by different words. Open
a fact's conversation from Memory, then check that the next voice turn did not join it. HIPAA on: no note,
no request in the network log. Whether a cloud backlog should use LM's background wake is decided here,
from what the pass shows.

## Risks

- **A wrong note.** A model can misstate what was decided. Mitigations: the note is badged inferred, it opens
  the conversation in one tap, it is never used as a fact, and forget means it is not written again.
- **Cost.** One call per finished conversation, plus at most one per resume, and a daily backlog cap. Spend
  caps stop it outright. Most conversations are short and never qualify.
- **Licensed or third-party text leaving its context.** Job threads are skipped (decision 2), replies after
  untrusted tools are not sent, and the copying check drops quotes. A note is no way to read a manual
  without the manual.
- **LN not built yet.** P1 waits for it rather than duplicating it. Until P1, nothing is written.
- **Bystanders.** Ambient-audio tools (`memory_rewind`, `meeting_summary`, `summarize_conversation`) are
  untrusted output, so their replies are never sent (§3). LN's other-person rule catches what the wearer
  repeats. P0 checks whether any live mode writes caption text into a thread as a user message; if one does,
  those messages are left out of the input as well.

## Out of scope

- A daily or weekly roll-up across conversations (LE's check-in could read notes later, in its own plan).
- Editing a note's text.
- Sending notes to the gateway or any other device beyond today's watch payload.
- Changing the timeline, its pass or its request block.
- Facts extracted from notes (decision 8).
