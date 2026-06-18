# Additional Capabilities — net-new features over the shipped engines

A set of self-contained capabilities identified for OpenGlasses, each a genuine fit that builds on
the engines we already ship (TTS, Config/Keychain, GlassesDisplayService + CameraService, BrainStore,
WakeWordService). This plan scopes each one, records what's **out of scope** and why, and tracks what's
shipped.

---

## Already shipped — Phone-side HUD renderer

A native SwiftUI renderer that walks the same `MWDATDisplay.FlexBox/Text/Button/Image/Icon` tree the
SDK sends to the lens is shipped as [HUDPreviewView.swift](../../OpenGlasses/Sources/App/Views/HUDPreviewView.swift)
(Plan Y / Display Phase 4) — brand-styled (coral accent, capsule buttons) and driven by
`GlassesDisplayService.previewFlexBox(for:)`. This is the highest-value item here and it's done. ✅

**Remaining follow-up (small):** add **snapshot tests** over `HUDPreviewView` for the canonical
screens (task card, launcher menu) so the device-less preview is also a regression gate — the natural
extension of "no Display hardware → tests are the gate." (~0.5 day.)

---

## Candidates

| # | Feature | Effort | Verdict |
|---|---|---|---|
| 1 | **Kokoro on-device TTS tier** | ~3–4 days | ✅ Shipped — selection + download + vendored binary + inference; on-device audio pending |
| 2 | **Provider API keys → Keychain** | ~0.5–1 day | ✅ **Shipped** — secrets now Keychain-backed |
| 3 | **Shared `DeviceSession` (camera + display)** | ~2–3 days | 🚧 Core shipped — coordinator tested; live adoption deferred |
| 4 | **`needs` / follow-ups in BrainStore** | ~1 day | ✅ **Shipped** (this PR) |
| 5 | **Alternative hands-free triggers** | ~2–4 days | 🚧 Core shipped — gate + service + shake detector + Settings; acoustic/volume detectors deferred |
| 6 | **Multi-user profiles + PIN gate** | ~4–6 days | ◻︎ Conditional — only if shared-device is a goal |
| 7 | **Declarative HUD widget board** | ~3–5 days | ⏸ Defer — Display Phase 5 concept |
| 8 | **On-device ASR (SenseVoice) tier** | ~2–4 days | ✅ Take — sherpa-onnx binary already vendored; closes the offline loop |
| 9 | **Vision-based procedure auto-advance (SOP spotter)** | ~3–4 days | ✅ Take after #8 — hands-free Field Assist; reuses analyzeFrame + ProcedureRunner |

---

### 1. Kokoro on-device TTS tier  *(headline)*

**Today:** [TextToSpeechService.swift](../../OpenGlasses/Sources/Services/TextToSpeechService.swift) has
exactly two engines — ElevenLabs (cloud, paid; `speakWithElevenLabs`) and AVSpeechSynthesizer
(robotic fallback; `speakWithiOS`). There is **no on-device neural voice**.

**What to add:** a `KokoroTTSEngine` — a self-contained wrapper around **sherpa-onnx** running the
`kokoro-int8-en-v0_19` model. It loads `model.int8.onnx` / `voices.bin` / `tokens.txt`, generates a
WAV on background CPU threads, and plays via `AVAudioPlayer`. Gated behind a compile flag.

**Why it fits us specifically:**
- **Offline + free + good quality** — a third tier between ElevenLabs and AVSpeech: no network, no
  per-character cost, far better than `AVSpeechSynthesizer`.
- **Runs backgrounded.** It's CPU/ONNX, not Metal/MLX — so unlike our on-device MLX models (which
  can't run in the background, see [project_local_model_background]), Kokoro *can* speak while
  backgrounded. This is the key differentiator and the reason it's worth the dependency.

**Plan:**
1. Add the **sherpa-onnx** dependency (vendored `.xcframework` / binary target) + the bridging header.
   Register in `project.base.yml`, regenerate via `./Scripts/generate-xcodeproj.sh`, and refresh
   `ci_scripts/Package.resolved` (see [project_xcode_cloud_resolved]).
2. `KokoroTTSEngine` (load on a background task; expose `isReady`, `speak(_:onFinish:)`).
3. Wire it into the fallback chain in `TextToSpeechService.speak(_:urgency:mirrorToHUD:)`:
   **ElevenLabs (if key + online) → Kokoro (if model present) → AVSpeech**. Add a Settings toggle + a
   TTS-engine preference.
4. **Model delivery:** the int8 model is tens of MB. Prefer a **downloadable model** (fetch on first
   enable into Application Support) over bundling, to avoid bloating the app binary — make Kokoro a
   no-op until the model is present (mirrors the SDK's no-Display no-op discipline).
5. Tests: sanitization still applies (we already sanitize before TTS); add a headless test that the
   engine-selection logic picks Kokoro when "model present + offline" and falls through correctly.

**Risk:** binary-dependency size/signing, and the license of the Kokoro weights — confirm
redistribution terms before bundling/hosting.

**Status: ✅ shipped (audio device-pending).** The tested core is in
[`Sources/Services/TTS/`](../../OpenGlasses/Sources/Services/TTS/):
- [TTSEngineSelector.swift](../../OpenGlasses/Sources/Services/TTS/TTSEngineSelector.swift) — a **pure
  policy**: given availability (ElevenLabs key + online, Kokoro model present), the user's
  `TTSEnginePreference`, and urgency, it produces the ordered `ElevenLabs → Kokoro → AVSpeech` fallback
  chain. `.system` is the guaranteed terminal; a high-urgency utterance promotes a *ready* on-device
  Kokoro ahead of the network engine (don't wait on the network for a hazard alert) but never
  downgrades to the robotic voice for speed. No SDK/audio types — fully unit-tested.
- [KokoroModelBundle.swift](../../OpenGlasses/Sources/Services/TTS/KokoroModelBundle.swift) +
  [KokoroModelStore.swift](../../OpenGlasses/Sources/Services/TTS/KokoroModelStore.swift) — a **bundle
  descriptor** (the shipped choice is `kokoro-int8-multi-lang-v1_1`, ~185 MB int8, en+zh, hosted as
  unpacked files on the `csukuangfj/kokoro-int8-multi-lang-v1_1` HuggingFace repo) and a
  descriptor-driven **presence/selection** check in Application Support. "Installed" means every
  declared file (`model.int8.onnx`, `voices.bin`, `tokens.txt`, `lexicon-*.txt`, `*-zh.fst`) **and**
  directory (`espeak-ng-data/`, `dict/`) is present and non-empty — directories included, since
  sherpa-onnx needs them. File/dir set verified against the live HF repo tree. Tested headlessly.
- [KokoroModelDownloader.swift](../../OpenGlasses/Sources/Services/TTS/KokoroModelDownloader.swift) +
  [HuggingFaceModelInstaller.swift](../../OpenGlasses/Sources/Services/TTS/HuggingFaceModelInstaller.swift)
  — the **download** layer: an orchestration state machine (`notDownloaded → downloading → verifying →
  ready/failed`) that stages the download, verifies it against the descriptor, then **atomically**
  swaps it into place (a partial/failed download never half-installs), plus a real
  **HuggingFace installer** that lists the repo tree (HF API) and fetches each unpacked file —
  **no `.tar.bz2`/bzip2 decoding needed**. Both network seams (list/download) are injected, so the
  enumeration/sequencing/progress logic is fully unit-tested headlessly. Not user-triggerable yet —
  the model is unusable until the binary is compiled in, so there's no point downloading ~185 MB.
- [KokoroTTSEngine.swift](../../OpenGlasses/Sources/Services/TTS/KokoroTTSEngine.swift) — gated behind
  the `KOKORO_ENABLED` compile flag; `isReady = isCompiledIn && model present` (always false in the
  shipped build, so the selector never routes to a non-functional engine), with a guarded/stub
  `synthesize` so the selection + wiring compile and are exercised without the binary.
- Wired into [TextToSpeechService.speak](../../OpenGlasses/Sources/Services/TextToSpeechService.swift)
  via `speakThroughEngineChain` (the chain is walked, each engine tried in turn), a
  `Config.ttsEnginePreference` + a **Voice Engine** picker and on-device-model status row in
  [ServicesSettingsView.swift](../../OpenGlasses/Sources/App/Views/ServicesSettingsView.swift). Existing
  sanitization/urgency/quota handling are unchanged; with Kokoro off the chain collapses to exactly
  today's `ElevenLabs → AVSpeech`. 46 headless tests.

**Decisions (2026-06-17):** redistribution is fine (Kokoro-82M weights + sherpa-onnx are **Apache-2.0**
→ proceed); model hosted on **HuggingFace** (`csukuangfj/kokoro-int8-multi-lang-v1_1`, unpacked files);
bundle is **`kokoro-int8-multi-lang-v1_1`** (~185 MB int8); binary integration is the **manual
`.xcframework` vendor** route (no official sherpa-onnx SPM package — only the community wrapper ships
prebuilt iOS xcframeworks).

**Binary + inference shipped.** The sherpa-onnx engine is now vendored and wired:
- [Vendor/SherpaOnnx](../../Vendor/SherpaOnnx) — a local SPM package wrapping **sherpa-onnx 1.13.3**
  (built from k2-fsa source, Apache-2.0) + **onnxruntime 1.26.0** (MIT) iOS static xcframeworks, committed
  under `Frameworks/`. `SherpaOnnxWrapper` re-exports the `sherpa_onnx` C module + carries the link
  settings (libc++, Accelerate). Registered in `project.base.yml`; the `KOKORO_ENABLED` flag
  (`OTHER_SWIFT_FLAGS`) compiles the real path in.
- [KokoroSynthesizer.swift](../../OpenGlasses/Sources/Services/TTS/KokoroSynthesizer.swift) — builds a
  sherpa-onnx `OfflineTts` from the downloaded model (model/voices/tokens + espeak-ng-data + dict +
  lexicons + `rule_fsts`), runs `Generate` on a serial queue, and packs the float samples into a
  16-bit PCM WAV. `KokoroTTSEngine` loads it lazily and runs synthesis off the main actor;
  `isCompiledIn` is now true so Kokoro is selectable once the model is present.
- The Settings **On-Device Voice (Kokoro)** section now has a real **Download (~185 MB)** button +
  progress/verify/installed states + remove, driven by `KokoroModelDownloader`.

**Validated:** the full headless suite (47 TTS-tier tests) + Debug **and** Release builds are green with
the binary linked and the inference compiled against the real sherpa-onnx C API. **Device-only
remainder:** actual neural audio output + backgrounded audio-session interplay (no Ray-Ban / device on
hand). The engine-selection fallback chain means a synthesis failure degrades to ElevenLabs/AVSpeech, so
the feature is safe to ship ahead of that on-device check.

**Note:** the vendored binaries add ~187 MB to the repo (largest single file 83.6 MB, under GitHub's
100 MB limit). If that weight is unwanted, the alternative is committing the 46 MB zips + an unzip step,
or hosting them as a release asset (remote `binaryTarget`) — a localized swap (same inference code).

---

### 2. Provider API keys → Keychain  *(security — shipped)* ✅

**Status: shipped.** [Config.swift](../../OpenGlasses/Sources/Utils/Config.swift) now routes every
provider secret (`anthropicAPIKey`, `openAIAPIKey`, `elevenLabsAPIKey`, …) through `KeychainService`,
with a one-time `migrateSecretsToKeychainIfNeeded()` that copies any existing UserDefaults values into
the Keychain and deletes the plaintext copies. Config's public API stayed stable, so call sites didn't
change; only secrets (not toggles/onboarding flags) were migrated. Fits our secrets-hygiene history.

---

### 3. Shared `DeviceSession` — camera + display on one session

**Today:** [GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift)
owns its own `DeviceSession` via `AutoDeviceSelector`, **separate** from `CameraService`. The SDK
allows one session per device, so while the HUD session is held, the camera falls back to the
iPhone-camera path. The file's own header flags unifying the two as "a tracked follow-up."

**Pattern to adopt:** a `useSharedDeviceSession(_:)` + an `ownsDeviceSession` flag, so the display
capability attaches to an externally-owned session (created by the camera path) instead of spinning up
its own; it only creates+owns a session when none is shared.

**Plan:** introduce a session owner/coordinator so `CameraService` and `GlassesDisplayService` share
one `DeviceSession` when both want the glasses, and the display gracefully owns-its-own when the
camera isn't active. Validate by headless tests of the ownership state machine; on-glasses behaviour
(camera + HUD simultaneously) is a device-only check to log as outstanding.

**Status: 🚧 core shipped.** The tested coordinator core is in:
- [DeviceSessionOwnership.swift](../../OpenGlasses/Sources/Services/Device/DeviceSessionOwnership.swift)
  — a pure reference-counting state machine over the `camera`/`display` capabilities: `acquire`
  reports the **first** holder (create the session), `release` reports the **last** (tear it down),
  idempotent, with `isShared`/`isHeld`/`holds`. No SDK types — fully unit-tested.
- [DeviceSessionCoordinator.swift](../../OpenGlasses/Sources/Services/Device/DeviceSessionCoordinator.swift)
  — `@MainActor` owner of the single real `DeviceSession`, driven by the ownership machine; creates on
  first acquire, stops + drops on last release, `invalidate()` for a died-underneath session. A
  `DeviceSessionHandle` protocol (which `MWDATCore.DeviceSession` satisfies with no new code) + an
  injected session factory make its create/teardown ref-counting testable via a fake session.
- 11 headless tests (`DeviceSessionCoordinatorTests`).

**Deferred (device-only):** wiring `CameraService` and `GlassesDisplayService` to source their session
from the coordinator (replacing their separate `Wearables.shared.createSession` calls with
`acquire`/`release`), and the on-glasses "camera + HUD on one session at once" validation. Rewiring
two hardware-coupled session owners can't be validated without Display hardware, so it's the staged
follow-up — the coordinator is the tested foundation it adopts.

---

### 4. `needs` / follow-ups in BrainStore  *(shipped this PR)* ✅

**Status: shipped.** [BrainStore.swift](../../OpenGlasses/Sources/Services/Brain/BrainStore.swift) gains
a first-class `Need` — what a person wants / is looking for / you owe them, a lightweight CRM
follow-up with an open/resolved lifecycle (a SQLite `needs` table, `addNeed`/`needs`/`resolveNeed`/
`resolveNeeds`, counted in `stats.openNeeds`, and cleared by `forget`). [BrainTool.swift](../../OpenGlasses/Sources/Services/NativeTools/BrainTool.swift)
surfaces it via `save_need` / `needs` / `resolve_need`, and open follow-ups appear in the `person`
dossier. Native-first (the brain works without OpenClaw). 11 headless tests.

**Optional fast-follow:** let `ProactiveAlertService` nudge open needs before a meeting with that
person.

---

### 5. Alternative hands-free triggers  *(conditional — Accessibility tier)*

**Today:** the only hands-free entry into the assistant is the **wake word**
([WakeWordService.swift](../../OpenGlasses/Sources/Services/WakeWordService.swift)) plus Siri App
Intents / Shortcuts (Plan Z). There is **no non-voice, no-Siri trigger** — nothing for a user who
can't or won't speak, or who's in a loud/silent setting.

**What to add:** several alternative ways to fire the assistant hands-free —
- **Volume-button trigger** — KVO on `AVAudioSession.outputVolume`; a volume press fires "what am I
  looking at."
- **Shake trigger** — a deliberate phone shake.
- **Cough / acoustic trigger** — `SoundAnalysis` / `SNClassifySoundRequest`, fires on a detected cough
  (generalises to clap/snap/whistle).
- **AirPod stem trigger** — a background AppIntent with Ray-Ban audio priority.

**Fit:** a natural **Accessibility tier** (Plan A) feature — "alternative input methods" for users who
can't use wake-word/voice.

**Plan:** add an `AlternativeTriggerService` exposing opt-in triggers (volume, shake, acoustic), each
routing to the same entry point as the wake word; gate behind a Settings section. Start with **shake**
(lowest risk) and the **acoustic** pattern; treat volume-button as opt-in/off-by-default.

**Caveats (why this is conditional, not a default-take):**
- **App Store risk:** hijacking the **volume button** as an app trigger runs against Apple's HIG and
  has historically drawn rejections — ship it off-by-default, clearly user-enabled, and be ready to
  drop it.
- **False positives:** cough/acoustic and low-threshold shake triggers misfire easily; need a
  confidence threshold + a debounce, and they shouldn't run while a card/critical flow is held.
- Battery: continuous `SoundAnalysis` is a wakeful audio tap — coordinate with the wake-word pipeline
  and the Presence-Aware Throttle ([Plan W](W-presence-aware-agent-throttle.md)) rather than running a
  second always-on listener.

**Negative knowledge (record, don't re-attempt):** a **glasses double-tap / touchpad** trigger is
**not possible** — the DAT SDK exposes no touchpad/gesture events. This corroborates
[Plan X](X-interactive-hud-now-next-tasks.md): the glasses/Neural Band firmware owns gesture, focus and
select; there is **no raw gesture/touchpad stream** to subscribe to. Triggers must therefore be
phone-side (button/motion/audio), never from the glasses hardware.

**Status: 🚧 core shipped.** The tested core is in
[`Sources/Services/Triggers/`](../../OpenGlasses/Sources/Services/Triggers/):
- [TriggerGate.swift](../../OpenGlasses/Sources/Services/Triggers/TriggerGate.swift) — the **pure gate**:
  confidence threshold + debounce window + suppression (don't fire while a conversation/card is held),
  clock passed in. The answer to the "false positives" caveat — fully unit-tested.
- [AlternativeTriggerService.swift](../../OpenGlasses/Sources/Services/Triggers/AlternativeTriggerService.swift)
  — `@MainActor` service that funnels every detected event through the per-trigger gate to one
  `onTrigger` callback (injected clock + enabled-set make the routing headlessly testable). The
  **CoreMotion shake detector** is wired live.
- [AlternativeTrigger.swift](../../OpenGlasses/Sources/Services/Triggers/AlternativeTrigger.swift) +
  `Config.alternativeTriggerEnabled` (all opt-in / off by default) + a **Hands-Free Triggers** Settings
  section. Wired in `AppState`: `onTrigger → handleWakeWordDetected(manual:)`, suppressed under the same
  guard as the wake word (`inConversation || isProcessing || AssistiveMode`). 16 headless tests.

**Deferred (device-tuned):** the **acoustic** (`SoundAnalysis` cough/clap/whistle) and **volume-button**
(`AVAudioSession.outputVolume` KVO) detectors — both need on-device threshold tuning and, for acoustic,
mic/battery coordination with the wake-word pipeline + Presence-Aware Throttle (the gate/routing already
accepts their events). The **AirPod stem** AppIntent (entitlement + device). On-device shake-threshold
and false-positive tuning is also a device check. Volume stays off-by-default (App-Store risk).

---

### 6. Multi-user profiles + PIN gate  *(conditional)*

A per-user, PIN-gated, profile-scoped storage layer (`ProfileManager`, `ProfileGateView`, `PINPadView`,
`ProfileScopedStore`) — we have nothing equivalent (`ReadingProfile` is unrelated accessibility prefs).

**Fit:** meaningful only for **shared-device / kiosk** deployments — which our museum-docent and
field-assist directions imply (one pair of glasses shared across staff, each with isolated
brain/memory/conversations). Take the PIN + `ProfileScopedStore` core; skip any email-OTP path (it
needs a backend; overkill on-device). Treat as a product decision, not a default — sequence it only if
shared-device use is committed. Any auto/agentic behaviour stays behind `agentModeEnabled`.

---

### 7. Declarative HUD widget board  *(defer — Display Phase 5)*

An LLM-driven declarative board: a `render_widgets` tool emits a list of widgets
(text/image/table/music) that the app renders, a natural **Display Phase 5** direction beyond our
single-frame + Now/Next task card (Plan X) and launcher (Plan Y). Take the **concept + the
JSON-decoding shape**. Defer until X/Y are fully shipped and there's a concrete multi-widget use case.

---

### 8. On-device ASR (SenseVoice) tier  *(headline — closes the offline loop)*

**Today:** every transcription path runs on Apple **`SFSpeechRecognizer`** —
[WakeWordService](../../OpenGlasses/Sources/Services/WakeWordService.swift),
[TranscriptionService](../../OpenGlasses/Sources/Services/TranscriptionService.swift),
[AmbientCaptionService](../../OpenGlasses/Sources/Services/AmbientCaptionService.swift),
[MemoryRewindService](../../OpenGlasses/Sources/Services/MemoryRewindService.swift),
[LiveTranslationService](../../OpenGlasses/Sources/Services/LiveTranslationService.swift). Apple's
recognizer can fall back to **server-side** recognition (a privacy + offline gap), is rate-limited,
and gives no emotion / audio-event signal.

**What to add:** an on-device **SenseVoice** recognizer running on the **sherpa-onnx runtime we already
ship** (vendored for Kokoro TTS, #1). The binary's `c-api.h` already exports the full ASR surface
(`SherpaOnnxCreateOfflineRecognizer`, `SherpaOnnxOfflineSenseVoiceModelConfig`,
`SherpaOnnxDecodeOfflineStream`, …) — so this is **zero new dependency**, just a model bundle + the
same engine pattern as Kokoro, an `OfflineRecognizer` instead of an `OfflineTts`. (Idea sourced from
[VisionClaw #61](https://github.com/Intent-Lab/VisionClaw/issues/61).)

**Why it fits us specifically:**
- **Zero marginal binary cost.** sherpa-onnx + onnxruntime are already vendored ([Vendor/SherpaOnnx](../../Vendor/SherpaOnnx)); ASR reuses the exact wrapper, bridging, and `KOKORO_ENABLED`-style gating.
- **Closes the fully-offline loop**: wake → on-device STT (SenseVoice) → local LLM (MLX) → on-device TTS (Kokoro). Private, no network, and — like Kokoro — **CPU/ONNX so it runs backgrounded**.
- **Faster** — SenseVoice is non-autoregressive (~5× Whisper, constant-time decode), good for a wearable.
- **Free signals we already consume**: it emits **emotion** tags (feed [emotion-aware TTS](../../OpenGlasses/Sources/Services/TextToSpeechService.swift)) and **audio-event** tags — music/traffic/crowd — (feed the Presence-Aware Throttle [Plan W](W-presence-aware-agent-throttle.md) / scene awareness).

**Plan (mirror the Kokoro tier):**
1. **Generalize the model layer.** Lift `KokoroModelStore`/`KokoroModelDownloader`/`HuggingFaceModelInstaller`
   into a **shared sherpa-onnx model-management layer** (a generic `SherpaModelBundle` descriptor +
   store + the HF installer, which is already model-agnostic) so ASR and TTS share one downloader.
2. **`OnDeviceASREngine`** — wraps `SherpaOnnxCreateOfflineRecognizer` with a SenseVoice model config
   (model/tokens, `use_itn`, language hint); decodes a PCM buffer → text (+ emotion/event tags) on a
   background thread. Gated behind the same compiled-in sherpa flag.
3. **`ASREngineSelector`** — a pure policy mirroring `TTSEngineSelector`: given (Apple-Speech available,
   SenseVoice model present, user preference, **online**), pick `On-Device → Apple Speech` (or the
   reverse by preference). On-device-first when offline; Apple-Speech-first stays the safe default until
   the model is downloaded. Fully unit-testable.
4. **Model delivery:** the SenseVoice int8 bundle (`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-*`, ~hundreds
   of MB fp32 / ~tens int8) downloads on first enable through the shared HF installer — no-op until
   present (same discipline as Kokoro).
5. **Wire one consumer first** — the discrete one-shot path (`TranscriptionService`) — behind a
   `Config.asrEnginePreference` + a Settings toggle, leaving the continuous wake-word path on Apple
   Speech initially.

**Deferred / risk:**
- **Streaming.** SenseVoice is **offline / non-streaming** — the always-on wake-word + ambient-caption
  paths need **VAD-chunked** feeding (sherpa-onnx ships a Silero VAD), so start with the discrete
  one-shot transcription path and treat continuous/streaming as the staged follow-up.
- **Accuracy + mic contention** are device-validated (no hardware here) — the deterministic core is the
  selector + the shared model store/downloader; real recognition quality is the device gate.
- Model size + first-download UX (reuse the Kokoro download UI).

**Scope the deterministic core (this PR):** the shared `SherpaModelBundle`/store/downloader refactor +
the SenseVoice descriptor, the `ASREngineSelector` pure policy, and `OnDeviceASREngine` behind the
sherpa flag with a guarded decode path — all headlessly testable. Real transcription accuracy +
streaming/VAD are deferred (device-validated), exactly as Kokoro's audio output was.

---

### 9. Vision-based procedure auto-advance (SOP spotter)  *(Field Assist × Plan X — sequence after #8)*

**Today:** [ProcedureRunner](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureRunner.swift) only
moves forward on an **explicit `advance(choice:)`** — the technician (or the LLM tool) reports the
observation and calls `procedure_runner` action `next`. The glasses don't *watch* and confirm; the
[Plan X](X-interactive-hud-now-next-tasks.md) Now/Next HUD card shows the step but doesn't tick forward
on its own. For a worker whose hands are busy, every step still needs a deliberate voice/band action.

**What to add:** a **`ProcedureSpotter`** — a proactive, throttled vision loop that, for the *active*
step, checks the camera frame against the step's expected objects / postconditions / validation, and
**auto-advances** when a **confidence threshold** is met **and sustained over a stability/evidence
window** (N stable observations across an active-duration), with **critical-step gating** (critical
steps never auto-advance — they surface an explicit confirm). Turns Field Assist procedures genuinely
hands-free. (Pattern sourced from the `GeminiLiveSpotter` in
[a VisionClaw fork](https://github.com/Intent-Lab/VisionClaw/compare/main...Lcunha25:VisionClaw:main) —
adapted to run **native-first** through our own `analyzeFrame`, not their Cloud-Run relay.)

**Why it fits us specifically:**
- Reuses [LLMService.analyzeFrame](../../OpenGlasses/Sources/Services/LLMService.swift) (vision),
  `ProcedureRunner.advance`, the `LiveCoachService` proactive-loop pattern (per-domain loop, dedup,
  throttle), `CaptureFlow`'s precondition/validation model (Plan U), and the Plan X HUD card (auto-tick).
- Coordinates with the **Presence-Aware Throttle** ([Plan W](W-presence-aware-agent-throttle.md)) —
  `LoopThrottle` already exists, so the spotter loop suspends when the user is away/idle, and with the
  frame-quality gate (Plan J `FrameThrottler`) to keep battery sane.

**Plan (deterministic core first):**
1. **Schema:** extend `Procedure.Step` with optional spotting criteria — `expectedObjects: [String]`,
   `postconditions: [String]`, `validationPrompt: String`, `confidenceThreshold`, a stability window
   (observations + duration), `critical: Bool`, `evidenceRequired: Bool`. **Backward-compatible:** steps
   without criteria stay manual-only (never auto-advance), so existing procedures are unchanged.
2. **`SpotterPolicy` (pure)** — the real architectural value: given a stream of per-frame observations
   (`matched` + `confidence` + timestamp), decide when to auto-advance — confidence ≥ threshold
   **sustained** over the stability/evidence window (M-of-N stable observations within the active
   duration), never for a critical step. A misfire-resistant state machine (the vision analogue of
   `TriggerGate`), fully unit-testable with synthetic observation sequences + a clock.
3. **`ProcedureSpotter` (`@MainActor`)** — drives the throttled `CameraService` frame loop per active
   step, builds the vision prompt from the step's criteria, parses the model's match/confidence, feeds
   `SpotterPolicy`, and calls `ProcedureRunner.advance` on a confirmed match. **Critical steps** →
   surface a HUD/TTS "confirm step done?" instead of auto-advancing. Gated behind a Settings toggle +
   `LoopThrottle`; only runs while a procedure is active.
4. **HUD (Plan X):** the Now/Next card auto-ticks on a confirmed advance (brief "✓ detected" cue);
   critical steps render a confirm affordance.
5. **Settings:** a **Hands-free step advance** toggle (off by default — it's a proactive vision loop).

**Deferred / risk:**
- **Detection accuracy** (does `analyzeFrame` reliably confirm step completion?) is device/LLM-validated
  — the deterministic core is `SpotterPolicy` + the schema + the loop wiring; real recognition quality +
  prompt/threshold tuning are the gate.
- **Battery:** continuous frame analysis — must ride the Plan W throttle + Plan J frame-quality gate and
  only run mid-procedure.
- **Safety:** a false auto-advance on a critical step is dangerous → critical steps **never** auto-advance
  (hard gate). Evidence-required steps must capture the frame as proof before advancing.
- **No new backend:** unlike the source fork (Gemini spotter via a Cloud-Run `WorkerAdminAPI`), this runs
  through native `analyzeFrame` — native-first, no relay (see [project_brain_store]).

**Scope the deterministic core (the PR after #8):** the `Procedure.Step` schema extension + the
`SpotterPolicy` pure state machine + the `ProcedureSpotter` loop wiring (gated, throttled, with a fake
frame source) + the Settings toggle — all headlessly testable. Real vision detection + tuning are
deferred (device/LLM-validated), exactly as Kokoro audio and ASR accuracy were.

---

## Explicitly out of scope

- **A third-party LLM provider/voice swap** — we're already multi-provider (OpenAI Realtime / Gemini
  Live); only worth it if a specific provider is wanted.
- **A tailnet/OAuth secret broker** — gateway-specific; the generic idea ("a key broker so secrets
  never live in the app") is a future design, not a port, and would sit behind `agentModeEnabled`.
- **An external personal "memory API" client** — would couple us to an undocumented localhost server
  and duplicates our native brain.
- **Lock-screen widget / Live Activity / App Intents / PTT** — we're already ahead
  (`LiveActivityManager`, `GlassesActivityWidget`, full Intents suite).
- **Multi-chat session management** — we have `ConversationStore` (+ encryption).
- **Gemini Live reliability tuning** (indefinite reconnect / frame-scaling) — we already have automatic
  reconnection with **exponential backoff** ([GeminiLiveService.swift:35](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift))
  plus a `FrameThrottler`.
- **Glasses double-tap / touchpad trigger** — not possible (no SDK gesture stream; see candidate 5).
- **Bluetooth glasses-mic audio fix, pre-emptive Gemini Vision, DirectSession, reconnect** — all
  already handled here, more robustly (`.allowBluetoothHFP/A2DP` across the audio pipelines;
  `LLMService.analyzeFrame`; Direct mode; backoff reconnect).
- A second CI (we use Xcode Cloud, `ci_scripts/`).

## Watch items (recorded, not actioned)

- **TTS request cancellation.** [TextToSpeechService.swift](../../OpenGlasses/Sources/Services/TextToSpeechService.swift)
  uses `URLSession.shared.data(for:)`, which **propagates `Task` cancellation** — if the enclosing
  speak `Task` is cancelled mid-fetch, the request throws `URLError(.cancelled)` and audio silently
  drops. Often that's *desired* (a newer utterance supersedes an older one), so this is **not a
  confirmed bug** — but if ElevenLabs TTS is ever observed dropping mid-request, the fix is an explicit
  `dataTask` + continuation (or shielding the fetch in an unstructured `Task`) so cancellation is
  deliberate, not incidental.

---

## Suggested sequence

1. **HUDPreviewView snapshot tests** (~0.5 day) — finish the already-shipped renderer as a regression gate.
2. ~~**API keys → Keychain**~~ — ✅ shipped.
3. ~~**`needs` in BrainStore**~~ — ✅ shipped.
4. ~~**Kokoro on-device TTS tier**~~ — ✅ shipped (selection policy + bundle descriptor + model store + download + real HuggingFace installer + **vendored sherpa-onnx 1.13.3 binary + real OfflineTts inference** + Settings download; 47 tests, Debug+Release green). Only actual on-device audio output remains to validate (no hardware).
5. **Shared `DeviceSession`** (~2–3 days) — closes the standing camera+display TODO.
6. *(If Accessibility tier is in scope)* **Alternative triggers** (~2–4 days) — shake + acoustic first; volume opt-in.
7. *(If shared-device committed)* **Profiles + PIN** (~4–6 days).
8. *(Deferred)* **Declarative widget board** — Display Phase 5, after X/Y ship.

## Device-less validation

No Ray-Ban Display / Neural Band hardware is on hand, so — consistent with Plans X/Y — **headless tests
+ the on-phone `HUDPreviewView` are the gate.** Outstanding device-only checks to log, not block on:
Kokoro audio-session interplay on glasses, simultaneous camera + HUD on one shared `DeviceSession`, and
on-glass legibility of any new frames.
