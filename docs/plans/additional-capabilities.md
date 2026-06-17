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
| 1 | **Kokoro on-device TTS tier** | ~3–4 days | 🚧 Core shipped — selection + model store + wiring tested; binary/inference deferred |
| 2 | **Provider API keys → Keychain** | ~0.5–1 day | ✅ **Shipped** — secrets now Keychain-backed |
| 3 | **Shared `DeviceSession` (camera + display)** | ~2–3 days | 🚧 Core shipped — coordinator tested; live adoption deferred |
| 4 | **`needs` / follow-ups in BrainStore** | ~1 day | ✅ **Shipped** (this PR) |
| 5 | **Alternative hands-free triggers** | ~2–4 days | ◻︎ Conditional — Accessibility tier; App-Store caveat |
| 6 | **Multi-user profiles + PIN gate** | ~4–6 days | ◻︎ Conditional — only if shared-device is a goal |
| 7 | **Declarative HUD widget board** | ~3–5 days | ⏸ Defer — Display Phase 5 concept |

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

**Status: 🚧 core shipped.** The tested deterministic core (no binary needed) is in
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

**Remaining deferred (binary + device-validated):** vendor the **sherpa-onnx + onnxruntime
`.xcframework`s** + bridging header (a local `binaryTarget` — only with the real binaries present, since
a phantom one breaks the green build); the real ONNX `OfflineTts` inference inside `KokoroTTSEngine`
(behind `KOKORO_ENABLED`); enabling the now-implemented download from the Settings UI once the engine
can use the model. Actual neural audio + backgrounded audio-session interplay are device-only.

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
4. ~~**Kokoro on-device TTS tier**~~ — 🚧 core + download shipped (selection policy + bundle descriptor + model store + download orchestration + real HuggingFace installer + wiring + Settings; 46 tests). Decisions made (Apache-2.0; HuggingFace unpacked files; int8 multi-lang ~185 MB; manual xcframework). Binary vendor + ONNX inference deferred (device-validated).
5. **Shared `DeviceSession`** (~2–3 days) — closes the standing camera+display TODO.
6. *(If Accessibility tier is in scope)* **Alternative triggers** (~2–4 days) — shake + acoustic first; volume opt-in.
7. *(If shared-device committed)* **Profiles + PIN** (~4–6 days).
8. *(Deferred)* **Declarative widget board** — Display Phase 5, after X/Y ship.

## Device-less validation

No Ray-Ban Display / Neural Band hardware is on hand, so — consistent with Plans X/Y — **headless tests
+ the on-phone `HUDPreviewView` are the gate.** Outstanding device-only checks to log, not block on:
Kokoro audio-session interplay on glasses, simultaneous camera + HUD on one shared `DeviceSession`, and
on-glass legibility of any new frames.
