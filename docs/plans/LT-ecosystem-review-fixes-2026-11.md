# Plan LT — Fixes from the November 2026 Ecosystem Review (our own defects, found by looking at adjacent work)

**Status:** 📝 Drafted 2026-11-14 — nothing implemented.
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
  `NativeToolRouterEgressTests` (a secret in a search query is withheld; no profile, no screen bypass),
  `PrivateSpanCheckTests` (five-word and 24-character spans; memory-only turns never prompt; no external read,
  no prompt), `WatchPhotoReplyTests` (each `PhotoTurnResult` maps to its reply; no stale response; no phone camera
  from the watch; busy), `StandbyClaimPolicyTests`, `WakeAlternativePositionTests` with the 36-sentence corpus,
  `GeminiLiveStillEnvelopeTests`, `RealtimeAudioCarryTests`, `GlassesSleepPolicyTests` additions, the notice
  wording test, `WebHUDMirrorServerTests` additions. **Exit:** full suite and a Release build green.
- **P1 — device checks.** The screen-capture switch with a screen recording, a FaceTime share and AirPlay; item 4's
  tap counts; item 6's two A/B runs; a watch photo with the glasses off and with a capture failure. Each result
  goes in As built, and items 4 and 6 settle their defaults in a short follow-up PR.

## Decisions for Greig

1. **What the preview does when the screen is captured with the blur on.** *Recommended:* show the filtered
   frames (blank only if none arrive in 500 ms). *Alternative:* always blank while captured, simpler and certain,
   but it makes a deliberate demo or a support screen share useless.
2. **The private-span rule's answer.** *Recommended:* ask the wearer, with what would be sent. *Alternative:* block
   outright. Asking keeps "search for the dose in my notes" possible on purpose; blocking is stricter but would
   refuse some honest requests with no way through.
3. **Whether the rule also covers MCP and the gateway.** *Recommended:* yes, the same check after `EgressScreen`,
   since the same leak is possible there. *Alternative:* native tools only in P0, MCP later.
4. **Watch requests with no glasses.** *Recommended:* reply "Glasses not connected" and do nothing. *Alternative:*
   take the photo with the phone's back camera without a viewfinder. That is useful only when the phone is
   propped up facing the work, and surprising otherwise.

## Out of scope

The new features found in the same review (spoken coaching while recording, wording-based safety reminders, a
private conversation, a battery forecast, a QR safety check, photo-based machine matching, sharpest-frame choice,
a text crop for vision, and others). They are noted for their own plans. The changes to how GX judges a photo are
in GX's own amendment.
