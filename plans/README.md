# Compliance assessment and remediation plans

**Assessment date:** 4 September 2026
**Repository baseline:** `b2b5190f2c3a55064242d6bd45a16c006c65d55b`
**Status:** Assessment complete; remediation is in progress; controls and certification have not been approved or attested.
**Location:** `/plans` means this repository's top-level `plans/` directory.

OpenGlasses has substantial security engineering, but the repository does **not establish readiness for SOC 2 attestation or ISO 27001, ISO 27701, or ISO 42001 certification**. Concrete product gaps remain alongside organizational evidence that must be obtained from management. EU AI Act applicability requires decisions for each use case and market; it is not established by a product-wide label.

## Read in this order

1. [Detailed assessment and evidence](00-compliance-assessment.md): boundary, strengths, 23 findings, risk rationale, and source limitations.
2. [Integrated remediation roadmap](04-remediation-roadmap.md): eight workstreams, task acceptance criteria, dependencies, proposed owners, milestones, and evidence collection.
3. [SOC 2 readiness plan](01-soc2-readiness-plan.md): service scope, Trust Services Criteria mapping, examination evidence.
4. [ISO 27001 ISMS plan](02-iso27001-isms-plan.md): management system and Annex A coverage.
5. [ISO 27701 privacy plan](03-iso27701-privacy-plan.md): PIMS, controller/processor responsibilities, data lifecycle and privacy rights.
6. [ISO 42001 and EU AI Act plan](05-ai-governance-and-eu-ai-act-plan.md): intended-use classification, current legal timeline, AI assurance and transparency.

## Implementation checkpoint — 6 September 2026

Implementation has started in the uncommitted working tree at repository HEAD `b790c5c9129faa191eca4311d22c62073d548ad1`. The assessment remains tied to the original baseline above so the original observations are not overwritten by later changes.

| Finding | Implemented checkpoint | Verification completed | Work still required before closure |
|---|---|---|---|
| F01 | Release builds refuse the legacy MCP Glasses and Web HUD cleartext listeners before token/listener creation, clear their persisted opt-ins and suppress the HUD token URL. | Generated the Xcode project, built the app and test bundle with Xcode 27, and passed all 5 `LocalServiceExposurePolicyTests`. | Inspect an installed Release artifact and network behavior; replace permitted Debug LAN use with authenticated encrypted pairing; add token rotation, capability scopes, replay protection and resource limits. |
| F02 | QR context, signed catalog/archive and public remote-pack fetches now use named bounded profiles in Debug and Release. Each redirect hop is resolved and revalidated, mixed/private/reserved public answers are refused, the connection is pinned to an approved numeric peer while retaining the original TLS hostname, and MIME/coding/streamed-byte limits are enforced. Private HTTP pack loading is Debug-only, private-address-only and redirect-free. Sideload consent is exact-request-bound, single-use and five-minute limited before streaming into protected, backup-excluded staging. Installation hashes and re-extracts the exact reviewed bytes. Strict ZIP parsing checks central/local/descriptors/ranges, paths, count, size, ratio, type, actual streamed output and CRC. | The earlier Xcode-beta containment suite passed 13 tests. Xcode-beta compiled and linked the arm64 Debug app and full test bundle containing the new 60-test focused selection. It also produced and inspected the current unsigned arm64 Release simulator artifact (Xcode build `27A5228h`, SHA-256 `ec32f1eb275856c43f36e4cf76d116ffa01d3df384f3e5aa4332e299cc84eb1a`); public bounded-fetch profile/policy strings were present and the Debug-only `internalSkillPack` literal was absent. Two runtime attempts ran zero XCTest cases: a new simulator timed out booting, and an existing booted simulator stalled waiting for workers to materialize. | Execute the focused/full suites on healthy infrastructure; add explicit first-byte/idle and TLS-hostname negative cases; validate the manifest before optional-file materialization; inspect a signed installed Release artifact and collect physical-device network evidence; complete the remaining outbound-route inventory. |
| F03 | Enabled privacy filtering now distinguishes verified no-face results from detector failure; suspended or failed still-image processing returns an opaque replacement, and outbound relay failures/suspension drop frames. | Passed all 27 `OutboundFramePrivacyTests`, including detector, conversion, compositor and publication-race cases. | Verify real background/lock transitions and every recording, RTMP, WebRTC, HUD and AI consumer; add device/CPU-pressure evidence and address exposure between detection intervals. |
| F07 | Medical-mode enable/disable and audit clearing now retain transition/clear records. The protected operation journal preserves corrupt bytes, blocks admission when load/write durability fails, and makes later admissions unavailable after a terminal persistence failure. | The focused medical, journal and routing/privacy suites passed as part of 114 tests, with no failures. | Add authorized audit clearing, retention/export, tamper/rollback checkpoints, locked-data/disk-full/crash integration tests and unknown-outcome reconciliation. |
| F09 | A central medical inference-routing policy now selects a downloaded local model or refuses the request when medical local-only mode is active. Primary, cascade, auxiliary and provider dispatch paths have boundary guards, and web-search cloud fallback is suppressed. | The routing-policy and provider-boundary tests passed as part of the same 114-test run. | Inventory and gate STT/TTS, realtime, translations, memory and tool routes; handle queued/in-flight policy changes; run synthetic network canaries and device traffic verification. |

The earlier focused checkpoint totals **119 tests passed, 0 failures**. The later F02 containment run passed **13 tests, 0 failures**; these counts are stated separately because selected suites may overlap. The final F02 source set and its 60 selected tests compile and link, and the current unsigned Release simulator artifact was built and inspected, while beta-simulator execution remains pending due to the two worker/boot failures described above. This is implementation evidence for the listed seams, not operating-effectiveness evidence, certification, or a legal determination.

## Immediate priorities

| Priority | Work | Findings | Accountable role proposed |
|---|---|---|---|
| P0 | Preserve privacy filtering or stop outbound frames when backgrounded/processing fails | F03 | iOS lead |
| P0 | Enforce the medical “Local LLM Only” setting at provider boundaries | F09 | iOS/privacy leads |
| P0 | Contain cleartext LAN services and unsafe outbound fetches | F01–F02 | Security lead |
| P0 | Decide EU intended uses, biometric/medical restrictions and AI disclosures | F08, F20–F23 | Product lead + legal/privacy lead |
| P0/P1 | Correct cross-store deletion, retention, export and audit lifecycle | F04–F07 | iOS lead |
| P1 | Complete broader data-destination and external-tool permissions | F09–F12 | Security/privacy leads |
| P1 | Harden build/publication controls and establish the integrated management system | F13–F19 | Engineering lead + executive sponsor |

P0 means start immediately and resolve or restrict the affected release/use case before broader distribution. It does not mean every feature is internet-exposed or that a breach was observed. The roadmap defines provisional delivery targets; none are statutory deadlines or certification promises.

## Evidence discipline

- **Observed** means a source-level behavior was verified. **Partial** means some controls exist but do not close the full objective. **Not evidenced** means the reviewed repository cannot demonstrate the organizational control; it does not prove the organization lacks it.
- Unit-test sources and CI configuration were reviewed for the original assessment. The remediation checkpoint generated the Xcode project with Xcode-beta, built the app/test bundle, ran the earlier 119 focused tests and then ran the 13-test F02 containment suite. After archive, consent, streaming staging, review and lifecycle hardening, Xcode-beta compiled the complete app/test bundle but its simulator worker failed before newer test execution. No physical-device exercise, packet capture, penetration test, cloud-console inspection or audit observation period was performed.
- Keep actual personnel records, credentials, incident details, customer data, audit samples, supplier contracts and test captures in a restricted evidence system. These plans contain source-level findings and proposed work only.
- The current Pages workflow publishes the repository root. Treat files committed here as potentially public until an allowlisted publishing directory is implemented (F15). No deployment, commit or push was performed; remediation code and plan updates are uncommitted working-tree changes.

Baseline editions are SOC 2 using the 2017 TSC with 2022 revised points of focus; ISO/IEC 27001:2022 including Amendment 1:2024; ISO/IEC 27701:2025; and ISO/IEC 42001:2023. Framework mappings are planning aids, subject to verification against licensed standards and the agreed audit scope. The [AI plan](05-ai-governance-and-eu-ai-act-plan.md) distinguishes current Commission guidance from article text not yet consolidated for the 2026 AI Omnibus.
