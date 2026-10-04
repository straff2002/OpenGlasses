# Recorded-session contract — draft v1 (shared rules and fixtures built; signed messages and transport not)

Drafted 2026-10-02 with Plan [HE](../docs/plans/HE-recorded-session-action-map.md). This is the
agreement between the phone app and Avenkin Office about a recorded job: what the phone sends,
what the office acknowledges, and the platform-neutral rules both sides must compute identically.
It is self-contained so it can be carried into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*.

**What exists (2026-10-05).** The phone repository holds reference code and fixtures for the parts
that need no key and no transport: the timeline and transcript files (§4, §5), the chunk rule
(§3), and the shared rules (§7). The fixtures are in `Contracts/fixtures/` —
`recorded-session-timeline-v1.json`, `recorded-session-transcript-v1.json`,
`walkthrough-segments-v1.json` (the segments §7.3 means by "step-like"), `action-events-v1.json`,
`agreement-v1.json`, `cross-reference-v1.json` — and `Contracts/tests/test_recorded_session_contracts.py`
runs the reference code against them. Everything in them is fictional. Where §7 leaves a detail
open — what a word is, the stop-words, the stemming, how far a negation reaches, whether an edge
counts, the order rejections are tried in, how rows are named — the fixture's `rules` block and
its cases are the reference until this text is revised to say the same; the choices are listed in
Plan HE under "P0 as built". **Not yet built:** the signed manifest (§3) and the receipt (§6),
their keys and golden fixtures; the transport (§2); anything on the office side. Nothing on the
phone records, bundles or sends a recorded job yet.

## 1. Roles

| | Phone | Office |
|---|---|---|
| Records, builds the timeline and transcript, marks candidate spans | ✔ | |
| Packages and sends a bundle; keeps it until acknowledged | ✔ | |
| Verifies, stores, acknowledges | | ✔ |
| Runs a video model, builds the action map and index, hosts review | | ✔ |
| Publishes an approved procedure (as a vault) | | ✔ |
| Shows what came of the recording | ✔ | |

## 2. Trust and transport

- The bundle travels over the managed connection Plan FX defines, between a phone and the one
  office named in its current administrator-signed binding. This contract adds no transport.
- *Assumption (FX, not built):* a phone → office managed folder, send-only on the phone, and an
  outbound guard that serves only files named in a sealed manifest.
- Authority is never taken from the bundle. The office verifies the manifest signature with the
  phone application key it already holds from the binding; the phone verifies office messages
  with the office key from the same binding. Both recheck the binding generation.

## 3. Bundle layout

```
<bundleID>/
  manifest.envelope.json     signed; lists every other file
  timeline.json
  transcript.json
  media/<sha256>.chunk       fixed-size chunks of each media part
```

**Envelope.** Two base64 strings, `payload` and `signature`; Ed25519 over the UTF-8 bytes
`Avenkin.RecordingBundle.v1`, one zero byte, then the exact decoded payload bytes. No JSON
re-encoding at verification. Closed objects: duplicate or unknown keys and non-integer numeric
spellings are refused. Envelope cap 1 MiB.

**Manifest payload.**

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.recording-bundle` |
| `bundleID` | 32 lowercase hex |
| `organizationID`, `enrolmentID`, `officeID`, `generation` | The binding this bundle is for |
| `jobSessionID`, `jobNumber?` | The job it belongs to |
| `createdAt` | Unix UTC seconds |
| `timelineVersion`, `transcriptVersion` | Schema versions of the two JSON files |
| `blurred` | `true` when faces were blurred on the phone before sealing |
| `droppedFrames` | Frames removed because the blur could not process them |
| `consentAt` | When the recorder acknowledged the recording consent |
| `chunkBytes` | Chunk size used (every chunk but a part's last is exactly this) |
| `files[]` | `{path, bytes, sha256, role}`; `role` ∈ `timeline`, `transcript`, `media` |
| `parts[]` | `{partID, track, container, chunks: [sha256…], bytes, sha256}` — concatenating a part's chunks in order yields a file with that digest |

Paths are fixed names or digests; a peer-supplied name never selects a path. Integers are
positive and ≤ 2^53 − 1.

## 4. Timeline (`timeline.json`, version 1)

```
clock:  { wallStart (Unix ms), monotonicZero: 0 }
tracks: [{ track: "video"|"audio", parts: [{ partID, tZero, duration }] }]
gaps:   [{ track, from, to, reason: "stall"|"pause"|"restart"|"filter" }]
events: [{ t, kind, ref?, text? }]
candidates: [{ from, to, certainty: "certain"|"likely", reason }]
```

- All times are seconds from the session's monotonic zero (`t`), to millisecond precision.
- `events.kind` ∈ `turn_started`, `turn_logged`, `assistant_speaking_began`,
  `assistant_speaking_ended`, `tool_call`, `photo`, `procedure_started`, `procedure_step`,
  `procedure_completed`, `capture_silenced`, `capture_passed`, `user_marker`. Unknown kinds are
  ignored by a reader, never refused (forward compatibility — the manifest is closed, the
  timeline is not).
- `turn_logged` carries the speaker, the text, and `precision: "aligned"|"coarse"`.
- **The assistant's words are in events, not reliably in the audio.** The capture is silenced
  while replies play from the phone speaker.
- `candidates` are advisory. The office may ignore them, and must not treat their absence as
  "no procedure".

## 5. Transcript (`transcript.json`, version 1)

`utterances: [{ id, start, end, text, speaker? }]`, times as above. Produced by speech-to-text
and unchecked; the office may re-transcribe, and if it does it keeps the phone's ids for anything
it references back.

## 6. Acknowledgement and status (office → phone)

Same envelope rule, domain `Avenkin.RecordingReceipt.v1`. Payload: `version`, `kind`
(`avenkin.recording-receipt`), `bundleID`, `manifestSHA256`, the binding fields, `receivedAt`,
`status`.

- The office sends `status: "received"` **only after** it has verified the manifest signature,
  every chunk digest and every part digest, and committed the bundle durably. Transport
  completion is not receipt.
- The phone deletes nothing before a verified `received`. A repeated receipt is harmless.
- `status: "refused"` carries a closed `reason` (`signature`, `binding`, `digest`, `too_large`,
  `policy`). The phone keeps the recording and tells the technician.
- Later, optional status for the same bundle (§8): `reviewed`, `published`, `rejected`.

## 7. Rules both sides compute the same way

These are pure and platform-neutral. The phone repository holds reference fixtures so an office
implementation — and any later phone-side analysis — can be checked against the same answers.

### 7.1 Action events

```
action_events: [{ id, start, end, action, object?, tool?,
                  evidence: [{ t }] ,            // moments in the video that show it
                  utterances: [utterance id],     // the model's own claim; advisory
                  confidence }]                   // 0…1
view_limitations: [string], partial_view: bool
```

Produced by whatever model the office uses, under a forced schema.

### 7.2 Validation (reject or repair, never guess)

1. `start < end`, both inside the analysed span and inside a media part (not in a gap).
2. Every `evidence.t` lies within `[start, end]`. An event with no evidence is dropped.
3. Every utterance id exists in the transcript.
4. `confidence` in 0…1; missing confidence is treated as below the floor.
5. `action` is 1–200 characters; `object`, `tool` ≤ 80. Unknown fields are dropped.
6. Below the confidence floor (0.4) an event is kept and marked `low_confidence`; it is never
   used for compliance and never shown as fact.

Fixture: `action-events-v1.json` (valid, reversed times, evidence outside the span, unknown
utterance, no evidence, missing confidence) with the expected result of each.

### 7.3 Agreement (recomputed locally — the model's `utterances` are not trusted)

For each validated event, against the transcript:

- **`confirmed_by_speech`** — an utterance overlaps `[start − 5 s, end + 5 s]` **and** shares at
  least one content token with `action`/`object`/`tool` after normalisation (lowercase, strip
  punctuation, stop-words removed, simple stemming), with no negation attached to that token in
  the utterance ("don't remove the cover" does not confirm "remove cover").
- **`seen_not_said`** — otherwise.

For each step-like utterance (the segmenter's step segments) with no validated event overlapping
its window: **`said_not_seen`**.

Fixture: `agreement-v1.json` — the three labels, the negation case, the window edges, a
low-confidence event (labelled, but flagged).

### 7.4 Cross-reference index

Rows of `{ rowID, step?: { procedureID, stepID }, utterances: [id], video: { partID, from, to },
keyframes: [{ t }], events: [id], agreement }`.

- A row never spans a gap.
- A row refers to media by part and time, never by file path, so the index stays valid when the
  media is archived or deleted; a consumer shows the words and keyframes and says the clip is gone.
- Built deterministically from the timeline, transcript and validated events: same inputs, same
  rows, same order (by `video.from`, then `rowID`).

Fixture: `cross-reference-v1.json`.

## 8. What the office does (requirements, implementation-neutral)

1. **Ingest** — verify, store, acknowledge (§6).
2. **Analyse** — optionally run a video-capable model over the candidate spans or any span a
   reviewer chooses, behind a provider seam (a local model, or a cloud model; native video or
   sampled frames). The output is §7.1 and is validated by §7.2 before anything else sees it.
3. **Agreement and index** — §7.3 and §7.4, computed by the office, not by the model.
4. **Review** — a person sees each step beside its words and its clip, with the agreement label,
   and can edit, reorder, merge, split, accept or discard. Nothing unreviewed reaches a technician.
5. **Safety content** — a safety note in a published procedure must be the recorded person's own
   words (linked to utterances) or a cited line of the vault's safety file, or be written and
   signed for by the reviewer. **Never from video alone.**
6. **Publish** — an approved procedure goes out as a vault archive through the existing signed
   manual-assignment path, and must pass the same procedure-graph validation the phone's vault
   importer applies (entry exists, targets resolve, no non-terminal dead end, a terminal is
   reachable). The phone installs it like any assigned vault. A draft is never live.
7. **The "observed" record** — what was seen on a job is an internal record. It is never added
   to a customer's work order; the audience rule the phone applies to transcripts (office yes,
   customer no) applies to it.
8. **Compliance** — comparing the action map with the procedure the job ran is advisory and
   later. Three answers only: *observed*, *not observed*, *unclear*. "Not observed" is not "not
   done": a head-mounted camera misses what the hands do out of frame. Never a verdict on a
   safety-critical step.
9. **Status back** — `reviewed`, `published` (with the vault id and version), `rejected`.

## 9. Privacy duties of the office

- A bundle with `blurred: false` holds identifiable people on a customer's premises. It is the
  organisation's data, held on the organisation's computer.
- **Before any frame or clip leaves the office for a cloud model, faces are blurred**, and the
  audio track is not sent — words go as text. A local model needs neither.
- Organisation policy decides whether cloud analysis is allowed at all, and which provider.
- Retention is the organisation's decision; the office must be able to delete a bundle's media
  while keeping its index, and to delete everything for a job.
- The office never forwards a bundle to another phone.

## 10. Open points

- Chunk size (proposed 32 MiB) and whether the transport's own block resumption makes chunking
  redundant — decide when FX's phone → office folder exists.
- Whether `received` should also be sent per part, so a phone can free space early.
- Whether the office should return the action map to the phone at all (v1: no).
