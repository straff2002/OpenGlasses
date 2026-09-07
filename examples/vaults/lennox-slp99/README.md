# Example vault: Lennox SLP99UHVK gas furnace

A complete Field Assist vault built from a real pair of OEM manuals, laid out exactly as
[the vault guide](../../../docs/field-assist-vault-guide.md) describes. It is the reference for what a
customer-built vault looks like, and the fixture `ExampleVaultLennoxTests` imports headlessly.

```
lennox-slp99/
├── manifest.json            id lennox_slp99 · four core files · two manuals · three procedures
├── safety.md                core: the reminders spoken before a panel, the gas train or the burner box is opened
├── error_codes.md           core: every E-code on the seven-segment display, grouped per lookup section
├── models.md                core: the six models, nameplate spellings, unit size codes, field accessories
├── service_values.md        core: line/manifold pressures, Delta P, meter clocking, CO2, flame signal, timings
├── documents/               reference: the extracted manuals — NOT in the repository, see documents/README.md
└── procedures/              three voice-walked diagnostics: pressure-switch lockout, size code, no ignition
```

## What is and is not committed

The core files and procedures are original work written *from* the manuals and are committed. The
manuals themselves are Lennox Industries' copyright and stay out of the repository: `documents/*.md`
is ignored by git, and `documents/README.md` says how to regenerate them from your own PDFs with
`Scripts/extract-manual-text.swift`. Until the two files are in place the importer refuses the
folder with `listed document missing`, which is the intended behaviour for a vault that needs the
customer's own manuals.

## How it was built

1. Both PDFs were run through the repository extractor. Each had a full text layer, so no page was
   recognised, and their printed page numbers match the PDF page index, so citations read as printed.
2. The diagnostic-code table (Service Manual p.19–22, repeated in the Installation Instructions
   p.45–48) became `error_codes.md`, split into sections of a dozen codes so a lookup reads back one
   short section rather than the whole table.
3. The specification table (Service Manual p.2) became one `##` section per model in `models.md`, so a
   spoken or camera-read model number lands on its own section. The manuals spell the same unit four
   ways (`SLP99UH090XV60CK`, `SLP99UH090V60CK`, `SLP99UHXV-090-60C`, `090XV60C`); every spelling is in
   the section heading or body so any of them matches.
4. Measurement tables that a technician compares against in the field (TABLES 34–40) became
   `service_values.md`. Everything carries the manual and page it came from.
5. Three procedures were written for the faults that have a defined path in the manuals. Each passes
   the importer's graph check (entry resolves, every branch resolves, a terminal is reachable).

Core total is about 25 KB, under the 32 KB budget the validator warns at.

## Trying it

Put the two extracted manuals in `documents/`, copy the folder to the phone, and import it from
**Settings › Custom Vaults**. Then:

- *"Start a session in Lennox SLP99 Furnace Service."*
- *"What does E223 mean?"* — answers from `error_codes.md`, then from the manual with a page citation.
- *"Look up 090XV60C."* — the model section, including its own TABLE 39 row.
- *"Start the pressure switch lockout procedure."*
- *"What is the torque for the blower wheel set screw?"* — the manuals do not cover it; the correct answer says so.

## What importing a real manual pair showed (2026-09-07, simulator run)

`ExampleVaultLennoxTests` imports this folder with the manuals in place. Everything the guide promises
holds: validation is clean and under budget, every E-code and every model spelling resolves from the
core with a file citation, the three procedures walk to their terminals, both manuals index (352 and
340 chunks) and a bare `E223` comes back citing Service Manual page 20 and Installation Instructions
page 47 — the printed pages the table sits on. Four things did not hold up and need attention in the
app or the guide, not in the vault:

1. **Exact-code hits lose the ranking to "similar" prose.** A token hit scores `0 + 0.25`; a semantic
   hit on the simulator's embedder scores about `0.89` for *any* passage. Ask *"the display shows E223
   on a heat call"* and the four passages returned are LED-menu prose; the E223 rows are ranked below
   them and cut off. The bare-code path works only because it has no semantic competitor. A matched
   token should sort ahead of unmatched passages, or the boost should exceed 1.0.
2. **The evidence gate never says "insufficient" on a real manual.** With `similarityFloor = 0.30` and
   cosines of 0.87–0.91 for *"torque for the blower wheel set screw"* and *"replace the heat exchanger
   on a Carrier 58MVB"*, the gate passes both and the model is handed three irrelevant passages
   instead of the fixed "the manuals do not cover this" sentence — the exact failure step 6 of the
   guide asks testers to report. The floor has to be calibrated per embedder (the simulator ran
   `nl-word.en`, the word-average fallback; check the sentence model on a device before trusting any
   number), or the gate should use a relative margin rather than an absolute cosine.
3. **Section headings from OEM PDFs are noise.** Citations came back as `§FIGURE 5`, `§C 24VAXC COMMON`,
   `§2 cu ft`, `§2.6 or greater 2.5 or less 1.1`, `§7 - Inspect the condensate drain…`. The chunker's
   heading detector accepts numbered list steps, table rows and any ALL-CAPS label. Until it is
   tightened (skip `FIGURE`/`TABLE` lines, lines with ` - ` after the number, and rows that are mostly
   digits), the `§section` part of a manual citation is worse than nothing; page alone is right.
4. **Page-marker text leaks into passages.** Lennox prints `Page N` at the top of every page, so the
   extractor's own `Page N` line is followed by the OEM's, and chunks read `… Page 34 Page 34 TEST B …`.
   The chunker uses marker lines as breakpoints but does not drop them from the emitted text. Harmless
   here (the numbers agree), but a manual whose printed numbering differs from the PDF index would have
   the OEM line silently override the extractor's — worth stripping marker lines from chunk text and
   only honouring a marker that is the whole line.

Smaller notes for the guide: a lookup returns whole `##` sections in file order and stops at three, so
a spelling that also appears in an introduction or a summary table can push the model's own section
out — put every spelling in the model's heading (done here) and say so in the guide. The extractor's
closing hint prints `"kind": "service_manual"` and the file name as the title for every input; the
author has to edit both. Both manuals repeat the same diagnostic table, so a code query returns the
same row twice from two titles; that is correct, just verbose at `limit: 4`.
