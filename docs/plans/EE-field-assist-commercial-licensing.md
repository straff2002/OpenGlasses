# Plan EE — Field Assist Commercial Licensing (team codes, solo subscription, renewal)

**Status:** 📋 Planned 2026-09-03
**Origin:** The first inbound commercial enquiry for Field Assist asked, in order: a trial, current
pricing for the one-time purchase and for teams, whether the licence permits customer demos and paid
pilots, and partnership terms. The code can answer "trial" today and nothing else cleanly. This plan
gives Field Assist a coherent commercial shape: a solo product on the App Store, an organisation
licence for teams that renews, and a paywall that tells the truth about which one a device holds.
**Priority:** P1 for the commercial track, alongside [Plan ED](ED-vault-manual-retrieval.md).
**Surfaces:** Phone Settings → Field Assist. Nothing on the glasses changes.

---

## Product shape (decided here; numbers proposed, not decided)

Two tiers with different capabilities, not one capability with two prices. Today the entitlement
is a single boolean: a solo one-time purchase unlocks custom vault import, audit PDF export and
expert escalation — the same set a team seat would buy for many times the price. Twenty one-time
purchases would cost a contractor about a tenth of a year's team licence, with the only friction
being one Apple ID per technician. The gap between the prices is only defensible if the tiers
differ in what they can do.

| Capability | Solo | Team | Enterprise |
|---|---|---|---|
| Bundled vaults (refrigeration, IT) + procedures + domain calc | ✅ | ✅ | ✅ |
| Session log, Spotlight metadata opt-in | ✅ | ✅ | ✅ |
| Expert escalation via meeting link / MJPEG | ✅ | ✅ | ✅ |
| Custom vault import ([Plan H](H-custom-vault-import.md)) | — | ✅ | ✅ |
| OEM manual retrieval tier ([Plan ED](ED-vault-manual-retrieval.md)) | — | ✅ | ✅ |
| Audited session PDF export | — | ✅ | ✅ |
| Org-issued configuration (Plan CT, later) | — | ✅ | ✅ |
| White-label, SLA, retention terms, self-hosted expert relay | — | — | contract |

| Who | Vehicle | Term | Where it is bought |
|---|---|---|---|
| Solo technician | `com.openglasses.field_assist` (non-consumable, exists) **or** a new monthly / annual auto-renewing subscription | Perpetual, or renewing | In-app, StoreKit |
| Team / organisation | Signed licence code (exists) with `tier: "team"`, a `plan` and an expiry | Annual, renewed by a new code | Invoiced by the vendor, entered in-app |
| Pilot | The same signed code with `tier: "team"`, `plan: "pilot"` and a 60–90 day expiry | Fixed | Issued by the vendor |
| Enterprise | Signed code, `tier: "enterprise"`; later a Plan CT org profile | Contract | Invoiced |

Teams do **not** go through StoreKit. Apple's commission, Apple-ID scoping (a contractor with twenty
technicians does not want twenty App Store receipts), and the absence of any org concept in StoreKit
all argue against it, and the offline signed code already exists and already carries an expiry.
App Store Review Guideline 3.1.3(c) permits an app sold directly to organisations for their
employees to unlock previously purchased access; the consumer path must stay purchasable in-app and
the app must not steer consumers to buy outside it. Licence-code entry is enterprise activation,
not a storefront, and the copy has to keep it that way.

The existing non-consumable is **never revoked**: anyone who bought it keeps the solo tier forever.
Whether it stays *on sale* once the subscription exists is an open question below — a perpetual
grant on a product whose model routing and vaults keep changing is a liability, and it is easier to
withdraw before the first team customer signs than after.

## Verified starting point

- **The product is a non-consumable.** `MedicalCompliance.storekit` declares
  `com.openglasses.field_assist` as `NonConsumable` and two Medical Compliance
  auto-renewing subscriptions in one group. `StoreKitService.checkSubscriptionStatus` handles the
  medical products with renewal info, grace period and auto-renew state; the Field Assist branch
  records `transaction.expirationDate`, which is always nil for a non-consumable.
- **Entitlement is already expiry-aware.** `FieldAssistEntitlementEvaluator.decide` is a pure
  function of evidence plus a clock: perpetual outlasts dated, later expiry wins, expiry is
  exclusive, and absence is denial. `FieldAssistEntitlementEvidence` carries
  `.verifiedStoreProduct(productID, expiration)` and `.verifiedOrganizationLicense(licenseIDHash,
  expiration)`. `VerifiedStorePurchaseRecorder` is process-local and re-derived from the receipt.
  Gates sit at `VaultRegistry.isUnlocked`, `SessionExporter.export`, and
  `EscalationCoordinator.requestExpert`; revocation is an entry check and in-flight work finishes.
  A subscription product slots in with no evaluator change.
- **The licence code is minimal.** `LicenseService.LicensePayload` is `{feature, licensee, issued,
  expires?}`, Ed25519-signed, decoded expiry-free by the `nonisolated decode` so the evaluator owns
  the clock. `Scripts/generate-field-license.swift` mints codes from a private key that lives only
  with the vendor (env var or gitignored `secrets/` file). There is no notion of plan, organisation,
  seat count, or renewal.
- **The paywall is honest but thin.** `FieldAssistSettingsView` offers one product with its
  `displayPrice`, a licence-code field, "Licensed to <licensee>", and Remove License. It does not
  show an expiry, warn before one, or distinguish a pilot from a paid team.
- **Legal posture.** The repo is BSL 1.1: commercial purpose requires a separate licence from the
  licensor. A trial code unlocks the feature; it does not grant commercial use. Demos to prospects
  and paid pilots therefore need a written pilot agreement alongside the code. That is a document,
  not code, but the in-app licence status should name the plan so nobody mistakes a pilot for a
  perpetual grant.
- **Plan CT** (drafted) will carry the licence inside a signed org profile fetched by QR. This plan
  keeps the payload shape CT will reuse and adds nothing CT would have to undo.

## Design

### P1 — Tiered entitlement

The evaluator stays a pure function; evidence gains a tier and the decision reports the best one.

- `FieldAssistTier: Comparable` — `.solo < .team < .enterprise`.
- `FieldAssistEntitlementEvidence` carries a tier: `.verifiedStoreProduct` is always `.solo`;
  `.verifiedOrganizationLicense` takes the tier from the signed payload (a legacy code without a
  `tier` field decodes as `.team`, because every code issued so far went to an organisation).
- `FieldAssistEntitlementDecision.granted` gains `tier`. "Best" evidence is now the highest live
  tier, then perpetual-outlasts-dated, then later expiry — so a solo purchase beside a lapsed team
  code grants **solo**, and the decision's `expiresAt` is the date the *granted tier* lapses, not
  the date some lower tier does.
- `FieldAssistEntitlement.isGranted` stays (any tier) and gains `isGranted(atLeast:)`. The gates
  move up where the capability matrix says so: `VaultRegistry.isUnlocked` for `"enterprise"`-gated
  (custom) vaults requires `.team`; `SessionExporter.export` requires `.team`; the ED document tier
  imports and retrieves only at `.team`; `EscalationCoordinator.requestExpert` stays at any tier.
  Bundled vaults stay at `.solo`.
- Denial gains a reason: `.insufficientTier(required:, held:)`, so the paywall can say "your
  purchase covers the bundled vaults; custom vaults need a team licence" instead of a generic no.

Nothing a solo buyer has today is taken away silently: a device that holds only the non-consumable
and has already imported a custom vault keeps reading it (the gate is on import and on session
start of a *newly* custom vault — see the migration note in Tests). Export of a session already
recorded stays possible for 30 days after the change ships, then requires team. Both are stated in
the release note.

### P2 — Licence payload v2 and the generator

Add optional fields to `LicensePayload`; decoding stays backwards-compatible so every code already
issued keeps verifying:

```json
{
  "feature": "field_assist",
  "licensee": "Acme Mechanical Ltd",
  "issued": "2026-09-03T00:00:00Z",
  "expires": "2027-09-03T00:00:00Z",
  "tier": "team",            // "team" | "enterprise"; absent = legacy → team
  "plan": "team",            // "pilot" | "team" | "enterprise"; absent = legacy
  "seats": 20,               // informational — see "What seats mean"
  "reference": "PO-2026-0142" // free text for the invoice / agreement
}
```

**What seats mean.** The code is device-scoped and offline; there is no server, so seats are not
enforced. The number is recorded so the status screen can show "20 seats" and the vendor and the
customer agree on what was bought. Enforcement, if ever, is a Plan CT profile concern. The plan says
this plainly rather than implying a control that does not exist.

The generator gains `--tier`, `--plan`, `--seats`, `--reference`, `--days` (expiry from now) and prints the
decoded payload it just signed so the vendor can eyeball it before sending. Signing key handling is
unchanged.

### P3 — Solo subscription beside the one-time purchase

- App Store Connect and the local `.storekit`: a **Field Assist** subscription group with
  `com.openglasses.field_assist_monthly` and `com.openglasses.field_assist_annual`.
- `StoreKitService`: add the ids to `allProductIds`; route them through the same renewal-status
  branch Medical Compliance uses so grace period and auto-renew state are known; record the
  subscription's `expirationDate` through `VerifiedStorePurchaseRecorder` exactly as the
  non-consumable is recorded today (with a date instead of nil).
- `FieldAssistEntitlementProvider`: a `.verifiedStoreProduct` with an expiry already evaluates
  correctly and is always `.solo`. Add the product ids to the "field assist" match.
- Paywall: a tier picker (one-time / monthly / annual) with each `displayPrice`, restore purchases,
  and the standard subscription disclosure copy. Existing one-time purchasers see "Purchased" and
  no subscription upsell.

### P4 — Status, warnings, and renewal

`FieldAssistSettingsView` grows a status card driven by `FieldAssistEntitlement.decision()`:

- Granted: tier, source (purchase / subscription / licence), plan label when present, licensee,
  reference, seats, and "until <date>" or "perpetual". A solo device that tries a team capability
  sees the `.insufficientTier` explanation and the team-licence entry, never a store upsell for
  something the store does not sell.
- Expiring: a warning row at 30 and 7 days for dated evidence, so a team's admin has time to
  renew before technicians lose access in the field.
- Expired: the evaluator already denies; the card explains what expired and, for a licence, says
  "enter a renewal code from your administrator". No link to buy anything outside the store; a
  subscription's lapse points at Manage Subscriptions.
- Renewal is pasting a new code. The new code replaces the stored one; the old one is not kept.

Session-level behaviour does not change: a session already running at expiry finishes (the gates
are entry checks), the audit log records the entitlement source at session start so an exported
record from a pilot says so.

### P5 — deferred to Plan CT

Org profile carries the licence; Managed App Configuration delivers it zero-touch; policy and
entitlement keep separate expiry clocks. Nothing in P1–P4 has to be undone for it.

## Pricing

Numbers are set outside the repo and are not part of this plan. The model the code supports is the
one the tier table above describes: a solo product on the App Store (one-time or subscription), an
annual team licence issued by the vendor per organisation, a fixed-term pilot on the same code, and
enterprise by contract. Two principles carried into the design and worth keeping when the numbers
are set: the team seat is priced as software rather than as a hosted service (there is no server,
the customer brings their own model key, and a partner delivers support), and the gap between a
solo purchase and a team seat has to map to the capability gap in the tier table, or it invites
arbitrage.

## Tests

- Payload v2 decodes with and without the new fields; a v1 code signed with the test keypair
  still grants (`LicenseServiceTests` / `FieldAssistEntitlementTests` patterns).
- Generator round-trip: mint with `--plan pilot --days 90 --seats 10`, decode, assert fields and
  that expiry is 90 days from the injected now.
- Subscription evidence: a verified subscription transaction with an expiry grants until that
  date; past it denies with `.expired`; a non-consumable beside a lapsed subscription still grants
  (perpetual outlasts dated — existing rule, new case).
- Grace period: an in-grace subscription still grants; the status shows the grace state.
- Tier ordering: solo purchase + live team code → `.team`; solo purchase + lapsed team code →
  `.solo` with `expiresAt` nil (the granted tier is perpetual) and the lapse surfaced separately;
  legacy code without `tier` → `.team`; enterprise outranks team regardless of expiry order.
- Gates: custom-vault import, custom-vault session start, ED document ingest/retrieval and session
  export deny with `.insufficientTier(required: .team, held: .solo)` on a solo-only device;
  bundled vaults and escalation grant at solo.
- Migration: a solo-only device with an already-imported custom vault still opens it; export of a
  session recorded before the change is allowed inside the 30-day window and denied after (clock
  injected).
- Status-card view model: granted / expiring-30 / expiring-7 / expired / no-evidence render the
  right strings from a decision plus a clock, with no StoreKit or UserDefaults involved.
- Paywall: one-time purchasers do not see the subscription tiers; nobody sees off-store purchase
  copy (a string-level guard, like the App Intents metadata guard, so it cannot regress silently).
- Release-configuration build, per the house rule for anything touching StoreKit and entitlement.

## Non-goals

- Seat enforcement, licence servers, or user accounts.
- Changing Medical Compliance products or the Accessibility tier (free, never gated).
- White-label or reseller tooling beyond the payload fields.
- The pilot agreement text itself — it is drafted outside the repo and referenced by `reference`.

## Open questions

- Whether the one-time purchase stays **on sale** once the subscription exists. Existing buyers
  keep it either way. Leaning withdraw: a perpetual grant on a product whose model routing and
  vaults keep changing is a liability, and doing it before the first team customer signs avoids
  explaining a change of terms to them later.
- Whether the annual subscription and the one-time purchase should be the same price (proposed
  yes while both are sold).
- Per-storefront pricing in App Store Connect versus Apple's equalisation, for a partner quoting in
  their own currency.
- Whether a `pilot` code should refuse `SessionExporter` PDF export (a pilot is evaluation, the
  export is the paid artefact) or leave export on so the pilot demonstrates it. Leaning leave it on:
  the export is the thing that sells the seat.
