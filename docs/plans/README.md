# OpenGlasses Feature Plans

Six plans drafted from a survey of the community smart-glasses landscape, plus a B2B field-service direction informed by IT and refrigeration commercial opportunities. Extended in later rounds (G–M) with features unlocked by the shipped engines.

## Status (as of latest)

All plans A–M are **built and merged to `main`** to the extent verifiable without device hardware or external infrastructure. **148 feature tests passing.**

| Plan | Status |
|---|---|
| A1/A2/A3 Accessibility | ✅ Shipped (OCR reading tool, urgency TTS, scene/social assistive modes + HUD toggle) |
| B Personal Health Vault | ✅ Shipped (templates, tool, editor) |
| C Live Coach | ✅ Shipped (per-domain loop, dedup) |
| D Utilities | ✅ Shipped (OneEuroFilter, aircraft_overhead) |
| E MCP Server | ✅ Shipped (dev-only HTTP server) |
| F Field Assist | ✅ Phases 1–3 shipped (vault, procedures, domain calc, audit/PDF export, escalation) |
| G IT/Network pack | ✅ Shipped (vault, 5 procedures, subnet calc) |
| H Custom vault import | ✅ Shipped (validator, importer, manager UI) |
| I Medication Identifier | ✅ Shipped (OCR × Health Vault) |
| J Navigation Assist | ✅ Shipped (hazard loop, frame-quality gate) |
| K Integration & polish | ✅ K1 HUD + transcription, K2 expert bridge + real notifier; K3 (CarPlay heading) is a documented no-op (no heading consumer) |
| L WebRTC transport | ✅ App-side shipped (real RTCPeerConnection, MJPEG/WebRTC selectable). Needs external signaling + TURN to connect. |
| M WebRTC infra + audio | ✅ M3 audio coordinator shipped; M1 signaling server + M2 expert client shipped as reference impls (`docs/webrtc/`). Remaining: deploy infra + on-device echo/precedence testing. |
| Meeting-link connector | ✅ Shipped — zero-infra `meeting_link` transport opens/pages an external Zoom/Teams/Meet/Whereby URL; nothing to self-host. Recommended remote path. |
| O Document RAG | ✅ Shipped (on-device chunking, embedding, retrieval — chat with your files) |
| P Page & section citations | ✅ Shipped (per-page/section citations for Document RAG) |
| Q Vault & skills-library management | ✅ Shipped (in-app reference editing, vault export round-trip, ClawHub/voice skills export-import) |

Three selectable expert-stream transports: **MJPEG** (same-LAN browser viewer), **Meeting link** (zero-infra — your meeting tool hosts the call; recommended for remote), and **WebRTC** (self-hosted peer-to-peer, needs your own signaling + TURN).

**Genuinely outstanding (cannot be done/tested without hardware or hosting):** for the self-hosted WebRTC path only — deploy the signaling relay + TURN server, host the expert web client, and run on-device echo/precedence + audio-session testing. The Meeting-link transport needs none of this.

---

| Plan | Title | Effort | Strategic fit |
|---|---|---|---|
| [A](A-accessibility-tier.md) | Accessibility Tier (new IAP) | ~3-5 days | New paid track parallel to Medical Compliance |
| [B](B-personal-health-vault.md) | Personal Health Vault | ~1-2 days | Extends Medical Compliance IAP — first applied vault |
| [C](C-live-coach-tool.md) | Live Coach Tool | ~1-2 days | Generic utility — reuses CameraService |
| [D](D-small-utilities-bundle.md) | Small Utilities Bundle | ~1 day | OneEuroFilter + aircraft_overhead + (deferred) DPad |
| [E](E-mcp-server-mode.md) | Claude Code MCP Server Mode | ~2 days | Developer-only (gated behind `agentModeEnabled`) |
| [F](F-field-assist.md) | **Field Assist (B2B)** | ~3 weeks foundation + 1 week per pack | New B2B revenue line — refrigeration, IT, electrical, automotive |

## Round 2 — features unlocked by the shipped engines

A–F are built (A1–A3, B, C, D, E, and Field Assist Phases 1–3). These reuse the now-shipped building blocks — VaultStore + ProcedureRunner, `LLMService.analyzeFrame`, the Assistive ambient loop, `OCRService`, `SessionExporter`, the `ExpertBridge` seam, `OneEuroFilter` — so each is mostly content or wiring, not new infrastructure.

| Plan | Title | Effort | Reuses | Strategic fit |
|---|---|---|---|---|
| [G](G-it-network-pack.md) | IT / Network Field Assist Pack | ~1 week | F engine | 2nd B2B vertical; proves multi-pack thesis |
| [H](H-custom-vault-import.md) | Custom / Enterprise Vault Import | ~3-4 days | VaultStore overlay + ProcedureLibrary | Enterprise tier — bring-your-own pack |
| [I](I-medication-identifier.md) | Medication Identifier | ~1-2 days | A1 OCRService + B Health Vault | Consumer cross-feature; reinforces Medical Compliance |
| [J](J-low-vision-navigation.md) | Low-Vision Navigation Assist | ~2-3 days | A3 loop + analyzeFrame + SpeechUrgency | Highest-impact Accessibility use case |
| [K](K-integration-polish.md) | Integration & Polish (A3 HUD, F Phase 5 expert, CarPlay smoothing) | ~half day–1 week | A3, ExpertBridge+WebRTC, OneEuroFilter | Finish/wire shipped capabilities |
| [L](L-webrtc-expert-transport.md) | Real WebRTC Expert Transport (two-way A/V) | ~1.5–2 weeks | Plan K transport seam | Genuine remote-expert collaboration — Field Assist Pro |
| [M](M-webrtc-infra-and-audio.md) | WebRTC signaling relay + expert web client + audio-session coordination | ~3–5 days | Plan L app side | Completes the live WebRTC call loop |

## Round 3 — agent control

| Plan | Title | Effort | Reuses | Strategic fit |
|---|---|---|---|---|
| [N](N-remote-agent-harness.md) | Remote Agent Harness (phone-only, harness-agnostic) | ~3–4 days core + ~1–2/adapter | OpenClawBridge + OpenClawEventClient, `agentModeEnabled`, LLMProvider pattern, MeetingSummaryTool | Glasses as a hands-free remote for any coding/agent backend (OpenClaw / Codex / Claude / custom). 📋 Planned |

## Round 4 — on-device knowledge

| Plan | Title | Effort | Reuses | Strategic fit |
|---|---|---|---|---|
| [O](O-document-rag.md) | Document RAG (chat with your files) | ~3–4 days | SemanticMemoryStore (sqlite + NLEmbedding + cosine), OCRService (A1) | Persistent, retrievable chunked document knowledge — load a manual/PDF and ask about it across sessions. ✅ Shipped |
| [P](P-chunk-citations.md) | Page & section citations for Document RAG | ~0.5 day | Document RAG (O), chunk metadata | Cite the exact page/section behind a RAG answer, not just the file. ✅ Shipped |
| [Q](Q-vault-and-skills-library-management.md) | Vault & skills-library management (edit, export, import) | ~1–1.5 days | VaultStore/VaultImporter, InstalledSkillStore, VoiceSkillStore | Edit vault references in-app; export/import vaults and both skills libraries between devices. ✅ Shipped |

## Dependency graph

```
Plan F (Phase 1: VaultStore foundation)
   │
   ├──> Plan B (Health Vault — first applied vault)
   │
   ├──> Plan F (Refrigeration pack — first vertical)
   │
   └──> Plan F (additional vertical packs)
```

Plans A, C, D, E are independent and can ship in any order.

## Suggested sequence

1. **D** (1 day) — Low-risk warmup, ships utilities
2. **A2** (half day, inside Plan A) — Urgency TTS, universal upgrade
3. **A1** (1-2 days) — Reading Accessibility Tool
4. **F Phase 1** (1 week) — Generic VaultStore foundation
5. **B** (1-2 days) — Health Vault rides on F Phase 1
6. **F Phase 2** (1.5 weeks) — Refrigeration pack MVP
7. **A3** (1-2 days) — Assistive Modes, closes out Accessibility IAP
8. **F Phase 3** (0.5 weeks) — Escalation architecture stub
9. **F Phase 4** (1 week) — IT pack
10. **C** (1-2 days) — Live Coach
11. **E** (2 days) — MCP Server (dev-only)
12. **F Phase 5** (TBD) — Expert escalation goes live

## Revenue impact, rough

| Plan | Revenue model | Order of magnitude |
|---|---|---|
| A | Accessibility IAP (consumer) | $-$$ |
| B | Bundled with existing Medical Compliance | (uplift only) |
| C | Free | — |
| D | Free | — |
| E | Free (dev-only) | — |
| **F** | **B2B subscription, per-seat** | **$$$-$$$$** |

Plan F is the single largest revenue opportunity. Even one signed refrigeration contractor (~20 techs × $200/mo) is ~$48k/yr in recurring revenue that doesn't require consumer marketing investment.

## Cross-cutting infrastructure

Generic `VaultStore` (built in Plan F Phase 1) is the shared foundation for all domain knowledge bases:

| Vault | Plan | Gating |
|---|---|---|
| `health` | B | Medical Compliance IAP |
| `refrigeration` | F MVP | Field Assist – Refrigeration IAP |
| `it_network` | F v1.1 | Field Assist – IT IAP |
| `electrical` | F v2 | Field Assist – Electrical IAP |
| `automotive` | F v2 | Field Assist – Auto IAP |
| `custom` | F v2 | Enterprise tier |
