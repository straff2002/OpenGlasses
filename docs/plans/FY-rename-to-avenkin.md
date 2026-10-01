# Plan FY — Rename to Avenkin (a private assistant; glasses become one device among several)

**Status:** 🚧 P1–P3 shipped 2026-09-30; P5 in the private desktop repository; owed on device: pronunciation,
tinted icon, the Avenkin shortcut glyph on the Action button and in Shortcuts; owner: App Store listing text.
**2026-10-01:** Siri answers to Avenkin only — `INAlternativeAppNames` withdrawn, App Shortcut glyph
is the Avenkin symbol (*P1 → item 3*). P2 built 2026-09-30 on branch `feat/fy-copy` (*P2 → Built*).
Drafted 2026-09-26, revised
2026-09-28 and 2026-09-29. **Built so far (all merged 2026-09-29):** the Home Screen name and icons ([#571](https://github.com/straff2002/OpenGlasses/pull/571), build 422,
*Decisions 2026-09-28 → Branding*); the same Meta sign-in link from any address ([#573](https://github.com/straff2002/OpenGlasses/pull/573)); the
desktop thread's phone-side PR, with the `Contracts/` and `Transport/` moves ([#574](https://github.com/straff2002/OpenGlasses/pull/574)); and a
coming-soon page at avenkin.com, which now serves this repository's Pages site ([#575](https://github.com/straff2002/OpenGlasses/pull/575)). F1 shipped
([#580](https://github.com/straff2002/OpenGlasses/pull/580)): the storage and signing constants renamed to read as keys, values unchanged,
and `StorageIdentifierGuardTests` pinning every D2 identifier. F2, F3 and the base-URL PR built
2026-09-30; rename PR next. P1's rename itself and P3 built 2026-09-30 (*The rename itself → Built*, *P3 → Built*), and P2 the same day (*P2 → Built*); P4 is not being done and P5 is carried out in the private desktop repository. **Every open question was answered 2026-09-29** (*Decisions 2026-09-29 → Open
questions answered*), so P1 and P2 are unblocked. Drafted as Plan FX; relettered FY on 2026-09-28 because Plan FX is
the desktop plan.
**Origin:** The owner's direction of 2026-09-25/26: the product is being renamed **Avenkin**. It is
primarily a **personal AI agent**, sold as a **one-time purchase**, and glasses are optional. Field
Assist stays as the professional tier, presented as **"Field Assist, powered by Avenkin"** and unlocked
by the in-app subscription or a signed licence key, as it is today. The same app, under the same name,
sits on the home screen of both kinds of user. The owner's decisions of 2026-09-28 widen the scope to
the whole product — the desktop app becomes **Avenkin Office** (*Decisions 2026-09-28*). The
decisions of 2026-09-29 settle where the code lives: the phone app stays public in this repository,
and only Avenkin Office moves to a private repository (*Decisions 2026-09-29*).
**Depends on:** nothing in code for F1 and F3. P1 and P2 waited for the desktop thread's phone-side
changes (with the `Contracts/` and `Transport/` moves) to merge into this repository as their own
public PR (*Sequencing*). That PR merged 2026-09-29 ([#574](https://github.com/straff2002/OpenGlasses/pull/574)).
**Related:** [Plan FX](FX-desktop-office-and-device-sync.md) (the phone's connection to Avenkin Office; the
desktop itself is developed in the private desktop repository from 2026-09-29), Plan EE (Field Assist commercial licensing — the
product ids and licence format stay), Plan CT (org profiles and activation keys — the signing domains stay, and add-on entitlements ride on
the profile), Plans FT/FU (the office tools that become add-ons), Plan DQ (privacy copy — the
same PR rule applies to renamed copy), Plan EC (UI localisation — the renamed strings must reach every
language), Plan DB/DD (first run and onboarding — the repositioning lands there), Plan DG (app design
refresh — lists rebranding, renaming and icon work as non-goals; this plan picks them up).

This plan changes **what the product is called and how it describes itself**, and nothing a wearer
has stored. Every identifier that data, purchases, signatures or links depend on keeps its current
`openglasses` spelling; the table in *Decisions and invariants* lists them and why. It covers both
apps: the iPhone app (with its watch, widget and share extension) becomes **Avenkin**, and the desktop
app becomes **Avenkin Office**. The phone work happens in this repository; the desktop work happens
in the private desktop repository (P5).

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

**D1 — The name is Avenkin.** Display name `Avenkin`. Owner's decision, 2026-09-26, after comparing
OhGee, TaskRook and Ogee: Avenkin is a coined word, reads as credible behind "Field Assist, powered
by Avenkin", and is distinctive enough to be a wake word on its own. Pronounced **a-VEN-kin** (the owner's stress, 2026-09-30)
("haven" without the h, plus "kin"); the in-app voices must say it that way (P1 item 9). The desktop
app is **Avenkin Office** (2026-09-28, D9). This supersedes Plan FX's 2026-09-27 note that named the
desktop app plain "Avenkin".

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
| Desktop signed kinds `avenkin.manual-assignment`, `avenkin.managed-job`, `avenkin.office-peer-binding`, `avenkin.preview-*`, and the engine extension `avenkin-model-hook.1` | `Contracts/` (the signed fixtures), `Transport/` (the phone's embedded office transport), `Services/OfficeSync/` — arriving with the desktop thread's phone-side PR — and the desktop's own code in the private desktop repository | Already spelled Avenkin, and they are signing domains like the ones above. They are **never** changed to say "Avenkin Office", or every issued binding, assignment and receipt stops verifying |

**D2a — Frozen until a migration (the desktop).** These desktop identifiers locate a user's data, so
they stay as they are until P5 moves them with a tested migration. Only lab and preview installs exist
today, so this is the cheapest the move will ever be; it must happen before the first production
desktop release, after which the chosen identifier is frozen like D2. The production identifier is
`com.avenkin.office` (open question 11, decided 2026-09-29). Both live in the private desktop
repository from 2026-09-29, and both are pinned there, not here.

| Identifier | Where | What changing it without a migration would break |
|---|---|---|
| Desktop app identifier `com.openglasses.office.lab` | The desktop app's Tauri config (`apps/desktop/src-tauri/tauri.conf.json`) | The OS app-data folder is named after it (`~/Library/Application Support/com.openglasses.office.lab/` on Mac, the equivalent on Windows). It holds the office workspace, the content store, the pairing identity and the administrator key; a new identifier opens an empty office |
| Device Lab bundle id `com.openglasses.avenkin.devicelab` (and `.uitests`) | The Device Lab test app and its guard script | A different app to iOS: the lab's saved binding and queued work stay with the old one |

**D3 — The URL scheme gains `avenkin://`; `openglasses://` is never retired.** Both are registered and
both are accepted everywhere a link is handled. Link *generation* switches to `avenkin://` only in P3's
second step, once the build that accepts it has shipped. Meta DAT's `AppLinkURLScheme` stays
`openglasses://` until the Meta Wearables developer portal registration is changed to match, because
a mismatch breaks the glasses registration callback.

**D4 — Wake word: "avenkin", with no "hey".** It keeps the current design: the default is the bare
name, matched as whole words anywhere in the utterance, so "hey avenkin" is caught too
(`Config.wakePhrase`). `Config.defaultAlternativesForPhrase` records that a phrase without "hey" is
only safe when it is not ordinary speech; three syllables of a coined word pass that test, as
"openglasses" did. Anyone who still has the old default (`openglasses` or `hey openglasses`) is
migrated once; a phrase the user chose is left alone.

**D5 — The assistant's default name becomes Avenkin; a name the user chose is left alone.**
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

**D9 — The desktop app is Avenkin Office** (2026-09-28). It is renamed in this plan's scope (P5), with
the D2a migration. Phone copy that names the desktop says "Avenkin Office".

**D10 — The name change is a script plus a guard test, not a hand edit** (2026-09-28). The visible
rename is done by a re-runnable script over an explicit rule list, and a guard test fails on any
user-visible "OpenGlasses" outside an allowlist. F1's guard stops the rename reaching too far; this
one stops it falling short. The script runs against whatever `main` is when P1 starts, so other
work landing first costs a re-run rather than a hand-resolved conflict (*Sequencing*).

---

## Decisions 2026-09-28

The owner's decisions of 2026-09-28. They are recorded here as settled; the questions still open are
listed at the end of this section and in *Open questions*.

### Scope is the whole product

- The iPhone app becomes **Avenkin**. The desktop app (Plan FX) becomes **Avenkin Office**.
- **Why "Office":** it is the hub that organisations later **buy add-ons for** — the office tools
  already floated in Plans FU and FX, such as an accounting connector, a refrigerant log and
  certifications. "Base" was rejected because it implies everything is included.
- **Add-ons are per-office entitlements.** Each is a named feature in the office's signed licence or
  org profile (Plan CT), pushed to the office's phones through the profile. They are not separate
  apps and not per-phone purchases.

### Add-on entitlements: leave room in the formats (design only)

Nothing is built here. The point is that the licence and profile formats must be able to carry named
add-ons before the first one is sold, so no add-on needs a format break.

- **Where they live today.** The Field Assist licence payload (`LicenseService.LicensePayload`) carries
  `feature`, `licensee`, `issued`, `expires`, `tier`, `plan`, `seats`, `reference`, `packs` and
  `profile`. `packs` is the precedent: a named list the issuer signs and the app reads. The org
  profile (`OrgProfile/ConfigProfile.swift`) carries the licence it rides on in `licenceCode`, and
  that licence's `expires` is the entitlement clock. Ceilings live in the profile's policy envelope.
- **Shape.** One optional, signed list of named add-ons on the licence, for example
  `addOns: [{ "id": "office.refrigerant-log" }]`, with room for an optional per-add-on `expires` so a
  different term later needs no new format. Absent means none. An add-on id names a feature, never a
  price or a tier.
- **Who can grant one.** Only the vendor's licence key. The office receives signed artefacts and
  cannot mint or extend entitlements (Plan FX §6); a phone never enables an add-on locally and never
  infers one from a tier.
- **How phones learn.** Through the profile the office already pushes. Phone-side parts of an add-on
  (for example capturing refrigerant readings) gate on the add-on list through one pure resolver, the
  way `FieldAssistCapability` already resolves capabilities from entitlement evidence (Plan FS PR1).
- **Compatibility.** Older builds ignore an unknown key, which is safe because the signature covers
  the exact bytes and an ignored add-on simply stays off. Unknown add-on ids are ignored too.
- **Coordination.** The desktop thread is changing `LicenseService` and the OrgProfile code now (the
  desktop licence's `organizationID`/`profileID` claims). Add the add-on list in the same reviewed
  schema revision as those claims, or after it, in that thread's code, not in this plan's.
- **Tests, when built:** an absent add-on hides the feature; an unknown id is ignored; a profile
  cannot grant an add-on its licence does not carry; a phone cannot turn one on by itself.

### Repository (reversed 2026-09-29)

The 2026-09-28 decision to move the whole product into one private repository was reversed the next
day: this repository's CI is free only because it is public, and the same CI on a private repository
would be a large monthly bill. See *Decisions 2026-09-29*.

### Branding assets exist

The direction is **Open Span**, committed with PR #571 at `docs/branding/avenkin/bridge/` (its
`README.md` and `open-span/README.md` describe it):

- Vector masters in `open-span/masters/`: `avenkin-mark.svg`, `avenkin-light.svg`, `avenkin-dark.svg`,
  `avenkin-monochrome.svg`, and the same four as `avenkin-office-*.svg`, with 1024-px exports and a
  rebuild script.
- Palette: warm orange `#E77F47`, ivory `#F6F2EB`, charcoal `#202B2D`.
- The two marks share one arch and crossbar. **Avenkin has separated feet; Avenkin Office adds a
  joined foundation**, so the apps differ by silhouette as well as colour.
- P0 and P1's icon work uses these masters rather than new artwork. The review sheet's typography is
  a label, not a wordmark, so the watch wordmark (P1 item 10) still needs one.
- **An early slice merged 2026-09-29: [#571](https://github.com/straff2002/OpenGlasses/pull/571) (build 422).** It sets the Home Screen name — "Avenkin" for
  the app, the Watch app and the widgets, "Avenkin Teleprompter" for the share extension — adds the
  Open Span app icons (light, dark and tinted, for phone and watch), and commits the
  `docs/branding/avenkin/` assets. That is P0 item 3's icon work and P1 item 1's display names; once
  it merges, P1 does not redo them. Because Siri phrases are written with `.applicationName`, they
  already say "Ask Avenkin…" from that build; registering the old name under
  `INAlternativeAppNames`, so "Ask OpenGlasses…" keeps working, belonged in P1 (item 3) — **withdrawn
  2026-10-01** (owner: "it should all be avenkin"): the key is removed and Siri answers to Avenkin
  only. The in-app `OpenGlassesLogo` and `OpenGlassesSymbol` images are not part of it and stay in P0
  item 3.

### Still open from that day

The licence for the desktop's private code, whether the brand orange and the AI accent converge, and
Avenkin Office's production identifier: *Open questions* 9–11. All three, and the public repository's
fate and hosting (questions 7 and 8), were decided on 2026-09-29.

---

## Decisions 2026-09-29

The owner's decisions of 2026-09-29. They supersede the 2026-09-28 repository decision; everything
else from that day stands.

### The phone app stays public

- **The phone app stays in `straff2002/OpenGlasses`**, public, under its existing BSL 1.1 licence.
  CI on this repository is free only because it is public; on a private repository the same CI would
  be a large monthly bill.
- The product is still renamed Avenkin in code and in the store: P1–P3 are unchanged in substance.
- **Xcode Cloud stays connected to this repository.** `origin`, the Actions setup, secrets and
  Dependabot stay where they are, and Pages keeps building from this repository (under a custom
  domain, below); nothing is cut over.

### The site moves to avenkin.com now

- The owner has bought **avenkin.com**. The existing Pages site, still built by this repository's
  `pages.yml`, takes it as its GitHub Pages custom domain **now**, not at launch (P0 item 7).
- GitHub Pages is expected to redirect the old project address `straff2002.github.io/OpenGlasses/…`
  to the custom domain, so shipped builds keep working through the redirect. That is **verified, not
  assumed**, before anything relies on it (P0 item 7's check).
- New builds read every address from one base-URL setting pointing at `https://avenkin.com`, in a
  small PR that can land before P1.

### The repository is renamed late, if ever

- The GitHub repository keeps its name. Renaming it would likely end the
  `straff2002.github.io/OpenGlasses/…` redirect that shipped builds depend on (GitHub does not redirect
  a renamed repository's Pages path).
- Rename only once no supported build reads the old `github.io` addresses, or never: with the custom
  domain, the repository's name is invisible to users (P4). GitHub redirects the repository's web URL
  and git remotes after a rename; Xcode Cloud is checked to follow it.

### Only Avenkin Office is private

- **The desktop app, Avenkin Office, moves to its own private repository** (`straff2002/avenkin-office`;
  this plan calls it "the private desktop repository"). The intent is CI on Linux only, path-filtered.
  **As of 2026-09-29 that isn't in place:** its workflow is dispatch-only and has never had a green
  run, so Office's checks are run locally for now. The macOS and Windows packages are built locally.
- The interim all-private repository created on 2026-09-28 (`straff2002/avenkin`) is retired: its
  Actions are off (2026-09-29) and nothing new goes there. **It is not archived yet:** a few private
  files still exist only there, and move to the private desktop repository first.

### The split boundary

The desktop thread carries out the split. **Anything the phone app needs stays public:**

- The signed contract fixtures move from `Office/contracts` to a top-level **`Contracts/`**.
- The phone's embedded office transport (`Office/mobile-core`, and the vendored sync-engine extension
  it builds from, with its MPL-2.0 licence and notices) moves to a top-level public path such as
  **`Transport/`**, because it is compiled into the phone app.
- **Desktop-only parts leave this repository** and never merge into it: the Tauri app, the Rust
  crates, the Device Lab test app, lab evidence and the desktop scripts.
- The private desktop repository copies `Contracts/` in at a pinned commit. **This repository never
  depends on the private one.**

### Open questions answered

The owner answered the remaining open questions on 2026-09-29. Each is marked in *Open questions*, and
the phases below are written to match:

- **Store listing (Q1):** App Store name "Avenkin: Private AI Assistant", subtitle "Your AI, on your
  terms", tagline "Your AI. Your terms." (P0.1, P2.1).
- **Field Assist and glasses (Q2):** Field Assist users do use glasses, but not all the time. The "Add a
  device" step keeps glasses prominent for them, one tap away, and "Use this phone" stays a complete
  answer (P2.2).
- **Prompt role (Q3):** F3 names the current device, not a device-neutral role.
- **Old wake phrases (Q4):** "OpenGlasses" and "Hey OpenGlasses" stay in the pickers, listed below
  "Avenkin" and "Hey Avenkin", for **one App Store version** (the one that ships P1 and P3; one
  marketing version, not one build), then leave the presets. After that the old name is still usable as
  a custom wake phrase (P3.2).
- **OpenClaw `userAgent` (Q5):** renamed to `avenkin-ios/…` in P1.5; no gateway keys on it.
- **P4 (Q6):** not done. It stays unscheduled, revisited only if the old names confuse contributors.
- **Desktop licence (Q9):** Avenkin Office's private code carries a plain "© 2026 Skunkworks NZ Ltd.
  All rights reserved." notice, with a customer licence agreement shipped with the installer later.
  `Contracts/` and `Transport/` keep this repository's BSL 1.1 (and MPL-2.0 for the vendored sync
  engine).
- **Brand orange and the AI accent (Q10):** they converge. The AI accent becomes the brand orange
  `#E77F47` in P1 (item 11).
- **Avenkin Office's production identifier (Q11):** `com.avenkin.office`. P5 migrates the lab
  identifier to it (D2a).

---

## Sequencing with the desktop work (Plan FX)

The desktop thread's phone-side changes arrive as a **public PR on this repository**: the
`Contracts/` and `Transport/` moves (*Decisions 2026-09-29*), the phone's office-sync code, and no
`Office/` folder. That PR modifies about twenty tracked phone-app files that this rename also
touches: `LicenseService`, `KeychainService`, `StoreKitService`, `FieldAssistSettingsView`,
`MedicalCompliancePaywallView`, `OrgProfile/*` (`ConfigProfile`, `OrgEnrolmentService`,
`OrgProfileManager`, `ProfileVerification`), their tests (`FieldAssistEntitlementTests`,
`OrgEnrolmentServiceTests`, `OrgProfileVerificationTests`, `StoreKitRecoveryTests`),
`Localizable.xcstrings`, `project.tests.yml` and the signing scripts. Two threads editing the same
strings would mean resolving conflicts by hand in exactly the files where a wrong resolution loses keys
or breaks signatures.

1. **F1 lands any time**, as its own PR. It changes no values and no visible names; its overlap with the
   desktop thread's phone-side PR is a few constant renames, which that PR takes on rebase. Landing it
   early also means that PR's own changes are checked by the storage guard.
2. **F3 lands any time**, as before. It touches the prompt code, not the files the phone-side PR
   changes.
3. **P1 and P2 wait** until the desktop thread's phone-side PR has merged. F2 ships inside P1.
4. **The desktop app keeps evolving in the private desktop repository.** It is renamed later in this
   plan's scope (P5), with the D2a migration. P5 stays in this plan as the cross-product checklist,
   but it is carried out in the private desktop repository.
5. **P1's rename is the D10 script plus the guard test**, run against whatever `main` is at the time.
   If more work lands before P1 merges, re-run the script; do not merge renamed strings by hand.

---

## P0 — Store, design, domain and repository (owner and repository work; item 7's base-URL PR is the only app code)

1. **App Store listing text:** name "Avenkin: Private AI Assistant" (29 of 30 characters), subtitle
   "Your AI, on your terms" (both decided 2026-09-29), description, keywords and screenshots, submitted with the P1 build. The name can only
   change with a version submission. The privacy policy, support and marketing URLs in App Store
   Connect follow item 7 (avenkin.com).
2. **Meta Wearables developer portal:** the app's display name. The URL scheme there only changes if
   P3 step 3 goes ahead. Check which redirect page the registration names: `index.html` on the Pages
   site is the Meta auth redirect page; item 7 moves the registration to the avenkin.com page, and the
   old address keeps redirecting.
3. **App icon and logo from the Open Span masters** (*Decisions 2026-09-28*), not new artwork.
   **The branding commit and the app icons merged in [#571](https://github.com/straff2002/OpenGlasses/pull/571)** (*Decisions 2026-09-28 →
   Branding*): the phone's `AppIcon` light, dark and tinted appearances from `avenkin-light`,
   `avenkin-dark` and `avenkin-monochrome`, and the watch icon from the same set. Still to do:
   `OpenGlassesLogo` and `OpenGlassesSymbol` are replaced by the mark, including where onboarding
   shows them (the first-run welcome logo and the Meta AI link row, `OnboardingView.swift`). Avenkin Office uses the
   `avenkin-office-*` set in P5. Check the tinted appearance on a device, as the branding README warns.
4. **The repository and CI stay where they are** (*Decisions 2026-09-29*): `origin`, Xcode Cloud, the
   Actions setup and secrets are unchanged, and there is no cutover. What is still owed here: when the
   desktop thread's phone-side PR adds `Contracts/` and `Transport/`, check that the workflows' path
   filters run the phone jobs that compile or test them. If the repository is ever renamed (P4),
   check that Xcode Cloud follows the rename and that one build and archive completes; GitHub
   redirects git remotes, so clones keep working.
5. *(Removed 2026-09-29: moving the Actions setup — nothing moves.)*
6. *(Removed 2026-09-29: reconnecting Xcode Cloud — it stays connected.)*
7. **Web pages and data files: avenkin.com, now** (open question 8, decided 2026-09-29). The existing
   Pages site, still built and deployed by this repository's `pages.yml` on every push to `main`, takes
   **avenkin.com** as its custom domain. Shipped builds keep reading the old
   `straff2002.github.io/OpenGlasses/…` addresses for as long as they are installed, so **every old
   address below must keep answering, through GitHub Pages' redirect to the custom domain.** That
   redirect is expected but is **verified, not assumed**: `URLSession` follows a 301 for a GET, which is
   all these fetches are, but the check below has to pass before anything relies on it.
   - **Domain setup (owner).** Verify avenkin.com for the account in GitHub (the account's Pages
     settings; a TXT record) **before** adding it to the repository, so no other account can claim
     it. Point the apex at GitHub Pages with its A and AAAA records, and add a `www` CNAME to
     `straff2002.github.io`. Set the custom domain in the repository's Pages settings, and enforce
     HTTPS once the certificate has issued.
   - **New builds (a small PR, can land before P1).** Every address in the table is read from one
     base-URL setting pointing at `https://avenkin.com`, rather than the separate hard-coded strings the
     table lists. From that PR on, builds have no `github.io` address left.
   - **Store and portal.** App Store Connect's privacy, support and marketing URLs switch to
     avenkin.com. The Meta portal redirect registration is updated to the avenkin.com page; the old one
     keeps redirecting.
   - **Publishing does not change.** New activation keys, pack catalog updates and policy or support
     page changes are committed to this repository and deployed by `pages.yml` as today; they appear at
     avenkin.com and, through the redirect, at the old addresses.
   - **Universal Links (an option, not a step).** With a real domain, the
     `.well-known/apple-app-site-association` file is served at the domain root, where iOS would fetch
     it. Universal Links stay off unless the app adds an associated domain for avenkin.com.

   *Check:* for each old address in the table, `curl -sI` returns a redirect to the matching
   `https://avenkin.com/…` path; each new address answers 200 from a clean device with no GitHub login;
   the signed pack catalogs and an activation file fetched through the old address still verify after
   the redirect.

   | Reference | Where it is written | What it is | What needs to change |
   |---|---|---|---|
   | `straff2002.github.io/OpenGlasses/privacy.html` | `SettingsView.swift:146`, App Store Connect privacy URL | The public privacy policy | Old address redirects; new builds and the listing point at avenkin.com; renamed copy moves with D8 |
   | `…/support.html`, `…/about.html` | App Store Connect support and marketing URLs | Support and marketing pages | Same; `support.html:73` and `about.html` link to GitHub issues and the repository, which stay public but should not be where a user is sent to get help |
   | `…/index.html` | Meta Wearables portal registration (check) | Meta auth redirect page (bounces to the `mwdat-…://` scheme) | Old address redirects; the portal registration moves to the avenkin.com page; its "Open OpenGlasses" button text is renamed |
   | `…/.well-known/apple-app-site-association` | `Scripts/stage-pages-site.sh` | Universal Link association (`B9L8ANZQZX.com.openglasses.app`) | Inert today: on a project path iOS does not fetch it, and the committed entitlements carry no associated domain. At the avenkin.com root it becomes fetchable; it matters only if the app adds the associated domain (option above) |
   | `…/skillpacks/catalog.json`, `…/vaultpacks/catalog.json` | `Config.swift:2176`, `Config.swift:2186`, the two pack READMEs | Signed pack catalogs the app downloads | Old address redirects and must still verify; new builds read avenkin.com |
   | `…/activation/` | `ActivationKey.swift:29` (`defaultDirectory`) | Sealed licence files, one per issued activation key (Plan CT 3a) | **Must stay writable and reachable from shipped builds**: every new activation key is published here and shipped builds only look here, so the redirect check covers an activation file |
   | `raw.githubusercontent.com/straff2002/OpenGlasses/main/…/Translations` | `LocalizationManager.swift:45` | Downloadable language packs | **Not served by Pages, so it does not move with the domain.** It keeps answering because the repository stays public; new builds may instead read the translations from the site |
   | `github.com/straff2002/OpenGlasses/issues/new` | `DiagnosticsReportBuilder.swift:86`, asserted in `DiagnosticsReportBuilderTests.swift:174`, `support.html:73` | Report-an-issue link | Replace with the Mail-based support report (Plan FV), whose address can already be set on the phone or by a profile, or a support page; reporting a problem should not need a GitHub account |
   | `github.com/straff2002/OpenGlasses` as OpenRouter `HTTP-Referer` | `LLMService.swift:2056` | A label OpenRouter displays | Point at avenkin.com (with P1 item 5's display labels) |
   | Clone and download URLs | `docs/BUILDING.md:45`, `docs/field-assist-vault-guide.md:61` | Build-from-source and the manual extractor download | Still correct: the repository stays public under its name. Update them only if it is renamed (P4); GitHub redirects them after a rename |
   | PR and commit links | 57 files in `docs/plans/` | History | Leave as they are; they keep resolving, and GitHub redirects them if the repository is ever renamed |

   **Redirects verified 2026-09-30:** each old `straff2002.github.io/OpenGlasses/…` address answers 301
   to the same path on avenkin.com, and `avenkin.com/skillpacks/catalog.json` answers 200. The base-URL
   PR shipped (branch `feat/fy-prereqs`): `PublicSite` (`Utils/PublicSite.swift`) derives the privacy,
   support and about pages, both pack catalogs and the activation directory from `https://avenkin.com`,
   keeping the paths the redirect preserves; the pack catalogs' `UserDefaults` overrides still work. The
   OpenRouter `HTTP-Referer` is the base. The report link in Diagnostics & Support opens the support page
   (no account needed) instead of a GitHub issue, and no longer carries the report in its address.
   The translations address stays on the repository (it is not served by the site).
   `PublicSiteGuardTests` pins every derived address under the base at its old path, and fails on any
   `github.io` or repository address in `OpenGlasses/Sources` outside comments and that one line.

## P1 — The visible name (one PR)

P1 rests on three fixes (F1–F3), all before any copy changes. **F1 lands ahead as its own PR, any
time** (*Sequencing*), so its guard test checks every rename commit after it and the desktop
thread's phone-side PR too. F2 has to ship with the new name, or existing installs keep speaking as
OpenGlasses, so it is P1's first commit. F3 is wrong today regardless of the rename, so it can also
land ahead as its own small PR. The rest of P1 waits for the desktop thread's phone-side PR. The
wake-word migration (D4) stays in P3.

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
   would break ("changing this loses every stored API key"). Once the desktop thread's phone-side PR
   has merged, it also pins the `avenkin.*` signed kinds from D2 as they appear in `Contracts/` and the
   phone's sources. The D2a identifiers live in the private desktop repository, which pins them with
   its own guard until P5 migrates them.

**Exit:** a global replace of `OpenGlasses`/`openglasses` in the Swift sources fails the suite.

**Built 2026-09-29 (PR pending).** Constants renamed to `storageService`/`storageAccount` (Keychain) and
`*SigningDomain` (signing domains, and the audit export's schema); the StoreKit, vault-pack, job-file and
MCP names already read as identifiers and only gained doc comments. `DeepLinkTrust` reads the App Group
from `SharedAppState`, the one file its two targets share; the Share Extension and the two watch targets
keep their literal and the test pins each. The guard spells the old name in pieces, so the same replace
cannot rewrite its expectations. Three corrections to the text above: the org-profile, revocation and
admin-card domains are mirrored in `Scripts/make-org-profile.swift` (only the activation-key domains are in
`generate-field-license.swift`); the audit schema is stamped on exports rather than hashed into the chain;
and the `avenkin.preview-*` kinds and `avenkin-model-hook.1` live only in `Transport/`, so they are pinned
there. Also pinned, though not in D2: the scoped-erasure Keychain service `OpenGlasses.ScopedKey`, the
activation file-id domain `openglasses.activation-id.v1`, the profile and revocation `format` ids, and the
job file's `format`.

### F2 — Keep the assistant's name right across the rename

`AssistantIdentity.resolve` treats a persona named `defaultName` as "not a name anybody picked" and
lets the preference win. The first-run persona is created with the literal `"OpenGlasses"`
(`Config.swift:1574`). Changing `defaultName` to `"Avenkin"` alone would make every existing install's
first-run persona look like a name the user chose, and the assistant would keep calling itself
OpenGlasses.

1. `defaultName` becomes `"Avenkin"`. Add `legacyDefaultNames = ["OpenGlasses"]` and an
   `isDefaultName(_:)` check, and use it everywhere `resolve` or the UI compares against
   `defaultName`.
2. `Config.savedPersonas` creates the first-run persona with `AssistantIdentity.defaultName`, not a
   literal. So do onboarding's name step (`OnboardingView.swift`): the name field's placeholder
   (`TextField("OpenGlasses", …)`) and "Skip — call it OpenGlasses" read `defaultName`, so they follow
   the rename rather than being rewritten by it.
3. A one-time migration, behind a stored flag: a saved persona still named `"OpenGlasses"` is renamed
   `"Avenkin"`, so the Personas list shows the new name too. A stored `assistantDisplayName` of
   `"OpenGlasses"` is cleared, which resets it to the default.
4. Tests: a fresh install speaks as Avenkin; an existing install with the first-run persona speaks as,
   and lists, Avenkin; any other persona name and any other typed name are untouched; the migration
   runs once. Known edge: someone who deliberately named a persona "OpenGlasses" is renamed too. That
   is accepted, and they can rename it back.

**Built 2026-09-30 (PR pending).** `AssistantIdentity.defaultName` is `"Avenkin"`, with
`legacyDefaultNames` and `isDefaultName(_:)`; `resolve`, `Config.assistantDisplayName`, the setter,
Settings' Reset button and the status badge all use the check, so the old default counts as the
default wherever a name is compared (typing it is the same as choosing the default). The first-run
persona, onboarding's placeholder and its "Skip — call it …" button, and Settings' placeholder and
"Reset to …" button read `defaultName`. `Config.migrateAssistantNameToAvenkinIfNeeded()` runs at
launch beside the other Config migrations, behind `assistantNameMigratedToAvenkin_v1`: a persona named
exactly "OpenGlasses" becomes "Avenkin" and a stored display name equal to it is cleared; it reads the
raw stored personas, so a fresh install is not seeded early. The legacy name is spelled in pieces in
the source and in `AssistantNameMigrationTests`, so the rename's find-and-replace cannot turn the
migration into a no-op. Two button titles become format keys ("Skip — call it %@", "Reset to %@"), so
their translations return with the next catalog sync.

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

**Built 2026-09-30 (PR pending).** `AssistantIdentity.Device` (`glasses`, `watch`, `phone`) with
`devicePhrase(glassesConnected:watchOnly:)` — "on smart glasses", "on the user's watch", "on the
user's phone" — and a Chinese counterpart ("智能眼镜上", "用户的手表上", "用户的手机上"). The default
prompt's opening and context line, the four English identity role lines, the navigation and
ultra-concise presets, the fourteen mode presets, the five Chinese openings and the lean cloud prompt
are composed with it; no prompt names a vendor, and the two realtime vision notes lose "Ray-Ban Meta"
too. The default prompt's camera sentence is now device-neutral ("You have a camera."). The device is
read once per turn where the prompt is assembled, through `LLMService.deviceInUse` (set by the app
from its existing glasses link, the same closure pattern as the debrief context), and passed down;
`AssistantIdentity` and `Config` never read it. **Stored prompts stay untouched:** nothing is written
back. Shipped presets were already recomposed on read when their body matched the shipped body
(Plan FE P6), and a built-in the wearer edits stops being built-in; the comparison now folds the
device-dependent sentences and their pre-F3 wording into one form, so a Default preset stored by an
earlier build is recognised as shipped text and follows the device, while a user-owned prompt is
returned byte for byte on every device. **No watch-turn signal exists yet**: the watch's "ask"
starts the phone's own listening and nothing marks a turn as the watch's, so the app passes
`watchOnly: false` and a watch turn reads as the phone until such a signal exists. The EVEN
Realities link is not part of "glasses connected" yet either; its wearers read as the phone, which
is honest if not complete, and never as Ray-Ban Meta. Left for the copy PR (P2): the "glasses camera"
lines in the preset bodies, the Chinese default body's camera line, and the agent-mode document
template — all three done in P2 (*P2 → Built*).

### The rename itself

**How it is done (D10).** The name change is mechanical, so it is a script, and a test proves it
complete:

- `Scripts/rename-to-avenkin.swift` applies an explicit rule list: which files (the `Info.plist`s,
  `Localizable.xcstrings` and `Resources/Translations/*.json`, Swift string literals in views, intents
  and notifications, the website pages and READMEs) and which patterns, with the D2 identifiers,
  legacy-name checks and historical plans excluded. It is idempotent: a second run changes nothing.
  It carries translations across when it renames an `xcstrings` key (item 4).
- `BrandNameGuardTests` scrapes the user-visible string sources (`xcstrings` source text and
  translations, the `Info.plist` display names and usage strings, App Intents phrases, `Text("…")`
  and notification-title literals, the website pages) for "OpenGlasses" and fails on any hit outside
  an allowlist: the D2 and D2a identifiers, F2's `legacyDefaultNames`, item 6's echo stripping, P3's
  wake-phrase migration and old-phrase picker entries. Each allowlist entry says why it stays.
- The items below are the script's rule list. Anything the script cannot do safely (the watch
  wordmark, device-neutral wording, P2's copy) is a hand-written commit on top, and the guard test
  checks it the same way.
- The PR is produced by running the script on current `main`. If `main` moves before merge, rebase
  by re-running the script, not by resolving string conflicts by hand.

1. **Bundle display names:** `CFBundleDisplayName` in the app, `GlassesActivityWidget`,
   `OpenGlassesWatch`, `OpenGlassesWatchWidget` and `OpenGlassesShareExtension` `Info.plist`s, and
   the `project.watch.yml` overrides. The share extension becomes "Avenkin Teleprompter".
   **Done early in [#571](https://github.com/straff2002/OpenGlasses/pull/571)** (merged 2026-09-29): the script's rule for these only confirms
   them, and the guard test keeps them.
2. **Permission prompts** (`NS*UsageDescription` in `OpenGlasses/Info.plist`): the name, and
   device-neutral wording where the permission is not glasses-only (D6). Bluetooth may keep "smart
   glasses" because that is what it is for.
3. **In-app strings:** views, App Intents phrases and responses (`App/Intents/*`: "Ask Avenkin…",
   "Avenkin is not running"; the Siri phrases already follow the display name through
   `.applicationName` since PR #571; P1 added `INAlternativeAppNames` so the old name still
   reached the app, and that was withdrawn 2026-10-01 — Siri answers to Avenkin only), notification titles (`ProactiveAlertService`, `GeofenceTool`), the Live
   Activity default (`LiveActivityManager`), the Settings footer, and the "Avenkin Job" document type
   description. Strings that name the desktop app, which arrive with the desktop thread's phone-app
   PR ("Import Avenkin Setup File", "Pair with Avenkin Office"), consistently say "Avenkin Office"
   (D9).
4. **Localisation:** 44 `Localizable.xcstrings` entries whose source text contains the name. The
   source text is the key, so each renamed entry must carry its translations across. The 32 mentions
   in `Resources/Translations/*.json` get the same treatment. Brand names are not translated.
5. **Outbound product identifiers that are display names, not stored keys:** the OpenRouter
   `X-Title` header (`LLMService.swift:2005`), MCP `clientInfo.name` (`MCPTransport.swift:171`), the
   OpenClaw `displayName` (`OpenClawEventClient.swift:363`), the export and diagnostics file names
   (`openglasses-export`, `openglasses-diagnostics`) and the OpenClaw connect `userAgent`
   (`openglasses-ios/…`, `OpenClawConnectParams.swift:55`). These are labels other systems display,
   and none is a lookup key. The `userAgent` becomes `avenkin-ios/…`; no gateway the owner runs or plans
   keys on it (open question 5, decided 2026-09-29).
6. **Echo stripping:** `LocalOutputPolicy.swift:285` strips a model's echoed speaker label. Add
   `"Avenkin"` and **keep** `"OpenGlasses"`, since old conversation history still carries it.
7. **Docs and website:** `README.md`, `README.zh-CN.md`, `SECURITY.md`, `index.html`, `about.html`,
   `privacy.html`, `support.html`, `docs/BUILDING.md`, `docs/CAPABILITIES.md`, the Field Assist guide.
   The renamed pages are served at avenkin.com (P0 item 7), and the addresses old builds read keep
   answering through the redirect. The GitHub links in these pages change with P0 item 7's table.
   Historical plan documents in `docs/plans/` are **not** rewritten; they record what was true then.
   The plan index gets a one-line note that plans before FY say OpenGlasses (Plan FX already says
   Avenkin, and its "Avenkin" for the desktop means Avenkin Office).
8. **Tests:** 34 test files assert brand strings. Update the assertions to the new copy; do not
   loosen them. That includes the UI test target, not only the unit tests:
   `OnboardingAccessibilityTests` finds the welcome screen by the text "OpenGlasses", and
   `SettingsAccessibilityTests` looks for "Open iOS Settings for OpenGlasses".
9. **Pronunciation.** The assistant says its own name in its identity line and in replies. Check
   "Avenkin" in each voice tier (system voices, Kokoro, the realtime providers) says **a-VEN-kin** (the owner's stress; it is how the app's voices say the name, not how people must);
   where a voice gets it wrong, substitute a spelling it reads correctly at the TTS boundary only,
   never in displayed text or stored data.
10. **The watch wordmark.** `WatchMainView.swift:147–154` draws "OpenGlasses" from four separate
    `Text` pieces ("O", "pen", "G", "lasses"), so a search for the name misses it. Replace it with an
    Avenkin wordmark.
11. **The AI accent becomes the brand orange** (open question 10, decided 2026-09-29). The coral
    `#F08A4B` preset becomes `#E77F47`, changed once in `AppAccent` (the preset stored as `"violet"`),
    not in raw colour literals; any literal copy is routed through the preset in the same commit. The
    accent's rule stands: never violet or cyan. Check contrast in light and dark and in the Dynamic
    Type audit, since the new shade is slightly darker.
12. **The onboarding wake-word hint.** The last onboarding page hard-codes `Say "OpenGlasses" or tap the
    mic…` (`OnboardingView.swift`). It shows the configured wake phrase (`Config.wakePhrase`) instead
    of a literal, so it can never disagree with the setting. This is why P3's wake-phrase migration
    ships in the same App Store version as P1 (*Rollout*): otherwise a new user is told to say
    "Avenkin" while the app still listens for "openglasses".

**Exit:** the app, its extensions, Siri, notifications, the website and the README say Avenkin, and the
assistant introduces itself as Avenkin on an existing install; `rg -i openglasses` finds only D2's kept
identifiers (now pinned by F1), target, module and file names, historical plans, and the legacy-name
checks this plan adds; `BrandNameGuardTests` passes, and a second run of the rename script changes
nothing.

**Built 2026-09-30** (branch `feat/fy-rename`). `Scripts/rename-to-avenkin.swift` holds the rule list
and `BrandNameGuardTests` the allowlist, each entry with its reason; the script's output is its own
commit, and a second run changes nothing (asserted on fixtures and on the tree). Items 1–8 and 10–12
are done; item 9 is owed on device. Deviations and additions:
- The script renames Swift **string literals only**. Comments are history and keep the old name, so
  the exit's `rg -i openglasses` also finds comments; `BrandNameGuardTests` scans every Swift literal
  (not only `Text`/`Label`), so nothing user-visible is missed.
- Kept, and allowlisted with reasons beyond the plan's list: the HealthKit workout metadata key and
  the HL7 `MSH` sending-application field (both keys other systems read), and the catalog and
  translation entries for the old wake phrase's picker label (P3.2).
- The two wake-phrase hints (onboarding and the agent setup) became `Say "%@"…` keys; the script
  carries their translations across with the placeholder. Finnish's inflected form (`…iin`) has its
  own rule.
- Also renamed: `docs/support-reports-guide.md` and the bundled refrigeration vault's prose, which
  the app shows. The README notice now says the rename has happened.
- Item 11: `#E77F47` is written once, in `AccentColors`, and `OGTheme.Token.accent` reads it; the
  light derivative `#B05426` is unchanged (≈ 5.1:1 on white, 4.6:1 on the canvas). The preset keeps
  id `"violet"` and is labelled **Orange**; the old Orange swatch (id `"orange"`) is labelled **Amber**
  so two presets never share a name.
- Item 3: the desktop-naming strings (setup-file import, pairing, the vault receipt's source) say
  Avenkin Office. `INAlternativeAppNames` carried the old name with the hint "open glasses" until
  **2026-10-01**, when the owner withdrew it ("it should all be avenkin"): the key is gone from
  `OpenGlasses/Info.plist`, the rename script no longer shelters it, and `BrandNameGuardTests` fails
  if it returns. The same follow-up replaced the App Shortcut glyph `OpenGlassesSymbol` (the old
  mark) with `AvenkinSymbol`, an SF Symbols template drawn from the Open Span mark with Ultralight,
  Regular and Black small sources plus Regular medium, so every weight and scale interpolates; the
  guard now also checks App Intents metadata, the App Shortcut phrases, short titles and glyphs.
- The UI-test assertions follow the new copy; the UI target is compiled, not run, headless.

## P2 — Repositioning the copy (one PR; can merge with P1; waits for the desktop thread's phone-side PR, as P1 does)

1. **Positioning and tagline.** Lead with *private* and *yours*, and put glasses last:
   - One sentence: *Avenkin is a private AI assistant that works for you, not for a platform: your
     choice of AI, your memory on your device, on your phone, your watch or your glasses.*
   - Tagline: **"Your AI. Your terms."** (decided 2026-09-29)
   - Device line: **"On your phone, from your wrist, or hands-free with glasses."** Not "better with
     your watch": today the watch is a remote that needs the phone nearby, and most of its controls
     drive glasses (Plan CS drafts the standalone watch). The copy can say more when CS ships.
   - Claims stay as precise as the README's: "offline" and "fully private" only for the on-device
     setup; "buy once, no subscription to us", since cloud AI providers bill their own usage.
   Final wording is the owner's.
2. **Onboarding** (`OnboardingView.swift`, Plans DB/DD): lead with the agent (name, voice, model,
   memory). Devices become an "Add a device" step where glasses are one choice and "Use this phone"
   is a complete answer. Field Assist users do use glasses, though not all the time (open question 2),
   so for them glasses stay prominent, one tap away. "Skip — no glasses yet" goes.
3. **System prompts:** done in P1 (F3).
4. **The glasses-copy sweep:** the ~59 UI strings and 34 `Info.plist` lines. Each keeps "glasses"
   only when the feature needs glasses (D6). The sweep produces a short table in the PR description
   of what kept the word and why.
5. **Field Assist surfaces:** "Field Assist, powered by Avenkin" in Settings → Field Assist, the
   licence page, the paywall and the Field Assist guide.

**Exit:** a first run with no glasses never shows a screen that treats the user as unfinished, and
the assistant does not describe itself as a glasses product during a phone-only session.

**Built 2026-09-30** (branch `feat/fy-copy`, one PR; no build bump — the rename PR's build 430 is the
TestFlight build this ships in).

1. **Positioning.** The tagline, the P2.1 sentence and the device line, verbatim, open the README
   (and its Chinese translation), `about.html` and `index.html`; the onboarding welcome page carries
   the tagline and the sentence, and the Settings About footer the tagline and the device line.
   Claims stay as precise as the README's: "offline" only for the on-device setup (local AI, speech
   recognition and voice), and "buy once, with no subscription to us — a cloud AI provider you choose
   bills its own usage". The Quick Start and *What you need* say the phone is enough on its own and
   glasses are an addition, not "explore without glasses".
2. **Onboarding.** `OnboardingFlow` (`Services/Flow/`) holds the page order and the device step's
   answers, out of the view. The device page moved after the assistant's pages and became **Add a
   device**; nothing else moved:

   | | Before | After |
   |---|---|---|
   | 1–5 | Welcome, Choose your AI, Access key, Services, Permissions | unchanged |
   | 6 | Connect Your Glasses | Name Your Assistant |
   | 7 | Name Your Assistant | **Add a device** |
   | 8 | Ready | Ready |

   The step lists **This iPhone** as a device that is already *Ready* and offers **Use this phone** as
   its primary button, which ends the step; **Add smart glasses** is one tap below it and brings up
   the camera and Meta AI rows, after which the buttons are Continue and Use this phone. The glasses
   rows start open for someone set up for Field Assist (an activated licence or a managed phone),
   per open question 2. "Skip — no glasses yet" is gone. There is no memory page to lead with, so
   "memory" is carried by the positioning sentence on the welcome page. Every permission and safety
   page is where it was, `OnboardingAccessibilityTests` reads the new tagline and still counts eight
   pages, and no accessibility identifier changed (the flow has none; VoiceOver focus follows the page
   index as before). The Bluetooth row on the permissions page says "To connect smart glasses, if you
   use them", and the Meta hint now points at "the Permissions page" rather than "the previous page".
3. **After the first run.** The exit reaches past onboarding: the session card used to headline
   "Glasses Not Connected" and the Settings hub opened on a "Meta Glasses — Not connected" card for
   everyone. `Config.glassesAdded` (UserDefaults `glassesAdded`) records that someone uses glasses —
   set when they choose glasses on the device step or when glasses connect. Until then
   `OnboardingFlow.phoneIsTheDevice` is true: the session card reports the session (Ready,
   Listening…, Speaking…), the glasses pill is quiet and says "Not added" instead of an error-coloured
   "Disconnected", and the hub's device card is **This iPhone — In use**. Someone who has added
   glasses sees their state exactly as before.
4. **The glasses-copy sweep** — the table below. `BrandNameGuardTests.GlassesCopyGuard` scrapes the
   phone-only surfaces (onboarding, the Settings hub and its general screens, the Chat tab and the
   conversation list, the model and prompt settings) and fails on "glasses" standing as a word in any
   string literal there that is not on its list, each entry with its reason; a stale entry fails too.
5. **Field Assist.** `FieldAssistPaywallCopy.poweredBy` — "Field Assist, powered by Avenkin" — heads
   the paywall's locked block and the licence (entitlement) section; the Settings → Field Assist footer
   opens with it, as do the vault guide's byline and the README's Field Assist section.
6. **F3's leftovers.** The seventeen English "You CAN see images from the glasses camera" preset
   lines and the six Chinese camera lines (the Chinese Default's included) say "the camera"; the
   on-device photo prompt and the cloud image note say "the camera" / "the user's camera". A stored
   built-in seeded by an earlier build is still recognised as shipped text: `Config.legacyCameraLines`
   folds the old lines onto the new for comparison only, so it follows the new wording and nothing
   stored is rewritten. The agent-mode templates (`AgentDocumentStore.defaultSoul`/`defaultSkills`)
   and the agent's first-run prompt no longer say the agent "lives on Ray-Ban Meta smart glasses"; they
   name the phone, the watch and glasses when worn, and say "user" where they said "wearer". Existing
   agent documents are the user's own files and are not touched.
7. **Localisation.** `Localizable.xcstrings` was edited by hand, not by a build: twenty keys renamed
   where the English changed, one removed ("Skip — no glasses yet"), eight added for new strings.
   Each carries a Russian translation rewritten to the new meaning — carrying the old one across would
   have kept "glasses" in Russian — and the catalog keeps Xcode's formatting and key order. The
   downloadable translations had none of the changed keys.

**Tests.** `OnboardingFlowTests` walks the phone path from the welcome page to completion (every page
once, "Use this phone" ends the step, nothing recorded, the session card reports the phone), pins the
order and the organisation shortcut's page numbers, and the glasses answer and Field Assist opening.
The assistant's phone-only identity is F3's `DeviceIdentityTests.testAPhoneOnlyPromptContainsNoGlasses`;
P2 adds `testNoShippedPresetBodyAssumesGlassesOnAPhone`, the stored pre-P2 preset and the agent
template. `BrandNameGuardTests` gains the glasses guard, the onboarding phrases that must not return,
the Field Assist naming and the verbatim positioning.

### Sweep 2026-09-30

Scope: every string literal under `OpenGlasses/Sources/App` (views, App Intents, support reports) and
the watch that says "glasses" as a word, the user-visible service strings that do, and the
`OpenGlasses/Info.plist` usage strings. The plan's "~59 UI strings and 34 plist lines" were counted
before P1: P1 already made 21 of the plist's usage strings device-neutral, and 2 still mention glasses.
Rule (D6): keep "glasses" only when the feature needs glasses — the glasses' camera stream, the
in-lens HUD, the glasses' mic or Bluetooth link, the glasses themselves — otherwise say the device the
feature runs on, or nothing. Still photos fall back to the phone's camera (`CameraService.capturePhoto`),
so photo features are device-neutral; live video, narration, fingerspelling and the reading
companion need the glasses' stream.

**Changed — 33 strings**

| Where | Before → after | Why |
|---|---|---|
| Onboarding welcome | "AI assistant for your smart glasses" → "Your AI. Your terms." + the P2.1 sentence | Leads with the assistant; glasses are one device of three |
| Onboarding device page (title, subtitle) | "Connect Your Glasses" / "Authorize camera access and link Avenkin to the Meta AI app." → "Add a device" / "Avenkin works on this iPhone. Add glasses now, or whenever you like in Settings." | The phone is a device, not a missing one |
| Onboarding device page | "Skip — no glasses yet" → removed; "Use this phone" | Framed a phone-only user as not set up |
| Onboarding permissions (Bluetooth) | "To connect to your Ray-Ban Meta glasses" → "To connect smart glasses, if you use them" | Kept the word (Bluetooth is for glasses); no vendor, not a requirement |
| Onboarding device page (Camera) | "…from your Ray-Ban Meta glasses" → "…from your Meta glasses" | Kept the word; the registration is Meta's, not one model's |
| Chat tab, conversation list (3) | "…works with or without your glasses." ×2, "Talk to your glasses or type…" → "Start a chat by typing a message.", "Type a message below to start.", "Talk or type a message, and it will show up here." | Chat runs on the phone |
| Model settings (2) | "Turn on Vision to send photos from your glasses to the AI…" → "…send photos to the AI…" | Photos come from either camera |
| Prompt inspector (2) | "…images from the glasses camera…", "…the glasses camera is available." → "the camera", "a camera" | Matches the device-neutral prompts |
| Hardware & Privacy (face blur) | "…faces in the glasses camera feed…" → "…in the camera feed…" | The blur applies to every outbound frame |
| Accessibility (reading) | "Reads text through the glasses camera…" → "…through the camera…" | `reading_assist` takes a still, which falls back to the phone |
| Quick action editor | "Captures a still through the glasses (or the phone)…" → "Captures a still from the camera…" | Device-neutral |
| Agent features (image for remote agents) | "…one still from the glasses camera…" → "…from the camera…" | Device-neutral still |
| Support report, Diagnostics footer (2) | "Plus this phone and the glasses…", "…this phone, the glasses and…" → "…any connected glasses…" | Said the user has glasses |
| Gateway Remote Invoke footer | "ask the glasses to act (speak, show text…" → "ask Avenkin to act (speak, show text on the glasses…" | Speaking and status run on the phone; only the text display needs glasses |
| Settings hub, screen title (3 sites) | "Glasses & Privacy" → "Devices & Privacy" | The screen holds mic, face blur, encryption and Medical Compliance; the glasses' own rows live inside it |
| Cross-references (3) | "…under Glasses & Privacy → Hardware & Privacy…" (HUD screen, evidence review ×2) → "Devices & Privacy" | Follows the rename |
| Settings hub (Diagnostics) | "Test the glasses, camera, and AI…" → "Test your devices and AI…" | General section |
| App Intents (4) | "Take a photo with the glasses and analyze it", "Read text visible through the glasses", "Analyze food nutrition from what the glasses see", "Take a photo with the glasses and describe what you see" → "Take a photo and analyze it", "Read text the camera can see", "…what the camera sees", "Take a photo and describe what you see" | The intents capture a still, which falls back to the phone |
| AI disclosure (structured assessment) | "…an AI assessment from the glasses camera." → "…from the camera." | Either camera |
| Session card headline | "Glasses Not Connected" → the session's own state while no glasses are added | Was the first thing a phone-only user read |
| Session card glasses pill | "Disconnected" (error colour) → "Not added" (quiet) while no glasses are added | Not an error |
| Settings hub device card | "Meta Glasses — Not connected" → "This iPhone — In use" while no glasses are added | The phone is the device |

Prompts (not UI strings, finished from F3): 17 English and 6 Chinese preset camera lines, the
on-device photo prompt, the cloud image note, the agent-mode soul and skills templates and the agent's
first-run prompt — all device-neutral as described in *Built* item 6.

**Kept — 86 strings**

| Where | Strings | Why the feature needs glasses |
|---|---|---|
| App Intents: connect, disconnect, toggle (6) | descriptions and results ("Could not connect to glasses", "Glasses disconnected", …) | They connect the glasses |
| App Intents: capture (5), glasses actions (3) | "Capture Glasses Photo", "Record Glasses Video", "Connect your glasses first.", … | Capture on the glasses' own camera; they fail without glasses rather than fall back |
| App Intents: broadcast (1), camera choice (1) | "Start or stop broadcasting the glasses camera over RTMP", the "Glasses" camera option | Live stream; a named choice beside "Phone" |
| Support report fields (3) | "Glasses: connected", "Glasses: not connected", "Glasses display" | Report fields describing the glasses link |
| Hardware & Privacy — the glasses' section (18) | "Connected Glasses", "Update Glasses App/Firmware", "No glasses detected…", "Unavailable on these glasses", SDK-unavailable ×1, companion-app note, wake-mic and mic-route explanations, camera-off note, "Glasses Display (HUD)" + note, translation-mic note, "Glasses Only Audio" + note, "Glasses Analytics" + note, the privacy footer's glasses-SDK sentence | The glasses' hardware, firmware, mic, HUD and SDK |
| Settings hub (2) | the device card's "Meta Glasses" once glasses are added; the About footer's device line | Names the glasses in use; the owner's device line |
| Voice & Triggers (1) | temple double-tap | A gesture on the glasses |
| Display & HUD screens (6) | HUD toggle + note (journey screen), EVEN display picker, web HUD mirror ×3 | In-lens display |
| Accessibility (3) | scene narration, fingerspelling ×2 | The glasses' live camera stream |
| Reading companion, teleprompter, navigation, translation, digest (5) | "…the glasses will follow along", "Point the glasses at a printed…script", "the glasses menu under Navigate", "the glasses display shows only the line addressed to you", "when the glasses reconnect" | Page capture from the stream; in-lens teleprompter, menu, captions and digest |
| Capture & streaming, live vision, preview (6) | codec note, the "Glasses" Photos album (the existing album's name), RTMP "Stream what your glasses see", live-frame dedup, live preview error, "Paused — no live camera feed from the glasses." | The glasses' video stream; an album that already holds the user's photos |
| Field Assist expert streaming (2), job clips (1) | "How the glasses view reaches the expert", signalling note, "Records up to %lld seconds from the glasses camera" | Glasses video to the expert; the glasses' clip recorder |
| Developer (4) | MCP glasses server ×2, turn-timeline "8 kHz glasses mic", scan assist's wearing side | Glasses camera server; the glasses mic route; a setting about wearing them |
| Skill packs / local models (1), agent cadence (1), diagnostics field (1) | "Needs %@ — connect glasses first", "Faster when glasses are on", "glasses connection" | A glasses capability is missing; behaviour keyed to the connection; a report field |
| Session card (7) | pill "Glasses", "Disconnect Glasses", "Glasses: %@", its two hints, "Glasses Not Connected" (once added), "Glasses Idle" | The glasses link |
| Watch (1) | "Glasses Connected" | The glasses link |
| Onboarding "Add a device" (5) | "Links Avenkin to your glasses via the Meta AI app", "Smart glasses", "Add smart glasses", "Meta glasses, linked through the Meta AI app", its hint | The step where glasses are one choice |
| Onboarding welcome (1) | the P2.1 sentence ("…or your glasses") | The owner's wording, glasses last |
| `Info.plist` (2) | `NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription` ("…connect to your smart glasses (Ray-Ban Meta or EVEN Realities G2)") | Bluetooth is only for glasses (P1 item 2) |

`GlassesCopyGuard` holds thirteen entries — the strings in these two tables that sit on the phone-only
surfaces it scans, plus one category id the hub routes on — each with its reason.

## P3 — Scheme alias and wake-phrase migration (one PR)

1. **Accept `avenkin://` everywhere.** Register it in `CFBundleURLSchemes` next to `openglasses`.
   Replace the scattered `url.scheme == "openglasses"` checks (`OpenGlassesApp.swift:346–472`,
   `SkillPackSideload.swift:34`, `OrgEnrolmentService.swift:95`, `VaultLinkPolicy.swift:54`,
   `Shared/DeepLinkTrust.swift`) with one helper that accepts both, so no path accepts only one.
   Test: every route, both schemes, same result; an unknown scheme is still refused.
2. **Migrate the default wake phrase once**, behind a stored flag: `openglasses` or
   `hey openglasses` → `avenkin`, including on the first-run persona, with alternates in
   `defaultAlternativesForPhrase` for the recogniser splitting or mishearing it (for example
   "aven kin", "haven kin", "avon kin", "avenkins"), each checked against ordinary speech before it
   is added. The picker lists in `SettingsScreens.swift` and `PersonasView.swift` offer "Avenkin" and
   "Hey Avenkin" first, with "OpenGlasses" and "Hey OpenGlasses" listed below them for **one App Store
   version** (the one that ships P1 and P3), then removed from the presets in the next (open question 4,
   decided 2026-09-29). The migration itself stays for good, so an install that skipped a version still
   migrates. (The assistant's name is migrated earlier, in P1 F2.)
   - **The old name lives on as a custom phrase.** The wake word is whatever is stored, not whatever the
     picker lists (`Config.wakePhrase` reads the stored value), so a stored `openglasses` keeps
     working after the presets drop it. `SettingsScreens.swift` already shows a non-preset phrase as
     "Custom: openglasses" and has a "Custom wake phrase" field, so someone who wants it back types it
     in. Keep the `openglasses` and `hey openglasses` cases in `Config.defaultAlternativesForPhrase`,
     which custom phrases also draw on, so the recogniser's splits of the old name stay covered.
   - **One default, not five.** The default is written in five places: `Config.wakePhrase`'s fallback,
     `@AppStorage("wakePhrase")` defaults in `SettingsView.swift` and `SettingsScreens.swift`, the
     picker fallback in `SettingsScreens.swift`, and `PersonasView.swift`'s initial state. All read one
     constant, and `BrandNameGuardTests` catches any literal left behind.
   Tests: an untouched install migrates; a user-chosen phrase survives; the migration runs once; a
   stored phrase no longer in the presets still wakes the app and shows as custom.
3. **Later, in a following release:** generate `avenkin://` links (enrolment links, widget and quick
   action URLs) once the P3 build is what users have. `openglasses://` stays accepted for good. Meta's
   `AppLinkURLScheme` changes only after the portal does (D3).

**Built 2026-09-30** (branch `feat/fy-rename`, with P1). `DeepLinkScheme` sits in
`Shared/DeepLinkTrust.swift`, so the widget compiles it too; `isApp(_:)` is case-insensitive and
replaced fourteen hand-written comparisons (eleven routes in `onOpenURL`, enrolment, skill-pack
sideload, vault links). Generated links read `DeepLinkScheme.generated`, still `openglasses`, until
P3.3. The routing stays inline in `onOpenURL`, so `DeepLinkSchemeTests` asserts "same result" on
what each route consults — the scheme helper, the trust policy, the privacy route and the three
parsers — and fails on any hand-written scheme comparison in the sources.
`Config.defaultWakePhrase`, `legacyDefaultWakePhrases`, `wakePhrasePresets` and
`isCustomWakePhrase(_:presets:)` are the one source for the five default sites and both pickers.
`migrateWakePhraseToAvenkinIfNeeded()` (flag `wakePhraseMigratedToAvenkin_v1`) runs at launch after
F2's; it moves the alternatives with the phrase only while they are still the old phrase's
suggestions (or empty on a persona). Added beyond the plan: a `hey avenkin` alternates case, and the
persona picker shares the settings presets (plus its two extra phrases).

## P4 — Internal rename (not being done; unscheduled)

Targets, schemes, module, folders (`OpenGlasses/`, `OpenGlassesTests/`, `OpenGlassesWatch*`,
`OpenGlassesShareExtension/`), `OpenGlassesApp.swift`, the `OPENGLASSES_*` build conditions and
environment variables, CI `-scheme`/`-only-testing:` lines, and `ci_scripts/`. Mechanical but touches
roughly 600 files, and nobody outside the codebase sees it. **Decided 2026-09-29 (open question 6):
not done**; revisit only if the old names confuse contributors. Never touches D2's identifiers.

**The GitHub repository rename** is separate and also optional (*Decisions 2026-09-29*). GitHub
redirects a renamed repository's web URL and git remotes, but not its Pages path, so a rename would
likely end the `straff2002.github.io/OpenGlasses/…` redirect to avenkin.com that shipped builds rely on
(P0 item 7). Rename only once no supported build reads the old `github.io` addresses, or never: with
the custom domain, users never see the repository's name. If it is renamed: check that Xcode Cloud
follows the rename (one build and archive completes), that the `raw.githubusercontent.com` translations
address still answers for any build that reads it, and update the clone URLs in `docs/`.

## P5 — Avenkin Office (carried out in the private desktop repository; before the first production desktop release)

The desktop app keeps evolving in the private desktop repository under its current names
(*Sequencing*). This phase is carried out there, as that repository's work; it stays in this plan as
the cross-product checklist, so the two apps' names, identifiers and icons move together. It must land
before any production desktop release so the D2a identifiers only ever move once. The only part that
touches this repository is item 4's transport build variables.

1. **Display name:** the desktop `productName` ("Avenkin") becomes "Avenkin Office", with the window
   and menu titles, installer and bundle names, the desktop's own copy and its README. Run it through a
   rule list like the D10 script's, in the private desktop repository.
2. **Production identifier and data migration (D2a).** The production identifier is
   `com.avenkin.office` (open question 11, decided 2026-09-29); the migration moves
   `com.openglasses.office.lab` to it. On first launch of the renamed build: if the old app-data folder exists and the
   new one does not, copy it across, verify the copy (the workspace opens; content digests
   match), switch to the new folder, and leave the old one in place until the office removes it; if both
   exist, use the new one and say that an old folder was left behind; if neither, start empty. The
   administrator key and pairing identity move with the folder and are never regenerated, or every
   phone's peer binding breaks. Tests cover each case and an interrupted copy.
3. **Device Lab:** its bundle id changes only if the lab outlives the production pairing path; it is
   a development harness, so re-pairing it is acceptable and no migration is owed.
4. **Build variables:** the desktop scripts' and CI's `OPENGLASSES_*` variables are renamed in one
   commit in the private desktop repository, reading the old name as a fallback for one release. Any
   such variable in this repository's transport build spec (`project.office-transport.yml`, if it
   survives the split) changes in a phone PR at the same time. Nothing stored depends on them.
5. **Icons:** the `avenkin-office-*` Open Span set for the Mac and Windows app icons.
6. **Never touched:** the `avenkin.*` signed kinds and `avenkin-model-hook.1` (D2).

**Exit:** the installed desktop app says Avenkin Office everywhere; an office installed from the old
build opens with its jobs, manuals, devices and paired phones intact; a brand-name guard in the
private desktop repository covers the desktop's user-visible sources.

---

## Rollout, rollback, and exit criteria

- **Order:** F1 (and F3) land any time, as does PR #571's Home Screen name and icons. P0 item 7's
  move to avenkin.com happens now and does not wait on the rename: the domain first, then the redirect
  check, then the base-URL PR (which can land before P1). The desktop thread's phone-side PR merges
  next. Then P1 + P2 ship as one App Store version with the P0.1 listing text, produced by the rename
  script on the `main` of that day. **P3's wake-phrase migration ships in that same App Store
  version** (P1 item 12). The next App Store version drops the old phrases from the pickers (P3.2),
  and P3.3 is one release later. P5 is carried out in the private desktop repository before its first production release. P4
  and any repository rename stay optional, and the rename comes only after no supported build reads
  the old `github.io` addresses.
- **Field Assist users** are told before the build lands: same app, same subscription, same
  licence, new name. Nothing is re-issued.
- **Rollback:** P1's copy and P2 revert cleanly. F1 changes no values. The F2 and P3 migrations only
  rewrite values that still equal the old defaults, so reverting leaves "Avenkin" and `avenkin` in
  place, which an old build treats as a name and phrase the user chose. No identifier in D2 changes,
  so no rollback can strand data. P5's migration copies rather than moves, so an older desktop build
  still finds its old folder.
- **Done when:** the P0 checks and the P1, P2 and P5 exits hold; `StorageIdentifierGuardTests` and
  `BrandNameGuardTests` exist and pass; both schemes open every route; the migration tests pass;
  `TelemetryOptOutGuardTests` and the full suite are green; the App Store listing reads Avenkin
  and points at avenkin.com; every old address in P0 item 7's table still answers for old builds
  through the redirect, and the signed files fetched that way still verify. (P5's exit is checked in
  the private desktop repository.)

## Open questions for review

All eleven were answered by 2026-09-29 (*Decisions 2026-09-29 → Open questions answered*).

1. **Tagline and App Store name**: the owner's wording for P2.1 and P0.1. **Decided 2026-09-29:**
   "Avenkin: Private AI Assistant", subtitle "Your AI, on your terms", tagline "Your AI. Your terms."
2. **Do Field Assist users use glasses?** If yes, the "Add a device" step keeps glasses
   one tap away; if not, the phone path gets the attention first. **Decided 2026-09-29:** yes, but not
   all the time; glasses stay one tap away for them, and the phone path is still complete.
3. **F3 prompt wording:** the plan names the current device ("on the user's phone"). Say if a
   device-neutral role is preferred instead. **Decided 2026-09-29:** name the current device.
4. **Old wake phrases in the picker:** keep "OpenGlasses" selectable indefinitely, or for one
   release? **Decided 2026-09-29:** one App Store version, listed below the new phrases; after that
   the old name is a custom phrase (P3.2).
5. **OpenClaw `userAgent` (P1.5):** does any gateway you run, or plan to (Plan FU), key on
   `openglasses-ios`? If unsure, keep it and change only the display names. **Decided 2026-09-29:**
   none does; rename it.
6. **P4:** do it at all? **Decided 2026-09-29:** no; unscheduled.

Added 2026-09-28:

7. **The public repository's fate.** **Decided 2026-09-29:** it stays the phone app's public home,
   developed in the open as before, under BSL 1.1 (*Decisions 2026-09-29*). Only Avenkin Office is
   private. The repository may be renamed to Avenkin later, but only once no supported build reads the
   old `github.io` addresses, or never (P4). It is not archived or deleted.
8. **Where the public pages and data files are served from** (P0 item 7). **Decided 2026-09-29:
   avenkin.com, now, through the existing Pages site.** The site is still built by this repository's
   `pages.yml`; avenkin.com becomes its custom domain, and GitHub Pages redirects the old
   `straff2002.github.io/OpenGlasses/…` addresses to it, which makes the move non-breaking for shipped
   builds once P0 item 7's redirect check passes. New builds read every address from one base-URL
   setting pointing at avenkin.com. The translations address on `raw.githubusercontent.com` is not
   served by Pages and stays where it is while the repository is public.
9. **Licence for the desktop's private code.** The phone app keeps BSL 1.1 with the notice
   "© 2026 Skunkworks NZ Ltd" (Change Date 2030-03-24, then Apache 2.0, per `LICENSE`); that is not in
   question. For Avenkin Office's code in the private desktop repository, the options are the same BSL
   terms and notice for consistency, a plain all-rights-reserved notice, or a commercial licence.
   `Contracts/` and `Transport/` are public in this repository, so they carry this repository's
   licence (and, for the vendored sync engine, its own MPL-2.0 terms). The owner decides; nothing in
   this plan depends on it. **Decided 2026-09-29:** a plain "© 2026 Skunkworks NZ Ltd. All rights
   reserved." notice, with a customer licence agreement shipped with the installer later.
10. **Brand orange and the AI accent.** The app's AI accent is coral `#F08A4B`; the brand orange is
    `#E77F47`. They are close enough to read as a mistake side by side. Converge (the AI accent becomes
    the brand orange, or the reverse), or stay deliberately distinct (and far enough apart to look
    intended)? Either way the accent's existing rule (never violet or cyan) still applies.
    **Decided 2026-09-29:** converge; the AI accent becomes `#E77F47` (P1 item 11).
11. **Avenkin Office's production identifier** (P5). Stay in the `com.openglasses.*` family like the
    phone's bundle id (nobody sees it, and the family stays consistent), or start an `avenkin`
    namespace for the desktop? It is frozen once the first production release ships.
    **Decided 2026-09-29:** `com.avenkin.office`.
