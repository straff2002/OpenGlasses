# ISO/IEC 42001 and EU AI Act analysis and resolution plan

**Date:** 2026-09-06. **Status:** Proposed; no certification or legal compliance determination.
**Owner proposed:** AI/product lead, accountable to executive sponsor, supported by privacy/legal, security, domain experts and an independent evaluator.
**Related findings:** F08/F09/F11/F20–F23 in [the assessment](00-compliance-assessment.md). Shared implementation: W01/W03/W04/W05/W06/W07/W08 in [the roadmap](04-remediation-roadmap.md).

ISO/IEC **42001:2023** is the AI management system standard relevant to the user's request. It provides an organizational governance baseline for developing, providing or using AI. The EU AI Act is legislation with role-, territory- and use-specific duties. Treat these as complementary work programs; a 42001 certificate is not an AI Act approval or a guarantee that an individual system is safe. [ISO 42001](https://www.iso.org/standard/42001).

## 1. Current legal baseline and source limitations

The Commission reports that the **AI Omnibus entered into force on 27 July 2026**, including revised high-risk dates, changes to AI literacy and registration, and other amendments. It would be inaccurate to describe it simply as a pending proposal or use the original high-risk dates without qualification. [Commission enactment announcement](https://digital-strategy.ec.europa.eu/en/news/ai-omnibus-enters-force).

| Provision family | Planning position as of 4 September 2026 | OpenGlasses action |
|---|---|---|
| Original prohibited practices | Applied from 2 February 2025 | Screen actual enabled uses immediately; local-only execution does not remove prohibited-use concerns. |
| GPAI-model governance | Began applying from 2 August 2025, with relevant transitional provisions | Determine whether OpenGlasses merely integrates models or separately becomes a model provider; check legacy-model treatment where relevant. |
| General application and AI transparency | General application/Article 50 date is 2 August 2026 | Treat applicable interaction/output duties as current work, not something to defer until high-risk dates. |
| Annex III high-risk uses | Commission reports revised date of **2 December 2027** | Classify biometric/worker and other sensitive use cases now and plan conditional evidence before affected release/application. |
| Annex I product-related high-risk systems | Commission reports revised date of **2 August 2028** | Obtain medical/product-safety classification if intended use triggers regulated-product assessment. |
| Additional prohibition introduced by the Omnibus | Commission overview identifies December 2026 application for the new non-consensual sexual-content/CSAM generation prohibition | Add to misuse policy/provider review; no such intended feature was established in this repository review. |
| AI literacy | Original rules applied in 2025; Commission reports simplified company obligations in the 2026 amendment | Verify final role-specific duties; retain competence/training as an AIMS control and appropriate human-oversight measure. Do not assert the unamended Article 4 wording is the current company obligation. |

Timeline basis: [Commission AI Act overview](https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai), [Omnibus enactment](https://digital-strategy.ec.europa.eu/en/news/ai-omnibus-enters-force), and [July 2026 transparency guidance](https://digital-strategy.ec.europa.eu/en/policies/guidelines-ai-transparency-obligations). These summaries do not establish an individual deployment's transition entitlement or exact compliance date.

**Material verification limit:** the official [Regulation (EU) 2026/1744 amending text](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32026R1744) and current Commission implementation pages were accessible in the 6 September recheck and support the timeline above. The [Service Desk article pages](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-2) explicitly warn that their displayed article text has not incorporated the amendments, and the [Omnibus FAQ](https://ai-act-service-desk.ec.europa.eu/en/faq?combine=&faq_category_id=99) retains some proposal-era language. Treat article references below as an **issue map requiring consolidated-text validation**, especially literacy, registration, legacy-system relief, provider/deployer responsibilities and marking transitions. Do not grant an exemption, assign a penalty or sign a conformity decision from this draft alone.

**Task AI-01 is concrete:** obtain and archive the applicable consolidated regulation/amending text and current guidance, record version/effective date and affected articles, resolve the discrepancies above, then approve the role/use-case determinations. This is an evidence dependency, not a reason to delay the verified privacy, security or misleading-certainty fixes.

## 2. Territorial and operator-role decision record

Complete this for every distribution/deployment pattern. Facts are not established by this repository.

| Question | Present evidence / working inference | Required determination and owner |
|---|---|---|
| Is a system offered/put into service in the EU, used by an EU business, or producing output used in the EU? | Project has broad language/support and source distribution; actual markets/customers unknown. NZ workspace timezone is not evidence of legal scope. | Legal/product: list markets, distribution channels, users, outputs and contractual operator entities; document territorial conclusion. |
| Who provides the branded AI system? | Maintained app integrates models, tools and UX under OpenGlasses. This may make the distributing entity a system provider for a defined offering. | Identify legal entity, name/trademark, intended purpose and release; confirm under current definitions. |
| Who deploys it professionally? | Could be an employer, clinic, technician business or an individual; repository cannot identify the customer deployment. | Sales/legal: define deployer duties and instructions by customer class; collect onboarding facts. |
| Is any use purely personal and non-professional? | Source allows personal/noncommercial uses. Professional use and offered system responsibilities are separate questions. | Record the specific natural-person use; do not extend a personal-use deployer exclusion to a provider's entire product. |
| Is it a GPAI-model provider? | Integrating cloud APIs or downloading models does not alone establish that role; conversion/evaluation scripts do not prove commercial model placement. | Inventory training/fine-tuning/modification/distribution activities and reassess if models are placed on the market under own responsibility. |
| Does a free/open-source exemption apply? | [LICENSE](../LICENSE#L7) limits commercial use under BSL; README describes source-available, not unrestricted open source. | Do not rely on a FOSS exemption without current-law and license analysis. Even qualifying exemptions have important high-risk/prohibited/transparency limitations. |
| Is a customer changing intended purpose or substantially modifying a system? | Custom tools, model selection, vaults and prompts can materially alter behavior. | Contract/product: record supported customization boundaries and trigger a new role/classification review for consequential changes. |

Role/territorial issue map: [Article 2](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-2) and [Article 3](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-3), read with the amendment caveat above. These are conditional inferences, not conclusions that any identified person already has a particular legal duty.

## 3. Use-case register seeded from current code

The app must not receive one blanket “high risk” or “minimal risk” designation. Separate features, intended purposes and prohibited modifications. A medical subject, physical device or workplace image alone is not sufficient to establish an Article 6 classification.

| System/use | Source evidence | Initial risk analysis, not legal determination | Release decision and evidence required |
|---|---|---|---|
| General voice/chat/translation assistant | [README](../README.md#L5), LLMService, speech/realtime providers | Usually a general assistant use, with interaction/synthetic-output transparency and harmful-answer/privacy risks; not automatically Annex III high-risk. | Record supported use, audience, disclosure and capability limits; test misleading output, sensitive-data routing and multilingual behavior. |
| Face enrollment and recognition of known people | [FaceRecognitionTool](../OpenGlasses/Sources/Services/NativeTools/FaceRecognitionTool.swift#L4), [FaceRecognitionService](../OpenGlasses/Sources/Services/FaceRecognitionService.swift#L14) | Identification against stored templates needs biometric/remote-identification analysis. On-device execution and wearer enrollment do not settle subject rights or classification. | Privacy/biometric assessment, lawful purpose and current Annex III determination before professional/EU deployment; restrict use to the approved purpose. |
| Person notes and social memory | [SocialContextTool](../OpenGlasses/Sources/Services/NativeTools/SocialContextTool.swift#L3) | Remembering facts is not automatically prohibited social scoring. Risk escalates if used to rank people, infer protected traits or make consequential decisions. | Explicitly prohibit unsupported evaluative/eligibility/employment use; implement correction/deletion propagation and misuse tests. |
| Meeting recording and speaker diarization | [Diarization providers](../OpenGlasses/Sources/Services/Diarization/DiarizationProvider.swift), recording/transcription services | Segmenting anonymous speakers differs from identifying people or inferring emotion. Recording/biometric purposes and organizational use require separate review. | Record whether identity/emotion inference exists; do not silently add worker sentiment, emotional state or performance profiling. Provide participant transparency and retention controls. |
| Job-site hazard assessment and field guidance | [SafetyAssessmentSchema](../OpenGlasses/Sources/Services/StructuredVision/Schemas/SafetyAssessmentSchema.swift#L51), [SafetyAssessmentService](../OpenGlasses/Sources/Services/SafetyAssessment/SafetyAssessmentService.swift#L61) | Safety-significant advice merits rigorous assurance. It is not automatically Annex III employment evaluation or Annex I safety-component software. Deployment as worker monitoring/management, critical-infrastructure safety or regulated-product functionality changes the analysis. | Intended-use statement, domain expert evaluation, uncertainty/abstention, human verification and technical restriction of unsupported safety decisions. |
| Personalized health interaction advice and medical exports | [HealthSafetyResponseBuilder](../OpenGlasses/Sources/Services/HealthSafety/HealthSafetyResponseBuilder.swift#L24), [HealthVaultTool](../OpenGlasses/Sources/Services/NativeTools/HealthVaultTool.swift#L42), MedicalExportService | Advice based on conditions/medications may require medical-device intended-purpose review; format/export alone is not the same as diagnostic/therapeutic decision support. A disclaimer or paid medical setting does not settle classification. | Specialist intended-purpose/product assessment; approved clinical boundaries and evaluation. Do not market diagnosis/treatment/medical-device compliance without supporting determination/evidence. |
| Home/remote/tool actions | [SafetySupervisor](../OpenGlasses/Sources/Services/Agent/SafetySupervisor.swift#L48), [NativeToolRouter](../OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift#L111) | Consequential actuation, messaging and data disclosure create misuse and human-oversight risks. Risk classification depends on purpose and downstream system. | Bound capabilities, authenticate actor/target, approve consequential actions, test prompt injection and replay, and provide stop/revoke paths. |
| Local/downloaded and cloud model pipeline | ModelConfig, ModelRoutingPolicy, ModelFallbackChain, `MedicalLLMRoutingPolicy` and installer/conversion scripts | Provider selection changes capability, data exposure and evaluation validity. The 6 September 2026 checkpoint enforces medical local-only selection/refusal at primary, auxiliary and named cloud-provider LLM boundaries; broader routes and network canaries remain open. Local execution is a privacy choice, not a safety certification. | Complete F09 route inventory and final-transport verification; maintain approved model/system cards, artifact/license provenance and evaluation per route before making a product-wide local-only commitment. |

Classification issue map: [Article 6](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-6) and [Commission risk framework](https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai). Under the original Article 6 structure, Annex I treatment requires both a relevant product/safety-component purpose and required third-party conformity assessment. Verify the amended text and sector law before applying this test. For Annex III, document the relevant category and any claimed exception; do not assume a narrow-task exception when the use profiles people. Registration consequences of exceptions require special amendment verification.

### Prohibited-use screen

AI-02 must test each offered feature, model capability, tool integration and intended customer configuration against current prohibitions. For this product, prioritize:

- Emotion inference in workplace/education contexts; distinguish this from speech recognition and diarization, and assess any narrow current-law exceptions explicitly.
- Biometric inference of protected characteristics, prohibited identification/scraping practices, and unsupported law-enforcement surveillance uses.
- Harmful manipulation/exploitation, prohibited social scoring or consequential judgments derived from unrelated social-memory data.
- Non-consensual sexual-content/CSAM generation capabilities introduced through custom models or tools, considering the amended prohibition and its application date.

These are preventive review targets, not allegations that the repository implements each prohibited practice. [Commission overview](https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai). When a use is prohibited, a consent dialog or risk acceptance does not make it permissible. Where not prohibited but sensitive, use a proper classification/impact assessment and constraints rather than treating consent as the only control.

## 4. ISO 42001 management-system gap map

The following is an original planning crosswalk. Use licensed ISO/IEC 42001:2023 for final subclause/control wording and applicability. Existing code safeguards are partial design evidence; none establishes organizational certification.

| Management area | Evidence status | Proposed action and owner | Acceptance/evidence |
|---|---|---|---|
| Clause 4 — Context/scope | Not evidenced organization-wide | Sponsor defines AI products, roles, stakeholders, relevant law and boundaries with W01. | Approved AIMS scope links each AI system, use, affected group and supplier. |
| Clause 5 — Leadership | Not evidenced | Sponsor approves AI policy, accountable owners and escalation authority. | Named decision-makers can stop an unsafe model/use; policy and staff acknowledgment retained. |
| Clause 6 — Planning | Partial code safeguards; formal AI risk/impact process not evidenced | AI/privacy leads integrate individual/group/societal harms, risks/opportunities, objectives and controlled change. | Risk and impact records have mitigation, residual-risk owner, measurable objectives and review trigger. |
| Clause 7 — Support | Tests exist; competence/resources/evidence controls unassessed | Engineering/people leads budget domain expertise and evaluation, teach role-specific competence, control documents and communication. | Training includes assessed competence; evidence versions/retention/access are controlled. |
| Clause 8 — Operation | Partial: routing, tools, safety and health gates exist | AI lead operates impact review, design/data/model/evaluation/release/monitoring procedures. | Every release has purpose, approved model/data provenance, evaluation and oversight evidence. |
| Clause 9 — Evaluation | Unit tests present; management measurement/audits not evidenced | Independent reviewer audits AIMS operation; sponsor reviews outcomes, complaints, risks and objectives. | Audit and management review have inputs, decisions, owners and follow-up; reviewer is independent. |
| Clause 10 — Improvement | Existing engineering plans; formal corrective-action cycle not evidenced | AI/security leads investigate harms and control failures, change controls and verify recurrence prevention. | Corrective actions close only with independent effectiveness evidence. |

### Annex A topic coverage

These group references identify work areas, not a declaration that every normative control is met. AI-03 must map all relevant individual controls, inclusion/exclusion rationale and evidence in the AIMS applicability record.

| Annex group | OpenGlasses-specific work | Gap/owner | Evidence to close |
|---|---|---|---|
| A.2, AI policies | Supported uses, unsafe uses, model/tool selection, sensitive data and user claims | Not evidenced; sponsor/AI lead | Approved policy linked to technical restrictions and tested exceptions |
| A.3, internal organization | Responsible AI decisions, escalation, independent challenge and harm reporting | Not evidenced; sponsor | RACI, escalation drill, concerns register and protection against retaliation |
| A.4, resources | Inventories of model/data/toolchain/compute/human expertise | Partial; engineering lead | Model/artifact/license manifests, evaluation resources and expert competence |
| A.5, impact assessment | Wearer, bystander, biometric subject, patient/clinician, worker and public harms | Not evidenced as complete assessment; privacy/AI leads | Impact studies with affected-party input, mitigation and residual-risk approval |
| A.6, lifecycle | Requirements, design, development, verification, release, monitoring and retirement | Partial; AI lead | System card, release evaluations, versioned prompts/routing/tools, rollback/retirement evidence |
| A.7, data | Provenance, lawful access, quality/coverage, labels, bias and retention for evaluation/training/retrieval | Partial; data/privacy leads | Dataset cards, source rights, expert labels, coverage analysis and deletion lineage |
| A.8, information | User/deployer instructions, limitations, disclosures and incident communication | Partial and F21/F22 gaps; product lead | Accurate accessible notices, preserved output metadata and tested complaint route |
| A.9, use | Purpose restrictions, appropriate human oversight, accountability of consequential action | Partial; product/security leads | Capability policies, abuse tests, stop/confirmation paths and deployment instructions |
| A.10, relationships | Responsibilities across cloud models, downloadable weights, tools, customers and operators | Not evidenced contractually; supplier/legal leads | Approved supplier/customer obligations and change/incident/rights coordination |

## 5. EU obligation-to-work map

This matrix distinguishes work warranted now from conditional high-risk obligations. Article numbering is a navigation aid pending AI-01's amended-text check; applicability, exceptions, transition relief and precise evidence periods must be recorded per system.

| Duty family | Applicability decision | Proposed implementation/evidence |
|---|---|---|
| Scope/role/prohibited practice, Articles 2–5 | Territorial facts, role and actual functionality first | AI-01/02: market/role register, prohibited-use decisions and enforced restrictions; literacy/competence under current-law plus AIMS policy |
| High-risk qualification, Article 6/Annex I/III | Feature/use/sector-specific; no blanket app classification | AI-02: documented determination, sector specialist input where relevant, version/date and change triggers |
| Risk/data/technical documentation, Articles 9–11 | If corresponding high-risk duties apply | AI-03/04: lifecycle risk register, dataset governance, intended-purpose/architecture/limitations and technical dossier |
| Records, information, human oversight, Articles 12–14 | If corresponding high-risk duties apply | W05/AI-05/06: reconstruct consequential decisions with minimal data, clear deployment instructions and effective override/stop/competence |
| Accuracy/robustness/security, Article 15 | If corresponding high-risk duties apply; sensible assurance for all consequential features | AI-04: risk-based evaluated metrics, abuse/failure tests, calibrated uncertainty and field monitoring |
| Provider/deployer duties, Articles 16–27 | Separate roles, modification, representatives and applicable oversight/impact duties | AI-01/03: responsible entity, quality process, supplier/customer agreements, appropriate deployer instructions; Article 27 fundamental-rights assessment only for its applicable deployer classes |
| Standards/conformity/registration, Articles 40–49 | Determine applicable assessment route, harmonised references and amendment effects | AI-07: evidence dossier, required external involvement, declaration/marking/database steps only when legally applicable |
| Interaction/synthetic content, Article 50 | Provider/deployer, audience and output-specific | AI-05: accessible interaction notice and applicable machine-readable marking; deepfake/public-interest publication rules assessed separately |
| GPAI-model duties, Articles 51–55 | Only if relevant model-provider role/classification established | AI-01/03: obtain upstream information; if own model role exists, address documentation, copyright/training-summary and any systemic-risk duties under current rules |
| Post-market/serious incident, Articles 72–73 | Conditional duty/role/classification; ordinary incident process applies as policy regardless | AI-06: harm intake, monitoring, versioned traceability, escalation and legally determined reporting thresholds/clocks |

Source navigation: [AI Act official text](https://eur-lex.europa.eu/eli/reg/2024/1689/oj/eng), [Service Desk Article 6](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-6), [Article 50](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-50), and [Commission current transparency guidance](https://digital-strategy.ec.europa.eu/en/policies/guidelines-ai-transparency-obligations). The original official text was not treated as a consolidated post-Omnibus text.

### Transparency implementation details

Inventory conversational voice, chat, HUD cards, translated captions, summaries, safety/medical exports and synthesized audio. For each, record producer, audience, generation method, destination, and whether the user could reasonably misunderstand origin.

Where Article 50 applies, distinguish informing someone they interact with AI from marking synthetic output in machine-readable form. A visible “AI” label alone does not demonstrate robust machine-readable marking. Conversely, not every private generated paragraph is a public-interest publication, every synthetic voice a deepfake, or every face detector an emotion/categorization system. Determine exceptions by actual function and current guidance. Information should be accessible and timely for voice-first and visually impaired users. [Article 50](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-50).

Proposed design: store an output record with generation status, system/provider/model revision, prompt/policy version, creation time and sources/human-review status as appropriate. Preserve interoperable provenance through supported export formats; adopt an appropriate marking scheme after technical review rather than inventing a proprietary metadata field and declaring legal compliance. Assess provider-supplied markers and whether transformation strips them. Never put raw health data or credentials in provenance metadata. Validate applicable exceptions and any transition period in AI-01.

### Standards and conformity

The EU route depends on the system and sector. Do not automatically commission a notified body, apply CE marking, register every assistant feature or claim all ISO 42001 controls are harmonised requirements. Verify the current Official Journal references and applicable conformity route. The Commission explains that harmonised-standard references in the Official Journal are central to the relevant presumption-of-conformity mechanism; an unrelated ISO certificate is insufficient. [Commission standardisation guidance](https://digital-strategy.ec.europa.eu/en/policies/ai-act-standardisation).

## 6. Executable AI work packages

| Package | Priority / owner / dependencies | Deliverables | Acceptance and evidence |
|---|---|---|---|
| AI-01 — Law, role and market facts | P0; legal/product; W01 | Current-law register resolving Omnibus changes; legal entities/territory/roles; provider-versus-model-provider decision | Dated signed determination cites operative text; unresolved legal points have restricted release scope and an owner; no unsupported blanket exemption |
| AI-02 — Purpose and impact decisions | P0; AI/privacy/domain lead; AI-01 and data inventory | System cards, prohibited-use screen, feature-level Article 6 assessment, DPIA/AI impact assessments for biometrics/health/worker/safety uses | Every sensitive enabled use has approved intended purpose, excluded uses, affected-person impacts, mitigations and change trigger; policies have enforceable settings/tool restrictions |
| AI-03 — AIMS and supply-chain evidence | P1; sponsor/AI lead; W01/W06 | AIMS policy/RACI/applicability, model/dataset/tool manifests and supplier/customer responsibility matrix | All releases link rights/provenance, reviewed changes and accountable approvals; independent audit can reconstruct controls |
| AI-04 — Safety and robustness gates | P0 wording/uncertainty fix; P1 evaluation; AI/domain lead | Remove constant confidence/expertise; create representative expert-labelled corpora; define thresholds and adverse-case tests | No fabricated 100% confidence or unqualified absence-of-hazard claim; critical failures block release; evidence includes provider/model/routing configuration and domain review |
| AI-05 — Transparency and oversight | P0 for applicable existing EU duties; product/security; AI-01/W04/W05 | Accessible disclosures, provenance/marking, safe confirmation and stop/revoke flows | Voice/HUD/chat/export tests preserve the approved notices/marking; malicious content cannot impersonate human approval; all external effects respect authority |
| AI-06 — Operations, competence and harm response | P1; AI/operations; W05/W07 | Role-specific competence checks, complaint/redress route, incident playbook, monitoring and model/tool kill switch | Tabletop demonstrates detection→triage→restriction→investigation→corrective action; any legal report obligation is determined from current law and facts |
| AI-07 — Conditional market-access evidence | Before the affected legal release/application deadline; legal/quality lead; AI-01–06 | High-risk dossier/conformity route and applicable declaration/registration/representative/post-market arrangements, if required | Independent competent review approves required evidence before covered distribution; non-applicability has a documented reason, not a blank field |

No implementation package is completed by creating this document. The initial roadmap aims for internal readiness evidence within 90 days; legal applicability and independent certification timelines are separate.

## 7. Evaluation plan tailored to OpenGlasses

Tests present in the repository include safety, health, face ambiguity/matching, model routing and prompt-injection checks. These are useful building blocks, not evidence that field accuracy, fairness or human reliance has been validated. Use consented/synthetic/licensed data; production user recordings are not automatically authorized as training or evaluation material.

| Evaluation family | Representative scenarios | Measures and release rule |
|---|---|---|
| Hazard vision | Occluded hazards, poor lighting, motion blur, misleading perspective, incomplete site views, unrelated scenes, fake safety signage | Expert-scored false negatives, unsupported certainty and abstention; high-severity cases have explicit minimum gates approved before running tests |
| Health advice | Unknown medicines, misspellings, incomplete vaults, contradictory context, multilingual questions, emergency symptoms | Deterministic warnings cannot be downgraded; source/uncertainty/escalation retained; specialist review of potentially harmful errors |
| Face recognition | Similar-looking people, unknown people, lighting/camera differences, aging, varied skin tones/ages and consented demographic coverage | False matches/nonmatches and unknown-person rejection at fixed thresholds; do not infer demographic attributes from users merely to measure fairness |
| Voice and human approval | Noisy site, different accents/languages, bystander speech, replayed approval, wearer disengagement, device lock | Unauthorized action rate must be zero in the defined critical test suite; changed payload/actor/session invalidates approval |
| Injection/data disclosure | Malicious QR/manual/web page/tool definition, sensitive health/name/location result, external write disguised as read | No policy bypass, secrets or disallowed sensitive data leaving the boundary; quarantine excludes malicious metadata |
| Routing/reliability | Local model failure, memory pressure, cloud outage, model/provider update, fallback to weaker route | Local-only remains local; no silent downgrade of privacy or tool authority; selected route/version accurately recorded |
| Communication/accessibility | Voice-only first interaction, HUD truncation, screen reader, exported report, shared synthetic output | Users can identify AI origin and limitations; provenance survives intended export; no fabricated certainty or hidden consequential action |

Do not set a universal “95% accuracy” or claim statistical fairness from small unit fixtures. Record population, sample size, label agreement, known limitations, uncertainty intervals where appropriate and acceptance rationale. Separate factual content correctness from processing-integrity guarantees such as preserving sources and never reporting an unexecuted action as completed.

## 8. Required evidence and review triggers

Maintain in the restricted evidence system:

- AI system register with purpose, owner, version, markets, affected people, provider/deployer role, legal classification and limitations.
- Model/dataset/tool cards with source/license/provenance, access/retention constraints, known capabilities and evaluation evidence.
- AI/privacy impact assessments, legal applicability record, prohibited-use decisions and approved residual risks.
- Evaluation reports, consequential-action trace schemas, human-oversight design and accessible notices/output-marking evidence.
- Release approval/rollback evidence, supplier obligations, competence records, complaints/incidents, internal audit and management review.

Reassess when adding a country/customer sector, enrolling biometric subjects, adding health or worker decision support, changing intended purpose, adding an external tool or action, changing a model/provider/prompt/routing policy, changing data recipients, learning of significant harm, or changing applicable law. Review dormant features before enabling them; release flags are part of the assessed configuration.

**Completion gate:** named owners accept scope/classification and impacts; applicable duties are addressed; technical findings pass integrated tests; operational controls produce evidence; an independent reviewer verifies closure. ISO 42001 certification and any required EU conformity activities then follow the applicable independent assessment process. Neither is claimed here.
