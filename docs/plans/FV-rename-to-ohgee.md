# Plan FV — Rename to OhGee (a personal agent; glasses become one device among several)

**Status:** 📝 Drafted 2026-09-26 — for review before any code changes. Nothing is built.
**Origin:** The owner's direction of 2026-09-25/26: the product is being renamed **OhGee**. It is
primarily a **personal AI agent**, sold as a **one-time purchase**, and glasses are optional. Field
Assist stays as the professional tier, presented as **"Field Assist, powered by OhGee"** and unlocked
by the in-app subscription or a signed licence key, as it is today. The same app, under the same name,
sits on the home screen of both kinds of user.
**Depends on:** nothing in code.
**Related:** Plan EE (Field Assist commercial licensing — the product ids and licence format stay),
Plan CT (org profiles and activation keys — the signing domains stay), Plan DQ (privacy copy — the
same PR rule applies to renamed copy), Plan EC (UI localisation — the renamed strings must reach every
language), Plan DB/DD (first run and onboarding — the repositioning lands there).

This plan changes **what the product is called and how it describes itself**, and nothing a wearer
has stored. Every identifier that data, purchases, signatures or links depend on keeps its current
`openglasses` spelling; the table in *Decisions and invariants* lists them and why.

---

## Problem

1. **The name no longer describes the product.** "OpenGlasses" says *glasses* and *open*. The app
   already runs without glasses (phone camera and video sources, the watch client, the display
   backends), and the licence is BSL 1.1, which is source-available, not open source.
2. **The copy assumes glasses.** Onboarding leads with "AI assistant for your smart glasses", the
   glasses step is "Connect Your Glasses", and skipping it reads "Skip — no glasses yet", which frames
   a phone-only user as not set up yet. About 59 UI strings and 34 `Info.plist` lines mention glasses.
   The shipped system prompts say *"a voice assistant on Ray-Ban Meta smart glasses"* (21 lines in
   `Config.swift`), so the assistant describes itself as a glasses product even on a phone.
3. **The glasses dependency is a business risk to put in the name.** The Meta DAT SDK is 0.x and
   breaks its API on minor releases (see the pin note in `project.base.yml`). The product should not
   be named after one vendor's hardware.

## Decisions and invariants

**D1 — The name is OhGee.** Display name `OhGee`, with the capital G. Owner's decision, 2026-09-26.

**D2 — Keep every stored or signed identifier.** Renaming these costs data, purchases or trust, and
buys nothing a user can see:

| Identifier | Where | What renaming would break |
|---|---|---|
| Bundle ids `com.openglasses.app` and its extension ids | `project.base.yml` `bundleIdPrefix`, `project.watch.yml`, `project.tests.yml` | It becomes a different app to Apple: new App ID, the Field Assist products stranded, `.well-known/apple-app-site-association` (`B9L8ANZQZX.com.openglasses.app`) invalid |
| App Group `group.com.openglasses.app` | three `.entitlements`, `GlassesActivityWidget/SharedAppState.swift` | The widget and extensions lose the data they share with the app |
| Keychain service `"OpenGlasses"` | `Services/KeychainService.swift:21` | **Every stored API key disappears.** It looks like the product name, which is why P1 F1 pins it with a guard test |
| Keychain account `com.openglasses.conversation-key` | `Services/ConversationEncryptionService.swift:16` | **Encrypted conversation history becomes unreadable** |
| Signing domains `openglasses.org-profile.v1`, `openglasses.admin-card.v1`, `openglasses.activation-key.v1`, `openglasses.org-revocation.v1`, `openglasses.audit.v1` | `Services/OrgProfile/*`, `HIPAAComplianceService.swift:642`, mirrored in `Scripts/generate-field-license.swift` | Every issued org profile, admin card, activation key, revocation and audit chain stops verifying |
| StoreKit ids `com.openglasses.field_assist_*`, `com.openglasses.medical_compliance_*`, `com.openglasses.vault.*` | `StoreKitService.swift`, `VaultPack.swift` | Product ids can never be renamed in App Store Connect; subscribers would lose Field Assist |
| UTType `com.openglasses.app.job`, MIME `application/vnd.openglasses.job+json` | `OpenGlasses/Info.plist` | `.ogjob` files already sent no longer open in the app |
| Skillpack ids `com.openglasses.*` | `skillpacks/` | Pack identity and the catalog |
| Wire identifiers: `nz.co.skunkworks.openglasses/idempotency-key`, `nz.co.openglasses.bounded-http.*` | `MCPClient.swift:197`, bounded HTTP client | Idempotency and log correlation with MCP servers that already key on them |
| Target, scheme and module names (`OpenGlasses`, `OpenGlassesTests`, …) | `project*.yml`, 549 `@testable import`s, CI workflows | Nothing functional, but a very large diff. Deferred to P4 and optional |

**D3 — The URL scheme gains `ohgee://`; `openglasses://` is never retired.** Both are registered and
both are accepted everywhere a link is handled. Link *generation* switches to `ohgee://` only in P3's
second step, once the build that accepts it has shipped. Meta DAT's `AppLinkURLScheme` stays
`openglasses://` until the Meta Wearables developer portal registration is changed to match, because
a mismatch breaks the glasses registration callback.

**D4 — Wake word: "hey ohgee", never a bare "ohgee".** Said aloud, "OhGee" is the everyday
interjection "oh gee", and `Config.defaultAlternativesForPhrase` already records why a phrase without
"hey" is only safe when it is not ordinary speech. Anyone who still has the old default
(`openglasses` or `hey openglasses`) is migrated once; a phrase the user chose is left alone.

**D5 — The assistant's default name becomes OhGee; a name the user chose is left alone.**
`AssistantIdentity.defaultName` changes, and **the old default is recognised as a default**:
`resolve(preference:personaName:)` compares against `defaultName`, and the migration persona created
on first run (`Config.swift:1574`) stores the literal `"OpenGlasses"`. Without a legacy check, an
existing install would treat `"OpenGlasses"` as a persona the user named and keep speaking as it.
Fixed in P1 (F2), so the name changes in the same release as everything else.

**D6 — Glasses are a first-class option, not the premise.** The product is "a private agent that goes
where you are: phone, watch, or glasses". Copy that describes a glasses-only feature keeps the word
glasses; copy that describes the product or a device-neutral feature drops it.

**D7 — The company name is unchanged.** The company is **Skunkworks NZ Limited**, written
"Skunkworks NZ Ltd" in copy: the copyright lines, `LICENSE`, the privacy, support and about pages and
the contact lines always use the full name, never a bare "Skunkworks NZ". This plan renames the product
only.

**D8 — Privacy copy moves in the same PR as any change to it.** The website privacy page and the
in-app privacy copy are renamed together. The `PrivacyInfo.xcprivacy` manifests mention the name
only in XML comments, which are updated in the same PR; their declarations do not change.
`TelemetryOptOutGuardTests` must stay green (Plan DQ's pairing rule).

---

## P0 — Store and design (owner; no code)

1. **App Store listing text:** name (up to 30 characters, for example "OhGee: Personal AI Agent"),
   subtitle, description, keywords and screenshots, submitted with the P1 build. The name can only
   change with a version submission.
2. **Meta Wearables developer portal:** the app's display name. The URL scheme there only changes if
   P3 step 3 goes ahead.
3. **New app icon and logo** (design task). The current `AppIcon`, `OpenGlassesLogo` and
   `OpenGlassesSymbol` assets depict the old brand. P1 can ship with the current icon if the new one
   is not ready; it should not wait on it.

## P1 — The visible name (one PR)

P1 opens with three fixes (F1–F3) as its first commits, before any copy changes. F1 has to land
first so its guard test checks every rename commit after it. F2 has to ship with the new name, or
existing installs keep speaking as OpenGlasses. F3 is wrong today regardless of the rename, so it
can also land ahead as its own small PR. The wake-word migration (D4) stays in P3.

### F1 — Pin the storage identifiers so a rename cannot reach them

The keychain service that holds **every stored API key** is the literal `"OpenGlasses"`
(`KeychainService.swift:21`). It looks like the product name, so a find-and-replace would silently
empty the keychain on the next launch. The other D2 identifiers carry the same risk in smaller
doses.

1. Rename the constants so they read as storage keys: `KeychainService.service` becomes
   `storageService`, with a doc comment saying it is a storage key and that changing it loses every
   stored key. Do the same for the conversation-key account (`ConversationEncryptionService`), the
   signing domains (`ProfileVerification`'s profile and revocation domains, `AdminSecrets`,
   `ActivationKey`, and `AuditLogExportDocument.currentSchema` in `HIPAAComplianceService.swift`) and
   the StoreKit ids. Raise `private` to `internal` where
   the test needs to read them. **Values do not change.**
2. The App Group string is repeated as a literal in five files across four targets
   (`DeepLinkTrust.swift`, `SharedTeleprompterInbox.swift`, `SharedAppState.swift`,
   `WatchConnectivityService.swift`, `OpenGlassesWatchWidget.swift`). Where targets share source,
   route them through one constant; where they cannot, the guard test pins each copy.
3. Add `StorageIdentifierGuardTests`, the same drift-guard pattern as `TelemetryOptOutGuardTests`.
   It pins each D2 value to its literal, and also checks the App Group string in the three
   `.entitlements` files and the job UTType in `Info.plist`. Each failure message names what a change
   would break ("changing this loses every stored API key").

**Exit:** a global replace of `OpenGlasses`/`openglasses` in the Swift sources fails the suite.

### F2 — Keep the assistant's name right across the rename

`AssistantIdentity.resolve` treats a persona named `defaultName` as "not a name anybody picked" and
lets the preference win. The first-run persona is created with the literal `"OpenGlasses"`
(`Config.swift:1574`). Changing `defaultName` to `"OhGee"` alone would make every existing install's
first-run persona look like a name the user chose, and the assistant would keep calling itself
OpenGlasses.

1. `defaultName` becomes `"OhGee"`. Add `legacyDefaultNames = ["OpenGlasses"]` and an
   `isDefaultName(_:)` check, and use it everywhere `resolve` or the UI compares against
   `defaultName`.
2. `Config.savedPersonas` creates the first-run persona with `AssistantIdentity.defaultName`, not a
   literal.
3. A one-time migration, behind a stored flag: a saved persona still named `"OpenGlasses"` is renamed
   `"OhGee"`, so the Personas list shows the new name too. A stored `assistantDisplayName` of
   `"OpenGlasses"` is cleared, which resets it to the default.
4. Tests: a fresh install speaks as OhGee; an existing install with the first-run persona speaks as,
   and lists, OhGee; any other persona name and any other typed name are untouched; the migration
   runs once. Known edge: someone who deliberately named a persona "OpenGlasses" is renamed too. That
   is accepted, and they can rename it back.

### F3 — Stop the assistant calling itself a glasses product when there are no glasses

The shipped prompts give the assistant a glasses identity whatever the device:

- the four identity role lines "a voice assistant on **Ray-Ban Meta** smart glasses"
  (`Config.swift:890–926`), which are **already wrong for EVEN Realities G2 wearers**;
- the default prompt's "The user is wearing smart glasses…" (`Config.swift:768`);
- about 16 mode presets "… assistant on smart glasses" (`Config.swift:939–1253`).

1. Compose one device phrase at prompt time from the current session: glasses connected → "on smart
   glasses" (no vendor name); watch-only → "on the user's watch"; otherwise → "on the user's phone".
   Build it through `AssistantIdentity`, as the name already is.
2. Saved user prompts, and presets the user has edited, stay byte-for-byte unchanged (the existing
   `AssistantIdentity` rule).
3. Tests: a phone-only prompt contains no "glasses"; a Meta glasses session says smart glasses; a G2
   session never says "Ray-Ban Meta"; a user's own prompt is unchanged.

### The rename itself

1. **Bundle display names:** `CFBundleDisplayName` in the app, `GlassesActivityWidget`,
   `OpenGlassesWatch`, `OpenGlassesWatchWidget` and `OpenGlassesShareExtension` `Info.plist`s, and
   the `project.watch.yml` overrides. The share extension becomes "OhGee Teleprompter".
2. **Permission prompts** (`NS*UsageDescription` in `OpenGlasses/Info.plist`): the name, and
   device-neutral wording where the permission is not glasses-only (D6). Bluetooth may keep "smart
   glasses" because that is what it is for.
3. **In-app strings:** views, App Intents phrases and responses (`App/Intents/*`: "Ask OhGee…",
   "OhGee is not running"), notification titles (`ProactiveAlertService`, `GeofenceTool`), the Live
   Activity default (`LiveActivityManager`), the Settings footer, and the "OhGee Job" document type
   description.
4. **Localisation:** 44 `Localizable.xcstrings` entries whose source text contains the name. The
   source text is the key, so each renamed entry must carry its translations across. The 32 mentions
   in `Resources/Translations/*.json` get the same treatment. Brand names are not translated.
5. **Outbound product identifiers that are display names, not stored keys:** the OpenRouter
   `X-Title` header (`LLMService.swift:2005`), MCP `clientInfo.name` (`MCPTransport.swift:171`), the
   OpenClaw `displayName` (`OpenClawEventClient.swift:363`), the export and diagnostics file names
   (`openglasses-export`, `openglasses-diagnostics`) and the OpenClaw connect `userAgent`
   (`openglasses-ios/…`, `OpenClawConnectParams.swift:55`). These are labels other systems display,
   and none is a lookup key. The `userAgent` is the only one a gateway might filter on, so it is
   checked against the OpenClaw gateway before it changes.
6. **Echo stripping:** `LocalOutputPolicy.swift:285` strips a model's echoed speaker label. Add
   `"OhGee"` and **keep** `"OpenGlasses"`, since old conversation history still carries it.
7. **Docs and website:** `README.md`, `README.zh-CN.md`, `SECURITY.md`, `index.html`, `about.html`,
   `privacy.html`, `support.html`, `docs/BUILDING.md`, `docs/CAPABILITIES.md`, the Field Assist guide.
   Historical plan documents in `docs/plans/` are **not** rewritten; they record what was true then.
   The plan index gets a one-line note that plans before FV say OpenGlasses.
8. **Tests:** 34 test files assert brand strings. Update the assertions to the new copy; do not
   loosen them.

**Exit:** the app, its extensions, Siri, notifications, the website and the README say OhGee, and the
assistant introduces itself as OhGee on an existing install; `rg -i openglasses` finds only D2's kept
identifiers (now pinned by F1), target, module and file names, historical plans, and the legacy-name
checks this plan adds.

## P2 — Repositioning the copy (one PR; can merge with P1)

1. **Tagline:** "AI assistant for your smart glasses" becomes, for example, "Your private AI agent —
   on your phone, your watch, or your glasses". Final wording is the owner's.
2. **Onboarding** (`OnboardingView.swift`, Plans DB/DD): lead with the agent (name, voice, model,
   memory). Devices become an "Add a device" step where glasses are one choice and "Use this phone"
   is a complete answer. "Skip — no glasses yet" goes.
3. **System prompts:** done in P1 (F3).
4. **The glasses-copy sweep:** the ~59 UI strings and 34 `Info.plist` lines. Each keeps "glasses"
   only when the feature needs glasses (D6). The sweep produces a short table in the PR description
   of what kept the word and why.
5. **Field Assist surfaces:** "Field Assist, powered by OhGee" in Settings → Field Assist, the
   licence page, the paywall and the Field Assist guide.

**Exit:** a first run with no glasses never shows a screen that treats the user as unfinished, and
the assistant does not describe itself as a glasses product during a phone-only session.

## P3 — Scheme alias and wake-phrase migration (one PR)

1. **Accept `ohgee://` everywhere.** Register it in `CFBundleURLSchemes` next to `openglasses`.
   Replace the scattered `url.scheme == "openglasses"` checks (`OpenGlassesApp.swift:346–472`,
   `SkillPackSideload.swift:34`, `OrgEnrolmentService.swift:95`, `VaultLinkPolicy.swift:54`,
   `Shared/DeepLinkTrust.swift`) with one helper that accepts both, so no path accepts only one.
   Test: every route, both schemes, same result; an unknown scheme is still refused.
2. **Migrate the default wake phrase once**, behind a stored flag: `openglasses` or
   `hey openglasses` → `hey ohgee`, including on the first-run persona, with new alternates in
   `defaultAlternativesForPhrase` (for example "hey oh gee", "hey o g", "hey og"). The picker lists in
   `SettingsScreens.swift` and `PersonasView.swift` offer "Hey OhGee" and keep the old phrases
   selectable. (The assistant's name is migrated earlier, in P1 F2.)
   Tests: an untouched install migrates; a user-chosen phrase survives; the migration runs once.
3. **Later, in a following release:** generate `ohgee://` links (enrolment links, widget and quick
   action URLs) once the P3 build is what users have. `openglasses://` stays accepted for good. Meta's
   `AppLinkURLScheme` changes only after the portal does (D3).

## P4 — Internal rename (optional; separate PR; not scheduled)

Targets, schemes, module, folders (`OpenGlasses/`, `OpenGlassesTests/`, `OpenGlassesWatch*`,
`OpenGlassesShareExtension/`), `OpenGlassesApp.swift`, the `OPENGLASSES_*` build conditions and
environment variables, CI `-scheme`/`-only-testing:` lines, and `ci_scripts/`. Mechanical but touches
roughly 600 files, and nobody outside the codebase sees it. Worth doing only if the old name confuses
contributors. Never touches D2's identifiers. The GitHub repo rename is separate (GitHub redirects the
old URL).

---

## Rollout, rollback, and exit criteria

- **Order:** P1 + P2 ship as one App Store version with the P0.1 listing text. P3 can ride the same version or the next. P3.3 is one release later.
- **Field Assist users** are told before the build lands: same app, same subscription, same
  licence, new name. Nothing is re-issued.
- **Rollback:** P1's copy and P2 revert cleanly. F1 changes no values. The F2 and P3 migrations only
  rewrite values that still equal the old defaults, so reverting leaves "OhGee" and `hey ohgee` in
  place, which an old build treats as a name and phrase the user chose. No identifier in D2 changes,
  so no rollback can strand data.
- **Done when:** the P1 and P2 exits hold; `StorageIdentifierGuardTests` exists and passes; both
  schemes open every route; the migration tests pass; `TelemetryOptOutGuardTests` and the full suite
  are green; the App Store listing reads OhGee.

## Open questions for review

1. **Tagline and App Store name**: the owner's wording for P2.1 and P0.1.
2. **Do Field Assist users use glasses?** If yes, the "Add a device" step keeps glasses
   one tap away; if not, the phone path gets the attention first.
3. **F3 prompt wording:** the plan names the current device ("on the user's phone"). Say if a
   device-neutral role is preferred instead.
4. **Old wake phrases in the picker:** keep "OpenGlasses" selectable indefinitely, or for one
   release?
5. **OpenClaw `userAgent` (P1.5):** does any gateway you run, or plan to (Plan FU), key on
   `openglasses-ios`? If unsure, keep it and change only the display names.
6. **P4:** do it at all?
