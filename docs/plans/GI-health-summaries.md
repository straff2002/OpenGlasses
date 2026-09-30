# Plan GI — Health Summaries (heart rate, sleep, steps from Apple Health)

**Status:** ✅ Shipped 2026-10-01 — P0–P2 built in one PR: the HealthKit entitlement (spec, committed
entitlements, personal example, setup-script patch for existing personal copies), the pure core
(`SleepNightAggregator`, `StepBaseline`, `HeartRateSummary`, `HealthSummaryPhraser`,
`HealthSummaryDeliveryPolicy`, `HealthSummaryCache`), `HealthKitSampleReader`, the `health_summary`
tool, Settings → Privacy → Health, and 76 headless tests. Decisions taken: fix the entitlement now;
cache summary numbers for locked-phone answers; speak-direct when sharing is off; free for everyone;
no HRV / blood oxygen / workouts in v1. **Owed (P3, device):** register the HealthKit capability on
the App ID before the next archive; confirm `fitness_coach` authorisation and workout saving now
work; Watch and no-Watch phones; a night with and without stages; locked phone in a pocket;
speak-direct during a Gemini Live / OpenAI Realtime session; toggling sharing mid-conversation;
VoiceOver on the Health settings screen.

**As built — where the code differs from the draft below:**
- The reader takes `restingHeartRates(from:to:)` (the pure summary picks the day) rather than
  `restingHeartRate(on:)`; `authorizationState()` can only say *asked / not asked / unavailable*,
  because HealthKit never reveals whether read access was granted.
- "On-device model active" is computed conservatively: Direct mode, an on-device active model **and
  no cloud model saved at all** (routing, the cascade or a later model switch could otherwise carry
  this turn's history to the cloud). Otherwise the tool treats the model as cloud.
- Speak-direct uses on-device voices only (`TextToSpeechService.speakReporting(_:onDeviceOnly:)`
  drops the cloud voice for that utterance); the glasses display mirrors the sentence as usual. A
  suppressed or failed utterance returns a second, still number-free receipt.
- Medical Compliance speaks direct even with an on-device model (the draft's delivery list left the
  order implicit; the test "HIPAA always speak-direct" decides it).
- A steps read that returns nothing at all, today and for two weeks, is what a denied read looks
  like; `CMPedometer` answers today's count in that case, when Health is unavailable or not yet
  allowed, and when the phone is locked with no cached count.
- Registered as an `AIFeature` (`healthSummaries`, own off switch) and a `SensitiveStore`
  (`healthSummaryCache`) so the privacy inventories stay complete; the ET data-lifecycle matrix was
  regenerated.
**Related:** Plan [B](B-personal-health-vault.md) (Health Vault, a separate document vault; its
"HealthKit auto-population" open question stays open), the Tier 3 fitness work
(`FitnessCoachingTool`, `PedometerTool`), HIPAA / Medical-Compliance modes (`MedicalEgressGuard`).

---

## Trigger

"How did I sleep?", "What's my heart rate?", "Am I behind on steps today?" are short questions with
short answers already sitting in Apple Health. The app reads steps from CoreMotion and its own
workouts, nothing else.

## Outcome

Read-only summaries, one spoken sentence each:
- **Heart rate:** latest reading and today's resting rate — "72 a few minutes ago; resting 58 today."
- **Sleep last night:** time asleep, and stages when the source records them — "7 h 10 m asleep,
  about 1 h 20 m deep and 1 h 40 m REM, woke twice."
- **Steps:** today vs. the wearer's usual by this time of day — "6,200 so far, about 1,500 more than
  usual by now."
- Health data leaves the phone **only inside an answer to a question the wearer asked**, and only
  to an AI provider when they have turned that on.

## What exists today (verified 2026-10-01)

- `NativeTools/PedometerTool.swift` (`step_count`, CoreMotion `CMPedometer`, today only).
- `NativeTools/FitnessCoachingTool.swift` (`fitness_coach`): writes workouts and energy; reads
  workout history **only when `Config.shareHealthDataWithAI` is on** (default off; Apple guideline
  5.1.3 comment in the code). `App/Views/ToolPermissionGate.swift` requests read access to
  `stepCount` and `activeEnergyBurned` for it.
- `Info.plist` already has `NSHealthShareUsageDescription` ("reads your health data (steps,
  workouts)…") and `NSHealthUpdateUsageDescription`. `Resources/PrivacyInfo.xcprivacy` already
  declares `NSPrivacyCollectedDataTypeHealth` and `…Fitness` (app functionality, not linked).
  Settings shows "Share Health Data with AI".
- **No HealthKit entitlement.** Neither `project.base.yml` (`entitlements.properties`) nor
  `OpenGlasses/OpenGlasses.entitlements` nor `Config/Entitlements/OpenGlasses.entitlements.example`
  carries `com.apple.developer.healthkit`. Without it `HKHealthStore.requestAuthorization` fails in a
  signed build, so the existing HealthKit reads and workout writes likely do not work today. P0
  confirms on device before anything is built on top.
- `NetworkDataClass.healthFact` exists in `Security/NetworkRouteRegistry.swift`; `MedicalEgressGuard`
  decides per route under HIPAA / local-only.
- Plan B's vault is Markdown the wearer edits (Medical Compliance gated); it does not read HealthKit.

## Design

**Reader seam.** `HealthSampleReading` protocol (`latestHeartRate(within:)`,
`restingHeartRate(on:)`, `sleepSamples(from:to:)`, `cumulativeSteps(from:to:)`, `authorizationState`)
with a live `HealthKitSampleReader` and a fake for tests. Only these read types are requested:
`heartRate`, `restingHeartRate`, `sleepAnalysis`, `stepCount`. Nothing is written by this plan.

**Pure core.**
- `SleepNightAggregator`: "last night" = samples overlapping 18:00 yesterday → 14:00 today (local
  time); overlapping sources are merged into one timeline (asleep intervals unioned, a watch's
  staged samples preferred over an in-bed-only phone sample); outputs asleep duration, in-bed
  duration, stage totals (`asleepCore`, `asleepDeep`, `asleepREM`) when present, and awakenings ≥ 5 min.
- `StepBaseline`: usual steps by now = median of each of the previous 14 days' cumulative count at
  the same clock time, ignoring days with fewer than 500 steps (phone left at home). Fewer than 5
  usable days → no comparison, just today's count.
- `HeartRateSummary`: latest sample ≤ 2 h old, else "no recent reading"; resting HR for today,
  else the most recent within 3 days with its day named.
- `HealthSummaryPhraser`: one sentence per metric, rounded (heart rate to the beat, sleep to 10 min,
  steps to the hundred), locale-aware numbers; honest absences — "I don't have heart-rate readings;
  those come from a watch or another wearable." Never interprets, diagnoses or advises; a separate
  line is never added unless asked ("Is that normal?" goes to the model, see below).

**Delivery policy (the privacy core).** `HealthSummaryDeliveryPolicy.decide(activeModelIsLocal:,
shareHealthWithAI:, hipaaMode:, medicalLocalOnly:)` → `.returnToModel` or `.speakDirect`:
- On-device model active → `.returnToModel` (nothing leaves).
- Cloud model and the share toggle **off**, or HIPAA / local-only on → `.speakDirect`: the tool
  speaks the sentence itself through `TextToSpeechService` and returns to the model only a
  content-free receipt ("Summary spoken to the wearer; values withheld"). The question went to the
  provider; the numbers did not.
- Cloud model and the toggle **on** (and no HIPAA) → `.returnToModel`, so follow-ups like "is
  that normal for me?" work.

**Tool.** `health_summary` (`metric`: `heart_rate`, `sleep`, `steps`, `overview`). `overview` is at
most two sentences. `PedometerTool` stays as the fallback for steps when Health is not authorised or
unavailable (iPad, restricted device).

**Locked phone.** HealthKit's store is unreadable while the device is locked, which is exactly
when a glasses wearer asks. `HealthSummaryCache` keeps the last computed **summary numbers** (not
samples) in a file with `completeUntilFirstUserAuthentication`, excluded from backup, 24 h TTL,
refreshed whenever the app is foregrounded or unlocked. A locked-phone answer says its age: "As of
8:10 this morning, you'd slept 7 hours." If there is no cache: "I can read Health once your phone
is unlocked." (Decision 2.)

**Surfaces.** Voice first; phone and glasses display get the same sentence. Works phone-only.
Settings → Privacy gains a "Health" row (read types, the share toggle, clear cache). The Info.plist
string is rewritten to name heart rate, sleep and steps; no new privacy key. No plan letters in
copy.

**Relation to Plan B.** Separate: GI reads live Health data, B holds documents the wearer writes.
GI never writes into the vault. Whether a "save today's resting heart rate to my vault" action
belongs anywhere stays Plan B's open question.

## Phases (one PR each)

**P0 — Entitlement and truth check.** Add `com.apple.developer.healthkit` to the spec (register the
capability on the App ID first — a new capability breaks archive until it is registered);
confirm on device that `fitness_coach` authorisation now works. Rewrite the Health usage string.
Tests: `HealthEntitlementGuardTests` (spec and entitlements file carry the key; usage strings name
every requested read type).

**P1 — Pure core.** Aggregator, baseline, heart-rate summary, phraser, delivery policy, cache
model. Tests: `SleepNightAggregatorTests` (split night, nap excluded, overlapping watch + phone,
stages absent), `StepBaselineTests` (median, low-day exclusion, < 5 days), `HeartRateSummaryTests`,
`HealthSummaryPhraserTests` (rounding, absences, no advice words), `HealthSummaryDeliveryPolicyTests`
(every combination; HIPAA always speak-direct), `HealthSummaryCacheTests` (TTL, age phrasing).

**P2 — Reader, tool and settings.** `HealthKitSampleReader`, `HealthSummaryTool`, permission gate
entry, Settings row, speak-direct receipt path. Tests: `HealthSummaryToolTests` with the fake reader
(each metric, unauthorised, locked with and without cache, speak-direct returns no numbers).

**P3 — Device checks (owed).** Real Watch and no-Watch phones; a night with and without stage data;
locked phone in a pocket; toggling share on/off mid-conversation; VoiceOver on the settings row.

## Risks

- **Sleep data varies by source** (Watch, phone, third-party rings); the aggregator is tested
  against each shape, and absent stages are simply not mentioned.
- **Locked-phone questions** are the common case; the cache is the only answer and holds derived
  numbers, which is itself health data on disk (protected, not backed up, clearable).
- **App Review 5.1.3**: speak-direct keeps cloud disclosure opt-in, matching the existing toggle.

## Decisions for Greig

1. Confirm the missing HealthKit entitlement is a bug to fix now (P0), independent of the rest.
2. Cache summary numbers for locked-phone answers (recommended) or answer only when unlocked.
3. Speak-direct when sharing is off (recommended) vs. refusing health questions on cloud models.
4. Free for everyone (recommended: it is wellbeing information, not a Medical Compliance feature).
5. Add HRV, blood oxygen or workouts-this-week later? *Recommend not in v1.*

## Out of scope

Writing to Health, medical interpretation or alerts, trends beyond "usual by now", syncing to the
Health Vault, background delivery (`HKObserverQuery`), and clinical records.
