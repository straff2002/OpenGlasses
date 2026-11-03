# Plan KL — Say Why, Keep the Tools (a missing sign-in said once, a request that fits the plan, work a hop keeps)

**Status:** 🚧 P0 built 2026-11-03 (headless; the device re-run is P5). Drafted 2026-11-03 from two
TestFlight users' support reports on build 615. The owner took all six decisions the same day. P2's
hop logging landed with P0; P1–P5 are not built.
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

### P3 — a refused voice key is asked once (headless)

- `CloudVoiceRejection` gains `.keyNotAccepted` (401/403 from ElevenLabs and the other cloud voices). It
  latches like `outOfCredit`, and is cleared when that voice's key changes.
- `voicesRequestFailed` reads the latch, so a known-bad key doesn't fetch the voice list.
- Settings shows "ElevenLabs didn't accept the key" on the voice row.
- Tests: classification, the latch and its reset, and no request once latched.

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

### P5 — the users' re-runs (owed, device)

- User A, signed out: one turn and one photo. Expect the sign-in line once and the status-card row.
  Then sign in and repeat; ChatGPT should answer.
- User B: "Check my calendar for today and my reminders that are due, and tell me the weather here.
  Keep it short." on the free Groq key. Expect one 413 at most, a fitted retry that answers, or the
  plain allowance line, and no restart on another model.

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

- Whether Groq counts the output cap toward the per-minute allowance (P1 checks it from the figures
  before the rung table is fixed).
- What Apple failed on after the tools ran in User B's turn. P2's logging answers it the next time.
- The 94-character line (P4).
