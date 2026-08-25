# Plan DI — Photo Library & Camera Warmup Hygiene

**Status:** 🚧 P1 shipped 2026-08-25 (readWrite-once, not add-only — see Close-out); P2 audit complete below · companion to [DH](DH-local-gemma-keyless-tier.md); together they take everything of value from external PR #331, so it can close with the contributor fully credited

## Why

External PR #331 contains, alongside its Gemma work (extracted by Plan DH), a genuinely
well-shaped photo-library fix: the app requests broader photo-library access than saving needs,
and two services (`CameraService`, `VideoRecordingService`) each carried their own private
`fetchGlassesAlbum()` copy of the album-resolution logic. The contribution centralises saving
in one `GlassesPhotoAlbum` using **add-only** authorization (`PHPhotoLibrary` `.addOnly`) — the
user is prompted once, for the narrowest permission that saving to the Glasses album requires —
with the album resolved by cached local identifier (title-match fallback), the album-exists
race handled (`PHPhotosErrorDomain` 3311), and the `NSPhotoLibraryUsageDescription` string in
the committed plist. Narrower permission is both better UX and a better privacy posture, and
the dedup removes a real divergence hazard.

It cannot merge as-is: the branch predates the recording-persistence work (Plan DA) — which
rebuilt exactly the save paths it touches — and it bundles shared-camera-stream logic
(`stopStreamUnlessShared()` and friends) that main has since superseded with the
`CameraStreamClaims` ownership mechanism. So: port the photo-library half onto current main
**with credit**, and verify-then-drop the stream half.

## P1 — Prompt once via consolidation, ported onto current main

Scope follows the review on #331, which separated the universal fix from the tested-device
workaround:

- **The consolidation is the fix.** Bring over `GlassesPhotoAlbum` (cached-identifier album
  resolution with title fallback, 3311 race handling, image + video save) re-composed against
  today's save paths: `RecordingFiler`'s ordering is law — Documents first, Photos last,
  nothing deleted until a persistent copy exists — and the Photos step goes through the new
  album API. Replace both private `fetchGlassesAlbum()` copies; photo capture and dwell-capture
  save paths route the same way. The double prompt dies because the request now happens in
  exactly one place.
- **Authorization stays `readWrite`, requested once — NOT add-only** unless the review's
  album-churn analysis is disproven on a fresh install: under `.addOnly`,
  `PHAssetCollection.fetchAssetCollections` returns empty (it needs read access), so the cached
  identifier is discarded on every save, title lookup fails, and `createAlbum()` runs again —
  an empty "Glasses" album per photo, or none. If an add-only design that keeps stable album
  targeting exists, it may be adopted with that repro test as the gate; otherwise readWrite
  once is the honest trade and the doc records why.
- **Camera warmup, the half worth keeping**: port the `lastStreamError` early-abort (turns a
  20 s hang into a fast fail — good for everyone) while **restoring the full 20 s attempt-1
  timeout** (the PR's shortened `attempt == 1 ? 10 : 20` sits below the recorded ~15–18 s
  healthy cold-start window, so it made every healthy cold start fail its first attempt); and
  fix the dead branch (`action(consecutiveFailures: attempt - 1)` can only see 0, so
  `resetSession()` was unreachable).
- Plist usage-string changes only as the chosen authorization requires; verify against the
  personal-plist-override gotcha (check the ProcessInfoPlistFile input, not just the committed
  plist).
- Credit the contributor in commit and PR text.

## P2 — Verify the superseded half, take nothing blindly

Walk the remaining #331 hunks (`OpenGlassesApp` stream sharing, `MetaCameraBackend`,
`DwellCaptureService`, `CameraService`) against current main: confirm each is either already
covered (`CameraStreamClaims`, the CV camera-ownership work, DA persistence) or genuinely still
valuable — anything in the second bucket gets its own small follow-up, not a ride-along here.
The deliverable is the audit note in this doc, so closing #331 can say precisely what was
taken, what was superseded, and by what.

## Close-out

**P2 audit — every #331 hunk this plan owns, walked against main (2026-08-25).**

| #331 hunk | Verdict | Detail |
|---|---|---|
| `GlassesPhotoAlbum.swift` (new) | **Taken in P1** | Ported with the album resolution, title fallback and the 3311 race intact. Split into `GlassesPhotoAlbumPolicy` (pure, tested) + a PhotoKit edge; `.limited` restored to the savable set; a failed album-targeted save now retries untargeted instead of losing the asset. |
| `CameraService.saveToPhotoLibrary` + `fetchGlassesAlbum` | **Taken in P1** | Both deleted; the call routes through the shared album. `import Photos` went with them. |
| `VideoRecordingService.saveVideoToPhotos` + `fetchGlassesAlbum` | **Taken in P1** | Same, with DA's `RecordingFiler` ordering untouched — the filer still writes Documents first and the Photos step is still last and still non-fatal. #331's orphaned `albumName` doc comment is not reproduced. |
| `DwellCaptureService` → album | **Taken in P1** | Was `UIImageWriteToSavedPhotosAlbum`, i.e. loose in the camera roll behind its own prompt. Not awaited, so the spoken confirmation can't queue behind a permission sheet. |
| Add-only authorization | **Re-designed** | Ships as readWrite-once. Add-only blinds `fetchAssetCollections`, so every save takes the create path — one "Glasses" album per capture. Recorded as a policy test rather than only as prose. |
| `Info.plist` usage string | **No change needed** | Both keys are already present and accurate for readWrite-once; #331's rewording suited add-only. Verified against the *built* app's plist and its `ProcessInfoPlistFile` input, not just the committed file. |
| `MetaCameraBackend.lastStreamError` + warmup abort | **Taken in P1** | Re-expressed as `CameraErrorPolicy.abortsWarmup` (pure, tested) — deliberately the inverse of `abortsCapture` for the two start-failure errors, terminal conditions left bounded by the timeout. |
| `waitForStreaming(timeout: attempt == 1 ? 10 : 20)` | **Rejected, and reverted where main already had it** | 10 s sits under the device-traced ~15–18 s cold start, so it fails *healthy* starts. Both warmup loops now use `StreamRecoveryPolicy.warmupTimeout`; a test asserts it clears `observedColdStart`. This also removes the same shortened attempt from `capturePhoto`, which predates #331. |
| `action(consecutiveFailures: attempt - 1)` dead branch | **Taken in P1, fixed** | Escalation now runs on the shared `consecutiveRecoveryFailures` counter, so the `resetSession` tier is reachable across calls; a single call's attempt count never could reach it. |
| `AppState.otherStreamConsumersActive()` | **Covered by main** | `CameraStreamClaims` plus the `unclaimedStreamConsumers` closure in `AppState` already give one answer to two readers, and `hasStreamClaims` covers the scene-narration and fingerspelling owners that #331 listed by hand. |
| `stopStreamUnlessShared()` in `returnToWakeWord()` | **Not taken** | Fires after every turn, not at end of session, and doesn't consult claims — with the 15–18 s cold start that is a full cold start per photo question, and it can stop a stream Live Preview or continuous narration is holding. |
| `stopStreamUnlessShared()` after a smart-camera capture | **Follow-up, not built** | The underlying question — how long a stream started *for one capture* should outlive it — is real, but the answer is a `CameraStreamClaims.Owner` for the smart-camera grab with `claimStream`/`releaseStream`, not a fourth hand-rolled consumer check. |
| `Localizable.xcstrings` | **Dropped** | Build extraction only; catalog updates go in their own commit. |
| `Config.swift`, `LLMService`, `LocalLLMService`, `Package*`, `project.base.yml`, the Gemma tests | **Out of scope** | DH owns them. |

When DH P1 and DI P1 are merged, close PR #331 with thanks: what was ported (with commit
links), what the upstream dependency fix made unnecessary, and what main had already solved.

## Non-goals

- The camera/stream refactors themselves (superseded; P2 only audits).
- Any change to recording persistence semantics (DA owns them; this plan only swaps the Photos
  step's authorization and album plumbing).
- Read access to the photo library — **superseded by P1**: album targeting needs it, so the
  shipped default reads the library it writes to. The narrower ask is preserved as an open
  follow-up rather than as a requirement.
