# Plan ID: Hardening Bundle from the October 2026 Ecosystem Review

**Status:** 🚧 Item 1 shipped 2026-10-10 (PR #PRNUM); items 2 to 8 unbuilt. A checklist plan: each item is its own small,
direct PR with a test, in any order, and is ticked here (with its PR number) when it merges. Item 7
is tracked in Plan [FG](FG-workflow-vaults-and-enterprise-auth.md) and only referenced here.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md), sections 3 and 4
(and section 5 for item 8). Each item was found by comparing an outside technique with our tree
and confirmed in our code; the techniques are described here on their own merits.
**Priority:** Item 1 is safety work and goes first (the review's recommended batch puts it first).
The rest are S or XS and can be picked up in any gap.

Evidence under `OpenGlasses/Sources/` unless noted; line numbers as recorded by the review at
`7a0cc0e0`, re-read on `main` at `48bcae0c`.

House rules for every item: a pure core with a unit test first; full suite and Release build green;
`SWIFT_EMIT_LOC_STRINGS=NO` on headless builds; the privacy-logging gate; no plan letters in any
string a user sees; this file's checklist and the index row updated in the same PR.

---

## Checklist

- [x] **1. Stale navigation hazard advice expires** (S, Plan [J](J-low-vision-navigation.md)):
  done 2026-10-10, [#PRNUM](https://github.com/straff2002/OpenGlasses/pull/PRNUM).
- [ ] **2. Broadcast frame pacing on a deadline** (S, Plan [CY](CY-broadcast-resilience-and-quality.md)'s surface).
- [ ] **3. Web mirror page sized to the device and quiet while hidden** (XS, Plan [BP](BP-web-hud-mirror.md)).
- [ ] **4. Gateway hosts typed without a scheme** (S).
- [ ] **5. A second cloud voice from the OpenAI key** (S-M).
- [ ] **6. `framegate-probe` replay script** (S).
- [ ] **7. OAuth single-flight refresh, failure classes and a forced refresh on 401** (S): tracked
  as Plan FG's 2026-10-10 amendment.
- [ ] **8. Face recognition accuracy measurement and comment fix** (S, measurement only).

---

## 1 · Stale navigation hazard advice expires

**Defect.** `NavigationAssistService.tick()` (`Services/Accessibility/NavigationAssistService.swift:89-112`)
captures a frame, awaits the model, and speaks whatever comes back. The loop runs every 2.5 s
(`:18`) but nothing records when the frame was taken, so a slow reply about a kerb is spoken after
the wearer has passed it. For a blind wearer, advice about where they were is worse than none.

**Fix.** Stamp `CACurrentMediaTime()` when the frame is captured. A pure
`NavigationAdviceFreshness.isFresh(capturedAt:now:maxAge:)` drops advice older than
`Config.navigationAdviceMaxAge` (default 5 s) before it reaches the HUD or speech, and a counter
records drops (`PrivacyLog` event, count only). High-urgency advice gets no exemption: stale is
stale. The loop's next tick takes a new frame as today.

**Test.** `NavigationAssistTests` with a slow model fake (reply after 6 s → not spoken, drop
counted; after 2 s → spoken) and an injected clock. Never apply a call budget here (Plan
[HY](HY-live-session-hygiene.md) P2 states the exemption).

**Built 2026-10-10 ([#PRNUM](https://github.com/straff2002/OpenGlasses/pull/PRNUM)).** As specified, with
these details: the pure policy is `NavigationAdviceFreshness.isFresh(capturedAt:now:maxAge:)`
(`Services/Accessibility/NavigationAdviceFreshness.swift`); an age exactly at the limit is fresh,
and an impossible age (negative or not finite) fails closed. `tick()` stamps the injected
`clock` (default `CACurrentMediaTime()`) just before it fetches the filtered still, so the age
includes filtering as well as the model, and `freshAdvice(capturedAt:analyze:)` checks it once
the reply is back; nothing awaits between that check and the HUD and speech. A drop increments
`staleAdviceDrops` (reset on start) and logs `PrivacyLog.vision(.navigationAssist, .adviceExpired)`
with the frame's age in milliseconds and the drop count only. The threshold is the constant
`Config.navigationAdviceMaxAge` (5 s), not a setting. Tests: `NavigationAssistTests` (policy
fresh/stale/boundary/fail-closed; slow model fake at 2 s spoken, 6 s dropped and counted, high
urgency not exempt, exactly 5 s spoken, unparseable replies not counted; injected and default
clock).

## 2 · Broadcast frame pacing on a deadline

**Defect.** `BroadcastService.handleFrame` paces the main source by wall-clock gap: push only if at
least `0.9 / targetFPS` has passed since the last push (`Services/BroadcastService.swift:506-511`).
Against a 30 fps phone source a 24 fps setting sends roughly every other frame, about 15 fps,
because a frame arriving 33 ms after the last push is early for 37.5 ms and the next one is the
first accepted.

**Fix.** Pure `FramePacer` with a deadline on `CACurrentMediaTime()`: push when `now >= due`, then
`due = max(now, due + 1/fps)`. The `max` keeps a long gap from causing a burst. `handleFrame` asks
the pacer instead of comparing dates. The secondary-source cache path is unchanged.

**Test.** `FramePacerTests`: a 30 fps arrival stream at 24 fps target yields 24 ± 1 pushes per
simulated second; 15 at 15; a two-second gap does not burst. Plan
[DR](DR-broadcast-resilience.md)'s P1 (amended 2026-10-10) owns the spoken notices and phone
fallback on the same file; this item is independent of it.

## 3 · Web mirror page sized to the device and quiet while hidden

**Defect.** `WebHUDRenderer` writes `<meta name="viewport" content="width=600, …">`
(`Services/Display/WebHUD/WebHUDRenderer.swift:47`), fixes `html, body` at 600 × 600 px (`:52`), and
polls on a `setInterval` with no `visibilitychange` handling (`:140-152`), so a hidden page keeps
fetching `hud.json`. Meta's current web-app guidance is a device-width viewport and no work while
hidden.

**Fix.** `width=device-width, initial-scale=1`; `html, body` at 100 % with the existing additive
black; on `visibilitychange` to hidden, clear the interval; on visible, poll once immediately and
restart it. Inline mode is unchanged.

**Test.** `WebHUDMirrorTests`: the rendered HTML carries the device-width viewport and no fixed
pixel body size, and the script registers a `visibilitychange` listener (string assertions over
the pure renderer, as the existing injection-safety tests do). BP's platform section gets one
sentence in the same PR.

## 4 · Gateway hosts typed without a scheme

**Defect.** `GatewayConfig.lanURL` builds `host:port` with no scheme
(`Models/GatewayConfig.swift:72-81`); `EndpointPolicy.validate` then rejects it as
`disallowedScheme` (`Services/Security/EndpointPolicy.swift:69-71`). Typing "nuc" or "box.tailnet.ts.net"
fails with a scheme error the wearer did not cause.

**Fix.** Pure `GatewayAddress.normalise(_:)`: keep any explicit scheme; otherwise `http` for
localhost, private and link-local addresses, 100.64/10, `.local` names, dot-less names, and
`*.ts.net` names given with an explicit port; `https` for everything else. The private-range
classification reuses `URLFetchGuard`'s (`Services/URLFetchGuard.swift`). Applied to the OpenClaw
gateway host, the Home Assistant URL (`Config.homeAssistantURL`) and the Hermes bridge host
(`App/Views/HermesBridgeSettingsView.swift`). The normalised URL still goes through
`EndpointPolicy`; normalising never overrides a refusal (a cleartext public host stays refused).
The settings field shows the normalised form after editing so the wearer sees what will be used.

**Test.** `GatewayAddressTests` (a table: bare name, IPv4 private, IPv4 public, IPv6 unique-local,
100.64 address, `.local`, `*.ts.net` with and without port, explicit `https://`, trailing slash,
whitespace) and one `EndpointPolicy` case showing a normalised cleartext public host is still
refused.

## 5 · A second cloud voice from the OpenAI key

**Gap.** The engines are ElevenLabs, Kokoro and the system voice
(`Services/TTS/TTSEngineSelector.swift:5-11`). A wearer with only an OpenAI key, which many have for
the LLM, gets no cloud voice. The privacy manifest names ElevenLabs only
(`Resources/PrivacyInfo.xcprivacy:57`).

**Fix.** `TTSEngine.openAI`: posts text to the OpenAI speech endpoint (`/v1/audio/speech`) with the
Keychain key the LLM already uses, a fixed model and voice chosen in Settings, and audio returned as
AAC or MP3 into the existing player. It sits after ElevenLabs in the fallback chain and before
Kokoro, and reuses `CloudVoiceRejection` handling. Egress rules in the same PR:
`MedicalEgressGuard` blocks it under Medical Local Only and HIPAA mode; a new `EndpointPolicy`
route; the network route registry entry; `PrivacyInfo.xcprivacy` and the in-app privacy copy name
the new recipient (`TelemetryOptOutGuardTests` and the privacy-manifest pairing enforce the
same-PR rule).

**Test.** `TTSEngineSelectorTests` (chain order with and without each key; Medical mode removes
it); a request-shape test through the `URLProtocol` stub (headers, body, no key in the URL); the
manifest test. A live-key check is owed after merge.

## 6 · `framegate-probe` replay script

**Gap.** `FrameGate` (Plan AT), `PageTurnDetector` (reading companion) and `NarrationGate` (Plan
[CV](CV-continuous-scene-narration.md)) carry thresholds nobody has measured
(`Services/Vision/NarrationGate.swift:5-7`); AT's default-on decision waits on a motion check.

**Fix.** `Scripts/framegate-probe.swift`, a macOS command-line script in the style of
`Scripts/extract-manual-text.swift`: input a folder of JPEGs or a recorded video sampled at N fps;
run each frame through `PerceptualHash` and `FrameGate` (and optionally `PageTurnDetector`) with
thresholds from flags; print per frame the distance and decision, and per minute the number of
sends. A script cannot import the app module, so the probe is built with `swiftc` from its own
file plus the gate sources (`Services/Vision/PerceptualHash.swift`, `Services/Vision/FrameGate.swift`
and their pure dependencies), which keeps one implementation of each gate: the probe and the app
cannot disagree. A `--self-check` mode, as `extract-manual-text.swift` has, runs the fixture.
Nothing leaves the desk.

**Test.** A small fixture folder (three identical frames, one changed) under `Scripts/tests/` with
an expected-output check run in CI only when the script or the gate sources change. A simulator
`ReplayCameraBackend` for demos can follow as its own item.

## 7 · OAuth refresh: single-flight, failure classes, forced refresh on 401

**Defect.** `ChatGPTOAuthService.validAccessToken` (`Services/ChatGPTOAuthService.swift:134-155`),
`ClaudeOAuthService` (`:91-109`) and `GoogleOAuthService` (`:86-101`) each refresh when near expiry,
with no coordination: two callers in the refresh window both spend the same rotating refresh token,
the loser gets `invalid_grant` and signs the wearer out. Any failure, a network blip included, sets
"sign-in expired, please sign in again" (`ChatGPTOAuthService.swift:152`). `LLMService` classifies a 401 but never retries it
with a fresh token (`Services/LLMService.swift:2171-2173`).

**Home.** Plan FG P1 already specifies single-flight refresh for its enterprise OAuth model and is
not built. Rather than two implementations, FG's 2026-10-10 amendment pulls the shared
`SingleFlightRefresher` forward as a standalone PR that the three subscription services adopt
first and FG P1 reuses. The design and tests are written there; this item is ticked when that PR
merges.

## 8 · Face recognition accuracy measurement and comment fix

**Added to this bundle on purpose.** The review lists it as a correction, not a feature, and it has
no other home. `FaceRecognitionService` stores a `faceprint` described as a "128-dim face embedding
vector" (`Services/FaceRecognitionService.swift:17`), but computes it with
`VNGenerateImageFeaturePrintRequest` on the face crop (`:297`), a generic image feature print. An
outside measurement found that approach scores different people above the same person at glasses
resolution.

**Task (measurement only, no feature change).** Correct the comment to say what the vector is.
Write a headless probe test over a small set of synthetic or consented reference crops at the
stream's resolution that reports same-person and different-person distance distributions under the
current threshold. Record the result in `docs/eu-ai-act-review-2026-10.md` §3.1 as Article 15
accuracy evidence. If the distributions overlap, the record says so; any change to the matcher is a
separate decision, not part of this item. Face recognition stays opt-in and is not expanded.

**Test.** The probe test itself, plus an assertion that the threshold constant it measured is the
one the service uses.

---

## Dependencies

- **J** (✅), **CY** (🚧 core shipped), **BP** (✅ P1 and P2), **AT** (🚧 core shipped), **CV** (✅
  P1 to P3), **FG** (📝 drafted, P1 unbuilt; index and file agree), **HP** and **HS** (face
  recognition opt-in and the storefront gate, both built).
- **DR**: independent; same broadcast file as item 2.
