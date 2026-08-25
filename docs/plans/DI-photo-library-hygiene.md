# Plan DI — Photo Library Hygiene

**Status:** 📝 Drafted 2026-08-25 · companion to [DH](DH-local-gemma-keyless-tier.md); together they take everything of value from external PR #331, so it can close with the contributor fully credited

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

## P1 — Add-only saving, ported onto current main

- Bring over `GlassesPhotoAlbum` (add-only authorization, cached-identifier album resolution,
  3311 handling, image + video save) re-composed against today's save paths: `RecordingFiler`'s
  ordering is law — Documents first, Photos last, nothing deleted until a persistent copy
  exists — and the Photos step goes through the new album API. Replace both private
  `fetchGlassesAlbum()` copies. Photo capture and dwell-capture save paths route the same way.
- Plist: the add-only usage string; verify against the personal-plist-override gotcha (the
  committed plist is not always the one shipped — check the ProcessInfoPlistFile input).
- **Existing-install caveat, stated in UI copy**: a user who previously granted or denied the
  broader permission must change it in Settings — the PR body itself notes this. Detect the
  limbo states (`denied`, `limited`, legacy readWrite grants) and point at Settings honestly
  rather than silently failing to file.
- Credit the contributor in commit and PR text.

## P2 — Verify the superseded half, take nothing blindly

Walk the remaining #331 hunks (`OpenGlassesApp` stream sharing, `MetaCameraBackend`,
`DwellCaptureService`, `CameraService`) against current main: confirm each is either already
covered (`CameraStreamClaims`, the CV camera-ownership work, DA persistence) or genuinely still
valuable — anything in the second bucket gets its own small follow-up, not a ride-along here.
The deliverable is the audit note in this doc, so closing #331 can say precisely what was
taken, what was superseded, and by what.

## Close-out

When DH P1 and DI P1 are merged, close PR #331 with thanks: what was ported (with commit
links), what the upstream dependency fix made unnecessary, and what main had already solved.

## Non-goals

- The camera/stream refactors themselves (superseded; P2 only audits).
- Any change to recording persistence semantics (DA owns them; this plan only swaps the Photos
  step's authorization and album plumbing).
- Read access to the photo library.
