# FD P0 — camera readiness consumer inventory

What each UI surface and tool treated as "the camera is ready", what it actually needs, and what it
reads after P0. Line numbers are as at the P0 change; the classification is what matters if they
drift.

Four different facts were being used interchangeably as "ready":

| Fact | What it really says |
|---|---|
| SDK state / `isStreaming` | a stream object exists. Stays true across a doff-pause and across a decoder that has stopped producing. Says nothing about pictures. |
| a non-nil cached still | a picture arrived *once*. Carries no age, so last week's would do. |
| `isStartingStream` | a start is in flight. A button state, never evidence. |
| user intent | somebody wants the camera on. The only correct input for "should I press Start", and the wrong one for "may I answer a question about what is in front of you". |

`CameraReadiness` keeps them apart: `phase` for display, `frameAge` on a monotonic clock for
evidence, `session` for identity across a replacement, `userWantsStream` for intent.

## Gates that need fresh visual evidence

These answer a question about what is in front of the wearer *now*. A stale or held picture is a
wrong answer, not a partial one, so each reads `readinessNow.hasFreshVisualEvidence` (phase `ready`
**and** `frameAge <= CameraReadiness.evidenceMaxAge`).

| Consumer | Was | Needs | Now |
|---|---|---|---|
| `CameraService.filteredStill(for:source:)` — the chokepoint all 19 still readers go through (`Sources/Services/CameraService.swift:347`) | a non-nil cached still | fresh evidence | stale cache is withheld; `.cachedFrameOnly` → `.unavailable(.noFreshView)`, `.cachedFrameThenPhoto` → falls through to a capture |
| `AppState.currentVisionFrameDataIfAvailable` (`Sources/App/OpenGlassesApp.swift:4154`) | `isStreaming` + non-nil still | fresh evidence | readiness; absent → text-only turn |
| `AppState.smartCameraCapture` (`…:4266`) | `isStreaming` | fresh evidence | readiness; then the capture path |
| `AppState` live-session poll fallback, both realtime managers (`…:1404`, `…:1410`) | non-nil still | fresh evidence | readiness (a held **pin** stays exempt — the pin *is* the referent the wearer chose) |
| `AppState.resolveAttachment` `.live` (`…:1553`) | non-nil still | fresh evidence | readiness |
| `AppState.attachmentContext` `cameraStreaming` (`…:1543`) | `isStreaming` | can a live frame be had | readiness |
| `AppState.pinCurrentFrame` (`…:4169`) | non-nil still | fresh evidence | readiness — a pin makes one moment's staleness permanent |
| `SceneNarrationService.currentFrame` (`…:3156`) | non-nil still | fresh evidence | readiness; no frame this tick is a case the loop already handles |
| Every `filteredStill` caller — `SmartCaptureTool`, `BarcodeScannerTool`, `QRContextTool`, `ManualLookupTool`, `EquipmentLookupTool`, `MedicationIdentifierTool`, `ColorIdentifierTool`, `BadgeScanTool`, `ReadingAccessibilityTool`, `CapturePhotoTool`, `PhotoLogTool`, `MoneyIdentifierTool`, `FaceRecognitionTool`, `StudyService`, `TeleprompterService`, `AssistiveModeService`, `NavigationAssistService`, `LiveCoachService`, `SafetyAssessmentService`, `StructuredVisionService`, `MCPGlassesServer` | non-nil cached still | fresh evidence | unchanged at the call site — the chokepoint enforces it for all of them at once |

## Intent gates — must stay reachable with no frames

These decide whether to *start* the camera. None of them may consult a picture, or Start needs
frames and frames need Start. All were already reading intent or the stream flag, and all stay as
they were; P0 adds tests that pin it.

| Consumer | Reads | Verdict |
|---|---|---|
| `AppState` live-session camera start handler (`…:1431`) | `isStreaming`, then the claim | correct — claims, never frames |
| `BottomControlBar` camera button action (`Views/BottomControlBar.swift:643`) | `isStreaming`, `isStartingStream` | correct |
| `LivePreviewView.startStreamIfNeeded` (`Views/LivePreviewView.swift:273`) | `isStreaming` | correct |
| `ReadingCompanionService` start / resume / restart / end (`Services/Reading/ReadingCompanionService.swift:152, 208, 243, 412`) | `isStreaming` | correct — a reader restarting a dropped stream is an intent decision |
| `VideoRecordingTool` start (`Services/NativeTools/VideoRecordingTool.swift:77`) | `isStreaming` | correct |
| `AppState.toggleRecording`, remote `startVideo` (`…:3488`, `…:4980`) | `isStreaming` | correct |
| `AppState.capturePhotoSilently` (`…:3407`) | `isStreaming` to restore it afterwards | correct |
| `SceneNarrationService.isCameraStreaming` (`…:3215`) | `isStreaming` | correct — asks "is the camera already paid for", not "can I see" |
| `LookCloselyTool` | `capturePhoto()` | unchanged: a one-off capture with its own bounded acquisition contract and its own 6 s timeout, served by the backend's own `frameFallbackMaxAge` rule |

## Displays — say the phase, never a permanent "live"

| Surface | Was | Now |
|---|---|---|
| `BottomControlBar` camera button label (`Views/BottomControlBar.swift:636`) | `isStreaming ? "Streaming" : isStartingStream ? "Starting…" : "Camera"` — **said "Streaming" over a paused or stalled stream** | `readiness.controlLabel`: Camera / Starting… / Waiting… / Streaming / Paused / No frames / No picture / Stopping… |
| `BottomControlBar` accessibility hint (`…:661`) | "The camera is already streaming." over a paused camera | `readiness.controlHint` |
| `StatusIndicator` CAM chip (`Views/StatusIndicator.swift:76`) | green dot + "CAM" on `isStreaming` alone | `readiness.statusChip` — green only while pictures flow, otherwise a warn dot and the phase word |
| `StatusIndicator.spokenStatus` (`…:432`) | "camera streaming" | the chip's spoken phrase |
| `LivePreviewView` placeholder (`Views/LivePreviewView.swift:269`) | spinner + "Connecting to camera…" for every `.waiting`; a paused or stalled stream with no frame drew a **black rectangle and said nothing** | connecting/awaiting keep the spinner and the cold-start hint; paused / no frames / no picture get their own branch with the phase sentence and the move the wearer can make |
| `LivePreviewView` held frame (`…:29`) | image kept, labelled "Live camera feed from glasses" | persistent marker over the image and the same sentence as its accessibility label |

## Notices checked for inferred causes

`CameraStreamStatePolicy.pausedNotice` / `stoppedNotice` / `coldStartHint`, the
`MetaCameraBackend` transient notices, and every string on `CameraReadiness` were read against the
plan's rule. Nothing claims another app owns the camera, concludes whether the glasses are being
worn, or asks for a power cycle; the pause copy names putting the glasses on as a **remedy**, which
is legitimate — DAT 0.9 pauses the stream on a doff, so it is an observation about the stream, not a
guess from a failed start. `CameraReadinessTests.testNoticeCopyNamesNoCauseTheAppCannotSee` pins it.
