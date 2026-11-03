"""Fill in the assistant side of each fixture with gpt-6-luna under a no-new-figures constraint, then
save fixtures/<id>.json. Re-runnable: replies already saved are kept unless --regen is given."""
import json, os, re, sys, threading
from datetime import datetime
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kkapi
import fixture_spec as F
from textnorm import normalise

BASE = os.path.dirname(os.path.abspath(__file__))
FIXDIR = os.path.join(BASE, "fixtures")
RECENT_START = 47  # pairs from here on are the 'recent' part (controls + fillers)

MODE = {
    "field": "The wearer is a refrigeration and HVAC service technician working a long service job at a small grocery store, talking to the assistant hands-free through smart glasses. The assistant is a capable, practical trade assistant.",
    "everyday": "The wearer is going about a busy ordinary day of errands, family plans and a coming trip, talking to the assistant hands-free through smart glasses. The assistant is friendly and practical.",
}


def target_len(fx, i):
    user = fx["pairs"][i][1]
    question = "?" in user or user.lower().startswith(("help", "walk me", "make a", "remind"))
    if i >= RECENT_START:
        return 2600 if question else 1500
    return 1700 if question else 1100


def distinctive_patterns(fx, exclude_index):
    pats = []
    for d in fx["details"] + fx["controls"]:
        if d[1] == exclude_index:
            continue
        for p in d[3] + d[4] + d[5]:
            m = re.fullmatch(r"\(\?<!\[\\d\.\]\)(.+?)\(\?!\[\\d\]\|\\\.\\d\)", p)
            if m and len(m.group(1).replace("\\", "")) <= 2:
                continue  # a bare one- or two-digit number is too generic to police
            if p in (r"\btext", r"\btrain", r"\bmiddle|\bcent(er|re)", r"\bmotors?\b", r"thursday", r"friday",
                     r"carriage c\b|\bc\b", r"thursday|(?<![\d])12(th)?\b", r"tuesday|10[:. ]30") or "ring|call" in p \
                    or "driv" in p or "left|right" in p or "whole|entire" in p or "(?<![\\d])" in p and len(p) < 32:
                continue  # common words: policed only by the figure check
            pats.append((d[0], p))
    return pats


def violations(fx, i, reply):
    user_norm = normalise(fx["pairs"][i][1])
    user_tokens = set(re.findall(r"[a-z0-9.:/-]*\d[a-z0-9.:/-]*", user_norm))
    user_tokens |= {t.strip(".:-/") for t in user_tokens}
    reply_norm = normalise(reply)
    bad = []
    # Literal figures the wearer did not just say.
    for tok in re.findall(r"[A-Za-z0-9.:/-]*\d[A-Za-z0-9.:/-]*", reply.lower().replace(",", "")):
        t = tok.strip(".:-/")
        if t and t not in user_tokens and not any(t in u for u in user_tokens):
            bad.append("figure:" + t)
    for did, p in distinctive_patterns(fx, i):
        if re.search(p, reply_norm) and not re.search(p, user_norm):
            bad.append("detail:" + did)
    if re.search(r"(^|\n)\s*([-*•]|\d+\.)\s", reply) or "**" in reply or "#" in reply:
        bad.append("markdown")
    return bad


def gen_reply(fx, i, prior, extra=""):
    n = target_len(fx, i)
    system = (
        "You write the assistant's side of an invented test conversation. " + MODE[fx["mode"]] + "\n\n"
        "Write only the assistant's reply to the wearer's latest message.\n"
        f"- Length: about {n} characters. Spoken style: plain sentences and paragraphs, no markdown, no lists, no headings, no emoji.\n"
        "- Do not introduce any number, measurement, time, date, price, code, model, part or serial number of your own, in digits or in words. "
        "You may repeat figures the wearer said in their latest message, exactly as they said them. If they corrected themselves, use only the corrected figure.\n"
        "- Do not mention specific figures, codes, product names, places, choices or decisions from earlier in the conversation; talk about the latest message.\n"
        "- Do not invent names of people, businesses or places. Ask at most one question.\n"
        "- Give general practical advice in words where useful, without figures." + extra
    )
    msgs = []
    for u, a in prior[-2:]:
        msgs.append({"type": "message", "role": "user", "content": [{"type": "input_text", "text": u}]})
        msgs.append({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": a}]})
    msgs.append({"type": "message", "role": "user", "content": [{"type": "input_text", "text": fx["pairs"][i][1]}]})
    body = {"model": "gpt-6-luna", "instructions": system, "input": msgs, "store": False,
            "max_output_tokens": 3000, "reasoning": {"effort": "low"}}
    r, _ = kkapi.post("/responses", body)
    text = "".join(c.get("text", "") for o in r["output"] if o.get("type") == "message" for c in o.get("content", []))
    return text.strip(), r.get("usage", {})


def build(fx, regen=False):
    path = os.path.join(FIXDIR, fx["id"] + ".json")
    old = json.load(open(path)) if os.path.exists(path) else None
    tz = ZoneInfo(fx["tz"])
    replies = [] if (regen or not old) else [m["content"] for m in old["messages"] if m["role"] == "assistant"]
    usage_in = usage_out = 0
    for i, (clock, user) in enumerate(fx["pairs"]):
        if i < len(replies) and replies[i] and not violations(fx, i, replies[i]):
            continue
        prior = [(fx["pairs"][j][1], replies[j]) for j in range(i)]
        best, best_bad = None, None
        extra = ""
        for attempt in range(5):
            text, u = gen_reply(fx, i, prior, extra)
            usage_in += u.get("input_tokens", 0); usage_out += u.get("output_tokens", 0)
            bad = violations(fx, i, text)
            if not bad:
                best, best_bad = text, []
                break
            if best is None or len(bad) < len(best_bad):
                best, best_bad = text, bad
            extra = "\n- Your previous draft broke a rule (" + ", ".join(sorted(set(bad)))[:200] + "). Use no figures except the wearer's own from their latest message."
        if best_bad:
            print(f"[{fx['id']}] pair {i}: kept with violations {best_bad}", flush=True)
        if i < len(replies):
            replies[i] = best
        else:
            replies.append(best)
        print(f"[{fx['id']}] {i} {len(best)} chars", flush=True)
    messages = []
    for i, ((clock, user), reply) in enumerate(zip(fx["pairs"], replies)):
        hh, mm = map(int, clock.split(":"))
        y, mo, d = map(int, fx["date"].split("-"))
        t_user = datetime(y, mo, d, hh, mm, 0, tzinfo=tz)
        t_asst = datetime(y, mo, d, hh, mm, 20, tzinfo=tz)
        messages.append({"id": f"{fx['id']}-u{i:03d}", "role": "user", "content": user, "timestamp": t_user.isoformat(), "pair": i})
        messages.append({"id": f"{fx['id']}-a{i:03d}", "role": "assistant", "content": reply, "timestamp": t_asst.isoformat(), "pair": i})
    out = {"id": fx["id"], "thread_id": fx["thread_id"], "tz": fx["tz"], "date": fx["date"],
           "probe_time": fx["probe_time"], "mode": fx["mode"], "messages": messages}
    json.dump(out, open(path, "w"), indent=1)
    print(f"[{fx['id']}] saved; generation tokens in={usage_in} out={usage_out}", flush=True)


if __name__ == "__main__":
    regen = "--regen" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    threads = [threading.Thread(target=build, args=(fx, regen)) for fx in F.FIXTURES if not only or fx["id"] in only]
    for t in threads: t.start()
    for t in threads: t.join()
