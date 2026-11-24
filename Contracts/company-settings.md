# Company settings contract — v1

Plan [ND](../docs/plans/ND-company-settings-from-the-portal.md). What a company's administrator may
change in the licence portal, how an edit becomes a signed profile, and how a phone picks it up. The
reference code is `Tools/LicenceIssuance/Sources/LicenceIssuance/ProfileContract.swift` (the service
compiles it); the phone's half is in `OpenGlasses/Sources/Services/OrgProfile/`. Nothing here
describes how the service stores, authenticates or audits an edit.

## The profile's new fields

Both are optional and omitted when absent, so a profile without them is the bytes it was. Builds
from before ND ignore both.

| Field | Type | Rule |
|---|---|---|
| `profileGeneration` | integer ≥ 1 | Rises by at least one with **every** re-sign of a `profileId`, whoever made the change (partner, administrator, vendor, a new licence code). Never reused. The signer sets it with `ProfileContract.nextGeneration(after:)`; an edit never carries its own. |
| `aiChoices` | list of `chatgpt`, `local`, `appleOnDevice` | What a person may pick on a managed phone when `aiModel` names no model. Non-empty, no repeats, and refused beside `aiModel`. Absent means the phone's full provider list. |

## What an administrator may edit

`ProfileContract.administratorEditableSettings` and `administratorEditableFields`. A preset may narrow
them (fewer keys, fewer values) and never widen them. The partner edits the same set.

- **May edit:** every starting value; the company's own values (display name, report channel and
  recipients, transcript rules, experts and handover rules, the locked accent, photographed-manual
  policy, manual search model, stock place and clinical flag, the stock system's switch, connector,
  send-back and reason, Workiz switch and field names); `aiModel` among the preset's providers and
  models; `aiChoices`; `lockdown.open` and `lockdown.lock` among the preset's categories (never
  Accessibility, Look & Feel, Diagnostics or Assisting).
- **Never:** any ceiling; `organizationJobSigningKey`; `organizationToolDefinitionsMode`; the
  per-person `technicianFullName`, `technicianDisplayName` and `technicianID`; `lockdown.closedTools`;
  and every other top-level field (`edition`, the lease and erasure windows, `licenceCode`,
  `officeAuthority`, `credentials`, `companyVaults`, `vaultPack`, `skillPacks`,
  `revokedEnrolmentIds`, `profileId`, `organizationName`, `profileGeneration`).

`ProfileContract.checkAdministratorEdit(from:to:)` refuses an edit that changes anything else, naming
the field.

## Before signing

The signer runs, in order: `checkAdministratorEdit` against the input in force, `check` on the
result (which runs `checkSetting` on every setting, including `contentProblem`), then sets
`profileGeneration`.

- `contentProblem` is at least as strict as the phone for every key outside
  `ProfileContract.phoneCheckedSettings`, so the portal refuses a value a phone would drop. The keys
  in `phoneCheckedSettings` depend on what is installed on a phone or on rules the contract does not
  repeat; the signer checks their type and direction only.
- **Concurrent edits.** An edit names the generation it was made against. If that is no longer the
  latest, the signer refuses it and the portal shows what changed in between.
- **Revert** re-signs an earlier generation's settings as a new generation. Old bytes are never
  served again: every phone that applied a later generation refuses them.

## The profile's address

The profile is served where it is today (`/p/<profileId>` on the licence host, and its off-host
copy). Two additions:

| Request | Answer |
|---|---|
| any `GET` | `ETag: "<profileGeneration>"` on every `200` |
| `GET` with `If-None-Match: "<n>"`, where `n` is the generation served | `304 Not Modified`, no body |
| `GET` with `If-None-Match` naming any other value | `200` and the document |

The off-host copy answers the same way. A `304` is never cached as a `200`.

## On the phone

- **The gate** (`ProfileGenerationGate`). The phone keeps the highest generation it has applied. A
  lower generation, or a copy with none after one was seen, is refused: not applied, the lease not
  renewed, no revocation in it honoured. The same generation renews the lease. A profile with no
  generation applies as before until the phone has seen one.
- **When** (`ProfileRefreshPolicy`). A full fetch once a day, as before, and on *Check for Updates*:
  a verified copy renews the lease. Between them, on launch and foreground at most every 15
  minutes, a conditional fetch. A `304` renews and changes nothing. A `200` is verified like any
  other copy. A redirect or an error changes nothing.
- **Between jobs.** A newer generation that arrives while a job is open is held and applied when the
  job closes. The lease renews from it at once. A revocation never waits.
- **Starting values** (`StartingValueFollow`). A default the person never touched follows the new
  value. One they chose stays and is listed on the organisation's page with *Use company default*.
  Owned values and ceilings follow at once (between jobs) and are clamped on read.

## The company's AI key

`credentials.aiModel` is the key for the provider `aiModel` pins, sealed under the company secret like
`credentials.workiz` (same domain, name `aiModel`). `check` refuses it without a pinned `aiModel` whose provider
takes a key (`checkSealedModelKey`; `keylessProviders` take none). It is set through the sealing call, never an
edit: `credentials` stays outside `administratorEditableFields`. A phone that holds the company secret (enrolled
with the activation key) installs the model with it and asks nothing; any other phone asks for the key as before.
A re-sealed key replaces the one in use; a profile that stops carrying one leaves it in place until removal.

## Managed App Configuration

For a company that deploys with an MDM. The dictionary iOS keeps at
`com.apple.configuration.managed` (`ManagedConfigReading`):

| Key | Value |
|---|---|
| `orgProfile` | The profile's HTTPS address (recommended), or the signed document itself. Never raw settings. |
| `activationKey` | Optional: the company's 16-character activation key, as a person would type it. |

Any other key is ignored and named once in the app's log. With the address form the lease renews
like a link. With the inline form it runs from each push. The phone leaves the company only after
`orgProfile` has been absent at two reads at least 10 minutes apart, or across a relaunch
(`ManagedConfigAbsence`). The app reads the dictionary at launch, on every foreground and whenever it changes
(`ManagedConfigIngress`). A profile delivered this way applies without a review sheet. The same company's
profile keeps a phone's enrolment, and another company's replaces the one in force.

The app writes this back for the company's own MDM console at `com.apple.feedback.managed`, and sends none of
it to the vendor:

| Key | Value |
|---|---|
| `profileId` | The profile in force. Absent when none is. |
| `profileGeneration` | The highest generation applied (integer). Absent before the first versioned profile. |
| `enrolmentState` | `notEnrolled`, `enrolled`, `waitingForJob` (a newer generation is waiting for an open job), `awaitingModelKey`, `lapsed`, `revoked` or `notVerified`. |
| `build` | The app's build number. |
