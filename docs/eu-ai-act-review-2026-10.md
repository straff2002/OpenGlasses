# EU AI Act review of Avenkin, October 2026

**Date:** 2026-10-06. **Code reviewed:** `main` at `f3d90a0d` (build 463). **Law as of:** 6 October 2026.
**Status:** engineering review. It states positions so that decisions can be made; it is not legal advice and makes no compliance determination. Counsel should confirm the four decisions in §6 before any EU release relies on them.
**Builds on:** [EV](plans/EV-ai-governance-and-eu-ai-act.md) (6 Sept 2026), which deliberately stopped at an issue map. This review takes the positions EV left open, against the law as it now stands and the code as it now is.

## 1. Where the law stands

Regulation (EU) 2024/1689, as amended by the Digital Omnibus on AI (Regulation (EU) 2026/1744, in force 27 July 2026).

| Provision | Applies | What changed in 2026 |
|---|---|---|
| Art. 5 prohibited practices | Since 2 Feb 2025 | New prohibition on systems that foreseeably generate non-consensual intimate imagery or CSAM, from 2 Dec 2026. Not relevant: Avenkin has no image, video or voice generation. |
| Art. 4 AI literacy | Since 2 Feb 2025 | Softened to an obligation of means: providers and deployers take reasonable measures to support staff AI literacy. |
| Art. 50 transparency (chatbots, synthetic content, emotion recognition, deepfakes) | **Since 2 Aug 2026** | Unchanged by the Omnibus. Final Commission Guidelines adopted 20 July 2026. Code of Practice on transparency of AI-generated content published 10 June 2026, found adequate 8/9 July 2026. One grace period: the Art. 50(2) machine-readable marking duty runs from **2 Dec 2026** for systems placed on the market before 2 Aug 2026, and a watermark-interoperability milestone is set for 2 Feb 2027. |
| Annex III high-risk (biometrics, employment, emergency triage and others) | **2 Dec 2027** (was 2 Aug 2026) | Draft classification guidelines published 19 May 2026; final version expected around September 2026 and not confirmed adopted at the time of writing. |
| Annex I high-risk (AI in regulated products, including medical devices) | **2 Aug 2028** (was 2 Aug 2027) | |
| GPAI model duties, Chapter V | Since 2 Aug 2025 | Not Avenkin's role (see §2). |

Penalties: up to EUR 35 m or 7 % of turnover for Art. 5, EUR 15 m or 3 % for the rest, with SME proportionality.

## 2. Who Avenkin is under the Act

- **Provider:** Skunkworks NZ Ltd, New Zealand. The Act applies to a provider placing an AI system on the EU market regardless of where it is established (Art. 2(1)(a)). For a high-risk system a non-EU provider must also appoint an EU authorised representative (Art. 22). Not needed for Art. 50-only systems.
- **Not a GPAI model provider.** Avenkin integrates Claude, Gemini, OpenAI, Mistral, DeepSeek and downloads open models from Hugging Face at the user's request. It trains and places no general-purpose model. The fingerspelling model is a narrow task model.
- **No open-source exemption** (Art. 2(12)). The licence is BSL 1.1 and the app is sold. Art. 2(12) also never covers Art. 5 or Art. 50 systems.
- **Personal users** are outside the Act as deployers (Art. 2(10)). This removes *their* duties, not the provider's. Avenkin's own obligations for a feature do not change because the buyer is a private individual.
- **Business users** (Field Assist editions, Medical Compliance, organisation profiles) are deployers (Art. 3(4)). Today their only live duties are Art. 4 literacy and Art. 50(3)/(4) disclosure where applicable. Art. 26 deployer duties attach only to high-risk systems and only from 2 Dec 2027.
- **EU presence is undetermined in the repo.** `OpenGlasses/Info.plist` records that the app is not sold in France (encryption declaration). App Store territories live in App Store Connect. The App Store channel became ready on 24 Aug 2026, which is **after** 2 Aug 2026: if the first EU availability was after that date, the Art. 50(2) grace period does not apply and marking has been due since launch. **Decision 1 (§6): record the EU storefront list and first-availability date.**

The Act's territorial scope has no "personal developer" carve-out. If the app is downloadable in any EU storefront, every finding below is live for that build.

**TestFlight is not a safe harbour.** Art. 2(8) excludes testing and development before placing on the market, but expressly not "testing in real world conditions", and an external beta used on real people is that. If any tester is on an EU storefront, treat Art. 50 as live for that build now. The calendar, not the distribution channel, is what defers the December 2027 items.

**One binary, every storefront.** The App Store ships the same build to all territories, so an "EU build" means a runtime gate on the Apple ID storefront (StoreKit `Storefront.current`, available in TestFlight), not a separate binary. Gate on storefront rather than location; a traveller is not a case worth engineering for, and a documented storefront boundary is the kind of concrete, coherent limitation of use the draft guidelines ask for.

## 3. Findings by feature

Severity: 🔴 a live or near-certain obligation with no current answer; 🟠 a classification or implementation gap to close by a dated milestone; 🟢 reviewed, no action beyond hygiene.

### 3.1 🔴 Face recognition is a remote biometric identification system (Annex III 1(a), high-risk from 2 Dec 2027)

What the code does (`FaceRecognitionService.swift`, `FaceRecognitionTool.swift`): the wearer enrols a person by name from a camera still; a Vision feature print of the face crop is stored in `Documents/known_faces.json`; once the model turns recognition on, every 15th glasses frame is matched against all enrolled prints and a confident match is spoken ("That's Maria") and logged to `brain.sqlite` with place, latitude, longitude and time.

Classification. The draft guidelines (¶129–144) set three conditions, and all three are met:
1. **Purpose is identification**, one-to-many against stored templates. The verification carve-out needs a person claiming an identity the system confirms; nobody claims anything here.
2. **Without active involvement, typically at a distance.** The person in front of the glasses does nothing; the guidelines say being informed is not enough, the person must "actively and consciously present themselves" to a sensor (¶140). Body-worn cameras are an express example of remoteness (¶142).
3. **A reference database**, which "may consist of biometric data of one or many individuals" (¶143).

Consequences:
- Not prohibited. Art. 5(1)(h) bans real-time RBI in public only for law enforcement. The guidelines note that Annex III 1(a) is "not limited to RBI in publicly accessible spaces".
- High-risk from 2 Dec 2027 for any EU build that contains the capability. Being off by default does not help; the classification follows the intended purpose of the system placed on the market. There is no accessibility or assistive exemption in Annex III or in the guidelines.
- What high-risk means for a micro-company: Arts. 9–15 (risk management, data governance, technical documentation, logging, instructions for use, human oversight, accuracy and robustness), a quality management system (Art. 17, simplified for microenterprises under Art. 63), **third-party conformity assessment by a notified body** for Annex III point 1 while no harmonised standard is cited (Art. 43(1)), CE marking, EU database registration (Art. 49), an authorised representative (Art. 22), post-market monitoring and serious-incident reporting (Arts. 72–73).
- Separately and already in force: bystander face templates are GDPR Art. 9 biometric data. The household exemption does not cover a camera pointed at public space (CJEU *Ryneš*), so an EU personal user has no lawful basis for enrolling strangers, and `privacy.html:231` currently delegates that problem to them.

Gaps in the current implementation that matter regardless of the classification decision:
- `Config.faceRecognitionEnabled` defaults **on** and has no Settings UI; the only user switch is the Tools list.
- Enrolment has no consent step and no subject-facing notice; the tool is classed `.localMutation` with no confirmation.
- The ambiguity message tells the user to "remove the one that's wrong in Settings" but no screen lists enrolled faces.
- Organisation profiles cannot lock the feature off.
- The tool description claims "faces are recognized automatically when the camera is active", which overstates the behaviour and would be read as the intended purpose.
- `PrivacyInfo.xcprivacy` declares no biometric data type.

Position: **face recognition can stay available to everyone, opt-in, until 2 December 2027, and must be unavailable on EU storefronts from that date** unless the company carries a notified-body conformity assessment (Decision 2). Nothing in the Act regulates it before then except Art. 5(1)(h), which reaches only law enforcement. A user's own opt-in relieves the user (Art. 2(10)); it never relieves the provider, so no consent sheet keeps it lawful in the EU after that date. The interim engineering work in §5 should land now for GDPR hygiene and to establish the intended-purpose record.

### 3.2 🔴 Assistive "Social" mode is an emotion recognition system (Art. 5(1)(f) today; Annex III 1(c) from 2 Dec 2027; Art. 50(3) today for business users)

What the code does (`AssistiveRouter.swift:51-57`, `AssistiveModeService.swift`): when Assistive Mode is on and the wearer's words mention a person or a feeling, a camera still is sent to the cloud model every six seconds with the prompt "Help the user understand the emotional state of the person they are looking at", urgency low = calm, medium = unease, high = distress, and the result is spoken.

Classification. Art. 3(39) defines an emotion recognition system as one that identifies or infers emotions or intentions of natural persons on the basis of their biometric data. A facial image processed to infer a person's state is biometric data under Art. 3(34). The draft guidelines' own wearable example (¶ on point 1(c)): a smart-watch mood monitor is emotion recognition and "it is not relevant whether the emotion recognition results are disclosed solely to the specific user". The contrast case they give is "the mere observation that a person is smiling", which is not emotion recognition.

Consequences:
- **Art. 5(1)(f) prohibits** placing on the market, putting into service for this purpose, or using an emotion recognition system "in the areas of workplace and education institutions", except for medical or safety reasons. The ban is live now, carries the top fine tier, and no consent cures it. Avenkin ships this mode in the same binary as Field Assist, a workplace product, with no gate between them. The draft guidelines treat a broadly positioned system whose capabilities make a high-risk use "feasible and reasonably foreseeable" as intended for it, and say disclaimers alone do not narrow intended purpose.
- The medical exception is narrow. An assistive tool for neurodivergent wearers may fit it, but only if that is the system's stated intended purpose, which for a general assistant with a "Social" sub-mode it is not. Taking that route also turns the feature into a medical-purpose product, with MDR and Annex I questions attached.
- Outside the workplace it is Annex III 1(c) high-risk from 2 Dec 2027, with the same conformity consequences as §3.1 (notified body while no standard exists).
- **Art. 50(3), live since 2 Aug 2026:** a *deployer* must inform the people exposed that the system is operating, on first exposure, orally or by icon. A business user of Avenkin pointing Social mode at a colleague or customer has this duty today and the app gives them nothing to meet it. A personal user is outside Art. 50(3) by Art. 2(10).
- The feature appears nowhere in `privacy.html`, `AIFeatureRegistry`, or the EV use-case register.

Position: **redesign out of the definition** (Decision 3), which keeps the feature for every user in every region. Until then, personal opt-in outside a workplace is lawful today; the prohibition turns on the intended purpose including workplaces, which the gate below addresses. The guidelines' line between "observe" and "infer" is the design target: a Social mode that reports visible facts ("they are smiling, leaning away, not making eye contact, speaking fast") without labelling an emotional state or an urgency band stays outside Art. 3(39) while keeping most of the accessibility value. If the emotional-state inference is kept, it must be unavailable when any Field Assist edition or organisation profile is active, carry copy that it is not for workplace or education use, be added to the registry and the privacy notice, and expose a wearer-triggered spoken notice for Art. 50(3). Even then it is high-risk in December 2027.

**Note, 7 October 2026: Decision 3 taken and built.** The company took the observe-only redesign on 2026-10-07, and it is built as [Plan HR](plans/HR-social-mode-observe-only.md). Social mode's prompt now asks only for visible cues (expression as a shape, gaze, posture and distance, gestures, what the person is doing) and forbids naming an emotion, a mood, an intention or a diagnosis. A deterministic word filter (`EmotionLabelFilter`) checks every answer; one that names a feeling is never spoken, is re-asked once with a stricter instruction, and if the second answer names one too the wearer hears "I can describe what I can see, not how they feel." The urgency field is kept, but redefined in observable terms about the situation (nothing needs a response; the person is addressing or waiting for you; the person is signalling urgently), not as a band of the person's state. `AIFeatureRegistry` now screens the feature `.none` with a note. The workplace and Field Assist refusals stay until a device run shows the filter holds on real frames; lifting them is the recorded follow-up. Art. 50(3) no longer arises for deployers, and the deployer sheet says so.

### 3.3 🟠 First-aid triage via `vision_assess` (Annex III 5(d) decision needed)

What the code does (`FirstAidTriageSchema.swift`, `VisionAssessTool.swift`): the model reports responsiveness, breathing, severe bleeding and visible injuries from a frame; deterministic code picks the tier and the instruction ("Not breathing: start CPR now and call emergency services"). The card says advisory only; a once-per-session spoken disclosure exists; unobserved vitals abstain.

Annex III 5(d) covers systems used "to evaluate and classify emergency calls" or "to establish priority in the dispatching of emergency first response services ... as well as of emergency healthcare patient triage systems". The draft guidelines (¶334–335 and examples) frame this around emergency departments, dispatch and crisis lines; their closest example is a crisis chatbot that "assesses severity and urgency" and "directs intervention responses", and they add that a triage system that is a medical device goes to Annex I instead. A consumer first-aid prompt for a bystander is not obviously inside that, but a Field Assist edition sold to employers as a first-response aid at work is a professional triage use and a worse fit for the argument.

Also live today: `firstAidAssistEnabled` does not guard this path (only the `first_aid` coaching tool checks it), so the registry's claim that the switch disables "camera triage" is false.

Position: keep for personal use with the current disclaimers; make the switch actually gate `vision_assess kind:first_aid_triage`; record a written intended-purpose statement that it does not prioritise or dispatch; and decide (Decision 4) whether the vertical stays in business editions, where the safer answer by December 2027 is to remove it or carry the classification.

### 3.4 🟠 Clinical Assistant persona and Skin Check (MDR first, AI Act second)

The persona prompt (`Config.swift:1259-1288`) asks for a "differential diagnosis ranked by likelihood" from skin lesions and malignancy features; the Skin Check template and playbooks do the same. It is installable without the Medical subscription. This is medical device software by intended purpose under the MDR (software that provides information for diagnosis), which is not an AI Act question until Annex I applies in August 2028, but it is a CE-marking question now. Position: either strip diagnosis-ranking language and keep documentation support, or treat it as a device. The AI Act adds nothing until 2028, so this is a note, not an action in §5.

### 3.5 🟠 Art. 50(1): telling people they are dealing with an AI

What exists: onboarding ("Powered by AI", "may not always be accurate"), an "AI-generated" capsule on chat replies, and the once-per-session spoken line for structured-vision assessments. EV recorded chat and live-session disclosure copy as still owed; it still is.

What the final Guidelines ask: disclosure "from the start of the first interaction", clear and distinguishable, with the "obvious" exception read narrowly and a higher bar where people with disabilities are a foreseeable audience. Avenkin has an Accessibility tier aimed at blind and neurodivergent users, so the exception should not be relied on, and the disclosure must work by voice. An onboarding screen a blind user may not have read is weak evidence.

Third parties. Where the app's output is addressed to someone other than the wearer the obligation runs to them:
- **Live translation spoken aloud** through glasses or the phone speaker (`live_translate`, `OpenGlassesApp.swift:2490`) reaches the other party with no disclosure. Note that `LiveTranslationService.translate()` is a stub that returns "[src→tgt] text" without translating; the feature is broken as well as undisclosed. Two-way translated captions are text on the wearer's phone and carry no label either.
- **Messages the wearer sends** (`send_message`, `send_via`, report delivery) are sent by a human who approved and tapped Send; Art. 50(1) does not reach the recipient. The Guidelines' "AI agents must reveal on whose behalf they act" language applies to the unattended paths: the organisation `endpoint` POST and gateway `execute` messaging. Both are machine-to-machine or behind the deployer's own systems; low exposure, but note it in the deployer sheet.

Position: add a spoken first-session disclosure in voice mode and Gemini Live / OpenAI Realtime; add a one-line spoken or on-screen notice when a translation mode starts; fix or remove the translation stub.

### 3.6 🟠 Art. 50(2): machine-readable marking of synthetic output

Due now if the EU launch post-dates 2 Aug 2026, else by 2 Dec 2026. The duty is on the provider of the system "to the extent technically feasible", with exemptions for short outputs, assistive editing, text not substantially altered, and machine-to-machine output; the Guidelines put text under about 150 words at metadata-only, and free-form text that cannot carry metadata at a single technique. The Code of Practice's layered approach (metadata plus watermark or fingerprint) is the voluntary benchmark.

Output by output:
- **Chat and voice replies, HUD text:** generated text consumed in the app. Short, in-app, and already labelled on screen. No marking action beyond keeping the label.
- **TTS audio:** generated by iOS, Kokoro or ElevenLabs, played from memory, never written to a file. The Guidelines give no general ephemeral exemption, but there is nothing to mark. Keep it that way. When `captureIncludesAssistantVoice` (default off) mixes the assistant's voice into an RTMP stream, WebRTC or a recording, the audio persists unmarked. Write a marker into recording metadata when that toggle is on, and leave it off by default.
- **PDF and JSON exports** (safety assessment, field session, job transcript, agent archive): already carry `AIProvenance` (PDF Creator and Subject, footer line, `is_ai_generated` JSON). Good. Move the PDF side onto standard XMP fields rather than only the Info dictionary, so a detector finds it.
- **Medical export** (FHIR, PDF): no marking at all. Add the same provenance block.
- **Saved notes, meeting summaries, chat transcript shares:** plain text with at most an "AI" speaker label. Meeting summaries are keyword extraction, not a model; still text produced by an automated system and worth a header line. Chat shares should state the model and the date in the header.
- **AI-drafted SMS / WhatsApp / email bodies:** human-edited, human-sent, usually under 150 words, with no metadata channel. Treat as exempt and document why.
- **Images and video:** Avenkin generates none. Assessment-card region boxes are overlays on a photo, not synthetic imagery.

Position: a half-day of engineering (recording marker, medical export provenance, XMP on PDFs, note headers) plus a written feasibility record covers this proportionately for a company of this size.

### 3.7 🟢 Speaker diarization and naming is not biometric identification

Deepgram returns per-session cluster ids; the app maps an id to a typed name in UserDefaults. There is no voiceprint, no embedding, no cross-session voice matching. A name attached to "Speaker 1" simply re-attaches to whatever Deepgram labels id 0 next time. That is outside Annex III 1(a). Two hygiene points: `AIFeatureRegistry` tags it `.biometric`, which overstates it and would mislead a classification file; and `RecordingTranscriber.swift:30` uploads saved recordings to Deepgram batch whenever a key is present, even with the diarization toggle off. Bystander audio to Deepgram is a GDPR matter and the settings copy handles it honestly.

### 3.8 🟢 Business deployment today, 🟠 the designs on the shelf

Built today: job allocation inbound from the office, work records and transcripts outbound by organisation rule, a billable clock, help requests that can send location, remote-expert live view when the organisation runs a relay, and gateway remote-invoke with capture off by default. No performance scoring, ranking, or continuous location, caption or camera feed to the organisation exists, so nothing reaches Annex III 4(b).

Plans FT and FU design an on-shift position indicator, a status board and "performance figures: first-visit fix rate, time on site, repeat visits". The draft guidelines (¶273–275) read 4(b) as an autonomous category covering systems that monitor *or* evaluate workers, with "performance" including quantitative productivity measures. Metrics derived deterministically from signed reports are an employment-law and GDPR matter; the moment a model scores, ranks or allocates on them it is high-risk in December 2027. Design rule to adopt now: AI output is never an input to a performance figure or an allocation decision.

Deployer obligations a business customer carries today: Art. 4 literacy (obligation of means) and Art. 50(3) if they use Social mode. From December 2027, if any high-risk feature remains in their edition: Art. 26 (use per instructions, human oversight, log retention of at least six months, inform workers' representatives before putting it into use, Art. 26(7)). None of this is written down for them anywhere; `docs/field-assist-vault-guide.md` has no AI Act content.

### 3.9 🟢 Other screens

- **Art. 5 otherwise:** no social scoring (social memory stores facts, scores nothing), no manipulation, no untargeted scraping (enrolment is one face at a time by the wearer), no biometric categorisation (no code infers ethnicity, religion, politics, orientation, age or gender; the clinician types the Fitzpatrick type).
- **Emotion-aware TTS:** sentiment of the assistant's own reply text; and the flag is read nowhere but the Settings toggle, so it is inert. Not emotion recognition. Remove the dead toggle or wire it. **Done 2026-10-07 ([HQ](plans/HQ-eu-ai-act-second-tranche.md) item 8):** the "Expressive Voice" toggle and its `Config` accessor are gone; the old `emotionAwareTTSEnabled` defaults value is left in place, unread.
- **Accessibility preset "describe expressions":** observation, not inference. Fine, and the model for §3.2's redesign.
- **HECA safety assessment:** hazard checklist of a scene, no per-person analysis; not an infrastructure safety component. Provenance already attached.
- **Body pose, Live Coach, fingerspelling:** landmarks and posture, nothing stored, no categorisation. `check_form` reads the raw frame and analyses whichever body Vision returns first; outside the Act but worth a wearer-only guard.
- **Art. 50(4) deepfakes:** no generation. The ElevenLabs voice id is free text, so a user can paste a voice cloned elsewhere; a line in the privacy notice that voice choice is theirs is enough.
- **Agent mode and tool authority:** no AI Act duty attaches to a non-high-risk system's autonomy, but the oversight design is the evidence Art. 14 would want later. Known gaps from the audit: `AIFeatureGate` is not enforced at the router, calendar writes and non-lock HomeKit actions run unconfirmed with Agent Mode off, and voice "stop" halts speech but not running tools.
- **GPAI:** downstream integrator only; upstream Art. 53 documentation is the model vendors' job.

## 4. Personal and business users side by side

| Feature | Personal user in the EU | Business user in the EU (deployer) | Avenkin as provider |
|---|---|---|---|
| Face recognition | No AI Act duty on the user; GDPR Art. 9 exposure for enrolling strangers | Deployer of a high-risk system from Dec 2027 (Art. 26); GDPR Art. 9 now | High-risk provider from Dec 2027 if the capability ships in EU builds (§3.1) |
| Assistive Social mode | No AI Act duty; prohibition does not bite at home | **Prohibited now** at a workplace or school; Art. 50(3) notice to exposed people now | Placing a workplace-foreseeable emotion recognition system on the market risks Art. 5(1)(f) now; Annex III 1(c) from Dec 2027 (§3.2) |
| First-aid triage | None | Possibly Art. 26 from Dec 2027 if classed 5(d) | Classification decision owed; switch must gate it (§3.3) |
| Voice assistant generally | None | Art. 4 literacy support | Art. 50(1) disclosure now (§3.5); Art. 50(2) marking now or by 2 Dec 2026 (§3.6) |
| Live translation aloud | None | Same as above | Art. 50(1) to the other party (§3.5); fix the stub |
| Diarization, captions, Memory Rewind | GDPR for bystander audio | GDPR, employment law | No AI Act classification (§3.7) |
| Field Assist reports and Office | n/a | Employment law; keep AI out of performance figures | Annex III 4(b) only if the shelved designs ship with model-derived evaluation (§3.8) |
| Clinical persona | n/a | MDR deployer (clinic) | MDR now; Annex I Aug 2028 (§3.4) |

## 5. Actions in order

**Before the next EU-visible release**
1. Face recognition: default `faceRecognitionEnabled` off with an explicit opt-in and honest copy; a Settings screen that lists, removes and disables; an enrolment confirmation naming the person and stating they are not told; org-lockable key; truthful tool description; `PrivacyInfo.xcprivacy` biometric entry. Everyone keeps the feature. Build the storefront gate as a pure, tested policy now (storefront country in, per-capability availability out) and switch it on for EU storefronts in a release before 2 Dec 2027 unless Decision 2 goes the other way.
2. Social mode: implement the observe-only redesign or, at minimum, hard-gate it off under any Field Assist edition or organisation profile, add workplace/education copy, add it to `AIFeatureRegistry` and `privacy.html`, add a spoken Art. 50(3) notice the wearer can trigger.
3. Spoken first-session AI disclosure in Direct voice mode and both live modes; a start-of-mode notice for translation; fix or remove the translation stub.
4. Gate `vision_assess kind:first_aid_triage` behind `firstAidAssistEnabled`; correct the registry's claim; write the intended-purpose line.
5. Deepgram batch path honours the diarization toggle; registry drops `.biometric` from diarization.

**By 2 December 2026 (or immediately if the EU launch post-dates 2 Aug 2026)**
6. Art. 50(2): recording marker when assistant voice is captured; provenance on medical exports; XMP on PDFs; header lines on notes, meeting summaries and chat shares; a short feasibility record for audio watermarking and SMS drafts.
7. `privacy.html`: an EU section (controller identity, Art. 27 GDPR representative question for a non-EU controller, rights route), and honest descriptions of Social mode, triage and the Clinical persona.
8. A two-page deployer information sheet for Field Assist and Medical customers: what the AI does, Art. 4 and Art. 50(3) duties, the "no AI in performance figures" rule, logs available, how to switch features off.

**By 2 December 2027**
9. Either the face recognition and emotion inference capabilities are absent from EU builds, or a notified-body conformity assessment, authorised representative, EU database registration and the Arts. 9–15 dossier are complete. There is no middle path for Annex III point 1.
10. Settle the first-aid triage and Field Assist 4(b) classifications in writing with the dated guidance that supports them.

**Keep doing**
11. EV's AI-01 (archive the consolidated text and current guidance with dates) is still the right first evidence step; the final high-risk guidelines, when adopted, should be checked against §3.1 to §3.3 the week they appear.

### What a user can enable on their own

| | Until 2 Dec 2027 | From 2 Dec 2027 |
|---|---|---|
| Face recognition, EU personal user | Opt-in is lawful under the Act; GDPR is the user's own problem as controller of on-device processing | Unavailable on EU storefronts, or conformity-assessed; no opt-in design survives |
| Face recognition, outside the EU | Opt-in | Opt-in, unchanged |
| Social mode emotional-state inference | Opt-in for personal users; never under an organisation profile or Field Assist edition | Observe-only redesign keeps it everywhere; otherwise EU-unavailable |
| First-aid triage | Available; the switch must work | Personal: available. Business editions: Decision 4 |
| Self-build from source | A person compiling for their own use puts it into service themselves, but publishing the complete app under a commercial licence is plausibly still "making available" by the provider; counsel question, not a workaround to advertise | Same |

## 6. Decisions owed by the company (with counsel)

1. **EU posture:** which EU storefronts, since when, and whether TestFlight or side-loaded EU users existed before 2 Aug 2026. This fixes the Art. 50(2) date and whether the Act is engaged at all.
2. **Face recognition in the EU:** withdraw from EU builds, or commit to the high-risk route by December 2027. Recommendation: withdraw, and revisit if a harmonised standard for Annex III point 1 is cited in the Official Journal, which would reopen the internal-control route.
3. **Social mode:** observe-only redesign (recommended), or keep emotional-state inference with gating and accept high-risk status in December 2027 and workplace-prohibition exposure now.
4. **First-aid triage in business editions:** remove from Field Assist, or carry the 5(d) classification.

## 7. What changed since EV (6 Sept 2026)

- EV's timeline table was right and stands. The 2 Aug 2026 Art. 50 date has now passed; the 2 Dec 2026 marking grace and the 2 Feb 2027 interoperability date come from the final Guidelines and the Code, published after EV.
- EV's use-case register missed the three features this review rates highest: Assistive Social mode, the Clinical persona, and the ungated triage path. `AIFeatureRegistry` misses Social mode too.
- EV asked for face recognition to be classified "before professional/EU deployment". The draft guidelines now make that classification straightforward, and it is adverse.
- EV's AI-05 provenance half shipped and covers the Field Assist exports well; the chat and live disclosure it listed as owed is still owed.

## 8. Sources

- Regulation (EU) 2024/1689 (AI Act); Regulation (EU) 2026/1744 (Digital Omnibus on AI), in force 27 July 2026: [Gibson Dunn summary](https://www.gibsondunn.com/eu-ai-act-omnibus-agreement-postponed-high-risk-deadlines-and-other-key-changes/), [Jones Walker on what still applied on 2 Aug 2026](https://www.joneswalker.com/en/insights/blogs/ai-law-blog/yes-august-2-still-matters-the-eu-approved-a-high-risk-ai-delay-but-most-trans.html?id=102nbon), [Usercentrics](https://usercentrics.com/knowledge-hub/eu-ai-act-high-risk-delay-article-50-transparency-consent/).
- Commission FAQ on Art. 50 and the final Guidelines of 20 July 2026: [digital-strategy.ec.europa.eu](https://digital-strategy.ec.europa.eu/en/faqs/transparency-obligations-under-article-50-ai-act); [Reed Smith](https://www.reedsmith.com/our-insights/blogs/viewpoints/102nbz0/transparency-obligations-for-ai-generated-content-the-code-of-practice-adequacy/); [Paul, Weiss](https://www.paulweiss.com/insights/client-memos/eu-finalises-transparency-rules-for-ai-generated-content); [Stibbe on marking exemptions](https://www.stibbe.com/publications-and-insights/water-marking-the-machine-making-ai-generated-content-detectable).
- Code of Practice on transparency of AI-generated content, 10 June 2026: [Commission page](https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content).
- Draft Commission guidelines on the classification of high-risk AI systems, 19 May 2026 (consultation closed 23 June 2026): [Commission library](https://digital-strategy.ec.europa.eu/en/library/draft-commission-guidelines-classification-high-risk-ai-systems); paragraph numbers above refer to the consultation PDF.
- Commission guidelines on prohibited AI practices, C(2025) 5052, 4 Feb 2025 (emotion recognition, workplace, medical/safety exception): [AI Act Service Desk](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-5).
- Code inventories prepared for this review are summarised in §3; the underlying files are cited inline.
