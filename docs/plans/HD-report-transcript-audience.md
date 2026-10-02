# Plan HD — Who Receives the Job Transcript

**Status:** 🚧 In progress — P0 (pure policy) + P1 (exporter, delivery, send sheet, organisation keys)
in one PR. **Owed (device):** a report to the office address and one to a customer address through
the real Mail composer, with the attachments opened on a Mac; the send sheet with VoiceOver.

**Related:** Plan [EM](EM-work-record-and-parts.md) (the job report, `DeliveryChannel`,
`DeliverySettings`, the composer), Plan [FO](FO-guided-job-flow-and-job-tab.md) (clips and
`AttachmentBudget`, sign-off, debriefs and the addendum, the send queue), Plan
[GB](GB-field-test-round-3.md) P0 (`TranscriptOriginClassifier` — the app's own prompts are not the
technician's words), Plan [CT](CT-org-configuration-profiles.md) (organisation profiles,
`SettingKey`, ceilings, deny-by-default keys), Plan [HA](HA-settings-hub-and-org-lockdown.md) (the
lockdown envelope). The "Export transcript…" file (support ask, 2026-09-26) is unchanged.

---

## Trigger

Greig, 2026-10-02: the work-order PDF may become an invoice, so it has to be safe to hand to a
customer — and today it prints every technician and assistant line under a "Transcript" heading.
Decided the same day:

1. The work-order PDF loses its Transcript section. Everything else stays.
2. The JSON record keeps the transcript only when the report goes somewhere internal — the
   technician's own office, the organisation's ops platform, the organisation's report address —
   and leaves it out by default for a customer or an address nobody configured.
3. An organisation profile can force the transcript on or off for internal destinations, and can
   forbid it for customer destinations entirely. Without a profile: internal = included,
   customer = omitted.
4. The send screen gets "Include transcript (internal)", off by default, available only for an
   internal destination and within the organisation's policy. On, it attaches a separate transcript
   PDF — who said what and when, labelled as unchecked speech-to-text — beside the work order and
   the JSON, inside the attachment budget and reproducibly.
5. The decisions live in one pure, tested type; the views and the exporter stay thin. No transcript
   content goes anywhere it did not already go.

## What existed (verified 2026-10-02, main at 38d02f5f)

- `SessionExporter.writePDF` printed `layout.section("Transcript")` with every
  `SessionExport.transcript` entry, after Sources Cited. The debrief addendum
  (`writeAddendumPDF`) prints debriefs only — no transcript.
- `SessionExport.transcript: [TranscriptEntry]` is a non-optional key in the JSON, rebuilt from the
  job log's `user_message` (technician lines, via `TranscriptOriginClassifier`) and
  `assistant_message` events. **`SessionExport.citations[].claim` also carries the assistant's whole
  answer text** for every answer that cited a source — transcript content under another name.
  `SessionExport` has no `schema_version`; every field added since has been optional.
- Five places build a job report: `DeliverReportTool` (voice), `JobSendService`'s `buildRequest`
  (the car's queue), "Send report…" on the open job (`FieldAssistSettingsView`) and on a past job
  (`PastJobView`), and `presentDelivery`'s device fallback (no Mail account → share sheet). All go
  through `FieldSessionService.reportDelivery(for:canSendAttachments:sessionId:)` and
  `DeliveryRequest.make`. There was **no send screen** — "Send report…" opened the system composer
  directly.
- Destinations: `DeliveryChannel` (email, messages, whatsapp, telegram, share sheet, endpoint).
  Recipients come from `DeliverySettings` (the device's "Job reports" defaults — the placeholder is
  `office@example.com, dispatch@example.com`), the organisation profile's
  `organizationReportRecipients`, a name or address the technician said (`deliver_report`'s `to`),
  or the share sheet's own picker. The endpoint queues the `WorkRecord` (which has no transcript),
  not the JSON export.
- `AttachmentBudget` partitions clips against `FieldSessionService.reportFileReserveBytes`
  (3 MB, stated not measured, so a re-send reproduces the partition).

## Decisions

### Destination audience (P0)

`ReportTranscriptPolicy.audience` — two audiences, office and customer, decided from configuration
and never from the content:

| Destination | Audience |
|---|---|
| The organisation's endpoint | Office (the ops platform) |
| Email / Messages / WhatsApp / Telegram where **every** recipient is a configured office address — the device's Job reports defaults or the organisation's report recipients | Office |
| Any other address — one the technician named, an empty list | Customer |
| The share sheet | Customer — the app cannot see where it goes |

Addresses compare case-insensitively; phone numbers compare by their digits. **Deny by default:**
one unknown recipient makes the whole report a customer report.

**The technician's opt-in** ("a customer email/share sheet = customer unless the user opts in"): the
send sheet offers "This is going to my office" when the derived audience is customer and the channel
carries files. On, the report is treated as internal. This is the one honest answer for the share
sheet (AirDrop to the office Mac, the firm's drive), which the app cannot see into.

### What each audience gets

| | JSON `transcript` | Assistant text in `citations[].claim` | Transcript PDF |
|---|---|---|---|
| Office, no profile | included | kept | off by default; the technician may add it |
| Office, profile `always` | included | kept | attached, locked on |
| Office, profile `never` | omitted (`organisation_policy`) | removed | none, locked off |
| Customer | omitted (`customer_destination`) | removed | none — the toggle is shown disabled with the reason |
| Channel that carries no files (WhatsApp, Telegram, endpoint, Messages that cannot attach) | n/a — no JSON travels | n/a | hidden, with the reason |

The work-order PDF prints no transcript for anybody, so the customer-facing document is the same
whichever audience the report was for.

### JSON schema (backward compatible)

- `transcript` stays a **present, non-optional key**: an empty array when omitted, so any reader
  that decoded it before still decodes it.
- New optional `transcript_included` (`true`/`false`) and `transcript_omitted_reason`
  (`customer_destination` | `organisation_policy`). Absent on records written by earlier builds,
  which always included it. An archive export (the field-session tool, records owed when leaving an
  organisation) is the office audience and writes `transcript_included: true` unless the profile
  says `never`.
- When omitted, `citations[].claim` is null — the citation, the source and whether it was opened
  stay. No `schema_version` is introduced: the record never had one and every addition so far has
  been an optional key.

### Organisation control (P1)

Two `SettingKey`s, following CT's kinds:

- `organizationReportTranscriptInternal` — **profile-owned string**, `always` or `never`. Absent:
  the technician decides (JSON included, PDF toggle off by default). Profile-owned rather than a
  ceiling because it moves both ways (`always` attaches more), exactly like
  `organizationJobReportChannel`; any other value is a named drop.
- `organizationForbidsCustomerTranscript` — **ceiling pinned to true**. On, only configured office
  destinations count as internal: the "This is going to my office" opt-in is withdrawn, so a
  transcript can never leave for an address the organisation did not set up.

### The send sheet

"Send report…" (open job and past job) now opens a short sheet before the composer: where the
report goes and to whom, which audience that is, the office opt-in when it applies, "Include
transcript (internal)" in its state (available / locked on / locked off / unavailable with the
reason / hidden with the reason), and one line saying what the data file carries. Continue opens the
same composer as before. The voice and car paths have no sheet: they use the defaults (no transcript
PDF unless the profile says `always`; JSON by audience).

### Attachment budget

The transcript PDF is a report file, so it takes room **before** any clip: the partition reserves
`reportFileReserveBytes + transcriptFileReserveBytes` (500 kB, stated not measured — a text-only PDF
of a long day is well under it) only when the transcript PDF is attached. Same job, same channel,
same choice → same partition, so a re-send reproduces the report.

### The device fallback

When `presentDelivery` has to fall back to the share sheet (no Mail account, no Messages), a report
prepared with transcript content is rebuilt for the share sheet, so the audience follows the route
the report actually leaves by. The technician's office opt-in, if they gave it, is carried over.

### Known limitation

Mail and Messages let the technician add recipients after the composer opens; the app cannot see
that. The audience is decided from the addresses the report was prepared for, and the sheet says the
transcript goes to whoever is added.

## Phases

- **P0 — `ReportTranscriptPolicy`** (pure): audience, the decision table above, sheet copy.
  `ReportTranscriptPolicyTests`.
- **P1 — wiring:** exporter (PDF section removed, JSON fields, transcript PDF writer reusing
  `JobTranscriptExport`'s lines), `reportDelivery`/`DeliveryRequest`/audit payload, the send sheet,
  the two `SettingKey`s with review copy, the device fallback, privacy page copy. Tests on the
  rendered PDFs (PDFKit text), the JSON, the partition and the profile keys.

## As built

(Filled in when the PR lands.)
