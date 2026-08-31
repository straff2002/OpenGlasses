# Plan DP — Release Entitlement Boundary

**Status:** 🚧 P0 ✅ + P1 ✅ shipped (2026-08-31); P2 partially landed (test injection); P3 planned
**Origin:** 2026-08-26 adversarial review finding 7 (High business/access-control risk).
**Priority:** Immediate release blocker.

This plan removes the shipped Field Assist “Developer unlock (skip IAP)” path and makes entitlement a
testable policy with production-allowed evidence. Debug convenience moves to dependency injection and
internal build configuration; it is never a user preference interpreted by release code.

---

## Problem and verified path

`FieldAssistSettingsView` exposes a "Developer unlock (skip IAP)" toggle without a compile-time
internal guard — an always-compiled `@AppStorage("fieldAssistDeveloperUnlocked")` binding rendered in
every configuration including Release. `Config.fieldAssistDeveloperUnlocked` reads that key straight
from `UserDefaults`, and `Config.fieldAssistUnlocked` (the actual property name; there is no
`fieldAssistEntitled`) ORs it with `fieldAssistLicenseValid` and `fieldAssistPurchased`. `VaultRegistry.isUnlocked`
gates the refrigeration, IT/network, and enterprise vaults on `fieldAssistUnlocked` too, so one
`UserDefaults` write bypasses both the license-code and StoreKit paywalls at once. Multiple tests set
the same global key. A production user, restored preference, UI automation, backup, or defaults
manipulation can therefore bypass the intended commercial entitlement boundary.

`fieldAssistLicenseValid` and `fieldAssistPurchased` are a subtler case worth stating precisely: in
production they are *written* only after real verification — `LicenseService` after an Ed25519
signature/feature/expiry check, `StoreKitService` after iterating `Transaction.currentEntitlements`
with a revocation check — so they are not user-facing toggles like the developer flag. But they are
*stored* as bare mutable `UserDefaults` booleans, so at read time they are exactly as forgeable as the
developer flag. P0 must therefore fail closed on all three until P1 reads verified evidence directly,
rather than trusting the cached mirror.

Relevant seams:

- `OpenGlasses/Sources/App/Views/FieldAssistSettingsView.swift`
- `OpenGlasses/Sources/Utils/Config.swift`
- `OpenGlasses/Sources/Services/Vault/VaultRegistry.swift`
- Field Assist services, exporters, tools, and settings entry points
- tests currently setting `fieldAssistDeveloperUnlocked`

## Decisions and invariants

1. A Release build recognizes only verified StoreKit entitlement or a validated organization license.
2. Developer access is a compile-time internal capability. No Release symbol, string, preference key,
   URL/deep-link, environment variable, or hidden gesture can enable it.
3. Entitlement is enforced at service/tool boundaries, not only by hiding UI.
4. Tests obtain access from an injected fake entitlement provider, never by mutating global defaults.
5. Removing a stale developer preference cannot revoke a legitimate purchase/license and is safe to run
   on every release launch.

---

## P0 — Remove the release bypass ✅

1. Delete `Config.fieldAssistDeveloperUnlocked` and remove it from
   `Config.fieldAssistUnlocked`/all production decisions.
2. Remove the developer toggle/status copy from release UI and localization. If retained for internal
   builds, introduce one repository-wide `OPENGLASSES_INTERNAL` compilation condition and wrap its
   declaration, storage, rendering, and evaluation in `#if DEBUG || OPENGLASSES_INTERNAL`.
3. Add a release-launch migration that removes the legacy `fieldAssistDeveloperUnlocked` defaults key.
   It must not touch StoreKit receipts, license codes, or cached verified entitlement.
4. Search all app targets, extensions, widgets, intents, tests, and scripts for the key and bypass copy.
   Ensure no alternate helper still ORs a debug condition into production access.
5. Do not treat the remaining `fieldAssistLicenseValid` and `fieldAssistPurchased` `UserDefaults`
   mirrors as authoritative either: a mutable cached boolean is not purchase/license evidence. Until
   P1 lands, fail closed unless the current process has received a verified transaction or validated
   signed license result.
6. Until P1 centralizes policy, add service-level guards to every Field Assist entry point that can read
   vaults, run procedures, export sessions, or escalate—not only the settings/navigation surface.

**Tests.** Stale developer/purchase/license defaults `true` do not grant access; a verified purchase
grants; a cryptographically valid license grants; neither
denied; tool/service calls fail closed even when invoked without UI; migration removes only the legacy
key. Build a Release configuration as part of the PR.

**Shipped 2026-08-31.** `Config.fieldAssistDeveloperUnlocked` is gone, as is the settings toggle, its
footer, and the "unlock active" status row — including their entries in the string catalog.
`FieldAssistEntitlement.removeLegacyPreferenceKeys()` runs from `OpenGlassesApp.init` next to the
Keychain migration; it deletes exactly one key and is idempotent, so a real purchase or license cannot
be revoked by it. Steps 5 and 6 were satisfied directly by P1 rather than by interim guards: the
mirrors stopped being authoritative the moment `fieldAssistUnlocked` began delegating to the
evaluator, so no throwaway fail-closed layer was written.

Debug convenience is `FieldAssistEntitlement.setInternalDeveloperGrant(_:)` — in-memory, `#if DEBUG`,
routed through the same provider, with no preference key and no Release symbol or string. Plain
`#if DEBUG` was used rather than a new repository-wide `OPENGLASSES_INTERNAL` condition; introducing
one is still open should an internal TestFlight flavor ever be wanted, and would be the place to hang
P2's internal launch argument and watermark. No internal-only UI shipped with P0/P1.

## P1 — Typed entitlement evaluator and injected provider ✅

Create a pure policy result:

```swift
enum FieldAssistEntitlementEvidence: Equatable {
    case verifiedStoreProduct(productID: String, expiration: Date?)
    case verifiedOrganizationLicense(licenseIDHash: String, expiration: Date?)
    #if DEBUG || OPENGLASSES_INTERNAL
    case internalDeveloper
    #endif
}

struct FieldAssistEntitlementDecision: Equatable {
    let isGranted: Bool
    let source: Source?
    let expiresAt: Date?
    let denial: DenialReason?
}
```

1. `FieldAssistEntitlementProvider` gathers evidence; `FieldAssistEntitlementEvaluator` makes a pure
   decision for an injected clock/build flavor. Production code cannot construct internal evidence.
2. Replace `Config.fieldAssistUnlocked` reads with the provider at the ownership boundary. Pass the
   decision/provider into `VaultRegistry`, tools, session/export services, and views.
3. Define expiration/offline behavior explicitly: StoreKit follows verified transaction state;
   organization licenses use signed claims and a bounded offline grace period. Failure to parse/verify
   is denial, not developer fallback.
4. Cache only signed/verified entitlement facts needed for offline use, protected and expiry-bound.
   Never persist a mutable boolean named “entitled.”
5. Observe entitlement changes so an active paid operation completes safely or stops at a documented
   boundary; it must not continue opening new premium resources after revocation.

**Tests.** Truth table for purchase/license/expiry/revocation/offline grace/clock boundary; forged or
malformed license; cached evidence expiration; service reactions to mid-session revoke; internal source
is constructible only in internal test compilation.

**Shipped 2026-08-31** in `OpenGlasses/Sources/Services/Entitlement/`:

- `FieldAssistEntitlementEvidence` + `…EvidenceSet` + `FieldAssistEntitlementDecision` — evidence is
  only constructed by code that already checked a signature or a StoreKit verification result. The
  evidence set carries `hasUnverifiableLicense`, so a forged code denies with a stated reason rather
  than looking like "never bought it".
- `FieldAssistEntitlementEvaluator.decide(_:now:)` — pure, injected clock. Expiry is **exclusive**
  (evidence lapses at the instant it expires); among live evidence the perpetual piece wins, otherwise
  the one that lasts longest. Absent or unverifiable evidence denies; there is no fallback grant.
- `LiveFieldAssistEntitlementProvider` — the stored license **code** is the evidence, re-verified on
  every read through the new `nonisolated LicenseService.decode(code:publicKeyBase64:)` (signature +
  feature, no expiry check, so the clock lives in one place). Its identity reaches decisions as a
  16-hex-character SHA-256 prefix, never the code itself.
- `VerifiedStorePurchaseRecorder` — process-local, deliberately unpersisted. `StoreKitService`
  records or clears it from `Transaction.currentEntitlements`, which resolves against the on-device
  receipt and so holds offline. Organization licenses bound themselves by their signed expiry claim;
  no separate offline grace window was added, because a signed claim already is one.
- `FieldAssistEntitlement.shared` — lock-guarded provider + clock, so the synchronous gates can ask
  from any isolation domain. The provider is the single injection seam; tests swap it.

`Config.fieldAssistUnlocked` survives only as a delegating convenience with no stored boolean.
Enforcement is at service boundaries, not UI: `VaultRegistry.isUnlocked` (which every Field Assist
tool and `FieldSessionService.startSession` route through), `SessionExporter.export`
(`ExportError.notEntitled`), and `EscalationCoordinator.requestExpert`.

**Revocation contract.** Gates are entry checks. Once `VerifiedStorePurchaseRecorder.clear()` runs,
every later decision denies, so no new vault, procedure, export, or escalation opens; an operation
already in flight completes, and an escalation already under way runs to `resolve`/`cancel` so a
technician is never abandoned on a live call. Artifacts already written stay on disk.

Item 4 (a protected, expiry-bound cache of verified facts) was not needed: nothing entitlement-bearing
is persisted at all. The license code was already on disk and is now re-verified rather than trusted,
and StoreKit state is re-derived per process.

## P2 — Replace debug globals in tests and internal builds 🚧

1. ✅ **Landed with P1.** `ITNetworkPackTests`, `EscalationCoordinatorTests`, `FieldSessionServiceTests`,
   `SessionExporterTests`, and `ToolEffectClassificationTests` inject through `EntitlementTestScope`
   (`AlwaysGrantedEntitlementProvider` / `DeniedEntitlementProvider` / `StubEntitlementProvider` in
   `OpenGlassesTests/EntitlementTestSupport.swift`). No test writes the legacy key any more, and
   `LicenseServiceTests` asserts through a decision computed from the stored code rather than a mirror.
2. Provide an internal-only launch argument or settings toggle backed by an ephemeral in-memory provider,
   reset on restart, with an unmistakable “INTERNAL ENTITLEMENT” banner/watermark.
3. Ensure internal builds cannot produce or migrate entitlement evidence that a Release build accepts.
   Separate bundle id/receipt environment where practical.
4. ✅ **Landed with P1** as `EntitlementTestSupport.swift`.

## P3 — Release artifact and CI enforcement 🟠

1. Add a CI Release-archive check that fails if the binary/resources contain the legacy defaults key,
   “Developer unlock (skip IAP),” an internal entitlement case, or internal-only settings route.
2. Add a source rule rejecting entitlement decisions based on `UserDefaults.bool`, environment
   variables, launch arguments, or `#if DEBUG` branches outside the single internal adapter.
3. Run UI tests against a production-like StoreKit test configuration for denied, purchase, restore,
   expiration, and organization-license flows.
4. Document the entitlement evidence and revocation contract for future Field Assist packs. A new pack
   must reuse the provider; it may not invent a local boolean gate.

---

## Rollout, rollback, and exit criteria

P0 and P1 land before the next release archive. They are a forward-only security/business migration:
rollback may disable Field Assist for users who cannot be verified, but must not restore the developer
boolean or mutable entitlement mirrors. P2 then removes test globals. P3 becomes a permanent release
gate.

Complete when:

- setting the old key to any value cannot affect release entitlement;
- release UI/binary/resources contain no developer-unlock control or evaluator;
- every premium service/tool enforces an injected production decision;
- tests use explicit fake providers and no shared defaults bypass;
- purchase/license restore, expiry, revoke, and offline behavior are covered; and
- CI Release archive and the full suite are green.
