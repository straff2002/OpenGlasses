# Plan HB — Field Assist Mode and the Job-Day Card

**Status:** 📋 Planned 2026-10-02 — P0 (pure types) + P1 (views) in one PR.

**Related:** Plan [F](F-field-assist.md) (Field Assist, vaults, procedures), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (the Job tab, upcoming jobs, debriefs, the send queue,
sign-off), Plan [ED](ED-vault-manual-retrieval.md) (manuals in vaults), Plan
[CT](CT-org-configuration-profiles.md) 3b (the edition and what it closes), Plan
[HA](HA-settings-hub-and-org-lockdown.md) (Field Assist as a top-level Settings category, the
lockdown envelope), Plan [GW](GW-home-grid-pages.md) (the home grid's measured height and adaptive
rows), Plan [DY](DY-my-day-everyday-briefing.md) (My Day). Plans
[GX](GX-photo-checked-procedure-steps.md), [GY](GY-procedure-from-narrated-recording.md) and
[GZ](GZ-expert-annotations.md) are drafted Field Assist gaps and are not touched here.

---

## Trigger

Greig, 2026-10-02:

1. "Give the user a shortcut on Modes to Settings › Field Assist. Once Field Assist is enabled, the
   mode changes to Field Assist and the Field Assist logo appears in the bottom bar. Show scenarios
   and quick access to stored manuals, plus anything else useful. Available modes are minimised
   under an accordion." Confirmed the same day: with Field Assist on, the Modes tab **becomes** Field
   Assist.
2. The job-day card: with Field Assist on, the home screen shows the technician's day — today's jobs
   and the job admin still owed — even when My Day is off; My Day's switch only controls the
   personal part.

## What existed (verified 2026-10-02, main at 701328df)

- The Modes tab (`PersonaPickerTab`) already had a Field Assist section above the personas: an
  "Unlock" row when not entitled, "Tap to enable" when entitled and off, and when on a vault
  switcher, a per-vault model picker, a "Manage Field Assist" link and the active vault's procedures
  as "Scenarios" — each started a session through `FieldSessionService.startSession` directly
  (bypassing `GuidedJobFlow`, the job chokepoint) and **silently ended any open job first**.
- The edition (CT 3b) hid the Modes and Chat tabs from the technician
  (`EditionPresentation.hiddenTabs`).
- "Field Assist on" is spelt three ways: `Config.fieldAssistActive` (switch ∧ entitlement, what the
  tools and the injected quick actions read), `JobTabPresence` (switch ∨ edition, with an
  undetermined entitlement drawn as absent) and the settings row.
- The Field Assist mark is the SF Symbol `wrench.and.screwdriver.fill`: the dock's Field Assist
  tile (`QuickAction.fieldAssist`) and the CarPlay jobs tab both wear it.
- Manuals are `VaultDocument`s on installed vault manifests, copied under
  `VaultImporter.baselineDirectory`; `manual_lookup` answers only inside an open job on that vault.
- The home screen's My Day card (`MyDayHomeView`) shows when `myDayEnabled ∧ myDayOnHome` and
  yields to a turn or captions (`HomeSurfaceVisibility`); its height feeds GW's measured
  `heightAboveDock`.
- Nothing on the phone gathered the day's job admin in one place: upcoming jobs, the open job, the
  delivery queue (staged/failed), sign-offs owed and parts requests each live on their own screen.

## Decisions

1. **What "Field Assist mode" is.** Field Assist mode is on when the Field Assist switch is on —
   or the organisation's edition puts the technician's view in force — **and** the entitlement
   grants it (`FieldAssistMode.isOn`; the same "switch ∨ edition" reading `JobTabPresence` already
   uses). While it is on: the Modes tab is the Field Assist tab, the Jobs tab is present, the Field
   Assist quick actions are in the grid, the field tools are registered, and the home screen shows
   the job-day card; during an open job the field tool profile (GD3) narrows the tools, unchanged.
   **It is not a persona.** Personas choose the model, prompt and wake phrase; Field Assist chooses
   what the phone is for. The two are orthogonal.
2. **Modes tab when Field Assist is off** (`ModesTabPresentation.modes(shortcut:)`): a "Field
   Assist" row at the top opens **Settings › Field Assist** (switches to the Settings tab and pushes
   the category, read-only/partly-locked exactly as the hub would open it, and never past the
   Lock Settings owner gate). Entitled → "Turn on for jobs, scenarios and manuals". Not entitled →
   the existing upsell row is kept ("Unlock…", lock glyph; the Settings screen holds the paywall).
   Entitlement lapsed with the switch still on → "Your Field Assist access has ended". Entitlement
   not yet resolved at launch → **no row** (nothing is drawn on a guess, as `JobTabPresence`).
3. **Modes tab when Field Assist is on** (`.fieldAssist(otherModes:)`): titled "Field Assist",
   wearing `wrench.and.screwdriver.fill`. The tab keeps its identity (`MainTab.modes`, privacy-log
   token "modes"); only its title, symbol and content change. Content, in order:
   - **Job** — "Resume Job 1005" / "Start a job" → the Jobs tab.
   - **Vault** — the vault switcher (unchanged) and, outside the edition, the per-vault model.
   - **Scenarios** — the active vault's procedures (see 4).
   - **Manuals** — the installed manuals, active vault first, up to five here and the rest behind
     "All manuals" (searchable). Tap opens the manual itself (the manufacturer's original when
     bundled, otherwise the imported file) in Quick Look. **Ask** appears on a manual only while a
     job is open on its vault — `manual_lookup` only answers inside a job, and a button that sends a
     question the tool will refuse would be a dead end; the footer says so.
   - **Field Assist settings** → Settings › Field Assist.
   - **Other modes** — a collapsed accordion (not remembered: it always comes back collapsed)
     whose header names the persona in use; expanded, it is today's persona picker.
4. **Scenarios are vault procedures**, not playbooks. A procedure belongs to the trade vault the job
   runs on ("Low suction pressure diagnosis") and is what `procedure_runner` executes; playbooks are
   personal checklists with no vault, so they answer "what routine do I follow", not "what job am I
   doing". Tapping one (`FieldAssistScenarioStart`): no job open → confirm, start a job through
   `GuidedJobFlow` (the chokepoint, fixing the old direct `startSession`), run the procedure, go to
   the Jobs tab; a job open on the same vault → "Run in Job 1005"; a job open on **another** vault →
   refused with the reason. **An open job is never ended by a scenario tap** (the old code did).
5. **Picking a persona from the accordion while Field Assist is on** activates that persona
   exactly as the Modes tab always has; Field Assist stays on and the tab stays Field Assist.
   Field Assist is turned off in one place only — Settings › Field Assist.
6. **Lapse revert.** Everything derives from `FieldAssistMode.Inputs` read live (switch, entitlement,
   entitlement-checked, edition) — nothing is written when Field Assist goes on or off. Switch off,
   entitlement expiry and an organisation removing it all produce `.modes(...)` on the next render;
   the tab's navigation stack is rebuilt (`.id` on the presentation), so no pushed Field Assist page
   survives, and the accordion state is not persisted. The quick actions already follow
   `Config.withFieldAssistAction`; the job-day card follows `FieldAssistMode.isOn`.
7. **Org-forced (the edition, technician's view).** Field Assist is on regardless of the switch
   (with a valid organisation licence); the tab is Field Assist; **Other modes is hidden** (not
   locked) because the edition already decided the technician does not choose personas — CT 3b hid
   the whole Modes tab for that reason. Reconciled: `EditionPresentation.hiddenTabs` is now just
   Chat; the Modes slot is drawn as Field Assist. The per-vault model picker is hidden too (the
   organisation chose the model — the same rule as the dock's model tile). An edition whose licence
   has lapsed draws no Modes slot at all (`.hidden`), as before. An administrator session lifts the
   technician's view: the accordion is back.
8. **The job-day card** (`HomeDayCard`, `JobDayComposer`):
   - Shown on the home screen whenever Field Assist mode is on, whatever `myDayEnabled` says; it
     yields to a turn and to captions exactly like My Day. **One card**: when it shows, the My Day
     card does not.
   - Collapsed (the default, remembered under `jobDayCollapsed`), it is one header row: "Today"
     and a one-to-two-line summary — "3 jobs · next 10:30 Smith & Co — 1 report to send". The
     chevron expands it in place (GW's measured height follows on the same curve). Tapping the body
     opens the full-screen day view; every row there opens its own screen, with Done to come back.
   - Order: (a) **jobs** — upcoming jobs scheduled today, the open job, and jobs finished today, in
     time order (scheduled time, else start time) with time, site and status; an upcoming job
     scheduled on an earlier day and never started is listed as **Overdue** rather than dropped;
     (b) **still to do** — an unsaved debrief, reports (failed, then ready to send, then finished
     today and never sent), customer sign-offs owed (only when the organisation requires sign-off),
     parts requests not yet answered — each kind only when non-empty; (c) **My Day** items, folded
     below, only when My Day is on and placed on the home screen, and **not under the edition's
     technician view while Connections is locked** (HA's envelope: My Day's switch lives in
     Connections › Works with your iPhone, which the edition locks by default; a profile that opens
     Connections brings the personal part back).
   - Routes: upcoming job → its page; open job → the Jobs tab; finished job → its page (send report,
     sign-off and debrief all live there); a staged or failed report → its composer (the send
     screen; a failed one is a retry); "report not sent" → the job's page; a debrief → the job's
     page (or the Jobs tab when it is the open job); parts → the job.
   - Empty day: "No jobs today", then the next scheduled job ("Next: Thu 9:00 · Acme") when there
     is one.
   - Scope of "still to do": the queue's waiting and failed entries from the last seven days (a
     failure superseded by a later send of the same document is not owed), and jobs that are open or
     finished today. Older never-sent jobs are left to the Jobs tab — many organisations do not send
     every job, and a card that grew with history would be noise.
   - "Validations" in the request are covered by the customer sign-off; the app has no separate
     validation record, so no row is invented for one.

## P0 — pure types

| Type | File | API |
|---|---|---|
| `FieldAssistMode` | `Services/FieldAssist/Mode/FieldAssistMode.swift` | `Inputs{switchOn, entitled, entitlementChecked, restricted}`, `isOn(_:)` |
| `ModesTabPresentation` | same | `resolve(_:)` → `.modes(shortcut:)` / `.fieldAssist(otherModes:)` / `.hidden`; `title`, `systemImage`, `showsTab`, `isFieldAssist`, `selection(_:after:)`; `FieldAssistShortcut.title/subtitle/showsLock` |
| `FieldAssistScenarioStart` | same | `decide(vaultId:vaultName:vaultUnlocked:openJob:)` → `.startJob` / `.runInOpenJob(label:)` / `.blocked(reason:)`, with the dialog copy |
| `FieldAssistManualShelf` | `Services/FieldAssist/Mode/FieldAssistManualShelf.swift` | `manuals(vaults:activeVaultId:query:)`, `homeLimit`, `canAsk(_:openJobVaultId:)`, `askPrompt(manual:question:)` |
| `HomeDayCard` | `Services/FieldAssist/Mode/FieldAssistMode.swift` | `resolve(fieldAssistOn:myDayEnabled:myDayOnHome:personalLocked:surfaceFree:)` → `.jobDay(showsPersonal:)` / `.myDay` / `.none` |
| `JobDayComposer` / `JobDay` | `Services/FieldAssist/Job/JobDay.swift` | `compose(_ inputs:)` → jobs, to-dos, personal items, next job, summary and its spoken form; `JobDayDestination` routes |

The views only gather facts (`JobDayFeed`, an observable that re-composes when the session service,
the flow, the upcoming store, the send queue or My Day changes, and on the minute) and draw.

## P1 — views

- `MainView`: the Modes slot from `ModesTabPresentation`; a fallback to Avenkin when the slot goes
  away; `AppState.requestedSettingsCategory` switches to Settings.
- `SettingsView`: opens a requested category through the same locked/read-only wrapper as its row,
  and holds the request while the Lock Settings cover is up.
- `PersonaPickerTab`: the shortcut row; its persona sections extracted (`PersonaModeSections`) so
  the Field Assist tab's accordion shows exactly the same picker.
- `FieldAssistModeTab`, `FieldAssistManualsView` (+ the ask sheet).
- `VoiceTab`: `HomeDayCard` decides between `JobDayHomeCard` and `MyDayHomeView`.
- `JobDayHomeCard`, `JobDayView`.
- UI-test seed `-OGUITestSeedFieldDay`: two upcoming jobs today and one tomorrow.

## Tests

`FieldAssistModeTests` (the on/off matrix incl. edition and undetermined entitlement, the Modes
presentation for every input, titles and symbol, the selection fallback, lapse revert,
org-forced), `FieldAssistScenarioStartTests`, `FieldAssistManualShelfTests`, `HomeDayCardTests`,
`JobDayComposerTests` (ordering, statuses, overdue, the to-do kinds and their scoping, routes,
summary line and empty day), `EditionPresentationTests` updated for the reconciled tab set.

## Owed (device)

The Field Assist tab and the job-day card on a phone with a real day of jobs; VoiceOver on the
accordion and the card's two targets; Quick Look on an imported manufacturer PDF.
