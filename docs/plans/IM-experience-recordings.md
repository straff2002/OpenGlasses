# Plan IM — Experience Recordings (what the crew already knows, one case per recording)

**Status:** ✅ P0 merged 2026-11-27 (PR 1256, build 783) ([below](#p0--contract-amendment-and-the-model-headless)): team-learning §13, the candidate's `tried`/`outcome` and `recording` evidence, the manifest's `equipment_types`, symptom matching in retrieval, recollections ranked below job-confirmed learnings, and the recalled lead-in. Part of P0 was built by Plan NF P0 (2026-11-25): `LearningCandidate.Origin.recollection`, the entry fields `tried`/`outcome`, `LearningEntry.Subject.symptom(equipmentType:phrase:)` and §11. ✅ P1 merged 2026-11-27 (PR 1258, build 784) ([below](#p1--the-recorder-record-experience-phone-and-carplay)): the recorder on the phone and CarPlay. ✅ P2 merged 2026-11-27 (PR 1261, build 786) ([below](#p2--the-drafting-pass-pure-segmentation-model-extraction-validation)): the drafting pass, segmenter, schema-forced extraction and validator, with the schema and ten scripted recollections shared with the office's intake (team-learning §13.1). 🚧 P4 headless core built 2026-11-27, PR pending ([below](#p4--onboarding-campaign-and-site-brain-dumps)): the coverage count and the list, and site recordings drafting an HV site document; sending the list waits on P3's channel, and the site recording's entry points, its review and the device pass are owed. P3 not built. Drafted 2026-10-16.
**Track:** Field Assist (B2B).
**Depends on:** Plan [FP](FP-team-learnings.md) P0–P3 (shipped: candidate, review, entry, corpus,
bundle) and FP P4 (the review queue on a screen) before anything here is usable by a supervisor.
**Related:** Plan [GY](GY-procedure-from-narrated-recording.md) (a procedure drafted from a narrated
recording, the sibling for "how we do it" rather than "what we found"), Plan
[HV](HV-site-system-vaults.md) (where site-specific knowledge belongs), Plan
[FO](FO-guided-job-flow-and-job-tab.md) §6 (the debrief, on phone and CarPlay, whose recorder and
review pattern this reuses), Plan [IF](IF-photographed-manuals.md) (the captured-then-reviewed
round trip to the office), Plan [HO](HO-office-delivery-phone-half.md) (delivery to the office),
Plan [IP](IP-organisation-feature-switches.md) (an organisation switches it on).
**Origin:** A partner, 2026-10-16, after a call with an appliance-repair company that services
residential and commercial units: *"We have manuals, but they don't cover everything. How do we add
what we already know from experience?"* The partner names four kinds of knowledge: manuals,
procedures, existing hands-on experience, and new learnings from jobs. Plan FP covers the last. This
plan covers the third, which has to be populated when a customer is onboarded rather than waiting
for each situation to come round again. Many technicians "just want to finish the job and go
home", so capture has to take almost no effort.

---

## Where each kind of knowledge lives

| The partner's kind | Where it lives | Cited as |
|---|---|---|
| Manuals and service documentation | Vault documents (Plans ED/EF), photographed manuals (Plan IF) | "Title, page N, §section" |
| Procedures | Vault procedures (Plan F); drafted from a narration (Plan GY) | the procedure's name and step |
| **Existing hands-on experience** | **FP's learning corpus, origin `recollection` (this plan)** | "Crew experience · <model> · recalled by <role> · approved <date>" |
| New job learnings | FP's corpus, origins `spoken`, `report`, `reportReview` | "Team learning · <model> · noted on n jobs" |
| Site specifics ("at this site the condensate line…") | Plan HV site documents, never the learning corpus | the site document |

There is one corpus for both kinds of crew knowledge, so retrieval, the trust rules and "never
outranks a safety note" are not built twice. The **origin** is what keeps a recollection from
sounding like a confirmed job finding. A recollection was never bound to a job, so its
`confirmedJobCount` starts at 0 and it can never be described as "noted on n jobs". When later
jobs confirm it, FP's merge raises the count and the citation earns the stronger wording.

## The recording, as the partner proposed it

The partner will give customers a simple structure, one model or case per recording:

1. the equipment: brand and model, or what it is if the model is unknown;
2. the customer or site, if it matters;
3. the problem as it showed up;
4. what they checked and tried;
5. what fixed it, and how sure they are.

**This plan takes that structure and tolerates people who don't follow it.** The recorder shows
the five prompts as a card and reads them aloud on CarPlay. The drafting pass (P2) expects one case
but splits a recording that plainly holds several ("…and the other one we see a lot is…") into
separate candidates, each pointing at its own time range in the recording. A recording that names
no model becomes a candidate with a `symptom` subject within an equipment type, which is FP open
question 7, decided here (decision 4).

Talking about one case at a time is easier to process, as the partner says. It also makes the
reviewer's job tractable: one candidate per card, approved or not on its own, instead of a ten-minute
brain dump that is all-or-nothing.

## Answering the owner's two questions

- **Structured at onboarding, or a stream of consciousness the AI picks apart?** Structured, one
  case per recording, with a prompt card. The owner's point stands for site knowledge, though: a
  brain dump *per site* ("everything about the Hill Street plant room") structures easily against
  the site's own units. That route is HV's, and P4 offers it as a second recording kind that drafts
  a site document instead of learnings.
- **Is a dedicated "learning" voice-note button worth having?** Yes, and it is the same recorder.
  During a job it files against the open job, just as "note this for the team" does today. Outside
  a job it files a recollection. The office's review pass over job reports (FP decision 2) remains
  the main source for new learnings, because the technician often does not know they have learned
  something. The button is for the technician who does.

## Verified starting point (`main` @ `8d0266ae0`, 2026-10-16)

- **The corpus and its trust rules exist.** `LearningCandidate` has `origin` (`spoken` | `report` |
  `reportReview`), `symptom`/`fix` (up to 500 characters each), `finding` (1–2000), equipment
  identity, evidence by name and count, and redactions. `LearningEntry` adds `subject`
  (`model(token, manufacturer?, equipmentType?)` or `practice(topic)`), approval, `origin`,
  `sourceJobIDs`, `confirmedJobCount`, safety-note collision and supersession. `LearningReview` is a
  pure state machine. `LearningCorpus` publishes under `learning:<vaultId>`. Retrieval labels a
  passage "TEAM LEARNING (not the manual)". A learning alone is `.teamLearningOnly`, and
  `TeamLearningDisclosure` prepends "The manual doesn't cover this. Your crew's own finding…".
- **The candidate has no "tried" and no "outcome".** Those are two of the partner's five parts.
- **Capture needs a job.** `team_learning` returns `.noActiveJob` without one. It needs the
  `.teamLearnings` capability (team and enterprise) and is withheld under HIPAA.
- **No screen yet.** FP P4 (the review queue, the corpus browser, the badge) is unbuilt. Today the
  only inbound route is an unsigned `LearningBundle` opened from Mail or Files.
- **No job-independent recorder for technicians.** `audio_recording` saves an `.m4a` with a live
  transcript to Files. `memory_rewind` keeps nothing. `notes_vault` writes unreviewed text straight
  into a prompt-visible overlay, which FP warns against. The debrief (FO §6, phone and CarPlay)
  records, transcribes, and drafts a fixed-schema summary with each item citing its source turns,
  saved only on a spoken "save". That is the nearest pattern, and P1 reuses its recorder and review
  state.
- **The office route is design-only.** `Contracts/team-learning.md` is draft v1 with no fixtures.
  The office's review pass over reports (FX20 successors) is private and planned.

## Decisions proposed (owner to confirm)

1. **The technician only talks; structuring happens where the reviewer is.** The phone records,
   transcribes on the device and redacts. It does *not* ask the technician to check a structured
   draft, because that is the effort the partner says people will not spend. The drafting pass runs
   on the reviewer's device, or in Avenkin Office's intake, on the organisation's own provider
   credentials. That is consistent with FP decision 2: a person approves everything and nothing is
   trained.
2. **The audio stays on the phone that recorded it unless the organisation asks for it.** The
   transcript (redacted) travels to the reviewer. The audio is kept 30 days on the recording phone
   so a reviewer can ask "what did they say here?", then deleted. An organisation may set it to
   travel with the transcript (an `IP` switch) for offices that want to listen.
3. **Two new candidate fields: `tried` and `outcome`.** Both are optional, up to 500 characters,
   and both are added to `Contracts/team-learning.md` as a v1 amendment, with FP's `origin` cases
   becoming `spoken | report | reportReview | recollection`. `outcome` carries the technician's own
   confidence in words ("fixed it every time", "worked once"). It is shown to the reviewer and never
   turned into a number.
4. **A symptom subject, bounded by equipment type.** `subject` gains
   `symptom(equipmentType, phrase)`. The equipment type comes from a closed list, never free text.
   No vault declares one today (`equipmentType` exists only as an optional string on a model
   subject), so P0 adds an optional `equipment_types` list to the vault manifest. Where there is an
   office, its own vocabulary is the alternative. A dryer finding then never answers for a
   dishwasher. This closes FP open question 7.
5. **Recollections are ranked below job-confirmed learnings and are worded as recalled.** The
   lead-in says "From your crew's experience (recalled, not yet seen on a recorded job):". FP's
   merge promotes an entry when a job report confirms it.
6. **Site detail is split off, not discarded.** A drafted candidate that names a customer or
   site has that part moved to a "site note" draft for HV, not published as a learning, because
   FP's contract §8 keeps sites out of learnings.

## Phases (one PR each)

### P0 — Contract amendment and the model (headless)

- `LearningCandidate.Origin.recollection`, `tried`, `outcome`, and `recording` evidence
  (`recordingID`, `segment: start..<end` seconds), so a candidate drafted from part of a recording
  points at that part. `LearningEntry.Subject.symptom(equipmentType:phrase:)`, and the optional
  `equipment_types` list in `VaultManifest` that bounds it (decision 4).
- `Contracts/team-learning.md` v1 amendment, with fixtures cut for the four origins and the
  symptom subject. Older bundles decode unchanged, and a newer bundle on an older phone is refused
  by name, as today.
- Retrieval: `VaultRetriever` matches a symptom subject only within the turn's resolved equipment
  type. `TeamLearningDisclosure` gains the recollection lead-in (decision 5). Ranking puts
  `confirmedJobCount > 0` ahead of a recollection when both clear the floor.
- **Exit tests:** codec round trips; an old-shape bundle still imports; a dryer-symptom entry is not
  retrieved for a dishwasher turn; a recollection-only answer opens with the recalled lead-in; the
  existing FP suite is green.

**Merged 2026-11-27 (PR 1256, build 783).** Team-learning §13. The candidate gains `tried` (≤ 500), `outcome` (≤ 120,
the entry's limit from NF rather than decision 3's 500, so an approval carries it as written) and
`evidence.recording` (`recordingID`, `segmentStart..<segmentEnd` whole seconds, within a day), validated
and redacted like the other fields, carried by FP's bundle (and `tried`/`outcome` on its entries). An
approved recollection carries no jobs, and merging one confirms none. `VaultManifest.equipment_types`,
with its rules in the shared core (`VaultPackRules.equipmentTypeIssues`, `equipmentTypeKey`), so the
portal reads the same list for the crew experience sheet; a company layer adds to it. Review refuses a
symptom subject whose type is not on every in-scope vault's list; a vault that lists its types holds back
a symptom entry of another type. Retrieval (`VaultRetriever.EquipmentTypeScope`) resolves the turn's type
from the list named in the turn, then in the job, then the unit's own types from its model entries, and
drops a symptom learning of another type; with no type, nothing scopes it, as a model learning with no
unit. `learningsBySeenOnAJob` puts job-confirmed learnings ahead of unconfirmed recollections. The recalled
lead-in is NF's crew experience lead-in, not a second sentence: decision 5's wording is an owner question.
Fixtures in `Contracts/fixtures/team-learning-v1/`; tests in `TeamLearningRecollectionTests`.

### P1 — The recorder: "Record experience" (phone and CarPlay)

- An `ExperienceRecording` (id, created, duration, transcript, redactions, the vault in force,
  optional spoken model and site, status `recorded → sent → drafted → reviewed`) in its own
  `ExperienceRecordingStore`. It is registered in `SensitiveStore`, walked by the subject erasure,
  backup-excluded, and cleared when the phone leaves its organisation, like `learningCandidates`.
- The recorder is FO §6's debrief recorder with the five-prompt card. On the phone it lives in the
  Job tab ("Record experience", with or without a job open) and in Field Assist settings. On
  CarPlay it is a Jobs-list action that reads the prompts aloud and records hands-free. Drive time
  is when technicians are most likely to do this. Each recording has a hard cap (10 minutes) and a
  spoken "that's one, next case" that ends one recording and starts the next.
- On-device transcription only (the same path the debrief uses). `SecretPatterns.redact` runs on
  the transcript at capture, and the standing "no customer names or addresses" line is spoken once
  per session.
- A recording made during an open job files a `spoken`-origin candidate bound to the job (today's
  path), not a recollection.
- **Exit tests:** store lifecycle, erasure and redaction; the CarPlay template contract; the
  "next case" split; HIPAA withholding; and the `.teamLearnings` capability gate, plus Plan IP's
  switch once it exists.

**Merged 2026-11-27 (PR 1258).** Decisions 1, 2 and 6 as recommended. `ExperienceRecording` (id,
created, whole-second duration, redacted transcript, redaction names, the default vault, optional
spoken model and site, which P1 leaves empty for P2, status forward-only `recorded → sent → drafted →
reviewed`, and when its audio went) lives in `ExperienceRecordingStore`: an index beside the
candidates and one `.m4a` per recording, first-unlock protected and backup-excluded, registered as
`experienceRecordings` (third-party subject, like `learningCandidates`), walked by the subject erasure
with its audio, and cleared in the organisation departure beside the candidates. The audio is deleted
30 days after recording (swept at launch and when the recorder opens; the transcript stays), and
nothing leaves the phone. `ExperienceRecorder` is FO §6's debrief without the model: it starts only
when no conversation is listening, and nothing said reaches the assistant. `LiveExperienceCapture`
records through `CaptureAudioRouter` and transcribes with `requiresOnDeviceRecognition` always on: a
phone that cannot transcribe its language on the device is refused, never sent to Apple's servers. A
stretch is what was said between pauses (1.6 s); `ExperienceRecordingMarkers` reads "that's one, next
case" (anywhere in a stretch, or a bare "next case" alone or as its last sentence) and "that's all"
(only as a whole stretch or its last sentence, so "that's all it needed" stays in the case). The standing line
"Please leave out customer names and addresses" is spoken once per session; in the car the five
prompts are read aloud too, and the card's second prompt asks for the kind of site rather than the
customer. With a job open a recording files `spoken` candidates on that job through
`LearningCandidateService.note` (in parts of at most 2,000 scalars when long), keeps no audio, and is
kept on the phone instead if the filing is refused or the job closes mid-recording. Plan IP has no
switch built, so the `.teamLearnings` capability is the only organisation gate
(`ExperienceRecordingAvailability`); Medical Compliance withholds it wherever `team_learning` is
withheld. On the phone it is a row on the Jobs list and a link in Field Assist settings; in the car a
Jobs-list row that becomes Stop while recording. The markers are English only. Tests in
`ExperienceRecordingTests` (store, transcript, markers, availability, the car's row, the recorder,
the job path). Owed: a device pass (CarPlay audio route for recording, the wake word during a
recording, recogniser stretches on hardware).

### P2 — The drafting pass (pure segmentation, model extraction, validation)

- `RecollectionDrafter`: a pure segmenter over the timed transcript (explicit "next case" markers,
  then a change of model token through `VaultModelIndex`), then one schema-forced extraction per
  segment (`model?`, `equipmentType`, `symptom`, `findings`, `tried`, `fix`, `outcome`,
  `siteNote?`). It uses the structured-output path Plan AD uses and is validated before anything is
  stored. A field the transcript does not support is left empty, never filled in. Each drafted
  field keeps the transcript span it came from.
- It runs on a reviewer device (`Config.teamLearningReviewerDevice`). The same schema and fixture
  file are what the office's intake implements (named in the contract amendment), so a recording
  drafts to the same candidate wherever it is processed.
- **Exit tests:** a fixture set of ten scripted recollections. Each covers: one case; three cases in
  one recording; no model; a site mentioned; a safety-relevant fix; a recording that is not a case
  ("just testing"). Each must draft the expected candidates, with spans that cover every filled
  field and nothing invented. Run against a stub model in CI and against the live provider as an
  owed check.

**Built 2026-11-27, PR pending.** Decisions 1, 3, 4 and 6 as recommended; the shared rules are
team-learning §13.1. `RecollectionSegmenter` (pure) splits the transcript into sentences, cuts cases at
P1's markers (`ExperienceRecordingMarkers.split`, read the recorder's way: "that's all" ends the
transcript), then at a sentence naming exactly one vault model after another was named
(`VaultModelIndex`). Each segment is one call through `LLMService.completeStructured` (Plan AD's
path) behind the `RecollectionDraftModel` seam, with the closed eight-field schema
(`RecollectionDraftRules.jsonSchema`, held to `recollection-draft-schema-v1.json`). The model gives
each field as its words plus the exact quotes it rests on; **the phone finds every quote in the
segment itself** (Unicode scalar spans; a model is good at quoting, bad at counting), and
`RecollectionDraftValidator` refuses the whole answer for a filled field with no quote, a quote the
segment does not hold, a model or type its quotes do not say, a control character, a malformed shape,
or a learning field touching the site note. A free-text field that says more than its quotes becomes
the technician's words verbatim instead, so nothing is invented. Over a limit (`tried` 500, `outcome`
120, P0's) a field is held back with its spans, never cut; an equipment type off the vault's closed list
is held back and drafts no symptom subject. The site is a separate `RecollectionSiteNote` (decision 6).
A draft carries its segment, the recording evidence in whole seconds (estimated from where the segment
sits in the transcript, because P1 keeps no stretch timings), the suggested subject and the safety
check's hazard words; `RecollectionDraft.candidate(from:author:)` makes the `recollection` candidate P3
will file (finding: the findings, else the fix, then the symptom). `RecollectionDrafter` runs only on a
reviewer device (`Config.teamLearningReviewerDevice`) and never under Medical Compliance, and stores
nothing: moving the recording to `drafted` and filing are P3's. The schema and the ten recollections
(`Contracts/fixtures/team-learning-v1/recollection-draft*-v1.json`) are shared with the office's intake;
`Contracts/tests/test_recollection_drafts.py` (`python3 -I`, in the contracts workflow) is a second
implementation held to them. Tests in `RecollectionDraftTests` (stub model). Owed: the live-provider
pass over the ten recollections (Anthropic, OpenAI, Gemini, on-device), and English-only markers as in
P1.

### P3 — Delivery and review

- A recording goes to the reviewer as FP's `LearningBundle` (no office) or as an office `records`
  report (Plan HO, opt-in build). The transcript is in the bundle. The audio is included only under
  decision 2's switch.
- On the reviewer device, drafted candidates land in FP P4's review queue grouped by model and
  symptom. Each has the transcript span beside every field and a play button when the audio is
  there. Approve, edit and approve, merge into an existing entry ("this is the same as the one
  from 3 March"), or discard. The site part goes to a site-note draft (decision 6).
- **Exit test:** headless, from a recorded fixture on phone A to an approved recollection entry
  answering on phone B with the recalled lead-in and citation.

### P4 — Onboarding campaign, and site brain-dumps

- **What's missing.** For the active vault, `VaultModelIndex` lists the models it covers, and the
  corpus lists the models that have crew experience. The reviewer device shows "14 models in your
  vault have no crew experience yet" and can send a list to technicians: "Could you record what you
  know about these?" A technician sees the list on the recorder's card. Nothing is assigned and
  nothing nags.
- **Site recordings.** A second recording kind, "Tell me about this site". It drafts an HV site
  document (units, how they connect, local quirks) for review, instead of learnings. It is gated on
  HV P1 existing.
- **Exit test:** the coverage count against the Lennox (or fictional) vault fixture; a site
  recording drafts a site document that validates against HV's schema.

**Headless core built 2026-11-27, PR pending.** HV P0–P2 are built, so the site recording is not
gated on them.

- **What's missing.** `ExperienceCoverage.of(_:entries:)` (pure) takes the vault's
  `LearningCorpus.VaultTarget` and the phone's approved entries (`TeamLearningSources`: phone-reviewed
  and the company's crew experience set, every origin) and returns the index's models no entry is
  about, in the index's order. An entry counts when it is live and `LearningCorpus.placement` would
  publish it to the vault; it covers a model by identity, as retrieval scopes a learning
  (`ModelScope.identity(token)` among the model's `tokens`, contract §7.2), never by its prose.
  `ExperienceCoverageCopy` words it ("14 models in your vault have no crew experience yet", "1 model
  …", "Every model in your vault has crew experience.", nothing for a vault with no models).
  `ExperienceCoverageRequest` is the list a reviewer would send (vault, its name, the models' names,
  the day asked; nobody named, nothing assigned) and the card's line is "Could you record what you
  know about these?". On a reviewer device (`Config.teamLearningReviewerDevice`), wherever the
  recorder is offered, the recorder page shows the count and the missing models in a section of its
  own, read when the page opens: no notification, no badge, nothing sent.
- **Site recordings.** `ExperienceRecording.Kind` (`experience` | `site`): absent decodes as
  `experience`, and it is encoded only for a site, so a recording kept before P4 reads and writes the
  bytes it did. `ExperienceRecorder.start(from:kind:)` records a site the way it records a case, reads
  the site prompts in the car (`ExperienceRecorderCopy.sitePrompts`), and always keeps a site
  recording on the phone: it is never filed on an open job. `RecollectionDrafter` refuses a site
  recording (`.siteRecording`), so it never drafts a learning candidate. `SiteRecordingDrafter` (same
  gates as P2: a reviewer device, never under Medical Compliance) cuts the transcript at P1's markers
  with P2's segmenter, makes one schema-forced call through P2's `RecollectionDraftModel` seam
  (`LLMRecollectionDraftModel` with its own tool name and budget), and `SiteRecordingDraftValidator`
  holds the answer to: empty text or list means not said (the schema's own convention, as P2's); the
  phone stamps `format`, `version` and `id` (`site-<recording id>`, so the file is
  `sites/site-<id>.json`) and refuses an answer carrying them or another system's identifiers
  (`external_location_ids`, a unit's `external_ids`); HV's `SiteSystemValidator.check` against the
  recording's vault (`modelCovered(by:)`) unchanged, its issues the refusal verbatim (an unknown
  model, a unit naming another vault, a missing name); a unit's model and serial said in the
  transcript (letters and digits, any case); every word of every text member among the transcript's
  words (P2's support rule). Nothing is patched; it stores nothing. Tests in
  `ExperienceCoverageAndSiteDraftTests.swift` (`ExperienceCoverageTests`, `ExperienceRecordingKindTests`,
  `ExperienceRecorderSiteTests`, `SiteRecordingDraftTests`), against HV's fictional fixture vault.

**Decisions taken in P4** (owner to confirm):

1. **A symptom entry covers no model.** Retrieval admits a symptom learning for a unit only within the
   unit's equipment type, and the unit's type comes from its own approved model entries, which already
   cover it; with no type resolved, a symptom learning is unscoped, answering for every unit and so
   about none. Counting it would make "no crew experience" mean less. A practice entry covers none
   either.
2. **Coverage is counted on the reviewer's device**, from what that device has approved or received,
   not from an office's corpus. An office with its own vocabulary would compute it from its own
   corpus (open question 4 below stands).
3. **A site recording is not contract-visible yet.** It drafts an HV site document, a vault format
   that is already specified, on the reviewer's device only; P2's shared schema stays the
   recollections'. If the office's intake is to draft site recordings too, the site schema joins
   team-learning §13.1 with fixtures, as P2's did.
4. **A site draft must keep to the technician's words**, and a word nobody said refuses the draft
   rather than being kept: a site document has no verbatim fallback (P2's), because its members are
   short labels that a quoted sentence would not fit. A live-provider pass may show this is too strict
   for paraphrasing models (owed check).

**Owed for P4:** sending the list to technicians and showing it on their card (P3's channel; the value
and the line exist); the "Tell me about this site" entry on the Jobs list, in Field Assist settings and
in the car (the recorder takes the kind; nothing offers it yet); where a site draft is reviewed and how a
reviewed one reaches a vault (HV's documents are baseline vault content, so through the office's vault
build or an export, not built); the live-provider pass over site recordings; the device pass.

## Acceptance

- At onboarding, a technician driving between jobs records three cases on CarPlay without touching
  the phone. That evening the supervisor sees three drafted candidates, each with its transcript
  beside it, approves two and merges one.
- The next day another technician asks about the same model's symptom and hears the crew's
  recalled experience, clearly worded as recalled and not from the manual, with the manual's
  answer first if it has one.
- A site mentioned in a recording never appears in a learning. It reaches the site-note draft or
  nowhere.

## Open questions for the owner

1. Decision 1: is drafting on the reviewer's device acceptable for organisations without the
   office, given it spends their provider credits there?
2. Decision 2: the 30-day audio retention on the recording phone, and whether audio travels by
   default.
3. Does a recollection expire if no job ever confirms it (FP open question 6, sharper here)?
4. Should P4's missing-models list be a CT profile item ("these are the models we want covered"),
   so the office sets it rather than the reviewer device?
5. P4: should the office's intake draft site recordings too (the site schema then joins §13.1)?
6. P4: is refusing a site draft for any word the technician did not say right, or should a site
   draft's free text be kept and flagged for the reviewer instead?
