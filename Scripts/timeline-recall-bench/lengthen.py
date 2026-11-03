"""Lengthen assistant replies that fall short of their target, under the same no-new-figures rules,
then (optionally) trim recent replies so the 14k cut lands just before the recent part.
python3 -I lengthen.py <fixture> [--min-ratio 0.8]"""
import json, os, sys, threading
from concurrent.futures import ThreadPoolExecutor
BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import kkapi
import fixture_spec as F
import generate_fixtures as G


def expand(fx, i, draft, target):
    system = (
        "You are editing the assistant's side of an invented test conversation. " + G.MODE[fx["mode"]] + "\n\n"
        f"Rewrite the assistant's reply below so it is about {target} characters long (it is now {len(draft)}). "
        "Keep what it says and add more practical, general explanation, reasons, things to watch for and a "
        "closing offer of help, in the same spoken style: plain paragraphs, no markdown, no lists, no headings.\n"
        "- Do not introduce any number, measurement, time, date, price, code, model, part or serial number, in digits or in words. "
        "You may repeat figures the wearer said in their message, exactly as said.\n"
        "- Do not mention products, places, people's names or decisions other than those in the wearer's message.\n"
        "Return only the rewritten reply.")
    user = f"Wearer's message:\n{fx['pairs'][i][1]}\n\nAssistant's reply to rewrite:\n{draft}"
    body = {"model": "gpt-6-luna", "instructions": system,
            "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": user}]}],
            "store": False, "max_output_tokens": 4000, "reasoning": {"effort": "low"}}
    r, _ = kkapi.post("/responses", body)
    return "".join(c.get("text", "") for o in r["output"] if o.get("type") == "message"
                   for c in o.get("content", [])).strip()


FROM = 0

def main():
    global FROM
    FROM = int(sys.argv[sys.argv.index("--from") + 1]) if "--from" in sys.argv else 0
    fid = sys.argv[1]
    ratio = float(sys.argv[sys.argv.index("--min-ratio") + 1]) if "--min-ratio" in sys.argv else 0.8
    spec = next(f for f in F.FIXTURES if f["id"] == fid)
    path = os.path.join(BASE, "fixtures", fid + ".json")
    fx = json.load(open(path))
    asst = [m for m in fx["messages"] if m["role"] == "assistant"]

    def work(i):
        target = G.target_len(spec, i)
        draft = asst[i]["content"]
        if i < FROM or len(draft) >= ratio * target:
            return i, draft, "kept"
        best = draft
        for attempt in range(4):
            text = expand(spec, i, draft, target)
            if G.violations(spec, i, text):
                continue
            if len(text) > len(best):
                best = text
            if len(best) >= ratio * target:
                break
        return i, best, f"{len(draft)}->{len(best)} (target {target})"

    with ThreadPoolExecutor(max_workers=6) as pool:
        for i, text, note in pool.map(work, range(len(asst))):
            asst[i]["content"] = text
            print(fid, i, note, flush=True)
    json.dump(fx, open(path, "w"), indent=1)


if __name__ == "__main__":
    main()
