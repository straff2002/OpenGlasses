# Plan EY — Power Controls and Diagnostics

**Status: 📝 Drafted 2026-09-12; not scheduled.** One PR: pure settings/profile resolution
and bounded metrics first, then Settings UI and instrumentation. Device energy results follow.

## Gap and ownership

[BV](BV-power-policy.md) owns automatic posture, consumer enforcement, optional glasses
signals and thermal/drain validation. Its battery thresholds are UserDefaults-backed code knobs;
user-selected profiles are explicitly outside its scope. There is no complete power-controls or
operational battery-diagnostics deliverable in that plan. EY supplies those surfaces, not a
second power policy. [AT](frame-dedup-change-gate.md) owns dedup settings;
[EZ](EZ-adaptive-camera-capture.md) owns source capture adaptation.

## Scope and build order

1. Define validated settings for battery enter/exit thresholds, inactivity and maximum live-vision
   duration, plus All-Day/Balanced/Performance preferences. Keep automatic reserve as a resulting
   posture, not a profile that overrides thermal pressure. Profile resolution composes with BV:
   Performance cannot bypass critical thermal/device limits, privacy rules or explicit stream consent.
   Record exact defaults and ranges in the implementation PR; current behavior is the migration
   baseline until consumer enforcement is available.
2. Add Settings controls and a visible effective-posture reason, reset-to-defaults and clear copy
   explaining camera, timeout and warm-session effects. Expose only controls whose consumers are
   wired. A selected profile must not be a cosmetic label over unchanged behavior.
3. Add optional bounded session metrics: duration; phone/glasses battery at start/end when available;
   camera/mic/network active durations; frames captured, forwarded and analyzed; backend/model
   identifiers; thermal transitions; cleanup failures. Reuse existing counters and diagnostic export
   facilities, with counts rather than transcripts, images, audio, tokens or network addresses.

## Acceptance

Headless tests cover malformed persisted settings, 0–100 percentage bounds, ordered reserve/conserve
thresholds and hysteresis exits, migration, profile/posture precedence, unavailable battery values,
overlapping resource durations, duplicate stop and bounded retention. UI tests verify effective
settings and accessible labels; instrumentation tests prove prohibited content cannot enter metrics.
Diagnostics are opt-in, local and clearable; no automatic upload or inferred glasses battery reading.
Report a missing metric as unavailable, never zero.

## Dependencies and device validation

Core/settings tests are buildable now. BV consumer wiring precedes functional profile rollout;
[EW](EW-session-resource-cleanup.md) supplies audited resource lifetimes and failure counters.
Measure repeatable static/moving and voice/snapshot/live sessions on the same device, codec,
model and network. Record battery deltas, elapsed time, thermal state and counters, including
unknown glasses readings. No battery-life improvement claim without an observed baseline and
comparison. Product tuning of defaults remains a decision informed by those measurements.
