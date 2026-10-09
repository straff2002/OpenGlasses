# Ecosystem review, October 2026

**Research date:** 9 October 2026

**Status:** Engineering review of outside work since the 7 September sweep. Recommendations only; not an implementation commitment. Code reviewed: `main` at `7a0cc0e0` (build 480).

Related: [Cross-vendor AI glasses support](cross-vendor-ai-glasses-research.md), [EU AI Act review](eu-ai-act-review-2026-10.md), [Plans index](plans/README.md), [Agent harness wire contract](agent-harness-wire-contract.md).

Earlier sweeps: 2 August, 21 August, 27 August and 7 September 2026. This one covers what moved since. Evidence paths are relative to `OpenGlasses/Sources/` unless they start with `docs/`, `OpenGlasses/` or `OpenGlassesTests/`. Outside sources are cited as `[A1]` to `[A29]`; names are in Appendix A only.

## 1. Executive summary

Six weeks after the DAT 1.0.0 release, the ecosystem has three live currents. Meta is steering the Ray-Ban Display toward browser apps that Meta AI drives through WebMCP. Hobby and research work has converged on glasses as a voice front end for desk coding agents. The Even G2 community has published field findings about BLE sessions that contradict one of our design decisions.

Few new features are worth copying. Most of the value this round is in defects and small hardenings that outside code exposed in our own tree: a keyframe test that probably never fires on real glasses, a silent glasses link drop, stale hazard advice, an OAuth refresh race, a one-arm Even "ready" state that field evidence says loops, and a handful of unbounded or unpaced loops. A few plan amendments follow (GY, GX, CM, CU, DS, BP), plus one new plan for a desk-side agent bridge outside the app.

Recommended next batch (section 8): navigation stale-advice expiry, an audible link drop, EO keyframe and raw-frame hardening, glasses thermal and compatibility state, OAuth single-flight refresh, Even DS P0, live-session idle end, and DR P1 broadcast notices. All are S or S-M with a headless core.

## 2. What changed in the ecosystem

- **DAT 1.0.0 release wave.** Meta tagged 1.0.0 on 24 September and moved the Android artefacts to Maven Central. Ports followed within days, mostly hackathon builds. The one well-documented port published hardware findings that matter to us: SDK pixel buffers starve the pool if retained, short stalls sometimes self-heal, RAW streams end 8 to 15 s after the phone locks while HEVC survives, and the Bluetooth Classic frame-rate ceiling it claimed earlier was a measurement artefact.
- **Ray-Ban Display goes to the web.** Meta published WebMCP samples and an AI-assisted web-app toolkit. A page registers tools; the wearer speaks to Meta AI, which calls them. Constraints are tight: scalar parameters only, a 10 s deadline, developer mode or staged rollout only. While a DAT camera session runs, the Display's web app goes black.
- **Glasses as a voice front end for coding agents.** At least six independent projects route Claude Code, Codex or Copilot hook events from a desk process to glasses: a tone and a spoken summary when the agent stops, permissions answered by voice or touchpad, multiple-choice answers by ordinal, cancel from the glasses. Pairing is by QR code over LAN or tailnet, using the desk CLI's own subscription.
- **Even G1/G2 hobby ecosystem is the largest by repo count.** Plugins, custom firmware, protocol notes, a G2 rasteriser and agent bridges. The mature multi-glasses BLE layer found that a one-arm G2 session rebuilds its display about every 18.5 s, and now requires both arms from one serial-matched pair before declaring ready.
- **The largest open DAT assistant turned assistive.** Its post-review work is a blind-user mode (hazards first, clock directions, never "the path is clear"), earcons, VoiceOver labels and announcing link loss even from the healthy state.
- **A close feature-parity competitor added backends.** ChatGPT subscription sign-in with single-flight token refresh, a Grok backend, OpenAI and xAI cloud voices, a native Hermes Agent backend, scheme guessing for typed hosts, and per-sentence fallback to the system voice.
- **Continuous procedure checking.** One DAT-shaped project built continuous assembly checking: procedures imported from PDF, a changed-and-settled frame gate with an hourly call budget, graded alerts, critical-step gates, a PDF report and a replay tool for tuning thresholds.
- **Privacy backlash tooling as context.** Smart-glasses detectors (Bluetooth company IDs, ESP32 and M5Stack builds, one with about 2,400 stars) are growing. They are not features to copy, but they reinforce the bystander-blur and consent posture.

## 3. Defects and hardenings surfaced in our own code

Each row was found by comparing an outside approach with our tree, then confirmed in our code. Sizes: XS under an hour, S a day, M several days.

| Finding | Our evidence | Fix sketch | Size | Suggested home |
|---|---|---|---|---|
| **HEVC keyframe detection trusts `NotSync`.** A field report says DAT never sets the attachment, so every sample reads as a keyframe and the hold after a decoder rebuild never holds. Rebuilds after lock then decode mid-GOP P-frames. | `Services/VideoDecoder.swift:239-249` (absent attachment means keyframe); gates at `:185`, `:200`. Tests use simulator clips that do set `NotSync` (`OpenGlassesTests/VideoDecoderRoundTripTests.swift:71-87`). | Pure `HEVCNALInspector` reads the first slice NAL type: 16 to 23 is a random-access picture. Use the attachment only when parsing fails. Drop RASL (8, 9) after a CRA. Log once per stream whether `NotSync` was present. Reported GOP: 45 frames (3 s at 15 fps). | S | EO P1 follow-up; evidence feeds EO P2 |
| **Raw frames dropped while locked.** The SDK's image helper is GPU-based and returns nil in the background; a raw frame has an image buffer but no data buffer, so it is classed empty and dropped. | `Services/Camera/StreamCodecPolicy.swift:46-56` (`.empty` maps to `.drop`); `Services/Camera/GlassesFramePipeline.swift:63-70`. | Add a `.rawPixels` shape routed through the existing CPU conversion in `VideoDecoder`. HJ P3 already plans a per-session codec rung for RAW under lock. | S | EO follow-up, alongside HJ |
| **Silent glasses link drop.** Loss only stops speech and logs. VoiceOver also suppresses "glasses disconnected" because the policy believes a disconnect tone plays. | `App/OpenGlassesApp.swift:746-748` (loss), `:749-755` (connect tone on return only), `:894-908`; `Services/Accessibility/SessionAnnouncementPolicy.swift:89-91`. | `hasOwnAudioCue` returns false for disconnect. Pure `GlassesLinkCuePolicy`: silent when doffed, stood down or deliberately disconnected; otherwise lost and restored earcons. Fix the stale comment. | S | Direct PR (FF follow-up) |
| **Thermal and compatibility state not read.** `Device` already reports both on the listener we subscribe to. | `Services/GlassesConnectionPhase.swift:44-52` (link, battery, charging, worn only); `Services/Power/PowerPolicyService.swift:58` (`glassesThermal = { nil }`); `DATCompatibilityMessage.message(for: Compatibility)` (`Services/StreamRecoveryPolicy.swift:217`) has test callers only; `Services/Camera/MetaCameraBackend.swift:805` clears the notice every cycle. | Add `thermal` and `compatibility` to `GlassesDeviceState`, published only while connected. Point `PowerPolicyService` at it. Announce an update requirement at link time. Latch `insufficientSDKVersion` for the process lifetime. | S | BV deferred item (its `deviceStateStream` reference is obsolete) |
| **OAuth refresh race, no forced refresh on 401.** Two callers inside the refresh window both spend the same rotating refresh token; the loser signs the wearer out. Any failure, including a network blip, says "sign in again". | `Services/ChatGPTOAuthService.swift:134-155`, `:152`; `Services/ClaudeOAuthService.swift:91-109`; `Services/GoogleOAuthService.swift:86-101`; `Services/LLMService.swift:2171-2173` classifies 401 only. | `SingleFlightRefresher` actor keyed by provider; commit only if the task still owns the slot. `invalid_grant` means expired; transport errors keep credentials and neutral copy. One forced refresh and retry on 401 for the subscription routes. | S | Direct PR (FG already specifies this pattern for enterprise auth) |
| **Stale navigation hazard advice.** A slow reply about a step is spoken after the wearer has passed it. | `Services/Accessibility/NavigationAssistService.swift:89-112`; 2.5 s tick (`:18`); no capture timestamp. | Stamp `CACurrentMediaTime()` at capture. Drop advice older than `Config.navigationAdviceMaxAge` (5 s) and count drops. Test with a slow model fake. | S | Direct PR (Plan J) |
| **Direct-mode replies are not sentence-streamed.** Tokens reach the bubble only; speech starts after generation ends. | `speakStreaming` has one caller, the OpenClaw stream (`App/OpenGlassesApp.swift:3030`); Direct `onToken` at `:6856-6858`; `docs/plans/CU-voice-turn-latency.md:146-151`. | Sentence splitter on `onToken` into `speakStreaming`, two or three synth requests in flight. Hold back while memory-command parsing or think filtering could still change text; speak whole replies that carry choice buttons. Also demote the cloud voice for the rest of a reply after two consecutive failures. | M | New CU phase (CU's `ttsLeadIn` measures it) |
| **Mode switch forgets the conversation.** | `App/OpenGlassesApp.swift:3080-3150` carries only the frame pin (`:3096-3098`); `pendingResumeContext` is written only by the offline handoff (`App/AppState+OfflineHandoff.swift:72-73`). | Build `LiveContextHandover` from the old recorder, or from the Direct thread's last six turns, and set it on the new manager when the actions include `.startSession`. In memory only, as today. | S | Direct PR (CF follow-up) |
| **Live sessions never idle out.** A forgotten Gemini Live or Realtime session streams to a metered API indefinitely. | No inactivity timer in `Services/GeminiLive/`, `Services/OpenAIRealtime/`, `Services/Live/`. CM P1's unbuilt `WearStatePolicy` fan-out omits live sessions (`docs/plans/README.md:112`). | Pure `LiveIdlePolicy`: no wearer speech or tool activity for N minutes (default 10) ends the session, with one spoken warning 30 s before. Doffed for over 60 s ends it too. | S | CM P1 amendment |
| **Live Coach has no call budget.** | `Services/LiveCoachService.swift:107-109`: 1 to 10 s interval, up to 120 min, so up to 7,200 cloud calls per session; no pixel gate. | Pure `CallBudget` rolling window (about 240 an hour) plus a `FrameGate` with heartbeat; say once when the budget is spent. Never apply it to navigation. | S | Direct PR |
| **Broadcast frame pacing aliases.** A 24 fps setting on a 30 fps phone source sends about 15 fps. | `Services/BroadcastService.swift:506-511`, wall-clock minimum gap. | Pure `FramePacer` with a deadline on `CACurrentMediaTime()`: push when due, then `due = max(now, due + 1/fps)`. | S | DR P1 |
| **Even G2 "ready" on one arm; unguarded connect timer; no pairing serial check.** Field evidence shows a one-arm session rebuilds the display about every 18.5 s. | `Services/Display/Even/EvenBLETransport.swift:12-13` (single-lens degraded by design), `:58-61` (any lens counts), `:161` (disconnect only when none remain), `:82-88` (timeout without generation or `cancelPeripheralConnection`); `App/Views/EvenDisplaySettingsView.swift:52-54` (manual Left and Right on any "Even G2" device). | Pure `EvenPairSession` (both arms, auth, generation) and `EvenPairTarget` (side from `_L_`/`_R_`, accept an uncached arm only if its advertised serial matches the pair). Timeout captures the generation and cancels armed connects. Re-send the last frame on ready. Missing-arm notice after 3 s. | S-M | DS, new P0 ahead of P1 |
| **HUD answers cut at 120 characters.** Long replies are silently truncated on both backends. | `Services/Display/HUDScreen.swift:24` (`HUDTextShaper.maxBodyLength`), applied at `Services/GlassesDisplayService.swift:231`. | Paged answers, section 4. | S-M | New small plan |
| **Web mirror page ignores Meta's current web-app guidance.** | `Services/Display/WebHUD/WebHUDRenderer.swift:47` (`width=600`), `:52` fixed body size, `:140-152` polls with no `visibilitychange`. | `width=device-width` and 100% boxes; pause polling while hidden, poll once on return. Refresh BP's platform section. | XS | BP |

## 4. Features worth adopting

| Feature | What it is | Verified absent | Design sketch in our architecture | Size | Licence |
|---|---|---|---|---|---|
| **Multiple-choice agent questions, ordinal voice answers** | A coding agent's question with options, answered "the second one" or by the option's words; "later" leaves it pending. | `Services/AgentHarness/AgentQuestion.swift:22-28` (free text and approval only); no options in `docs/agent-harness-wire-contract.md:124-151`; `Services/RemoteActionConsent.swift:131-147` accepts three words, approve or deny. | `AgentQuestion.Kind.choice(options:)`; optional `question.options` path and a `choice` decision with an index. Pure `AgentChoiceParser`: ambiguous input asks again, never guesses. Touch rows on the consent card. "Always" deferred: a standing rule needs the consent gate's terms and version model. | S | Portable; write fresh |
| **Desk-side coding-agent bridge** | A small macOS helper that turns Claude Code and Codex hook events into our wire contract. | No desk side anywhere; Plan N calls a self-hosted bridge "a custom URL a power user can opt into" (`docs/plans/N-remote-agent-harness.md:138`). | New plan, outside the iOS target. Hooks installed per run, not in global settings. Route a permission to the glasses only when the desk has been idle 90 s and the phone is polling. Cancel by a halt marker that denies the next pre-tool hook. Settle prompts answered at the terminal. QR pairing with a certificate fingerprint, private and tailnet addresses only, public tunnels refused (reuse `Services/OfficeSync/OfficeCommissionTransport.swift`). The app gains only a preset. Agent Mode gating unchanged. | M | Portable with attribution if adapted |
| **Procedure draft from PDF or pasted text** | Turn the manuals technicians already have into a draft procedure. | GY drafts only from recordings or video (`docs/plans/GY-procedure-from-narrated-recording.md:130`); no numbered-list splitter. | `VaultDocumentExtractor` (OCR fallback included), then a pure `NumberedStepSplitter` (consecutive from 1, at least two steps, "2.5 mm" continuation guard), else one model split into GY's JSON. Validate with `VaultValidator.validateProcedureGraph`; GY's draft store and review. Refuse over the size cap rather than truncate. Safety notes only from the step's own words. | M | Ideas; write fresh |
| **Spoken broadcast drop and recovery, automatic phone fallback** | The streamer hears when the stream drops and comes back; the phone camera takes over when glasses frames stop. | `BroadcastService` never speaks and nothing in `App/` observes its session state; source switching is manual (`Services/BroadcastSupport.swift:69-87`); stopped glasses frames surface only as the 8 s stall (`Services/BroadcastResilience.swift:480-500`). | DR P1 notice, repeated at 30, 60 and 120 s while down, recovery spoken once. Pure `BroadcastAutoSourcePolicy`: 2 s stale goes to the phone's back camera, about 5 s of fresh glasses frames switches back, never when the user pinned a source. Through `switchSource`, so RTMP is untouched; phone frames already pass the relay. | S-M | Ideas only |
| **Paged HUD answers** | Long replies split into HUD pages with a "1/3" footer, turned by tap, swipe or voice. | See the HUD row in section 3. `Services/Teleprompter/TeleprompterPaginator.swift:16` is used only by the teleprompter. | Pure `HUDAnswerPager` over `TeleprompterPaginator`. `GlassesDisplayService` gains a `frameRevision` bumped by every other render; a page turn carries its revision and is dropped if stale. Pages are ordinary `HUDContent`, so both backends work. | S-M | Ideas; re-stated |
| **Second cloud voice from the OpenAI key** | A wearer with only an OpenAI key gets a cloud voice. | Engines are ElevenLabs, Kokoro and system (`Services/TTS/TTSEngineSelector.swift:5-11`); the privacy manifest names ElevenLabs only (`Resources/PrivacyInfo.xcprivacy:57`). | `TTSEngine` case posting `/v1/audio/speech` with the Keychain key, after ElevenLabs in the chain; reuse `CloudVoiceRejection`. Add `MedicalEgressGuard` and `EndpointPolicy` routes, and update the manifest and in-app privacy copy in the same PR. | S-M | Public API |
| **Gateway host typed without a scheme** | "nuc" or "box.tailnet.ts.net" just works. | `Models/GatewayConfig.swift:72-81` builds `host:port`; `Security/EndpointPolicy.swift:69-71` rejects it as `disallowedScheme`. | Pure `GatewayAddress.normalise`: `http` for localhost, private ranges, 100.64/10, `.local`, dot-less names and `*.ts.net` with a port; otherwise `https`. Applied to gateway, Home Assistant and Hermes bridge hosts. Never overrides `EndpointPolicy`. | S | Ideas |
| **`framegate-probe` replay script** | Replay recorded frames through our gates to tune thresholds at a desk. | No probe in `Scripts/`; AT's default-on and CV P4's thresholds are unmeasured (`Services/Vision/NarrationGate.swift:5-7`). | macOS CLI in the style of `Scripts/extract-manual-text.swift`: JPEG folder or recording at N fps through `FrameGate` and `PageTurnDetector`; prints distance, decision, sends per minute. A `ReplayCameraBackend` for simulator demos can follow. | S | Ideas |
| **Reference-photo composite for GX checks** | One labelled image, REFERENCE beside NOW, so any single-image model can compare. | `LLMService.analyzeFrameStructured` takes one image (`Services/LLMService.swift:1640`); GX's `condition` check has no reference. | Optional `reference_photo` on `condition` checks; prompt judges the NOW tile only. NOW comes from `filteredStill(for:source: .photoOnly)`; the reference comes from the vault, so no roster entry. Validator checks the file exists. | S | Ideas |
| **Tools-off realtime announcements** | Deferred and agent-result announcements cannot trigger more tool calls. | `Services/Live/LiveInjection.swift:88` emits a bare `response.create`. | `toolsAllowed` flag that adds `"tool_choice": "none"` for those injections. Gemini has no per-turn equivalent. One envelope test. | XS | Ideas |
| **WebMCP surface on the Display mirror** | The mirror page registers a few tools so "Hey Meta, next step" works with no DAT display entitlement. | No WebMCP code; the mirror server is GET-only (`Services/Display/WebHUD/WebHUDMirrorServer.swift:187-188`); BP defers mutations until after P4 (`docs/plans/BP-web-hud-mirror.md:94-95`). | Plan only, after BP P4. Three to five `og_` tools (read card, next and previous page, check step, pause teleprompter) post to a token-gated write route; same gate as BP, off under HIPAA, every action also reachable by D-pad. Honest limits: Meta AI is the agent, so none of our LLM, memory, persona or consent stack applies and arguments pass through Meta; scalar parameters only; 10 s deadline; developer mode or rollout only; the page goes black while a DAT camera runs. | M | BSD-3 samples; keep the notice if adapted |

## 5. Corrections to prior assumptions

- **We are probably streaming over Bluetooth Classic, not Wi-Fi.** We ship the ExternalAccessory keys (`OpenGlasses/Info.plist:298-309`) and neither entitlements file carries Hotspot Configuration or Wi-Fi info. Two independent field reports say the SDK picks the transport from configuration, and that those keys keep it on Bluetooth Classic. Three documents assume Wi-Fi: `docs/plans/EO-hevc-glasses-stream.md:58`, the `StreamConfigPolicy` premise (`Services/StreamRecoveryPolicy.swift:143-145`) and `.claude/rules/dat-conventions.md:164`. **Before touching any of them, confirm the link level in the MWDATCore log on a device** (`.medium` is Wi-Fi, `.low` is Bluetooth). Do not add Wi-Fi blindly: it costs about 10 s per session, a join prompt, and the phone's Wi-Fi internet. Bluetooth Classic measured 29 to 32 fps at 504x896.
- **Broadcast reconnect with backoff is done.** Plan CY shipped it on 24 August (#337). The 27 August gap note is half stale; only DR's spoken notice and multi-destination remain.
- **"DAT 1.1 planned capabilities" was a plugin's own roadmap,** not Meta's. It plans to expose 1.0's experimental motion and inputs, which we must not link.
- **Sentence-streaming TTS is only on the OpenClaw path,** not Direct mode (section 3).
- **Grok is already a supported LLM** (`Models/ModelConfig.swift:82-100`). Only non-ElevenLabs cloud voices are missing.
- **Face recognition uses a generic image feature print, not a face embedding.** `Services/FaceRecognitionService.swift:297` runs `VNGenerateImageFeaturePrintRequest` on the crop; the comment at `:17` calls it a "128-dim face embedding". An outside measurement found this approach scores different people higher than the same person at glasses resolution. This is a **measurement task only**: probe our pipeline at stream resolution, fix the comment, and record the result in `docs/eu-ai-act-review-2026-10.md` §3.1 as Art. 15 accuracy evidence. Do not expand the feature.
- **The Claude Code bridge phone half exists.** Plans N and FE give a harness-agnostic stack with questions, typed replies, cancel, replay, spoken summary and Agent Mode gating. What is missing is the desk side and choice questions (section 4). The `claudeRemote` preset's contract is still unverified.
- **Meta's web-app toolkit is BSD-licensed** (a 30-line LICENSE), not unclassified as discovery recorded. Its bundled UI-toolkit validator is separately licensed.
- **The "fully offline" glasses example [A27] is an Android-only React Native module** from May 2026, not an offline assistant. Our offline tier is broader.
- **The cross-glasses SDK [A25] is still on DAT 0.9.0** and its Meta video support has not shipped.
- **The multi-glasses BLE layer's frame budget [A20] applies only to one non-G2 display profile,** so it is not a G2 hardening item.
- **Camera and Display on one `DeviceSession` works on hardware** [A2]: display up in 0.9 s, camera joined the same session, 12 display updates at 40 to 100 ms while streaming. This unblocks `Services/Device/DeviceSessionCoordinator.swift` and Plan DT.
- **Plan AH's "single-lens degraded" mode is contradicted by field evidence** (section 3, Even row).

## 6. Already covered or planned (do not re-litigate)

- SDK frames consumed inside the callback, no retained SDK buffers; two-clock stall detection at 1.5 s; device and camera lifetimes split (EO, BR P2, EW).
- RAW streams ending under lock, a per-session codec rung: **HJ** (📋 Planned).
- Shared camera and HUD session: **DT** and additional-capabilities item 3, now unblocked.
- Blind-user mode, earcons, VoiceOver announcements, call audio to the speaker, idempotent App Intents: Blind Assistant mode, **FF** P0, `AudioRoutePolicy`.
- Broadcast reconnect (**CY**), chat readback (**CI**), dual-capture inset (**BS** P3), multi-destination (**DR** P2), caption-burned export (**DR** P3).
- Clip recording to Photos (**FO** P2b), PDF report and zip export (**FO** P2a), PDF and OCR import (vault extractor).
- Change, settle and spacing gates (**AT** `FrameGate`, `PageTurnDetector`, `NarrationGate`).
- Rolling video lookback (**GQ**); agent notebook memory (**GN**).
- Async agent delivery, cancel, ack, replay (**N**, **FE**, **EH**, **CB**); tool circuit breaker (**BR** P1); "btw" side questions and live session streams (**N** deferred live stream).
- Even G2 heartbeats to both arms, wake-word disable, side-keyed reassembly, off-main acks, width-table fit (**DS** P1 to P5); Meta audio route as intent (**DT**).
- ChatGPT subscription sign-in, Keychain keys, the Xcode 27 MLX pin, CI and Dependabot, per-request token caps, local model catalogue and repository import, offline ASR, MLX, llama.cpp and Kokoro.

## 7. Skipped, and why

- **Phone-screen mirroring to the Display with the wristband as touchpad** [A21]: iOS cannot inject input into other apps. Keep its pinch-and-Enter and double-Back de-duplication rules as BP's input contract.
- **G2 rasteriser** [A22]: no raster path on any backend. Its ink-budget and contrast-lint tests are worth adopting if one appears; note on DS's deferred list.
- **G1 protocol knowledge base** [A23]: no G1 backend. Bookmark for CQ.
- **GPL G2 interface with custom firmware** [A24]: copyleft and firmware-dependent; no idea outside an existing plan.
- **Cross-glasses SDK** [A25]: nothing for our DAT path.
- **Streaming overlays and reactions** [A26]: cosmetics with no assistant value.
- **Conversation copilot with social cues** [A28]: inferring what people want or feel is the emotion-recognition exposure Plan HR removed.
- **Second-vendor Realtek glasses and a face model** [A5]: closed vendor SDK with LGPL FFmpeg; the weights are non-commercial; face recognition is not to be expanded. One paragraph on these glasses belongs in the cross-vendor research doc.
- **Dual-agent design** [A9]: covered; stale since March; Meta developer-terms licence.
- **Lifelog OS** [A8]: machine-generated, low confidence; GQ and GN cover the useful parts.
- **Detector tools** [A29]: context only.
- Also skipped on the merits: continuous procedure monitoring (GX rules it out for battery and heat), HEVC passthrough broadcast (bypasses the blur chokepoint), Picture-in-Picture keep-alive (pending a five-minute locked broadcast test), SRT output, a native Hermes Agent backend, persisted live-session summaries and camera archives, a listen-only live mode, sideloading model files, the Wi-Fi Aware Bonjour key, Mac remote control and Kokoro on the Mac.

## 8. Recommended next PR batch

1. **Navigation stale-advice expiry** (direct PR, S). Safety first; tiny.
2. **Audible glasses link drop and VoiceOver fix** (direct PR, S). Pure `GlassesLinkCuePolicy`.
3. **EO P1 hardening** (S): NAL-based keyframe detection and the `.rawPixels` CPU path, with the once-per-stream `NotSync` log for EO P2.
4. **Glasses thermal and compatibility from `Device` state** (BV, S), with the `insufficientSDKVersion` latch.
5. **OAuth single-flight refresh, failure classification and 401 retry** (direct PR, S).
6. **Even G2 pair readiness** (DS P0, S-M): pure `EvenPairSession` and `EvenPairTarget` first, then transport wiring; drop "single-lens degraded" from AH.
7. **Live sessions end when idle or doffed** (CM P1 amendment, S).
8. **Broadcast notices, phone fallback and deadline pacing** (DR P1, S-M).

Then, in order: mode-switch handover, Live Coach budget, Direct-mode sentence streaming (CU), paged HUD answers, choice questions, the BP mirror fix, gateway address normalising, `framegate-probe`, the second cloud voice. Plan-only work: a new desk-bridge plan, the GY and GX amendments, and a post-P4 WebMCP section in BP. The transport documents wait for the device log check.

## Appendix A: sources

Plan docs, PR descriptions and commits must not cite these sources; describe techniques on their own merits.

| Ref | Repo | Licence | Flag | What was reviewed | Commits and dates |
|---|---|---|---|---|---|
| A1 | rodcone/flutter_meta_wearables_dat | MIT | portable | DAT 1.0 migration, pixel-buffer pool fix, stall tracker, lifecycle branch, hardware QA notes | 56 since 27 Aug; v1.0.0 on 5 Oct |
| A2 | amanshah0729/vision | MIT | portable | Transport keys, keyframe parsing, camera plus HUD on one session, web-app bridge | 35 commits, 11 to 17 Sep; DAT 0.9.0 |
| A3 | Intent-Lab/VisionClaw | Custom, Meta-derived | ideas only | Assistive mode, earcons, VoiceOver, reconnect announcement, call audio | 5 after the 7 Sep review, to 26 Sep |
| A4 | saeedkolivand/meta-stream | None | ideas only | Codec matrix, PiP, phone fallback, spoken drop and recovery, chat lanes | 129 commits, 15 to 17 Sep; DAT 0.9.0 |
| A5 | prasanthsasikumar/hermes-glasses | MIT; vendor SDK closed, face weights non-commercial | portable with exceptions | Build Check, second vendor, clip recording, face model | About 50 distinct, 28 Aug to 7 Oct |
| A6 | rayl15/OpenVision | MIT | portable | Subscription sign-in, Grok, cloud voices, Hermes backend, address guessing, Keychain | 17 since 21 Aug; v2.14.0 on 2 Oct |
| A7 | hao-ai-lab/hawky | Apache-2.0 | portable with NOTICE | Rolling session memory, delegation, tools-off announcements | 9 since 20 Aug, last 24 Sep; iOS client idle since 9 Jul |
| A8 | train-cell/R0lling | MIT | ideas only | Rolling A/V buffer, Obsidian export, agent folder | 28 commits, 6 to 8 Oct |
| A9 | Intent-Lab/Matcha | Meta developer terms | ideas only | Dual agent, circuit breaker, SSE | None since 30 Mar |
| A10 | FerSaiyan/Alternative-HeyCyan-App-and-SDK | Apache-2.0 (own code) | ideas only (Android) | Walking-aid stale-frame rule, metered live sessions, local models | 403 since 20 Aug, last 29 Sep |
| A11 | lennystepn-hue/sidekick | MIT | portable | Answer parsing, hook dedupe, summary and side-question prompts | 64 since 20 Aug, last 10 Sep |
| A12 | ethanpaschkes/meta-glasses-voice-bridge | MIT | portable | Spoken decision edits, Mac actions | 21 since 20 Aug, last 13 Sep |
| A13 | soothslayer/RayBridge | None | ideas only (README) | Pinned certificate, private-address pairing | 58 since 20 Aug, last 23 Sep |
| A14 | wmoto-ai/cc-g2 | MIT | portable | G2 approvals and option answers, terminal settlement | 3 since 20 Aug, last 6 Oct |
| A15 | ukaoma/cos-glasses-server | MIT | portable | Permission broker, halt-marker cancel | 129 since 20 Aug, last 8 Oct |
| A16 | ThatCrispyToast/g2-claude-remote | MIT | portable | Question payload shape, passphrase token | 5 since 20 Aug, last 5 Oct |
| A17 | facebook/meta_glasses_webmcp | BSD-3-Clause | portable with notice | WebMCP samples and tool registration | 14 commits, created 9 Sep, last 7 Oct |
| A18 | facebook/meta-wearables-webapp | BSD | read docs only | Build, device and WebMCP skills | 20 since 20 Aug, last 1 Oct |
| A19 | facebook/meta-wearables-dat-ios, -android | Meta DAT licence | pinned dependency | Release commits only | 1.0.0 on 24 Sep; Android to Maven Central 14 Sep |
| A20 | Mentra-Community/MentraOS | Apache-2.0 | portable with NOTICE | iOS Bluetooth SDK G2 session, reconnect demand, display manager | 3,250 on `dev` since 27 Aug; key commits 9 Sep to 8 Oct |
| A21 | handzlikchris/Glasscast | MIT | portable | Phone mirroring to Display, input quirks | 100 since 20 Aug, last 7 Oct |
| A22 | gabrielevierti/glyph | MIT | portable | G2 rasteriser, ink budget, contrast lint | 19, last 21 Sep |
| A23 | Cheddies1/even-g1-companion | BSD-2-Clause | portable | G1 protocol notes | 16, last 8 Sep |
| A24 | jimrandomh/faceclaw | GPL-3.0 | copyleft | README and note titles only | 246 since 20 Aug, last 7 Oct |
| A25 | hkust-spark/xg-glass-sdk | Apache-2.0 | portable | DAT 0.9 move, callback awaiter, simulator | 2 on 9 Sep |
| A26 | przemek-nowicki/meta-lens-ai | MIT | portable | Dual capture, overlays | 3, last 25 Sep |
| A27 | Mentra-Community/Edge_AI_SmartGlasses | Apache-2.0 | portable | Offline example module | Module from 24 May; 2 since 20 Aug |
| A28 | ColinHu07/SituationalAwareness | None | ideas only (README) | Social-cue copilot | 39 since 20 Aug, last 27 Sep |
| A29 | yjeanrenaud/yj_nearbyglasses; skizzophrenic/SquachWatch-CYD; CIS-C0/RFSentinel; kevinl95/Spectacle | AGPL-3.0; GPL-3.0; GPL-3.0; MIT | context only | READMEs | v1.0.11 on 23 Sep; others pushed Sep to Oct |

Known repositories with no movement since the last review (do not re-review before 1 December 2026 unless a new push appears):

| Repo | Licence | Last push |
|---|---|---|
| EitanWong/hyper-meta-ai | MIT | 20 Aug |
| iannellomarco/GlassifAI | MIT | 22 Aug |
| Alphonso84/RayBan_Meta_NoteBuddy | None | 23 Aug |
| shannen-flame/meta-glasses-ai | None | 4 Aug |
| arniesaha/NixClaw | Unclassified | 14 Aug |
| DarlingtonDeveloper/OpenGlass | MIT | 24 Feb |
| dvanblaricom/SamGlasses | None | 9 Feb |
| SEZ9/kiwi-meta-glasses-ios | Unclassified | 6 Aug |
| rsantomauro/TeroGlasses | GPL-3.0 | 9 Aug |
| mweinbach/parakeet-coreml-swift | Apache-2.0 | 22 Apr |
| Intent-Lab/Matcha [A9] | Meta developer terms | 30 Mar (last commit) |
| gitpcl/JarvisVision | | 404; drop from the watch list |
| "metamemory" | | unresolvable; drop from the watch list |

## Appendix B: spot-check results

The eight highest-stakes claims were re-read in our tree at `7a0cc0e0` before writing.

| # | Claim | Result |
|---|---|---|
| 1 | `VideoDecoder.isKeyframe` treats an absent `NotSync` as a keyframe | Confirmed, `:239-249`; both hold gates at `:185` and `:200`. |
| 2 | No single-flight OAuth refresh | Confirmed in all three services; no single-flight helper anywhere in `Sources`. Plan FG already specifies single-flight refresh for enterprise auth (`docs/plans/FG-workflow-vaults-and-enterprise-auth.md:60`), so the pattern is planned there but not for these. |
| 3 | `NavigationAssistService` has no frame-age check | Confirmed, `tick()` at `:89-112`. |
| 4 | `speakStreaming` called only from the OpenClaw path | Confirmed, single caller at `App/OpenGlassesApp.swift:3030`. |
| 5 | `performModeSwitch` carries only the frame pin | Confirmed, `:3080-3150`; `pendingResumeContext` written only by the offline handoff. |
| 6 | Even one-arm readiness and unguarded 10 s timer | Confirmed at `:13`, `:58-61`, `:82-88`, `:96-102`, `:161`. The timer path does not cancel armed connects. |
| 7 | HUD 120-character cap | Confirmed. The constant is `HUDTextShaper.maxBodyLength` in `Services/Display/HUDScreen.swift:24`, applied at `Services/GlassesDisplayService.swift:231`. |
| 8 | Silent link drop | Confirmed, `:746-755`; `releaseGlassesHardware` (`:894-908`) stops speech only. `playDisconnectTone()` is called only from the end-of-turn path and the live-session earcon map, never on link loss. |

Drift corrected while checking: `PowerPolicyService` lives in `Services/Power/`. `DATCompatibilityMessage.message(for: Compatibility)` is at `Services/StreamRecoveryPolicy.swift:217` with test callers only (`OpenGlassesTests/BRHardeningTests.swift:141,147-148`). Plan HJ, which the review passes did not cite, already plans the RAW-under-lock codec rung, so the raw-frame row now names it; the CPU path for raw pixels is still uncovered. CM P1's stream half has shipped; only the `WearStatePolicy` fan-out is unbuilt.

Plan status lines, index (`docs/plans/README.md`) against each plan file:

| Plan | Index | Plan file | Agree |
|---|---|---|---|
| EO | 🚧 P1 implemented 2026-09-08, P2 device pending | Same | Yes |
| CY | 🚧 Core shipped 2026-08-24 (#337) | Same | Yes |
| DR | 📝 Drafted 2026-08-27; reviewed 2026-09-08, P1 reduced to the spoken notice | 📝 Drafted | Yes |
| DS | 📝 Drafted 2026-08-27 | Same | Yes |
| GX | 📝 Drafted, not scheduled, 2026-10-02 | Drafted, nothing implemented | Yes |
| GY | 📝 Drafted, not scheduled, 2026-10-02 | Drafted, nothing implemented | Yes |
| CM | 🚧 Partly landed; fan-out, P2, P3, P4 unbuilt | 🚧 Partially shipped, elsewhere | Yes |
| CU | 🚧 P1 and P2 PR1 shipped; PR2 next | Same | Yes |
| BP | ✅ P1 and P2 shipped; P3 and P4 hardware-deferred | Same | Yes |
| DT | 📝 Drafted 2026-08-27 | Same | Yes |
| N | 🚧 Phases 1 to 3 shipped | 🚧 "Phase 1 core shipped" | **No.** The plan file's Status line lags the index. |
| FE | ✅ P0 to P6 shipped 2026-09-16 | Same | Yes |
| GQ | 📝 Drafted, not scheduled, 2026-10-01 | Same | Yes |
| BS | ✅ Implemented (#238) | Same | Yes |
| BV | 🚧 P1 and P2 core shipped; glasses thermal deferred | Same; deferral still cites `deviceStateStream` | Yes |

## Appendix C: method

- **Discovery.** About 25 GitHub repository searches, 12 re-run at a limit of 300 and one at 1,000 because results saturated, plus 9 code searches (`MWDATCore`, `MWDATDisplay`, `Wearables.configure`, `com.meta.wearable` and similar). Code-search recall is partial: several queries hit the 100-result cap and `import MWDATCamera` returned nothing.
- **Filters.** About 1,000 raw hits; 883 pushed since 20 August; 464 dropped as empty, template or tiny (five commits or fewer, or three source files or fewer); 415 passed; **305 are glasses-relevant**. About 45 were digested by hand and 16 shortlisted.
- **Deep review.** 27 repositories cloned at depth 200 with all branches (the largest monorepo [A20] sparse and blob-less). Nothing cloned was executed. Our tree was read only.
- **Forks.** 29 forks of OpenGlasses; 14 pushed since 5 August; 10 have no commits ahead. The rest are signing, CI and branding changes, plus two tiny voice and model-save commits. No fork has material new engineering.
- **No movement.** The repositories in the no-movement table at the end of Appendix A had no commits on their default branch since 27 August (one none since 30 March). Do not re-review them before 1 December 2026 unless a new push appears. The DAT repositories [A19] carry only the 1.0.0 release we already pin. Two names on the old watch list could not be resolved (one returns 404, one matches nothing relevant); drop them.
- **Out of window but prominent:** six popular repositories last pushed before 20 August were excluded by date.
