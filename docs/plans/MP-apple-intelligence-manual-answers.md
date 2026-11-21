# Plan MP — Apple Intelligence Answers From the Manuals

**Status:** 📝 Drafted 2026-11-20 · `ManualReadingCheck` built 2026-11-21 under [Plan MQ](MQ-local-model-tool-harness-and-qualification.md) P0 (`Services/FieldAssist/ManualReadingCheck.swift`, with `ManualReading`); the rest of P0 and P1–P3 not built · 9 decisions below, each with a recommendation

Apple Intelligence is the model a Field Assist technician should be able to use without a key, a
download or a third-party processor. Today it cannot answer a manual question, by design. This plan
gives it two ways to: **Apple's Private Cloud Compute model when the phone is online and the
day's allowance lasts**, and **a retrieve-then-read turn on the on-device model otherwise**. In
both, the app finds the passages and checks the answer against them; the model only reads.

Background research: [iOS local model tool calling](../../reports/iOS%20local%20model%20tool%20calling.md)
(2026-11-20) and its notes in `research_notes/iOS local model tool calling/`.

## Why it doesn't work today

A tester set Apple Intelligence as the model and asked a manual question in a Field Assist job; it
did not answer from the manual. That is the shipped design ([Plan JD](JD-apple-intelligence-tools.md),
window follow-up of 2026-10-20), not a model fault:

- The on-device model has a **4,096-token window** shared by instructions, every tool definition,
  the history and the answer. The lean on-device prompt is about 1,000 tokens and the tool
  definitions get 1,500 (`AppleOnDeviceToolSet.definitionBudgetTokens`).
- `manual_lookup` is **not offered** on this path: one lookup returns about 3,000 characters, which
  does not fit beside the rest (`AppleOnDeviceToolSet.fieldAssistPriority`).
- While a job is open, a job turn is **handed to any other configured model** with the sentence
  "Apple Intelligence can't hold the manuals" (`OnDeviceJobRoutePolicy`).
- With nothing else configured, the instructions tell the model to say that **manual answers need
  a cloud model** and not to answer from memory (`AppleOnDeviceInstructions.manualsNote`).

Tool calling itself is not the problem on this path. Unlike the MLX path, it uses the framework's
own `Tool` protocol with a `GenerationSchema` per tool (`AppleToolBridge`), so calls are
schema-constrained. The tool-harness changes the research recommends for MLX and GGUF do not apply
here.

## What iOS 27 adds

At WWDC26 Apple opened its server model on Private Cloud Compute (PCC) to the Foundation Models
framework. As reported (**every point to be confirmed against Apple's documentation in P0** — the
sources so far are Apple's session pages and secondary write-ups):

| Fact | As reported | Source |
|---|---|---|
| API | `PrivateCloudComputeLanguageModel`, a separate model type; the same `Instructions`, `@Generable` types and `Tool` conformers work with it | [Apple WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/); [ivanmagda.dev](https://ivanmagda.dev/posts/foundation-models-private-cloud-compute/) |
| Context | 32K tokens, with reasoning levels; the on-device model stays at 4,096 (some posts report 8,192 on the newest phones; Apple's lab answer says 4,096) | [blakecrosley.com](https://blakecrosley.com/blog/foundation-models-private-cloud-compute); [Apple WWDC26 lab 8121](https://developer.apple.com/videos/play/wwdc2026/8121/) |
| Allowance | A **daily limit per user**, tied to the user's account and higher for iCloud+ subscribers; the on-device model has no request limit | [Apple WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/); [Medium](https://medium.com/@sairamkotha/apples-free-cloud-ai-for-developers-how-the-daily-quota-really-works-feb2370bcb94) |
| Reading the allowance | `quotaUsage.isLimitReached` on the model, separate from `availability` (a model can read as available with the day's allowance spent); a request over the limit throws `quotaLimitReached`. One macOS 27 beta report names `rateLimited` instead | [wwdc.ai summary of 319](https://wwdc.ai/2026/319); [Apple Developer Forums](https://developer.apple.com/forums/topics/machine-learning-and-ai/machine-learning-and-ai-foundation-models) |
| Testing | Xcode scheme option "Simulate Apple Foundation Models Availability" includes quota states (limit reached, nearing limit) | [Medium](https://medium.com/@sairamkotha/apples-free-cloud-ai-for-developers-how-the-daily-quota-really-works-feb2370bcb94) |
| Access | Managed entitlement `com.apple.developer.private-cloud-compute`, requested from Apple; free for developers in the App Store Small Business Program with under 2 million first-time downloads; paid access for others announced for later | [socket-link/ampere #757](https://github.com/socket-link/ampere/issues/757); [creuto.com](https://creuto.com/foundation-models-framework-ios-27-apps) |
| Platform | iOS 27 / macOS 27 and later, network required | [ivanmagda.dev](https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/) |

Our deployment target is iOS 26.0 (`project.base.yml`), so every PCC call sits behind
`@available(iOS 27.0, *)` and an iOS 26 phone simply never takes that route.

## Design

### One reader, two models

A manual question on the Apple preset becomes a **read**, not a tool loop:

1. **The app searches first.** The same search `ManualLookupTool` runs (`VaultRetriever`, with the
   vault seal of [Plan KE](KE-symptom-diagnosis-and-vault-only.md) applied as it is today) runs
   before any model, in code. A question the search finds nothing for never reaches a model: it
   gets the existing "not in the manuals" answer.
2. **The reader gets passages, the question and a short instruction**, in a fresh session with
   **no tools**. On PCC the passages can be the whole lookup plus the job summary; on the device
   they are fitted to the space left, measured with `tokenCount(for:)` against
   `SystemLanguageModel.contextSize` rather than estimated.
3. **The answer is structured.** A `@Generable` `ManualReading` holds `found` (did the passages
   answer it), `answer`, `passage` (which one) and `quote` (the words it relied on). Guided
   generation guarantees the shape; it does not guarantee the content.
4. **The app checks the answer.** `ManualReadingCheck` (pure) accepts it only when `found` is true,
   the quote occurs in the cited passage (normalised whitespace and case), and every number with a
   unit in `answer` appears in that passage. Anything else is spoken as "that isn't in the manual"
   with the page the nearest passage came from, never as an answer. This makes abstention a rule
   in code: the research found that even the best small models decline correctly only about 57% of
   the time on BFCL's irrelevance cases.
5. **The citation is the passage's own**, so `show_source` opens the page as it does for every
   other model.

Job actions — open a job, log a reading, attach evidence, deliver the report — stay as they are on
the on-device model (`fieldAssistPriority`). Only manual questions take the reader.

### Which model reads (pure `AppleManualRoute`)

Inputs: online (the GE handoff's network reading, not a bare `NWPath`), PCC availability, quota
state, entitlement present, OS ≥ 27, the Medical "Local LLM Only" rule
(`MedicalLLMRoutingPolicy.isEnforced`), the organisation profile's allowance for Apple's cloud
model, the wearer's setting, whether the fitted passages fit the on-device window, and whether
another model is configured.

| Situation | Route |
|---|---|
| Online, PCC allowed and available, allowance left | **PCC reader** |
| Allowance used up, or PCC refuses with the quota error mid-turn | **On-device reader**, and one sentence per day: "Apple's cloud allowance is used up for today, so I'm answering from the phone" |
| Offline, or PCC not allowed (Local LLM Only, organisation off, wearer off, no entitlement, iOS 26) | **On-device reader** |
| On-device reader, and the best passages don't fit even trimmed to one | The configured other model if online (today's `OnDeviceJobRoutePolicy` handoff), else **held** for when the signal returns (`HeldQuestionStore`, Plan GE), with its own line |
| Apple Intelligence not available on the phone at all | Unchanged: today's errors and handoff |

`OnDeviceJobRoutePolicy` changes in one place: a manual question no longer hands the job turn
away when the reader can take it. A turn that is not a manual question keeps today's behaviour.

### Privacy and policy

PCC is off the phone. Apple publishes PCC's privacy commitments, but the question, the job summary
and the passages still leave the device, so for every rule in this app it is a **cloud model**:

- **Medical "Local LLM Only"** refuses PCC, the same as any cloud model.
- **Vault-only jobs** (Plan KE) seal sources, not providers, so PCC is allowed on a sealed job as
  any chosen model is; the reader adds no outside source.
- **Organisation profile:** a new `apple_cloud` key (`allowed` / `off`) in the profile's AI-model
  section, shown in the review lines ("Manual questions may go to Apple's Private Cloud Compute").
  Some customers' manuals are licensed on terms that may forbid sending their text to an outside
  service.
- **Disclosure:** the in-app privacy copy and `PrivacyInfo.xcprivacy` say that manual questions
  may be sent to Apple's Private Cloud Compute when the setting is on, in the same PR as the code
  (the telemetry posture rule in `.claude/rules/dat-conventions.md` applies to any new egress).
- **Logging:** `PrivacyLog` records the route, the quota state and the check's verdict as tokens
  and counts, never the question, passage or answer.

### Allowance in the interface

The allowance is the wearer's own and is shared with every other app on their account. The Field
Assist status line shows a persistent "Apple cloud: used up today — answering on the phone" state
rather than an alert, and the reason on the session card when a question was held. The app never
spends the allowance on everyday turns: only manual reads go to PCC unless decision 2 says
otherwise.

## Phases (one PR each)

### P0 — Headless core

- Confirm every row of "What iOS 27 adds" against Apple's documentation and the iOS 27 SDK
  headers; correct this plan where it differs.
- `AppleManualRoute` (pure) with the table above as tests, including every refusal reason.
- ✅ *(built under MQ P0, 2026-11-21)* `ManualReadingCheck` (pure): quote containment, number-and-unit containment, `found == false`,
  empty quote, quote from a different passage, near-miss numbers (`4.5` vs `45`), unit variants.
- `ManualPassageFitter` (pure) over an injected token counter: keeps passages in rank order, trims
  the last one at a sentence boundary, reports what it dropped.
- `AppleCloudModelSource` seam (availability, quota state, respond) with a fake, so P1/P2 run in
  tests without iOS 27 or the entitlement.
- Flags, default off: `Config.appleManualReaderEnabled`, `Config.appleCloudManualAnswersEnabled`.

### P1 — On-device reader

- The reader on `SystemLanguageModel.default`, behind the first flag; the `OnDeviceJobRoutePolicy`
  change; `contextSize` read at runtime in place of the fixed 4,096 assumption (this also closes
  Plan JD P1 "measured budget").
- Works offline and on iOS 26, so it ships value before PCC is approved.

### P2 — Private Cloud Compute

- Request the entitlement (decision 7); the PCC reader behind the second flag and
  `@available(iOS 27.0, *)`; quota checked before the call and the quota error caught during it;
  the once-a-day sentence; the status-line state; the wearer setting under Settings → Assistant →
  AI Models → Apple Intelligence; the organisation profile key; privacy copy and manifest.

### P3 — Device pass (owed, not automatable)

On a phone with Apple Intelligence and iOS 27: a manual question answered on PCC with its page; the
same question in airplane mode answered on the device; a question the manual does not answer
declined on both; the Xcode quota simulation (limit reached, nearing limit) and a real exhaustion
if one can be reached; Local LLM Only and the organisation key each refusing PCC; an iOS 26 phone
taking only the device route; a phone without Apple Intelligence unchanged. Record tokens used per
read, latency to first word on both routes, and the check's acceptance rate over the Lennox
example vault's labelled questions (`RetrievalGateCalibrationTests`), so the reader is qualified
the way [Plan FC](FC-local-model-remediation.md) asks of every local model.

## Decisions

1. **PCC for manual reads only, or for whole job turns online?** *Recommend manual reads only at
   first.* Job actions already work on the device and spend no allowance; revisit after P3 shows
   what a field day costs.
2. **When another cloud model is also configured, which reads first?** *Recommend PCC first on the
   Apple preset*, then the configured model, since that is the wearer's stated preference and it
   needs no key.
3. **Default for the wearer setting.** *Recommend on for a solo licence, following the profile for
   an organisation.*
4. **Default for the organisation key when a profile says nothing.** *Recommend off*, so no
   customer's licensed manuals reach a new processor without an administrator choosing it.
5. **Hold or hand off when nothing fits on the device and the phone is offline?** *Recommend hold*,
   as Plan GE does for other unanswerable offline turns.
6. **Speak the allowance sentence once per day or once per job?** *Recommend once per day.*
7. **Request the PCC entitlement now?** *Recommend yes*: approval time is unknown and P1 does not
   depend on it. Confirm the Small Business Program enrolment and the download count first.
8. **Glasses builds go through TestFlight** (`dat-conventions.md`, App Store review and DAT). *Check
   in P0* that a managed entitlement granted for the app is usable in TestFlight builds of both
   variants.
9. **Does a vault need its own `cloud_ok` flag** for licensed manuals, beyond the organisation key?
   *Recommend not yet*: the organisation key covers the customers who license manuals; add a
   per-vault flag if one asks.

## Non-goals

- Vision on either Apple model.
- Training a Foundation Models adapter: it must be retrained for every system model update and
  needs its own entitlement.
- Changing the MLX or GGUF tool paths: that is [Plan MQ](MQ-local-model-tool-harness-and-qualification.md).
  MQ reuses this plan's `ManualPassageFitter` and `ManualReadingCheck`, so a downloaded model's
  manual answers are checked the same way.
- Using PCC as a general cloud brain for the app.
- Breaking a vault down for small windows: [Plan MV](MV-manuals-a-small-model-can-use.md) does
  that. Its cards are the passages the on-device reader takes, and its typed facts answer a table
  question before any reader runs.
