# Plan CX — Vision as a spoken mode

**Status: 📝 Drafted 2026-08-23** — from a device session, not a review. No PR yet.

## The problem, as observed

Starting a live session with vision currently takes two steps, and the second one is close to
undiscoverable. The Camera button exists **only** in a realtime mode, is disabled until the session
is already active, and then cold-starts the glasses camera through a session, a stream and a first
frame — device-traced at up to **20 seconds** during which the button still read "Camera" and looked
broken. The wearer pressed it repeatedly, then reported that streaming "did nothing".

Two fixes already landed and neither addresses the shape of it: the button now says "Starting…" and
refuses re-taps, and a paused stream no longer claims to be streaming. The remaining problem is that
a real decision — *is this session allowed to see?* — is expressed as a hidden second action that
must be rediscovered every session.

## Why not simply start the camera with every live session

The obvious fix is the wrong one, for four reasons that are each individually sufficient:

- **Cost.** Frames are image tokens on every turn. A voice-only live session and a vision one are
  materially different bills — the same concern that motivated the small-context work.
- **Power and heat.** The camera is the glasses' largest drain, and the device aborts a stream on
  its own under `thermalCritical` / `peakPowerShutdown`.
- **Consent.** The privacy LED lights and bystanders enter frame. `PrivacyFilterScope` exists
  because egress must be deliberate; a camera that switches itself on because a wearer started a
  voice chat is precisely the case that reasoning protects against.
- **Latency.** The cold start would front-load *every* live session, including the ones that only
  ever wanted voice.

## The shape: a spoken mode, not a control

Vision is entered and left **by voice** — "start video" / "stop video" — and while it is on, the
wearer asks freely with **no wake word between questions** until they leave it. The camera warms as
the mode starts, so the cold start lands on a boundary the wearer chose rather than under a button
that looks broken.

The important part is the second half. Suppressing the wake word makes this a **conversational
state**, not merely a camera state: "we are looking at something together" is a different mode of
talking, and re-addressing the assistant before every question is the wrong ceremony for it. That
is also what makes the feature worth the camera being on — a wearer who must say the wake word each
time would be as well taking single photos.

Hands stay free, which is the entire premise of the device: a control that requires the phone to be
out has already lost the argument on glasses.

**Consent is better served by this than by a button**, which is not obvious and worth stating. The
spoken command is an explicit, audible act with a spoken confirmation — anyone nearby hears the
wearer turn the camera on. A button press is silent and private to the wearer. The privacy LED
still does its work either way; the difference is that the *social* signal now matches the
technical one.

**The mic is open throughout, and that is the real cost.** Wake-word suppression means continuous
recognition for the mode's lifetime, which is battery, and it removes the one gesture that bounds
listening. So the mode needs firm edges: an explicit "stop video", an inactivity timeout, and exits
on session end, doff, and power/thermal pressure — each announced, because a mode that ends quietly
leaves the wearer believing the glasses can still see.

Two gates, both existing policy rather than new invention:

- **Device tier ([CQ](CQ-third-party-glasses-backends.md)).** Glasses with no camera must not offer
  the mode — the tier already knows, and `CameraFeatureGate` already produces the copy.
- **Power posture (BV).** Under `conserve` / `reserve`, entering is refused with a reason rather
  than started and then aborted by the device.

The grammar reuses `VoiceCommandParser` + `PhraseMatcher` (`Sources/Services/Flow/`) rather than
adding a second phrase layer; the authorisation rules there already exist to stop a passing mention
of "stop video" in conversation from ending the mode.

**The button stays.** It is the mid-session way in and out, and the accessible one — a wearer who
cannot rely on speech recognition must not lose the feature to a voice-only entrance.

## Phases

- **P1 — pure core.** `VisionModeState` (off / warming / on / ending) with the entry and exit
  grammar, wake-word suppression as an explicit property of the state rather than a side effect,
  and a policy resolving a request against device tier and power posture — returning what is
  actually available and, when it differs, why. Fixture-tested, including the exits that must
  announce themselves.
- **P2 — wiring.** The spoken commands through `VoiceCommandParser`; the camera warming as the mode
  starts; wake-word suppression applied and, critically, *released* on every exit path. The Camera
  button drives the same state machine.
- **P3 — device.** Whether warming during entry actually hides the cold start; the battery cost of
  continuous recognition across a mode's lifetime; whether the inactivity timeout is tuned so a
  wearer who wandered off is not left with an open mic and a live camera.

## Non-goals

- **Auto-starting vision without a choice.** See above — this plan exists because that is wrong.
- **A voice-only entrance.** The button stays; losing the feature to speech recognition a wearer
  cannot rely on would trade one discoverability problem for an accessibility one.
- **Continuous narration.** [CV](CV-continuous-scene-narration.md) owns the unprompted case; this
  plan is only about what a session is allowed to see.
- **Changing the frame rate or the dedup gate.** Untouched here.

## Open questions

- Does the preference belong per persona/project, or globally? A "describe my surroundings" persona
  wants vision every time; a note-taking one never does.
- Should a voice session be able to *upgrade* to vision mid-session without a restart? The Camera
  button implies yes, and the SDK's capability model may not.
