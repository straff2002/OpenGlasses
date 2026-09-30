# Plan GA — Watch Vision with the Phone Camera

**Status:** 📋 Planned 2026-09-30 — nothing built. For review before any code changes.
**Origin:** The owner, 2026-09-30: the phone camera is a real alternative to the glasses camera for
vision, and the watch's camera and vision controls must behave sensibly whether the vision source is
the glasses, the phone camera, or nothing.
**Depends on:** nothing. The watch App Group entitlement ([#581](https://github.com/straff2002/OpenGlasses/pull/581),
merged 2026-09-30) is what lets complications read the state this plan adds.
**Related:** Plan [CS](CS-standalone-watch-client.md) (standalone watch; its unbuilt `WatchCommandRoute`
decides *whether* a command reaches the phone, and this plan decides what the phone does with a
camera command once it arrives. CS's table calls `capturePhoto` glasses hardware; with this plan it
is camera hardware, served by either camera), Plan [CQ](CQ-third-party-glasses-backends.md) (camera
capabilities and `GlassesTierPolicy`, which the source resolution reads), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (the job block on the watch, and job photo evidence), Plan FY
(the product is Avenkin; code and bundle ids still say OpenGlasses).

---

## What is true today (verified 2026-09-30)

**The watch is a remote, not a camera.** watchOS has no camera API for third-party apps, so every
wrist command is carried out on the phone. The watch's camera surfaces are the **Photo** row
(`WatchMainView.swift:225–247`, sends `capturePhoto`), the **Video** toggle (`:251–263`,
`toggleVideo`), the **Quick Actions** (`:267–299`, `quickAction` + `action_id`), and the **Photo Note**
complication (`OpenGlassesWatchWidget.swift:291–307`, whose `CapturePhotoNoteIntent` sends
`capturePhoto` by `transferUserInfo`, fire-and-forget, `WatchComplicationIntents.swift:16–25, 68–77`).
The phone also handles `photo` and `describe` (`WatchConnectivityManager.swift:212–224`) but no watch
control sends them.

**The watch knows one camera fact: `isConnected`**, the glasses flag. Photo and Video are disabled
when it is false (`WatchMainView.swift:246, 261`); quick actions are not (`:296`). The flag is often
stale: the phone pushes its status (`sendStatusUpdate`, `WatchConnectivityManager.swift:46–96`) only
after a watch command or a job change (`OpenGlassesApp.swift:2685`), never when the glasses connect
or drop, and it skips the push entirely unless the watch is reachable (`:47`), although
`updateApplicationContext` does not need reachability. On the phone `isConnected` is itself optimistic:
it goes true on registration or a granted permission (`OpenGlassesApp.swift:3198, 3259, 3345`), not on
glasses present and unfolded.

**Success is reported for things that did not happen.** The watch fires the success haptic for any
reply without an `error` key (`WatchConnectivityService.swift:127–135`, `WatchMainView.swift:139–140`).

| Watch action | What the phone does without usable glasses | What the watch is told |
|---|---|---|
| Photo (`capturePhoto`) | `capturePhotoSilently()` returns at `guard isConnected` (`OpenGlassesApp.swift:4321–4322`); a failed glasses capture is also swallowed, logged only (`:4362`) | `status: "captured"` (`WatchConnectivityManager.swift:226–230`): success |
| Photo Note complication | the same silent return (`WatchConnectivityManager.swift:155–159`) | nothing; the complication has no reply channel |
| Describe-type quick action | `captureAndAnalyzePhoto()` retries the glasses for up to 5 s, then `presentPhoneCamera` (`OpenGlassesApp.swift:4218–4235`) | `status: "completed"` with the **previous** `lastResponse`: an old answer shown as the new one |
| `describe` / custom prompt | `capturePhotoAndSend` → `presentPhoneCamera` at once (`:3966–3971`) | the same stale "completed" |
| Video (`toggleVideo`) | `toggleRecording()` fails in `cameraService.startStreaming()` and sets the phone's `errorMessage` (`:4396–4419`) | `status: "stopped"`, no `error`: success |

**`presentPhoneCamera` only sets `phoneCameraRequest`** (`OpenGlassesApp.swift:3911–3913`), which
`MainView.swift:155–160` shows as the `PhoneCameraView` sheet: a live preview with a shutter the
person presses (`PhoneCameraView.swift:15–120`). iOS will not run `AVCaptureSession` for an app that
is not in the foreground, and nothing can bring an app to the foreground from a watch message. So when
the phone is in a pocket (a watch message wakes the app in the background), the request just waits,
with no expiry, and the camera sheet appears whenever the app is next opened, possibly much later and
out of context. The sheet does not say what it was opened for: `prompt` is never drawn.

**Quick actions from the watch are misrouted.** The watch's switch (`WatchConnectivityManager.swift:283–302`)
does not match `executeQuickAction` (`OpenGlassesApp.swift:4145–4216`):

- `.photo` and `.photoThenPrompt` both call `captureAndAnalyzePhoto()`, so *Event*, *Task* and
  *Translate Sign* lose their prompt and become a generic describe;
- `.prompt`, `.homeAssistant`, `.siriShortcut` and `.openApp` call `capturePhotoAndSend(prompt: action.label)`:
  *Lights Off* or *Field Assist* from the wrist takes a photo and sends the label to the model;
- only `.toggleRecording` is right.

**The camera layer already has a vision-source notion; nothing else does.** `CameraService.capturePhoto()`
(`CameraService.swift:266–297`) uses the glasses backend when it is ready and can take stills, and
otherwise captures **headlessly** from the iPhone camera (`PhoneCameraSource`, no preview), recording
which one served it in `lastCaptureSource` (`:299–300`). Readiness is `MetaCameraBackend.isReady`
(registration ≥ 3, `MetaCameraBackend.swift:156–161`); `activeCapabilities` gives the glasses
camera's capabilities when one is usable (`CameraService.swift:190`), and `GlassesTierPolicy`
(`Device/GlassesTier.swift:44–69`) already says "camera features use the iPhone camera" for
audio-only glasses. A watch command can reach the headless phone capture today: `capturePhotoAndSend`
gates on the optimistic `isConnected`, then calls `capturePhoto()`, which falls back when the backend
cannot take stills. There is no user setting for a preferred camera; broadcast has its own picker
(`BroadcastVideoSource`), which this plan leaves alone. Video recording is glasses-only by
construction: `VideoRecorder` records `outboundFrames`, which are the glasses frames
(`OpenGlassesApp.swift:2366`).

**Foreground state.** `scenePhase` drives `notePresenceForeground` (`OpenGlassesApp.swift:489–491`),
but its `isForegroundActive` starts `true` (`:800`), so an app cold-launched in the background by a
watch message reads as foreground. The command handlers must read
`UIApplication.shared.applicationState` when the command arrives.

**Notification plumbing exists.** `JobSendNotifications` posts one replace-in-place local notification
and `JobSendNotificationRouter` (`JobSendNotifications.swift:76–101`) is the app's
`UNUserNotificationCenter` delegate (`OpenGlassesApp.swift:1018–1021`). It implements only
`didReceive`, and routes by a `userInfo` key through a pure `requestedTab(from:)`. A local
notification's `userInfo` never leaves the process, so it needs no `DeepLinkTrust` token; the
`openglasses://action/...` URLs do, and this plan adds none.

## Decisions

**D1 — The watch is a remote for whichever camera can serve the request.** Glasses when the glasses
camera can take a still now; otherwise the phone camera; otherwise nothing, and the watch says so.
The resolution is automatic, with no new setting (see *Open questions*).

**D2 — The phone camera never captures from a wrist action without a preview on the phone.** The
phone camera faces other people in public. From the watch it always goes through the `PhoneCameraView`
preview, with the shutter pressed on the phone. A watch command never reaches the headless
`PhoneCameraSource` fallback. That fallback stays for in-app voice tools, where the person is already
holding the app, and is not changed here. **Glasses behaviour is unchanged:** a wrist tap with the
glasses camera ready captures on the glasses immediately, as today.

**D3 — Honest outcomes, four kinds.** *Captured* (success haptic), *on the phone now* (the preview is
up on an open phone), *continue on iPhone* (a handoff notification; its own haptic, not success) and
*refused* (a short reason and the error haptic). A reply never carries a `response` it did not just
produce.

**D4 — Backward compatible both ways.** A new key the other side does not know is ignored. A watch
that finds no `visionSource` keeps today's `isConnected` rule. A refusal always carries `error`, which
old watches already show with the error haptic.

**D5 — Not agentic, not paid.** Watch vision is a direct request from the wearer, so it is not gated
behind `agentModeEnabled`. Describe-from-the-wrist is an assistive path for low-vision wearers and
stays free: nothing here checks an entitlement.

**D6 — No plan letters in anything rendered.** "GA P1" may appear in code comments and this document,
never in a watch string, notification, sheet caption or accessibility label. No experimental DAT API
is used (no `MWDATInputs`/`Motion`/`Speech`, no voice invocations, no standalone `Camera.photo`, no
camera audio).

## Design

**`WatchVisionSource`** (shared wire vocabulary): `glasses` · `phone` (phone camera, app in the
foreground now) · `phoneInHand` (phone camera, but the app is not in front, so the person has to take
the phone out) · `none` (no glasses camera, and the phone camera is denied, restricted or absent).

**`VisionSourceResolver.resolve(glassesStillCapture:phoneCamera:appActive:)`** (pure, phone). The
inputs are `cameraService.activeCapabilities?.stillCapture == true` (not `isConnected`), the
`AVCaptureDevice` authorisation mapped to `.authorized / .notDetermined / .denied / .absent`, and
`applicationState == .active`. `notDetermined` counts as available, because the permission prompt
appears inside the preview.

**`WatchVisionPolicy.decide(_:source:origin:notificationsAuthorized:)`** (pure, phone). `WatchVisionCommand`
is `.photoNote` (`capturePhoto`), `.look(prompt)` (camera quick actions, `describe`, `photo`) or
`.video(start: Bool)`. `origin` is `.watchApp` or `.complication`.

| Command | `glasses` | `phone` | `phoneInHand` | `none` |
|---|---|---|---|---|
| `.photoNote` | capture on glasses, silent (today) | preview in note mode: shutter, then the same caption note, no AI | handoff | refuse: "No camera available" |
| `.look(prompt)` | glasses capture → AI (today, prompt kept) | preview with the prompt | handoff | refuse: "No camera available" |
| `.video(start: true)` | glasses (today) | refuse: "Video needs glasses" | same | same |
| `.video(start: false)` | always stops | — | — | — |

A handoff without notification permission becomes a refusal: "Open Avenkin on your iPhone". The
pending request is still held (P3), so opening the app still gets the person the preview.
Complication-origin refusals and handoffs also post the phone notification, because the complication
has no reply channel (P3). iOS mirrors a locked phone's notifications to the watch.

**Glasses capture from the watch fails instead of falling back:** `CameraService.capturePhoto(allowPhoneFallback: Bool = true)`;
the watch paths pass `false`, so a glasses failure after a stale "ready" becomes a refusal ("Couldn't
reach the glasses camera") instead of a headless phone photo.

**Status payload.** `sendStatusUpdate` adds `visionSource` (raw string), built by a pure
`WatchStatusPayload.make(...)` so the key set is testable. It is pushed whenever the answer can change:
glasses connect/drop (`isConnected` didSet), `scenePhase`, and after each command. The reachability
guard becomes `activationState == .activated && isPaired && isWatchAppInstalled`. Replies to camera
commands carry `outcome` (`captured` / `onPhone` / `handoff` / `refused`), `visionSource`, and
`message` or `error`. Old watches read `status` and `error` only, as today.

**Watch presentation.** A pure `WatchVisionPresentation.row(for:source:reachable:processing:)` returns
enabled, a short caption and the accessibility label. Captions: none for glasses; "On iPhone";
"Opens on iPhone"; "No camera"; "Needs glasses" (video). A disabled row always says why, following
Plan CS's rule that a greyed control with no stated cause reads as broken.

**Where the code lives.** `OpenGlasses/Sources/Shared/WatchVisionContract.swift` holds the source
enum, the keys, the outcome values, the presentation mapping and the short texts. It is compiled into
the app, the watch app and the watch widget, as `DeepLinkTrust.swift` already is into the app and the
iOS widget, so producer and consumer cannot drift. OpenGlassesTests covers it through the app target.
The watch target compiles none of the phone's files and has no test target of its own, so no watch
logic lives outside that shared file. The resolver, the policy and the payload builder are phone-only
(`OpenGlasses/Sources/Services/Watch/`).

**Strings.** Phone-side user-visible text (notification, preview caption) goes into
`Localizable.xcstrings` with every complete language filled in the same PR
(`LocalizationCatalogGuardTests` holds Russian complete). The watch has no string catalog and stays
English like the rest of the watch UI until Plan EC reaches it. Watch strings stay at about 20
characters or fewer.

## Phases (one PR each)

**P0 — Stop reporting success that didn't happen.** Smallest shippable fix, no new concepts.
- `capturePhotoSilently()` returns `PhotoNoteResult` (`.saved`, `.noGlasses`, `.failed`). The watch
  message handler replies `error: "Glasses not connected"` / `"Photo failed"` for the last two.
- `captureAndAnalyzePhoto()` and `capturePhotoAndSend(prompt:)` return `WatchLookResult` (`.answered`,
  `.phonePreviewRequested`, `.failed`). The watch handlers reply `response` only for `.answered`. For
  the preview case they reply `error: "Take the photo on iPhone"` (P1 replaces this with an outcome).
- `toggleVideo`: a start that did not start replies `error: "Video needs glasses"`.
- Quick actions from the watch go through `executeQuickAction`, so `.photoThenPrompt` keeps its prompt
  and non-camera types take no photo. `.siriShortcut` / `.openApp` reply `error: "Open on iPhone"`
  when the app is not active (`UIApplication.open` does nothing from the background).
- Files: `OpenGlassesApp.swift`, `WatchConnectivityManager.swift`. Tests: `WatchCommandReplyTests`
  (a pure `WatchCommandReply.make(for:)` over the result enums: no `response` without `.answered`,
  `error` on every non-success), `WatchQuickActionRoutingTests` (type → route, using
  `QuickAction.defaults`: *Lights Off* takes no photo, *Event* keeps its prompt).

**P1 — Vision source, policy and payload.**
- New: `Shared/WatchVisionContract.swift` (added to `project.base.yml` app sources and
  `project.watch.yml` watch and widget sources), `Services/Watch/VisionSourceResolver.swift`,
  `WatchVisionPolicy.swift`, `WatchStatusPayload.swift`.
- `CameraService.capturePhoto(allowPhoneFallback:)`; the phone handlers route `capturePhoto`,
  `describe`, `photo`, camera quick actions and `toggleVideo` through the policy. Until P3,
  `phoneInHand` resolves to the "Open Avenkin on your iPhone" refusal.
- Status pushes on glasses change and `scenePhase`, with the reachability guard replaced.
- Tests: `VisionSourceResolverTests` (each input combination; `notDetermined` counts as available;
  `isConnected` true with no still capture resolves to phone), `WatchVisionPolicyTests` (the table
  above cell by cell, complication origin, no-permission handoff becomes a refusal),
  `WatchVisionContractTests` (wire strings pinned; an unknown or missing value decodes to `nil`),
  `WatchStatusPayloadTests` (`visionSource` present, existing keys unchanged, `job` rule intact),
  `CameraServiceCoordinatorTests.testCaptureWithoutPhoneFallbackThrowsWhenBackendNotReady` and
  `…DoesNotTouchThePhoneSource`, both with the existing fakes.

**P2 — Watch UI and complication.**
- `WatchConnectivityService` stores `visionSource` from context and replies, and persists it into the
  App Group in `persistSharedState()`. `WatchMainView`'s Photo row, Video row and camera-type quick
  actions (by the `type` the watch already receives) take enabled state, caption and accessibility
  label from `WatchVisionPresentation`. Outcomes map to haptics: `captured` → success, `refused` →
  error, `onPhone`/`handoff` → `.start` with the message shown. No `visionSource` → today's rules.
- The Photo Note complication reads `visionSource` from the App Group: caption "Silent · added to
  transcript" for glasses, "Opens on iPhone" for either phone case, "No camera" (dimmed) for none.
  The Listen and Record complications are untouched (their "OG glasses" caption is FY's rename-script
  work).
- Tests: `WatchVisionPresentationTests` (every source × row, legacy `nil`, a disabled row always
  has a caption, labels carry the source and never a plan letter). The watch views are checked on a
  device (P4).

**P3 — Continue on iPhone.**
- `WatchVisionHandoff` (phone, pure store with an injected clock) holds one pending request: a
  `PhoneCameraRequest` plus mode (note or look), created time and id. A newer request replaces it;
  it expires after the TTL; it is consumed once. It lives in memory only: the prompt is never
  persisted.
- On handoff the phone posts one replace-in-place notification (`identifier "watch.vision-handoff"`,
  `userInfo` holds only the id). Title "Continue on iPhone", body "Open Avenkin to take the photo you
  asked for on your watch." The notification never contains the prompt or the action label (lock
  screen, mirrored to the wrist). Permission is used only if already granted; a wrist tap never
  triggers the permission prompt on a phone nobody is looking at.
- The next time the app becomes active within the TTL, by the notification or otherwise, the preview
  is presented, after any HIPAA lock clears. On expiry, consumption or cancel the notification is
  removed. `JobSendNotificationRouter` gains a pure `requestedHandoff(from:)` beside `requestedTab`
  and still implements only `didReceive`.
- `PhoneCameraView` shows a one-line caption of what the photo is for (the action label, e.g.
  "Describe"), which is also its VoiceOver announcement on appear. Note mode saves through the same
  path as the glasses photo note (file and caption line), with no AI. When a watch-started look
  finishes, a status push lands the answer on the wrist.
- Stale-sheet fix: `phoneCameraRequest` set from the watch goes through the handoff store, so a sheet
  can no longer turn up hours later.
- Tests: `WatchVisionHandoffTests` (TTL, replace, consume-once, expiry removes the notification,
  content never contains the prompt), `NotificationRouterTests` (tab and handoff keys independent, an
  unknown id is ignored).

**P4 — Device checks (owed; a real iPhone and Apple Watch, glasses on and off).**
Photo and Describe from the wrist in each source: glasses on; glasses off with the phone open; phone
locked in a pocket (notification on the wrist, tap on the phone opens the preview; expiry clears it);
camera permission denied. Also the Photo Note complication in each case, including whether a watch
widget extension's `transferUserInfo` reaches the phone at all (unverified: the watch app's own
`didReceiveUserInfo`, `WatchConnectivityService.swift:246–253`, handles the phone-to-watch direction
and relays nothing from the complication). Also the reply time of a glasses Describe, which awaits the
spoken answer before replying and may hit the WatchConnectivity reply timeout; the preview appearing
over another open sheet; and VoiceOver on the watch rows and the phone caption.

## Not covered

- **Phone-camera video from the watch.** The recorder is glasses-frame-only, and phone video from the
  wrist raises D2's problem for longer. Refused with a reason.
- **Headless phone capture for in-app voice tools** (`CameraService`'s fallback). Unchanged. It was
  built for a person using the app, and whether it should also require a preview is a separate
  question for the owner.
- **The watch working without the phone.** That is Plan CS. There is no camera on the wrist to fall
  back to.
- **Knowing whether the glasses are worn or folded.** DAT 1.0.0's stable `Device` state (`donState`,
  `hingeState`) could make `glasses` less optimistic. It is not experimental, but the app does not
  observe device state yet, and that is glasses-section work of its own.

## Open questions

1. **Photo note through the phone camera?** A glasses photo note is silent. By phone it means a
   preview and a shutter press. *Recommend yes:* same caption note, with D2's preview.
2. **Handoff lifetime.** *Recommend 2 minutes*, long enough to take the phone out, short enough that
   an unused request cannot surprise anyone.
3. **Should the notification name the action?** *Recommend no.* It shows on the lock screen and is
   mirrored to the watch, and the preview caption names it once the phone is in hand.
4. **A "preferred camera" setting** (for example the phone while wearing glasses)? *Recommend no
   setting now*; automatic, glasses first. If one is added it is not glasses-only, so it belongs in
   general camera settings, not the glasses section.
5. **Reply early for vision turns?** A glasses Describe replies only after the answer is spoken. *Recommend*
   replying `captured` on capture and delivering the answer through the context's `lastResponse`,
   decided before P1 so the outcome vocabulary is fixed once.
6. **Headless phone fallback for in-app tools** (see *Not covered*). *Recommend* a separate review,
   not this plan.
