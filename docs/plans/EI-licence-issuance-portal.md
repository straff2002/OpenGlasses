# Plan EI — Licence Issuance Portal (a partner issues and renews team codes without the vendor)

**Status:** 📋 Planned 2026-09-03
**Origin:** Every Field Assist team code that exists was minted by hand, on the vendor's machine, by
the one person holding the Ed25519 private key
([`Scripts/generate-field-license.swift`](../../Scripts/generate-field-license.swift)). That is fine
for the first customer and impossible for a reseller: a partner that sells annual team licences —
sometimes with vault packs included — needs to issue a code the afternoon the deal closes, renew it a
year later, and stay inside an agreed volume, without a round trip to the vendor for each one. The
vendor needs the mirror of that: a record it can bill from monthly, and confidence the partner cannot
issue itself capabilities it was never sold.
**Priority:** P2 for the commercial track — after [Plan EE](EE-field-assist-commercial-licensing.md)'s
tiers and [Plan EG](EG-vault-packs.md)'s pack claim (both shipped, both are the payload this plan
issues), before the first partner agreement is signed.
**Surfaces:** None in the app. This plan's deliverable is vendor-side tooling and a partner-facing
issuance surface; the phone is deliberately untouched.

---

## Product promise

To the partner: "Close the deal, fill in four fields, hand the customer a code. Renew from the same
row a year later. You never wait on us, and you can see exactly what you have issued."

To the vendor: "Nothing was issued that is not on the ledger, nothing on the ledger exceeds what that
partner was sold, and the ledger never contains a code anyone could paste into a phone."

Wholesale per seat to the partner, retail set by the partner. Terms live in the agreement; this plan
carries no numbers.

## Verified starting point

- **The code format is fixed and strict.**
  [`LicenseService.decode(code:publicKeyBase64:)`](../../OpenGlasses/Sources/Services/LicenseService.swift)
  splits on `.` with `omittingEmptySubsequences: false` and requires **exactly two** components —
  `base64(payloadJSON)` and `base64(Ed25519 signature)` — then verifies against a single embedded
  public key (`productionPublicKeyBase64`) and checks `feature == "field_assist"`. It is
  `nonisolated` and expiry-free by design, so the clock stays in the evaluator. Any code with a third
  component is `.malformed` on every build shipped to date.
- **The payload already carries everything a partner sells.** `LicensePayload` is
  `{feature, licensee, issued, expires?, tier?, plan?, seats?, reference?, packs?}` (EE added the
  middle four, EG the last), decoded backwards-compatibly, encoded with ISO-8601 dates and
  `.sortedKeys` in `LicenseService.encoder` — a byte-for-byte contract the generator script
  duplicates, because a differently-ordered JSON is a different signature and a different hash.
- **The tier claim fails safe.** `LicensePayload.resolvedTier` maps a missing or unrecognised `tier`
  to `.team` and coerces `solo` to `.team`, so no malformed claim can grant more than team. The
  generator already refuses `--tier solo` outright ("solo is a store product, never a code").
- **Entitlement re-verifies the stored code on every read.**
  [`LiveFieldAssistEntitlementProvider.evidence()`](../../OpenGlasses/Sources/Services/Entitlement/FieldAssistEntitlementProvider.swift)
  decodes the stored code afresh, hands the *signed* expiry and tier to
  [`FieldAssistEntitlementEvaluator`](../../OpenGlasses/Sources/Services/Entitlement/FieldAssistEntitlementEvaluator.swift),
  and `livePacks` unions the `packs` claim of live evidence only. Nothing stored as a preference is
  ever evidence — Plan DP's rule, and the constraint this plan must not erode.
- **There is a code→row join already.** `LiveFieldAssistEntitlementProvider.licenseIDHash(for:)` is
  the first 16 hex characters of SHA-256 over the code, and it is what the decision's `auditLabel`
  and session audit lines carry (`license:<hash>/team`). A support screenshot therefore already
  contains the token a ledger row can be found by, and never the code.
- **Storage is one code.** `LicenseService.storageKey` holds a single string; activation replaces it
  and `clear()` removes it. Renewal is a new code replacing the old one (EE decided this); a device
  cannot hold two licences at once.
- **Seats are recorded, not enforced.** EE says so plainly, and the code agrees: `seats` is an
  informational claim, the licence is device-scoped and offline, and there is no seat server. Any
  "quota" this plan introduces is therefore a **commercial cap on issuance**, not a device-side seat
  limit. The plan must say that in the partner's own UI or it will be misread.
- **There is no vendor server anywhere in this product.** Signed artefacts are static files served
  from GitHub Pages (`pages.yml`; `vaultpacks/index.json`, the skill-pack catalog) and verified
  offline. Static hosting can publish, it cannot mint. Whatever this plan builds is the first
  networked vendor service in the stack, and its blast radius should be reasoned about on that basis.
- **The signing key lives in one place.** `Scripts/generate-field-license.swift` resolves it from
  `$FIELD_ASSIST_SIGNING_KEY` or a gitignored `secrets/` file. It has never been on a host.
- **There is exactly one embedded verifying key.** No staging key path exists on a production build,
  so a partner cannot rehearse against a sandbox key and see the result on a shipped app.

## Two designs

### (A) Vendor-hosted issuance — the partner asks, the vendor's key signs

Partner accounts on a small vendor-run service. Each account carries a grant: which tiers it may
issue, which packs it may include, the maximum term, and a seat quota. A form submits an issuance
request; the service validates it against the grant and the ledger, mints with the vendor key
server-side, writes a ledger row, and shows the code once. The app is untouched: the resulting code
is byte-identical to one the vendor minted by hand.

### (B) Delegated partner keys — the vendor signs a certificate, the partner signs codes

The vendor signs a certificate binding a partner's public key to a partner id, an allowed tier and
pack set, a code-count cap and an expiry. The partner mints codes offline with its own private key. A
code carries the certificate, and the app verifies vendor → partner → code.

What that costs, concretely:

- **The wire format breaks.** A chain needs a third component (or a nested payload). `decode` accepts
  exactly two, so until every device updates, a partner-minted code is `.malformed` and the partner
  can sell to nobody. The trust root of an offline verifier is also the least rollback-able thing in
  the product: a bug in chain verification ships in a binary and is fixed by an App Store review
  cycle, in a code path that is re-run on **every gate read**.
- **The codes get much longer.** They are already a base64 payload plus a base64 signature, typed or
  pasted by hand into the licence field in Field Assist settings. A certificate (partner key,
  claims, vendor signature) roughly doubles that before the partner's own signature is added.
- **Quota stops being a fact.** A `maxCodes` claim inside a certificate is a number nothing counts —
  the minter is offline and stateless. The vendor would bill from a partner's self-report, which is
  precisely the number the vendor most wants to be independent of.
- **The ledger becomes a reporting duty**, so the audit trail is only as good as the partner's
  discipline, and a discrepancy surfaces at renewal rather than at issuance.
- **Revocation collapses to certificate expiry.** A leaked partner key mints unlimited valid codes
  until the certificate lapses, and the vendor's only lever is to not re-issue the certificate — a
  fleet-wide event that also breaks the partner's honest customers.
- It buys one real thing: the partner can issue with no connectivity and no dependency on vendor
  uptime, and the vendor's private key never touches a host.

### Recommendation: (A), with the pure rules kept out of the server

Two reasons, both grounded in what is already shipped:

1. **The app is the one component that must not change, and (A) does not change it.** `decode` is
   strict, single-rooted, re-run on every entitlement read, and already deployed to the devices a
   pilot is running on. Under (A) a partner-minted code is indistinguishable from a vendor-minted one
   at the byte level — every shipped build accepts it on the day the portal goes live, including
   builds that predate the portal's existence. Under (B) nothing a partner mints works until a new
   binary is everywhere, and the change lands in the verification path with the least margin for
   error in the product.
2. **Quota, ledger and audit are the entire commercial point, and only (A) makes them facts.**
   Validation happens *before* a code exists, so an over-issuing partner is refused rather than
   detected; the ledger row is written by the thing holding the key, so it cannot be incomplete; the
   monthly bill is derived from rows rather than reconciled against a report. The repo has already
   conceded once, honestly, that seats are unenforceable on-device because there is no server (EE,
   "What seats mean"). Repeating that concession at the layer where money changes hands would leave
   the vendor with no enforceable number anywhere.

The cost of (A) is real and must be designed for rather than waved at: **the vendor's Ed25519 private
key moves from a laptop to a host.** Mitigations, in order of value: the signing step is isolated from
the web tier and is the only component that touches the key (a KMS/HSM if the hosting supports one, a
separate minimal process if not); the service never talks to a device, so a compromise mints codes but
changes nothing about how a phone verifies; codes are short-term, so the blast radius of a compromise
is bounded by the term, not by the product's lifetime; and the vendor's manual path
(`Scripts/generate-field-license.swift`) stays, so the service can be taken offline without stopping
sales.

## Design

### What is a partner allowed to do

One record per partner, held by the vendor, versioned, and the only source of truth for what the
policy function will accept:

| Field | Meaning |
|---|---|
| `partnerId` | Opaque, stable, appears in every ledger row |
| `tiers` | Always `["team"]` in practice. **Never `enterprise`** |
| `packs` | The `licensePack` keys this partner may resell |
| `maxTermDays` | Longest term a single code may carry |
| `maxSeatsPerCode` | Ceiling on the `seats` claim of one code |
| `seatQuota` | Total seats the partner may have issued, the number the vendor bills against |
| `pilotsAllowed`, `maxPilotDays` | Whether `plan: "pilot"` may be issued, and for how long |
| `validFrom` / `validUntil` | The agreement's own term |

**Enterprise is never delegable.** `FieldAssistTier.enterprise`'s summary is white-label, SLA,
retention terms and a self-hosted relay — vendor obligations, not resellable capability. It is also
the tier that unlocks *every* pack in `VaultRegistry`'s resolution table regardless of the `packs`
claim (EG), so allowing a partner to issue enterprise would silently void the per-partner pack
constraint. Solo is refused for the reason the generator already gives: it is a store product.

Pack keys are validated against the signed vault-pack catalog
([`VaultPackManifest.effectiveLicensePack`](../../OpenGlasses/Sources/Services/Vault/VaultPack.swift)),
not against free text, so a typo cannot mint a `packs` claim that no pack answers to and that the
customer will only discover as a missing vault.

### The pure core

Everything that decides whether a code may exist is a function of `(request, grant, ledger, now)`:

```
IssuanceRequest  { licensee, seats, termDays | expiry, plan, packs, reference, replaces? }
IssuanceRefusal  .tierNotDelegated | .packNotResellable(key) | .unknownPack(key)
                 .termTooLong(max) | .seatsPerCodeExceeded(max) | .quotaExceeded(remaining)
                 .pilotNotAllowed | .pilotWithoutExpiry | .grantExpired | .replacesUnknown
IssuancePolicy.validate(...) -> Result<LicensePayload, IssuanceRefusal>
```

The success case returns a `LicensePayload` built with the *same* encoder settings the app decodes
with; signing is a separate step so the policy is testable without a key. A pilot without an expiry
is refused here as well as in the generator, because the rule belongs with the policy, not with a
CLI's argument parsing.

### The ledger

Append-only, one row per issuance, hash-chained (each row carries the SHA-256 of the previous row) so
partner and vendor can agree afterwards that nothing was edited. A row records:

`issuanceId` · `partnerId` · `operator` · `issuedAt` · `licensee` · `tier` · `plan` · `seats` ·
`packs` · `expires` · `reference` · `licenseDigest` · `licenseIDHash` · `replaces?` · `prevRowHash`

**Never the code.** `licenseDigest` is the full SHA-256 of the code; `licenseIDHash` is the 16-hex
prefix, stored separately because that is the exact token
`LiveFieldAssistEntitlementProvider.licenseIDHash(for:)` puts in an audit line and a support
screenshot — the join that lets support answer "which code is this device holding?" without ever
handling a code. Sixteen hex characters is 64 bits: fine as a display and support join, not as a
primary key, so rows are keyed by `issuanceId` and the full digest is the uniqueness check.

The service shows a minted code **once** and cannot show it again, because it does not have it. A
customer who loses a code gets a re-issue: a new row with `replaces` set to the prior `issuanceId`,
which does not consume fresh quota and supersedes the old row for billing. The superseded code keeps
working offline until its expiry — nothing can revoke it — which is the strongest argument for short
terms, and the reason `replaces` is a first-class field rather than a comment.

Billing is a pure function over the ledger for a period. Leaning: **bill on issuance** (seats × term
at the moment a row is written), not on live seats per month, because an issuance is a discrete
event, while "live seats" requires reconciling overlapping renewals, mid-term re-issues and
superseded rows — see the open question.

### What the partner sees

**A minimal web form**, not a CLI: the people closing these deals are salespeople. Four fields —
customer name (becomes `licensee`), term (a picker limited to what the grant allows), seats, and a
reference for the partner's own paperwork — plus a checkbox list of the packs that partner may
include, rendered from its grant. Submit shows the code once with a copy button and a plain-text
block suitable for pasting into an email, followed by "we cannot show you this again; if it is lost,
use Re-issue."

The rest of the surface is the ledger as a table: issued, customer, seats, packs, expires, and a
**Renew** action that pre-fills a new request from that row and links the two. An "expiring within 60
days" filter is the partner's whole renewals workflow.

A token-authenticated JSON endpoint behind the same policy exists for a partner with a back office
that wants to script renewals; it is documented but not the primary path. The vendor keeps its own
view: every partner's ledger, remaining quota, and a period export for invoicing.

### What the app does, and does not, do

Nothing changes. That is the recommendation's main asset and P1 asserts it as a test rather than as
prose: a code minted through the issuance library, signed with the test keypair, must decode and
grant through `LicenseService.decode` and `FieldAssistEntitlementEvaluator` exactly as a
generator-minted code does, with `livePacks` returning the same set.

Two app-side changes are *possible* and both are deferred so that claim stays true:

- An optional `issuer` claim naming the issuing partner, backwards-compatible in the way EE's fields
  were, so the status card can say who sold the licence. It puts a partner's name on the customer's
  screen, which a white-label partner will not want — so if it lands it should be an opaque
  `issuerId` resolved to a name only in the ledger.
- A signed revocation list of `licenseIDHash` values, verified like the pack catalogs. It is the only
  lever that could stop an unexpired code, and it is a bad one: it needs a network fetch, so it works
  "the next time this device is online", and it must **fail open** — a fetch that does not arrive can
  never become a denial, because the absence of a signed artefact is not evidence of revocation
  (Plan DP). Held as an open question, not designed in.

### Relationship to Plan CT

[Plan CT](CT-org-configuration-profiles.md) decided that an organisation's signed profile carries
both the configuration and the entitlement, that the QR is a pointer rather than a payload, and that
CT's profiles are signed with a **key distinct from the consumer licence key**, with domain
separation in the signed bytes so the two payload kinds can never be replayed as one another. This
plan touches neither: it issues ordinary licence codes under the existing licence key and adds no new
payload kind. If CT later ships, a partner issuing profiles rather than codes is the same policy
function over a different artefact, and the ledger row is unchanged apart from what it names — but a
partner would then be issuing *policy* for a fleet, and whether that is delegable at all is a
question for CT, not for this plan.

### Abuse cases

| Case | What happens |
|---|---|
| Partner credentials stolen | The vendor disables one account in one place. Every code minted through it is in the ledger with a timestamp and an operator, so the blast radius is enumerable and the affected customers are named. There is no partner key to leak, because under (A) partners hold none. |
| Partner over-issues | Refused at validation, before a code exists, by a pure function with a typed reason. Under (B) this is only detectable, and only from a self-report. |
| Customer shares a code between more devices than seats | Unchanged and unsolved, honestly. The code is a bearer credential, device-scoped and offline; `seats` is informational. The controls are commercial — short terms, the `reference` on the agreement, renewal as the audit point — not technical. Device binding would fix it and is rejected: it requires knowing the device before selling, which destroys the offline, hand-it-over property the whole licence model rests on. |
| Partner sells a pack it does not carry | Refused by the resale-set check; the pack key must also exist in the signed catalog. |
| Partner issues itself an enterprise or perpetual licence | Refused: tier is not delegable, and every code has a term bounded by `maxTermDays`. |
| Vendor service is compromised | Codes can be minted; no device's verification changes, and nothing on a phone is reachable from the service. Terms bound the exposure. This is the reason to isolate the signing step and keep terms annual. |
| Vendor service is down | Sales continue via the vendor's existing manual generator; the partner waits, which is the failure mode (A) trades for everything above. |

## Build order

**P1 — pure, headless core (one PR).** A Swift package under `Tools/LicenceIssuance/`: a library with
`PartnerGrant`, `IssuanceRequest`, `IssuanceRefusal`, `IssuancePolicy.validate`, the hash-chained
`LedgerEntry`, the billing derivation, and payload construction pinned to the app's encoder contract;
a CLI front-end so the vendor can issue and record from a terminal on day one; and the app-side
fixture test proving a partner-minted code is indistinguishable to `LicenseService`. Nothing here
requires a server, and `Scripts/generate-field-license.swift` becomes a thin caller of the same
payload construction so the two can never drift. The package's `swift test` becomes a CI job beside
the existing iOS suite (`tests.yml`), which today runs only `OpenGlassesTests`.

**P2 — the service (second PR, mostly outside this repo).** Account and session handling, the form,
the ledger store, the renewal and re-issue flows, the period export, and the isolated signing step.
In-repo: `docs/licensing/partner-issuance.md` describing the operational contract, key handling and
the recovery procedure if the service is unavailable.

**P3 — partner onboarding.** The first partner's grant record and resale pack set, the `reference`
convention that ties a code to its agreement, a written issuance procedure, and a rehearsal path.
Rehearsal needs care: the app embeds one production verifying key, so a sandbox-signed code cannot be
tested on a shipped build — a partner rehearses against the CLI's decode output and a debug build,
and the first real code is the first production code.

## Tests

All P1, all headless, all pure:

- **Byte compatibility.** A code minted by the library and one minted by
  `Scripts/generate-field-license.swift` from the same inputs and a fixed clock are byte-identical,
  and both decode through `LicenseService.decode` — the guard on the ISO-8601 + `.sortedKeys`
  contract that three pieces of code now depend on.
- **Indistinguishability.** A library-minted code signed with the test keypair grants through
  `FieldAssistEntitlementEvaluator` with the same tier, expiry and `livePacks` set as a
  generator-minted one (the `LicenseServiceTests` / `FieldAssistEntitlementTests` pattern), and no
  existing app test changes.
- **Grant constraints, one test per refusal.** Enterprise refused; solo refused; a pack outside the
  resale set refused; a pack key absent from the catalog refused; term beyond `maxTermDays` refused;
  seats beyond `maxSeatsPerCode` refused; a pilot when pilots are not allowed refused; a pilot
  without an expiry refused; a request under an expired grant refused.
- **Quota.** A request that would exceed the remaining quota is refused with the remaining count; the
  request that exactly consumes it succeeds; a `replaces` re-issue does not consume quota; a lapsed
  code's seats return to the quota only if the billing model says they do (fixture-driven, so the
  open question below is answered by changing one function).
- **Ledger integrity.** Rows chain; an altered row breaks the chain at that row and every later one;
  `licenseIDHash` in the row equals `LiveFieldAssistEntitlementProvider.licenseIDHash(for:)` of the
  minted code; a property test that no field of any serialised row contains the code or its payload
  bytes.
- **Billing derivation** over a fixture ledger with a fixed period boundary, including a renewal
  mid-period, a re-issue, and a code issued on the last day of the period.
- **Packs round-trip.** A code minted with two of a partner's three resellable packs unlocks exactly
  those two through the EG resolution table, and unlocks nothing once it lapses.

## Non-goals

- **A seat server, per-device activation, or device binding.** Seats stay recorded and unenforced on
  device; this plan caps *issuance*, not installs.
- **Changing what the app verifies.** No new payload kind, no chain, no second embedded key, no new
  trust root. If a change to `LicenseService` turns out to be required, that is the signal to
  re-examine this recommendation, not to make the change quietly.
- **A consumer storefront.** Solo stays on the App Store. Nothing about this service may appear in
  the app; EE's string-level copy guard exists precisely so an off-store purchase path cannot leak
  into the paywall.
- **Partner-authored vault packs.** EG's non-goal stands: the vendor signs every pack. A partner may
  *resell* a pack it has been granted; it may not publish one.
- **Sub-partners.** One level of delegation. A partner reselling through another partner is a
  contract question, and the ledger has no shape for it on purpose.
- **Becoming a licensing platform for anything but Field Assist.** `feature` stays `field_assist`;
  Medical Compliance and Accessibility are not in scope (Accessibility is free and never gated).

## Open questions

- **Bill on issuance or on live seat-months?** Leaning issuance: it is a discrete ledger event and
  needs no reconciliation. Live seat-months matches how the partner's own customers think about it
  and is what a partner will ask for; it is derivable from the same rows, at the cost of deciding how
  a mid-term re-issue and an overlapping renewal count.
- **Where the signing key lives** — a managed KMS/HSM from the start, or a file-backed key handled
  the way `Scripts/generate-field-license.swift` handles it, isolated from the web tier. The second
  is a week cheaper and the thing most likely to be regretted.
- **Whether a signed revocation list is worth building at all**, given it must fail open and can only
  act when a device is online. Leaning no, and bounding exposure with term length instead.
- **Whether partners may issue pilots.** A pilot is an evaluation the vendor may want to know about
  before it happens; against that, a partner that cannot demo cannot sell.
- **Whether a partner may include a pack authored by a different partner**, which puts two revenue
  shares on one code and is a contract shape before it is a code shape.
- **Whether the code should name its issuer** (the deferred `issuer` claim) and whether a white-label
  partner would accept it.
- **Where the service runs.** The repo's only publishing infrastructure is static hosting via
  `pages.yml`, which cannot mint. This is the first vendor-run service in the product and the first
  thing in it with an uptime obligation.
