"""Tables, recall statistics, costs and results.json for the KK P0 runs."""
import glob, json, os, re, sys
from collections import Counter, defaultdict
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import scorer as S
from textnorm import normalise
import fixture_spec as F

RATE_IN, RATE_CACHED, RATE_OUT = 0.10, 0.01, 0.50   # US$ per 1M tokens, ModelPricing gpt-6-luna
CLASSES = ["correct", "wrong", "outdated", "hedged", "declined", "unplaced"]
CORR_IDS = {d[0] for fx in F.FIXTURES for d in fx["details"] if d[4]}


def cost(i, c, o):
    return ((i - c) * RATE_IN + c * RATE_CACHED + o * RATE_OUT) / 1e6


def main(show_review=False):
    adjud = S.load_adjudications()
    results = {"runs": [], "probes": []}
    review = []
    for path in sorted(glob.glob(os.path.join(BASE, "runs", "*-*-r*.jsonl"))):
        rows = S.score_file(path, adjud)
        if not rows:
            continue
        fid, arm, run = rows[0]["fixture"], rows[0]["arm"], rows[0]["run"]
        counts = {"old": Counter(), "control": Counter(), "old_corrections": Counter()}
        agg = Counter()
        recall_probes = recall_calls = found_wrong = found = brain_other = memsearch = 0
        for r in rows:
            counts[r["kind"]][r["class"]] += 1
            if r["id"] in CORR_IDS:
                counts["old_corrections"][r["class"]] += 1
            spec = S.SPEC[(fid, r["id"])]
            recalls = [t for t in r["tools"] if t["name"] == "brain" and (t["args"].get("action") or "").lower() in ("recall", "remember", "history")]
            if any(t["name"] == "brain" and t not in recalls for t in r["tools"]):
                brain_other += 1
            if any(t["name"] == "memory_search" for t in r["tools"]):
                memsearch += 1
            hit = any(S.present(spec["expected"], normalise(t.get("result", ""))) for t in recalls)
            if recalls:
                recall_probes += 1
                recall_calls += len(recalls)
            if hit:
                found += 1
                if r["class"] != "correct":
                    found_wrong += 1
            i = sum(c["input"] for c in r["calls"]); ca = sum(c["cached"] for c in r["calls"])
            o = sum(c["output"] for c in r["calls"]); rs = sum(c["reasoning"] for c in r["calls"])
            lat = sum(c["latency"] for c in r["calls"])
            si = sum((t.get("summary_usage") or {}).get("input", 0) for t in recalls)
            sc = sum((t.get("summary_usage") or {}).get("cached", 0) for t in recalls)
            so = sum((t.get("summary_usage") or {}).get("output", 0) for t in recalls)
            slat = sum((t.get("summary_usage") or {}).get("latency", 0) for t in recalls)
            agg.update({"probes": 1, "calls": len(r["calls"]), "input": i, "cached": ca, "output": o,
                        "reasoning": rs, "latency": lat + slat, "recall_in": si, "recall_cached": sc,
                        "recall_out": so, "errors": 1 if r.get("error") else 0})
            agg["cost"] += cost(i, ca, o) + cost(si, sc, so)
            results["probes"].append({k: r.get(k) for k in ("fixture", "arm", "run", "id", "kind", "question", "answer", "class", "why")}
                                     | {"tools": [{"name": t["name"], "args": t["args"], "hits": t.get("hits"),
                                                   "result": t.get("result")} for t in r["tools"]],
                                        "detailInRecallResult": hit, "calls": r["calls"]})
            if r["why"] in ("both, correction marker", "both, or", "both, no marker", "no figure", "other figure",
                            "both, or-without-correction") or r["class"] == "unplaced":
                review.append((f"{run}|{fid}|{arm}|{r['id']}", r["class"], r["why"], r["answer"]))
        n = agg["probes"]
        results["runs"].append({
            "fixture": fid, "arm": arm, "run": run, "probes": n,
            "old": {c: counts["old"][c] for c in CLASSES}, "control": {c: counts["control"][c] for c in CLASSES},
            "oldCorrectionItems": {c: counts["old_corrections"][c] for c in CLASSES},
            "recall": {"probesWithRecall": recall_probes, "recallCalls": recall_calls,
                       "probesWhereRecallResultHeldAnswer": found, "heldAnswerButNotCorrect": found_wrong,
                       "probesWithOtherBrainActions": brain_other, "probesWithMemorySearch": memsearch},
            "perProbe": {"modelCalls": round(agg["calls"] / n, 2), "input": round(agg["input"] / n),
                         "cached": round(agg["cached"] / n), "output": round(agg["output"] / n),
                         "reasoning": round(agg["reasoning"] / n), "latencySec": round(agg["latency"] / n, 2),
                         "recallSummaryInput": round(agg["recall_in"] / n), "recallSummaryOutput": round(agg["recall_out"] / n),
                         "costUSD": round(agg["cost"] / n, 6)},
            "totalCostUSD": round(agg["cost"], 4), "errors": agg["errors"]})
    # timeline costs
    tls = {}
    for path in sorted(glob.glob(os.path.join(BASE, "runs", "timeline*.json"))):
        tl = json.load(open(path))
        calls = []
        for c in tl["calls"]:
            u = c["usage"]
            if u.get("reused"):
                continue
            calls.append({"messages": c["messages"], "estTokens": c["estTokens"], "promptTokens": u.get("prompt_tokens"),
                          "outputTokens": u.get("completion_tokens"),
                          "reasoningTokens": (u.get("completion_tokens_details") or {}).get("reasoning_tokens"),
                          "latency": round(c["latency"], 2), "finalChars": c.get("finalChars"),
                          "restoredLines": c.get("restoredLines"), "rejected": c.get("rejected"),
                          "costUSD": round(cost(u.get("prompt_tokens", 0), 0, u.get("completion_tokens", 0)), 6)})
        tls[os.path.basename(path)] = {"blockEstTokens": tl["rendered"]["estimatedTokens"],
                                       "blockChars": len(tl["rendered"]["text"] or ""),
                                       "entries": tl["rendered"]["rendered"], "dropped": tl["rendered"]["dropped"],
                                       "hasGap": tl["rendered"]["hasGap"], "coveredUpTo": tl["coveredUpTo"],
                                       "omittedAtProbe": tl["omittedAtProbe"], "summaryCalls": calls}
    results["timelines"] = tls
    results["totalCostUSD"] = round(sum(r["totalCostUSD"] for r in results["runs"]), 4)
    json.dump(results, open(os.path.join(BASE, "results.json"), "w"), indent=1)
    # print tables
    print(f"{'fixture':9} {'arm':3} {'run':3} | OLD/40: corr wrong outd hedg decl unpl | CTRL/8: corr wrong outd hedg decl unpl | recall probes/calls held->miss | in cached out lat $/probe")
    for r in sorted(results["runs"], key=lambda x: (x["fixture"], x["arm"], x["run"])):
        o, c, rc, p = r["old"], r["control"], r["recall"], r["perProbe"]
        print(f"{r['fixture']:9} {r['arm']:3} {r['run']:3} | " + " ".join(f"{o[k]:4}" for k in CLASSES) + " | "
              + " ".join(f"{c[k]:4}" for k in CLASSES) + f" | {rc['probesWithRecall']:3}/{rc['recallCalls']:3} {rc['probesWhereRecallResultHeldAnswer']:3}->{rc['heldAnswerButNotCorrect']:2}"
              + f" | {p['input']:6} {p['cached']:6} {p['output']:4} {p['latencySec']:5} {p['costUSD']:.5f}")
    print("total cost", results["totalCostUSD"])
    if show_review:
        print(f"\nREVIEW ({len(review)}):")
        for k, cls, why, ans in review:
            print(f"{k} [{cls} / {why}] {ans[:260]!r}")


if __name__ == "__main__":
    main("--review" in sys.argv)
