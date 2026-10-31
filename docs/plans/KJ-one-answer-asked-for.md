# Plan KJ — One Answer, Asked For (a reply said once, an offer that was an offer, a reading's unit once)

**Status:** 📝 Drafted 2026-11-01 from a tester's report on build 581. Nothing built. P0 is a live probe and
needs an OpenAI API key for the session; P1 waits on it. P2 and P3 are headless and can go first.
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
     back a message labelled `commentary` (`ResponsesTranslator.isCommentary`), if the API route labels
     it. Whether it does for this model is unknown.
   - A doubled reply goes into history as it came. The model may be copying its own earlier replies,
     which the probe tests, because a route change would not stop that.
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

### P3 — a reading's unit once (headless)

- `valueWithUnit` prints the value alone when it already ends in the unit: compared case-insensitively,
  with the unit not starting mid-word ("5 am" with "m" still prints both). This covers every print path,
  and readings already stored.
- `ReadingTool`'s `value` description asks for the number alone, without the unit.
- `value` itself is not rewritten, so what the technician reported stays as recorded. A value and unit
  that differ ("140 F" with `°F`) are left for now; the schema change is what reduces those.
- Tests on `valueWithUnit` and on the record's reading line, with and without a correction.

### P4 — the tester's re-run (owed, device)

The same style of long job on the first build with P1 to P3, on gpt-6-luna at Automatic: no doubled reply,
no expert card unless asked or accepted, and each reading's unit printed once.

## Acceptance

- P0's table is filled in, with the rates, and the plan's P1 path is chosen from it.
- A reply on the chosen route says the answer once across a replay of the same length.
- A short yes passes the expert gate only after a real offer.
- No reading prints its unit twice.
- First output on the moved route is within what the owner accepts from P0's timing.

## Decisions

Recorded here when taken. The owner kept gpt-6-luna on Chat Completions in Plan KD P3, with no probe
behind that choice either way; this plan asks to revisit it on P0's result.

## Open

- **Not in this plan:** when a manual says "replace if outside specification" and gives no figure, may
  the model apply a labelled web figure to a reading it has been told? In the report it found one, then
  would not answer a plain yes-or-no. Plan KE's refusal text sends that turn to an expert offer, so the
  question stays unanswered. This is a product decision for the owner, not a fix.
- Whether gpt-6-sol doubles the same way. Only gpt-6-luna has been reported.
