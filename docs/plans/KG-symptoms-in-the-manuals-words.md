# Plan KG — Symptoms in the Manual's Words (a model number is not evidence, drawings that are prose, a reviewed symptom map)

**Status:** 📝 Drafted 2026-10-31 from the measurement behind Plan KE's document scoping. Nothing built.
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
   extractor.
5. **No tables were extracted.** 0 stored tables and 0 row chunks across 44 documents, though about 53
   chunks in 11 documents hold problem, cause and solution text. None of the 11 is assigned to the two
   models tested. The count comes from a broad text pattern, so it is rough.
6. **No assigned page is keyed by symptom.** Even a perfect search returns a part's test, not which part to
   test first or what to do next. That order has to come from somewhere a person has checked.

## Rejected

- **A search scoped to the assigned documents.** It brought 4 more right pages into the pool, and the
  shared-terms check stopped all 4. Top-four results did not change, for about 0.55 s more per search on the
  Mac. Of the 8 passages it added to the top four, 1 answered the question, and that replaced the same
  table from another family's document.
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

### P2 — a reviewed symptom map (no app change first, then headless)

**First, with no app change.** The vault author adds a core file listing, for each symptom, the checks in
order, each with its part, document and page. A core file reaches the model on every turn. Try this on the
real vault before building anything, because it shows whether the order helps and what format a person can
actually maintain.

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
comes from the 6 of 8 upper bound and needs revisiting after P1.

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

- **Not the scoped search,** by the measurement above.
- **The gate stays strict.** Fix what reaches it, not its bar.
- **The symptom order is the author's, checked by a person,** not inferred by the model from a part's test
  page. A wrong order on site costs a call-out, and the manuals don't state one.

## Open

- Whether a turn answered only from unassigned documents, with a model active, should be refused or
  labelled (finding 3). Plan KE keeps those passages so the assistant can say a figure belongs to another
  model. Labelling is the likely answer.
- Whether a query rewrite by the model belongs here for vaults with no map. `manual_lookup` already takes
  model-written `queries` for other languages. It needs a live test, and it spends a tool round on each
  symptom turn.
- Who writes and reviews the first map, and how it is kept current when a manual is replaced.
- What the tester is told about the re-run in the meantime. Plan KE's P3 should not be expected to pass on
  symptom questions before P2.
