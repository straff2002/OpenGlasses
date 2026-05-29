# OpenGlasses Feature Plans

Six plans drafted from a survey of ~19 community Meta Ray-Ban / smart-glasses projects on GitHub, plus a B2B field-service direction informed by IT and refrigeration commercial opportunities.

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

## Source repos surveyed

**High-value sources:**
- [soma-hud](https://github.com/CarlKho-Minerva/soma-hud) → Plan B (health vault, source attribution) + Plan F (vault pattern)
- [neurobridge](https://github.com/AspectParadox-dev/neurobridge) → Plan A2 + A3 (urgency TTS, scene/social modes)
- [brain](https://github.com/christineortiz1125-cell/brain) → Plan A1 (reading accessibility modes)
- [sidelineiq](https://github.com/prasanthsasikumar/sidelineiq) → Plan C (live coach pattern)
- [SkyRadar](https://github.com/Trickdog/SkyRadar) → Plan D (OneEuroFilter, aircraft tracking)
- [glasses-context](https://github.com/scottconnolly-byte/glasses-context) → Plan E (MCP server)

**Plan F informed by enterprise patterns:**
TeamViewer Frontline, Microsoft Dynamics 365 Remote Assist, Vuzix Remote Assist, Librestream Onsight, Augmentir.

**Surveyed but not adopted:**
- glassbridge, MetaOakleyVerse, Grock-Glasses — duplicate existing functionality
- hand-wave — sign language ML, too heavy to integrate now
- nano-sight — Quest 3 only
- ar-glasses-master-sdk — reference catalog
- shopping list — D-pad UI deferred until Display glasses
- vanguard-glasses, vison-claw — empty repos

**Flagged as ethically problematic:**
- [JARVIS](https://github.com/affaan-m/JARVIS) — stranger-OSINT via PimEyes, no consent model. Avoid this pattern.
- SignalSight — body-language analysis of others without consent. Skip.

**Notable peer project:**
- [VisionClaw](https://github.com/Intent-Lab/VisionClaw) — academic research project (Liu, Lee, Gonzalez, Gonzalez-Franco, Suzuki). Same stack as OpenGlasses (DAT SDK + Gemini Live + OpenClaw). Validates architecture choice. Worth finding the associated paper.
