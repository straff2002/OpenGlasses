# Plan IM — Experience Recordings (what the crew already knows, one case per recording)

**Status:** 📝 Drafted 2026-10-16. Part of P0 built by Plan NF P0 (2026-11-25): `LearningCandidate.Origin.recollection`, the entry fields `tried`/`outcome` (on `LearningEntry`, not yet on the candidate), `LearningEntry.Subject.symptom(equipmentType:phrase:)` decoded additively, and the team-learning contract amendment (§11). Not built: `recording` evidence, the `equipment_types` manifest list, the retriever's symptom matching, the recalled lead-in and ranking.
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
