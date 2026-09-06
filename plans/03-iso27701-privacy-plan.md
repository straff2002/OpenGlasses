# ISO/IEC 27701 privacy remediation plan

**Status:** Proposed; technical remediation checkpoints are in progress, with no organizational-control or certification assertion.
**Assessment date:** 2026-09-04.
**Baseline:** ISO/IEC 27701:2025, edition 2, a standalone privacy information management system (PIMS). The 2019 edition's extension model must not be reused as the current requirements map. ISO describes the current standard as applying to PII controllers and processors and confirms it can operate independently. See the [official standard record](https://www.iso.org/standard/27701).
**Scope limitation:** Source review establishes implementation evidence, not operating effectiveness or legal applicability. Organizational policies, contracts, production configurations, processing locations, customer deployments, and audit records were not supplied. Exact requirement wording and Annex control identifiers must be checked against a licensed 2025 edition before preparing a certification control register. The clause 4–10 headings below organize management-system work; privacy controls are mapped by topic rather than invented Annex numbers.

## 1. Outcome and accountability

Establish a PIMS covering the organization responsible for OpenGlasses, its development and support operations, the distributed apps and extensions, and the actual services included in each commercial deployment. Include the device-to-provider data paths even when the developer does not receive those data.

The manifest describes a product without a developer backend or user account. That is relevant architecture evidence, but it does not decide whether the developer, an enterprise customer, an end user, a gateway operator, or an AI supplier is a controller or processor for a particular operation. Make those decisions per purpose and deployment. Do not describe every AI provider as a subprocessor automatically.

Proposed accountable roles:

| Role | Proposed responsibility |
|---|---|
| Executive sponsor | Approves PIMS scope, resources, privacy objectives, residual risk and management review actions. |
| Privacy lead | Maintains processing inventory, role determinations, notices, rights procedure, DPIAs, legal register and evidence. Assess whether a statutory DPO is required; do not infer that a title alone satisfies that obligation. |
| Security lead | Owns access controls, protection, incident handling, vulnerability and transport dependencies. |
| iOS engineering owner | Implements collection, consent, export, deletion and retention controls across all stores and capture paths. |
| AI/product owner | Defines intended uses, provider routing, sensitive-data restrictions, model changes and accessible disclosures. |
| Supplier/contract owner | Verifies agreements, onward use, subprocessors, locations, deletion assistance and change notifications. |
| Independent reviewer | Tests evidence, samples operating controls, reports findings and checks corrective-action closure. |

Assign named individuals before starting implementation. These roles are proposed assignments, not evidence that personnel or processes currently exist.

## 2. Evidence and data-flow inventory

This is a starting inventory; W01 must reconcile it against every persistence writer, network client, tool result, app extension and supported deployment. Repository paths and line numbers refer to the assessed checkout and will drift after changes.

| Processing activity | Data and affected people | Observed destinations or storage | Source evidence | Required inventory decisions |
|---|---|---|---|---|
| Assistant conversations and vision | Wearer prompts, speech, transcripts, images; incidental bystander and document data | Local conversations; selected cloud, custom or local LLM | `OpenGlasses/Sources/Services/LLMService.swift:7`, `:68`; `OpenGlasses/Sources/Services/ConversationStore.swift:95`; `OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy:46` | Purpose, lawful basis where applicable, recipient entity, geographic routes, account association, training/retention terms, age policy, local-only meaning. |
| Live audio and translation | Raw voices of wearer and nearby people, captions, speaker labels | Gemini, OpenAI realtime, optional Deepgram; local caption and recording surfaces | `OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeService.swift:113`; `OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift:315`; `OpenGlasses/Sources/App/Views/DiarizationSettingsView.swift:54`; `OpenGlasses/Sources/App/Views/TranslationSettingsView.swift:103` | Capture notice, participating/bystander rights, session stop, provider onward use, recording-law assessment, business versus personal use. |
| Recording, broadcast and expert calls | Video, ambient audio, potentially location or identifiable documents | Local recordings, RTMP recipients, browser WebRTC recipients, expert participants | `OpenGlasses/Sources/Services/PrivacyFilterService.swift:49`; `OpenGlasses/Sources/Services/Vision/OutboundFrameRelay.swift:65`; `OpenGlasses/Sources/App/Views/SettingsView.swift:943` | Visible/audible capture indicators, recipients, retention, authorization, capture restrictions, whether recipients independently retain copies. |
| Face enrollment and recognition | Names, face embeddings, enrollment/last-seen timestamps; observed persons | `Documents/known_faces.json`; recognized names spoken; face list returned as tool content | `OpenGlasses/Sources/Services/FaceRecognitionService.swift:14`, `:58`, `:109`, `:169`, `:333`; `OpenGlasses/Sources/Services/NativeTools/FaceRecognitionTool.swift:43` | Purpose, subject enrollment basis, permitted setting, biometric classification, deletion/expiry, incorrect-match remedy, no secondary identity or employment use without reassessment. |
| Personal memory and agent diary | Facts, preferences, inferred observations, relationships; potentially health and other sensitive data | SQLite memories and diary, legacy migrated JSON, configured OpenClaw gateway | `OpenGlasses/Sources/Services/SemanticMemoryStore.swift:422`, `:434`, `:465`, `:493`, `:703` | Explicit versus inferred memory, provenance, purpose changes, recipient synchronization, correction propagation, expiry, independent local/gateway deletion. |
| Apple Health and personal health vault | Workouts; conditions, medications, biometrics, laboratory notes | Apple Health APIs; local vault; health results returned to configured AI context | `OpenGlasses/Sources/Services/NativeTools/FitnessCoachingTool.swift:183`; `OpenGlasses/Sources/Services/NativeTools/HealthVaultTool.swift:42`, `:63`, `:86` | Separate collection and onward-sharing bases, sensitive-data restrictions, clinical roles, provider agreement requirements, whether health sharing is permitted for the route. |
| Contacts and location | Names, telephone numbers, email addresses, precise location and places | Native tools and resulting LLM context; location-dependent service recipients | `OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy:85`, `:123`; `OpenGlasses/Info.plist:145`, `:159` | Data minimization, bystander/contact transparency where applicable, precision and duration, purpose-specific permission, result redaction. |
| Portability and clinical exports | Conversation and memory contents, agent files, clinical output | Share-sheet recipients, temporary archives, protected medical export directories | `OpenGlasses/Sources/Services/AgentDataExporter.swift:21`; `OpenGlasses/Sources/Services/Export/ProtectedExportFileStore.swift:44` | Identity/authority verification, scope completeness, protection, pending-share lifecycle, downstream copies and recipient acknowledgment. |
| Diagnostics and SDK operations | Structured counts, durations, outcomes and pseudonymous identifiers; SDK registration/device traffic | In-memory diagnostic buffer and voluntary export; Meta registration paths with telemetry opt-out/blocking | `OpenGlasses/Sources/Services/Diagnostics/DiagnosticExportBuilder.swift:48`; `OpenGlasses/Info.plist:92`; `OpenGlasses/Sources/Services/Device/MetaTelemetryBlock.swift` | Actual packet-level behavior, support handling, identifier linkability, SDK changes, retention of any reports recipients receive. |

For each inventory record capture: accountable entity and role; data subjects; source; purposes; data categories and sensitivity; lawful basis and any additional condition; collection triggers; notice/consent versions; processors and other recipients; locations and transfers; access roles; retention trigger and period; deletion/export mechanism; backup behavior; linked risks and controls; technical owner; evidence date; and change-review date. Record uncertain fields explicitly.

## 3. Verified gaps and proposed engineering work

### PIM-01 — Preserve bystander filtering during background streaming

**Priority:** P0 for the affected streaming path. **Workstream:** W04, with W06 validation. **Owners:** iOS and privacy leads.

`OpenGlassesApp.optimizeForBackground()` runs when broadcast or WebRTC streaming is active and calls `privacyFilter.suspend()` at `OpenGlasses/Sources/App/OpenGlassesApp.swift:3146`–`:3163`. The relay then sends the original image at `OpenGlasses/Sources/Services/Vision/OutboundFrameRelay.swift:69`–`:71`. The direct filter likewise returns the input while suspended at `OpenGlasses/Sources/Services/PrivacyFilterService.swift:125`. The toggle's explanation promises filtering across these outbound paths at `OpenGlasses/Sources/App/Views/SettingsView.swift:947`. Filtering is opt-in, default false at `OpenGlasses/Sources/Utils/Config.swift:2639`; the defect concerns users who enabled it.

Proposed actions:

- Separate UI/background optimization from the egress privacy policy. When filtering is requested, continue a supported blur pipeline or withhold/pause the affected video with an accessible explanation.
- Treat detection/compositing failures explicitly. Existing paths return raw frames on failure (`PrivacyFilterService.swift:126`–`:134`, `:183`; `OutboundFrameRelay.swift:117`). For a mode promising protected egress, define a fail-closed policy rather than silently treating errors as no faces.
- Preserve unfiltered on-device processing only for explicitly documented purposes such as enrolled face recognition and local scene narration. Do not confuse those exceptions with cloud or broadcast paths.
- Document the limitations of face blurring: it does not remove voices, text, tattoos, contextual identity, or undetected faces, and is not proof of anonymization.

**Acceptance/evidence:** With filtering enabled, tests and a device capture show no raw frame emitted after backgrounding, GPU/detection failure, configuration change, overload or resume. Record accessible pause/stop behavior and measured latency. Reuse the relay and device-measurement work in `docs/plans/CP-outbound-frame-privacy.md`; its status text is stale relative to existing relay code, so verify implementation rather than relying on the heading.

### PIM-02 — Make deletion and correction cover derived and remote data

**Priority:** P1. **Workstream:** W03. **Owners:** iOS, gateway and privacy leads.

`SemanticMemoryStore.forget()` and `clearAll()` affect local tables/cache (`OpenGlasses/Sources/Services/SemanticMemoryStore.swift:145`, `:163`); memory is copied to a connected gateway at `:434`–`:442`, with no matching remote deletion in these functions. `clearAll()` also leaves the separate `gatewayMemories` array untouched. Expired entries are skipped on read at `:555`, while legacy JSON is renamed to a surviving `.migrated` copy at `:720`–`:724`. The header claims tombstoning, but actual `deleteMemory` executes SQL DELETE at `:533`; do not report that stale comment as runtime behavior.

Proposed actions:

- Define record IDs and provenance linking source conversations, semantic memories, agent diary, brain/project stores, contact/face records, recall projections, gateway copies and exports.
- Implement deletion/correction orchestration with local and remote outcomes. Clear in-memory results, caches and pending tasks; prevent stale responses and synchronization from resurrecting deleted data.
- Propagate deletion to managed recipients where technically and contractually possible. For independently controlled recipients, show the limitation and provide a usable request path; do not claim completed erasure from an unacknowledged remote system.
- Delete retired migration artifacts after verified migration; include SQLite database, WAL/SHM, expired rows, caches and backups in the storage lifecycle assessment. Do not promise forensic overwrite solely from a SQL DELETE or application-level overwrite on flash storage.
- Use a narrowly scoped tombstone/receipt containing no removed content only when necessary to prevent resurrection or prove fulfillment. Give that receipt its own retention rule.

**Acceptance/evidence:** Seed synthetic identities across every mapped store and a test gateway. Exercise forget, correction, persona delete, all-data delete, retry after outage, crash/relaunch, restore and interrupted sync. Verify removed content cannot be searched, exported, reinjected, or restored as active data. Evidence contains store coverage, remote acknowledgments or declared limits, and no actual subject content. Reuse the protected conversation projection in `docs/plans/DK-protected-conversation-recall-index.md`; that improvement does not establish deletion parity for other stores.

### PIM-03 — Extend retention beyond the medical transcript/temp subset

**Priority:** P1. **Workstream:** W03. **Owners:** Privacy, iOS and product owners.

`HIPAAComplianceService.enforceRetentionPolicy()` only runs when the mode is enabled and the period is positive, and covers the transcript directory plus temporary files named `OpenGlasses_…` (`OpenGlasses/Sources/Services/HIPAAComplianceService.swift:169`–`:183`). The default is 90 days and zero disables purging (`OpenGlasses/Sources/Utils/Config.swift:2167`); the launch hook is at `OpenGlasses/Sources/App/OpenGlassesApp.swift:1113`. These paths do not establish a retention program for conversations, memories, biometrics, durable recordings, health vaults or supplier copies.

**Proposed actions:** Approve purpose-specific periods and triggers for each inventory class; offer justified user controls outside medical mode; cover derived data and exports; define legal-hold exceptions and release; execute retention on appropriate lifecycle events with bounded background work and failure reporting. Choose periods from actual purposes and obligations rather than copying the existing 90-day default universally.

**Acceptance/evidence:** A retention register covers all inventoried stores and recipients. Time-controlled fixtures expire content and derived copies, preserve valid holds, and retry partial failures without claiming success. Device restore tests confirm expired data does not silently reappear. Record the distinction between inactive backups awaiting expiry and accessible live copies.

### PIM-04 — Establish notice, consent and recipient transparency

**Priority:** P1. **Workstreams:** W01, W04. **Owners:** Privacy and product leads.

There are useful contextual notices for Deepgram and translation bystander audio, and the HealthKit AI-sharing toggle defaults off. However, `PrivacyInfo.xcprivacy:17`–`:36` justifies every Linked=false declaration by the absence of a developer account/backend, while subscription/OAuth providers are supported in `LLMService.swift:8`–`:18`. The provider's account association and actual processing must be assessed too. The Settings footer at `SettingsView.swift:965` says no images leave the phone even though the adjacent control describes outbound image paths at `:947`.

As a 6 September remediation checkpoint, QR context, signed catalog/archive and remote skill-pack fetches now use named `BoundedHTTPClient` profiles in Debug and Release. Each hop resolves once, rejects mixed/private/reserved answers on public routes, connects to an approved numeric peer while retaining the original TLS hostname, and manually revalidates redirects; MIME, coding and streamed-byte limits are enforced. A private HTTP pack profile exists only in Debug, accepts only private addresses and does not redirect. Sideloads show the normalized origin and 8 MiB limit before transport; approval is bound to the exact request, single-use and valid for five minutes. The downloader streams into protected, backup-excluded staging; dismissal/backgrounding invalidates and cleans the flow, and startup removes abandoned UUID sessions. Signature/manifest/definition admission runs before the second single-use decision, whose review enumerates origin, hash, actions, capabilities, settings and warnings. Installation rechecks the staged hash and re-extracts the exact reviewed bytes through a strict, bounded ZIP reader. The earlier 13 containment tests passed, and Xcode-beta compiled and linked the Debug app plus the 60-test focused bundle. It also built and inspected the current unsigned arm64 Release simulator artifact (build `27A5228h`, SHA-256 `ec32f1eb275856c43f36e4cf76d116ffa01d3df384f3e5aa4332e299cc84eb1a`); the public profile/policy strings were present and the Debug-only `internalSkillPack` literal was absent. Two runtime attempts executed zero XCTest cases because one simulator timed out booting and an existing booted simulator remained blocked waiting for workers to materialize. First-byte/idle and TLS-hostname negative cases, manifest-before-optional-assets validation, signed installed-device network evidence, the broader outbound inventory and purpose-specific disclosure governance remain open.

Apple asks developers to assess their practices and integrated third parties, and provides criteria for data linkage and collection disclosures. Verify manifests and App Store disclosures using those actual practices, rather than assuming that absence of a first-party login settles the question. See [Apple's app privacy guidance](https://developer.apple.com/app-store/app-privacy-details/).

Proposed actions:

- Publish a role-appropriate layered privacy notice with responsible entity/contact, purposes, data categories, collection context, recipients, international routes, retention, rights, complaints, and automated features. Confirm legal requirements for each deployment and jurisdiction.
- Show the selected destination and data categories before a new cloud or remote sharing purpose. Clearly distinguish local ML inference, a LAN/custom server, cloud AI, live viewers, and a remote agent.
- Where consent is the chosen or required basis, capture a minimal versioned record of the specific purpose and affirmative action, with equivalent withdrawal. OS permissions and a generic disclaimer are not substitutes for purpose-specific analysis.
- Ensure withdrawal immediately stops further sharing on every relevant path, including mid-session sockets, retries, fallbacks and queued requests. Explain what it cannot retract from earlier recipients.
- Retain the current bystander-audio notices but make them available at actual start points and through accessible audio/display surfaces; determine whether practical bystander notice and refusal mechanisms are required for the intended setting.
- Reconcile all app/extension manifests, permission copy, website statements, subscription-provider routes and vendor manifests. Avoid claiming anonymous data where only identifiers or faces were removed.

**Acceptance/evidence:** A recorded decision exists for every inventory purpose and disclosure field. A reviewer can follow each launch/tool/session route from notice through authorization to actual network payload. Tests show withdrawal blocks subsequent egress and rerouting cannot silently broaden recipients. Reuse `docs/plans/DQ-third-party-telemetry-opt-out.md` and retain its outstanding device packet-capture verification as an open evidence item.

### PIM-05 — Perform biometric, bystander and health impact assessments

**Priority:** P1, before deployment into sensitive settings. **Workstreams:** W01, W04, W08. **Owners:** Privacy and AI/product leads with independent review.

The face service stores a name, embedding and timestamps (`FaceRecognitionService.swift:14`–`:26`) and enrolls from a current frame (`:109`–`:149`, `FaceRecognitionTool.swift:43`–`:52`). Its record schema has no subject enrollment-basis, notice-version, expiry or withdrawal fields. This is a gap in evidence and lifecycle controls; it is not a conclusion that every use is legally prohibited. File protection at `FaceRecognitionService.swift:337` is a useful safeguard.

The [HealthKit sharing check](../OpenGlasses/Sources/Services/NativeTools/FitnessCoachingTool.swift#L188) is purpose-specific: [its configuration](../OpenGlasses/Sources/Utils/Config.swift#L2680) and [Settings explanation](../OpenGlasses/Sources/App/Views/SettingsView.swift#L955) describe Apple Health/workout history. In contrast, [HealthVaultTool](../OpenGlasses/Sources/Services/NativeTools/HealthVaultTool.swift#L42) checks subscription availability and returns manually authored medication/condition/biometric notes [as tool context](../OpenGlasses/Sources/Services/NativeTools/HealthVaultTool.swift#L86). These are different data sources; the vault path is not evidence that the Apple Health permission is bypassed. Clarify the broad setting title, and separately decide whether an all-health outbound policy is required. An entitlement is not privacy authorization. PIM-08 addresses the stronger, separately verified failure to enforce the medical local-only routing preference.

Proposed assessments must separately cover:

- Face enrollment, recognition errors, accessibility benefit, subject participation, biometric identification, last-seen tracking, retention and misuse in employment, education, public-space or surveillance settings.
- Continuous audio/video, incidental children, non-participants, private spaces, location inference, recordings and live recipients.
- Health/clinical functions, medication and laboratory data, wellbeing and safety inferences, professional reliance, clinical organizations and provider contracts.
- Durable/inferred memories, profile combination, correction, unexpected redisclosure, linkage across personas/projects and vulnerability to prompt injection.

Each assessment records purpose and necessity, less intrusive alternatives, affected people, consultation where appropriate, data flow, threat/misuse scenarios, rights impacts, technical/organizational measures, residual risk, accountable approval, review triggers and conditions that disable a use case. Counsel should decide which deployments legally require a DPIA or prior consultation. Coordinate EU AI Act/ISO 42001 intended-purpose analysis with W08; do not infer an AI Act category from the feature name alone.

**Acceptance/evidence:** Signed assessments precede sensitive deployments; enrolled subjects have an applicable basis, deletion and correction path; unacceptable settings are blocked or excluded from supported use; accuracy/ambiguity and privacy tests cover relevant populations and contexts. Changing models, recipients, clinical scope, capture duration or identity purposes triggers reassessment.

### PIM-06 — Protect all export paths and make portability scope explicit

**Priority:** P1. **Workstream:** W03. **Owners:** iOS and privacy leads.

`AgentDataExporter.swift:32`–`:51` writes plaintext agent documents, memories and conversations into a temporary directory; `:75`–`:92` returns a ZIP without a completion/expiry lifecycle. `AgenticFeaturesView.swift:336`–`:339` shares that URL without a release callback. The function exports only selected stores, so its name cannot establish complete subject portability.

**Proposed actions:** Reuse `ProtectedExportFileStore` for pre-protected directories, backup exclusion, atomic success/failure semantics, share leases and crash cleanup; provide an explicit export inventory; include relevant persona/diary/derived data or disclose why excluded; verify authority without collecting excessive identification; remove abandoned staging files and finished archives; keep downstream-recipient limits visible.

**Acceptance/evidence:** Export canaries cover content and store completeness. Protection is applied before first sensitive byte; sharing/printing completion, cancellation, lock, reset, crash and stale-session recovery release files or enforce a documented TTL. Reuse `docs/plans/DL-medical-secret-and-export-lifecycle.md` and `docs/plans/DM-privacy-safe-production-logging.md`; DL P3 and physical-device share-lifecycle evidence remain open. Existing protected medical/diagnostic exports are a starting point, not evidence that agent archives use those controls.

### PIM-07 — Preserve privacy/security audit evidence without logging content

**Priority:** P1. **Workstreams:** W05, W07. **Owners:** Security, privacy and iOS leads.

At the assessment baseline, disabling medical mode was not recorded because the flag changed before the gated logger ran, and clearing removed its own clearing event. As of 6 September 2026, mode transitions use a state-independent append path, disable is recorded before the normal audit gate closes, and clearing retains `AUDIT_LOG_CLEARED` while medical mode is active. Focused medical tests passed within the 114-test combined remediation run. The local history is still capped and mutable, and this checkpoint does not establish an organizational evidence archive.

**Proposed actions:** Specify minimal audit events independently of a mode toggle; retain disable/reset outcomes; distinguish user-visible history from controlled administrative evidence; restrict access and define retention; add integrity/order checks appropriate to the deployment; monitor write/export failures. Avoid storing transcripts, medical content, identities or credentials merely to prove an event happened.

**Acceptance/evidence:** Tests cover disable, clear, overflow, failure and clock/order scenarios; administrative evidence survives within the approved retention period and deletion is itself accountable. Preserve the typed `PrivacyLog`, canary tests and diagnostic preview controls already delivered by DM. A PIMS does not require covert first-party telemetry; managed deployments must explicitly define any organizational evidence collection.

### PIM-08 — Enforce the medical local-only routing preference

**Priority:** P0 for medical mode with local-only enabled and a cloud model configured. **Workstreams:** W04, W06, W08. **Owners:** iOS, AI/product and privacy leads. **Related master finding:** F09.

At the assessment baseline, the [Local LLM Only control](../OpenGlasses/Sources/App/Views/HIPAASettingsView.swift#L321) wrote `Config.hipaaLocalOnly` and [promised on-device processing](../OpenGlasses/Sources/App/Views/HIPAASettingsView.swift#L329), but the preference had no routing reader and the existing test checked only flag storage. As of 6 September 2026, `MedicalLLMRoutingPolicy` and `LLMService` enforce medical mode plus local-only preference across the main, cascade, stateless, context-summary, structured frame/text, fast-tier/local-agent and named cloud-provider boundaries. Cloud or unusable selections resolve to a downloaded local model or an explicit refusal, and local/Apple web-search cloud fallback is suppressed. Focused policy and provider-boundary tests passed within the 114-test combined run. No real clinical transmission was performed or observed.

Proposed actions:

- Make the medical local-only rule an authoritative runtime policy, checked before any eligible request is constructed or queued and again at outbound dispatch where necessary. Define its activation as medical mode plus the local-only preference, and test those states explicitly.
- Keep a local-only request on a supported on-device route. If no local model is available, it is incompatible, or it fails, decline or pause with an accessible explanation. Do not fall back to cloud, a LAN/custom server, a remote agent or another provider while presenting the processing as on-device.
- Apply the restriction to auxiliary summarization, classification, planning, vision, agent inference and embeddings as applicable, plus retries, model cascades and background tasks. Enumerate live STT/TTS, translation, memory synchronization and remote tools separately so the stronger UI statement that clinical data stays on-device is either enforced across these routes or accurately narrowed without hiding a material limitation.
- Re-evaluate in-flight sessions and queued work when medical/local-only settings change; cancel unsent remote work and prevent the next audio/frame/result from leaving. Explain that a setting change cannot retract previously transmitted data.
- Make route decisions and blocked outcomes inspectable using content-free diagnostic events. Keep the actual destination and mode synchronized with the visible/audible state.

**Acceptance/evidence:** Exercise the real request builders and transport seams with synthetic clinical canaries for every supported provider and auxiliary route. With medical/local-only mode active and cloud selected, assert zero canary-bearing outbound HTTP/WebSocket/audio/video/tool/memory requests; observe local execution or an explicit refusal. Repeat with missing/incompatible local models, timeouts, malformed responses, fallback/cascade, retries, auxiliary summarization, session resumption, backgrounding, queued requests and a mid-session policy change. Test the inactive-policy combinations to preserve intentional cloud operation. Capture actual device traffic and the effective configuration for representative paths; inspect generated payloads rather than only asserting the preference value. Complete the route inventory, residual-limit disclosure and independent review before closing F09. Reconcile the existing [medical routing UI](../OpenGlasses/Sources/App/Views/HIPAASettingsView.swift#L319) with demonstrated behavior.

## 4. Management-system implementation, clauses 4–10

| Management-system area | Proposed activity | Workstream / accountable owner | Acceptance and required evidence |
|---|---|---|---|
| Clause 4 — Context and scope | Define responsible legal entity, products, customer modes, support, jurisdictions, interested parties, interfaces and documented scope; justify exclusions. | W01 / executive and privacy leads | Approved scope, role matrix, applicability/legal register, boundaries and inventory with no unowned processing. |
| Clause 5 — Leadership | Approve privacy policy, accountable ownership, escalation, resources and commitments to affected people. | W01 / executive sponsor | Dated policy, assigned owners, resource decision, communication and accessible contact route. |
| Clause 6 — Planning | Assess privacy risks/opportunities; set measurable objectives; create treatment plans and change criteria; map controls against the licensed 2025 edition. | W01, W08 / privacy lead | Risk register includes data-subject harms, treatment owners and residual approval; verified requirements/control applicability register. |
| Clause 7 — Support | Establish competence, privacy training, communication, evidence access, documentation/version control and supplier review capability. | W06, W07 / privacy and security leads | Training completion, role-specific competence checks, document register, evidence permissions and approved communications. |
| Clause 8 — Operation | Operate notices, rights, consent, sensitive-data restrictions, transfer/supplier reviews, retention, incident processes and privacy change review. | W02–W08 / process owners | Samples of actual operation, completed engineering gates and complete activity/recipient coverage. |
| Clause 9 — Performance evaluation | Measure fulfillment and failures; perform independent internal audit; conduct management review and track decisions. | W01, W05 / independent reviewer and sponsor | Metric history, audit plan/report, objective findings, management minutes, decisions and resources. |
| Clause 10 — Improvement | Correct failures, investigate causes, check efficacy and update controls after incidents/complaints/changes. | All / accountable control owner | Corrective-action record connects cause, change, verification, recurrence monitoring and closure approval. |

## 5. Controller, processor and supplier responsibilities

| Context | Proposed obligations and role-specific work | Evidence before claiming readiness |
|---|---|---|
| Organization acts as controller | Decide and record purposes and applicable bases; issue notice; respond to subject rights; assess sensitive/high-impact processing; set retention and recipient restrictions; document accountability. | Role decision, processing record, notice version, assessment, rights cases and recipient register. |
| Organization acts as processor for an enterprise | Process within documented instructions; define confidentiality and security; assist with rights/incidents/assessments; control subprocessors; handle instructions outside scope; return/delete at service end. | Executed agreement, instruction register, subprocessor authorization, assistance tests, termination/deletion evidence. |
| Enterprise customer controls device use | Provide deployment documentation, configurable restrictions and data-flow facts; explain controls the customer must operate, including staff/bystander notices and permitted locations. | Deployment responsibility matrix accepted by customer; configuration export; verified operational procedures. |
| AI, speech, gateway or streaming recipient | Determine processor, independent-controller or other role per service and contract; verify actual entity, locations, onward uses, training settings, retention, subprocessors, security, incident assistance and deletion. | Contract/terms snapshot, review, configuration proof, transfer assessment/mechanism where needed and change-monitoring owner. |
| BYOK or subscription account | Explain account-owner responsibilities without assuming they remove the developer's obligations; validate which terms and settings apply to the actual endpoint/account tier. | Provider/route matrix and per-purpose decision; no unsupported claim of zero retention or no training. |
| Support recipient | Limit report contents and authorized access; disclose recipient and retention; operate subject/incident procedures for reports that are actually received. | Support workflow, access review, purge evidence and diagnostic content checks. |

Where GDPR applies, use its actual purpose, role, rights, security and transfer requirements as a separate legal register rather than treating ISO certification as legal compliance. The authoritative instrument is [Regulation (EU) 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj). The standards plan does not resolve jurisdiction, exemptions or a lawful basis by itself.

## 6. Rights and incident operating procedure

Proposed rights workflow: receive requests through an accessible channel; establish the responsible controller; verify identity/authority proportionately; determine data and applicable rights; search the inventory and derived/remote copies; check third-party rights and lawful exceptions; fulfill with secure delivery; record scope, outstanding recipients and completion; provide escalation/complaints. Maintain jurisdiction-specific deadlines in the legal register. Do not impose a generic deletion button as the whole procedure.

Proposed incident workflow: detect unauthorized collection, unfiltered broadcast, lost device/export, provider compromise, unintended recipients or failed deletion; preserve minimal evidence; stop/revoke affected paths; assess impact and controller/processor roles; notify counterparties, regulators and affected people when applicable; document rationale and applicable deadlines; verify recovery and prevention. Run a joint exercise involving a cloud audio session, an enterprise customer, a bystander and a vendor notification.

**Acceptance/evidence:** A synthetic access/portability, correction, deletion and objection/withdrawal case completes through each supported deployment. A timed incident exercise proves ownership, contact availability, contractual assistance and decision recording. Track late requests, unverified deletion, repeated failed jobs and unauthorized route attempts without collecting unnecessary content.

## 7. Proposed execution sequence and release evidence

The workstream identifiers below align with the shared remediation roadmap; they are workstreams, not calendar weeks.

| Sequence | Dependencies and work | Exit evidence |
|---|---|---|
| Immediate containment | W02 untrusted-fetch Release restriction; W04 PIM-01 background/filter failure policy and PIM-08 medical local-only enforcement; correct misleading privacy copy; restrict sensitive deployments lacking an approved basis and impact assessment. | Reproduced failures, fixes or gated paths, zero-egress route evidence for contained/local-only modes, device verification, accessible user behavior. |
| Scope and design | W01 role/scope/inventory/legal register; W08 sensitive-use assessment; W03 deletion/retention design; W04 consent/recipient design. | Named ownership, approved records and risk treatments, licensed-standard mapping scheduled. |
| Implementation | W02 transport dependencies; W03 cross-store rights and exports; W04 purpose/recipient enforcement; W05 reliable audit evidence; W06 regression gates. | Passing route/store matrix, negative tests, migration/restore results, independent review. |
| Operational readiness | W07 access/support/supplier operations; W01 controller/processor procedures; all required device and recipient verification. | Contract and configuration evidence, rights/incident exercise, completed training and documented exceptions. |
| Assurance and improvement | Clause 9 evaluation and independent internal audit; management review; Clause 10 corrective actions. | Observed operation, closed material findings, evidence index and a scoped readiness decision. |

Do not infer implementation or effective operation from a plan marked complete. Preserve the current controls as strengths: complete file protection for conversations and face records; optional biometric conversation encryption; in-memory, lock-scoped recall with deletion propagation; opt-in Apple Health sharing; context-specific bystander-audio notices; typed privacy logging and canaries; protected medical/diagnostic export sessions; and SDK telemetry opt-out/interception. Revalidate these after changes and collect remaining device evidence.

## 8. Readiness decision

Proposed readiness criteria are: verified 2025 requirement/control mapping; approved PIMS scope and roles; complete processing/recipient inventory; resolved material egress/deletion/export gaps; approved sensitive-use assessments; usable notice and rights processes; supplier/transfer decisions; demonstrated privacy-aware operations; independent internal audit; management review; and evidence that corrective actions work.

This repository assessment is insufficient to assert ISO/IEC 27701 certification, organizational conformity, SOC 2 Privacy operating effectiveness, GDPR compliance, or suitability for any particular medical, biometric or workplace deployment. The output of this plan should be a reviewable evidence set and a justified scope-specific readiness decision.
