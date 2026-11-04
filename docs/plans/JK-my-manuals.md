# Plan JK — My Manuals (a personal tier: your own manuals, asked by voice, without Field Assist)

> **Owner revision — 2026-10-25:** My Manuals and Field Assist are separate services, with
> separate subscriptions and access. My Manuals grants `personalManuals`; Field Assist grants
> `fieldWork`/`ownVaults` and retains its own manual management. A Field Assist subscriber normally
> uses that service's manuals and does not need Personal. Holding both is supported; neither
> unlocks the other, and their expiry and quotas are independent. The local StoreKit fixture now
> uses a separate `my_manuals` group, with monthly/annual at the same level. Personal library
> documents and publisher projections are excluded from professional vault selection and quota.
> This supersedes the original shared-group upgrade/downgrade ladder described below.
> The My Manuals page exposes Upload before purchase and opens native in-app plans; the
> preparation placeholder, external subscription-management button, fixed headline capacity and
> Field Assist redirect/upsell have been removed. Current capacity is in the purchase sheet's
> Plan limits disclosure. Live App Store Connect setup and sandbox qualification remain open.
>
> **Owner revision — 2026-10-26 (P1e built headless 2026-10-26; device and owner items owed):** five on the shelf is not a limit on its
> own, because removal frees a slot at once and nothing records it — a technician could load the
> day's five job manuals each morning and delete them at night. §8 adds a **new-manual
> allowance**: three new manuals in any rolling 30 days, a returning manual free, the allowance
> shared across one person's devices through iCloud. Built as P1e.


**Status:** 🛠 Implemented in the working tree 2026-10-25; validation and device/store qualification in progress. Purchase offers remain disabled. Owner decisions 2026-10-20: the product
is called **My Manuals**; it holds **five manuals**; it is sold as a **monthly and an annual**
subscription; it is a new **`personal` tier** below `solo`; and its figures are set in the store
configuration and off-repo, never in this plan, a PR or a commit (the rule
[Plan EE](EE-field-assist-commercial-licensing.md) set for every price).
**Track:** consumer. Phone first; the glasses, AirPods and CarPlay are surfaces, not requirements.
**Related:** [EE](EE-field-assist-commercial-licensing.md) (tiers, the paywall, the store products),
[FS](FS-subscriber-vaults-and-vault-links.md) (a subscriber's own vaults, receiving a vault by link
or QR, the never-share rule), [H](H-custom-vault-import.md) (the importer),
[EF](EF-scanned-manual-import.md) and [IF](IF-photographed-manuals.md) (a paper manual, by camera),
[EK](EK-manual-structure-and-figures.md) (figures), [JJ](JJ-table-lookup-and-rule-chains.md)
(tables), [FN](FN-vault-manual-removal.md) (removal), [DP](DP-release-entitlement-boundary.md)
(entitlement is verified evidence, never a preference), [HB](HB-field-assist-mode-and-job-day.md)
(Field Assist as a mode of the phone), [JD](JD-apple-intelligence-tools.md) (the on-device tool
set), [DH](DH-local-gemma-keyless-tier.md) (a local model, no key).

**Build review and implementation, 2026-10-25:** P0 and P1 phone code is implemented. The owner confirmed
family sharing off, a one-week trial for eligible subscribers, publisher documents counting toward
five, each paywall naming the other tier, and the entitlement label **Personal**. After measuring the supplied
large manuals and a five-slot 9,459-page stress set, provisional limits are **8,000 per manual /
10,000 total**; purchase offers stay disabled pending older-device qualification. The
[build preparation](JK-build-preparation.md) records the code review, implementation contracts,
measurement protocol and P1a–P1d build sequence. See the [implementation and measurement report](../../reports/my-manuals-build-2026-10-25.md) for validation and remaining acceptance. Its contracts qualify the original design below.

---

## Why

The owner's question: *could Field Assist be made for a private user — the person with a car in the
garage who wants a few manuals at hand — without giving them the solo technician's Field Assist?*

Yes, and cheaply, because the part that person wants already ships and already sits behind one
capability. Since Plan FS a gate never asks *which tier* but *which capability*
(`FieldAssistCapability`), and a store product resolves to a capability set in one pure function.
Import a PDF, photograph the pages of the manual in the glovebox, ask a question hands-free and hear
the answer with its page, say "show me" and see the page with the passage marked, read one cell of
a torque table with its headings and units, receive a manual set a publisher sells by scanning a
code: every one of those is behind `ownVaults`, and none of it was built for teams.

The hard part is the other half of the question. "Ask my manual" is also the heart of what the solo
technician buys, so a cheaper tier has to be defined by what it **lacks**, and the lack has to be
structural — a capability the code asks for — rather than a hidden switch or a word on a paywall.
Three things do that, and together they are the whole plan:

1. **No Field Assist mode.** The phone never becomes a technician's phone: no Field Assist tab, no
   Jobs tab, no job-day card, no sessions, work records, procedures, escalation, van stock, parts
   orders, apprentice logbook, refrigerant toolkit, site systems, field-service connectors or team
   learnings. All of those hang off the mode today, so one new capability removes the lot.
2. **No bundled trade vaults and no packs.** The customer brings their own manuals.
3. **A quota.** Five manuals. There is no vault or document limit anywhere in the code today; this
   is the one genuinely new concept.

**The test every restriction has to pass (owner, 2026-10-20):** a working technician must find
My Manuals *not enough* — hard to stay inside while trying to build a library of their own — and
a private owner must never notice the limits. A count alone does not do that: a technician can
concatenate thirty short manuals into one PDF. What separates the two is *how a professional
builds*: a manifest with scenarios, procedures, prompt rules, trades, sites, document kinds and
editions, imported as a folder or an archive built off-phone, and a camera read of a nameplate at
every unit. None of that is a private owner's. So the sharpest limit here is **no manifest**:
My Manuals takes uploaded PDFs, Word (DOC/DOCX) or Markdown files, photographed pages and a signed publisher's set
(§2). The count and the page caps are the fence; the missing manifest is the wall.

The competitor review of 2026-10-17 recommended exactly this shape: a low-priced individual tier as
the funnel, leading with what no rival has (a wake word on AirPods, CarPlay and the glasses), with
the working technician's tier and then the team seat as the upgrades. The ladder holds only if the
middle rung is priced for what it adds — the whole job layer — not for the manuals.

## The customer, in one paragraph

Someone owns a car, a motorbike, a boat, a tractor, a sewing machine or a 1990s hi-fi, and owns the
manual for it: a factory service manual bought as a PDF, a workshop manual on paper, the owner's
handbook in the glovebox. Their hands are dirty or full. They want to ask "what's the torque on the
sump plug" or "which fuse is the rear wiper" and hear the answer with the page, then glance at the
page on the phone on the bench. They do not have a job, a customer, a crew or a van. They will not
tolerate the word *vault*, a "session", or a screen that asks which trade they are in.

## Verified starting point (main, 2026-10-20, build 541)

- **Capabilities, not tiers, are the gates.** `FieldAssistCapability` (`Sources/Services/Entitlement/`)
  resolves one piece of evidence to a set: a Field Assist subscription grants `bundledVaults` and
  `ownVaults`; the retired one-time unlock, and *any store product the build does not recognise*,
  grant `bundledVaults` only; a licence code grants by its signed tier. `capabilities(for set:)`
  unions live evidence; lapsed evidence contributes nothing. `FieldAssistCapabilityCheck.resolve`
  gives a gate `granted` / `notIncluded(held:)` / `denied(reason)`, so a screen can say *your
  purchase covers X; Y comes with Z* instead of a generic lock.
- **A tier is what a licence is.** `FieldAssistTier` is `solo` / `team` / `enterprise`, `Comparable`
  by rank; `FieldAssistEntitlementEvaluator.decide` picks the highest live tier, then perpetual, then
  the later expiry, and reports the granted tier and when it lapses. Licence codes carry a signed
  `tier`; `LicenseService` reads a code's claim and never resolves it below `team`
  (`testSoloCodeClaimIsNeverBelowTeam`).
- **Field Assist is a mode.** `FieldAssistMode.isOn` (Plan HB) is `(switchOn || restricted) &&
  entitled`, where `entitled` is `Config.fieldAssistUnlocked`, which is
  `FieldAssistEntitlement.shared.isGranted` — *any* live evidence. `Config.fieldAssistActive` is the
  switch and the grant together; the field tools and vaults gate on it.
- **Every manual tool needs a field session today.** `manual_lookup`, `manual_figure`, `table_lookup`
  and `show_source` all begin `guard Config.fieldAssistActive` and then `guard let store =
  session.activeVault`, the vault `FieldSessionService` loaded for the job. There is no way to ask a
  manual a question without Field Assist switched on and a vault chosen as the session's.
  `equipment_lookup` does the same and reads an organisation's site systems.
- **Own vaults are one gate.** `VaultRegistry.isUnlocked` returns `has(.ownVaults)` for a vault of
  the reader's own, `isGranted` for the two bundled trade vaults, and the pack rules (store product,
  licence `packs` claim, or `everyVaultPack`) for a pack. `VaultImporter` refuses to ingest without
  `ownVaults` but lets a lapsed licence still shed manuals. **Correction from the 2026-10-25 review:**
  `CapturedManualCatalog` also requires Field Assist to be active and a session for eligibility;
  `ManualCaptureService` requires a job. Personal capture needs its own explicit context, not just
  an `ownVaults` quota check. `VaultLinkService` asks `ownVaults` before installing a received vault.
- **No quota exists.** The only limits are the receive path's byte, entry-count and zip-slip caps.
- **The store.** `StoreKitService` knows three Field Assist products: the retired non-consumable and
  the monthly and annual subscriptions, in one subscription group, `field_assist`. The paywall
  offers `fieldAssistCatalogProductIds` (monthly only today). `FieldAssistPaywallCopy`
  (`FieldAssistEntitlementStatus.swift`) is guarded by `testPaywallCopyNeverSteersOutsideTheStore`.
  `FieldAssistEntitlementStatus` gives the 30-day and 7-day lapse warnings.
- **No full-manual sharing or export** (FS): every export and every vault archive excludes documents
  (`documents_included` marker); the app never offers to share a vault; received manuals are
  excluded from export. These rules carry over unchanged. Selected passages and rendered page
  images may reach the chosen model as described in §7; the export rule is not a no-egress claim.

## Product shape

| Capability | My Manuals (`personal`) | Field Assist (`solo`) | Team / Enterprise |
|---|---|---|---|
| Your own manuals, indexed on the phone (`ownVaults`) | ✅ **five manuals** | ✅ no limit | ✅ |
| Ask by voice, page cited, "show me" opens the page with the passage marked | ✅ | ✅ | ✅ |
| Figures and table cells from your manuals | ✅ | ✅ | ✅ |
| A paper manual by camera (local pages) | ✅ counts as a manual | ✅ | ✅ (+ reviewer route) |
| Build a vault: manifest, scenarios, procedures, prompt rules, trades, sites, editions; folder import; off-phone archive | — | ✅ | ✅ |
| Receive an unverified archive (your own build, by link) | — | ✅ with acknowledgement | ✅ |
| Camera read of a nameplate or fault display into the lookup | — | ✅ | ✅ |
| Page caps per manual and across the library | ✅ | — | — |
| Receive a manual set by link or QR (FS) | ✅ counts its manuals | ✅ | ✅ |
| Wake word on AirPods, CarPlay, the glasses | ✅ | ✅ | ✅ |
| Field Assist mode: tabs, jobs, sessions, work records, procedures (`fieldWork`, new) | — | ✅ | ✅ |
| Bundled trade vaults, domain calculators (`bundledVaults`) | — | ✅ | ✅ |
| Vault packs | — | by purchase | by licence / all |
| Expert escalation, van stock, parts, site systems, refrigerant toolkit, apprentice, FSM | — | ✅ (as each plan says) | ✅ |
| Audited export, org configuration, team learnings, reviewer route | — | — | ✅ |

| Who | Vehicle | Where |
|---|---|---|
| Private owner | two new auto-renewing products, monthly and annual, in the **same** subscription group as Field Assist, one level **below** solo | In-app, StoreKit |
| Solo technician | the existing Field Assist monthly / annual | In-app, StoreKit |
| Team / enterprise | signed licence code (never `personal`) | Vendor |

Same group, lower level: upgrading from My Manuals to Field Assist is an in-group upgrade with
Apple's proration and one subscription, and the customer's manuals are already own vaults, so
nothing is re-imported — the limit lifts. The downgrade is the same path in reverse, and the quota
then applies to what they hold (see §2).

## Design

### 1. Entitlement: a tier that *is* something and a capability that gates the mode

- **`FieldAssistTier.personal`**, rank below `solo`, label "Personal", summary: *Your manuals,
  asked by voice with the page cited.* Raw value `personal`. The evaluator needs no change:
  a personal subscription beside a live Field Assist subscription grants solo and reports solo's
  lapse; beside a lapsed one it grants personal. `LicenseService` keeps its clamp: a code claiming
  `personal` still resolves to `team`, because a vendor never issues the personal tier and a
  code's floor is the organisation's.
- **Two product ids** — `com.openglasses.my_manuals_monthly`, `com.openglasses.my_manuals_annual` —
  in `StoreKitService`, recorded as evidence by the existing `VerifiedStorePurchaseRecorder`, with
  `FieldAssistEntitlementEvidence.tier` reading `personal` for them (today every store product reads
  `solo`; `testStoreProductsAreAlwaysSolo` becomes *store products are solo unless personal*).
- **`FieldAssistCapability.fieldWork`** (new): *the phone as a technician's: Field Assist mode, a
  field session, the job tools.* Granted by both Field Assist subscriptions, the retired unlock, and
  every licence tier. **Not** granted by the personal products, which grant exactly `[.ownVaults]`.
- **The mode asks for it.** `FieldAssistMode.Inputs.entitled` and `Config.fieldAssistUnlocked` read
  `has(.fieldWork)` instead of `isGranted`. `Config.fieldAssistActive` follows. A personal subscriber
  with the Field Assist switch somehow on sees nothing change: the Modes tab stays the persona picker,
  the Jobs tab is absent, the Settings › Field Assist screen shows the plain Field Assist paywall.
  (It once added "your My Manuals subscription covers your own manuals"; removed 2026-11-04 by the
  owner: My Manuals is never mentioned on the Field Assist screen.)
- **The bundled vaults ask for theirs.** `VaultRegistry.isUnlocked`'s two bundled branches read
  `has(.bundledVaults)`; the pack branch requires `has(.fieldWork)` before the pack rules (a pack is
  a trade's; a publisher's manual set for a private owner is a received vault, not a pack). The
  Packs list is hidden without `fieldWork`.
- **`ManualLimits` derived from live evidence** (new, pure): the number of manuals and measured
  page limits across eligible own manuals, or nil for no limit. Personal → 5 manuals plus page
  limits chosen after measurement; anything else granting `ownVaults` → unlimited; the most
  generous live piece wins. A legacy unlock beside personal does not lift its manual quota.
- Everything above is pure and lands with a truth table in `FieldAssistCapabilityTests` /
  `FieldAssistTierTests`: every evidence combination × every capability × the limit, and
  `FieldAssistMode` with a personal grant in every switch/edition state.

### 2. The library: five manuals, one admission policy for three routes

A *manual* is one document in an own vault: a PDF, a text import's original, a photographed manual,
or one document of a received vault. The count is over every own vault on the phone. Nothing is
counted as another manual merely because its size or page count changes. Separate page caps apply.

- **Only three doors, and none takes a manifest.** A manual enters My Manuals as (a) one PDF, Word or Markdown file
  chosen in the Files picker, (b) photographed pages (the IF local route), or (c) a signed set from
  a publisher listed in the catalogue, by link or QR. The Plan H folder import (`manifest.json`,
  markdown, `procedures/`, `trades`, `sites`, `prompt_rules`, `kind`, `edition`, `source_url`) is
  **not offered** without `fieldWork`, and `VaultLinkService` refuses an **unverified** archive —
  the output of the off-phone builder and the double-acknowledgement path FS built for a
  technician's own work — with a message that names Field Assist. Each PDF becomes one
  `VaultDocument` with its title taken from the file (editable on the screen) and nothing else set.
  A professional therefore cannot bring scenarios, procedures, prompt rules, a trade, a site
  system, a controlled edition or a code book's clause structure into My Manuals at all; the only
  way to build a vault of their own is Field Assist, as today.
- **Page caps.** A manual over the per-manual cap, or an addition that takes the library over its
  total, is refused with the counts. **Measured, 2026-10-25:** provisional limits are 8,000 pages
  per manual and 10,000 total, after the supplied 7,595 + 466-page pair and the five-slot 9,459-page
  phone benchmark. Older-device qualification remains required before purchase offers are enabled. The caps are `ManualQuota` inputs beside the count, derived from evidence
  (nil for every other `ownVaults` holder). Measured per-document page metadata is persisted;
  aggregate usage and entitlement are derived, not stored counters.
- **`ManualQuota`** (new, pure): a verdict over held inventory and a proposed transition
  (additions and explicit replacements/removals),
  over three measures — manuals, pages in this manual, pages across the library — with `.allowed`
  and `.wouldExceed(measure:, held:, adding:, limit:)`. A shared admission coordinator applies it
  before durable install for Files, downloaded-link review/commit, and capture. The initial link
  fetch offer has no manifest or page count; exact checks run after download and before install.
  The coordinator reserves capacity across asynchronous work and different vaults; checking
  `toIngest` alone is too late and would also count a reindex as a new manual.
  A refusal names the counts: *"This set has 8 manuals. My Manuals holds 5, and
  you have 2. Remove some, or Field Assist has no limit."* A received set is refused whole, never
  installed partially — a partial manual set would answer wrong by omission. A received set's
  procedures, scenarios and prompt rules install with it only under `fieldWork`; for a personal
  customer derive a manual-only projection after verifying the unmodified publisher bytes, and
  the review sheet says so. That projection also governs reading existing professional imports
  after downgrade, so old manifest rules cannot activate professional features.
- **The photographed route counts.** Reserve a manual slot before a new personal capture begins,
  then check its measured pages before commit. Use an explicit personal capture destination;
  reuse local scan/redaction/OCR without manufacturing a field session or changing the v1 job and
  Office contract. Cancellation and recovery release or resume the reservation.
- **Removal frees a slot** through Plan FN's removal, unchanged. Forgetting never needs the
  entitlement (the importer's rule today) and never needs the quota. It frees a *shelf slot*, not
  a *new-manual addition*: what fills the slot next is governed by §8.
- **Over the limit without adding** — a downgrade from Field Assist, or a lapse — deletes nothing.
  Every manual stays readable while an `ownVaults` grant is live; the quota only refuses the next
  addition. On lapse, reading stops exactly as an own vault's does today (`isUnlocked` false), the
  files stay until the person removes them, and the paywall says so. No grace period beyond Apple's
  own billing grace (Plan EE's open question stands; the decision here is *no*).
- **One place to live.** On first addition without any own vault, the app creates the personal vault
  (`my-manuals`, an own vault like any Plan H import, with no trades, procedures or scenarios) and
  adds to it. A received set keeps its own vault id, as FS requires, and counts into the same five.
  The word *vault* appears nowhere the personal customer reads; the library screen lists manuals.

### 3. Answering without a field session

The four manual tools stop asking for a session and ask **which manuals answer right now**:

- **`ManualSource`** (new, pure policy with store-loading adapters): apply existing medical/privacy
  rules first. When Field Assist is active or an organisation edition is restricted, return only
  its authorised `.session` source, or a refusal if none is available. **Never fall through to a
  personal library in those contexts.** Otherwise return `.library` when `ownVaults` is held and
  eligible personal manuals exist; else `.none(reason)` with a reason the tool can say ("you have no
  manuals yet — add one in Settings › My Manuals" / "your My Manuals subscription has ended").
- `manual_lookup`, `manual_figure`, `table_lookup` and `show_source` replace `guard
  Config.fieldAssistActive` + `session.activeVault` with the resolver. Retrieval, figures, tables,
  the page sheet (`ManualPageSheet`) and the passage highlight are unchanged behind it; a library of
  several vaults can be searched together when the user selects them for the current chat.
  Selection stores stable manual identities on the conversation and survives switching/relaunch.
  Each selected book passes its own evidence gate and keeps its manual/page citations; conflicts
  are reported separately. An explicit `document` narrows the selected set, never expands it.
  With no selection, ambiguous requests ask which manual. A missing selected book asks the user
  to update their selection instead of silently substituting another book. Page/figure requests
  still require a specific manual when the page number is ambiguous. `equipment_lookup` keeps its field-session guard: site systems are an organisation's.
  **`manual_lookup`'s `use_camera`** (read the nameplate or fault display and search on it) is
  honoured only for `.session`: a private owner knows what is in the garage; reading a nameplate at
  every unit is the technician's day, and it stays Field Assist's. From the library the tool
  answers the spoken question and says a nameplate read needs Field Assist. An omitted or empty
  query asks what to look up; it must not trigger the tool's existing implicit camera fallback.
- **Registration and citations are part of the change.** Register the four manual tools outside
  the field-only block, and refresh their exposure on access/library changes. Extract the
  session-owned retrieval and page-resolution seams into shared adapters. Library source memory
  needs conversation scope and stable vault/document/revision identity; title and page alone do
  not distinguish two books. Revalidate access before reopening or attaching a page.
- **Tool descriptions** say "the manuals you have loaded" rather than "the vault"; the system-prompt
  list is generated from them (`SystemPromptBuilder`), so no other list changes. The Field Assist
  wording stays for a field session, chosen by the resolver's case.
- **The on-device set** (JD): `AppleOnDeviceToolSet.priorityNames` gets a `libraryHasManuals` input
  beside `fieldAssistActive`, so `manual_figure`, `table_lookup` and `show_source` rank early for a
  personal customer too. `manual_lookup` stays off that set for the reason JD recorded (a lookup's
  size), and a cloud or local model answers it as now. `FieldToolProfile` applies only in a field
  job and is untouched.
- **Where the answer is heard and seen.** The ordinary assistant, in any persona, by wake word on
  AirPods, the glasses or in CarPlay; the page opens on the phone, never in the car (the existing
  car rules), and the HUD is unchanged. Nothing here is a mode.

### 4. Surfaces

- **Settings › My Manuals** (`SettingsCatalog` entry, a sibling of Field Assist, shown to everyone
  without `fieldWork`; a Field Assist holder manages the same vaults under Custom Vaults and sees
  My Manuals as a row that says so): the subscription row with the status and warnings
  (`FieldAssistEntitlementStatus` reused), the manuals held of five, each with title, pages and
  source (file, camera, received), *Upload manual* inside Your manuals (PDF, DOC/DOCX or Markdown Files picker; the camera route; *scan a code*
  for a received set), remove, storage used, and *What the assistant can read*: your manuals are
  indexed on this phone and excluded from sharing/export; when you ask, selected passages and
  rendered page images may be sent to the model you have chosen. Supported local paths keep their
  processing on the phone; the selected model's tool support determines which workflows it offers.
- **My Manuals quick action:** opens a checkbox picker from the home grid, with an optional
  multiple selection (for example Prius Workshop plus Prius Electrical). A chat strip shows the
  selected title or count and book names, and opens the same picker to change it. The picker
  provides reading and management links; importing/removal remain in Manage manuals. Changing the
  selection clears remembered/staged sources and the current selection is included in the model's
  context. Named saved groups remain an optional future convenience.
- **The paywall.** `MyManualsPaywallCopy` beside `FieldAssistPaywallCopy`, both under the
  never-steer-outside-the-store guard: what you get, monthly and annual, the current plan's
  capacity details, *Restore purchases*, and a line naming the Field Assist upgrade in the same
  subscription group. The owner requested neutral branding (“Keep your manuals”) and removed
  repeated Privacy/Terms links from the My Manuals page; the app's other legal/privacy surfaces
  remain unchanged. The Field Assist paywall does not name the smaller option (owner, 2026-11-04:
  My Manuals lives under Everyday and nowhere in Field Assist).
  `fieldAssistCatalogProductIds` splits into the two offer sets.
- **The Modes tab** (HB) for a personal subscriber: the persona picker with no Field Assist row;
  `ModesTabPresentation` gets a case for *entitled to manuals, not to Field Assist*, which is the
  persona picker, nothing added.
- **First run after purchase**: one hint on the home screen, *Add your first manual*, until one is.
- **An organisation's edition in force** (`AdminGate.isRestricted`): My Manuals is not offered and a
  personal library never answers in a field session — the resolver's `.session` case wins whenever
  Field Assist is active, and the Settings entry is hidden under the edition. A technician's own
  manuals do not leak into an audited job.

### 5. What stays out, by construction

Because `fieldWork` is missing: Field Assist mode and both its tabs; `field_session` and every job
tool in `FieldToolProfile.names` that is not a manual tool; work records and the session log;
procedures and `procedure_runner`; `domain_calc` and `refrigerant_gauges`; escalation and the
expert transports; van stock, parts, deliveries; site systems; the apprentice logbook; team
learnings; the office route and every connector. Because `fieldWork` is also what the vault doors ask for: the folder import and every manifest
field (scenarios, procedures, prompt rules, trades, sites, document kinds, editions, source
links), unverified archives and the off-phone builder's output, `use_camera` on a lookup, and the
clause-and-rule machinery that reads a manifest's `standard` documents (IN, JJ P2 chains). Because
`bundledVaults` is missing: the two trade
vaults. Because `auditedExport` is missing: every export of a session (there is none). Because
`capturedManualReview` is missing: pages never go to a reviewer. Each is a test, not a promise.

### 6. Store

Two products in the `field_assist` group at a level below the Field Assist pair; family sharing off
(confirmed 2026-10-25), one-week trial for eligible subscribers; the local `.storekit` file gains both with placeholder
figures that are the only place a figure shows in the repo; App Store Connect is the owner's by hand.
Reconcile the professional annual product in the fixture too; it is recognised in code but absent
from the current file. Recognise personal purchases in every evidence/restore/status path in P0;
only expose their purchase offers once P1 is complete. Apple trial eligibility applies to the whole
subscription group; the build preparation links the checked Apple setup guidance.
Sandbox checks: buy personal → import 5 → sixth refused → upgrade in-group → sixth imports → downgrade
→ all 6 still readable, seventh refused → let lapse → reading stops, files stay, re-subscribe → reading
resumes with nothing re-imported.

### 7. Privacy, copyright, data

- **Copyright.** The person indexes a manual they own, on their phone, for their own use. The app
  never redistributes it: FS's rules (no sharing, documents out of every export and archive) are
  the enforcement and stay guarded by their tests. The in-app copy says *your own copy*.
- **The model sees selected content.** The passages that answer, and rendered page images when
  the figure path attaches them, go to the cloud model the person has chosen. Supported local
  paths keep their processing on the phone; Apple on-device tools do not offer `manual_lookup`.
  The no-sharing/no-full-manual-export rule does not mean every answering path has no egress.
  `AIFeatureRegistry` gets a
  `myManuals` record (or the Field Assist record's title and copy widen to "Field Assist and My
  Manuals") so the privacy copy names it; the `PrivacyInfo.xcprivacy` claims do not change (no new
  egress, no new SDK).
- **Stores.** The library uses existing own-vault/document storage plus explicit personal capture
  metadata. Derive quota usage from admitted and pending inventory, including captures, with
  measured page metadata; no independently mutable total counter. Register any added durable
  metadata in `DataStoreRegistry` and subject erasure. Preserve the existing IF job/Office contract.
- **Medical mode** keeps its existing vault rules; nothing new is read or sent.
- **EU AI Act**: retrieval over the person's own documents; nothing in Annex III; no change to the
  review document.
- **Nothing is a preference.** The grant is the verified transaction; the quota is derived from it
  on every read; no stored "manual count" or "tier" boolean exists (Plan DP's rule). §8's addition
  history is the one stored record, and it is a history of events, not a count or a grant: the
  allowance is derived from it and from live evidence on every check, and losing it only ever
  makes the app *more* generous.

### 8. New-manual allowance: limiting swaps (owner decisions 2026-10-26)

**The gap.** Count, page caps and the missing manifest all describe what the shelf *holds*.
Nothing describes how fast it *turns over*: removal frees a slot immediately, needs no grant, and
leaves no record (`VaultLinkInstaller` says so in as many words). A technician who meets 80–120 jobs
a month can upload the day's manuals each morning, delete them each evening, and never hit a limit.
That fails the owner's test from the top of this plan.

**What separates the two customers is new manuals per month.** A private owner fills the shelf
once (car, motorbike, mower, boat, a hi-fi) and afterwards meets a new manual every few months; a
busy month brings two. A technician meets twenty or more. Any allowance from two to five separates
them; the number is chosen so the owner never feels it.

**Rules (decided):**

- **Three new manuals in any rolling 30 days.** Each new addition is spent for 30 days from the
  moment it was made and then comes back. Unused additions do not carry over. Rolling, not
  calendar: a calendar month allows three on the 31st and three more on the 1st, and rolling lets
  a refusal name the date the next addition becomes available.
- **The first five distinct manuals are free.** Filling the shelf — including inside the trial
  week — never touches the allowance. "First five" is per subscription (below), not per install.
- **A returning manual is always free.** A manual is *new* when its fingerprint (below) has never
  been held under this subscription. Re-adding one you removed, or adding to your iPad one that is
  on your phone, costs nothing. This is what keeps the owner who swaps between two vehicles' books
  out of the limit, and it cannot be gamed: a different manual cannot present an old fingerprint.
  A re-saved PDF or a re-photographed manual has different bytes and counts as new; the refusal
  copy does not need to explain this.
- **Undo is free only for a manual nothing was read from.** Removing a new manual within 24 hours
  gives its addition back **only if no answer cited it and none of its pages was opened** — the
  wrong-file case. *(This narrows the 2026-10-26 discussion, which had a plain 24-hour undo: with
  no read condition, a technician adds the job's manual, uses it all day and removes it at hour 23
  for free, which reopens the gap this section closes.)*
- **Removal stays free and immediate.** It frees a shelf slot; it never returns a spent addition
  outside the undo rule.
- **Publisher sets** spend one addition per manual in the set that is new to you. A set that does
  not fit the remaining allowance is refused whole, as for the shelf, never installed partially.
- **Annual subscribers get the same rate.** A year's subscription does not front-load 36.
- **Only the personal limits carry an allowance.** Any live unlimited `ownVaults` grant (Field
  Assist) lifts it with the other limits; `ManualLimits.resolve` returning nil means no allowance.
- **Lapse and downgrade** change nothing about the history. The allowance gates additions only;
  reading, removal and non-growing retries never consult it.

**Fingerprint.** HMAC-SHA256 of the original file's bytes (the uploaded PDF/DOC/DOCX/Markdown, not
the app-generated reading copy; each document of a publisher set separately), keyed with a random
per-subscription secret. The secret lives in the **iCloud Keychain** (synchronizable, end-to-end
encrypted) so every device on the person's iCloud derives the same fingerprints, while the history
itself never holds anything that could identify which manual a person owns.

**History.** An append-only set of records `{fingerprint, addedAt, spent: Bool, refunded: Bool}`
keyed by the subscription's **original transaction id** from verified evidence, so a monthly ↔
annual switch, a lapse and a re-subscribe all keep one history, and a different Apple ID's
subscription starts its own.

**Devices (decided): one allowance per person, one shelf per device.**

- The history syncs through **iCloud key-value storage** (`NSUbiquitousKeyValueStore`), so a phone
  and an iPad on the same iCloud share three new manuals a month. Each device keeps its own five on
  the shelf; the manuals themselves never sync (the Non-goals stand: no sync of manuals, no cloud
  copy). Only fingerprints and dates leave the phone, and only to the person's own iCloud.
- Without iCloud, the history lives in the local keychain, which survives an app reinstall. On a
  later iCloud sign-in the two are merged.
- **Merge is a union** of records by `(fingerprint, addedAt)`; a smaller set never overwrites a
  larger one. Two devices adding offline at once can overspend by what they added; accepted.
- **Clock:** a record dated after the device's current time counts as inside the window, so moving
  the clock forward to free the allowance spends the future window instead. Verified store time can
  replace the device clock later if this is ever seen in practice.
- **Accepted, not engineered against:** a company signing several technicians' App Store accounts
  into one subscription. iOS lets the App Store account differ from the iCloud account, so their
  histories never meet, and nothing on the phone can count devices without a server, which this
  product does not have. Each phone in that arrangement still holds five and gets three new a
  month, which is what makes it useless for daily work. The subscription terms (owner, off-repo)
  gain a **personal, non-commercial use** clause as the stated basis.

**Known residual.** Free returns mean a subscriber's set of *known* manuals grows by about three a
month — five plus thirty-six after a year — all swappable into the five slots without cost. Swapping
still means re-uploading the file for each job, which is the friction that matters. If this is
seen in practice, the dial is a cap on free returns per window; not built now.

**Not in this section:** one PDF made of many manuals still fits under the page caps. Detecting a
bundle (for example, an upload whose model sections span many unrelated series, using the series
inference already in the vault code) is a later, separate decision.

**Surfaces.** The refusal names the count and the date and does not upsell: *"You've added 3 new
manuals in the last 30 days. Your next new manual can be added on 12 November. Manuals you've had
before can come back any time."* The purchase sheet's Plan limits disclosure gains one line
(`MyManualsPaywallCopy.limitDetails`). The upload sheet says how many new additions remain only
when one or none is left. No headline counter on the My Manuals page, per the 2026-10-25 revision.
No plan letters in any of it.

**Code shape.** `ManualLimits` gains `newPerWindow: 3`, `window: 30 days`, `freeFirst: 5`,
`undoWindow: 24 h` (nil for every non-personal holder). A pure `ManualAdditionAllowance.decide(
limits:history:proposed:now:)` returns `.allowed(spending:)` or `.wouldExceed(remaining:
nextAvailable:)`, beside `ManualQuota` and with the same fail-closed rule: an unreadable history
refuses additions, never removal or reading. `ManualLibraryAdmission.install` and
`reserveCapture`/`validateCapture` consult it after the quota, under the same lock, and record spent
additions in the same critical section as the commit; a cancelled or failed install records
nothing. A small `ManualAdditionHistoryStore` owns the keychain/KVS pair and the merge. The read
condition for undo comes from the library's existing citation and "show me" paths.

**Privacy and data.** Register the keychain item, the iCloud Keychain secret and the KVS keys in
`DataStoreRegistry`. The in-app privacy copy names the sync: *a private record of which manuals
you've added — fingerprints and dates, never the manual — syncs through your iCloud.* No new SDK,
no third-party egress; `PrivacyInfo.xcprivacy` claims are re-checked, not expected to change.
**Owed — erasure:** subject erasure should delete the fingerprints and the secret (the person
loses only their free returns). Whether in-window dates (no content, self-expiring after 30 days)
may be kept until they expire, so that an erasure does not also reset the allowance, is a decision
for the privacy review, not this plan.

**Owner items.** iCloud key-value storage is a new capability: the entitlement in the spec and the
capability in the developer portal before the next archive. The non-commercial clause in the terms.

## Phases

### P0 — Entitlement core (headless, one PR)

`FieldAssistTier.personal`; the two product ids and their evidence; `fieldWork` and
evidence-derived `ManualLimits`; `FieldAssistMode`, `Config.fieldAssistUnlocked` / `fieldAssistActive`,
`VaultRegistry.isUnlocked` and `VaultPackAccess` moved onto capabilities; `ManualQuota` and
`ManualSource` as pure types with their tests; `MyManualsPaywallCopy` under the guard; the
`ModesTabPresentation` case. Tests: the capability truth table with personal evidence in every
combination; mode never on for a personal grant; bundled vaults locked, own vaults open, packs
hidden; licence codes never personal; quota verdicts; resolver cases; paywall copy guard; every
existing Field Assist gate test still green (nothing a solo or team holder has changes).

### P1 — The library and the answer (P1a–P1d)

Build as four reviewable slices, with the exit checks in the
[build preparation](JK-build-preparation.md): inventory/measurement/Files → retrieval and
citations → verified links and personal capture → Settings/paywalls/lifecycle.

The quota (count and measured page caps) at all three routes; the single-PDF door
(Files picker, one `VaultDocument`, title from the file); the folder import and unverified archives
refused without `fieldWork`, with the message; a received set installing manuals only for a
personal customer; `use_camera` refused from the library; the personal vault created on first addition; the
four manual tools on the resolver; tool-description wording; the on-device set input; Settings ›
My Manuals; the paywall; the first-run hint; the edition rule; the `AIFeatureRegistry` record and
privacy copy. Tests: importer and downloaded-link-review refusals with the counts in the message for each of the
three measures; a folder with a manifest refused for personal and accepted for solo; an unverified
archive refused for personal with the Field Assist message; a signed set's procedures left out for
personal and installed for solo; `use_camera` honoured from a session and refused from the library;
capture refused at the limit; forget and remove need neither grant nor quota; a lookup from the library with
Field Assist off, and from the session with it on, with the same vaults loaded; a two-manual answer
names the manual; the on-device set ranks the manual tools with a library and no job; the settings
entry present without `fieldWork`, hidden under an edition; the catalogue guard (strings, no plan
letters in copy).

### P1e — New-manual allowance (one PR, before purchase offers are enabled)

**Status (2026-10-26): 🛠 built, headless.** `ManualAdditionAllowance` (pure) beside `ManualQuota`;
`ManualAdditionHistoryStore` over a backend seam (live: synchronizable keychain secret, KVS
history, local keychain copy; tests: in memory); admission at the signed-set install, the link
preflight (decides, spends nothing), capture reserve/validate and the Files door; the read mark
from lookup, table and page opening; the unread undo on removal; the refusal, plan-limits line,
upload-sheet line and privacy disclosure; three `DataStoreRegistry` entries; the KVS entitlement
in `project.base.yml` and the personal example. The history is keyed by the personal
subscription's verified original transaction id (`store-<id>`), or one per-device key when no
store transaction is recorded. The read flag is carried on the record (synced, only turns on), so
a read on another device also ends the undo. Still owed, not done: the iCloud capability in the
developer portal before the next archive (and in each developer's personal entitlements file),
a phone + iPad check on one iCloud, the terms clause, and the erasure decision below.

§8, headless core first: `ManualAdditionAllowance` and its tests; the fingerprint and
`ManualAdditionHistoryStore` behind a seam (an in-memory store in tests, never the live keychain or
KVS); admission wired at Files, links and capture; the undo read condition; refusal and
disclosure copy through the catalogue guard; `DataStoreRegistry` entries. The KVS entitlement goes
into the spec in the same PR; the portal capability and a two-device check (phone and iPad on one
iCloud) are owed after merge. Exit: the sixth new manual in a window is refused at every door with
the date; a returning manual installs; removing and re-adding a manual costs nothing; an undo after
a cited answer refunds nothing.

### P2 — Store and device (owner + one PR)

The `.storekit` products; App Store Connect setup and the listing copy (owner); the sandbox sequence
in §6 on a phone; a device pass: add a PDF from Files, photograph three pages, ask by wake word on
AirPods with the phone in a pocket, ask in CarPlay, "show me" on the bench, a table cell with units;
the upgrade path end to end. Release build before the PR, as always.

## Non-goals

- No AI-generated summaries of a manual, no "chat with your car": the answer is a passage with its
  page, as for a technician.
- No sharing, no sync between phones, no cloud copy of a manual. FS's rule is the product. (§8's
  addition history syncs fingerprints and dates, never a manual.)
- No fetching a manual from a manufacturer's site (Plan IT is organisation-side; a later plan could
  offer the public-copy route to personal customers under IT's rules).
- No mode, no tabs, no jobs, no "my garage" record keeping. A later consumer plan may want a vehicle
  record (Plan AZ exists); it is not this one.
- No pack purchases for personal customers; publishers reach them by link or QR.
- No free tier: the app is paid and the subscription is on top, as for every paid capability.

## Owner decisions and remaining measurement

Confirmed 2026-10-25: family sharing off; one-week trial for eligible subscribers; received
publisher documents count toward five; each paywall names the other tier; entitlement label
**Personal**. The product name remains **My Manuals**.

Confirmed 2026-10-26 (§8): three new manuals in any rolling 30 days, no carry-over; first five
distinct manuals free; a returning manual free; one allowance per person through iCloud, one shelf
per device; a company sharing one App Store account accepted, with a non-commercial clause in the
terms. Owed: the undo read condition (§8 narrows the discussed plain 24-hour undo), the erasure
question for the privacy review, the iCloud capability, the terms clause, and a later decision on
detecting one PDF made of many manuals.

The supplied workshop PDFs and the completed five-slot phone benchmark support provisional
policy ceilings of 8,000 physical pages per manual and 10,000 total. The earlier 2,500 / 6,000
proposals are rejected. Older-device memory, diverse fully scanned books, cancellation/recovery
and answer quality still need qualification before purchase offers are enabled. Show measured
pages/bytes and indexing state; do not promise a time estimate from this small fixture set.

## Tests (headless)

`FieldAssistCapabilityTests`, `FieldAssistTierTests` (extended), `FieldAssistModeTests` (personal
rows), `ManualQuotaTests`, `ManualSourceTests`, `VaultImporterQuotaTests`,
`VaultLinkReviewQuotaTests`, `ManualCaptureQuotaTests`, `MyManualsDoorsTests` (manifest folder,
unverified archive, set-without-procedures, `use_camera`), `ManualToolsLibraryTests` (lookup, figure,
table, show-source from a library with Field Assist off), `AppleOnDeviceToolSetTests` (library
input), `MyManualsSettingsPresenceTests`, `PaywallCopyGuardTests` (both copies),
`ManualAdditionAllowanceTests` (window edges, first five, returning free, undo with and without a
read, a future-dated record, a set refused whole, nil limits, unreadable history),
`ManualAdditionHistoryMergeTests` (union, offline overspend, keychain → iCloud merge), the existing
`BrandNameGuardTests`, `OutboundFrameConsumerTests` and `TelemetryOptOutGuardTests` unchanged.

### Owner follow-up: uploaded Word and Markdown manuals

The file-upload door now accepts PDF, DOC, DOCX, MD and Markdown. PDFs retain physical source
pages. Other formats retain their original bytes and an app-generated paginated text reading PDF;
its pages are used for quota and citations and are explicitly labelled as a reading copy. The UI
explains that layout/images are not preserved and recommends PDF for diagrams. Read original uses
the system document preview. Corrupt/encrypted input refuses import, and conversion never sends
files to a remote service. No folder/manifest upload door is added.

Your manuals contains the Upload manual button, saved holdings and confirmed Delete controls.
Delete removes the original, reading copy and index and frees its quota slot. Subscription headlines
say Keep your manuals; usage displays the current plan limits. Privacy and Terms links are omitted
from this page at the owner's request.


Owner follow-up (build 567): Upload manual groups file selection and publisher links/codes.
Files can be selected and previewed before subscribing; save/index remains behind Personal access.
The standalone Receive row is removed. Only monthly is currently offered; annual restore remains.
The local native StoreKit app-host probe confirms the product, separate group and one-week offer.
Live App Store Connect metadata and review acceptance remain separate from that fixture check.
