# Timeline recall benchmark (Plan KK P0)

A live benchmark of how much early conversation detail a cloud model still gets right after the
request budget has dropped it. It reproduces the app's API-key request layout in Python from the
Swift source:
- `APIHistoryBudget` with `HistoryHygiene`'s estimates;
- the omission note in the volatile tail;
- the Responses route at Automatic;
- `brain` recall over an FTS5 index with the app's query builder and summary prompt.

Results and their limits are recorded in `docs/plans/KK-conversation-timeline.md`.

## What is here

- `fixtures/field.json`, `fixtures/everyday.json`: two invented conversations of about 150 messages,
  each with 40 planted early details and 8 recent controls. `short-*.json` are the same at realistic
  reply length; at that length the 14k budget barely drops anything.
- `fixture_spec.py`: the wearer turns, planted values, lookalikes, outdated values and question
  wording. `generate_fixtures.py` and `lengthen.py` built the fixtures.
- `scorer.py`, `textnorm.py`, `adjudications.json`: strict scoring (correct, wrong, outdated,
  hedged, declined) and the hand calls the scorer could not make.
- `appmodel.py` and `prompts.py`: the ports of the app's budget, prompt layout and tools.
  `timeline.py`: the P1 timeline core, ported.
- `bench.py`: one fixture, one arm, one run. `summarise.py`: the tables and `results.json`.
- `runs/summary-table.txt`: the P0 numbers; `runs/timeline-*.json`: the timelines arms D and E used.

## Arms

- **A**: today's layout.
- **B**: A plus a sentence telling the model to search with `brain` recall.
- **C**: the whole conversation, with no budget.
- **D**: A plus the timeline as P1 specifies it.
- **E**: D with the newest omitted run summarised too.
- **F**: D plus B's sentence.

## Running

The key never lives in this folder. Put it in a file elsewhere, readable only by you, and delete it
afterwards.

```bash
OPENAI_KEY_FILE=/path/outside/repo/openai.key python3 -I bench.py field B r1
```

`python3 -I summarise.py` rebuilds the tables. Run logs (`runs/*.jsonl`) and `results.json` are
ignored, because they hold every model reply.

Fixtures are invented: no manual figures, no real jobs, no tester content.
