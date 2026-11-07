# Plan KR — The Page It Says (one page per turn, the row marked, the size it read, guided work in the trade's words)

**Status:** 🚧 Drafted 2026-11-07 from the partner's retest on build 615 (2026-11-06: a furnace job and
two electrical code-book jobs, gpt-6-luna, phone only). Owner decisions taken as recommended on
2026-11-07 ("plan merged, build it"). **P1 and P2 built headless** on `feat/kr-page-it-says`: a tool
round's rebuild stages no page, a page a tool put up stays for the turn, pages said in words are
pages (a named page opens nothing by itself), a show-me with no object reopens the last source or
asks, a show-me after a lookup this turn shows only that table, and `manual_figure` asked for the
looked-up table opens it through `show_source`'s path, rows marked. **P0 measured** (simulator, the
app's own import; findings kept local). **P3 and P4 built headless** on the same branch: an aught row
says it is the size asked; the table hint reads the trade's words, demotes kilovolt-band tables for a
question naming no voltage and names each table's conditions; a note-only heading yields, a heading
heads only the columns it is centred over, and a column's own heading wins; "mm2" is "mm²"; a contents
chunk is not a passage and a section named by its heading is carried on; a walk-through request starts
the chosen chain, the refusal asks for a yes-or-no offer, and the list flags a column problem. P5–P8
not started.
**Track:** Field Assist. Every turn that opens a manual page; every table lookup; every rule chain;
every job close; the support report.
**Related:** Plan [GB](GB-field-test-round-3.md) P1 (`FigureAutoOpenPolicy`), Plan
[KD](KD-vault-retest-581.md) (chain start guard, AWG sizes, the label gate, printed pages), Plan
[JJ](JJ-table-lookup-and-rule-chains.md) P2 (the row "show me the table" marks), Plan
[JW](JW-vault-test-findings.md) P1b (`TableDirectory`), Plan [KE](KE-symptom-diagnosis-and-vault-only.md)
(`vault_only`), Plan [KL](KL-say-why-and-keep-the-tools.md) P2 (read-only tool effects).

---

## Why

The retest confirmed most of KD: a derating table read and its row marked, ampacity values from two
tables, one sizing chain run step by step, no unasked expert request, no doubled replies, and a rename
that no longer ends the job. What it found instead is that the app says one thing and shows another. It
said one printed page was open while another page was on screen. It answered from one table while a
different table was on screen. It refused its own correct row because the table prints 4/0 as 0000. It
made the technician repeat a set phrase after they had already asked to be walked through a chain. Each
of these is a deterministic seam, not the model.

## Findings and causes

1. **The page on screen is re-chosen after every tool round.**
   - `LLMService.refreshedFieldInstructions` rebuilds the Field Assist block after each tool iteration.
     The rebuild runs `manualPassagesContext`, which stages the turn's best retrieved figure with
     `presentOnPhone`, and the `$stagedFigure` sink opens it. Whatever `manual_figure` or `show_source`
     put up is covered on the next round.
   - A request for a printed page, said in words: the search's page opened first, then `manual_figure`
     opened the right page, then three `table_lookup` rounds each put the search's page back. The reply
     came from `manual_figure`'s result, and the screen from the last round.
   - A table request on a new job: the reply named one table, and three lookup rounds re-presented
     another table the search had found.
2. **A spoken page number is not a page.** `PageReference` reads digits only, so a page number said in
   words named nothing. The turn still classed as `.showMe` ("go" + "page"), and `FigureAutoOpenPolicy`
   presents whatever a `.showMe` turn retrieved.
3. **A show-me with no object opens the search's guess.** A request cut off after "show me the" (furnace
   job) opened an unrelated figure, two turns after the diagnosis had cited the right page.
4. **A show-me after a lookup can open another table.** `RetrievedFigureLabelGate` excludes other labels
   only when the turn *names* one. After `table_lookup` read a table this turn, a `.showMe` turn may still
   present a different table.
5. **"Show me the table" marks the row through only one of the two tools.** `show_source` presents the
   rows `table_lookup` noted, marked. `manual_figure` opens the bare page and never reads them, and its
   description offers to "re-open the source a previous answer cited". The model chose `manual_figure`
   twice and `show_source` three times.
6. **A row found by AWG size doesn't say so.** Matching treats 4/0, 0000 and "four aught" as one size
   (KD P0). The result prints "row 0000 …" and nothing links it to the size asked. Next to it,
   `mismatchLine` teaches the model to refuse a row that isn't the one asked for, so it refused.
7. **A table is chosen without saying why.** A question about one conductor material in a raceway was
   answered from a medium-voltage appendix table. `TableDirectory.hint` names one or two tables and says
   to ask for inputs. It doesn't say to give the conditions assumed, or to ask the one condition that
   separates the candidates.
8. **A column heading can be a note.** One temperature column came back with its note marker as its
   heading. Which line of a stacked heading wins has to be read from the phone's extraction, because the
   Mac's differs (KG).
9. **"Walk me through it" is not asking.** KD P0 counts "chain" plus a run verb, or every significant word
   of the chain's name. A sizing request that ended "walk me through it" had neither. The refusal says
   "you may offer the chain by name", and the model turned that into a phrase for the technician to repeat.
10. **A chain that can't start is listed as if it could.** The conduit-fill chain names a column that is
    printed under more than one heading. `columnProblems` refuses it at start, but the list flags only
    tables it can't read: a chain missing a table says "can't start", and this one didn't. We supplied the
    chain file.
11. **Closing a job keeps calling tools, and a turn stops when the app is put away.**
    - After `field_session end` the model called `field_session`, `activity` and `field_session` again,
      hit the tool budget and spoke the fallback, which included the day's activity count.
    - The app went to the background seconds into the turn, with listening already off. With no
      background task on the turn, iOS suspended it for almost three minutes: 205.7 s end to end for
      about 15 s of work.
12. **A job's name never reaches its title.** `setJobName` stores the name in `assetId` and does not call
    `onJobIdentityChanged`, and `JobThreadTitle` is built from the reference and the *equipment*.
13. **The report can't show what it doesn't print.**
    - The Vault line says "Vault-only: on" only when it is on, and no screen shows the setting.
    - Two jobs in one conversation each print the whole conversation, and the first job claims the
      second one's AI turns, so the second read "No AI turn records".
    - "figure presented" lines don't say where the page went: the phone, the model only, or nowhere.
14. **An action in a two-part request goes unsaid.** A request to take a part off the van stock and explain
    a test ran `van_stock` and answered only the question.

## Phases

### P0 — Read the partner's tables as the phone does (local, no code shipped)

The partner's books stay out of the repo and the plan (testing only). On the phone, export the code-book
vault's table catalogue and the tables these turns used, as extracted. On the Mac, replay them through
`TableDirectory.hint`, `TableLookup.resolve` and `RuleChainTool.columnProblems` to find:
- which tables the new-job turn's words offer, and in what order;
- which line the note-marked temperature heading kept;
- which conduit-fill chain step is ambiguous, and the full headings it should name;
- the chunks the furnace's sequence-of-operation section was cut into on the phone.

Output: an aggregate evidence note in this plan (counts and mechanisms only), and a corrected chain file
for the partner, sent as a handover and never committed.

**Measured 2026-11-07** (simulator, the app's own import of both editions; aggregate and generic only):
- The hint for a plain aluminum-in-conduit sizing question named two medium-voltage buried-conduit
  tables and a bonding table; the raceway table that answers it ranked sixth. The book prints
  "raceway" where the technician says "conduit", the wrong tables print "conduit" and a "ground wire"
  heading, and the right one shared only the material, the unit and "size". Asked in the book's own
  words ("… in a raceway ampacity") there was no hint at all: "ampacity" was not a value word.
- A temperature column whose heading line sat over only its own column took its note marker as its leaf,
  and its heading spread over the two columns to its left as a middle level; the stub's heading
  reached the first value column too.
- A conduit-fill chain's area step was ambiguous over four columns because "mm2" did not match the
  printed "mm²". Its fill-count step needs a heading row the extractor does not read; no chain-file
  fix exists for it yet.
- An aught size found its row (0000) by AWG form, and nothing in the result linked it to the asked size.
- The furnace's sequence-of-operation section is fifteen chunks over three pages; asked for by name,
  retrieval found its first chunk and a table-of-contents chunk; asked as "walk me through …", none
  of it.

### P1 — One page per turn (findings 1–4)

- The automatic figure is decided once, on the turn's first build of the Field Assist block. A refresh
  after a tool round keeps the passages and stages nothing (`manualPassagesContext` gains a
  `stagesFigure: Bool`; the refresh passes false).
- A page a tool put up this turn (`manual_figure`, `show_source`, a lookup's table) is never replaced by
  the automatic path for the rest of the turn (`turnPages` or a turn flag on `FieldSessionService`).
- `PageReference` reads spoken page numbers ("page four twenty-seven", "four hundred and twenty-seven",
  "page four oh eight", "page twelve") and keeps "printed" with the number. A turn that names a page
  presents nothing automatically; the page is `manual_figure`'s (`printed_page` when "printed" is said).
- A show-me with no object ("show me", "show me the", "show me that", "show me it") reopens the last
  source the job cited (`lastShownFigure` or the noted lookup); with none, nothing opens and the model is
  told to ask what to show.
- A `.showMe` turn after `table_lookup` read a table this turn presents only that table's label.
- Tests, with invented pages and tables: a search page, then `manual_figure`, then three lookup rounds
  ends on `manual_figure`'s page; a lookup's table stays on screen over a retrieved one; page numbers in
  words; a cut-off "show me the".

### P2 — The table opens with its row marked (finding 5)

- `manual_figure` asked for the table `table_lookup` last read (its label, or `again`, or no label on a
  turn right after a lookup) presents through `ShowSourceCenter`'s noted lookup, rows marked, exactly as
  `show_source` does. A numbered figure or page is unchanged.
- Descriptions: `show_source` is the path for "show me that" and "show me the table" after an answer;
  `manual_figure` is for a figure, table or page by number. Drop "re-open the source a previous answer
  cited" from `manual_figure`.
- Tests: both tools mark the same rows after a lookup on an invented table.

### P3 — The row, the table and the heading it read (findings 6–8)

- A row matched by AWG size in another printed form says so in the result: "row 0000 (this table prints
  4/0, four aught, as 0000: the size asked)". The reply rule: say the size as the technician said it.
- When `TableDirectory.hint` offers tables whose titles or headings differ in a deciding condition
  (voltage band, raceway or free air, conductor count, copper or aluminum), the hint names each one's
  condition and tells the model to say the table and the conditions it assumed, or ask the one condition
  that decides (owner decision 4). The ordering change, if any, waits for P0's replay.
- A column heading that is only a note marker ("See Note", "Note", "*") takes the heading line above it,
  if P0 shows that is where the temperature went.
- Tests: the result line for an aught row; the hint over a catalogue of invented tables shaped like P0's
  (titles that differ by voltage band, no real cells).

**Built 2026-11-07 (headless):**
- `TableLookup.aughtNote`/`aughtReplyLine`: a row found by AWG basis reads "row 0000 (this table prints
  4/0, four aught, as 0000: the size asked)", and the result says to give the size as the technician
  said it. `mismatchLine` is unchanged and never fires on that basis.
- `TableDirectory`: "ampacity", "ampacities" and "amperage" are value words. The hint's ranking
  (`ranked(…, asTechnicianSaid: true)`, the hint only; `table_lookup`'s words are read as written)
  counts "conduit" as "raceway" and "wire" as "conductor", and scores a kilovolt-band table at half
  when the question names no voltage. `conditions(of:)` reads material, voltage band, where the
  conductors run, how many, and ambient from a title (a kV band from the headings); the hint names
  them per table and says to state the table and conditions assumed, and — when the offered tables
  differ — to ask only the one that decides.
- `TableExtractor`: a heading spreads over neighbouring columns only when it is centred over them
  (`spanOffCentre`); a leaf that is only a note marker yields to the heading above it
  (`withoutNoteLeaf`); a row-header column's heading is left out of a value column's path above its
  own heading. `TableLookup` prefers, among columns matched alike, the one whose own heading (the
  last that is not a note marker) holds the asked words, so tables already stored resolve too.
- `TableLookup.tokens` folds ² and ³ to 2 and 3 on both sides.
- Retrieval (added from P0): a chunk that is mostly table-of-contents lines is not a candidate
  (`VaultRetriever.isContentsList`), and when the turn holds every content word of a passage's section
  heading (three or more words), the section's following chunks follow that passage in order up to
  4,200 characters (`continuingSection`, `DocumentStore.passages(after:)`, wired in `makeRetriever`).
  A turn that names the heading but whose retrieval finds none of the section is not helped.

### P4 — Guided work in the trade's words (findings 9–10)

- `TechnicianRequest` counts a guided-walk request as asking for the chain the model chose: "walk me
  through", "talk me through", "take me through", "step me through", "guide me", "step by step", "let's
  work it out", when the turn shares the chain name's task words (size, check, breaker, fit, voltage drop)
  and, where the name has one, its material. A plain question ("how many can I fit?") stays a question.
- The refusal tells the model to offer the chain as a yes-or-no question and never to give the technician
  words to say. A short yes after the offer already starts it (KD P2).
- The chain list says "can't start" for a column problem too, with the step, as it does for a missing
  table, so it is seen before anyone asks.
- Tests: invented sizing and fill requests, with and without walk-through words; the list line for a
  chain with an ambiguous column.

**Built 2026-11-07 (headless):** `TechnicianRequest.asksToRunChain(_:chain:)` counts the walk-through
words when the turn shares a task word of the chain's name (size, check, breaker, fit/fill, derate,
voltage drop as both words; "check" alone only for a chain whose one task it is) and its material; a
name with no known task word needs its other words said. `RuleChainTool.notAskedRefusal` asks for one
yes-or-no offer by name and never words to say; a short yes after it starts the chain (KD P2,
unchanged). The list marks a column problem "can't start: step N (name) names a column of Table X
printed under more than one heading" (`listMark`).

### P5 — A close ends the turn, and a turn finishes when the phone is put away (finding 11)

- `field_session end`'s result ends with the turn-end line: confirm in one sentence (outcome and billable
  time) and call no other tool unless the technician asked for the report.
- The budget fallback's "Done so far" leaves out read-only results (`executionSemantics.effect`, KL P2),
  so a day's activity count is never read out as something done.
- A Direct turn in flight when the app leaves the foreground runs inside a background task until it ends
  or iOS's allowance runs out (owner decision 5). If it ends unspoken, the reply is kept in the
  conversation and the next foreground says it's there.
- Tests: a close followed by more tool calls stops after the end; the fallback over [end, status, activity]; the
  background-task wrapper through a seam.

### P6 — The name, the setting and the report say what they mean (findings 12–13)

- `setJobName` calls `onJobIdentityChanged`; the title is "Job <reference> — <name>", or the name alone
  when it already starts with the reference (owner decision 1). The report heading carries it.
- The Vault line always says "Vault-only: on" or "off", and the vault's screen in Settings › Field
  Assist shows it, read-only, as set by the vault (owner decision 6).
- A job's section prints its conversation only from its start to its end (a minute's margin) when the
  thread is shared, and AI turns are claimed by the job's session id first, then by thread inside the
  job's own window.
- "figure presented" lines say where it went: on the phone, to the model only, or nowhere.
- Tests: two jobs in one thread export without overlap and each keeps its own turns; the title rule.

### P7 — What was done is said (finding 14)

- A stock change, reading or task change made in a turn that also asks a question ends its result with
  the one line the reply must carry ("Say: one taken off the van"), like `set_job_reference`'s
  confirmation line. Scope: `van_stock` writes first (owner decision 7).
- The section split from P0 was added to P3 (a contents chunk is not a passage; a named section is
  carried on). Measuring it on the retrieval keys is the KN/KO/KQ rounds'.

### P8 — Device re-run (owed)

The partner's turns from the 2026-11-06 report, on the phone and then with glasses connected: a printed
page asked for in words; "show me the table" after each kind of lookup; an aught size on a new job; a
table question with and without the voltage; a walk-through request for a sizing chain; the conduit-fill
chain with the corrected file; closing a job and leaving the app straight away; a rename; two jobs in
one conversation in the export.

## Decisions for the owner

1. **Title with a name:** "Job <reference> — <name>" (recommended), or the name alone.
2. **Guided-walk words start a chain:** yes, narrowing KD P0's "only when asked" to include them
   (recommended), or keep the explicit form.
3. **Code books as `standard` documents** (open only through a citation): leave the partner's manifest as
   it is, since P1 removes the reason (recommended), or suggest the change.
4. **Choosing between tables:** say the table and the conditions assumed, asking only when two fit and a
   condition decides (recommended), or always ask.
5. **Background task on a Direct turn:** yes (recommended); it only lets a started turn finish.
6. **Where Vault-only shows:** the vault's settings screen and the report (recommended), or also the job
   screen.
7. **Which actions must be said:** stock changes first (recommended), or every job write.

## Not in this plan

- The heating-sequence section beyond P3's two narrow fixes, and the post-repair checkout: retrieval,
  measured on the phone in the KN/KO/KQ rounds (a turn naming the heading whose search finds none of
  the section is still not helped).
- The ignitor resistance: not in the manuals; the labelled web figure was the right answer.
- The connected-glasses retest: P8.
