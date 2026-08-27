# Plan DQ — Third-Party Telemetry Opt-Out and Privacy-Manifest Honesty

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 follow-up to the 2026-08-26 review — trust item surfaced in the opportunity
assessment's release-blocker section that had no plan of its own.
**Priority:** Release blocker for App Store submission; the privacy-manifest contradiction is a review
risk independent of whether the SDK ever ships to the public channel.

This plan makes the app's actual outbound data match what its App Store privacy manifest promises. The
manifest states, in the author's own words, that there is no crash-reporting SDK; the linked wearables
SDK reports crashes to its vendor by default. One of the two has to change, and the privacy-first
posture says the egress does.

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
to `false`** — i.e. crash reporting is on unless the app opts out. The `MWDAT` dict in
`OpenGlasses/Info.plist` contains only `AppLinkURLScheme`, `ClientToken`, `MetaAppID`, and `TeamID`;
there is **no `CrashReporting > OptOut` key**. So a crash today ships a report to the SDK vendor while
the app's own privacy manifest asserts no crash-reporting SDK exists. That is a factual contradiction
in a submission artifact, not merely a missing preference.

Relevant seams:

- `OpenGlasses/Info.plist` — the `MWDAT` dict
- `OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy` — the "no crash-reporting SDK" assertion
- `.claude/rules/dat-conventions.md` — the opt-out key and the DAM-always-on note
- `project.base.yml` — `INFOPLIST_FILE`/`GENERATE_INFOPLIST_FILE` wiring (the plist is authored, not
  generated) and any CI plist verification
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

## P0 — Opt out and make the manifest true 🔴

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

**Verification.** Build Release; dump the built app's `Info.plist` and confirm
`MWDAT.CrashReporting.OptOut == true` survives into the archived bundle (not just the source plist).
Trigger a controlled crash on device and confirm no crash-report egress to the vendor in a packet
capture / network log. Confirm the app-level privacy report shows no crash-reporting data category.

## P1 — Guard against drift 🟠

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

## P2 — User-facing transparency 🟡

1. Ensure the in-app privacy disclosure copy states plainly that the app sends no analytics or crash
   telemetry to the developer or the wearables SDK vendor, consistent with the manifest.
2. If a future internal/TestFlight build wants crash diagnostics, gate it behind an explicit
   internal-build compilation condition (reuse `OPENGLASSES_INTERNAL` from
   [[DP-release-entitlement-boundary]]) and an unmistakable in-app indication — never a silent Release
   default.

---

## Rollout, rollback, and exit criteria

P0 ships immediately and is forward-safe: opting a default-on vendor egress out cannot regress user
privacy. A rollback would only re-expose the contradiction, so there is no reason to; the correct
"less aggressive" fallback is disclosure, handled inside P0 item 3, not restoration of silent
telemetry.

Complete when:

- the archived Release bundle carries `MWDAT.CrashReporting.OptOut = true`;
- a controlled device crash produces no vendor crash-report egress;
- `PrivacyInfo.xcprivacy` and the user-facing copy match the actual egress with no standing
  contradiction;
- a CI/plist guard fails on opt-out removal or manifest drift; and
- the SDK's own privacy manifest is recorded in the submission checklist.

Coordinate content-free diagnostic handling with [[DM-privacy-safe-production-logging]] and the
internal-build gating with [[DP-release-entitlement-boundary]].
