# Plan KJ — One Answer, Asked For (a reply said once, an offer that was an offer, a reading's unit once)

**Status:** 🚧 P0 run 2026-11-01 (see Evidence): the doubling reproduced on Chat Completions and not on
Responses, at the cost of slower tool turns. The owner took the route on that evidence. P1 to P3 are built
(see each phase's as-built note); P4, the tester's re-run on a device, is owed. Drafted the same day from a
tester's report on build 581.
**Track:** Field Assist first (the tester is comparing models on a vault job), app-wide underneath: any
Direct-mode turn on an OpenAI model at Automatic, and any reading recorded in a job.
**Related:** Plan [KD](KD-vault-retest-581.md) (P3's `RepeatedReplyCollapse`, and the route decision it
left owed), Plan [KE](KE-symptom-diagnosis-and-vault-only.md) (P1's expert gate),
Plan [GC](GC-openai-responses-reasoning.md) (`OpenAIRouteSelector`, commentary held back on Responses).

---

## Why

A tester ran one furnace job on build 581 with gpt-6-luna and reported two faults: the assistant opened
the expert card on a question that asked for nobody, and some replies said the same thing twice in
different words. Plan KE's gate already stops the first on main (build 611). Nothing on main stops the
second, and reading the same report turned up two smaller faults beside them.

## Findings and causes

1. **Doubled replies are still open.** 4 of the job's 14 replies carried the same answer twice in
   different words, on a new line. Each was one response to one request and was spoken as one utterance,
   so the app neither sent nor appended it twice. Two of the four made no tool call.
   - All four came late: none before the request carrying 38 messages. Not every late reply doubled.
   - `RepeatedReplyCollapse` only removes a word-for-word repeat, so it leaves these alone. Run on the
     four replies at build 614, it changed none of them.
   - Plan KD says Chat Completions merges the model's preamble into its answer. That was reasoned from
     the logs and has never been run against the live model. KD also calls these tool turns; here the
     tools were attached and not always called.
   - gpt-6-luna at Automatic goes to Chat Completions (`automaticStaysCheap`). Responses already holds
     back a message labelled `commentary` (`ResponsesTranslator.isCommentary`), and P0 shows the API
     route labels it for this model.
   - A doubled reply goes into history as it came. The model may be copying its own earlier replies,
     which the probe tests, because a route change would not stop that. P0 saw no sign of it.
   - The prompt tells the model to "ALWAYS speak a brief verbal acknowledgment BEFORE calling any tool"
     (`TOOL USAGE RULES`), and on OpenAI the job block and manual passages arrive as a trailing system
     message, after the technician's turn (`PromptLayout.chatMessages`). P0 found both matter to the
     replay; neither is named in Plan KD.
2. **The expert gate reads a mention as an offer.** `TechnicianRequest.confirmsExpertOffer` passes a
   short affirmative whenever the previous reply contained a person word or "escalate". A reply that
   says "escalate rather than treating it as a pass" offers nothing, yet "okay I will check it" and
   "right, the meter is on ohms" both passed as a yes after it. The refusal text then never runs and the
   card appears, which is the fault the tester reported, by a narrower door.
3. **A reading's unit can print twice.** The job log held a reading with the unit written twice. The
   model passed the unit inside `value` as well as in `unit`, and `SpokenReading.valueWithUnit` joins
   the two. That text reaches the job log, the tool result and the printed report's reading lines. The
   schema says "the value exactly as said", which invites it.

## Phases

### P0 — does the route explain it? (live, one key, no app change)

A replay outside the app, as in Plan KE's Evidence: gpt-6-luna, an approximate prompt, stubbed tools, all
tools attached, invented job content. The key stays in the session scratchpad and is deleted afterwards.

| Replay | Route | History |
|---|---|---|
| A | Chat Completions, `none` | Clean |
| B | Chat Completions, `none` | Holding doubled replies |
| C | Responses, lowest effort | Clean |
| D | Responses, lowest effort | Holding doubled replies |

- Twenty runs of each, on a history long enough to match the report (about 40 messages).
- Record for each run: whether the reply doubled (a similarity score, then read by eye), whether any
  output message carried a `phase` and which, whether the turn called the expected tool, the time to
  first output, and the tokens.
- A doubled reply needs a rate on Chat Completions before anything can be said to fix it. If A and B
  stay near zero the replay is not reproducing the fault: stop and use the tester's check below.

**The result decides P1:**

| Result | What follows |
|---|---|
| Doubling stops on Responses, labelled or not | P1 as written |
| Doubling follows the doubled history on both routes | P1b: keep the route, stop the doubled reply reaching history |
| Doubling happens on both routes with clean history | Back to the owner; a route change is not the fix |

**The tester's check, available now and on 581:** set gpt-6-luna's reasoning to Low in the model editor
and repeat a long job. An explicit level moves tool turns to Responses (rule 7). This changes the
reasoning level as well as the route, so it can point to the cause but not prove it.

### P1 — gpt-6-luna at Automatic goes to Responses (headless, after P0)

- A family flag beside `chatToolsRequireNone`, for families P0 shows doubling on. Only those families
  move; sol is included only if the replay is repeated on it.
- `OpenAIRouteSelector`: Automatic with tools for a flagged family goes to Responses with a new reason,
  so the trace and the model editor say why. `ReasoningPolicy` already resolves Automatic on that route
  to the family's lowest effort, so the reasoning stays where it is today.
- Rule 4 stays: Responses refusing the model falls back to Chat Completions at `none`. Other hosts stay
  on their own route (rules 1 and 2). An explicit `none` stays on Chat Completions.
- `RepeatedReplyCollapse` stays for every other model.
- Table tests in `OpenAIRouteSelectorTests`: flagged family at Automatic, the same with a learned
  rejection, explicit `none`, explicit Low, a custom host, an unflagged family.

**As built:** `ReasoningPolicy.Family.chatDoublesReplies`, true only for ids starting `gpt-6-luna`, and
`OpenAIRouteSelector.Reason.chatDoublesReplies`, a new rule 9 between explicit `none` and the cheap default.
On the wire it is `reasoning.effort: none`, because the family's default is `medium`. gpt-6-sol, rule 4, other
hosts, explicit `none` and no-tools turns are unchanged. The new explanation string is not in the catalog yet;
the next catalog sync picks it up. A commentary-only reply on this route is asked again once: see Decisions.

**P1b, only if P0 points to history:** the part of a reply that repeats the part before it is judged on
the finished reply, and the cleaned text is what history keeps. The detector itself is a design of its
own and is not specified here: it must leave a summary, a repeated safety warning and a read-back alone,
which is why this plan does not start there.

### P2 — an offer has to be an offer (headless)

- `confirmsExpertOffer` passes only when the previous reply asks: a sentence that ends in a question mark
  and holds a person word or "escalate". A line ending "Source: …" after the question does not hide it.
- Spoken offers without a question mark ("I can get an expert if you want") also count, by a short list
  of offering openers. Reading it wrong costs one turn, since the refusal tells the model to offer.
- Invented fixtures. A yes after a real offer passes. The same words after a reply that only says
  "escalate rather than…" are refused and show no card. `SymptomDiagnosisTests` keeps passing unchanged.
- The tool description and the refusal text do not change.

**As built:** `TechnicianRequest.offersExpert`, pure, reads the previous reply a sentence at a time: a person
or escalate word, and in that same sentence a question mark or an offering phrase. A full stop inside "0.28"
does not end a sentence. Two limits are accepted, each costing one turn or one approval card: a question that
names a person without offering one ("did the supervisor sign it?") passes, and an offer split across two
sentences ("the manual says escalate. Shall I?") is refused.

### P3 — a reading's unit once (headless)

- `valueWithUnit` prints the value alone when it already ends in the unit: compared case-insensitively,
  with the unit not starting mid-word ("5 am" with "m" still prints both). This covers every print path,
  and readings already stored.
- `ReadingTool`'s `value` description asks for the number alone, without the unit.
- `value` itself is not rewritten, so what the technician reported stays as recorded. A value and unit
  that differ ("140 F" with `°F`) are left for now; the schema change is what reduces those.
- Tests on `valueWithUnit` and on the record's reading line, with and without a correction.

**As built:** `valueWithUnit` as written, tests in `JobRecordFidelityTests`. The tool's own description also
said "'value' exactly as said", which would have contradicted the schema, so it now says the number alone too.

### P4 — the tester's re-run (owed, device)

The same style of long job on the first build with P1 to P3, on gpt-6-luna at Automatic: no doubled reply,
no expert card unless asked or accepted, and each reading's unit printed once.

## Acceptance

- P0's table is filled in, with the rates, and the plan's P1 path is chosen from it.
- A reply on the chosen route says the answer once across a replay of the same length.
- A short yes passes the expert gate only after a real offer.
- No reading prints its unit twice.
- First output on the moved route is within what the owner accepts from P0's timing.

## Evidence

**P0, 2026-11-01.** gpt-6-luna on the OpenAI API, outside the app. The app's real default prompt, tool rules
and tool descriptions for the Field Assist set (64 tools, schemas simplified), its request shapes and its
layout. An invented furnace job, stubbed tools, turns of 29 to 37 messages, three closing turns in rotation.
One-off key, deleted after the runs. About 22 million input tokens, 18 million of them cached.

Three runs, because the first two did not measure what was intended:

| Run | Set-up | Result |
|---|---|---|
| 1 | Job block and passages at the top of the prompt, acknowledgment rule absent | No doubling in 40 Chat Completions runs. Not the app's layout. Over half the Responses runs lost to a harness fault; discarded |
| 2 | The app's layout: block last, rule present; four arms of 20 | Doubling reproduced. The harness's stubs ran many turns into the round limit with no reply |
| 3 | Run 2 with stubs that finish and a last round without tools; three arms of 40 | Every run ended in a reply. Table below |

Run 3, on clean history:

| Arm | Doubled | Turns with a spoken preamble | Median whole turn | Rounds per turn | Turns calling the expert tool |
|---|---|---|---|---|---|
| Chat Completions | 2 of 40 | 22 of 40 | 4.5 s | 3.5 | 8 |
| Chat Completions, acknowledgment rule removed | 0 of 40 (1 reply repeated itself mildly on one line) | 0 of 40 | 6.6 s | 4.5 | 15 |
| Responses | 0 of 40 | 0 heard, 23 `commentary` messages held back | 9.1 s | 4.2 | 7 |

Every reply from runs 2 and 3, on both kinds of history:

| Route | Doubled | Replies |
|---|---|---|
| Chat Completions | 5 | 68 |
| Responses | 0 | 57 |

- **Every doubled reply was read by eye** and had the tester's shape: the same answer or question twice, on
  a new line. Two came from turns that made no tool call, as two of the tester's did.
- **The difference is suggestive, not proven.** 5 of 68 against 0 of 57 gives p = 0.06 (Fisher, two-sided).
  Against the rule-removed arm, p = 0.16.
- **The rate is below the tester's.** 7% against 4 of 14. The replay is shorter and its job is invented, so
  the rate here does not predict the rate on a phone.
- **Two messages in one response were never seen on Responses.** Each response carried one message, so the
  plain reading of "preamble merged into the answer" is still unconfirmed. Commentary only appeared on
  rounds that called a tool.
- **Doubled history made no visible difference:** 1 of 13 clean against 2 of 15 doubled in run 2.
- **Responses is slower.** About 0.3 s to the first output of the final round, and roughly 2.2 s against
  1.3 s for each round of a turn. The stubs inflate the number of rounds, so the whole-turn figures are
  an upper bound. Nothing is spoken during those rounds, because commentary is held back.
- **Removing the rule is not free.** It stopped the preambles, added a round, and nearly doubled the calls
  to `escalate_to_expert`. It also takes away the words that fill the silence on every provider.

**Reading it against P0's table:** doubling stopped on Responses, so the first row applies and P1 stands as
written, subject to the owner accepting the latency under Acceptance, which the owner did. The tester's check with reasoning at
Low is still worth having, on a real job.

## Decisions

**Owner decision 2026-11-01: gpt-6-luna moves to Responses at Automatic (P1), accepting the slower tool
rounds and the silence during them.** This reverses the choice made in Plan KD P3, which had no probe
behind it. gpt-6-sol stays on Chat Completions, because the doubling has only been seen on luna.

**Owner decision 2026-11-01: a turn that would end in silence asks the model once more.** On Responses a final
round holding only `commentary` was an empty reply, and nothing re-asked, so moving luna raised the exposure.
P0 did not see it on luna. Built outside the phases above: `StallReplyPolicy.isSilent`, one re-ask per turn
shared with the stall, on the three paths that keep an empty reply (Chat Completions, Responses, ChatGPT).
Anthropic and Gemini throw on one, which is how the cascade hops, so they are left alone. A second empty reply
ends on what the tools answered, if any did. `new_topic` is exempt, because it asks for the silence. Not yet
tried against a live model.

## Open

- **Not in this plan:** when a manual says "replace if outside specification" and gives no figure, may
  the model apply a labelled web figure to a reading it has been told? In the report it found one, then
  would not answer a plain yes-or-no. Plan KE's refusal text sends that turn to an expert offer, so the
  question stays unanswered. This is a product decision for the owner, not a fix.
- Whether gpt-6-sol doubles the same way. Only gpt-6-luna has been reported.
