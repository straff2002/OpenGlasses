# Plan ND — Company Settings from the Portal (the administrator sets them once, every phone that joins follows)

**Status:** 📝 Drafted 2026-11-24; nothing built; 15 [decisions](#decisions-for-greig) with recommendations.
**Track:** Field Assist — fleet. The organisation profile, the licence portal, onboarding, Managed App
Configuration.
**Builds on:** Plan [CT](CT-org-configuration-profiles.md) (the signed profile, `SettingKey` and its directions,
the layered `ProfileApplier`, the daily renewal, the `ProfileIngress` seam and the `.managedConfig` source it
built for a reader it deferred), Plan [JS](JS-licence-sales-and-device-seats.md) (one customer, one profile, one
key for life; partner configuration through vendor presets; every change re-signs the profile; device seats),
Plan [LR](LR-company-vaults-from-the-portal.md) (the portal-to-phone path: a change in the portal raises a
generation, the phone picks it up on its next pass, never mid-job), Plan [LS](LS-activation-keys-that-work-at-once.md)
(the key works the moment it is handed over), Plan [HA](HA-settings-hub-and-org-lockdown.md) (locked is hidden
from the technician; only the organisation's credential opens the administrator view).
**Sits beside:** Plan [FT](FT-organisation-administration.md) and the Avenkin Office plans (a firm that runs its
own office binds phones there; nothing here changes that path).
**Service side:** the portal and the signer live in the private service repository. This plan carries only the
contract the phone reads and the rules an edit must pass, with a one-line outline of each service step.

---

## Trigger

The sales partner, 2026-11-24: the main customers will be companies, and their administrators will want to
manage settings across their employees' phones from one back-office portal. That also makes onboarding and
support easier: a support call that starts "go to Settings, then…" ends instead with "I've changed it, open the
app".

Today a company's profile already carries the AI provider and model, sealed company credentials, 64 settings
the app accepts, locked settings categories and company vaults. But it is built by the vendor or the partner
from a preset, and the company's own administrator cannot change a single value. When they want the report to
go to a new office address, they ask the partner, who asks the vendor.

## Outcome

- The company's administrator signs in to the portal, opens **Settings**, changes the report recipients and the
  pressure unit refrigeration answers start in, and presses **Publish**. The portal says *"Version 13 published. Phones pick it up
  the next time they're opened."*
- A technician opens the app 10 minutes later. The new recipients are in force. If they are on a job, the change
  waits for it to close, and *Managed by ⟨company⟩* says *"Company settings updated. They apply after this job."*
- The pressure unit changed from kPa to psi. Technicians who never touched it now get psi. One who had picked
  bar themselves keeps bar, and their *Managed by ⟨company⟩* page says *"You chose bar. The company default is
  now psi."* with **Use company default**.
- A new hire enters the company's key on day one. Their whole setup is: allow the permissions, pick ChatGPT or
  the on-device model (or nothing, if the company pinned one), and confirm the language the app speaks. Every
  other choice is the company's and is already made.
- A company on Jamf or Intune pushes the app with its profile in the app's managed configuration. Nobody types a
  key. The phone enrols on first launch, and the MDM console shows which profile version each phone is on.
- The administrator publishes a mistake and presses **Revert to version 12**. The portal re-signs version 12's
  settings as version 14, and phones follow it the same way.

## What exists, and what doesn't

**Exists (verified against `main` at 762a3fe11):**

- **`SettingKey`** (`OpenGlasses/Sources/Services/OrgProfile/SettingKey.swift`): 64 cases, each with one `kind`.
  `profileOwned(type)` is organisation identity with no user surface (report recipients, accent, experts, stock
  system, the job-signing public key, the technician's name and ID on a per-person enrolment).
  `ceiling(pinnedTo:)` / `stringCeiling` may only pin a flag one way (privacy filter on, agent mode off, job
  recording forbidden, and so on). `startingValue(type)` is written once and the person may change it (Field
  Assist on, default vault and mode, units, trades, accent, support address, pilot reports). Each key carries its
  own content check (`contentProblem`), deny by default.
- **`ConfigProfile`** (`ConfigProfile.swift`): `profileId`, `issued`, `leaseDays`, `licenceCode`, `aiModel`
  (provider and model, never a key), `edition`, `adminPasscode` / `adminCard`, `lockdown` (`open`, `lock`,
  `closedTools`), `officeAuthority`, sealed `credentials`, `companyVaults` (`catalog`, `generation`,
  `minAppBuild`), and `settings`. Decoded lossily: an unknown key is a named drop, never a refused profile. Older
  builds ignore a top-level field they do not know, which is how LR added `companyVaults` without a schema bump.
- **`ProfileApplier`**: pure, layered (managed configuration > profile > the person), ceilings as a final clamp,
  **clamp on read**, so the person's own value is never overwritten by an owned value or a ceiling.
- **`OrgProfileManager`**: `renewIfDue` runs at launch and on foreground, but fetches the profile at most once a
  day (`ProfileLease.renewalInterval`, 24 h) unless forced by *Check for Updates*. A verified copy of the same
  `profileId` is applied without asking (`renew(with:)`).
- **Starting values on renewal:** `writeStartingValues(onlyNewKeys: true)` writes **only keys the profile has
  never written** on this phone. So a changed default never reaches a phone that already had the old one. The
  record keeps `priorStartingValues` (the person's value before enrolment, for removal) and `wroteStartingKeys`,
  but not the value the profile last wrote, so the phone cannot tell "the person changed it" from "the company
  changed it".
- **No order between profile copies.** Renewal accepts any verified document with the same `profileId`. An older
  signed copy, served by a stale edge cache or replayed, is applied as a renewal: it renews the lease, and it can
  bring back settings, or a phone missing from `revokedEnrolmentIds`, that a newer copy had changed. Only the
  company vault catalog has a generation high-water mark (LR P0).
- **Onboarding** (`OnboardingView.swift`, `OrgFirstRun.swift`): welcome → provider → key → services →
  permissions → assistant name → add device → ready. When the profile names a model, `pageAfterWelcome` skips the
  provider and key pages. Nothing else changes on a managed phone. The app's language is the phone's
  (`Config.preferredLanguageCode` reads `Locale.current`), and the reply follows the voice
  (`ReplyLanguagePolicy`).
- **The contract mirror** (`Tools/LicenceIssuance/Sources/LicenceIssuance/ProfileContract.swift`):
  `ProfileContract.allowList` lists **24 of the 64 keys**, and `checkSetting` repeats only three of the app's
  content checks. No test compares it with `SettingKey`. A portal editor built on the contract today could offer
  only 24 settings and would let through values the phone then drops.
- **Managed App Configuration:** `ProfileSource.managedConfig`, `ProfileSource.managedConfigProfileKey =
  "orgProfile"`, `isLocallyRemovable == false`, the `ProfileIngress` protocol, and the managed layer in the
  applier all exist and are tested with a synthetic layer. **No reader**: CT deferred it on 2026-09-24 until a
  customer deploys internally.
- **Presets** (JS): vendor-authored and versioned. The partner picks among a preset's enumerated values, and the
  signer builds, re-validates and signs. The company's administrator has one portal action today, the one-time
  passcode setup link.

**Doesn't exist:**

1. Any way for the company's administrator to change a setting.
2. A profile generation, and a phone that refuses a copy older than the one in force.
3. A changed default reaching the phones that already had the old one.
4. Picking up a change sooner than the next day.
5. A managed first run shorter than the unmanaged one, beyond skipping the model pages.
6. The MDM reader.

## Design

### Who may edit what

Three hands, one signer. The vendor writes presets. The partner and the company's administrator choose values
within them. The signer re-validates every choice against the same contract the phone applies, and alone holds
the profile key.

The contract gains one table, **`ProfileContract.administratorEditable`**: every profile field and `SettingKey`
a company's administrator may set, each with its value rule. A preset can narrow it (offer fewer keys, fewer
values) and can never widen it. The partner edits the same set, so support can make the change for a customer
who asks.

| Group | Administrator may edit | Stays vendor-only |
|---|---|---|
| **Starting values** | All of them: Field Assist on, the default vault (among the company's own and the preset's), the default mode, refrigeration units, trades, accent, support address, pilot reports and their recipients | — |
| **Company-owned values** | Display name, report channel and recipients, transcript rules for reports, expert list and handover rules, customer report shows expert time, the locked accent, photographed-manual policy, manual search model, stock place and clinical flag, the stock system's on/off, connector, send-back and reason, Workiz on/off and field names | `organizationJobSigningKey` (a key: it decides which job files the phone trusts; it comes from the company's office or the vendor), `organizationToolDefinitionsMode` (an engineering setting) |
| **Per-person values** | Never company-wide | `technicianFullName`, `technicianDisplayName`, `technicianID`: these belong to a per-person enrolment (Plan FP P3), and a company-wide profile carrying them would name every technician after one person |
| **Ceilings** (`ceiling`, `stringCeiling`) | Not in the first cut ([decision 2](#decisions-for-greig)) | All of them, from the preset. They only subtract, and some protect the wearer or a bystander |
| **AI** | `aiModel` among the preset's allowed providers and models; `aiChoices` (below) | Any provider or base URL the preset does not list |
| **Lockdown** | `lockdown.open` / `lockdown.lock` among the preset's categories; the pinned-open categories (Accessibility, Look & Feel, Diagnostics, Assisting) never ([decision 3](#decisions-for-greig)) | `lockdown.closedTools` |
| **Everything else** | — | `edition`, `leaseDays`, `eraseAfterLapseDays`, `undeliveredEraseDays`, `licenceCode`, `officeAuthority`, `revokedEnrolmentIds` (seats are JS P2's), `vaultPack`, `skillPacks`, `keyId`, `profileId`. The passcode keeps its own setup link (JS) |

Credentials are not settings. The Workiz key, and the company's AI key if [decision 9](#decisions-for-greig) is
taken, keep the sealed-credential path they already use.

### An edit becomes a signed profile

The profile gains one optional top-level field:

```json
"profileGeneration": 13
```

- **It rises by at least one with every re-sign of a `profileId`**, whoever made the change (partner,
  administrator, vendor, a new licence code, a seat change that re-signs). It is never reused.
- **The phone stores the highest generation it has applied**, on `OrgEnrolmentRecord`
  (`profileGenerationHighWater`), and refuses a lower one: not applied, the lease not renewed, nothing written,
  logged as `staleProfile`. The same generation is a renewal with no settings change (the lease renews).
- **A profile with no generation** applies as today until the phone has applied one with a generation. After
  that, a copy without one is older by definition and is refused. Every profile the signer issues after P4
  carries one, so the rollback gap above closes.
- **Revert** is a new generation with an old generation's settings, never the old bytes served again.
- **Concurrent edits.** An edit names the generation it was made against. The signer refuses it if that is no
  longer the latest, and the portal shows what changed in between. The rest of the edit flow (sign-in, history,
  who changed what) is service-side.
- **The portal refuses what a phone would drop.** The signer runs the same content checks as `SettingKey`
  (shared fixtures, P0), so an administrator learns of a bad address in the portal, not from a drop on someone's
  phone (CT: "an organisation should find out here, not at enrolment"). Where a key is newer than some phones in
  the company, the portal says which build it needs, as it does for `companyVaults.minAppBuild`.

The contract goes into **`Contracts/company-settings.md`**, written for the service the way
`Contracts/company-vaults.md` is: the new fields, the generation rule, the administrator-editable table, the
refusals, the revalidation rule, and the conditional fetch below.

### The phone picks it up

**When** (`ProfileRefreshPolicy`, pure: last full fetch, last check, now, trigger → *skip*, *conditional*,
*full*):

- **On launch and every foreground, at most once per 15 minutes: a conditional fetch** of the profile's address
  with `If-None-Match: "<generation>"`. The host answers `304 Not Modified` when nothing changed, and the
  edge's off-host copy does the same. A `304` is unsigned, so it renews nothing and changes nothing. It only
  saves a download.
- **Once a day, a full fetch** (no `If-None-Match`), as today. A verified copy renews the lease.
- ***Check for Updates*** under *Managed by ⟨company⟩* is always a full fetch.
- A `200` with a newer generation is applied by the path below. LR's vault pass runs after it as it does now.

**What applies, and when** (`OrgProfileManager.renew(with:)` with two pure helpers):

- **`ProfileGenerationGate`**: stored high-water mark and incoming generation → *apply*, *same* or
  *refuse as stale*.
- **Between jobs.** With a job open, a newer generation is verified, stored as pending, and applied when the job
  closes ([decision 5](#decisions-for-greig)), as LR holds a vault update. A revocation still applies at once,
  and the lease renews from the verified fetch either way. The row says *"Company settings updated. They apply
  after this job."*
- **Owned values and ceilings** follow the profile at once (once between jobs). They are clamped on read, so
  the person's own value underneath is untouched and returns if the company stops setting it.

### A setting the person already changed

The record gains `lastWrittenStartingValues`: for each starting value, the value the profile last wrote on this
phone. **`StartingValueFollow`** (pure) decides each key on a renewal from (the profile's value now, the value it
last wrote, the value stored now):

| The profile | Stored now | Result |
|---|---|---|
| Same value as last time | anything | Nothing |
| A new value | equal to what the profile last wrote (the person never changed it) | Write the new value: **the default follows** |
| A new value | different from what the profile last wrote (the person chose) | **Keep the person's choice**, and list it on *Managed by ⟨company⟩*: *"You chose ⟨x⟩. The company default is now ⟨y⟩."* with **Use company default** |
| A new value | equal to the new value | Nothing to write; the key follows again from here |
| A key it never set before | absent (the person never set it) | Write it, record the prior as absent |
| A key it never set before | set by the person | Keep it, list it as above |
| No longer set | anything | Leave the current value; it is now simply the person's. Removing the profile still restores `priorStartingValues` |

The **first enrolment** is unchanged: every starting value is written, and priors are recorded for removal.

**Migration.** Records from before P1 have no `lastWrittenStartingValues`. For each key in
`wroteStartingKeys`, the stored profile's current value is taken as the value written. Where the stored value
differs from it, the key is treated as the person's choice, and kept.

A company that needs everyone on one value locks it, where the app has a locked form (the accent has both), and
the person's own choice comes back when the lock lifts. A default stays a default ([decision 4](#decisions-for-greig)).

### The minimum per-person setup on a managed phone

**`ManagedOnboardingPlan`** (pure: managed or not, `aiModel`, `aiChoices`, what is already granted, whether the
edition uses glasses → the pages in order) replaces `OrgFirstRun`'s page arithmetic:

1. **Welcome**, with *Set up with my company* (the key or the code), then the enrolment review. On a phone the
   MDM enrolled, the review is skipped (the device is the company's).
2. **Assistant**, only when the company did not pin a model. The profile's new **`aiChoices`** lists what a
   person may pick: `chatgpt` (sign in with their own ChatGPT account) and `local` (the on-device model,
   downloaded now). The portal sets both for a new company. Absent, the page is today's full provider list, so
   existing profiles change nothing ([decision 8](#decisions-for-greig)). A pinned key provider with the key
   sealed in the profile ([decision 9](#decisions-for-greig)) asks nothing.
3. **Permissions**, as today: only the person can grant them, and no MDM can grant camera or microphone access
   to an app on iOS.
4. **Language**: one line, *"Avenkin speaks English, like your phone."* with **Change**, which opens the app's
   language in iOS Settings. Usually it is one tap on Continue. The company sets no language
   ([decision 10](#decisions-for-greig)).
5. **Glasses**, only when the edition uses them, and *Not now* ends it: Meta AI's approval cannot be given from a
   portal.
6. **Ready**.

The services page and the assistant-name page are not shown on a managed phone: connections are the company's,
and the assistant keeps its default name, which the person can change in Settings later.

### Managed App Configuration (the reader CT deferred)

**`ManagedConfigReading`** (pure) reads the dictionary iOS keeps at `com.apple.configuration.managed`:

| Key | Value | Meaning |
|---|---|---|
| `orgProfile` | the signed profile, or the HTTPS address it is hosted at (recommended) | The same signed document as every other path. CT's rule stands: **never raw settings**, one trust path, one verification |
| `activationKey` | the company's short key | Optional. Opens the sealed activation file, so the company's sealed credentials and manuals open without anyone typing the key ([decision 11](#decisions-for-greig)) |

Anything else in the dictionary is ignored and named once in the event log.

- **`ManagedConfigIngress`** is the third `ProfileIngress`. It reads at launch, on every foreground, and on
  `UserDefaults.didChangeNotification`, because an MDM can change it while the app runs (CT trap: "read managed
  config once at launch"). It hands over a delivery and nothing else, and verification and apply stay in one
  place.
- **Same company, two paths.** A phone enrolled by key whose MDM then delivers the same `profileId` keeps its
  enrolment, and its source becomes `.managedConfig`. A different company's profile is the precedence case CT
  already tests: the managed layer wins, and it is reported.
- **Renewal.** The address form renews like a link, with the generation rules above. An inline document has no
  address: its lease runs from each push, and the portal's MDM page says so.
- **Removal.** When `orgProfile` disappears, the phone leaves the company only after the key has been absent at
  two reads at least 10 minutes apart, or across a relaunch ([decision 12](#decisions-for-greig)), so one empty
  read during an MDM sync does not erase a fleet's manuals. Leaving then runs CT PR 4's owner removal (records
  delivered first). *Remove Profile* is still not offered on the phone.
- **Feedback to the MDM** ([decision 13](#decisions-for-greig)): the app writes `profileId`,
  `profileGeneration`, `enrolmentState` and its build to `com.apple.feedback.managed`, so the company's own MDM
  console shows which version each phone is on. Nothing goes to the vendor.
- **For MDM administrators**, `Contracts/company-settings.md` carries the dictionary and an AppConfig-style
  key list. The portal's MDM page gives the values to paste.

### What the administrator sees (service side, outlined)

A **Settings** page grouped like the phone's own Settings, showing only what the preset and the
administrator-editable table allow, each value with the preset's choices. **Publish** re-signs with the next
generation. **History** lists generations with when, what changed and by whom (kept in the service, never sent to
a phone). **Revert** to any earlier generation. **Preview** shows what a phone will show on its *Managed by
⟨company⟩* page, and what an older build will drop. If [decision 14](#decisions-for-greig) is taken, it also
shows *"7 of 9 phones on version 13"*.

## Phases

One PR each, headless first. The phone's P1 does nothing visible until the service's P4 issues a profile with a
generation, and the P0 contract is what the service builds against.

- **P0 — the contract and the pure core (headless).**
  - `ProfileContract.allowList` brought to parity with `SettingKey` (all 64 keys, `stringCeiling` included),
    and a test in the app's bundle that fails on any key, kind or direction that differs.
  - The content checks as a shared fixture table (key, value, accepted?) run against both `SettingKey.contentProblem`
    and `ProfileContract.checkSetting`, as `OrgCredentialTests` pins the seal.
  - `ProfileContract.administratorEditable`, with tests that it is a subset of the allow-list and excludes every
    ceiling, every `technician*` key, `organizationJobSigningKey` and every vendor-only field.
  - `profileGeneration` and `aiChoices` on `ConfigProfile` and `ProfileContract.Document` (omitted when nil, so a
    profile without them is the bytes it was).
  - `ProfileGenerationGate`, `StartingValueFollow`, `ProfileRefreshPolicy`, `ManagedOnboardingPlan`,
    `ManagedConfigReading`.
  - `Contracts/company-settings.md`.

  **Exit:** the tests above; every row of the follow table; stale, equal, missing and newer generations; a
  profile fixture with and without the new fields applying identically otherwise.
- **P1 — the phone follows.** `renew(with:)` through the gate and the follow rule; the high-water mark and
  `lastWrittenStartingValues` on the record, with the migration; the conditional foreground fetch; the pending
  generation held for an open job; the *Managed by ⟨company⟩* rows (version and date, *apply after this job*,
  each kept choice with **Use company default**); the event log (`staleProfile`, `notModified`, `heldForJob`).
  **Exit:** the manager's existing seams with an in-memory fetch: v12 → v13 with a default changed (untouched
  phone follows, changed phone keeps), v13 → v12 replayed (refused, lease not renewed), v14 mid-job (held, then
  applied), a `304` (nothing renewed).
- **P2 — the short first run.** `ManagedOnboardingPlan` wired into `OnboardingView`; the assistant page offering
  `aiChoices`; the language line; the sealed AI key if [decision 9](#decisions-for-greig) is taken.
  **Exit:** a UI test from a fresh install to Ready on a managed fixture.
- **P3 — the MDM reader.** `ManagedConfigIngress`, the observation, the activation key, the removal rule, the
  feedback dictionary, and the in-app privacy line about the feedback in the same PR. **Exit:** a synthetic
  managed dictionary through enrol, change, empty-once (nothing happens), absent twice (leaves), and another
  company's profile under management.
- **P4 — the portal (private repository, outlined).** The administrator's Settings page, Publish, History,
  Revert, Preview, the generation on every re-sign, the `ETag` / `304` on the profile address and its edge copy,
  the MDM page. If [decision 14](#decisions-for-greig) is taken, the app sends its applied generation on the seat
  check-in, with the privacy manifest and in-app copy in the same PR.
- **P5 — catalog sync** for the new strings (the *Managed by* rows, the onboarding pages).
- **P6 — device pass.** Two phones on the same company: publish a change, foreground within 15 minutes, check it
  follows on one and is kept on the one whose person changed it; publish mid-job; revert; a new hire from a
  fresh install, timed; one device enrolled from an MDM trial with the address form, then the key removed in the
  console.

## Decisions for Greig

1. **Who edits.** *Recommended:* the company's administrator edits within the preset, narrowed by
   `administratorEditable`. The partner can edit the same set on the company's behalf. The vendor alone writes
   presets, ceilings, the edition and anything that is a key.
2. **Ceilings in the administrator's hands.** *Recommended:* not in the first cut. Later, only the
   *organisation policy* group (customer sign-off required, job recording forbidden, van stock off, add-on
   limits, table checks), as tighten-only switches the preset offers. Switching one off returns to the preset's
   own state, never further. The capability ceilings (privacy filter, AI cue, interpreter, replay, dictation,
   notes, private conversations, agent mode, remote invoke, MCP) stay vendor-only.
3. **Locked categories.** *Recommended:* the administrator may open or lock settings categories among the
   preset's, never the pinned-open four. Closing individual tools stays vendor-only.
4. **A changed default.** *Recommended:* it reaches everyone who never touched it, and a person's own choice is
   kept and shown with **Use company default**. Alternatives: never re-write (today, so edits reach only new
   phones), or always overwrite (a default that behaves like a lock and silently undoes people's choices).
5. **Mid-job.** *Recommended:* a whole new generation waits for an open job to close, one rule matching LR. A
   revocation does not wait, and the lease renews either way.
6. **How soon.** *Recommended:* a conditional fetch on launch and foreground, at most every 15 minutes, plus
   today's daily full fetch. Alternatives: daily only (today; an edit can take a day), or push (needs device
   tokens, which are a new disclosed identifier, and a push service).
7. **Generation or date.** *Recommended:* an integer `profileGeneration`, rising with every re-sign, with
   rollback refused. `issued` stays as it is. An integer is what the portal shows ("version 13"), and it does not
   depend on the signer's clock.
8. **Assistant choice on a managed phone.** *Recommended:* the new `aiChoices`, set to ChatGPT and the on-device
   model for every new company. Absent means today's full list, so no existing profile changes. Other providers
   stay reachable in an administrator session.
9. **The company's AI key in the profile.** *Recommended:* yes, as the company's choice: a pinned key provider's
   key travels sealed under the company secret, as the Workiz key already does. The review says the company
   supplies the key, and the person types nothing. Without it, every phone on a pinned key provider still needs
   the key typed once.
10. **Language.** *Recommended:* no company setting. The app speaks the phone's language. The first run shows it
    in one line with **Change** (the app's language in iOS Settings).
11. **MDM.** *Recommended:* build the reader now (P3), with the address form recommended to MDM administrators,
    and accept `activationKey` as the one key beside `orgProfile`. It is the same short key a person would type,
    and it lives in the company's own MDM.
12. **MDM removal.** *Recommended:* leave the company only after `orgProfile` is absent at two reads at least 10
    minutes apart, or across a relaunch. One empty read erases nothing.
13. **MDM feedback.** *Recommended:* yes. The profile version, enrolment state and build go to the company's own
    MDM console, never the vendor, with one line in the in-app privacy copy.
14. **Fleet view.** *Recommended:* yes, after P1. The applied generation rides the existing seat check-in, so the
    portal shows who is on the latest version, disclosed in the privacy manifest and in-app copy in the same PR.
15. **Revert.** *Recommended:* revert re-signs the old settings as a new generation, so no phone ever has to
    accept an older generation.

## Traps

| Trap | Consequence |
|---|---|
| Re-serving an older generation's bytes for a revert | every phone refuses it as stale, or, without the gate, any stale copy can undo a newer policy and a revocation |
| Treating a `304` as a renewal | an unsigned answer extends the lease; only a verified copy renews |
| Comparing the stored value with the app default, not with what the profile last wrote, to decide whether the person changed it | a person who chose the app default is overwritten, and a person who never touched a key the company set is "kept" forever |
| Re-writing a company-owned value or ceiling into `UserDefaults` | breaks clamp-on-read: the person's own value is lost, and removal has nothing to restore |
| A company-wide profile carrying `technicianFullName` or `technicianID` | every phone in the company names its wearer after one person |
| An editor built on a contract allow-list that has drifted from `SettingKey` | the portal offers settings the phone drops, or misses ones it takes; the parity test is the only guard |
| Raw settings in the managed dictionary | a second, unsigned trust path beside the signed one (CT trap, unchanged) |
| Leaving the company on one empty managed-configuration read | an MDM sync hiccup erases a fleet's manuals |
| Applying a new generation under an open job | a technician's report route or sign-off rule changes mid-job |

## As built

Nothing yet.
