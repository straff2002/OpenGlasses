# LicenceIssuance (Plan JS P0 / EI pure core)

Vendor-only Swift package, macOS 13+ and Linux, Foundation and CryptoKit (swift-crypto's `Crypto` on
Linux, the licence service's containers). It is not linked into the production app. Its sources are
compiled into the iOS **test bundle** to exercise the deployed verifiers and profile manager without
changing them. Authentication, publishing, PDFs, reminders, seats and partner UI belong to later
phases; P1 lives in the private `avenkin-licence` repository.

## Run

From the repository root:

```sh
swift test --package-path Tools/LicenceIssuance
docker run --rm -v "$PWD":/src:ro -w /src swift:6.4 swift test --package-path Tools/LicenceIssuance --scratch-path /tmp/build
./Scripts/tests/signing-key-handling.sh
swift run --package-path Tools/LicenceIssuance licence-issuance /private/vendor/ledger.jsonl command.json /private/vendor/licence-key.txt
```

The terminal takes **paths**, never key material. Use a protected key file with its first non-comment
line containing the base64 raw Ed25519 key. Keep the journal, lock file, command files and keys in a
private vendor directory, never this repository or a web root. No production price, customer, bank
account or key is included. Tests generate throwaway keys and use fictional currency `XXX`.

The original `Scripts/generate-field-license.swift` and `Scripts/make-org-profile.swift` entry points
remain runnable both directly and via `swift`. They build their package executable on first use.
The package targets symlink to those scripts so there is only one argument/key-handling implementation.
Both use `IssuanceWire` for encoding and signing; activation sealing uses `ActivationKeyMint`.
`generate-field-license --issued-at ISO8601` supplies a fixed clock for fixtures; normal issuance uses now.
The unrestricted manual generator remains the vendor's recovery tool, not a partner-policy bypass
exposed to a service account.

## Linux

swift-crypto (pinned exactly in `Package.swift`, with `Package.resolved` committed) is a dependency only on
Linux; on Apple platforms every source imports CryptoKit and nothing from it is compiled in. The first
`swift test` or direct script run resolves it once from GitHub. `PlatformTests` pins the bytes of a licence
payload, a profile and ledger rows, and runs on both platforms (CI's `licence-issuance-linux` job), so a
journal the service writes on Linux verifies with the macOS tools. `make-org-profile` stays a macOS tool
(passcode prompt, PBKDF2, the admin card's QR); on Linux it says so and exits, and its byte-identity test
is skipped there.

## Command JSON

All dates are ISO 8601. `operatorId` is required on every command. The CLI is a local **vendor** tool;
its files and operator identity are trusted inputs. A hosted service must authenticate the operator,
load the vendor's versioned grant itself, and never accept a grant, clock, price or catalog key from
an authenticated partner's request.

| `action` | Other fields |
|---|---|
| `order` | `id`, `grant`, `request`, `profileId`, `bankDetails`, `catalogProof`, `catalogPublicKey`; optional `renewalOf` (prior order ID) |
| `issue` | `id`, `grant`, `request`, `catalogProof`, `catalogPublicKey` (EI issuance or like-for-like lost-code reissue) |
| `payment` | `payment` with `id`, `invoiceNumber`, positive `amountMinor`, `receivedAt`, `bankReference` |
| `credit` | `credit` with `id`, `invoiceNumber`, positive `amountMinor`, `issuedAt`, nonempty `reason` |
| `inspect` | No extra fields; prints the verified ledger without codes |
| `export` | `from`, `until`; prints invoices, credit notes and payments in the half-open period as JSON |

`PartnerGrant` contains `partnerId`, `version`, `tiers`, `packs`, `maxTermDays`, `maxSeatsPerCode`,
`seatQuota`, `pilotsAllowed`, `maxPilotDays`, `validFrom`, `validUntil`, `maxUnpaidSeats`, and `prices`.
`prices` contains `currency`, `taxTreatment`, and `perSeatByTermDays` (a JSON object mapping term days
to the **final invoice amount per seat in minor currency units**). The agreement supplies these
amounts and tax wording; the library does not infer rates or perform tax conversion.

`IssuanceRequest` contains `licensee`, `tier` (`team`), `plan` (`team` or `pilot`), positive `seats`,
`termDays` **or** `expiry`, `packs`, `reference`, optional `replaces`, and optional HTTPS `profile`.
Sales require `termDays` and `profile`; the request's `reference` is retained as the partner's own
paperwork reference, while the **signed code's** `reference` is always the order ID. `replaces`
is an issuance ID for an EI lost-code reissue, not a renewal. Renewals are separate billable orders.

`catalogProof` is `VerifiedPackCatalog.Proof`: `envelope` (the base64 bytes of the signed catalog JSON)
and `packsById`. Each pack proof has `manifest` (base64 `pack.json`) and `files` (every other extracted
file by relative path, with base64 data, including `manifest.json`). The verifier checks the catalog
signature, each listed pack's signature over the same sorted file digests as `VaultPackSignature`,
and the catalog/manifest ID, vault ID and version. Resale keys come from the signed manifest's
`licensePack ?? vaultId`. An empty signed catalog needs no pack proofs. The vendor configures the
trusted catalog public key; it is separate from the licence key. The tests cover a custom pack key
and refuse missing, changed or foreign-signed proofs.

On success an issuance prints its bearer code **once**, after the journal row is durable. Other
commands print `recorded`. Payments prompt for exactly `PAY <invoice-number> <minor-amount>`.
No flag silently confirms payment. Inspect/export do not need a signing key. Reusing payment/order
IDs is refused; after a crash inspect the journal before retrying. A lost delivery needs a reissue,
not another charge. Signing failure commits neither invoice nor payment nor issuance.

## Rules pinned by fixtures

- Grant validity is `[validFrom, validUntil)`. Enterprise, solo, unknown and non-resellable packs,
  perpetual/invalid terms, excessive seats, expired grants and exhausted quota are typed refusals.
- Bill on issuance: quotas count original issued seats for the agreement, including expired codes;
  renewals consume fresh quota. Unpaid renewal orders reserve quota before their code exists.
  Like-for-like reissues keep licensee, tier, plan, seats, packs, expiry, profile and reference and
  replace only the current leaf of the same partner's chain. They consume no extra quota or bill.
- A new commercial order signs `expires = issue + 35 days`; its invoice is due at `issue + 30 days`.
  Commercial terms shorter than the provisional window are refused. Pilots use their bounded
  actual term, raise no invoice, and never gain a 35-day extension.
- Amounts use integers, with checked multiplication and addition. Partial payments stay open. Only
  confirmed payments covering an uncredited invoice in full produce a full code. Excess receipts
  are recorded, without extending term. The full expiry remains `issue + term`, even if payment
  arrives after day 35 or after the entire term. Status is derived; paid terms still lapse at expiry.
- Any open invoice due at or before now blocks another order (including a pilot). Its full seat count stays
  in unpaid credit until financially settled. The unpaid-seat cap refuses an order that exceeds it.
- Invoices are immutable `let` snapshots with sequential `INV-000001` numbers. Refused orders and
  pilots consume no invoice number. A correction appends a credit note, never edits an invoice.
  Credits settle accounting but **never authorize a full licence**, nor revoke an already issued paid code. For a credited invoice, payments
  may settle its remaining balance; correct/rebill through a new order when a paid licence is needed.
- A renewal must reference a paid prior order for the same partner/customer/profile and be raised
  at least 35 days before prior expiry. It emits no provisional code; its paid expiry is the prior
  expiry plus the new term. It cannot branch into two successor orders.

## Durability, delivery and recovery

Each command is one hash-chained JSONL row: sale (order + invoice + provisional issuance), payment
(payment + optional full issuance), credit or manual issuance. A full SHA-256 code digest is the
uniqueness key; its first 16 hex characters match the app's audit/support `licenseIDHash`. The
journal has no code, profile document, short key or private key fields. Grant sets are sorted before
encoding so hashes survive process restarts. Keep customer data in this journal private.

The CLI holds a sibling `flock` lock through reading, verifying, signing, appending and `fsync`.
Writers must use that protocol. It refuses a corrupt/torn row rather than silently discarding it.
A new service must persist **all** state changes atomically under a serializable transaction before
returning any code. The value library alone does not coordinate concurrent service requests.

A hash chain detects edits, not an adversary able to rewrite the entire chain. Back up the journal
and retain its reported head hash separately. `verify(expectedHead:)` detects truncation or rewritten
history against that trusted anchor. A crash/write failure produces no code; stop, inspect and
restore the journal from a verified backup rather than deleting its tail to force a retry. Invoice
numbers must never be reused. Durable disk/backup management and access control are vendor duties.

`IssuedCode.profileDocument(...)` constructs the minimal signed hosted profile using a **separate**
profile signer, key ID and a 365-day lease, without policy expiry, revocation or erasure settings.
`ActivationKeyMint` generates/displays a short key and seals a code for the deployed public activation
directory. These delivery artefacts are ephemeral outputs, never journal fields. P1 must publish the
profile at the signed HTTPS claim and the activation file on the existing public site; before
publishing either, persist the journal transaction. An offline phone still lapses until it fetches
the paid code. Publishing/retrying delivery after a crash is a P1 responsibility; the core does not
pretend a returned full code has reached a phone. To re-seal an existing activation file P1 needs
protected delivery-key material outside the issuance journal, or issues a fresh activation key.

The integration test enrols a provisional hosted-profile code through `OrgEnrolmentService` and
`OrgProfileManager`, advances to day 35, observes locked entitlements/packs with a live profile lease
and no departure/erasure, then fetches the paid profile at day 40 and regains entitlement. Existing
Office inline verification is a **different route** and rejects hosted-profile licences. Its test
uses a correctly bound inline signed pair with the same provisional/full expiries, observes
`notCurrentlyValid -> stop(managementLapsed)`, and restores verification with the paid expiry.
Workiz regression tests use fixtures only; no real account or qualification runs are involved.

CryptoKit randomizes Ed25519 signatures on this platform. Compatibility therefore asserts identical
ISO-8601/sorted-key payload bytes, valid signatures, identical app entitlement/pack outcomes, and
exact full code assembly with a fixed valid signature. It does not incorrectly require two
independent randomized signatures to be equal.

## Customers and presets (P0b)

`SalesBook.signUp` writes a `Customer` and its first sale as **one** journal row (`.signUp`). The customer's
`licensee`, `organizationID`, `profileId` and profile address (`<base>/p/<profileId>`) are fixed; the ledger
refuses any later row that changes them, and any order outside the customer API that names its profile.
Sign-up seals the first code under a new activation key, returns the key and sealed file **once**, and records
only the file name. Later rows are `.customerChange` (preset, administrator verifier, partner move, key rotation).

- `order(id:customerId:…)` builds the request from the customer, never the partner: a renewal of the
  customer's current code, or a fresh order once that code has lapsed. One live code per customer.
- `increaseSeats` is co-termed: an invoice for the added seats, pro-rated **by day** over the whole days left
  on the live code (a part day counts), rounded half up. On payment the code is replaced by one with the
  total seats and the same expiry. No code until paid, and no increase while any order is unpaid. The
  agreement may choose a different rule (plan open question); this is the core's one rule until it does.
- `ProfilePreset` is vendor-authored and versioned; its digest is recorded on the customer, so an edited preset
  under the same version is refused (`presetChanged`) rather than reaching every phone. A partner picks only
  listed values, a listed vault pack whose `licensePack` is in its grant, and a listed AI model (never a key).
  `leaseDays` is 60–365.
- `setAdminPasscode` accepts `{salt, iterations, hash}` only, with the app's `AdminSecrets` bounds.
- `rotateActivationKey` seals the **current** code under a new key and lists the old file for deletion.
- `profileDocument` builds and signs the customer's profile from its preset, choices, verifier and current code
  through `ProfileContract`, the same contract `make-org-profile` uses, so both produce the same bytes.

The key-for-life path (key → sealed expired first code → enrolment → the profile's current code active,
nothing re-sealed) is proven in `LicenceIssuanceIntegrationTests` against the app's own enrolment.
Not in P0b: the setup link and the administrator contact it uses (P1), renaming a customer, presets that
carry an `officeAuthority`, and terminal commands for customers (the service is their caller).

## Device seats (P2)

`Seats.swift` is the contract between a phone and the seat service, and the rule that counts seats.

- **Codes.** `IssuanceRequest.seatCheck` / `CustomerOrder.seatCheck` (and `--seat-check` on the generator)
  sign `seatCheck: true` into the code. It needs a `profile`, because the seat service is that address's
  origin. A seat increase keeps the claim of the code it raises. Absent, the payload bytes are unchanged.
- **Wire.** `POST <origin>/seats/nonce` returns a single-use nonce (`SeatNonceReply`, five minutes). Then
  `POST /seats/claim`, `/seats/renew` or `/seats/release` sends a `SeatEnvelope`: the request's JSON
  (`SeatClaimRequest` has exactly `build`, `devicePublicKey`, `enrolmentId` and `profileId`), the nonce, and
  the phone's ECDSA P-256 signature over `SeatWire.signedBytes` (domain, action, nonce, request). The reply
  is always a `SeatReply`: a lease, or a `SeatRefusalCode`.
- **Lease.** `SeatLeasePayload` (`deviceKeyHash`, `enrolmentId`, `issued`, `licenseIDHash`, `notAfter`),
  Ed25519-signed under `openglasses.seat-lease.v1\n` with the seat-lease key, a third key. It runs 30 days
  and is honoured for 14 more (`SeatWire.leaseDays`, `graceDays`).
- **Counting.** `SeatPolicy.claim` / `renew`: a seat is held while it is not freed and its lease plus
  grace has not run out. The same key claiming again keeps its seat. A full licence is refused with
  `.full` and its seat count. A lapsed or non-seat-checked licence gets no lease. A freed seat's renewal
  is `.freed`.

The app's verifier (`DeviceSeatLease`) is held to these bytes by `DeviceSeatTests` in the app's test bundle.

## Validation (2026-10-23)

Local Xcode 27.2 / Swift 6.4.2: 33 package/terminal tests, 17 signing-key checks and the
privacy-logging gate pass. On a dedicated iOS 27.0 simulator, 161 related app tests pass; a
separate 27-test run includes all four new integration tests and the Workiz request/retention
fixtures. The CI package job and existing iOS/security jobs remain the merge gates. No live
Workiz account, real signing key or production app verifier change was used.
