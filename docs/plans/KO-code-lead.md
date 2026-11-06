# Plan KO — A Spoken Code Leads Half the Places (the passage that answers is no longer held back by lists that print the code)

**Status:** 🚧 P0 built 2026-11-06 (headless, measured on the Mac runner): the rule ships on. A spoken code
leads at most half the passages asked for. Past those, the question's words decide before the codes a
passage prints. A question whose only codes are numbers keeps today's order. On ten local answer keys:
- hit@4 169 → 180 of 331 on the sentence model and 199 → 213 on the contextual model;
- as sent, 177 → 187 and 211 → 224;
- hit@1 and every refusal unchanged, and no key's hit@4 lower.

P1, the device pass, is owed. Drafted and built 2026-11-06 from Plan [KN](KN-learned-passage-order.md)'s
decision 6, which the owner took the same day: a rule round for the exact-token tier rather than fitted
weights.

## Why

Plan KN P2 fitted three orders over the signals the retriever already holds. It held them out by manual family
and by manual type, on the request and gate the app actually uses. Inside the ranking groups nothing beat the
rules. Across them, the gain was almost all one place in the chain: the exact-token tier.

`VaultRetriever.retrieve` sorts a passage that prints a code the technician said (a model, a part number, a cable
type, a range, an error number) ahead of every passage that doesn't. That tier is right when the passage printing
the code is the answer. It is wrong when the question names the thing it is about and the answer is the general
procedure or rule. Lists, ordering tables, specification rows and other rules that mention the same designation
print the code, and there are usually four or more of them, so they fill every place handed to the model.

Of the 11 answers the fitted order recovered on the sentence model, 10 were lost that way. On the contextual
model it was 8 of 11. Which kind of token it was did not decide it: the gains named real codes, models, cable
types and ranges. What decided it was how many passages printing the code stood ahead of the answer.

## The rule

- **Half the places.** The passages printing a spoken code, outside a named table and a clause, keep the code's
  place only for the first `codeLeadPlaces(limit:)` of them in today's order. That is half the passages asked
  for, rounded up: two of the four a prose manual is handed, three of the six a clause-numbered or table-row vault
  is, and two of a job brief's three.
- **Past those, words first.** Every other passage outside a named table or clause, those printing the code
  too, is ranked by the question's words (BM25F, or the shared-term count) and then by the codes it prints.
  Today's chain ranked codes first and words second there.
- **Numbers alone keep today's order.** A number reaches the boost only when few passages print it: the search
  drops one that overflows its depth. Such a number names its passage the way an error or identifier number does,
  and the passages printing it are the answer. A question whose only codes are numbers is ranked as before.
- **Unchanged:**
  - the table tier, a named table's rows before its page, the clause tier and its offsets;
  - the model penalty;
  - the gate, which still keeps every passage printing a code as evidence;
  - which candidates are gathered.

  An order cannot change a refusal (Plan KN P2), and none changed.
- `RETRIEVAL_EVAL_CODE_LEAD=<places>|off` in the Mac runner measures another lead, or the order before it.

## Rejected

- **Words before codes everywhere** (no lead at all). On the same keys this gained about as much, but lost two
  refrigerator questions on both embedders: questions naming a code whose answering passage prints it.
- **A lead of a fixed two.** Measured as sent, where clause-numbered and table-row vaults hand the model six
  passages, a fixed two lost 2 dangerous-goods regulation questions on both embedders and 2 heat-pump questions
  on the sentence model. Half the places asked for
  keeps two of four and gives three of six. Rounded up, a request for three (a job brief) keeps two, as
  `VaultManualRetrievalTests` pins: a fault code's two passages lead three.
- **Telling tokens apart by kind** (a code against a bare number or unit). The gains were real codes, so a kind
  rule would not have reached them. Kind matters only at the edge kept above: numbers alone.
- **Fitted weights across the groups** (Plan KN decision 6a). They are per embedder, applied only to measured
  types and English, and were not better than this rule on either embedder.

## Measured (2026-11-06)

The Mac runner, the shipped request and gate, and ten answer keys over nine vaults. The keys are the ones from
Plan KN P0, held locally and never committed. Counts only.

| Key | Type | Scored | Sentence hit@4 | Sentence as sent | Contextual hit@4 | Contextual as sent |
|---|---|---|---|---|---|---|
| Furnace pair | service and install | 18 | 16 → 16 | 16 → 16 | 18 → 18 | 18 → 18 |
| Refrigerator, service | service | 35 | 13 → 13 | 13 → 13 | 19 → 19 | 19 → 19 |
| Refrigerator, owner | owner and install | 30 | 10 → 10 | 10 → 10 | 12 → 12 | 12 → 12 |
| Heat pump | service | 27 | 17 → 17 | 19 → 18 | 14 → 15 | 20 → 20 |
| Network switch | install | 23 | 9 → 12 | 9 → 12 | 13 → 16 | 13 → 16 |
| Drive | service | 31 | 14 → 15 | 17 → 18 | 15 → 16 | 17 → 18 |
| Code book | code book | 66 | 35 → 42 | 37 → 44 | 36 → 45 | 39 → 48 |
| Dangerous-goods regulation | standard | 34 | 24 → 24 | 25 → 25 | 27 → 27 | 28 → 28 |
| EU regulation | standard | 33 | 15 → 15 | 15 → 15 | 18 → 18 | 18 → 18 |
| Programming tutorial | software | 34 | 16 → 16 | 16 → 16 | 27 → 27 | 27 → 27 |
| **All** | | **331** | **169 → 180** | **177 → 187** | **199 → 213** | **211 → 224** |

- hit@1 is 120 on the sentence model and 139 on the contextual model, with the rule and without it.
- In-scope refusals and out-of-scope refusals (72 and 57 of 107) are unchanged on every key and both paths.
- Characters sent per question moved by at most 36.
- Simulated on the same candidates, the rule gains hit@4 on 12 questions and loses it on 1 (sentence), and gains
  15 and loses 1 (contextual).

**How far to trust it.** The rule's two choices were made on these keys: half the places, and numbers alone
keeping the tier. A lead of one, two or three places all met Plan KN's bar on the 4-passage request, so the half
is not balanced on one value. The number exemption moved one question per embedder. A key the rule has not
seen re-reads it: the next pilot's manuals, or the phone pass below.

## Phases

### P0 — the rule, its tests and the measurement (headless) — built 2026-11-06

- `VaultRetriever`: today's chain as `rulesOrder`, then the lead. It is computed from today's order, so the
  passages that keep the code's place are the ones today ranks first.
- `VaultRetriever.codeLeadPlaces(limit:)`, with `RETRIEVAL_EVAL_CODE_LEAD` for the runner.
- `CodeLeadTests` (5 tests, an invented cabinet manual):
  - the lead is half the request, rounded up;
  - two code passages lead, and the answer that never prints the code comes third and is handed to the model;
  - a code passage that answers keeps the lead;
  - a question whose only code is a number keeps every passage printing it;
  - past the lead, the codes still decide between passages that share as many words.

### P1 — the phone (device) — owed

- Run Plan KE's re-run questions and Plan KG's symptom questions on a phone, on the phone's extractor and the
  device embedder.
- Add a question naming a model or part whose answer is the general procedure.
- If a key there loses more than one question, the lead goes behind a flag in its own PR.
