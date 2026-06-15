# Community Fork Harvest — VisionClaw-family features worth lifting

**Source:** A survey of seven community forks of [`Intent-Lab/VisionClaw`](https://github.com/Intent-Lab/VisionClaw) (the Meta-wearables `CameraAccess` sample our DAT/OpenClaw lineage shares). Each fork explored a different direction; this plan extracts only what's net-new and a genuine fit for OpenGlasses, and explicitly records what to skip.

**Forks reviewed:**

| Fork | Headline | Net-new to us |
|---|---|---|
| [`mediclaw-ai/HoloClaw`](https://github.com/Intent-Lab/VisionClaw/compare/main...mediclaw-ai:HoloClaw:main) | Phone-side renderer of the `MWDATDisplay` DSL + declarative widget board | Renderer **already harvested** (see below); widget board is a Phase-4+ concept |
| [`FortisRiders/VisionClaw`](https://github.com/Intent-Lab/VisionClaw/compare/main...FortisRiders:VisionClaw:main) | "Jarvis" rebrand: PTT voice mode, **Kokoro on-device TTS**, multi-user profiles + PIN, Keychain | **Kokoro TTS**, **Keychain secrets**, profiles (conditional) |
| [`benkraus/VisionClaw`](https://github.com/Intent-Lab/VisionClaw/compare/main...benkraus:VisionClaw:main) | Grok voice + a `DisplayHUDManager` with a **shared `DeviceSession`** + tailnet OAuth broker | The shared-session pattern (our standing TODO) |
| [`wert-yunsub/VisionClaw`](https://github.com/Intent-Lab/VisionClaw/compare/main...wert-yunsub:VisionClaw:main) | Swap OpenClaw → a self-hosted "Jarvis Memory API" (typed people/meeting/memory/**needs** tools) | The `needs`/follow-ups concept for our brain |
| [`Vamiko234/VisionClaw`](https://github.com/Intent-Lab/VisionClaw/compare/main...Vamiko234:VisionClaw:main) | Hands-free **alternative triggers** (volume button, shake, cough, AirPod stem) + Gemini reliability tuning | **Alternative triggers** (accessibility); reliability we already have |
| [`chisince1991-debug/VisionClaw`](https://github.com/Intent-Lab/VisionClaw/compare/main...chisince1991-debug:VisionClaw:main) | Bug-fixes/perf to the sample's audio/TTS/vision + a DirectSession debug overlay | **Nothing to port** — all handled more robustly here; one TTS-cancellation gotcha noted |
| [`AppToptoptop/VisionClaw`](https://github.com/Intent-Lab/VisionClaw) | — | **Nothing** — 0 ahead / 80 behind upstream (stale mirror) |

> **Naming note:** "Jarvis" appears in three of these forks and means a *different thing each time* — a rebrand, a personal localhost memory server, an assistant mode. None is a public product to "integrate with." This plan treats them purely as feature sources.

---

## Already harvested — Phone-side HUD renderer (HoloClaw)

HoloClaw's `DisplayDSLView` (a native SwiftUI renderer that walks the same `MWDATDisplay.FlexBox/Text/Button/Image/Icon` tree the SDK sends to the lens) is **already ported** as [HUDPreviewView.swift](../../OpenGlasses/Sources/App/Views/HUDPreviewView.swift) on `display/hud-phase4` (Plan Y / Display Phase 4) — brand-styled (coral accent, capsule buttons) and driven by `GlassesDisplayService.previewFlexBox(for:)`. This was the single highest-value item across all four forks and it's done. ✅

**Remaining follow-up (small):** add **snapshot tests** over `HUDPreviewView` for the canonical screens (task card, launcher menu) so the device-less preview is also a regression gate — this is the natural extension of "no Display hardware → tests are the gate." (~0.5 day.)

---

## Candidates

| # | Feature | Source | Effort | Verdict |
|---|---|---|---|---|
| 1 | **Kokoro on-device TTS tier** | FortisRiders | ~3–4 days | ✅ Take — fills a real gap |
| 2 | **Provider API keys → Keychain** | FortisRiders | ~0.5–1 day | ✅ Take — security; task chip filed |
| 3 | **Shared `DeviceSession` (camera + display)** | benkraus | ~2–3 days | ✅ Take — closes a standing TODO |
| 4 | **`needs` / follow-ups in BrainStore** | wert-yunsub | ~1 day | ◻︎ Optional — small native add |
| 5 | **Alternative hands-free triggers** | Vamiko234 | ~2–4 days | ◻︎ Conditional — Accessibility tier; App-Store caveat |
| 6 | **Multi-user profiles + PIN gate** | FortisRiders | ~4–6 days | ◻︎ Conditional — only if shared-device is a goal |
| 7 | **Declarative HUD widget board** | HoloClaw | ~3–5 days | ⏸ Defer — Display Phase 5 concept |

---

### 1. Kokoro on-device TTS tier  *(headline)*

**Today:** [TextToSpeechService.swift](../../OpenGlasses/Sources/Services/TextToSpeechService.swift) has exactly two engines — ElevenLabs (cloud, paid; `speakWithElevenLabs` ~L479) and AVSpeechSynthesizer (robotic fallback; `speakWithiOS` ~L557). There is **no on-device neural voice**.

**What the fork adds:** `KokoraTTSEngine` — a self-contained wrapper around **sherpa-onnx** running the `kokoro-int8-en-v0_19` model. It loads `model.int8.onnx` / `voices.bin` / `tokens.txt` from the bundle, generates a WAV on background CPU threads (`num_threads: 4`), and plays via `AVAudioPlayer`. Gated behind `#if KOKORO_ENABLED`.

**Why it fits us specifically:**
- **Offline + free + good quality** — a third tier between ElevenLabs and AVSpeech: no network, no per-character cost, far better than `AVSpeechSynthesizer`.
- **Runs backgrounded.** It's CPU/ONNX, not Metal/MLX — so unlike our on-device MLX models (which can't run in the background, see [project_local_model_background]), Kokoro *can* speak while backgrounded. This is the key differentiator and the reason it's worth the dependency.

**Plan:**
1. Add the **sherpa-onnx** dependency (vendored `.xcframework` / binary target) + the `SherpaOnnxBridge.h` bridging header. Register in `project.base.yml`, regenerate via `./Scripts/generate-xcodeproj.sh`, and refresh `ci_scripts/Package.resolved` (see [project_xcode_cloud_resolved]).
2. Port `KokoraTTSEngine` as `KokoroTTSEngine` (load on a background task; expose `isReady`, `speak(_:onFinish:)`).
3. Wire it into the fallback chain in `TextToSpeechService.speak(_:urgency:mirrorToHUD:)` (~L140): **ElevenLabs (if key + online) → Kokoro (if model present) → AVSpeech**. Add a Settings toggle + a TTS-engine preference.
4. **Model delivery:** the int8 model is tens of MB. Prefer a **downloadable model** (fetch on first enable into Application Support) over bundling, to avoid bloating the app binary — make Kokoro a no-op until the model is present (mirrors the SDK's no-Display no-op discipline).
5. Tests: sanitization still applies (we already sanitize before TTS); add a headless test that the engine-selection logic picks Kokoro when "model present + offline" and falls through correctly.

**Risk:** binary-dependency size/signing, and license of the Kokoro weights — confirm redistribution terms before bundling/hosting.

---

### 2. Provider API keys → Keychain  *(security)*

**Today:** [Config.swift](../../OpenGlasses/Sources/Utils/Config.swift) persists provider secrets in **UserDefaults plaintext** (e.g. `UserDefaults.standard.set(key, forKey: "anthropicAPIKey")` ~L374), which lands in unencrypted device backups. We already use the Keychain elsewhere ([ConversationEncryptionService.swift](../../OpenGlasses/Sources/Services/ConversationEncryptionService.swift)).

**Plan:** add a small `KeychainService`, route every provider secret getter/setter through it, and run a one-time migration that copies existing UserDefaults values into the Keychain then deletes the plaintext copies. Keep Config's public API stable so call sites don't change. Migrate **secrets only** — not toggles/onboarding flags. Fits our secrets-hygiene history (the scrubbed-Meta-creds PR). *A background task chip has been filed for this (`task_a50c6d7a`).*

---

### 3. Shared `DeviceSession` — camera + display on one session

**Today:** [GlassesDisplayService.swift](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift) owns its own `DeviceSession` via `AutoDeviceSelector`, **separate** from `CameraService`. The SDK allows one session per device, so while the HUD session is held, the camera falls back to the iPhone-camera path. The file's own header flags unifying the two as "a tracked follow-up."

**What the fork shows:** benkraus's `DisplayHUDManager` implements exactly this — `useSharedDeviceSession(_:)` + an `ownsDeviceSession` flag, so the display capability attaches to an externally-owned session (created by the camera path) instead of spinning up its own; it only creates+owns a session when none is shared.

**Plan:** crib the ownership pattern (not the file — our service is more advanced: render queue, dedup, interactive screens). Introduce a session owner/coordinator so `CameraService` and `GlassesDisplayService` share one `DeviceSession` when both want the glasses, and the display gracefully owns-its-own when the camera isn't active. Validate by headless tests of the ownership state machine; on-glasses behaviour (camera + HUD simultaneously) is a device-only check to log as outstanding.

---

### 4. `needs` / follow-ups in BrainStore  *(optional, small)*

The wert-yunsub fork's one genuinely-new memory concept is `save_need` — tracking what a person wants / is looking for / you owe them (a CRM follow-up). Our [BrainStore.swift](../../OpenGlasses/Sources/Services/Brain/BrainStore.swift) models entities, relationship edges, and encounters, but has no first-class "need/want/follow-up."

**Plan:** add a `needs`/`wants` relation (or a light `Need` record) to BrainStore, surface it in the `dossier`/`person` output of [BrainTool.swift](../../OpenGlasses/Sources/Services/NativeTools/BrainTool.swift), and optionally let `ProactiveAlertService` nudge open needs before a meeting. Native-first (brain works without OpenClaw). Everything else in that fork — people/meeting/memory search — we already have (`SemanticMemoryStore` + `MemorySearchTool`, `MeetingAssistantService` + `MeetingSummaryTool`, `FaceRecognitionService`).

---

### 5. Alternative hands-free triggers  *(conditional — Accessibility tier)*

**Today:** the only hands-free entry into the assistant is the **wake word** ([WakeWordService.swift](../../OpenGlasses/Sources/Services/WakeWordService.swift)) plus Siri App Intents / Shortcuts (Plan Z). There is **no non-voice, no-Siri trigger** — nothing for a user who can't or won't speak, or who's in a loud/silent setting.

**What the fork adds:** several alternative ways to fire the assistant hands-free —
- **Volume-button trigger** (`VolumeButtonTrigger.swift`, KVO on `AVAudioSession.outputVolume`) — a volume press fires "what am I looking at."
- **Shake trigger** — a deliberate phone shake (added, then they removed it in favour of an exam-solver prompt — the code is still a reference).
- **Cough / acoustic trigger** (`CoughTrigger.swift`, ~185 lines, `SoundAnalysis`/`SNClassifySoundRequest`) — fires on a detected cough.
- **AirPod stem trigger** — a background AppIntent with Ray-Ban audio priority.

**Fit:** a natural **Accessibility tier** (Plan A) feature — "alternative input methods" for users who can't use wake-word/voice. The acoustic-trigger pattern generalises (clap/snap/whistle), and the volume/shake triggers are tiny and self-contained.

**Plan:** add an `AlternativeTriggerService` exposing opt-in triggers (volume, shake, acoustic), each routing to the same entry point as the wake word; gate behind a Settings section. Start with **shake** (lowest risk) and the **acoustic** pattern; treat volume-button as opt-in/off-by-default.

**Caveats (why this is conditional, not a default-take):**
- **App Store risk:** hijacking the **volume button** as an app trigger runs against Apple's HIG and has historically drawn rejections — ship it off-by-default, clearly user-enabled, and be ready to drop it.
- **False positives:** cough/acoustic and low-threshold shake triggers misfire easily; need a confidence threshold + a debounce, and they shouldn't run while a card/critical flow is held.
- Battery: continuous `SoundAnalysis` is a wakeful audio tap — coordinate with the wake-word pipeline and the Presence-Aware Throttle ([Plan W](W-presence-aware-agent-throttle.md)) rather than running a second always-on listener.

**Negative knowledge (record, don't re-attempt):** the fork tried a **glasses double-tap / touchpad** trigger and reverted it — *"DAT SDK exposes no touchpad gesture events."* This corroborates [Plan X](X-interactive-hud-now-next-tasks.md): the glasses/Neural Band firmware owns gesture, focus and select; there is **no raw gesture/touchpad stream** to subscribe to. Triggers must therefore be phone-side (button/motion/audio) — not from the glasses hardware.

---

### 6. Multi-user profiles + PIN gate  *(conditional)*

The fork's only genuinely-new *capability* (we have nothing equivalent — `ReadingProfile` is unrelated accessibility prefs): per-user, PIN-gated, profile-scoped storage (`ProfileManager`, `ProfileGateView`, `PINPadView`, `ProfileScopedStore`, `KeychainService`).

**Fit:** meaningful only for **shared-device / kiosk** deployments — which our museum-docent and field-assist directions imply (one pair of glasses shared across staff, each with isolated brain/memory/conversations). **Take the PIN + `ProfileScopedStore` core; skip their email-OTP** (it needs a backend; overkill on-device). Treat as a product decision, not a default — sequence it only if shared-device use is committed. Any auto/agentic behaviour stays behind `agentModeEnabled`.

---

### 7. Declarative HUD widget board  *(defer — Display Phase 5)*

HoloClaw's `WidgetSpec` + `WidgetBoardView` is an LLM-driven declarative board: a `render_widgets` tool emits a list of widgets (text/image/table/music) that the app renders. A natural **Display Phase 5** direction beyond our single-frame + Now/Next task card (Plan X) and launcher (Plan Y). But the fork code is hackathon-grade (hardcoded placeholder image URLs, Gemini-coupled, phone-card-only, not sent to the lens). **Take the concept + the JSON-decoding shape, not the code.** Defer until X/Y are fully shipped and there's a concrete multi-widget use case.

---

## Explicitly NOT bringing

- **Grok** as a provider/voice (benkraus replaces Gemini; we're multi-provider and it overlaps OpenAI Realtime / Gemini Live — only if specifically wanted).
- **Tailnet/Grok OAuth broker** (benkraus) — xAI-OAuth- and OpenClaw-gateway-specific; the generic idea ("tailnet key broker so secrets never live in the app") is a future design, not a port, and would sit behind `agentModeEnabled`.
- **A "Jarvis Memory API" client** (wert-yunsub) — couples us to an undocumented personal localhost server; duplicates our native brain.
- **Lock-screen widget / Live Activity / App Intents / PTT** (FortisRiders) — we're already ahead (`LiveActivityManager`, `GlassesActivityWidget`, full Intents suite).
- **Multi-chat session management** (FortisRiders) — we have `ConversationStore` (+ encryption).
- **Wake-word manager** (benkraus) — our `WakeWordService` is more mature.
- **Gemini Live reliability tuning** (Vamiko234 — indefinite reconnect, frame-scaling for code-1007) — we already have automatic reconnection with **exponential backoff** ([GeminiLiveService.swift:35](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift)) + a `FrameThrottler`; theirs is a cruder forever-retry.
- **Exam-solver prompt / "solve this problem"** (Vamiko234) — off-strategy use case; skip.
- **GitHub Actions iOS build** (Vamiko234) — we use Xcode Cloud (`ci_scripts/`); no second CI.
- **Glasses double-tap / touchpad trigger** — not possible (no SDK gesture stream; see candidate 5).
- **Bluetooth glasses-mic audio fix, pre-emptive Gemini Vision, DirectSession, reconnect** (chisince1991-debug) — all already handled here, more robustly (`.allowBluetoothHFP/A2DP` across WakeWord/GeminiLive/OpenAIRealtime/LiveTranslation; `LLMService.analyzeFrame`; Direct mode; backoff reconnect).
- Rebrands, eye icons, and all **Android** changes.

## Watch items (recorded, not actioned)

- **TTS request cancellation** (from chisince1991-debug). [TextToSpeechService.swift:62](../../OpenGlasses/Sources/Services/TextToSpeechService.swift) and [:508](../../OpenGlasses/Sources/Services/TextToSpeechService.swift) use `URLSession.shared.data(for:)`, which **propagates `Task` cancellation** — if the enclosing speak `Task` is cancelled mid-fetch, the request throws `URLError(.cancelled)` and audio silently drops. Often that's *desired* (a newer utterance supersedes an older one), so this is **not a confirmed bug** — but if ElevenLabs TTS is ever observed dropping mid-request, the fix is an explicit `dataTask` + continuation (or shielding the fetch in an unstructured `Task`) so cancellation is deliberate, not incidental.

---

## Suggested sequence

1. **HUDPreviewView snapshot tests** (~0.5 day) — finish the already-shipped renderer as a regression gate.
2. **API keys → Keychain** (~0.5–1 day) — security; isolated; task already filed.
3. **Kokoro on-device TTS tier** (~3–4 days) — the headline capability.
4. **Shared `DeviceSession`** (~2–3 days) — closes the standing camera+display TODO.
5. **`needs` in BrainStore** (~1 day) — small, optional, native-first.
6. *(If Accessibility tier is in scope)* **Alternative triggers** (~2–4 days) — shake + acoustic first; volume opt-in.
7. *(If shared-device committed)* **Profiles + PIN** (~4–6 days).
8. *(Deferred)* **Declarative widget board** — Display Phase 5, after X/Y ship.

## Device-less validation

No Ray-Ban Display / Neural Band hardware is on hand, so — consistent with Plans X/Y — **headless tests + the on-phone `HUDPreviewView` are the gate.** Outstanding device-only checks to log, not block on: Kokoro audio-session interplay on glasses, simultaneous camera + HUD on one shared `DeviceSession`, and on-glass legibility of any new frames.
