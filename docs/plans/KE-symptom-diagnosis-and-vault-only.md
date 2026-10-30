# Plan KE — Symptom Diagnosis and Vault-Only Jobs (no web search in a sealed vault, the known model picks the manuals, citations that open the right page)

**Status:** 📝 Drafted 2026-10-31 from a tester's report of 2026-10-30 (three simulated jobs on a
refrigerator vault, build 581). Nothing built. Every cause below was traced on main at build 610:
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
   the model the same way.
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
   is unchanged and one moves to the other wrong side. The rule also only moves a page within one
   section, and a table row read as a heading likely splits that section.
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
  symptom or answer." A fixture built from the report's sequence proves the arguments first, since
  the report does not carry them. The existing stop stays as the backstop.

### P2 — every page where it is (headless, then the real manuals)

- **A chunk knows its pages.** `Chunk` keeps its page breaks (offset and page), stored beside
  `sentenceStarts`, with `locationVersion` 10 and the existing migration: text that chunks as stored
  keeps its rows and vectors, only its places change.
- **The model sees the break.** The passage text in the prompt carries a mark at each break
  ("[page 12 (printed 3-4)]"), so a step at the top of a page is cited at that page rather than at
  the chunk's. The citation line gives the range (`pages 11–12`), which `Citation.throughPage`
  already reads. Stored text and vectors do not change.
- **A table row is not a heading.** `structuredHeading` stops taking a row of a table for a section
  title, so the section rule stops holding pages back and citations stop naming a row as their section.
- **Open what is cited.** Command and tap go through one resolution: a range opens the sheet at the
  page holding the cited passage (`PassageLocator`), and the technician can move to the others. If
  the passage is on no page of the range, the sheet says the mark could not be placed.
- **Pages add up.** A second `manual_figure` in a turn joins the first in the sheet through
  `ShowSourceCenter.present`, up to `ShowSourceResolver.maximumPages`, opening on the newest.

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
