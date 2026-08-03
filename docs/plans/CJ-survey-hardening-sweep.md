# Plan CJ — Survey-Surfaced Hardening Sweep

**Status: 🚧 Items 3–7 verified & shipped (2026-08-03); items 1–2 still in flight as separate
sessions** (re-verified 2026-08-03: neither had landed on main — no traversal/token/rate-limit
code in the signaling surfaces, no relative-time parsing in `TimerTool`/`AppleRemindersTool`).
Verification notes per item below.

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
   *Verified 2026-08-03: the invariant was unenforced but mostly vacuous — first-aid/HECA
   speak deterministic protocol prose with static disclaimers and produce no citations; no
   retrieval underpins any vertical. The one LLM-composed fragment reaching speech unchecked
   was the Health-Safety Advisor's grounded advisory.* **Shipped:** pure `CitationGate`
   (`filter(proposed:retrieved:)` + sentence-wise `scrub` of authority-shaped claims — "per
   FDA guidance", "section 4.2", named health authorities), wired at
   `HealthSafetyAdvisor.llmAdvisory`; withheld claims log to the field-session audit sink
   (`logAssistantMessage(citations:)`, previously dead plumbing) and the console.

4. **Category-only privacy reporting in vision prompts.** A structured-vision option where
   the model must report *that* a sensitive item is visible (card, ID, prescription, screen,
   handwriting) as a category flag while being schema-forbidden from transcribing its
   content. Complements the face-blur `PrivacyFilterService` (pixels) with a language-side
   guarantee (words). Add as an `AssessmentSchema` capability + a default-on flag for
   ambient/assistive modes.
   *Verified 2026-08-03: no privacy language existed in any vision prompt; the ambient
   assistive loop uses the free-text `analyzeFrame` path, not the schema substrate.*
   **Shipped:** `AssessmentPrivacy` (enum-only `sensitive_items` property + prompt fragment)
   augmenting every vertical at the `StructuredVisionService.assess` chokepoint; categories
   surface as card findings ("Privacy: payment card visible — contents not read"); the same
   fragment rides every assistive-mode frame prompt. `Config.visionPrivacyCategoriesEnabled`,
   default on.

5. **Realtime audio input-tap format.** Verify every `AVAudioEngine` input tap installs at
   the node's *live hardware format* (16 kHz mono over HFP) rather than an assumed graph
   format — the mismatch class throws `-10868` and only bites with the glasses routed,
   which is why it survives sim testing. Audit the Gemini Live / OpenAI Realtime capture
   paths and the wake-word engine tap.
   *Verified 2026-08-03: all five tap sites already fetch `inputNode.outputFormat(forBus: 0)`
   immediately before `installTap` — no cached or hard-coded formats anywhere; wake word and
   the realtime engine also rebuild on route change. Residual gap: `LiveTranslationService`
   had no format-validation guard and was the only long-lived engine with no route-change
   handling.* **Shipped:** the wake-word-style zero-format guard before its tap, plus a
   route-change observer that rebuilds the engine on device add/drop.

6. **Barge-in truncation by confirmed-played frames.** On user interruption, the truncation
   point reported to the realtime API should come from *confirmed-played* PCM (player-node
   completion callbacks), never wall-clock estimates — wall-clock over-reports what the user
   heard and desyncs the server transcript. Verify the OpenAI Realtime interruption path;
   align Gemini Live's equivalent.
   *Verified 2026-08-03: worse than the survey pattern — the client sent no
   `conversation.item.truncate` at all (only `response.cancel`), so the server-side item kept
   the full unheard audio after every barge-in; `scheduleBuffer` was completion-less, so no
   played accounting existed to compute a truthful value from. Gemini Live needs nothing: its
   protocol truncates server-side on `interrupted`.* **Shipped:** `PlaybackProgressLedger`
   (pure — confirmed-played frames via `.dataPlayedBack` callbacks, generation counter drops
   the callbacks `stop()` fires for discarded buffers) in `RealtimeAudioEngine`;
   `cancelResponse` now sends `conversation.item.truncate` with the confirmed-played
   `audio_end_ms` (read before playback stops; per-response window reset on turn complete).
   Conservative by construction — the partially-played final chunk under-reports, never over.

7. **Gemini Live native session resumption.** If our reconnect path replays transcript
   history to restore context, switch to the API's session-resumption handle (cheaper,
   faster, no token re-spend; interacts with Plans BD/CF redial). Verify first — this may
   already be done.
   *Verified 2026-08-03: not done — setup never requested `sessionResumption`, so every
   reconnect (including the handled `goAway` rotation) was a cold restart that lost the live
   dialogue; only locally-rebuilt system-instruction context survived. No transcript replay
   either.* **Shipped:** `GeminiSessionResumption` (pure wire shapes) — every setup requests
   updates, the latest resumable handle is stored and rides the next reconnect's setup, and
   an intentional `disconnect()` clears it so deliberate fresh sessions stay fresh. Plans
   BD/CF mode-switch redials are unchanged by design (changing brains never resumes).

## Shape

One PR, CD-style: each item lands as (verification note in this doc) + (fix + test where the
check found a gap). Items 1–2 merge back here as status lines when their sessions land.

## Non-goals

- No new features — this is correctness/safety debt only.
- No speculative fixes: an item that verifies as already-handled gets a status line and no
  diff.
