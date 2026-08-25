# Plan DA — Recording Persistence

**Status: ✅ Shipped (2026-08-25)** — `RecordingFiler` (pure naming + collision rule + ordered
destinations behind a `RecordingFileOperating` seam) called from `VideoRecordingService.stopRecording`,
so every path — UI toggle, `video_recording` tool, stream-death auto-stop — files the recording out
of `tmp/` before anything else touches it. `Config.recordingSaveToPhotos` (default on) and
`Config.recordingFolderBookmark`/`recordingFolderURL` with a folder-picker row in Settings; the
"Recording & Transcripts" footer now describes what actually happens. 23 named tests, no Photos and
no recorder involved.

**A recording the user was never told about could simply vanish.** The recorder writes into
`FileManager.default.temporaryDirectory` while it encodes — correct for a file still being written,
wrong for a finished one, because iOS empties that directory whenever it wants the space. Saving was
opt-in via a `autoSaveToPhotos` flag that exactly one caller set: the AI tool. The UI path
(`toggleRecording`) never set it, and on stop did one thing — handed the temporary URL to a share
sheet. Dismiss the sheet and an hour of footage was gone, silently, with the Settings footer still
telling the user that "videos always save to the Glasses album in Photos".

That is the worst shape a data-loss bug can take: the destructive path is the *default* one, the
user's only warning is a screen they have to act on, and the copy they'd been promised was never
made. Nothing about the fix is clever — the recording just has to be somewhere durable before the
user is offered anything.

## What changed

**Persistence is unconditional and ordered by durability.** On stop, in this order:

1. **Move out of `tmp/` into `Documents/Recordings/`** with a timestamped name
   (`Recording_2026-08-24_143012.mp4`). This copy needs no permission, cannot be declined, is
   visible in the Files app, and is backed up. It happens first precisely so that a permission
   prompt or a failing library cannot strand the file.
2. **Copy to the user's chosen folder**, if they picked one — a *copy*, not a move, so the app's
   own folder stays the location we can always find again.
3. **Save to the Photos "Glasses" album**, unless the user has turned that off. Last, because it is
   the destination most likely to be declined and by then the file is already safe.

The share sheet on the UI path is unchanged, but it is now an *offer* rather than the only chance to
keep the recording. Nothing is ever deleted: if a destination fails, the ones that worked stand.

## Pure core

`RecordingFiler` holds everything worth testing and nothing that needs a device:

- **Naming** — `fileName(for:fileExtension:timeZone:)` is a pure function of the stop time; the
  format sorts chronologically as text, which is how the Files app will present it.
- **Collisions** — `uniqueURL(base:exists:)` walks `name`, `name-2`, `name-3`… . Two recordings can
  finish in the same second (a stop-start-stop, or a chosen folder that already holds a file from an
  earlier install) and the older one must not be overwritten. Losing a recording is the whole thing
  this file exists to prevent, so it must not be reintroduced by the fix.
- **Destinations** — `file(_:date:saveToPhotos:)` performs the moves through a
  `RecordingFileOperating` seam, so tests run in a temp directory and can fail a move, a copy, or a
  directory creation on demand.
- **Reporting** — `Outcome` says what landed. `message` is the problem-only note, and it names
  *where the recording is* rather than only what failed, because the point of the safety-net copy is
  that the user can go and get it. `summary` is the positive version, spoken back by the voice paths
  which have no screen to show a path on.

The Photos save deliberately sits *outside* the filer — it is the one destination needing an
authorization prompt and a framework the core has no business linking. `saveToPhotos:` records only
that it was *asked for*, which is what honest reporting needs; the service performs the save against
`Outcome.primaryURL` and writes the result back.

## Thin edges

- `VideoRecordingService.stopRecording` calls the filer immediately after `finishWriting`, then does
  everything else — the transcript sidecar, HIPAA file protection, the URL it returns — against the
  filed location instead of the temporary one. Previously the sidecar `.txt` was written next to a
  file in `tmp/`, so it was orphaned by design.
- `autoSaveToPhotos` is gone. There is no opt-in left to forget.
- `toggleRecording` still offers the share sheet and surfaces `lastSaveNote` on the existing error
  surface when something didn't land. The stream-death auto-stop appends the same note to what it
  speaks — the wearer has no screen.
- `video_recording` reports the destinations that actually took rather than the ones we hoped for.
- Settings gains an "Also Save to Photos" toggle and a "Video Copy Location" folder picker beside
  the existing transcript one, and the footer is rewritten to describe real behaviour. The two
  picker rows share one small row builder; both now hold the chosen folder name in view state, so
  choosing or resetting a folder redraws the row that names it (the transcript row didn't).

## Out of scope

- **Recording quality / bitrate.** `VideoBitratePolicy` already derives it; untouched here.
- **Broadcast and expert-stream paths.** They never wrote a file to begin with.
- **Background upload / offsite sync.** Filing is local. Anything that leaves the device is a
  consent question, not a persistence one.
- **A recordings browser in-app.** The Files app already lists `Documents/Recordings`; a gallery is
  a feature, not a fix for losing footage.

## Testing

`RecordingFilerTests` — 23 tests, no `.shared` service, no Photos, no recorder, no device:
naming and chronological sort; the collision walk and two recordings finishing in the same second
both surviving; the move actually emptying `tmp/`; directory creation; the chosen-folder copy
leaving the app-folder original in place; a failed move never deleting the source; a failed move
still reaching the chosen folder and promoting it to `primaryURL`; a failed copy and an unreachable
folder both leaving the app-folder copy intact; the exact wording of every `message` and `summary`
case, including the run where the app-folder move failed and the note must name the user's own
folder rather than describing it as the app's.

## Follow-ups (not blocking)

- **The app's Documents container is not exposed to the Files app.** `UIFileSharingEnabled` /
  `LSSupportsOpeningDocumentsInPlace` are absent from `Info.plist`, so `Documents/Recordings` is
  durable and backed up but not *browsable*. The copy here says so honestly — it names the folder
  and points at the share sheet and the folder pickers, which are the routes that actually work —
  rather than repeating the older, untrue "reachable from the Files app" claim the transcript
  footer had been making. Turning the keys on would expose the whole container (the face-recognition
  database, the vault, the brain store, HIPAA-protected transcripts) and is its own privacy
  decision, not a persistence one.
- `Documents/Recordings` is shared with `AudioRecordingService`'s meeting `.m4a` files, which is
  deliberate — one folder holds everything the app captured. Nothing enumerates the directory:
  `RecordedSessionStore` only ever touches files named in its own session records, so the video
  files are invisible to it rather than mistaken for sessions.
- Retention: `Documents/Recordings` grows without bound. HIPAA mode already has a retention policy
  for transcripts; recordings should probably join it rather than get their own rule.
- The chosen-folder copy doubles disk use for long recordings. Worth offering "move instead of copy"
  once there is a way to say it in Settings that isn't a footgun.
