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
the chosen chain, the refusal asks for a yes-or-no offer, and the list flags a column problem. **P5–P7
built headless** on the same branch: a close the technician did not also ask the report of ends the
turn on the outcome and billable time, "Done so far" leaves out what only read, and a Direct turn in
flight when the app leaves the foreground finishes inside a background task; a rename reaches the
job's title and the report heading, the report always says Vault-only on or off and the vault's
settings screen shows it, two jobs in one conversation each print only their own part and keep their
own AI turns, and a figure line says where the page went; every `van_stock` write ends with what the
reply must say. **P1–P7 built headless; P8 device re-run owed.** **Follow-up built 2026-11-09:** the
conduit-fill chain starts — a short table's counted headings, a heading that wraps and a heading over
the rows are read (measured on the simulator's import of both editions); the corrected chain file is
local, for the owner to send with the build that carries it.
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
  fix exists for it yet. (Read since the follow-up after P7, with its conductor-area step's row groups.)
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

**Built 2026-11-07 (headless):**
- `field_session end` returns `FieldSessionTool.endedResult`: when the turn's words did not also ask
  for the report (`TechnicianRequest.asksForReport`: report, summary or a sending word), its last line
  is `ToolTurnEnd.confirmLine` ("End of turn — confirm this … : Job closed: resolved, 45 min
  billable."). `ToolTurnEnd` gained `.afterConfirming(summary:)`; the loop ends the round there, makes
  the one request left with tools withheld, answers every later call as not run, and says the summary
  if the model says nothing. Only `field_session`'s `end` may end a turn (`mayEndTurn(_ call:)`), not
  its other actions, whose results carry vault and job text. With the report asked for, or no words
  captured, the result is as before.
- `ToolLoopBudget.spoken(from:readsOnly:)` skips a call that only read, through
  `ProviderLoopAdapter.readsOnly`, which `LLMService.notingStalls` sets from `callEffect` for all five
  providers. `field_session`'s "status", "list" and "vaults" are now read actions
  (`ToolEffectClassifier.readActions`), so they count as reads for a hop too (KL P2).
- `TurnBackgroundTime` (`Services/Flow`): the Direct turn and the photo turn call `turnBegan` and
  `turnEnded`, the scene's background phase calls `appLeftForeground`, which claims one background
  task through `BackgroundTaskRunning` (it gained `begin(name:onExpiry:)`; the system runner calls
  it on expiry and ends the task in the handler, so the expiry is forgotten, never ended twice). A
  reply whose speech did not complete (or a streamed reply, which reports no outcome) with the app
  away is noted; the next active phase says "Your last answer is in the conversation." once. The
  reply was already saved before it was spoken.

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

**Built 2026-11-07 (headless):**
- `setJobName` calls `onJobIdentityChanged`. `JobThreadTitle.title(reference:name:equipment:)` gives
  "Job <reference> — <name>", or the name alone when it opens with the reference (or "Job
  <reference>") as a whole word; the name stands in for the unit; with no name the rule is
  unchanged. `isGenerated` also counts the name-alone form, so a later rename moves it; a title the
  technician chose is still theirs. The report's job heading uses the same rule.
- The Vault line reads "Vault: X · Vault-only: on|off". The vault's screen in Settings › Field Assist
  (Reference Files → the vault, `VaultFilesEditorView`) has a read-only "Vault-only On/Off" row, "as
  set by the vault".
- `JobTranscriptExport.job(…, sharesThread:)` (the caller asks `sharesThread(_:among:)` over the
  history) keeps only the thread's lines from the job's start to its end, a minute either side. AI
  turns are claimed by session id for every job before any by thread, and by thread only a turn with
  no session id inside the job's window when the thread is shared; a job alone in its thread is as
  before.
- A "figure presented" line ends "· on the phone", "· to the model only" or "· nowhere".

### P7 — What was done is said (finding 14)

- A stock change, reading or task change made in a turn that also asks a question ends its result with
  the one line the reply must carry ("Say: one taken off the van"), like `set_job_reference`'s
  confirmation line. Scope: `van_stock` writes first (owner decision 7).
- The section split from P0 was added to P3 (a contents chunk is not a passage; a named section is
  carried on). Measuring it on the retrieval keys is the KN/KO/KQ rounds'.

**Built 2026-11-07 (headless):** every `van_stock` write that changed the van — load, use, remove,
count, undo, a top-up to standard, a standard set, a part said not to be from the van — ends with one
line, `VanStockService.saying(_:_:)`: "Say: 1 × <part> taken off the van for job <ref>. Put this in
the reply, whatever else the technician asked this turn." Several parts in one call are one line.
A read, a refusal and a write that matched nothing carry none. Scope: van stock only (decision 7).

### Follow-up — the conduit-fill chain's other steps (finding 10)

P3's "mm2" fold settled the chain's area step; its fill and conductor-area steps were the extractor's.

**Built 2026-11-09 (headless; measured on the simulator's import):**
- A row of counts under a heading over the value columns, nothing printed at its left and the last
  count perhaps in words ("1 2 3 Over 3"), heads the columns however few rows follow it
  (`TableExtractor.numberedRowHeads`, shared with the recognised-grid reader). The numbered-heading
  rule wanted three rows under it and a fill table has two, so the counts were read as an unnamed row
  and every column was named by the heading over them alone. A first row that names a row at its left
  still needs three rows under it.
- A heading that wraps onto the next line — set straight under it from the same edge, no wider, and
  reading on (a small letter, or a word broken with a hyphen) — heads exactly the columns its first
  line heads (`continuesHeading`). Its second line alone was narrower and reached only some of them.
  A row-header heading's first line left alone in a value column is still the rows' heading.
- A heading set alone under the columns' own headings, wider than one column and clear of the
  row-header column, heads the rows under it, not the columns it sits over (`headsRows`): a
  conductor-area table's stranded group had become a level of three columns, and its rows printed the
  same sizes twice with nothing to tell the two groups apart. A "(Concluded)" page, or a page carrying
  the table on with no caption, starts the group its own heading names.
- Measured: both editions read again on the simulator (iOS PDFKit, the import's own extractor), every
  stored table's headings and row names compared before and after. The fill table reads five count
  columns and two rows; six conductor-area tables group their rows; in about forty more a wrapped
  heading line joins the line above (mostly a unit line under its quantity: the same words, fewer
  levels, and a few stray fragments gone); in a few, a heading that already reached a neighbour column
  carries its wrapped words there too, or gives a word up. Every chain in the partner's file resolves as before, and the conduit-fill chain runs to its
  answer for five sizes with the file as supplied. The corrected file names the printed headings and
  needs a build later than 657; it stays local and the owner sends it.
- Tests: an invented fill table (counted headings, a wrapped heading, two rows), the same through a
  PDF text layer, a first row that names a row, the wrap rule's cases, a group heading over the rows on
  one page and on a concluded or carried-on page, and a chain over the fill table that starts — and
  is flagged in the list when the counts are not read.

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
