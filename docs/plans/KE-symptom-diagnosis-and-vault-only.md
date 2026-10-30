# Plan KE — Symptom Diagnosis and Vault-Only Jobs (no web search in a sealed vault, the known model picks the manuals, citations that open the right page)

**Status:** 🚧 P0 and P1 built 2026-10-31, headless; P2 written, its simulator tests owed; P3 to do. Drafted 2026-10-31 from a
tester's report of 2026-10-30 (three simulated jobs on a refrigerator vault, build 581). Every cause
below was traced on main at build 610:
the citation causes by running the parser on the report's exact lines, the page causes by running
`DocumentChunker` over the vault's own PDFs, the title and unit causes by reading the code only.
**Track:** Field Assist first (the tester's customer pilot is held on this), app-wide underneath:
any vault with several product families, any manual with printed page numbers, any answer that
writes "PDF page".
**Related:** Plan [KD](KD-vault-retest-581.md) (the previous retest; its guards are the pattern
here), Plan [EL](EL-equipment-identity.md) (model scoping), Plan
[JW](JW-vault-test-findings.md) (printed page labels), Plan [IN](IN-verifiable-code-lookup.md)
(`show_source`), Plan [EK](EK-manual-structure-and-figures.md) (citations), Plan
[BI](BI-uncertainty-web-search.md) (the web re-ask), Plan [FO](FO-guided-job-flow-and-job-tab.md)
(job titles, job-change question).

---

## Why

Specific questions held up: naming a service test, a code or a page got a correct, cited answer.
What failed is how a technician actually asks on site: model, symptom, "what should I check next?"
Both simulated calls stalled. Being on 581 explains almost none of it: of the twelve defects below
one is fixed on main, the other eleven reproduce at 610, so a newer build does not clear the retest.

The vault tells the model all of this in `prompt_rules` (no web knowledge, only the documents
assigned to the model, cite the page). Rules in a prompt are not guards. As in Plan KD, what a
sealed vault or a citation must do is enforced by the app.

## Findings and causes

1. **Web search during a vault job** (11:50). `web_search` is on `FieldToolProfile.names`, and
   nothing reads the vault's rule. There is no Vault-only setting. The search query carried the
   model and the question; the answer gave no sign a search had happened.
2. **The known model does not pick the manuals** (11:15, 11:45). `ModelScope.penalty(for:)` only
   penalises a passage that names another model. A generic page of a manual for another family
   names none, so it ranks freely. The vault's model sections say which documents each model has,
   and `VaultModelIndex.Model` drops that text.
3. **A model said aloud is not recorded** (job 103, until 11:53; the suffix in job 101). Equipment
   is set only when the model happens to call `equipment_lookup`, so one job ran with no scope at
   all. `recogniseEquipment` returns early when the heading is unchanged, so a suffix said later
   is never kept, and the Unit card and job heading stay on the base model.
4. **Follow-ups retrieve nothing** (11:49, 11:53). `manualPassagesContext` searches the turn's
   words alone. "The tech sheet is missing, what next?" holds neither model nor symptom, the gate
   refuses it, and the model has no pages to work from.
5. **Cancel ended the diagnosis** (11:15). After four lookups the model asked for an expert on a
   retrieval miss. `declineMessage` says "do not retry, tell the user it was cancelled" for every
   tool, and the reply stopped guiding. The vault's own rule ("state the gap and escalate") points
   the model the same way. A replay of that job's turn on the same model (below, under Evidence)
   asked for an expert in six trials of six when the search came back empty.
6. **A false "no longer in this vault"** (11:12). `sourceBody` reads from the first `Source:` to
   the end of the line. The previous reply had two markers on one line, and the scan note said
   "recognized", which `stripProvenanceNote` does not match. The parser built a 140-character title,
   `resolveCitation` returned `.unknown`, and `show_source` words every miss as a removed manual.
   Label plus refusal sentence is the 236 characters the log recorded.
7. **A tapped citation opens page 1** (11:24; not in the report). `pageRange` reads "page N" but
   not "PDF page N", which is how answers now write it, as the vault's rules and Plan KD P0's
   reply teach. The citation carries no page, `resolveCitation` falls back to page 1, and "PDF page
   63", "printed page 57" and "Step 4" become chips of their own.
8. **Cited pages are wrong when a passage crosses a page break** (three cases in the report).
   Packed chunks hold one page. Replaying the old rule gives the report's three pages exactly.
   With the post-581 majority rule (Plan JY P5a), which migrates by itself, one case is fixed, one
   is unchanged and one moves to the other wrong side. The unchanged case has its majority on the
   right page, but the rule only moves a page within one section and table rows read as headings
   split it: with those rows rejected, the same manual cites the true page. The other case is a
   chunk over three pages whose true page holds only a third of it, so no choice of one page can
   be right, but its sentence does carry the true page. Hence both fixes in P2.
9. **A second page replaces the first** (11:19). Each `manual_figure` call stages one page;
   `show_source` already has a multi-page sheet.
10. **Equipment and status called in a loop** (11:53). `toolRepeatsStopped` worked as built, after
    four calls and no `manual_lookup`. The report does not carry the arguments.
11. **Stale chat titles** (jobs 101, 102). `JobThreadTitle.isGenerated(existing, reference:)` is
    asked about the old title with the *new* reference, so a rename can never pass the guard.

Not an app defect, and for the vault's author: a model section with no suffix list makes the rule
"verify unit-specific applicability" refuse every engineering suffix (finding in job 103); "state
the gap and escalate" invites finding 5; and the service manuals have no symptom section in their
text layer, so no retrieval can say which check is the manufacturer's first step.

## Phases

The plan ships as one PR unless review says otherwise; the phases are the order of work.

### P0 — the seal, and citations that are true (headless)

- **`vault_only` in the manifest.** A new optional key, `"vault_only": true`, read as
  `VaultManifest.vaultOnly: Bool?`. Absent or false means today's behaviour, and a manifest
  without it encodes exactly as it did (the `sites` rule). It is carried by `copy`, by
  `VaultManualRemoval` and by an export. `field-assist-vault-guide.md` documents it, with the
  build it needs: an older build ignores the key, so a sealed vault must state its minimum build.
- **What it seals, while a job on that vault is open.** `VaultOnlyPolicy` (pure) holds one
  decision: which ways out bring outside knowledge into a job. Sealed:
  - `web_search` and `get_news`, in declarations and the prompt's tool list (`declaredNames`,
    `ToolExposureCore`) and refused at dispatch in `featureGateRefusal`, so a remembered name, a
    goal step or a skill pack cannot reach it;
  - MCP tools and the OpenClaw fallback, which do not pass through `FieldToolProfile`;
  - `UncertaintyReask`, which searches without going through the router at all;
  - `lookup_tools`, so a sealed tool cannot be looked up back in.

  A guard test walks `FieldToolProfile.names` and fails on any tool not classified as sealed or
  kept, so a new tool is decided, not inherited. Kept: the job's tools and the phone's own (timer,
  weather, directions), which do not answer a technical question.
- **The trace proves it.** The report's job heading says "Vault-only: on", and any call that
  reached the gate is shown as refused. A job with the seal shows no `web_search` line at all.
- **What the seal does not do, said plainly in the guide:** turns still go to the chosen cloud
  model. It stops outside *sources*, not the model provider.
- **`CitationLineParser`.** A second `Source:` marker starts a new body. "(text recogni[sz]ed"
  is stripped. A sentence end closes a body, so the prose after it is never a title. "PDF page N"
  is a page; "printed page M" and "Step N" attach to the citation before them and never become a
  citation. The parser stays pure and total; every case above is a test with invented titles.
- **A miss says what it is.** `show_source` keeps "no longer in this vault" for `.removed` only.
  `.unknown` and a core file get their own sentence ("that source is not a manual page; use
  manual_lookup"), and a page that failed to display is never reported as a missing document.
- **Titles.** `ConversationThread` keeps the title the app last wrote for the job, and
  `applyJobTitle` compares against that, so a thread the technician renamed stays theirs and a
  corrected job number or unit always moves the app's own. Every path that changes the reference
  or unit retitles (Job tab, `field_session`, intake), and the unit line and job heading show the
  model as stated, suffix included.

**P0 as built (2026-10-31).** Headless; nothing here has been run on the phone yet.

- `VaultOnlyPolicy` keeps an allowlist, so anything not kept is sealed: a tool nobody decided, a custom
  HTTP tool, a skill pack's tools, MCP's qualified names, the gateway's `execute`. The guard test walks
  `FieldToolProfile.names`, the core set and the on-device set. The seal holds with the field profile
  switched off in the Developer panel, and the job records it (`FieldSession.vaultOnly`) for its report.
- The sweep added routes the plan did not list. `qr_context` takes any URL and hands the page to the
  model, and it was on the field profile: sealed. `discover_capabilities` would list sealed tools back:
  sealed. The Apple on-device and MLX paths pick from the registry, not `declarableNames`: filtered
  there. Custom tools are listed by the prompt outside the profile: dropped. The acknowledgement
  examples named `web_search` to every turn: now only when it is offered. A kept name whose native tool
  is off would have fallen through to MCP or the gateway: refused at the same gate.
- `UncertaintyReask.answer` takes `vaultOnly` as a required argument, so a new caller cannot forget it,
  and a test fails if anything but the registry and the re-ask builds a search tool.
- `vault_only` is read strictly: a value that is not a boolean refuses the manifest.
- `Citation.printedPage` is kept only when a citation names no PDF page, and opens through the manual's
  page labels. `CitationLineParser.closingSentence` treats a full stop after a page, step or caption as
  the end unless another place follows; a full stop in a title ends it only after a non-abbreviation
  with a capital next, and not when a page follows the next piece.
- `FieldSessionService.onJobIdentityChanged` is the one hook every number and unit route ends in, so
  the title moves at once rather than at the next turn. `ConversationThread.jobTitle` decides what is
  the app's own, and `isGenerated` is read only for a thread saved before the record existed.
- The title, the report's heading, the session card, the past-job and list rows and the watch show the
  model as stated.

### P1 — the model and the symptom reach the search (headless)

- **The model said aloud counts.** Before retrieval, a turn naming exactly one of the vault's
  models records it through the same path `equipment_lookup` uses, in two cases only: no equipment
  yet, or a fuller spelling of the unit already active (a suffix), which keeps what was stated.
  A *different* model keeps today's path and its job-change question, so a machine mentioned in
  passing moves nothing.
- **Documents by model.** `VaultModelIndex.Model` keeps its section's text and reads the document
  ids in it (a ledger title's first word, or the document number). `ModelScope` gains the assigned
  set: with a model active and at least one document assigned, a passage from an unassigned
  document takes the same `modelPenalty`. It ranks down rather than out, as Plan EL chose, and a
  vault whose sections name no documents is unchanged. The prompt's relevant-pages line names the
  assigned documents, so the model is told which ones apply. Sealed vault or not.
- **A follow-up keeps the job's subject.** `JobSearchContext` (pure) reads the active model and the
  last two technician turns of the job that were questions or descriptions (no bookkeeping, no
  readings). When the turn's own search is refused, or finds nothing in an assigned document, one
  more search adds that context. It can only add passages, and they still clear the evidence gate.
- **A miss is not an escalation.** `escalate_to_expert request` on a turn whose words do not ask
  for a person, and are not a short yes to an offer (`TechnicianRequest`, as Plan KD's guards),
  returns "Not requested: name what the manuals do not cover and offer an expert." The tool
  description drops "cannot safely resolve" as a trigger. `declineMessage` gains a per-tool line
  for this tool: the technician said no, keep helping with what the manuals support.
- **One supported check.** The Field Assist block says, for a diagnostic turn: give one check the
  passages support, say what to observe, use the answer to pick the next; with nothing supported,
  name the specific gap. Never present a check as the manufacturer's first step unless a passage
  says so.
- **The loop.** A repeat, within one turn, of an `equipment_lookup` or `field_session status` whose
  answer cannot have changed is not run; it is answered "you have this; search the manual for the
  symptom or answer." The report does not carry the arguments. The replay made the same pair of
  calls, `field_session` `status` and `equipment_lookup` with `set_equipment` or a free-text query,
  but not the full loop, so the fixture uses those and the existing stop stays as the backstop.

**P1 as built (2026-10-31).** Headless; nothing here has been run on the phone yet.

- The shared recognition is `EquipmentRecognition.reading` and `.change`, moved out of the tool. Both
  the tool and `recordModelSaid` use them, so a turn's words and `equipment_lookup` record the same
  identity. The hook is the top of `FieldSessionService.promptContext`, the one place spoken and typed
  turns both pass before anything is retrieved; the words come through `TechnicianWords`, so a turn with
  none records nothing. `.spoken` already says "from the technician", so `Source` gained no case.
- `match(text:)` keeps its first reading when two tokens name different models, so "the QX100 is fine,
  the QX200 trips" counted as one match. `unitSaid` asks the stricter `namesOneModel`. A denial ("it's
  not the QX100") records nothing, and neither does a paused job, or the same words a second time in a
  job: a prompt rebuilt after a tool round must not bring back a unit the tool has just forgotten.
- A `set_equipment` that repeats a unit the turn already recorded still logs a correction with the
  same words on both sides. That is how a technician's "no, it really is the 48C" is logged, so it
  stays; the job log may show more of these now.
- The ledger has no number field, so a document's number is any word of its title with letters and
  digits, beside the title's first word when that holds a digit. A photographed manual takes no
  document penalty: it is the job's own and in no vault's list. A series member has no spellings to
  score text by, so its scope carries only the union of its series' documents, and its text and team
  learnings score as they did.
- The context goes in a new `Request.jobContext`, searched like a procedure step's title and never a
  boost token: the unit's number is on half the vault's pages, and a verbatim token clears the gate by
  itself. The earlier turns are held in memory on the service, by job and unit, last four, two used.
  Nothing is written for this; a crash loses only the follow-up's context.
- The second search runs for any turn but job bookkeeping, on a job that is not paused, and not when
  the turn names another known model. A page it adds is never staged: the turn's own outcome decides
  what opens. On a turn that already answered it adds at most two, from assigned documents, after what
  the turn found. It reads the words `manualPassagesContext` reads, so `manual_lookup` stays as it was.
- The escalation gate is in the router, ahead of the policy, so no card goes up, and covers
  `escalate_to_expert` `request` and `field_session` `escalate`. It errs towards a request: a wrong
  pass shows the card, a wrong refusal stands between a technician and a person.
- `ToolRepeatGuard` is new, in the tool loop. Status repeats until something else changed; a unit
  lookup is settled once the text only restates the active unit, whatever its arguments; a fault code
  beside the model, another model or a fuller spelling runs. A call refused this way counts towards
  `identicalRepeats` only from the second telling, or the wrap-up would withhold tools from the very
  round the model is told to search. Live sessions have no loop, so this is Direct mode only.
- `oneCheckRule` sits beside the passages, on question, description and reading turns. It is in the
  volatile tail, so the cached prefix does not move.

### P2 — every page where it is (headless, then the real manuals)

- **A chunk knows its pages.** `Chunk` keeps its page breaks (offset and page), stored beside
  `sentenceStarts`, with `locationVersion` 10 and the existing migration: text that chunks as stored
  keeps its rows and vectors, only its places change.
- **The model sees the break.** The passage text in the prompt carries a mark at each break
  ("[page 12 (printed 3-4)]"), so a step at the top of a page is cited at that page rather than at
  the chunk's. The citation line gives the range (`pages 11–12`), which `Citation.throughPage`
  already reads. Stored text and vectors do not change.
- **A table row is not a heading.** `detectHeading` stops taking a row of a table for a section
  title, so the section rule stops holding pages back and citations stop naming a row as their
  section. A numbered line repeating a word was enough in the test; the rule still needs checking
  against the manuals' real headings.
- **Open what is cited.** Command and tap go through one resolution: a range opens the sheet at the
  page holding the cited passage (`PassageLocator`), and the technician can move to the others. If
  the passage is on no page of the range, the sheet says the mark could not be placed.
- **Pages add up.** A second `manual_figure` in a turn joins the first in the sheet through
  `ShowSourceCenter.present`, up to `ShowSourceResolver.maximumPages`, opening on the newest.

**P2 as built (2026-10-31).** Written and checked against the real manuals on the Mac. Not yet compiled for
the app or run on the simulator, and nothing here has been run on the phone.

- `Sentence.page` is only where a sentence starts. A form feed does not end a sentence for the tokenizer,
  so a run of table lines reads straight over the page: over a third of the service manuals' chunks hold a
  form feed inside a sentence. `taggedSentences` reads the pages that open inside one (`turns`), and
  `Chunk.pageBreaks` is built from both. A page with no words of the chunk on it is not a break, and a
  chunk on one page has none. The first break is at offset 0, because `page` may be a later page of the
  chunk (the majority rule). A hard-split piece takes the page it really starts on.
- `page_breaks` is its own column, "0:11,412:12", beside `sentences`. Version 10 moves `textReadVersion`
  too: breaks can only come from the packed sentences, so the text is read again. The heading rule moves
  sections and no word, so the rows, ids and vectors stay and an installed index gets all of it on its
  next migration, without a re-import. A recognised manual imported before its pages were kept is left as
  it is and reads as one page, as is a document in the library outside vaults, which is only stamped.
- Marks are `Passage.markedText`, rendered by `passageLine`, so the prompt, `manual_lookup` and the
  personal library all have them, and `text` stays what the gate, tokens and highlight read. The opening
  page gets a mark too, since the chunk's `page` may not be it. `Passage.printedPage` is only set for a
  photographed manual, so a mark's label comes from the document's own map (`withPrintedLabels`). The
  citation of a vault manual still names no printed page: only the marks do. The marks sit inside the
  256 characters `boundedOutcome` already allows each passage.
- `pageMarkRule` sits beside the passages, in the rules a passage calls for, only when one crosses a page.
- A heading rule over one line cannot tell "3 Fixed Shelf" from "12 Wiring", so there are two. On the line:
  a number followed by `=`, a word printed three times, the line's number printed again, a figure and its
  unit alone or running into a sentence, two digits in a row; and for capitals, a note in brackets, an
  open bracket, a sentence, spaced-out letters, a word printed twice. On the page (`tableLines`, one pass
  before the scan): whole numbers that do not go up, and past five titles in capitals everything but one
  at the head of the page. The second goes beyond table rows: drawing labels were what a section fell back
  on once the rows went, and the mis-cited case then read "§" of a label. A number that is a value ("24
  VAC Supply") takes no part in the count, and neither does a running header or footer.
- Only the lexical path changes. A document with one `## ` line has none of it, which is what the app's
  extractor produces for one of the three service manuals; `ManualStructure`'s own rules are untouched.
- `resolveCitedPage` is the one resolution; `show_source` and a tap both use it, and the personal library
  calls the same `placing`. Only a citation with a range reads pages, at most twelve. A passage is looked
  for on every page of a range, because a model can write a range of its own and an old row knows one page.
  An anchor is read a page at a time (`sentences(onPage:)`), so a chunk over a break is found on each side
  of it, and moving to the other page in the sheet marks that page's part. `marking` now finds a chunk by
  any page it covers: the model is told to cite page 12, and the chunk may say 11. The audit records the
  page that opened. The sheet's existing "couldn't be marked" line is the words for a passage on no page.
- `TurnPageStack` keys on the turn id, else the minute, as `manual_lookup`'s misses do. The second page is
  staged for the model only, so the single-page sheet stays down. A page already up is not logged again
  (`SourcePagesRequest.opening`). `manual_figure` in the personal library still shows one page.
- Follow-ups from P1: both sentences that nudged an escalation now name the gap and offer an expert. A title
  word is a document's id only as its first word holding a digit, or at six characters of which four are
  digits, hyphens aside, so a refrigerant in a title and a section's prose assigns nothing; a designation
  with four digits would still pass. The turn that records a unit by itself now carries the earlier-work
  sentence and the site line, for as long as those words are the turn. The vault guide says what naming a
  document does.

Against the real manuals, aggregates only (the app's chunker over each page's text, majority rule on):

| Measure | Before | After |
|---|---|---|
| The three mis-cited pages, as the model reads them | 1 right | 3 right |
| Lines of the three service manuals read at their own page (2,907 unique lines) | not readable | all |
| Distinct headings across the three | 270 | 41 |
| Chunks crossing a page | not recorded | 133 of 361 |

Of the 229 headings removed, 113 were numbered and none of those was a title. Of the rest, one is the second
line of a page title whose first line stays, and the others are labels on drawings, table headers, and the
lines over phone numbers on the contact pages. Of the 41 left, about ten are still no title (two header rows,
a cell, some wrapped lines). Recall on the acceptance questions was not re-measured: the text and vectors are
unchanged, so only a section's words could move it.

### P3 — the tester's re-run (owed, device)

Run on the phone on the build this ships in:

- The symptom question with the full model and no hints: one applicable check, the next chosen from
  the technician's observation, the supporting page opened on request.
- The missing-tech-sheet question: the trace has no outbound search and no equipment/status loop.
- With the vault's `vault_only` set: a trace with no `web_search` line, and "Vault-only: on".
- The three mis-cited pages, each by answer, command and tap.

## Acceptance

Headless: every finding above has a test on invented manuals and models. Against the real vault,
kept on the machine: the page harness gives the true page for all three cases, and recall on the
vault's acceptance questions does not fall (aggregate numbers only in this plan).

## Evidence

Live replay, 2026-10-31: the report's own transcript as history on the same model at the same
effort, the app's descriptions for the main tools, the vault's rules and core files, stubbed tool
results. The rest of the app's prompt and most of its tools were absent, so these are indications,
with small samples, not a measure.

| Condition | Trials | Tried to escalate | Gave a check |
|---|---|---|---|
| Search returns nothing (today) | 6 | 6 | 0 |
| Real passages, escalation refused (P1) | 3 | 2 | 1 |
| The same, with the vault's rule reworded and its suffix listed | 3 | 0 | 3 |

The app's fixes alone do not reliably pass the re-run; the vault's side is needed too. Even then the
answers still hedged on the suffix, because the job's earlier refusals stay in its history. P3 runs
in a fresh job for that reason, and the checks offered must be read against the page.

## Decisions

- **Per-vault, in the manifest** (owner, 2026-10-31), not an app setting or an organisation policy:
  the seal belongs to the content whose licence or customer needs it, and travels with the vault.
- **Default off.** Absent means today's behaviour.
- **Ranks down, does not drop**, for unassigned documents, so the assistant can still say a figure
  belongs to another model.

## Open

- Whether an organisation profile should also be able to require the seal on any vault.
- Whether `vault_only` should also lift the assigned-document rule from a penalty to a hard filter.
- Vault side, the author's: reword the escalation rule, add suffix lists where coverage is verified,
  add `vault_only`, and decide whether a reviewed symptom-to-check file belongs in the core.
