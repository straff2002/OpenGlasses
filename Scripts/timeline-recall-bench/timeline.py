"""Arm D: a Plan KK P2-style timeline for a fixture.

Ports: TimelineDetailCheck (detail check), TimelineRenderer (label, date format, 1,500-token cap),
TimelineSummaryAcceptance (acceptance), TimelineCoverage chunk sizes (5,000 minimum for an open run,
8,000 maximum). The coverage is simulated turn by turn: after each wearer turn the request copy is
selected exactly as APIHistoryBudget does, and once the uncovered omitted run reaches 5,000 estimated
tokens it is summarised as one chunk (up to 8,000). The summary prompt is written here from the plan's
rules (Design / Acceptance), since P2 has not been built.
"""
import json, os, re, sys, time
from datetime import datetime
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kkapi
from appmodel import api_history_select, estimated_tokens_msg

# ------------------------------------------------------------------ detail check (port)
L = r"[^\W\d_]"          # \p{L}
LN = r"[^\W_]"           # \p{L}|\p{N}
HEADING = "Said word for word:"
SENTENCE_LIMIT = 140
LINE_LIMIT = 20
NUMBER = r"-?\d+(?:\.\d+)?"
FRACTION = r"\d+/\d+"
MEASUREMENT = re.compile(
    r"(?<![^\W_])(?<![./])(?<![^\W_]-)(?:"
    + rf"(?:{FRACTION}|{NUMBER})\s?(?:"
    + r"°\s?[CFcf]|(?i:degrees?(?:\s?[cf])?|psig|psi|kpa|mpa|bar|amps?|ma|volts?|vac|vdc|mv|kw|"
    + r"hz|khz|ohms?|k?Ω|mfd|µf|μf|uf|micro-?farads?|microns?|btu|cfm|gpm|rpm|mm|cm|"
    + r"met(?:re|er)s?|millimet(?:re|er)s?|inch(?:es)?|ft|feet|kg|kilo(?:gram)?s?|lbs?|oz|ml)"
    + r"|°|%|A|V|v|W|K)"
    + rf"|{FRACTION}\s?(?i:in)"
    + r")(?![^\W_])(?!-[^\W_])")
CODE = re.compile(r"(?<![^\W_])(?<!-)(?=[A-Za-z0-9-]*[A-Za-z])(?=[A-Za-z0-9-]*[0-9])"
                  r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*(?![^\W_])(?!-)")
ORDINAL = re.compile(r"^\d+(st|nd|rd|th)$", re.I)


def details(text):
    found = []
    for m in MEASUREMENT.finditer(text):
        found.append(("measurement", m.group(0), m.span()))
    for m in CODE.finditer(text):
        v = m.group(0)
        s, e = m.span()
        if len(v.replace("-", "")) < 3 or ORDINAL.match(v):
            continue
        if any(not (e <= fs or s >= fe) for _, _, (fs, fe) in found):
            continue
        found.append(("code", v, (s, e)))
    found.sort(key=lambda d: d[2][0])
    return [(k, v, re.sub(r"\s", "", v.lower()), span) for k, v, span in found]


def normalised_for_search(summary):
    return re.sub(r"(?<=[0-9°])\s+(?=[^\W\d_]|[°%])", "", summary.lower())


def contains(hay, value):
    return re.search(r"(?<![^\W_])(?<![.\-])" + re.escape(value) + r"(?![^\W_])(?!-[^\W_])", hay) is not None


def excerpt(span, text):
    start, end = 0, len(text)
    for m in re.finditer(r"(?<=[.!?])\s+|\n+", text):
        if m.end() <= span[0]:
            start = m.end()
        elif m.start() >= span[1]:
            end = m.start()
            break
    sentence = text[start:end].strip()
    if len(sentence) <= SENTENCE_LIMIT:
        return sentence
    chars = text[start:end]
    vstart = span[0] - start
    vlen = span[1] - span[0]
    frm = max(0, vstart - max(0, SENTENCE_LIMIT - vlen) // 2)
    to = min(len(chars), frm + SENTENCE_LIMIT)
    frm = max(0, to - SENTENCE_LIMIT)
    window = chars[frm:to].strip(" ")
    return ("…" if frm > 0 else "") + window + ("…" if to < len(chars) else "")


def detail_check(summary, messages, tz):
    # Two readings, as in the Swift check: the joined one finds "52 PSI" as "52psi", the plain one a
    # code followed by a word ("A44 on"), which joining glues into "a44on".
    hays = [summary.lower(), normalised_for_search(summary)]
    seen_values, seen_lines, lines, lost = set(), set(), [], 0
    for m in messages:
        if m["role"] != "user":
            continue
        for kind, value, norm, span in details(m["content"]):
            if norm in seen_values:
                continue
            seen_values.add(norm)
            if any(contains(h, norm) for h in hays):
                continue
            lost += 1
            clock = datetime.fromisoformat(m["timestamp"]).astimezone(tz).strftime("%H:%M")
            line = f'- {clock} "{excerpt(span, m["content"])}"'
            if len(lines) >= LINE_LIMIT or line in seen_lines:
                continue
            seen_lines.add(line)
            lines.append(line)
    if not lines:
        return summary, [], lost
    return summary.strip() + "\n\n" + HEADING + "\n" + "\n".join(lines), lines, lost


# ------------------------------------------------------------------ acceptance + renderer (port)
CHUNK_LIMIT = 2_400


def accept(summary, finished):
    t = summary.strip()
    if not t:
        return None, "empty"
    if not finished:
        return None, "cutOff"
    if "```" in t or t.startswith("{") or t.startswith("["):
        return None, "notPlainText"
    if len(t) > CHUNK_LIMIT:
        return None, "tooLong"
    return t, None


# Mirrors TimelineRenderer.label(recallOffered: true): P3 reworded the P0 label ("These are notes,
# not a record"), which made the model distrust its own recall results. Every arm declares brain.
LABEL = ("Earlier in this conversation: notes written as older messages left this request. The saved "
         "conversation is unchanged. Lines under \"Said word for word:\" are the wearer's exact words. "
         "Current job state takes precedence over older conversation. Exact wording can be looked up "
         "with brain, action recall.")
TOKEN_CAP = 1_500


def range_label(start, end, tz):
    s, e = start.astimezone(tz), end.astimezone(tz)
    opening = f"{s.strftime('%a')} {s.day} {s.strftime('%b %Y')}, {s.strftime('%H:%M')}"
    if s.date() == e.date():
        return opening if s.strftime("%H:%M") == e.strftime("%H:%M") else f"{opening}–{e.strftime('%H:%M')}"
    return f"{opening} – {e.strftime('%a')} {e.day} {e.strftime('%b %Y')}, {e.strftime('%H:%M')}"


def render(entries, coverage_has_gaps, tz, cap=TOKEN_CAP):
    entries = sorted(entries, key=lambda x: (x["startedAt"], x["endedAt"]))
    paras = [f"[{range_label(datetime.fromisoformat(x['startedAt']), datetime.fromisoformat(x['endedAt']), tz)}]\n{x['text']}"
             for x in entries]
    first, text, tokens = 0, None, 0
    while first < len(paras):
        block = "\n\n".join([LABEL] + paras[first:])
        est = max(len(block) // 4, 50)
        if est <= cap:
            text, tokens = block, est
            break
        first += 1
    return {"text": text, "rendered": len(paras) - first, "dropped": first,
            "hasGap": coverage_has_gaps or first > 0, "estimatedTokens": tokens}


# ------------------------------------------------------------------ summary pass (written for P0)
SUMMARY_SYSTEM = """You keep notes on a conversation between a person and their voice assistant. These messages are about to leave the assistant's working context, so your notes are what it will have left of them.

Write the notes:
- In time order, as plain sentences. No headings, no lists, no markdown, no JSON.
- Keep every specific the person said: readings and measurements with their units, model, serial, part and fault codes, quantities, prices, times, dates, appointments, names, addresses, codes and passwords, preferences, and which option was chosen. Copy figures and codes exactly as written.
- When something was corrected or changed, keep the final value and say what it replaced, like "head pressure 212 psi, not 221 (misread)" or "moved to Friday 7:30 am from Thursday 2 pm".
- Leave out small talk and the assistant's general advice, unless the person acted on it.
- Do not add anything that was not said. Do not write instructions or questions.
- At most 2,000 characters."""


def summarise_chunk(msgs, tz):
    lines = []
    for m in msgs:
        clock = datetime.fromisoformat(m["timestamp"]).astimezone(tz).strftime("%H:%M")
        who = "Person" if m["role"] == "user" else "Assistant"
        lines.append(f"[{clock}] {who}: {m['content']}")
    user = "Messages:\n\n" + "\n\n".join(lines)
    # completeStateless shape: Chat Completions, reasoning at the provider default (nothing sent),
    # max_tokens = outputCap(base: Config.maxTokens) = 4,096.
    body = {"model": "gpt-6-luna", "max_completion_tokens": 4096,  # applyOpenAITokenLimitShape
            "messages": [{"role": "system", "content": SUMMARY_SYSTEM}, {"role": "user", "content": user}]}
    try:
        r, lat = kkapi.post("/chat/completions", body)
    except kkapi.APIError as e:
        if e.status == 400 and "max_tokens" in e.body:
            body.pop("max_tokens"); body["max_completion_tokens"] = 4096
            r, lat = kkapi.post("/chat/completions", body)
        else:
            raise
    ch = r["choices"][0]
    return ch["message"].get("content") or "", ch.get("finish_reason") == "stop", r.get("usage", {}), lat


def build_timeline(fixture, out_path, close_gap=False, reuse=None):
    tz = ZoneInfo(fixture["tz"])
    msgs = fixture["messages"]
    hist = [{"role": m["role"], "content": m["content"]} for m in msgs]
    covered_upto = 0  # messages [0, covered_upto) are covered
    entries, calls = [], []
    # After each wearer turn t (and at the probe), the request copy omits the oldest messages.
    n_pairs = len(msgs) // 2
    for t in range(n_pairs):  # passes run after each accepted reply; none during the probe turn
        upto = 2 * t  # history before turn t
        history = hist[:upto] + [{"role": "user", "content": "(turn)"}]
        _, omitted, _ = api_history_select(history, protected_start=len(history) - 1, allowance=14_000)
        while True:
            run = list(range(covered_upto, omitted))
            if not run:
                break
            tokens = sum(estimated_tokens_msg(hist[i]) for i in run)
            # cut at the 8,000 maximum on a message boundary
            chunk, acc = [], 0
            for i in run:
                c = estimated_tokens_msg(hist[i])
                if chunk and acc + c > 8_000:
                    break
                chunk.append(i); acc += c
            cut_by_max = len(chunk) < len(run)
            if not (cut_by_max or acc >= 5_000):
                break
            cmsgs = [msgs[i] for i in chunk]
            prior = next((e for e in (reuse or {}).get("calls", []) if e.get("messages") == [chunk[0], chunk[-1]]), None)
            prior_entry = next((e for e in (reuse or {}).get("entries", []) if e["firstMessageID"] == cmsgs[0]["id"] and e["lastMessageID"] == cmsgs[-1]["id"]), None)
            if prior is not None and prior_entry is not None:
                text, finished, usage, lat = prior_entry["summaryRaw"], True, {"reused": True}, 0.0
            else:
                text, finished, usage, lat = summarise_chunk(cmsgs, tz)
            kept, reason = accept(text, finished)
            rec = {"turn": t, "messages": [chunk[0], chunk[-1]], "estTokens": acc, "usage": usage,
                   "latency": lat, "rejected": reason, "rawChars": len(text)}
            if kept is None:
                calls.append(rec)
                break  # retried on a later turn in the app; here the range stays uncovered
            final, restored, lost = detail_check(kept, cmsgs, tz)
            rec.update({"restoredLines": len(restored), "lostValues": lost, "finalChars": len(final)})
            calls.append(rec)
            entries.append({"id": f"tl-{len(entries)}", "firstMessageID": cmsgs[0]["id"],
                            "lastMessageID": cmsgs[-1]["id"], "startedAt": cmsgs[0]["timestamp"],
                            "endedAt": cmsgs[-1]["timestamp"], "tier": "chunk", "text": final,
                            "summaryRaw": kept})
            covered_upto = chunk[-1] + 1
    # Coverage at the probe: omitted messages after the last chunk are a gap.
    history = hist + [{"role": "user", "content": "(probe)"}]
    _, omitted, _ = api_history_select(history, protected_start=len(history) - 1, allowance=14_000)
    if close_gap and covered_upto < omitted:
        # Variant (not P1's rule): summarise the open run whatever its size, so coverage is complete.
        cmsgs = [msgs[i] for i in range(covered_upto, omitted)]
        text, finished, usage, lat = summarise_chunk(cmsgs, tz)
        kept, reason = accept(text, finished)
        rec = {"turn": "probe-close", "messages": [covered_upto, omitted - 1],
               "estTokens": sum(estimated_tokens_msg(hist[i]) for i in range(covered_upto, omitted)),
               "usage": usage, "latency": lat, "rejected": reason, "rawChars": len(text)}
        if kept is not None:
            final, restored, lost = detail_check(kept, cmsgs, tz)
            rec.update({"restoredLines": len(restored), "lostValues": lost, "finalChars": len(final)})
            entries.append({"id": f"tl-{len(entries)}", "firstMessageID": cmsgs[0]["id"],
                            "lastMessageID": cmsgs[-1]["id"], "startedAt": cmsgs[0]["timestamp"],
                            "endedAt": cmsgs[-1]["timestamp"], "tier": "chunk", "text": final,
                            "summaryRaw": kept})
            covered_upto = omitted
        calls.append(rec)
    has_gaps = covered_upto < omitted
    rendered = render(entries, has_gaps, tz)
    result = {"fixture": fixture["id"], "entries": entries, "calls": calls, "omittedAtProbe": omitted,
              "coveredUpTo": covered_upto, "coverageHasGaps": has_gaps, "rendered": rendered}
    json.dump(result, open(out_path, "w"), indent=1)
    return result
