# Plan HA — One Settings List, Organisation Lockdown, and a Truthful Hero Card

**Status:** ✅ Shipped 2026-10-02 — C1 + C2 + C3 in one PR. The hub lists all twelve categories in
one fixed order (`SettingsCatalog`), the Discover shelf and the settings journey are gone, Field
Assist is a top-level row, and Devices & Privacy gained a Glasses row; the Field Assist edition now
**locks** settings read-only under a "Managed by ⟨org⟩" banner instead of hiding them
(`ManagedLockdown` on `AdminPolicy`, `SettingsLockPolicy`), with a profile `lockdown` field, a
read-side tool clamp and the administrator session as the override; the hero card shows the glasses
only while they are attached (`SettingsHeroDevice`). **Owed (device):** the managed hub on a real
enrolled phone — banner placement, read-only screens scrolling, and VoiceOver on a locked row.
**Revised 2026-10-04 (C4):** locked settings are now *hidden* from the technician, not drawn
read-only, and "Remove Profile" moved off the hub to the bottom of the organisation's own page.
**Owed (device):** the C4 hub, the organisation's page and Remove Profile on a real enrolled phone.

**Related:** Plan [DE](DE-settings-capability-journey.md) (the journey this retires), Plan
[CT](CT-org-configuration-profiles.md) (the profile, the edition, the administrator gate and the
decisions this extends), Plan [FY](FY-rename-to-avenkin.md) P2 (the device card, phone-first), Plan
[GU](GU-wake-word-audio-and-power.md) (the Connected Glasses rows), Plan
[GW](GW-home-grid-pages.md) (My Day's "Show on Home Screen").

---

## Trigger

Greig, 2026-10-02, after living with the hub:

1. **"The suggestions always being there looks crap."** The Discover shelf of folded categories,
   their pitches and the "Show everything" switch sit at the bottom of Settings on every phone. He
   wants every category, always, in this order: AI & Personality; Voice & Triggers; Devices &
   Privacy; Accessibility; Field Assist; Look & Feel; Tools & Actions; Connections; Capture &
   Streaming; Display & HUD; Advanced; Diagnostics & Support.
2. **An organisation that configures Field Assist must be able to rely on it staying configured**,
   and close off most of what is not Field Assist. Most settings disabled, not removed.
3. **The hero card shows the glasses whenever glasses were ever added** — a pair in its case leads
   Settings as "Not connected". The glasses panel belongs to glasses that are attached.

## What existed (verified 2026-10-02, main at 14d04710)

- `SettingsView` drew the hero card, the Organisation and Administrator sections, the visible
  categories (`SettingsJourneyState.visibleCategories` over `CapabilityCatalog.all`), a Language row
  in the edition, the Discover shelf (`OGDiscoverCard`) with "Show everything", Simple Mode / Lock
  Settings and About.
- The journey (Plan DE): `CapabilityCatalog` (tiers, placements, pitches), `SettingsJourneyState`
  (unfolded set, unlock moments), `SettingsJourneySignals` (the migration probe),
  `SettingsJourneyStore` (persisted under `settingsJourneyState`), and three `note(_:)` call sites
  — the first photo, a broadcast starting, a tool confirmation.
- The Field Assist edition (Plan CT 3b) **hid** every category but Accessibility, Devices & Privacy
  and Diagnostics & Support (`EditionPresentation.categories`), plus Modes and Chat and the model
  switcher. An administrator session (`AdminGate`) showed everything; ceilings (`SettingKey`) still
  clamped with a "Set by ⟨org⟩" caption (`ManagedSettingNote`).
- The hero card used `OnboardingFlow.phoneIsTheDevice(glassesConnected:glassesAdded:)`: this iPhone
  only when glasses were neither connected nor ever added.

## C1 — One list, always

`SettingsCatalog` (`Sources/Services/SettingsHub/SettingsCatalog.swift`) is the hub as pure data.
`SettingsCategoryID`'s declaration order **is** the order, so a category cannot exist without a
place in it, and `SettingsView.destination(for:)` switches over it exhaustively — a new case does
not compile until it has a screen. Accessibility is built by `SettingsCategory.pinnedAssistive`,
which has no Simple Mode parameter. The raw ids are what a profile's `lockdown` names, so they are
pinned by a test.

**Names reconciled.** The requested names are the shipped ones: the hub row was already "Devices &
Privacy" (its sub-screen stays "Hardware & Privacy"). "Works with your iPhone" was a hub row with no
place in the list; it is the first row of Connections now (it is the phone's own apps, connected).

**Mapping — every screen the old hub reached, and where it lives now.** `SettingsHubTests.inventory`
is this table as data; `testEveryScreenTheOldHubReachedIsStillReachable` reads the view sources and
checks each chain, from `destination(for:)` to the screen.

| Old hub entry | Screens it reached | New category |
|---|---|---|
| AI & Personality | `AIPersonalitySettingsScreen` → Personas, System Prompt, What Avenkin Remembers, Smart Routing, Vision Images, Agentic Features | AI & Personality |
| Voice & Triggers | `VoiceTriggersSettingsScreen` → Temple Taps | Voice & Triggers |
| Devices & Privacy | `GlassesPrivacySettingsScreen` → Hardware & Privacy (Recordings, Meeting Records, Health, Insights, HUD links…), Medical Compliance, How Your Requests Are Processed | Devices & Privacy |
| Devices & Privacy › Hardware & Privacy › *Connected Glasses* section | wake-word mic, Reply audio, switch time limit, Sleep When Quiet, device class, Update Glasses App / Firmware | Devices & Privacy › **Glasses** (new screen, `GlassesSettingsView`; same rows, same order) |
| Accessibility | `AccessibilitySettingsView` | Accessibility |
| Tools & Actions › Field Assist | `FieldAssistSettingsView` | **Field Assist** (top level) |
| Look & Feel | `LookFeelSettingsScreen` → Languages | Look & Feel |
| Tools & Actions | Quick Actions, Tools, Custom Vaults, Personal Notes, Study Mode, Reading, Health Vault, Custom Tools, Skill Packs, Siri & Search, MCP Server, Playbooks, Skill Store, Voice Skills, Suggested Skills | Tools & Actions |
| Works with your iPhone | `AppleIntegrationsSettingsScreen` (My Day with Show on Home Screen, Apple apps, About Weather Data) | Connections › Works with your iPhone |
| Connections | Services & Integrations, Gateways, MCP Servers | Connections |
| Capture & Streaming | Recordings, Meeting Records, a shortcut to Services | Capture & Streaming (Services' home is Connections) |
| Display & HUD | HUD Mirror, Display Backend, Web HUD Mirror, Teleprompter | Display & HUD |
| Advanced | Developer, Prompt Inspector, Network Activity, Live Vision, Documents, Author Capture-Flow | Advanced |
| Diagnostics & Support | `DiagnosticsSupportView` | Diagnostics & Support |
| Language (edition only) | `LanguageSettingsView` | Look & Feel (open under the edition) |
| Simple Mode, Lock Settings, About, Organisation, Administrator | — | unchanged, on the hub |

Placement decisions kept: glasses-only settings live under the glasses (now their own Glasses
screen in Devices & Privacy, which the hero card no longer has to stand in for); the wake-word mic,
Reply audio and Sleep When Quiet rows are still the Connected Glasses section, in their order; My
Day's "Show on Home Screen" switch is unchanged inside Works with your iPhone.

**Simple Mode** shows Voice & Triggers, Devices & Privacy, Accessibility, Look & Feel and
Diagnostics & Support, in hub order — the same five as before. Field Assist is hidden with the rest
of the owner's configuration (licence, organisation code, vaults, reports); a Field Assist session
runs from the home tab, not Settings. Its footer now names Field Assist.

**Journey code removed:** `CapabilityCatalog` and its tier/placement types, `SettingsJourneyState`
(+ migration and unlock moments), `SettingsJourneySignals`, `SettingsJourneyStore`, `OGDiscoverCard`,
the three `SettingsJourneyStore.note` calls, the launch migration, the UI-test journey seed and the
`-OGUITestShowAllSettings` flag, `SettingsJourneyTests`. The stored `settingsJourneyState` default
is removed at launch. **Kept:** nothing else used the journey — onboarding and capability hints
never read it. The category screens file is renamed `SettingsCategoryScreens.swift`; the two model
wording tests that lived in the journey suite moved to `AIPersonalitySettingsWordingTests`.
`OnboardingFlow.phoneIsTheDevice` stays (its onboarding tests describe the first run); the hub no
longer calls it.

## C2 — Organisation lockdown

Extends the edition, not a second envelope. `ConfigProfile` gains an optional, lossily decoded
`lockdown {open?, lock?, closedTools?}`; `ProfileApplier` resolves it into
`AdminPolicy.lockdown: ManagedLockdown` beside the edition and the administrator credentials, so it
rides the verified profile in `PolicyEnvelope` (`PolicyEnvelope.lockdown`) and lifts with it. A
`lockdown` without an edition is a named drop, as an admin card without one already was.
`make-org-profile.swift` passes it through and checks it (category ids mirrored and test-pinned).

**The rules, in CT's terms:**

- **Deny by default.** The lock set is computed as *every category* minus `pinnedOpen` minus
  `openByDefault` minus what the profile opens, so a category added later is locked on a
  technician's phone until someone decides otherwise.
- **Pinned open — never lockable:** Accessibility (free forever, never withheld), Look & Feel (theme,
  text and accent colour, language — how a technician reads the app at all), Diagnostics & Support
  (how a technician proves a managed phone has stopped working). A profile that tries to lock one is
  a named drop.
- **Open by default:** Field Assist. Its settings follow the organisation's own per-key policy (the
  `SettingKey` ceilings and starting values that already render "Set by ⟨org⟩"). The master switch
  is locked (`ManagedArea.fieldAssistSwitch`): the edition *is* Field Assist. A profile may lock the
  whole category (`"lock": ["field-assist"]`).
- **Locked by default:** AI & Personality, Voice & Triggers, Devices & Privacy, Tools & Actions,
  Connections, Capture & Streaming, Display & HUD, Advanced. Devices & Privacy keeps two areas open —
  **Glasses** (a technician has to get the glasses working: wake mic, updates) and **How Your
  Requests Are Processed** (a disclosure, not a setting). The hub's Simple Mode and Lock Settings
  are locked (`ManagedArea.ownerControls`). A profile may open any locked category
  (`"open": ["voice"]`).
- **Read-side, nothing written.** Every decision is a pure function over the lockdown and whether
  the technician's view is in force (`SettingsLockPolicy.lock(_:lockdown:restricted:)`,
  `isLocked(_:lockdown:restricted:)`, `AdminGate.lock/isLocked`). Removing the profile or opening an
  administrator session lifts it with nothing to restore.
- **Locked is visible.** A locked category is still a row, valued "Managed", with the hint "Opens
  read only". Its screen opens with every control disabled under the "Managed by ⟨org⟩" banner —
  the same row the hub's Organisation section shows (`ManagedByOrganisationRow`, extracted from
  `ManagedByOrganisationSection`). A partly open screen disables its locked rows one by one under
  the same banner. Individual locks carry `ManagedLockNote` ("Set by ⟨org⟩"), which
  `ManagedSettingNote` now draws too. **The edition no longer hides settings**:
  `EditionPresentation.categories` is gone and so is the edition's separate Language row.
- **The administrator path still changes things.** An administrator session or administrator phone
  (`AdminGate.isRestricted == false`) opens every category. Ceilings still clamp.
- **Closed features.** Tabs and the model switcher stay as CT 3b closed them (Modes and Chat hidden,
  `EditionPresentation`). **Tools** close only when the profile names them (`closedTools`), clamped
  on read through `Config.disabledTools` — every reader, including the model's tool list, sees them
  off; the setter keeps the person's own stored choice for a closed tool, so lifting the lockdown
  restores it. Closed tools are the profile's statement about the phone, like a ceiling: an
  administrator session does not reopen them. Tools & Actions and the Works with your iPhone switches
  show a closed tool off and disabled with "Set by ⟨org⟩".
- **The review sheet** says "Shows Field Assist, Job and Settings, with most settings locked", then
  whatever differs from the standard set ("Left open: …", "Also locked: …", "Tools switched off: …").

**Why tools are not deny-by-default (yet).** An inverted tool list — everything off but a named Field
Assist set — is the right end state, but a list written without the pilot's own jobs in front of it
would switch off a tool a job needs in front of a customer, and there is no device pass to catch
it. With Tools & Actions locked, a technician already cannot change which tools run; the profile can
close the ones the organisation names. Deny-by-default tools wait for the pilot's tool list.

## C3 — The hero card

`SettingsHeroDevice.resolve(phase:glassesAdded:)`, over #604's truthful `GlassesConnectionPhase`:

| Link | Card |
|---|---|
| connected (incl. paused — "Connected · paused") | the glasses |
| connecting | the glasses ("Connecting…" — the moment after a tap on Connect) |
| added, not connected | This iPhone — "In use · Glasses not connected" |
| no glasses | This iPhone — "In use" |

Glasses settings are reachable either way: Devices & Privacy › Glasses is always a row, with the
link's state as its value, and open even on a locked phone.

## C4 — Locked is hidden from the technician (2026-10-04)

**Trigger.** Greig, after using an enrolled phone: *"You should also hide those settings that
operators aren't allowed"*, and *"Why can I remove the Profile from the top of the settings?"*.
C2's "locked is visible" put screens of greyed-out switches in front of a technician who could use
none of them.

**The rule, one place** (`SettingsVisibilityPolicy`, pure, `SettingsVisibilityPolicyTests`):

- A setting the organisation has locked is **not shown to the technician**: no row; a category
  whose every row is locked (`CategoryLock.locked`, renamed from `readOnly`) is not a hub row; a page
  whose only control is pinned is not linked (Agentic Features with Agent Mode pinned off, the MCP
  Server page with the server pinned off). A partly open category (Devices & Privacy) stays a row
  and its screen leaves out the locked rows.
- **The administrator sees everything.** What the lockdown locks is open in an administrator
  session or on an administrator phone; what still binds them — ceilings and closed tools — is
  drawn read-only with "Set by ⟨org⟩", as C2 drew it.
- **A profile without an edition** has no administrator view, so whoever holds the phone is the
  technician: its pinned switches are hidden too.
- **Shown read-only, never hidden** (`alwaysShown`): Blur Bystander Faces pinned on — the protection
  a bystander is relying on — and the routing disclosure. Everything else the person needs
  regardless (Accessibility, Look & Feel, Diagnostics & Support, About, the Organisation section,
  Glasses) is outside any lock already. The Field Assist screen's wake-word row stays as text when
  the screen that owns the phrase is hidden: on a job it is the whole interface.
- **Not concealed.** The hub's Organisation section says *"Some settings are set by ⟨org⟩ and aren't
  shown."* Its "Managed by ⟨org⟩" row opens the organisation's page, which lists what is not shown on
  this phone, then everything the profile does in force now, in the enrolment review's words (Locks,
  starting values, what this phone shows, installs, supplies, not applied).
- **Remove Profile moved** from the hub to the bottom of that page, under "Leave ⟨org⟩", with the
  records panel, confirmation and device-owner gate of CT PR 4 unchanged. The MDM case still says it
  can only be removed there.
- **Unmanaged phones are unchanged** (every setting editable, the hub the catalogue). There is no
  settings-wide search; the tool list's search draws from the same filtered list, so it cannot
  surface a closed tool. Hidden rows are not built, so VoiceOver cannot reach them; a hidden
  category reached anyway (a session ending under an open screen) draws only a one-line notice.

## Tests

`SettingsHubTests` (order, ids, Simple Mode, pinned accessibility, the script's id mirror, the
reachability inventory, one screen per category), `SettingsHeroDeviceTests`, `ManagedLockdownTests`
+ `ManagedLockdownGateTests` (standard set, deny-by-default complement, pinned open, technician view
vs administrator, partly open Devices, the Field Assist switch, never hidden, profile adjustments and
drops, the applier, lossy decode, review lines, the tool clamp), `EditionPresentationTests` (settings
locked, not hidden), `AIPersonalitySettingsWordingTests` (moved), `BrandNameGuardTests` and
`DataStoreRegistryTests` updated for the moved and removed files. UI tests that seeded
"Show everything" or audited the Discover shelf were rewritten for the single list.

## Decisions (made 2026-10-02 with Greig away)

1. Connecting counts as attached for the hero card; paused does too.
2. "Works with your iPhone" → Connections; Field Assist leaves Tools & Actions; the Connected Glasses
   section becomes the Glasses screen. Services keeps a shortcut from Capture & Streaming.
3. Simple Mode keeps the same five categories; Field Assist is owner configuration.
4. The edition locks instead of hiding; locked rows open read-only. **Superseded by C4
   (2026-10-04): locked is hidden from the technician.**
5. Pinned open: Accessibility, Look & Feel, Diagnostics & Support. Field Assist open by default with
   its master switch locked. Devices & Privacy locked with Glasses and the routing disclosure open.
6. Tools close by name only, read-side, and an administrator session does not reopen them.

## Out of scope

Deny-by-default tools; locking individual rows inside other categories beyond the four named areas;
per-row lock reasons inside read-only screens; the watch (CT's watch propagation still applies).
