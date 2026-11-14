# Plan LT — Fixes from the November 2026 Ecosystem Review (our own defects, found by looking at adjacent work)

**Status:** 🚧 P0 built 2026-11-14 (items 1–7, headless; see [As built](#as-built)); the P1 device checks owed,
then a short follow-up PR settling the defaults of items 4 and 6. All four [decisions](#decisions-for-greig)
taken 2026-11-14 as recommended.
**Track:** Hardening. Privacy, the watch, temple taps, wake word, Gemini Live audio and vision, glasses
lifecycle, the web mirror.
**Builds on:** Plan [R](R-mcp-egress-and-tool-poisoning-screen.md) (`EgressScreen`), Plan [LN](LN-memory-manners.md) §3 (the turn's
untrusted-read flag), Plan [CP](CP-outbound-frame-privacy.md) / W04.1 (privacy scopes and the consumer roster),
Plans [CH](CH-media-button-trigger.md) / [GJ](GJ-remappable-temple-gestures.md) (temple taps over Now Playing), Plan
[BP](BP-web-hud-mirror.md) and item 3 of [ID](ID-ecosystem-review-hardening-bundle.md) (the web mirror), the
glasses sleep policy (`GlassesSleepPolicy`).
**Sits beside:** the amendment to [GX](GX-photo-checked-procedure-steps.md) made in the same PR (checks that tell
before from after, settle time, prompt and scoring rules). New features from the same review are not in this plan.

---

## Trigger

A survey of about 27 adjacent smart-glasses and agent projects on 2026-11-14 found few features worth copying,
but several places where another project had hit a problem that our code still has. Each item below was checked
against `main` at 6bd283ef6. Where a fix depends on how the hardware or a provider behaves, the item says so and
ships behind a device check rather than as a guess.

## Outcome

- A screen recording, screen share or AirPlay mirror of the app never carries an unblurred bystander's face
  while the bystander blur is on.
- A tool that sends model-written text to a third party (a web search, a places or news query) is
  screened like an MCP call, and a turn that has read outside content cannot quietly copy the wearer's private
  data into that query.
- A photo request started from the watch reports its own result: a failure says what failed, never the previous
  answer, and with no glasses connected it says so instead of opening a phone camera nobody is looking at.
- Every temple tap is heard, not only the first (once the device check confirms the cause).
- A wake-word alternative that is an ordinary word only wakes the assistant at the start of what was said.
- Gemini Live answers about a deliberate photo from the photo, and its turn starts are tuned on a device rather
  than assumed.
- An odd-length audio chunk from a realtime provider cannot misalign the rest of the reply.
- A glasses-off reading that was never preceded by glasses-on on this connection does not stand the app down.
- The camera's "session ended by device" notice mentions a glasses update.
- The web mirror has a launcher icon.

## What exists, and what doesn't

**Exists (verified against `main` at 6bd283ef6):**
- `PrivacyFilterScope` (`Services/PrivacyFilterService.swift`): `.onDevicePreview` is unfiltered and
  `leavesTheDevice == false`; `OutboundFrameConsumer` maps `.livePreview` and `.phoneViewfinder` to it. Nothing
  in the sources reads `UIScreen.isCaptured`, `capturedDidChangeNotification` or `sceneCaptureState`.
- `EgressScreen.evaluate(_:policy:)` (`Services/Security/EgressScreen.swift`) runs in `NativeToolRouter` only for
  an `.mcpServer` seam (`NativeToolRouter.swift:262–272`), in `MCPTransport`, and in `RecipeRunner`. Native tools
  are not screened. `web_search` (Perplexity, DuckDuckGo), `find_nearby` (MapKit, so Apple) and `get_news`
  (Google News search) are `readOnly`, so the effect-class floor (`ToolEffectClass.requiresBoundApproval`) never
  asks either. Seven files under `Services/NativeTools` reach `URLSession` or `BoundedHTTPClient`. (`translate`
  sends nothing: the model translates in its reply.)
- The turn ledger (`HopAfterTools`, `TurnToolLedger`) keeps each call's tool, effect, nativeness and up to
  `capturedResultLimit` of its result. `readUntrustedOutput` is true when any `PromptInjectionPolicy.untrustedOutputTools`
  member ran, and that set includes our own stores (`memory_search`, `brain`, `my_memory`, `notes_vault`,
  `health_vault`, `document_knowledge`, `remember_scene`), which are also where private data comes from.
- `WatchConnectivityManager` `photo`, `describe` and `quickAction` await `captureAndAnalyzePhoto` /
  `capturePhotoAndSend` and then reply `["status": "completed", "response": appState.lastResponse]`.
  `capturePhotoAndSend` returns early without touching `lastResponse` when the model cannot see images, when the
  glasses are not connected (it presents the phone camera instead), and on a capture or model failure.
- `MediaTriggerService` registers play, pause, toggle, next and previous, and in standby keeps a silent
  `AVAudioPlayer` looping (`numberOfLoops = -1`) at rate 1.0. A pause command maps to a tap but never pauses the
  player or changes the Now Playing rate. Its header records a Gen 2 that heard only the first tap after launch.
- `WakePhraseMatcher.match` first looks for each candidate, primary and alternatives alike, as whole tokens
  anywhere in the transcript (`PhraseMatcher.contains`), then fuzzy windows at every position. Fuzzy matching is
  already off for short phrases.
- Gemini Live: `GeminiLiveSetup.swift:39` sends `START_SENSITIVITY_HIGH`. Streamed frames and the deliberate
  sharp still (`sendHighResImage` → `LiveInjectionEnvelope.geminiImage`) both go as `realtimeInput.video`, with no
  instruction attached to the still.
- `RealtimeAudioEngine.frameCount(forByteCount:)` divides and drops a remainder byte.
- `glassesWornChanged(false)` starts the doff grace on any `false` reading while `doffGraceApplies` holds; it does
  not ask whether this connection ever read `true`.
- `DeviceSessionFailureReason.sessionEndedByDevice` says to end any broadcast in Meta AI and to case the glasses
  for a minute. It does not mention an out-of-date glasses install.
- `WebHUDMirrorServer` serves `/` and `/hud.json` only: no icon, no manifest.

**Doesn't exist:** a screen-capture signal anywhere; a screen on native egress; a private-span check on outbound
queries; error replies from the watch photo commands; a start-of-utterance rule for wake alternatives; a carried
audio byte; a "seen worn on this connection" fact.

## Design

### 1. The preview while the screen is being captured (privacy, first)

**`ScreenCaptureState`** (new, `Services/Vision/`): one `@MainActor` observable that reads
`UITraitCollection.sceneCaptureState` for the app's foreground scene (iOS 17+), falling back to
`UIScreen.main.isCaptured`, and listens for `capturedDidChangeNotification` and trait changes. It publishes one
`Bool`, `isCaptured`, which covers screen recording, Control Centre and app screen sharing, and AirPlay or cable
mirroring.

**Policy (pure, `PreviewCapturePolicy`):** `(blurOn, isCaptured, scope) → .raw | .filtered | .blank`. With the
blur on and the screen captured, `.onDevicePreview` consumers get `.filtered`: the preview switches to
`OutboundFrameRelay`'s filtered frames, the same blur pass the recording uses, so there is no second blur.
If the relay has no filtered frame within 500 ms the preview shows `.blank` with a short line ("Preview hidden
while the screen is shared"), never raw pixels. With the blur off nothing changes, as the wearer chose. When
capture stops, the preview returns to raw on the next frame.

**Roster.** `.livePreview` and `.phoneViewfinder` keep `.onDevicePreview`; their roster entries gain a
`switchesWhenCaptured` mechanism note, and `OutboundFrameConsumerTests` checks that every `.onDevicePreview`
view reads `PreviewCapturePolicy`. `leavesTheDevice` stays false: the scope no longer leaves the device unblurred,
which is what the flag promises.

**Not covered, and said in the privacy notice:** a screenshot (iOS reports it only after it is taken), and another
device filming the phone.

### 2. Native tools that send text out

**`NativeEgressProfile`** (new, declared on each native tool that sends model-written arguments off the device):
which argument keys leave, and to whom (a `NetworkRoute`). The first set is `web_search`, `find_nearby` and
`get_news`; a guard test scrapes `Services/NativeTools` for tools that reach `URLSession` or
`BoundedHTTPClient` and fails on one with no profile and no justified exemption, the same way the frame roster
works.

**Screen.** `NativeToolRouter` runs `EgressScreen.evaluate` on the profiled arguments of a native call before
authorization, exactly as it does for MCP, with policy `.block` (secrets and card numbers never go into a search
query; the reason is spoken as it is for MCP).

**Private-span rule (pure, `PrivateSpanCheck`).** The ledger gains two derived facts:
- `readExternalUntrusted`: an untrusted tool ran whose content came from outside the wearer. This is
  `untrustedOutputTools` minus our own stores listed above, so the rule does not fire on every memory lookup.
  The wearer's own documents stay untrusted for prompt framing; they count as private here, not external.
- `privateOutputs`: the captured results of private reads this turn (the health vault, notes, memory, contacts,
  calendar, messages, the job's customer details), by a `privateOutput` mark on those tools.

When both are present, every profiled outbound argument is checked for a copied span: five consecutive
normalised words, or 24 consecutive characters with no spaces, that also appear in a private output. A match
turns the call into one that needs the wearer's bound approval, spoken with what would be sent ("Search the web
for '…'? It includes something from your health notes."). No match, no prompt. Shingle hashes only; the
private text is not copied again.

### 3. The watch's photo commands

`capturePhotoAndSend` and `captureAndAnalyzePhoto` gain a result (`PhotoTurnResult`: `.answered(String)`,
`.cannotSee`, `.glassesNotConnected`, `.captureFailed`, `.modelFailed`, `.busy`), and the existing callers ignore
it. The watch handlers reply with `response` only on `.answered` and with `error` plus a short spoken-style line
otherwise. A request that comes from the watch passes `phoneCameraFallback: false`, so with no glasses it replies
"Glasses not connected" instead of presenting the phone camera. A second watch request while one runs replies
`.busy` at once. The watch shows the error line in place of an answer (`WatchConnectivityService` already reads
`error`).

### 4. Temple taps after the first (device check first)

The cause is not proven on iOS: the measurement that suggested it was made on another platform. So this item is
an experiment with a headless core.

- **`StandbyClaimPolicy`** (pure): what the silent claim does on a `pause` or `togglePlayPause` while it holds
  standby: today's `.keepPlaying`, or `.pauseThenResume(after: 3 s)`, which pauses the silent player, sets the Now
  Playing rate to 0, and restarts both after the delay or on the next command, whichever comes first. A tap that
  arrives during the pause is still a tap. Debounce: a pause followed by a play within 0.6 s is one tap.
- A Developer panel switch chooses between them, with the existing test mode announcing every command heard.
- **Device check:** ten single taps and five double taps on a Gen 2 and a Gen 1, after launch and after the wake
  word has reconfigured the session, with each policy. If `.pauseThenResume` hears them all and `.keepPlaying`
  does not, it becomes the default and the switch goes. If neither does, the item records the result and closes.

### 5. Wake-word alternatives only at the start

**`WakeAlternativePosition`** (pure): a candidate that is an alternative (its `phrase` differs from its `primary`)
and is a single token, or a phrase whose every token is an ordinary word (in the system lexicon,
`UITextChecker`, for the wake language), matches only at the start of an utterance. Optionally after one opener
from a short per-language list ("hey", "ok", "okay", "hi"). The start of an utterance is the first token of the
recogniser's current result, or the first token after a gap of at least 0.7 s where segment timestamps are
available. The primary phrase and invented-word alternatives keep matching anywhere, as now: "what's on my
list, Avenkin" must still wake.

A test corpus of 36 ordinary sentences containing common-word alternatives ("summary", "small tree", "even
kin") wakes on none; the same alternatives at the start wake on all.

### 6. Gemini Live: turn starts and deliberate stills (device A/B)

- **Start sensitivity** becomes a setting read by `GeminiLiveSetup` (`high` stays the default), so a device
  session can compare `low`. The check: ten minutes in a café and in a van with the radio on, each setting, counting
  turns started by room noise and turns missed. The setting that wins becomes the default; the other is removed
  unless they are close.
- **A deliberate still** (`sendHighResImage`: the photo tool, "what's this", a dwell capture) is sent as a
  `clientContent` turn: the image as `inlineData` plus one instruction line ("This photo was just taken by the
  wearer's camera; answer about it."), with `turnComplete` false so the wearer's words still lead. Streamed frames
  stay on `realtimeInput.video`. The check: twenty object questions with frame dedup on, old envelope against
  new, counting answers that describe something not in the photo.

### 7. Small fixes

- **Odd-length audio chunks.** `RealtimeAudioEngine` keeps a one-byte carry: an odd chunk's last byte is held and
  put in front of the next chunk; the carry is cleared on a new response, an interruption and a stop. Tests:
  odd-then-odd, odd-then-interrupt, even only.
- **Glasses off.** `glassesWornChanged(false)` starts the grace only when this connection has read `worn == true`
  at least once (`GlassesConnectionSnapshot` gains `seenWornThisConnection`, cleared on disconnect). A first
  reading of "off" is logged and otherwise ignored. Tests through `GlassesSleepPolicy`.
- **Session ended by device.** The notice adds: "If it ends just after it starts, open Meta AI and check for a
  glasses update."
- **Web mirror icon.** `WebHUDMirrorServer` serves a 192 px and a 512 px PNG (the app mark on black, monochrome
  friendly) and `/manifest.webmanifest` (name, `display: standalone`, theme colour black); the page's `<head>`
  links both. PNG, not SVG; the router test covers the new paths, all read-only and behind the same token. The
  rest of the mirror's lifecycle stays item 3 of ID, which gains notes in this PR: when the page is hidden, pause
  rather than end, and end after 10 minutes; while hidden, don't treat the phone as gone (the browser slows
  timers); restart on `pageshow` with `persisted`.

## Phases

One PR for P0, as the house rhythm prefers; the device checks follow.

- **P0 — everything headless.** Items 1, 2, 3, 5 and 7 in full; items 4 and 6 as their policies, the settings and
  the Developer switch, with today's behaviour as the default. Tests:
  `PreviewCapturePolicyTests`, `OutboundFrameConsumerTests` (capture rule), `NativeEgressProfileGuardTests`,
  `NativeToolRouterEgressTests` (a secret in a search query is withheld; no profile, no screen bypass; the
  private-span rule also applies to MCP and gateway calls, after `EgressScreen`),
  `PrivateSpanCheckTests` (five-word and 24-character spans; memory-only turns never prompt; no external read,
  no prompt), `WatchPhotoReplyTests` (each `PhotoTurnResult` maps to its reply; no stale response; no phone camera
  from the watch; busy), `StandbyClaimPolicyTests`, `WakeAlternativePositionTests` with the 36-sentence corpus,
  `GeminiLiveStillEnvelopeTests`, `RealtimeAudioCarryTests`, `GlassesSleepPolicyTests` additions, the notice
  wording test, `WebHUDMirrorServerTests` additions. **Exit:** full suite and a Release build green.
- **P1 — device checks.** The screen-capture switch with a screen recording, a FaceTime share and AirPlay; item 4's
  tap counts; item 6's two A/B runs; a watch photo with the glasses off and with a capture failure. Each result
  goes in As built, and items 4 and 6 settle their defaults in a short follow-up PR.

## As built

### P0, items 1–3 (2026-11-14)

**Item 1 — the preview while the screen is captured.**
- `ScreenCaptureState` (`Services/Vision/ScreenCaptureState.swift`): one `@MainActor` observable, `shared`,
  publishing `isCaptured`. It reads `sceneCaptureState` from the foreground window scene's traits, watches the
  trait on that scene's key window (`registerForTraitChanges([UITraitSceneCaptureState.self])`; a window inherits
  the scene's traits, and a window is certain to be trait-observable), re-picks the scene on scene activation and
  foreground, and listens for `UIScreen.capturedDidChangeNotification`. An `.unspecified` reading falls back to
  that scene's screen's `isCaptured`, read through a small protocol so the deprecated flag compiles without a
  warning. The plan's `UIScreen.main` fallback became the scene's own screen (`UIScreen.main` is deprecated).
- `PreviewCapturePolicy` (`Services/Vision/PreviewCapturePolicy.swift`), pure:
  `decide(blurOn:isCaptured:scope:hasFilteredSource:) → .raw | .filtered | .blank` and
  `resolve(_:filteredFrameAge:)`, which turns `.filtered` into `.blank` unless the relay's latest frame is at most
  `filteredFrameWait` (0.5 s) old. The plan's `(blurOn, isCaptured, scope)` gained `hasFilteredSource`, because
  the two preview surfaces differ: the glasses frames pass the relay, the phone viewfinder's never do.
- `LivePreviewView` applies it to both surfaces. The glasses preview draws `outboundFrames.publisher`'s frames
  (kept only while the decision is `.filtered`, cleared when capture stops) inside a 0.25 s `TimelineView`, so a
  relay that stops producing blanks the picture within 0.5 s; before the first filtered frame it is blank. The
  phone viewfinder is not drawn at all while captured with the blur on (no filtered source), and its "not
  blurred" caption goes with it. The blank shows "Preview hidden while the screen is recorded or shared."; the
  filtered picture's accessibility label says faces are blurred. A held-picture state with no frame yet keeps
  its existing placeholders (they show no pixels).
- Roster: `OutboundFrameConsumer.switchesWhenCaptured` (`.toRelayFrames` for `.livePreview`, `.toBlank` for
  `.phoneViewfinder`, nil elsewhere) and `capturedScreenPolicyHost` (`LivePreviewView`). Mechanism stays
  `.exemptByScope`, scope stays `.onDevicePreview`, `leavesTheDevice` stays false; the scope's and both cases'
  documentation say why.
- Privacy copy: the glasses variant of the Blur Bystander Faces explanation (`BystanderBlurSwitch`) gains "While
  the screen is recorded, shared or mirrored, the camera preview shows only blurred frames; a screenshot, or
  another device filming the phone, isn't covered." The same edit drops that string's stale sentence about faces
  enrolled for recognition (face recognition was removed 2026-11-13). The key changed, so it needs the next
  catalog sync and its translations.

**Item 2 — native tools that send text out.**
- `NativeEgressProfile` (`Services/Security/NativeEgressProfile.swift`): argument keys that leave, the
  `NetworkRoute` (nil for MapKit, Apple's own request), and the verb the ask opens with. Declared through a new
  `NativeTool.egressProfile` requirement (default nil) by `WebSearchTool` (`query`, `.webSearch`),
  `LocationSearchTool` (`query`, Apple Maps) and `NewsTool` (`topic`, `.newsHeadlines`). `translate` has none.
- `NativeToolRouter` screens a profiled native call's outbound arguments with `EgressScreen.evaluate(…, .block)`
  before authorization, beside the MCP screen; a hit is refused with a "do not retry" reason naming the pattern
  (never the value) and `PrivacyLog` `egressWithheld`, and a plan's preflight treats it as nothing to ask.
  Unprofiled arguments of the same call are not screened. **Note:** `SecretPatterns` has no card-number
  pattern today, so "card numbers" in Design §2 is not yet true; and because it does match e-mail addresses and
  NZ IRD-shaped numbers, `.block` refuses a search containing one.
- `PrivateSpanCheck` (`Services/Security/PrivateSpanCheck.swift`), pure. `readExternalUntrusted` is
  `PromptInjectionPolicy.isUntrustedOutput` over completed calls, minus our own stores (`memory_search`, `brain`,
  `my_memory`, `notes_vault`, `health_vault`, `document_knowledge`, `remember_scene`, `session_search`); a call
  still running has read nothing. The private mark is a table, `privateOutputTools`, rather than a property on
  each tool: health vault, Apple Health (`health_summary`, `health_check`), notes (`notes_vault`, `list_notes`,
  `contextual_note`, `project_note`), memory (`memory_search`, `my_memory`, `brain`, `session_search`,
  `remember_scene`), `document_knowledge`, `lookup_contact`, `calendar`, `reminder` and `field_session` (the
  job's customer details), native only. No tool reads messages back, so messages are not on it. A copy is five
  consecutive folded words, or a 24-character window inside a run with no whitespace; the outbound text is
  hashed, each private output is walked once and looked up, nothing of it is kept.
- The ledger (`AttemptToolLedger`) gains `privateSpanReads`, `readExternalUntrusted`, `readPrivateOutput` and
  `hasCallInFlight(tool:)`. The router reads it through a new `turnLedger` seam (AppState wires the Direct-mode
  turn's ledger) and applies the rule only to a call the ledger shows in flight — so live sessions, which keep no
  ledger, are not judged against an earlier turn's reads (and are not covered).
- The answer rides `ToolAuthorizationPolicy.Input.privateSpan` (`PrivateSpanAsk`), applied last and only
  strengthening: an `allow` becomes a bound `.confirm` whose summary is what would be sent, where, and where the
  copied part is from ("Search the web for “…”. It includes something from your health notes."); an ask already
  being made gets that last sentence appended. It covers native profiled tools, MCP calls (after `EgressScreen`,
  on the screened arguments), user-authored HTTP tools and the gateway. A plan step's grant is not spent on a call
  the rule caught: it asks on its own. `PrivacyLog` gains `privateSpanCopied` (tool name only).

**Item 3 — the watch's photo commands.**
- `PhotoTurnResult` (`Services/WatchPhotoReply.swift`) is returned, `@discardableResult`, by
  `capturePhotoAndSend(prompt:phoneCameraFallback:)` and `captureAndAnalyzePhoto(glassesOnly:phoneCameraFallback:)`.
  It has one case more than the plan: `.phoneCameraOpened`, for the existing no-glasses path that presents the
  phone camera (never a watch request's result). `phoneCameraFallback: false` also stops the capture's own phone
  fallback.
- `WatchPhotoReply.dictionary(for:)`: `response` only for `.answered`, else `status: failed` and `error` with a
  short line ("Glasses not connected.", "Couldn't take the photo.", …). `WatchPhotoGate` answers a second request
  `.busy` at once, and also when the app is mid-turn (`isProcessing`, the same check dictation makes).
- `WatchConnectivityManager`: `photo`, `describe`, the photo and prompt quick actions and the custom-prompt
  default all go through one `watchPhotoTurn` with `phoneCameraFallback: false`; the recording quick action no
  longer sends the last answer as its reply.
- Watch: `WatchConnectivityService` already turns `error` into the command's error. `WatchMainView` drew the
  error under the previous answer, so a quick action that comes back with an error now hides that answer until
  the next action.

**Tests:** `PreviewCapturePolicyTests`, `OutboundFrameConsumerTests` (three capture-rule tests),
`NativeEgressProfileGuardTests` (the scrape covers `URLSession`, `BoundedHTTPClient` and `MKLocalSearch(`; five
justified exemptions: QR context, Home Assistant, aircraft overhead, gateway skills, currency),
`NativeToolRouterEgressTests` (the gateway half is covered at the policy and phrasing level, not through a live
bridge), `PrivateSpanCheckTests`, `WatchPhotoReplyTests` (pure mapping and gate, plus a source read of the
handler, since `AppState` cannot be stood up headless). 38 new tests (7 + 3 + 4 + 9 + 10 + 5), all passing on the
iPhone 17 Pro simulator alongside the existing router, MCP, frame-roster, privacy-filter, tool-effect, privacy-log
and watch classes (352 tests, 0 failures). Full suite and Release build not yet run.

**Left after items 1–3:** the P1 device checks (a screen recording, a FaceTime share and AirPlay; a watch photo
with the glasses off and with a capture failure); the catalog sync for the new strings. Candidates the guard does
not reach yet: `qr_context` fetches a model-passed URL, and directions or geocoding tools that send a typed place
to Apple are not on the network scrape.

### P0, items 4–7 (2026-11-14)

**Item 4 — temple taps after the first.**
- `StandbyClaimPolicy` (`Services/Triggers/StandbyClaimPolicy.swift`), pure: `.keepPlaying` (the default, today's
  behaviour) or `.pauseThenResume`. In the second, a `pause` or `togglePlayPause` while the silent player plays is
  `.pause(resumeAfter: 3)`; the next command of any kind, or the delay, is `.resume`; a command during the pause is
  still a tap, except a `play` within 0.6 s of the pause, which is the same tap (`countsAsTap: false`).
- `MediaTriggerService` reads the mode (`Config.standbyClaimMode`, key `standbyClaimMode`) at each claim, shows every
  command under a standby claim to the policy before the decoder (so a paused player resumes on the next command
  whether or not it fires a tap), times the resume with the same injected `sleep` as the settle re-check, and forgets
  a pause on release or a fresh claim. Session control never pauses (no player). The dropped half of a pair logs
  `commandDropped` with `pairedResume`; pause and resume log `claimPaused` / `claimResumed` with the session shape.
- `NowPlayingClaiming` gains `pauseStandby()` / `resumeStandby()`. `SilentNowPlayingClaimer` pauses the player and
  publishes `MPNowPlayingInfoPropertyPlaybackRate: 0`, and its `standbyClaimLive` stays true while paused this way,
  so the claim's health check does not read a deliberate pause as a lapsed claim and retake it. A pause during the
  session's activation holds the pending start back; the resume plays it.
- Developer panel → Temple Taps → "Pause after a tap" (glasses builds only); switching it retakes the claim.
  The existing Temple Taps test mode announces every tap heard; a dropped command is in the support log, not spoken.
- **Note:** the service's 1 s tap debounce (`TriggerGate`) still drops a second tap inside a second of the last one
  that fired, in either mode, so the 0.6 s pair window only changes what the log says for a quick pair.
- **P1 must check:** on a Gen 2 and a Gen 1, ten single and five double taps after launch and after the wake word has
  reconfigured the session, in each mode, counting taps heard (test mode) against taps made. Also whether a rate of 0
  makes the lock screen show a paused widget (harmless) and whether iOS gives Now Playing to another app during the
  3 s pause.

**Item 5 — wake-word alternatives only at the start.**
- `WakeAlternativePosition` (`Services/Flow/WakeAlternativePosition.swift`), pure: `isStartBound` (an alternative —
  tokens differ from its primary's — whose every token the lexicon knows), `utteranceStarts(tokenCount:segments:)`
  (token 0, and the first token of a segment after a gap of at least 0.7 s; segments that do not tokenise to the
  transcript's count are not trusted, so only 0), `allowedStarts` (each start, and the next token when the start is an
  opener) and `openers(forLanguage:)` (hey, ok, okay, hi everywhere; a few greetings for de, fr, es, it, pt, nl).
- `WakePhraseMatcher.Candidate` gains `startOnly`; `match` and a new `detailedMatch` honour it in all three passes
  (exact whole-token, fuzzy windows begin only at allowed starts, unspaced-script tokens only from the token's
  beginning). `WakeWordService` now calls `detailedMatch` instead of its own copy of the three passes, passes the
  recogniser's `bestTranscription.segments`, and marks candidates with `WakeLexicon` (`UITextChecker` in the
  recogniser's locale, cached per word; a locale with no dictionary makes nothing ordinary, so behaviour there is
  unchanged). Transliterated candidates inherit the mark.
- **Note:** only the alternative is bound. A primary's own fuzzy allowance can still reach an ordinary phrase
  anywhere ("hey cloud" is two edits from "hey claude"), and an invented-word alternative can sit within fuzzy reach
  of ordinary words ("aven kin" is one edit from "even kin"); both are as before. Persona alternatives such as "read
  this" and "travel mode" are now start-only too.
- **P1 must check:** partial results on the device — whether segment timestamps arrive before a result is final
  (if not, the gap rule only helps on final results, and the first token is the only start for partials).

**Item 6 — Gemini Live turn starts and deliberate stills.**
- `GeminiLiveStartSensitivity` (`.high`, the default, or `.low`) is a `GeminiLiveSetup.body` parameter, read from
  `Config.geminiLiveStartSensitivity` (key `geminiLiveStartSensitivity`) at each setup. Developer panel → Gemini Live
  → "Less sensitive turn starts". End sensitivity, silence and padding are unchanged.
- `LiveInjectionEnvelope.geminiStill(base64JPEG:)` replaces `geminiImage`: a user `clientContent` turn with the image
  as `inlineData` then the line "This photo was just taken by the wearer's camera; answer about it.", and
  `turnComplete: false`. `GeminiLiveService.sendHighResImage` (both `look_closely` and an injected pin) uses it; the
  ~1 fps stream stays `realtimeInput.video`. OpenAI and the JSON adapters are untouched.
- **Note:** the plan's "photo tool" and "dwell capture" do not reach Gemini Live through `sendHighResImage`: the only
  callers are `look_closely` and the pinned frame. A Live `clientContent` message interrupts generation in progress,
  so a pin injected while the model is speaking may now cut it off where the video lane did not.
- **P1 must check:** the café and van A/B for start sensitivity; the twenty object questions old envelope against new
  (the old one is in git history at ec97c4958); and that `look_closely`'s still, sent while its function call is
  pending, is accepted before the tool response rather than refused or answered on its own.

**Item 7 — small fixes.**
- `PCMByteCarry` (`Services/Audio/PCMByteCarry.swift`), pure: holds the bytes past the last whole frame
  (`bitsPerSample / 8 × channels`) and puts them in front of the next chunk. `RealtimeAudioEngine.playAudioOnQueue`
  aligns every chunk first, even one it then drops, so the stream keeps its boundary; the carry is cleared in
  `resetPlaybackProgress` (turn complete), `stopPlaybackOnQueue` (barge-in) and `stopCapture`, not on a graph rebuild
  mid-reply.
- `GlassesConnectionSnapshot.seenWornThisConnection`: set by a connected `liveWorn == true`, cleared whenever the phase
  is not connected. `GlassesSleepPolicy.doffGraceApplies` gains `seenWornThisConnection` (required, so no caller can
  forget it); `AppState.glassesWornChanged` passes it at the start and the end of the grace, and logs a first "off"
  as `doffBeforeDon` instead of timing it.
- `DeviceSessionFailureReason.sessionEndedByDevice` adds "If it ends just after it starts, open Meta AI and check for a
  glasses update." **Deviation:** with the new sentence the old notice was 218 characters and the spoken-error gate
  (`SpokenErrorPolicy.looksHuman`) refuses anything over 200, so the rest was shortened: "End any broadcast in Meta
  AI, or close the glasses in their case for a minute." (194 in all).
- `WebHUDLauncher` (`Services/Display/WebHUD/WebHUDLauncher.swift`): `/icon-192.png`, `/icon-512.png` (the
  `AvenkinMark` asset drawn white inside the middle 60 % of a black square, scale 1, cached) and
  `/manifest.webmanifest` (`application/manifest+json`: name, `display: standalone`, black theme and background, both
  icons). All need `?t=`, like `hud.json`; HIPAA and non-GET refuse them as everything else. Because the token lives in
  the page's hash, the `<head>` carries the `manifest`, `icon` and `apple-touch-icon` links with no `href`, and the
  page script fills them in with the token; the manifest's icon URLs carry it too, and its `start_url` is `/#t=<token>`
  so a launcher opens a page that can poll. Purpose `any`, not `monochrome`: that purpose reads only alpha and the
  icon is opaque. ID item 3's lifecycle notes were already added with the docs PR.
- **P1 must check:** "Add to Home Screen" on the Display web view and on an Android browser, with the icon showing,
  and that rotating the token breaks the installed launcher (expected) rather than serving the old one.

**Cleanups in the same commit:** the `watchPhotoTurn` comment sat under `startGuidance`'s; each is now on its own
function. The watch's recording quick action replies `status` only (the watch sets its status and taps success,
with no answer shown) and now says "Recording didn't start." as an `error` when a start did not take, which the
watch shows in place of an answer.

**Tests:** `StandbyClaimPolicyTests` (9), six `MediaTriggerServiceTests` additions (keep playing never pauses; pause,
live while paused, resume after the delay; a tap during the pause; the pair window; release forgets a pause; session
control never pauses), `WakeAlternativePositionTests` (the 36-sentence corpus wakes on none and did wake before the
rule; the same alternatives at the start, after an opener and after a 0.7 s pause wake; fuzzy and unspaced passes
keep the rule; the system lexicon on the runtime), `GeminiLiveStillEnvelopeTests` (envelope shape, the two paths
read from source, the sensitivity default and setup), `RealtimeAudioCarryTests` (even only, odd-then-odd,
odd-then-interrupt, stereo, and the engine's three clears read from source), three `GlassesSleepPolicyTests`
additions, `DeviceSessionFailureNoticeTests`, `WebHUDMirrorServerTests` (token on each path, HIPAA and read-only, PNG
of the right size, manifest content, the page head). `LiveInjectionTests` loses the old video-lane image test.
54 new tests. On the iPhone 17 Pro simulator: the new and related classes (37 classes, 499 tests; one float-edge
assertion in the pair-window test fixed and its two classes re-run, 58 tests, 0 failures), then the full unit suite
(16,948 tests, 16 skipped, 0 failures) and a Release build for the simulator, both green. **P0 exit met.**

## Decisions for Greig

1. **What the preview does when the screen is captured with the blur on.** *Taken 2026-11-14 as recommended:* show the filtered
   frames (blank only if none arrive in 500 ms). *Alternative:* always blank while captured, simpler and certain,
   but it makes a deliberate demo or a support screen share useless.
2. **The private-span rule's answer.** *Taken 2026-11-14 as recommended:* ask the wearer, with what would be sent. *Alternative:* block
   outright. Asking keeps "search for the dose in my notes" possible on purpose; blocking is stricter but would
   refuse some honest requests with no way through.
3. **Whether the rule also covers MCP and the gateway.** *Taken 2026-11-14 as recommended:* yes, the same check
   after `EgressScreen`, since the same leak is possible there, in P0. *Alternative:* native tools only in P0, MCP later.
4. **Watch requests with no glasses.** *Taken 2026-11-14 as recommended:* reply "Glasses not connected" and do nothing. *Alternative:*
   take the photo with the phone's back camera without a viewfinder. That is useful only when the phone is
   propped up facing the work, and surprising otherwise.

## Out of scope

The new features found in the same review (spoken coaching while recording, wording-based safety reminders, a
private conversation (now Plan [LU](LU-private-conversation.md)), a battery forecast, a QR safety check, photo-based machine matching, sharpest-frame choice,
a text crop for vision, and others). They are noted for their own plans. The changes to how GX judges a photo are
in GX's own amendment.
