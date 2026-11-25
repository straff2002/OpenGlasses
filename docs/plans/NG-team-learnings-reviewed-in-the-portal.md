# Plan NG — Team Learnings Reviewed in the Portal (what a technician files on the job reaches the company's administrator, not a reviewer phone)

**Status:** 📝 Drafted 2026-11-25. Nothing is built. 10 [decisions](#decisions-for-greig), each with a
recommendation.
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

### S1 — The portal (private service repository)

The two seat endpoints, the queue page, approve / same as / not taken up, the merge into NF's set, and retention
(decision 7).

### P2 — String catalog sync

The job status lines and the refusal wording in all 13 languages, add-only.

### P3 — Device pass (owed)

Two phones in one portal company. File a learning on phone A in airplane mode, then reconnect: it arrives in the
portal. Approve it: phone B answers with it on its next foreground. Mark one "same as" a sheet row: the citation
changes on both phones. Not take one up: phone A's job shows the reason.

## Decisions for Greig

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

## Acceptance

- A learning filed offline reaches the portal once the phone has signal, exactly once.
- Approve, same as and not taken up each reach the author's job as the right status.
- An approved entry reaches every phone in the company through NF's set, with no app release.
- A HIPAA phone and a lapsed licence send nothing. A company on the office or reviewer-device route sends
  nothing to the portal.
