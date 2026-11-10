# Plan JS — Licence Sales and Device Seats (a partner orders codes, pays by bank transfer, and a code counts its phones)

**Status:** 🚧 P0 merged 2026-10-23 (PR 838); validation recorded in `Tools/LicenceIssuance/README.md`. Hosting for P1 decided the same day (*Hosting*). **P0b built 2026-10-26** (PR 847; customers, presets, co-termed seat increases, key rotation, the key-for-life test; *P0b implementation notes*). **P1 built 2026-10-26** in the private service repository, after the package's Linux build (PR 853); not deployed yet. **P2 built 2026-11-09** (PR 1010; device seats: the app side and the shared seat contract in this repository, the service's endpoints in the private one; not deployed; *P2 implementation notes*). The owner settled the lease at **30 days plus 14 days' grace** the same day. P3 remains unimplemented.
**Origin:** the pilot partner resells Field Assist team licences and needs to order and pay for them
without waiting on the vendor. The owner asked whether a licence could be held to a number of
devices, and whether one server could produce the code and its QR, and let the partner buy and be
invoiced. Today every code is minted by hand ([`Scripts/generate-field-license.swift`](../../Scripts/generate-field-license.swift)),
and `seats` is a label nothing counts.
**Decided (owner, 2026-10-23):**
1. **One vendor-run server** issues codes, keeps the ledger, raises invoices, and in P2 counts seats.
2. **The partner pays by bank transfer.** No card processor and no stored payment details. An
   invoice carries the vendor's bank details and a payment reference. The vendor marks it paid when
   the money arrives.
3. **Payment terms are 30 days.** An order is issued at once as a **provisional** code that expires
   **35 days** after issue. When the invoice is paid, the server replaces it with the **full-term**
   code. If the invoice is not paid, the provisional code lapses on day 35 on every phone that holds
   it.
4. **A lapsed licence cannot be used, and deletes nothing.** The phone stops connecting to the
   firm's systems: Avenkin Office, Workiz ([Plan JR](JR-workiz-from-the-phone.md)) and any job system
   like them. Field Assist's team features lock. Stored credentials, jobs, reports and manuals stay
   on the phone, and they work again the moment a paid code arrives.
5. **The person's own use of the app is untouched.** Accessibility is mainly for personal users, and
   a lapsed organisation licence takes nothing from someone's own setup.
6. **Sales first, seats second.** P0–P1 change nothing in the app. P2 counts phones against `seats`
   and changes the app.

**Amends** [Plan EE](EE-field-assist-commercial-licensing.md) ("What seats mean": seats recorded, not
enforced) and [Plan EI](EI-licence-issuance-portal.md) (non-goal: "A seat server, per-device
activation, or device binding"). Both stay true until P2 ships, and only for licences P2 marks as
seat-checked. **Builds on EI:** this plan takes EI's recommended design (A), a vendor-hosted service
holding the key and validating against a partner grant, and its pure core as written. It adds what EI
left open: payment, the provisional term, delivering a replacement code without retyping, and seats.

---

## Product promise

To the partner: "Order a licence for a customer and hand over the key the same afternoon. You get
an invoice with 30 days to pay. Pay it and the licence runs its full term with nothing to re-enter.
Don't, and it stops on day 35."

To the vendor: "Every code is on the ledger, every ledger row is on an invoice, and the credit we
extend is 35 days of one order, never a year."

To the technician: nothing about money. The phone works from the moment the key is entered. If an
invoice goes unpaid, the phone stops connecting to the office and the job system, and Field Assist
shows the message it already shows for an expired licence. Nothing is erased, and the person's own
use of the app carries on.

## Verified starting point (main, 2026-10-23)

- **A code is strict, offline and immutable.** `LicenseService.decode` accepts exactly two
  components (`base64(payload).base64(signature)`) under one embedded Ed25519 key. The payload's
  `expires` is signed, so a code's term cannot change. "Changing to the full term" therefore means
  **minting a second code** and getting it onto the phone.
- **A licence can point at a profile, and a profile can carry a newer licence.** The `profile` claim
  (CT 3a, `--profile` on the generator) makes entering the key enrol the phone in the organisation's
  hosted profile. `OrgProfileManager` re-fetches that address at launch and on foreground, at most
  once a day (`ProfileLease.renewalInterval` = 86,400 s). `renew(with:)` activates the renewed
  profile's `licenceCode` when it differs from the one in force. **So a full-term code published in
  the profile reaches every enrolled phone on its next daily fetch, with nothing typed.** This is the
  mechanism decision 3 needs, and it already ships.
- **A minimal profile is valid.** `ConfigProfile` needs only `profileId`, `organizationName`,
  `issued`, `leaseDays` (held to 7–365) and `settings`, which may be empty. `licenceCode` is
  optional. `Scripts/make-org-profile.swift` signs one with the profile key (`og-profile-2026-09`,
  separate from the licence key, domain-separated).
- **The short activation key resolves through the public site, at a fixed address.**
  `ActivationKey.defaultDirectory` is `PublicSite.activationDirectory`, the `activation/` directory
  `Scripts/stage-pages-site.sh` publishes. Every shipped build reads it there. The server cannot
  serve activation files itself without an app change, so **P1 publishes the sealed files to the
  public site.** The profile address is different, because it sits inside the signed licence, so it
  can point at the server.
- **An expired licence locks, it does not erase.** The entitlement provider re-decodes the stored
  code on every read, and an expired `expires` fails the gates. The status card says *"This licence
  has expired. Enter a renewal code from your administrator."* Plan IL keeps the same rule for its
  technician app: finished jobs stay readable and composed reports can still be sent.
- **The office connection already stops on an expired licence.** `OfficeInlineEntitlement.verify`
  refuses a licence past its `expires` (`notCurrentlyValid`), and `OfficeFieldConnectionPolicy` turns
  that into `.stop(.managementLapsed)`. The saved approval is rechecked every 30 s while the
  connection runs (`approvalRecheckInterval`), so a lapse ends a live connection within half a
  minute, and a missing licence stops it the same way (`.missingLicence`). **The recheck is local:**
  `OfficePairingService.currentApprovedPeer()` reads only the stored record, the stored code, the
  phone's own stores and its clock. It makes no network call, so being out of signal neither
  triggers a lapse nor delays one. The network matters for one thing only: getting the paid code
  (see *A phone offline on the day of payment*).
- **Workiz is implemented (JR, #837).** It checks the live licence before every request and retains
  local credentials and state at lapse. P0 uses its fixture tests; live qualification remains deferred.
- **A profile lapse or revocation is different, and harsher.** A lapsed profile lease withholds the
  licence the profile brought. `eraseAfterLapseDays` (an organisation opt-in) erases the firm's
  content, and a signed revocation erases it after delivering records. **An unpaid invoice must
  therefore be expressed only as a licence expiry, never as a lease lapse or a revocation.**
- **A phone already has an enrolment id** (`OrgProfileManager.newEnrolmentId`, eight hex characters
  made on the phone), but it never sends it anywhere: the renewal fetch is an anonymous GET of a
  static address. Nothing on any server can count phones today.
- **There is no vendor server.** Signed artefacts are static files on the public site. This plan
  builds the first networked vendor service, with the blast-radius reasoning EI already set out.

## How an order runs (P0–P1, no app change)

```
day 0   partner orders: customer, seats, term, packs, reference
        → server validates against the partner's grant and credit (pure policy)
        → mints a provisional code: expires = day 35, profile = <server>/p/<profileId>
        → signs the customer's profile carrying that code; serves it at that address
        → seals the activation file and publishes it to the public site's activation/
        → shows the short key and its QR once; ledger row written
        → raises invoice INV-…: due day 30, bank details, reference = invoice number
day 0+  customer's phones take the key → licence active → enrolled in the profile
paid    vendor records the payment against the invoice
        → server mints the full-term code (expires = day 0 + term), replaces = provisional row
        → re-signs the profile with it; re-seals the activation file with it
        → each phone picks it up on its next daily fetch
day 30  unpaid: reminder to the partner; no new orders while overdue
day 35  unpaid: the provisional code lapses on every phone; no office or job-system connection,
        Field Assist locks, nothing erased
late    paid after day 35: full-term code published as above; phones recover on their next fetch
```

**The full term starts on day 0, not on the day of payment.** The customer has been using the
licence since issue. Paying late does not buy extra days, and paying early loses none.

**Renewals need no provisional code.** The renewal invoice is raised at least 35 days before the
running code expires. When it is paid, the next term's code goes into the profile, and the phones
switch to it when it is issued. Unpaid, the current code simply runs out at the end of its term.
Provisional codes exist only for new customers and for seat increases.

**What every code the server mints carries:** the `profile` claim (so a replacement can reach the
phone), `reference` = the order id, and `seats`. The profile carries no settings unless the
customer's organisation also uses CT configuration, and its `leaseDays` is longer than the
provisional window (at least 60). The lease must never be the thing that runs out first.

**A phone offline on the day of payment** still lapses on day 35 if it has not fetched since. It
recovers on its first fetch after that. The partner's view says how many phones have not yet picked up
the full code once P2 can see them. Before P2, the server only knows the profile was fetched, not
by whom.

**The pilot's existing code** was hand-minted with no `profile` claim. It cannot be upgraded in place.
When the pilot becomes a paid order, its phones enter the new key once.

### What a lapse stops, and what it keeps

**Stops: every connection to the firm's systems.** It does this by checking the live licence each
time, not by remembering a decision made at setup.
- **Avenkin Office:** already done (see *Verified starting point*). P0 adds a test that pins it to a
  lapsed provisional code.
- **Workiz, and every later job-system connection on the phone:** the client checks the live Field
  Assist entitlement (`FieldAssistEntitlement.shared`, which re-decodes the stored code) before
  **every** request, not only when its Settings section is drawn. A refused check sends nothing and
  says *"⟨licensee⟩'s licence has expired. Your administrator can renew it."* The saved API key is
  kept. This is a requirement on Plan JR's P1, and JR's tests carry it: a lapsed licence sends no
  request and keeps the key. *(Checked 2026-10-23, after JR merged in PR 837: every Workiz request
  and the report sink first check `WorkizConnection.isRunning`, which reads `Config.fieldAssistUnlocked`,
  the live entitlement. A lapse sends nothing and keeps the key, and reports wait. **Still to do:**
  the refusal says "The Workiz connection is off." (`WorkizFailure.disabled`), not that the licence
  has expired.)*
- **Field Assist's team features:** locked through the gates that exist (vaults, packs, procedures,
  audited export, team learnings).

**Keeps: everything on the phone.** Credentials, jobs, reports, captured manuals and the profile all
stay. Reports finished before the lapse wait in their outbox and go when a paid code arrives. Nothing
is lost, and nothing reaches the firm while unpaid. The lapse never triggers CT's lapse erasure or
revocation, and the profile's lease runs on.

**Untouched: the person's own app.** Their own model keys, conversations, memory and the
accessibility tier carry on. A lapse is about the firm's licence, and the firm's systems are what
stop.

**The way back is automatic.** The daily profile fetch keeps running while the licence is lapsed,
because it is how the paid code arrives. The status card's *Check for Renewal* runs it at once.

### Bank transfer, specifically

- **Invoices are immutable and numbered in sequence.** A mistake is corrected with a credit note,
  never an edit. The number is the payment reference the partner puts on the transfer.
- **Recording a payment is a vendor action:** invoice number, amount, date received and the bank's
  reference, from the bank statement. Only a payment covering the invoice in full marks it paid. A
  short payment is recorded and the invoice stays open (see *Open questions*). Recording asks for
  confirmation, because once a full-term code is published it cannot be withdrawn (see *Failure
  cases*).
- **Amounts come from the partner's agreement**, as a wholesale price table on the grant: currency,
  per seat per term, and the tax treatment the agreement states. No figure appears in this plan or
  in the repo.
- **An accounting export** (CSV of invoices, credit notes and payments for a period) is the hand-off
  to the vendor's books. The server keeps no accounts of its own.
- **Credit is bounded by the grant:** `maxUnpaidSeats` caps the seats on open invoices, and any
  invoice past due refuses new orders (`.overdueInvoice`) until it is paid. Pilots raise no invoice
  and stay within `maxPilotDays`, as EI defines them.

### What the partner and the vendor see

The partner uses a web portal. **Order** has EI's four fields (customer, term, seats, reference)
plus the packs the grant allows. Submitting shows the short key, its QR and the long code once.
**Ledger** lists every code, showing provisional, paid, lapsed or replaced, with the date a
provisional code lapses unless paid. **Invoices** shows open, paid and overdue invoices, each with
bank details and a PDF. **Renewals** lists codes expiring within 60 days, with a Renew action.

The vendor uses a console. It covers partner grants (EI's table plus the price table and credit
limits), record payment, overdue invoices with their lapse dates, the period export, and every
partner's ledger.

## Customers (decided 2026-10-23)

**Owner decision:** each company a partner signs up is a **customer** with **one profile and one
activation key for its whole life**. A partner configures a customer **only through presets the
vendor has approved**. P0 takes a `profileId` per order and builds only the minimal profile, so both
rules are new.

### One customer, one profile, one key

When the partner signs up a company, the service creates a customer record once:

| Field | Set | Changes |
|---|---|---|
| `customerId` | At sign-up | Never |
| `partnerId` | At sign-up | Only by the vendor (moving a customer to another partner) |
| `licensee` | At sign-up, the exact name the phones show | Never. See *Renaming* |
| `organizationID`, `profileId` | At sign-up | Never |
| Profile address (`https://licence.avenkin.com/p/<profileId>`) | At sign-up | Never. It is inside every code |
| Activation-key file name | At sign-up | Only when the key is rotated |
| Preset (id and version) and the partner's chosen values | At sign-up | By the partner, within the preset; every change re-signs the profile |

- **Every order belongs to a customer:** the first order, seat increases, renewals, and a
  provisional code turning full-term. All of them update that customer's one profile, and phones pick
  the new code up on the daily fetch.
- **One live code per customer.** A seat increase is **co-termed**: the new code carries the total
  seats and keeps the current expiry, and the invoice is pro-rated by the agreement's own rule. Two
  overlapping codes with different end dates for one company would be two answers to "when does
  this licence end".
- **The key is shown once** at sign-up, as the short key and its QR. The partner hands it to the
  company's administrator, and every technician at that company uses the same key for as long as
  the company is a customer.

**Why one key can last for life without the server keeping it.** The key unlocks one sealed file,
and that file holds the customer's *first* code, whose signed `profile` claim names the customer's
fixed address. When a phone enters the key, enrolment decodes the code without checking its expiry,
fetches the profile, and activates the profile's later-issued code (`OrgProfileManager`, the
same-organisation check: "the later-issued of the two is the one activated"). So a key entered two
years later still opens a first code long since expired, and the phone ends up on today's code.
**The service never stores the key**, and the ledger keeps only the file name, as CT 3a requires.

That rests on a path nothing tests yet as a whole: short key → sealed **expired** provisional code →
enrolment → the profile's current code active. `LicenseService.activate(code:)` refuses an expired
code, so any step that calls it on the entered code would break the rule. **P0b proves the path
with a test.** If it fails, the fallback is re-sealing: the signer keeps each customer's key
encrypted at rest and re-seals the file with every new code. That is no worse than the signing keys
the signer already holds, but it is a stored bearer secret, so it is the fallback, not the design.

- **A lost or leaked key is rotated:** a new key and sealed file, with the old file deleted from the
  public site. Phones already enrolled are untouched, because they renew from the profile, not from
  the key. Before P2, a leaked key is the same exposure EE and EI already accept. With P2, extra
  phones are refused a seat.
- **Renaming a company** changes `licensee`, and the same-organisation check refuses an entered key
  whose code names a different organisation from the profile's. So a rename is a key rotation: the
  new sealed file carries a code in the new name, and enrolled phones take the renamed code on their
  next fetch (`renew(with:)` does not compare names).
- **Ending a customer** is not a delete. Its last code runs out, its profile stays served so phones
  show why they stopped, and the record stays in the ledger.

### Partner configuration through presets

Plan CT decided (2026-09-23, decision 1) that **profiles are issued by the vendor only**, and
partners issue codes, never profiles. A partner setting a company's edition, model or vault pack by
hand would be a partner issuing policy. Presets keep CT's rule true: the vendor writes every rule
in a profile, and the partner only picks.

- **A preset is a vendor-authored, versioned template** of everything a profile may carry apart from
  the licence: `edition`, the `SettingKey` ceilings and starting values, `lockdown`, `leaseDays`
  (at least 60, as above), `eraseAfterLapseDays` (absent unless the preset says otherwise), and
  **enumerated choices**. Examples: the vault packs the preset allows (always within the partner's
  grant), and the AI providers and models it allows (`aiModel`, never a key).
- **The partner chooses only among a preset's enumerated values,** in the portal. No free-form JSON,
  no `SettingKey` the preset does not list, no base URL the preset does not list. The signer builds
  the profile from the preset plus the choices, re-validates both, and signs it with the vendor's
  profile key. The partner never holds a key and never writes a rule.
- **Presets are added and changed by the vendor only,** in the console. A new preset version applies
  to a customer when the partner moves the customer onto it, never silently. The profile's renewal
  path already applies a changed profile without asking (CT PR 2b), so a silent preset change would
  reach every phone of every customer at once.
- **The first presets** are the two the pilot needs. *Field Assist* is the CT 3b edition, the
  technician's tabs and the administrator behind a passcode. *Field Assist with Avenkin Office* is
  the same, with the field-service route through the office. The vendor drafts both before P1 ships.

**The administrator passcode belongs to the company, so its own administrator sets it, not the
partner.** At sign-up the portal produces a **one-time setup link** for the company's administrator.
Opening it asks for the passcode and derives the verifier **in the browser** (PBKDF2-HMAC-SHA256,
the derivation `AdminSecrets.pbkdf2` checks, with a fresh salt and an iteration count inside
`AdminSecrets`' accepted range). Only `{salt, iterations, hash}` reaches the service, so neither the
partner nor the vendor ever sees the passcode. The signer re-signs the profile with the verifier.
The link works once and expires after 7 days. Until it is used, the profile carries no passcode,
and the phone has no administrator view (`AdminGate`: "a profile that issued neither a card nor a
passcode has no administrator view on the phone"). The technician's edition still works. A
forgotten passcode has no local reset by design (`AdminGate`), so the partner issues a new setup
link, and the re-signed profile reaches the phones on their next fetch.

**Personal data in a customer record** is kept to the company's name and, optionally, one
administrator contact for the setup link, deleted once the link is used or expires. Technicians are
never named. A seat is a phone (P2), and identity stays CT's axis.

## Device seats (P2, app change)

P2 makes `seats` a number the server enforces, by claiming a seat at first use. EI rejected device
binding because it "requires knowing the device before selling". A claim happens after the sale, on
the phone, so that objection does not apply.

1. **Only seat-checked licences are counted.** The server mints new codes with a signed claim
   `seatCheck: true`. A code without it (every code issued before P2, and any hand-minted one)
   behaves exactly as today. Older builds ignore the unknown claim (synthesised `Decodable`), so they
   activate it as a plain licence. See *Failure cases*.
2. **Claiming a seat.** On enrolment, the phone makes a P-256 key in the Secure Enclave (not
   exportable, not in backups). It sends `{profileId, enrolmentId, devicePublicKey, build}`, signed
   by that key over a server nonce, to `POST <server>/seats/claim`. If the licence has a free seat,
   the server records the claim and returns a **seat lease**, signed by a third vendor key with its
   own domain prefix: `{licenseIDHash, enrolmentId, deviceKeyHash, issued, notAfter}`.
3. **The lease is checked offline, on every entitlement read**, the same way the code is. For a
   seat-checked licence, the evidence is only live while the stored lease verifies, names this
   phone's Secure Enclave key and has not passed `notAfter` plus a grace period. A copied lease fails
   on another phone because that phone does not hold the key.
4. **Renewal rides the daily profile fetch.** The phone presents its lease and gets a new
   `notAfter`. **Decided 2026-11-09: a 30-day lease with 14 days' grace** (the leaning was 14 + 7).
   A phone back from a month's holiday renews the moment it has signal, and one that then spends a
   fortnight out of signal still works. A lost phone frees its seat within 44 days. The seat lease
   is separate from the profile lease (`leaseDays`, 60–365) and from the licence's term.
5. **Seats come back** when the partner (or the vendor) frees one in the portal, when the phone's
   owner-gated removal releases it, or when a lease is not renewed. A freed phone keeps working until
   its current lease runs out. Leases are verified offline, so that overlap is the honest bound, and
   it is at most one lease period.
6. **A full licence** gets a plain answer on the phone: *"All N seats for ⟨licensee⟩ are in use. Ask
   your administrator to free one."* It is treated exactly like a lapse: no office or job-system
   connection, and Field Assist locked. The person's own use of the app is unaffected.
7. **Unpaid, with P2:** the server also stops renewing seat leases for a lapsed provisional code. A
   full-term code published by mistake (see *Failure cases*) can now be stopped too, without a
   revocation: its seat leases are not renewed.

**What P2 sends, and the disclosure it needs.** The enrolment id, a device public key, the app build
and the profile id. It sends no name, no device model, no vendor identifier and no location. The
server does not store IP addresses. By the telemetry rule ("off by default, disclosed by exception,
never silent"), the privacy manifest entry and the in-app privacy copy land in the same PR. Only a
phone holding a seat-checked licence makes the call.

**Phone without office.** The claim is made from the phone. Avenkin Office plays no part, and a firm
running it gains nothing it needs and loses nothing.

## Hosting (P1, decided 2026-10-23)

**Owner decision:** the service runs in **OrbStack containers on the vendor's own Mac**. It is
reachable from the internet, not only from a private network, and it is locked down. It is not
published on Tailscale. Moving it to a proper host is expected before P2, and the design below
keeps that move invisible to phones.

### How it reaches the internet: a Cloudflare Tunnel

A `cloudflared` container opens an **outbound** connection to Cloudflare. Nothing listens on the
router and no port is forwarded, so the Mac is no more exposed than it is now. Unlike Tailscale
Funnel, which serves only `ts.net` names, a tunnel serves **the vendor's own domain**. That matters
because the profile address is inside every signed code and can never change for a code already
issued (the same trap as the Pages address that blocked the repo rename). The one requirement: the
domain's DNS, or at least the delegated subdomain, is on Cloudflare.

### Two hostnames, two doors

| Hostname (example) | Who | What it serves | Locked how |
|---|---|---|---|
| `licence.avenkin.com` | Customers' phones | `GET /p/<profileId>` (signed profiles), and in P2 the seat claim, renew and release calls | Public, but only those paths. No portal page answers on this name. Profile ids are unguessable and there is no listing. Cloudflare rate limits in front. P2 calls are signed by the phone's Secure Enclave key. |
| `partners.avenkin.com` | The partner and the vendor | The portal and the console | **Cloudflare Access** checks identity before any request reaches the Mac: the partner by email one-time code or Google sign-in, the vendor by passkey. Then the app's **own login with two-factor**, so getting past one still meets the other. |

Activation files do not come from the box. Shipped builds read them from the public site's
`activation/` directory (*Verified starting point*), so the service publishes each sealed file there.
**Profiles must never go in the public repository:** each one carries a licence code, and the repo
would list them all.

### Containers, and what each may reach

| Container | Holds | Reachable from |
|---|---|---|
| `tunnel` (`cloudflared`) | The tunnel credential | Outbound to Cloudflare only; forwards to `web` and `public` |
| `web` | Portal and console, sessions, the 2FA secrets | `tunnel`. **Never holds a signing key.** |
| `public` | Read-only signed profile documents | `tunnel` |
| `signer` | The signing keys: licence and profile now, seat lease in P2 | **`web` only, over a local socket on the internal network.** No route from `tunnel`. |
| `db` | Ledger, invoices, payments, customers (a volume) | `web` and `signer`; never exposed |

- **The signer re-runs the policy.** It validates every request against the stored partner grant
  itself, using the P0 package, and does not trust `web`'s decision. A compromised `web` can ask,
  but cannot obtain a code the partner's grant does not allow, and the ledger row is written by the
  signer.
- **Keys:** one 0600 file per key on the FileVault disk, mounted **read-only into `signer` only**.
  Never baked into an image, never in an environment variable, never in a log. The manual generator
  reads the same files, so it remains the recovery path when the box is down.
- **Linux:** OrbStack containers are Linux, so the P0 package needs swift-crypto there. That settles
  the language question: **Swift on Linux**, using the P0 package directly rather than a port held to
  golden fixtures. **Done 2026-10-26:** the package builds and passes its suite in the `swift:6.4`
  image, bytes pinned across both platforms, with a Linux CI job.

### Backups, and running on a home Mac

- **The ledger is the billing record.** It is backed up off the Mac, encrypted, on a schedule, with
  a restore rehearsed once before the first paid order. The hash chain shows tampering. It cannot
  replace a lost disk.
- **The Mac stays on and logged in:** sleep off, OrbStack set to start at login, and the containers
  set to restart automatically. A Mac that naps takes the box with it.
- **Cloudflare decrypts traffic in transit,** so it sees profile documents and the licence codes
  inside them. That is normal for a CDN in front of a service. Cloudflare is named as a processor in
  the privacy policy.
- **Pinned images, patched on a schedule;** the console shows each image's version and the last
  update date.

### When the box is down

- **Before P2, phones are unaffected.** Codes and profiles are checked offline, and a failed fetch
  only delays a renewal. The partner cannot order; the vendor can still mint by hand.
- **The sensitive window is a paid invoice near day 35:** a phone needs one fetch to get the full
  code. Keep the box up around payments.
- **P2 is the point to move.** With seats, an outage longer than the lease plus grace locks
  seat-checked phones. Moving means pointing the domain at the new host, with no new codes.

## Failure cases

| Case | What happens |
|---|---|
| Invoice unpaid | Provisional code lapses on day 35. The office and job-system connections stop and Field Assist locks. Nothing is erased, and finished reports wait in their outbox. Paid later, phones recover on their next fetch. |
| Partner orders and never pays | Bounded by `maxUnpaidSeats` and 35 days. Once an invoice is overdue, no new orders. |
| Payment recorded by mistake | The full-term code is published and, before P2, cannot be withdrawn. Phones verify offline and the only lever is a signed revocation, which erases the firm's content. Hence the confirmation step. With P2, seat leases simply stop renewing. |
| Phone offline at payment | Lapses on day 35 if it has not fetched since; recovers on first fetch. |
| Server down | Phones are unaffected: codes, profiles and leases verify offline, and a failed fetch only fails to renew. Partners cannot order, and the vendor's manual generator still works (EI). With P2, an outage longer than lease plus grace locks seat-checked phones. That is the price of enforcement, and the reason the lease is not short. |
| Customer shares the short key beyond its seats | Before P2: unchanged, as EE and EI say. With P2: the extra phones are refused a seat. |
| Customer keeps an old build to avoid seat checks | An older build ignores `seatCheck`. The App Store serves only the current build to new installs, so the gap closes as phones update. A minimum-build requirement is an open question, not a design. |
| Reinstall without the keychain | A new key means a new claim. The old claim lapses with its lease, or the partner frees it. |
| Server compromised | Codes, profiles and leases could be minted. No phone's verification changes. The signer is isolated from the web tier, as EI says, and now holds three keys (licence, profile, seat lease), each with its own domain prefix. |

## Build order

**P0 — pure core, headless (this repo, one PR).** EI's P1 unchanged: a Swift package
`Tools/LicenceIssuance/` with `PartnerGrant`, `IssuanceRequest`, `IssuanceRefusal`,
`IssuancePolicy.validate`, the hash-chained ledger, payload construction pinned to the app's encoder,
the generator as a thin caller, and `swift test` in CI. Additions:
- `Order` and its states (provisional → paid → active; provisional → lapsed → paid late → active;
  replaced), and the term rule: provisional `expires` = issue + 35 days, full `expires` = issue +
  term.
- `Invoice` (sequential number, lines from the grant's price table, due date, immutable), `CreditNote`,
  `Payment`, and status derived from payments rather than stored.
- Credit refusals: `.overdueInvoice`, `.unpaidSeatLimit`.
- Profile construction through `make-org-profile.swift`'s contract, and activation-file sealing
  through the generator's, both shared rather than copied.
- **The no-app-change test.** A provisional code with a `profile` claim enrols through
  `OrgProfileManager`'s seams. A renewed profile carrying the full-term code is activated by
  `renew(with:)`. The provisional code lapsing on day 35 locks the entitlement and erases nothing,
  and `OfficeFieldConnectionPolicy.afterFailure` answers its `notCurrentlyValid` with
  `.stop(.managementLapsed)`. The full code restores both. No existing app test changes.

**P0b — customers and presets (this repo, small; before P1).** In `Tools/LicenceIssuance`: a
`Customer` record (fixed `licensee`, `organizationID`, `profileId` and profile address; orders keyed
to it); one live code per customer, with seat increases co-termed; a `ProfilePreset` (versioned,
vendor-authored, enumerated choices) and profile construction from a preset plus the partner's
choices, refusing any value the preset does not list; the passcode verifier accepted only as
`{salt, iterations, hash}`, with iterations inside `AdminSecrets.iterationRange`; key rotation
(new sealed file, old file name listed for deletion). The app-side test the key-for-life rule rests
on: short key → sealed expired provisional code → enrolment → the profile's current code active, with
nothing re-sealed.

**P1 — the service (separate private repository; in-repo, only `docs/licensing/partner-issuance.md`), hosted as in *Hosting*.**
The partner portal, the vendor console, the isolated signer, profile hosting at the address the
codes name, publishing sealed activation files to the public site, the daily job (reminders on day
30, lapse report on day 35, renewal invoices 35 days out), invoice PDFs and the accounting export.
The operating document covers key handling, the recovery path with the manual generator, and how a
payment is recorded.

**P2 — device seats (app + service, one PR per side).** App side: the `seatCheck` claim in
`LicensePayload` and the generator (same `.sortedKeys` contract), a pure `SeatLease` verifier with
its domain prefix and embedded key, a Secure Enclave key seam (fake in tests), the claim and renew
client on `BoundedHTTPClient` with its own `NetworkRoute`, entitlement evidence that requires a live
lease for seat-checked licences, the "all seats in use" state, release on removal, and the privacy
manifest and copy. Service side: claim, renew and release endpoints, seat counting, and the seat list
with Free in both consoles.

**P3 — later, each optional.** A warning on the customer administrator's phone before an unpaid
lapse. Bank-statement import to match payments by reference. Emailing invoices from the server
(until then the vendor downloads and sends them).

## Tests

- **P0:** EI's tests as listed there (byte compatibility, indistinguishability, one test per refusal,
  quota, ledger integrity, billing, packs round trip). Also: provisional and full expiry from a fixed
  clock; a late payment's full code ends on day 0 + term; a renewal paid before expiry starts the
  next term at the old `expires`; an overdue invoice refuses an order; unpaid seats at the cap refuse
  an order; invoice numbers never repeat or skip; an edited invoice is impossible (a credit note is
  the only correction); a short payment leaves the invoice open; and the no-app-change test above.
- **P0b:** a customer's `licensee`, `profileId` and address cannot change after sign-up; a second
  order for a customer reuses its profile; a seat increase keeps the live code's expiry and raises
  its seats; a preset choice outside the preset's list is refused, as is a pack outside the
  partner's grant, a `SettingKey` the preset does not name, and an `aiModel` carrying a key; a
  verifier with too few iterations is refused; a profile built from a preset is byte-identical to one
  built by `make-org-profile.swift` from the same inputs; a rotated key's new sealed file opens to the
  current code; and the key-for-life path above.
- **P2:** a lease verifies only with its own domain prefix and key; a lease naming another device key
  fails; a lease past `notAfter` plus grace fails; a licence without `seatCheck` grants with no lease,
  exactly as today; a seat-checked licence with no lease is locked with the "all seats in use" or
  "connect once" state; renewal extends `notAfter`; removal sends a release; a property test that the
  claim request carries no field beyond the four listed; and the privacy-manifest pairing in
  `TelemetryOptOutGuardTests`.

## Non-goals

- **A card processor or stored payment details.** Bank transfer, marked paid by the vendor.
- **Billing per seat in use.** The customer buys N seats, and P2 makes N a cap, so the invoice stays
  per order.
- **Selling to consumers.** Solo stays on the App Store. Nothing about this service appears in the
  app, and EE's copy guard stands.
- **Accounts for technicians.** A seat is a phone, not a person. Identity stays CT's axis.
- **Seat checks for Medical Compliance or anything but Field Assist.** Accessibility is free and never
  gated.
- **Revocation as a payment tool.** An unpaid invoice is a licence expiry and nothing harsher.
- **Locking the whole app.** A lapse stops the firm's connections and its Field Assist features, not
  the person's own app or the accessibility tier.

## Open questions

- **Tax and currency on invoices.** The vendor invoices from New Zealand to partners abroad. The
  agreement and the vendor's accountant decide the tax treatment. The server only prints what the
  grant states.
- **Short payments and bank fees** on international transfers: treat an invoice as paid within a set
  tolerance, or keep it open until the balance arrives?
- **Who may free a seat:** the partner only, or also the customer's administrator phone (CT 3b)?
- ~~**Lease length and grace** for P2.~~ **Resolved 2026-11-09:** 30 days plus 14 days' grace.
  Holidays are covered, and a freed phone stops within 44 days.
- **Whether to require a minimum build** for seat-checked licences, and how the app would say so.
- ~~**Where the service runs**, and in what language.~~ **Resolved 2026-10-23:** OrbStack on the
  vendor's Mac behind a Cloudflare Tunnel, with the portal behind Cloudflare Access, and Swift on
  Linux. See *Hosting*.
- **Whether the customer is told before an unpaid lapse** (P3), given it puts the partner's billing
  dispute on the customer's screen.
- **Finished reports during a lapse.** This plan holds them in the outbox until a paid code arrives,
  consistent with "can't be used". Plan IL's decision 7 lets a lapsed technician app send reports
  already composed, because a late invoice should not hurt the customer. The two should agree.
  Leaning: hold, since the firm can end the hold by paying.
- **Which values each first preset enumerates**, notably which AI providers and models a partner
  may pick for a customer. The vendor drafts the two first presets before P1.
- **Pro-rating a co-termed seat increase:** by day, by month, or whole terms only. The agreement
  decides; the core needs one rule. **P0b uses by day** (whole days left, a part day counting, rounded
  half up) until the agreement says otherwise.
- **Whether the provisional window is fixed at 35 days or per grant.** Leaning fixed: it is the
  credit term, and a partner-by-partner number invites negotiation over it.

## P0 implementation notes (2026-10-23)

The package and terminal are under [`Tools/LicenceIssuance`](../../Tools/LicenceIssuance/README.md).
P0 adopts EI's bill-on-issuance quota model and exact payment coverage (no short-payment tolerance).
Prices and tax text are agreement-supplied immutable invoice snapshots. Credits correct accounting
without authorizing a paid code. A credited order needing a paid code is corrected/rebilled.
Profile/signing and activation sealing share the manual tools' contracts. Production app sources
and verification are unchanged; the test bundle alone compiles the vendor library.

Two starting-point assumptions are clarified by tests: CryptoKit signatures are randomized, so
byte compatibility means payload identity plus exact assembly using a fixed signature; Office
inline verification deliberately rejects hosted-profile licences, so hosted renewal and the Office
inline lapse/restore gate are exercised through their distinct existing routes. P1 must still
implement durable delivery and hosting in the separate private service repository.

## P0b implementation notes (2026-10-26)

In `Tools/LicenceIssuance` (`Customers.swift`, `ProfileContract.swift`); the package README has the rules.

- **One row per sign-up.** The customer record and its first sale are one journal row, so a customer never
  exists without its first code. The ledger itself refuses a later row that changes `licensee`,
  `organizationID`, `profileId` or the profile address, and an order outside the customer API that names a
  customer's profile.
- **The profile contract is shared, not copied.** `make-org-profile.swift`'s structs, allow-list and checks
  moved into the package as `ProfileContract`; the script is now a thin caller, gains `--issued-at` for
  fixtures, and a terminal test runs it against a preset-built profile and compares the payload bytes. The
  app tests that scraped the script for its provider, category and trade lists now compare the compiled
  contract instead.
- **A seat increase issues nothing until paid**, like a renewal. Seats are a label until P2, so waiting costs
  the customer nothing, and it keeps one live code: a provisional increased code would either cut a paid
  term to 35 days or need the phones to step back to an older code if unpaid. No increase is accepted while
  any order for the customer is unpaid, and a renewal must renew the customer's current code.
- **The preset's digest is recorded on the customer.** A preset edited under the same version is refused
  rather than applied, so a new version reaches a customer only when the partner moves it there.
- **The key-for-life path holds with no app change.** The integration test signs up, pays, renews and pays,
  then at day 400 enters the original key on a fresh phone: the resolver opens the expired first code, the
  enrolment fetches the profile, keeps the profile's later-issued code (`licenceToActivate` is nil) and
  activates it, and the sealed file is the one written at sign-up. The re-sealing fallback is not needed.
- **Not built:** the setup link and the administrator contact (P1), renaming a customer, presets carrying an
  `officeAuthority` (the second pilot preset's office route still needs the office's key per customer), and
  terminal commands for customers.

## P2 implementation notes (2026-11-09)

**Owner decisions:** the app side is built first. Its pull request defines the wire contract, and the
service builds against it at the commit its `core.lock` names. The lease is 30 days plus 14 days' grace.

**The contract is in the core.** `Tools/LicenceIssuance/Sources/LicenceIssuance/Seats.swift` defines
`SeatWire` (signing domains, the four endpoints under the origin of the licence's signed `profile`
address, the envelope, replies and refusals) and `SeatPolicy` (the one rule that counts seats). The
app restates the format in `DeviceSeatLease`, because no production verifier depends on the package.
`DeviceSeatTests` holds the two to the same bytes, and runs the whole path against a stub service
built from `SeatPolicy`.

- **Codes.** `seatCheck: true` is a signed claim (`IssuanceRequest.seatCheck`, `CustomerOrder.seatCheck`,
  `--seat-check` on the generator). It is accepted only with a `profile`, whose origin is the seat
  service. A seat increase keeps the claim of the code it raises. A code without the claim encodes
  and behaves exactly as before.
- **The phone.** On enrolment (`OrgProfileManager.apply`), a seat-checked licence claims a seat with a
  Secure Enclave P-256 key, kept in the Keychain this-device-only and so never in a backup
  (`DeviceSeatKeychainStore`). The claim sends exactly `{profileId, enrolmentId, devicePublicKey,
  build}`, signed over a single-use nonce from the service. The signed bytes include the action, so a
  claim cannot be replayed as a release. The lease is renewed on every `renewIfDue` pass after the
  profile, at most daily while live, and every ten minutes while not live, so a newly delivered
  full-term code is renewed onto the same seat at once. Removal releases the seat to the service
  the lease came from, then forgets the key.
- **The gate.** `LiveFieldAssistEntitlementProvider` withholds a seat-checked licence's evidence unless
  `DeviceSeatGate` finds a live lease. A live lease verifies under the embedded seat-lease key with its
  own domain, and names this phone's key hash, this enrolment and the stored code's `licenseIDHash`.
  It must be before `notAfter` plus the grace, judged against a clock high-water mark. Without one,
  the decision is `.seatUnavailable(DeviceSeatHold)`: *"All N seats for ⟨licensee⟩ are in use. Ask
  your administrator to free one."*, or the check-in message. This is handled like a lapse: no
  capability, so Workiz stops; Field Assist locks; the open job closes for handover as it does on
  expiry; the team-learning tools say why; nothing is erased. The office's inline route refuses a
  seat-checked licence as not in force. A licence whose own term has run out still reads as expired.
- **Check-ins are serial, and a release wins.** A check-in asked for while one is out runs next,
  so a forced claim on a move is never dropped. A claim waits for a release still on its way. An answer
  that arrives after a release is discarded. A Keychain that cannot be read (before first unlock)
  never causes a new key to be made, since that would orphan the seat. The lease the service signs
  resets the clock high-water mark to the service's time, so a phone whose clock once ran ahead
  recovers on its next lease.
- **Unsigned refusals never take a lease away.** A refusal (full, freed, lapsed) only words a lock that
  already exists for want of a live lease, so a freed phone keeps working until its lease and grace run
  out.
- **Disclosure.** It shares this pull request, per the telemetry rule: the route `licenceSeatLease`
  (data class `deviceIdentifier`), a `DeviceID` entry in `PrivacyInfo.xcprivacy`, whose header no
  longer says the app has no developer-operated backend, and a sentence in both Privacy footers.
  `TelemetryOptOutGuardTests` pins all three. The store is registered as `licenceSeat`. The route
  is blocked under Medical Local Only, like every route outside the pinned exceptions. Seat checks are
  for Field Assist only (*Non-goals*), so a phone in that mode does not renew its seat.
- **The third key** is Curve25519: public half in `DeviceSeatLease.productionPublicKeys`,
  private half a 0600 file beside the vendor's other signing keys. It is minted with the generator's
  `keygen` and never printed.
- **Not built:** a minimum-build requirement (still an open question), a seat row on the phone's licence
  screen beyond the footer note, and the administrator phone freeing seats (the open question on who may
  free one: the partner and the vendor can, in the portal). The service is not deployed; `seatCheck` stays
  off in its settings until a build that claims seats is on the App Store.

## P2 review follow-up (2026-11-10)

A code review of the merged P2 found four ways the phone could be locked out, or a seat or the clock
mark mishandled. Status unchanged (P2 built, not deployed). All headless, in `DeviceSeatTests`:

- **A new code no longer locks the phone until its next check-in.** A lease names the code it was issued
  for, so a renewal or a seat increase delivered in the profile made every phone's live lease
  `.otherLicence` and locked Field Assist until a check-in got through. `OrgProfileManager`'s renewal of
  the same profile now tells the seat check which code it is about to replace
  (`noteLicenceReplaced`); `DeviceSeatRecord.previousLicenseIDHash` (optional, so old records read) is set
  only when this enrolment's own stored lease names that code. The gate honours that lease until its own
  `liveUntil` or until a lease for the new code replaces it (which clears the field). Nothing is extended,
  and the signature, the phone's key, the enrolment and the clock are checked as before; such a lease is
  renewed at the ten-minute retry, not a day later.
- **The clock mark never moves back.** A reply lease resets the mark to its signed `issued` only when it is
  newer than the stored lease; otherwise the mark keeps its maximum, so an old lease replayed with the clock
  wound back to fit it is still caught. A phone whose clock ran ahead still recovers on its next lease.
- **A release while a renewal is out stays released.** After a `.freed` renewal, the re-claim is sent only
  if no release happened meanwhile.
- **The gate checks the enrolment in force.** `LiveFieldAssistEntitlementProvider` passes the stored
  organisation enrolment's id to `DeviceSeatGate.hold`, so a lease for an enrolment the phone has left
  reads `.otherEnrolment`; with no readable enrolment record it falls back to the seat record's own, as
  before.
