# Plan NG — Team Learnings Reviewed in the Portal (what a technician files on the job reaches the company's administrator, not a reviewer phone)

**Status:** 🚧 P0 and P1 merged 2026-11-27 (PR 1249, build 778); P2 catalog and P0b merged 2026-11-27 (PR 1254, build 779); S1 merged 2026-11-27 in the private service repository (its PR 30). **P0:** `Contracts/team-learning.md` §12 (the
portal binding `profileId` + `seatID`, the job session id sent only as a per-company hash, the two seat
actions `/seats/learning-candidate` and `/seats/learning-status` with their requests, replies, paging and
every refusal by name, and the route rule), golden fixtures in `Contracts/fixtures/team-learning-portal-v1/`,
and the shared core `SeatLearning.swift` (Foundation only, compiled into the app; `SeatWire.openLearningEnvelope`
and `learningJobSessionID` beside the other seat actions), with `organizationTeamLearningsInPortal` (company
value, on unless false) in the profile contract. **P1:** `DeviceSeatServer.sendLearning` and
`DeviceSeatService.learningExchange` (signed by the seat, live lease only, never makes a key), the
`teamLearningPortal` queue item (id and revision only), `sent` only on `received`, the status fetch after a
foreground with its paging, the job's status line (refusals named via `send_refusal`), the route choice
(`TeamLearningRoute`), and the new egress disclosed (route `teamLearningPortal`, manifest, both Privacy
footers). **P2:** the four new strings (the sync label, the profile switch, both Privacy footers) in all 13 languages, add-only. **P0b** merged 2026-11-27 (PR 1254, build 779; [below](#p0b--the-core-holds-what-the-portal-publishes-headless-found-2026-11-27-starting-s1)). **S1** (the portal) merged 2026-11-27 in the private service repository (its PR 30). Not built: P3 (device pass). Drafted 2026-11-25. All 10
[decisions](#decisions-for-greig) taken as recommended the same day.
**Track:** Field Assist — company knowledge. The licence portal, device seats, the team-learning corpus.
**Builds on:** Plan [FP](FP-team-learnings.md) P1–P3 (the candidate filed on the job, its statuses, the merge
that counts confirming jobs), Plan [NF](NF-crew-experience-sheet.md) (the portal's review preview and the sealed
per-vault set this plan adds to), Plan [JS](JS-licence-sales-and-device-seats.md) P2 (the device seat key and
the signed seat exchange), Plan [ND](ND-company-settings-from-the-portal.md) (portal publish and history).
**Sits beside:** Plan [JL](JL-procedure-deviations-and-learning-round-trip.md) (the same round trip for a
company with its own office), FP P4 (the reviewer-device screens, still the route for a company with neither).
**Service side:** the portal, the queue and the signer live in the private service repository. This plan
carries the contract the phone sends and reads, with a one-line outline of each service step.

---

## Trigger

Plan NF decision 15, taken 2026-11-25. Once the portal has a screen where an administrator reviews crew
experience before it reaches every phone, what technicians file on the job should arrive on that screen too.
Today it can't. A filed learning leaves the phone only as a file someone e-mails or shares to a reviewer
device, and nobody in a portal company has a reviewer device.

## Outcome

- On a job, a technician says *"note that: on this model the E228 is the harness at the plug, not the
  switch."* The phone files it as today. Within a minute of signal it is in the company's portal under
  **Crew experience › From the field (1)**, with the job number, model, author and what was checked.
- The administrator tidies the wording and presses **Approve**. It joins that vault's set beside the sheet's
  rows, and every phone has it on its next foreground.
- When the same finding already exists as a sheet row, the administrator presses **Same as row 17** instead.
  The row's `confirmedJobCount` goes to 1 and the citation now says the crew has noted it on a job.
- The technician's job shows **Approved** against their note, or **Not taken up**, with the administrator's
  reason.

## What exists (verified 2026-11-25 on `origin/main` 2c1276428)

- **The candidate.** `team_learning` files a `LearningCandidate` in the team-learning contract's §3 shape into
  `LearningCandidateStore`, redacted at capture. It carries the job and task, the author's display name, the
  vault, the model token or spoken model, `finding`/`symptom`/`fix`, and evidence as names and counts only. It
  is gated on `.teamLearnings` (team and enterprise) and withheld under HIPAA. The contract's §4 statuses are
  `received`, `approved`, `merged`, `not_taken_up`.
- **The routes out today.** FP P3's unsigned `LearningBundle` goes by e-mail, Messages, the share sheet or the
  organisation's own `DeliveryChannel.endpoint`. The reviewer is a device-local setting
  (`Config.teamLearningReviewerDevice`, also a profile key with a `false` ceiling). FP P4's review screens are
  unbuilt.
- **A signed channel to the service already exists.** `DeviceSeatService` sends nonce-gated requests signed by
  the device's own seat key (`DeviceSeatKey`) to the origin of the licence's **signed** `profile` claim, on an
  ephemeral session, with an 8 KiB reply cap and `MedicalEgressGuard`. Its actions are `claim`, `renew` and
  `release` under `/seats/`.
- **The seat claim discloses four fields and nothing else.** The privacy manifest, the in-app copy and the
  tests (`DeviceSeatTests`, `TelemetryOptOutGuardTests`; `DeviceSeatLease`'s comment still says
  `DeviceSeatServiceTests`) name exactly those. Sending a learning's text to the service is new egress, and has
  to be disclosed in the same PR (the repository's telemetry and egress rule).
- **The way back.** NF §5 puts a sealed set per vault on the company-vault catalog. This plan adds entries to
  that set and doesn't add a second carrier.

## Design

### 1 · Sending a candidate

- A phone enrolled in a portal company sends each filed candidate, and each revision or withdrawal of one, as a
  new seat action, `POST /seats/learning-candidate`. It is signed by the seat key over a fresh nonce, like
  `renew`. The body is the contract's §3 candidate. The binding fields name the profile and seat, not an
  office. The envelope cap is 32 KiB.
- It goes through the offline queue and retries without limit, as §3 already requires. The candidate becomes
  `sent` only on the service's `received` reply. A refused send is named on the technician's job.
- Nothing is sent that isn't already in the candidate: no photo, no reading value, no transcript, no
  customer or site.

### 2 · Review in the portal

The queue sits under the vault's **Crew experience** page, next to NF's sheet preview. For each candidate the
administrator can:

- **Approve.** Edit the wording, set the subject (model, practice or symptom), and publish. The entry keeps
  `origin: spoken` and `candidateID`. The administrator's role is `approvedByRole`.
- **Same as an existing entry.** Merge into an existing entry or sheet row. FP's merge rule raises
  `confirmedJobCount` and records the job in `sourceJobIDs`. A `recollection` row merged this way earns the
  job-confirmed citation.
- **Not taken up.** Give a reason of up to 500 characters, which goes back to the author.

NF's rules apply unchanged: the unknown-model choice, the safety second confirmation, and redaction marks.

### 3 · Back to the phones

- Approved and merged entries join the vault's NF set. There is one set and one `sequence` per vault, and
  sheet rows and field entries sit side by side, kept apart by `origin`.
- Statuses come back on a new seat action, `POST /seats/learning-status`. The phone asks after a foreground
  when it has candidates `sent` and not yet answered. The reply is the contract's §4 statuses for that seat's
  candidates only, under the 8 KiB cap, paged when there are more. The job shows each one.

### 4 · Which route a company uses

One route per company, chosen in this order:

1. **Office** (Plan JL), when the phone holds an office binding.
2. **Portal** (this plan), when the company has company vaults on the portal and the profile switches it on.
3. **Reviewer device** (FP P3/P4), for a company with neither.

The profile names the route. The phone never sends a candidate by two routes.

## Phases

One PR each on the app side. The service steps are outlined only.

### P0 — The contract (headless)

`Contracts/team-learning.md` amended additively: the portal binding fields (`profileId`, seat id) as the
alternative to the office binding; the two seat actions with their request, reply and refusal reasons; the
route rule (§4). Golden fixtures in `Contracts/fixtures/team-learning-portal-v1/`. The shared seat request
types sit beside `DeviceSeatLease`.

### P1 — The phone sends and hears back

The seat actions on `DeviceSeatServer`, the queue item, `sent` on `received`, the status fetch and its paging,
the job's status line, and the route choice from the profile. Privacy manifest and in-app copy updated for the
new egress, with `TelemetryOptOutGuardTests` and `DeviceSeatTests` extended to name it. Tests: a refused
send stays queued, a duplicate revision is idempotent, HIPAA sends nothing, a lapsed licence stops sending and
keeps what was published.

### P0b — The core holds what the portal publishes (headless; found 2026-11-27 starting S1)

S1 cannot approve or merge without restating rules the core lacks. Shipped phones run
`CrewExperienceSet.check` on every set and refuse the whole set when any entry's `origin` is not
`recollection`, and `CrewExperienceSet.Entry` has no `candidateID`, `sourceJobIDs` or `confirmedJobCount`.
FP's merge rule lives only in the app (`LearningReview.merge`).

- `CrewExperienceSet.check` admits `origin: spoken` beside `recollection`; `Contracts/crew-experience.md`
  says so. The entry gains the three optional fields, absent on every sheet row.
- The merge rule moves into the core (a job already counted adds nothing; a recollection merged with a job
  becomes job-confirmed), with fixtures; `LearningReview.merge` calls it, and so will the service.
- `CompanyExperienceStore` reads a `spoken` entry as `.spoken`, so it is cited as a team learning, not as
  crew experience.
- **Older phones.** Builds 775–778 refuse a set holding a `spoken` entry, so the service publishes one only
  once every active seat in the company reports an app build at or above the P0b build (seat renewals carry
  the build). Until then an approved learning waits in the portal and the queue says why.
- **Exit tests:** the check admits both origins and still refuses any other; old sets decode unchanged; the
  merge rule's fixtures agree between the app and the core; a spoken entry is cited as a team learning.

**Built 2026-11-27, merged in PR 1254 (build 779).** Crew experience contract §11 and team-learning §12.5. Core:
`CrewExperienceSheet.spokenOrigin`, `CrewExperienceSet.origins`, the entry's `candidateID?`/`sourceJobIDs?`/
`confirmedJobCount?` (encoded only when present: `set-v1.json` and the sealed fixture unchanged), the
provenance rules in `check` (a `spoken` entry carries its candidate and jobs; a recollection no candidate;
job ids are the 32-hex join keys; count ≥ jobs; one entry per candidate), `Entry.citationName` as
`Team learning · …` for a `spoken` entry, `CrewExperienceMerge.merge(jobSessionID:into:)`, and the gate
`CrewExperienceSet.spokenEntriesMinAppBuild` (779) with `mayPublishSpokenEntries(seatBuilds:)`,
`mayPublish(_:seatBuilds:)` and `SeatPolicy.mayPublishCrewExperience(_:seats:profileId:now:)`. A sheet row
whose id is a published entry keeps its origin, candidate and jobs when edited. Phone: `LearningReview.merge`
calls the core, `CompanyExperienceStore` maps `spoken` to `.spoken` with its fields. Golden fixtures in
`Contracts/fixtures/crew-experience-v1/learnings/`. One reading of FP's rule: a recollection's count before a
merge is its jobs (0 for a sheet row), not FP's `max(1, jobs)`, so its first job makes it 1 (contract §11 there).

### S1 — The portal (private service repository)

The two seat endpoints, the queue page, approve / same as / not taken up, the merge into NF's set, and retention
(decision 7). **Merged 2026-11-27** in the private service repository (its PR 30).

### P2 — String catalog sync

The job status lines and the refusal wording in all 13 languages, add-only. **Merged 2026-11-27** (PR 1254).

### P3 — Device pass (owed)

Two phones in one portal company. File a learning on phone A in airplane mode, then reconnect: it arrives in the
portal. Approve it: phone B answers with it on its next foreground. Mark one "same as" a sheet row: the citation
changes on both phones. Not take one up: phone A's job shows the reason.

## Decisions for Greig

Taken 2026-11-25: all 10 as recommended.

1. **Use the seat channel, not the organisation endpoint.** *Recommended:* yes. It is already signed per
   device, points only at the vendor-signed origin, and needs nothing configured.
2. **The portal is the reviewer for a portal company; the reviewer device stays for a company with neither.**
   *Recommended:* yes (§4).
3. **The job number goes to the portal; the job session id is hashed.** *Recommended:* yes. The administrator
   needs to find the job, and the session id is only a join key.
4. **The author's display name goes to the portal.** *Recommended:* yes. The administrator is the technician's
   employer, and the name is already on the job report they receive.
5. **No photos in v1.** *Recommended:* yes. Evidence stays as names and counts, as in the contract today.
   Photos are a privacy and size question of their own.
6. **Statuses come by a fetch after foreground, not inside the seat renewal reply.** *Recommended:* fetch. The
   renewal reply is capped at 8 KiB and runs once a day.
7. **Retention in the portal.** *Recommended:* a candidate that is not taken up is deleted 90 days after the
   decision. An approved one is kept as the entry's history for as long as the entry is.
8. **A field entry may merge into a sheet row.** *Recommended:* yes (§2). It is how a recollection earns the
   job-confirmed wording.
9. **On by default for a portal company.** *Recommended:* yes, with a profile switch to turn it off. Without it
   a filed learning goes nowhere in a portal company.
10. **Disclosure.** *Recommended:* the in-app copy says *"Learnings you file are sent to your company's
    administrator for review"*, in the same PR as the send (P1), and the privacy manifest lists the data
    type as user content linked to the seat.

### Decided 2026-11-27 (questions raised while building P0b and S1)

1. **A company with no device seats sends no learnings to the portal.** Accepted for v1: the seat channel is
   the signed route, and a company without seats is not a portal company; it uses the reviewer device and
   bundles (FP P3). The portal's onboarding says so (private service repository).
2. **`notIncluded` is reserved.** The service has no tier to read, so it never sends it; the contract keeps the
   name (§12.2) and the phone keeps handling it.
3. **A recollection's first job makes its count 1.** Kept: the count is the jobs that confirmed it, and a
   recollection is not a job. P0b's reading of FP's rule stands.
4. **The reseal hold-back stays.** Holding a set back until every active seat reports build 779 or later is
   safer than publishing a set an older phone refuses whole.
5. **Backups follow the 90-day deletion.** The service's encrypted backups rotate after 30 days (the newest
   seven kept whatever their age), so a learning deleted 90 days after its decision is gone from the host's
   backups within 30 days of that deletion. A copy taken off the host must be rotated the same way (private
   service repository).
6. **No `practice` subject yet.** Model and equipment-type subjects cover every case so far; it waits for a
   real request.
7. **S1 checks no HIPAA value.** A HIPAA phone sends nothing (§12.3), and the company profile the portal
   publishes carries no Medical Compliance value for the service to read. When a company profile can pin
   Medical Compliance on, the seat actions refuse that company's learnings as well.

## Acceptance

- A learning filed offline reaches the portal once the phone has signal, exactly once.
- Approve, same as and not taken up each reach the author's job as the right status.
- An approved entry reaches every phone in the company through NF's set, with no app release.
- A HIPAA phone and a lapsed licence send nothing. A company on the office or reviewer-device route sends
  nothing to the portal.
