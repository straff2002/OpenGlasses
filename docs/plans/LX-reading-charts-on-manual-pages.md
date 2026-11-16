# Plan LX — Reading Charts on Manual Pages (a charging chart or a fan curve, read off the page and said to be approximate)

**Status:** 🚧 P0 and the words-only part of P2 built 2026-11-16 (headless) — the deterministic core and, live on
the phone with no model, charts found at import and indexed as words-only passages, announced to the model as unread,
their page opened for the phone and never sent as the model's picture (see "What shipped in P0"). Not built: P1
(reading a chart's values: prompts, schema, the cache on disk, the disclosure, Max's switch and the org key, `AIFeature.chartReading`),
the rest of P2 (`chart_lookup`, precedence wired into `table_lookup` / `domain_calc`, chain-step marking), P3, and the
P4 device pass. Decisions 1, 2, 5, 6 and 7 taken 2026-11-16: chart reading is a company setting on the phone, on by
default (on demand, §8); decisions 3–4 open. P0 sends no picture anywhere and calls no model: reading
values is P1.
**Track:** Field Assist first (charging charts, pressure–temperature curves, derating curves), app-wide
underneath: any vault PDF, any My Manuals PDF, any photographed manual page.
**Builds on:**
- Plan [JN](JN-pictured-tables.md): `PictureRegion`, `PictureTableReading` and its
  `PictureTableCheckpoint`, `RecognisedReading` / `RecognisedPage` (`Vault/RecognisedTable.swift`),
  `CellCertainty`, and JN's first principle, *a value read from a picture says so, every time*.
- Plan [EK](EK-manual-structure-and-figures.md): figure captions, the `diagram` chunk kind and the
  citation as a door to the page.
- Plan [JJ](JJ-table-lookup-and-rule-chains.md): `ManualTable`, `table_lookup`, row passages
  (`TableRowPassage`) and chains.
- Plan [IS](IS-refrigerant-toolkit.md): `SaturationTable`, `domain_calc` superheat and subcooling, and
  P4's unbuilt `target_superheat`, which is to use "the manufacturer's chart where the vault carries it".
- Plan [AD](structured-vision-assessment.md): `LLMService.analyzeFrameStructured`, a schema-forced JSON
  reading of one image.

**Sits beside:** `FigureAutoOpenPolicy` and `ManualFigure` (when a page opens by itself), and
`PageEvidencePolicy` (how a page is labelled and whether it was shown).

---

## Trigger

A technician on a fixed-orifice system asks *"what's the target superheat at 67 wet bulb and 85
outside?"*. The unit's manual answers it, but only as a chart: a family of curves on page 41, one
per indoor wet-bulb temperature, outdoor temperature along the bottom, target superheat up the side.
The same holds for a pressure–temperature curve, a blower's fan curve (airflow against static
pressure), a pump curve, or a derating curve (allowed current against ambient temperature).

Today the app can find the chart's *words*: its caption, the axis titles, perhaps a printed note. It
cannot give a single value off it. The best it does is cite the page. The worst it can do is let the
model answer from general knowledge with the manual's page beside it, which looks as though the
manual said it.

JN solved the neighbouring problem for tables printed as pictures. A chart needs something JN doesn't
have: the values are not printed anywhere, they are positions on a drawing.

## Outcome

- **The question above** gets *"About 15 °F, read off the chart on page 41 (Figure 99). That's
  approximate: check it on the chart."* The page opens on the phone, and on the lens with Display
  glasses.
- **A printed or computed figure always wins.** When the manual also prints the target in a table, or
  the value can be computed (a saturation temperature from IS's tables), that figure is given and the
  chart is not used.
- **A question about what a chart shows** (*"what does the fan curve do above 0.8 inches?"*) finds the
  chart by its words and gets a short description from the chart's own reading, with the page.
- **A value outside the chart** (an outdoor temperature beyond the last tick) gets *"That's outside
  the chart on page 41, so the manual doesn't give one."* Nothing is extrapolated.
- **A chart that could not be read cleanly** is never used for a value. The answer is the page.
- **The first time a chart is read with a cloud model**, the phone says what is sent and where, and
  asks once for that manual.

## What exists, and what doesn't

**Exists (verified against `main` on 2026-11-15):**
- `VaultDocumentExtractor` (`OpenGlasses/Sources/Services/Vault/VaultDocumentExtractor.swift`) writes a
  figure caption as `### Figure N — Title` and tags a drawing page `<!-- page: diagram -->`, counted in
  `Extracted.diagramPages`. `DocumentChunker.Kind` (`Services/RAG/DocumentChunker.swift`) has `prose`,
  `diagram` and `tableRow`.
- `PictureRegion.below(caption:words:pageBounds:…)` finds the region under a caption from
  `PositionedWord`s (`Vault/TableExtractor.swift`). `PictureTableReading` renders a region at two scales
  chosen by thermal state (`scales(for:)`), recognises it on device, and checkpoints by content hash,
  physical page, label, reader and scale (`PictureTableCheckpoint.key`).
- `CellCertainty` (`Vault/CellCertainty.swift`) marks a recognised cell `uncertain` on any doubt; an
  uncertain cell keeps its text and is never given as a value (`ManualTable.Cell.uncertain`).
- `PageEvidencePolicy` (`Services/FieldAssist/PageEvidencePolicy.swift`): `PageOrigin`
  (automatic/requested), `PageEvidenceState` (shown/opened/verified) and `label(title:page:figure:)`.
- `FigureAutoOpenPolicy` and `ManualTurnClassifier` (`Services/FieldAssist/FigureAutoOpenPolicy.swift`)
  decide when a figure opens without being asked. `ManualFigure.swift` holds `ManualFigureAttachment`,
  `ManualFigureCue` and `ManualFigurePresenter`; `FieldSessionService.StagedFigure` is the staged page.
- `LLMService.analyzeFrameStructured(systemPrompt:userText:imageData:jsonSchema:…)` forces the active
  provider to return JSON matching a schema, and returns nil for the local and Apple on-device models.
  The local model service links an image-capable on-device runtime (`LocalLLMService`), unused for this.
- IS: `SaturationTable` and `SaturationTableCatalog` (`Services/FieldAssist/Refrigerant/`) feed
  `domain_calc`'s superheat and subcooling. `target_superheat` is not built. The bundled refrigeration
  vault's `superheat_subcool.md` tells the model the target comes from the manufacturer's chart.
- `ModelPricing.estimate(model:tokensIn:tokensOut:…)` and `SpendCapPolicy` (`Services/Usage/`).
- `AIFeature` (`Services/Privacy/AIFeatureRegistry.swift`) and `DataStoreRegistry`
  (`Services/Privacy/DataStoreRegistry.swift`), each checked by its own tests.
- The org profile's `SettingKey` (`Services/OrgProfile/SettingKey.swift`): no key covers page images.

**Doesn't exist:**
- Anything that tells a chart from a wiring diagram or a photograph.
- Any reading of a chart's values, or a data model for one.
- Any passage that makes a chart's values findable.
- A rule for which source wins when a chart and a table or a calculation give the same quantity.
- JN states *"no page image leaves the phone"*. A chart can't be read on device by Vision alone, so
  this plan has to decide where the picture goes (decision 2).

## Design

### 1 · Which pictures are charts (`ChartCandidate`, pure)

A chart is found from positioned words, the same input `PictureRegion` already uses, so no model is
involved in finding it:
- a region (under a caption, or a whole `diagram` page) holding **at least three numbers in a row
  along one edge** and **at least three in a column along a perpendicular edge**, each run evenly
  spaced within a tolerance (these are the tick labels);
- a word run beside each run that isn't a number (the axis titles), where present;
- a caption or title word such as *chart*, *curve*, *graph*, *performance* or *derating* raises
  confidence but is not required.

A wiring diagram has numbers (terminal numbers, wire gauges), but not as two evenly spaced runs along
perpendicular edges. A corpus test pins both kinds, built from hand-placed words.

`ChartCandidate` records the document, physical page, printed page label, caption label, the region,
and the tick labels and axis words exactly as recognised. These printed words are what the reading
is checked against in §3.

`ChartKind` is decided at reading time: `.lines` (one or more series over x), `.family` (a series per
value of a third input, as a charging chart draws one curve per wet bulb), `.bars`, or `.other`.

### 2 · Reading it, in two passes

**Pass 1: the data, as a table.** One `analyzeFrameStructured` call with the region's image and a
fixed schema. The model is asked to write the chart out, not to describe it:
- each axis: role (x, y, second y), the title and unit as printed, the tick values as printed, and
  the scale (linear, logarithmic, or unknown);
- each series: its label as printed (for a family, the third input's value, such as `67`), and its
  points, read at every printed x tick and at each bend between ticks;
- anything printed inside the plot area (a shaded "do not charge" band, a note).

Writing points as a table first is what makes long series come out right. A one-pass description
tends to drift along a long curve and put later points against the wrong tick.

**Pass 2: the words, from the table.** A text-only call, given the validated table and the caption but
**not the image**, writes two to four sentences: what the chart is for, how the series move, where
they bend. Because it never sees the picture, it can't contradict the table. A pure check
(`ChartDescriptionCheck`) then requires every number in the description to appear in the table, the
ticks or the caption; a description that fails is dropped and the template in §4 is used alone.

### 3 · The data model and its validator (`ChartReading`, `ChartReadingValidator`, pure)

`ChartReading`:
- `axes: [ChartAxis]`: role, printed title, printed unit, the tick values, `range` (lowest to highest
  tick) and scale;
- `series: [ChartSeries]`: printed label, an optional numeric `parameter` (the family value), and
  `points: [ChartPoint]` (x, y);
- `step`: the reading's resolution per axis, half the smallest tick interval. Every value given from
  the chart is rounded to it;
- `source`: document id, physical page, printed label, figure label, the image hash, the prompt
  version, the model id and the date.

There is no `approximate` flag to set, because there is no way to make one false: every value that
leaves a `ChartReading` is approximate by type (`ChartValue` carries `about: Double` and `step`, and has
no initialiser from a plain `Double`).

`ChartReadingValidator.check(_:against: ChartCandidate) -> .usable / .wordsOnly(reasons) /
.rejected(reasons)`:
- **Ticks agree with the page.** The lowest and highest tick of each axis must be among the numbers
  recognised on device in that run. A reading whose axes the page doesn't print is rejected
  (`ticksNotOnPage`). This ties every reading to printed text.
- **Units present.** An axis with no unit, printed or read, makes the reading `.wordsOnly`
  (`unitMissing`): it is indexed for its words and never gives a value.
- **Points inside the axes**, within one step. One point outside rejects the reading
  (`pointOutsideAxes`).
- **x increases** along each series of a `.lines` or `.family` chart. Repeated x values are merged
  only when their y values are within a step; a series that goes back on itself is rejected
  (`seriesNotMonotonic`).
- **Logarithmic axes** have positive ticks, each a constant ratio from the last.
- **Series labels** of a family are numbers and each appears among the recognised words in the
  region; a missing one is a warning, not a rejection.
- **Bounds:** at most 12 series and 60 points a series; more is rejected as a misread.

### 4 · What retrieval finds (`ChartPassage`, pure)

A usable or words-only reading becomes one passage, stored the way JJ stores row passages (beside
the document's own chunks, kind `chart`, never changing the page text). Its text is built from the
reading by a template, plus pass 2's sentences when they passed the check:

```
Chart: Figure 99 — Target superheat (page 41). Read from a picture of the chart; every value is approximate.
Axes: outdoor temperature (°F), 65 to 115; target superheat (°F), 0 to 40.
Series by indoor wet bulb: 57, 62, 67, 72.
At wet bulb 67: about 22 at 75, about 15 at 85, about 9 at 95.
```

(Invented example.) A words-only reading keeps the first three lines and says *"values not read"*.
The passage's citation is the page's, with the figure label, through the same `Passage.citation` the
retriever already attaches. The retriever sees it like any passage; the evidence gate is unchanged.

### 5 · Giving a value (`ChartLookup`, pure)

Given a reading, a series (or a family parameter) and an x value:
- linear interpolation between the two nearest points of the series;
- for a family, linear interpolation between the two series whose parameters bracket the asked
  value (wet bulb 64 between the 62 and 67 curves);
- the result rounded to the step and returned as `ChartValue`;
- **never extrapolated**: an x outside the axis range, or a parameter outside the family, returns
  `.outsideChart`, and the answer says so;
- a value falling inside a shaded band the reading recorded is returned with the band's printed note.

The spoken and written form comes from one place (`ChartCitation`):
*"About 15 °F, read off the chart on page 41 (Figure 99). That's approximate: check it on the chart."*
The word *about* and the page are never dropped, in any language. `PageEvidencePolicy.label` supplies
the page and figure part.

### 6 · Which source wins (`ChartPrecedence`, pure)

For one quantity, in order:
1. a value printed as text in the manual (a text-layer table, JJ);
2. a certain cell of a table read from a picture (JN);
3. a value the app computes from bundled data (IS's saturation tables);
4. a value read off a chart.

A lower source is used only when no higher one answers. When a chart and a higher source both answer
and differ by more than two steps, the higher one is given, the chart isn't mentioned, and a count
(never the values) goes to the diagnostics ring, so a misread chart shows up in support reports.

For IS: `target_superheat` (IS P4) reads a manufacturer's table when the vault has one, else a chart
reading of the unit's charging chart, said as above, else says the manual gives no target. A
pressure–temperature chart in a manual never replaces the saturation tables.

### 7 · Charts that must always send the technician to the page (`ChartSafetyClass`, pure)

A chart is **critical** when its caption, titles or units name refrigerant charge (superheat,
subcooling, charging, liquid line, suction), electrical limits (derating, ampacity, conductor, current
against temperature), fuel gas (manifold pressure, orifice, input rating) or combustion. Words are
matched with `LexicalSupport` content terms, so the list is per language like the gate's.

For a critical chart:
- the page **always** opens with the value (a new `FigureAutoOpenPolicy` rule, origin `.automatic`),
  on the lens too with Display glasses;
- the value never feeds a chain step silently: a step that takes one is marked *"read off a chart"*
  the way JN marks a step read from a pictured table, and the chain's read-back says so;
- `domain_calc` never treats it as the unit's specification in a pass/fail sentence. It says *"the
  chart gives about 15 °F; you measured 22 °F"*, and leaves the judgement to the technician.

Other charts (fan and pump curves, most performance charts) open the page when asked, as figures do
today.

### 8 · When a chart is read, and where the picture goes

Recommended (decisions 1 and 2):
- **At import, on device, free:** chart candidates are found (§1) and their printed words indexed
  as a words-only passage, so the chart is findable from the day the manual arrives. No model call.
- **On demand:** the first time a turn's evidence includes a chart candidate and the turn asks for a
  value or what the chart shows, the chart is read (§2) and the reading cached. Later questions
  about that chart cost nothing.
- **For an organisation, at import as well**, when it switches that on: every candidate up to the
  cap, with the cost estimate shown first.

The picture goes to the provider the wearer has chosen, the same one that answers their questions.
- **Disclosure.** Before the first cloud reading from a manual: *"Reading this chart sends a picture
  of page 41 to Anthropic. Nothing else from the manual is sent."* (the provider's name filled in),
  with **Read it** and **Not now**. Asked once per manual; the Settings explainer says it always.
- **On-device models.** When the chosen model is the local one and it takes images, the reading runs
  on the phone and nothing is disclosed because nothing leaves. The Apple on-device model doesn't
  take images, so it offers the page instead.
- **HIPAA mode** uses the same routing it uses for every image. If that routing refuses, the chart
  isn't read and the page is offered.
- **Max's switch (decisions 1–2, taken 2026-11-16).** Chart reading is an option the company sets on
  the phone, **on by default**: *Read charts on manual pages* in Field Assist settings, `off` /
  `onDemand` / `atImport`, default `onDemand`. Whoever runs the company sets it there, with no office
  app and no profile needed. An organisation profile may also pin it through a ceiling
  `SettingKey.organizationChartReading` (same values, tighten only); a pinned value shows on the
  phone as set by the organisation. Off means nothing is read: the chart is still found, searched
  and cited by its page, as P0 does. On by default does not skip the disclosure: the first cloud
  reading from each manual still asks.
- A new `AIFeature.chartReading` registers the feature, its switch and what stays on disk.

### 9 · The cache (`ChartReadingCache`, `ChartCachePolicy`, pure decision)

- **Key:** SHA-256 of the exact rendered image bytes sent, joined with the SHA-256 of the exact
  prompt (system text, user text, schema, prompt version). A re-import of the same manual renders the
  same image and asks the same question, so it pays nothing. A changed prompt or render reads again.
- **Stored:** the validated reading and the validator's verdict, the model id and the date, in one
  file per manual content hash beside `PictureTableCheckpoint`'s, excluded from backup, deleted with
  the manual (Plan [FN](FN-vault-manual-removal.md)), and registered in `DataStoreRegistry` as
  not linked to a person.
- **Never stored:** a reply that failed, a reply cut off at its token limit (the provider's stop
  reason, or JSON that doesn't close), or one the schema decoder refused. These are retried on the next
  question, at most once a day per chart.
- **A complete reply the validator rejected is stored as rejected**, so the app doesn't pay again
  for the same misread. The chart sheet offers **Read again**, which replaces it.

### 10 · Limits and cost

- At most **40 charts read per manual at import**. On demand there is no count limit; each new chart is
  one image call and one short text call, under the wearer's spend cap (`SpendCapPolicy`).
- The import-time estimate uses `ModelPricing.estimate` with the measured tokens per chart from P1.
- Rendering uses JN's thermal-aware scales; reading pauses while the phone is hot, as JN does.

### 11 · Is it a chart at all? A second signal (added 2026-11-15)

Tick labels (§1) are one signal. A flow diagram or a wiring sequence drawn as numbered boxes can carry
two evenly spaced runs of numbers too: steps 1 to 6 down the left, boxes 1 to 4 across the top. Taken
for a chart, it would be sent to be read and come back as a confident nonsense curve. So a second
signal, the **picture type**, sits beside the ticks, and `ChartCandidate` needs both:
- **A rule over the region's shape and text** (`ChartShape`, pure, in P0): two long straight lines
  along the tick runs that meet at a corner (from the PDF's drawn paths, or from the rendered region on
  a scanned page); tick values that step evenly in value as well as in position; numbers outside the
  plot area rather than inside boxes; few words inside the plot area.
- **Optionally, a small on-device picture classifier** (chart, diagram, photograph, other), only if the
  measurement shows the rule alone misses. It runs on the phone with no network, like the other readers.
- **When the two disagree**, the candidate is words-only: indexed for its printed words, never read for
  values.

Measured on the Mac test bench of Plan [MA](MA-reading-manuals-better.md) §1, whose second reader
classifies pictures: over manuals a developer holds, how many of our candidates it calls something
other than a chart, and how many charts it finds that we miss, counted and triaged there, never text.
P0's `ChartCandidateTests` gain a numbered-box flow diagram and a wiring sequence that must not be
charts.

## Decisions for Greig

1. **When charts are read.** **Taken 2026-11-16 as recommended, as Max's switch (§8), on by default
   (on demand).** *Recommended:* printed words at import on device (free), values on demand
   the first time a turn needs them, cached; an organisation can add reading at import. *Not
   recommended:* every chart at import for everyone, which costs money and sends pictures for charts
   nobody asks about; or on demand only, without the free words, which leaves charts unfindable.
2. **Where the picture may go.** **Taken 2026-11-16 as recommended, with the ceiling a phone setting
   the company sets, on by default (§8).** *Recommended:* the wearer's chosen provider, with the one-time
   disclosure per manual; on device when the local model takes images; HIPAA routing unchanged; an org
   ceiling, default on demand. This is a deliberate exception to JN's "no page image leaves the phone",
   limited to chart regions, and the disclosure says so. *Alternative:* on device only, which today
   means the local model only, so most wearers would never get a value.
3. **Pass 2.** *Recommended:* text only, from the validated table, number-checked, so it adds words for
   search without a second image call. *Alternative:* the template alone, cheaper and duller to search.
4. **The cap.** *Recommended:* 40 charts per manual at import, none on demand beyond the spend cap.
5. **Critical charts.** *Recommended:* the vocabulary in §7, the page always opens, never a silent
   chain input, never a pass/fail. *Alternative:* treat every chart as critical, which makes fan
   curves noisy for no safety gain.
6. **The tool.** *Recommended:* a new `chart_lookup` (find a chart, give a value or describe it),
   classified in `VaultOnlyPolicy` as a kept job tool and added to `FieldToolProfile`,
   `AppleOnDeviceToolSet` and `ActivityTitler`. *Alternative:* extend `table_lookup`, whose row-and-
   column arguments don't fit a series and an x value.
7. **The cache key.** *Recommended:* image and prompt only, with the model recorded; **Read again**
   replaces a reading. *Alternative:* add the model id to the key, which pays again whenever the
   wearer switches models.

## Phases

### P0 — the deterministic core (headless, no model)

`ChartCandidate` detection, `ChartReading` and `ChartValue`, `ChartReadingValidator`,
`ChartDescriptionCheck`, `ChartPassage`, `ChartLookup`, `ChartCitation`, `ChartPrecedence`,
`ChartSafetyClass`, `ChartCachePolicy` and the cache key. Every input is hand-written: placed words for
detection, hand-written readings for everything else.

Tests:
- `ChartCandidateTests`: a two-axis chart found; a wiring diagram with terminal numbers not found;
  uneven ticks not found; a chart with no caption still found.
- `ChartReadingValidatorTests`: ticks not on the page, a missing unit (words only), a point outside
  the axes, x going backwards, a log axis with a zero tick, too many series, a family label missing
  from the page (warning).
- `ChartLookupTests`: between two points, between two family curves, exactly on a tick, outside the x
  range, outside the family, inside a shaded band, rounding to the step.
- `ChartPassageTests` and `ChartCitationTests`: the template; a words-only passage; *about* and the
  page present in every wording, in English and one other UI language.
- `ChartDescriptionCheckTests`: a number not in the table drops the description.
- `ChartPrecedenceTests`: printed beats recognised beats computed beats chart; a disagreement counted,
  not spoken.
- `ChartSafetyClassTests`: charge, derating and gas captions critical; a fan curve not.
- `ChartCachePolicyTests`: a cut-off reply, a failure and an undecodable reply not stored; a rejected
  reading stored as rejected; the same image and prompt hit; a changed prompt misses.

### What shipped in P0 (2026-11-16)

All pure, Foundation and CoreGraphics only, under `Services/Vault/Charts/`; every input in the tests is
invented (placed words and hand-written readings).

- **`ChartCandidate`** (§1, §11). Tick runs (`ChartTicks`): at least three upright numbers on one baseline, or
  aligned at their right edge or centre down a column, evenly spaced (12 % of the median gap) and stepping
  evenly in value, linearly or by a constant ratio (a logarithmic axis). The second signal is `ChartShape`, from
  words and region shape: the row is under the column and the column at the row's start (the plot's lower-left
  corner, within five type sizes); the tick labels stand alone (a column whose numbers head lines of text, or a
  row set among words, is numbered boxes); words inside the plot that line up with most ticks are a table's
  rows or columns; more than 24 words inside is not a chart. A candidate needs both. The axis title is the line
  under the row, or the words set on their side beside the column (else the line over its top tick); its unit
  is a bracketed run at its end or a last word that is a unit. The caption is the nearest "Figure N" line within
  a fifth of the page. Header and footer bands never hold ticks. A second column at the row's far end is a
  second y axis. `pictureType` is where an on-device classifier's answer goes; none is built.
- **`ChartReading`, `ChartReadingValidator`, `ValidatedChartReading`** (§3), as the plan lists the rules. A
  reading's axis the page has no run for counts as ticks not on the page; a unit printed on the page is enough
  when the reading left it out. Only `ValidatedChartReading` (made only by the validator) can be looked up.
- **`ChartLookup` and `ChartValue`** (§5). `ChartValue` has no public initialiser; it is rounded to the step and
  carries it. Interpolation is in log space on a logarithmic axis. Past either end of a series' own points is
  `.outsideChart(.xOutsideSeries)`, as well as past the axis and outside the family.
- **`ChartCitation`** (§5). The value, outside-the-chart and page-only sentences are held per language in code
  (English, German, French, Spanish), not in the string catalog, so the tests can prove the word for *about* and
  the page are in every wording; a language without a template is said in English. A value is written to its
  step's precision with the language's decimal separator.
- **`ChartPassage` and `ChartDescriptionCheck`** (§4, §2). The words-only passage: caption and page, "Values not
  read: the manual gives them only as a chart.", the axes as printed with their tick ranges, and up to 16 words
  printed inside the plot. The read template is there for P1.
- **`ChartPrecedence`** (§6) with a count-only `DisagreementTally`; **`ChartSafetyClass`** (§7), the vocabulary in
  English, German, French and Spanish matched as `LexicalSupport` content terms under the document's rule, plus
  current against temperature; **`ChartCachePolicy`** (§9) with the key (image SHA-256 : prompt SHA-256, the parts
  joined by a unit separator) and the store/retry decision. Nothing is written to disk.

**The words-only part of P2, live.**
- **At import.** `PDFChartReader` reads each page's placed words (`PDFTableReader.positionedWords`) on pages whose
  plain text holds six numbers and a line of numbers alone, from the document's PDF or the original it was
  imported from, and `DocumentStore.ingest(charts:)` stores one passage per chart, `DocumentChunker.Kind.chart`,
  numbered after the row passages and embedded like them. It is the app's text: left out of the document's own
  text, its language, `writeLocations` and the reconstructed text, like a row passage (`Kind.isAppWritten`).
  Counts only are logged (`charts_words_only`, `charts_critical`). A page with no text layer gives no chart.
- **Manuals already imported.** Location version 11. A document whose text is at version 10 has only its charts
  read (`DocumentStore.replaceCharts`): no table is read again, nothing is recognised again, no text chunk or row
  is re-embedded. Below 10, the existing paths run and write the charts with the tables (`replaceTables(charts:)`,
  which otherwise keeps stored chart passages and renumbers them after new rows). A photographed manual
  (`ingestPages`) gets no charts.
- **Retrieval.** `.chart` is a searched kind. A chart passage is announced as "(chart, Figure 9, page 41; values
  not read)", cited like a drawing ("…, page 41, Figure 9", or "…, page 41 (chart)" uncaptioned), and the block
  carries `VaultRetriever.chartRule`: never a number from the chart or from general knowledge as if the manual
  said it; say the manual gives this as a chart on the cited page, and send the technician there.
- **The page.** `FigureAutoOpenPolicy.PassageKind` gains `chart` and `criticalChart`. A question whose evidence is a
  chart opens its page (`chart_for_question`), found through numbers too, since a value off a chart is asked with
  numbers; a critical chart's page opens with any question or statement (`critical_chart`); readings, corrections
  and job bookkeeping open nothing, as before; a named page stages nothing for a chart. A drawing chunk on a page
  the turn's evidence holds a chart passage for is treated as the chart. `StagedFigure.isChart` keeps the page off
  the model's image slot (`ManualFigureAttachment.Skipped.chartPage`): the phone shows it, the model never reads
  values off it. A chart page asked for by name through `manual_figure` or `show_source` is unchanged.

Tests: `ChartCandidateTests`, `ChartReadingValidatorTests`, `ChartLookupTests`, `ChartPassageTests`,
`ChartCitationTests`, `ChartDescriptionCheckTests`, `ChartPrecedenceTests`, `ChartSafetyClassTests`,
`ChartCachePolicyTests`, and `ChartPagesTests` (an invented manual drawn into a real PDF: found at import, stored,
searched, migrated from version 10, announced, staged).

Interpretations: the candidate carries the page and caption but no document id (the store keys it); the shape
rule reads words only, because PDFKit gives no access to a page's drawn paths; a critical chart's page does not
open on a reading or a correction, which ask for no page.

### P1 — reading (live model, headless measurement)

The two prompts and the schema, pass 1 through `analyzeFrameStructured`, pass 2 as a text call, the
cache on disk, the disclosure sheet, Max's switch in Field Assist settings (on, on demand, by
default) and the org key that may pin it, `AIFeature.chartReading`, the HIPAA rule.

**Measurement without licensed material.** A script draws synthetic charts with Core Graphics from
known data: lines, families, a log axis, dense and sparse ticks, a shaded band, two fonts. The
truth is the data the script drew from. For each provider the wearer can choose, the harness reports
the share of readings that validate, the median and worst error in steps, and how often a reading
the validator accepted was more than two steps off (the number that matters). Output goes to the
work folder, never committed. A real manual's charts are checked by hand on the phone in P4, and
nothing from them goes into a fixture.

### P2 — answering

The words-only and chart passages in retrieval; `chart_lookup`; the precedence rule in `table_lookup`,
`domain_calc` and IS's `target_superheat` when that is built; the figure staging and the new
`FigureAutoOpenPolicy` rule; chain-step marking. A test runs the whole path on a test store with a
hand-written reading: question, passage found, value, wording, page staged.

### P3 — organisations reading at import

The `atImport` ceiling, the estimate shown before the import starts, the cap, progress in the
import row, pausing when hot.

### P4 — device pass (owed)

On the phone with real manuals the owner holds: three charging charts, a fan curve and a derating
curve; each value checked against the page by eye; the disclosure; a re-import paying nothing; the
lens showing the page with Display glasses; a hot phone pausing.

## Risks

- **A confident misread.** The validator ties ticks to printed numbers and keeps points inside the
  axes, but it can't see a point drawn on the wrong curve. Hence *about*, the page that always opens
  for critical charts, the precedence rule, and P1's accepted-but-wrong rate as the number to watch.
- **Sending pages to a provider.** Limited to chart regions, disclosed per manual, switchable by the
  organisation, never in HIPAA mode without its routing.
- **Cost creep.** One reading per chart, cached by exact image and prompt, capped at import.
- **Charts drawn as tables.** Many charging "charts" are grids. Those are JN's and JJ's, and §6 makes
  them win.

## Out of scope

- Wiring diagrams, exploded parts drawings and photographs. They aren't charts and nothing here
  reads them.
- A chart the camera sees live on a unit's door. That is `vision_assess` and the glasses camera.
- Exporting a chart's data, or drawing charts.
- Replacing IS's saturation tables with a manual's pressure–temperature chart.
- Charts in documents that are not manuals (a photo in a conversation, a web page).
