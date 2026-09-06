# OpenGlasses compliance assessment

**Date:** 2026-09-04. **Baseline:** `b2b5190f2c3a55064242d6bd45a16c006c65d55b`. **Assessment type:** repository-based control design and readiness review. **Decision:** significant remediation and organizational evidence collection required; no conformity opinion issued.

## 1. Scope and method

The reviewed product is an iOS voice/vision assistant with wearables, local and cloud models, recordings, personal memory, external tools, medical export, safety advice, remote streaming, and Watch/share/widget/Siri surfaces. Source, tests, configuration, CI scripts, public documentation and existing plans were inspected. Existing plans were treated as leads, then checked against current implementation; a checked box or an old defect description was not accepted as current evidence.

The working tree was clean at the start. Local secret contents and personal data were not read. Git history was not exhaustively scanned for secrets. Generated builds, production infrastructure, organization settings, contracts, employee controls, customer deployments and operating logs were not audited. No system was attacked, no external messages were sent, and no application behavior was modified.

References below identify current source lines, not immutable proof of a deployed binary. The baseline commit, future build digest, configuration and evidence capture date must accompany audit samples. Static review cannot demonstrate that a control operated consistently over time.

### Boundary to approve in W01

1. **Product and development:** maintained app targets, build/release/signing pipeline, dependency and model artifacts, public documentation, maintainers and support.
2. **Operator-owned services, if any:** gateway, signaling/TURN, licensing, model endpoints, support systems and telemetry. Ownership, hosting regions and production configuration are unresolved. Sample servers are not evidence of an operated production service.
3. **User-controlled assets:** phone, glasses, API subscriptions, self-hosted models, MCP servers, smart home and exported files. Document shared responsibilities without assuming user configuration removes the vendor's design obligations.
4. **Suppliers:** Meta, Apple, model/speech providers, model registries, build services and any hosted relay. Separate contractual subprocessors from independently chosen user providers; do not label every integration a subprocessor without a role analysis.

[README](../README.md#L5) describes source-available distribution and [the current developer-preview limitation](../README.md#L7). Neither establishes the legal entity, EU market status, organization scope or a production service boundary. SOC 2 examines a defined service organization's system; it is not a certificate for a repository. ISO certification concerns the scoped management system. ISO 42001 certification would not itself establish EU AI Act compliance.

### Evidence and risk conventions

| Label | Meaning |
|---|---|
| Observed gap | A specific implemented behavior falls short of an identified control objective |
| Partial | Relevant safeguards exist, but coverage or assurance remains incomplete |
| Not evidenced | Requested organizational/operational evidence was not available in the reviewed repository |
| Conditional | Applicability or exploitability depends on configuration, operator role or intended use |

Severity is a qualitative prioritization, not a CVSS score or formal audit nonconformity. **High** means plausible exposure of sensitive data, consequential unauthorized action, material release-assurance weakness or a significant governance blocker. **Medium** means a narrower exposure or important strengthening of a partially implemented control. No critical exploitable breach was established. W01 must adopt a repeatable likelihood/impact model and obtain named risk-owner acceptance; do not convert these findings into an invented compliance percentage.

## 2. Data flows and trust boundaries

| Flow | Data and subjects | Boundaries and existing controls | Assessment focus |
|---|---|---|---|
| Glasses/phone → voice and vision pipeline | Wearer/bystander audio, images, recognized text, potentially health/workplace data | OS and DAT permissions; optional face filter | Consent purpose, ongoing capture visibility, fail-closed filtering |
| App → chosen LLM/STT/TTS provider | Prompts, tool results, images, recordings, derived facts and OAuth/API credentials | Local execution options; provider APIs; keychain credentials | Destination policy, fallback, provider retention/training/region and notice |
| App → local stores | Chats, recordings, face embeddings, person notes, health vaults, semantic/graph memory | iOS sandbox/data protection, optional extra conversation encryption | Inventory, subject linkage, retention and complete deletion |
| App ↔ gateway/MCP/custom tools | Context/memories and read/write commands | Auth tokens, scoped local routing and some egress screening | Transport, per-tool effects/consent, replication deletion and remote identity |
| App → broadcast/expert/HUD | Live video/audio, display text, scene context | Shared frame relay, optional blur, default-off LAN services | Background filtering, channel security and session revocation |
| App → exports/FHIR/share/Siri/Watch | Transcripts, health records, safety reports, searchable content | Protected medical export, selective Spotlight exclusions | Other export paths, recipient retention, lock-screen and shared container behavior |
| Development → dependencies/build/site | Source, signed packs, binary frameworks, model weights, CI artifacts | Version locks/checksums in some paths, tests, signing | Immutable provenance, required checks, narrow publication surface |

The privacy plan expands this into a proposed records-of-processing inventory. Each flow needs purpose, data classes, role, recipients, location, retention, rights mechanism, owner and evidence. A user API key does not make all transmitted data anonymous; no first-party account does not imply no person can be linked to data.

## 3. Controls worth preserving

- **Keychain and authenticated encryption:** [ConversationEncryptionService](../OpenGlasses/Sources/Services/ConversationEncryptionService.swift#L27) uses ChaChaPoly; its key policy uses device-local, unlocked access with user presence. Conversation files also apply complete file protection in [ConversationStore](../OpenGlasses/Sources/Services/ConversationStore.swift#L531). Optional app encryption being off is not evidence that iOS files are stored without OS encryption.
- **Medical credentials/exports have already improved:** [FHIRCredentialStore](../OpenGlasses/Sources/Services/Medical/FHIRCredentialStore.swift), [FHIRConfigurationStore](../OpenGlasses/Sources/Services/Medical/FHIRConfigurationStore.swift) and [ProtectedExportFileStore](../OpenGlasses/Sources/Services/Export/ProtectedExportFileStore.swift) implement protected credentials, export leases and cleanup. Reuse these components; do not reopen the old plaintext FHIR finding solely from [Plan DL's historical problem statement](../docs/plans/DL-medical-secret-and-export-lifecycle.md).
- **Remote authentication exists:** MCP uses strong bearer credentials and comparison logic. F01 concerns cleartext transport and exposure scope, not an unauthenticated-by-default server.
- **Deterministic action checks:** [SafetySupervisor](../OpenGlasses/Sources/Services/Agent/SafetySupervisor.swift#L48), prompt-injection policy, remote consent and typed tool outcomes provide useful safety boundaries. External-tool coverage still requires F11 verification.
- **Privacy engineering and regression tests exist:** scoped filtering, selective Siri donation, privacy logging checks, protected medical exports and substantial security/privacy tests are present. Review the actual evidence and failure paths; test filenames are not proof of passing execution.
- **Health and safety outputs contain guardrails:** [HealthSafetyResponseBuilder](../OpenGlasses/Sources/Services/HealthSafety/HealthSafetyResponseBuilder.swift#L24) preserves deterministic warnings and appends an advisory disclaimer. [SafetyAssessmentSchema](../OpenGlasses/Sources/Services/StructuredVision/Schemas/SafetyAssessmentSchema.swift#L11) also has a disclaimer. These mitigate overreliance but do not validate clinical or occupational safety performance.

## 4. Findings and resolution paths

### F01 — Cleartext LAN and bridge transports

**High; observed; production listener exposure contained on 5 September 2026, with transport remediation still open.** [MCPGlassesServer](../OpenGlasses/Sources/Services/MCPServer/MCPGlassesServer.swift#L77) and [WebHUDMirrorServer](../OpenGlasses/Sources/Services/Display/WebHUD/WebHUDMirrorServer.swift#L63) now consult a compile-time-derived `LocalServiceExposurePolicy` before creating a token or listener. Release refuses both legacy cleartext transports, clears their persisted opt-ins at launch, suppresses the HUD registration URL and describes the services as unavailable. Debug preserves the existing LAN development workflow. All 5 focused policy tests passed in the Xcode 27 simulator checkpoint on 6 September 2026. The Debug transport still uses plain TCP, the HUD request still forwards its bearer in a query, and Hermes bridge URL construction still needs secure WebSocket policy. No TLS, pairing, replay protection, scope separation, resource-limit or installed-Release-artifact claim is made by this containment.

**Residual impact:** a Debug build with either service enabled can expose camera/context/credentials to observation or replay by an actor on its network path; Hermes and any other bridge remain separately in scope. **Resolve:** complete W02, reusing [Plan DO](../docs/plans/DO-local-network-transport-hardening.md); verify the Release artifact/configuration boundary, authenticate paired peers over encrypted channels, remove token URLs, scope capabilities and prove lock/background/revocation behavior. **Mapping:** SOC CC6.1/6.6/6.7; ISO A.8.20/A.8.21/A.8.24; PIMS disclosure security.

### F02 — Outbound endpoint, redirect and resource limits are incomplete

**High; observed at the assessment baseline; bounded-fetch, consent and archive engineering checkpoints implemented on 6 September 2026.** At baseline, [QRContextTool](../OpenGlasses/Sources/Services/NativeTools/QRContextTool.swift) validated only the initial URL before using a redirect-following shared session, while [URLFetchGuard](../OpenGlasses/Sources/Services/URLFetchGuard.swift) did not resolve DNS. QR context, signed catalog/archive and remote skill-pack deep-link fetches now use named `BoundedHTTPClient` profiles. For every hop, the client resolves once, rejects mixed or private/reserved public-DNS answers, connects to one approved numeric address while retaining the original host for TLS verification, and manually revalidates at most three redirects. It rejects downgrade, loops, credentials, fragments, non-default public ports, disallowed MIME/content/transfer codings and streamed byte overflow. The private HTTP skill-pack profile is compiled only in Debug, permits only private addresses and refuses redirects. The earlier 13-test containment suite passed; the new bounded-client and archive tests compile and link in the Xcode-beta arm64 test bundle.

All builds stop a sideload link at a non-network prompt showing the normalized origin and 8 MiB limit. Its approval is single-use, bound to the exact parsed request and expires after five minutes. The downloader streams consented bytes through a 32 KiB rolling buffer into a protected, backup-excluded staging file and enforces the compressed limit during receipt. Dismissal or backgrounding cancels and invalidates the flow and removes staging; a late response cannot restore it, and service startup removes abandoned UUID staging sessions. The production signature, manifest, definition and admission checks run before the post-inspection confirmation. That single-use review enumerates origin, archive hash, actions, native/procedure/remote/hardware capabilities, settings and warnings. Installation reloads, hashes and re-extracts the exact staged archive before repeating admission and writing. Credential-bearing and fragment-bearing source URLs are rejected without retaining the full URL in the parse error.

Protected staging maps the capped ZIP rather than duplicating it in heap. The strict reader checks EOCD/central-directory bounds, single-disk/non-ZIP64 layout, central/local name/flag/method/size/CRC agreement, descriptors and non-overlapping physical regions. Skill-pack admission rejects oversized archives/entries, excessive count/aggregate size/ratio, unsafe or duplicate paths, encrypted/nested/unsupported entries, Unix special files and type masquerading. Stored and deflated content is decoded through 32 KiB chunks with actual-output limits and incremental CRC before approved files are materialized. The 60-test focused selection was compiled and linked, but zero XCTest cases ran in two Xcode-beta attempts: a new iOS 27 simulator timed out while preparing to boot, and an existing booted simulator remained blocked waiting for workers to materialize. These are infrastructure failures, not passing runtime evidence.

The current source set also built successfully as an unsigned arm64 Release simulator app with Xcode-beta build `27A5228h`. The inspected 136,425,544-byte Mach-O has SHA-256 `ec32f1eb275856c43f36e4cf76d116ffa01d3df384f3e5aa4332e299cc84eb1a`; its binary contains the public `qrContext`, `signedCatalog` and `skillPack` profile strings and the bounded-fetch policy messages, while the Debug-only `internalSkillPack` literal is absent.

**Residual impact:** the new adversarial suite has compile/link evidence but no post-change execution evidence. The inspected Release artifact is unsigned and simulator-only, so it does not establish installed-device behavior. The client has total and TCP connection/drop limits but still needs explicit first-byte/idle deadline cases and a TLS-hostname negative test. Skill-pack extraction reads the manifest first but validates it after optional files are materialized within the 32 MiB aggregate cap. Configured MCP, custom-model, gateway, FHIR and other outbound routes are not covered by this checkpoint. **Resolve:** W02 and [Plan DN](../docs/plans/DN-outbound-fetch-and-sideload-hardening.md): run the focused/full suites on working simulator/CI infrastructure, add the remaining deadline/TLS/manifest-first gates, inspect a signed installed Release artifact, capture physical-device DNS/redirect/private-address behavior and finish the W02.3 outbound inventory. **Mapping:** CC6.6/6.7, CC7.1; A.8.6/A.8.20/A.8.26/A.8.28/A.8.29.

### F03 — Background streaming suspends the privacy filter

**High; observed at the assessment baseline; fail-closed checkpoint implemented on 6 September 2026.** The baseline background path suspended filtering and allowed raw frames through several failure paths. `PrivacyFilterService` now distinguishes a verified no-face result from detector failure and returns an opaque replacement when enabled filtering is suspended or still-image conversion/detection/compositing fails. `OutboundFrameRelay` drops frames for those failures, rechecks suspension at the publication boundary and sends raw content only after a successful no-face result. All 27 focused outbound privacy tests passed, including suspension, detector, conversion, compositor and publication-race cases.

**Residual impact:** the source-level checkpoint has not yet traversed actual app background/lock transitions or every recording, RTMP, WebRTC, HUD and AI consumer on a device. Detection intervals may also leave a newly entering face unobserved between scans. Filtering remains optional and is not a consent or anonymization guarantee even when working. **Resolve:** complete W04 with consumer inventory, lifecycle/device/CPU-pressure tests, a documented interval policy and evidence that no raw frame reaches a protected destination when filtering is enabled but unavailable. **Mapping:** CC6.7, C1.1, P3/P6; A.8.11/A.8.12; PIMS minimization and disclosure; AI impact assessment.

### F04 — Deletion does not cover derived and replicated memory

**High; observed.** [SocialContextTool](../OpenGlasses/Sources/Services/NativeTools/SocialContextTool.swift#L35) writes person facts into both social storage and BrainStore, but its forget path at line 69 only clears social facts. [SemanticMemoryStore](../OpenGlasses/Sources/Services/SemanticMemoryStore.swift#L145) deletes locally while its remember path sends to the gateway; a corresponding gateway deletion is not demonstrated. Clearing must also address gateway cache, derived graph data and migration remnants.

**Impact:** a person or fact can remain retrievable after a forget operation. **Correction to stale documentation:** the current semantic SQL deletion is a real `DELETE`, not merely a tombstone; the gap is cross-store/remote lifecycle. **Resolve:** W03 with provenance/subject identifiers, coordinated erasure, remote acknowledgments/retries and honest partial-completion receipts. **Mapping:** C1.2, P4/P5/P6; A.8.10; PIMS rights and retention.

### F05 — Retention policy covers only selected files

**High; observed.** [HIPAAComplianceService](../OpenGlasses/Sources/Services/HIPAAComplianceService.swift#L169) runs retention only when the mode and a positive duration are enabled, over transcripts and selected temporary filenames. It does not establish a uniform schedule for conversations, faceprints, preserved recordings, graph/semantic memory and replicas. Semantic expiry can suppress retrieval without physical purging; migration backups also need lifecycle treatment.

**Impact:** sensitive records can survive the user's assumed retention period. **Resolve:** W03, using a data-class schedule and persistent cleanup jobs across files/databases/remote stores. Include offline devices, crash recovery, encrypted backups and justified holds. No framework supplies a universal 90-day or seven-year retention requirement. **Mapping:** P4, C1.2; A.5.33/A.8.10; PIMS retention.

### F06 — Generic AI data export lacks the medical export lifecycle

**Medium; observed.** [AgentDataExporter](../OpenGlasses/Sources/Services/AgentDataExporter.swift#L32) stages documents, memory and conversation content as readable files and creates a ZIP in temporary storage. It removes the staging directory on its success path at line 87, but the returned ZIP and interrupted/error paths do not demonstrate the protected medical export's lease/TTL lifecycle. OS sandbox/encryption still applies; this is not proof anyone can read the phone filesystem.

**Impact:** additional sensitive copies may outlive sharing. **Resolve:** W03; reuse [ProtectedExportFileStore](../OpenGlasses/Sources/Services/Export/ProtectedExportFileStore.swift), protect before writing, exclude backup, close leases on completion/cancel and sweep after crashes. Apply the same inventory to HECA PDFs and other export families. **Mapping:** CC6.7, C1.2, P4; A.8.10/A.8.12/A.8.24.

### F07 — Compliance audit lifecycle loses events

**High; observed at the assessment baseline; correctness checkpoint implemented on 6 September 2026.** `HIPAAComplianceService` now records enable and disable transitions through a state-independent append path, records disable before closing the normal audit gate, and retains `AUDIT_LOG_CLEARED` after clearing while medical mode is active. `ProtectedOperationJournal` now distinguishes unavailable storage, preserves unreadable/corrupt bytes, refuses admission when initial load or admission persistence fails, restores its in-memory state after a failed write and prevents later dispatch after a terminal-resolution persistence failure. `NativeToolRouter` fails before performing work when journal storage is unavailable. Focused medical and journal tests passed as part of the 114-test combined remediation run.

**Residual impact:** the local JSON audit history remains mutable and capped without an approved retention/export scheme or independently stored tamper/rollback checkpoint. Audit clearing still needs an authorization design. Locked-data, disk-full and crash-boundary integration evidence and reconciliation of unknown remote outcomes remain open. **Resolve:** complete W05 with destructive-action authorization, durable independently verifiable checkpoints appropriate to the deployment, retention/export/review procedures and injected storage/lifecycle failures. A hash chain inside the same writable file alone cannot prevent rollback or deletion. **Mapping:** CC7.2/7.3, CC4.1, optional PI1; A.8.15/A.8.16; PIMS accountability; AI traceability.

### F08 — Biometric enrollment lacks demonstrated subject governance

**High; partial/conditional.** [FaceRecognitionService](../OpenGlasses/Sources/Services/FaceRecognitionService.swift#L14) models names, face embeddings and encounter timestamps. [FaceRecognitionTool](../OpenGlasses/Sources/Services/NativeTools/FaceRecognitionTool.swift#L43) can enroll a face from a current image. The path does not demonstrate a record of the subject's enrollment decision, notice, permitted purpose or expiry. Local file protection and explicit wearer commands are meaningful safeguards, but the wearer is not necessarily the biometric subject.

**Impact:** persistent identification/social profiling without a justified purpose or usable subject-rights path. **Resolve:** W01/W04/W08; approve intended uses, biometric/privacy impact assessment and applicable legal basis; implement enrollment restrictions, deletion linkage and person-facing notice/withdrawal where appropriate. Do not assert every face feature is prohibited or every diarization feature is identification; classify actual functionality. **Mapping:** P2/P3/P5/P6; A.5.34; ISO 27701; ISO 42001 impact/use; EU Articles 5/6 and Annex III assessment.

### F09 — Health-sharing and provider-routing policy is not universal

**High; routing gap observed at the assessment baseline; LLM-boundary checkpoint implemented on 6 September 2026, with a separate partial health-policy issue.** [HIPAASettingsView](../OpenGlasses/Sources/App/Views/HIPAASettingsView.swift#L321) offers “Local LLM Only” and promises all AI queries remain on-device. `MedicalLLMRoutingPolicy` and `LLMService` now enforce the combination of medical mode plus local-only preference across the main send path, cascade selection, stateless/context-summary and structured frame/text requests, fast-tier/local-agent selection and the Anthropic, OpenAI-compatible, ChatGPT and Gemini provider boundaries. A cloud or unusable local selection is replaced with a downloaded local model or refused with a clear message; local/Apple web-search cloud fallback is suppressed. Routing-policy and provider-boundary tests passed as part of the 114-test combined remediation run. No live clinical transmission was performed or observed in this review.

Separately, the default-off health-sharing preference is checked by [FitnessCoachingTool](../OpenGlasses/Sources/Services/NativeTools/FitnessCoachingTool.swift#L188). Its description concerns Apple Health/workouts. [HealthVaultTool](../OpenGlasses/Sources/Services/NativeTools/HealthVaultTool.swift#L42) uses a subscription gate and returns manually authored conditions/medications to tool context. This is not proof of bypassing HealthKit permission; it shows that an Apple Health preference is not a universal sensitive-health-data egress policy. Model routing and fallback require destination controls beyond a single tool.

**Residual impact:** broader STT/TTS, realtime, translation, memory synchronization and tool routes have not yet been proven to honor the same rule. Queued/in-flight requests during a mode change, content-free route diagnostics and actual network canaries also remain open. **Resolve:** finish W04 by inventorying every data route, enforcing or accurately narrowing the UI commitment, testing mid-session changes and tracing synthetic clinical canaries at final HTTP/WebSocket/audio/video/tool/memory dispatch. Precisely scope the separate Apple Health label. **Mapping:** CC6.7, P2/P3/P6; A.8.12; PIMS purpose/disclosure; AIMS data use.

### F10 — Privacy claims need reconciliation with processing

**High; partial.** [PrivacyInfo.xcprivacy](../OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy#L17) explains unlinked declarations primarily by absence of a first-party account; provider OAuth/subscription linkage needs a fuller Apple-rule analysis. [SettingsView](../OpenGlasses/Sources/App/Views/SettingsView.swift#L965) says no images leave the phone, while line 947 describes cloud/broadcast egress. Reconcile the exact scope of that statement with F03. The [README](../README.md#L369) names multiple international medical/privacy frameworks, and [HIPAASettingsView](../OpenGlasses/Sources/App/Views/HIPAASettingsView.swift#L316) asserts implementation of their technical safeguards. Feature names and assertions cannot substantiate those claims.

**Impact:** notices or marketing can set commitments broader than implemented/contractual controls. **Resolve:** W01/W04; create a claim-to-evidence register, verify SDK telemetry against the actual pinned SDK and configuration, reconcile public notice/App Store declarations/settings for every provider mode. [Plan DQ](../docs/plans/DQ-third-party-telemetry-opt-out.md) is a verification lead, not proof of current telemetry behavior. **Mapping:** CC2.3, P1/P2/P6; A.5.31/A.5.34; PIMS transparency; AI information to users.

### F11 — External tool effects and untrusted definitions need stronger policy

**High; partial; malicious/compromised configured server required.** Tool-definition scanning can label a definition quarantined while keeping it offered. The native high-impact policy covers named native tools; the external dispatch seam does not establish equivalent write-effect classification. Credential-pattern egress screening cannot classify arbitrary health, name or location narratives. Name qualification helps prevent tool shadowing but does not make remote descriptions trustworthy.

**Evidence:** [ToolDefinitionScanner](../OpenGlasses/Sources/Services/Security/ToolDefinitionScanner.swift#L6), [MCPClient](../OpenGlasses/Sources/Services/MCPClient.swift#L96), [PromptInjectionPolicy](../OpenGlasses/Sources/Services/PromptInjectionPolicy.swift#L73), and [NativeToolRouter](../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift#L198). **Resolve:** W04/W08; default-deny unreviewed effects, keep quarantined definitions out of model context, bind consent to server/tool/arguments and execute adversarial integration tests across native/MCP/custom/gateway routes. **Mapping:** CC6.1/6.3/6.7; A.8.3/A.8.26/A.8.28; AIMS human oversight and misuse.

### F12 — Owner authentication fails open when unavailable

**Medium; observed; enterprise policy conditional.** [OwnerGate](../OpenGlasses/Sources/Services/OwnerGate.swift#L59) permits access when device-owner authentication is unavailable. This is a consumer usability decision, not an enforced enterprise administrator boundary.

**Impact:** a managed policy that requires owner authentication cannot rely on this gate alone. **Resolve:** W07; define supported enterprise device posture, require passcode/device-owner authentication when policy demands it, fail closed with recovery support and test unavailable/cancel/lock states. **Mapping:** CC6.1/6.2/6.3; A.8.1/A.8.5.

### F13 — Build provenance and dependency resolution have inconsistent gates

**Medium; observed.** Actions use version tags; XcodeGen download/execution lacks an integrity check in [ci_post_clone](../ci_scripts/ci_post_clone.sh#L23). Xcode Cloud copies its lock into the generated project, but the reviewed GitHub test path does not demonstrate that same frozen-resolution gate. Root package/lock and canonical Xcode dependency versions differ. Existing MediaPipe and llama checksum/pin mechanisms are strengths to replicate.

**Impact:** builds may incorporate unreviewed upstream changes or resolve differently between pipelines. **Resolve:** W06; pin action SHAs with controlled updates, verify tool downloads, define the authoritative dependency manifest/lock, require frozen resolution and archive dependency/model/binary provenance per release. **Mapping:** CC8.1, CC9.2; A.5.21/A.8.8/A.8.25/A.8.32.

### F14 — Security release-gate operation is not demonstrated

**High; not evidenced/partial.** CI/test sources show significant verification intent. Repository configuration alone cannot prove required PR reviews, protected branches, least-privilege workflow defaults, secret scanning, vulnerability triage or independent release approval. Some workflow files omit explicit token permissions; actual effective platform settings were not inspected.

**Impact:** even good tests can be bypassed or fail to cover the released artifact. **Resolve:** W06; obtain settings exports, enforce required security checks/reviews, prove a failing change is blocked, test emergency changes and collect release-to-build-to-review evidence. **Mapping:** CC5/CC7.1/CC8.1; A.8.8/A.8.29/A.8.32.

### F15 — Website publishing includes the repository root

**Medium; observed.** [pages.yml](../.github/workflows/pages.yml#L18) uploads `path: .` on main pushes. That couples product source/plans to a public website artifact instead of an explicit website allowlist.

**Impact:** future internal evidence or files may be published unintentionally. No secret exposure is asserted and this assessment did not deploy. **Resolve:** W06; stage only approved website files, reject sensitive paths from artifacts and keep audit evidence outside the repository. **Mapping:** CC6.7, CC8.1; A.5.12/A.5.14/A.8.12.

### F16 — Integrated management-system evidence is unavailable

**High; not evidenced.** The reviewed repository does not establish approved scope, accountable control owners, interested-party requirements, risk methodology/register, risk treatment, Statement of Applicability, objectives, training records, internal audit, management review or corrective-action operation.

**Impact:** technical improvements alone cannot support the requested attestations/certifications. **Resolve:** W01; build one coordinated evidence system for ISMS/PIMS/AIMS with distinct scope and requirements, and approve a SOC 2 system description. Evidence may already exist outside the repository; obtain and assess it first. **Mapping:** CC1–CC5/CC9; ISO management clauses 4–10.

### F17 — Organization access, people and physical controls are unassessed

**High; not evidenced.** Maintainer identities/access reviews, joiner/mover/leaver records, MFA/recovery, signing-key custody, laptop management, backups and office/home-work controls were not available. Local key files by filename alone do not prove tracked/live/exposed credentials, and their contents were not inspected.

**Resolve:** W07; inventory identities and assets, enforce MFA and least privilege, document employment/confidentiality/training and remote-work controls, protect signing material, test offboarding and retain access reviews. **Mapping:** CC1, CC6; ISO A.5.15–A.5.18, A.6, A.7, A.8.1/A.8.2.

### F18 — Incident response and continuity operation are unassessed

**High; not evidenced.** Runtime retry/recovery code does not prove a staffed incident process, breach decision workflow, measured backup restore, production RTO/RPO or dependency-outage plan. No operational evidence was available for hosted services, if any.

**Resolve:** W07; define incident severity/ownership/contact routes, preserve redacted evidence, exercise data disclosure/credential theft/unsafe-AI scenarios, and test restoration and supplier outage handling. Legal notification clocks must be determined per applicable law, role and facts. **Mapping:** CC7.2–CC7.5/CC9.1, optional A1; A.5.24–A.5.30/A.8.13/A.8.14.

### F19 — Supplier and international processing commitments are unresolved

**High; not evidenced.** Model, speech, wearables and infrastructure integrations do not provide contracts, region commitments, subprocessors, onward-use restrictions, deletion guarantees or the allocation of incident/rights duties. User-supplied providers require separate treatment from operator-contracted services.

**Resolve:** W01/W04; classify each relationship, review applicable terms/DPA/transfer mechanism and security evidence, maintain an approved provider profile, propagate obligations and block configurations incompatible with a stated restricted-data policy. Do not infer a BAA/DPA from a provider name or paid tier. **Mapping:** CC9.2, P6; A.5.19–A.5.23/A.5.31/A.5.34; PIMS third parties; AIMS value chain.

### F20 — AI role and intended-use classification is not established

**High; not evidenced/conditional.** Face recognition, medical interaction advice, job-site hazard assessment and external actuation require separate intended-use decisions. Source-available licensing, developer preview and an advisory disclaimer do not settle provider/deployer status, EU territorial scope or regulated-product classification. [LICENSE](../LICENSE#L7) restricts commercial use, so a free/open-source exemption must not be assumed.

**Resolve:** W08 and the [AI plan](05-ai-governance-and-eu-ai-act-plan.md); record supported/forbidden uses, market/role facts, prohibited-practice screening, high-risk analysis and change triggers. Restrict ambiguous sensitive uses pending an accountable determination. **Mapping:** ISO 42001 scope/risk/impact; EU Articles 2–6/Annex I/III, subject to current amendments.

### F21 — Safety outputs overstate certainty

**High; observed design gap.** [SafetyAssessmentSchema](../OpenGlasses/Sources/Services/StructuredVision/Schemas/SafetyAssessmentSchema.swift#L93) assigns `confidence: 1.0` to findings and the whole card regardless of model/image quality; [AssessmentCardView](../OpenGlasses/Sources/App/Views/AssessmentCardView.swift#L117) displays the resulting percentage. Its prompt at line 56 calls the model a certified expert. [SafetyReportPDF](../OpenGlasses/Sources/Services/SafetyAssessment/SafetyReportPDF.swift#L64) can state that no hazards are present, even though a single image/model cannot establish site-wide absence. Disclaimers exist and reduce, but do not remove, contradictory certainty.

**Impact:** automation bias and unsafe reliance on missed/occluded hazards. **Resolve:** W08; distinguish not observed/unknown/verified, remove fabricated confidence/expertise, enforce escalation independent of prompts, and validate with representative expert-labelled scenes and false-negative/overconfidence measures. This is not a claim of a measured model error rate. **Mapping:** PI1 if scoped; ISO 42001 impact/evaluation/information; EU accuracy/human oversight requirements where applicable.

### F22 — AI interaction/output transparency is not demonstrated end to end

**High; partial/conditional.** The app presents itself as AI, but that does not establish the first-interaction experience for voice/HUD/shared recipients or preservation of machine-readable provenance in exported/generated content. The reviewed safety PDF includes a disclaimer but no evidenced model/version/generation provenance design.

**Resolve:** W08; inventory every synthetic output and audience, implement accessible AI interaction notices and applicable generation marking, preserve provenance on export and document technically justified exceptions. Article 50 duties vary by provider/deployer and content type; ordinary private text is not automatically public-interest publishing or a deepfake. **Mapping:** ISO 42001 information/use; EU Article 50; SOC CC2.3 and relevant processing integrity commitments.

### F23 — AI lifecycle evaluation and monitoring evidence is incomplete

**High; partial/not evidenced.** Safety, privacy and face-matching unit tests exist, and deterministic health-warning logic is present. No reviewed release evidence establishes representative field performance, subgroup/language robustness, calibrated uncertainty, data/model rights, model-change approval, harm monitoring, rollback thresholds or AI literacy for staff/operators.

**Resolve:** W08; establish model/system cards, impact assessments, lawful evaluation datasets, quantitative risk-based release thresholds, adversarial evaluations, human oversight training and post-release harm response. Treat prompt/model/provider/routing changes as controlled changes. **Mapping:** ISO 42001 lifecycle/data/impact; SOC CC7/CC8 and optional PI1; relevant EU duties conditional on role/classification.

## 5. Framework conclusions

| Framework | Current assessment | What closes the gap |
|---|---|---|
| SOC 2 | Design evidence exists, but scoped service commitments, organizational controls and operating effectiveness are not established | Agree categories/boundary; close material design gaps; operate controls and retain auditor-selected evidence |
| ISO 27001 | Stronger product controls than management-system evidence; Annex A applicability not formally approved | Risk process/SoA, people/physical/supplier/continuity coverage, internal audit and management review |
| ISO 27701 | Rich sensitive-data processing with incomplete unified lifecycle and role accountability | PIMS scope and roles, processing inventory, privacy impacts, rights/retention/transfer and processor evidence |
| ISO 42001 | Some runtime safety mechanisms, but no demonstrated complete AI management system | Intended-use controls, AI inventory/impacts, evaluation/data lifecycle, transparency, literacy and monitoring |
| EU AI Act | Mixed use cases; no blanket in/out/high-risk conclusion justified | Resolve territorial/operator/intended-use facts and current-law classification; implement already applicable duties and conditional high-risk work |

None of the requested standards is satisfied by adding encryption alone. Equally, absence of corporate policies in a source repository is not proof they do not exist. The first governance milestone is to obtain, verify and reuse actual evidence.

## 6. Standards and legal source register

Sources were checked on 2026-09-04 and the time-sensitive EU sources were rechecked on 2026-09-06. Summaries and crosswalks are original planning analysis, not reproductions of normative standards. Full licensed texts were not provided; exact clause/control mapping and certification scope require edition-specific validation.

| Source | Use |
|---|---|
| [AICPA 2017 TSC, revised points of focus 2022](https://www.aicpa-cima.com/resources/download/2017-trust-services-criteria-with-revised-points-of-focus-2022) | SOC 2 criteria baseline; public catalog is not the full examination guide |
| [AICPA SOC 2 resource page](https://www.aicpa-cima.com/topic/audit-assurance/audit-and-assurance-greater-than-soc-2/) | Service-organization scope and description-criteria resources |
| [ISO/IEC 27001](https://www.iso.org/standard/27001) | 2022 edition and 2024 climate amendment |
| [ISO/IEC 27701](https://www.iso.org/standard/27701) | 2025 second edition PIMS baseline; do not reuse 2019 control numbering silently |
| [ISO/IEC 42001](https://www.iso.org/standard/42001) | 2023 AIMS baseline |
| [European Commission AI Act overview](https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai) | Current application timeline and 2026 AI Omnibus status |
| [Regulation (EU) 2026/1744](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32026R1744) | Official AI Omnibus amending text and revised transition provisions |
| [Commission transparency guidance](https://digital-strategy.ec.europa.eu/en/policies/guidelines-ai-transparency-obligations) | Article 50 application and current guidance |
| [AI Act Service Desk](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-2) | Article navigation; explicitly warns displayed text has not incorporated the Omnibus |

See the AI plan for article-specific sources and the remaining consolidated-text verification. No claim of regulatory approval, certification, a passing audit, actual breach, or fully completed remediation is made.
