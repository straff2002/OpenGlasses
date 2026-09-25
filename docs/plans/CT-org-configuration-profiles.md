# Plan CT — Organisation Configuration Profiles (scan once, configured correctly)

**Status:** 🚧 PR 1 (headless core) merged 2026-09-24 ([#548](https://github.com/straff2002/OpenGlasses/pull/548)).
PR 2a — enforcement, the stored enrolment, the `openglasses://enrol` link, the managed row, removal
and locked controls — merged 2026-09-24 ([#549](https://github.com/straff2002/OpenGlasses/pull/549)).
PR 2b — the lease, renewal, revocation, the clock guard and the mid-job grace — merged 2026-09-24
([#551](https://github.com/straff2002/OpenGlasses/pull/551)), green on its first CI run with 16 new tests.
The scanner (3c, early) merged 2026-09-24 ([#553](https://github.com/straff2002/OpenGlasses/pull/553)).
The pack at enrolment (3d) was written 2026-09-24 and is awaiting CI
([#555](https://github.com/straff2002/OpenGlasses/pull/555)). Next, per the evening re-cut: 3a (the
activation key) and 3b (the Field Assist edition). See *Numbering, reconciled*. Re-sequenced the same day to a thin first slice aimed at the seven `organization*`
stand-ins Plans FO and FS already shipped (see *Delivery order* below). Revised
2026-09-03 ([#406](https://github.com/straff2002/OpenGlasses/pull/406)) — partner-configured edition
(packs, tiers, EI issuance)
**Depends on:** Plan F/licensing primitives (Ed25519 verification), Plan BX (signed-manifest +
lossy-decode precedent), Plan BM P10 (`OwnerGateMachine`), Plan CD P1 (the onboarding-flag hazard),
Plan EE (tiers on every piece of evidence, licence payload v2), Plan EG (vault packs, the `packs`
claim, the signed catalog and its installer) — the last two shipped after this plan was drafted and
are the reason for the revision
**Related:** Plan CS (watch propagation), Plan CR P4 (enrolment endpoint, for the secrets half),
Plan EI (who mints the code and the profile), Plans ED and EF (the documents tier an organisation
loads its own manuals into)
**Shape:** the design is stated as P1–P4 below — pure schema + applier (P1), three ingress adapters
(P2), onboarding + pack install + managed-state UI + watch propagation (P3), enrolment endpoint (P4).
It is **delivered** as three PRs cut across those phases — headless core scoped to the keys that
already exist, then enforcement + managed state + the deep link, then the scanner + first-run
enrolment — with the MDM reader, the single-purpose edition, identity re-clamping and watch
propagation deferred. The MDM reader is deferred *as a reader only*: the seam it plugs into ships
in PR 1 and PR 2. See *Delivery order*.

---

## Revision 2026-09-24 — the shipped code is already waiting on this plan

Three weeks after the partner-edition revision, the argument for CT has changed from "an
organisation will want this" to "shipped behaviour cannot be reached without it".

**Plans FO and FS each landed policy hooks in `CT`'s name.** Each is a `Config` accessor whose doc
comment says CT P1 replaces it, paired with the behaviour that reads it, so the rule is real rather
than promised
([`Config.swift`](../../OpenGlasses/Sources/Utils/Config.swift), the `organization*` block):

| Stand-in | Shipped by | What reads it |
|---|---|---|
| `organizationAllowsUnsignedVaults` (default `true`) | FS PR2 | vault-link import refuses an unsigned archive when `false` (`VaultLinkInstallPolicy`) |
| `organizationRequiresCustomerSignOff` (default `false`) | FO P2c | the customer sign-off step is demanded rather than offered |
| `organizationDisplayName` (default empty) | FO P2c | the heading on the customer-facing sign-off sheet |
| `organizationJobReportChannel` (default none) | FO P3b | the route a spoken "send it" uses from the car |
| `organizationReportRecipients` (default empty) | FO P3b | the last step of the report recipient order |
| `organizationJobSigningKey` (default empty) | FO P3c | the organisation's Curve25519 key `.ogjob` files are checked against |
| `organizationRequiresSignedJobFiles` (default `false`) | FO P3c | an unsigned job file is refused rather than shown as not signed |

**Nothing in production writes any of them.** The only writer is `UITestSupport` (which sets
`organizationDisplayName` for screenshots). So on a real phone every organisation branch of FO and FS
is one nobody can take: a pilot organisation cannot require a customer signature, cannot sign its
job files, cannot route reports, and cannot refuse unsigned vault links, whatever it wants. That is
the gap worth closing first, and it is much narrower than the plan as drafted.

**The "long pole" is shorter than the roadmap says.** Round 14 calls the enumerable `Config` surface
the long pole, and `Config` has kept growing — 4,206 lines and 72 `@UserDefaultsBacked` properties
(measured 2026-09-24; 3,747 / 56 at the 2026-09-08 review). But `SettingKey` is an allow-list by
design, so the applier needs a typed, clampable accessor for **the keys it allows** and nothing
else. The full audit stays what the open questions already call it: a per-setting judgement that
does not block P1.

**Plan EI is still unbuilt**, so nothing can mint a profile. The authoring script P4 deferred is the
only issuance path until EI exists, and it moves into the first PR.

---

## Revision 2026-09-24 (evening) — the pilot partner's direction

The pilot partner answered the questions this plan had parked. They are selling to HVAC and other
technical service companies first, and a company that installs and services CNC machines and other
complex equipment is working towards a local presentation and demo. The answers, in their words
where the words matter:

1. **MDM and SSO wait until a customer is ready to deploy internally.** That confirms the MDM
   decision below (*Decisions*, 1): the reader stays deferred and the seam PR 1–2 built stays. It
   also defers **SSO**, which is this plan's identity axis (*Identity is per-person*): sign-in
   re-clamping, and the credential half in P4, wait for the same customer. Nothing is built for
   either now.
2. **"Having the app recognise the organisation and apply its configuration when the licence key is
   entered at first launch is exactly what we need."** The ingress a technician meets is therefore
   **the licence key**, not a poster QR or an emailed enrolment link. The key is the thing an
   organisation already hands out, and the first-run branch is built around it. See *Enrolment by
   licence key* below.
3. **"Keep only Field Assist visible and put the other modes and advanced settings behind a
   password-protected settings menu."** This is the first real request for the single-purpose
   edition, which *Deferred, and why* was waiting on. It settles the open question on a named preset
   versus a subtraction list: **a named preset.** It also asks for something this plan did not
   design, an administrator's way back in. See *The Field Assist edition* below.
4. The reason, which decides the details: *"Technicians should have as few buttons and options as
   possible, so they can focus on the job without accidentally changing the configuration, getting
   confused, and concluding that the app doesn't work."* The threat is confusion, not an adversary.
   The edition is a **presentation** that keeps a technician on the job. The **ceilings** stay the
   security boundary, unchanged.

### Enrolment by licence key

**The licence carries a pointer to the profile.** `LicensePayload` gains one optional signed claim,
`profile`: the HTTPS address of the organisation's hosted profile.
`Scripts/generate-field-license.swift` takes it as `--profile https://…`. Entering the key does this:

1. `LicenseService.decode` verifies the key as it does today (signature, feature). Nothing is fetched
   or activated yet.
2. If the key has no `profile` claim, it activates exactly as it does today. Every code issued so
   far is this case.
3. If it has one, the app says *"This licence is for ⟨licensee⟩ — setting up this phone"* and fetches
   the address with no host offer. Only the first step differs from the `openglasses://enrol` link.
   The link asks before fetching because anyone can write a link's address. A licence's address is
   signed by the vendor key, so the licensee's name is the thing to show. From there the flow is the
   one PR 2a built: `OrgEnrolmentService`'s HTTPS-only, 64 KB `BoundedHTTPClient` fetch, then
   verification, then the review sheet, then one confirmation, then `OrgProfileManager` applies it.
4. **The profile and the key must name the same organisation.** When the profile carries its own
   licence code, that code must verify and its `licensee` must equal the entered key's. Otherwise the
   review refuses, naming both organisations. The code with the later `issued` date is the one
   activated, so a renewal re-minted at the same address wins over an older code entered from an email.
5. The enrolment records the address, so PR 2b's renewal, lease and revocation work unchanged. It
   also records a new `ProfileSource.licence`. On removal, that source clears the licence it enrolled
   with. That is the rule PR 4 settles on anyway, and it is the right one here: the key was the
   organisation's, even though the technician typed it.

**Why a pointer and not the profile inside the key.** The same reasons P2 gives for the QR. The
profile outgrows any code a person can type or scan. The organisation must be able to change its settings
without re-issuing keys to the fleet. And the lease and revocation are keyed on the address.

**Older builds are unaffected.** `LicensePayload`'s `Decodable` is synthesised, so an unknown key is
ignored. A build from before this change activates such a code as a plain licence. The signature
covers the payload bytes, so the extra field costs nothing. The generator's copy of the payload
struct must gain the field in the same PR, because `.sortedKeys` makes the encoding a byte-for-byte
contract.

**What the technician types: a short activation key, not the licence code** (decided 2026-09-24,
evening). A signed licence code is about 400 characters of base64. Nobody types that on a job site,
and "paste it" is not an answer for a technician holding a phone. So the thing handed out is a
short key that *resolves* to the licence:

- **Format.** `K7Q3-X9PD-M2VA-8RTN`: sixteen Crockford base32 characters in groups of four. That is 75
  random bits plus a 5-bit check character. Crockford's alphabet has no I, L, O or U, and reads
  `O` as `0` and `I`/`L` as `1`. Case and dashes are ignored. A typo fails the check locally, as
  *"Check the key — one character looks wrong"*, before anything is fetched.
- **Resolution without a server.** The product has no vendor server (Plan EI's starting point), and
  this does not add one. The generator publishes one file per key on the static host the catalogs
  already use (`straff2002.github.io/OpenGlasses/activation/`):
  - **Path:** hex(SHA-256(`"openglasses.activation-id.v1\n"` + key)).
  - **Content:** the full licence code, sealed with AES-GCM under HKDF-SHA256(key, info
    `"openglasses.activation-key.v1"`).
  - The phone derives both from what was typed, fetches the file (a few hundred bytes, through
    `BoundedHTTPClient`), opens it, and carries on as if the licence code had been entered.
- **Why that is safe on a public host.** The files are ciphertext, and their names are hashes of 75
  random bits. Nothing on the host maps back to a key, and guessing a key is 2^75 work. The host is
  not trusted either way. What it serves still has to verify against the embedded licence key, so a
  compromised host can withhold a licence but cannot forge one.
- **The key is a bearer secret, exactly as the licence code already is.** Deleting its file stops new
  activations. Phones that already activated keep their stored licence, and revoking those is PR
  2b's signed revocation. A lost key is a new key, which means a new file, not a new licence.
- **Issuance.** `generate-field-license.swift --activation-key` prints the short key once and writes
  the sealed file for the Pages workflow to publish. `activation/` joins the allowlist in
  `Scripts/stage-pages-site.sh`, and holds nothing but sealed files. Plan EI mints the same pair later. The ledger
  records the file name, never the key.
- **The long code still works** anywhere a code is accepted, including the tap-a-link and scan paths
  (PR 3c). The short key is simply the one a person types.

**The first-run branch.** The welcome page gains **"I have a licence key from my company"**, ahead of
the provider and key pages. With a base server, **"Scan setup code from my administrator"** sits above it and is the default. The phone scans a one-time QR code from the server's console and nobody types anything. See Plan [FT](FT-organisation-administration.md). Onboarding's other branches do not change.

- It takes the short activation key, typed, with a keyboard that shows only its alphabet and
  inserts the dashes. It also accepts a full licence code, and PR 3c adds scanning a QR of either.
- It goes through `WearablesBootstrap` and sets `hasCompletedOnboarding` explicitly, with the test
  P3 already requires (CD P1's hazard).
- **Offline at first launch.** The licence activates, since it is verified offline. The phone then
  shows *"Setting up for ⟨licensee⟩ — connect to the internet once to finish"*, with Retry, and does
  not fall through to the general app. The ceilings live in the profile. A phone that opens as the
  full app while its organisation's settings are pending is exactly what point 4 describes.
- **The licence sets the provider, and the next step adds the key** (decided 2026-09-24, evening).
  Which provider and model to use is not a secret. The key for it is. So they travel separately:
  - The profile carries `aiModel = {provider, model, baseURL?, name?}`. `provider` is an
    `LLMProvider` raw value. `baseURL` is only for `custom` and `openrouter`, and must be HTTPS; the
    review sheet shows its host, because it is where the phone's prompts go. It is a profile field,
    not a `SettingKey`, because it becomes a `ModelConfig` and `savedModelConfigs` is on the secrets
    list. An unknown provider or model is a named drop, and the app falls back to the no-model state
    below.
  - Right after the review is confirmed, first run shows **one more page**: *"Enter the ⟨provider⟩
    API key from ⟨org⟩"*. It has one secure field, runs the same check onboarding's key page runs,
    and has *"My administrator will add this"* as the way past it. The phone then builds the
    `ModelConfig` locally (provider, model and base URL from the profile, key from the field), saves
    it through the existing Keychain-backed `savedModelConfigs` path, and makes it the active model.
    **The key never enters the licence, the profile, or any request to the profile's address.**
  - Providers that sign in instead of taking a key (`chatgpt`, `geminiVertex`) show their existing
    sign-in on that page. `local` and `appleOnDevice` skip it.
  - Skipped, or refused by the check: Field Assist says *"Your administrator needs to finish setting
    up this phone"*, and the administrator passcode opens that same key page. Later changes to the
    key, the provider or the model are behind the passcode too. A technician never sees a model
    picker.
  - **A renewal that changes the model** under the same provider updates the model on the existing
    config and keeps the key. **One that changes the provider** leaves the old config in place and
    puts the phone in the "administrator needs to finish" state for the new one, so a technician is
    never dropped into a provider with no key.
  - **Removal deletes the config enrolment created, including its key.** It is the organisation's
    key, whoever typed it in. It joins PR 4's list of the firm's stores. The person's own model
    configs are untouched.
  - **With a base server** (Plan [FT](FT-organisation-administration.md)), nobody types the key:
    the server sends it sealed to the phone's registered key once an administrator approves the
    phone. The key page is then the no-server path.
  - SSO or the organisation gateway (Plan CR) would remove the key page altogether. Both are
    deferred per point 1, and the page is the stand-in until then.
- **A key entered after onboarding** in Field Assist settings runs the same flow and shows the same
  review sheet. That is the "licence code entered" event in the re-clamp table.

**Honest exposure.** A team key is already a bearer code shared across a fleet (Plan EE). With a
`profile` claim, a leaked key also fetches the organisation's profile, including its report
recipients, which are personal data. That is the same exposure the profile address already has. The
remedies are the ones PR 2b and PR 4 built: a signed revocation at the address, and a new key.

### The Field Assist edition, and the administrator passcode

**Hidden is not forbidden.** Two mechanisms, kept apart:

| | Hidden by the edition | Forbidden by a ceiling |
|---|---|---|
| What it is | the technician's view of the app | what this phone may do, whoever holds it |
| How it is stated | one named preset: everything not on the kept list | per key, with a direction (PR 1) |
| Who can get past it | the organisation's administrator, with its passcode | nobody. A new profile is the only change |
| A feature added to the app later | hidden from technicians by default | available until someone ceilings it |

The last row settles the open question. The draft preferred an enumerated subtraction because it can
be tested key by key. That argument still holds for **ceilings**, and they stay enumerated. For
**visibility**, the inverted form is the one this request describes ("keep only Field Assist
visible"). It is also the one that stays correct as the app grows.

**The profile field.** `ConfigProfile` gains `edition`, and PR 3b defines one value, `"fieldAssist"`.
An unknown value is a named drop in the lossy-decode report, and the app keeps its normal
presentation. The edition implies `fieldAssistEnabled` and the Field Assist mode for the technician.
It does not write them as starting values.

**What the technician sees.**

- **Tabs:** Field Assist (the Voice tab as the session surface), Job, and Settings. Modes and Chat
  are hidden. The Voice tab's mode and persona switchers are hidden too, so there is no other mode to
  land in by accident.
- **Settings:** a short list.
  - "Managed by ⟨org⟩". The removal path moves one level down into its detail view, and is still
    owner-gated per P3.
  - Glasses, for pairing and connecting.
  - Accessibility. This is `pinnedAssistive`, and neither the edition nor the passcode may hide it.
  - Language.
  - Diagnostics & Support.
  - About.
  - **Administrator settings**, locked.
- **What is hidden:** everything else, including Voice & Triggers, the Simple Mode switch, Discover,
  and "Show everything". The *Ceilings for a single-purpose edition* table becomes the list of what
  an administrator finds behind the passcode. The ceilings a profile sets still bound that list.

**What the administrator gets.** Entering the passcode opens today's full Settings hub and the hidden
tabs, including the other modes the partner names. Every ceiling still clamps. The administrator session
ends when the app goes to the background, or after ten minutes of inactivity in Settings, whichever
comes first. The phone then returns to the Field Assist view.

**The passcode is the organisation's, not the phone's.** `OwnerGateMachine` asks for the device
passcode. On a phone a technician carries, the technician knows that passcode, so the gate would stop
nobody it is meant to stop. So:

- **One passcode per organisation** (decided 2026-09-24, evening). Every profile minted for an
  organisation, for every crew and every link, carries a verifier for the same passcode, each with
  its own salt. An administrator therefore needs one passcode for the whole fleet. Changing it means
  re-minting that organisation's profiles, and each phone picks up the change on its next renewal.
- The profile carries a **verifier**, not the passcode: `adminPasscode = {salt, iterations,
  PBKDF2-HMAC-SHA256}`, using CommonCrypto's `CCKeyDerivationPBKDF`, since CryptoKit has no PBKDF2.
  `make-org-profile.swift` prompts for the passcode with echo off and never takes it in argv. It
  refuses anything shorter than eight characters or purely numeric.
- **It is a guard, not a lock, and the plan says so.** A short passcode can be brute-forced from its
  verifier by anyone holding the profile. Against the stated threat, a technician changing settings
  by accident, that does not matter. Against a determined one it would, which is why the passcode
  lifts **no ceiling**. What it opens is only what the edition hides.
- Failed attempts back off, persisted across launches: five free, then 30 s doubling to an hour.
  VoiceOver announces the wait.
- **A forgotten passcode is a re-mint.** A new profile at the same address carries a new verifier.
  The next renewal applies it, from PR 2b's `renewIfDue` or the *Check for Renewal* button. There is
  no local reset, because a local reset is a way round the passcode.
- **The administrator card: a QR scan as the unlock** (2026-09-24, evening). An organisation can be
  issued a printed or on-screen **admin card** instead of, or as well as, a typed passcode.
  *Administrator settings* opens the phone's camera, the administrator scans the card, and the
  administrator session starts. It is stronger than the passcode, not just quicker:
  - **The card holds 128 random bits** (`og-admin:` followed by base32). Nobody types a secret that
    long, and a camera doesn't need to. The profile carries `adminCard = SHA-256("openglasses.admin-card.v1\n" + secret)`.
    Brute-forcing that from the profile is out of reach, which removes the typed passcode's
    weakness.
  - **It is still per organisation**, like the passcode. `make-org-profile.swift --admin-card`
    generates the secret once per organisation, renders the card as a PNG (CoreImage's
    `CIQRCodeGenerator`, which is the QR renderer P4 deferred), and writes the digest into every
    profile it mints for that organisation. The secret is printed onto the card and kept nowhere
    else. A **lost or photographed card** is handled the same way as a forgotten passcode: re-mint
    with a new card, and every phone drops the old one at its next renewal.
  - **The card is scanned inside the app, never by the system Camera app.** An
    `openglasses://admin?…` link would push the secret through Camera, Safari history, and every
    place links get forwarded, and it would open administrator settings from any app that fires the
    link. So the scanner PR 3c was going to build moves into **3b**, where it is scoped to this one
    use, and 3c reuses it for licence keys. The same backoff applies to failed scans.
  - **It opens exactly what the passcode opens**: the hidden view, never a ceiling.
  - **A card, a passcode, or both**, per organisation. Card-only is the stronger choice. With both,
    the passcode is the fallback when the card isn't to hand, for example an administrator talking
    a technician through a fix over the phone. The weak verifier is only on the phone if the
    organisation asked for it.
- **Managing other phones is Plan [FT](FT-organisation-administration.md)'s**: the organisation's
  base server, the one that dispatches jobs, sets up and updates the crew's phones through signed
  overlays bounded by this profile. The administrator phone below remains a local convenience.
- **An administrator phone: the card, remembered** (2026-09-24, evening). A supervisor's own phone
  needs the full view all the time, and is the obvious thing to unlock technicians' phones with.
  There is no separate admin profile or admin key. An administrator phone is an ordinary enrolled
  phone that has been shown the card once:
  1. **Enrol it like any other phone**, with the same activation key, so it gets the same licence,
     pack and ceilings.
  2. **Scan the card once with *Make this an administrator phone* ticked.** This first scan needs the
     printed or emailed PNG the script produced. The phone stores the card's secret in the Keychain
     as `…ThisDeviceOnly`, so it never reaches a backup or another device, and it stays in the full
     view. A banner at the top of Settings says *Administrator phone* so it is never mistaken for a
     technician's. *Stop being an administrator phone* deletes the stored secret.
  3. **It then becomes the card.** Its Settings gains *Show admin card*, behind the device owner's
     Face ID or passcode (`OwnerGateAuth`, **failing closed** here, unlike the Simple Mode gate). The
     phone renders the QR full screen for a technician's phone to scan. The Face ID step means a
     lost or unattended administrator phone does not hand the card to whoever picks it up. The
     screen dims the QR again after 30 seconds and when the app goes to the background.
  - **Rotation reaches it automatically.** A renewal that carries a new card digest no longer
    matches the stored secret. The phone drops back to the technician view and asks for the new
    card, the same thing that happens to every other phone.
  - **Still bounded.** An administrator phone sees everything the edition hides and nothing a
    ceiling forbids. It is also the organisation's phone for the lease, revocation and PR 4 erasure.
    Revoking its enrolment id is how an administrator who leaves loses it.
- **A profile with the edition but neither a card nor a passcode** falls back to `OwnerGateAuth`, the device-owner
  gate. The review sheet says *"Anyone who can unlock this phone can open administrator settings"*,
  so the organisation knows before it confirms.
- The passcode verifier is not a secret in the `SettingKey` sense, because it is not a credential to
  any service. But it rides a profile that should not be printed on a wall. It is one more reason the
  licence carries a pointer.

**Simple Mode is not the edition.** Simple Mode stays the owner's own hand-off switch, gated on the
device passcode. On a phone with the edition, its switch is behind the administrator passcode with
everything else. The technician's view is already simpler than Simple Mode, and two nested
simplifications with two different gates would be the confusion point 4 warns about.

### Delivery, re-cut (2026-09-24, evening)

PR 2b (the lease, in review as [#551](https://github.com/straff2002/OpenGlasses/pull/551)) lands
first. The licence-key path writes the address that 2b's renewal reads, and both touch
`OrgProfileManager`. Then, ahead of the rest:

| PR | What | Why this order |
|---|---|---|
| **3a** | the short activation key (format, check character, sealed file on the static host, `--activation-key`), the `profile` licence claim, the generator flag, `ProfileSource.licence`, the same-organisation check, the first-run "I have a licence key" branch through `WearablesBootstrap`, the offline holding screen, the profile's `aiModel` and the first-run key page that follows the review, and the "administrator needs to finish setup" state | the entry point, and where CD P1's hazard lives, so it gets its own CI round |
| **3b** | `edition: "fieldAssist"`, the technician's tabs and Settings list, the `adminPasscode` verifier, the `adminCard` digest and an in-app scanner scoped to it, the administrator phone (remembered card, *Show admin card* behind a fail-closed owner gate), the backoff, the administrator session, and the script's passcode prompt and card renderer | the view point 3 asks for. Testable before 3a through the enrol link PR 2a shipped |
| **3c** | 3b's scanner reused to read a licence key, an activation key, or an enrol link into the same field | a convenience once 3a exists, since the short key can be typed |
| **4** | leaving the firm: the owner axis, sealing, deliver-then-erase | unchanged |

3a and 3b are what a demo needs. Before any demo, the owner has to run `make-org-profile.swift` and
`generate-field-license.swift` on a Mac. That produces a profile with the edition and a passcode,
hosted at an HTTPS address, and a key whose `profile` claim names that address. Neither script has
yet been run against the production keys.

---

## The ask, and the gap

An organisation — a museum, a field-service contractor, a hospital ward, a training provider — wants
to hand someone a device and have the app come up configured: the right capabilities on, the wrong
ones off, the right gateway, the right vault, the right mode. Today the only route is a person walking
through [`OnboardingView`](../../OpenGlasses/Sources/App/Views/OnboardingView.swift)'s seven pages and
then through Settings, by hand, per device, correctly, every time.

**The case this revision is written against: a partner-configured edition.** A reseller or
integration partner sells an organisation an annual team licence that includes a vault pack for its
trade, and wants every technician's phone to come up as *the HVAC assistant* — Field Assist on, the
partner's pack installed and set as the default vault, the organisation's own manuals loaded into
that pack's documents tier, and every unrelated capability hidden and unavailable, with nothing the
technician can widen. One scan standing in for a purchase, a licence code, an onboarding flow, a
vault import, a documents import and a dozen Settings toggles — and it is the same schema and the
same applier as the museum, the ward and the training provider. What it adds to this plan is three
things the draft predates: tiers and packs on the entitlement side (Plans EE and EG, both shipped),
an issuance service that mints the artefact (Plan EI), and a ceiling deep enough to leave exactly one
feature standing.

The primitives for the fix are almost all already here:

| Needed | Already shipped |
|---|---|
| Signed payload the app can trust | [`LicenseService`](../../OpenGlasses/Sources/Services/LicenseService.swift) — `base64(payload).base64(sig)`, Ed25519, public key embedded, private key off-repo, generator script; and `SkillPackSignature` over a manifest |
| Trust posture for a QR-delivered link | [`SkillPackSideload`](../../OpenGlasses/Sources/Services/SkillPacks/SkillPackSideload.swift) — deliberately *not* token-gated because a QR cannot carry the `DeepLinkTrust` app-group token; the compensating control is that the link never acts, it presents identity + signature status and a human confirms |
| QR decoding | `VNDetectBarcodesRequest`, used in three tools already |
| A gate between the user and Settings | [`OwnerGateMachine`](../../OpenGlasses/Sources/Services/OwnerGate.swift) (BM P10) + Simple Mode |
| A precedent for policy removing capabilities | HIPAA mode — an external policy hard-disables features and the app says so |

**So the QR is not the hard part.** The hard part is that
[`Config.swift`](../../OpenGlasses/Sources/Utils/Config.swift) is 4,206 lines of 72
`@UserDefaultsBacked` properties (measured 2026-09-24; 3,747 / 56 on 2026-09-08, 3,277 / 45 at the
2026-09-03 revision) plus a long tail of hand-written accessors, with **no export, no import, no versioning and
no enumerable schema**. A profile cannot be applied to a settings surface that cannot enumerate
itself. That is the work — but only for the keys a profile may set, which is an allow-list (below);
everything else is adapters.

The one genuinely new UI piece is a live-camera QR scanner — every existing decode path reads a
*captured* frame (glasses camera or a still), and there is no scanner view.
[`PhoneCameraView`](../../OpenGlasses/Sources/App/Views/PhoneCameraView.swift) already wraps
`AVCaptureSession`, so this is small.

## Identity is per-person; policy is per-device

The profile answers *what this device may do*. It does not answer *who is holding it* — a person still
signs in as themselves, and the two must not be conflated. That separation is what makes a shared
device (a ward handset on a shift rota, a museum handset per visitor, a contractor's pool phone)
coherent rather than a pile of leftover state.

**Today the app has no user identity at all.** `ClaudeOAuthService` and `ChatGPTOAuthService` sign you
in to an *LLM provider*; StoreKit entitlements are Apple-ID scoped; `LicenseService` is device-scoped
and offline. There is no `UserAccount`, no account service, nothing that names a person. So "log in as
a user" is a capability this plan assumes and does not itself build — the natural home is Plan CR's
gateway, which is already `token:userId` with a per-user memory store, vault and session. CT's job is
to make sure that when identity arrives, it cannot widen the envelope.

Three consequences, each of which changes the design rather than decorating it:

1. **A user signing in must never widen the device.** Hence ceilings rather than pins. The user gets
   their own history, memory, connected apps and preferences *inside* the org's envelope.
2. **The envelope must cover provider and credential configuration, or it is theatre.** If a person
   can paste a personal API key, they route around the org's model policy; if they can add their own
   gateway, they route around its egress policy. So "which providers may be used" and "may the user
   add providers, gateways or MCP servers at all" are ceiling dimensions, not ordinary settings.
3. **Sign-out clears the person, keeps the policy.** The exact inverse of profile removal, which
   clears the policy and restores the person's prior values. Getting these two backwards is how a
   device ends up either leaking the last user's data or silently unmanaged.

## Three ingress paths, one schema

Worth stating up front because it changes the shape of P2 and costs almost nothing extra:

- **QR** — the asked-for path. Orgs without device management: museums, contractors, BYOD field teams,
  a code printed on a workshop wall or a laminated card in an equipment case.
- **Managed App Configuration** — the Apple-native path (`com.apple.configuration.managed`, written
  into the app's `NSUserDefaults` by the MDM). We support **none of it today**. For an organisation on
  Jamf/Intune/Kandji this is strictly better than a QR: zero-touch, nothing to scan, and policy can be
  changed remotely without touching a device. It is also roughly thirty lines to read.
- **Deep link** — the same profile emailed or messaged rather than printed.

Build the schema and the applier once; all three are thin adapters onto it. That turns an onboarding
convenience into an actual deployment story.

## Non-goals

- **Becoming an MDM.** We are a *managed app*, not a management platform. No enrolment of the device
  itself, no remote wipe, no inventory.
- **Building the user-account system.** One device, one active *policy* profile; identity is a
  separate axis and its home is Plan CR's per-user gateway. CT defines how policy clamps identity, not
  how identity works. Per-user *settings* profiles with PIN switching remain Plan AJ's deferred
  "profiles + PIN".
- **Downloaded code or behaviour.** A profile sets values and locks; it does not add tools, prompts or
  procedures. That is what Plan BX skill packs are for, and they have their own signing and install
  trust decision. A profile may *reference* a pack; it may not embed one — and that holds for the
  vault pack enrolment now installs, which arrives as signed, checksummed **data** through Plan EG's
  own installer rather than as anything the profile carries.
- **White label.** A partner's own name on the icon is a separate bundle identifier, App Store
  listing, review, signing identity and privacy manifest, with its own screenshots, support URL and
  localisation — none of which a configuration profile shortens by a single step, and Plan EE already
  places white label in the enterprise *contract* column rather than in any tier's code path. What
  this plan offers instead is a single-purpose edition **inside the same app**: the partner's pack,
  the organisation's name on the managed row, everything else subtracted. That is the behaviour a
  partner asks for and not the branding, and the distinction belongs in the sales conversation rather
  than being discovered during review.
- **Secrets in the profile.** Structural, see below.
- **Silently locking a device.** A managed device says so, on screen, always.

---

## P1 — Pure core (headless, no wiring)

### `ConfigProfile`

Versioned, `Codable`, signed. Fields: profile id, org display name, schema version, issued date,
**two expiry dates** (below — corrected 2026-09-24: the second is the licence code's own signed `expires`, not a profile field), an optional skill-pack reference list, a **vault-pack reference** (the
pack id enrolment installs, plus an optional documents source for the organisation's own manuals),
the **licence code** the entitlement half rides on, and the settings themselves as
`[SettingKey: ManagedValue]` where:

```
ManagedValue = { value: ProfileValue, disposition: .default | .ceiling }
```

**The disposition is the field that decides whether this is a good feature**, and it is deliberately
not a boolean `locked`.

- `.default` — the org sets a starting value; the user may change it afterwards. A museum handing out
  devices wants this.
- `.ceiling` — the org sets a bound that **nothing downstream may widen**. Not "the org picked this
  value" but "this capability is not available on this device, whoever is holding it."

The distinction is not stylistic. The moment a person signs in (below), a pin and a ceiling behave
differently: with pins, whichever write happens last wins, so the outcome depends on the order of
enrolment, login, entitlement restore and settings sync. With a ceiling, **policy can only ever
subtract**, so the result is the intersection of org policy and user preference regardless of the
order they arrived in. Order-independence is what makes this auditable — an org can state what a
device can do without having to reason about the sequence of events on it.

Concretely: `.ceiling(privacyFilterEnabled: true)` means the blur cannot be turned off; a user
toggling it sees a locked control with the org name as the reason.
`.ceiling(remoteInvokeCaptureEnabled: false)` means no configuration, no login, no skill pack and no
future feature can grant remote capture on this device. A lock is never invisible — it renders with
its reason, per the rule CQ P0 and CS P1 both landed on.

### `SettingKey` — the org-settable surface

An explicit allow-list enum, not a string passthrough onto `UserDefaults`. Three reasons, in order of
importance:

1. **Secrets must be structurally impossible.** A QR is a photograph — it gets Slacked, printed,
   photographed, left in a camera roll. `Config` already maintains the authoritative inventory of what
   counts, in `migratableStringSecretKeys` (`anthropicAPIKey`, `openAIAPIKey`, `elevenLabsAPIKey`,
   `perplexityAPIKey`, `openClawGatewayToken`, `homeAssistantToken`, `broadcastStreamKey`,
   `expertTurnCredential`) and `migratableDataSecretKeys` (`savedModelConfigs`, `savedGateways`,
   `mcpServers`, `customAgentHarness` — each of which embeds a credential inside a JSON blob). None of
   those may be `SettingKey` cases, and a test asserts the two lists stay disjoint so a future key
   added to one cannot quietly appear in the other.
2. An arbitrary key/value write into `UserDefaults` from a scanned code is a remote-configuration
   primitive for anything the app stores, including flags that were never designed to be
   externally set.
3. It gives the profile a schema to validate against, which is what makes the report below possible.

Deliberately small first cut: the capability toggles and feature gates (`privacyFilterEnabled`,
`glassesDisplayEnabled`, `simpleModeEnabled`, `audioOnlyMode`, `mcpServerEnabled`,
`agentModeEnabled`, the `remoteInvoke*` trio, the visual-state family), plus non-secret endpoints
(gateway host/port, Hermes bridge host/port), the Field Assist selection keys (`fieldAssistEnabled`,
`fieldAssistDefaultVaultId`, `fieldAssistDefaultMode`) and skill- and vault-pack references.
Everything else is a later addition, and adding one is one enum case. **The first PR cuts this
further, to the seven FO/FS stand-ins plus a handful of capability keys** — the exact list, and the
direction each may move, is in *Delivery order* below.

**Two families are settable in the pin-*on* direction only, and one of those is a correction to this
plan's own first cut.** The assistive surface may be turned on by a profile and never off — the
decision was already recorded here, and it is now enforced in code:
[`CapabilityCatalog`](../../OpenGlasses/Sources/Services/SettingsJourney/CapabilityCatalog.swift)
builds the Accessibility category through `pinnedAssistive`, a constructor that deliberately exposes
no placement and no Simple Mode parameter, with the reason written above it. **The fingerspelling
family is part of that surface**, not a general capability: `FingerspellingSettingsView` is presented
from inside `AccessibilitySettingsView`, so listing it beside `mcpServerEnabled`, as the draft did,
would have let an organisation withhold a sign-language reader from the person holding the device. It
moves to pin-on-only with the rest of the assistive surface. The privacy filter is the second family:
`.ceiling(privacyFilterEnabled: true)` is a supported policy, pinning it off is not one.

### `ProfileApplier`

Pure: `apply(profile:, to: ConfigSnapshot, now:) -> ApplyResult`. No `UserDefaults` in the decision
path; the caller commits the result. `ApplyResult` carries the settings to write, the lock set, and a
**lossy-decode report** — BX's rule, which is the right rule here for a sharper reason than usual: a
profile is written by an org against one app version and scanned on another, so unknown keys and
out-of-range values are the *normal* case, not the exceptional one. Named drops, never silent, and the
report is surfaced to whoever is holding the phone at enrolment.

Precedence, stated once and tested: **managed app config > profile > user**, with ceilings applied as
a final clamp rather than a layer — a ceiling is not outranked by anything, including a later
managed-config *default*. An MDM-managed device whose administrator changes policy must win over a
profile scanned last month, and both win over a local preference. A profile arriving on a device
already under MDM management is reported, not silently merged.

### `PolicyEnvelope` — the clamp, and when it runs

The applier's ceiling output is a standing envelope, not a one-time write. It re-clamps on **every
identity or entitlement change**, not just at enrolment:

| Event | Why it must re-clamp |
|---|---|
| Sign-in (provider OAuth, gateway identity) | a person's own configuration must not widen the device |
| Sign-out / user switch | the next person inherits policy, not the last person's settings |
| IAP entitlement change or restore | a purchased tier must not unlock what the org forbade |
| License code entered | same, for the offline B2B path |
| Managed config updated by the MDM | policy changed under a running app |

A one-shot apply looks correct in testing and fails in exactly the case this plan exists for: someone
signs in an hour after enrolment and their own settings quietly restore a capability the org removed.

### Ceilings for a single-purpose edition

A ceiling that removes a handful of toggles produces a general assistant with some settings missing.
"The HVAC assistant" is a stronger claim: one feature stands and the rest of the app is gone. That is
a long subtraction, and it has to be enumerated against what actually ships rather than described in
the abstract. The shipped hub is `CapabilityCatalog.all` — twelve categories rendered by
`SettingsView.destination(for:)` — so the subtraction is stated per category.

**Subtracted by a Field-Assist-only ceiling.**

| Category | What the ceiling takes away |
|---|---|
| AI & Personality | The persona library and the Modes tab's grid (`Config.savedPersonas`, `PersonaPickerTab`), the custom system prompt, model choice, `autoModelRoutingEnabled`, `modelCascadeEnabled`, `narrateModelSwitchesEnabled`, `llmComplexityClassifierEnabled`, `intentClassifierEnabled` |
| Live / realtime modes | Gemini Live and OpenAI Realtime. Neither is a toggle today — `Config.geminiLiveModelConfig` and `Config.openAIRealtimeModelConfig` decide availability by whether a provider is configured — so the ceiling dimension is *which providers and modes may be configured or used at all*, which is the same dimension the draft already required for model and egress policy |
| Capture & Streaming | Recording (`recordingSaveToPhotos`, `recordingFolderBookmark`), RTMP broadcasting (`broadcastPlatform`, `broadcastRTMPURL`, the frame-rate/bitrate family), `broadcastChatReadbackEnabled`, browser streaming, `dwellCaptureEnabled` |
| Connections | The gateway (`openClawEnabled`, saved gateways), `agentModeEnabled`, the `remoteInvoke*` trio, `mcpServerEnabled`, the Hermes bridge (`hermesBridgeEnabled` + host/port), the custom agent harness, Home Assistant |
| Tools & Actions | Skill packs (`skillPackCatalogURL`, `skillPackDevModeEnabled`, and the `SkillPackSideload` deep-link host), playbooks, quick actions, custom home actions |
| Memory & context | `memoryCurationEnabled`, `memoryNudgesEnabled`, `visualStateMemoryEnabled` / `visualStateInjectThumbnails`, `contextualEmbeddingEnabled`, `myDayEnabled` |
| Local inference | `localAgentEnabled`, `ggufModelsEnabled`, `localRuntimeCoordinatorEnabled` — a managed phone should not be pulling gigabyte model files over a customer's tether, and that is the organisation's call rather than the technician's |
| Advanced | The prompt-and-traffic inspection surface behind `AdvancedSettingsScreen` |

**Kept, and not at the organisation's discretion.**

- **Accessibility** — already decided here, now enforced by `CapabilityCatalog.pinnedAssistive` as
  above. Assistive narration, reading help and fingerspelling stay reachable on a fully ceilinged
  device.
- **Diagnostics & Support** — the catalog marks it everyday *and* visible in Simple Mode, because the
  wearers who most need a self-test and a way to report a problem are the ones who never see
  Advanced. A technician whose managed phone has stopped working has to be able to prove it.
- **Voice & Triggers** — Field Assist is a hands-free product; the wake phrase and push-to-talk are
  its input, not an extra.
- **Glasses & Privacy** — pairing, and `privacyFilterEnabled`, which an org may pin on and nobody may
  pin off.
- **Look & Feel** — theme, accent and language. `LanguageSettingsView` is how a technician reads the
  app at all.
- **Field Assist itself** — the session surface, Custom Vaults with its Packs section, the session
  log, escalation.
- **The managed row and its removal path** — a device that cannot be un-managed is malware with a
  nicer name, and that does not soften for a single-purpose edition.
- **About** — version, build, attributions and the licence notice are an obligation, not a
  capability.

**What the surface looks like when most of it is gone.** `MainView` is four tabs — Voice, Modes,
Chat, Settings. On a fully ceilinged device the Modes tab holds exactly one mode, so it collapses to
the Field Assist entry rather than presenting a grid of one; Chat holds field-session transcripts and
nothing else; Voice stays the session surface. **Field Assist is the home**, which is what "comes up
as the HVAC assistant" means concretely. Settings renders the surviving categories, a persistent
"Managed by ⟨org⟩" row carrying the issue date and both expiries, and nothing else.

Two second-order effects a first implementation will get wrong unless they are written down: the
**Discover** shelf must not pitch a category the ceiling removed, and **"Show everything"**
(`journey.state.showsEverything`) must not be able to bring one back — it is a display switch over
folded categories, and its footer today ("Nothing here is locked — this only decides what the list
shows") stops being true on a managed device and has to change with it.

### Entitlement rides the profile — one artefact, bought once for the fleet

**Decided:** the org's code is both the configuration *and* the licence. An organisation buys for
everyone it deploys to, so the artefact that bounds a device is the same one that entitles it. There
is no per-seat activation, no seat-management system, and no reason for a person's login to carry
entitlement — login stays purely identity and personalisation.

This is cheaper than keeping them apart, not more expensive, because they are already the same
primitive. [`LicenseService`](../../OpenGlasses/Sources/Services/LicenseService.swift) verifies
`{feature, licensee, issued, expires?, tier?, plan?, seats?, reference?, packs?}` under an Ed25519
signature with an embedded public key; `ConfigProfile` verifies `{settings, expiry}` the same way.
Merging is one payload type and one verification path instead of two. The join on the consuming side
already exists and has grown since this was drafted:
[`VaultRegistry.isUnlocked`](../../OpenGlasses/Sources/Services/Vault/VaultRegistry.swift) is now a
resolution table rather than a two-case switch — `nil` unlocked always, `medical_compliance` on the
Medical Compliance subscription, the two bundled ids at any Field Assist tier, `enterprise` (a
customer's own imported vaults) at tier ≥ team, and **anything else resolved as a pack id** through
`VaultPackAccess.isUnlocked` from the verified store products, the licence's `packs` claim and the
tier. So an organisation grant needs no new gating; it needs the right claims in the code the profile
carries.

**The profile's entitlement half is the licence code, and nothing but the licence code.** Enrolment
does not invent an evidence kind. It hands the code to `LicenseService.activate(code:)`, which
verifies the signature and the `feature == "field_assist"` claim before storing the string at
`LicenseService.storageKey` — the same single slot a technician typing a code by hand writes to. From
that moment the shipped path does all the work:
[`LiveFieldAssistEntitlementProvider.evidence()`](../../OpenGlasses/Sources/Services/Entitlement/FieldAssistEntitlementProvider.swift)
decodes the stored code **afresh on every read**, hands the *signed* `expires` and `resolvedTier` to
`FieldAssistEntitlementEvaluator`, and `livePacks` unions the `packs` claim of live evidence only, so
a lapsed code contributes no packs. Nothing in that chain is a cached "entitled" flag, which is Plan
DP's rule and the constraint this plan must not erode — a profile that wrote a boolean would be
exactly the forgeable preference DP removed, arriving through the one path that looks administrative
rather than security-relevant.

Three consequences, stated as rules rather than left implicit:

- **A profile may never widen entitlement beyond the code inside it.** The tier a device holds is the
  decision's tier, derived from the signed payload; `LicensePayload.resolvedTier` maps a missing or
  unrecognised claim to `.team` and coerces `solo` up to `.team`, so no malformed claim reaches
  enterprise. Where a profile's settings imply a capability the code does not entitle, the result is a
  locked or absent control with an honest reason, never an unlock. Ceilings only subtract; the
  entitlement half only reports what was signed.
- **A pack the code does not list stays locked, whatever the profile says.** The profile names a pack
  so enrolment can *install* it. The registry still asks `VaultPackAccess` with the granted packs and
  the verified store products, so an installed-but-unentitled pack is a visible, locked row — which is
  the correct outcome for a renewal that has lapsed, and a much better one than a vault that vanishes.
- **Enterprise is not delegable, and a profile is where that would leak.** The registry's pack branch
  unlocks *every* pack at enterprise regardless of the `packs` claim, so an enterprise grant issued by
  a partner would silently void per-partner pack accounting. Plan EI's partner record allows team only
  for that reason, and a partner-issued profile therefore carries a team code. Enterprise stays a
  vendor contract, minted by the vendor.

Nor is it a new bypass of StoreKit. Field Assist is *already* unlockable by an offline signed code as
well as by `com.openglasses.field_assist` — the org-purchase path is shipped and this is the same path
with better ergonomics. What changes is the ergonomics only: one scan instead of a purchase flow plus
a code emailed to whoever set the device up.

**Why this is safe here specifically, and would not be as an inline code.** P2 already decided the QR
carries a *pointer*, not a payload. So a photographed poster yields a URL, not a bearer credential —
and that buys three properties an inline licence QR could never have: the hosted profile can be
**revoked** (delete it and the next fetch fails), **rotated** (a lost poster is a new URL, not a new
entitlement), and optionally **bound at first fetch** to the devices that actually enrol. An inline
licence in a wall-mounted QR would be a bearer token on a wall, and I would argue against it.

The offline cost is one round trip: enrolment needs connectivity, after which the verified profile is
cached and works offline indefinitely — which is what Field Assist actually needs, since enrolment
happens at the depot and the work happens in the field.

**Two clocks, not one.** `policyExpiry` and the entitlement's expiry are separate — the latter is the signed `expires` of the licence code the profile carries, never a second field (corrected 2026-09-24, see *PR 1 as built*) — because a lapsed
subscription must not unmanage a device (the capability bounds are a safety property, not a paid
feature) and a rotated policy must not revoke a licence the org has paid for. Merging them into one
date is the mistake that turns a billing event into a compliance incident.

**And a third, short one: the lease** (2026-09-24). `policyExpiry` is the organisation's term;
`leaseDays` is how long a phone stays the firm's without hearing from the profile's URL, renewed on
every fetch. It is what makes a leaver's access end — see *PR 4 — leaving the firm*.

### Pack install is part of enrolment

Naming a pack and installing one are different acts, and the draft only had the first. The profile
carries the pack id — the same string the vault manifest's `gating.iap` carries and the catalog entry
is keyed by — and enrolment installs it through the path Plan EG shipped rather than a new one:
[`VaultPackCatalogService`](../../OpenGlasses/Sources/Services/Vault/VaultPackCatalogService.swift)
verifies the signed index against the embedded key, then runs download → SHA-256 against the
catalog's checksum → pack-signature verification over `pack.json`, `manifest.json` and every payload
file → structural checks (vault id, gating string, no documents, `minAppBuild`) →
`VaultImporter.installReporting(from:)`. The importer records `pack.json` beside the read-only
baseline, which is what lets a later pack update preserve the technician's own edits in the overlay.

Only once that install reports success does enrolment write `fieldAssistDefaultVaultId` and switch
`fieldAssistEnabled` on. In the other order the default points at a vault id the registry cannot
resolve — a broken home screen on a device whose entire purpose is that screen.

**The organisation's own manuals are a pointer too.** A pack ships trade knowledge and never OEM
manuals; Plan EG is categorical about it, so the customer's books belong in the same vault's
`documents` tier. The profile may name an organisation-hosted folder or document set for that tier,
and ingestion runs through `VaultImporter.syncDocuments`, which is already gated at `.team` at the
boundary where the store is written and already routes scans through Plan EF's extractor. The profile
carries a location and never document bytes — the same rule that makes it a pointer rather than a
payload, and for the additional reason that a service company's manual library is not something to
put behind a code on a workshop wall.

**Offline, at enrolment and afterwards.** Enrolment already costs one round trip. The catalog and the
pack archive want the same connectivity, and the honest behaviour is a *partial* success rather than
a refusal: the verified profile is cached and applied immediately — the ceilings and the licence are
the safety half and must not wait on a download — while the pack is recorded as pending, retried, and
named on the Field Assist screen as the thing that is missing. A half-configured device that says
which half is missing is recoverable in the field; one that quietly comes up as a general assistant
is not.

After enrolment nothing needs the network to stay configured: the cached profile, the stored code
(re-verified locally on every read) and the installed baseline are all offline artefacts. Catalog
reachability matters only for the update check, which Plan EG runs at session start and never
mid-session.

### Where the profile and its code come from — Plan EI

A partner-configured edition needs somebody to mint it, and that is not this plan. Plan EI's issuance
service holds the signing key, checks a partner's grant record — which tiers, which packs, longest
term, seat quota — *before* anything exists, and writes the ledger row the vendor bills from. **A
partner issues a profile for a customer exactly the way it issues a code:** same grant, same
validation, same ledger row, one more artefact. The profile is that code plus the settings that turn
the app into a single-purpose edition, published at the URL the QR points at.

Three properties follow, worth stating so neither plan drifts from the other:

- **Renewal is a new code, or a new profile at the same URL.** `LicenseService.storageKey` holds one
  string and activation replaces it, so a device cannot accumulate licences; renewal is replacement in
  both plans, and a rotated poster is a new URL rather than a new entitlement.
- **The two clocks stay two.** The partner's agreed maximum term bounds the *entitlement* clock it
  sells. `policyExpiry` is the organisation's own and is not the partner's to lapse: a device whose
  licence ran out must be a bounded device that lost a feature, never an unmanaged device that
  regained the rest of the app.
- **Support still names a ledger row and never a code.** The provider's licence-id hash — the first 16
  hex characters of SHA-256 over the code — is what the decision's audit label and the session audit
  lines carry. Enrolling by profile changes none of that, so a screenshot from a partner-configured
  phone is still safe for a customer to send.

### `ProfileVerification`

Reuses the license primitive directly — same Ed25519 verification, with **domain separation in the
signed bytes** (a typed prefix per payload kind) and a signing key distinct from the consumer licence
key, so an org profile and a consumer licence code can never be replayed as one another and
compromising either key does not yield the other. Both expiries are checked here, independently, and
an expired profile is a *refusal with a reason*, never a silent no-op: an org that let one lapse needs
to hear which clock ran out, from the device.

---

## P2 — Ingress adapters

- **Scanner view** — the one new UI component. `AVCaptureSession` + `AVCaptureMetadataOutput`, on the
  phone, torch toggle, and it does nothing but hand a decoded string to the parser.
- **`openglasses://enrol?url=…&sig=…`** — parsed by the same shape as `SkillPackSideload`, reusing its
  source policy verbatim (HTTPS anywhere; plain HTTP only to a private/LAN host). Not
  `DeepLinkTrust`-gated, for the reason that file already documents, with the same compensating
  control: it fetches and verifies, then presents.
- **Managed app config reader** — `UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")`,
  observed rather than read once, because an MDM can update it mid-session. **Deferred 2026-09-24** — the
  reader waits for an organisation that needs it; the seam it plugs into ships in PR 1–2 (see
  *Delivery order*).

**The QR carries a pointer, not a payload.** A version-40 QR tops out near 2,953 bytes at the weakest
error correction, and a code meant to be scanned reliably off a printed card at arm's length wants to
be well under half that; after JSON, base64 and a 64-byte signature, an inline profile realistically
fits a few dozen settings and no more. So the default form is a signed URL the app fetches over HTTPS,
with inline profiles supported for genuinely small ones. This is also strictly better operationally:
the org updates the hosted profile without reprinting anything.

---

## P3 — Onboarding, enrolment, managed state, watch

### The first-run branch

A "Configure with a QR code" option on the welcome page, ahead of the provider/key pages, because the
whole point is skipping them.

**The trap here is a live crash class we have already been bitten by.** Plan CD P1: `needsOnboarding`
is `!hasCompletedOnboarding && !hasAnyAPIKey`, so anything that causes a key to exist *before*
onboarding finishes leaves both flags unset — the screen never reappears, nothing calls
`Wearables.configure()`, and MWDAT answers an unconfigured `Wearables.shared` with `fatalError`. An
enrolment path that applies settings mid-onboarding is exactly that hazard wearing a new hat. So:
enrolment funnels through `WearablesBootstrap`, sets `hasCompletedOnboarding` *explicitly* rather than
relying on the derived flag, and a test asserts that a profile applied at first run leaves the app in
the same flag state as completing onboarding by hand.

### Enrolment, in order

Enrolment is no longer "apply settings". On a partner-configured device it is a sequence, and the
order is load-bearing:

1. Fetch and verify the profile — both signatures, both clocks — and present it: the organisation's
   name, what it will turn on, what it will take away, and which pack it will install. That is the one
   human confirmation, and it covers the pack too, per Plan BX's rule that install is the trust
   decision.
2. Activate the licence code, so entitlement exists before anything gated on it runs.
3. Install the pack through `VaultPackCatalogService` — which is gated on that entitlement and needs
   the catalog.
4. Write the settings and raise the ceiling, then set `fieldAssistDefaultVaultId` and
   `fieldAssistEnabled` — after the pack is on disk, never before.
5. Sync the organisation's documents into the pack's documents tier when the profile names a source.
   On a binder of scans this takes a long time, so it is resumable and does not block enrolment.

Steps 1, 2 and 4 succeed together or not at all; 3 and 5 may be pending, retried and reported. The
device is correctly *bounded* the moment step 4 lands, and that is the property that must never wait
on a download.

### Managed state, visible

- A persistent "Managed by ⟨org⟩" row in Settings, with the profile's issue date and expiry.
- Locked controls render locked with the org name as the reason — never merely disabled.
- **Removal is possible and owner-gated.** An organisation must be able to un-manage a device, and a
  person must be able to leave. Removal composes with `OwnerGateMachine`: it is a device-owner action,
  and it restores prior values rather than leaving the org's settings behind as unexplained defaults.
  A profile that could not be removed would be malware with a nicer name.

### Watch propagation

The profile rides the same phone→watch application-context channel Plan CS P2 defines. Locks must
travel with it: a capability disabled by policy on the phone but live on the wrist is a hole in
exactly the boundary the policy was drawn for — the same reasoning as CS's HIPAA revocation note, and
it fails the same way.

The watch has no camera and cannot scan, and WCSession already provides an authenticated channel
between exactly the right two devices. A QR there would be strictly worse than what exists.

---

## P4 — Deferred

- **The credential half — and per-user login resolves it more cleanly than a shared secret.** A
  profile cannot carry credentials, and with per-person identity it does not need to: the profile
  names *which* org gateway to authenticate against, and the person's own sign-in supplies the
  credential. That is strictly better than a shared enrolment secret, which would be one credential
  for every device that ever scanned the poster, unattributable and unrevocable per person. Plan AR's
  `SetupCode` remains the right shape for the shared-appliance case (a kiosk with no person to sign
  in), against Plan CR's endpoint. Until identity lands, an org-configured device is correctly
  *bounded* but still needs its credential entered once — which is a smaller gap than it sounds,
  because the bounding is the part that was impossible before.
- Device verification: printed-code scan distances and lighting, and the honest failure when a code is
  damaged or partially obscured.
- ~~An authoring tool for profiles~~ — **moved into PR 1** (2026-09-24): with Plan EI unbuilt, a
  script mirroring `Scripts/generate-field-license.swift` is the only way a profile can exist. The
  QR renderer stays here; PR 3 is the first thing that scans one.

---

## Delivery order (2026-09-24)

P1–P4 above are the design. They are delivered as three PRs cut across those phases, each
headless-testable where it can be. Each PR is useful on its own, and each is shaped so that the
next one adds to it rather than rewriting it.

### PR 1 — headless core, scoped to the keys that already exist

`ConfigProfile`, `SettingKey`, `ProfileVerification` and a pure `ProfileApplier`, exactly as P1
describes them, over a deliberately short first cut. **Each `SettingKey` case declares the one
direction it may move**, so a profile that tries to move a key the other way is a named drop in the
lossy-decode report rather than a write. That generalises the pin-on-only rule this plan already
applies to the assistive surface and the privacy filter, instead of special-casing two families.

| Kind | Keys | What a profile may do |
|---|---|---|
| **Profile-owned** — organisation identity, never a user preference | `organizationDisplayName`, `organizationJobSigningKey`, `organizationJobReportChannel`, `organizationReportRecipients` | set; there is no user surface to override them, and removal clears them |
| **Ceiling, tighten only** | `organizationAllowsUnsignedVaults` → `false`; `organizationRequiresSignedJobFiles` → `true`; `organizationRequiresCustomerSignOff` → `true`; `privacyFilterEnabled` → `true`; `remoteInvokeObserveEnabled` / `remoteInvokeOutputEnabled` / `remoteInvokeCaptureEnabled` → `false`; `mcpServerEnabled` → `false`; `agentModeEnabled` → `false` | pin in the stated direction; the other direction is refused and reported |
| **Default** | `fieldAssistEnabled`, `fieldAssistDefaultVaultId`, `fieldAssistDefaultMode` | set a starting value the person may change afterwards |

Four notes on that cut:

- **`organizationJobSigningKey` is a public key**, so carrying it in a profile is not a secret
  leaking into a photograph; the secret-disjointness test still runs over every case.
  `organizationReportRecipients` is the organisation's own addresses — not a secret, but personal
  data, which is one more reason the QR carries a pointer and not the profile.
- **`fieldAssistEnabled` is a default here, not a ceiling.** Pinning a feature *on* is the
  single-purpose edition's move, and that edition is deferred (below). A museum or a pilot wants
  Field Assist on at first run; whether a technician may then switch it off is a later decision.
- **`fieldAssistDefaultVaultId` is validated, not trusted.** Until PR 3 installs packs, the applier
  takes the set of vault ids the registry resolves as an input, and a profile naming one it cannot
  resolve is a named drop — the same failure the *Setting `fieldAssistDefaultVaultId` before the
  pack installs* trap describes, caught at apply time instead.
- **`Scripts/make-org-profile.swift`** mints a signed profile — the domain-separated prefix, a new
  Ed25519 keypair distinct from the consumer licence key, the private key off-repo exactly as
  `generate-field-license.swift` keeps its own. Until Plan EI exists this is issuance. The same
  script mints the **signed revocation document** PR 4 describes (`--revoke`, whole link or named
  enrolment ids).
- **One vendor profile key, with a key id** (decided 2026-09-24). Profiles are not signed per
  customer: a phone that has never seen customer X has no way to trust X's key unless something it
  already trusts vouches for it, and that is this key. The per-customer key lives one level down —
  the vendor-signed profile *carries* the organisation's `organizationJobSigningKey`, and the
  organisation signs its own job files with that. The profile names the key it was signed with
  (`keyId`) and the app embeds a small set of public keys, so a key can be rotated or retired
  without breaking every profile already issued. A leaked profile key cannot grant entitlement — the
  licence code inside is signed separately — but it could substitute a job-signing key or redirect
  report recipients, so it is held to the licence key's standard.
- **`leaseDays`**, bounded 7–365, and the optional `eraseAfterLapseDays` and undelivered-record
  cap — schema only here; PR 2 and PR 4 act on them.

Tests: the secret/`SettingKey` disjointness assertion; every direction refusal; both expiry clocks
checked independently with the refusal naming which one ran out; a profile signed with the licence
key (and a licence code signed with the profile key) refused; an unknown key and an out-of-range
value each reported by name; a `keyId` the app does not embed refused by name; a `leaseDays`
outside 7–365 reported and clamped; the precedence order (managed config > profile > user, ceilings as a
final clamp) as a table, with a synthetic managed layer standing in for the reader that does not
exist yet.

**The seam an MDM adapter plugs into — built now, with no MDM reader behind it.** Decided
2026-09-24: CT starts without Managed App Configuration, but no structure PR 1 or PR 2 builds may
assume a profile only ever arrives by scan or link. Four things carry that:

- **`ProfileSource`** — `.link`, `.scan`, `.managedConfig` — recorded with every applied profile and
  carried in `ApplyResult`. The source decides removal (below) and the wording of the managed row,
  so the case exists from the start even though nothing produces `.managedConfig` yet.
- **`ProfileIngress`** — a small protocol an adapter conforms to: it yields a signed profile (the
  string itself, or the HTTPS pointer to it) and a source, and nothing else. The link parser and the
  scanner are its first two conformances; the MDM reader later is a third, observing
  `com.apple.configuration.managed`, and adds no verification or apply logic of its own.
- **The applier takes layers, not a profile.** `apply` accepts an optional managed layer beside the
  profile layer and the user's snapshot, and the precedence table — managed > profile > user,
  ceilings as a final clamp, a second profile arriving under management reported rather than
  merged — is tested now with a synthetic managed layer. When the reader lands, precedence is
  already proven.
- **The managed-config wire shape is documented now**, in this plan and beside the script that
  mints profiles: the dictionary carries **the same signed profile** (inline or as a URL) under a
  reserved key, never raw settings. One trust path and one verification; an administrator who
  changes policy re-mints rather than editing an unsigned plist. Writing it down before an MDM
  customer exists stops the first one from getting an ad-hoc format.

**PR 1 as built (2026-09-24, headless; written without a Swift toolchain, so CI was the compiler —
it compiled and all 32 tests in `OrgProfileVerificationTests` and `OrgProfileApplierTests` passed
on the first run).** Files under `OpenGlasses/Sources/Services/OrgProfile/`:

- `ConfigProfile.swift` — `ConfigProfile`, the lossy `RawSetting`, `ProfileValue` (flag, string,
  string list), `ProfileRevocation`, `ProfileSource` (with `managedConfigProfileKey = "orgProfile"`,
  the reserved managed-config key), `ProfileDelivery` and the `ProfileIngress` protocol.
- `SettingKey.swift` — the sixteen cases above; each declares its `kind` (profile-owned, a
  one-way ceiling, or a starting value) and its content checks (a job-signing key must be a
  Curve25519 public key, a report channel a known `DeliveryChannel`, a mode a `FieldSession.Mode`,
  a default vault one the registry resolves).
- `ProfileVerification.swift` — `productionKeys` holds `og-profile-2026-09`, the owner's key
  generated 2026-09-24. Documents are `base64(payload).base64(signature)` with the signature over
  `openglasses.org-profile.v1\n` or `openglasses.org-revocation.v1\n` then the payload. Verification
  never reads the clock; `enrolmentRefusal(for:now:)` does, naming which clock ran out.
- `ProfileApplier.swift` — the pure layered resolution, `Drop`s and `Notice`s by name, and
  `effectiveValue(_:stored:)`, the clamp PR 2's getters will call.
- `Scripts/make-org-profile.swift` — `make`, `revoke` and `keygen`; it refuses an unknown key or a
  wrong-direction ceiling at minting time rather than letting a phone drop it. Not yet run: it
  needs a Mac.
- `Config.migratableStringSecretKeys` / `migratableDataSecretKeys` lose `private` so the
  disjointness test can read them.

**A correction to this plan, found while building it: the entitlement clock is not a profile
field.** The draft gave the profile an `entitlementExpiry` beside `policyExpiry`. But the
entitlement already has a signed clock — the `expires` of the licence code the profile carries —
and a second copy in the profile could disagree with it, which is exactly the forgeable-preference
shape Plan DP removed. So the profile carries `policyExpiry` (the organisation's term), `leaseDays`
(the leaver clock) and the licence code, and the licence's own `expires` is the entitlement clock.
Still two clocks at enrolment, both checked, each refusal naming its own.

### PR 2 — enforcement, managed state, and the link

**Clamp on read, never on write.** The envelope is enforced in the `Config` getter of each allowed
key, so every existing read site — `VaultLinkInstallPolicy`, the sign-off step, the delivery policy,
the job-file check — gets the clamped value with no change of its own. The keys declared with
`@UserDefaultsBacked` today (`privacyFilterEnabled`, the `remoteInvoke*` trio, `mcpServerEnabled`)
become managed accessors; the rest are already hand-written. The envelope is an in-memory value
loaded at launch from the cached profile, **re-verified on load** rather than trusted from storage,
so a getter never pays for a signature check and a tampered cache is a refusal, not a policy.

A ceiling never overwrites the person's stored value; it only clamps what the getter returns. That
makes *removal restores prior values* free for ceilings — there is nothing to restore — and leaves
only `.default` writes needing a recorded prior value. It is also why a setter under a ceiling is
harmless rather than a hole: it writes a preference the getter will not return until the ceiling
lifts.

The rest of PR 2:

- **`openglasses://enrol?url=…&sig=…`**, the first `ProfileIngress` — P2's parser, reusing
  `SkillPackSideload`'s source policy verbatim, fetch → verify → present → one human confirmation.
  It is the smallest adapter (no camera) and it exercises the whole verify-and-apply path end to end.
  **It applies only after onboarding has completed**; a link opened on a phone that has not finished
  onboarding is held and presented once it has, and a test asserts an apply leaves both onboarding
  flags unchanged. The first-run branch — where CD P1's hazard lives — is PR 3's.
- **The "Managed by ⟨org⟩" row** — issue date, both expiries, and the source — and locked controls
  rendered with the organisation's name as the reason. **"Show everything"**'s footer ("Nothing here
  is locked…") changes on a managed device in this PR, because it stops being true the moment the
  first ceiling lands, not only in the single-purpose edition.
- **Removal behind `OwnerGateMachine`**, decided by source: a `.link` or `.scan` profile is removable
  by the device owner. A `.managedConfig` profile is not locally removable — the MDM would reapply
  it — so the row names who manages the device instead of offering a button that cannot work. That
  branch is written and tested now against the synthetic managed layer.
- **The envelope re-clamps on entitlement change and on a policy-source change** — a new profile,
  a removal, and (when the reader lands) a managed-config update all arrive as the same event.
  Sign-in and sign-out re-clamping waits for identity, which does not exist yet (below).
- **The lease, from PR 4's design:** the renewal fetch on launch and on foreground (at most daily),
  the "Connect to renew by ⟨date⟩" warning from 14 days out, lapse-locking through the envelope
  (deferred until an active job closes), the clock high-water mark, and recognising a signed
  revocation document. What a received revocation *erases* is PR 4; until PR 4 lands, a revoked
  profile locks exactly as a lapsed one does and lifts its ceilings.
- **A check, not a build, for the watch:** confirm that no watch path reaches a ceilinged key except
  through the phone's `Config` getter. If none does, watch propagation stays with Plan CS; if one
  does, it is a bug in this PR.

**PR 2 ships in two parts (decided 2026-09-24).** CI is the only compiler for this work, so each
round is kept small. **PR 2a** is everything above except the lease bullet: enforcement, the
stored enrolment, the link, the managed row, removal and the locked controls — the part that makes
the FO/FS stand-ins reachable at all. **PR 2b** is the lease bullet: renewal, the warning,
lapse-locking, the clock high-water mark and the signed revocation document.

**PR 2a as built (2026-09-24).**

- `PolicyEnvelope` (`OrgProfile/PolicyEnvelope.swift`) holds the applier result in memory behind a
  lock and answers the typed reads; `Config`'s sixteen-key surface now reads through it. The five
  `@UserDefaultsBacked` keys (`privacyFilterEnabled`, the `remoteInvoke*` trio, `mcpServerEnabled`)
  became hand-written accessors.
- **A refinement of "a setter under a ceiling is harmless":** the setter of a locked key is
  *refused*, not merely overridden on read. The reason turned up in the code: several screens hold
  a copy of the value in `@State` and write it back on the way out (`GlassesPrivacySettingsScreen`
  does exactly that), so a disabled switch showing the clamped value would have written the
  organisation's value over the person's own, and removal would then have "restored" the
  organisation's choice. Refusing the write keeps the person's value untouched for the life of the
  profile.
- `OrgProfileManager` stores the **document**, not the decoded profile, and re-verifies it at
  launch (`OpenGlassesApp.init`, before the settings-journey signals read anything). A document
  that no longer verifies leaves the phone unmanaged and says so on the managed row. It records the
  person's own value for each starting value it writes — once, at first enrolment, so a renewal
  cannot record the organisation's earlier value as the person's — and whether the licence in
  `LicenseService`'s slot is the one it brought, so removal never clears a code somebody typed.
  Another organisation's profile is refused until the first is removed; the same `profileId`
  renews in place.
- `OrgEnrolmentService` is the link: `openglasses://enrol?url=https://…`, **HTTPS only** (the
  sideload's LAN-HTTP allowance was dropped — an organisation profile has no developer loop to
  serve), no `sig` parameter (the signature is inside the document), an offer naming the host
  before any fetch, a 64 KB `BoundedHTTPClient.Profile.orgProfile`, then the review sheet: who it
  is from, what it locks, what it sets, what it supplies, and what this build could not use. A
  link that arrives during onboarding is held and offered from `completeOnboarding()`.
- The review sheet, the "Managed by ⟨org⟩" section at the top of the Settings hub (enrolment date,
  policy end, enrolment id), removal behind `OwnerGateAuth.authenticate` — fail-open like the
  Simple Mode gate, because a phone without a passcode that could never be un-managed is the trap
  this plan names — and a "Set by ⟨org⟩" note under each locked switch (privacy blur, the three
  remote-invoke switches, agentic features, the MCP server). The Discover footer changes on a
  managed phone.
- On `.orgPolicyDidChange`, `AppState` re-reads the live privacy filter and stops what the policy
  switched off: the agent scheduler, the Hermes bridge and the web HUD mirror when agent mode goes,
  the MCP server when either of its two switches does.
- **Watch check:** nothing under `OpenGlassesWatch` reads any of the sixteen keys; the watch reaches
  them only through the phone. Propagation stays with Plan CS.
- **Owed, and recorded here rather than done:** the stored document sits under `DataStoreRegistry`'s
  generic `.preferences` store. It carries the organisation's report recipients and a licence code,
  so it wants its own registry case; that lands with PR 4's owner axis, which reworks the registry
  for the organisation's data anyway.

**PR 2a merged 2026-09-24 ([#549](https://github.com/straff2002/OpenGlasses/pull/549)),** green on its
first CI run, all 26 new tests passing.

**PR 2b as built (2026-09-24) — the lease.**

- `ProfileLease` (`OrgProfile/ProfileLease.swift`) is the pure decision: `status(leaseDays:
  lastRenewed:policyExpiry:clockHighWater:revoked:now:)` answers *live*, *renew soon* (inside 14
  days), *lapsed* (the lease or the organisation's own `policyExpiry`, whichever ends first), *clock
  wound back* (more than a day behind the latest time the app has seen) or *revoked*. `Lock` is the
  mid-job grace: grace is granted once, at the moment a lapse is first seen, to the job running
  then, and to no job started afterwards.
- **How content locks: the licence is withheld, nothing is deleted.** When the lease is not in force
  and no job holds the lock off, `PolicyEnvelope.withheldLicenceCode` is the licence the profile
  brought, and `LiveFieldAssistEntitlementProvider` skips exactly that code. The organisation's pack
  and the vaults its licence unlocks then lock through the gates that already exist; the person's
  own purchases are untouched; a renewal puts it back. Only a licence the profile itself activated
  is ever withheld.
- **Renewal.** The enrolment record now keeps the profile's URL (optional fields throughout, so a
  2a record still reads — though one made by 2a has no URL and renews only by opening the link
  again). `OrgProfileManager.renewIfDue` re-fetches it at launch and on every foreground, at most
  once a day unless the person taps *Check for Renewal*. A verified copy of the same profile renews:
  the lease restarts, the new ceilings apply, a new licence is activated, and only starting values
  never written before are written, so the person's own changes stand. The job observer re-evaluates
  the lease as jobs start and end.
- **Only a signed answer changes anything.** A failed fetch, a timeout, a server error or a 404
  only fails to renew. A signed revocation document for this profile, or this enrolment's id in the
  profile's `revokedEnrolmentIds`, revokes: the rules lift (the envelope clears) and the content
  stays locked. Erasing it, after delivering session logs and unsent reports to the firm, is PR 4.
- The managed row says where the lease stands — the renew-by date inside the warning window, the
  lapse and whether a job is holding the lock off, a wound-back clock, a revocation — with a *Check
  for Renewal* button whenever there is something to renew.
- **Still owed from the plan's lease design:** the warning on the Field Assist screen itself (the
  managed row carries it for now), and `eraseAfterLapseDays`, which is an erasure and so PR 4's.

### PR 3 — the scanner, the first-run branch, and enrolment

P2's scanner view as the second `ProfileIngress`, and P3's first-run branch and enrolment sequence,
as written: through `WearablesBootstrap`, `hasCompletedOnboarding` set explicitly, and the five
enrolment steps in their load-bearing order — verify, activate the licence, install the pack through
`VaultPackCatalogService`, write settings and raise the ceiling, then sync documents — with steps 3
and 5 allowed to be pending, retried and named. This is where `fieldAssistDefaultVaultId` stops
being validated against the installed set and starts being written after the install succeeds.

**Numbering, reconciled (2026-09-24).** Two things were built under the labels "3a" and "3b"
before the evening re-cut above was read. They are relabelled here so the re-cut's 3a, 3b and 3c keep
their meaning:

- **Scanner (3c, early)** — [#553](https://github.com/straff2002/OpenGlasses/pull/553), merged. A
  general in-app scanner and scanning of the enrol link or a bare profile address. The re-cut's 3b
  scopes a scanner to the admin card and 3c reuses it for keys, so both reuse this one
  (`OrgCodeScannerView`) instead of building their own. 3c's remainder is reading a licence key or an
  activation key into the same field. The welcome page's *My organisation gave me a code* joins the
  re-cut 3a's *I have a licence key from my company* when that lands, as the scan beside the typed
  key.
- **Pack at enrolment (3d)** — [#555](https://github.com/straff2002/OpenGlasses/pull/555). Enrolment
  step 3 from P3 (install the named pack before the default vault is written), which the re-cut table
  left out. It applies to every enrolment path, the licence key included.

Next, per the re-cut, is **3a** (the activation key and the first-run licence branch), then **3b**
(the Field Assist edition and the administrator passcode and card). Both come before PR 4, because
they are what the demo needs.

**Scanner (3c, early) as built (2026-09-24, [#553](https://github.com/straff2002/OpenGlasses/pull/553)).**

- `OrgCodeScannerView` — `AVCaptureSession` + `AVCaptureMetadataOutput` for QR, torch toggle,
  camera-permission and no-camera states. It reads one code, stops the camera, and hands the text
  back; it never fetches, verifies or applies anything.
- `OrgEnrolmentService.openScanned` accepts either the `openglasses://enrol?url=…` link or the
  profile's bare `https://` address — so an organisation can print whichever it likes, and the
  iPhone Camera app still works for the link form — through the same HTTPS-only policy, and records
  the enrolment as `.scan`.
- **The first-run branch is simpler than the plan feared.** The welcome page gains *My
  organisation gave me a code*; the review sheet appears over onboarding, and once applied the
  welcome page says *Managed by ⟨org⟩ — next, choose the AI provider your organisation uses* and
  onboarding carries on normally. It does not skip the provider and key pages, because a profile
  never carries a key (P4's credential half is what would let it). And it needs no special
  onboarding-flag handling: Plan CD P1's hazard is a write that makes `hasAnyAPIKey` true before
  onboarding finishes, and applying a profile writes no key and no onboarding flag — a test pins
  that no `SettingKey` is an onboarding flag, beside the existing secret-disjointness test.
  `hasCompletedOnboarding` is still set only by onboarding's own completion. A **link** arriving
  from outside during onboarding is still held (it was not asked for); a **scan** from the welcome
  page is not.
- Field Assist settings gain *Scan an Organisation Code* on an unmanaged phone.

**Pack at enrolment (3d) as built (2026-09-24).**

- `OrgPackInstaller` is step 3: it loads the signed catalog, finds the entry the profile's
  `vaultPack.packId` names and runs it through `VaultPackCatalogService.install` — download,
  checksum, pack signature, structural checks, `VaultImporter` — returning at once if that pack is
  already on the phone. A pack the catalog does not list is a failure with a reason; the profile
  carries an id, never bytes, so there is nowhere else to install it from.
- **The order is the plan's.** A profile naming a pack applies its ceiling, its licence and every
  starting value *except* the default vault and the Field Assist switch, which are held on the
  enrolment record until the pack lands; then they are written. The default vault is written only if
  a vault with that id now resolves, so a pack that turns out to provide a different vault leaves
  the default where it was instead of pointing it at nothing. The review counts the profile's
  default vault as resolvable when a pack is named, so it is not reported as dropped.
- **Pending, retried and named.** The install starts as soon as the review is confirmed and does not
  hold the sheet; a failure is recorded, shown on the managed row ("Couldn't install … It tries
  again each time the app opens"), and retried from the same launch-and-foreground path as renewal.
- **Still owed:** a renewed profile that names a *different* pack (a renewal today installs nothing
  new). Step 5, the organisation's own manuals, is now Plan FT's (FT4): they come from the base
  server, not a profile pointer.

**3a, first slice as built (2026-09-24) — enrolment by licence key.** The re-cut's 3a is shipping
in three slices: this one; the short activation key and its sealed file on the static host; and the
first-run branch with the offline holding screen and the `aiModel` key page.

- `LicensePayload` gains the optional signed `profile` claim, and `generate-field-license.swift`
  takes `--profile https://…`, refusing anything but an HTTPS address with no credentials or
  fragment. Older builds decode such a code as a plain licence.
- `OrgEnrolmentService.openLicence` is the entry point. A key with no `profile` claim returns
  `.plain` and activates exactly as before. A key with one fetches the profile with **no host
  offer**, because the vendor signed the address. The sheet shows *Setting up this phone for
  ⟨licensee⟩*, and the rest is the link's path: bounded fetch, verification, review, one
  confirmation. An address the link policy refuses is refused. Offline, the sheet says setting up
  needs the internet once. Licence entry in Field Assist settings goes through it first.
- **Same organisation, later licence.** When the profile carries its own licence code, its
  licensee must equal the entered key's, or the review refuses naming both. The later-issued of the
  two is activated. A profile without a licence activates the entered key. The enrolment records
  `ProfileSource.licence` and `activatedLicenceCode`, so lease withholding and removal act on the
  licence actually activated. Removal clears it: the key was the organisation's.
- **A fix found on the way:** PR 2b's renewal rebuilt the enrolment record from scratch and copied
  only the lease fields, so a renewal would have dropped the pack still pending. That fix went into
  3d ([#555](https://github.com/straff2002/OpenGlasses/pull/555)), where the pending pack was
  introduced: renewal now updates the record in place and leaves held values unwritten. This slice
  adds that a renewal bringing a newer licence of the profile's own clears `activatedLicenceCode`.

**3a, second slice as built (2026-09-24) — the short activation key.**

- **Format.** `ActivationKey` reads what was typed. It takes any case, and ignores dashes and
  spaces. It reads `O` as `0` and `I`/`L` as `1`. Anything longer than 24 characters, or with a
  character outside the alphabet (a `.`, say), is *not a key* and goes to the licence path untouched.
  So the one field takes either the key or the long code.
- **The check character.** It is Σ αⁱ·vᵢ over GF(32) with the polynomial x⁵ + x² + 1, and the
  weights are distinct non-zero elements. So *every* single wrong character and *every* swap of two
  different neighbours is caught, not 31 times in 32. The tests enumerate both.
  - A typo, a `U` or the wrong length is refused before anything is fetched: *"Check the key — one
    character looks wrong"*, or *"An activation key is 16 characters — that one has N."*
- **Derivations.** "Key" means the sixteen canonical characters (upper case, no dashes, aliases
  mapped).
  - **The file name** is hex(SHA-256(`"openglasses.activation-id.v1\n"` + key)).
  - **The file** is base64 of AES-GCM's combined nonce ‖ ciphertext ‖ tag, under HKDF-SHA256(key,
    no salt, info `"openglasses.activation-key.v1"`, 32 bytes).
  - The tests pin both with vectors computed independently, in Node's `crypto`.
- **Lookup.**
  - `ActivationKeyResolver` fetches `straff2002.github.io/OpenGlasses/activation/<name>` through
    `BoundedHTTPClient`'s new `activationKey` profile. The cap is 8 KB, and it takes
    `application/octet-stream` or `text/plain`.
  - **Unknown key:** a 404, or the host's HTML error page (refused by type), means *that key isn't
    recognised*. So does a file this key did not seal.
  - **No connection:** anything else says an activation key needs the internet once.
  - The licence that comes back is only a candidate. It goes on through `openLicence` and
    activation exactly as if typed, so a key whose licence names a profile enrols the phone.
- **Where it's entered.** `OrgEnrolmentService.resolveEntry` is the one entry point, and Field
  Assist settings' licence field ("Activation key or licence code") uses it. The first-run branch
  (the third slice) will too.
- **Issuance.**
  - `generate-field-license.swift --activation-key [--activation-dir DIR]` mints the key alongside
    the code. It prints the key once on stdout, and writes `DIR/<name>` (default `./activation`,
    refusing to overwrite).
  - `Scripts/stage-pages-site.sh` publishes `activation/` when it exists, and its gate refuses any
    path there that is not a 64-character hex name.
  - Deleting a file stops new activations with that key.
- **Not in this slice:** a keyboard showing only the alphabet and inserting the dashes. That lands
  with the first-run page, which is where a technician types the key.

**3a, third slice as built (2026-09-25) — the organisation's AI model.** The remaining 3a work is
split in two. This part is the model; the next is the first-run screens.

- **The profile field.** `ConfigProfile.aiModel` is `{provider, model, baseURL?, name?}`, and it is
  decoded without failing: a malformed entry reads as empty fields.
  - `OrgAIModel.resolve` checks it. The provider must be an `LLMProvider` raw value. `baseURL` is
    allowed only for `custom` (where it is required) and `openrouter`, and must be HTTPS with no
    credentials.
  - Each failure is a drop keyed `aiModel`, and the phone behaves as if the profile named no model.
  - `ProfileApplier.Result.aiModel` carries the checked model. The managed layer wins, as for
    settings.
  - `make-org-profile.swift` checks the same rules from its own provider list. A test holds that
    list to `LLMProvider.allCases`.
- **The review.** *Supplies* shows *AI model: ⟨provider⟩ · ⟨model⟩*, and *Prompts go to ⟨host⟩*
  when the organisation names its own address. A footer says the key is not part of the profile.
- **The key step.** After *Apply*, a profile naming a keyed or sign-in model moves the sheet to
  `Stage.modelKey`.
  - That page takes the provider's key in a secure field. Its check is onboarding's prefix check
    (`OrgAIModel.keyProblem`). There is no model list to fetch, because the model is the profile's.
  - `chatgpt` uses the existing `OnboardingAccountSignInSection`, and `geminiVertex` uses
    `GoogleSignInRows`. On-device providers need nothing, and their config is made at apply.
  - `OrgProfileManager.completeModelSetup` builds the `ModelConfig` (provider, model and address
    from the profile, key from the field), saves it through `Config.setSavedModels` (the Keychain),
    and makes it active. It records `modelConfigId`.
  - *My administrator will add this* leaves `modelSetupPending` set. Field Assist then says *Your
    administrator needs to finish setting up this phone*, and the managed row offers *Finish Setup*.
    3b puts that behind the administrator passcode.
- **Renewal.**
  - **Same provider:** the model, address and label follow the profile, and the key stays.
  - **New provider:** pending again. The old config stays active until the new key is in, and then
    it is replaced.
  - **No model named any more:** changes nothing.
- **Removal** deletes the config enrolment made, key included. If it was active, the first
  remaining config becomes active. The person's own configs are untouched.

**3a, fourth slice as built (2026-09-25) — the first-run branch.**

- **The welcome page.** *My organisation gave me a code* becomes **My company gave me a key or
  code**. The footer keeps the same number of buttons.
- **`OrgKeyEntrySheet`** has one field for the activation key or a full licence code.
  - `OrgFirstRun.formatKeyEntry` upper-cases an attempt at a key and groups it in fours as it is
    typed. A pasted code is left exactly as it is.
  - *Scan a code instead* reuses `OrgCodeScannerView`. An enrolment link or profile address goes to
    the link's path, and anything else is looked up as if typed.
  - `resolveEntry` runs before the sheet closes. What it resolves to is acted on only in `onDismiss`,
    so the review sheet never presents over it.
- **A licence naming a profile** is activated at once, since it verifies offline. Onboarding then
  holds on **Setting up for ⟨licensee⟩**:
  - The holding page is shown whenever `OrgFirstRun.holdingLicensee` is non-nil: the active licence
    carries a `profile` claim, and no profile is in force. So a relaunch comes back to it rather
    than to the general app.
  - `OrgSetupStatus` follows the enrolment stage. Offline it says to connect once and try again.
  - *Try Again* re-opens the stored licence. *Use a different key* clears it.
  - There is no *Skip setup* on this page.
- **A plain licence** activates as it always has, and says so on the welcome page.
- **Once the profile is in force.** When it names the AI model, *Get Started* skips the provider and
  key pages (`OrgFirstRun.pageAfterWelcome`), and Back from the services page returns to the
  welcome page. The key was entered, or left for the administrator, on the review sheet's key step
  from the previous slice.
- **Completion.** Onboarding still finishes through its one `completeOnboarding`, which writes
  `hasCompletedOnboarding` and runs `WearablesBootstrap`. The branch adds no second way out. Saving
  the organisation's key mid-onboarding is the same write onboarding's own key page makes; CD P1's
  predicates already cover it (`WearablesBootstrapTests`).

**3b, first slice as built (2026-09-25) — the edition and the administrator gate, underneath.** 3b
ships in three slices, with this one first:

1. the profile fields and the gate;
2. the technician's Field Assist view, with *Finish Setup* behind the gate;
3. the administrator phone.

- **Profile fields.** `ConfigProfile` gains `edition` (`"fieldAssist"`), `adminPasscode`
  (`{salt, iterations, hash}`, decoded without failing) and `adminCard` (hex digest).
  - `ProfileApplier.Result.adminPolicy` carries the checked edition and its `AdminCredentials`.
  - **Named drops:** an unknown edition; a verifier with a salt under 16 bytes, a hash that is not 32
    bytes, or iterations outside 10 000–5 000 000; a card that is not 64 hex characters; a
    passcode or card with no edition.
  - With the edition but no usable credential, the method is `.deviceOwner`.
  - The review gains *What this phone shows*. It names the edition and how administrator settings
    open, including *Anyone who can unlock this phone can open administrator settings*.
  - `OrgProfileManager.adminPolicy` is nil on a revoked phone, which also lifts the edition.
- **`AdminSecrets`.**
  - PBKDF2-HMAC-SHA256 through CommonCrypto's `CCKeyDerivationPBKDF`.
  - The card digest is SHA-256(`"openglasses.admin-card.v1\n"` + secret).
  - A scanned card reads as `og-admin:` followed by 26 Crockford characters (130 bits).
  - Comparison is constant-time.
  - Vectors: RFC-style PBKDF2 plus a Node-computed passcode and card, which pin the script.
- **`AdminGate`** (`shared`, with seams).
  - `tryPasscode`, `tryCard`, and `deviceOwnerPassed` (only when neither credential was issued).
  - **Backoff, persisted as two scalars:** five free attempts, then 30 s doubling to an hour. A
    wrong card counts like a wrong passcode. Nothing is checked during a wait. Text that is not a
    card is not an attempt.
  - **The session** ends on background (wired in the app's scene-phase handler) or after ten idle
    minutes. `noteActivity` restarts the clock. `isRestricted` is read-only, so a view can ask it
    without publishing.
- **`make-org-profile.swift`.**
  - `admin-card <card.png>` makes a 26-character secret, renders it with `CIQRCodeGenerator` into
    the PNG only, and prints the digest for the organisation's input JSON.
  - `make … --admin-passcode` prompts twice with echo off (`getpass`) and refuses fewer than eight
    characters or all digits. It carries a 210 000-iteration verifier with a fresh 16-byte salt.
  - `edition` and `adminCard` are input fields.
- **Not yet:** the view the edition hides behind (the next slice), and VoiceOver announcing a wait,
  which lands with that view.

**3b, second slice as built (2026-09-25) — the technician's view.** `EditionPresentation` holds the
drawing rules as pure functions. The views read `AdminGate.shared.isRestricted`, which is true when
an edition is in force and no administrator session is open.

- **Tabs.**
  - `MainView` drops Modes and Chat (`hiddenTabs`), so the bar is Voice, Job, Settings.
  - The edition implies Field Assist for the Job rule (`featureEnabled || restricted`) without
    writing the switch.
  - A session ending, or a request for a hidden tab (the Job tab's *Open conversation*), falls back
    to Voice (`EditionPresentation.tab`).
  - A 30 s tick calls `AdminGate.refresh()`, so an idled-out session closes on screen.
- **Settings.**
  - The rows are the kept list: Accessibility (pinned, so it can never be withheld), Glasses &
    Privacy, and Diagnostics & Support. A **Language** row appears, because Language otherwise lives
    inside Look & Feel. The managed row and About stay.
  - Discover, *Show everything* and the Simple Mode section are hidden.
  - A category added to the app later is hidden from technicians by default, because the list is the
    inverted form.
- **Administrator Settings** (`OrgAdministratorSection`, `AdminUnlockSheet`).
  - It unlocks with the card, scanned in the app, or the passcode. Only when neither was issued, it
    uses the device owner through `OwnerGateAuth.authorize`, which fails closed.
  - Every refusal and wait is shown and spoken through `SessionAnnouncer`.
  - While a session is open, a banner says how it ends and offers *End Administrator Session*.
  - The managed row's *Finish Setup* (the organisation's AI key) appears only outside the
    technician's view.
- **Voice tab.** The dock's Model tile is hidden, because the organisation chose the model. The
  persona switcher on this tab was already unused; the real ones go with the Modes and Chat tabs.
- **Not yet:**
  - the dock's edit page;
  - moving *Remove Profile* one level down;
  - a UI-test launch flag for the edition;
  - the administrator phone (the third slice).

**3b, third slice as built (2026-09-25) — the administrator phone.**

- **Making one.** *Administrator Settings* gains *Make this an administrator phone* beside *Scan the
  Admin Card*.
  - On an accepted scan with it on, `AdminGate.tryCard(_:remember:)` keeps the card's secret in the
    Keychain (`KeychainService`, `…AfterFirstUnlockThisDeviceOnly`, key `orgAdminCardSecret`). It is
    read once per launch, not on every redraw.
  - A passcode never makes an administrator phone, and neither does a wrong card.
- **What it shows.** `isAdministratorPhone` holds while the kept secret matches the profile's
  current card digest. `isRestricted` is false then, whatever the session, and backgrounding does
  not lock it.
  - Settings shows an **Administrator Phone** section in place of the locked row, so it is never
    mistaken for a technician's.
- **Rotation.** A renewal carrying a new card digest makes `keptCardIsStale` true. The phone drops to
  the technician's view, and the locked row's footer asks for the new card.
- **Show Admin Card.**
  - It sits behind `OwnerGateAuth.authorize`, failing closed. The card is the organisation's key to
    every technician's phone.
  - `AdminCardDisplay` renders the QR full screen with `CIQRCodeGenerator`. It hides after 30 s, and
    whenever the scene leaves `.active`. *Show Again* brings it back.
  - A replaced card is never shown (`cardToShow`).
  - This is the one place the app renders a code. Plan FS decision 2 (the app never renders a vault
    link) is enforced by `VaultLinkNoShareTests`. That test now names `AdminGateViews.swift` as the
    single allowed renderer, and holds it to never touching a vault link or archive.
- **Stopping.** *Stop Being an Administrator Phone* deletes the kept secret, after a confirmation.
  **Removal and revocation also forget it** (`OrgProfileManager.Seams.forgetAdminCard`), so a phone
  handed on and re-enrolled is not quietly an administrator phone again.

**PR 4, first slice as built (2026-09-25) — deliver, then erase.**

**Delivery, decided 2026-09-25.** Only the firm's endpoint delivers unattended, and a record counts
as delivered only once the endpoint has *accepted* it. When the device owner removes the profile,
they are first offered the waiting report sends and an export of the session logs for the firm.
That prompt is the next slice. Anything undelivered stays and is erased after the window. Full logs
and photos reach the firm unattended once Plan FT's base server exists.

- **`OrgDepartureService`.** Revocation (`markRevoked`) and removal (`remove`) both call it, through
  the manager's `beginDeparture` seam. Removal is treated exactly as revocation.
  - The default seam does nothing, so no test inherits an erasure. `OrgProfileManager.shared` uses
    `Seams.production`, which wires it.
  - It keeps an `OrgDeparture` (UserDefaults `orgDeparture`) apart from the enrolment record, which
    removal deletes. The record holds the organisation, the enrolment id, the reason, the session
    ids owed, and `eraseBy`.
  - `eraseBy` is `undeliveredEraseDays`, 30 by default, held to 1–365.
  - Leaving twice for the same enrolment changes nothing, so a revoked phone its owner then removes
    keeps the first window.
- **At once** (`eraseContent`): the vault the profile's pack installed (found by the pack sidecar's
  id), the jobs ahead, and the staged field-session exports.
- **Delivered, then erased** (`settle`, run at the start, at launch and on every foreground):
  - With an endpoint configured, the sync engine is flushed. Delivery holds only when no work record
    for the owed sessions is still outstanding (`QueuedRecordRows.outstandingCount`).
  - Without an endpoint, nothing counts as delivered, because the local sink marks records done with
    nothing leaving the phone. Only the window decides.
  - Nothing is erased while a job is open, not even past the window.
  - `eraseRecords` deletes the owed session logs (new `FieldSessionService.deleteSessions(ids:)`,
    never the session in progress), the report queue, the owed sessions' queued work records, and
    the delivery settings and endpoint token (new `DeliverySettings.clearStored()`).
  - The departure records `deliveredToFirm`, so an erasure that ran out the window says so.
- **Settings.** The managed row, once the profile is gone, says the phone has left ⟨org⟩, and that
  its records from that time go there when it can reach it and are erased by ⟨date⟩ either way.
- **Registry.** `SensitiveStore.orgEnrolment` now registers the enrolment record and the departure.
  It was an unregistered gap, because its codec lives in `ProfileVerification`. The matrix row is
  added.
- **The removal prompt** (second slice). *Remove Profile* on a phone that still holds the firm's
  records opens a step first, inline on the managed row so the send composers (hosted by `MainView`)
  can present:
  - *Send N Waiting Reports* (`JobSendService.sendAll`);
  - *Share Job Records for ⟨org⟩*, each managed session's export in one share sheet, taken while the
    licence is still in force;
  - *Remove Profile Now*;
  - *Not Now*.

  It offers and never forces. Whatever is not sent goes to the endpoint if there is one, and to the
  window either way. `OrgDepartureService.managedSessionIds` is the one rule for which logs are the
  firm's, shared with the departure.
- **`eraseAfterLapseDays` (4c).** The organisation's opt-in, which needs no network.
  - `evaluateLease` starts a departure with the new reason `.lapsed` once the lease has been lapsed
    for that many days (1–365, or else ignored). It runs only while the content is locked, so never
    mid-job, and only once (`lapseErasedAt`).
  - The firm's content goes at once. Its records follow the same deliver-then-erase path.
  - The profile's rules stay, because a lapse is not a revocation. The pack is marked pending, and
    the pending-pack pass leaves it alone while lapse-erased.
  - A renewal heard afterwards clears `lapseErasedAt`, reinstalls the pack straight away, and
    `cancelLapse` ends the lapse departure. Records it still owed are the firm's again and are kept.
    A revocation or removal is never undone this way.
  - The managed row warns when erasure is due, and says so once it has happened.
- **Not yet:**
  - sealing under a per-enrolment `ScopedKeyring` class, so erasure is `.cryptographic` (PR 4b);
  - the registry's wearer/organisation axis (`owner` already names the owning type, so it will be
    a new field, e.g. `custodian`);
  - enterprise vaults imported while managed, which carry no marker yet.

### PR 4 — leaving the firm: lease, revocation, and erasure

Decided 2026-09-24. The case is an engineer who leaves the firm and keeps the phone with the app on
it. **Nothing about that phone is frozen or bricked** — it stops being the firm's phone and remains
an ordinary copy of the app. Three things are handled separately, because they want different
answers:

| | Lease lapses (no renewal heard) | Revoked, or removed by the device owner |
|---|---|---|
| **The organisation's rules** (the ceilings) | stay as they were, with a visible "management expired" state | lifted with the profile |
| **The organisation's content** (below) | **locked** — unreadable in the app, intact on disk, and back the moment a renewal is heard | **delivered, then erased** |
| **The person's own data and the app itself** | untouched | untouched |

**The lease.** A profile carries `leaseDays`, set by the organisation when the profile is minted and
bounded by the app to **7–365 days** so a typo is neither a one-day lease nor no expiry at all. The
lease runs from the last successful, verified fetch of the profile's URL, and any fetch renews it —
a single small download, so a day in town, a satellite window or a hotel's Wi-Fi renews the whole
lease silently. Different crews get different leases by getting different profiles: a profile
belongs to a link, not to the organisation, so an office team on 30 days and a remote crew on 180
are two links from the same script. What the organisation is choosing is the longest a leaver who
stays offline keeps access, per crew.

- **A warning before it lapses.** From 14 days out, the managed row and the Field Assist screen say
  "Connect to renew by ⟨date⟩", so an engineer heading out of contact can plan for it.
- **Never mid-job.** A lease that lapses during an active Field Assist session or an open job locks
  when that job closes. Losing the manual halfway through a repair is worse than a few hours' grace.
- **Lapse locks; it never erases by default.** An engineer 45 days out on a 30-day lease loses the
  firm's content until they have signal; the next fetch renews and everything returns as it was.
  Erasure after a lapse heard *offline* is an organisation opt-in (`eraseAfterLapseDays`, absent by
  default), because a genuine remote worker should not lose their manuals for having been somewhere
  without signal.
- **The lock is the envelope's, not the licence's.** The licence code inside the profile has its
  own signed, typically annual, expiry, and a lapsed lease must lock the firm's content even while
  that licence is still valid. So content gating — `VaultRegistry.isUnlocked` for the firm's pack and
  vaults, and the stores below — asks the envelope whether the lease is live, in addition to the
  entitlement it already asks.
- **The clock is not trusted to go backwards.** The envelope keeps a high-water mark of the latest
  time it has seen; a device clock more than a day behind it counts as lapsed. Without that, winding
  the clock back is a lease that never ends.

**Revocation is explicit and per enrolment.** A fetch that fails — no network, a timeout, a server
error, a 404 from a host migration somebody got wrong — **only fails to renew**. It never erases,
because an unsigned HTTP status is not a decision anyone made, and treating it as one would let a
misconfigured web server wipe a fleet. Revocation is a **signed revocation document** at the
profile's URL, minted with the profile key by the same script (`make-org-profile --revoke`). Two
granularities, one format:

- **The whole link** — every phone enrolled from it hears the revocation on its next fetch.
- **One enrolment** — each enrolment generates a random id, shown on the managed row and recorded
  by the script when it mints a per-person link. The hosted document carries a signed list of
  revoked enrolment ids; the named phone erases and the rest of the crew renews as normal. This is
  the leaver case on a shared crew link, and it needs nothing but a static file — the same hosting
  the profile already uses.

**Removal by the device owner is treated exactly as revocation.** An engineer who removes the profile
on the way out gets the same deliver-then-erase as one whose firm revoked it. Otherwise removal would
be the way to keep the firm's manuals, and the licence code the profile carried is cleared from
`LicenseService.storageKey` either way.

**What counts as the firm's.** `DataStoreRegistry` already inventories every store, and it gains an
owner axis — the wearer or the enrolled organisation — so erasure is a query, not a list somebody
maintains by hand. The organisation's, while a profile is applied:

- the pack enrolment installed, and its documents tier (`vaultDocuments`), and any enterprise vaults
  imported while managed
- `upcomingJobs` and the `.ogjob` files behind them
- `jobDeliveryQueue` and `fieldDeliverySettings`
- `fieldSessionLogs`, and the job photos, clips and work records attached to the firm's jobs
- the profile-owned values: the organisation's name, job-signing key, report route and recipients

**Session logs and unsent reports go to the firm first.** Decided 2026-09-24: on revocation or
removal, `fieldSessionLogs` and every report still waiting in `jobDeliveryQueue` are delivered over
the report route the profile set (`organizationJobReportChannel` / `organizationReportRecipients`),
and erased once delivered. That also settles the registry's current note that a session log cannot
be deleted because it is "the engineer's compliance record": on a managed device it is the firm's
record, and it goes to the firm. Where delivery cannot complete — no route set, or no signal after a
received revocation — those two stores stay locked and are retried, and are erased regardless after
30 days (the organisation may set a different figure in the profile), with the erasure itself
recorded. The engineer cannot read them in the meantime.

**Sealing, so "erased" is true.** Today a locked pack is a row the app will not open over files that
are still on disk under ordinary platform protection, and a determined leaver with a backup has
them. `ScopedKeyring` already exists for exactly this: a class of data sealed under its own key, so
destroying the key makes every copy ciphertext — including a backup or a snapshot the app cannot
reach. It seals two classes today (conversation content and faces). PR 4 adds an organisation class
keyed per enrolment, seals the stores above under it as they are written, and revocation becomes
one key destruction reported as `.cryptographic` rather than `.logicalOnly`. An offline
`eraseAfterLapseDays` erasure is the same key destruction and needs no network.

**Honest limits, said on the managed row rather than implied away:** a photo already saved to the
camera roll, a screenshot, and a report already forwarded somewhere are outside the app and outside
any erasure. A ceiling on `recordingSaveToPhotos` narrows the first; nothing narrows the others.

**Placement.** The lease, the renewal fetch, the warning, lapse-locking, the clock high-water mark
and the signed revocation document are small and land in PR 1 (schema, script) and PR 2 (fetch,
state, locking). The owner axis, sealing and deliver-then-erase touch every store in the list above,
which is why they are a PR of their own.

### Deferred, and why

| Deferred | Why not now |
|---|---|
| **The Managed App Configuration reader**, and **SSO** | no pilot organisation needs either yet (decided 2026-09-24; the partner confirmed the same evening that both wait until a customer is ready to deploy internally). SSO is the identity axis: sign-in re-clamping and P4's credential half wait with it. When one does, it is a third `ProfileIngress` conformance over the source case, precedence layer, removal branch, re-clamp event and wire shape PR 1 and PR 2 already built and tested — about thirty lines plus its observation |
| ~~**The single-purpose edition**~~ | **Un-deferred 2026-09-24 (evening):** the pilot partner asked for it. It is now PR 3b, a named preset plus an administrator passcode. See *Revision 2026-09-24 (evening)* |
| **Re-clamp on sign-in / sign-out** | the app has no user identity (see *Identity is per-person*); the envelope is built to re-clamp on any event, and gains those two when identity arrives |
| **Watch propagation** | needs Plan CS P2's application-context channel; PR 2 checks the watch cannot route around the clamp in the meantime |
| **Hosting the organisation's documents** | still the open question it was; the pointer field exists in the schema from PR 1 so no profile needs re-minting when it lands |
| **P4** — the credential half, device verification of printed codes, the QR renderer | unchanged |

### Decisions

1. ~~**Does the pilot organisation use MDM?**~~ **Decided 2026-09-24:** start without it, and build
   the structures an MDM would integrate with — the `ProfileSource` case, the `ProfileIngress` seam,
   the layered applier, source-aware removal and the documented wire shape. The link and the scanner
   are the ingress paths that ship; the reader is deferred.
2. ~~**Profile key per customer?**~~ **Decided 2026-09-24:** one vendor profile key with a `keyId`
   for rotation; the per-customer key is the organisation's job-signing key the profile carries.
   **Still owed before PR 1 merges:** the owner generates the keypair, private half off-repo on the
   licence key's terms. Nothing can be signed for production until then.
3. ~~**Expired profile: freeze or revert?**~~ **Decided 2026-09-24,** and it turned out to be three
   questions: the organisation's *rules* stay as they were on a lapse; its *content* locks on a
   lapse and is delivered-then-erased on a revocation or an owner removal; the person's own data and
   the app are untouched. Nothing freezes the phone. See *PR 4*.
4. ~~**Can the organisation set the lease?**~~ **Decided 2026-09-24:** yes, per profile, bounded
   7–365 days; different crews get different links. A lapse never erases unless the organisation
   opted in, and never locks mid-job.
5. ~~**Session logs and unsent reports on revocation?**~~ **Decided 2026-09-24:** they go to the
   firm over its report route, then are erased; undelivered ones stay locked and retried, and are
   erased after 30 days by default.

6. ~~**MDM and SSO?**~~ **Decided 2026-09-24 (evening), by the pilot partner:** both wait until a
   customer is ready to deploy internally.
7. ~~**How does a technician's phone find its organisation?**~~ **Decided 2026-09-24 (evening):** by
   the licence key entered at first launch. The key carries a signed `profile` address, and PR 3a
   builds the path.
8. ~~**Single-purpose edition: now or later, preset or list?**~~ **Decided 2026-09-24 (evening):**
   now, as PR 3b. Visibility is a named preset (`edition: "fieldAssist"`, everything off the kept
   list hidden), while ceilings stay enumerated per key. The hidden part opens with the
   **organisation's** administrator passcode, carried as a PBKDF2 verifier. It is not the device
   passcode, which the technician knows. It lifts no ceiling.
9. ~~**Who supplies the AI provider credential, and is the passcode per organisation?**~~
   **Decided 2026-09-24 (evening):** the profile names the provider and model (`aiModel`), and the
   first-run page after the review asks for that provider's key, which is stored only on the phone.
   An administrator finishes the step behind the passcode if it is skipped. There is **one
   administrator passcode per organisation**, across all of its profiles.
---

## Traps

| Trap | Consequence |
|---|---|
| Applying settings mid-onboarding | reproduces CD P1's flag desync — onboarding never reappears, `Wearables.configure()` is never called, the app fatals on Connect |
| Arbitrary key passthrough instead of an allow-list | a scanned code becomes a write primitive for every value the app stores |
| A secret key added to `Config` and to `SettingKey` | a credential becomes photographable; the disjointness test is the only thing that catches it |
| Applying the envelope once at enrolment | someone signs in an hour later and their own configuration restores a capability the org removed — the exact case this plan exists for |
| Ceilings that stop at feature toggles | a personal API key or a self-added gateway routes around the model and egress policy entirely |
| Sign-out that clears policy, or removal that keeps it | the two are inverses; swapping them leaks the last user's data or silently unmanages the device |
| One expiry covering both policy and entitlement | a lapsed subscription unmanages the device, turning a billing event into a compliance incident |
| An inline licence in the QR rather than behind the fetch | a bearer credential on a wall — no revocation, no rotation, no binding |
| Locks that don't reach the watch | policy holds on one device and not the other, silently |
| No removal path | the device is permanently owned by whoever printed a poster |
| Inline payload instead of a pointer | the profile stops fitting, or the code stops scanning, at exactly the size a real org needs |
| Read managed config once at launch | an MDM policy change lands next launch, or never |
| A profile that writes an "entitled" flag rather than storing the code | the forgeable preference Plan DP removed, re-introduced by the one path that looks administrative rather than security-relevant |
| A profile naming a pack the licence's `packs` claim omits | an installed vault that never unlocks, and no explanation unless the row says why |
| Setting `fieldAssistDefaultVaultId` before the pack installs | the default points at a vault id the registry cannot resolve — a broken home screen on a device whose whole purpose is that screen |
| A partner-issuable enterprise tier | the registry unlocks *every* pack at enterprise, so one delegated grant voids per-partner pack accounting |
| Blocking enrolment on the pack download | a depot with poor signal leaves the device unbounded, which is the half that must never wait |
| Ceilings that stop at Settings and leave the tabs alone | the Modes tab still presents a grid of one and Discover still pitches what the ceiling removed — the app reads as broken rather than purposeful |
| Withholding the assistive surface, or the fingerspelling family inside it | an organisation takes a sign-language reader off the device of the person holding it; this plan's own first cut made that mistake |
| Clamping on write instead of on read | the ceiling overwrites the person's own value, removal has nothing to restore, and any setter that runs after enrolment quietly widens the device again |
| Trusting the cached profile because it was verified once | a tampered cache becomes policy; the envelope re-verifies on load, and a getter never reads an unverified profile |
| Accepting raw settings from managed app config beside the signed profile | two trust paths with two sets of rules, one of them unsigned; the managed dictionary carries the same signed profile |
| Treating a failed fetch or a 404 as a revocation | a network outage or a botched host migration erases a fleet's manuals; only a signed revocation document erases |
| Revoking only by link | a leaver on a shared crew link cannot be cut off without cutting off the crew; revocation names enrolment ids |
| Letting owner removal skip the erasure | removing the profile becomes the way to keep the firm's manuals and job history |
| Locking on the licence's clock instead of the lease | a leaver keeps the firm's content until the annual licence runs out |
| Erasing on an offline lapse by default | a remote engineer loses the manuals for having been out of signal |
| Trusting the device clock for the lease | winding the clock back is a lease that never ends |
| Calling a lock "erased" | the files are still on disk and in a backup; only a destroyed scoped key makes a copy unreadable |
| Building the link and scanner paths as if they were the only ingress | the MDM reader, when a customer needs it, arrives as a second verify-and-apply path and a retrofit of removal and precedence instead of one adapter; the source case, the layered applier and the ingress seam exist from PR 1 for that reason |
| A `SettingKey` with no declared direction | an organisation can pin the privacy filter off or turn a refusal back into an allowance; the direction is part of the case, not a comment |
| Leaving the FO/FS stand-ins as free-standing `UserDefaults` keys after CT lands | two writers for one policy — the profile and whatever last touched the key — and the stand-in comments go on promising a replacement that already happened |

---

## Open questions

- **How much of `Config` is org-settable, eventually?** The first cut above is deliberate and small.
  The full audit is a judgement call per setting, not a technical problem, and it does not block P1.
- ~~Should a profile be able to require a pack?~~ **Resolved for vault packs:** yes, and enrolment
  installs it — the profile names the pack, the enrolment screen presents it as part of the same human
  confirmation so one decision covers the profile and the install, and the pack itself is checksummed
  and signature-checked on the way in. **Unchanged for skill packs:** a skill pack adds *behaviour*,
  which is a different trust decision from adding a reference vault, and Plan BX's line stands until
  somebody argues it down on its own merits.
- ~~**Should "Field Assist only" be a named preset rather than a subtraction list?**~~ The table above is
  long, and every capability added to the app afterwards defaults to *present* unless somebody
  remembers to ceiling it — the wrong default for a single-purpose edition and the right one for a
  museum. A disposition that inverts it (nothing but the named feature and the kept list) is more
  robust and much blunter. Leaning: ship the enumerated ceiling first, because it is testable per key,
  and revisit the inverted form when a second partner asks for a second edition.
  **Resolved 2026-09-24 (evening), by the first real request:** both, for different jobs.
  *Visibility* is the inverted, named preset, so a feature added later stays hidden from a technician
  unless someone adds it to the kept list. *Capability* stays the enumerated, per-key ceiling. See
  *Hidden is not forbidden*.
- ~~Where do an organisation's manuals actually come from?~~ **Decided 2026-09-24: from the
  organisation's base server** (Plan [FT](FT-organisation-administration.md), *The organisation's
  manuals*). The overlay carries a signed manual set, and the phone fetches each file from
  `baseServer` with a signed request and a hash check into the pack's documents tier. The vendor holds
  nothing, and licensed OEM manuals never sit at a public address. `vaultPack.documentsSource` is
  withdrawn. Without a server, manuals are loaded by hand through Custom Vaults, as today.
- ~~Does an expired profile revert or freeze?~~ **Decided 2026-09-24:** the rules freeze, the
  organisation's content locks, and a revocation delivers then erases that content — see *PR 4 —
  leaving the firm*.
- ~~Does the pilot organisation use MDM?~~ **Decided 2026-09-24:** start without the reader and
  build the seam it plugs into — see *Delivery order → Decisions*.
- ~~Does org membership carry entitlement?~~ **Resolved:** entitlement rides the profile, device-scoped
  and org-purchased — see *Entitlement rides the profile* above.
- ~~Which tiers may an org grant?~~ **Resolved 2026-08-09.** Two grantable, one not:
  - **Field Assist** — already works this way; nothing changes but the ergonomics. Tiers are real
    now (solo / team / enterprise, Plan EE), so the grant is specifically a **team** code with a
    `packs` claim, and **enterprise is never delegable to a partner** — see *Entitlement rides the
    profile* above.
  - **Medical Compliance** — grantable as an org site licence. This is the coherent shape anyway: a
    ward buys the tier *and* pins HIPAA mode as a ceiling, and those are the same purchase rather than
    a licence plus a separate configuration step someone has to remember.
  - **Accessibility** — not grantable, because there is nothing to grant. It is free (Plan A), and a
    profile must never be able to *withhold* it either: accessibility settings are excluded from
    `SettingKey` in the ceiling direction, so no org policy can take assistive features away from the
    person holding the device.

  What remains is a price, not a decision: a Medical Compliance fleet licence has to mirror or
  deliberately depart from the per-region IAP pricing, and that is a sales question, not a schema one.
- ~~Should the profile be able to set HIPAA mode?~~ **Resolved above, affirmatively:** yes,
  `.ceiling`-only (pin it on, never off) — a Medical Compliance site licence and a pinned HIPAA mode
  are the same purchase (see *Which tiers may an org grant?*). It is still the most consequential
  toggle in the app, so it still wants its own review before shipping, but the direction is settled.
