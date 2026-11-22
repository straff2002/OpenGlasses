#!/usr/bin/env python3
"""Generate the local-model tool corpus from the Lennox SLP99 example vault (Plan MQ P0).

    python3 -I Scripts/local-tool-eval/generate-corpus.py           # write the corpus
    python3 -I Scripts/local-tool-eval/generate-corpus.py --check   # exit 1 if it is out of date

The corpus is mostly Field Assist job turns, because the point of running Field Assist on a
downloaded model is cost: every service value, diagnostic code, part, model and size code, safety
rule and procedure step in `examples/vaults/lennox-slp99` that can carry a question becomes cases,
and most answered manual questions get a near-miss twin that must be declined. A short everyday set
(small talk, job-adjacent chatter, the time, a timer) and the protocol cases (clean output,
cancellation) are written here by hand.

Deterministic: the same vault and this script give byte-identical output. The header records the
SHA-256 of every input (this script included) and of the case lines, and
`LocalToolEvalCorpusTests` recomputes both, so a vault edit without a regeneration fails CI.

Only stdlib; reads files, writes one file. No turn, passage or answer is printed: the summary is
counts.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VAULT_REL = "examples/vaults/lennox-slp99"
VAULT = ROOT / VAULT_REL
OUT = ROOT / "Scripts/local-tool-eval/corpus/local-tool-corpus.v2.jsonl"
VERSION = 2
VAULT_TAG = "lennox-slp99"

INPUTS = [
    "examples/vaults/lennox-slp99/service_values.md",
    "examples/vaults/lennox-slp99/error_codes.md",
    "examples/vaults/lennox-slp99/parts.md",
    "examples/vaults/lennox-slp99/models.md",
    "examples/vaults/lennox-slp99/safety.md",
    "examples/vaults/lennox-slp99/procedures/slp99_no_ignition.json",
    "examples/vaults/lennox-slp99/procedures/slp99_pressure_switch_lockout.json",
    "examples/vaults/lennox-slp99/procedures/slp99_unit_size_code.json",
    "examples/vaults/lennox-slp99/eval/calibration.jsonl",
    "Scripts/local-tool-eval/generate-corpus.py",
]

FIELD_TOOLS = ["field_session", "reading", "evidence", "equipment_lookup", "domain_calc",
               "procedure_runner", "table_lookup", "show_source"]

# ---------------------------------------------------------------------------------------------
# Reading the vault


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def sections(markdown):
    """[(heading, [lines])] for every `## ` section, in file order."""
    out, heading, lines = [], None, []
    for line in markdown.splitlines():
        if line.startswith("## "):
            if heading is not None:
                out.append((heading, lines))
            heading, lines = line[3:].strip(), []
        elif heading is not None:
            lines.append(line)
    if heading is not None:
        out.append((heading, lines))
    return out


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def tables(lines):
    """[(header cells, header line, [(row cells, row line)])] for each pipe table in a section."""
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("|") and i + 1 < len(lines) and re.match(r"^\|[-| :]+\|$", lines[i + 1].strip()):
            header_line = lines[i].strip()
            rows, j = [], i + 2
            while j < len(lines) and lines[j].startswith("|"):
                rows.append((cells(lines[j]), lines[j].strip()))
                j += 1
            out.append((cells(header_line), header_line, rows))
            i = j
        else:
            i += 1
    return out


def table_passage(heading, lines, header_line, row_line):
    """A table row the way a retrieved chunk carries it: the heading, the section's own prose
    (where a table's unit is often stated) and the row under its header."""
    prose = " ".join(l.strip() for l in lines if l.strip() and not l.startswith("|"))
    return "\n".join(p for p in (heading, prose, header_line, row_line) if p)


def short_heading(heading):
    return re.split(r" — |: | \(", heading)[0].strip()


NUMBER = re.compile(r"(?<![\w.])(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+)(?!\d)")
QUANTITY = re.compile(
    r"(?<![\w.])(\d+(?:\.\d+)?)\s*(in\. w\.c\.|in\. w\.g\.|psig|vac|v|°f|°c|µa|s|%|cfm|a|min|minutes?|seconds?|ft)(?![a-z0-9])",
    re.IGNORECASE)


def numbers(text):
    return {n.replace(",", "").lstrip("0") or "0" for n in NUMBER.findall(text)}


def near_miss(value, passage):
    """A number a weak model might say instead — a shifted decimal or one more — that the passage
    does not hold. Nil when every try is in the passage."""
    tries = []
    if "." in value:
        tries.append(value.replace(".", "").lstrip("0") or "0")
        whole, frac = value.split(".")
        tries.append(f"{int(whole) + 1}.{frac}")
    else:
        tries.append(value + "0")
        tries.append(str(int(value) + 1))
    held = numbers(passage)
    for candidate in tries:
        if (candidate.lstrip("0") or "0") not in held:
            return candidate
    return None


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.;])\s+(?=[A-Z0-9])", text) if s.strip()]


# ---------------------------------------------------------------------------------------------
# Cases

cases = []


def add(case):
    case.setdefault("group", "fieldAssist")
    if case["group"] == "fieldAssist":
        case.setdefault("vault", VAULT_TAG)
    cases.append(case)


def call(name, arguments):
    return "<tool_call>" + json.dumps({"name": name, "arguments": arguments}, ensure_ascii=False) + "</tool_call>"


def reading_case(cid, source, turn, passage_id, passage, answer, quote, accepted, found=True, question_source=None):
    add({
        "id": cid, "category": "manualAnswer" if accepted else "notInManual", "source": question_source or source,
        "turn": turn, "offered": [],
        "passages": {passage_id: passage},
        "reading": {"found": found, "answer": answer, "passage": passage_id, "quote": quote},
        "expect": {"calls": [], "readingAccepted": accepted},
    })


SERVICE_UNITS = {
    "Gas supply (line) pressure": ("in. w.c.", "inWC"),
    "Manifold pressure and operating pressure signal (Delta P)": ("in. w.c.", "inWC"),
    "Combustion": ("%", "%"),
    "Voltage and ground": ("VAC", "VAC"),
}


def service_values():
    src = "service_values.md"
    count = 0
    for heading, lines in sections(read(f"{VAULT_REL}/{src}")):
        short = short_heading(heading)
        unit = next((u for k, u in SERVICE_UNITS.items() if heading.startswith(k)), None)
        for header, header_line, rows in tables(lines):
            for row, row_line in rows:
                label = row[0]
                passage = table_passage(heading, lines, header_line, row_line)
                for col, cell in zip(header[1:], row[1:]):
                    nums = NUMBER.findall(cell)
                    if not nums or cell in ("—", "-"):
                        continue
                    count += 1
                    cid = f"sv-{count:03d}"
                    written_unit = "" if re.search(r"[a-z%]", cell.split()[-1] if cell.split() else "") else (unit[0] if unit else "")
                    answer = f"{label}, {col.lower()}: {cell}{(' ' + written_unit) if written_unit else ''}."
                    quote = row_line.strip("| ").strip()
                    turn = f"{short}: what should the {col.lower()} be for {label}?"
                    reading_case(f"{cid}-answer", src, turn, "p1", passage, answer, quote, True)
                    miss = near_miss(nums[0].replace(",", ""), passage)
                    if miss and (written_unit or re.search(r"\d\s*[a-z%]", cell)):
                        wrong = answer.replace(nums[0], miss, 1)
                        reading_case(f"{cid}-miss", src, turn, "p1", passage, wrong, quote, False)
                    # Readings logged against the value, in range and out of range.
                    if len(nums) >= 2 and unit:
                        lo, hi = float(nums[0]), float(nums[1])
                        places = max(len(n.split(".")[1]) if "." in n else 0 for n in nums[:2])
                        inside = f"{(lo + hi) / 2:.{places}f}"
                        outside = f"{hi + (hi - lo) / 2:.{places}f}"
                        for tag, value in (("in", inside), ("out", outside)):
                            quantity = f"{col.lower()}, {label}"
                            add({
                                "id": f"{cid}-log-{tag}", "category": "toolChoice", "source": src,
                                "turn": f"Log {quantity} at {value} {unit[0]}",
                                "offered": ["reading", "field_session", "table_lookup", "domain_calc"],
                                "expect": {"calls": [{"tool": "reading", "required": ["action", "value"],
                                                      "values": {"action": "record_reading", "value": value}}]},
                                "results": {"reading": f"Recorded {quantity} {value} {unit[1]}; "
                                                      f"the manual's range is {cell} ({'inside' if tag == 'in' else 'above'} it)."},
                                "reference": [call("reading", {"action": "record_reading", "quantity": quantity,
                                                               "value": value, "unit": unit[1]}),
                                              f"Logged {value}. That's {'inside' if tag == 'in' else 'above'} the {cell} range."],
                            })
                        # Multi-turn: the second of two values said together.
                        if tag == "out" and "manifold" in col.lower():
                            add({
                                "id": f"{cid}-followup", "category": "multiTurn", "source": src,
                                "turn": "and the other one?",
                                "history": [
                                    {"role": "user", "content": f"{col} reads {inside} on {label}, and {outside} on the other burner. Log the first."},
                                    {"role": "assistant", "content": f"Logged {inside} {unit[0]}."},
                                ],
                                "offered": ["reading", "field_session"],
                                "expect": {"calls": [{"tool": "reading", "required": ["action", "value"],
                                                      "values": {"value": outside}}]},
                                "results": {"reading": f"Recorded {outside} {unit[1]}."},
                                "reference": [call("reading", {"action": "record_reading", "quantity": col.lower(),
                                                               "value": outside, "unit": unit[1]}),
                                              f"Logged the other at {outside}."],
                            })
        # Prose sections: every sentence that states a quantity.
        prose = " ".join(l.lstrip("-0123456789. ").strip() for l in lines if l.strip() and not l.startswith("|"))
        for n, sentence in enumerate(s for s in sentences(prose) if QUANTITY.search(s)):
            count += 1
            cid = f"sv-{count:03d}"
            passage = f"{heading}\n{prose}"
            turn = f"{short}: what does the manual say?"
            reading_case(f"{cid}-answer", src, turn, "p1", passage, sentence, sentence, True)
            q = QUANTITY.search(sentence)
            miss = near_miss(q.group(1), passage)
            if miss:
                wrong = sentence[:q.start(1)] + miss + sentence[q.end(1):]
                reading_case(f"{cid}-miss", src, turn, "p1", passage, wrong, sentence, False)


def error_codes():
    src = "error_codes.md"
    all_codes = []
    for heading, lines in sections(read(f"{VAULT_REL}/{src}")):
        for header, header_line, rows in tables(lines):
            if not header or header[0] != "Code":
                continue
            section_codes = []
            for row, row_line in rows:
                code, meaning = row[0], row[1]
                action = row[2] if len(row) > 2 else ""
                section_codes.append(code)
                all_codes.append(code)
                passage = f"{heading}\n{header_line}\n{row_line}"
                quote = f"{code} | {meaning}"
                reading_case(f"code-{code}-answer", src, f"What does code {code} mean?", "p1", passage,
                             f"{code}: {meaning}. {action}".strip(), quote, True)
                add({
                    "id": f"code-{code}-lookup", "category": "toolChoice", "source": src,
                    "turn": f"The control's showing {code}. What do I check?",
                    "offered": ["table_lookup", "equipment_lookup", "field_session", "show_source", "reading"],
                    # equipment_lookup's own description names error codes, so looking the code
                    # up there is as right as reading it from the table.
                    "expect": {"calls": [{"tool": "table_lookup", "required": ["table", "row"],
                                          "values": {"row": code},
                                          "alternatives": [{"tool": "equipment_lookup", "required": ["query"],
                                                            "values": {"query": code}}]}]},
                    "results": {"table_lookup": f"Diagnostic codes, {code}: {meaning}. Action: {action}",
                                "equipment_lookup": f"{src}: {code}: {meaning}. Action: {action}"},
                    "reference": [call("table_lookup", {"table": "Diagnostic codes", "row": code}),
                                  f"{code} means {meaning[0].lower() + meaning[1:]}."],
                })
            for first, second in zip(section_codes, section_codes[1:]):
                add({
                    "id": f"code-{second}-followup", "category": "multiTurn", "source": src,
                    "turn": f"and if it's {second} instead?",
                    "history": [{"role": "user", "content": f"The control's showing {first}."},
                                {"role": "assistant", "content": f"{first} is in the diagnostic table; I read it out."}],
                    "offered": ["table_lookup", "equipment_lookup", "field_session"],
                    "expect": {"calls": [{"tool": "table_lookup", "required": ["table", "row"],
                                          "values": {"row": second},
                                          "alternatives": [{"tool": "equipment_lookup", "required": ["query"],
                                                            "values": {"query": second}}]}]},
                    "results": {"table_lookup": f"Diagnostic codes, {second}.",
                                "equipment_lookup": f"{src}: {second}."},
                    "reference": [call("table_lookup", {"table": "Diagnostic codes", "row": second}),
                                  f"That's {second} — here's what it means."],
                })
    # Codes the vault doesn't list, beside the nearest listed one: abstain.
    listed = set(all_codes)
    for code in sorted(listed):
        m = re.match(r"E(\d+)$", code)
        if not m:
            continue
        missing = f"E{int(m.group(1)) + 1}"
        if missing in listed:
            continue
        reading_case(f"code-{missing}-absent", src, f"What does code {missing} mean?", "p1",
                     f"Diagnostic codes\n| Code | Meaning |\n| {code} | listed |",
                     "", "", False, found=False)


def parts():
    src = "parts.md"
    models = ["070XV36B", "090XV36C", "090XV48C", "090XV60C", "110XV60C", "135XV60D"]
    for heading, lines in sections(read(f"{VAULT_REL}/{src}")):
        for header, header_line, rows in tables(lines):
            for row, row_line in rows:
                part, description, fits = row[0], row[1], row[2]
                passage = f"{heading}\n{header_line}\n{row_line}"
                turn = f"Which part number is the {description[0].lower() + description[1:]}?"
                reading_case(f"part-{part}-answer", src, turn, "p1", passage,
                             f"{part}: {description}, fits {fits}.", f"{part} | {description}", True)
                if fits != "All models":
                    others = [m for m in models if m[:3] not in fits and m not in fits]
                    if others:
                        reading_case(f"part-{part}-other-model", src,
                                     f"Which part number is the {description[0].lower() + description[1:]} for the {others[0]}?",
                                     "p1", passage, "", "", False, found=False)


def model_facts():
    src = "models.md"
    md = read(f"{VAULT_REL}/{src}")
    patterns = [
        ("overcurrent", r"Maximum overcurrent protection (\d+) A", "the maximum overcurrent protection", "{} A"),
        ("afue", r"AFUE ([\d.]+)%", "the AFUE", "{}%"),
        ("rise", r"[Tt]emperature rise(?: range)? (\d+)–(\d+) °F at max input", "the temperature rise at max input", "{}–{} °F"),
        ("cfm", r"(\d+)–(\d+) cfm", "the blower airflow range", "{}–{} cfm"),
    ]
    for heading, lines in sections(md):
        m = re.match(r"(SLP99UH\w+K) \(([^)]*)\)", heading)
        if m:
            model, aliases = m.group(1), [a.strip() for a in m.group(2).split(";")[0].split(",")]
            short = aliases[0]
            body = "\n".join(lines).strip()
            passage = f"{heading}\n{body}"
            for name in [model] + aliases:
                add({
                    "id": f"model-{model}-{re.sub(r'[^A-Za-z0-9]', '', name)}-lookup", "category": "toolChoice",
                    "source": src, "turn": f"Which unit is this? The nameplate says {name}",
                    "offered": ["equipment_lookup", "field_session", "reading", "table_lookup"],
                    "expect": {"calls": [{"tool": "equipment_lookup", "required": ["query"], "values": {"query": name}}]},
                    "results": {"equipment_lookup": f"{model}: {short}."},
                    "reference": [call("equipment_lookup", {"query": name}), f"That's the {short}."],
                })
            for tag, pattern, what, fmt in patterns:
                found = re.search(pattern, body)
                if not found:
                    continue
                line = next(l for l in body.splitlines() if found.group(0) in l).lstrip("- ").strip()
                values = found.groups()
                answer = f"On the {short}, {what} is {fmt.format(*values)}."
                turn = f"What's {what} on the {short}?"
                reading_case(f"model-{short}-{tag}-answer", src, turn, "p1", passage, answer, line, True)
                miss = near_miss(values[0], passage)
                if miss:
                    reading_case(f"model-{short}-{tag}-miss", src, turn, "p1", passage,
                                 f"On the {short}, {what} is {fmt.format(miss, *values[1:])}.", line, False)
        elif heading.startswith("Unit size codes"):
            for header, header_line, rows in tables(lines):
                for row, row_line in rows:
                    model, code = row[0], row[1]
                    passage = f"{heading}\n{header_line}\n{row_line}"
                    reading_case(f"size-{model}-answer", src, f"What unit size code does the {model} take?", "p1",
                                 passage, f"The {model} takes size code {code}.", f"{model} | {code}", True)
            for missing in ["SLP99UHXV-045-24A", "SLP99UHXV-155-60D"]:
                reading_case(f"size-{missing}-absent", src, f"What unit size code does the {missing} take?", "p1",
                             f"{heading}\n" + "\n".join(l for l in lines if l.startswith("|")), "", "", False, found=False)


def safety():
    src = "safety.md"
    for s_index, (heading, lines) in enumerate(sections(read(f"{VAULT_REL}/{src}")), 1):
        bullets = [l[2:].strip() for l in lines if l.startswith("- ")]
        passage = f"{heading}\n" + "\n".join(f"- {b}" for b in bullets)
        for b_index, bullet in enumerate(bullets, 1):
            first = sentences(bullet)[0]
            cid = f"safety-{s_index}-{b_index}"
            turn = f"Before I start — {heading[0].lower() + heading[1:]}: anything I need to know?"
            reading_case(f"{cid}-answer", src, turn, "p1", passage, first, first, True)
            q = QUANTITY.search(first)
            if q:
                miss = near_miss(q.group(1), passage)
                if miss:
                    wrong = first[:q.start(1)] + miss + first[q.end(1):]
                    reading_case(f"{cid}-miss", src, turn, "p1", passage, wrong, first, False)


def procedures():
    for name in ["slp99_no_ignition", "slp99_pressure_switch_lockout", "slp99_unit_size_code"]:
        src = f"procedures/{name}.json"
        procedure = json.loads(read(f"{VAULT_REL}/{src}"))
        title = procedure["title"]
        offered = ["procedure_runner", "field_session", "table_lookup", "reading"]
        add({
            "id": f"proc-{name}-start", "category": "toolChoice", "source": src,
            "turn": f"Start the {title[0].lower() + title[1:]} procedure",
            "offered": offered,
            "expect": {"calls": [{"tool": "procedure_runner", "required": ["action"],
                                  "values": {"action": "start", "procedure_id": name}}]},
            "results": {"procedure_runner": f"Step 1: {procedure['steps'][0]['title']}."},
            "reference": [call("procedure_runner", {"action": "start", "procedure_id": name}),
                          f"First: {procedure['steps'][0]['title'].lower()}."],
        })
        for step in procedure["steps"]:
            history = [{"role": "user", "content": f"Start the {title.lower()} procedure"},
                       {"role": "assistant", "content": step["instruction"]}]
            add({
                "id": f"proc-{name}-{step['id']}-next", "category": "multiTurn", "source": src,
                "turn": "Done. Next step", "history": history, "offered": offered,
                "expect": {"calls": [{"tool": "procedure_runner", "required": ["action"], "values": {"action": "next"}}]},
                "results": {"procedure_runner": "Next step."},
                "reference": [call("procedure_runner", {"action": "next"}), "Next step is up."],
            })
            add({
                "id": f"proc-{name}-{step['id']}-repeat", "category": "multiTurn", "source": src,
                "turn": "Sorry, say that step again", "history": history, "offered": offered,
                "expect": {"calls": [{"tool": "procedure_runner", "required": ["action"], "values": {"action": "repeat"}}]},
                "results": {"procedure_runner": step["instruction"]},
                "reference": [call("procedure_runner", {"action": "repeat"}), step["title"] + "."],
            })
            for branch in step.get("branches", [])[:1]:
                add({
                    "id": f"proc-{name}-{step['id']}-answer", "category": "multiTurn", "source": src,
                    "turn": branch["condition"], "history": history, "offered": offered,
                    "expect": {"calls": [{"tool": "procedure_runner", "required": ["action"],
                                          "values": {"action": "answer"}}]},
                    "results": {"procedure_runner": "Recorded; moving on."},
                    "reference": [call("procedure_runner", {"action": "answer", "value": branch["condition"]}),
                                  "Got it."],
                })


def two_steps():
    src = "service_values.md"
    models = [("070XV36B", 15), ("090XV36C", 15), ("090XV48C", 15), ("090XV60C", 20), ("110XV60C", 20), ("135XV60D", 20)]
    for model, amps in models:
        for volts in ("115", "120"):
            add({
                "id": f"twostep-{model}-{volts}", "category": "twoStep", "source": src,
                "turn": f"Line voltage at the {model} control is {volts}. Log it, then work out the voltage drop "
                        f"at {amps} amps over 50 feet of 14 gauge copper.",
                "offered": ["reading", "domain_calc", "field_session"],
                "expect": {"calls": [{"tool": "reading", "required": ["action", "value"], "values": {"value": volts}},
                                     {"tool": "domain_calc", "required": ["operation"],
                                      "values": {"operation": "voltage_drop", "current_a": str(amps), "length_ft": "50"}}],
                           "carry": {"fromCall": 0, "fromArgument": "value", "toCall": 1, "toArgument": "supply_v"}},
                "results": {"reading": f"Recorded line voltage {volts} VAC (manual range 97 – 132 VAC).",
                            "domain_calc": "Voltage drop about 3 V."},
                "reference": [call("reading", {"action": "record_reading", "quantity": "line voltage",
                                               "value": volts, "unit": "VAC"}),
                              call("domain_calc", {"operation": "voltage_drop", "supply_v": volts,
                                                   "current_a": amps, "length_ft": 50, "area_cmil": 4110}),
                              f"Logged {volts} volts; the drop is about 3 volts."],
            })


CALIBRATION_PASSAGES = {
    "what is the manifold pressure on high fire": ("service_values.md", "High, all models", "Manifold, natural gas: 3.0 – 3.8 in. w.c. on high fire.", "High, all models | 3.0 – 3.8"),
    "high fire manifold pressure": ("service_values.md", "High, all models", "Natural gas on high fire: 3.0 – 3.8 in. w.c.", "High, all models | 3.0 – 3.8"),
    "how do I measure the gas supply pressure at the valve": ("service_values.md", "Natural", "Natural gas line pressure: 4.5 – 10.5 in. w.c., at the supply tap on the inlet side.", "Natural | 4.5 – 10.5"),
    "what flame signal in microamps should I read at the sensor": ("service_values.md", "Flame signal", "Normal is 2.6 µA or greater.", "Normal 2.6 µA or greater"),
    "flame signal microamps": ("service_values.md", "Flame signal", "Normal is 2.6 µA or greater; drop-out 1.1 µA.", "drop-out 1.1 µA"),
    "how do I configure the unit size code on the integrated control": ("models.md", "Unit size codes", "Program the size code on the control; the 090XV60C takes d.", "SLP99UHXV-090-60C | d"),
}


def calibration():
    """The vault's retrieval calibration phrasings, reused as reading cases. That file is the
    retrieval eval's answer key (pages per question, in scope or out); here the same words test
    whether a model reads a passage honestly and declines what it doesn't hold."""
    src = "eval/calibration.jsonl"
    sv = read(f"{VAULT_REL}/service_values.md")
    md = read(f"{VAULT_REL}/models.md")
    passages = {
        "High, all models": next(table_passage(h, ls, t[1], r[1]) for h, ls in sections(sv) for t in tables(ls) for r in t[2] if r[0][0] == "High, all models"),
        "Natural": next(table_passage(h, ls, t[1], r[1]) for h, ls in sections(sv) for t in tables(ls) for r in t[2] if r[0][0] == "Natural"),
        "Flame signal": next(f"{h}\n" + " ".join(l for l in ls if l.strip()) for h, ls in sections(sv) if h.startswith("Flame signal")),
        "Unit size codes": next(f"{h}\n" + "\n".join(l for l in ls if l.startswith("|")) for h, ls in sections(md) if h.startswith("Unit size codes")),
    }
    lines = [json.loads(l) for l in read(f"{VAULT_REL}/{src}").splitlines() if l.strip() and not l.startswith("//")]
    for n, entry in enumerate(lines, 1):
        q = entry["q"]
        if q in CALIBRATION_PASSAGES:
            file, key, answer, quote = CALIBRATION_PASSAGES[q]
            reading_case(f"cal-{n:02d}-answer", file, q[0].upper() + q[1:] + "?", "p1", passages[key], answer, quote,
                         True, question_source=src)
        elif entry.get("outOfScope"):
            reading_case(f"cal-{n:02d}-absent", src, q[0].upper() + q[1:] + "?", "p1", passages["High, all models"],
                         "", "", False, found=False)


def job_flow():
    """Running the job by voice: open, reference, pause, resume, next unit, end, evidence."""
    src = "synthetic"
    flow = [
        ("job-open", "Open a new job for the SLP99 furnace at 14 Hill Street", {"action": "start"}, "Started a new job."),
        ("job-open-ref", "Start job 1005", {"action": "start", "job_reference": "1005"}, "Started job 1005."),
        ("job-ref", "The work order number is 2231", {"action": "set_job_reference", "job_reference": "2231"}, "Job reference set."),
        ("job-pause", "Pause the job, I'm going for lunch", {"action": "pause"}, "Paused."),
        ("job-resume", "Right, back on the furnace job", {"action": "resume"}, "Resumed."),
        ("job-next-unit", "Moving on to the second furnace in the plant room", {"action": "next_unit"}, "Second unit."),
        ("job-status", "How long have I been on this job?", {"action": "status"}, "Job open 1 h 20 min."),
        ("job-end", "That's it, close the job", {"action": "end"}, "Job ended."),
    ]
    for cid, turn, args, result in flow:
        values = {k: v for k, v in args.items()}
        add({
            "id": cid, "category": "toolChoice", "source": src, "turn": turn,
            "offered": ["field_session", "reading", "evidence", "equipment_lookup", "procedure_runner"],
            "expect": {"calls": [{"tool": "field_session", "required": sorted(args.keys()), "values": values}]},
            "results": {"field_session": result},
            "reference": [call("field_session", args), "Done."],
        })
    for action, item in [("keep", "photo of the gas valve label"), ("keep", "photo of the E223 on the display"),
                         ("exclude", "blurry photo of the inducer"), ("include_all", "all of today's photos")]:
        add({
            "id": f"evidence-{action}-{re.sub(r'[^a-z0-9]+', '-', item)[:24].strip('-')}", "category": "toolChoice",
            "source": src, "turn": f"{action.replace('_', ' ').capitalize()} the {item}",
            "offered": ["evidence", "field_session", "reading"],
            "expect": {"calls": [{"tool": "evidence", "required": ["action"], "values": {"action": action}}]},
            "results": {"evidence": "Done."},
            "reference": [call("evidence", {"action": action, "item": item}), "Done."],
        })
    for which in ["table", "first", "last"]:
        add({
            "id": f"source-{which}", "category": "toolChoice", "source": src,
            "turn": f"Show me the {'page that table came from' if which == 'table' else which + ' source you used'}",
            "offered": ["show_source", "table_lookup"],
            "expect": {"calls": [{"tool": "show_source", "required": [], "values": {"which": which}}]},
            "results": {"show_source": "Opened on the phone."},
            "reference": [call("show_source", {"which": which}), "It's on the phone."],
        })
    # Long prompts: the job context near a 4K model's prompt budget (3,456 tokens).
    for n, (tokens, turn, value) in enumerate([(3000, "Log manifold pressure on low fire, 0.6 inches", "0.6"),
                                               (3200, "Log line pressure 7 inches natural", "7"),
                                               (3400, "Flame signal reads 2.9 microamps, log it", "2.9")], 1):
        add({
            "id": f"long-{n}", "category": "longPrompt", "source": src, "turn": turn, "contextTokens": tokens,
            "offered": ["reading", "field_session", "table_lookup"],
            "expect": {"calls": [{"tool": "reading", "required": ["action", "value"], "values": {"value": value}}]},
            "results": {"reading": f"Recorded {value}."},
            "reference": [call("reading", {"action": "record_reading", "value": value}), f"Logged {value}."],
        })
    add({"id": "long-restraint", "category": "longPrompt", "source": src, "turn": "Thanks, that's all for this one",
         "contextTokens": 3300, "offered": ["field_session", "reading"], "expect": {"calls": []},
         "reference": ["No problem."]})
    # Protocol cases on job turns.
    add({"id": "clean-job-1", "category": "cleanOutput", "source": src, "turn": "Log 0.6 on low fire",
         "offered": ["reading"],
         "expect": {"calls": [{"tool": "reading", "required": ["action", "value"], "values": {"value": "0.6"}}]},
         "results": {"reading": "Recorded 0.6 inWC."},
         "reference": ["Sure. " + call("reading", {"action": "record_reading", "value": "0.6"}), "Logged 0.6.</tool_call>"]})
    add({"id": "clean-job-2", "category": "cleanOutput", "source": src, "turn": "Log 3.5 inches high fire",
         "offered": ["reading"],
         "expect": {"calls": [{"tool": "reading", "required": ["action", "value"], "values": {"value": "3.5"}}]},
         "results": {"reading": "Recorded 3.5 inWC."},
         "reference": ["<think>Record it. " + call("reading", {"action": "record_reading", "value": "3.5", "unit": "inWC"}) + "</think>",
                       "Logged 3.5 on high fire."]})
    add({"id": "clean-job-3", "category": "cleanOutput", "source": src, "turn": "How long before I read manifold pressure?",
         "offered": ["table_lookup"], "expect": {"calls": []},
         "reference": ["<think>The vault says five minutes on low heat.</think>Run low heat for five minutes, then read it."]})
    add({"id": "cancel-job-1", "category": "cancellation", "source": src, "turn": "Log 0.6 on low fire",
         "offered": ["reading"], "cancel": "decode", "expect": {"calls": []},
         "reference": [call("reading", {"action": "record_reading", "value": "0.6"}), "Logged."]})
    add({"id": "cancel-job-2", "category": "cancellation", "source": src, "turn": "Start the no ignition procedure",
         "offered": ["procedure_runner"], "cancel": "generation",
         "expect": {"calls": [{"tool": "procedure_runner", "required": ["action"], "values": {"action": "start"}}]},
         "results": {"procedure_runner": "Step 1."},
         "reference": [call("procedure_runner", {"action": "start", "procedure_id": "slp99_no_ignition"}), "First step."]})


def field_restraint():
    """Job turns that need no tool although the job tools are offered (the restraint floor, decision 5).

    Three kinds, all written here: chatter and asides during a job; turns that name the unit, a code
    or a procedure without asking for anything (the tempting ones); and requests none of the offered
    tools can do. None states a reading, so none should be logged.
    """
    src = "synthetic"
    turns = [
        # Chatter and asides on the job.
        ("cheers", "Cheers, got it", "No problem."),
        ("hang-on", "Hang on, the customer's at the door", "Sure, I'll wait."),
        ("ladder", "Just getting the ladder out of the van", "Okay."),
        ("coffee", "Customer's made me a coffee, nice of them", "Enjoy it."),
        ("tight", "This flue is a pain to get at", "Take your time."),
        ("dusty", "It's filthy in this cupboard", "Mind the dust."),
        ("think", "Give me a second to think about where to start", "Sure, take a moment."),
        ("back", "Okay, I'm back", "Welcome back."),
        ("phone-low", "My phone's on twenty percent, I'll have to be quick", "Understood, I'll keep it short."),
        ("rain", "It's started raining, glad this one's inside", "Lucky timing."),
        ("good-news", "Good news, it fired up first time", "Great."),
        ("not-sure", "I'm not sure about this one yet", "Okay, tell me what you're seeing when you're ready."),
        ("stretch", "Hold on, my knee's killing me from kneeling", "Take a break."),
        ("van", "I left my multimeter in the van, back in a minute", "Okay, I'll be here."),
        # Naming the unit, a code or a procedure without asking for anything.
        ("seen-code", "I've seen that E223 code loads of times, I know what it is", "Okay."),
        ("did-procedure", "I already ran the no ignition procedure yesterday, it was the igniter", "Got it."),
        ("know-this", "Don't bother with the manual, I know this furnace", "Okay, shout if you want anything."),
        ("panel-off", "The last tech left the SLP99 panel off, typical", "That's annoying."),
        ("old-unit", "This SLP99 has been in since the house was built by the look of it", "It's had a good run."),
        ("switch-fine", "The pressure switch looks fine to me", "Okay."),
        ("photo-later", "I'll take photos once I've got the cover off", "Okay."),
        ("job-later", "I'll start the job properly once I've had a look", "Sure, tell me when."),
        ("readings-later", "I'll give you the readings in a bit", "Okay, ready when you are."),
        ("customer-asked", "Customer asked if it's the original furnace, I told them yes", "Fair enough."),
        ("spoken-before", "We talked about this unit last week, same problem again", "Okay."),
        ("no-log", "Don't log anything yet, I'm just looking", "Okay, nothing logged."),
        ("filter", "Filter's due a change, I'll mention it to them", "Good idea."),
        ("tidy", "Right, tidying up my tools", "Okay."),
        # Requests none of the offered tools can do.
        ("call-boss", "Call my boss and tell them I'm running late", "I can't make calls here. Let them know when you can."),
        ("order-part", "Order a new igniter for me", "I can't place orders from here. Note it down for the office."),
        ("text-customer", "Text the customer that I'm outside", "I can't send messages offline. Knock when you're there."),
        ("directions", "How do I get to the next job from here?", "I can't do directions offline. Check your maps when you've got signal."),
        ("invoice", "Send the invoice to the customer", "I can't send invoices from here. The office can do it."),
        ("music", "Put some music on", "I can't play music in this mode."),
        ("weather", "Is it going to rain later?", "I can't check the weather offline."),
        ("remind-office", "Remind the office to book the follow-up", "I can't contact the office from here. Note it for later."),
    ]
    sets = [
        ["field_session", "reading", "evidence", "equipment_lookup", "procedure_runner"],
        ["field_session", "reading", "table_lookup"],
        ["reading", "evidence", "show_source"],
        ["field_session", "procedure_runner", "equipment_lookup", "domain_calc"],
    ]
    for n, (cid, turn, answer) in enumerate(turns):
        add({"id": f"fa-restraint-{cid}", "category": "restraint", "source": src, "turn": turn,
             "offered": sets[n % len(sets)], "expect": {"calls": []}, "reference": [answer]})


def everyday():
    """The short everyday set: small talk, job-adjacent chatter that needs no tool, the time, a timer."""
    src = "synthetic"
    chatter = [
        ("chat-morning", "Morning! Long day ahead.", "Morning! Shout when you want the first job opened."),
        ("chat-thanks", "Thanks, that's all for now", "No problem."),
        ("chat-spell", "How do you spell Lennox?", "L-E-N-N-O-X."),
        ("chat-crawl", "This crawl space is tight, I'll be a minute", "Take your time."),
        ("chat-dog", "Customer's dog won't stop following me around", "Sounds like you've got an assistant."),
        ("chat-customer", "Tell the customer I'll be about twenty minutes", "I can't message them from here offline — let them know when you're back in signal."),
        ("chat-done-check", "The suction was 118 and superheat came out at 12, so that's fine, right?", "Yes — 12 degrees is a normal superheat for that."),
    ]
    for cid, turn, answer in chatter:
        add({"id": cid, "category": "restraint", "source": src, "group": "everyday", "turn": turn,
             "offered": ["field_session", "reading", "evidence", "get_datetime"], "expect": {"calls": []},
             "reference": [answer]})
    add({"id": "every-time", "category": "toolChoice", "source": src, "group": "everyday", "turn": "What's the time?",
         "offered": ["get_datetime", "set_timer"],
         "expect": {"calls": [{"tool": "get_datetime", "required": [], "values": {}}]},
         "results": {"get_datetime": "Friday 21 November, 1:52 pm."},
         "reference": [call("get_datetime", {}), "Assistant: It's 1:52 pm."]})
    add({"id": "every-timer", "category": "toolChoice", "source": src, "group": "everyday",
         "turn": "Set a timer for ten minutes while the furnace runs", "offered": ["set_timer", "get_datetime"],
         "expect": {"calls": [{"tool": "set_timer", "required": ["seconds"], "values": {"seconds": "600"}}]},
         "results": {"set_timer": "Timer set for 10 minutes."},
         "reference": [call("set_timer", {"seconds": "600"}), "Ten-minute timer started."]})
    add({"id": "every-cancel", "category": "cancellation", "source": src, "group": "everyday",
         "turn": "What's the time?", "offered": ["get_datetime"], "cancel": "decode", "expect": {"calls": []},
         "reference": [call("get_datetime", {}), "It's 1:52 pm."]})


# ---------------------------------------------------------------------------------------------


def build():
    service_values()
    error_codes()
    parts()
    model_facts()
    safety()
    procedures()
    two_steps()
    calibration()
    job_flow()
    field_restraint()
    everyday()
    ids = [c["id"] for c in cases]
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        sys.exit(f"duplicate case ids: {len(duplicates)}")
    body = [json.dumps(c, ensure_ascii=False, sort_keys=True) for c in cases]
    digest = hashlib.sha256()
    for rel in sorted(INPUTS):
        digest.update(rel.encode() + b"\0" + (ROOT / rel).read_bytes() + b"\0")
    body_digest = hashlib.sha256("\n".join(body).encode()).hexdigest()
    header = [
        f"// Local model tool corpus, version {VERSION} (Plan MQ P0). Generated by Scripts/local-tool-eval/generate-corpus.py",
        f"// from {VAULT_REL}; do not edit by hand. Lines starting with // are skipped.",
        "// `reference` is what a passing model emits, raw: CI plays it through a scripted fake model; P3's runners use real models.",
        f"// inputs-sha256: {digest.hexdigest()}",
        f"// body-sha256: {body_digest}",
    ]
    return "\n".join(header + body) + "\n"


def summary(text):
    rows = [json.loads(l) for l in text.splitlines() if l and not l.startswith("//")]
    by = {}
    for r in rows:
        key = (r["group"], r["category"])
        by[key] = by.get(key, 0) + 1
    sources = {}
    for r in rows:
        sources[r["source"]] = sources.get(r["source"], 0) + 1
    fa = sum(v for (g, _), v in by.items() if g == "fieldAssist")
    print(f"cases {len(rows)}; fieldAssist {fa} ({fa * 100 // len(rows)}%), everyday {len(rows) - fa}")
    for (g, c), v in sorted(by.items()):
        print(f"  {g} {c}: {v}")
    for s, v in sorted(sources.items()):
        print(f"  source {s}: {v}")


if __name__ == "__main__":
    text = build()
    if "--check" in sys.argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print("local-tool corpus is out of date: run Scripts/local-tool-eval/generate-corpus.py")
            sys.exit(1)
        print("local-tool corpus is current")
    else:
        OUT.write_text(text, encoding="utf-8")
    summary(text)
