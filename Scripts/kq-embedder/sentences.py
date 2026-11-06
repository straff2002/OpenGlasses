"""Invented sentences for the parity check (Plan KQ P0).

Every sentence is assembled here from made-up parts: no manual, code book or answer key is read. The
codes are fictional (letters and digits in no maker's scheme). A few non-English lines check that the
tokenizer and model agree beyond English.
"""

import itertools

_QUESTIONS = [
    "what does fault {code} mean on the {unit}",
    "how do I reset the {unit} after a {symptom}",
    "the {unit} shows {code} and the {part} is {state}, what next",
    "what torque for the {part} on a {unit}",
    "where is the {part} on the {unit}",
    "why does the {unit} {symptom} when it is cold outside",
    "can I replace the {part} without draining the system",
    "what clearance does the {unit} need on each side",
]

_PASSAGES = [
    "If the display shows {code}, check the {part}. A {state} {part} stops the {unit} until it is cleared.",
    "To reset the {unit}, switch off the isolator, wait thirty seconds, and switch it on. A {symptom} that returns needs a service visit.",
    "Remove the front panel to reach the {part}. Disconnect power first. Torque the fixings to the value printed on the label.",
    "Table 9: the {unit} at a glance. Supply 230 V. Fuse 16 A. The {part} is on the left-hand side.",
    "When the {part} is {state}, the controller logs {code} and retries three times before it locks out.",
    "Clearances: 300 mm on each side of the {unit}, 600 mm in front, and nothing stored on top.",
]

_UNITS = ["outdoor unit", "boiler", "dishwasher", "heat pump", "ice maker", "chiller", "condensing unit"]
_PARTS = ["drain pump", "expansion valve", "flow sensor", "fan motor", "pressure switch", "igniter", "door latch"]
_STATES = ["blocked", "open circuit", "stuck closed", "out of range", "loose"]
_SYMPTOMS = ["lockout", "short cycle", "loud hum", "slow start", "no heat"]
_CODES = ["Z9", "QX-41", "K7R", "B0B-2", "W33", "M-5T"]

_OTHER_LANGUAGES = [
    "¿Qué significa el código {code} en la bomba de calor?",
    "Le ventilateur ne démarre pas après le code {code}.",
    "Wie setze ich den Kessel nach einer Störung zurück?",
    "Как сбросить ошибку {code} на наружном блоке?",
    "室外机显示 {code} 是什么意思？",
    "ヒートポンプのエラー {code} の意味は？",
    "ما معنى الرمز {code} على الغلاية؟",
    "Hoe reset ik de vaatwasser na een storing?",
]


def sentences(limit_questions=160, limit_passages=160):
    """(kind, text) pairs, deterministic: kind is "query" or "document"."""
    fills = itertools.cycle(itertools.product(_UNITS, _PARTS, _STATES, _SYMPTOMS, _CODES))
    out = []
    for i in range(limit_questions):
        unit, part, state, symptom, code = next(fills)
        template = _QUESTIONS[i % len(_QUESTIONS)]
        out.append(("query", template.format(unit=unit, part=part, state=state, symptom=symptom, code=code)))
    for i in range(limit_passages):
        unit, part, state, symptom, code = next(fills)
        template = _PASSAGES[i % len(_PASSAGES)]
        out.append(("document", template.format(unit=unit, part=part, state=state, symptom=symptom, code=code)))
    for i, template in enumerate(_OTHER_LANGUAGES):
        out.append(("query", template.format(code=_CODES[i % len(_CODES)])))
    # One long passage, to exercise a length near the package's limit.
    long_text = " ".join(_PASSAGES[i % len(_PASSAGES)].format(
        unit="heat pump", part="fan motor", state="loose", symptom="loud hum", code="Z9") for i in range(14))
    out.append(("document", long_text))
    return out


PREFIX = {
    "query": "task: search result | query: ",
    "document": "title: none | text: ",
}
