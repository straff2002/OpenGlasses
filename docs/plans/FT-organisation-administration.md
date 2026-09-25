# Plan FT — Organisation Administration (the base server sets up and manages the crew's phones)

**Status:** 📋 Planned 2026-09-24. This is the phone side and the contract only. The base server
itself is Plan [FU](FU-base-server.md) (drafted 2026-09-25).
**Origin:** The pilot partner's direction for Plan CT (see CT's *Revision 2026-09-24 (evening)*):
technicians see only Field Assist, and everything else is behind an administrator's unlock. The
owner then asked how an organisation sets up phones and manages them, and whether the API key could
arrive by QR. Then came the steer this plan is written around: *"it's likely we need a base server
that sends jobs, so [it] could be admin for setup."*
**Depends on:** Plan CT (the vendor-signed profile, the layered `ProfileApplier`, the enrolment
record, PR 2b's lease and revocation in [#551](https://github.com/straff2002/OpenGlasses/pull/551),
3a's activation key and `aiModel`, and 3b's edition and admin card). Plan FO (the `.ogjob` job file,
`organizationJobSigningKey`, the report route).
**Related:** Plan CR (the organisation gateway). Plan CT PR 4 (erasure on removal). Plan
[FU](FU-base-server.md) (the base server itself).

---

## The shape

**The organisation's base server is the administrator.** It dispatches jobs, so it already needs a
channel to every technician's phone and the organisation's signing key. Setting a phone up and
changing its settings are two more messages on that channel.

| | Today | With the base server |
|---|---|---|
| A job reaches the phone | an `.ogjob` file by email, signed with `organizationJobSigningKey` | the same signed `.ogjob`, fetched from the server |
| A report leaves the phone | the report route (`organizationJobReportChannel`, recipients) | posted to the server, with the route as the fallback |
| The phone is set up | activation key, then the profile, then the AI key page (CT 3a) | activation key, then the profile, then the phone registers with the server, which sends the AI key and settings |
| Settings change | re-mint the vendor profile | the server sends an update |
| A phone is taken off | the vendor-signed revocation (PR 2b) | the server sends `unenrol`; revocation is kept for a phone that never checks in |
| The organisation's own manuals reach the phone | loaded by hand into a custom vault (Plans H, ED) | fetched from the server into the pack's documents tier |

**It is the organisation's server, not the vendor's.** It is self-hosted, or run by the partner for
the organisation. The product still runs no server of its own (Plan EI's starting point). And it is
not an MDM: it manages the app, not the device. CT's "MDM waits" decision still stands for device
management. What arrives earlier than MDM is **app-level** remote administration, because jobs need
the channel anyway.

## Trust: the vendor bounds the organisation, and the organisation's key signs

This is the same two-level trust as job files. The vendor-signed profile carries:

- **`baseServer`** — the server's HTTPS address. Only the vendor-signed profile can name it, so no
  message and no person can point a phone at a different server.
- **`adminKey`** — an Ed25519 public key the server signs administrator messages with. It is kept
  separate from `organizationJobSigningKey` even though one server holds both, so that either can be
  rotated alone. A rotation is a re-minted profile, picked up at the phone's next renewal.

**Every administrator message is an overlay**: a new layer in `ProfileApplier`, below the vendor
profile and above the person.

> ceilings (vendor profile, final clamp) > MDM (later) > vendor profile > **administrator overlay** >
> the person

| The overlay may | It may not |
|---|---|
| set the provider and model (`aiModel`) and hand over the AI key, sealed to this phone | touch the licence, its tier or its packs — entitlement stays signed by the vendor |
| set the starting values (default vault, default mode) | loosen a ceiling the vendor profile set |
| tighten a ceiling the profile left open, and lift its **own** tightening later | change `baseServer`, `adminKey`, the profile address or the lease |
| set the report route and recipients | lift the Field Assist edition — the admin card does that, for one session |
| label the phone ("Sam — van 3") | |
| `unenrol` the phone | |

Each overlay names the phone it is for (its enrolment id) and carries a sequence number that only
goes up, so an old message replayed cannot undo a newer one. It carries the whole desired overlay,
not a diff. A phone applies an overlay only after the vendor profile naming `adminKey` has verified.

## Setting a phone up: scan the server's QR code

**The default is one scan, nothing typed** (decided 2026-09-24). The administrator opens *Add a
phone* on the server's console, types the technician's name, and the console shows a **setup QR
code**. The new phone, at first launch, taps *"Scan setup code from my administrator"* and scans it.
Setup finishes without another question, unless the review screen has something to say.

**What the QR code holds, and what it deliberately doesn't.** It holds `og-setup:` followed by the
server's HTTPS address and a **one-time token** (128 random bits). It holds no licence, no settings
and no AI key, so it is small and scans easily off a monitor. The token is:

- **single-use**, spent by the first phone that registers with it
- **short-lived**, fifteen minutes by default, set by the organisation
- **tied to one phone slot**, the name the administrator typed

**The chain that makes a QR code on a screen safe to trust.** The QR code's address is not trusted
on its own, because anyone can print a QR code. The phone trusts it only after the vendor's
signatures close a loop back to that same address:

1. The phone posts its new key and the token to the address in the QR code.
2. The server answers with the organisation's **licence code**. It holds the code, so the QR code
   does not need to.
3. The phone verifies the licence against the embedded vendor key. It follows the licence's
   `profile` claim (CT 3a), fetches the profile and verifies it against the vendor profile key.
4. **The profile's `baseServer` must be the address in the QR code.** If it is not, the phone stops
   and says so: *"This setup code points at a server your organisation's profile doesn't name."*
   A fake server can only hand out a licence the vendor signed, and that licence's profile names the
   real server, so a fake QR code dead-ends at step 4.
5. Review, confirm and apply, as in CT. The administrator created the token, so **the phone is
   approved the moment it registers**, and the fingerprint-matching step below is skipped. The
   server sends the first overlay, including the AI key sealed to the phone's key, and Field Assist
   is ready.

**A photographed setup QR code** is worth one phone's registration for fifteen minutes. The console
shows the slot as used the moment it is, with the time and the phone's app version. A slot used by
a phone nobody expected is visible, and `unenrol` handles it.

**Many phones at once.** *Add phones* takes a list of names and shows each QR code in turn, advancing
when the previous one is used. That is the depot setup day: phones on a table, one scan each.

**The scanner** is CT 3b's in-app scanner (built for the admin card), offered on the welcome page.
CT 3c's "scanner reused for keys and links" gains this third code type. The QR code is read only
inside the app. An `og-setup:` code opened by the system Camera app does nothing, because a setup
token in a URL would travel through Safari history and forwarded links.

### Without a scan: the activation key, then approval

For a technician who is not in front of the console — a new starter in another town, or a
replacement phone in a van — the typed activation key from CT 3a still works. Registration then
waits for the administrator to approve the fingerprint:

1. **The technician types the activation key** (CT 3a). The profile is fetched, reviewed and
   applied. It names `baseServer`.
2. **The phone registers.** It generates a per-phone key pair and posts its public half to the
   server with a registration message. The private half is P-256 in the Secure Enclave, which does
   not support Curve25519. The message carries the enrolment id, a label the technician types or
   picks, the app version, and proof of the licence (a signature over the server's challenge, with
   the licence-id hash rather than the code).
3. **The administrator approves it on the server.** The phone shows *"Waiting for ⟨org⟩ to approve
   this phone"* with a **six-character fingerprint** of its key. The server's console shows the same
   fingerprint beside the label. An administrator who sees they match clicks Approve. This step
   stops a leaked activation key from quietly registering a stranger's phone as one of the crew.
4. **The server sends the first overlay**: the model, the **AI key sealed to the phone's registered
   key**, the label and the starting values. Field Assist is ready. The technician typed one short
   key and nothing else.

The phone's registered key is long-lived, so later secrets are sealed to it too. That is what makes
remote key handover possible without a scan: a new AI key after the organisation rotates it arrives
the same way.

**Could the AI key be a QR? It doesn't need to be.** With the server, the key is never shown to
anyone: it moves from the server to one phone, sealed to that phone's key. Without a server, CT 3a's
key page takes a pasted key or a scan of a plain QR the administrator made. That is accepted as no
worse than pasting. The app never generates such a QR, and it says a printed key is a credential
anyone with a camera can copy.

## Staying in touch

- **Jobs, overlays and `unenrol` are fetched, not pushed.** Fetches happen at launch, on foreground,
  on background app refresh, and from *Check for jobs* on the Job tab. The phone uses the same
  `BoundedHTTPClient` discipline as the profile fetch, restricted to `baseServer`, and each request
  is signed with the phone's key so the server knows which phone is asking.
- **Real push notifications need the vendor.** APNs delivers only with the app's own push key. An
  organisation's server cannot hold that key, and the vendor running a relay is the vendor server
  this product has avoided. Decide this when a customer needs a job to arrive within seconds rather
  than on the next foreground.
- **The check-in renews the lease.** A successful, verified exchange with `baseServer` counts as
  hearing from the organisation, exactly like PR 2b's profile fetch. A phone that talks to its
  server daily never approaches its renew-by date.
- **The server's view is last check-in, not live status.** For each phone it records the label, app
  version, overlay sequence, lease date and last check-in, and its console should say "last checked
  in", not "online".

## The organisation's manuals

Decided 2026-09-24: **an organisation's own manuals come from its base server.** This settles the
question CT left open (*Where do an organisation's manuals actually come from?*) and withdraws CT's
`vaultPack.documentsSource` pointer, which was a URL in the profile.

- **Why the server.** A vault pack ships trade knowledge and never OEM manuals (Plan EG), so the
  manuals are always the customer's own material, and usually licensed documents it may not
  republish. They cannot sit at a public address, so a URL in the profile was either a leak or a
  second authenticated service to build. The server already authenticates each phone, since every
  request is signed with the phone's key, and it already holds the organisation's documents next to
  the jobs that refer to them. The vendor holds nothing.
- **How they arrive.** The overlay carries a **manual set**: file names, sizes and SHA-256s, signed
  with `adminKey` like the rest of the overlay. The phone fetches each file from `baseServer` with a
  signed request, checks its hash against the signed set, and ingests it through
  `VaultImporter.syncDocuments` into the documents tier of the vault the pack installed. That path is
  already gated at team tier and already routes scans through Plan EF's extractor. The sync is
  resumable and runs in the background. A binder of scans is large, and nothing waits on it.
- **Which vault.** The set names its target vault id. It must be a vault the phone has, usually the
  pack's, or the set is a named drop.
- **Updates and removal.** A later set with a higher overlay sequence adds, replaces and removes
  files by hash, so a withdrawn manual leaves the phone at the next check-in. On `unenrol` or
  revocation the synced manuals are the firm's content, so they lock with the lease and are erased
  with the rest of it (CT PR 4).
- **Without a server.** No manuals path. An organisation with no base server loads its manuals by
  hand through Custom Vaults, as today.
- **Privacy.** Nothing new beyond `baseServer` itself, which is already disclosed. The files go from
  the organisation's server to the organisation's phone.

## Taking a phone off

- **`unenrol` from the server** is handled like an owner removal: CT PR 4's deliver-then-erase, the
  licence cleared, and the person's own data untouched. Until PR 4 lands, it locks as PR 2b's
  revocation does.
- **A phone that never checks in again** is covered by the lease. PR 2b's signed revocation at the
  profile address remains the backstop, and the server's list shows which enrolment id to name.

## Privacy

`baseServer` is a new network destination, named by the organisation and contacted with job data,
reports and check-ins. It is the organisation's own system, like the report route, and not a
third-party SDK. It still has to be disclosed, and the PR that first contacts it adds that to:

- the in-app privacy copy: *"If your organisation manages this phone, it talks to your
  organisation's server"*
- the enrolment review sheet, which names the server's host beside the profile's

`PrivacyInfo.xcprivacy`'s claims are unchanged, because nothing here is analytics, crash reporting
or advertising. `TelemetryOptOutGuardTests`' rule on disclosing new egress is met by the two items
above.

## Location while on shift (Plan FU Part 5)

Added 2026-09-25. The base server's status board needs job and shift events, and, where the
organisation turns it on, the phone's last known position during a shift. The phone side:

- **Shift start and end** are the technician's own actions (Job tab, and by voice). Outside a shift
  nothing is sent but the check-in itself.
- **Position rides existing messages**: attached to check-ins and job events while on shift, never a
  stream of its own, and no `location` background mode.
- **Only when the profile turns it on, and only on a company phone** unless the enrolment says
  otherwise. The enrolment review sheet names it, and the technician acknowledges the
  organisation's monitoring policy before the first shift.
- **An indicator** — *"Base can see your location"* — whenever a position is being shared.
- **The "Always" permission string and `privacy.html`** stop promising location reminders only, in
  the same PR.

## The administrator phone, reduced to what the server does not cover

- **The admin card stays as CT 3b designed it**: a scan that opens hidden settings on one phone for
  one session. It is a local unlock, not management.
- **In-person management with no server** — a phone-to-phone, two-scan handshake that seals the AI
  key to a one-exchange X25519 key — was designed on the way here. It is **deferred**. It becomes
  worth building only for an organisation with no base server, or for sites with no signal at setup,
  and neither is the pilot. Its core idea survives in the server design: secrets are sealed to one
  phone, overlays are signed, and sequences only go up.

## Delivery

| PR | What |
|---|---|
| **FT1** (headless) | the `baseServer` and `adminKey` profile fields; the overlay schema; the applier's administrator layer with each key's overlay permission; target, sequence and "profile first" checks; sealing to a P-256 key; the registration and check-in messages, as `Codable` shapes with a written wire contract the server can be built against. Tests: an overlay from the wrong key, for another phone, replayed with an older sequence, or arriving before the profile verifies is refused by name; one that tries to loosen a vendor ceiling or touch entitlement is dropped by name; a sealed key opens only with the registered key; precedence as a table with the new layer |
| **FT2** | the setup QR code (`og-setup:` parsing, the one-time token, the loop check that the profile's `baseServer` is the QR code's address, auto-approval), registration after enrolment, the Secure Enclave key, the waiting-for-approval screen with its fingerprint for typed-key setups, the check-in loop and lease renewal from it, jobs fetched from the server into the Job tab through `JobFileImportPolicy` unchanged, overlays applied, and the privacy copy |
| **FT3** | reports posted to the server, with the report route as the fallback; `unenrol` wired to CT PR 4 |
| **FT4** | the manual set in the overlay, the hash-checked fetch from `baseServer`, resumable ingestion into the pack's documents tier through `VaultImporter.syncDocuments`, and removal by hash |
| **FT5** | shift start and end; job and shift events on check-in; the on-shift position when the profile enables it and the enrolment is a company phone; the indicator; the monitoring-policy acknowledgement at enrolment; the rewritten "Always" string and privacy copy (Plan FU Part 5) |

FT1 can land after CT 3a, because it needs `aiModel`. FT2 needs a server to talk to, so its tests use
a stub, and Plan FU's first server PR (FU1) is built to be that stub. **The base server is Plan
[FU](FU-base-server.md)**: where it runs, its console, its storage of the organisation's AI key, and
what else it carries (live support, the accounting hand-off, the manuals).

## Traps

| Trap | Consequence |
|---|---|
| Letting anything but the vendor profile name `baseServer` | a message or a link points a crew at someone else's server |
| Applying an overlay before the profile naming `adminKey` verifies | anyone who can answer an HTTPS request becomes the administrator |
| Registering phones without the fingerprint approval | a leaked activation key quietly adds a stranger's phone to the crew, which then receives the AI key |
| Trusting the setup QR code's address before the profile names it | a printed QR code points a new phone at an impostor server, which then sends it settings and a model endpoint |
| A reusable or long-lived setup token | a photo of the console becomes a standing way to add phones |
| Opening `og-setup:` codes from the system Camera app | the token travels through Safari history and forwarded links |
| Sealing the AI key to anything but the registered phone key | the key travels readable by the server's storage, a proxy or a log |
| No sequence number | an old overlay, replayed, undoes a newer one |
| Letting the overlay reach entitlement or a vendor ceiling | the organisation, or whoever holds its server, widens what the vendor sold |
| Calling "last checked in" "online" | an administrator trusts a stale phone as current |
| A vendor push relay added "just for notifications" | the vendor server the product has avoided, arriving through the side door |
| `baseServer` contacted before it is disclosed | an undisclosed egress, which the telemetry posture forbids |

## Open questions

- ~~**Who builds the base server?**~~ **Direction 2026-09-25 (Plan [FU](FU-base-server.md)):** one
  self-contained package, one organisation per install, with a browser console. The partner hosts
  the pilot firm's instance, pending the partner's agreement; running it in-house stays a supported
  option. Never a vendor-hosted service for every firm. `baseServer` names an address on the firm's
  own domain, so moving hosts is a DNS change rather than a re-minted profile.
- **Does the base server replace email `.ogjob` or sit beside it?** Leaning beside: email stays the
  no-server path, and both carry the same signed file.
- **Push, or fetch on foreground?** Fetch is enough for a day's dispatch. Push needs the vendor's APNs
  key and so a relay, which should wait for a customer who needs it.
