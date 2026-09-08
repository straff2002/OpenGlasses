# Plan BQ — Siri & Apple Intelligence Discoverability

**Status: 🚧 P1/P2/P3 + follow-up all shipped** ([#231](https://github.com/straff2002/OpenGlasses/pull/231)/[#232](https://github.com/straff2002/OpenGlasses/pull/232)/[#233](https://github.com/straff2002/OpenGlasses/pull/233)/[#234](https://github.com/straff2002/OpenGlasses/pull/234)); **on-device Apple Intelligence smoke owed.**

*P2 as-built notes:* one generic `GlassesContentEntity` (not per-type entities — the
metadata surface stayed small and the processor accepted it); the `OpenIntent` presents a
generic read-only detail sheet (`SiriContentDetailView` via `AppState.pendingSiriContent`)
rather than per-owning-view navigation — full owning-view deep-links deferred to a rider.
Meeting summaries are filtered from the shared `saved_notes` key by title prefix as
planned (no store migration). Conversations donate title + auto-summary only, and only
while the store is unlocked. Field sessions: per-vault opt-in, metadata-only
(asset/date/outcome/vault), completed sessions only.

Make OpenGlasses' actions *and content* discoverable to Siri, Spotlight, and Apple
Intelligence — and put the exposure surface under user control: a Settings screen where the
user picks which actions Siri can run, and can **create new ones** (a spoken name bound to a
canned assistant prompt or a native tool).

Builds on the Plan AF Siri layer (conversational `AskQuestionIntent`/`AskPersonaIntent`,
`PersonaEntity` + `PersonaQuery` precedent) and the existing ~20 static intents in
`Sources/App/Intents/`. What's missing today, and what this plan adds:

| Gap | Today | After BQ |
|---|---|---|
| Content in Spotlight / semantic index | Nothing (`CoreSpotlight` unused anywhere) | Notes, meeting summaries, saved locations, teleprompter scripts, playbooks, study decks, (opt-in) conversations as `AppEntity + IndexedEntity` |
| User control over Siri surface | None — intents are compile-time, all-or-nothing | Per-action + per-content-type toggles; disabled actions leave the Siri catalog and refuse politely |
| User-defined Siri actions | None (custom *tools* exist, but only the glasses LLM can call them) | "Add Action": name + optional synonyms → runs a canned prompt, a native tool, or an existing custom tool |
| Onscreen content for Siri | `onContinueUserActivity` plumbing exists, nothing donated | Chat thread / note / summary views donate `NSUserActivity` + entity identifier (P3) |

**Curation principle (agreed 2026-07-14):** expose an action to Siri only if it does something
Siri/system apps can't already do — glasses hardware (capture, live modes, listening) or
OpenGlasses' own data (notes, summaries, rewind, briefing). No `where_am_i`, calculator,
weather, timers, unit conversion: those stay glasses-loop-only.

## The runtime-exposure trick

Static `AppIntent`s are compiled into the app's metadata — they cannot be added or removed at
runtime. Everything dynamic therefore routes through **one** generic intent with an
`AppEntity` parameter, because *entity queries are runtime code*:

- `RunGlassesActionIntent` takes `action: SiriActionEntity`.
- `SiriActionQuery` returns only the actions the user has enabled — built-in candidates the
  user toggled on, plus every user-created action. Siri's phrase prediction ("Run *log my
  coffee* on OpenGlasses") is fed from exactly this set.
- Adding/removing/renaming an action = editing data + calling
  `OpenGlassesShortcuts.updateAppShortcutParameters()` (currently called nowhere; the
  `AskPersonaIntent` persona phrase silently depends on launch-time state today — wiring this
  fixes that too).

This is the same pattern `PersonaEntity` already proves out
(`Sources/App/Intents/PersonaEntity.swift:8`), extended to a user-editable catalog.

**Honesty note:** the existing static intents (`TakePhotoIntent`, `ConnectGlassesIntent`, …)
can't be hidden from the Shortcuts app at runtime. Their per-action toggle governs (a)
membership in the `SiriActionEntity` catalog and (b) a runtime guard — a disabled intent
`perform()` returns a "disabled in OpenGlasses Settings → Siri" dialog instead of acting. The
Settings copy says exactly that.

## P1 / PR1 — Exposure core + action catalog 🟢

Deterministic core, fully headless-testable; no CoreSpotlight yet.

**Models (pure, `Sources/Models/`):**
- `SiriActionBinding: Codable` — enum: `.builtin(id)` (maps to an existing intent's behaviour),
  `.prompt(String)` (canned instruction through the normal direct-mode assistant turn, i.e.
  the `AskQuestionIntent` path with the text pre-filled), `.tool(name: String, argsJSON: String)`
  (one native-tool call, result spoken via the intent dialog/snippet), `.customTool(id: String)`
  (existing `CustomToolDefinition` — reuses `CustomToolWrapper` execution), and
  `.capability(kind: CapabilityKind, id: String)` — launches a user-authored capability by id:
  a capture flow (`CaptureFlowLibrary`, Plan U — starts `CaptureFlowRunner`), a procedure
  (`ProcedureLibrary`, incl. custom-vault imports from Plan H — starts `ProcedureRunner`), or
  a playbook (`PlaybookStore` — starts the playbook session).
- `SiriActionDefinition: Codable, Identifiable` — `id`, `displayName`, `synonyms: [String]`,
  `binding`, `isEnabled`, `createdAt`.
- `SiriExposureConfig: Codable` — `enabledBuiltinActions: Set<String>`,
  `userActions: [SiriActionDefinition]`, per-content-type index toggles (P2 reads these).
  Persisted via `Config` static get/set over UserDefaults (house pattern,
  cf. `Config.customTools` at `Config.swift:1266`).

**Catalog (pure):** `SiriActionCatalog` — merges three candidate sources, applies enablement,
resolves an entity id back to a binding, validates user input (non-empty name, name
collisions, tool exists, args JSON parses, tool not in `Config.hipaaDisabledTools` when
`hipaaMode`):

1. **Built-ins** (per the curation principle): take photo, start/stop video, quick vision,
   read text, describe environment, connect/disconnect, listening on/off, the four live
   modes, **memory rewind**, **daily briefing**, **start/stop teleprompter**, **meeting
   summary**, **save this location**, **start broadcast**.
2. **Harvested user-authored capabilities** — the catalog auto-discovers what the user has
   already built and offers each as a toggleable candidate (default off): authored capture
   flows, procedures (incl. custom-vault imports), playbooks, and custom tools. The user
   doesn't hand-wire these; authoring a capture flow makes "Run *pump inspection* on
   OpenGlasses" one toggle away. Harvest adapters are pure (`CapabilityHarvester` per
   library, injected stores) and re-run on library change → `updateAppShortcutParameters()`.
3. **Hand-made actions** — the `.prompt` free-form kind, for anything not expressible as a
   capability.

Agent-flavoured bindings (`.customTool` → shortcut/URL egress, any gateway-touching tool or
skill) are catalog-eligible only when `Config.agentModeEnabled`.

**Intents (`Sources/App/Intents/`):**
- `SiriActionEntity: AppEntity` + `SiriActionQuery: EntityStringQuery` (modelled on
  `PersonaQuery`; reads the catalog through a static provider seam, not `.shared` services,
  so it's unit-testable).
- `RunGlassesActionIntent` — resolves the binding: `.builtin` dispatches to the same
  `AppState` calls the static intents use (via `IntentSupport.awaitConnectedAppState`);
  `.prompt` injects the text into a direct-mode turn; `.tool`/`.customTool` executes through
  `NativeToolRegistry` and returns the string result as the intent dialog + snippet.
- Runtime guards added to the existing static intents (one shared
  `IntentSupport.requireEnabled(_:)` helper).
- App Shortcut: `"Run \(\.$action) on \(.applicationName)"` / `"\(\.$action) with
  \(.applicationName)"`. We're at iOS's 10-shortcut cap — **drop the `AnalyzeFoodIntent`
  shortcut** to make room (the intent survives; food analysis remains reachable via the
  catalog and the glasses loop).
- New non-shortcut discoverable intents for the curated additions that have no intent yet:
  `MemoryRewindIntent`, `DailyBriefingIntent`, `StartTeleprompterIntent`,
  `MeetingSummaryIntent`, `SaveLocationIntent`, `StartBroadcastIntent` — thin wrappers over
  the corresponding tools/services; background-safe ones (`DailyBriefing`, `SaveLocation`,
  `MemoryRewind`) do **not** set `openAppWhenRun`.

**Settings UI:** `SiriExposureView` ("Siri & Search") reached from `SettingsView` — toggle
list for built-ins, add/edit/delete user actions (`SiriActionEditorView`: name, synonyms,
binding picker; binding picker reuses the tool list and `CustomToolsView` patterns). Every
mutation persists via `Config` and calls `updateAppShortcutParameters()`.

**Tests:** catalog merge/enable/validate; binding resolution; HIPAA + agent-mode gating;
query results (enabled-only, string matching over name+synonyms); guard behaviour. No
`.shared` service touched (Wearables fatals headless).

## P2 / PR2 — Content entities + Spotlight index (shipped)

**Adapter seam (pure):** `SiriContentSource` protocol — `type`, `records() -> [IndexableRecord]`
(`id`, `contentType`, `title`, `text`, `keywords`, `date`, `location?`). One small adapter per
store; the messy underlying persistence stays where it is:

| Content type | Backing | Default |
|---|---|---|
| Notes | `NotesStorage` (UserDefaults `nativeTool_savedNotes`) + `ContextualNoteStore` | on |
| Meeting summaries | `saved_notes` records tagged as summaries (they share the notes key today — adapter filters by title prefix; no store migration in this plan) | on |
| Saved locations | UserDefaults `saved_locations` | on |
| Teleprompter scripts | `TeleprompterScriptStore` (JSON file, injectable) | on |
| Playbooks / study decks | `PlaybookStore` / `StudyStore` (injectable dirs) | on |
| Conversations | `ConversationStore` (encrypted JSON, injectable) | **off** (privacy; titles-only when enabled) |
| Field sessions | `FieldSessionService` sessions (encrypted `VaultStore`) | **off** (per-vault opt-in; metadata only) |

**Field sessions get special handling.** The output of a technician visit (asset, dates,
outcome, escalations, billable time, the audit/PDF export) is exactly the record a field
engineer wants findable later — "show me the compressor job from Tuesday" — but it lives in
an *encrypted vault* for compliance reasons, and Spotlight donation copies data out of that
boundary into the system index. So: off by default, opted in **per vault** (not globally),
and the donated record is metadata-only — title (asset + date), outcome, vault name — never
the audit-log body or captured values. The `OpenIntent` deep-links to the session detail
where the full report lives behind the vault. `hipaaMode` hard-disables and purges, same as
everything else.

**Never indexed, not even as candidates:** Health Vault / medical anything, face-recognition
people, memory-rewind audio, agent diary. `Config.hipaaMode` hard-disables *all* donation and
purges the index on enable (mirrors the diarization precedent).

**Entities:** one `AppEntity + IndexedEntity` type per content type (or one generic
`GlassesContentEntity` with a type property — decide at implementation; generic keeps the
metadata surface small), `EntityQuery` reading through the adapters, `Transferable` plain-text
representation (PDF for meeting summaries deferred), and an `OpenGlassesContentIntent`
(`OpenIntent`) that opens the app and routes via a new `AppState.pendingDeepLink` to the
owning view (chat thread, note list filtered, teleprompter script, …).

**Index maintenance (deterministic core + thin edge):** `IndexPlanner` (pure) diffs
`[IndexableRecord]` + `SiriExposureConfig` against the last-donated snapshot → add/update/
delete operations; `SpotlightIndexService` (edge) applies them via `CSSearchableIndex`,
re-plans on store change notifications and app-foreground, full purge on toggle-off/HIPAA.
Tests cover the planner exhaustively; the edge is a dumb executor.

## P3 / PR3 — Onscreen content + camera App Schema (shipped; on-device Apple Intelligence smoke owed)

- `siriOnscreenContent` modifier: `NSUserActivity` + `appEntityIdentifier` donation from
  `ChatThreadView` (thread title/summary only) and `SiriContentDetailView` — "Siri,
  summarize this". Dedicated note/summary detail views don't exist (those stores render
  through Settings editors), so the Spotlight-result detail sheet is the second surface.
- Camera schema via the current **`@AppIntent(schema: .camera.startCapture/.stopCapture)`**
  macros (`@AssistantIntent` is deprecated in the iOS 27 SDK). Shape (metadata-processor
  verified): `startCapture` requires `captureMode`/`timerDuration`/`device`, each an
  `@AppEnum(schema: .camera.*)` — v1 honours mode (photo→silent capture, video→recorder),
  timer/device accepted but immediate/glasses-only.
- **Assistant schema** — shipped same-day as a follow-up ([#234](https://github.com/straff2002/OpenGlasses/pull/234)): `@AppIntent(schema: .assistant.activate)` twin of
  `AskOpenGlassesIntent` — registers OpenGlasses as a *voice assistant* for the side-button
  assistant slot. iOS 26.2+ only (`@available`-gated; the domain doesn't exist below), and
  the schema contract requires `supportedModes = .foreground` instead of `openAppWhenRun`
  (metadata-processor enforced). **Region reality (verified 2026-07-15): the user-facing
  surface is Japan-only** — Apple Account region = Japan + physically in Japan, mandated by
  Japan's Mobile Software Competition Act (Dec 2025); reporting says developers "opt in",
  so an entitlement/App Store Connect capability may also be needed — check when a Japan
  user or region expansion (EU DMA is the likely next) makes this live. Zero cost to carry:
  dormant elsewhere, `AskOpenGlassesIntent` + Action-button shortcut remain the global path.
- On-device Apple Intelligence verification (phrases, onscreen "this" resolution, assistant
  activation) deferred to a hardware session, same rhythm as BJ/BO smoke gates.

**Riders (from WWDC26 App Schemas guidance):**
- Per-item `.appEntityIdentifier()` annotations in list views (chat messages, script list)
  — the multi-item onscreen story; `NSUserActivity` covers only the single primary item.
- `IntentValueRepresentation` on `GlassesContentEntity.transferRepresentation` so other
  apps' intents can consume entities (current: plain-text proxy only).
- Adopt the `AppIntentsTesting` framework for isolated intent tests (would let the curated
  intents be exercised headless instead of guard-level-only).
- Consider `@AppEntity(schema:)` domain adoption if a content domain lands that fits notes
  (`journal`?) — generic entity today.

## Gotchas (project-verified)

- **App Shortcut phrases interpolate only `AppEntity`/`AppEnum`** — a free `String` halts
  `appintentsmetadataprocessor` and wipes *all* intent metadata, and **only a Release/SDK
  build catches it**. Release build is part of the PR gate anyway; treat it as the metadata
  check too.
- **Intent/entity display strings must not contain "apple"** (ITMS-90626) — mind "Siri &
  Search" copy, avoid "Apple Intelligence" in `IntentDescription`s.
- **10 App Shortcut cap** — enforced at build; P1 swaps AnalyzeFood out.
- `updateAppShortcutParameters()` after every catalog mutation, and once at launch.
- Entity queries/adapters must read through injectable seams — `.shared` services pull in
  `Wearables` which fatals in headless tests.
- Spotlight donation must key on stable ids so re-donation updates rather than duplicates;
  `NotesStorage` records have no id today → adapter derives a content-hash id (documented
  limitation: editing a note re-creates its index entry).

## Escape hatches

- If the generic-entity vs per-type-entity decision fights the metadata processor, fall back
  to per-type entities for the two highest-value types (notes, meeting summaries) and ship
  the rest in a follow-up.
- If `.tool` bindings prove awkward to voice (long results), constrain v1 user actions to
  `.prompt` + `.customTool` and keep `.tool` internal for the built-in list.
