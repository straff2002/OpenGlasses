# Plan CX — Vision as a session choice, not a second tap

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

## The shape

A live session starts as **Voice** or **Voice + Vision**, chosen where the session starts and
remembered as a preference. Vision warms *with* the connection rather than after it, so the cold
start overlaps the handshake instead of following it.

Two gates, both existing policy rather than new invention:

- **Device tier ([CQ](CQ-third-party-glasses-backends.md)).** Glasses with no camera must not offer
  the option — the tier already knows, and `CameraFeatureGate` already produces the copy.
- **Power posture (BV).** Under `conserve` / `reserve`, vision is deferred and said so, rather than
  started and then aborted by the device.

## Phases

- **P1 — pure core.** `LiveSessionKind` (voice / voice+vision) + a policy resolving the wearer's
  preference against tier and posture, returning the kind actually available and, when it differs,
  why. Fixture-tested across tiers and postures.
- **P2 — wiring.** Session start honours the kind; the camera warms during connect; the preference
  persists. The Camera button remains, as the mid-session way in and out.
- **P3 — device.** Whether warming during connect actually hides the cold start, and what the
  thermal cost of routinely-on vision is across a long session.

## Non-goals

- **Auto-starting vision without a choice.** See above — this plan exists because that is wrong.
- **Continuous narration.** [CV](CV-continuous-scene-narration.md) owns the unprompted case; this
  plan is only about what a session is allowed to see.
- **Changing the frame rate or the dedup gate.** Untouched here.

## Open questions

- Does the preference belong per persona/project, or globally? A "describe my surroundings" persona
  wants vision every time; a note-taking one never does.
- Should a voice session be able to *upgrade* to vision mid-session without a restart? The Camera
  button implies yes, and the SDK's capability model may not.
