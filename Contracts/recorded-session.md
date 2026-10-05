# Recorded-session contract — draft v1 (shared rules, signed messages and fixtures built; the phone records, blurs where required, seals and sends in the opt-in build; no office, and no device run, yet)

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
Plan HE under "P0 as built". **The two signed messages have a reference implementation** (2026-10-05):
`Transport/mobile-core/recordingbundle` signs and reads the manifest (§3) and the office's
receipt and later status (§6), with golden fixtures (§11); the connection helper
(`cmd/office-preview`) exposes the office key-holder's signing of a receipt as
`sign-recording-receipt`. The phone's own code for them writes
the golden manifest byte for byte and reads the golden receipts, tested headless; nothing in the
app calls it. **The phone records, seals and sends a bundle, in the opt-in office
transport build** (Plan HE P1 and the headless part of P2, 2026-10-05). "Record this job" writes
the glasses' frames and the microphone into the job's own folder on one clock, behind a recording
consent whose time is the manifest's `consentAt`; stopping builds `timeline.json` and
`transcript.json` (§4, §5) and seals the bundle (§3). The transport publishes exactly what a
sealed manifest lists under `records/recordings/<bundleID>/` and serves nothing else of it, the
phone feeds it a couple of chunks ahead of what the office has taken, and only the office's
verified *received* lets the phone let go of anything. **A bundle is `blurred: true` where the
organisation requires it** (2026-10-05): every picture of every part is put through the phone's
face blur before the bundle is sealed, a picture the blur cannot process is left out and counted
in `droppedFrames`, and the sound is carried over as it was. Everywhere else a bundle is
`blurred: false`. A bundle sealed unblurred before an organisation turned the rule on cannot be
blurred afterwards — it is signed — and is kept on the phone and not sent. The blur has so far
run only over a small movie made in a test. **Not yet built:** anything on the office side.
**No bundle has left a physical phone**, and nothing here has been run on one: what a phone and
glasses have still to show is listed in Plan HE under "P1 as built" and "The blur pass, as built".

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
- **A bundle waits for Wi-Fi, not for the office's own network.** The phone publishes a
  bundle's files on any network the system does not call expensive — never mobile data or a
  personal hotspot — whenever the office is in reach, directly or through a relay. *Requirement
  on the office:* a recording may arrive from anywhere, hours after the job, slowly and in
  pieces; it is shown as on its way, not failed.
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
`Avenkin.RecordingBundle.v1`, one zero byte, then the exact decoded payload bytes, signed with
the phone application key. No JSON re-encoding at verification. Envelope cap 1 MiB.

**One spelling.** The manifest holds lists, so it cannot be a flat object like the other
messages. Instead it has exactly one spelling: the members in the order of the table below (and
of the two list tables), no white space, integers in plain decimal, `blurred` as `true` or
`false`, and no string that needs a JSON escape. A verifier parses the payload, writes it again
that way, and refuses it unless the bytes are identical — which refuses a duplicate or unknown
member, another order, and a number written another way, all at once. Every member is always
present.

**Manifest payload.**

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.recording-bundle` |
| `bundleID` | 32 lowercase hex |
| `organizationID`, `enrolmentID`, `officeID`, `generation`, `phoneTransportID` | The binding this bundle was sealed under |
| `jobSessionID`, `jobNumber` | The job it belongs to; `jobNumber` is empty when the job has none, and otherwise printable ASCII that needs no escape, at most 80 characters |
| `createdAt` | Unix UTC seconds |
| `timelineVersion`, `transcriptVersion` | Schema versions of the two JSON files |
| `blurred` | `true` when faces were blurred on the phone before sealing: every picture in every part listed has been through the blur. Never `true` for a bundle with a part that has not |
| `droppedFrames` | Frames left out because the blur could not process them, across every part. They are in no part of the bundle |
| `consentAt` | When the recorder acknowledged the recording consent |
| `chunkBytes` | Chunk size used (every chunk but a part's last is exactly this), at most 64 MiB |
| `files[]` | `{path, bytes, sha256, role}`; `role` ∈ `timeline`, `transcript`, `media` |
| `parts[]` | `{partID, track, container, chunks: [sha256…], bytes, sha256}` — concatenating a part's chunks in order yields a file with that digest. `track` ∈ `video`, `audio`; `container` ∈ `mp4`, `m4a` |

Paths are fixed names or digests; a peer-supplied name never selects a path. Integers are
positive and ≤ 2^53 − 1, except `droppedFrames`, which may be `0` and is `0` unless `blurred`.

What makes a manifest list exactly its bundle:

- exactly one `timeline` file at `timeline.json` and one `transcript` file at `transcript.json`;
- a `media` file's path is `media/<its sha256>.chunk`, it is no larger than `chunkBytes`, and no
  path appears twice — identical chunks are one file;
- every chunk a part names is a listed media file; every chunk of a part but its last is exactly
  `chunkBytes`; a part's `bytes` is the sum of its chunks'; and every listed media file is in at
  least one part;
- no two parts share a `partID`; at most 256 parts and 4 096 chunks;
- `consentAt` is not later than `createdAt`;
- a bundle with no media — `files` is the two JSON files and `parts` is `[]` — is a bundle.

**The generation.** A bundle may take days to arrive, and the binding may be renewed
meanwhile. The manifest names the generation it was sealed under. *Requirement on the office:*
it accepts a manifest whose generation is the binding's current one or an earlier one it issued
to that enrolment, signed by the phone application key that binding names, and refuses one that
names a generation it has not reached.

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
- **A part is one file holding its pictures and its sound.** The manifest lists it once, as
  `track: "video"`, `container: "mp4"` (as `audio` only when it holds no pictures). The
  timeline's `audio` track names the same `partID`, with the sound's own `tZero` and `duration`.
  Inside the file each track begins at zero at its own first sample, so the sound is offset from
  the pictures by the difference of the two `tZero`s; a reader that needs them in step applies it.
- **A gap** lies between one part of a track and the next, from where the earlier ends to where
  the later begins, with the reason the earlier one ended. A recording carried on after the app
  was closed has a `restart` gap, and the parts after it are placed through the wall clock.
- **A `filter` gap** is on the video track and may lie *inside* a part: a stretch of a second or
  more in which every frame was left out because the blur could not process it. The part's
  `tZero` and `duration` are as recorded; in its file the frames either side of the stretch keep
  their times, so nothing after it has moved. A shorter run of dropped frames is counted in
  `droppedFrames` and not written as a gap — the frame before it is simply shown for longer. A
  part none of whose frames could be blurred has no video: it is listed as `audio` when it has
  sound, and is absent when it has not, and the stretch its video covered is a `filter` gap. A
  reader that tests "inside a part and in no gap" (§7.2, §7.4) needs nothing new for this.
- Events the phone notes as they happen (`turn_started`, the assistant speaking, the capture
  silenced, `tool_call`, `user_marker`) are to the millisecond. Events taken from the job's log
  (`turn_logged` before alignment, `photo`, the `procedure_*` kinds) are to the second: the log
  stamps in whole seconds. `ref` on `photo` is the photograph's file name in the job; on a
  `turn_logged` the log gave no id for, it is `log-N`.
- The transcript's utterances are the phone's own, on-device, one for each ten-second window of
  sound that held words; with no on-device recogniser the transcript is empty and every turn is
  `coarse`.
- `candidates` are advisory. The office may ignore them, and must not treat their absence as
  "no procedure".

## 5. Transcript (`transcript.json`, version 1)

`utterances: [{ id, start, end, text, speaker? }]`, times as above. Produced by speech-to-text
and unchecked; the office may re-transcribe, and if it does it keeps the phone's ids for anything
it references back.

## 6. Acknowledgement and status (office → phone)

Same envelope rule, domain `Avenkin.RecordingReceipt.v1`, signed with the office application
key, cap 8 192 bytes. The payload is a closed, flat object like the other office messages — every
member always present, each a string or an integer in plain decimal:

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.recording-receipt` |
| `bundleID` | The bundle's |
| `manifestSHA256` | SHA-256 of the manifest's exact payload bytes |
| `organizationID`, `enrolmentID`, `officeID`, `generation`, `phoneTransportID` | As the manifest names them: `generation` is the manifest's, not the binding's current one |
| `status` | `received`, `refused`, `reviewed`, `published` or `rejected` |
| `reason` | For `refused`, one of the closed reasons below; otherwise empty |
| `vaultID`, `vaultVersion` | For `published`, the vault the procedure went out as; otherwise empty |
| `at` | Unix UTC seconds, by the office's clock |

Each status is its own file, `control/recordings/<bundleID>.<status>.envelope.json`, so a
published name always holds the same bytes.

The phone accepts one only if it is closed and in form, signed by the office application key of
the binding held, names that binding's organisation, enrolment, office and phone, and its
`bundleID`, `manifestSHA256` and `generation` equal the phone's own record of the manifest it
sealed. A receipt has no expiry: it is a statement of fact about a bundle.

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
- Whether a later status needs an order of its own (`reviewed` before `published`). In this
  version each is an independent statement; a phone shows the latest it holds.

## 11. Fixtures for the signed messages

In `fixtures/`, made by `recordingbundle.Fixtures()` and checked byte for byte by its tests. Keys
are derived from public labels (seed = SHA-256 of the label) and have no authority; they are the
check-in fixtures' office and phone keys, and the binding is the check-in fixtures' binding. The
clock is 1 800 000 000.

| File | What it is |
|---|---|
| `recording-bundle-manifest-v1.json` | The signed manifest of one fictional bundle: `timeline.json` and `transcript.json` are exactly `recorded-session-timeline-v1.json` and `recorded-session-transcript-v1.json`; a video part of three chunks and an audio part of one, at a chunk size of 32 bytes |
| `recording-receipt-received-v1.json` | The office has the bundle, two hours later |
| `recording-receipt-refused-v1.json` | The office refuses it, reason `digest` |
| `recording-receipt-published-v1.json` | A procedure was published from it as `fixture-organisation-vault` 1.0.0 |

The media is not in the repository. The video part's whole bytes are the ASCII sentence
`Avenkin public fixture recording video part v1: eighty-two bytes of nothing at all` and the audio
part's are `Avenkin public fixture audio v1`; cut at 32 bytes they give the chunks the manifest
names.
