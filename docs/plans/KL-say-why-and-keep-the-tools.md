# Plan KL — Say Why, Keep the Tools (a missing sign-in said once, a request that fits the plan, work a hop keeps)

**Status:** 🚧 P0 merged 2026-11-03, P1 merged 2026-11-04, P2, P3 and P4 merged 2026-11-05 (PRs 937, 948,
949, 950, 951; all headless). Nothing is left to build. P5, the device re-runs, is owed, with exact
steps below. Drafted 2026-11-03 from two TestFlight users' support reports on build 615. The owner took all six decisions the same day.
P4 names the 94-character line: the conversation cue's once-ever introduction, which the voice turn awaited;
it now plays alongside the turn, and every spoken line logs its source.
P2 carries User B's calendar, weather and reminders turn forward: a calendar or reminders read action counts
as read-only. P3 latches a refused voice key per voice and per key, so it costs one request, not one per line.
**Track:** app-wide. Any Direct-mode turn whose chosen model has no working credential, or whose account
caps tokens per minute; every turn the fallback chain hops.
**Related:** Plan [BK](BK-adversarial-review-remediation.md) P2 (the fallback chain and its spoken notices),
Plan [IE](IE-rejected-turn-reasons-and-claude-request-contract.md) (`ProviderRejection`, and the
`requestOverTokenRateLimit` reason added 2026-10-29), Plan [IU](IU-on-demand-tool-schemas.md) (on-demand
tool schemas), Plan [KH](KH-from-capabilities-to-use.md) (the status card).

---

## Why

Two users sent reports on build 615, and the app failed both of them in ways the wearer could not fix from what they heard.

- **User A** chose ChatGPT (Subscription) but was never signed in. Every turn that day went to Apple's
  on-device model. Before each answer the app said ChatGPT was "unavailable". That model can't search
  the web or see photos, and it refused a plain "yes".
- **User B** is on Groq's free tier, which refused every request as too large for its per-minute
  allowance. That is the second report of the same refusal, after build 581. The app told them to turn on
  Small context, which removes the tools their question needed. Apple then took the turn, ran all three
  tools successfully, failed, and the turn restarted on Groq without those results.

## Findings and causes

1. **A missing sign-in is announced as an outage.**
   - `sendChatGPT` throws `LLMError.missingAPIKey`, with the message "ChatGPT account not connected — sign
     in with ChatGPT in the model editor", before it builds any request.
   - The chain classifies that as `.terminalForCandidate`, and `ModelSwitchNarrator.fallbackPhrase` gives
     that class the outage wording: "ChatGPT (Subscription) is unavailable — switching to Apple
     Intelligence." The thrown message is dropped.
2. **…and announced on every turn.** `narrateModelSwitch` is limited to one notice per turn
   (`didNarrateModelSwitchThisTurn`). A credential that is missing stays missing, so the wearer heard the
   same 72-character line before all three answers. It also delayed every answer by the length of the line.
3. **A photo turn says even less.** With ChatGPT unusable and Apple unable to see photos, the wearer
   heard "I took the photo, but couldn't get an answer about it — I don't have working credentials for
   them." (`SpokenErrorPolicy` → `exhaustionReason`, `.terminalForCandidate` without a rejection). That
   sentence names neither the service nor what to do.
4. **The size refusal is per minute, and the advice removes the tools.**
   - Groq answered 413 `rate_limit_exceeded` (`requestOverTokenRateLimit`) to a 44 KB request: 18,814
     characters of instructions, already at **core** tool exposure (36 of 106 tools).
   - IE's line says "turn on Small context for that model in Settings, or pick another". Small context
     sets `effectiveIncludeTools = false` (`LLMService.sendMessage`), so a question about the calendar,
     reminders and weather can no longer be answered.
   - Plan IU's Automatic rule measures the context window. That window (131k for this model) was never
     the limit; the account's tokens per minute were.
   - The report keeps only the size of the 413 body (385 bytes). Groq's message carries the allowance
     and the requested count as numbers, and neither is logged.
5. **A hop restarts the turn and throws away results it already has.**
   - `ModelCascade.run` resets `conversationHistory` to the pre-turn snapshot for every attempt.
   - User B: Apple ran calendar, weather and reminder successfully (1,951 characters in 9.4 s). It
     then failed with a `retryOtherModel` failure, and the turn started again from nothing on a second
     Groq config, which got the same 413.
   - The overflow paths already end the turn once a tool has run (`CapacityError`, `contextOverflow`);
     every other failure class restarts it.
   - **What Apple failed on is not recorded.** `onSwitch` receives only the failure class, so
     `cascadeSwitched` logs `detail=retryOtherModel` with no error. There was no `contextRecovery`, so
     the window did not overflow.
6. **A refused ElevenLabs key is asked again on every line.** `CloudVoiceRejection` latches `outOfCredit`
   and `modelUnavailable` for the session. A 401 maps to `.refused` and is not latched, so every
   utterance paid 0.2–0.4 s for the refusal before the system voice, plus three `voicesRequestFailed`.
7. **Unidentified:** a 94-character line held back User A's first persona-thread turn by about 6 s.
   - It was spoken at 14:13:03, between the transcript and `turnClassified`, right after a persona thread
     started. The persona picker had been opened seven times in the minute before.
   - The report logs the length of each spoken line but not where it came from, so I couldn't find it
     from the report.

## Decisions (owner, 2026-11-03: all six taken as recommended)

1. **The spoken line is short; the screen carries the path.** Spoken: "You're not signed in to ChatGPT,
   so I'm answering on this phone." On screen, the status card and the turn's error banner name the
   setting and link to it. *Taken.*
2. **A known-missing credential is said once per process per service**, and again only after it changes
   (signed in, signed out, key edited). Later turns hop without a notice; the log still records each hop. *Taken.*
3. **A learned per-minute allowance is kept per saved model** across launches, and cleared when that
   model's key, provider or model id changes. *Taken.*
4. **Under an allowance, a cloud model may get the condensed instructions** the on-device path already
   uses, but only when the full ones don't fit. *Taken: the quality cost is smaller than no answer.*
5. **A hop after a tool has run.**
   - If every tool that ran is read-only, its results go forward to the next model as already-fetched
     results.
   - If any tool changed state, the turn ends and says what was done, the rule the overflow paths follow today.
   - *Taken.* The alternative, ending every such turn, is simpler but would have lost User B's answer.
6. **The app keeps allowing a subscription model to be chosen while signed out.** A sign-in can expire
   later anyway, so the fix is to say so, not to block the choice. *Taken.*

## Phases

### P0 — say why, once (headless)

- `ModelSwitchNarrator.fallbackPhrase` takes the thrown error as well as its class. A credential gap
  gets its own wording: `missingAPIKey`, `credentialNotAccepted`, and a 401/403 without a model-contract
  reason.
  - The wording names the **service** ("ChatGPT", "Claude", "Groq"), not the saved model's name.
  - On-device target: "You're not signed in to ChatGPT, so I'm answering on this phone."
  - Cloud target: "…so I'm using Gemini."
  - A rejected key: "ChatGPT didn't accept the sign-in…".
- `exhaustionReason` names the service the same way, so a photo turn says "…couldn't get an answer about it —
  you're not signed in to ChatGPT."
- `CredentialNoticeLatch` (pure): keyed by service and a credential fingerprint (connected flag, key
  present or not; never the key itself). `narrateModelSwitch` consults it, so a gap already said this
  process is not said again. Other hops keep the once-per-turn notice.
- The status card shows "Not signed in to ChatGPT" with a Sign in action while the assistant model has no
  credential. It reads the same `modelAuthBadge` inputs the model list already uses.
- Tests:
  - an error-to-phrase table covering every credential case and the existing non-credential rows,
    which stay unchanged
  - latch transitions: said, silent, credential changed, said again
  - the photo exhaustion line
  - the status-card state for each provider's sign-in

**As built (2026-11-03):**

- `CredentialGap` (`Services/CredentialGap.swift`) classifies a thrown error for a saved model: kind
  `.missing` (`missingAPIKey`) or `.refused` (`credentialNotAccepted`, or a 401/403 the classifier left
  as `other` or unclassified), credential `.account` or `.key`. Only a `.terminalForCandidate` failure
  can be a gap; a model-contract refusal, `modelNotAvailable` and `modelDeclined` are not, and the
  on-device providers never have one. `LLMProvider.serviceName` gives the service's own name.
- `fallbackPhrase(from:to:failure:gap:)` and `exhaustionReason(lastError:gap:)` take the gap as an
  optional argument; without one every line is byte-identical. `ModelSwitchNarrator.Model` gained
  `isOnDevice` (Apple Intelligence as well as MLX) for "I'm answering on this phone"; `isLocal` keeps
  its meaning for the existing lines. An exhaustion reason uses the gap only while the error itself
  is a credential failure of the same kind.
- `ModelCascade.run`'s `onSwitch` gets the thrown error as a fourth argument (nil for the vision
  pre-switch). `sendMessageCascading`'s
  `onModelSwitch` passes it on to `narrateModelSwitch`, which reads the gap from it.
- `LLMService.credentialGap(behind:)` returns the gap the last failed attempt recorded, matched on the
  error itself, for the two text exhaustion lines and the three photo failure lines. "No model fits
  this turn" is thrown before any attempt, so it is never a gap.
- `CredentialNoticeLatch` (value type on `AppState`, process lifetime) is keyed by provider, with a
  fingerprint of the provider's account-connected flag, whether the model has a key, and the key's
  process-seeded `hashValue` (so a refused key replaced by another is said again). A gap already
  said is not narrated, and does not spend the turn's one notice.
- The status card row is `CredentialSignInRow` under `StatusIndicator` (Direct mode only), from the
  pure `CredentialSignInPrompt.resolve`, which reads `modelAuthBadge`: "Sign in to ChatGPT" or "Add a
  key for Groq", opening Settings › AI & Personality. The row says what to do rather than "Not signed in to
  ChatGPT" with a separate action, so it is one control.
- **From P2:** `cascadeSwitched` now logs `SafeErrorSummary(error)` beside the class.
- Tests: `CredentialGapTests` (classification, phrase tables, exhaustion, latch, row, cascade error),
  and two `SelectedPhotoModelTests` cases through the real `LLMService`.

### P1 — fit the request to the account's per-minute allowance (headless core; live check owed)

- **Read the figures.** `ProviderRejection` parses the allowance and the requested count from a
  `requestOverTokenRateLimit` message: Groq's "Limit N, Requested M" on tokens per minute. They are numbers,
  so they are logged (`model event=streamError … limit=N requested=M`), and the support report prints them.
- **Learn the ceiling.** `PerMinuteAllowance` (pure, persisted per saved model per decision 3) records N
  from the refusal.
- **Fit before sending.** `PerMinuteFit` (pure) estimates the request against a known ceiling: prompt,
  declared tools, history and output cap. Whether the provider counts the output cap toward the
  allowance is settled first, by comparing M with our estimate on fixtures built from both reports'
  sizes; the plan does not assume it. The fit then takes the first rung that fits:
  1. today's request;
  2. on-demand tools with the core set emptied: `lookup_tools` plus tools already used in this conversation;
  3. step 2 plus the condensed instructions (decision 4);
  4. step 3 with history cut to the last two exchanges and a smaller output cap;
  5. nothing fits: say so, as below.

  Tools are never dropped to make room. Small context stays the wearer's own setting.
- **Same-turn retry.** A `requestOverTokenRateLimit` with figures retries once on the same candidate
  with the fitted request, before the chain hops. The 413 arrives before anything runs, so the retry can't
  repeat a tool.
- **Spoken line when nothing fits:** "Groq's plan allows about N thousand tokens a minute, and this
  question needs more, so pick another model in Settings." The Small-context advice stays only for turns
  that carry no tools.
- Tests:
  - parsing the message (with figures, without them, other providers)
  - the rung table against fixtures at both reports' sizes
  - the retry happens once and only before a tool has run
  - the spoken line by rung outcome
- **Owed live:** one free-tier Groq turn on a device, which needs a Groq key. Groq is not one of the
  providers the owner live-tests, so this is the tester's re-run in P5 unless the owner supplies a key.

**As built (2026-11-04):**

- `ProviderRejection` gained `limit` and `requested`, read only for `requestOverTokenRateLimit`: the
  whole number standing after the word "limit" and after "requested", nothing else of the sentence
  (the organisation id, the model and the tier are never kept). Nil when absent; other reasons and
  providers are unaffected. `streamError` and `apiError` log them (`limit=N requested=M`), and the
  turn trace carries them (`allowanceLimit`, `allowanceRequested`), so a failed turn's report line
  reads "allowance: 8000 tokens a minute · requested: 11234 tokens".
- `PerMinuteAllowance` (pure) and `PerMinuteAllowanceStore` (preferences, keyed by saved model id,
  read through on every call): the limit, a calibration, and a fingerprint of provider, model id and
  endpoint. Nothing of the key is kept, not even a digest: `Config.setSavedModels` compares the list
  it replaces with the new one (`PerMinuteAllowance.modelsToForget`) and drops the entry of a model
  whose key, provider, model id or endpoint changed, or that was removed (decision 3; logged as
  `perMinuteFit detail=cleared count=N`). A read whose fingerprint no longer matches clears it too.
  Registered as exempt in `DataStoreRegistryTests`: numbers and a fingerprint, nothing about anyone.
  A signed-in account route has no key to compare; none of the fitted providers uses one but xAI,
  whose account change is not caught here.
- `PerMinuteFit` (pure) estimates a request as its body bytes over four plus its output cap, and
  takes the first rung within 90% of the allowance. `LLMService.fitToPerMinuteAllowance` measures
  each rung as it would be sent: the prompt (with the on-demand guide swapped for one listing every
  tool), the serialized tool definitions, the history (Groq's last six messages), the cap. Rung 2 is
  `ToolExposurePolicy.emptyingCore` (reason `perMinuteAllowance`); rung 3 is
  `LLMService.condensedCloudPrompt` — `AppleOnDeviceInstructions` without its "manuals need a cloud
  model" line, the photo lines on a photo turn, and the guide; rung 4 (`PerMinuteFitScope.shortened`)
  keeps this turn whole and two exchanges before it, and halves the cap (not under 512). Rungs 2–4
  need the lookup tool and are not built when the organisation pinned tool definitions to Never. A
  rung-5 turn throws `PerMinuteFit.NothingFits` before sending: `.terminalForCandidate`, so another
  model may take it; summary `overAllowance(beforeSending)`. The fit applies to the OpenAI-compatible
  family on Chat Completions (Groq, DeepSeek, Mistral, Z.ai, Qwen, MiniMax, xAI, OpenRouter, custom).
- **The output cap is counted.** Neither report kept Groq's requested count, so whether Groq counts
  `max_tokens` could not be settled from fixtures. The estimate counts it, which can only be stricter
  than Groq. Each refusal that states its count stores the ratio of that count to the app's estimate
  of the same request (body bytes and cap, recorded at `requestSent`), clamped to 0.5–2, and later
  fits apply it; a refusal with the limit alone raises the calibration until the refused request
  estimates over it. If Groq does not count the cap, the ratio comes out below one and fits loosen.
- **Same-turn retry.** `PerMinuteRetry.run` wraps each attempt in `sendMessageCascading`: a refusal
  with figures on a request that carried tools is learned, the history rewound to the attempt's
  start, and the same model asked once more — now fitted, since the allowance is known. Only while
  `toolCallsDispatched` (counted by the shared tool dispatcher and the on-device tool runner) has not
  moved since the attempt began. A second refusal is learned from and goes to the chain. Later turns
  on the model fit before sending.
- **Spoken:** `PerMinuteNotice` — "Groq's plan allows about 8 thousand tokens a minute, and this
  question needs more, so pick another model in Settings." Without figures: "this question is
  bigger than Groq allows per minute on this account, so pick another model in Settings"; the Small
  context advice is kept only when the request carried no tools (unknown counts as tools). A hop
  says "…, so I'm using Claude." (or "I'm answering on this phone"), never "unavailable". The banner
  (`plainReason`) reads the trace's allowance and tool count the same way; the OpenAI-compatible
  path now records the tool count too.
- Fixtures (`PerMinuteFitTests`): build 615 (44,317 bytes, 18,814 of instructions, 36 core tools,
  1,200 of history) and build 581 (43,000 bytes) against 8,000 a minute both take rung 3
  uncalibrated; with a count like 581's (11,234) against 615's estimate of 12,103 it takes rung 2. 6,000 a
  minute takes rung 4; 4,000 fits nothing. `PerMinuteRetryTurnTests` runs the real `LLMService` with
  the registry's tools over a recording transport: one refusal and one fitted retry declaring only
  `lookup_tools`, no hop; the next turn fitted before sending; no resend after a tool ran; nothing
  sent when nothing fits (in `PerMinuteFitTests.swift`, beside the pure cases). A key edit through
  `Config.setSavedModels` clears the shared entry.
- **Not covered:** a fitted turn that needs several tool rounds can spend the minute's allowance
  across them — rung 2 adds a lookup round — and Groq then answers 429 mid-turn, after tools ran. That
  hop is P2's case. The fit measures the first request only.
- **Not covered either:** an allowance is forgotten only when the model's key, provider, model id or
  endpoint changes, so a plan upgraded on the same key keeps being fitted until then. Groq's
  `x-ratelimit-limit-tokens` response header could re-learn it on every answered turn; it is not read.

### P2 — a hop keeps the work, and logs why (headless)

- `ModelCascade.run`'s `onSwitch` passes the error. `cascadeSwitched` logs `SafeErrorSummary(error)`
  next to the class, so the next report shows what Apple failed on.
- Each attempt reports the tools it ran and whether each is read-only. Each native tool already declares
  `executionSemantics.effect` (`ToolEffect`, `.readOnly` among them); that is used, no second list is
  built. An unclassified tool counts as changing state (`conservativeDefault`).
- On a hop after tools ran (decision 5):
  - all read-only: the next attempt starts from the pre-turn snapshot, plus the results as an
    already-fetched block (tool name, arguments, result text). The model is told not to fetch them again.
  - any state change: the turn ends, saying what ran and that it was not repeated.
- The overflow rules (`CapacityError`, `contextOverflow(toolsRan:)`) move under the same rule, so there
  is one place that decides.
- Tests:
  - read-only results carried into the next candidate's history
  - a state-changing tool ends the turn with its line
  - the overflow cases unchanged in outcome
  - the logged error token for each failure class

**As built (2026-11-05):**

- **One rule.** `HopAfterTools` (`Services/HopAfterTools.swift`, pure) decides every hop from what the
  turn's tools did and whether the failure is an overflow: nothing ran → restart as before; only
  read-only tools → carry forward; anything that may have changed state → end the turn; an overflow
  after any tool → end the turn, as before. `ModelFallbackChain.classify` reads `CapacityError` and
  `contextOverflow(toolsRan:)` through `HopAfterTools.overflowClass`, and a new `beforeHop` step in
  `ModelCascade.run` applies the same rule with the turn's ledger. It runs only once a hop has been
  chosen, before `onSwitch`; throwing from it ends the turn with that error instead.
- **The overflow outcomes are unchanged.** Whether a read-only tool ran or not, an overflow after a
  tool still ends the turn with "the request was too large for this model". Carrying the results
  forward would send the bulk that overflowed to a model the chain does not know to be bigger
  (`CapacityError` and provider overflows hop `.retryOtherModel`, not `.needsBiggerWindow`). This also
  covers a carried attempt that overflows. Local `promptTooLong` (`needsBiggerWindow`) is not an
  overflow here: it follows the general rule.
- **The ledger.** `AttemptToolLedger` (value type on `LLMService`, reset when a turn starts and kept
  across its attempts) records every model tool call. Each entry has the tool name, canonical JSON
  arguments (up to 600 characters), the result (up to 8,000), and the effect from
  `NativeTool.executionSemantics.effect`. No second list is built. A name the registry does not hold
  (an MCP tool, the gateway) gets `conservativeDefault`, as does a native tool that declares nothing.
  Both count as changing state.
  - **Read actions count as reads.** Decision 5 is about what the call did, and `CalendarTool` and
    `AppleRemindersTool` are declared by their strongest action (`.local()`, since they can create
    entries). `ToolEffectClassifier.isReadAction(tool:args:)` sits beside the argument-aware
    `face_recognition` and `code_agent` rows. It is one row per tool with the read actions taken
    from that tool's own `execute` switch:
    - `calendar`: today, schedule, next, upcoming, week, this_week, tomorrow;
    - `reminder`: list, show.
  - The action is read as the tool reads it, lower-cased only. A missing action, an unknown one and
    every write (create/add; create/add/set, complete/done/finish) stay a change. That includes the
    calendar's missing action, which the tool runs as "today".
  - The ledger enters such a call as `.readOnly`, and every other call with its tool's declared
    effect. The authorization class is not touched: `nativeClass` and the router still classify
    both tools as `.write`.
  - A call counts as run from dispatch. Only `.rejected` and `.failedBeforeExecution` take that back.
    A call still in flight, or with an unknown outcome, counts and has no result to carry.
  - Calls are entered by the shared dispatcher (beside P1's `toolCallsDispatched`), by the Apple
    runner (only calls that actually run; a replay from `AppleToolResultCache` adds nothing), and by
    the MLX model's single call, which now also counts toward `toolCallsDispatched`.
  - Plan S's agent plan calls the router directly and is not entered. A plan that ran steps always
    returns its summary, so the attempt does not fail after it.
- **The carried block.** It goes into the next attempt's instructions, not its history. It goes in the
  uncached volatile tail on OpenAI and Anthropic, and at the end of the prompt elsewhere. The attempt
  still starts from the pre-turn snapshot, with one user turn and no replayed tool exchange.
  - Why not history: a second user message in a row is refused by providers that require roles to
    alternate (`ProviderRejection`'s "roles must alternate"), and a history entry would outlive the turn.
  - Format: a header saying another model ran these tools for this request and stopped, and not to
    call them again with the same arguments. Then one line per call, `- tool {arguments}: result`,
    using the latest of identical calls. `lookup_tools` is left out.
  - Each result is wrapped as the tool loop wraps it (`PromptInjectionPolicy` for untrusted output),
    so it is no more trusted in the instructions than it was in the turn. A result is cut before it
    is wrapped, so the envelope always closes.
  - Bound: 8,000 characters for a cloud model, 2,400 for an on-device one. The last result that
    fits in part is cut with a marker, and the rest are named as left out, so the model may fetch them.
  - The per-minute fit counts the block in the prompt's bytes, and its condensed rungs carry it too.
    `RequestContextBudget` counts it as instructions. A P1 retry on the carried model resends it.
- **The turn that ends.** `HopAfterTools.TurnEnded` is `.terminalForTurn`. It holds the state-changing
  tools as spoken names ("save note"; a non-native tool is "a connected tool") and the failure's
  `SafeErrorSummary`, never the error itself.
  - Spoken, in the overflow line's frame: "I couldn't get a response — save note had already run,
    so I didn't run it again on another model." A photo turn says the same after "I took the photo, but…".
  - As with the overflow line, narration off gives the generic line.
  - Summary: `stoppedAfterTools(<failure category>)`. The banner says "the AI stopped after a tool had
    already done something, so it wasn't run again on another model".
- **Logging.** `hopAfterTools` records the decision, what ran (`readOnly`/`changedState`), the call
  count and the attempt's error. With detail `carriedBlock` it records the results carried, those
  left out, whether one was cut, and the length. `hopToolRan` logs each tool's native name (`other`
  otherwise) and the effect its call was entered with. Arguments and results are never logged. P0's `cascadeSwitched` line is
  now `LLMService.logCascadeSwitch`, so it can be tested.
- Tests:
  - `HopAfterToolsTests`, pure: the rule table; the overflow cases unchanged in outcome (both
    `CapacityError` values and the default, both `contextOverflow` values, a provider overflow); a
    mixed ledger and an unclassified stub counting as a change; refused, in-flight and unknown
    calls; the block's content, dedupe, exclusion, bound and closed envelopes; the spoken, photo and
    banner lines; the logged error token for each failure class; `beforeHop` ending a turn and
    being asked only for a real hop; every read action of `calendar` and `reminder` read-only,
    every write, missing, unknown or padded action a change, and their approval class unchanged.
  - `HopAfterToolsTurnTests`, through the real `LLMService` with two Groq configurations, stub tools
    and a recording transport: a read-only result carried into the second model's request and not
    fetched again; a state-changing stub ending the turn with its line after one write and no hop;
    a hop before any tool unchanged; the next turn carrying nothing. Under the real tools' names
    and declared effects, the report's turn (calendar today, `get_weather`, reminders list) carries
    all three results and runs each once; a calendar create beside the weather ends the turn.

### P3 — a refused voice key is asked once (headless)

- `CloudVoiceRejection` gains `.keyNotAccepted` (401/403 from ElevenLabs and the other cloud voices). It
  latches like `outOfCredit`, and is cleared when that voice's key changes.
- `voicesRequestFailed` reads the latch, so a known-bad key doesn't fetch the voice list.
- Settings shows "ElevenLabs didn't accept the key" on the voice row.
- Tests: classification, the latch and its reset, and no request once latched.

**As built (2026-11-05):**

- **`.refused` is split.** `CloudVoiceRejection.keyNotAccepted` is the key itself: a 401 or 403 the
  body does not explain otherwise, and Gemini's `API_KEY_INVALID` 400 (the marker list is now
  `keyNotAcceptedMarkers`). `.refused` keeps its raw value, so an episode stored under it still counts,
  and now means the voice chosen for the key: a 402 (a plan that will not pay for the voice; xAI's
  402 stays here too, as before), and any status whose body names `voice_not_found`, ElevenLabs's
  bad voice id. `voiceRefusedMarkers` is read before the key's status, so a bad voice id can never
  latch a good key off: the wearer fixes it by picking another voice, and the key is still tried.
  A 404 `voice_not_found` used to be unclassified and fell through with no notice; it now gets the
  existing "refused the voice request… check the key and voice" notice. Voice refusals are not
  latched, so a voice change has nothing to clear.
- **The latch.** `CloudVoiceKeyLatch` (pure, `CloudVoiceFallback.swift`) holds one fingerprint per
  cloud voice: the refused key's process-seeded `hashValue`, never the key, never persisted, as
  P0's `CredentialNoticeLatch`. A key that changes anywhere (the ElevenLabs field, a saved model's
  key, a refreshed xAI token) does not match, so it is tried again without anything clearing it;
  an empty key is never latched. `TextToSpeechService.keyLatch` is `@Published` for the settings row.
  - `cloudVoiceAudio` latches a `.keyNotAccepted` answer for the key it sent and logs
    `tts event=keyNotAccepted`. A second, different refused key from the same voice ends that voice's
    announcement episode first, so it is said again.
  - `cloudVoiceKeyChanged(_:)` clears the latch and then does what `resetCloudVoiceQuota` does. The
    ElevenLabs key field calls it in place of `resetElevenLabsQuota`, so editing the field is also how
    a wearer asks for the same key to be tried again. `resetCloudVoiceQuota`, called on every voice and
    model change (ElevenLabs voice picker and field, OpenAI voice, xAI voice and field, Gemini model
    and voice, the three list loaders), leaves the key latch alone: the key is still the one refused.
- **No request once latched.** `isLatchedOff(_:key:)` (credit, model or key) is what the engine chain
  passes to `TTSEngineSelector.cloudVoiceReady`, so a latched voice is not ready and the chain goes
  straight to the next engine. The chain reads each voice's key without asking a sign-in for a
  token: the ElevenLabs key, the OpenAI and Gemini keys from the saved models, and the typed xAI
  model key. Each `fetch…Audio` also refuses a latched credential before building the request
  (`refuseLatchedKey`), quietly (no notice), because a streamed reply's sentences in flight do not
  go through the chain again.
  - **Deviation: an xAI sign-in reads as ready.** Its token is only available asynchronously, so
    readiness cannot see it. It is latched on the token actually sent, so the same token is never
    sent again (the chain hops with no request), and the refreshed token is a new credential.
- **The voice list.** The three static fetches now throw `CloudVoiceRequestRejected` classified
  from the body (a `LocalizedError` with the old "Cloud voice API error: N" text, so other failures
  read the same). `TextToSpeechService.fetchVoiceList(_:key:_:)` wraps them: a latched key fetches
  nothing (`tts event=voicesRequestSkipped`), and a list refused for the key latches it, so speech
  does not ask either. Both throw `CloudVoiceKeyNotAccepted`. The Settings loaders call it with the
  same key the chain reads (for xAI, the typed key, or empty for a sign-in, which is never latched
  there). A refused key is not repeated as "Could not load voices" under the picker while the row says it.
- **Settings.** `CloudVoiceKeyRefusedRow` (Connections › Services & Integrations) observes the
  service and shows "ElevenLabs didn't accept the key" ("OpenAI…", "xAI…", "Gemini…") as a caption
  in the error colour (under the ElevenLabs key field, above the other voices' pickers) while the latch
  holds for the key now saved.
- **Spoken notice.** `.keyNotAccepted` has its own lines, said once per episode like `outOfCredit`:
  "By the way, ElevenLabs didn't accept the key, so I'm using the built-in voice. Check the key in the
  app's Settings, under Connections, then Services and Integrations." The OpenAI, xAI and Gemini keys
  live on the saved model, so their line says "Check the key on your OpenAI model in the app's
  Settings, under Assistant" (`SettingsHub.path(to: .intelligence)`). Each has a banner and an
  "another voice" form. The existing `.refused` lines are unchanged.
- Tests: `CloudVoiceKeyLatchTests` (the classification table, the latch per voice and per key and
  holding no key, one request then none for synthesis, key change vs voice change, a bad voice id
  never latching, an xAI token not sent again, the voice list skipped and latching for speech,
  Gemini's model list, a server fault unlatched with its old message, readiness, the row and notice
  wording, once per episode). `CloudVoiceFallbackTests`, `CloudVoiceRequestsTests` and
  `GeminiCloudVoiceTests` now expect `.keyNotAccepted` for a bad key, and its latch.

### P4 — the line before the turn (headless, then a small fix)

- Every spoken line logs where it came from as a token: `tts event=speaking source=<caller>`. That covers
  the switch notice, the reply, the error line, persona and job lines, and acknowledgements. A report
  then names each line, not just its length.
- Reproduce User A's sequence on the simulator: pick a persona in the picker, then a wake-word
  question. Name the 94-character line.
- If it delays the turn, start the model while it plays, as the switch notice already does. If it is
  repeated per turn, say it once.
- Tests: every `speak` call site passes a source (a source-scrape guard like `OutboundFrameConsumerTests`),
  plus the fix's own test.

**As built (2026-11-05):**

- **`SpeechSource`** (`Services/TTS/SpeechSource.swift`): 19 kinds of line, not one per call site —
  `reply`, `phoneAnswer`, `errorLine`, `switchNotice`, `disclosure`, `confirmation`, `acknowledgement`,
  `progress`, `alert`, `statusNotice`, `job`, `translation`, `navigation`, `narration`, `coaching`,
  `lifecycle`, `agent`, `readAloud`, `diagnostic`. There is no persona case: no call site speaks a persona
  line (picking a persona says nothing).
- **Required.** `speak(_:source:urgency:mirrorToHUD:)`, `speakReporting(_:source:…)` and
  `speakStreaming(_:source:)` take it with no default; about a hundred call sites name one (103 by the
  guard's count). The `String` seams (the job flow, job sends, the handoff, the turn runner, the
  remote-command executor) stay `String`: their wiring in `AppState` names the source.
- **Threaded through deferred speech.** `TurnAnnouncement.Speak` carries the source, so a notice queued
  behind another is logged as itself. `StreamedReplyQueue` holds its reply's source and passes it to
  `playStreamedSentence`; the gateway stream opens its queue with the source `speakStreaming` was given.
- **The log.** Both `speaking` lines (the engine chain, a streamed sentence) gain `source=<token>` right
  after `characters=`, so the report's App events section reads `characters=94 source=disclosure`. The
  report prints spoken lines nowhere else (the turn traces keep no spoken lines), so nothing else changed.
- **The 94-character line, found by reading, not on the simulator.** The only speech between the
  transcript and `turnClassified` on a voice turn is `speakConversationCueIfDue()`, which was awaited. Its
  first-ever form, "Connecting to Avenkin AI, your AI assistant. It can be wrong, so check anything
  important.", is 90 characters written and **94 spoken**: the brand is said "Ah-Ven-Kin A I", and the log
  counts the spoken form. The launch's short cue is 29 spoken. It is said once per install, which fits a first
  persona-thread turn and no later one; the persona picker speaks nothing. No sim reproduction was needed.
- **The fix: it plays alongside the turn.** It was not repeated, so no latch; it delayed the turn by its whole
  length. `AIDisclosureLedger.announceConversationCue(cueEnabled:through:)` consumes the line as before and
  starts it through `turnAnnouncement` (source `disclosure`); `handleTranscription` calls
  `announceConversationCueIfDue()` and goes straight on to classify and start the model. Every path after it
  that speaks now waits on the announcement first, so the disclosure is still heard whole: the cascade's reply
  and failure line already did; added to the `new_topic` reset, the tier-0 answer, `finishPhoneTurnWithoutModel`
  and both lines of `runAgentTurn` (whose thinking sound now waits for the notice too). The photo command and
  the realtime sessions still await the cue: the photo's line comes before its shutter tone by design, and a
  realtime session must not open its audio over it.
- Tests: `SpeechSourceGuardTests` (the scrape finds the known sites; every speech-service call passes
  `source:`; no declaration defaults a `SpeechSource`; both `speaking` lines log it) and `SpeechSourceTests`
  (the rendered line and the event ring, the tokens, a queued notice keeping its source, the introduction's
  90/94 characters, the cue returning while it plays with the reply waiting behind it, once per launch and
  install, and a scrape that the voice turn announces rather than awaits). `TurnAnnouncementTests`,
  `StreamedReplyTurnTests`, `SpeechDeliveryOutcomeTests`, `PrivacyCanaryTests` and
  `GlassesDeviceStateWiringSourceGuardTests` follow the new signatures.

### P5 — the users' re-runs (owed, device)

Not run. P5 needs a phone, the glasses and two accounts, so it can't be done headlessly, and
nothing here stands in for it. Run on a TestFlight build at or after **623** (P4 merged in
PR 951). For each run, send a support report afterwards (Settings › Advanced & Support, "This
conversation") and check the log lines named below.

**1. Signed out of ChatGPT (P0).**
1. In Settings › Assistant › AI Models, choose a ChatGPT (Subscription) model while signed out of
   ChatGPT. Leave Apple Intelligence in the chain.
2. Ask one plain question by wake word, then a second one.
   - Expect: before the first answer, "You're not signed in to ChatGPT, so I'm answering on this
     phone." Nothing before the second answer. The status card shows "Sign in to ChatGPT", and the
     row opens the model settings.
   - Log: `cascadeSwitched detail=terminalForCandidate` with an error token on both turns. There is
     never an "unavailable" line.
3. Take one photo and ask about it.
   - Expect "…couldn't get an answer about it — you're not signed in to ChatGPT."
4. Sign in to ChatGPT from the status-card row, then repeat steps 2 and 3.
   - Expect ChatGPT to answer both, with no switch notice.

**2. Free-tier Groq (P1, P2).** This needs a free Groq key. The owner doesn't live-test Groq, so
this run belongs to whoever has one.
1. Choose the Groq model with the free key, tools on (Small context off).
2. Ask: "Check my calendar for today and my reminders that are due, and tell me the weather here.
   Keep it short."
   - Expect at most one 413. Then either a fitted retry on Groq that answers using the tools, or
     the line "Groq's plan allows about N thousand tokens a minute, and this question needs more…".
     Never the Small-context advice, and no restart from nothing on another model.
   - Log: `streamError status=413 … limit=N requested=M`, then `perMinuteRetry` and a second
     `requestSent` that is smaller. A `perMinuteFit` rung is logged.
3. Ask the same question again.
   - Expect it fitted before sending: no 413 at all.
4. If any hop happens after tools ran, check `hopAfterTools`. It should read `carryForward` for
   calendar, weather and reminder reads, and the next model's answer should use those results
   without running the tools again.
5. Settle the open question: compare `requested=` against the app's estimate on the same
   `requestSent`. The ratio says whether Groq counts the output cap.

**3. A refused ElevenLabs key (P3).**
1. Choose the ElevenLabs voice, and enter a wrong key in Connections › Services and Integrations.
2. Ask two questions.
   - Expect one `engineFailed status=401`, then `keyNotAccepted`, and the system voice for every
     line after it with no further ElevenLabs request. You hear "ElevenLabs didn't accept the
     key…" once. The voice row shows "ElevenLabs didn't accept the key", and the voice list
     isn't fetched (`voicesRequestSkipped`).
3. Enter the right key.
   - Expect the next line in the ElevenLabs voice.
4. Optional: pick a voice id the account can't use. Record the real status and body code, which
   P3 assumed to be `voice_not_found`. It should not latch the key.

**4. First voice turn on a fresh install (P4).**
1. Delete and reinstall, sign in to a cloud model, and ask the first question by wake word.
   - Expect the introduction ("Connecting to Avenkin AI…") heard in full before the answer.
   - Log: `tts event=speaking … characters=94 source=disclosure`, with no multi-second gap before
     `turnClassified`. Every `speaking` line in the report carries a `source=`.

**What to bring back:** the support report from each run. Run 1 is checked on device when
sign-in works. Run 2 closes P1's live check and the output-cap question. Run 3 closes P3.
Run 4 closes P4.

## Acceptance

- A missing or refused credential is said by service name, once per process, with the setting on screen.
  No credential gap is called "unavailable".
- A per-minute refusal with figures is retried once, fitted, keeping the tools. When nothing fits, the
  wearer hears the allowance and is never told to turn tools off for a question that needs them.
- No hop throws away read-only tool results. Every `cascadeSwitched` carries the error.
- A refused voice key costs one request per key, not one per line.
- Every spoken line in a support report names its source.

## Evidence

- User A, 2026-11-02, iPhone18,2, iOS 27.2: every turn logs `turnStarted provider=chatgpt` →
  `cascadeSwitched detail=terminalForCandidate` in the same second, with no `requestSent`. The 18:15
  photo turn: `Turn FAILED — unknown(missingAPIKey)` and a 98-character line, which matches the photo
  exhaustion sentence above exactly. The 72-character pre-answer line matches the outage wording exactly.
- User B, 2026-11-02, iPhone17,3, iOS 27.0.1:
  - Groq `requestSent bytes=44317` → `streamError status=413`, at `toolExposure detail=core count=36`.
  - Apple ran `calendar`, `get_weather` and `reminder` (all `succeeded`), then `cascadeSwitched
    detail=retryOtherModel` to a second Groq config, and a second 413.
  - ElevenLabs `engineFailed status=401` on each line.
- Build 581's report (2026-10-29) had the same Groq refusal at about 11k tokens against an allowance of
  about 8k. IE then classified it and wrote the Small-context advice.

## Open

- Whether Groq counts the output cap toward the per-minute allowance: P1 counts it and calibrates
  from each refusal's own requested count; the live Groq turn will show the ratio in its log.
- What Apple failed on after the tools ran in User B's turn. P2's logging answers it the next time.
- ~~The 94-character line (P4).~~ The conversation cue's once-ever introduction; it now plays alongside the
  turn. P5's first signed-in voice turn on a fresh install should show `source=disclosure` and no gap before
  `turnClassified`.
