# Plan MT — Who May Change a Company's Procedures (a grant per phone from the portal, changes proposed from the phone, reviewed or published, and back on every phone as the next version)

**Status:** 📝 Drafted 2026-11-21. Nothing is implemented. 10 decisions below, each with a
recommendation.
**Track:** Field Assist, fleet. Phone half and the shared contract in this repository; the service
and the portal in the private service repository, as for Plan LR.
**Builds on:**
- Plan [LR](LR-company-vaults-from-the-portal.md): company vaults uploaded to the portal and installed
  on every enrolled phone, each new version picked up by itself (`Contracts/company-vaults.md`).
- Plan [LV](LV-published-vaults.md): publisher baseline → company layer → technician overlay; the
  company layer is add-only; the sealed core.
- Plan [JS](JS-licence-sales-and-device-seats.md) P2: device seats. Each phone holds a P-256 key;
  every request is a `SeatEnvelope` (the request, a single-use nonce, the phone's signature); the
  service answers with a lease it signs (`SeatLeasePayload`); `SeatRecord` is the portal's row for
  one phone.
- Plan [MS](MS-editing-a-procedure-on-the-phone.md): the on-phone procedure editor, saved versions,
  and `ProcedureChanges` (a change in words, one row per change). This plan needs MS P0–P1.
- Plan [MN](MN-answers-the-app-can-check.md) and Plan [H](H-custom-vault-import.md): the procedure
  checks (`VaultValidator.validateProcedureGraph`, `ProcedureAnswerValidator`).
- Plan [FP](FP-team-learnings.md) (team learnings, built) and Plan
  [JL](JL-procedure-deviations-and-learning-round-trip.md) (drafted): what a technician found or did
  differently, sent for review.
- Plan [JI](JI-apprentice-support.md) (drafted): the apprentice's profile and the journeyman.
- Plan [CT](CT-org-configuration-profiles.md): identity is per person, policy is per device.

---

## Trigger

A partner asked whether procedures sent from the portal could be locked or unlocked for editing
per phone: apprentices can't change them, experienced technicians can, and those technicians can
push their changes out. Today:

- Procedures reach every phone in a company through its company vaults (LR), per company.
- No phone can edit them. MN's rule editor and MS's editor are for a vault the person made or
  imported (`VaultAuthoring.isOwned`), and a company vault is not one.
- Nothing grants anything per phone. A company has one signed profile, and every enrolled phone
  follows it. The portal does keep a row per phone (`SeatRecord`), which already reports the vault
  versions that phone holds.
- Nothing carries a procedure change back up. Team learnings go up for review as findings, not
  edits.

The experienced technician who finds a better order of steps on a job has to tell the office, and
someone re-uploads the vault.

## What exists (verified 2026-11-21 on `origin/main` eac4c9fab)

- **Seats.** `SeatClaimRequest` / `SeatRenewRequest` / `SeatReleaseRequest` inside a `SeatEnvelope`,
  verified against the phone's P-256 key (`SeatRecord.devicePublicKey`). `SeatLeasePayload` has five
  fields (`deviceKeyHash`, `enrolmentId`, `issued`, `licenseIDHash`, `notAfter`), and its comment
  says no name, no device model, no location. A renewal may carry `vaults: [{vaultId, version}]`
  (LR P2), disclosed in the privacy manifest and the in-app copy.
- **Company vaults.** A catalog signed for the company (`CompanyVaultContract`), a pointer in the
  profile with a `generation` raised on every change, read at launch and on every foreground. Packs
  are signed by the pack-catalog key on the service, so the service can sign a new version itself.
  A row may be a publisher's vault (`publisher`, possibly `sealedCore`) or a company layer
  (`extends`), which may not replace a publisher's file.
- **Editing.** `VaultAuthoring.isOwned` excludes a vault with a company layer, a pack or a receipt.
  The technician overlay exists on a company vault (it wins over the baseline and the layer), but no
  procedure editor writes to it.
- **Identity.** No user account. `Config.technicianDisplayName` names the technician on records;
  JI's apprentice profile is drafted, not built.
- **Shared checks.** `VaultPackRules` is already the same code in the app and in
  `Tools/LicenceIssuance`. The procedure checks are app-only.

## Design

### 1 · The grant

The portal sets, per seat, how that phone may treat the company's procedures (decision 1):

| Grant | On the phone |
|---|---|
| **Run** (default for a new seat) | Runs the company's procedures. Can still report a step that is wrong or was done differently (FP, JL), as today. |
| **Propose** | Also opens a company procedure in the MS editor, as a draft, and sends the change for review. |
| **Publish** | Also publishes a change: it becomes the company's next version without waiting for review, unless the company has turned on *Review every change* (decision 2). |

The grant travels on the seat's **lease** as a sixth field, `procedures: "run" | "propose" |
"publish"`, signed by the service with the rest (decision 5). The phone reads it at each renewal and
on every foreground when it renews. A lease without the field means *Run*, so an older service and
an older lease change nothing. A phone with no seat (a vault of your own, no company) is unaffected:
its own vaults stay editable as MS has them.

The phone's gate is a convenience. **The service enforces the grant:** it accepts a proposal or a
publish only from a seat whose current grant allows it, checked against that seat's key, at the
moment it arrives. Editing the app, or replaying an old lease, gets nothing through.

Grants are per phone, because the app has no accounts (CT). A phone a person carries is that
person's; a shared pool phone gets what its seat allows, and the portal says so beside the seat.

### 2 · Editing a company procedure on the phone

With *Propose* or *Publish*, the procedure screen on a company vault gains *Edit*. It opens the MS
editor on a **draft** of the procedure as the company has it now:

- The draft lives on this phone in the vault's overlay under `_procedure_drafts/` at the overlay's
  root (never exported, never run), with the company version it started from (`baseVersion`).
- **The phone keeps running the company's version** until a change is published (decision 3). *Try
  it* runs the draft, as MS describes, with nothing kept.
- *Send for review* (Propose) or *Publish* (Publish) sends the draft with a short note.

A procedure in a **publisher's** vault (a partner's product) can be proposed but never published by
the company: the proposal goes to that publisher's inbox in the portal, for their next version, and
the company layer never replaces a publisher file (LV decision 4; decision 4 here).

### 3 · What goes up

A new seat request, `SeatProcedureProposal`, in the usual `SeatEnvelope`:

```json
{ "lease": "<the current lease>", "vaultId": "example-refrigeration", "baseVersion": "12",
  "procedureId": "leak_check", "file": "leak_check.json",
  "procedure": "<the draft, base64 JSON>", "changes": ["Added step Check the fuse", "…"],
  "note": "The fuse fails more often than the sensor on these units.", "publish": false }
```

- At most 256 KiB; the procedure must pass the shared checks (§5) on the phone before it is sent.
- Queued in the offline queue (a new `procedureProposal` op) and sent when there is signal, so a
  change made in a plant room is not lost.
- No technician name, no job, no customer, no photos. The note is the technician's own words, and
  the screen says it goes to the company's reviewers. Disclosed in the privacy manifest and the
  in-app copy in the same PR (telemetry posture rule).
- The reply is `received`, `published` (with the new version), or a refusal with its reason
  (`grantNotAllowed`, `failsChecks`, `vaultNotFound`, `publisherVault` for a publish).

### 4 · Review and publish (service and portal)

In the portal, per company, a **Proposed changes** inbox:

- Each proposal shows the procedure, the seat's portal label (decision 6), the note, and MS's change
  rows **against the company's current version**, not the version it started from. A row that no
  longer applies (its step was removed since) is marked and can't be accepted (decision 7).
- The reviewer accepts or rejects each row, or the whole, with an optional reason. Accepting runs the
  shared checks on the result; it can't be published while they fail.
- Publishing a change (from the inbox, or directly from a phone with *Publish*) builds the next
  company version of that vault, signs it with the pack-catalog key, raises the catalog
  `generation`, and records who published it (the reviewer, or the seat), when, and from which
  proposal. Every phone picks it up as LR delivers any update.
- **History** per vault lists each version with what changed and who published it; *Restore* makes
  an earlier version the next one, so a bad publish is one tap from undone.
- A company setting, *Review every change*, turns every *Publish* into a proposal (decision 2).
- A publisher sees proposals for its own vaults across the companies that use them, without the
  companies' seat labels.

### 5 · Shared checks

`ProcedureGraphRules` moves the procedure checks MN and MS run on the phone into
`Tools/LicenceIssuance` as one pure module the app also compiles, as `VaultPackRules` is now. The
service runs exactly what the phone runs, so a change the phone accepts is never refused on the
service for a different reason, and the reverse.

### 6 · What the technician sees afterwards

On the phone's procedure screen, each sent change has a status: *Sent*, *Waiting for review*,
*Published in version 13*, *Not taken* with the reviewer's reason, or *Overtaken* (another change
was published first and this one no longer applies) (decision 8). The draft is removed once its
change is published or not taken; *Overtaken* keeps it so it can be redone on the new version.

### 7 · The apprentice

A phone with *Run* has no *Edit*. What it has already is the way to say a step is wrong: a team
learning (FP), and when JL lands, *skipped*, *done differently* or *step wrong* bound to the step.
In the portal a reviewer can turn one of those into a proposal on the procedure it names (decision
9), so an apprentice's catch reaches the procedure through someone allowed to change it. When JI's
apprentice profile is built, a phone set up as an apprentice's is shown in the portal so the grant
is not raised by mistake.

## Phases

- **P0 — the contract (headless, both sides' tests).** The lease's sixth field and its absent-means-run
  rule; `SeatProcedureProposal` and its reply; `ProcedureGraphRules` in `Tools/LicenceIssuance`, with
  the app's validator calling it; the pure change classification against a newer version (applies /
  no longer applies); `Contracts/procedure-proposals.md` and golden fixtures read by both sides.
- **P1 — the phone.** Reading the grant; *Edit* on a company procedure (MS editor) with the draft
  store; *Send for review* / *Publish*; the `procedureProposal` queue op; the statuses; the privacy
  manifest and in-app copy.
- **P2 — the service and the portal (private repository).** The grant per seat and the portal label;
  the inbox, row review against the current version, publish, history and restore; *Review every
  change*; the publisher inbox; turning a learning into a proposal.
- **P3 — catalog.** The phone's new strings in the 13 complete languages, in its own PR.
- **P4 — device and pilot pass (owed).** Two phones in one company, one *Run*, one *Propose*, one
  reviewer: a change proposed, accepted in part, published and picked up by both phones; a
  *Publish* phone with *Review every change* off and on; a restore.

P0 and P1 are one PR in this repository after MS P0–P1; P2 is the service's; P3 its own; P4 owed.

## Decisions

1. **Three grants per phone, Run / Propose / Publish, and a new phone starts on Run (recommended).**
   The alternative is two (Run / Edit), with every edit reviewed, which is simpler and gives a
   senior technician no way to fix a procedure on the spot.
2. **Publish goes out at once, unless the company turns on *Review every change* (recommended).**
   Every version is in the history with one-tap restore. The alternative reviews every change in the
   portal, always, which is safer for procedures with safety steps and slower for the fix a lead
   technician needs out today.
3. **A draft never changes what the phone runs until it is published (recommended).** The
   alternative lets the proposer's own phone run their draft, which puts two versions of one
   procedure in one company's records.
4. **A publisher's procedures can be proposed to the publisher, never changed by the company
   (recommended).** The company layer stays add-only. The alternative lets a company copy a
   publisher's procedure into its layer under a new id and change that, which forks licensed content
   the publisher no longer maintains.
5. **The grant rides the signed lease (recommended).** The alternative lists seats in the company
   profile, which every phone in the company would receive.
6. **A seat gets a portal-only label (*Van 3*, *Workshop iPad*) that the company types and that is
   never sent to any phone (recommended).** The alternative shows only the seat's key fingerprint,
   which a reviewer can't tell apart.
7. **A proposal is reviewed against the company's current version, row by row, and a row that no
   longer applies can't be accepted (recommended).** The alternative refuses any proposal made on an
   older version and asks the technician to redo it.
8. **The phone shows what happened to each change, with the reviewer's reason (recommended).** The
   alternative shows *Sent* only, which leaves a technician guessing whether to make the change
   again.
9. **A reviewer can turn a learning or a reported step into a proposal (recommended),** so a *Run*
   phone's catch has a way in. The alternative keeps learnings and procedure changes apart.
10. **Included with the Field Assist team tier (recommended),** since it is how a team keeps its
    procedures right. The alternative is a separate fleet add-on.

## Not in scope

- **Accounts and sign-in per person.** Grants are per phone (CT). A shared phone with several people
  on it gets its seat's grant.
- **Editing anything but procedures from the phone for a company vault** (core files, manuals,
  rules). The same grant could cover them later.
- **Approving on the phone.** Review happens in the portal. A reviewer who wants to approve from the
  field uses the portal on the phone's browser.
- **Merging two proposals into one.** The reviewer accepts rows from each in turn.
- **A company of one with no portal.** Their own vaults are already editable on the phone (MS).

## Risks

- **A change published to every phone at once.** That is the point and the danger. The shared
  checks, *Try it* before sending, the history with restore, and *Review every change* for companies
  that want it are the guards. The record names who published each version.
- **The grant enforced only on the phone.** It must not be: P0's contract tests and P2's service
  tests pin that a proposal or publish from a seat without the grant is refused, whatever the
  request says.
- **What leaves the phone.** A proposal is a procedure and a note. The note box says who reads it,
  nothing else is attached, and the disclosure ships in the same PR as the request.
- **Licensed content.** A publisher's procedure text goes up only to that publisher's inbox, and a
  company never gets a writable copy of it (decision 4). The phone's leak checks for licensed
  content apply to the draft store as to any overlay file.
