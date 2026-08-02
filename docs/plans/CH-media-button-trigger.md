# Plan CH — Media-Button Hands-Free Trigger (the tap we do control)

**Status: 🚧 P1+P2 shipped (2026-08-02); P3 device smoke deferred** — `MediaTriggerPolicy`
pure claim/release/defer matrix (user audio, realtime sessions, and exclusive lease holders
all beat us; only next-track fires in the v1 grammar) + `MediaTriggerService` state machine
over a `NowPlayingClaiming` seam, both fully headless-tested. Wiring: `SilentNowPlayingClaimer`
(generated silent WAV, zero volume, `MPRemoteCommandCenter` handlers, coexisting rider on the
AS coordinator), same wake-path entry as the alternative triggers, `MusicControlTool` posts a
pre-emptive stand-down before driving the user's player, `NowPlayingSnapshot` filters our own
sentinel out of "what's playing?". Settings: "Temple Tap (Experimental)", off by default.
Device-pending (P3): whether iOS grants Now Playing to a `mixWithOthers` session, which temple
gestures arrive as which AVRCP commands on this firmware, double-tap latency.

The glasses expose no captouch remapping to third-party apps — but their temple gestures send
standard AVRCP media commands (play/pause, next-track) to whatever app owns Now Playing. If
we *claim* Now Playing, a double-tap on the temple becomes a physical assistant trigger: no
wake word, no phone touch, works in noise where speech recognition struggles.

## The trade (why this is a policy problem, not a wiring problem)

Claiming Now Playing means registering `MPRemoteCommandCenter` handlers and being the active
audio app — which collides with three things we already do:

1. **The user's own music.** If they're playing Spotify through the glasses, stealing Now
   Playing pauses/hijacks it. Unacceptable as a default.
2. **`MusicControlTool`** issues playback commands on the user's behalf — it must keep
   working against the *user's* player, not find us squatting on the session.
3. **The now-playing reader** (`OpenGlassesApp` reads `MPNowPlayingInfoCenter` for "what's
   playing?") would start seeing ourselves.

So the core of this plan is **`MediaTriggerPolicy` (pure)**: given
`(triggerEnabled, userAudioPlaying, sessionMode, audioLeaseState)` decide
`claim / release / defer`. Claim only when the user isn't playing anything (interruption
notifications + `isOtherAudioPlaying` as inputs); release the moment external audio starts;
never claim while a realtime session holds the audio lease (Plan AS coordinator is the
arbiter, this becomes one more lease client). The policy is a table of cases — test it as
data, no audio stack needed.

## Wiring (thin, device-pending by nature)

- Claiming = playing a silent looping buffer at zero volume via the existing audio session
  (the standard mechanism for receiving remote commands), registering `nextTrackCommand` /
  `togglePlayPauseCommand` handlers.
- **Gesture grammar (v1):** next-track (double-tap) → start listening, same entry as wake
  word; play/pause single-tap is left to the OS/user's music and NOT claimed unless nothing
  is playing. Keep the grammar one gesture until device testing says more is reliable.
- Trigger fires the same path as a wake-word hit (`WakeWordService`'s downstream), so
  everything after the trigger is shared code.
- Settings: off by default ("Temple-tap trigger (experimental)"), with an explicit note that
  it pauses when your own music plays.

## Phases

- **P1 — policy core:** `MediaTriggerPolicy` + tests (claim/release/defer matrix, lease
  interplay, music-interruption transitions).
- **P2 — wiring:** silent-session claim/release, command handlers, wake-path handoff,
  settings. Testable in sim for state transitions; gesture feel needs hardware.
- **P3 — device smoke (deferred):** which temple gestures actually arrive as which AVRCP
  commands on this firmware; double-tap latency; interaction with glasses auto-pause on
  removal.

## Non-goals

- No attempt to intercept single-tap play/pause while user audio is active — their music wins.
- No new audio session machinery — Plan AS's lease coordinator stays the single arbiter.
