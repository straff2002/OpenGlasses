# Plan FF — Blind Assistant Readiness

**Status: 📝 Drafted 2026-09-13 — source audit only; no implementation, tests, simulator run or hardware validation performed for this assessment.**

Origin: a blind-user readiness request naming seven areas — non-visual activation, a blind-user prompt, reading-quality capture, audible state, session resilience, offline local vision and safety framing.
Baseline: OpenGlasses working tree at `4573210f`, including existing local changes. Existing plan status is context, not proof of current device behaviour.

## Assessment

We are substantially closer than a developer demo: six of the seven requested areas have relevant implementation. That is architectural coverage, not six completed requirements. Automatic cloud-to-offline visual conversation is the largest missing capability. Prompt consistency, audible recovery and independent end-to-end use are the immediate gaps.

The online experience looks close enough for a focused hardening and user-validation milestone. Daily-use offline reliability is a separate, larger milestone. A numerical completion percentage would hide the difference between an implemented policy and a proven pocketed-phone experience.

## Requirement-to-code map

| Requested area | Current evidence | Remaining gap |
|---|---|---|
| Non-visual activation | `AskOpenGlassesIntent` and `ToggleGeminiLiveIntent` support Action Button shortcuts; wake-word activation and launch-time listening exist. VoiceOver semantics and UI audits exist. | Launch listening is not opt-in auto-start of a Gemini session. Experimental temple media trigger needs hardware validation; do not equate it with capture-button support. Finish the full setup/recovery journey without sight. |
| Blind-user prompt | `LiveAIMode` has a selectable Blind Assistant; the Gemini manager incorporates the selected prefix. Navigation mode already uses clock directions and rough distances. | Blind Assistant currently asks for detail and lacks a unified brevity, verbatim reading, uncertainty and non-visual-language contract. Distinct assistive services have different prompts. |
| Reading-quality capture | `LookCloselyTool` captures a sharp still and injects it into the active live session, with timeout and power/cooldown policy. | Establish that natural reading requests reliably invoke it and that delivered image detail survives the complete pipeline. Failure copy currently permits answering from the stream; unreadable characters must remain unreadable. |
| Audible state | TTS exposes connect/disconnect/listening/photo tones. Session announcements are wired in AppState; Gemini terminal failures speak locally. | VoiceOver announcements require VoiceOver and can be dropped during assistant speech. Reconnected callback restarts capture without an explicit cue there. Prove all four requested states are audible, including cloud recovery rather than only Bluetooth changes. |
| Session resilience | Gemini has coalesced bounded reconnects, ten-attempt limit, resumption handles and server-rotation handling. | Verify actual context continuity and usable microphone/frame recovery. Audio restart failure is logged in the reconnect callback; connection success alone is insufficient. Exhaustion ends the session. |
| Offline local vision | MLX local vision and capability guards exist; offline turn-loop/freshness/assembler tests exist. | BU explicitly leaves offline service device wiring pending. No automatic takeover exists in the inspected Gemini failure path. llama.cpp currently advertises no vision and rejects images; a downloaded text model is not a visual fallback. |
| Safety framing | Navigation service describes itself as supplementary in code/comments and has view-quality checks. | Its model prompt explicitly includes `low = clear path`. Shared safeguards must reach Blind Assistant, navigation, reading, narration and local fallback. An activation disclaimer does not correct the model instruction. |

### Evidence locations

- [Live presets](../../OpenGlasses/Sources/Models/LiveAIMode.swift), [navigation prompt](../../OpenGlasses/Sources/Services/Accessibility/NavigationAssistService.swift), [assistive routing](../../OpenGlasses/Sources/Services/Accessibility/AssistiveRouter.swift).
- [Action Button intent](../../OpenGlasses/Sources/App/Intents/ToggleGeminiLiveIntent.swift), [application wiring](../../OpenGlasses/Sources/App/OpenGlassesApp.swift), [media trigger plan and device caveats](CH-media-button-trigger.md).
- [Sharp capture tool](../../OpenGlasses/Sources/Services/NativeTools/LookCloselyTool.swift), [capture policy](../../OpenGlasses/Sources/Services/Live/LookCloselyPolicy.swift).
- [Announcement policy](../../OpenGlasses/Sources/Services/Accessibility/SessionAnnouncementPolicy.swift), [audio cues](../../OpenGlasses/Sources/Services/TextToSpeechService.swift).
- [Gemini session manager](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift), [socket recovery](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift), [resumption helpers](../../OpenGlasses/Sources/Services/GeminiLive/GeminiSessionResumption.swift).
- [Local MLX service](../../OpenGlasses/Sources/Services/LocalLLMService.swift), [llama.cpp backend](../../OpenGlasses/Sources/Services/LocalInference/LlamaCpp/LlamaCppLocalInferenceBackend.swift), [offline core tests](../../OpenGlassesTests/OfflineLiveSessionTests.swift).
- [Onboarding UI audit](../../OpenGlassesUITests/OnboardingAccessibilityTests.swift): stops before glasses registration; does not establish that the complete real setup is accessible. [DF](DF-app-accessibility.md) also explicitly leaves hardware VoiceOver and blind-user validation pending.

## P0 / PR1 — One blind-assistance contract

Extend existing prompt composition; avoid another mode or parallel assistant service.

- Share a blind-assistance instruction block across the selected live preset and relevant visual assistance paths, preserving each tool's output format.
- Default to one short useful observation, relevant observed hazards first; give more detail on request. Use clock positions and approximate distance only when supported by the image, otherwise say the position/distance is uncertain.
- Read requested text faithfully; distinguish exact transcription, partial text and interpretation. Never fill in unreadable medication names, quantities, dates or instructions.
- Remove `clear path` from navigation guidance. Prohibit assurances that movement/crossing is safe or that an unseen hazard is absent. Describe limited visual evidence and preserve cane/guide-dog framing.
- Exclude visual assumptions such as “as you can see.” Audit generic system instructions for conflicts with the selected preset.

Acceptance: prompt-composition tests across Gemini, OpenAI Realtime and local/direct paths that support the preset; evaluated image/transcript cases for stairs, partial labels, no visible obstacle, blurred text and requests for unsafe certainty. Static phrase checks alone are insufficient. Record model/version and observed outputs; no safety certification is implied.

## P0 / PR2 — Audible lifecycle that survives interruptions

Reuse TTS/earcons, `SessionAnnouncementPolicy` and existing speech/audio arbitration.

- Define distinct feedback for session usable, connection lost/retrying, service usable again, and successful requested photo capture. Offer a short cue-learning/help flow.
- Work with VoiceOver both enabled and disabled when Blind Assistant is selected; deduplicate speech and tones across transport, Bluetooth and UI events.
- A recovery cue requires restored audio and, for visual assistance, fresh visual evidence. Explicitly describe audio-only or camera-unavailable recovery.
- Queue/coalesce essential loss/recovery notices if speech occupies the route; expire obsolete notices so “disconnected” cannot play after successful recovery. Do not drop the only failure notice indefinitely.
- Make cue settings accessible. Announce requested capture success only after capture succeeds, not on button press or repeated background sampling.

Acceptance: injected transition sequences plus actual audio delivery checks for start, loss, retry, recovery, exhaustion, capture timeout, assistant speaking and VoiceOver speaking. Verify glasses output with the phone pocketed and distinguish a queued cue from a heard cue. Coordinate with FE's delivery feedback work.

## P1 / PR3 — Complete the non-visual entry journey

- Add an explicit opt-in “Start Blind Assistant when I open the app” setting using the existing session activation owner. Gate on completed setup, permissions, provider readiness and user intent.
- Coalesce launch/shortcut/wake requests. User Stop cancels pending startup; ordinary foreground events must not repeatedly restart a stopped session.
- Validate existing Action Button and Siri paths first. Treat temple-tap support as experimental until CH's device gate passes. Audit the pinned DAT API before proposing capture-button handling; do not promise an unsupported hardware gesture.
- Extend DF coverage through actual registration, permission denial/retry, provider setup, mode selection, session start/stop and error recovery. Audit all controls encountered, focus order, state values and accessible alternatives to gestures.

Acceptance: a blind participant can complete supported setup and use the assistant without a sighted operator. Record any unavoidable OS/companion-app step, plus an accessible instruction for it. Test cold launch, repeated activation, cancellation during permission checks, lock/unlock and external audio coexistence.

## P1 / PR4 — Make reading requests reliably obtain usable detail

- Reuse `look_closely` and existing reading tools; do not raise continuous streaming bandwidth globally.
- Ensure Blind Assistant routes “read this,” expiry dates, menus and label requests to a sharp capture when required. Evaluate existing model tool selection before adding deterministic intent routing.
- Verify image dimensions/quality after privacy filtering, capture, provider preparation and injection. Ensure one fresh still precedes the corresponding answer and stale captures cannot attach to a replacement session.
- On blur, darkness or timeout, speak a concise reposition/hold-steady instruction or partial transcription. Never infer missing digits from packaging context. Bound retries and retain power/privacy controls.

Acceptance: a fixed corpus of mail, small print, prices and synthetic medication labels, including blur/glare/occlusion; measure character/digit accuracy, capture success and end-of-question to first useful spoken text. Test capture failure and session replacement through production adapters. Proposed performance targets must be agreed after a baseline, before declaring the milestone complete.

## P1 / PR5 — Prove recovery through usable conversation

Extend the existing Gemini recovery implementation, coordinating with FD camera readiness and EW resource cleanup.

- Fault-inject socket loss, setup timeout, server rotation, expired resumption handle, audio-restart failure and missing/stale camera frames.
- Resume valid context; if resumption is unavailable, explicitly rebuild a bounded handover from existing conversation state. Do not replay side-effecting tool calls or pretend an interrupted answer completed.
- Verify stop during every retry phase cancels future work and old callbacks. Respect DAT pause semantics; no competing camera restart while paused.
- Treat socket, microphone and visual readiness as separate recovery facts. Surface degraded operation audibly rather than logging it as the only response.

Acceptance: recover from a short outage without user action and answer a context-dependent follow-up correctly, using current visual evidence. A long outage exits predictably into the offline policy below or an audible limitation. Measure recovery time and test repeated network flapping on real glasses.

## P2 / PR6–7 — Offline takeover, then field qualification

This is the largest gap. Extend BU/DW/DZ/FC rather than introducing a second local model manager.

1. Finish the production offline voice/vision loop behind actual model capability, locale/ASR, TTS, memory and foreground-execution readiness checks. Validate the currently available MLX VLM; do not select a model solely because a request mentions it. The text-only llama.cpp path cannot meet this requirement.
2. Add opt-in automatic handover from the existing cloud session owner. Announce the change, release/transfer audio and camera ownership once, retain a bounded context and cancel outstanding cloud speech/inference. Use a finite outage threshold; do not wait indefinitely for retries.
3. If the VLM is unavailable, use a verified on-device OCR/basic-perception tier where supported, with explicit capability limits. Missing assets or unsupported background execution must produce local feedback, not fabricated visual answers. No model download can be assumed possible after connectivity is lost.
4. Return to cloud only under the chosen user preference after a stable connection and at a turn boundary. Avoid oscillation, duplicate answers and replayed tools. Stop cancels both recovery and local work.
5. Qualify phone lock/background behaviour separately. Existing MLX guards constrain inference in the background, making the pocketed-phone offline promise a release blocker until a supported alternative is proven. Foreground-only offline support must be labelled as such.

Acceptance: airplane-mode scene question and text reading with assets preinstalled; absent/corrupt/text-only model; unsupported ASR locale; low memory; thermal pressure; lock/unlock; cloud loss during speech; network flapping; stop during handover. Trace permitted network activity to prove the fallback does not quietly call cloud services. Measure first spoken feedback, first useful answer, accuracy, battery and thermal behaviour per target phone.

## Delivery gates and order

| Gate | Exit evidence | Current status |
|---|---|---|
| A — Coherent online Blind Assistant | PR1–5 implemented; complete VoiceOver journey; heard lifecycle feedback; successful sharp reading and reconnect scenarios | Pending |
| B — Foreground offline continuity | Production offline loop and automatic handover; capability failures audible; airplane-mode evidence | Pending |
| C — Daily-use qualification | Blind-user sessions on target phones/glasses, pocketed/locked behaviour established, latency and power results, unresolved limitations published | Blocked on a supported background-inference path |

Gate C's pocketed-phone offline promise depends on the on-device MLX background constraint recorded in this repository — local inference cannot run backgrounded — so it is a release blocker to schedule early rather than a late qualification step.

Recommended order: PR1 → PR2 → PR3/PR4 → PR5 → PR6–7. Start the offline hardware feasibility check early because background execution may constrain Gate C. Gate A can ship independently with truthful offline limitations.

Existing work to reuse: DF accessibility, CH media trigger, BU offline session, DW offline perception, CV narration, DZ local runtime, FC local-model remediation, FD camera recovery, EW resource cleanup and FE voice delivery. This plan owns the complete blind-user acceptance journey, not duplicate implementations of those systems.

For each gate record build/commit, provider/model, phone/iOS, glasses/firmware/SDK, enabled settings, expected/observed outcome and remaining failures. Establish latency budgets from a baseline with blind participants; report p50/p95 end-of-question to first useful audio, rather than token throughput alone. Tests already present in the repository were inspected, not rerun for this plan.
