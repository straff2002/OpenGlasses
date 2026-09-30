# Plan GE — Automatic Offline Handoff (cloud → phone → cloud, mid-conversation)

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Continues:** Plan [BU](BU-offline-live-session.md) (offline live session). BU's pure core shipped
(`LiveSessionTurnLoop`, `FrameFreshnessPolicy`, `LiveTurnAssembler`); its P2 wiring
(`OfflineLiveSessionService`) is unbuilt, and BU puts "mid-session cloud fallback" out of scope.
GE reverses that for the conversation as a whole: it is the switch that moves an ongoing
conversation onto the phone and back, and its P3 builds BU P2's service as the live-mode target.
**Related:** Plan BK (`ModelFallbackChain`, reactive per-turn cascade), Plan T/BM (`Reachability`,
offline queue), Plan W (presence), Plan [GK](GK-on-device-intent-model.md) (offline routing hint).

---

## Trigger

Signal drops in a lift, a tunnel, a basement plant room or a rural road. Today the conversation
does not stop, but it limps: every turn first waits for the cloud request to fail and only then
cascades to a local model, and the model switch is restored at the end of the turn, so the next
turn pays the same timeout again. When signal returns nothing moves back on purpose.

## Outcome

- When the connection goes, the conversation carries on **on the phone**: on-device hearing,
  an on-device model, on-device voice, with a smaller tool set. It says so **once**, briefly.
- When a **stable** connection returns it moves back to the cloud on its own, carrying the whole
  transcript, including the turns answered on the phone.
- When the phone is locked in a pocket (the common case) the plan is explicit about what still
  works, because on-device MLX cannot run in the background.

## What exists today (verified 2026-10-01)

- **Connectivity:** `Services/Offline/Reachability.swift` wraps `NWPathMonitor` (`isOnline`,
  `isExpensive`, `onChange`, `setOnline` test seam). `path.status == .satisfied` is its only input, so
  a captive portal or a dead cellular link reads as online. `AppState` (`OpenGlassesApp.swift`
  ~1792) speaks "You're offline. Your work is being saved…" on **every** falling edge, whether or not
  any field work is queued.
- **Per-turn cascade:** `ModelFallbackChain.classify` maps `URLError` connectivity codes to
  `.retryOtherModel`; `next(...)` skips `isLocalMLX` candidates when `TurnNeeds.isBackgrounded`.
  `LLMService.sendMessageCascading` runs it and restores the pre-turn model in a `defer`.
  `ModelSwitchNarrator.fallbackPhrase` speaks the first hop ("X is unavailable — switching to Y").
- **On-device model:** `LocalLLMService` (MLX) throws `LocalLLMError.backgrounded` when
  `applicationState == .background`; `Services/LocalInference/` also has a llama.cpp backend
  (`LlamaCppLocalInferenceBackend`, `LlamaModelOptions.gpuLayers`). `LLMProvider.appleOnDevice`
  exists (Apple Intelligence). `OfflineModelOffer` decides whether first run offers the download.
- **On-device hearing and voice:** `Services/ASR/ASREngine.swift` `.auto` already prefers
  SenseVoice (`OnDeviceASREngine`, CPU/ONNX, runs backgrounded) when offline. `TextToSpeechService`
  drops ElevenLabs when `reachability.isOnline` is false; `TTSEngineSelector` falls to Kokoro
  (`KokoroTTSEngine`, CPU/ONNX, runs backgrounded; `KOKORO_ENABLED` is set in `project.base.yml`) and
  then AVSpeechSynthesizer. (The comment in `TextToSpeechService` saying Kokoro is "always false in the
  shipped build" is stale; the flags are on.)
- **Nothing** decides "we are offline for this conversation" at session level, classifies tools by
  whether they need the network, or hands the offline turns back to the cloud model.

## Design

**`ConnectivityHandoffPolicy`** (pure, injected clock). Inputs: path events (`satisfied`,
`unsatisfied`, `expensive`), turn outcomes (`connectivityFailure`, `cloudSuccess`), probe results.
States: `cloud` → `degraded` → `phone` → `returning` → `cloud`.
- Enter `phone` at once on `unsatisfied`, or after **2** consecutive connectivity-class turn
  failures while the path claims `satisfied` (captive portal, dead bearer).
- Leave `phone` only after the path has been `satisfied` for **≥ 20 s** *and* one probe succeeds
  (a `HEAD` to the active provider's host, which the app already talks to; no new third party).
  A failed probe restarts the 20 s window; probes back off 20 → 40 → 80 s, capped at 5 min.
- Never switch mid-utterance: a transition requested while `speaking`/`inferring` applies at the
  next turn boundary.
- Numbers are defaults in one struct, pinned by tests, tunable after device runs.

**`OfflineToolPolicy`** (pure). A table classifying every registered native tool as `local`
(timer, alarm, notes, step count, object memory, save location, calculator…), `needsNetwork`
(web search, weather, maps routing, send_via, MCP, gateway, skill-pack gateway bindings) or
`degraded` (works but thinner). A test walks `NativeToolRegistry` and fails on any unclassified
tool, so a new tool cannot silently land in the offline set. In `phone` state only `local` and
`degraded` tools are declared to the model; MCP and gateway tools are not declared at all.

**`HandoffTranscriptBridge`** (pure). Outbound (cloud → phone): the last turns that fit
`LocalModelBudget.contextWindow(for:)`, oldest dropped first, with a one-line summary of dropped
turns if one already exists (no new model call to make it). Inbound (phone → cloud): every turn
answered on the phone is kept in `ConversationStore` like any other and marked
`answeredOnDevice`, so the cloud model sees the full history plus one system note that the
marked answers came from a smaller model and may deserve a second look.

**`HandoffAnnouncer`** (pure). One line on entering `phone` ("I've lost signal. I'm running on
the phone now, so I can do a bit less."), one on return ("Back online."), none on flapping: a
second announcement within 2 minutes is suppressed. It absorbs the existing unconditional
offline line — the Plan T sync line is spoken only when the offline queue actually has items.
HUD gets a short status chip through `GlassesDisplayService`; glasses are optional, the phone
speaker/earbuds path is the same.

### The backgrounded case (phone locked in a pocket)

MLX uses Metal and cannot run backgrounded. The conversation keeps going with this ladder, first
available wins, decided by a pure `OfflineBrainSelector(appActive:available:)`:
1. **Apple on-device model** (`appleOnDevice`) — *device-unverified* whether it serves a
   background app; P3 measures it. Used only if verified.
2. **llama.cpp, CPU only** (`gpuLayers: 0`, a ≤1.5 B GGUF already installed) — CPU work is
   allowed while the audio background mode keeps the app alive; risk is the background CPU
   budget and heat. *Device-unverified*; off unless P3 shows it is safe.
3. **Deterministic answers + holding.** Requests a native tool can serve without a model (time,
   timer, "remember that…", step count, "where did I park") run through a small keyword router
   (replaced by GK's classifier when it lands). Anything else: "I can't think that through
   without signal while the phone is locked — I'll answer when we're back online." The question is
   held (in memory only, one slot per conversation, 30 min TTL) and answered by the cloud on return
   if still within TTL, or offered as a notification.

Hearing (SenseVoice) and voice (Kokoro/AVSpeech) are CPU and work backgrounded; only the
thinking changes.

### Modes

- **Direct mode:** full handoff as above (P1).
- **Gemini Live / OpenAI Realtime:** a dropped socket today goes to `LiveRecoveryDriver` (`Services/Live/`)
  retries. In GE, once retries are exhausted and the policy says `phone`, the session hands off to
  BU's offline session (foreground: camera-grounded VLM; background: the ladder above) and, on
  return, restarts the realtime session seeded through `LiveContextHandover` (P3).
- **Medical local-only / HIPAA:** local-only mode never uses the cloud, so GE is inert there.
  Under plain HIPAA mode the inbound bridge re-sends offline turns only to providers the mode
  already allows (`MedicalEgressGuard`); nothing new leaves.

## Phases (one PR each)

**P0 — Pure core.** `ConnectivityHandoffPolicy`, `OfflineToolPolicy`, `HandoffTranscriptBridge`,
`HandoffAnnouncer`, `OfflineBrainSelector` in `Services/Offline/Handoff/`. Tests:
`ConnectivityHandoffPolicyTests` (enter on unsatisfied; enter on two failures while "online";
20 s + probe to return; failed probe restarts; backoff cap; no switch mid-turn; flapping),
`OfflineToolPolicyTests` (every registered tool classified; MCP/gateway never offline),
`HandoffTranscriptBridgeTests` (window fit, oldest-first drop, `answeredOnDevice` marking),
`HandoffAnnouncerTests` (once per episode, 2-minute suppression, sync line only with queued items),
`OfflineBrainSelectorTests` (foreground MLX; background never MLX; unverified tiers off).

**P1 — Direct-mode wiring.** `ConnectivityHandoffController` (`@MainActor`) owns the policy,
feeds it `Reachability` events and cascade outcomes, and sets a session-level route that
`ModelRoutingPolicy` reads before `sendMessageCascading`, so offline turns go straight to the
local model with the offline tool set instead of timing out first. Probe route added to
`NetworkRoute` as `telemetryFree`. `Reachability.onChange` speech moves into the announcer.
Settings → Intelligence: "Keep talking without signal" (on when an on-device model is
installed; off otherwise with a link to the download). Tests: `ConnectivityHandoffControllerTests`
with a fake reachability, fake LLM and injected clock.

**P2 — Backgrounded ladder and held questions.** Deterministic router, held-question slot,
notification on TTL expiry, llama.cpp CPU option behind a default-off flag.
Tests: `HeldQuestionStoreTests` (one slot, TTL, never persisted), `OfflineKeywordRouterTests`.

**P3 — Live modes and device checks.** Build BU P2's `OfflineLiveSessionService` as the handoff
target; realtime resume through `LiveContextHandover`. Device checks (owed): airplane-mode toggles
mid-sentence; lift/tunnel flapping; captive portal; phone locked in pocket for each ladder tier
(Apple on-device in background, llama.cpp CPU heat and CPU-budget kills, 10-minute run); battery.

## Risks

- **Background CPU budget.** iOS can terminate a background app that holds the CPU hot for too
  long; llama.cpp tier stays off unless P3 proves otherwise.
- **Quality cliff.** A small model answering mid-conversation can be confidently wrong; the
  `answeredOnDevice` note lets the cloud model correct it on return.
- **Probe privacy.** The probe carries no user content and goes only to the host already in use.

## Decisions for Greig

1. Return hysteresis: **20 s stable + one probe** (recommended) vs. faster return.
2. Background ladder: allow the llama.cpp CPU tier at all, pending device numbers? *Recommend
   off by default until P3.*
3. Held questions: answer automatically on return (recommended, within 30 min) or only on request?
4. Should the cloud model be told which answers came from the phone? *Recommend yes (one line).*
5. Setting placement: Intelligence section, not glasses (works phone-only). Copy never names the
   plan.

## Out of scope

Offline maps/routing (MapKit needs network), offline web search, syncing a held question across
devices, and any change to the Medical local-only mode.
