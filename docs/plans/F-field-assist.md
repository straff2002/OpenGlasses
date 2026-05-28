# Plan F — Field Assist (B2B / Enterprise)

**Source pattern:** TeamViewer Frontline, Dynamics 365 Remote Assist, Vuzix Remote Assist, Librestream Onsight, Augmentir. Mature enterprise smart-glasses category.

**Strategic fit:** Likely the highest-revenue feature in OpenGlasses. Hands-free, AI-grounded field service for technicians (refrigeration, IT, electrical, automotive). B2B subscription model. Establishes OpenGlasses in the enterprise market alongside consumer use cases.

**Target customers (hypothetical but real commercial opportunities):** Refrigeration / HVAC service companies, IT MSPs, electrical contractors, automotive service centers.

**Effort:** Foundation + Refrigeration pack: ~3 weeks. Subsequent packs: ~1 week each.

---

## Product shape

Two **selectable session modes**, with mid-session escalation supported:

| Mode | Description | MVP? |
|---|---|---|
| **AI-Only** | AI is the remote expert. Grounded by vault + procedure library. Audit-logged. | ✅ Yes |
| **Human+AI** | Live human expert via WebRTC, AI assists with transcription, knowledge lookup, post-call summary. | Architecture only — defer build to v2 |

Escalation flow: technician says *"I need a human"* → `EscalateToExpertTool` → notifies expert pool → expert joins via WebRTC → AI stays in loop for support.

---

## Architecture

### Generic `VaultStore` (shared foundation, also used by [Plan B](B-personal-health-vault.md))

```
Sources/Services/Vault/
├── VaultStore.swift          // File I/O for any vault directory
├── VaultLoader.swift         // Loads vault → system-prompt addendum
├── VaultRegistry.swift       // Lists available vaults + their gating
├── VaultManifest.swift       // Vault metadata struct
└── VaultPromptBuilder.swift  // Composes system-prompt rules + content
```

A **vault** is a directory of markdown files + a `manifest.json`:

```json
{
  "id": "refrigeration",
  "name": "Refrigeration Service",
  "version": "1.0.0",
  "files": ["error_codes.md", "pt_charts.md", "epa_608.md", "..."],
  "procedures_dir": "procedures/",
  "gating": { "iap": "field_assist_refrigeration" },
  "prompt_rules": [
    "Never fabricate equipment data or procedures.",
    "Use only the vault contents and the technician's observations.",
    "Cite source files on every factual claim.",
    "If unsure, recommend escalation rather than guess."
  ],
  "source_attribution_format": "Source: {files}"
}
```

Vaults ship as part of vertical packs:

| Vault | Plan | Gating |
|---|---|---|
| `health` | Plan B | Medical Compliance IAP |
| `refrigeration` | Plan F MVP | Field Assist – Refrigeration IAP |
| `it_network` | Plan F v1.1 | Field Assist – IT IAP |
| `electrical` | Plan F v2 | Field Assist – Electrical IAP |
| `automotive` | Plan F v2 | Field Assist – Auto IAP |
| `custom` | Plan F v2 | Enterprise tier (customer-uploaded) |

### Field Assist core

```
Sources/Services/FieldAssist/
├── FieldSessionService.swift   // Session lifecycle (start/pause/resume/end)
├── FieldSession.swift          // Session model: id, vault, asset, transcript, photos, work order
├── SessionLogger.swift         // Append-only audit log; structured JSON + photo capture
├── ProcedureRunner.swift       // Step-by-step procedure execution + progress tracking
├── ProcedureLibrary.swift      // Loads procedure definitions from vault/procedures/*.json
├── EscalationCoordinator.swift // AI → human expert handoff state machine
├── ExpertBridge.swift          // WebRTC connection to remote expert (reuses WebRTCStreamingService)
└── ExpertNotificationService.swift // Push/email/Slack notify expert pool on escalation
```

### Native tools

```
Sources/Services/NativeTools/
├── FieldSessionTool.swift           // start_session, pause, resume, end, status
├── ProcedureRunnerTool.swift        // start_procedure, next_step, previous_step, repeat_step, complete
├── EscalateToExpertTool.swift       // escalate, request_expert
├── EquipmentLookupTool.swift        // OCR a label → look up in vault → return manual section
├── DomainCalcTool.swift             // Per-pack math (PT charts, subnet math, etc.)
└── PhotoLogTool.swift               // Attach photo to session log with caption
```

---

## Session flow (AI-Only MVP)

```
1. User (voice): "Start refrigeration service session for unit 47B"
2. → FieldSessionTool.start(vault="refrigeration", asset_id="47B", mode="ai_only")
3. System loads refrigeration vault into LLM system prompt
4. SessionLogger begins append-only log; auto-records timestamp + GPS
5. User: "I see error code E5 on the display"
6. → EquipmentLookupTool grounds via vault → "E5 = low-pressure fault, Carrier 30RB series"
7. AI: "Possible low-pressure fault. Let's check suction-side pressure first. Should I run the diagnostic procedure?"
8. User: "Yes"
9. → ProcedureRunnerTool.start_procedure(id="low_pressure_diagnostic")
10. AI: "Step 1 of 6: Verify the unit is calling for cooling. Look at the thermostat — what's the setpoint vs current?"
11. ... PhotoLogTool captures gauge readings at each step ...
12. User: "This doesn't match the manual's flowchart, escalate"
13. → EscalateToExpertTool → ExpertBridge wakes WebRTC session, notifies expert
14. Expert joins; AI continues to log + retrieve manual sections on demand
15. Session ends → SessionLogger emits JSON audit + optional PDF (for warranty / EPA 608 / customer record)
```

---

## Per-vertical packs

### Refrigeration pack (MVP — ship first)

**Why first:** Highest revenue per seat ($150-300/mo norms), regulatory lock-in (EPA Section 608), fewer competitors than IT, and operating expense pressure on contractors drives adoption.

**Vault contents:**
- `manufacturers.md` — Carrier, Trane, Daikin, Lennox, Mitsubishi specifics
- `error_codes.md` — by manufacturer × model × code
- `pt_charts.md` — pressure/temperature for R-410A, R-32, R-454B, R-22 (legacy)
- `epa_608.md` — recovery, recycling, leak reporting requirements
- `safety.md` — refrigerant handling, electrical LOTO, PPE
- `superheat_subcool.md` — measurement procedures + interpretation
- `tools_catalog.md` — common tools, gauge manifolds, recovery machines

**Procedures (`procedures/*.json`):**
- `low_pressure_diagnostic.json`
- `high_pressure_diagnostic.json`
- `leak_check_procedure.json`
- `refrigerant_recovery.json`
- `system_startup_checklist.json`
- `superheat_subcool_measurement.json`
- `compressor_replacement.json`

**Domain calc tool (`DomainCalcTool` for refrigeration):**
- PT chart lookup: `pt_lookup(refrigerant, pressure_psig) → saturation_temp_F`
- Superheat: `superheat(suction_pressure, suction_temp, refrigerant) → degrees`
- Subcool: `subcool(liquid_pressure, liquid_temp, refrigerant) → degrees`
- Target charge by mass / weigh-in for system size
- CFM and tonnage calculations

**Safety prompts (auto-injected at session start):**
- "Confirm proper PPE before opening any panel."
- "Refrigerant recovery required before opening refrigerant circuit (EPA 608)."
- "LOTO required on all electrical sources before service."

### IT/Network pack (v1.1)

**Vault contents:**
- Network topology templates
- Server/switch inventory schema
- Runbooks per common issue class
- Error code DB (Cisco, Aruba, Dell iDRAC, HPE iLO, etc.)
- Cable identification guide (color, label conventions)

**Procedures:**
- Server replacement (cold swap, hot swap)
- Network troubleshooting (link down, packet loss, slow link)
- Cable trace
- Firmware update

**Domain calc tool (IT):**
- Subnet math (CIDR → range, broadcast, usable hosts)
- VLAN ID lookup
- Port-to-cable-label translation
- Cable run length calculation

### Electrical pack (v2)

NEC code section lookup, GFCI/AFCI test procedures, panel inspection checklist, voltage drop calc, arc flash boundary calc, LOTO procedure.

### Automotive pack (v2)

OBD-II code DB, repair procedures by VIN, torque spec lookup, fluid capacity DB, recall lookup.

### Custom pack (Enterprise tier, v2)

Customer uploads their own vault + procedures. Useful for in-house engineering teams, specialized equipment manufacturers, or vertical we haven't shipped a pack for.

---

## Audit & compliance

Every session emits a structured log:

```json
{
  "session_id": "uuid",
  "started_at": "ISO",
  "ended_at": "ISO",
  "vault": "refrigeration",
  "asset_id": "47B",
  "technician_id": "user_uuid",
  "location": { "lat": ..., "lon": ..., "address": "..." },
  "mode": "ai_only" | "human_assisted",
  "expert_id": "uuid?" ,
  "transcript": [...],
  "photos": [{ "ts": "ISO", "path": "...", "caption": "..." }],
  "procedures_run": [{ "id": "...", "steps_completed": 5, "outcome": "..." }],
  "ai_citations": [{ "claim": "...", "source": "error_codes.md" }],
  "escalations": [{ "ts": "ISO", "reason": "..." }],
  "outcome": "resolved" | "escalated" | "deferred",
  "billable_minutes": 47
}
```

PDF export available for:
- EPA 608 refrigerant recovery logs
- Customer work orders
- Warranty submission packages

---

## Pricing model

Subscription, B2B, per-seat. Three tiers — names TBD:

| Tier | Includes | Indicative pricing |
|---|---|---|
| **Field Assist Base** | One vertical pack, AI-only, basic audit log | ~$X/seat/month |
| **Field Assist Pro** | Multi-pack, expert escalation, PDF export, SSO | ~$Y/seat/month |
| **Field Assist Enterprise** | Custom vaults, white-label, on-prem audit log retention, SLA | Contract |

(Pricing is your call — flagging the model, not numbers.)

---

## Build order

### Phase 1: Foundation (~1 week)
1. Generic `VaultStore` + `VaultLoader` + `VaultRegistry`
2. `FieldSessionService` + `SessionLogger` (no procedures yet — just free-form Q&A with vault grounding)
3. Settings UI for IAP gating, vault selection, mode picker (AI-only vs Human+AI)

### Phase 2: Refrigeration MVP (~1.5 weeks)
4. Ship refrigeration vault (markdown files + manifest)
5. `ProcedureRunner` + `ProcedureLibrary` + 3 hero procedures (low-pressure diag, leak check, startup)
6. `EquipmentLookupTool` (uses Plan A1's OCR for label reading)
7. `DomainCalcTool` for refrigeration math
8. `PhotoLogTool`
9. `FieldSessionTool` + `ProcedureRunnerTool` native tool registrations
10. Audit log JSON output + basic PDF export

### Phase 3: Escalation architecture (no live build) (~0.5 weeks)
11. `EscalationCoordinator` state machine + `EscalateToExpertTool` stub
12. `ExpertBridge` interface defined (implementation deferred)
13. Document expert-side protocol for v2

### Phase 4: IT pack (v1.1, ~1 week)
14. IT vault + procedures + domain calc tool

### Phase 5: Expert escalation goes live (v2)
15. Build out `ExpertBridge` over `WebRTCStreamingService`
16. Expert-side web client (or use existing WebRTC viewer)
17. Expert notification service (push/Slack/email integrations)

---

## Open questions

- **Audit log retention:** Local-only, or cloud sync for multi-device / multi-technician scenarios? *Recommendation: local-only in MVP, opt-in cloud sync in Pro tier.*
- **Photo storage:** Inline in JSON (base64) or external (file paths + sidecar)? *Recommendation: external paths, sidecar archive for export.*
- **Offline mode:** Vault is on-device, but LLM requires connectivity. Should sessions queue Q&A for retry, or hard-fail offline? *Recommendation: queue with explicit "offline mode active" indicator; flush on reconnect.*
- **Pack distribution:** Bundled in app, downloaded post-purchase, or both? *Recommendation: download post-purchase to avoid app-size bloat; cache locally.*
- **Vault versioning:** How are vault updates rolled out — auto, with user approval, or manual? Need to handle in-progress sessions on update. *Recommendation: auto-pull on session start, never mid-session.*
- **Expert pool:** Customer-managed expert roster, or marketplace of OpenGlasses-vetted experts? *Recommendation: customer-managed in MVP; marketplace optional later.*
- **Compliance attestation:** Refrigeration vault touches EPA 608 — do we need any attestation/certification on its content? *Action: legal review before shipping refrigeration pack.*
- **Multi-language:** Refrigeration contractors often have Spanish-speaking field crews. Vault content i18n strategy? *Recommendation: separate vault per language; English MVP, Spanish as fast follow.*

---

## Dependencies / prereqs

- **Plan A1 (OCR)** is a soft prereq for `EquipmentLookupTool`. Could ship without OCR by requiring user to read codes aloud, but OCR is the high-utility path.
- **Generic VaultStore** is the foundation — also unblocks Plan B.
- **WebRTCStreamingService** (existing) provides expert-side video — escalation reuses this.
- **agentModeEnabled** gating already exists; Field Assist is a separate IAP gate, not the agentic gate.

---

## Why this matters strategically

OpenGlasses today is positioned for consumers. Field Assist opens a wholly different revenue line:
- Higher ARPU (~10-50× consumer pricing)
- Stickier (operational dependency, audit-compliance lock-in)
- Multi-seat sales (one customer = N technicians)
- Lower acquisition cost (B2B sales motion, not consumer marketing)
- Validates the architecture on demanding real-world workloads

Even one signed refrigeration contractor (~20 techs × $200/mo) is a meaningful annual revenue line that doesn't require consumer marketing investment.
