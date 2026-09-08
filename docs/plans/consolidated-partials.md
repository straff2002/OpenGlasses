# Consolidated Partials — Outstanding Work Across the Plans

One place for every **deferred / partial** item pulled out of the plan set. The house style ships a
deterministic, headless-tested core first and defers the live edge; this doc gathers those deferred
edges so the remaining work is visible in a single list instead of scattered across plan docs.

Four buckets, by what unblocks them:

- **A. Buildable now** — headless software follow-ups. These can be picked up as normal one-PR
  sub-plans today; nothing external is required. **This is the actionable backlog.**
- **B. Hardware-pending** — needs the glasses / mic / camera / on-device model / audio routing to
  *do* or *validate*.
- **C. Backend/service-pending** — needs a gateway, relay, store product, or external API to
  exist/be reachable.
- **E. Decisions owed** — waiting on an owner call, not on code or hardware.

**Complete to the extent verifiable.** These plans have nothing left to *build* — every planned
phase is shipped and headless-tested — and appear below only because a device or backend pass is
still owed: [AD](structured-vision-assessment.md), [AG](teleprompter.md),
[AP](audio-session-resilience-p2.md), [AA](first-aid-assist.md),
[X](X-interactive-hud-now-next-tasks.md), [AK](standalone-chat-experience.md),
[BG](BG-spine-refactor.md), [BJ](BJ-audio-activation-offmain.md),
[BO](BO-realtime-audio-activation.md), [BR](BR-realtime-and-stream-hardening.md),
[BS](BS-transcript-guard-and-broadcast-breadth.md), [BT](BT-reading-companion.md),
[BW](BW-chatgpt-subscription-provider.md), [CB](CB-live-vision-detail.md),
[CD](CD-fork-surfaced-remediation.md), [CG](CG-interaction-pack.md),
[CI](CI-broadcast-chat-readback.md), [CK](CK-sign-language.md),
[CO](CO-identity-budget-turn-taking.md), [CP](CP-outbound-frame-privacy.md),
[CV](CV-continuous-scene-narration.md), [CZ](CZ-independent-capture-audio.md),
[DD](DD-onboarding-signin-and-refresh.md), [DF](DF-app-accessibility.md),
[DJ](DJ-composed-tool-safety-and-execution-outcomes.md),
[DK](DK-protected-conversation-recall-index.md), [DQ](DQ-third-party-telemetry-opt-out.md),
[DY](DY-my-day-everyday-briefing.md), [EB](EB-action-reach-and-conversation-continuity.md),
[ED](ED-vault-manual-retrieval.md), [EF](EF-scanned-manual-import.md),
[EJ](EJ-manual-retrieval-fidelity.md). Treat them as done for code purposes; their rows are
validation checklists.

When a buildable item (A) lands, or a dependency for B/C appears, work it and update the originating
plan doc's status, then **remove** the row here — shipped rows are deleted, never struck through.

---

## A. Buildable now (headless follow-up PRs)

**Refreshed 2026-09-08** against a code-verified review of every plan (previous pass: 2026-08-22).
Removed as verified shipped: [AK](standalone-chat-experience.md)'s SSE session seam and the three
streaming defects (BM P9); [AM](embedding-quality-upgrade.md)'s two benchmark rows stay under A3 —
the plan is code-complete and they are the optional default-flip evidence it names.
Added, mostly from plans that did not exist or had not been audited on 08-22: the compliance-control
remainders ([DN](DN-outbound-fetch-and-sideload-hardening.md),
[DO](DO-local-network-transport-hardening.md), [DP](DP-release-entitlement-boundary.md),
[DL](DL-medical-secret-and-export-lifecycle.md)), [BH](BH-gateway-remote-invoke.md)'s three
still-open safety gaps, [CJ](CJ-survey-hardening-sweep.md)'s two hardening items, the unbuilt phases
of [CM](CM-dat-0-9-0-unlocks.md) / [CX](CX-live-session-vision-choice.md) /
[DZ](DZ-local-gguf-and-durable-agent-runtime.md) / [EH](EH-openclaw-2-0-wire-alignment.md) /
[EG](EG-vault-packs.md) / [EK](EK-manual-structure-and-figures.md) /
[EL](EL-equipment-identity.md) / [EM](EM-work-record-and-parts.md), and one-liners for the twelve
plans that are drafted or planned with nothing built.

### A1 — Bugs and gaps first

| Plan | Outstanding item | Notes |
|---|---|---|
| [T](T-offline-field-queue-and-sync.md) | Persist `ConflictResolver.knownVersion`, and stop `resolve()` advancing the baseline inside the `.conflict` branch | The baseline is an in-memory `[String: Int]`, so every relaunch resets each session to version 0 and the first flush after launch cannot detect a conflict it should |
| [BH](BH-gateway-remote-invoke.md) | Three open safety gaps: drop `type:"req"` frames until the connect handshake completes; reclass `getTranscript` out of the default-on `.observe` class; attribute remote `speak` text to its source | All three re-verified in `OpenClawEventClient`, `RemoteGlassesCommand`, `RemoteCommandExecutor`. The origin-aware policy/audit refactor the doc still calls "scheduled" shipped as BN P2 |
| [AR](gateway-device-pairing.md) | Accept a `device.paired` token only mid-bootstrap; wire `startPairing`/`onPairingStatusChange` into `GatewaySettingsView`; consume `payload.url` | `OpenClawEventClient` accepts the token unconditionally; `startPairing` has zero callers and the status callback zero subscribers |
| [CJ](CJ-survey-hardening-sweep.md) item 1 · [L](L-webrtc-expert-transport.md) · [M](M-webrtc-infra-and-audio.md) | WebRTC signaling security triad — path-traversal guard on static serving, per-room creator tokens, per-IP rate limits on create/join. This is also L/M's room-token gate | The room ID is still a bare capability string embedded in the viewer URL; no token, rate-limit or traversal code in `WebRTCStreamingService` |
| [CJ](CJ-survey-hardening-sweep.md) item 2 | Relative-time guard for `TimerTool` / `AppleRemindersTool` — deterministic parse of "in 15 minutes" overriding model arithmetic | No relative-time parsing in either tool today |
| [AQ](speaker-diarization.md) | On-device offline diarization for the HIPAA / no-cloud batch path | The HIPAA guard is a true per-buffer runtime invariant now, but the batch path silently falls back to *undiarized* on-device ASR |
| [AQ](speaker-diarization.md) | Speaker attribution into meeting summaries + `BrainStore.ingest(subject:)` | `MeetingAssistantService` / `MeetingSummaryTool` carry no speaker references at all |
| [DO](DO-local-network-transport-hardening.md) | Remaining P0 controls (token rotation, connection/request/idle deadlines even on loopback, capability gating that starts all-unavailable), then P1 TLS identity + pairing, P2 route authorization, P3 HTTPS-origin WebRTC replacement of the browser-HUD LAN HTTP | `LocalServiceExposurePolicy` makes Release refuse LAN binding for both servers; Debug still binds all interfaces and tokens were never rotated. P1/P3 not started |
| [DN](DN-outbound-fetch-and-sideload-hardening.md) | P3 manifest-first admission; Release-artifact inspection that the compiled behaviour matches the policy | `BoundedHTTPClient`, the consent-first sideload state machine and the archive/zip-bomb budgets shipped; the doc names these two as still pending |
| [DP](DP-release-entitlement-boundary.md) | P2.2 internal-only provider with an "INTERNAL ENTITLEMENT" watermark; P2.3 guarantee internal builds can't produce Release-accepted evidence; P3.2 source rule rejecting `UserDefaults.bool`/env/launch-arg entitlement decisions outside the single adapter; P3.3 StoreKit-test UI tests; P3.4 evidence + revocation contract docs | P0+P1 shipped (`FieldAssistEntitlementEvaluator`/`Provider`); `EntitlementTestSupport` covers only the first P2 item |
| [DL](DL-medical-secret-and-export-lifecycle.md) | P3.1 user-facing failure copy that never echoes PHI-bearing server bodies; P3.2 biometric / device-owner gate on the existing "Clear FHIR credentials" control; P3.4 privacy-doc + settings disclosure updates | The clear control exists in `MedicalExportSettingsView` with no `LAContext` anywhere near it |

### A2 — Unbuilt phases of in-flight plans

| Plan | Outstanding item | Notes |
|---|---|---|
| [CM](CM-dat-0-9-0-unlocks.md) | `WearStatePolicy` core + fan-out (meeting recorder, ambient captions, video recording, Live Coach, `PowerPolicyService`); P2a background-recording continuation in `SessionRecorderController`; P3 `CameraState`×`StreamState` → status-pill phase map; P4 button-row alignment plumbed from `HUDScreen` | P5 shipped under DQ; P1's stream half shipped as `CameraStreamStatePolicy`. The doff pause is device-traced, so the SDK-rollout gate the plan waited on is lifted |
| [CU](CU-voice-turn-latency.md) | P2 PR2 Silero backend behind `SpeechActivityDetecting` (+ `AVAudioConverter` resampling, hop chunking, install flag); P4 `WakePreRollRing`; wire turn boundaries into both realtime session managers | Only `NoSpeechActivityDetector` implements the seam; no realtime turn is ever recorded, so the Direct-vs-realtime baseline can't be read off the Developer panel |
| [CW](CW-realtime-audio-rig-recovery.md) | P3's playout-tail drain at hang-up (needs `async` teardown through both session managers); P2's `confirmedPlayedMilliseconds` consumer + Gemini truncate-on-loss reporting; the route-pinned-cues rider | `TextToSpeechService.playTone` still builds a private `AVAudioPlayer` per tone — exactly the path the rider forbids |
| [CX](CX-live-session-vision-choice.md) | P2 wiring — "start video"/"stop video" through `VoiceCommandParser`+`PhraseMatcher`, camera warm-up on entry, wake-word suppression applied and released on every exit path, inactivity timeout, Camera button driving the same machine | `VisionModePolicy`/`VisionModeGrammar` have zero references outside their own two files; `MetaCameraBackend.warmUpStream()` already exists to call |
| [DZ](DZ-local-gguf-and-durable-agent-runtime.md) | PR6 durable scheduler semantics; PR7 two-stage memory curation; PR9 skill-pack storage binding | PR1–PR5 all merged (runtime seam, GGUF load/generate, validated catalog/downloader, manager + diagnostics UI); no `DurableAgentScheduler`/`MemoryCuration`/`SkillPackStorage` in the tree |
| [EH](EH-openclaw-2-0-wire-alignment.md) | P2 structured questions/approvals UI wiring; P3 invoke-socket node role + tool descriptors | P1's 2.0 wire merged; every `question.requested`/`exec.approval`/`node.invoke` hit is BH-era code or a forward-referencing comment |
| [EG](EG-vault-packs.md) | P3 — republish the refrigeration vault as a pack to prove the path | Manifest, signature reuse and registry all shipped; no new API needed |
| [EK](EK-manual-structure-and-figures.md) | P4 — region-cropped figures, per-manual heading lists for PDFs with no type structure | Deferred by choice, not dependency |
| [EL](EL-equipment-identity.md) | P3 — nameplate fields beyond the model (serial, refrigerant, charge) | Same: scope choice |
| [EM](EM-work-record-and-parts.md) | P3 — hand-off to the ops peer, which needs [BL](BL-ops-platform-agent-bridge.md) built first | `propose_task`/`WorkRecord`/`PartsRequest`/`EndpointSyncSink` shipped and tested |
| [T](T-offline-field-queue-and-sync.md) | Route the per-event `SessionLogger` entries through the queue | Rescoped 2026-08-22 and unchanged: photo evidence and session export already enqueue; the `log.jsonl` events themselves are still file-only. Plain headless plumbing per the plan |
| [DV](DV-reminders-tool.md) | Notes field, named-list selection on create, `EKAlarm` location alarms, `list_reminders` filters | Core create/list/complete landed via DY P0; the tool schema carries none of these |
| [DI](DI-photo-library-hygiene.md) | `CameraStreamClaims.Owner` claim/release around a smart-camera capture's stream lifetime | The single item the plan's own close-out table marks "follow-up, not built" |
| [U](U-structured-capture-flows.md) | Route `barcode_or_voice` / `photo` / `ocr_text` into `fillCurrentStep`; wire `CaptureFlowService.insideRegion` to GeofenceTool regions | Only `voice_number` is wired; follow the `VisionAssessTool` pattern (tool checks for an active step, offers the resolved value) |
| [AJ](additional-capabilities.md) | Adopt `DeviceSessionCoordinator` in the Meta camera and display backends; then the SOP spotter core (`ProcedureSpotter`/`SpotterPolicy`) | `MetaCameraBackend` and `MetaDisplayBackend` each still create their own session — the coordinator has zero consumers. The spotter's SenseVoice prerequisite shipped |
| [AV](visual-state-memory.md) | Thumbnail injection into the LLM message (second flag); BrainStore ingest of aged keyframes | Thumbnails persist already, but `VisualContextBuilder` is text-only and nothing ingests |
| [AB](health-safety-advisor.md) | `use_camera` glue over the MedicationIdentifier OCR path (or a `food_label` schema on the AD substrate) | The rubric riders and the system-prompt routing rule all shipped in BM P4; only the camera half is missing |
| [AF](siri-and-local-server.md) | Trust-on-discovery mitigation — picker copy plus flagging first-seen and non-`.local` hosts | The `LocalServerDiscovery` candidate core shipped; nothing warns before a host is trusted |
| [AS](audio-session-lease-coordinator.md) | Trim `AppState.switchMode`'s hardware-settling sleep | Unblocked: the BJ PR1 prerequisite merged. Note BJ kept `assumeOwnership` deliberately — the doc's "slated for retirement" line is wrong |
| [DR](DR-broadcast-resilience.md) | Spoken once-per-episode notice on first drop and on give-up; then P2 multi-destination fan-out (`ParallelBroadcastCoordinator`, per-destination retry, Settings) and P3 `CaptionBurnPlan` evidentiary export | CY already shipped the reconnect/backoff/session-state core this plan's P1 assumed missing — the TTS notice is all that remains of P1 |
| [BQ](BQ-siri-discoverability.md) | Riders: per-item `.appEntityIdentifier()` on list views, `IntentValueRepresentation` on `GlassesContentEntity`, `AppIntentsTesting` adoption, `@AppEntity(schema:)` domain adoption | P1–P3 plus the `assistant.activate` follow-up are all merged |
| [BV](BV-power-policy.md) | Deeper posture consumers: camera snapshot-first escalation, idle stream teardown, local-model tier switch, reading-companion checkpoint | Posture is read by the throttler, `device_info`, walking routes, digest and look-closely; none of the four named escalations exist |
| [CQ](CQ-third-party-glasses-backends.md) | Retro-fit `CameraFeatureGate` to the EVEN display backend's unavailable-feature list; build Track A/P2's pure halves (`PhotoWebhookReceiver` routing/multipart/correlation/timeout, warm-up + back-off against `PowerPolicyService`) | P0 + P1 + B/P4 merged; everything else in the plan is vendor-SDK or hardware bound |
| [CN](CN-agent-vision-attachment.md) | Reconcile the doc's "default off" prose and the self-contradicting `Config` comment with `agentVisionAttachmentEnabled` defaulting **on**; fix the "EF P4" pointer to EH P4 | The frame has ridden the gateway's `attachments` list since EH P1 |
| [DQ](DQ-third-party-telemetry-opt-out.md) | Record the SDK's own bundled privacy manifest in the App Store submission checklist | The only non-device item the plan still names |
| [V](V-mcp-catalogue-and-transport-breadth.md) | SSE `initialize` handshake — `notYetSupported(.sse)` today | Buildable, but its fixture peer is BL's `MockOpsPeer`, so it sequences after BL P1 |
| [T](T-offline-field-queue-and-sync.md) | Offline `llmGrounding` routing | Low value and near-superseded by the local-model tiers |
| [CP](CP-outbound-frame-privacy.md) | Show the wearer what an outbound *stream* is sending (this exists for stills) | Gated on the two P3 decisions in §E |
| [EO](EO-hevc-glasses-stream.md) | The stop-during-warmup race the plan records but scopes out | Belongs to the reconnect follow-up, not to EO |
| [ED](ED-vault-manual-retrieval.md) | Table-aware chunking; procedure-page anchors | Open questions, explicitly non-blocking |

**Whole plan, unstarted** — nothing of these exists in the tree:

| Plan | Outstanding item | Notes |
|---|---|---|
| [BL](BL-ops-platform-agent-bridge.md) | P1 `A2AClient`/`A2ATaskPoller`/`OpsTaskTool`/`MockOpsPeer`; P2 envelope/router/replay cursor; P3 reply registry/router; P4 `MCPGlassesServer` `tools/list`+`tools/call` | Zero BL types anywhere; P1's auth-header prerequisite already landed as BM P6, so don't rebuild it. Blocks T's sync sink, V's SSE fixture, EM P3 and AF's tailnet probing |
| [CR](CR-cloud-action-agent-gateway.md) | P1 `GatewayTaskTransport` seam + clock-injected `DeferredTaskLedger` + `SpawnAckPolicy`; P2 `GatewayKind`, ledger-before-triage, expiry, agent-mode gate + HIPAA hard-disable; P3's authoring half (`docs/gateway/` reference source + documented traps) | None of the types and no `docs/gateway/`. The ledger fixes a live defect: late socket answers still reach `triageOpenClawNotification` |
| [CS](CS-standalone-watch-client.md) | P1 `WatchCommandRoute`/`WatchTranscript`/`WatchEndpointConfig`; P2's provisioning half (endpoint+token to watch Keychain, HIPAA revocation push); P3 honest empty state, route-marked transcript, dictation/synthesis, complication re-routing | `sendCommand`'s `isReachable` guard is intact and `OpenGlassesWatch/` is untouched since 2026-07-05. P2's transport target needs CR |
| [CT](CT-org-configuration-profiles.md) | P1 profile/ceiling/allow-list/verification cores; P2 scanner + `openglasses://enrol` + managed-config reader; P3 first-run branch, "Managed by ⟨org⟩" row, owner-gated removal | Zero types. `Config.swift` is 3,747 lines / 56 `@UserDefaultsBacked` measured 2026-09-08 — both the doc and index still quote 3,277/45, which is the plan's own stated reason this is hard |
| [DS](DS-even-g2-link-hardening.md) | `LinkKeepalivePolicy`, onboard-trigger disable/enable handshake, side-keyed reassembly, non-isolated ack box, measured text-fit renderer | `EvenBLETransport` has no keepalive and is entirely `@MainActor`-isolated, so the ack-resolution problem is real and unaddressed |
| [DT](DT-dat-session-lifecycle.md) | P1 `SelectorHealthPolicy` + lifetime devices-stream subscription/rebuild; P2 grace-period, deliberate-stop suppression, generation guard; P3 `SessionGestureInterpreter` | `DeviceSessionCoordinator` builds one selector in a factory closure and never rebuilds it |
| [DU](DU-eyes-free-capture-confirmation.md) | P1 stability-gated auto-capture; P2 double-read barcode acceptance; P3 vCard/MECARD parser merged with OCR fields | `DocumentScanTool` exists; none of the additions do |
| [DW](DW-offline-perception-tier.md) | P0 mic fan-out audit (and any re-tapping fixes it surfaces); P1 ASR provider + selection policy + transducer hygiene; P3 `FallbackCaptionComposer` + `ModelFallbackChain` | The P0 audit has never been run; `Sources/Services/ASR/` holds only the pre-existing translation-tier recognizer |
| [DX](DX-private-memory-timeline.md) | P0 contracts + privacy audit + `ObjectMemoryStore` off UserDefaults; P1 non-conversation timeline MVP; P3 capture/correction/voice routes; P4 adapters | Zero types. The doc's 🔴/🟠/🟡 phase glyphs are risk markers, not status |
| [EC](EC-ui-localization.md) | P1 code plus the specifier-parity and coverage-floor guardrail tests | The design-kit `LocalizedStringKey` prerequisite merged |
| [EI](EI-licence-issuance-portal.md) | P1 — the pure `Tools/LicenceIssuance` package (policy, ledger, billing, payload construction) | Nothing in the tree; CT's issuance half is delegated to this |
| [AL](on-device-image-generation.md) | The deterministic core, once the runtime decision in §E is made | Nothing built |
| [BA](BA-android-port.md) | Phase 0 spike — project skeleton, DAT SDK wiring, a MockDeviceKit vertical slice | No Android artefacts anywhere; everything through Phase 3 is headless |

### A3 — Optional / not scheduled

| Plan | Outstanding item | Notes |
|---|---|---|
| [S](S-plan-then-execute-and-safety-supervisor.md) | Phase 2 parallel-safe concurrent execution | Classifier and the DJ authorization hardening shipped; concurrency changes the executor model |
| [AJ](additional-capabilities.md) | Declarative HUD widget board | Display Phase-5 concept; defer until X/Y are fully exercised |
| [BP](BP-web-hud-mirror.md) | P5 — WebSocket push inlined in the rendered page, D-pad room-code pairing, iframe tabindex fix | Pure and fixture-testable today, but deliberately sequenced after the P3/P4 hardware experiments |
| [AK](standalone-chat-experience.md) | Per-provider streaming backfill (Gemini) | The rest shipped as BM P9 |
| [BX](BX-skill-packs.md) | P4 JavaScriptCore skill-pack handlers | Deferred by design |
| [V](V-mcp-catalogue-and-transport-breadth.md) | OAuth device-code/PKCE + Keychain refresh | Deprioritized, and needs a real IdP anyway |
| [AM](embedding-quality-upgrade.md) | Skip-gated contextual A/B benchmark test + debug "Run embedding benchmark" row; grow the corpus to ~20–30 labelled pairs | The plan's own cheapest path to the `contextualEmbeddingEnabled` default-flip decision; unchanged since 08-22 |
| [AM](embedding-quality-upgrade.md) | Optional bundled MiniLM Core ML path behind the `EmbeddingBackend` seam | Gated on the `recall@k` benchmark showing a lift |

## B. Hardware-pending (glasses · mic · camera · on-device model · audio routing)

**Refreshed 2026-09-08.** The queue has roughly doubled since 08-22 — not because work regressed but
because a great deal shipped headless and now waits on the same few sittings. Three rows below are
*groups*: one audio session, one streaming-vision session, one Field Assist session would discharge
about half this table. Several default-off flags ([CC](CC-duplex-live-audio.md)'s duplex audio,
[AT](frame-dedup-change-gate.md)'s frame dedup, [AV](visual-state-memory.md)'s keyframes) and one
whole phase ([EO](EO-hevc-glasses-stream.md) P3, [DZ](DZ-local-gguf-and-durable-agent-runtime.md)
PR8) cannot move until it happens.

| Plan | Shipped core | Live edge remaining | Validate with |
|---|---|---|---|
| [AP](audio-session-resilience-p2.md) · [AS](audio-session-lease-coordinator.md) · [BJ](BJ-audio-activation-offmain.md) · [BO](BO-realtime-audio-activation.md) · [CW](CW-realtime-audio-rig-recovery.md) — **one audio session** | Interruption/route policies, ledger + coordinator, off-main activation seam, `AudioGraphRecovery`+`PendingPlaybackMirror` | Recovery on real interruptions and route flips; no settling race after the sleep trim; the BJ smoke (wake, TTS, BT flip, translation, call interruption); realtime start/stop + TPC sweep; CW's route-change-mid-reply verdict and restart-vs-rebuild ratio | One sitting: a call/Siri interruption, a BT↔speaker flip, and a realtime session, on glasses |
| [BG](BG-spine-refactor.md) | P1–P5 all merged (flow engine, both handler chains, turn runner, cancellable typed turns, merged realtime audio engine) | On-glasses smoke of the P2 voice path — wake → transcribe → LLM → speak → resume, barge-in and cancel. Open since 2026-07-04 | Shares the audio sitting above |
| [AT](frame-dedup-change-gate.md) · [AV](visual-state-memory.md) · [CB](CB-live-vision-detail.md) · [CC](CC-duplex-live-audio.md) · [CX](CX-live-session-vision-choice.md) · [EO](EO-hevc-glasses-stream.md) — **one streaming-vision session** | `PerceptualHash`+`FrameGate`; ring buffer + keyframe feed; vision detail + async delivery; graded echo cancellation; `VisionModePolicy` core; HEVC negotiation + `DecoderRecoveryPolicy` | Motion sanity-check before flipping the two dedup/keyframe defaults on; sharp-frame quality, injected-turn behaviour and zoom feel; CC's P3 barge-in matrix (gates default-on); whether warming hides the cold start; EO P2's tier/fps/decoder-rebuild/HFP/thermal numbers, which pick the codec defaults and unblock P3 | One live streaming session across the three voice modes |
| [ED](ED-vault-manual-retrieval.md) · [EF](EF-scanned-manual-import.md) · [EJ](EJ-manual-retrieval-fidelity.md) · [EK](EK-manual-structure-and-figures.md) · [EL](EL-equipment-identity.md) · [EM](EM-work-record-and-parts.md) — **one Field Assist session** | Vault retrieval + evidence policy, scanned-page reader, retrieval-fidelity gate, `manual_figure`, equipment identity, work record + parts | Oldest-phone retrieval and OCR latency with a real OEM manual; run `RetrievalGateCalibrationTests` on a phone carrying the `com.apple.linguisticdata` sentence asset and set `RetrievalEvidencePolicy.default(for:)` from measurement instead of a placeholder; a figure turn against a cloud provider; nameplate → `set_equipment` → scope check; one real email and one real message sent | One field sitting with a customer manual and a real unit |
| [AD](structured-vision-assessment.md) | Structured-vision substrate + `vision_assess` + consumers | Assessment **accuracy** on real camera frames | On-glasses camera vs real instruments/scenes |
| [AB](health-safety-advisor.md) | Rubric + grounding + advisor + tool (34 tests) | OCR-label photo path — accuracy only; the build half is in §A | Glasses camera + a real food/drug label |
| [U](U-structured-capture-flows.md) | `CaptureFlow` + runner + `capture_flow` tool | Camera-binding **accuracy** only; the routing is in §A | On-glasses camera capture |
| [AQ](speaker-diarization.md) | Parser/merger/registry + provider seam + chips + batch wiring | Live diarized caption WebSocket stream; speaker-naming accuracy on real multi-speaker audio | On-device mic, several speakers |
| [AG](teleprompter.md) | `ScriptAligner`/paginator + audio-paced mode + ingestion | Live streaming-recognition tuning | On-device mic while reading |
| [AF](siri-and-local-server.md) | `LocalServerDiscovery` candidate core + experimental scanner | Live Bonjour mDNS hit-rate | A LAN with advertising and non-advertising servers |
| [X](X-interactive-hud-now-next-tasks.md) | Band card + voice bridge + sources | On-device band free-navigation spike | A Display device |
| [AA](first-aid-assist.md) | CPR metronome + protocol catalog + AED + tool | Metronome timing precision; AED spoken/HUD interplay | On hardware |
| [AJ](additional-capabilities.md) | Coordinator ref-counting; alt-trigger gate/service/shake detector; SenseVoice + Kokoro chains behind flags | Simultaneous camera+HUD without contention; acoustic trigger tuning and the AirPod-stem intent (entitlement); streaming/VAD endpointing and Kokoro audio quality | On-glasses camera+HUD, on-device mic and speaker |
| [BR](BR-realtime-and-stream-hardening.md) | `ToolCallBreaker` + `StreamRecoveryPolicy` + `ConnectionGenerationGate`; the 09-06 stopped-while-wanted reconnect | One session covering a forced stream failure (walk out of BT range), a live tool-failure loop, and a reconnect under network flap | Glasses camera stream, forced interruption |
| [BS](BS-transcript-guard-and-broadcast-breadth.md) | `TranscriptGuard`, `BroadcastGeometry`, source selector + PiP compositor | A silence session producing zero captions; audible mic audio per preset; a mid-stream source switch plus a timed dual-capture thermal run | Glasses mic in a quiet room, then a live stream |
| [BT](BT-reading-companion.md) | P1–P4 (page-turn detector, session store, alignment index, stats/HUD) | One 20-minute physical-book session and one e-reader session (glare/contrast) with battery notes; watch `unreadableCaptures` to tell tuning from a quiet reader | Glasses camera + a real book |
| [BQ](BQ-siri-discoverability.md) | P1–P3 + `assistant.activate` follow-up merged | Apple Intelligence smoke: phrase invocation, onscreen "this" resolution, assistant-slot activation | A phone with Apple Intelligence enabled |
| [BU](BU-offline-live-session.md) | P1 turn loop + assembler + freshness policy | P2 `OfflineLiveSessionService` wiring — speech stack, camera publisher, local VLM, streaming speech, foreground-only guard. Device-pending by design: on-device MLX cannot be meaningfully validated headless | Glasses + a loaded local model |
| [BV](BV-power-policy.md) | `PowerPolicy` + service (30 tests) | Glasses thermal via the DAT `deviceStateStream` (not observed today); drain and hot-day threshold tuning | A long session on hardware |
| [BW](BW-chatgpt-subscription-provider.md) | P4's code half + account-scoped models + device-code fallback | P4 live verification checklist on a phone with a real account, including a voice-quality listen | Phone + a live ChatGPT account |
| [CD](CD-fork-surfaced-remediation.md) | P1–P3 (bootstrap, phrase matcher, onboarding gate) | Device smoke of the Connect flow from the desync state — P1 was a live startup crash | A cold install on device |
| [CG](CG-interaction-pack.md) | `ChoiceDetector`/`DwellTracker`/`BadgeFieldParser` | P3 — saliency dwell feel and badge OCR on real badges | Glasses camera + a Display device |
| [CH](CH-media-button-trigger.md) | `MediaTriggerService`/`Policy` + music control (flag off) | Whether iOS grants Now Playing to a `mixWithOthers` session; which temple gestures map to which AVRCP commands on this firmware; double-tap latency | Glasses temple gestures |
| [CI](CI-broadcast-chat-readback.md) | Parser, readback policy, chat client, arbiter | P3 — TTS bleed into the broadcast mic, battery impact, YouTube chat conformer | A live broadcast with chat |
| [CK](CK-sign-language.md) | P0–P2 + activation surface; model published and the default repo live | Solo physical smoke per the protocol: frame-rate/battery envelope, distance/angle robustness, decode cadence, confidence floor against live logits | Glasses camera, one signer |
| [CM](CM-dat-0-9-0-unlocks.md) | P5 (via DQ) + P1's stream half | P2b background-capture spike, plus the streaming/capture/ButtonGroup smoke the plan owed — now actually runnable, the rollout gate is lifted | Glasses on 0.9.0 |
| [CN](CN-agent-vision-attachment.md) | P1+P2 attachment policy/phrasing, wired both adapters | Pin a real label → dispatch → confirm the agent's answer carries detail the spoken description lacked | Glasses camera + a delegated run |
| [CO](CO-identity-budget-turn-taking.md) | Items 0–4 (scope, ambiguity margin, budget policy, turn admission, continuation) | The blur's ~1 fps cost on the live path; `margin` tuned against real enrolments; no empty completions or truncation at 2048 against a live key; suspend/resume across real BT route changes; the turn window in conversation | Glasses + a live model key |
| [CP](CP-outbound-frame-privacy.md) | `OutboundFrameRelay` + cores, all five egress consumers rewired | P3 numbers: sustained fps through the relay while broadcasting at 200 ms detection, drop count under real motion, thermal over a long recording, and whether 200 ms covers a walking bystander. `droppedFrameCount` is already surfaced | A long broadcast with a moving bystander |
| [CQ](CQ-third-party-glasses-backends.md) | P0 + P1 + B/P4 (tier policy, camera backend seam, capture protocol) | Track A/P2's vendor-SDK backend and P3's WHIP/WebRTC loopback spike; the blocking cellular experiment (does iOS keep cellular alive while joined to the glasses' routeless AP) which gates P6/P7 entirely; Track B P5 transport and P6 media transfer | Third-party glasses in hand |
| [CR](CR-cloud-action-agent-gateway.md) | — (unbuilt; see §A) | P5 — on-device round trip: dispatch → ack → late answer → spoken, with a latency profile | A phone plus a running gateway |
| [CS](CS-standalone-watch-client.md) | — (unbuilt; see §A) | P4 — a cellular watch out of Bluetooth range actually answering; battery cost; no double-send on reconnect mid-request | Cellular Apple Watch |
| [CU](CU-voice-turn-latency.md) | P1 + P2 PR1 (timeline/ledger/recorder + detector seam) | P3's KV prefix cache and per-model routing-prompt sizing, gated on P1's device numbers (not yet taken); P5's perceived latency on both mic routes, false-cut rate, detector cost, converter rebuild on route change, pre-roll correctness | Glasses and phone mic, both routes |
| [CV](CV-continuous-scene-narration.md) | P1–P3 + captions arbitration + camera ownership | P4 — dwell and duty cycle on a walked route, speech-gate threshold, sustained thermal/battery, decode-vs-synthesis contention with live captions, background camera-release trade, `reserve` refusal tuning; plus an accessibility review with a wearer who would use it | A walked route, on glasses |
| [CY](CY-broadcast-resilience-and-quality.md) | Session machine + reconnect policy + adaptive bitrate; the 08-27 `hasSentAnything` readout and unconditional stall→reconnect guard | A real mid-stream drop (airplane mode, Wi-Fi→cellular), clean republish against a live ingest, adaptation under genuine congestion, 30 fps end-to-end, give-up-budget validation, and a first successful LAN publish once the zero-bytes root cause is proven | Glasses + a live RTMP ingest |
| [CZ](CZ-independent-capture-audio.md) | Arbiter, assistant gate, capture router; the 08-27 `CaptureAudioNormalizer` fix | Handover audio continuity on a Bluetooth glasses route — listen to the artefact, don't count buffers; assistant-inaudibility check; mic release | Glasses mic, mid-recording toggle |
| [DF](DF-app-accessibility.md) | P1–P4 all shipped, DG P4 rows closed | A manual VoiceOver pass on hardware, and a session with a blind user whose judgement is the specification | Phone + VoiceOver, and a user |
| [DH](DH-local-gemma-keyless-tier.md) | P1 + P2; P3's headroom correction (`MemoryHeadroom`, photo-turn refusal, pre-resize cap) | P3's full vision-wiring measurement — decode latency and Metal contention against on-device TTS; P4's performance matrix (tok/s, first-token latency, battery, thermal) across phones, which sets P2's real thresholds | Several phones, oldest included |
| [DK](DK-protected-conversation-recall-index.md) | P0–P3 complete; benchmarks and Release gates green | Oldest-supported-phone footprint and lifecycle smoke | The oldest supported iPhone |
| [DL](DL-medical-secret-and-export-lifecycle.md) | P0–P2 (credential and configuration stores migrated to protected storage) | P3.3 — a real share to Files/Mail/AirDrop with cleanup verified, including after a force-quit, plus app-container TTL inspection | A phone with the share sheet |
| [DN](DN-outbound-fetch-and-sideload-hardening.md) | P0–P3 engineering checkpoints | Physical-device network evidence: a real DNS rebind, live redirect chains, an on-device sideload end to end | A phone on a controlled network |
| [DO](DO-local-network-transport-hardening.md) | P0 containment (`LocalServiceExposurePolicy`) | Live-socket verification and Release-artifact inspection on a real build | A device on a real LAN |
| [DQ](DQ-third-party-telemetry-opt-out.md) | P0 + P1 + P2 copy (opt-out keys, `MetaTelemetryBlock`, guard tests) | Trigger a controlled crash on real glasses with packet capture confirming no vendor crash-report egress; read the diagnostics copy on device | Glasses + a network capture |
| [DR](DR-broadcast-resilience.md) | — (P1's core shipped under CY) | P2's exit gate — a real RTMP endpoint drop, Wi-Fi killed mid-stream | A live ingest |
| [DS](DS-even-g2-link-hardening.md) | — (unbuilt; see §A) | P1's exit gate (a backgrounded app holds both lens links past five minutes) and P2's (the glasses' own assistant does not fire) | EVEN G2 glasses |
| [DT](DT-dat-session-lifecycle.md) | — (unbuilt; see §A) | P3 — which physical gestures produce which session transitions on current firmware; the plan defers this to CH P3's protocol run | Glasses, shared with CH |
| [DV](DV-reminders-tool.md) | Core create/list/complete via DY P0 | Location-alarm firing is system behaviour, not unit-testable — run it alongside a geofence test | A phone, outdoors |
| [DW](DW-offline-perception-tier.md) | — (unbuilt; see §A) | P2's background-execution verdict for the ASR tier — confirm on device that it does not share the local-model foreground-only constraint before claiming it | A backgrounded phone |
| [DY](DY-my-day-everyday-briefing.md) | P0–P4 implemented, suite green | Calendar/Reminders denial and regrant recovery; a live DST boundary; MapKit route failure and offline weather; locked-phone scheduled delivery; snapshot latency and spoken duration on the oldest supported iPhone; VoiceOver and largest Dynamic Type walkthroughs | A phone across a day |
| [DZ](DZ-local-gguf-and-durable-agent-runtime.md) | PR1–PR5 (runtime seam, GGUF load/generate, catalog, manager UI) — structural proof only | The PR3–PR5 device matrix: load a real GGUF, run a Metal/CPU graph, generate on hardware. Gates PR8's multimodal adapter | A phone with a downloaded model |
| [EB](EB-action-reach-and-conversation-continuity.md) | P1–P3 + the 09-02 resumed-thread fix | The panel header at accessibility text sizes; an Action-Button-bound grid action end to end | A phone with the Action Button |
| [EE](EE-field-assist-commercial-licensing.md) | P1–P4 (tiers, entitlement, paywall) | A device paywall and purchase-flow pass | A phone with sandbox products |
| [EN](EN-memory-distillation-and-external-graph-memory.md) | P1–P3 (distiller, ontology, enrichment policy/parser, catalog row) | The schema migration has only run against test-built databases, never a device's real `brain.sqlite` | A phone with an established brain |
| [M](M-webrtc-infra-and-audio.md) | App-side WebRTC + audio coordinator | `RTCAudioSession` echo behaviour and session-wedge testing | Glasses + a live call |
| [BP](BP-web-hud-mirror.md) | P1+P2 (payload, renderer, mirror server) | P3 — LAN HTTP reachability from phone to the glasses web view, falling back to tailnet HTTPS; P4 — Developer-Mode URL registration and QR enrolment, 600×600 legibility, D-pad feel, poll cadence vs battery, web-view lifecycle | Display glasses + a LAN |
| [BA](BA-android-port.md) | — (roadmap; see §A) | Phase 0's confirmation on a test handset: Display-module availability and the permission gate | An Android handset + glasses |

## C. Backend / service-pending (gateway · relay · store products · external API)

**Refreshed 2026-09-08.** Most of this table is still one acceptance list — read it as
[CR](CR-cloud-action-agent-gateway.md)'s and [EH](EH-openclaw-2-0-wire-alignment.md) P4's, not as
independent blockages: we have a complete, now 2.0-aligned gateway *client* and no gateway. The rest
is store products, a CI container, and two hosted services that have plans of their own.

| Plan | Shipped core | Live edge remaining | Unblocked by |
|---|---|---|---|
| [EH](EH-openclaw-2-0-wire-alignment.md) | P1 — the 2.0 wire (`GatewayWire`, request catalog, run tracker, schema-pin tests) | **P4 — a 2.0 gateway container in CI.** This is the acceptance harness for every row below it | A runnable gateway image |
| [N](N-remote-agent-harness.md) | Harnesses + registry + tools + Codex/Claude preset adapters | Gateway `agent.*` and its live event stream; **Phase 0 live verification** of the Codex-cloud and Claude-remote trigger contracts against the real endpoints | Gateway `agent.*`; the real provider endpoints |
| [AR](gateway-device-pairing.md) | `SetupCode`/`GatewayAuthSelector`/`PairingResponseInterpreter` | The live approval round trip (bootstrap → approve → per-device token). The client-half fixes moved to §A | A gateway implementing the v3 handshake (shared-token today) |
| [BH](BH-gateway-remote-invoke.md) | Parser/policy/executor + audited service, per-class toggles, activity log, origin-aware policy (BN P2) | Live end-to-end round trip against a real gateway | A gateway that sends `node.invoke`-style frames |
| [CN](CN-agent-vision-attachment.md) | Attachment policy + phrasing, on the gateway's `attachments` list | Does a real 2.0 gateway accept the frame within its advertised `maxImageBytes`? Higher stakes now the setting defaults **on** | EH P4 |
| [CR](CR-cloud-action-agent-gateway.md) | — (unbuilt; see §A) | P3/P4 as running artefacts: standing the managed-agents backend up, and the OAuth → vault connected-apps path | Someone to run it |
| [CS](CS-standalone-watch-client.md) | — (unbuilt; see §A) | P2's direct HTTPS transport has no target until CR's cloud gateway kind exists — CS cannot finish past P1 without it | CR |
| [CT](CT-org-configuration-profiles.md) | — (unbuilt; see §A) | The hosted-profile endpoint (P2) and the partner issuance service, now delegated to EI; P3's watch propagation rides CS P2's application-context channel | EI, then CS/CR |
| [EI](EI-licence-issuance-portal.md) | — (unbuilt; see §A) | P2 — the hosted issuance service plus its isolated signing step | Somewhere to host it |
| [BL](BL-ops-platform-agent-bridge.md) | — (unbuilt; see §A) | A real conforming peer: A2A `tasks.send`/`tasks.get`, an MCP server, a `glasses`-topic SSE stream with `Last-Event-ID` replay, and `submitReply`. The plan is explicit this is a contract, not something this repo builds | A peer implementation |
| [EM](EM-work-record-and-parts.md) | P1+P2 (work record, parts request, delivery, endpoint sink) | P3's hand-off needs BL's peer | BL |
| [BP](BP-web-hud-mirror.md) | P1+P2 | P3's third fallback — a cloud relay through the ops-platform bridge — only if LAN and tailnet both fail | BL |
| [AK](standalone-chat-experience.md) | Chat tab + rich rendering + real SSE streaming, hardened in BM P9 | **Live-credential smoke only** | Real API keys on a device |
| [EN](EN-memory-distillation-and-external-graph-memory.md) | P1–P3 headless (distiller, ontology, enrichment policy/parser, catalog row) | P2's model-assisted enrichment call has never run against a real provider; P3's catalog entry has never connected to a self-hosted graph-memory MCP server — it decodes, resolves and installs in tests only | A provider key; a self-hosted server |
| [EE](EE-field-assist-commercial-licensing.md) | P1–P4 | App Store Connect product setup — the subscription and the one-time product | App Store Connect |
| [EG](EG-vault-packs.md) | P1+P2 (manifest, signature reuse, registry) | The vendor signs `vaultpacks/catalog.json` with the off-repo private key; per-pack App Store Connect products | The signing key holder; App Store Connect |
| [CD](CD-fork-surfaced-remediation.md) | P1–P3 | Enabling tests in the Xcode Cloud workflow — App Store Connect configuration, not code. The GitHub Actions gate does not satisfy this | App Store Connect |
| [DP](DP-release-entitlement-boundary.md) | P0+P1 | P3.1 — a CI Release-archive check that fails the build if the legacy defaults key, the "Developer unlock" string, the internal entitlement case, or an internal-only route survives into the artifact | A CI archive step |
| [CQ](CQ-third-party-glasses-backends.md) | P0 + P1 + B/P4 | P6's Hotspot Configuration entitlement — a new App ID capability, which historically breaks the Xcode Cloud archive on signing until registered | Apple developer portal |
| [BS](BS-transcript-guard-and-broadcast-breadth.md) | P1–P3 | One real stream per preset — needs an actual ingest endpoint, not just hardware | A YouTube/Twitch/Kick ingest |
| [L](L-webrtc-expert-transport.md) · [M](M-webrtc-infra-and-audio.md) | App-side WebRTC + audio coordinator; M1/M2 reference impls | Deploy the signaling relay and TURN (**on-demand only** — the meeting-link path covers remote today, and room-token auth is the real gate, in §A); host the expert web client | A self-host or compliance customer |
| [AI](provider-auth-and-fallbacks.md) | Custom-provider path covers these today | Azure Entra OAuth and Bedrock SigV4 as first-class provider auth | The respective clouds |
| [BA](BA-android-port.md) | — (roadmap) | Play Store review and policy prep, flagged for Phase 0/1 | A Play Console account |

---

## D. Device-pending edges tracked in README prose only (pointer)

Two shipped plans still carry a live edge that has no row above because no verdict itemised it:
**BD** long-session realtime soak and **BI** uncertainty-phrase-list tuning. BG's on-glasses voice-path
smoke, once listed here, now has its own row in §B. Listed so the pickup queue is complete.

---

## E. Decisions owed

Nothing else in the repo collects these. Each waits on an owner call, not on code or hardware.

- [AL](on-device-image-generation.md) — which runtime: a Core ML diffusion port, MLX diffusion, or the iOS 26 image creator. Everything else waits on this.
- [AP](audio-session-resilience-p2.md) — should the phone-speaker fallback be surfaced to HUD/TTS rather than logged, and how aggressive should reset be?
- [AS](audio-session-lease-coordinator.md) — does the coordinator enforce precedence, or stay advisory with a preemption callback?
- [AQ](speaker-diarization.md) — nova-3 or a meeting-tuned model as the diarization default.
- [AF](siri-and-local-server.md) — whether tailnet-peer probing belongs here or in the ops bridge.
- [AW](skill-self-evolution.md) — which model analyses failure batches, and whether edits apply on approval.
- [AX](memory-taxonomy.md) — unify `SemanticMemoryStore` and `BrainStore`, or keep two fact stores; archive-vs-delete for project lifecycle.
- [AI](provider-auth-and-fallbacks.md) — whether Vertex streaming is worth its own path.
- [BA](BA-android-port.md) — one repo or an `/android` directory; minimum SDK; on-device engine; whether to staff it at all.
- [BL](BL-ops-platform-agent-bridge.md) — transport preference when both A2A and MCP could serve a request (proposal: MCP sync, A2A long-running).
- [BP](BP-web-hud-mirror.md) — does the glasses web view support SSE/WebSocket, or is polling the ceiling? Answerable only at hardware contact, but the answer changes P5's shape.
- [BR](BR-realtime-and-stream-hardening.md) — when to take the Gemini 3.1 Live migration; the rider is a checklist for that day, not a task now.
- [CK](CK-sign-language.md) — whether to fund a larger model on a GPU run for a better CER/size trade.
- [CO](CO-identity-budget-turn-taking.md) — does the identity-ambiguity outcome belong in the tool surface as well as auto-announce?
- [CP](CP-outbound-frame-privacy.md) — stricter per-frame detection for recordings than for streams? Under thermal pressure, widen the interval silently or say so? Both gated on the P3 numbers.
- [CQ](CQ-third-party-glasses-backends.md) — ship Track A user-visible or developer-panel-only while the vendor SDK is beta; the camera/mic exclusivity policy.
- [CR](CR-cloud-action-agent-gateway.md) — server-side memory store versus `BrainStore`/AX/AY, which must be stated before P3; ledger expiry visible or a silent retry; whether the cloud kind ever deprecates `sessions.send`.
- [CS](CS-standalone-watch-client.md) — do direct turns reconcile into the phone's `ConversationStore` on reconnect (leaning yes, append-only)? Persona on the direct path?
- [CT](CT-org-configuration-profiles.md) — how much of `Config` is org-settable, per setting; does an expired profile revert or freeze; the P4 credential model (per-user login vs shared enrolment secret); tier pricing. The doc also answers "may a profile pin HIPAA mode" affirmatively in one section while still listing it open in another.
- [CU](CU-voice-turn-latency.md) — replace `noSpeechTimeout` with VAD outright; whether `OnDeviceASREngine` becomes the detector's second consumer; ring size and whether debug export is Debug-only.
- [CV](CV-continuous-scene-narration.md) — does narration write `.distinct` descriptions to `BrainStore` as ambient memory? A separate HUD-mirror toggle?
- [CW](CW-realtime-audio-rig-recovery.md) — should `.newDeviceAvailable` still map to `.resetGraph` (needs the P4 ratio first)? Should a bounded rebuild count surface a real error to the wearer?
- [CX](CX-live-session-vision-choice.md) — is the vision preference per persona/project or global? Can a voice session upgrade to vision mid-session without a restart?
- [CY](CY-broadcast-resilience-and-quality.md) — what retry affordance follows a give-up while the glasses are worn; is the 60-second stability window right?
- [DD](DD-onboarding-signin-and-refresh.md) — should the external-browser flow also attempt the loopback listener (leaning no)? Can Google/Vertex sign-in share the sheet and listener?
- [DW](DW-offline-perception-tier.md) — which locale-independent transducer model to vendor; the doc names properties, not a model.
- [DX](DX-private-memory-timeline.md) — P2 is gated on DK reaching `.ready`; confirm DK's state before starting it.
- [DZ](DZ-local-gguf-and-durable-agent-runtime.md) — PR4 shipped without the JSON catalog size/digest/revision entries and curated licence text it named; confirm whether those are tracked elsewhere or were dropped.
- [EE](EE-field-assist-commercial-licensing.md) — does the one-time purchase stay on sale once the subscription exists, at the same price? Per-storefront pricing? Should a pilot code block PDF export?
- [ED](ED-vault-manual-retrieval.md) · [EF](EF-scanned-manual-import.md) — a per-vault `language` manifest field for Vision's per-language recognizer, deferred until the first non-English vault.
- [EG](EG-vault-packs.md) — redistribution terms for OEM-extracted text in a manufacturer-authored pack; one-time or subscription per pack; catalog placement.
- [EI](EI-licence-issuance-portal.md) — how to rehearse partner onboarding safely: one production verifying key is embedded and there is no sandbox path.
- [L](L-webrtc-expert-transport.md) · [M](M-webrtc-infra-and-audio.md) — whether to deploy the relay at all before a customer asks.

---

## How to use this

- **Want to ship something today?** Pick from **A1** first — those are live defects and gaps, not
  features. Then A2, which is ordinary phase work.
- **Bucket B/C rows are not code debt** — they're the validation/integration checklist for when the
  hardware or backend exists. The three grouped B rows are one sitting each and would close about
  half that table.
- **Bucket E is cheap** — most of those unblock an A row for the price of a sentence.
- When an item is done, update its originating plan doc's status and remove its row here.
