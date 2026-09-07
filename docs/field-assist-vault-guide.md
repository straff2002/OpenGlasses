# Building a Field Assist vault from your own manuals

*OpenGlasses Field Assist · applies to September 2026 builds with the manual tier · team licence required · formats: PDF (text layer or scanned), EPUB, Markdown, plain text*

A vault is a folder. It holds a manifest that names things, a few short markdown files the assistant always has in front of it, and the OEM manuals it searches when a technician asks. You build the folder on a computer, move it to the phones that will use it, and import it once on each.

## What you are building

Every vault has the same shape. The names in `manifest.json` have to match the files exactly, but the file names themselves are yours to choose.

```
rtu-service-vault/
├── manifest.json               names everything below
├── safety.md                   core: always in context
├── error_codes.md              core: fault codes by model
├── models.md                   core: nameplate quick reference
├── documents/                  reference: retrieved per question
│   ├── RTU-500-service-manual.pdf
│   ├── RTU-500-wiring.pdf
│   └── RTU-700-install-guide.pdf
└── procedures/                 optional: step-by-step flows
    └── low_pressure_diagnostic.json
```

The two kinds of content behave differently, and getting the split right is most of the work.

| | Core files | Documents |
|---|---|---|
| **When read** | Into the assistant's context on every single question | Only the passages relevant to a question, retrieved at that moment |
| **Size** | Keep the total under about 32 KB; the importer warns above that | No practical limit; a 300-page manual is fine |
| **Right for** | Safety rules, fault-code tables, model and refrigerant quick references | Full service manuals, wiring guides, installation and commissioning documents |
| **Citations** | Source file name | Manual title and page number |
| **Editable on the phone** | Yes; edits are kept separately from your originals | No; re-import to change |

## Before you start

1. Install the TestFlight build on the iPhone and pair the glasses.
2. Open **Settings › Field Assist**, paste the licence code you were sent, and tap **Activate Licence**. The status card should show **Tier: Team**. Custom vaults and manual indexing need a team licence; a solo purchase covers only the bundled vaults.
3. Turn on **Enable Field Assist** on the same screen.
4. Have a way to get a folder onto the phone. iCloud Drive in the Files app is the simplest; AirDrop of the whole folder also works.

## Step 1 · Prepare the manuals

The importer reads the text layer of a PDF. Open each manual on your computer and try to select a sentence with the cursor. If the text highlights, the page imports as-is. If nothing selects, the page is a scanned image. Scans still import; you have three ways to handle them, and you can mix them per manual.

**Route A · Let the phone read it.** Nothing to install. Import the scanned PDF like any other. The app reads scanned pages itself during import, page by page, on the device. A 300-page scan takes minutes; keep the app open, and if it is interrupted the import resumes where it stopped. The vault row afterwards shows how many pages were read this way and how many came out low confidence, so you know which manual to replace with a better copy. Any answer drawn from a recognised page carries a note to verify figures against the printed page, because numbers are where recognition fails quietly.

**Route B · Add a text layer on any computer (recommended for anything you will reuse).** Run the scan through an OCR tool that writes a searchable PDF, then import that PDF. The pages stay the same, so citations still match the printed book, and the phone does no recognition at all. Free, works on Windows, Mac and Linux:

```
ocrmypdf --language eng RTU-500-service-manual-scan.pdf RTU-500-service-manual.pdf
```

OCRmyPDF is at ocrmypdf.readthedocs.io; on Windows install it through the instructions there (it runs under Python, with Tesseract as the recognition engine). Adobe Acrobat's "Recognize Text" does the same job if you already have it, and so do most scanner drivers' "searchable PDF" settings if you are scanning the book yourself. Whatever tool you use, open the result and select a sentence to confirm the text layer is there before you copy it into `documents/`.

**Route C · The repository's extractor, on a Mac.** If you have a Mac, the app's repository includes a script that does the same per-page read and writes Markdown with a `Page N` line before each page, which lets you open the text and correct a misread figure before anyone relies on it. It is not in the app; download it from the public repository:

```
curl -O https://raw.githubusercontent.com/straff2002/OpenGlasses/main/Scripts/extract-manual-text.swift
swift extract-manual-text.swift RTU-500-service-manual.pdf
```

It needs Apple's command-line developer tools (`xcode-select --install`). It writes `RTU-500-service-manual.md` beside the PDF and prints how many pages were recognised and how many came out low confidence. Put the `.md` in `documents/` instead of the PDF and give it the same title.

It also warns, per page, when a manual prints its own page number at the top of the page and that number disagrees with the page's position in the PDF — usually an unnumbered cover or roman-numeral front matter shifting everything by a page or two — and counts them in the closing summary. Citations always name the physical page, the one you reach by counting from the front, so either fix the PDF (delete or add the front matter until the numbers line up) or accept the offset and tell your technicians about it. Zero warnings means a citation reads exactly as the page is printed.

Page numbers are preserved automatically either way, so a citation reads *RTU-500 Service Manual, page 42* and the technician can open the paper copy to it. That only works if the PDF's pages match the printed pages, which is true of nearly every OEM PDF.

A few habits that pay off:

- **One file per manual, one manual per model family.** A combined 900-page binder still works, but a technician hears the title in every citation, so shorter, specific titles read better.
- **Trim what does not help in the field.** Warranty terms, ordering forms and marketing pages add index time and add nothing to answers. Delete those pages before you copy the file in.
- **Keep fault-code tables in the core too.** The manual's fault-code chapter is retrieved fine, but a code that also sits in `error_codes.md` is found instantly by the nameplate lookup without a search at all.

## Step 2 · Write the core files

Markdown, plain text, any editor. Two conventions matter because the app relies on them.

### Headings define lookup sections

When a technician says *"look up fault T02"* or points the glasses at a display, the app splits each core file at `##` and `###` headings and returns the whole section that contains an exact match for the code. So group codes under a heading per manufacturer or model, and put the code in a table row or at the start of a line. A section that runs on for pages will be read back in full, so keep sections tight.

```markdown
# Fault Codes

## Acme RTU-500 (Series 5 controller)

| Code | Meaning                     | First check                                |
|------|-----------------------------|--------------------------------------------|
| ZX9  | Low refrigerant charge      | Sight glass, then subcooling before adding |
| ZX3  | Condenser fan failure       | Fan capacitor, fan relay                   |
| ZX1  | Discharge line sensor fault | Sensor resistance vs. table on page 61     |

## Acme RTU-700 (Series 7 controller)

| Code | Meaning                     | First check                                |
|------|-----------------------------|--------------------------------------------|
| F12  | High pressure lockout       | Condenser coil, fan staging                |
```

### A safety file the assistant repeats before risky steps

The assistant is instructed by the manifest to remind the technician of safety steps before opening electrical panels or the refrigerant circuit. Put the reminders you want spoken in `safety.md`, in your own words and to your own site rules. Lockout, PPE, recovery before opening the circuit, gas isolation for furnaces, and anything specific to Manitoba code belong here.

### A nameplate reference

`models.md` is where model and serial patterns live: what the numbers on the plate mean, refrigerant per model, nominal charge, controller type. When the camera reads a plate, the model number is matched against these sections the same way a fault code is.

**Put every spelling of a model in that model's own heading.** Manuals and nameplates rarely agree — `SLP99UH090XV60CK` on the plate, `SLP99UHXV-090-60C` in the parts list, `090XV60C` in a table. A lookup returns whole `##` sections in file order and stops at three, so a spelling that appears anywhere earlier in the file — an introduction, a summary table, a compatibility note — spends one of those three slots and can push the model's own section out of the answer. A heading that carries all the spellings costs nothing and cannot be crowded out:

```markdown
## SLP99UH090XV60CK (SLP99UHXV-090-60C, 090XV60C, SLP99UH090V60CK)
```

## Step 3 · Write the manifest

This is the whole file for the folder above.

```json
{
  "id": "acme_rtu",
  "name": "Acme RTU Service",
  "version": "1.0.0",
  "files": ["safety.md", "error_codes.md", "models.md"],
  "documents_dir": "documents",
  "documents": [
    { "file": "RTU-500-service-manual.pdf", "title": "RTU-500 Service Manual", "kind": "service_manual" },
    { "file": "RTU-500-wiring.pdf",         "title": "RTU-500 Wiring",         "kind": "wiring" },
    { "file": "RTU-700-install-guide.pdf",  "title": "RTU-700 Install Guide",  "kind": "install_guide" }
  ],
  "procedures_dir": "procedures",
  "gating": { "iap": "enterprise" },
  "prompt_rules": [
    "Never fabricate equipment data, fault codes, refrigerant properties, or procedures.",
    "Use only the vault contents, the retrieved manual passages, and the technician's stated observations.",
    "Cite the source file or manual page on every factual claim.",
    "If the manuals do not cover the question, say so and recommend escalation rather than guessing.",
    "Remind the technician of the relevant safety steps before any action that opens an electrical panel, the gas train, or the refrigerant circuit."
  ],
  "source_attribution_format": "Source: {files}",
  "source_attribution_required": true
}
```

| Key | What it does |
|---|---|
| `id` | Lowercase, no spaces. Never change it after the first import; updates match on it. |
| `name` | What technicians hear: *"start a session in Acme RTU Service"*. |
| `version` | Bump it when you re-import. |
| `files` | The core files, in the order you want them read. |
| `documents_dir` / `documents` | The manuals. `title` is what the technician hears in a citation; `kind` is a free-text label. |
| `procedures_dir` | Omit it if you have no procedures. |
| `gating` | Always `{ "iap": "enterprise" }` for a custom vault. |
| `prompt_rules` | The rules the assistant follows while this vault is active. |
| `source_attribution_*` | Forces a source line on every factual claim drawn from the core files. |

> **The importer refuses a manifest whose rules do not mention fabrication and citation.** Your `prompt_rules` must include a rule containing the word *fabricate* and one containing *cite*. The rules above satisfy that; reword them freely as long as those two words survive.
>
> **The title is the citation.** Whatever you put in `title` is what the technician hears: *"Source: RTU-500 Service Manual, page 42"*. Name it the way your people already refer to the book.

## Step 4 · Procedures (optional)

A procedure is a branching checklist the assistant walks a technician through by voice: *"next"*, *"go back"*, *"repeat that"*, and branch choices from what the technician reports. Skip this for your first import; add one once the question-and-answer loop works.

Each procedure is one JSON file in `procedures/`. The importer checks the graph before install: the entry step must exist, every branch must point at a real step, every non-terminal step needs a way forward, and at least one terminal step must be reachable.

```json
{
  "id": "rtu500_low_charge",
  "title": "RTU-500 Low Charge Diagnostic",
  "version": "1.0.0",
  "description": "Confirm and correct a ZX9 low-charge fault on the RTU-500.",
  "safety_notes": [
    "Lock out power before opening the control panel.",
    "Recover refrigerant before opening the circuit."
  ],
  "entry_step": "confirm_fault",
  "steps": [
    {
      "id": "confirm_fault",
      "title": "Confirm the fault",
      "instruction": "Read the controller display. Is ZX9 active now, or only in the history log?",
      "expected_input": "active or history",
      "citations": ["error_codes.md"],
      "branches": [
        { "id": "active",  "condition": "ZX9 is active now",     "next": "check_sight_glass" },
        { "id": "history", "condition": "ZX9 is only in the log", "next": "intermittent" }
      ],
      "default_next": "check_sight_glass"
    },
    {
      "id": "check_sight_glass",
      "title": "Check the sight glass",
      "instruction": "With the unit running for ten minutes, look at the liquid line sight glass. Is it clear, or bubbling?",
      "expected_input": "clear or bubbling",
      "safety_note": "Keep hands clear of the condenser fan while the panel is open.",
      "citations": ["RTU-500 Service Manual"],
      "branches": [
        { "id": "bubbling", "condition": "Bubbling or foaming", "next": "measure_subcooling" },
        { "id": "clear",    "condition": "Clear",               "next": "sensor_check" }
      ],
      "default_next": "measure_subcooling"
    },
    {
      "id": "measure_subcooling",
      "title": "Measure subcooling",
      "instruction": "Read liquid line pressure and temperature and tell me both. The manual's target is on page 58.",
      "expected_input": "liquid pressure and temperature",
      "citations": ["RTU-500 Service Manual"],
      "default_next": "done_charge"
    },
    { "id": "sensor_check", "title": "Sensor check", "instruction": "The charge looks right. Check the low-pressure transducer per page 61 before adding refrigerant.", "terminal": true, "outcome": "sensor_suspected" },
    { "id": "intermittent", "title": "Intermittent fault", "instruction": "Clear the log, run the unit for a full cycle, and re-run this check if ZX9 returns.", "terminal": true, "outcome": "deferred" },
    { "id": "done_charge", "title": "Charge corrected", "instruction": "Adjust charge to the target subcooling, record before and after readings, and clear the fault.", "terminal": true, "outcome": "resolved" }
  ]
}
```

## Step 5 · Import on the iPhone

1. Copy the whole folder into iCloud Drive (or AirDrop it to the phone and save it in Files). Do not zip it; the importer takes a folder.
2. Open **Settings › Custom Vaults** and tap **Import Vault Folder…**, then pick the folder.
3. The app validates first. If anything is wrong it names the file and the problem, and nothing is installed. Fix it on the computer and try again.
4. On success the vault appears in the list and indexing starts immediately. Each manual shows a progress bar and then a section count, for example *RTU-500 Service Manual · 412 sections*. Leave the app in the foreground until every manual has a count.
5. Warnings are advisory. The one you are most likely to see says the core files exceed the budget; move long material into `documents` and re-import.

## Step 6 · Test the loop

1. In **Settings › Field Assist**, choose your vault as the default.
2. Say *"Start a session in Acme RTU Service."*
3. Ask about a code you know is in the manual: *"What does fault ZX9 mean on the RTU-500?"* The answer should end with a source line naming the manual and page.
4. Look at a nameplate and say *"Look up this nameplate."* The app reads the plate on the phone, matches the model against your core files, then against the manuals.
5. Ask something the manuals do not cover, for example a torque spec that is not in the book. The correct answer is that the loaded manuals do not cover it and to escalate.

   The check that produces that answer is measured, not assumed, and it is worth knowing what it can and cannot do. Against a real pair of furnace manuals it refused three out of four out-of-scope questions — a torque figure the book never gives, another manufacturer's efficiency rating, a price, a warranty procedure. What it does **not** refuse is a question about a subject your manuals genuinely cover but a machine they do not: ask about the heat exchanger on someone else's furnace and passages about heat exchangers come back, because they are about heat exchangers. There the vault's prompt rules and the page citation on every passage are what keep the answer honest — which is why the rules about fabricating and citing are required. The same check occasionally refuses a fair question whose wording shares little with the book's; rephrase it in the manual's own words and ask again.

   If you get a confident answer where the book is silent, tell us; that is the behaviour the vault rules exist to prevent.
6. End the session. The audit log records every question, answer, photo and citation, and a team licence can export it as PDF.

> **Everything stays on the phone.** Manuals are indexed and searched on the device and never uploaded to us. The passages relevant to a question are sent to whichever AI model you configured, together with the question, in the same way the rest of the app works. If you use an on-device model, nothing leaves the phone at all.

## Updating a vault

Edit the folder on the computer, bump `version`, and import again with the same `id`. Manuals whose content has not changed are skipped; a changed manual is re-indexed and its old index removed; a manual you dropped from the manifest is removed. Technicians' in-app edits to the core files are kept and layered over your new originals. To pull a vault off the phone with those edits included, swipe the vault row and choose **Export**; the exported folder imports straight back in.

## If the import refuses

| Message | Fix |
|---|---|
| `manifest.json is missing or unreadable` | The file must sit at the top of the folder with that exact name. |
| `listed file missing: models.md` | A name in `files` does not match a file. Case and extension matter. |
| `listed document missing: documents/…` | Same for a manual; check `documents_dir` and the file name. |
| `… has no text layer on N of N pages; it will be read by on-device recognition at import` | A warning, not a refusal. Either let the phone read it (Route A), or add a text layer on your computer first (Route B or C). |
| `prompt_rules should address 'fabricate'` | Add a rule containing the word fabricate; likewise for cite. |
| `document has no title` | Every entry in `documents` needs a non-empty `title`. |
| `… → unknown step` | A procedure branch points at a step id that does not exist. |
| `no terminal step is reachable` | Give the procedure at least one step with `"terminal": true` that the entry step can reach. |
| `core files total … characters (budget 32768)` | Warning only. Move the long material into a document. |

## Sharing a vault: three situations

Most of this guide assumes you are building a vault for your own technicians. Two other situations come up, and they work differently. Decide which one you are in before you start.

### 1 · Your own crew

You build one vault, your manuals included, and put it on the phones your technicians carry. Nothing changes; this is the path the rest of the guide describes.

### 2 · Building a vault for a customer

Here you assemble the whole vault for one customer: their core files, their manuals, their procedures. You test it, then you hand it over finished. Their technicians do not each repeat the work; one person prepares the manuals once and everyone else uses the result.

The manuals in such a vault are normally the customer's own. They already hold them through their OEM portal access, their dealer relationship, or the equipment itself. What you are providing is the assembly, the text extraction and the testing. If you intend to reuse one master set of manuals across several customers, that is redistribution and it needs the manufacturer's permission, so check your agreements first.

Delivery today is by hand. You install the finished folder on the phones you are already setting up, importing once per phone, a few minutes each. An enrolment profile that installs the pack, the manuals and the configuration together from one scan is planned, so this step gets shorter.

### 3 · Publishing a pack

The parts you authored, the core files and the procedures, can be published as a **pack** that other Field Assist users install from the app's Packs list, and that a team licence can include for a whole organisation. What you are publishing is your fault-code tables, nameplate decoding, safety rules and diagnostics, which is where your field knowledge lives.

> **A pack must never contain manufacturer manuals.** It goes into a catalog anyone can install from, so everything inside it is copied to people you have never met. Keep the manuals out. A customer who installs your pack pairs it with manuals from their own vault, or from a vault you built for them as in situation 2.

To prepare one:

1. Copy the vault folder and delete `documents/`. Remove `documents` and `documents_dir` from the manifest, and set `gating` to `{ "iap": "com.openglasses.vault.<id>" }`, where `<id>` is the vault's `id`.
2. Add a `pack.json` beside the manifest:

```json
{
  "id": "com.openglasses.vault.acme_rtu",
  "vaultId": "acme_rtu",
  "version": "1.0.0",
  "name": "Acme RTU Service",
  "summary": "Fault codes, nameplate decoding, and diagnostics for Acme rooftop units.",
  "author": "Your company name, as technicians should see it",
  "licensePack": "acme_rtu"
}
```

3. Send the folder to us. We sign it, host it, and list it in the catalog; nothing unsigned can be installed. If the pack includes extracted manual text, it needs the manufacturer's written permission to redistribute, recorded in the pack, and we will ask for it.
4. Decide how it is sold. A pack is its own App Store product for solo technicians, and a team licence includes it when the code is issued with the pack's key, so your own customers get it with their licence rather than buying it separately.

Updating a published pack is the same folder with a higher `version`. Technicians who install the update keep their in-app edits and their own manuals.

## Checklist before you send a vault to a customer

- [ ] Every PDF selects text on the computer, or you have decided to let the phone read it.
- [ ] Each manual's `title` is the name the crew already uses.
- [ ] Fault codes sit under a heading per model, one code per row.
- [ ] `safety.md` says what you want spoken, in your words.
- [ ] Core files total well under 32 KB.
- [ ] Import shows a section count for every manual.
- [ ] A known fault code answers with a page citation.
- [ ] An out-of-scope question answers with "the manuals do not cover this".
