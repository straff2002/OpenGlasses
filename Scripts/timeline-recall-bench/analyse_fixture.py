"""Where the 14k cut lands at the probe, and which planted details are outside the kept window."""
import json, os, re, sys
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import appmodel as AM
import fixture_spec as F
from textnorm import normalise


def analyse(fid, verbose=True):
    spec = next(f for f in F.FIXTURES if f["id"] == fid)
    fx = json.load(open(os.path.join(BASE, "fixtures", fid + ".json")))
    hist = [{"role": m["role"], "content": m["content"]} for m in fx["messages"]]
    probe = hist + [{"role": "user", "content": "What was the reading?"}]
    sel, omitted, est = AM.api_history_select(probe, protected_start=len(probe) - 1, allowance=14_000)
    total = AM.estimated_tokens(hist)
    first_kept_pair = omitted // 2
    out_old = [d[0] for d in spec["details"] if d[1] < first_kept_pair]
    in_old = [d[0] for d in spec["details"] if d[1] >= first_kept_pair]
    out_ctl = [d[0] for d in spec["controls"] if d[1] < first_kept_pair]
    # any planted value restated inside the kept window (other than in its own pair)?
    kept = fx["messages"][omitted:]
    leaks = []
    for d in spec["details"]:
        for m in kept:
            if m["pair"] == d[1]:
                continue
            if any(re.search(p, normalise(m["content"])) for p in d[3]):
                leaks.append((d[0], m["id"]))
    asst = [len(m["content"]) for m in fx["messages"] if m["role"] == "assistant"]
    res = {"fixture": fid, "messages": len(hist), "totalEstTokens": total, "omittedAtProbe": omitted,
           "firstKeptPair": first_kept_pair, "keptEstTokens": est,
           "oldOutside": len(out_old), "oldInside": in_old, "controlsOutside": out_ctl,
           "expectedValueInWindowElsewhere": leaks,
           "assistantChars": {"mean": sum(asst) // len(asst), "min": min(asst), "max": max(asst)}}
    if verbose:
        print(json.dumps(res, indent=1))
    return res


if __name__ == "__main__":
    for fid in sys.argv[1:] or [f["id"] for f in F.FIXTURES]:
        analyse(fid)
