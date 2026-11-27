# Plan NI — Field Assist Tool Calls in the Support Report (what a rule chain, a table lookup and a manual lookup were asked, and what they answered)

**Status:** 🚧 P0 built 2026-11-27 (headless). D1 taken by Greig 2026-11-27: option 2, as recommended
(arguments and the tool's own words, never the book's). D2–D5 as written. P1 device look owed.
**Track:** Field Assist support and testing.
**Builds on:** the support trace (`TurnTrace`, 2026-09-26) and its web-search evidence
(`TurnTimeline.SearchEvidence`, Plan KE / KZ §9); Plan LU §3 (a private conversation's trace keeps
no text); Plan JJ (rule chains and `table_lookup`, and the chain read-back filed on the job); Plan
KD P0 (the chain start gate).

---

## Trigger

A tester ran a sizing question in a code-book vault on build 770. It failed: the start gate refused
every `rule_chain` start (fixed in PR 1257). The tester couldn't tell from anything the app gave
them. Their support report said `rule_chain (completed)` on each turn, the Activity trail said
"Started a rule chain", and the 217-character result the model was given appeared nowhere. They
asked how to see what each tool was asked, what it looked up and what it answered, so they could
review a turn.

A chain that *runs* already files its whole read-back on the job ("Rule chains worked on this job",
with the table, row, column and page each lookup used). This plan covers the tool calls that never
got that far: a refused start, an answer the chain turned down, a table lookup that asked which row,
and a manual search that found nothing it would stand behind.

## What exists (verified 2026-11-27 on `origin/main` 11a4527ea)

- `LLMService.makeToolDispatcher()` runs every model tool call and then calls
  `TurnRecorder.noteToolResult(name:outcome:query:result:turnID:)`. Only `web_search` keeps
  anything beyond its name: a `SearchEvidence` with the query and returned text. Both are masked by
  `DiagnosticsRedactor` *before* they are cut (so a cut can't leave half a secret), capped at
  1,024 / 8,192 characters a call and 24,576 characters of returned text a turn, and each is
  marked when it was cut.
- `outcome` is the dispatcher's class of the call: `completed`, `refused`, `failed`,
  `outcome unknown`. A Field Assist tool that refuses does so in words and returns normally, so the
  chain gate's refusal is `completed`. That is exactly what the tester saw.
- `TurnTrace.withoutText()` drops the search evidence from a private conversation's trace (Plan LU
  §3). `TurnTraceStore` keeps traces on the phone for 14 days, bounded at 2,000 traces and 8 MB.
- `JobTranscriptExport.render(_ trace:stamp:)` prints `tools: name (outcome), …` and then, for each
  call with search evidence, `web search (tool call N, outcome):` with the query and returned text,
  each marked `[truncated]` when it was cut.
- **Turn records only appear when "troubleshooting details" is on.** The exporter passes no traces
  without it (`JobTranscriptExporter`, `options.troubleshooting ? … : []`), and the masking pass
  runs over the whole file when it's on. A support report is that layer, so anything added to a
  trace is behind the setting already.
- Argument names in these three tools don't collide with the masking pass, which blanks whatever
  follows `key:`, `token:`, `secret:`, `password:`, `credential:` and a few others. None of
  `action`, `chain`, `step`, `value`, `table`, `row`, `column`, `document`, `query`, `queries` or
  `use_camera` is on that list.

What the three tools return:

| Tool | Arguments | Returned text |
|---|---|---|
| `rule_chain` | `action`, `chain`, `step`, `value` | The app's own words and the organisation's chain: which chain runs, the step it's waiting for, a refusal and why, the read-back. A read-back carries each cell a lookup used, which the job's read-back already files. |
| `table_lookup` | `table`, `row`, `column`, `document` | A refusal, a question back ("more than one row matches…") or a not-found, each listing headings. When it finds the cell: the row's **cells**, the table's **notes** (the book's prose), the page and a `Source:` line. |
| `manual_lookup` | `query`, `document`, `use_camera`, `queries` | A refusal or a miss with its retry guidance. When it finds something: up to 12,000 characters of **passages**, the book's own words, with their citations. |

## Decision for Greig (taken 2026-11-27: option 2)

**D1. What does the report show of a `table_lookup` or `manual_lookup` that found something in the
book?** Testers paste reports into outside AI tools, and these results carry cells, notes and
passages from licensed code books.

1. **Everything.** Arguments and returned text in full, cut at 8,192 characters a call like a web
   search. The most useful to a reviewer: they can see the exact cell or passage the model was
   handed. It also means a day's report can carry many kilobytes of a licensed book's text, and the
   tester then pastes it into a third party's AI.
2. **Arguments, and the tool's own words, but not the book's.** Arguments always. `rule_chain`'s
   returned text in full. A lookup that gave nothing from the book (a refusal, a question back, a
   not-found, an unreadable table) is shown in full, because those are the app's words. A lookup that
   did give something from the book shows what it found and where (the table, row, column and page,
   or each passage's manual and page) and how many characters of book text were left out, but not
   the cells, notes or passages. The value the model gave is still in the report, because the reply
   that said it is in the transcript, and a chain's read-back is on the job.
3. **Put it behind the troubleshooting-details setting.** This adds nothing: turn records already
   appear only with that setting on, and a support report always has it on. In practice it is
   option 1.

**Recommended: 2.** It answers the question the tester asked: why the chain was refused, which
table and row the model asked for, and what the tool said back. The tool's refusals and questions
were exactly what was missing in the build-770 case. It keeps the book's text out of a file that is
made to be pasted somewhere else. What's lost is checking a cell the model was handed against the
cell it read out. The fix for that is to open the page, and the report names it. It **fails closed**:
a lookup that doesn't say what it returned (the personal-manuals path, or anything new) is shown
by size only.

D1 is the only decision. These are taken as written unless Greig says otherwise:

- **D2.** Caps: the same as a web search. Each argument is cut at 1,024 characters, the returned
  text at 8,192 characters a call, and the returned text a turn keeps (searches and these tools
  together) at 24,576. Each is marked when it was cut. The on-disk bound (8 MB) is unchanged.
- **D3.** A private conversation keeps none of it, just as it keeps no search (`withoutText()`).
- **D4.** Everything is masked twice, like a search: as the trace is recorded (before it's cut) and
  again across the whole file at export.
- **D5.** Only these three tools. Every other tool stays name-and-outcome. A new tool joins by being
  named in the policy, never by default.

## Design

- **`TurnTimeline.ToolEvidence`** (pure, `Codable`), an optional field `detail` on `ToolNote`
  beside `search`, so older traces still decode. It holds `arguments: [Argument]` (name, value,
  truncated), `returned: String`, `returnedTruncated: Bool`, and `withheldCharacters: Int?`, which
  is set when book text was left out. The masking and the cuts happen in its initialiser, the same
  way `SearchEvidence` does them.
- **`ToolReportPolicy`** (pure): which tools record evidence (`rule_chain`, `table_lookup`,
  `manual_lookup`), which arguments each one keeps (by name, in schema order; an array such as
  `queries` is flattened to `language: query` lines), and, for the two lookups, whether the
  returned text may be shown. Under option 2, a lookup's returned text is shown only when the tool
  itself supplied a report version for this call. Otherwise only its size is.
- **`ToolReportText`**, a task-local slot like `ActionCompletionReport`. The dispatcher opens a
  collector around the native call, and a tool may `record(_:)` the version of its result that the
  report should show. `TableLookupTool` and `ManualLookupTool` record one on every Field Assist
  path: the full text when it's their own words, and `TableLookup.reportText(_:)` /
  `VaultRetriever.reportText(_:)` when the book answered (headings, rows, columns, pages and
  citations, with cells, notes and passages replaced by a count). The personal-manuals path records
  nothing, so it falls back to its size.
- **`TurnRecorder.noteToolResult`** gains `arguments: [String: Any]` and `reportText: String?`, and
  builds a `ToolEvidence` for the policy's tools. The returned-text budget for a turn is shared with
  searches.
- **`TurnTrace.withoutText()`** drops `detail` as well as `search`.
- **`JobTranscriptExport.render(_ trace:stamp:)`** prints, after the tools line:

  ```
  rule_chain (tool call 2, completed):
    arguments: action: start · chain: Size a feeder
    returned text:
      Not started: …
  table_lookup (tool call 3, completed):
    arguments: table: Table 99 · row: QXRT · column: Rating group 2
    returned text (cells, notes and passages from the book left out: 214 characters):
      Table 99, Example code book:
      row QXRT (page 12) — column Rating group 2: [left out]
  ```

  The troubleshooting preambles say that Field Assist lookups are now recorded alongside web
  searches, and what is left out.

## Phases

- **P0 — the core, the capture and the export (one PR, headless).** `ToolEvidence`,
  `ToolReportPolicy`, `ToolReportText`, the recorder and dispatcher change, the two lookups' report
  text, `withoutText()`, the export block and the preambles. Tests below.
- **P1 — a device look.** Export a support report from a code-book vault on a phone after a refused
  start, a lookup that asks which row, and a lookup that finds a cell. Check that the report reads
  as the design shows and that no cell, note or passage text appears.

The report text is not localized (the export is plain English for support), so no catalog sync is
owed.

## Tests

On an invented vault only: `Table 99`, rows like `QXRT`, made-up figures and generic wording. No
real table, rule or book text, and no tester's words.

- A refused `rule_chain` start: the report shows its arguments (`action: start`, the chain's name)
  and the refusal text.
- A `table_lookup` that found its cell: the report shows the arguments and where it was found, with
  the cell's text left out and the count of what was left out.
- A `table_lookup` that asked which row: its question is shown in full.
- A `manual_lookup` that found passages: citations and a count, no passage text.
- A lookup that recorded no report text: size only.
- Masking: a secret in an argument or a result is masked before the cut.
- Caps and `[truncated]` marks; the turn budget shared with a search.
- A private conversation's trace keeps no `detail`.
- Old traces (no `detail`) still decode.
- Other tools still print name and outcome only.

## Not in scope

- The Activity trail's wording for a refused start ("Started a rule chain") is fixed separately, in PR 1257.
- Live voice modes don't record turns yet (`untracedNote`). Nothing changes there.
