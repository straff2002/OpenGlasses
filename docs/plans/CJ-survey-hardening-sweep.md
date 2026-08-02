# Plan CJ — Survey-Surfaced Hardening Sweep

**Status: 📋 Planned (2026-08-02)** — items 1–2 already in flight as separate sessions.

A 2026-08-02 survey of the wider glasses-app field surfaced a set of correctness, security,
and safety patterns worth checking ourselves against — same spirit as Plan CD
(fork-surfaced remediation): independent implementations hitting the same walls are a map of
where the walls are. Each item below is verify-first: confirm whether we already handle it,
fix only what's real.

## Items

1. **WebRTC signaling security triad** *(in flight, separate session).* Three bug classes
   found-and-fixed elsewhere in the same feature shape we ship: static-file path traversal
   (raw URL joined to web root), room takeover via code-only rejoin (needs per-room creator
   tokens), missing per-IP rate limits on create/join. Audit `WebRTCStreamingService`, the
   Plan M reference signaling impls (`docs/webrtc/`), and `WebHUDMirrorServer`.

2. **Relative-time guard** *(in flight, separate session).* When the utterance says "in 15
   minutes", parse it deterministically and override the model-computed absolute time in
   `TimerTool`/`ReminderTool` args — small/local models botch now+N arithmetic, and the MLX
   path makes this a real-world case, not a theoretical one.

3. **Retrieve-or-silence citation gate (first-aid/HECA).** Rule: the assistant may only
   *speak* a safety/medical citation when retrieval actually returned the underlying text;
   a proposed-but-unretrieved citation is logged to a review queue and the spoken answer
   omits it, rather than free-forming an authoritative-sounding reference. Verify what the
   first-aid and safety-assessment verticals do today at the speech boundary; add the gate
   (pure: `CitationGate(proposed, retrieved) → spoken/queued`) if the invariant isn't
   already enforced.

4. **Category-only privacy reporting in vision prompts.** A structured-vision option where
   the model must report *that* a sensitive item is visible (card, ID, prescription, screen,
   handwriting) as a category flag while being schema-forbidden from transcribing its
   content. Complements the face-blur `PrivacyFilterService` (pixels) with a language-side
   guarantee (words). Add as an `AssessmentSchema` capability + a default-on flag for
   ambient/assistive modes.

5. **Realtime audio input-tap format.** Verify every `AVAudioEngine` input tap installs at
   the node's *live hardware format* (16 kHz mono over HFP) rather than an assumed graph
   format — the mismatch class throws `-10868` and only bites with the glasses routed,
   which is why it survives sim testing. Audit the Gemini Live / OpenAI Realtime capture
   paths and the wake-word engine tap.

6. **Barge-in truncation by confirmed-played frames.** On user interruption, the truncation
   point reported to the realtime API should come from *confirmed-played* PCM (player-node
   completion callbacks), never wall-clock estimates — wall-clock over-reports what the user
   heard and desyncs the server transcript. Verify the OpenAI Realtime interruption path;
   align Gemini Live's equivalent.

7. **Gemini Live native session resumption.** If our reconnect path replays transcript
   history to restore context, switch to the API's session-resumption handle (cheaper,
   faster, no token re-spend; interacts with Plans BD/CF redial). Verify first — this may
   already be done.

## Shape

One PR, CD-style: each item lands as (verification note in this doc) + (fix + test where the
check found a gap). Items 1–2 merge back here as status lines when their sessions land.

## Non-goals

- No new features — this is correctness/safety debt only.
- No speculative fixes: an item that verifies as already-handled gets a status line and no
  diff.
