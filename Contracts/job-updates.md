# Job update contract — draft v1: an update on a job the phone already has (messages and fixtures; no phone half yet)

Drafted 2026-10-05 for Plan [HO](../docs/plans/HO-office-delivery-phone-half.md) P3; the design
it serves is Plan [HN](../docs/plans/HN-job-updates-and-several-open-jobs.md) §2. This is the
agreement between the phone app and Avenkin Office about one thing: the office telling a phone
something new about a job that phone already has — a part's state, a new time, a note — and the
phone saying it has it. It is self-contained so it can be carried into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*.

**Built so far.** `Transport/mobile-core/jobupdate` implements both messages — signing, the
two-step signing a phone needs, the signing an office key-holder does over exact bytes, and
each side's checks — and the golden fixtures are in §8. **Nothing on the phone reads an update
yet**, the phone transport does not look in `control/updates/`, and no office sends one.

**Builds on, unchanged:** the [managed folders](office-folders.md) and the peer binding they
are opened under, the [job file](job-file.md) (format 2's `job_id` is what an update names),
and the phone application key that signs every phone receipt.

## 1. What an update is, and is not

- **Information about a job the phone holds.** It is kept, shown against the job it names, and
  receipted. That is all verifying one authorises.
- **It never edits a job.** A new time is shown as the office's new time; a part's state is
  shown beside the job. Changing what the job *is* — its site, its fault report, its equipment,
  its attachments — is a new revision of the [job file](job-file.md), which the technician
  reviews.
- **It never starts, pauses or opens anything.** Reading one is the technician's act.
- **Its text is untrusted content.** It is shown, and may be read out, as the office's words. It
  is never an instruction to the phone or to a model.
- **It is not a conversation.** A phone's reply to the office is not in this version (§7).

## 2. Signed bytes

Each message is the same envelope as every other office message: a closed JSON object
`{"payload": "<base64>", "signature": "<base64>"}`, standard base64 with padding, whose signature
is Ed25519 over **the domain, one zero byte, then the exact decoded payload bytes**. A payload is
a closed, flat JSON object: exactly the members listed, each once, each a string or an integer
in plain decimal. **Every member is always present**: one that does not apply is the empty
string or `0`. A verifier checks the signature over the bytes as they arrived and never
re-encodes. An envelope is at most 16 384 bytes.

| Message | Domain | Signed by |
|---|---|---|
| Job update | `Avenkin.JobUpdate.v1` | The office application key the binding names |
| Job update receipt | `Avenkin.JobUpdateReceipt.v1` | The phone application key the binding names |

Both keys come from the freshly verified peer binding, never from the message.

## 3. The update

Published by the office at `control/updates/<updateID>.envelope.json`.

| Member | Meaning |
|---|---|
| `version` | `1` |
| `kind` | `avenkin.job-update` |
| `updateID` | 32 lowercase hexadecimal characters, chosen by the office, never reused |
| `organizationID`, `enrolmentID`, `officeID`, `generation`, `officeTransportID`, `phoneTransportID` | The binding it is sent under. All six must equal the binding the phone holds now |
| `jobID` | The office's identifier for the job: the `job_id` of the format-2 job file |
| `sequence` | A positive integer, **within that job**: the office's order for its updates on it |
| `issuedAt`, `expiresAt` | Seconds since 1970. Valid from `issuedAt` until just before `expiresAt`; at most 30 days apart |
| `updateKind` | A lower-case word: a letter, then letters, digits or hyphens, at most 32 characters. This version defines `parts`, `schedule` and `note` |
| `body` | Text, at most 4 000 bytes of UTF-8; line feeds allowed, no other control character |
| `part` | For `parts`: what the part is, one line, at most 200 bytes |
| `quantity` | For `parts`: how many, `0` when not stated, at most 1 000 000 |
| `partState` | For `parts`: `ordered`, `dispatched`, `arrived`, `substituted` or `unavailable` |
| `expectedOn` | For `parts`: a calendar date `YYYY-MM-DD`, or empty |
| `scheduledFor` | For `schedule`: the new time, seconds since 1970 |
| `scheduledUntil` | For `schedule`: the end of a window, later than `scheduledFor`, or `0` |

What each kind carries:

| `updateKind` | Required | Optional | Must be empty |
|---|---|---|---|
| `note` | `body` | — | every `parts` and `schedule` member |
| `parts` | `part`, `partState` | `quantity`, `expectedOn`, `body` | `scheduledFor`, `scheduledUntil` |
| `schedule` | `scheduledFor` | `scheduledUntil`, `body` | every `parts` member |
| any other word | — | any member, each by its own rule | — |

**A kind this version does not define is not refused.** It verifies if every member obeys its
own rule, and the phone keeps it and shows its `body` as a note. *Requirement on the office:* a
later kind that needs a member not in this table is a new version of the payload, not a new
word in this one — a v1 phone refuses a payload with a member it does not list.

The phone accepts an update only if: the envelope and payload are closed and in form; the
signature verifies under the binding's office application key; the six binding members equal
the binding held; every member obeys the table; and now is inside the window.

## 4. Order, and the same update twice

- **A sequence is taken once.** The phone keeps each update under its job and sequence. The same
  bytes again are the same update: nothing new is kept and the same receipt is given. Other
  bytes at a sequence the phone already holds are a **conflict**: the first stays, the second is
  refused and gets no receipt. *Requirement on the office:* it never signs two different
  updates at one job and sequence.
- **Arrival order means nothing.** Update 3 may arrive before update 2; both are kept, and the
  phone shows them in sequence order. Unlike a job, an update is not superseded by a later one:
  each is something the office said.
- **A gap is not an error.** The phone does not wait for a missing sequence. The office knows
  what the phone has from its receipts.
- **The latest of a kind is the current one.** Where two updates say different things about the
  same matter — two times, two states for one part — the higher sequence is what the office
  says now, and the phone shows the earlier ones as earlier.

## 5. The job it names

An update names a job by `jobID`. The phone holds a job under that identifier once a format-2
job file with that `job_id` is on its list of jobs ahead or has been started.

- **Held, ahead or open:** the update is shown on that job.
- **Held and finished:** the update is kept and is not shown as live: the job's record is
  closed.
- **Not held:** the update is kept and waits. A job may still be in the technician's review, or
  arrive after its update. If a job with that identifier is later held, the update is shown on
  it. An update whose job never arrives is dropped when it expires.

Whichever it is, the update is committed and receipted; the receipt says which (§6).

## 6. The receipt

Published by the phone at `records/updates/<updateID>.envelope.json`, once, after the update is
verified and durably committed to the phone's own store. **It says the phone has the update. It
does not say anyone has read it**, and no message in this version does (§9).

| Member | Meaning |
|---|---|
| `version` | `1` |
| `kind` | `avenkin.job-update-receipt` |
| `updateID` | The update's |
| `updateSHA256` | SHA-256 of the update's exact payload bytes, 64 lowercase hexadecimal characters |
| `organizationID`, `enrolmentID`, `officeID`, `generation`, `phoneTransportID` | The binding, as in the update |
| `jobID`, `sequence` | The update's |
| `outcome` | `received`: verified and committed. The only outcome |
| `jobState` | What the phone held for that job when it committed the update: `held`, `finished` or `unknown` |
| `receivedAt` | Seconds since 1970, by the phone's clock |

The phone signs in two steps, because its application key lives in device-only storage outside
the transport: the transport offers the exact payload bytes, the application signs them under
the receipt domain, and the transport seals and publishes them. The signer signs nothing but a
closed payload of this kind.

The office accepts a receipt only if it is closed and in form, signed by the binding's phone
application key, and every one of `updateID`, `updateSHA256`, the binding members, `jobID` and
`sequence` equals its own record of the update it sent. *Requirement on the office:* it shows
*sent*, *delivered* (this receipt) and nothing further as three different things; a delivered
update has not been read.

A refused update — out of form, another binding, expired, a conflict — gets no receipt. It is
recorded once on the phone with a bounded reason and not looked at again until its bytes
change.

## 7. Deliberately left out

- **A reply from the phone.** The first free-text message from a phone to an office needs its
  own confirm-before-send and its own contract.
- **Attachments on an update.** A file for a job travels as the job's own attachment, named by
  a new revision of the job file ([bulk content](office-bulk.md) §5).
- **Applying an update.** Nothing here changes a job's booked time or its parts list.
- **A notification's wording**, and whether an update's text may appear on a locked screen.
- **Withdrawing an update.** The office sends another that says so.

## 8. Fixtures

In `fixtures/`, made by `jobupdate.Fixtures()` and checked byte for byte by its tests. Keys are
derived from public labels (seed = SHA-256 of the label) and have no authority; they are the
check-in fixtures' office and phone keys, and the binding is the check-in fixtures' binding.
The clock is 1 800 000 000.

| File | What it is |
|---|---|
| `job-update-parts-v1.json` | Sequence 1 on job `job-2031`: a fan motor, quantity 1, dispatched, expected 2027-01-18, with a line of text |
| `job-update-schedule-v1.json` | Sequence 2: the visit moved to three days on, with a two-hour window |
| `job-update-note-v1.json` | Sequence 3: a two-line note |
| `job-update-receipt-v1.json` | The phone's receipt for the parts update, `jobState` `held`, a minute later |

`job-2031` is the job in `job-file-v2.ogjob`.

## 9. Open points

1. **Does the office learn an update was opened?** The phone can record when it was first
   shown. Sending that is useful to an office and is a read receipt on an employee; it is not in
   this version, and adding it is a second receipt, not a change to this one.
2. **Which job a senior's support belongs to** — an update on the technician's job, or a job of
   its own — is Plan HN's question; this contract carries either.
3. **Thirty days.** A job waiting on a part may wait longer than an update lives. An update
   that expired before the phone took it is gone; *Assumption:* the office re-issues what still
   matters under a new identifier and sequence.
4. **An update under an older generation.** After a renewal the binding's generation moves on
   and an update signed under the previous one is for another binding. *Assumption:* the office
   re-signs what the phone has not receipted.
5. **How many.** No cap on updates per job is set here; a phone keeps a bounded number and says
   so in its own half.
