# Plan LU — Private Conversation (a conversation Avenkin keeps nothing of)

**Status:** 📝 Drafted 2026-11-14, nothing implemented. All six [decisions](#decisions-for-greig-taken) taken
2026-11-14 as recommended.
**Track:** Everyday assistant: privacy. Every way a conversation starts (wake word, Chat tab, watch
dictation, photo turns, live modes), the conversation store and everything fed from it, memory writers,
diagnostics, the watch, the Live Activity, the gateway bridges.
**Builds on:**
- `ConversationStore`, `ConversationContinuity`, `GuidedJobFlow.prepareThreadForTurn`, and the
  `onThreadLeft` hook that runs brain distillation and the conversation note. Plans
  [LQ](LQ-what-we-talked-about.md) and [KK](KK-conversation-timeline.md) feed from it.
- `Config.conversationPersistenceEnabled`, the global "save conversations" switch.
- Plan [LN](LN-memory-manners.md)'s `MemoryWriteGate` and `SemanticMemoryStore.parseAndExecuteCommands`.
- `MemoryLoopService`, `RelationEnrichmentPolicy`, `SkillEvolutionService`.
- `ToolEffectClass` and `NativeToolRouter`.
- `ConversationReset`, which already covers OpenClaw key rotation and the Hermes chain.
- The org profile's `SettingKey`.
- HIPAA mode's "keep the title only" rule for the activity trail.

**Sits beside:**
- Plan [LT](LT-ecosystem-review-fixes-2026-11.md), whose `PrivateSpanCheck` is unrelated despite the
  name: it stops private memory being copied into outbound calls.
- Plan [DX](DX-private-memory-timeline.md), the memory control surface. This plan doesn't touch it.

---

## Trigger

A wearer wants to ask about something they would rather Avenkin didn't keep: a health worry, a gift for
the person sitting next to them, a money problem, a question about a colleague. Today the only way is
Settings › Everyday › **Save conversations** off. That switch is global, so it's easy to forget it's
off. It also covers less than its name suggests. A read of `main` at 432e8fef4 found that, with it off:

1. **Memory still writes.**
   - `[REMEMBER…]` and `[DIARY…]` tags in a reply are still saved
     (`SemanticMemoryStore.parseAndExecuteCommands`, gated by `Config.userMemoryEnabled`, not by
     persistence).
   - In Agent Mode, `MemoryLoopService.observeTurn` still ingests the turn into the brain.
   - Facts still go to the OpenClaw gateway's memory.
2. **The debug log keeps the start of every dictated question.**
   - `addDebugEvent("Transcription: \(text.prefix(80))")` (`OpenGlassesApp.swift:8621`) writes to
     `Documents/debug-events.log`.
   - That file has no switch and isn't excluded from backup.
   - It is shown in the Developer panel and goes in the support report's log tail.
   - `DataStoreRegistry` calls it `notSubjectLinked`, which this line contradicts. **This is a defect
     for every conversation, not only private ones.**
3. **Turn traces keep web-search queries and results** for up to 14 days (`TurnTraceStore`).
4. **The activity trail keeps up to 200 characters of detail** for each side-effecting call. That detail
   can quote a message that was sent.
5. **Every photo turn is saved to the Photos library**. `CameraService.captureLibrarySink` runs on every
   shutter capture.
6. **The Live Activity and the watch show the reply.**
   - The Live Activity shows `lastResponse.prefix(80)`.
   - The watch's application context carries the last 200 characters and the last five conversation
     titles and summaries.
7. **The OpenClaw session key is deliberately stable across conversations**, so the gateway keeps
   context from one to the next. The Hermes API path sends `"store": true`.

So there is no per-conversation way to say "keep nothing of this". The global switch leaves the
places above writing.

## Outcome

- **Starting by voice.** The wearer says *"Hey Avenkin, off the record: is a mole that's changed shape
  something to see a doctor about?"* Before anything is saved, the turn becomes a private conversation.
  Avenkin first says *"Private. I won't keep any of this."*, then answers.
- **The conversation itself.** Follow-up questions in the same conversation work as usual: the model
  sees the earlier turns. Avenkin still uses what it already knows, such as the wearer's name, their
  memory and their people (decision 1). It writes nothing new.
- **Asking to remember something.** *"Remember to book the GP"* gets *"This conversation is private, so I
  won't remember that. Want a reminder instead?"*. A reminder, if the wearer says yes, is kept where
  reminders live, because they asked for it (decision 2).
- **While it's open.**
  - The phone's conversation page shows a **Private** badge, and the Chat list doesn't show the
    conversation at all.
  - The Live Activity says *"Private conversation"* instead of the reply.
  - The watch shows the badge and no reply text in its idle summary. A reply to a request made on the
    watch still comes back to the watch.
- **Ending it.**
  - It ends when the wearer says *"end private"* or taps **End** on the badge. It also ends when the
    glasses disconnect, after the usual 30-minute quiet gap, when a new conversation starts, when
    another conversation is opened, or when the app is quit.
  - Avenkin says *"Private conversation ended."* when the wearer is there to hear it.
  - It cannot be reopened, and its words are dropped from memory.
- **What is left afterwards.** No conversation in the list, nothing in `session_search`, Spotlight,
  recall, the brain, semantic memory, the diary, the Memory screen, the conversation notes, the
  timeline, the debug log, turn traces or the support report. The activity trail keeps the title of a
  call without its detail. A question-about-a-photo isn't in Photos (decision 3).
- **What Private does not change, and Avenkin says so.** The AI provider still receives the words, as it
  does for every conversation. The first private conversation explains this once, and the explainer in
  Settings says it every time.
- **During a job.** On a phone running Field Assist with a job open, *"off the record"* gets *"Not
  during a job: its record has to be complete. End the job first."* No private conversation starts.
- **Organisation control.** An organisation's profile can switch private conversations off. The phrase
  then gets *"Your organisation has switched private conversations off."*

## What exists, and what doesn't

**Exists:**
- **`ConversationStore`**
  - Holds a JSON file of up to 200 threads, optionally encrypted, rewritten in full on every save.
  - `startThread`, `appendMessage` and `endThread` write it, and `onThreadLeft` runs `BrainStore.distill`
    and the LQ note.
  - `saveAndProject(.messageUpsert)` feeds the in-memory recall index (`ConversationIndex`).
  - The active thread id is written to UserDefaults and restored at launch if it is under 2 hours old.
- **Readers of the thread list**: `ChatListView`, `ConversationContinuity`, the CarPlay list,
  `session_search`, `summarize_conversation`, `SpotlightIndexService` (conversation type off by
  default), the Siri on-screen `NSUserActivity` in `ChatThreadView`, the watch's `recentThreads`,
  `JobTranscriptExport` and `AgentDataExporter`.
- **`Config.conversationPersistenceEnabled`** guards every `startThread`/`appendMessage` call site in
  `OpenGlassesApp.swift`, and in `AskPersonaIntent` and `GuidedJobFlow`. With no thread, the timeline
  pass, the conversation note and the recall index switch themselves off.
- **Per-thread exclusion has a precedent.** `ConversationDigestEligibility` skips job threads by id.
- **Memory writers**:
  - `parseAndExecuteCommands`: REMEMBER, REMEMBER_GLOBAL, FORGET and DIARY tags, on every reply through
    `postProcess`.
  - The periodic memory nudge.
  - `MemoryLoopService.observeTurn` (brain ingest and voice skills in Agent Mode) and `enrich`.
  - `SkillEvolutionService.noteUserTurn`.
  - `pushToGateway`.
  - The tools `remember_scene`, `my_memory`, `agent_diary`, `brain` (link, log_encounter, save_need),
    `social_context`, `object_memory`, `meeting_summary`, `team_learning`, parking and badge scan.
- **Prompt context built from stored data**:
  - The memory block, people, job notes and voice-taught skills.
  - In Agent Mode, `soul.md`/`skills.md`/`memory.md`.
  - The current thread's KK timeline.
  - Nothing injects another conversation's note at the start of a conversation. That only happens
    through tools.
- **Diagnostics**:
  - The debug event log (carries content; item 2 above).
  - `TurnTraceStore` (web_search query and result text).
  - The activity trail (detail up to 200 characters; HIPAA keeps the title only).
  - `PrivacyLog` and `DiagnosticRing`, which are content-free by design.
- **Starts and ends**:
  - Wake word: `handleWakeWordDetected` → `handleTranscription` → `GuidedJobFlow.prepareThreadForTurn` →
    `recordVoiceQuestion`.
  - Typed: `sendTextMessage`. Photo turns go through their own entry points.
  - Live: `startSession`/`stopSession` in `AppState+LiveActivation.swift`.
  - Ends: `ConversationContinuity.startFresh`, the 30-minute idle gap (`JobThreadPolicy`), opening
    another thread, `conversationReset.requestReset`, and glasses disconnect (which keeps the thread
    today).
- **Live modes** write nothing to `ConversationStore`. Their tool calls reach the same native tools, so
  they can still write memory, notes and the activity trail.
- **Recognition**: questions use server recognition. On-device recognition is used for the wake word
  only (`Config.onDeviceWakeWordEnabled`), although `TranscriptionService` has an on-device engine
  (`OnDeviceASREngine`).

**Doesn't exist:**
- Any per-conversation private, incognito or ephemeral flag.
- A way to start one by voice before the turn is saved.
- A rule that a conversation-scoped flag silences memory writers, diagnostics content, the Photos sink,
  the Live Activity snippet and the watch summary.
- A throwaway gateway session.
- The org setting.

## Design

### 1 · The state (`PrivateConversation`, in memory only)

`PrivateConversationState` is `.inactive`, or `.active(id: UUID, startedAt: Date, entry:
PrivateEntry)`.
- The id is random. It is never written to disk, UserDefaults, a log or a trace; a `PrivacyLog` line
  carries only `privateConversation(.started/.ended(reason))`.
- `PrivateEntry` is `.voicePhrase`, `.button` or `.watch`.
- `AppState` owns one instance. Its only writers are `beginPrivate(entry:)` and `endPrivate(reason:)`.

The messages live in a `PrivateTranscript`: an in-memory array of the same `(role, content)` pairs that
`ConversationStore.replayMessages(for:)` returns, so `LLMService` builds the request exactly as it does
for a stored thread. `endPrivate` empties the array and drops the reference. Nothing else holds the
messages.

### 2 · Where it starts (`PrivateStartPhrase`, pure)

A pure matcher runs in `handleTranscription` **before** `prepareThreadForTurn`, so the turn that asks
for privacy is never saved anywhere.
- **Phrases.** It matches only at the start of the utterance: "off the record", "go private", "private
  conversation", "privately", "just between us", and "this is private".
- **Separators.** The phrase may be followed by a comma, a colon, "please", or the end of the utterance.
- **The question.** Whatever follows becomes the private conversation's first question. If nothing
  follows, Avenkin says *"Private. Go ahead."* and listens.
- **Phrases that must not match.** "Private school fees", "is this private property?" and "privately
  owned" are not at the start, or are not followed by a separator.
- **Tests.** A corpus test pins about 30 sentences that should match and should not.
- **Languages.** The phrase set is per language. English ships first; the other 18 UI languages get the
  button and the watch entry from day one, and their phrases are added as each translation is reviewed
  (decision 5).

The same matcher recognises the end phrases: "end private", "stop private", "back on the record".

**Buttons.**
- The conversation page header menu gains **Start a private conversation**, and the Chat list's new
  conversation menu gains the same item.
- The watch gains a **Private** button on its main screen.

All three call `beginPrivate`.

**Starting refuses, and says why, when:**
- a job is open, or the active thread belongs to a job or debrief;
- the organisation has pinned private conversations off;
- Live is running. A Live session must be started private, not switched part-way, because the provider
  already holds its earlier turns.

Starting a private conversation leaves the current stored conversation exactly as it was. It isn't
ended, so the next normal conversation can carry on from it.

### 3 · What each place does (`PrivateConversationPolicy`, a roster)

`ConversationSink` is a compile-checked enum listing every place listed under *Trigger* and *What
exists*. `PrivateConversationPolicy.rule(for:)` gives each one of:
- `.keep`: unchanged;
- `.skip`: not written or not sent;
- `.titleOnly`: the record is kept without its content;
- `.placeholder(text)`: shown with a fixed line in place of content.

A test fails if a case has no rule. A guard test scrapes `OpenGlasses/Sources` for calls to the
writers named below and fails on any call site that doesn't consult the policy, in the style of
`OutboundFrameConsumerTests`.

| Sink | While private |
|---|---|
| Conversation store: thread, messages, title, summary, active-thread id | `.skip`; turns go to `PrivateTranscript` |
| Recall index, `session_search`, `summarize_conversation`, Spotlight, Siri on-screen activity, CarPlay list, Chat list, switcher | `.skip` (there is nothing to list) |
| KK timeline pass, LQ note, `BrainStore.distill` on leave | `.skip` |
| REMEMBER, REMEMBER_GLOBAL and DIARY tags | `.skip`; stripped from the reply as today, and the `[FORGET…]` tag still works (forgetting is never blocked) |
| Memory nudge, `MemoryLoopService.observeTurn`/`enrich`, `SkillEvolutionService.noteUserTurn`, gateway memory push | `.skip` |
| Memory-like tools (§4) | `.skip`, with a reply line |
| Prompt context: memory block, people, job notes, voice skills | `.keep` (decision 1) |
| Debug event log: transcript line | Becomes `Transcription: N characters` for **every** conversation (§6) |
| Turn traces: query and result text | `.skip` text; timings kept |
| Activity trail | `.titleOnly` |
| Photo turn to the Photos library | `.skip` (decision 3); an explicit "take a photo" is kept |
| Live Activity snippet | `.placeholder("Private conversation")` |
| Watch application context: `lastResponse`, the private thread in `recentThreads` | `.placeholder` / `.skip`; a reply to a watch request still returns |
| Share transcript, support report, `AgentDataExporter` | `.skip` (there is no thread to export) |
| OpenClaw session key | A throwaway key for the private conversation, dropped at its end (§5) |
| Hermes API `store` | `false` for a private turn (§5) |
| Server or on-device recognition | On-device when the locale supports it (decision 4) |

### 4 · Tools (`PrivateToolRule`)

Every native tool whose `ToolEffectClass` is `write` is classified as one of two kinds:
- **`.memoryLike`** writes something Avenkin learns or keeps on its own initiative: `remember_scene`,
  `my_memory` (correct only; forget still runs), `agent_diary`, `brain` (link, log_encounter,
  save_need), `social_context`, `object_memory`, `meeting_summary`, `team_learning`, voice skills,
  `edit_agent_docs`.
- **`.wearerDirected`** is something the wearer asked for by name: reminders, calendar, notes, timers,
  goals, tasks, geofences, save location, parking, messages.

A guard test fails on any `write` tool left unclassified, so a new tool has to choose. In a private
conversation the router refuses a `.memoryLike` call before authorization, with a model-facing
reason: *"This conversation is private: nothing is remembered. Offer a reminder or a note if the
wearer wants to keep something."* A `.wearerDirected` call runs as usual (decision 2). MCP, custom and
gateway tools are not classified; they run under LT's rules as today.

The system prompt for a private turn gains one line: *"This conversation is private. Don't use memory
tags. Nothing from it is kept."* The code enforces the rule whatever the model does; the line only
saves wasted tags.

### 5 · Bridges

- **OpenClaw.** A private conversation uses a session key made for it. The key is dropped, never
  rotated into, at `endPrivate`, so the gateway's context from earlier conversations stays as it was
  and the private turns don't join it. Memory push and memory query to the gateway are skipped.
- **Hermes.** The API path sends `"store": false` and keeps no `previous_response_id` beyond the private
  conversation.
- **ChatGPT Responses** already sends `"store": false`.
- **Other cloud providers** keep whatever their own terms keep. The explainer says so (§7).

### 6 · The debug log line, for everyone

`Transcription: \(text.prefix(80))` becomes `Transcription: \(text.count) characters`. This applies to
every conversation, not just private ones: the registry already says the file is not linked to a
person, and this makes that true. Any other `addDebugEvent` call that interpolates spoken or reply text
is found by a grep in P0 and changed the same way. `PrivacyLogTests` gains a check that no
`addDebugEvent` argument interpolates `text`, `transcript`, `query`, `response` or `reply`.

### 7 · Words on the phone, the lens and the watch

- **Badge.** The conversation page header shows a lock and **Private**, and tapping it offers **End**.
- **Lens.** The HUD shows *Private* for 3 s at the start (Display glasses only).
- **Spoken lines.** At the start: *"Private. I won't keep any of this."*, or *"Private. Go ahead."* when
  no question followed. At the end: *"Private conversation ended."* An end the wearer doesn't hear,
  such as a disconnect, says nothing.
- **First-time explainer**, shown once on the phone: *"Private conversations aren't saved, listed or
  remembered, and leave no notes. The AI service you use still receives what you say, as it does for
  every conversation."*
- **Settings.** The explainer also sits under Settings › Everyday › **Private conversations**, with an
  **Allow** switch (on by default). An organisation can lock that switch.

### 8 · Ends (`PrivateEndPolicy`, pure)

`(state, event) → .stay / .end(reason)`. The events that end it:
- the end phrase, and End on the badge or the watch;
- the glasses disconnecting;
- 30 minutes without a turn, checked at the next turn and by a timer;
- `startFresh`;
- opening another conversation;
- `conversationReset.requestReset`;
- a job starting;
- the org pin arriving;
- Live stopping, for a Live-private session;
- the app being quit.

The app going to the background doesn't end it: the wearer may be using the glasses with the phone
locked.

## Decisions for Greig (taken)

All six taken as recommended, 2026-11-14.

1. **Does a private conversation read memory?** ✅ *Taken as recommended:* yes. The memory block, people and job
   notes stay in the prompt. Private means nothing new is kept, and reading what is already known
   keeps the answers personal. Not taken: a clean slate with no memory in the prompt, which is
   closer to "incognito" but answers worse.
2. **Tools the wearer asks for by name.** ✅ *Taken as recommended:* they run, and what they make is kept where it
   normally lives (a reminder in Reminders), because the wearer asked for it. Not taken: refuse
   every `write` tool in a private conversation, which is simpler to explain but blocks "remind me at
   5".
3. **Photos taken to answer a question.** ✅ *Taken as recommended:* a photo turn ("what's this?") isn't saved to
   Photos. An explicit "take a photo" is, because that is what the wearer asked for. Not taken:
   save nothing to Photos while private, including an explicit photo.
4. **Recognition.** ✅ *Taken as recommended:* a private conversation's questions use on-device recognition where
   the locale supports it, and server recognition with a one-time line in the explainer where it
   doesn't. Not taken: leave recognition as it is, and say in the explainer that Apple's server
   recognition is used.
5. **Phrases in other languages.** ✅ *Taken as recommended:* English phrases first; the other 18 languages get the
   button and the watch from P1, and their phrases as each translation is reviewed. Not taken:
   ship all 19 languages' phrases at once, from machine translations.
6. **Organisation control.** ✅ *Taken as recommended:* a `SettingKey.privateConversationsAllowed` ceiling, allowed
   by default, so an organisation can switch private conversations off. Jobs already refuse private
   conversations whatever the setting. Not taken: no org key, because jobs are the only records an
   organisation owns.

## Phases

### P0 — the pure core (headless)

`PrivateConversationState`, `PrivateStartPhrase` (English, with the start and end corpus),
`PrivateEndPolicy`, `ConversationSink` + `PrivateConversationPolicy` (complete table),
`PrivateToolRule` (every `write` tool classified), and the debug-log line change from §6 for every
conversation.

Tests:
- `PrivateStartPhraseTests`: the corpus, a question after the phrase, a phrase alone, a mid-sentence
  "private" not matching, and the end phrases.
- `PrivateEndPolicyTests`: every event; background stays.
- `PrivateConversationPolicyTests`: every sink has a rule, and the table matches §3.
- `PrivateToolRuleGuardTests`: every registered `write` tool is classified; forget is never blocked.
- `PrivacyLogTests`: no `addDebugEvent` interpolates spoken or reply text.

### P1 — wiring (headless, plus a UI test on the simulator)

- **Starting.** The matcher in `handleTranscription` ahead of `prepareThreadForTurn`, and
  `beginPrivate`/`endPrivate` on `AppState` with the refusals (job, org pin, Live part-way).
- **Turns.** A `PrivateTranscript` replay in `LLMService`. Every sink in §3 consults the policy, the
  router refuses memory-like tools, and the system-prompt line is added.
- **Bridges.** The OpenClaw throwaway key, Hermes `store: false`, and on-device recognition if decision
  4 is taken.
- **Phone and watch.** The badge, header and Chat-list menu items, the watch button and status, and
  the Live Activity placeholder.
- **Words.** The spoken lines, the explainer, the Settings switch, and the `SettingKey` with its locked
  control.

Tests:
- **`PrivateConversationTraceTests`** runs a Direct turn end to end on test stores (a private start
  by phrase, a follow-up, a REMEMBER tag in the reply, a `remember_scene` call, a reminder, then
  `endPrivate`). It asserts that `conversations.json`, semantic memory, the brain, the recall index,
  the diary, the debug log, turn traces and the LQ queue have no text from the conversation; that the
  activity trail has titles only; that the reminder exists; and that the stored conversation open
  before it is unchanged and still active.
- **`PrivateConversationEndTests`**: each end drops the transcript, and a later turn starts a normal
  conversation.
- **`PrivateLiveActivityTests`** and **`WatchPrivateContextTests`**: no reply text in either.
- **`OpenClawPrivateSessionTests`**: a throwaway key, the stable key untouched, no memory push.
- A UI test: start from the header menu, see the badge, end, and see nothing in the Chat list.

### P2 — device pass (owed)

On GiPhone with the glasses:
- the phrase start in a quiet and a noisy room;
- a follow-up while private, then a disconnect ending it;
- the watch button;
- the lens line on Display glasses;
- a private Live session;
- the Photos library after a photo turn;
- the Developer panel log after a private turn.

## Risks

- **The wearer thinks Private means the AI provider doesn't see it.** The explainer and the Settings
  copy say otherwise, in plain words, and the first private conversation shows it once.
- **The model writes a memory tag anyway.** The code skips it whatever the prompt says; the prompt line
  only saves tokens.
- **A new memory writer is added later and forgets the policy.** The guard tests (§3, §4) fail on an
  unclassified writer or tool.
- **Phrase false positives.** A start-of-utterance rule plus a required separator; the corpus pins the
  known near-misses.
- **A crash while private.** The messages are only in memory, so nothing survives. The debug log no
  longer carries text (§6).
- **Instant Replay and ambient captions keep running.** They are separate features with their own
  switches, and Private doesn't change them (out of scope). The explainer says "conversation", not
  "everything".

## Out of scope

- Instant Replay and ambient caption sessions. Both keep their own switches.
- Siri and Shortcuts asks (`AskPersonaIntent`), which are their own short conversations.
- Provider-side retention terms.
- Screenshots and screen recording. LT §1 covers the camera preview only.
- A private mode for a whole day, or a schedule.
- Hiding that a private conversation happened. Usage counts tokens without content, as today.
