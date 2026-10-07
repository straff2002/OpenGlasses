# Plan EC — Automatic UI Localization

**Status:** 🚧 Started (planned 2026-09-02; progress below, 2026-10-07). One P1 prerequisite fix,
four catalog syncs and two complete catalogs (Russian, then Mexican Spanish) have landed; P1
items 1 and 2, English plural variants, the rest of P2 and the other P3 languages remain.
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

## Progress (2026-10-07)

**Landed.**
- **Sync after the EU AI Act decisions (2026-10-07).** Three keys added the same add-only way:
  the Enrolled Faces 2 December 2027 notice, its "Unavailable in your region" row status and the
  Field Assist camera triage refusal. The two Social mode refusals the decisions removed stay as
  they were, unmarked. `ru` and `es-MX` were translated in the same commit, so each still covers
  all 2,959 translatable keys of 3,007.
- **Catalog sync after the EU AI Act tranches, and the line for the other person (2026-10-07).**
  The catalog was synced with the current sources: 40 keys added, none removed, taking it to
  3,004 keys (2,956 translatable). As before it is add-only. A command-line build writes the
  `.stringsdata` files but does not rewrite the catalog, so one Debug simulator build produced
  them and `xcstringstool sync` merged them into a copy; the 63 stale marks it proposed on
  existing keys were left out. New keys go where Xcode sorts them (`localizedStandardCompare`),
  not where the sync tool happened to write them: the rename check in `BrandNameGuardTests`
  re-sorts the catalog that way and fails on any other order. The additions are the Enrolled
  Faces screen, the Avenkin AI cue and introduction, the translation disclosures, Social mode's
  copy, the first-aid toggle, the persona and chat provenance lines, and four ElevenLabs fallback
  notices. The deployer sheet and the jurisdictions copy are HTML and not in the catalog.
  `ru` and `es-MX` were
  machine-translated for all 40, with plural variants on the two counted strings, so each covers
  all 2,956 translatable keys again. Two keys are said to or shown to someone who does not speak
  the wearer's language: the spoken "This is a live AI translation by Avenkin AI." and the
  caption label "AI translation". `TranslationDisclosureLanguage` picks them by the translation's
  target language, so they now exist in every catalog language, the partial ones (`de`, `es`,
  `fr`, `ja`, `pl`, `uk`, `zh-Hans`, `zh-Hant`) included. Like the rest of the machine
  translation, they still need human review.
- **The guard no longer reads a percentage as a specifier (2026-10-06).** The specifier pattern
  accepted the printf space flag, so "80% of a limit" parsed as `% o`, an octal argument, and any
  translation of that footer failed parity. No string in the app uses the space flag, and that
  footer was the only string in the catalog the flag changed the reading of, so it is dropped
  from the pattern, with a fixture for the case. The footer is now translated, and `ru` and
  `es-MX` each cover all 2,916 translatable keys. The two entries below describe the catalog as
  it stood before this.
- **Mexican Spanish is the second complete catalog (2026-10-06).** By owner request `es-MX` is
  filled end to end instead of staying an override layer over `es`; this replaces the 2026-09-02
  decision below. It was filled on top of the sync in the next entry, so it covers the same keys
  `ru` does: 2,915 of the 2,916 translatable keys, the 28 earlier overrides among them and kept
  as they were. The one key left in English is the same spending-limit footer, for the same
  reason. It was done the way `ru` was. Stale keys, and keys that are only symbols or specifiers,
  are left alone. The same 28 single-count strings carry plural variants, here
  `one`/`many`/`other` with `many` worded as `other`. The English `"file%@"` suffix tricks, and
  counts that share a sentence with other arguments, use the number-neutral colon form
  (`«Archivos: %lld»`), with positional specifiers skipping the suffix argument. The register is
  `tú` with Mexican vocabulary (`lentes`, `celular`, `computadora`) and Apple's own iOS names for
  system things (Configuración, Atajos, Recordatorios). `es-MX` was already in
  `LocalizationManager.bundledLanguages`, so nothing moved there and no downloadable pack is
  involved. It joins `completeLanguages` in `LocalizationCatalogGuardTests`, which now holds it
  to the coverage floor, specifier parity and its plural categories. Two things are still owed.
  Human review of the flagged subset (below), as for `ru`. And `es` itself, which is still the
  179-key slice: a phone set to Mexican Spanish gets the full catalog, but another Spanish region
  can still resolve to `es` and so to mostly English (which regions iOS sends where has not been
  checked on a device). The copy also quotes things to say ("navigate to …", "include all",
  "Run <action> on Avenkin"); those were translated as `ru`'s were, but the matchers behind some
  of them list English phrases only, so for those the translated example names a phrase that is
  not yet recognised. That is a code gap for both languages, not something a catalog can close.
- **Catalog sync and Russian top-up (2026-10-06).** The catalog was synced with the current
  sources: 403 keys added, none removed, taking it to 2,964 keys (2,916 translatable). The sync
  is add-only: the extraction proposed stale marks on 60 existing keys and those were left out,
  so no existing entry changed. That left `ru` at 86%, under the guard's floor, so 402 keys were
  machine-translated (the new translatable keys and one older gap), one of them with plural
  variants. `ru` now covers 2,915 of 2,916. The key left in
  English is the spending-limit footer beginning "At 80% of a limit": the guard reads `% o` there
  as a format specifier, so no translation passes specifier parity until the English copy or the
  guard's pattern changes. Human review of the flagged subset is still owed for `ru`.
- **Russian is the first complete catalog (2026-09-30).** Added to the language set by owner
  request. Every current catalog key with words in it now has a machine-translated `ru` value;
  that is the whole catalog, not the old 178-key slice. Stale keys, and keys that are only symbols
  or specifiers, are left alone. Count-of-noun strings with a single integer carry `ru` plural
  variants (`one`/`few`/`many`/`other`). The English `"file%@"` suffix tricks, and counts that
  share a sentence with other arguments, use the declension-free colon form (`«Файлов: %lld»`),
  with positional specifiers skipping the suffix argument. `ru` moved from the downloadable packs
  to `LocalizationManager.bundledLanguages`. `Translations/ru.json` stays for builds that still
  download it. `LocalizationCatalogGuardTests` is the first slice of P2: for each *complete*
  language it enforces the 95% coverage floor (relaxed from 100% on 2026-09-30, so a catalog sync
  that brings in untranslated English keys doesn't fail the suite; a failure names the missing
  keys). It also enforces specifier parity against the English source, where an English
  plural-suffix `%@` may be dropped, and every plural category the language needs. It checks the
  language is offered as bundled. Each language joins its `completeLanguages` set as its catalog
  fills. Human review of the flagged subset (below) is still owed for `ru`.
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
- The rest of P2: a coverage floor for partial languages and the `knownRegions` prune. Of P3,
  every language except `ru` and `es-MX` — `es` included.

---

## Decisions (2026-09-02)

- **Language set:** zh-Hans, es, de, fr, ja, pt-BR, nl, uk — plus **completing** the
  already-started zh-Hant and pl (shipping a 9%-translated language reads as broken; removing a
  started language is a regression). **es-MX stays an override layer** (~28 keys) over es — iOS
  language matching falls back es-MX → es, so it never needs a full fill. Ten full catalogs total.
  **ru added 2026-09-30** (owner request), making eleven; it shipped first, ahead of the P3 order.
  Its plural rules (`one`/`few`/`many`) are the same shape as uk's, so it also exercises plurals.
  **es-MX filled 2026-10-06** (owner request): it is a complete catalog of its own, no longer an
  override layer, which makes twelve. `es` is still to fill and is not replaced by it: `es` is
  what the other Spanish regions can resolve to.
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
  en + the eleven shipped (+ es-MX) — today's list makes iOS offer per-app language choices that do
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
- es-MX: complete since 2026-10-06 (see Progress); the 28 earlier overrides were kept. When `es`
  is filled, seed it from `es-MX` and change only what reads wrong outside Mexico.

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
