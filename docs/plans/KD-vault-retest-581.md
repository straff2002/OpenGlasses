# Plan KD — Vault Retest on 581 (jobs that end themselves, chains nobody asked for, 4/0, printed pages, the app hearing itself)

**Status:** 🚧 P0 built 2026-10-30 (headless) — all eight P0 items; P1–P3 and the partner's re-run of P0
on the phone are owed. See "P0 as built" below. Drafted from the partner's structured retest of
the code-book vault on build 581 (2026-10-29: five jobs, table questions by number and in plain
words, two rule chains, glasses then phone). Every cause below was traced to code on main at
597; nothing merged between 581 and 597 touches `field_session`, `rule_chain`, `table_lookup`,
`manual_figure`, `show_source` or the barge-in policy.
**Track:** Field Assist first (the partner's code-book vault and its pilot on the phone without
glasses), app-wide underneath: any Direct-mode turn over Bluetooth output with the phone's mic,
any vault table with AWG aught sizes, any book with printed page numbers.
**Related:** Plan [JW](JW-vault-test-findings.md) (printed page labels, `show_source` marking,
chains that stop — this plan picks up what the retest showed it left), Plan
[JJ](JJ-table-lookup-and-rule-chains.md) (`table_lookup`, `rule_chain`, `ChainRunner`), Plan
[FE](FE-agent-voice-reliability-and-feedback.md) (`BargeInPolicy`), Plan [FO](FO-guided-job-flow-and-job-tab.md) (the app's own
job-number question), Plan [IN](IN-verifiable-code-lookup.md) (`show_source`).

---

## Why

The table work from JW held up. Rating and correction-factor tables answered through
`table_lookup`, by number and in plain words, and a 42 °C question was refused rather than
interpolated. What failed was the control around those answers: jobs that ended themselves, chains
that ran on answers nobody gave, a conductor size swapped for another, a printed page that was
not the page asked for, and — on the glasses — the app answering its own voice. The partner's
pilot will run on the phone without glasses and without chains. P0 covers what that pilot hits:
the guards that writing "don't use chains" in the instructions cannot give.

## Findings and causes

1. **Naming a job ended it** (11:32, 12:32). `field_session end` accepts any outcome with no check
   that the technician asked (`FieldSessionTool.endSession`). The description says "an active job
   keeps its vault until ended", so the model ended a job to switch to a vault it misread from
   the job's name. A job "name" can only go in `asset_id`, and only at `start`, so the model also
   ended and restarted a job to rename it. The app's own job-number question missed both replies:
   `JobReferenceClassifier` has no "name"/"named"/"call it" carrier and caps a reply at 4 words /
   24 characters. Typed turns never reach the job intake (`sendTextMessage` skips it).
2. **The vault "mismatch"** (11:36) was a trailing "vault" in the name the model passed (copied
   from the app's own reply), not the dash; matching already strips punctuation.
3. **Chains started and listed unasked** (11:38, 12:33). The RULE CHAINS prompt block says
   "offer it and start it with rule_chain 'start'" on every turn, and `start` has no check on
   what the technician asked.
4. **One input answered several chain steps** (13:25, 13:30, 13:31, 13:33, 13:37). `answer` takes
   only a value — no step, no turn check — and every question result ends "Call 'answer' with
   what they say", so the model replays the last thing said into the next step. A restart
   "reused" earlier answers the same way: the code starts fresh, the model copied from history.
   The ACTIVE RULE CHAIN prompt block is built once per turn and went stale after a switch.
5. **The conduit-fill table's column was ambiguous** (13:27): the chain names its column by trade size alone,
   and each size sits under several groups. Chain data (the partner's file) plus a missing
   check at start.
6. **4/0 answered as No. 4** (12:52). `TableLookup.tokens()` splits "4/0" into "4" and "0"; the
   numeric step matches row 4, and the leftover "0" is dropped as a word no row prints. The
   result does not say it matched by number. No AWG aught normalisation exists, and the dictation
   glossary has "4/0" but no spoken form ("four aught") and not "0000".
7. **"Printed page 57" opened PDF page 57.** `manual_figure` describes `page` as printed but
   filters on the PDF page; the JW folio map (`PageLabelMap.physical(forPrinted:)`) is only used by
   tests. The reply did not say which page opened, so the model claimed the printed one.
8. **Pages opened before the answer.** The model called `show_source` because tool results invite
   it ("Offer to show… with show_source"), and `ShowSourceTool` does not check that the turn asked
   to see anything. An unrelated table retrieved on the turn can be attached to the model as its
   picture and become the "last shown" figure.
9. **The app heard its own voice** (12:52:40, 13:12:01). The phone's mic, the glasses' speakers on
   A2DP, no echo cancellation on that path. `MicRoutePolicy.isOpenSpeaker` counts only the phone's
   loudspeaker, and `BargeInPolicy`'s overlap test misses numbers ("2024–21" heard as "2000 2420")
   and two-edit near-homophones ("ampacity" as "capacity"). After every answer the app reopens
   the mic for a follow-up; there is no single-question mode.
10. **The microphone stayed off after a background start was refused** (13:04, 13:14). The
    end-of-turn re-arm ran in the second the app went to the background; iOS refused it (`'what'`)
    three times. "Tap Test Microphone to restart" was never cleared when the listener came back,
    names a button that screen does not have, and the status said Ready meanwhile.
11. **Doubled reply text** sits inside one model response. Automatic routing sends gpt-6-luna's
    tool turns to Chat Completions, which merges its preamble with the answer.

## Phases

### P0 — the phone-only pilot (headless)

- **Ending a job needs the technician's words.** `end` is refused — always for `cancelled`, and
  for any outcome on a voice or typed turn — unless the technician's words this turn say end,
  close, finish, cancel or wrap up. The refusal tells the model to ask. The description no longer
  suggests ending a job to change its vault or name.
- **Renaming an open job.** A `set_job_details` action sets the job's name (asset) and reference on
  the open job; `set_job_reference` ignores a repeat of the value it already holds.
- **The job-number question hears a name.** `JobReferenceClassifier` takes "name", "named", "job
  name", "call it" and "number" carriers, and allows about 6 words / 40 characters once a carrier
  is stripped (the read-back still catches a mishearing). Typed turns go through the same intake.
  The JOB NUMBER prompt line says to record the technician's answer when they give one.
- **Vault names** match with a leading "the" and a trailing "vault" removed.
- **Chains start on request only.** `rule_chain start` is refused unless the technician's words
  this turn name the chain or ask to run, start or use a chain, or answer yes to a chain the
  assistant offered last turn. The prompt block says "offer it by name; start it only when they
  ask".
- **4/0 is 4/0.** A pure `AWGSize` canonical form (1/0…4/0 ⇄ 0, 00, 000, 0000 ⇄ "one…four aught",
  "ought", "oh", and "out" next to a conductor word) is used by row matching before anything else,
  and as a dictation post-pass. Spoken forms and the "0000" spellings go into the electrical
  glossary. Row matching never drops a numeric leftover, and a match found by number rather than
  by the row's name says so: "asked for 4/0, matched row 4 by number — not the same row".
- **Printed pages.** `manual_figure` takes `printed_page` (also inferred when the words say
  "printed page"), resolved per document through the page-label map; an unknown label is refused,
  not guessed. The reply names both: "PDF page 63 (printed page 57)".
- **Pages open on request.** `show_source` opens nothing unless the turn asked to see a page,
  table or source; otherwise it returns "offer it". Tool results stop inviting it unasked.

**P0 as built (2026-10-30).** The guards gate only the model's tool call; the app's own paths (the
Job tab's close, `JobCloseSequence`'s screen route, an access withdrawal, a tapped citation) never
pass through the tools. `TechnicianRequest` is the one pure reader of the turn's words, and
`TechnicianWords.previousReply()` is what a bare "yes" answers.

- `field_session end` needs end/close/finish/cancel/wrap-up words, or a short yes after a reply that
  asked about ending; a refused end records no passed check. A turn with no captured words (an
  agent turn, a live session) may still end a job, as before, but never cancel one.
- `set_job_details` sets the open job's name (its asset) and reference in place, logged as
  `job_name_set`; `set_job_reference` with the number it holds changes and logs nothing.
- `JobReferenceClassifier` takes "name", "named", "job name", "call it", "it's called" and "drop
  number" carriers, and six words / forty characters after a carrier. "Drop number" is only ever a
  leading carrier, so a voltage-drop question never reaches it, and the read-back still runs. Typed
  turns answer the job-number question through `GuidedJobFlow.handleTypedAnswer`, recorded as typed
  (no read-back, as the Job tab's field); only the job number, not the unit or evidence questions.
- Vault names match with a leading "the" and a trailing "vault" left out, on both sides.
- `rule_chain start` (and a start that would replace a running chain) needs the chain named as a
  run of its words, or its words with a run verb, or "chain" with a run verb, or a short yes to a
  chain the last reply named or the proposal waiting for go. With no captured words it is not gated.
- `AWGSize` reads 1/0–4/0 in every printed and spoken form; row matching compares it before the
  exact, number and word steps, and an aught size no row prints is not found. A number left over is
  never dropped. A found row says how it was found (`RowBasis`), and a number or word match that is
  not the row asked says so. `table_lookup` refuses a bare "4" when the words said an aught size.
  The electrical dictation pass writes spoken sizes as printed; the glossary has the spoken forms.
- `manual_figure` takes `printed_page` (or "printed page N" in the words), resolved per manual
  through its page labels and the multi-manual choice; an unknown or repeated label is refused, and
  a page reply names both: "Opened PDF page 63 (printed page 57)".
- `show_source` opens nothing unless the words ask to see a page, table or source; results say
  "offer to show the page (open it with show_source only if they ask)".

### P1 — voice

- Phone mic with Bluetooth output (no echo cancellation) is treated like the loudspeaker: only
  "stop" and the wake phrase interrupt the reply.
- The echo test tolerates numbers and two-edit long words.
- Single-question mode: after the answer the conversation ends instead of reopening the mic; a
  distinct end-of-listening cue and an optional spoken "Listening" at the start. A setting, on by
  default for Field Assist (decision owed).
- The mic-failure message is cleared when the listener starts, names a control that exists, and
  the status does not say Ready while the listener is down; a refused background start re-arms on
  the next foreground or route event.

### P2 — chains that only move on what was said

- `answer` names the pending step; an answer in the same turn the question was asked (or the
  chain started) is refused; at most one accepted answer per turn; a question result ends the
  turn with tools withheld.
- Every result opens with "Running now: <name>, step k of n"; the prompt block says tool results
  supersede it.
- At start, every lookup's column is resolved against the extracted headings; an ambiguous one
  is refused with its candidates (the conduit-fill case — the partner's chain file also needs the
  full heading).
- `list` is spoken and shown verbatim.

### P3 — polish

- A repeated last paragraph is collapsed before speech and history; consider Responses for the
  gpt-6-luna family's tool turns.
- A retrieved table is attached to the model only when its label is the one asked or looked up;
  only a figure shown on the phone becomes the last shown.

## Owed

- The partner's re-run of P0 on the phone (job naming, 4/0 by voice, printed page, no chain or
  page unasked).
- The partner's chain file names the conduit-fill table's column by full heading (with P2's check).
- Decision: single-question mode on by default for Field Assist.
