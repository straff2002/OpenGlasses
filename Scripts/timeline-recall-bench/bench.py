"""Run the P0 probes: python3 -I bench.py <fixture> <arm> <run-label> [--limit N] [--only id,id]

Arms: A baseline (14k budget + omission note), B (A + one search sentence in the note), C (whole
conversation, no note), D (A + timeline block in the volatile tail; needs runs/timeline-<fixture>.json),
E (D with the open run summarised too, so coverage is complete and the block replaces the note),
F (D + B's search sentence in the note).
Each probe is independent: the fixture history, then one new wearer question.
"""
import json, os, re, sys, time, threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from zoneinfo import ZoneInfo

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import kkapi
import appmodel as AM
import prompts as P
import fixture_spec as F

MODEL = "gpt-6-luna"
MAX_ROUNDS = 5             # LLMService.maxToolCallIterations (full tool exposure)
TOOL_TURN_CAP = 1024       # baseOutputCap with tools; reasoning 'none' does not raise it
REASONING = "none"         # ReasoningPolicy: Responses + tools at Automatic on gpt-6-luna -> family lowest
SILENCE_NUDGE = ("Your last reply had no answer in it, so the user heard nothing. Give them your answer now, "
                 "in the user's language, or say plainly that you cannot answer.")

_indexes = {}


def load_fixture(fid):
    return json.load(open(os.path.join(BASE, "fixtures", fid + ".json")))


def recall_index():
    if "idx" not in _indexes:
        threads = [(f["thread_id"], load_fixture(f["id"])["messages"]) for f in F.FIXTURES]
        _indexes["idx"] = AM.RecallIndex(threads)
    return _indexes["idx"]


def run_recall(question, now, tz, log):
    hits = recall_index().search(question, now, tz, limit=8)
    log["hits"] = [h["id"] for h in hits]
    if not hits:
        return "I couldn't find anything about that in our past conversations."
    system, user = AM.recall_prompt(question, hits)
    body = {"model": MODEL, "max_completion_tokens": 4096,  # applyOpenAITokenLimitShape
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    try:
        r, lat = kkapi.post("/chat/completions", body)
        u = r.get("usage", {})
        log["summary_usage"] = {"input": u.get("prompt_tokens", 0),
                                "cached": (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0),
                                "output": u.get("completion_tokens", 0),
                                "reasoning": (u.get("completion_tokens_details") or {}).get("reasoning_tokens", 0),
                                "latency": round(lat, 2)}
        text = r["choices"][0]["message"].get("content") or ""
        return text.strip() or AM.recall_fallback(hits)
    except kkapi.APIError as e:
        log["summary_error"] = str(e)[:200]
        return AM.recall_fallback(hits)


def stub_tool(name, args, now, tz, log):
    if name == "brain":
        action = (args.get("action") or "query").lower()
        q = (args.get("question") or "").strip()
        if action in ("recall", "remember", "history"):
            if not q:
                return "What should I recall from past conversations?"
            return run_recall(q, now, tz, log)
        if action in ("query", "search", "ask"):
            if not q:
                return "What should I look up in the brain?"
            return (f'The brain has nothing on "{q}" — no matching facts, documents, people, meetings, or '
                    "relationships. Tell me things to remember, ingest documents, or add facts about people and I'll connect them.")
        if action in ("needs", "follow_ups"):
            return "No open follow-ups. Add one with 'save_need' (e.g. 'Bob wants the deck')."
        if action == "status":
            return "Brain: 0 entities, 0 relationships, 0 encounters, 0 open follow-ups. Semantic memory available; 0 documents; 0 people with notes."
        if action == "person":
            return f"I don't have anything on {args.get('person', 'them')} yet."
        return "Unknown action. Use: query, recall, insights, person, link, encounters, save_need, needs, resolve_need, forget, or status."
    if name == "memory_search":
        return f"No relevant memories found for: {args.get('query', '')}"
    if name == "web_search":
        return "No relevant results found."
    if name == "save_note":
        return "Note saved. You have 4 notes total."
    if name == "list_notes":
        return ("You have 3 notes: Van stock (Oct 28): restock nitrogen regulator washers. (Oct 30) Ask about "
                "the new uniform sizes. Gym (Nov 1): renew membership before the end of the month.")
    if name == "calendar":
        a = (args.get("action") or "today").lower()
        if a in ("create", "add"):
            return "Created the event."
        return "No events found." if a != "upcoming" else "No events in the next 7 days."
    if name == "reminder":
        a = (args.get("action") or "create").lower()
        return "No open reminders." if a in ("list", "show") else "Reminder created."
    if name == "get_weather":
        return "Partly cloudy, 17°. High 19°, low 11°. No rain expected in the next hour."
    if name == "get_datetime":
        return f"It's {now.strftime('%-I:%M %p')} on {now.strftime('%A, %B %-d, %Y')} (NZDT)."
    return f"Unknown tool {name}."


def parse_output(resp):
    text, calls = "", []
    for item in resp.get("output", []):
        if item.get("type") == "message":
            # commentary-phase messages are withheld from the reply by the app
            if item.get("phase") == "commentary":
                continue
            text += "".join(c.get("text", "") for c in item.get("content", []) if c.get("type") == "output_text")
        elif item.get("type") == "function_call":
            calls.append(item)
    return text.strip(), calls


def run_probe(fx, arm, item, timeline_block, timeline_has_gap=True):
    tz = ZoneInfo(fx["tz"])
    hh, mm = map(int, fx["probe_time"].split(":"))
    y, mo, d = map(int, fx["date"].split("-"))
    now = datetime(y, mo, d, hh, mm, tzinfo=tz)
    stable, instructions, volatile_base = P.build_layout(fx["mode"], now)
    tools = P.chat_tools()
    cache_key = AM.prompt_cache_key(MODEL, stable, tools)
    history = [{"role": m["role"], "content": m["content"]} for m in fx["messages"]]
    turn_start = len(history)
    history.append({"role": "user", "content": item["question"]})
    allowance = 0 if arm == "C" else 14_000
    log = {"id": item["id"], "question": item["question"], "calls": [], "tools": []}
    reasked = False
    tools_answered = False
    final = None
    for rnd in range(MAX_ROUNDS + 1):
        withhold = rnd == MAX_ROUNDS
        sel, omitted, est = AM.api_history_select(history, protected_start=turn_start, allowance=allowance)
        note = AM.omission_note(omitted, AM.SEARCH_SENTENCE if arm in ("B", "F") else None)
        tail = volatile_base
        if arm in ("D", "E", "F") and timeline_block:
            tail += "\n\n" + timeline_block
        # Arm E: coverage complete -> the block replaces the note (plan, "What the model sees").
        if note and not (arm == "E" and timeline_block and not timeline_has_gap):
            tail += "\n\n" + note
        body = AM.responses_body(MODEL, instructions, sel, None if withhold else tools, tail,
                                 TOOL_TURN_CAP, REASONING, cache_key if not withhold else None)
        t0 = time.time()
        try:
            resp, lat = kkapi.post("/responses", body)
        except kkapi.APIError as e:
            log["error"] = str(e)[:300]
            break
        u = resp.get("usage", {})
        text, calls = parse_output(resp)
        log["calls"].append({"round": rnd, "omitted": omitted, "estHistory": est,
                             "input": u.get("input_tokens", 0),
                             "cached": (u.get("input_tokens_details") or {}).get("cached_tokens", 0),
                             "output": u.get("output_tokens", 0),
                             "reasoning": (u.get("output_tokens_details") or {}).get("reasoning_tokens", 0),
                             "latency": round(lat, 2), "status": resp.get("status"),
                             "toolCalls": [{"name": c.get("name"), "arguments": c.get("arguments")} for c in calls],
                             "text": text})
        if not calls:
            if tools_answered and not text and not reasked:
                reasked = True
                history.append({"role": "user", "content": SILENCE_NUDGE})
                continue
            final = text
            break
        # Keep the raw output items (reasoning first) for replay within the turn.
        raw = [o for o in resp.get("output", []) if o.get("type") in ("reasoning", "message", "function_call")]
        history.append({"role": "assistant", "content": text,
                        "tool_calls": [{"id": c.get("call_id"), "type": "function",
                                        "function": {"name": c.get("name"), "arguments": c.get("arguments") or "{}"}}
                                       for c in calls],
                        "responses_output_items": raw})
        for c in calls:
            try:
                args = json.loads(c.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            tlog = {"name": c.get("name"), "args": args}
            result = stub_tool(c.get("name"), args, now, tz, tlog)
            tlog["result"] = result
            log["tools"].append(tlog)
            wrap = c.get("name") in AM.UNTRUSTED and not (os.environ.get("KK_NO_WRAP") and c.get("name") == "brain")
            content = AM.wrap_untrusted(c.get("name"), result) if wrap else result
            history.append({"role": "tool", "tool_call_id": c.get("call_id"), "content": content})
        tools_answered = True
    log["answer"] = final if final is not None else ""
    # strip Responses items before anything is saved (no ciphertext in logs)
    return log


def main():
    fid, arm, label = sys.argv[1], sys.argv[2], sys.argv[3]
    limit = None
    only = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    spec = next(f for f in F.FIXTURES if f["id"] == fid)
    fx = load_fixture(fid)
    items = [{"id": d[0], "question": d[2]} for d in spec["details"] + spec["controls"]]
    if only:
        items = [i for i in items if i["id"] in only]
    if limit:
        items = items[:limit]
    timeline_block = None
    timeline_has_gap = True
    if arm in ("D", "E", "F"):
        name = f"timeline-full-{fid}.json" if arm == "E" else f"timeline-{fid}.json"
        tl = json.load(open(os.path.join(BASE, "runs", name)))
        timeline_block = tl["rendered"]["text"]
        timeline_has_gap = tl["rendered"]["hasGap"]
    recall_index()
    out_path = os.path.join(BASE, "runs", f"{fid}-{arm}-{label}.jsonl")
    lock = threading.Lock()
    done = 0
    with open(out_path, "w") as out, ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(run_probe, fx, arm, it, timeline_block, timeline_has_gap) for it in items]
        for fut in futures:
            rec = fut.result()
            rec.update({"fixture": fid, "arm": arm, "run": label})
            with lock:
                out.write(json.dumps(rec) + "\n"); out.flush()
                done += 1
    print(f"wrote {done} probes to {out_path}")


if __name__ == "__main__":
    main()
