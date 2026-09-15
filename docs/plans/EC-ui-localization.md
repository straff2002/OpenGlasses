# Plan EC — Automatic UI Localization

**Status:** 🚧 Started (planned 2026-09-02; progress below, 2026-09-15). One P1 prerequisite fix
and two catalog syncs have landed; P1 items 1 and 2, plural variants, all of P2 and all of P3
remain. No translations have been added.
**Origin:** The design-kit `LocalizedStringKey` conversion ([#394](https://github.com/straff2002/OpenGlasses/pull/394))
made the string catalog able to see the app's authored copy, and the owner decision followed the same
day: the UI should render in the phone's language. iOS does the "automatic" part natively — the
bundle ships translated catalogs and the system picks per the phone's language list — so this plan
is about making the catalog *worth picking*: today it holds 1,864 keys (+65 pending in #394) of
which an early 178-key slice was translated into seven languages and then everything shipped since
drifted in English-only. A German phone currently gets a ~9% German mix; a Dutch phone gets pure
English.
**Priority:** P1 close the verbatim gaps, P2 guardrails + honest declarations, P3 translated
catalogs. Two PRs: P1+P2 (code, reviewable), then P3 (mechanical per-language catalog commits).

---

## Progress (2026-09-15)

**Landed.**
- **Literal copy in the design kit reaches the catalog again** ([#483](https://github.com/straff2002/OpenGlasses/pull/483)).
  Commit 5b35f09f added generic `init<S: StringProtocol>` verbatim overloads beside the
  `LocalizedStringKey` ones, and none of them was disfavoured. A string literal's default type,
  `String`, therefore won, so literal copy at call sites took the verbatim path. It rendered the
  same in English but was never extracted. `@_disfavoredOverload` now sits on the verbatim
  initializers of `OGRow` (trailing and value forms), `OGBadge`, `OGNotice` and `OGStatusLabel` in
  `OGDesign.swift`, as it does on `Text`'s own. A compiler-verified audit found that 51 of 74 call
  sites now resolve to the localized form, with no call-site edits. `OGDesignVerbatimOverloadGuardTests`
  scans the source so a new unattributed generic overload fails the suite.
- **Catalog syncs** [#481](https://github.com/straff2002/OpenGlasses/pull/481) (+19 keys) and
  [#483](https://github.com/straff2002/OpenGlasses/pull/483) (+41 keys), with no translations
  added. The catalog now holds 2,145 keys, and the same 178 carry any translation.

**Still open.**
- P1 item 1: `CapabilityCatalog` titles and subtitles are still `String`, not
  `LocalizedStringResource`, so the Settings hub categories are not extracted.
- P1 item 2: `OGChip`, `OGStatusPill`, `OGHeroDeviceCard` and `OGDiscoverCard` still accept only
  `String`.
- P1 items 3 and 4: runtime-composed sentences, and plural variants (the catalog has none).
- All of P2 (guardrail tests, `knownRegions` prune) and all of P3 (translated catalogs).

---

## Decisions (2026-09-02)

- **Language set:** zh-Hans, es, de, fr, ja, pt-BR, nl, uk — plus **completing** the
  already-started zh-Hant and pl (shipping a 9%-translated language reads as broken; removing a
  started language is a regression). **es-MX stays an override layer** (~28 keys) over es — iOS
  language matching falls back es-MX → es, so it never needs a full fill. Ten full catalogs total.
- **Machine translation is the first pass.** A flagged subset (below) gets human review before any
  store-listing claim of support; everything else ships MT and improves opportunistically.
- **English stays the development and fallback language.** An untranslated key renders English, by
  design — the guardrail tests keep that set near zero rather than pretending it can't exist.

## What exists

- `Localizable.xcstrings` (app target), `sourceLanguage: en`, 1,864 keys on main.
  Translated: 178 keys × {de, es, fr, ja, pl, zh-Hans, zh-Hant}, 35 × uk, 28 × es-MX.
- `project.base.yml` `knownRegions` already declares ~30 languages (nl and uk included) and
  `developmentLanguage: en`; `CFBundleDevelopmentRegion` is wired. Declarations are not the gap.
- #394's component contract: literals at call sites reach the catalog; runtime values ride
  `StringProtocol`/`verbatim:` overloads and are invisible to extraction **on purpose**. What still
  rides the verbatim path — and therefore cannot translate — is the subject of P1.

## P1 — Close the verbatim gaps

Copy that is authored in this repo but reaches the screen as a runtime `String`:

1. **Model-carried copy → `LocalizedStringResource`.** `CapabilityCatalog` category
   titles/subtitles/pitches and Discover suggestion notes, self-test names
   (Diagnostics & Support / Developer Panel test lists), and any other authored-copy model fields
   feeding `OGRow`/`OGDiscoverCard` via variables. `LocalizedStringResource` keeps the model
   `Codable`-free of surprises, extracts like a literal, and resolves at render.
2. **Composition components.** `OGChip`, `OGStatusPill`, `OGHeroDeviceCard`, `OGDiscoverCard`,
   `OGSelectionRow` and their `spokenLabel`/`spokenSummary` helpers compose sentences from parts.
   The *parts* arrive localized once callers pass localized strings; the helpers' own words and
   joiners ("unavailable", "Battery %lld percent", "Available: ", list separators) become
   `String(localized:)`. The helpers stay pure functions over resolved strings, so the existing
   accessibility tests keep passing under an English test locale and per-language wording is
   covered by the P2 parity checks rather than per-language unit tests.
3. **Runtime-composed sentences.** Sweep for user-facing `String` building that never meets a
   catalog: status summaries (e.g. the telemetry disclosure summary), hero-card statuses
   ("Connected"/"Not connected"), chip labels ("HUD on/off"), and error copy built in services.
   Each becomes `String(localized:)` at the point the sentence is built — the rule #394
   established, now enforced end to end.
4. **Plural hacks → variants.** English `"line\(n == 1 ? "" : "s")"`-style tricks and bare
   `%lld`-count keys get xcstrings plural variants. This is load-bearing for the chosen set:
   uk and pl have three plural categories, so a two-branch English ternary is wrong in both.
5. **Explicitly stays verbatim:** user-authored content (persona names, model names, wake phrases,
   vault data), AI conversation output, third-party attribution names/licenses, and the
   diagnostics/bug-report export bodies — those files are read by the developer, and a report
   in Ukrainian would be less useful to triage than the English original. The privacy *screens*
   around them translate; the exported artifact does not.

## P2 — Guardrails and honest declarations

Deterministic, headless, en-locale-independent tests over the catalog file itself:

- **Specifier parity:** every translation's format specifiers (`%@`, `%lld`, positional forms)
  match its source key in count and type. This is the machine-translation tripwire — a dropped or
  reordered specifier is a crash or garbled sentence, and it is exactly the mistake MT makes.
- **Coverage floor:** each shipped language ≥ 95% translated, and the report names the missing
  keys so a failing run is actionable. Floor ratchets to ~100% once P3 lands.
- **Declarations honest:** the shipped-language set (catalog languages meeting the floor) must
  equal what the app offers. Prune `knownRegions` from the ~30-language aspirational list down to
  en + the ten shipped (+ es-MX) — today's list makes iOS offer per-app language choices that do
  nothing.
- **Plural completeness:** keys with plural variants carry every category the language requires
  (uk/pl `few`/`many`).
- Extraction hygiene stays as-is: test and CI builds keep `SWIFT_EMIT_LOC_STRINGS=NO`; the
  extraction pass remains the manual touch-all → emit → `xcstringstool sync` procedure, run at the
  end of P1 to pull the freed keys in before P3 translates them.

## P3 — Translated catalogs

- One commit per language, mechanical, gated by the P2 tests. Order: nl, uk first (the newly
  requested pair proves the pipeline end to end, uk exercises plurals), then the seven
  178-key partials completed, then pt-BR fresh.
- **Human-review flag list** (before claiming support in store metadata): onboarding, the
  Glasses Analytics / telemetry disclosures, diagnostics privacy copy, Medical Compliance
  paywall + legal lines, first-aid coaching strings. Tracked as a checklist here; MT ships first.
- es-MX: review the existing 28 overrides still make sense over the new es fill; add overrides
  only where es reads wrong for Mexico.

## Non-goals

- Translating AI responses or transcripts (the assistant's language is a conversation concern,
  already steered by the voice/language settings, not the UI locale).
- Voice/TTS language selection — existing surface, orthogonal.
- App Store metadata localization — worthwhile follow-up, not this plan.
- RTL (ar is in today's aspirational `knownRegions` and comes out in the P2 prune; adding an RTL
  language is its own layout-audit plan).
- Watch / widget / share-extension strings — audit in P1 for whether they render authored copy;
  if so they get their own small catalogs, otherwise explicitly out.

## Verification

- P1/P2: full suite green (sim UDID destination), Release build green, catalog-sync commit
  separate, guard tests failing-then-passing as coverage lands.
- P3: guard tests are the gate per language; manual spot-check with the phone set to Dutch and to
  Ukrainian (plural rows: event counts, log-line footers) across the settings hub, diagnostics,
  onboarding, and the paywall; confirm the per-app language picker lists exactly the shipped set.
