#!/usr/bin/env python3
"""Plan KN P2: fit, hold out, compare.

Reads the ranking-feature lines the Mac runner writes with
`RETRIEVAL_EVAL_FEATURES_FROM=shipped` (every candidate of the shipped request, with the shipped
gate's verdict), and measures three ways of ordering the candidates against today's rules:

  1. logistic regression on pairs (a passage that holds the answer against one that doesn't);
  2. a small network, one hidden layer of 16, on the same pairs;
  3. weights written from the feature descriptions alone, with no data (`PRIOR` below).

Each fitted arm is measured with one manual family held out at a time, then with one whole manual
type held out at a time, inside the ranking groups (the default) and across them (`--across`).
Every figure printed is a count. The lines hold no text, and neither does anything this prints.

    Scripts/retrieval-eval/fit-order.py [--across] sentence-a.jsonl:service sentence-b.jsonl:code ...

Each file is one answer key's lines, given with its manual type (service, owner, code, software).
The family is the number the runner stamped (`RETRIEVAL_EVAL_FAMILY`); two keys over one vault
share a family and are held out together. Numpy only; deterministic.
"""

import argparse
import json
import math
import sys
from collections import defaultdict

import numpy as np

TYPES = ("service", "owner", "code", "software")

# The features each arm reads, transformed per question so they carry across manuals and
# embedders: places and shares rather than raw scores.
WITHIN = [
    "sim_rank",        # log(1 + the similarity's place among the question's candidates)
    "sim_gap",         # the best similarity less this one's
    "lex_rel",         # the words' value (BM25F or shared count) over the question's best
    "lex_rank",        # log(1 + the words' value's place among the question's candidates)
    "shared_terms",    # shared content terms, capped at 8, over 8
    "shared_frac",     # share of the question's content terms the passage holds
    "heading",         # the section heading holds a question term
    "matched_tokens",  # spoken codes the passage prints, capped at 3
    "matched_models",  # a model number matched
    "model_penalty",   # a row for another model
    "is_row",          # a table row
    "is_diagram",      # a figure or a table page
    "recognised",      # recognised from a scan
    "is_reference",    # a manual page, not a team learning
    "vector_pending",  # no vector yet
    "assigned",        # the unit's assigned documents
    "log_chars",       # log of the length in characters
    "by_meaning", "by_token", "by_clause", "by_table", "by_words",
    "route_count",     # how many routes found it, over 5
]
ACROSS_EXTRA = ["table_match", "clause_match", "token_group"]

# Arm 3, written from the descriptions above before any fit or result was seen (2026-11-06), on
# the transformed (not standardised) features, all of which run 0 to about 1 except log_chars.
PRIOR = {
    "sim_rank": -0.6, "sim_gap": -2.0, "lex_rel": 2.0, "lex_rank": -0.4,
    "shared_terms": 0.5, "shared_frac": 1.5, "heading": 0.8, "matched_tokens": 1.0,
    "matched_models": 0.3, "model_penalty": -2.0, "is_row": 0.2, "is_diagram": -0.3,
    "recognised": -0.1, "is_reference": 0.2, "vector_pending": -0.3, "assigned": 0.5,
    "log_chars": 0.1, "by_meaning": 0.3, "by_token": 0.4, "by_clause": 0.3, "by_table": 0.3,
    "by_words": 0.3, "route_count": 0.2,
    "table_match": 2.0, "clause_match": 2.0, "token_group": 1.0,
}


class Question:
    __slots__ = ("key", "family", "type", "oos", "rank", "label", "evidence", "group", "row_in_table",
                 "clause", "x")


def load(specs, across):
    names = WITHIN + (ACROSS_EXTRA if across else [])
    questions, embedders = [], set()
    for spec in specs:
        path, _, kind = spec.rpartition(":")
        if kind not in TYPES or not path:
            sys.exit(f"give each file as path:type, type one of {', '.join(TYPES)}")
        by_q = defaultdict(list)
        with open(path) as handle:
            for line in handle:
                if line.strip():
                    row = json.loads(line)
                    if "evidence" not in row:
                        sys.exit("these lines carry no gate verdict: export with RETRIEVAL_EVAL_FEATURES_FROM=shipped")
                    embedders.add(row["embedder"])
                    by_q[row["q"]].append(row)
        for q, rows in sorted(by_q.items()):
            rows.sort(key=lambda r: r["rank"])
            if [r["rank"] for r in rows] != list(range(len(rows))):
                sys.exit("a question's ranks are not 0..n-1")
            item = Question()
            item.key = (path, q)
            item.family = rows[0]["family"]
            item.type = kind
            item.oos = rows[0]["oos"]
            item.rank = np.array([r["rank"] for r in rows])
            item.label = np.array([r["label"] or 0 for r in rows])
            item.evidence = np.array([r["evidence"] for r in rows], dtype=bool)
            item.group = np.array([r["group"] for r in rows])
            item.row_in_table = np.array([1 if r["tableMatch"] and r["kind"] == 1 else 0 for r in rows])
            item.clause = np.array([r["clauseMatch"] for r in rows])
            item.x = transform(rows, names)
            questions.append(item)
    if len(embedders) != 1:
        sys.exit("one embedder per run: weights are fitted per embedder")
    return questions, names, embedders.pop()


def place(values, descending=True):
    """Each value's place, 0 the best, equal values sharing a place."""
    order = sorted(set(values), reverse=descending)
    index = {v: i for i, v in enumerate(order)}
    return [index[v] for v in values]


def transform(rows, names):
    lexical = [r["lexical"] for r in rows]
    best = max(lexical) if lexical else 0
    lex_places = place(lexical)
    out = []
    for r, lex_place in zip(rows, lex_places):
        f = {
            "sim_rank": math.log1p(r["similarityRank"]),
            "sim_gap": r["similarityGap"],
            "lex_rel": r["lexical"] / best if best > 0 else 0.0,
            "lex_rank": math.log1p(lex_place),
            "shared_terms": min(r["sharedTerms"], 8) / 8,
            "shared_frac": r["sharedFraction"],
            "heading": float(r["headingHasQuestionTerm"]),
            "matched_tokens": min(r["matchedTokens"], 3),
            "matched_models": float(r["matchedModels"] > 0),
            "model_penalty": float(r["modelPenalty"] > 0),
            "is_row": float(r["kind"] == 1),
            "is_diagram": float(r["kind"] == 2),
            "recognised": float(r["recognisedFromScan"]),
            "is_reference": float(r["isReference"]),
            "vector_pending": float(r["vectorPending"]),
            "assigned": float(r["assignedToUnit"]),
            "log_chars": math.log1p(r["characters"]),
            "by_meaning": float(r["byMeaning"]), "by_token": float(r["byToken"]),
            "by_clause": float(r["byClause"]), "by_table": float(r["byTable"]), "by_words": float(r["byWords"]),
            "route_count": r["routeCount"] / 5,
            "table_match": float(r["tableMatch"]),
            "clause_match": float(r["clauseMatch"] > 0),
            "token_group": float(r["group"] % 2 == 1),
        }
        out.append([f[n] for n in names])
    return np.array(out, dtype=float).reshape(len(out), len(names))


# --- Ordering and scoring -------------------------------------------------------------------

def order(q, scores, across):
    """The candidates' order under `scores`. Inside the groups (the default) the hard tiers stay
    as shipped: the group first, a named table's rows before its page, and the clause tier in
    today's order; the score decides only the rest. Across, the score decides everything."""
    n = len(q.rank)
    if across:
        return sorted(range(n), key=lambda i: (-scores[i], q.rank[i]))
    return sorted(range(n), key=lambda i: (-q.group[i], -q.row_in_table[i],
                                           q.rank[i] if q.clause[i] > 0 else -scores[i], q.rank[i]))


def outcome(q, idx):
    """hit@1, hit@4, refused: the first four the shipped gate keeps, in this order."""
    kept = [i for i in idx if q.evidence[i]][:4]
    if not kept:
        return 0, 0, 1
    return int(q.label[kept[0]] == 1), int(any(q.label[i] == 1 for i in kept)), 0


def measure(questions, score_of, across):
    """Per question: (hit1, hit4, refused). `score_of(q)` gives the candidates' scores, or None
    for today's order."""
    results = {}
    for q in questions:
        scores = score_of(q)
        idx = list(range(len(q.rank))) if scores is None else order(q, scores, across)
        results[q.key] = outcome(q, idx)
    return results


# --- The arms -------------------------------------------------------------------------------

def pairs(questions, across):
    """(positive, negative) candidate pairs a better order would swap, both kept by the gate, in
    the same group unless across; each question weighed equally."""
    xs_pos, xs_neg, weights = [], [], []
    for q in questions:
        if q.oos:
            continue
        found = []
        for i in np.flatnonzero((q.label == 1) & q.evidence):
            for j in np.flatnonzero((q.label == 0) & q.evidence):
                if across or (q.group[i] == q.group[j] and q.clause[i] == 0):
                    found.append((i, j))
        for i, j in found:
            xs_pos.append(q.x[i]); xs_neg.append(q.x[j]); weights.append(1 / len(found))
    if not weights:
        return None
    return np.array(xs_pos), np.array(xs_neg), np.array(weights)


class Scaler:
    def __init__(self, questions):
        x = np.vstack([q.x for q in questions])
        self.mean, self.std = x.mean(axis=0), x.std(axis=0)
        self.std[self.std < 1e-9] = 1.0

    def __call__(self, x):
        return (x - self.mean) / self.std


def adam(params, grad_fn, steps, rate=0.02):
    m = [np.zeros_like(p) for p in params]
    v = [np.zeros_like(p) for p in params]
    for t in range(1, steps + 1):
        grads = grad_fn(params)
        for k, g in enumerate(grads):
            m[k] = 0.9 * m[k] + 0.1 * g
            v[k] = 0.999 * v[k] + 0.001 * g * g
            params[k] = params[k] - rate * (m[k] / (1 - 0.9 ** t)) / (np.sqrt(v[k] / (1 - 0.999 ** t)) + 1e-8)
    return params


def sigmoid(z):
    return 0.5 * (1 + np.tanh(0.5 * z))


def fit_logistic(train, across, l2=0.01, steps=1500):
    scale = Scaler(train)
    data = pairs(train, across)
    if data is None:
        return lambda q: -q.rank.astype(float), None
    pos, neg, w = data
    d = scale(pos) - scale(neg)
    w = w / w.sum()

    def grad(params):
        (beta,) = params
        p = sigmoid(-(d @ beta))
        return [-(d * (w * p)[:, None]).sum(axis=0) + 2 * l2 * beta]

    (beta,) = adam([np.zeros(d.shape[1])], grad, steps)
    return (lambda q: scale(q.x) @ beta), (scale, beta)


def fit_network(train, across, hidden=16, l2=0.01, steps=1500, seed=0):
    scale = Scaler(train)
    data = pairs(train, across)
    if data is None:
        return lambda q: -q.rank.astype(float)
    pos, neg, w = data
    a, b = scale(pos), scale(neg)
    w = w / w.sum()
    rng = np.random.default_rng(seed)
    params = [rng.normal(0, 0.3, (a.shape[1], hidden)), np.zeros(hidden), rng.normal(0, 0.3, hidden)]

    def forward(x, W, c, v):
        h = np.tanh(x @ W + c)
        return h @ v, h

    def grad(params):
        W, c, v = params
        fa, ha = forward(a, W, c, v)
        fb, hb = forward(b, W, c, v)
        g = -w * sigmoid(-(fa - fb))          # d loss / d (fa - fb)
        gv = ha.T @ g - hb.T @ g + 2 * l2 * v
        da = (g[:, None] * v[None, :]) * (1 - ha ** 2)
        db = (g[:, None] * v[None, :]) * (1 - hb ** 2)
        gW = a.T @ da - b.T @ db + 2 * l2 * W
        gc = da.sum(axis=0) - db.sum(axis=0)
        return [gW, gc, gv]

    W, c, v = adam(params, grad, steps)
    return lambda q: forward(scale(q.x), W, c, v)[0]


def prior_score(names):
    beta = np.array([PRIOR[n] for n in names])
    return lambda q: q.x @ beta


# --- Hold-outs and the bar ------------------------------------------------------------------

def held_out(questions, fit, unit):
    """Each question scored by an arm fitted without its `unit` (family or type)."""
    results = {}
    for value in sorted({unit(q) for q in questions}):
        train = [q for q in questions if unit(q) != value]
        test = [q for q in questions if unit(q) == value]
        # With nothing else to fit on, the held-out unit keeps today's order.
        score = fit(train) if train else (lambda q: None)
        results.update(measure(test, score, ACROSS))
    return results


def totals(questions, results, select=lambda q: True):
    chosen = [q for q in questions if select(q)]
    scored = [q for q in chosen if not q.oos]
    oos = [q for q in chosen if q.oos]
    return {
        "scored": len(scored),
        "hit1": sum(results[q.key][0] for q in scored),
        "hit4": sum(results[q.key][1] for q in scored),
        "in_refused": sum(results[q.key][2] for q in scored),
        "oos": len(oos),
        "oos_refused": sum(results[q.key][2] for q in oos),
    }


def bar(questions, base, arm, unit_name, unit):
    """The ship bar: pooled hit@4 up, hit@1 not down, no unit's hit@4 down by more than one,
    out-of-scope refusals not down in any unit."""
    pooled_b, pooled_a = totals(questions, base), totals(questions, arm)
    failures = []
    if pooled_a["hit4"] <= pooled_b["hit4"]:
        failures.append("pooled hit@4 not up")
    if pooled_a["hit1"] < pooled_b["hit1"]:
        failures.append("pooled hit@1 down")
    for value in sorted({unit(q) for q in questions}):
        tb = totals(questions, base, lambda q: unit(q) == value)
        ta = totals(questions, arm, lambda q: unit(q) == value)
        if ta["hit4"] < tb["hit4"] - 1:
            failures.append(f"{unit_name} {value} hit@4 {tb['hit4']} -> {ta['hit4']}")
        if ta["oos_refused"] < tb["oos_refused"]:
            failures.append(f"{unit_name} {value} out-of-scope refused {tb['oos_refused']} -> {ta['oos_refused']}")
    return failures


def row(label, t):
    oos = f"{t['oos_refused']}/{t['oos']}" if t["oos"] else "—"
    return f"  {label:<22} scored {t['scored']:>3}  hit@1 {t['hit1']:>3}  hit@4 {t['hit4']:>3}  oos refused {oos:>7}"


def self_test():
    """Invented candidates: the hard tiers hold, only kept passages count, and the network's
    gradient matches a numerical one. Run with --self-test; no file needed."""
    def make(groups, rows, clauses, labels, evidence, x):
        q = Question()
        q.key, q.family, q.type, q.oos = ("t", 1), 1, "service", False
        q.rank = np.arange(len(groups))
        q.group, q.row_in_table, q.clause = np.array(groups), np.array(rows), np.array(clauses)
        q.label, q.evidence = np.array(labels), np.array(evidence, dtype=bool)
        q.x = np.array(x, dtype=float)
        return q

    # A table group (two rows, then the page), a clause group, and a plain group of three.
    q = make([101, 101, 100, 4, 4, 0, 0, 0], [1, 1, 0, 0, 0, 0, 0, 0], [0, 0, 0, 2, 2, 0, 0, 0],
             [0, 0, 0, 0, 0, 0, 0, 1], [1] * 8, [[0]] * 8)
    flipped = -np.arange(8.0)[::-1]                    # every score reversed
    within = order(q, flipped, across=False)
    assert within[:3] in ([1, 0, 2], [0, 1, 2]) and within[2] == 2, "a table's rows stay before its page"
    assert within[3:5] == [3, 4], "the clause tier keeps today's order"
    assert within[5:] == [7, 6, 5], "the score decides the plain group"
    assert order(q, flipped, across=True)[0] == 7, "across, the score decides everything"
    assert order(q, -q.rank.astype(float), across=False) == list(range(8)), "today's ranks read back as today"
    assert outcome(q, list(range(8))) == (0, 0, 0)
    assert outcome(q, within) == (0, 0, 0), "inside the groups the answer stays behind the table and the clause"
    assert outcome(q, order(q, flipped, across=True)) == (1, 1, 0), "across, it leads"
    # Only passages the gate keeps reach the model: a dropped answer is no hit.
    q.evidence[7] = False
    assert outcome(q, order(q, flipped, across=True)) == (0, 0, 0)
    q.evidence[:] = False
    assert outcome(q, within) == (0, 0, 1), "nothing kept is a refusal"

    # The network's gradient against central differences.
    rng = np.random.default_rng(1)
    a, b, w = rng.normal(size=(5, 3)), rng.normal(size=(5, 3)), np.full(5, 0.2)
    params = [rng.normal(size=(3, 4)), rng.normal(size=4), rng.normal(size=4)]

    def loss(ps):
        W, c, v = ps
        fa = np.tanh(a @ W + c) @ v
        fb = np.tanh(b @ W + c) @ v
        return float((w * np.log1p(np.exp(-(fa - fb)))).sum() + 0.01 * ((W ** 2).sum() + (v ** 2).sum()))

    def analytic(ps):
        W, c, v = ps
        ha, hb = np.tanh(a @ W + c), np.tanh(b @ W + c)
        g = -w * sigmoid(-(ha @ v - hb @ v))
        da = (g[:, None] * v[None, :]) * (1 - ha ** 2)
        db = (g[:, None] * v[None, :]) * (1 - hb ** 2)
        return [a.T @ da - b.T @ db + 0.02 * W, da.sum(0) - db.sum(0), ha.T @ g - hb.T @ g + 0.02 * v]

    for k, g in enumerate(analytic(params)):
        flat = params[k].reshape(-1)
        for i in range(flat.size):
            keep = flat[i]
            flat[i] = keep + 1e-6; up = loss(params)
            flat[i] = keep - 1e-6; down = loss(params)
            flat[i] = keep
            assert abs((up - down) / 2e-6 - g.reshape(-1)[i]) < 1e-5, "the network's gradient"
    print("[FIT] self-test passed")


ACROSS = False


def main():
    global ACROSS
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--across", action="store_true", help="let the score cross the ranking groups")
    parser.add_argument("--seed", type=int, default=0, help="the network's seed")
    parser.add_argument("--weights", action="store_true", help="print the logistic weights fitted on every file")
    parser.add_argument("--self-test", action="store_true", help="check the ordering and the gradient, then stop")
    parser.add_argument("files", nargs="*", help="lines.jsonl:type")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.files:
        parser.error("give at least one lines.jsonl:type")
    ACROSS = args.across
    questions, names, embedder = load(args.files, args.across)
    family = lambda q: q.family
    kind = lambda q: q.type

    base = measure(questions, lambda q: None, ACROSS)
    # Today's order read back through the sort: the scores -rank must give the shipped order exactly.
    for q in questions:
        if order(q, -q.rank.astype(float), ACROSS) != list(range(len(q.rank))) and not ACROSS:
            sys.exit("the shipped order is not the group sort of its own ranks; the hard tiers are misread")

    print(f"[FIT] embedder={embedder} mode={'across' if ACROSS else 'within'} questions={len(questions)} "
          f"families={len({q.family for q in questions})} features={len(names)}")
    print("[FIT] today's order (the shipped request, the shipped gate):")
    print(row("all", totals(questions, base)))
    for t in TYPES:
        if any(q.type == t for q in questions):
            print(row(f"type {t}", totals(questions, base, lambda q, t=t: q.type == t)))
    for f in sorted({q.family for q in questions}):
        print(row(f"family {f}", totals(questions, base, lambda q, f=f: q.family == f)))

    arms = {
        "logistic": lambda train: fit_logistic(train, ACROSS)[0],
        "network": lambda train: fit_network(train, ACROSS, seed=args.seed),
        "prior": lambda train: prior_score(names),
    }
    for arm_name, fit in arms.items():
        for unit_name, unit in (("family", family), ("type", kind)):
            results = held_out(questions, fit, unit)
            failures = bar(questions, base, results, unit_name, unit)
            print(f"[FIT] {arm_name}, one {unit_name} held out at a time:")
            print(row("all", totals(questions, results)))
            for value in sorted({unit(q) for q in questions}):
                tb = totals(questions, base, lambda q, v=value: unit(q) == v)
                ta = totals(questions, results, lambda q, v=value: unit(q) == v)
                print(row(f"{unit_name} {value}", ta) + f"   (today hit@4 {tb['hit4']}, hit@1 {tb['hit1']})")
            scored = [q for q in questions if not q.oos]
            gained = sum(1 for q in scored if results[q.key][1] > base[q.key][1])
            lost = sum(1 for q in scored if results[q.key][1] < base[q.key][1])
            print(f"[FIT]   hit@4 gained on {gained} questions, lost on {lost}")
            print(f"[FIT]   bar: {'MET' if not failures else 'not met — ' + '; '.join(failures)}")

    if args.weights:
        _, (scale, beta) = fit_logistic(questions, ACROSS)
        print("[FIT] logistic weights on every file (standardised features):")
        print(json.dumps({"embedder": embedder, "features": names, "mean": [round(v, 6) for v in scale.mean],
                          "std": [round(v, 6) for v in scale.std], "weights": [round(v, 6) for v in beta]}))


if __name__ == "__main__":
    main()
