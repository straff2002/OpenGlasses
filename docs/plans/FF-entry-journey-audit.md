# FF — The non-visual entry journey, audited

Companion to [FF — Blind Assistant Readiness](FF-blind-assistant-readiness.md), P1/PR3. It walks
the real setup a blind wearer has to complete — registration, permissions, provider setup, mode
selection, starting and stopping a session, and recovering from each failure — and records, per
step, the controls encountered, what carries state, where a gesture is the only affordance, and
which steps happen outside this app.

**What this is not.** Everything below was audited against the code and, for the screens the
UI-test target covers, against a running app on a simulator. **No blind participant has walked this
journey and no VoiceOver pass on hardware has been made.** Those are the acceptance evidence
PR3 names and they remain owed. A screen that passes `XCUIAccessibilityAudit` is a screen without
the defects that tool recognises — it is not a screen someone has used.

Audited at build 397, worktree `feat/ff-p3-entry-journey`.

## Summary of what the walk found

| # | Finding | Status |
|---|---|---|
| 1 | A refused permission left the row offering a Grant button that iOS will never honour again — the only recovery is the iOS Settings page, and nothing in the app said so or led there. Without sight, a refusal and a tap that did not register are the same experience. | **Fixed** — `OnboardingView.permissionRow` offers "Open Settings" after a refusal, seeded from the authorization status so a refusal from a previous run comes up that way too; the spoken refusal line says which button replaced it. |
| 2 | Opening the app never started the assistant; it started *listening*. The wearer's first action after every launch was to find a control on a screen. | **Fixed** — opt-in "Start Blind Assistant When I Open the App", gated by `BlindAssistantLaunchPolicy`. |
| 3 | A launch that could not start had nothing to say. Five different blocked states (no key, permission refused, wrong preset, setup unfinished, silent mode) all produced the same silence. | **Fixed** — five of the nine skip reasons are spoken, once each, through the app's own voice so they are heard with VoiceOver off. |
| 4 | Every entry point guessed at the teardown with a fixed 600 ms sleep, could not be cancelled, and two of them racing started two sessions. | **Fixed** — `LiveSessionActivator`; see the plan's PR3 evidence note. |
| 4b | The scene becoming active at cold launch could race the launch activation and announce an audio-only start before glasses registration had settled — a cue that stops being true a second later. | **Fixed** — foreground activation waits until the launch decision has been made. |
| 5 | Stop was not durable: nothing recorded that the wearer had stopped, so any future automatic start would put it back. | **Fixed** — the stop latch, cleared only by an explicit request or relaunch. |
| 6 | The glasses pairing step genuinely leaves this app. | **Unavoidable** — see "Steps outside this app" below; the app announces both ends of the wait and states what to do in the other app. |
| 7 | No gesture on the glasses can be claimed as an entry point. | **Confirmed again** — see "Hardware gestures". |

## Step 0 — Getting the app at all

Added with PR8. The journey a participant walks has to start where a real one does — at the App
Store listing, on a phone that may have never had this app or the companion app on it — because
every step below assumes an installed, launched app and none of them says how that happened.

**Distribution route:** the App Store is the channel. Nothing here assumes a Mac, a developer
account, a TestFlight invitation, or a sighted helper; where a step genuinely needs one of those,
it is not part of the supported journey and is not listed.

### Prerequisites, as a checklist

| # | Step | Where it happens | Accessible on its own? |
|---|---|---|---|
| 1 | Find the listing and install | App Store | Apple's, and natively accessible. The listing's own name and subtitle are the only part we control |
| 2 | Install the glasses companion app, if it is not already there | App Store, then that app's own onboarding | **Not ours.** Its accessibility is its vendor's, and it has to be recorded as observed, not assumed |
| 3 | Pair the glasses to the phone | iOS Settings → Bluetooth, and the companion app | Outside every app boundary we control (see "Steps outside this app") |
| 4 | Sign in to the companion app, if it asks | that app | Not ours |
| 5 | Launch OpenGlasses and complete onboarding | this app, pages 1–7 | Audited below. A wearer with no glasses can complete it — "Skip — no glasses yet" is what makes an audio-only setup reachable |
| 6 | Approve OpenGlasses in the companion app when onboarding asks | that app | Not ours; this app announces both ends of the wait and says what to do there |
| 7 | Add a provider key, or choose an on-device model | this app, onboarding page 3 or Settings | Audited below (Step 3) |
| 8 | Run **Settings → Accessibility → Check the Assistant Is Ready** | this app | Added by PR8; five checks, each spoken |

Steps 2, 3, 4 and 6 are the ones this app cannot make accessible. They are listed so a participant
run records *where* help was needed rather than only *that* it was.

### Two outcomes, recorded separately

An installation a researcher helped with and an installation the participant completed alone are
different results, and collapsing them is the specific way a setup claim becomes untrue. So each
participant run records both, per step of the checklist above:

* **Independently completed** — the participant did it with their own assistive technology and no
  intervention. Record the time taken and anything they had to work around.
* **Assisted** — record *which* step, *what* the assistance was (spoken description, a tap, reading
  something aloud, taking the phone), and whether the participant could have completed it given
  more time. "Assisted" with no step named is not a usable record.

Neither outcome is a pass or a fail on its own. A journey completed only with assistance is
evidence about this app, and it stays evidence until the step that needed help is fixed or
published as a known limitation.

**Nothing here has been walked by a participant yet.** The checklist is what a run should record;
it is not a record.

## Step 1 — Registration (glasses pairing)

Screens: `OnboardingView` page 6 of 7 (`connectGlassesPage`), and afterwards Settings → the glasses
rows.

| Control | Role | Name / value | Notes |
|---|---|---|---|
| "Camera" row | permission | title + detail combined into one element; state read as the word "Granted", not as a colour | Optional for the assistant — a session without it starts audio-only and says so |
| "Meta AI Integration" row | button → leaves the app | "Grant Meta AI Integration access" | The step below |
| Registration footer | live status | spoken at both ends: "Registering with Meta AI", then either "Meta AI connected" or the instruction to approve in the other app | Interrupting on failure, because it is the answer that stalls the flow |
| "Continue" / "Skip — no glasses yet" | navigation | both are real buttons | The skip is what makes an audio-only setup completable |

Focus order: the page title is an `isHeader` element carrying "Page 6 of 7" as its *value*, and
focus is moved to it on every page change, so arriving on the page says where in the flow it is.
Back is a named button overlaid at the leading edge; the page-indicator dots are hidden from the
tree (4 pt tall — a target no finger could find).

**No gesture-only control exists in the flow.** Onboarding is deliberately built from conditional
views rather than a paged `TabView`, so there is no swipe to discover; every page transition has a
button.

## Step 2 — Permissions, refusal and retry

Screen: `OnboardingView` page 5 (`permissionsPage`): microphone, speech recognition, location,
Bluetooth, Home data. Camera is on page 6.

Each row is one combined element (title + what it is for) followed by either "Granted" or a button.
The outcome of every request is announced, because the system alert is accessible on its own but
its *dismissal* is where the flow goes quiet: a grant swaps a button for a checkmark somewhere down
the list, and a refusal changes nothing at all.

**Finding 1, fixed.** iOS asks for a given permission exactly once. After a refusal the "Grant"
button still rendered and still did nothing. The row now offers **"Open Settings"** instead —
labelled "Open Settings to grant Microphone access", hinted "iOS only asks once, so this permission
is granted in Settings now" — and the refusal announcement says so: *"Microphone access not
granted. iOS only asks once, so the row now offers an Open Settings button instead."* The denied set
is also seeded from the authorization status in `checkExistingPermissions()`, so a refusal from a
previous run brings the row up already offering the route that works.

The same recovery is reachable later without re-entering onboarding: Settings → Accessibility →
**Opening the App** carries "Open iOS Settings for OpenGlasses", and the launch policy's spoken
skip names the permission and where to turn it on.

What is required, and what is not:

| Permission | Required for the assistant | If refused |
|---|---|---|
| Microphone | **Yes** | Launch start declines and says which permission is off |
| Speech recognition | **Yes**, for the wake word — the non-visual way back into the app | Same |
| Camera | No | Session starts **audio-only** and says "it can hear you but not see" |
| Location, Home data | No | Unrelated features degrade; the assistant is unaffected |

## Step 3 — Provider setup (the API key)

Screen: `OnboardingView` page 3 (`apiKeyPage`), and later Settings → AI & Personality → the model
editor (`ModelEditorView`, audited by `SettingsAccessibilityTests`).

Key entry uses `SecretInputField`: a `SecureField` paired with an explicit **Paste** button
(labelled "Paste", 44 pt target around a 26×17 glyph) and a **Reveal** toggle, because a plain
`SecureField` fights iOS paste for long random strings. That pairing is the relevant property here —
a wearer pasting a key from a password manager or another device, and then being able to have it
read back. The model editor is audited at AX5 Dynamic Type with the system `Form` chrome deferred
(DF P4's standing deferral, unchanged here).

A missing key no longer only surfaces as a connection error after a failed start: the launch policy
declines first and says *"Not starting the assistant: there's no Gemini API key yet. Add one in
OpenGlasses settings."*

## Step 4 — Mode selection

`Config.activeLiveAIModeId` selects the live preset; `BlindAssistanceContract.presetID`
(`"accessibility"`) is Blind Assistant. Two accessible routes select it:

* Settings → Accessibility → **Opening the App**: when the launch setting is on and a different
  preset is selected, a **"Use Blind Assistant as the Live Mode"** button appears, and selecting it
  announces the change.
* Siri / Shortcuts: `StartAccessibilityModeIntent` ("Blind Assistant Mode") selects the preset and
  starts the session in one step.

**Deliberate: turning the launch setting on never selects the preset for the wearer.** A setting
that silently re-selected it would take a choice away from someone who uses a different preset, and
the launch path is where a taken choice is hardest to notice. The status sentence under the switch
states the condition, and the button next to it is the one-tap fix.

## Step 5 — Starting and stopping

| Entry | Control | Routed through the activator |
|---|---|---|
| Opening the app | none — the setting decides | ✅ `.launch` |
| Returning to the app | none | ✅ `.foreground` (same gate, including the stop latch) |
| Action Button | `ToggleGeminiLiveIntent` | ✅ `.actionButton` |
| Siri / Shortcuts | `StartLiveAIModeIntent` and the four preset shortcuts, `RunGlassesActionIntent` | ✅ `.siriShortcut` |
| The app's own capsule | `BottomControlBar` hero capsule | ✅ `.appUI` — and its Stop is a *user* stop, so it latches |
| Wake word, and "Ask OpenGlasses" | `WakeWordService`; `AskOpenGlassesIntent` → Direct-mode transcription | Direct mode has no live session to start, so these are unchanged — but they are why speech recognition is a required permission above |

The hero capsule is a named button whose label and colour both change with state ("Start Gemini
Live" / "Stop Session"), and DF P4 audits it. No swipe is required to reach it; no stop is
gesture-only.

What the wearer hears at each outcome:

* **Started, fully** — nothing from the activator; PR2's session-usable cue owns the moment
  ("Ready. I'm listening."). Two voices saying the same thing is the failure PR2 exists to prevent.
* **Started, audio-only** — one line before the session comes up, then the usable cue.
* **Declined** — one spoken reason, de-duplicated so a repeated foreground does not repeat it.
* **Cancelled by a Stop** — nothing new. The stop is its own feedback.

## Step 6 — Error recovery

Owned by PR2 (`AudibleLifecycleCoordinator`): connection lost, service usable again, audio back but
camera not, reconnected without the microphone, retries exhausted. PR3 adds only the entry-side
half: an activation that cannot proceed says why, and a session that ended does not silently
reappear.

One deliberate consequence: after the retry ladder is exhausted, the terminal cue is played and the
session stays down. It is not a user stop, so it does not latch — the next launch, foreground event
or explicit request may start a new one.

## Steps outside this app

| Step | Where it happens | The accessible instruction |
|---|---|---|
| Approving OpenGlasses in the Meta AI companion app | Meta's app | "Open the Meta AI app to approve, then tap Connect again" — shown in the row footer and spoken, interrupting, when the attempt comes back unapproved. Its accessibility is Meta's, not ours. |
| Granting a permission after a refusal | iOS Settings → OpenGlasses | The row's "Open Settings" button, and the same button in Settings → Accessibility → Opening the App. The iOS Settings page is natively accessible. |
| Pairing the glasses to the phone at all | iOS Settings → Bluetooth, and Meta's app | Outside every app boundary we control. |
| Assigning the Action Button | iOS Settings → Action Button → Shortcut | The intent is discoverable by name ("Toggle Gemini Live"). Repo note: App Shortcuts appear in Spotlight and Siri, **not** in the Action Button picker — the wearer picks "Shortcut", then the app's intent. |

## Hardware gestures

Re-checked at this build, against the pinned SDK's `.swiftinterface` files for `MWDATCore`,
`MWDATCamera` and `MWDATDisplay`: **zero** occurrences of `gesture`, `captureButton`, `shutter`,
`temple`, `captouch`, `buttonPress` or `hardwareButton` in any of the three. The only `onTap` in the
SDK (2 occurrences, `MWDATDisplay`) belongs to HUD `Button` views this app renders itself. There is
no capture-button or temple-gesture API to build on, and nothing here proposes one.

The temple/media trigger explored in [CH](CH-media-button-trigger.md) is a different mechanism —
claiming Now Playing so an AVRCP command from the temple reaches us — and it remains **experimental
and off by default**, with its device gate (P3) unpassed. It is not part of this journey and nothing
in PR3 depends on it.

## Owed

* A blind participant completing this journey without a sighted operator — the acceptance bar PR3
  states, and the only evidence that closes it. With PR8, that now starts at the App Store
  listing (Step 0) and ends with the readiness check run on glasses, and the assisted and
  independent outcomes are recorded separately per step.
* VoiceOver on hardware, through the whole walk.
* Cold launch, repeated activation, cancellation during the permission checks, lock/unlock and
  external audio coexistence, on a real phone with real glasses. The headless tests assert the
  decisions; they cannot assert what a wearer hears.
* The audio-only cue heard through the glasses with the phone pocketed, alongside PR2's three
  outstanding device checks.
