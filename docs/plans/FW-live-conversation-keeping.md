# Plan FW — Keeping Live-Mode Conversations (records, turn details and learning)

**Status:** 📝 Drafted 2026-09-26 — not scheduled, nothing implemented.
**Origin:** Plan [FV](FV-support-reports.md) found that the two live voice modes (Gemini Live,
OpenAI Realtime) keep nothing a support report can use. The owner, the same day: customers may want
the option of keeping live conversations — and asked whether the agent ever reviews conversations
for learnings.
**Depends on:** FV (turn traces, support reports) for P2; Plan CT (organisation profiles) for the
organisation setting.

---

## What is true today (verified 2026-09-26)

**Live turns are not kept.** Plan FF P1/PR5 made this deliberate: `LiveConversationRecorder` holds
the last few turns **in memory only**, for a reconnect handover, and forgets them when the session
stops. Both session managers keep two strings — `userTranscript` and `aiTranscript` — cleared at each
turn boundary. Nothing is written to `ConversationStore`.

| Where the wearer is | What a live-mode turn leaves on the phone |
|---|---|
| In a Field Assist job | the wearer's words, as a `user_message` in the job log (`LiveJobBridge.handleTranscript` → `recordConversationTurn`) |
| Anywhere else | nothing |
| Either | **the assistant's reply is kept nowhere** |

**Live turns are not traced.** `TurnRecorder` has no turn boundaries in either session manager —
`TurnBackend.geminiLive` and `.openAIRealtime` are documented as unreachable — so a live turn has no
`TurnTrace`, and a live failure raises no *Send to support* banner.

**Does the agent review conversations for learnings?** Partly, and only in normal (Direct) mode, and
always turn by turn — nothing goes back over saved conversations later:

| Loop | What it learns | Where it runs |
|---|---|---|
| `MemoryLoopService.observeTurn` (Memory & Recall P3) | a durable fact the wearer stated, or a request they keep repeating; offers to save it, or saves it silently in Agent Mode | called once, from the Direct-mode turn path in `OpenGlassesApp` |
| Skill self-evolution (`SkillEvolutionService`) | tool errors (`NativeToolRouter`) and corrections ("no, that's wrong", `UserCorrectionDetector`) accumulate; a batch proposes a skill the wearer approves | Agent Mode only. Tool-error capture sits in the tool router, so it may already fire for live-mode tool calls; the correction capture is on the Direct path |
| Brain distillation (Plan EN) | consolidates repeated and changed facts in the knowledge graph | over what the loops above wrote |
| Team learnings (Plan [FP](FP-team-learnings.md)) | a technician's finding reaching every technician | drafted, nothing built |

So a live-mode wearer's conversations teach the app nothing, apart from any tool errors.

## The option

**"Keep live conversations"**, a setting beside the existing *save conversations* setting
(`Config.conversationPersistenceEnabled`, default on for Direct mode).

- **Default off**, so FF's posture holds for everyone who has not chosen otherwise. A wearer turns
  it on in Settings; an organisation profile (Plan CT) can turn it on for its phones and lock it.
- **When on, a live turn is kept exactly as a Direct turn is:** into the active thread (the job's
  thread in a job), under the same encryption, retention and deletion, and it becomes readable in
  the Chat tab, the Job tab, transcript exports and support reports.
- **Off still traces** (P2): turn details carry no words, so they need no conversation to be kept.
  A report from a live session with keeping off says the conversation was not kept, rather than
  printing an empty job.

## Phases (one PR each)

**P1 — Keep live turns.** At each turn boundary (`onTurnComplete`), append the wearer's final
transcript and the assistant's final transcript to the active thread when the option is on. An
answer the wearer spoke over (`onInterrupted`) or cut off by a dropped connection is kept marked as
interrupted — the handover already knows it may not have been heard. In a job, write through the
job's thread binding (`GuidedJobFlow`), never around it. Script-aware joining stays in the managers
(`ScriptAwareJoiner`); the store receives the finished strings.

**P2 — Trace live turns.** Begin a turn on the wearer's first transcription of an utterance; mark
first output on the first audio or output transcription; seal on turn complete. Interruptions mark
`interrupted`; a dropped connection, exhausted reconnect or session error marks a `failure`, which
raises FV's banner. Backend `.geminiLive` / `.openAIRealtime` and the model from the session config.
The transcriber is the provider's own (a new value, not an `ASREngine` case, so the Direct-mode
selector is untouched). The system instruction is built once per session: record its blocks at setup
and copy them onto each turn. Camera frames stream continuously, so a turn records how many were
forwarded while it ran rather than "a photo". Tool calls come from `ToolCallRouter` (Gemini) and
`OpenAIRealtimeToolRouter`. **Timing caveat:** the server decides when the wearer stopped talking,
so live timings are their own cohort and are never averaged with Direct-mode turns (Plan CU's rule).

**P3 — Learn from live turns.** When a live turn is kept, hand it to `MemoryLoopService.observeTurn`
and the correction detector under exactly the gates Direct mode uses (Agent Mode for silent saves,
presence and rate limits for spoken offers). A spoken offer must not talk over a live model: queue it
for the next pause, or show it on the phone. With keeping off, nothing is learned from live turns.

**P4 — Device checks.** One job and one non-job session in each live mode: turns kept and readable,
an interrupted answer marked, a forced disconnect raising the banner, the report lining the turn
details up under the right lines, keeping off leaving nothing in the Chat tab.

## Privacy

- **Disclosure in the same PR as P1:** `privacy.html` and the in-app Conversation settings copy say
  live conversations are kept when the option is on; the organisation-profile case is shown on the
  enrolment review sheet, as other organisation-set options are.
- **No new store and no new destination.** Kept turns go into `ConversationStore`
  (`SensitiveStore.conversationThreads`: encrypted when the wearer chose encryption, backup-excluded,
  erasable). Nothing leaves the phone except in a report the wearer sends.
- **Audio is still never kept.** The words kept are the provider's transcription of the wearer and
  of its own reply.
- **Bystanders.** Live mode keeps the microphone open between turns. Only turns the provider
  transcribed as the wearer's are kept, never ambient transcription (Plan CZ / captions stay out).

## Tests

Headless where the seam allows: the keep/skip decision (option, organisation lock, persistence
setting, medical mode), the interrupted marking, trace assembly from a sequence of live events
(transcription, first audio, interruption, turn complete, disconnect), and the learning hand-off
gates. The session managers themselves are exercised on a device (P4).

## Open questions

- **Default off, or on for organisation phones?** Leaning off everywhere, with the organisation
  deciding for its own phones.
- **Jobs only, or everything?** An organisation may want job conversations kept and nothing else.
  Leaning: one option, with an organisation able to limit it to jobs.
- **Should P2 ship alone first?** It keeps no words and closes the banner gap. Leaning yes, if the
  pilot runs a live mode before P1 is decided.
- **Team learnings (FP).** Kept live turns make FP's capture possible in live mode too; FP keeps its
  own review-before-publish rules.
