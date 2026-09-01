# Plan DQ — Third-Party Telemetry Opt-Out and Privacy-Manifest Honesty

**Status:** 🚧 **P0 ✅ shipped**, **P1 ✅**, **P2 ✅ copy / 🟡 device verification**.
P0 landed ahead of this document being updated: the `MWDAT` dict in `OpenGlasses/Info.plist` carries
both `Analytics > OptOut` and `CrashReporting > OptOut` (the opt-out went further than the plan
scoped — analytics as well as crashes), and `MetaTelemetryBlock` was added as a `URLProtocol`
backstop registered before `Wearables.configure()`, answering the vendor telemetry endpoint locally
and counting what it stopped. That state is surfaced in Settings and in the Diagnostics & Support
self-test. **Still device-pending:** the packet-capture half of P0's verification — nothing here has been
confirmed against a real crash on real glasses, only against the bundle and the interceptor.
P1 ships as `OpenGlassesTests/TelemetryOptOutGuardTests.swift`: a suite-embedded drift guard rather
than a CI script, so every PR inherits it with no CI configuration (same pattern as the
privacy-logging gate). P2's copy is in place; whether the wearer reads it as plainly as intended is
the 🟡 — that wants a look on device. P2.2 is deliberately **not built** (see below).
**Origin:** 2026-08-27 follow-up to the 2026-08-26 review — trust item surfaced in the opportunity
assessment's release-blocker section that had no plan of its own.
**Priority:** Release blocker for App Store submission; the privacy-manifest contradiction is a review
risk independent of whether the SDK ever ships to the public channel.

This plan makes the app's actual outbound data match what its App Store privacy manifest promises. The
manifest states, in the author's own words, that there is no crash-reporting SDK; the linked wearables
SDK reports crashes to its vendor by default. One of the two has to change, and the privacy-first
posture says the egress does. **It did** — the sections below are written in the plan's original
present tense, with what has since changed marked where it changed.

---

## Problem and verified path

`OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy` declares `NSPrivacyTracking = false`, an empty
tracking-domains list, and states in its header comment that "there is no analytics, crash-reporting,
or advertising SDK, and no cross-app/-developer tracking — so every type below is Linked=false,
Tracking=false, purpose = App Functionality." Every collected-data type is user-directed app
functionality under the user's own provider keys, which is accurate for the app's own code.

The linked Meta Wearables DAT SDK does not follow that claim by default. Per the SDK conventions this
project tracks, the DAT App Model is always enabled as of 0.9.0 (its `MWDAT.DAMEnabled` opt-out key is
ignored), and crash reporting is governed by `MWDAT > CrashReporting > OptOut`, a Bool that **defaults
to `false`** — i.e. crash reporting is on unless the app opts out. ~~The `MWDAT` dict in
`OpenGlasses/Info.plist` contains only `AppLinkURLScheme`, `ClientToken`, `MetaAppID`, and `TeamID`;
there is **no `CrashReporting > OptOut` key**. So a crash today ships a report to the SDK vendor while
the app's own privacy manifest asserts no crash-reporting SDK exists. That is a factual contradiction
in a submission artifact, not merely a missing preference.~~

**Superseded by P0 (kept for the history).** The `MWDAT` dict now carries `CrashReporting > OptOut`
**and** `Analytics > OptOut`, both `true`. The wider finding behind the narrower one was that crash
reporting is a single stream inside the SDK's `ar_wearables_sdk_*` event pipeline — session, stream,
permission, display *and* crash batches, all POSTed to a hard-coded `api2.ar.meta.com/mwsdk/telemetry`.
Opting out of crashes alone would have left the manifest's "no analytics … SDK" half just as untrue as
the crash half, so both keys went in together. The contradiction described above no longer stands; the
paragraph is left because it is the reason the keys exist.

The second thing P0 learned, which the plan did not anticipate: a plist flag is a request to a
closed-source binary this project ships but does not build. Nothing in a build log says whether it was
honoured. `MetaTelemetryBlock` answers that with a `URLProtocol` that intercepts the telemetry
endpoint in code we own — and a counter, so an ignored opt-out surfaces as visible state (Settings'
Glasses Analytics row flips from Off to Blocked; the `telemetry` self-test in Diagnostics & Support
fails with the count) rather than waiting for someone to run a packet capture. Attestation
(`/wearables/attestation/challenge`) shares that host and is deliberately **not** intercepted: it
gates device access, so blocking it would break the glasses, not protect anyone.

Relevant seams:

- `OpenGlasses/Info.plist` — the `MWDAT` dict (both opt-out keys)
- `OpenGlasses/Sources/Services/Device/MetaTelemetryBlock.swift` — the interceptor, the opt-out
  reader, and the Settings disclosure state
- `OpenGlasses/Sources/Services/WearablesBootstrap.swift` — installs the backstop before
  `Wearables.configure()`
- `OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy` — the "no crash-reporting SDK" assertion
- `OpenGlasses/Sources/App/Views/SettingsView.swift` — the Glasses Analytics status row and the
  Privacy section footer; `Diagnostics/SubsystemProbes.swift` — the `telemetry` probe
- `OpenGlassesTests/TelemetryOptOutGuardTests.swift` — the P1 drift guard;
  `OpenGlassesTests/MetaTelemetryBlockTests.swift` — the interceptor and shipped-bundle assertions
- `.claude/rules/dat-conventions.md` — the opt-out keys, the DAM-always-on note, and the
  telemetry-posture rule for any newly linked SDK
- `project.base.yml` — `INFOPLIST_FILE`/`GENERATE_INFOPLIST_FILE` wiring (the plist is authored, not
  generated); the removed `Config/Info/Info.personal.plist` override is why that matters
- App Store submission checklist / `docs/opportunity-assessment.md` release-blocker section

## Decisions and invariants

1. **The manifest is the contract; the egress conforms to it.** The privacy-first product posture (no
   developer backend, no account, no analytics) is a deliberate promise. The fix is to silence the
   default vendor crash egress, not to weaken the manifest to permit it.
2. Opting out must be explicit and durable in the authored `Info.plist`, not left to an SDK default or
   a runtime call that a background crash could pre-empt.
3. `DAMEnabled` is **not** a lever here — it is ignored in 0.9.0. Do not add it and imply it does
   something; document that DAM is always on and that DAM ≠ crash reporting.
4. Any third-party SDK data egress that cannot be disabled must be disclosed in the manifest and the
   user-facing privacy copy, never left as an unstated exception to a "no telemetry" claim.
5. A privacy-manifest claim is verifiable state. A build/CI check should fail if the plist opt-out and
   the manifest assertion ever drift apart again.

---

## P0 — Opt out and make the manifest true ✅

1. Add `CrashReporting` → `OptOut = true` (Bool) to the `MWDAT` dict in `OpenGlasses/Info.plist`. Keep
   it in the authored plist (`GENERATE_INFOPLIST_FILE: "NO"`), so it is present in every configuration
   including Release and cannot be dropped by a generated snapshot.
2. Confirm no code path re-enables crash reporting or sets `OptOut` back to `false` at runtime, and
   that the SDK reads the opt-out from `Info.plist` at initialization (before the first crash can be
   captured), not from a later async call.
3. Re-read `PrivacyInfo.xcprivacy` against reality after the opt-out. With crash reporting off, the
   "no crash-reporting SDK" statement is true again; leave the collected-data types unchanged (they
   describe the app's own user-directed egress, which is accurate). If for any reason the opt-out
   cannot be honored, the manifest comment and the user-facing privacy copy must instead disclose the
   vendor crash egress — do not leave the claim standing while the egress continues.
4. Verify the SDK ships its own privacy manifest inside the linked framework (Apple aggregates
   third-party manifests into the app's privacy report); note its declared types in the submission
   checklist so the app-level and SDK-level manifests are reviewed together, not in isolation.

**Shipped.** Both keys are in the authored plist (item 1, widened to analytics as well). Nothing
re-enables collection at runtime; the only runtime action is `MetaTelemetryBlock.install()`, which
runs *before* `Wearables.configure()` so the SDK's uploader cannot win the race against it (item 2).
The manifest was re-read and left as written — with the opt-out in place its claim is true again
(item 3). Item 4, recording the SDK's own bundled privacy manifest in the submission checklist,
remains open.

**Verification.** ~~Build Release; dump the built app's `Info.plist`~~ — done better than planned:
`MetaTelemetryBlockTests.testShippedBundleOptsOutOfBothAnalyticsAndCrashReporting` reads
`Bundle.main` in the app-hosted test bundle, so every test run asserts the keys survived into the
built app rather than leaving it to a manual dump. The `telemetry` self-test in Diagnostics & Support
makes the same check on device.
🟡 **Still device-pending:** trigger a controlled crash on real glasses and confirm no crash-report
egress to the vendor in a packet capture / network log; confirm the app-level privacy report shows no
crash-reporting data category. The interceptor's counter is the cheap standing proxy for this — a
non-zero count anywhere means the plist opt-out is being ignored — but a counter that reads zero
proves only that nothing was *attempted through URLLoading*, which is not the same statement a packet
capture makes.

## P1 — Guard against drift ✅

1. Add a lightweight CI/plist check (extend the existing pre-archive plist verification if one exists)
   that fails when `MWDAT.CrashReporting.OptOut` is absent or `false`, or when the SDK is present
   without the opt-out.
2. Add an assertion that pairs the plist state with the manifest claim: if `PrivacyInfo.xcprivacy`
   still asserts "no crash-reporting SDK," the opt-out must be present. If a future change intentionally
   enables vendor telemetry, the same check forces the manifest/disclosure copy to change in the same
   PR.
3. Document, in the submission checklist and `dat-conventions`, that any new linked SDK must have its
   default telemetry reviewed and either disabled or disclosed before it ships — telemetry-off is the
   default posture, disclosure is the exception, and neither is silent.

**Shipped as `OpenGlassesTests/TelemetryOptOutGuardTests.swift`.** Six tests, deliberately in
the test suite rather than in `Scripts/check-privacy-logging.sh` — that scanner has one job and
should keep it; the suite is what every PR already runs, so the guard needs no CI wiring:

1. The authored `Info.plist` opts out of both analytics and crash reporting, read through
   `MetaTelemetryBlock.plistOptOut` so the guard and the app cannot disagree about where the keys
   live. The failure message says what absent means: opted **in**.
2. The built bundle agrees with the authored file — the assertion that closes "the source is right"
   to "the build is right", whatever produced the bundle.
3. **The pairing rule** (item 2 above). If `PrivacyInfo.xcprivacy` still contains "There is no
   analytics, crash-reporting, or advertising SDK" (matched whitespace-normalised, so the XML's line
   wrapping is not load-bearing), the opt-outs must be present. Withdrawing the claim is an accepted
   way to satisfy the rule — the manifest would then be disclosing rather than denying — so the test
   skips instead of failing in that case. A future *intentional* telemetry-enable therefore fails
   this test until the manifest comment and the in-app copy change in the same PR, which the failure
   message says in as many words.
4. `MetaTelemetryBlock.install()` precedes `Wearables.configure()` in `WearablesBootstrap` — a
   source-order scan, because observing that ordering at runtime would mean configuring the SDK for
   real, which is fatal in a unit-test host and irreversible for the rest of the bundle.
5. `project.base.yml` still points `INFOPLIST_FILE` at the authored plist with
   `GENERATE_INFOPLIST_FILE: "NO"`.
6. A `project.local.yml`, if one exists on the machine running the test, does not override
   `INFOPLIST_FILE`. This one caught itself in review: the first version substring-matched the file
   and failed on the *comment* the template carries telling you never to set that key — a false
   failure whose obvious "fix" is deleting the warning. It now strips comments and matches the YAML
   key form.

**Personal-plist override — checked, and it is not a live risk.** The whole-plist override that
could have silently dropped these keys (`Config/Info/Info.personal.plist`, wired by overriding
`INFOPLIST_FILE`) was **removed** before this plan: it went stale once and dropped newly added usage
descriptions (ITMS-90683), and withdrawing it later swallowed the Meta credentials. Personal values
now ride in as build settings, and only credentials are substituted into the committed plist as
`$(...)`. The residual gap is honest and named in the test: `project.local.yml` is gitignored, so on
a clean clone or in CI there is no file to assert against. Test 6 enforces the rule where the file
exists; test 2 covers every machine either way, because it reads what was actually built.

Item 3 landed in `.claude/rules/dat-conventions.md` as a telemetry-posture bullet alongside the
existing data-collection note. The submission-checklist half is still open, with P0 item 4.

## P2 — User-facing transparency ✅ copy / 🟡 device verification

1. Ensure the in-app privacy disclosure copy states plainly that the app sends no analytics or crash
   telemetry to the developer or the wearables SDK vendor, consistent with the manifest.
2. ~~If a future internal/TestFlight build wants crash diagnostics, gate it behind an explicit
   internal-build compilation condition (reuse `OPENGLASSES_INTERNAL` from
   [[DP-release-entitlement-boundary]]) and an unmistakable in-app indication — never a silent Release
   default.~~ **Not built, deliberately.** Nothing wants internal crash diagnostics today, and
   building the gate before there is a thing to gate would add a telemetry path whose only current
   purpose is to exist. Recorded here as the documented route if that ever changes: an
   `OPENGLASSES_INTERNAL` compilation condition, an unmistakable in-app indication that diagnostics
   are on, and — per the P1 pairing rule — a manifest and copy change in the same PR. A silent
   Release default remains out of the question.

**Shipped copy.** The Glasses Analytics row in Settings › Hardware & Privacy already covered the
vendor half. It now opens with the developer half, which is the half a wearer cannot verify for
themselves: OpenGlasses collects nothing of its own, there is no developer backend and no account, so
no usage analytics and no crash reports reach us, in any build. The row also explains
what its own status word means — Off when the opt-out is set and nothing has ever had to be stopped,
Blocked if an upload was attempted anyway and intercepted — and points at the self-test in
Diagnostics & Support for the count. That pointer was checked rather than assumed: the `telemetry`
probe runs in both the Developer panel and Diagnostics & Support, and only the latter is an Everyday
category that survives Simple Mode, so it is the one the copy names. The Privacy section footer
carries the same two-part claim in one line. Attestation stays described as what it
is: one contact with the vendor to prove the app may talk to the glasses, carrying no usage data.
🟡 Whether that reads as plainly on a phone as it does in a diff is a look-on-device item.

---

## Rollout, rollback, and exit criteria

P0 ships immediately and is forward-safe: opting a default-on vendor egress out cannot regress user
privacy. A rollback would only re-expose the contradiction, so there is no reason to; the correct
"less aggressive" fallback is disclosure, handled inside P0 item 3, not restoration of silent
telemetry.

Complete when:

- ✅ the built bundle carries `MWDAT.CrashReporting.OptOut = true` — and `MWDAT.Analytics.OptOut`
  with it; asserted against `Bundle.main` on every test run, not by hand. **Precisely:** the suite
  reads the bundle of whatever configuration ran it, which in the ordinary PR run is Debug. The
  reason that generalises to Release is structural rather than observed — the keys live in the
  authored plist and `GENERATE_INFOPLIST_FILE` is `NO`, both asserted, so there is no
  configuration-specific plist to diverge — plus a Release-configuration test run exercises the same
  assertion directly;
- 🟡 a controlled device crash produces no vendor crash-report egress — device-pending; the
  interceptor's counter is the standing proxy until then;
- ✅ `PrivacyInfo.xcprivacy` and the user-facing copy match the actual egress with no standing
  contradiction — and the copy now covers the developer half as well as the vendor half;
- ✅ a guard fails on opt-out removal or manifest drift — `TelemetryOptOutGuardTests`, in the suite
  rather than in CI configuration, so it cannot be skipped by forgetting to wire it up; and
- ⬜ the SDK's own privacy manifest is recorded in the submission checklist — still open, with P0
  item 4.

Coordinate content-free diagnostic handling with [[DM-privacy-safe-production-logging]] and the
internal-build gating with [[DP-release-entitlement-boundary]].
