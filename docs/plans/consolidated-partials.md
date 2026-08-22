# Consolidated Partials — Outstanding Work Across 🚧 Plans

One place for every **deferred / partial** item pulled out of the in-progress (🚧) plans. The house
style ships a deterministic, headless-tested core first and defers the live edge; this doc gathers
those deferred edges so the remaining work is visible in a single list instead of scattered across
plan docs.

Three buckets, by what unblocks them:

- **A. Buildable now** — headless software follow-ups. These can be picked up as normal one-PR
  sub-plans today; nothing external is required. **This is the actionable backlog.**
- **B. Hardware-pending** — needs the glasses / mic / camera / on-device model / audio routing to
  *do* or *validate*.
- **C. Backend/service-pending** — needs a gateway, relay, or external API to exist/be reachable.

A 🚧 plan whose only remaining work sits in **B** or **C** is **complete to the extent verifiable** —
treat it as done for code purposes; the row is its validation/integration checklist. When a buildable
item (A) lands, or a dependency for B/C appears, work it and update the originating plan doc's status,
then strike it here.

---

## A. Buildable now (headless follow-up PRs)

**Refreshed 2026-08-22** against the tree (previous pass: 2026-07-11). Fifteen rows were **verified
shipped and removed** rather than struck — the strikethroughs had grown to outnumber the live work,
which is the one thing this table cannot afford. Removed as done: AU streamed/realtime token capture,
pricing editor, **cache-token capture**, family-prefix overpricing guard (`ModelPricing.isSnapshotSuffix`)
and the `untrackedTurns` drift marker; AN project export/import; AB rubric breadth; U author UI,
`schema_version` + lossy-decode rejection, typed `captureRecord` OpKind, `SessionExporter` folding;
O standalone `DocumentsView`; AW user-correction capture; AT threshold Settings control; S complexity
classifier; V custom auth-header kind + `SSETransport` initialize handshake; T purge/prune trigger
wiring, launch-time flush and `inFlight` startup recovery; BM P8 Brain/Teleprompter project scoping
(`scopedNamespaces()` in both tools); BM P10 owner gate (`OwnerGatePolicy`).

| Plan | Outstanding item | Notes |
|---|---|---|
| [T](T-offline-field-queue-and-sync.md) | **Persist the conflict baseline**, then `PeerSyncSink` vs BL's `MockOpsPeer` | Re-verified 2026-08-22: three of the four named prereqs are done, but `ConflictResolver.knownVersion` is an in-memory `[String: Int]`, so every relaunch resets each session to version 0 and the first flush after launch cannot detect a conflict it should. Fix that before the networked sink, or the sink's first real test is against a resolver that can't fail |
| [T](T-offline-field-queue-and-sync.md) | Route per-event `SessionLogger` entries through the queue | Rescoped 2026-08-22: photo evidence and session export already enqueue (`FieldSessionService.swift:227`, `:309`); the `log.jsonl` events themselves are still file-only |
| [U](U-structured-capture-flows.md) | Remaining camera-binding **routing** (scan_code / photo / ocr_text) | Unchanged — no tool consults an active flow step yet; follow the `VisionAssessTool.swift:52` pattern (tool checks for an active step, offers the resolved value). Accuracy validation stays in B |
| [CU](CU-voice-turn-latency.md) | Wire realtime turn boundaries into `TurnRecorder` | New 2026-08-22, and named in P1's own deferred list: `TurnBackend` models both realtime stacks and the cohorts keep them apart, but neither session manager marks a turn, so no realtime turn is recorded and the Direct-vs-realtime baseline cannot be read off the panel |
| [AB](health-safety-advisor.md) | OCR-label `can_i_eat` **build half**: `use_camera` glue over the MedicationIdentifier OCR path (or a `food_label` schema on the AD substrate) | Unchanged — the camera+OCR plumbing exists; only label accuracy is device-gated. Plus the rubric riders: consume `.anticoagulated`, NSAID+asthma rule, `isClassified` unrecognized wording |
| [AJ](additional-capabilities.md) | Adopt `DeviceSessionCoordinator` in `CameraService` + `GlassesDisplayService` | Unchanged and re-verified 2026-08-22: the coordinator still has **zero consumers outside its own file**. Headless refactor on the fake-session seam; only simultaneous-use validation stays device-bound |
| [AK](standalone-chat-experience.md) | **BM P9:** SSE session seam + fixture tests + mid-stream-error handling + retry policy | Unchanged — no streaming seam protocol exists; partials-as-success truncation, accumulator concatenation, no 429 retry |
| [AV](visual-state-memory.md) | Thumbnail injection (second flag) + BrainStore ingest of aged keyframes | Both ride the shipped ring-buffer/builder; text-only context ships today |
| [S](S-plan-then-execute-and-safety-supervisor.md) | Phase 2: parallel-safe concurrent execution | Classifier shipped; concurrent steps still pending (changes the executor model) |
| [AM](embedding-quality-upgrade.md) | Skip-gated contextual A/B benchmark test + debug "Run embedding benchmark" row; grow the corpus to ~20-30 labelled pairs | The cheapest path to the default-flip decision |
| [AM](embedding-quality-upgrade.md) | Optional bundled MiniLM Core ML path | Gated on the `recall@k` benchmark showing a lift; the `EmbeddingBackend` seam is in place |
| [AJ](additional-capabilities.md) | Declarative HUD widget board (#7) | Display Phase-5 concept; defer until X/Y are fully exercised and a concrete multi-widget use case exists |

## B. Hardware-pending (glasses · mic · camera · on-device model · audio routing)

**Refreshed 2026-08-22.** Nine rows below are *device smoke owed on already-implemented code*, most
added since the last pass. They are one hardware session, not nine pieces of work, and at least two
default-off flags (CC's duplex audio, AT's frame dedup) cannot be turned on until it happens — so
the queue is now long enough that scheduling it beats picking up another headless PR.

| Plan | Shipped core | Live edge remaining | Validate with |
|---|---|---|---|
| [AP](audio-session-resilience-p2.md) | `AudioInterruptionPolicy` + `AudioRoutePolicy` + permanent engine + generation counters (20 tests) | Recovery firing on real OS interruptions + route flips; phone-speaker fallback selection | A real call/Siri interruption + BT↔speaker route change on device |
| [AS](audio-session-lease-coordinator.md) | `AudioSessionLedger` + `AudioSessionCoordinator` seam (13 tests) | Trim `AppState.switchMode`'s hardware-settling `sleep` | On-device timing across mode switches |
| [AJ](additional-capabilities.md) — shared `DeviceSession` | `DeviceSessionOwnership`/`Coordinator` ref-counting (tested) | **Simultaneous camera+HUD validation only** — coordinator *adoption* in both services moved to bucket A (2026-07-10; the coordinator is dormant code today, zero consumers) | On-glasses camera stream + HUD without contention |
| [AJ](additional-capabilities.md) — alt triggers | Gate + service + shake detector + Settings (16 tests) | Acoustic (`SoundAnalysis`) tuning; AirPod-stem AppIntent (entitlement) | On-device mic tuning; AirPods + entitlement |
| [AJ](additional-capabilities.md) — on-device ASR/TTS | SenseVoice + Kokoro chains, model stores, real inference behind flags (Debug+Release green) | Streaming/VAD endpointing + accuracy; Kokoro audio quality | On-device audio in/out (no simulator path) |
| [AD](structured-vision-assessment.md) | Structured-vision substrate + `vision_assess` + consumers (60 tests) | Assessment **accuracy** on real camera frames | On-glasses camera vs real instruments/scenes |
| [AV](visual-state-memory.md) | Ring buffer + builder + gate keyframe feed (12 tests) | On-device describe budget/quality; flip the flag on | Live Gemini session on glasses |
| [AT](frame-dedup-change-gate.md) | `PerceptualHash` + `FrameGate` wired (18 tests) | Flip `frameDedupEnabled` default on after motion sanity-check | Live streaming-vision on device |
| [AB](health-safety-advisor.md) | Rubric + grounding + advisor + tool (14 tests) | OCR-label photo path — **accuracy validation only** (build half moved to bucket A, 2026-07-10) | Glasses camera + a real food/drug label |
| [U](U-structured-capture-flows.md) | `CaptureFlow` + runner + `capture_flow` tool (11 tests) | Camera-binding **accuracy validation** only (the routing itself moved to bucket A, 2026-07-10) | On-glasses camera capture |
| [AG](teleprompter.md) | `ScriptAligner`/paginator + audio-paced mode + ingestion (Phases 1–4) | Live streaming-recognition tuning | On-device mic while reading |
| [AF](siri-and-local-server.md) #6 | `LocalServerDiscovery` candidate core (5 tests) + experimental scanner | Live Bonjour mDNS hit-rate | Real LAN with advertising/non-advertising servers |
| [AQ](speaker-diarization.md) | Parser/merger/registry + provider seam (24 tests) | Speaker-naming accuracy on real multi-speaker audio | On-device mic, multiple speakers |
| [X](X-interactive-hud-now-next-tasks.md) | Band card + voice bridge + sources (30 tests) | On-device band free-navigation spike | A Display device |
| [AA](first-aid-assist.md) | CPR metronome + protocol catalog + AED + tool (23 tests) | Metronome timing precision + AED spoken/HUD interplay | On hardware |
| [BR](BR-realtime-and-stream-hardening.md) | `ToolCallBreaker` + `StreamRecoveryPolicy` ([#236](https://github.com/straff2002/OpenGlasses/pull/236)) | Device smoke — recovery ladder against a real stream drop | Glasses camera stream, forced interruption |
| [BS](BS-transcript-guard-and-broadcast-breadth.md) | `TranscriptGuard` + broadcast breadth ([#238](https://github.com/straff2002/OpenGlasses/pull/238)) | Endpoint + device smoke — energy gate against real silence on the HFP mic | Glasses mic in a quiet room |
| [CB](CB-live-vision-detail.md) | Vision detail + async delivery (P1–P3) | Device smoke — sharp-frame quality, injected-turn behaviour, zoom feel | Glasses camera in a live session |
| [CC](CC-duplex-live-audio.md) | Graded echo cancellation (P1+P2, flag **default off**) | **P3 device matrix — this is what gates flipping the flag on**; barge-in in phone mode without the model hearing itself | Phone speaker + phone mic, then glasses |
| [CD](CD-fork-surfaced-remediation.md) | Fork-surfaced correctness fixes (P1–P3) | Device smoke of the Connect flow (P1 was a live startup crash) | A cold install on device |
| [CG](CG-interaction-pack.md) | `ChoiceDetector`/`DwellTracker`/`BadgeFieldParser` (P1+P2) | P3 device smoke — dwell feel and badge OCR on real badges | Glasses camera + a Display device |
| [CK](CK-sign-language.md) | Fingerspelling decode pipeline (P0+P2, model published) | Solo physical smoke per the protocol in the plan doc | Glasses camera, one signer |
| [CW](CW-realtime-audio-rig-recovery.md) | `AudioGraphRecovery` + `PendingPlaybackMirror` (41 tests) | **P4** first-reply survival on glasses HFP + restart-vs-rebuild ratio; P3's playout-tail drain needs an `async` teardown through both session managers | Glasses HFP mic at realtime session start |
| [AT](frame-dedup-change-gate.md) / [AV](visual-state-memory.md) | (see rows above) | Both default-off flags flip on the same motion sanity-check | One live streaming-vision session |

## C. Backend / service-pending (gateway · relay · external API)

**Refreshed 2026-08-22.** Four of these rows (N, AR, BH, V's OAuth half) wait on the same missing
artefact, and it now has a plan: **[CR](CR-cloud-action-agent-gateway.md)** — we have a complete
gateway *client* and no gateway. Read this section as CR's acceptance list rather than as five
independent blockages.

| Plan | Shipped core | Live edge remaining | Unblocked by |
|---|---|---|---|
| [N](N-remote-agent-harness.md) | Harnesses + registry + tools + **Codex/Claude Code preset adapters** (56 tests) | Gateway `agent.*` + live event stream; **live endpoint verification** of the Codex/Claude REST contracts (adapters + presets built) | Gateway implementing `agent.*` + live events; the real Codex/Claude endpoints to confirm paths against |
| [AR](gateway-device-pairing.md) | `SetupCode`/`GatewayAuthSelector`/`PairingResponseInterpreter` (23 tests) | Live approval round-trip (bootstrap → approve → per-device token) **+ finish the stubbed client half** (wire `startPairing`/`onPairingStatusChange` to Settings, use `payload.url`, accept tokens only mid-bootstrap) | Gateway implementing the v3 pairing handshake (shared-token today) |
| [BH](BH-gateway-remote-invoke.md) | `RemoteCommandParser`/`RemoteCommandPolicy`/`RemoteInvokeReply`/`RemoteCommandExecutor` + audited service, per-class toggles + activity log | Live gateway round-trip; fold in the pre-auth `req`-frame drop, `getTranscript` reclassing, `speak` source attribution, and the origin-aware policy/audit refactor (BL P4 seam) | A gateway that sends `node.invoke`-style frames |
| ~~[T](T-offline-field-queue-and-sync.md)~~ | ~~Networked sync sink~~ | **Moved to bucket A** (2026-07-10) — Plan BL's A2A peer is the target; `MockOpsPeer` makes it headless-buildable | — |
| [AQ](speaker-diarization.md) | Batch path + parser (24 tests) | Live diarized caption **WebSocket** stream | Deepgram live streaming (cloud) |
| [V](V-mcp-catalogue-and-transport-breadth.md) | `MCPCatalog` + transport parsing + `SSEEventParser` (37 tests) | OAuth device-code/PKCE + Keychain refresh only (SSE handshake moved to bucket A, 2026-07-10; deprioritized below the new custom-header item) | A real IdP |
| [M](M-webrtc-infra-and-audio.md) | App-side WebRTC + audio coordinator; M1/M2 reference impls | Deploy signaling relay + TURN (**on-demand only** — meeting-link covers remote; room-token auth is the gate); host the expert web client; on-device echo/precedence | A self-host/compliance customer |
| [AK](standalone-chat-experience.md) | Chat tab + rich rendering + real SSE streaming (Phases 1–3) | **Live-credential smoke only** — the verification bulk moved to headless SSE fixture tests via a session seam (BM P9, 2026-07-10), which also fixes mid-stream-error truncation + per-iteration streaming | Real API keys on device (one smoke) |

---

## D. Device-pending edges of ✅ plans (tracked in README prose only — pointer, 2026-07-10)

Three shipped plans carry a live edge that appears nowhere above because the index scopes to 🚧:
**BD** long-session realtime soak, **BG** on-glasses P2 voice-path smoke test, **BI**
uncertainty-phrase-list tuning. Listed here so the pickup queue is complete.

---

## How to use this

- **Want to ship something today?** Pick from **A** — each is a normal deterministic-core sub-plan PR.
- **Bucket B/C rows are not code debt** — they're the validation/integration checklist for when the
  hardware or backend exists. Most are an afternoon of wiring + validation once the dependency lands.
- When an item is done, update its originating plan doc's status and remove its row here.
