# Job file contract — format 2, draft (reference implementation, fixture and the phone's import; no office writes it yet)

Drafted 2026-10-05 for Plan [HO](../docs/plans/HO-office-delivery-phone-half.md) P0b. This is the
agreement between an office and the phone app about a job sent as a file (`.ogjob`): what format
2 adds to format 1, what its signature covers, and what makes two files the same job. It is
self-contained so it can be carried into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*.

**Built so far:** `Transport/mobile-core/jobfile` reads and writes format 2 — the outer file,
the signature, the job's identity and how two identities relate — and makes the golden fixture
in §8. **The phone app reads both formats** (Plan HO P0b, 2026-10-05): `JobFileValidator` opens
a format-2 file under the rules here, `JobFileSignatureCheck` verifies its signature over the
exact bytes, the job ahead and then the visit's record keep `job_id`, `revision` and the digest
of the job's bytes, and `JobFileService` applies §5. That is tested headless against the golden
fixture; no office writes format 2 yet, and no format-2 file has been opened on a physical
phone. Two things in §5 the phone does not do yet are marked there.

## 1. What a job file is, in either format

A small JSON document that **proposes** a job ahead. It cannot start a job, change equipment,
create a task or send anything, and nothing is saved until the technician reads the review and
taps to add it. That is unchanged: an office's signature, or the file having arrived over the
[managed connection](README.md), never skips the review.

Format 1 is as the app reads it today: one object with `format` (`openglasses.job`),
`format_version` (`1`), the job's fields and an optional `signature`, signed over a canonical
re-encoding of the fields. It has no identifier of its own. Format 1 **stays readable**, and a
format-1 file is never upgraded in place: it is what it was when it arrived.

## 2. Why format 2

Three things format 1 cannot say:

| Gap | What it costs |
|---|---|
| No identifier the office assigned | The phone matches jobs by the job number a person typed, which two jobs can share and one job can change. A report cannot say which of the office's jobs it answers |
| No revision | A corrected job is a second job, or an overwrite the technician is asked about; an old copy arriving late can replace a newer one |
| The signature covers a re-encoding | Each side must reproduce the other's JSON encoder byte for byte, and the signature is not separated from anything else the organisation's key signs |

## 3. The file

One JSON object with these members and no others:

| Member | Meaning |
|---|---|
| `format` | `openglasses.job` — the wire identifier, unchanged |
| `format_version` | `2` |
| `job` | The job's exact bytes (§4), standard-alphabet padded base64 |
| `signature` | Optional. `{"algorithm":"ed25519","value":"<base64>"}` and no other member |

The whole file is at most 65,536 bytes. Unknown members, trailing data and a member named twice
in any object, at any depth, are refused. A format-1 reader sees a job file at a version it does not know and says so; it does
not mistake it for something else.

**The signature** is Ed25519 over the UTF-8 bytes `Avenkin.JobFile.v2`, one zero byte, then the
exact decoded `job` bytes. Nothing is re-encoded at verification: the bytes signed are the bytes
carried. The key is the **organisation's** job-signing key, which the phone has from its signed
organisation profile — the same key, held the same way, as for format 1. The domain means a
format-2 signature is not a format-1 signature, a managed-job signature or anything else that
key or any other has signed.

## 4. The job

The decoded `job` is one JSON object. Two members are new and **required**:

| Member | Meaning |
|---|---|
| `job_id` | The office's identifier for the job, stable for its whole life: 1–80 ASCII letters, digits, dot, underscore or hyphen, excluding `.` and `..`. It names nobody and is not shown as the job number |
| `revision` | A positive integer in plain decimal, at most 2^53 − 1, higher for each later version of the same job |

The rest are format 1's, with format 1's meaning and limits: `job_reference`, `site`
(`customer`, `address`, `contact`), `fault_report`, `equipment` (up to 10 of `model`, `serial`),
`scheduled_for` (ISO 8601), `notes`, `attachments` (up to 10 of `name`, `reference`; named,
never embedded) and `issued_by`. `format`, `format_version` and `signature` are members of the
file, not of the job. A member not listed here is refused, as in format 1: a file that carries
something the phone cannot show is a file whose review would not be the whole truth. Text is
plain — no markup, no control characters beyond a line break in `fault_report` and `notes` —
and within format 1's length limits. A job needs a job number, a site or a fault report.

`job_reference` remains the number a person knows the job by. It may change between revisions;
`job_id` may not.

## 5. One job, its revisions, and the same file twice

A job's **identity** is its `job_id`; its **version** is its `revision` and the SHA-256 of its
exact `job` bytes. When a file arrives for a `job_id` the phone already holds:

| Arriving | The phone |
|---|---|
| A higher `revision` | Shows it in the review as a revision of that job, not a second job, and, when the technician accepts it, replaces the job ahead in place. *Not yet:* the review shows the whole of the new revision and says which revision it replaces; it does not pick out what changed |
| The same `revision`, the same bytes | Has this job already. It is one job, however many times and by whatever route it arrives — in particular when an office issues a job again under a new managed message after a binding renewal |
| The same `revision`, other bytes | Refuses it as a conflict. Laying the same words out differently is other bytes |
| A lower `revision` | Refuses it. An older revision never replaces a newer one |

*Requirement on the office:* it never issues two different jobs under one `job_id` and
`revision`, and it changes a job only by issuing a higher revision.

**A job already started.** A revision that arrives after the technician has started the job
does not change the job in progress or its record. It is shown as information on that job. How
an office sends an update or a note to a job in progress is Plan HN's contract, not this one.
*Not yet:* the phone refuses such a file with a sentence saying the job has been started, and
shows nothing on the job. The same revision arriving again for a started job is still one job.

**Signed and unsigned.** Whether an unsigned file may be offered at all is the phone's existing
rule: refused in medical mode and where the organisation's profile requires its signature,
otherwise offered and said to be unsigned. In addition, in format 2: an unsigned file, or one
whose signature this phone cannot check, never revises a job that arrived signed. Its `job_id`
is only a claim.

## 6. What a report says about the job

A record the phone sends back names the job it was written against. The
[report](office-reports.md) carries `jobID` and `jobRevision`: the `job_id` and `revision` of
the file the job was added from, or empty and `0` for a job that began any other way — typed on
the phone, or from a format-1 file. *Requirement on the office:* it matches a report to its job
by `jobID`, and uses `jobRevision` to see when the technician worked from a revision that has
since been replaced. The job number in the record is for people.

## 7. With the managed connection

A [managed job](README.md) names its job file by digest and size, whatever the file's format, so
format 2 travels there unchanged. The two signatures say different things: the office
application key's signature on the managed message says which office sent these bytes to this
phone; the organisation's signature on the job file says the organisation issued this job. The
managed message's own `messageID` and `sequence` order deliveries; `job_id` and `revision` say
which job, and which version of it, a delivery carries. Two managed messages that carry the same
file are one job (§5).

## 8. Fixture

`Contracts/fixtures/job-file-v2.ogjob`, made by `jobfile.Fixtures()` and kept current by that
package's tests: `job-2031` at revision 2, signed with a fictional organisation key whose seed
is the SHA-256 of the public label `Avenkin public fixture organisation job key v1`. It has no
authority.

```
go -C Transport/mobile-core test -tags noassets ./jobfile/
JOBFILE_WRITE_FIXTURES=1 go -C Transport/mobile-core test -tags noassets ./jobfile/   # regenerate
```

Negative cases, covered in the Go tests and in the app's own tests (`JobFileFormat2Tests`): a file at
another format version; an unknown or duplicate member of the file or of the job; trailing
data; a `job` that is not base64 or not an object; a missing, non-identifier or path-like
`job_id`; a missing, zero, fractional or quoted `revision`; a signature by another key, with no
domain, under another message's domain, or over a re-encoding of the same job; and, for a job
held, a lower revision, and other bytes at the same revision.

## 9. Open points

1. **Attachments.** Format 2 still only names them. Job attachments are to travel in the `bulk`
   folder after the job (Plan HO, decided 2026-10-04); how a job names bytes that arrive there
   is that phase's contract and may need a later format version.
2. **A started job.** §5 leaves a revision of a job in progress as information only. Plan HN
   decides what an office can change once work has begun.
3. **Unsigned format 2.** This draft keeps format 1's rule and lets an unsigned format-2 file be
   offered where policy allows. Whether format 2 should always be signed is undecided.
4. **Withdrawing a job.** Nothing here cancels a job ahead. A revision can say so in words; a
   signed cancellation is not designed.
