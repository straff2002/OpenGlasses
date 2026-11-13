# Plan LP — Agent Manners (ask once before a plan, say what's happening, don't start over by accident)

**Status:** 🚧 Built 2026-11-13 (P0–P1); P2 device pass owed. The four [decisions](#decisions-for-greig)
were taken 2026-11-13, as recommended. What was built, and every deviation, is under [As built](#as-built).
**Track:** Agent Mode and the remote agents — how multi-step work asks, talks and stops. Spoken first; the lens
and the phone already show more.
**Builds on:** `AgentRunner`, `PlanValidator`, `PlanExecutor` (`Services/Agent/`), `ToolConfirmationCoordinator` and
bound approvals (`ApprovalGrant`, `approvalGrants.binding`), `ToolAuthorizationPolicy` and `ToolEffectClassifier`,
`PromptInjectionPolicy.actionSummary`, `AgentSessionService`, `CustomAgentHarness`, `AgentSummarizer`,
`AsyncDeliveryPhrasing`, `ToolLookupTool`, `SessionSearchTool`, `BrainTool` recall and `FTSQueryBuilder`.
**Sits beside:** Plan [LO](LO-spoken-manners.md) (spoken manners for ordinary replies), Plan
[LA](LA-quiet-after-actions.md) (a tone after a finished action), Plan [KL](KL-say-why-and-keep-the-tools.md).

---

## Trigger

A review of how other agent products instruct their models (browser agents, desktop agents, coding agents with a
voice front end) kept returning to four habits: ask for permission **once**, after the preparation and before
anything runs, about something concrete; say in one sentence what is about to happen; stay quiet while nothing
changes; and treat a new instruction during a running job as a correction to that job. Checked against our
code, Agent Mode does the opposite of the first two and the last:

- A three-step plan with two messages in it asks twice, mid-plan, and the second ask is refused outright if the
  first is still on screen.
- Nothing is spoken when a plan starts. "Planning 3 steps" and "Step 2 of 3" go to the lens only; the wearer
  hears "Still working on that." after ten seconds and then the summary.
- Saying "start a job to …" while another remote job is running silently replaces it.

## Outcome

- "Text Sam I'm running late and lock the front door." (Agent Mode) → "I'll text Sam 'running late' and lock the
  front door. OK?" → "Yes." → both run, one after the other, with no further question. "Done — I texted Sam and
  locked the front door."
- The same request, where the plan's model then tries to text *Alex* instead of Sam → the approval doesn't cover
  it: that step asks on its own.
- A five-step research plan → "I'll check three suppliers' prices and put them in a note." then quiet, then the
  summary. No "Step 2 of 5" aloud.
- While a remote coding job runs: "Also make the button blue." → passed to the running job as a follow-up where
  the harness takes one; otherwise "That job's still running. Stop it and start this one instead?".
- A remote job that asks the same question three times → it's asked once; the third time, "It keeps asking which
  branch to use. Do you want me to stop it?".
- An approval card for an unreviewed tool says what goes where: "Send your location to 'trip-planner' (an
  external tool this app hasn't reviewed)." Not "Run trip_planner: lat=…, lon=…".
- "Is there a tool for parking?" → `lookup_tools` with a keyword finds `parking` and the MCP server's
  `find_parking`.

## What exists, and what doesn't

**Exists (verified against `main` at 69c29f9d0):**
- `PlanExecutor.execute` runs each step through `router.executeRoot` (`Agent/PlanExecutor.swift:46–60`); a step the
  router confirms asks through `coordinator.requestApproval` (`NativeTools/NativeToolRouter.swift:325–341`); a decline
  is `.rejected` and aborts the rest (`PlanExecutor.swift:75–81`).
- `PlanValidator` marks irreversible steps `requiresConfirmation` (`PlanValidator.swift:29–30`). **Nothing reads the
  flag.**
- `ToolConfirmationCoordinator.ask` returns `.denied` when an approval is already pending (`:119`). Bound grants
  are single-use, bound to seam, tool, definition digest, argument digest and session, with a 120 s lifetime
  (`Security/ApprovalGrant.swift:104–133, 139, 241–246`), issued only from a live prompt (`:134–149` of the
  coordinator) and spent against the call as dispatched (`NativeToolRouter.swift:352–363`).
- `AgentRunner` narrates "Planning N step(s)" and "Step i of N — <rationale>" through `onNarrate`, which AppState
  sends to `glassesDisplay.showNotification` only (`App/OpenGlassesApp.swift:3164–3170`). The closing `summary`
  ("Done — I a, b and c." / "I …, then stopped — <reason>.", `AgentRunner.swift:65–75`) is the spoken reply.
- The router's ten-second timer speaks `AsyncDeliveryPhrasing`'s "Still working on that." / "Still working — almost
  there." in Direct mode (`NativeToolRouter.swift:640–648`, `Live/AsyncDeliveryPhrasing.swift:67–69`).
- Remote jobs: `AgentPollingPolicy` polls every 4 s with backoff; `CustomAgentHarness` yields nothing while
  `.queued`/`.running` and a question once per identity (`Adapters/CustomAgentHarness.swift:226–238`), **but that
  dedupe resets when the job goes back to running**, so a recurring question is announced each time.
  `AgentSummarizer.narration` speaks progress, failures, PRs and errors; the result and lost contact once each.
- A follow-up during a run is a new turn. It reaches the job only as `agent_control` answer/confirm while a question
  is pending (`AgentSessionService.swift:581–585`). **A new `start` replaces the active run**: `dispatch` has no
  in-flight guard and `subscribe` cancels the old event task (`AgentSessionService.swift:199–214, 228`).
- `PromptInjectionPolicy.actionSummary` names recipient and body for messages and calls (`:127–136`) and "clinical
  data" for `medical_export` (`:153`); anything else is "Run <tool>: k=v, …" with up to four arguments (`:165–180`).
  `approvalSummary` adds "— using an external tool this app hasn't reviewed" on external seams.
- `lookup_tools` takes exact names only, up to eight (`NativeTools/ToolLookupTool.swift:22–38`). `onDemandToolGuide`
  summarises native tools and names MCP tools without their descriptions, on purpose (a third party's text is
  not raised into the system prompt).
- `session_search` ("Search past conversations…", `query` + `max_results`) splits on spaces and substring-matches
  every word, "discussed" and "yesterday" included (`SessionSearchTool.swift:7–21, 39, 60–73`). Brain `recall` is
  also described as searching past conversations (`BrainTool.swift:17–19`) and goes through `FTSQueryBuilder`, which
  strips meta-words and reads a date window (`Memory/RecallModels.swift:43–63`).

**Doesn't exist:** a plan-level approval, a spoken plan opener, any handling of a follow-up during a run other than
as a fresh turn, recurrence detection across a remote job's continuation, data kinds in the approval copy, a
keyword tool lookup.

## Design

### 1 · Ask once, before the plan runs (`PlanApproval`, pure)

After `PlanValidator`, the plan's steps that would ask (`ToolAuthorizationPolicy.evaluate` returns `.confirm`,
evaluated with the step's exact arguments, **not** the unused `requiresConfirmation` flag) are collected into one
`PlanApproval`: one spoken sentence (`PlanApprovalPhraser`, from each step's `actionSummary`, joined: "I'll text Sam
'running late' and lock the front door. OK?") and one card listing each action.

A yes issues one bound grant **per step**, each bound exactly as today (seam, tool, definition digest, argument
digest, session), living as long as the plan runs rather than 120 s. A step whose arguments changed by dispatch
finds no matching grant and asks on its own, as today. A no aborts the plan before any step runs. Steps that
wouldn't ask are untouched. A plan with one confirmable step asks exactly as now.

Nothing changes outside Agent Mode plans: a Direct turn's single call still asks at the call.

### 2 · Say what's about to happen, then stay quiet (`PlanOpener`, pure)

A plan of two or more steps opens with one spoken sentence built from the step rationales (or the
`PlanApproval` sentence, when there is one — never both). It takes the place of the first "Still working on that."
for that turn. "Step i of N" stays on the lens. The summary is unchanged.

### 3 · A follow-up during a remote job (`AgentFollowUpRouting`, pure)

When a remote job is running (not awaiting input) and the wearer's turn would `start` another:

- If the harness accepts follow-up messages, the turn is sent to the running job as one, and "Passed that on."
  is said.
- Otherwise the start asks: "That job's still running. Stop it and start this one instead?". Yes stops the old job
  explicitly (its stop is recorded, not a silent cancel) and starts the new one.

`AgentSessionService.dispatch` gains the in-flight guard either way.

### 4 · The same blocker, three times (`RecurringBlocker`, pure)

`CustomAgentHarness` keeps a count per question identity (and per normalised error text) for the life of the job,
not just until it next runs. The first time it's announced as now; the second time it isn't; the third time the
wearer is asked whether to stop the job. A fresh identity resets nothing else.

### 5 · Approval copy that says what goes where

`actionSummary`'s generic branch names the **kind** of data in the arguments when it can tell (location from
lat/lon or an address, a photo or file, health, a contact, a message body) and the **destination** (the server's
label, the host, the recipient), e.g. "Send your location to 'trip-planner'", instead of listing keys and values.
Unknown arguments still fall back to the current form. Pure, table-driven.

### 6 · Drafting a message for the wearer

`send_message`, `send_via` and the email tool descriptions gain: write as the wearer, in their words; never add a
fact they didn't give; when the reply could go either way (accept or decline, yes or no), ask which in a few words
before drafting. The body that will be sent is kept apart from anything said around it, so the read-back reads the
body only.

### 7 · Finding tools and past conversations

- `lookup_tools` gains a `query`: matched against tool names and descriptions, native and MCP, returning up to
  five names with one line each. MCP descriptions come back inside the untrusted-output envelope, as tool output,
  never into the system prompt.
- `session_search` runs its query through the same meta-word stripping as `FTSQueryBuilder`. The two descriptions
  are made distinct: `session_search` finds a conversation by topic words; `brain recall` answers a question about
  what was said, including "yesterday" and "last week".

## Decisions for Greig

Taken 2026-11-13, as recommended (1–4 below). Decision 1's grant lifetime is "as long as the plan runs",
capped at five minutes (`PlanApproval.grantLifetimeCeiling`), with every unspent grant revoked when the plan
ends, stops at a step, is declined or is cancelled. Decision 4 leaves a saved writing style out of this plan:
it is memory, and it waits on Plan LN's write gate.


1. **One ask for the whole plan.** *Recommended:* as §1, one spoken sentence and one card, with a grant per step
   bound to its exact arguments. Alternative: keep per-step asks but queue them instead of refusing the second.
2. **Spoken opener threshold.** *Recommended:* plans of two or more steps. Alternative: only plans expected to run
   past the ten-second "still working" line.
3. **A new job while one runs.** *Recommended:* steer when the harness can, otherwise ask (§3). Alternative: always
   ask, never steer.
4. **A saved writing style for drafts** (learn the wearer's tone from edits they make before sending).
   *Recommended:* not in this plan; it is memory, and it should wait for Plan LN's write gate.

## Phases (one PR)

### P0 — the pure core (headless)
`PlanApproval` + `PlanApprovalPhraser`, `PlanOpener`, `AgentFollowUpRouting`, `RecurringBlocker`, the `actionSummary`
data-kind table, the `lookup_tools` matcher. Tests: two confirmable steps → one sentence and two grants; a step whose
arguments change → no grant matches; a no → nothing runs; a one-step plan unchanged; opener present for 2+ steps
and never alongside an approval sentence; follow-up routing for each harness capability; the third repeat asks; data
kinds for location, photo, health and unknown; keyword lookup across native and MCP, MCP text enveloped.

### P1 — wired (headless)
`AgentRunner` asks through the coordinator once and hands the grants to `PlanExecutor`; the grant lifetime follows
the plan; the opener replaces the first "still working" line; `AgentSessionService.dispatch` guard; harness counts;
tool descriptions (§6, §7); `session_search` stripping. Tests: an end-to-end plan with two messages asks once; a
`start` during a run asks; the stripped `session_search` finds the boiler thread from "what did we discuss about the boiler".

### P2 — device pass (owed)
Spoken checks on the glasses: the two-action plan, a five-step research plan, a follow-up to a running remote job,
a recurring question, an MCP approval card.

## Risks

- **A plan-level yes that covers more than the wearer heard.** Every action is in the sentence and on the card, and
  each grant is bound to its exact arguments; a long plan (more than three confirmable steps) asks in two halves.
- **A spoken opener plus LA's quiet tone** for a plan of actions: the opener is skipped when Quiet after actions is
  on and every step is an action LA would end quietly.
- **Harness follow-up support varies.** The routing is per capability; unknown means ask.

## As built

Built 2026-11-13, P0 and P1 together, headless. P2 (the device pass) is owed.

**§1 Ask once (`Agent/PlanApproval.swift`).** `NativeToolRouter.planPreflight` works out each step's verdict
in the order dispatch uses — feature and expert gates, the MCP egress screen, then
`ToolAuthorizationPolicy.evaluate` with the step's exact arguments (the ladder and the effect-class floor
after it, through one shared `authorizationDecision`), recording nothing. `PlanValidator.requiresConfirmation`
is not read. `PlanApproval.shape` gathers the `.confirm` steps: none → nothing; one → that step asks at its own
call exactly as before; two or three → one ask; four or more → two halves, asked one after the other before any
step runs ("Then I'll …" for the second). `ToolConfirmationCoordinator.requestPlanApproval` asks once (consent
register consulted as for any ask; refused with `.busy` when another card is up), and on a yes issues one grant
per step, bound exactly as the step's call would bind it (seam, tool, definition digest, argument digest,
session) and additionally **scoped to the plan run** (`ApprovalGrant.scope`): a scoped grant is spent only by a
call presenting the same scope, an unscoped one only by a call presenting none (`scopeMismatch`, checked
without spending). `PlanExecutor` hands each step its own grant through the task-local
`PlanApprovalScope.stepGrant`; the router's `.confirm` branch redeems it against the call as it stands at
dispatch (re-derived profile) for a root call only, and anything that does not match spends nothing, is written
to the authorization ring, and the call asks on its own. A no (to either half), a busy surface or withdrawn
consent returns before any step runs. `AgentRunner` revokes the run's unspent grants in a `defer`
(`ApprovalGrantStore.revoke(scope:)`), so they die with the plan however it ends.

**§2 Opener (`Agent/PlanOpener.swift`).** Two or more steps: "I'll a, b and c." from the rationales (three
steps or fewer, all with a rationale), else the planner's goal when it is not just the request echoed back,
else "I'll work through this in N steps.". None when the plan is asking first, or when Quiet after actions is
on and every step passes `QuietTurnJudge.holdsPreamble` (a reviewed native tool that changes something —
Plan LA's own before-it-runs test). Spoken through a new `LLMService.onAgentSpeak` (AppState → TTS,
`.progress`, Direct mode only). When the opener or the ask was said, the router's still-working timer skips its
first line for that plan (`PlanNarrationScope`, inherited by the timer's task). "Step i of N" stays on the lens.

**§3 Follow-up during a job (`AgentHarness/AgentFollowUpRouting.swift`).** `AgentHarness.followUpSupport` +
`sendFollowUp` (defaults `.unknown` / throws). `AgentSessionService.startOrSteer`: nothing running → start;
running and `.accepts` → follow-up, "Passed that on to the job that's already running."; running with
`.unsupported`/`.unknown`, or awaiting an answer → ask "That job's still running. Stop it and start this one
instead?" through the wearer's consent card. A yes cancels the old job at the far end and finishes it as a
local cancellation (its "Cancelled the agent run." delivery is recorded before the new dispatch), then starts
the new one; a cancel that fails starts nothing. `dispatch` gained the in-flight guard (`.runInFlight`).
`code_agent start` goes through `startOrSteer`.

**§4 Recurring blocker (`AgentHarness/RecurringBlocker.swift`).** Counted for the life of the job, reset only
by a new dispatch: 1st said, 2nd kept (still pending and answerable), 3rd asks "It keeps asking: “…” Do you
want me to stop it?"; a yes is an explicit cancel of that job only.

**§5 Approval copy (`Security/ActionDataSummary.swift`).** For an external seam, `approvalSummary` names
the data kinds (location coordinates, an address, a photo, a file, health data, contact details, a message, some
text) and the destination (an MCP server's label from the qualified name, a custom tool's name, the gateway):
"Send location coordinates to 'trip-planner' (an external tool this app hasn't reviewed)". Every argument the
table cannot place is still shown as `key=value`; with nothing recognised, today's form stays.

**§6 Drafting.** `MessageDraftingRules` in `send_message` and `send_via` (which is also the email tool):
write as the user, add no fact, ask accept/decline when ambiguous, body holds only the words sent and is the
only thing read back.

**§7 Tools and conversations.** `lookup_tools` takes a `query` (names no longer required): recall's
meta-word stripping plus a small lookup list, a light stem, name hits over description hits, at most five
names with one line each; MCP lines inside the untrusted-output envelope. `FTSQueryBuilder.searchTerms` is the
shared stripping; `session_search` uses it (a date with no topic word lists that window's conversations).
`session_search` and brain `recall` now describe themselves apart.

**Deviations.**
- §4: the count lives in `AgentSessionService`, not `CustomAgentHarness`, and is keyed by the question's
  normalised words rather than its identity. A re-asked question gets a new derived identity every time the
  job runs again (correctly — a reply must answer that ask), so identity can never see the repeat; counting in
  the session covers every harness. "Normalised error text" is a failed command (`commandRun(ok: false)`):
  the session's `.error` event is terminal, so it cannot recur within a job.
- §4 changes a Plan FE P1 expectation on purpose: two questions with the same words and different ids are
  both surfaced and answerable, but the words are now said once (`AgentQuestionReplyTests` updated). A
  revision of the pending question (same id) is still said again, uncounted.
- §4 ask quotes the blocker ("It keeps asking: “Which branch should I use?” …") rather than paraphrasing it.
- §3: no shipping harness declares a follow-up channel (the custom endpoint shape has none; it says
  `.unsupported`), so today every live case asks; the steer path is in place and tested with a fake.
- §3: a job we have lost contact with (and said so) is not "running" for this purpose — it can be neither
  steered nor stopped — so a new start goes ahead as before.
- §5: coordinates read "location coordinates", not "your location": the table cannot tell whose they are.
  The data-kind form is used only on external seams; native copy is unchanged, since "Send …" would misname a
  note or a timer.
- §7: `lookup_tools` by name still returns MCP definitions as JSON outside the envelope, as before; only the
  new keyword path envelopes.
- Risks: the two halves are both asked before the first step, so a no to either still means nothing ran.

**New user-facing localizable strings:** none (the card shows the joined summaries verbatim, through the
existing `Text(pending.summary)`).

## Out of scope

- A `say_progress` tool for the model. `PlanExecutor` runs a validated plan without the model in between, so §2's
  deterministic opener covers it; a model-driven narration channel can follow if Agent Mode moves to open-ended
  loops.
- Same-name people in the people tool (`SocialContextStore` merges two Sams): Plan [LN](LN-memory-manners.md)
  decision 4.
