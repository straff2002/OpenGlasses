# Plan KG — Symptoms in the Manual's Words (a model number is not evidence, drawings that are prose, a reviewed symptom map)

**Status:** 🚧 P0 and P1's audit built 2026-10-31, headless; P2's guide section written, its app part held for a
core file that proves it; P3 to do. Drafted 2026-10-31 from the measurement behind Plan KE's document scoping.
**The numbers below "Why" were read through the Mac extractor, which tagged far more pages as drawings than the
phone does.** P1 as built has the phone's numbers, which are worse for symptoms: start there.
**Track:** Field Assist first (the tester's customer pilot waits on Plan KE's re-run, and this decides
whether that re-run can pass), app-wide underneath: any vault whose manuals are organised by part.
**Related:** Plan [KE](KE-symptom-diagnosis-and-vault-only.md) (document scoping, the re-run),
Plan [EL](EL-equipment-identity.md) (model scoping), Plan [EK](EK-manual-structure-and-figures.md)
(diagram pages), Plan [JJ](JJ-table-lookup-and-rule-chains.md) (table rows), Plan
[IV](IV-manual-retrieval-rounds.md) (the evidence gate, BM25F).

---

## Why

A technician says what the machine is doing. A service manual says how to test a part. On a
refrigerator vault the right page reached the top four on 3 of 12 symptom questions, with or without
Plan KE's document scoping. A search limited to the unit's assigned manuals did not change that.
The manuals' words are the limit: of the 9 questions still missing, 5 have a specific test page under
the part's name, 3 have only general component tests, and 1 has no page.

Two other faults turned up in the same run, and both matter beyond symptoms. With a model number in the
turn the evidence gate refused none of 8 out-of-scope questions, because the page listing the model
passes on its own. And 62% of the vault's chunks are classed as diagrams, which the embedding and word
searches do not read, though some are plain prose.

## Findings and causes

1. **A model number passes the gate alone.** `RetrievalEvidencePolicy.isEvidence` returns true for any
   passage with a matched token, before the similarity and shared-terms checks. A model number is a code
   token, and the page listing the model prints it, so that page is evidence for any question. Refused,
   of 8 out-of-scope questions: 4 without the number, 0 with it.
2. **A model number counts as a question term.** It goes into `LexicalSupport.QueryTerms`, so it can raise
   the shared terms a passage needs, and only the listing page can supply it. Removing the number took
   the component-word questions from 6 of 8 to 7 of 8.
3. **Half the out-of-scope questions pass even without the number.** All 4 answered from unassigned
   documents only.
4. **Most of the vault is classed as diagrams.** 3,245 of 5,236 chunks. `DocumentStore.searchedKinds` is
   prose and table rows, so those are reached only by token and figure. `ManualStructure.isDiagramPage` says
   a page is a drawing when most of its characters are below body size and it has few sentence ends. A page
   of short instructions set in small type could meet that. The chunks include prose in an assigned owner's
   manual and the service test page behind one missed acceptance question. Not yet read on the phone's
   extractor. **Read now, and this was the Mac's alone: see P1 as built.**
5. **No tables were extracted.** 0 stored tables and 0 row chunks across 44 documents, though about 53
   chunks in 11 documents hold problem, cause and solution text. None of the 11 is assigned to the two
   models tested. The count comes from a broad text pattern, so it is rough.
6. **No assigned page is keyed by symptom.** Even a perfect search returns a part's test, not which part to
   test first or what to do next. That order has to come from somewhere a person has checked.

## Rejected

- **A search scoped to the assigned documents.** It brought 4 more right pages into the pool, and the
  shared-terms check stopped all 4. Top-four results did not change, for about 0.55 s more per search on the
  Mac. Of the 8 passages it added to the top four, 1 answered the question, and that replaced the same
  table from another family's document. **This rejection rests on the Mac extractor and needs a second look:**
  on the phone's text, where the whole vault is searchable, the same route took the right page from 0 of 12 to
  3 of 12 (P1 as built). It is not built here.
- **Waiving the gate for the top scoped hits.** The right page reached the top four on 7 of 12, and all 8
  out-of-scope questions were answered. The gate was doing its job.
- **Lifting the assigned-document rule to a hard filter.** After the search it removes passages and adds
  none. Plan KE's Open item is closed by this.

## Phases

### P0 — a model number is not evidence (headless)

- `VaultRetriever` knows the vault's models (`ModelScope.activeTokens`, `otherTokens`). A token naming a
  model no longer carries a passage past the gate by itself, and is left out of the terms the gate counts.
- It still ranks and proposes passages. A turn with no other content word, a bare model number, keeps
  today's behaviour: the listing page is what it asks for.
- Fault codes, part numbers and clause numbers are untouched: only model tokens change.
- The sentence given when only the listing page was found says so, rather than refusing the model.
- Tests on invented manuals: out-of-scope with the number refuses as it does without; a bare model still
  finds its page; a fault code still passes alone; a real question with a model number loses nothing.

Measure on the real vault, kept local: refused with the number at least equal to refused without; expected
pages not below 3 of 5.

**P0 as built (2026-10-31).** Headless; nothing here has been run on the phone yet.

- `Passage.matchedModels` is the part of `matchedTokens` that only names a model. The gate reads
  `hasEvidenceToken`, and ranking still reads `matchedTokens`, so such a passage ranks and proposes as before.
- The vault's models reach the retriever as `modelNames`, from `VaultModelIndex.namesModel`, in `makeRetriever`
  beside `ModelScope`, because the scope is nil with no unit on the job. A spelling a nameplate splits or a suffix
  the list doesn't hold still counts. Fault codes (`E223`), refrigerants and a part number the core only mentions
  are not model-like or not in a model's heading, so they pass alone as before. A hyphenated spelling reaches the
  tokenizer in pieces, and `ModelMention` treats each piece as the model.
- `gateQuestion` is the turn, nameplate, step and job context with models removed. `question` stays for ranking,
  so BM25F scores what it scored; a test pins the order. The model's letters were a term before ("ABCD" of
  `ABCD123`), and asked for a word only the listing page has.
- Asked for alone, the page is the answer: no content word and no other code in the turn, by the English rule,
  whatever a nameplate beside it holds. So a three-letter word ("QX100 fan") and a short question in another script
  still read as bare. A nameplate with no question keeps its page. With a question, the turn decides.
- A job's context is never a token, so the model only leaves its words. A refused turn then gets the second
  search, which it did not when the listing page answered it.
- A page reached by the model's number alone may never have been compared, so with a word count switched on its
  words decide rather than a similarity of 0. With none switched on it needs the floor as anything else does.
- When only such a page was found the turn is told `modelPageOnlySentence`: the model's page was found and nothing
  on the question. It ends as the KE P1 sentence does and does not mention escalating.
- `manual_lookup` and `equipment_lookup` come through `makeRetriever` and have the rule. The personal library has no
  model list and is unchanged: a number there is a code like any other.
- **What it cost.** A question about the listing itself ("is this model listed in the service manual?") lost its
  page, the one acceptance question it hit: 3 of 5 to 2 of 5 on the Mac's old text, below the plan's bar, and 4 of 5
  to 3 of 5 on the phone's. The turn is still told the manuals list the model, and `models.md` holds the answer. A
  softer rule, one word of credit for printing the model, did not bring it back and changed nothing else, so it is
  not built. No right page and no component-word question was lost.
- Of the passages it took out of the top fours, 22 on the phone's text, that question's page is the one anybody
  wanted. Out-of-scope refusals no longer depend on the number on any index.

### P1 — drawings that are prose, and why no tables (audit first, then headless)

- Audit first. Count diagram chunks per document through the iOS extractor (the simulator, then a phone),
  and read a sample of each document's pages. The Mac's extractor gave these numbers, and it has differed
  from the app's on these manuals before. If the phone's count is far lower, the rest of this phase shrinks.
- From what the audit shows, either correct `isDiagramPage`, or keep the page's figure handling and let a
  chunk with prose in it be searched. The second suits a page holding both a drawing and instructions.
- A change of classification moves chunks between kinds, so it needs a stored version and a migration, as
  Plan KE P2's did. Vectors exist for every row already.
- Find why no table was extracted from these manuals, as one audit question. Fixing it is a phase of its
  own if the answer is large.

Measure: the what-if gave 4 of 5 expected pages and useful first checks on 2 more symptom questions, 5 of
12, with refusals unchanged. It let only a scoped route read diagrams, so the vault-wide result must be
measured again, and labels on real drawings must not crowd the top four.

**P1 as built (2026-10-31).** No app change, no migration. The audit read the vault through the app's extractor
on the simulator, which is not a phone. A phone pass is owed. The full import stopped there with a recognition error
after one document, so the audit called the extractor's text-layer path per document: the one scanned document came
from the Mac, and pages the phone would recognise are as their text layer has them.

- **The 62% was the Mac's.** The app's `isDiagramPage` marks 3 pages of 1,061, all three real wiring diagrams: 13
  chunks of 5,126 (0.25%), against the Mac's 3,245 of 5,236. Font sizes and the rule are the same on both.
  `Scripts/extract-manual-text.swift` also tagged any page holding an embedded object, so a page of prose with a
  photograph left the search. That is fixed: such a page stays in the office report's list, and only the rule tags
  it, with a test. **That script is also the office worker's**, so its text changes the same way. A vault
  extracted on a Mac before this keeps the old tags until it is extracted again.
- **Nothing is hidden on the phone, so correcting `isDiagramPage` has nothing to do.** A sample of 35 pages across
  the five document types: 27 plain prose, 5 drawings with instructions, 2 tables, 1 real drawing, and none was
  misfiled in a way that hurt. About 45 of the pages read as mostly labels and are searched as prose, 12 of them in
  service manuals. None reached the top four of a symptom question.
- **Why no tables:** the table path runs on every PDF and found no caption. `PDFTableReader` is driven by a "Table N"
  caption, 0 of 44 documents print one, and 392 pages use the word. Reading a table with no caption is a reader of
  its own, so it is for its own plan.
- **What the phone's text does to retrieval.** With the whole vault searchable, other families' owner's and install
  guides fill the top four, and the right page falls to 0 of 12. The Mac's tag had hidden many of them by accident,
  which is why its numbers looked better. No labels crowd it: all 46 passages read were prose, 40 of them from
  documents not assigned to the unit. This is now a question of depth again, not only words.

| Arm, top four | Refused of 8, without / with the number | Expected, of 5 | Right page, of 12 | Component words, of 8 |
|---|---|---|---|---|
| Merged, Mac's old text | 4 / 0 | 3 | 3 | 6 |
| P0, Mac's old text | 4 / 4 | 2 | 3 | 6 |
| Merged, phone's text | 2 / 0 | 4 | 0 | 6 |
| **P0 and P1, phone's text** | **2 / 2** | **3** | **0** | **6** |
| P0 and P1, Mac's corrected text | 3 / 3 | 3 | 1 | 6 |
| What-if: P0 and a search scoped to assigned documents, phone's text | 2 / 2 | 3 | 3 | 7 |

The Mac runner with the contextual embedder, all rows vectored, each arm twice and the phone's text re-indexed, with
identical results. One index came back with no vectors, it seems because the model had not loaded, and was thrown
away; Plan KE's odd first run may have been the same. Six of 8 out-of-scope questions are answered on the phone's
text with or without the number, so finding 3 is larger than it looked. The Mac's corrected text and the phone's
still differ by 14 chunks. P0 and P1 reach 0 of 12 alone, so the target of 8 rests on P2, and the scoped search has
to be weighed again first.

### P2 — a reviewed symptom map (no app change first, then headless)

**First, with no app change.** The vault author adds a core file listing, for each symptom, the checks in
order, each with its part, document and page. A core file reaches the model on every turn. Try this on the
real vault before building anything, because it shows whether the order helps and what format a person can
actually maintain.

**As built (2026-10-31).** The vault guide has a section on writing that file, on an invented example, and a line in
the checklist. No `SymptomMap` and no manifest key: those wait for a core file that proves the idea.

**Then the app part,** if the core file proves the idea and the search still misses the pages:

- An optional file named in the manifest, with a strict format: symptom phrases, the families or models
  it applies to, the part's words as the manual prints them, and ordered checks with document and page.
- `SymptomMap`, pure: parses it and refuses it with a clear message when a check names a document the vault
  does not have or a page past its end. A check with no page is not a check.
- On a turn, or job context, that matches a phrase for the active unit, the part's words join the search
  (the gate still judges the passages), and the matching checks go to the model marked as the author's order.
- An unmatched symptom changes nothing, and a vault without the file behaves as today.
- The vault guide documents it. The map is the vault's own content and stays out of the repo; tests use
  invented manuals.

### P3 — the re-run (owed, device)

Plan KE's P3 with this built, in a fresh job, plus: a question the vault cannot answer with the full model
spoken, which must say so. Each check offered is read against its page.

## Acceptance

Headless: every finding has a test on invented manuals and models. Against the real vault, kept on the
machine, aggregates only in this plan: out-of-scope refusals do not depend on the model number, and on the
same 12 symptom questions a page that answers reaches the top four on at least 8, up from 3. That target
comes from the 6 of 8 upper bound and needs revisiting after P1. Revisited: the start on the phone's text is 0, not
3, and 8 is a target for after P2.

## Evidence

Measured 2026-10-31 on the Mac with the contextual embedder, all 5,236 rows vectored, two active models,
each arm on the first index, again on that store, and on a clean re-index, with identical results. Twelve invented
symptom and follow-up questions, 15 acceptance questions and 8 invented out-of-scope questions. The right
pages were picked by reading them, and the extractor is the Mac's, so these are indications, not a score.

| Arm, top four | Symptom: from assigned documents | Acceptance: expected page | Out-of-scope refused |
|---|---|---|---|
| Today | 25 of 47 | 3 of 5 | 4 of 8 |
| With a search scoped to assigned documents | 30 of 47 | 3 of 5 | 4 of 8 |
| The same, margin taken among assigned passages | 30 of 47 | 3 of 5 | 4 of 8 |

The third arm changes nothing: the contextual gate has no margin, so shared terms are what bind.

The best assigned passage was inside a route's top eight on 11 of 12 questions. For the right page itself, the whole-vault
top eight held it on 4 of 12 and the scoped top eight on 8 of 12, so depth did hide pages. Of 171 scoped
candidates, none failed the floor or the margin, 129 failed shared terms, and 42 passed: right pages shared
0 to 2 words against the 2 to 3 needed.

Eight questions asked in the manuals' own component words reached the right page on 6, or 7 without the
model number. Those words were chosen knowing the pages, so this is an upper bound.

## Decisions

- **Not the scoped search,** by the measurement above. **Reopened:** that measurement read the Mac's mis-tagged
  index, and P1's what-if on the phone's text points the other way. The owner decides.
- **The gate stays strict.** Fix what reaches it, not its bar.
- **The symptom order is the author's, checked by a person,** not inferred by the model from a part's test
  page. A wrong order on site costs a call-out, and the manuals don't state one.

## Open

- Whether to build the search scoped to assigned documents after all: 0 to 3 of 12 right pages and 6 to 7 of 8
  component-word questions on the phone's text, with no change to refusals, for about 0.55 s more per search
  on the Mac. Neither the cost on a phone nor the result on a real import has been measured.
- Whether a turn answered only from unassigned documents, with a model active, should be refused or
  labelled (finding 3). Plan KE keeps those passages so the assistant can say a figure belongs to another
  model. Labelling is the likely answer.
- Whether a query rewrite by the model belongs here for vaults with no map. `manual_lookup` already takes
  model-written `queries` for other languages. It needs a live test, and it spends a tool round on each
  symptom turn.
- Who writes and reviews the first map, and how it is kept current when a manual is replaced.
- What the tester is told about the re-run in the meantime. Plan KE's P3 should not be expected to pass on
  symptom questions before P2.
