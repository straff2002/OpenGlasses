# Plan LP — Agent Manners (ask once before a plan, say what's happening, don't start over by accident)

**Status:** 📝 Drafted 2026-11-12. Nothing built. The [decisions](#decisions-for-greig-open) below are
recommendations and are still open.
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

## Decisions for Greig (open)

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

## Out of scope

- A `say_progress` tool for the model. `PlanExecutor` runs a validated plan without the model in between, so §2's
  deterministic opener covers it; a model-driven narration channel can follow if Agent Mode moves to open-ended
  loops.
- Same-name people in the people tool (`SocialContextStore` merges two Sams): Plan [LN](LN-memory-manners.md)
  decision 4.
