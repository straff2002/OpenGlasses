#!/usr/bin/env python3
"""The drafting pass's rules (Contracts/team-learning.md §13.1) against their fixtures.

Standard library only: `python3 -I Contracts/tests/test_recollection_drafts.py`.

This is a second, independent implementation of what an office intake computes from a model's
answer: the quote search, the support rule, the plain-text rule, the limits, the closed
equipment-type list, the site split and the recording segment. It reads
`Contracts/fixtures/team-learning-v1/recollection-draft-schema-v1.json` (the schema every
extraction is forced through) and `recollection-drafts-v1.json` (ten scripted recollections, each
with its segments, a stub model's answer per segment and the drafts expected, plus answers the
rules must refuse). The phone's `RecollectionDraftTests` reads the same files, so a recording
drafts to the same candidate wherever it is processed.

Segmentation (the markers and the vault's model index) is the phone's, checked there; here the
segments are taken from the fixture and only held to their shape.
"""
from pathlib import Path
import json
import unicodedata
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Contracts/fixtures/team-learning-v1"
SCHEMA = FIXTURES / "recollection-draft-schema-v1.json"
CASES = FIXTURES / "recollection-drafts-v1.json"

FIELDS = ["model", "equipmentType", "symptom", "findings", "tried", "fix", "outcome", "siteNote"]
LEARNING = [field for field in FIELDS if field != "siteNote"]
# A name is held to its words: unsupported, it is refused rather than quoted.
NAMES = {"model", "equipmentType"}
# In Unicode scalars. A site note has none: it is not a learning (decision 6).
LIMITS = {"model": 80, "equipmentType": 80, "symptom": 500, "findings": 2000, "tried": 500,
          "fix": 500, "outcome": 120}
# What a draft is: at least one of these filled or held back.
SUBSTANCE = ("symptom", "findings", "fix")
MAX_QUOTES = 6
ELISION = " … "
SUFFIXES = ("s", "es", "ed", "d", "ing")
STOP_WORDS = {
    "a", "an", "the", "and", "or", "but", "so", "then", "it", "its", "this", "that", "these",
    "those", "is", "was", "were", "be", "been", "are", "of", "to", "in", "on", "at", "for", "with",
    "by", "from", "as", "i", "we", "they", "he", "she", "you", "my", "our", "their", "there", "um",
    "uh", "just", "also",
}
REFUSAL_KINDS = {"malformed", "unsupported", "quoteNotFound", "siteInLearning", "controlCharacter"}


class Refused(Exception):
    def __init__(self, kind, field=None):
        super().__init__(kind, field)
        self.kind = kind
        self.field = field


def is_word(character):
    return unicodedata.category(character)[0] in "LN"


def normalise(text, base=0):
    """Lowercased, every run of anything but letters and digits one space, trimmed; with the
    offset in the original of every scalar kept."""
    out, origin, pending = [], [], False
    for index, character in enumerate(text):
        if is_word(character):
            if pending and out:
                out.append(" ")
                origin.append(base + index)
            for lower in character.lower():
                out.append(lower)
                origin.append(base + index)
            pending = False
        else:
            pending = True
    return "".join(out), origin


def words(text):
    return [word for word in normalise(text)[0].split(" ") if word]


def find_quote(transcript, segment, quote):
    """The span of the quote's first whole-word occurrence inside the segment, or None."""
    hay, origin = normalise(transcript[segment["start"]:segment["end"]], segment["start"])
    needle = normalise(quote)[0]
    if not needle:
        return None
    index = hay.find(needle)
    while index != -1:
        end = index + len(needle)
        if (index == 0 or hay[index - 1] == " ") and (end == len(hay) or hay[end] == " "):
            return {"start": origin[index], "end": origin[end - 1] + 1}
        index = hay.find(needle, index + 1)
    return None


def related(a, b):
    if not (a.isalpha() and b.isalpha()):
        return False
    short, long = sorted((a, b), key=len)
    return len(short) >= 3 and long.startswith(short) and long[len(short):] in SUFFIXES


def covered(word, quoted):
    if len(word) < 2 or word in STOP_WORDS:
        return True
    return any(other == word or related(other, word) for other in quoted)


def plain(text, field):
    """§7.4: tabs to spaces, CR and CRLF to LF, LF a space outside `findings`; any other control
    character or a bidirectional control is refused; the ends trimmed."""
    unified = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", " ")
    out = []
    for character in unified:
        if character == "\n":
            out.append("\n" if field == "findings" else " ")
            continue
        code = ord(character)
        if unicodedata.category(character) == "Cc" or 0x202A <= code <= 0x202E or 0x2066 <= code <= 0x2069:
            raise Refused("controlCharacter", field)
        out.append(character)
    return "".join(out).strip()


def type_key(name):
    return " ".join(name.split()).casefold()


def listed_type(name, listed):
    wanted = type_key(name)
    return next((item for item in listed if wanted and type_key(item) == wanted), None)


def seconds(segment, total, duration):
    whole = max(duration, 1)
    start = segment["start"] * whole // total
    end = min(-(-segment["end"] * whole // total), whole)
    return start, end if end > start else start + 1


def overlaps(a, b):
    return a["start"] < b["end"] and b["start"] < a["end"]


def check_shape(answer):
    if not isinstance(answer, dict) or set(answer) != set(FIELDS):
        raise Refused("malformed")
    for field in FIELDS:
        value = answer[field]
        if not isinstance(value, dict) or set(value) != {"text", "quotes"}:
            raise Refused("malformed", field)
        if not isinstance(value["text"], str) or not isinstance(value["quotes"], list):
            raise Refused("malformed", field)
        if len(value["quotes"]) > MAX_QUOTES or not all(isinstance(q, str) for q in value["quotes"]):
            raise Refused("malformed", field)


def draft(transcript, segment, answer, duration, equipment_types, recording_id):
    """One segment's answer as the drafts it makes: (learning draft or None, site note or None)."""
    check_shape(answer)
    filled, held = {}, []
    for field in FIELDS:
        text = plain(answer[field]["text"], field)
        if not text:
            continue
        quotes = [q for q in answer[field]["quotes"] if q.strip()]
        if not quotes:
            raise Refused("unsupported", field)
        spans = []
        for quote in quotes:
            span = find_quote(transcript, segment, quote)
            if span is None:
                raise Refused("quoteNotFound", field)
            if span not in spans:
                spans.append(span)
        said = [transcript[span["start"]:span["end"]] for span in spans]
        quoted = set(words(" ".join(said)))
        verbatim = False
        if not all(covered(word, quoted) for word in words(text)):
            if field in NAMES:
                raise Refused("unsupported", field)
            text = plain(ELISION.join(said), field)
            verbatim = True
        if field == "equipmentType":
            listed = listed_type(text, equipment_types)
            if listed is None:
                held.append({"field": field, "reason": "notListed", "text": text, "spans": spans})
                continue
            text = listed
        limit = LIMITS.get(field)
        if limit is not None and len(text) > limit:
            held.append({"field": field, "reason": "overLimit", "count": len(text), "limit": limit,
                         "spans": spans})
            continue
        filled[field] = {"text": text, "spans": spans, "verbatim": verbatim}

    site = filled.get("siteNote")
    if site:
        site_key = normalise(site["text"])[0]
        for field in LEARNING:
            entry = filled.get(field)
            spans = (entry or {}).get("spans", []) + [s for h in held if h["field"] == field for s in h["spans"]]
            if any(overlaps(span, other) for span in spans for other in site["spans"]):
                raise Refused("siteInLearning", field)
            if entry and f" {site_key} " in f" {normalise(entry['text'])[0]} ":
                raise Refused("siteInLearning", field)

    start, end = seconds(segment, len(transcript), duration)
    learning = None
    if any(f in filled for f in SUBSTANCE) or any(h["field"] in SUBSTANCE for h in held):
        learning = {
            "segment": segment,
            "recording": {"recordingID": recording_id, "segmentStart": start, "segmentEnd": end},
            "fields": {f: filled[f] for f in LEARNING if f in filled},
            "heldBack": held,
        }
    note = {"segment": segment, "text": site["text"], "spans": site["spans"]} if site else None
    return learning, note


class SchemaTests(unittest.TestCase):

    def setUp(self):
        with SCHEMA.open(encoding="utf-8") as handle:
            self.schema = json.load(handle)

    def test_the_schema_is_one_closed_object_of_the_eight_fields(self):
        self.assertEqual(self.schema["type"], "object")
        self.assertIs(self.schema["additionalProperties"], False)
        self.assertEqual(self.schema["required"], FIELDS)
        self.assertEqual(list(self.schema["properties"]), FIELDS)

    def test_every_field_is_its_words_and_the_quotes_they_rest_on(self):
        for field, shape in self.schema["properties"].items():
            self.assertEqual(shape["type"], "object", field)
            self.assertIs(shape["additionalProperties"], False, field)
            self.assertEqual(shape["required"], ["text", "quotes"], field)
            self.assertEqual(shape["properties"]["text"]["type"], "string", field)
            quotes = shape["properties"]["quotes"]
            self.assertEqual((quotes["type"], quotes["items"]["type"], quotes["maxItems"]),
                             ("array", "string", MAX_QUOTES), field)
            self.assertTrue(shape["description"], field)

    def test_the_limits_are_told_to_the_model_and_not_enforced_by_the_schema(self):
        # An over-limit field is held back for the reviewer, not a malformed answer, so the
        # schema carries no maxLength; its description says the limit.
        for field, shape in self.schema["properties"].items():
            self.assertNotIn("maxLength", shape["properties"]["text"], field)
            if field in LIMITS:
                self.assertIn(f"{LIMITS[field]:,}", shape["description"], field)


class DraftTests(unittest.TestCase):

    def setUp(self):
        with CASES.open(encoding="utf-8") as handle:
            self.fixture = json.load(handle)
        self.types = self.fixture["vault"]["equipment_types"]

    def test_ten_recollections_cover_what_the_plan_asks(self):
        cases = self.fixture["cases"]
        self.assertEqual(len(cases), 10)
        self.assertEqual(len({case["name"] for case in cases}), 10)
        covers = {cover for case in cases for cover in case["covers"]}
        self.assertEqual(covers, {
            "one case", "three cases", "no model", "site mentioned", "safety-relevant fix",
            "not a case", "model change without a marker", "unsupported field stays empty",
            "over-limit outcome", "equipment type not listed",
        })

    def test_segments_are_ordered_inside_the_transcript(self):
        for case in self.fixture["cases"]:
            transcript = case["transcript"]
            previous = 0
            self.assertEqual(len(case["segments"]), len(case["answers"]), case["name"])
            for segment in case["segments"]:
                self.assertLessEqual(previous, segment["start"], case["name"])
                self.assertLess(segment["start"], segment["end"], case["name"])
                self.assertLessEqual(segment["end"], len(transcript), case["name"])
                text = transcript[segment["start"]:segment["end"]]
                self.assertEqual(text, text.strip(), case["name"])
                previous = segment["end"]

    def test_every_answer_drafts_exactly_what_is_expected(self):
        for case in self.fixture["cases"]:
            drafts, notes = [], []
            for segment, answer in zip(case["segments"], case["answers"]):
                learning, note = draft(case["transcript"], segment, answer, case["duration"],
                                       self.types, case["recordingID"])
                if learning:
                    drafts.append(learning)
                if note:
                    notes.append(note)
            expected = case["expected"]
            stripped = [{key: value for key, value in d.items() if key in
                         {"segment", "recording", "fields", "heldBack"}} for d in expected["drafts"]]
            self.assertEqual(drafts, stripped, case["name"])
            self.assertEqual(notes, expected["siteNotes"], case["name"])

    def test_every_filled_field_is_covered_by_its_spans_and_no_site_reaches_a_learning(self):
        for case in self.fixture["cases"]:
            transcript = case["transcript"]
            notes = case["expected"]["siteNotes"]
            for drafted in case["expected"]["drafts"]:
                segment = drafted["segment"]
                for field, value in drafted["fields"].items():
                    self.assertTrue(value["spans"], (case["name"], field))
                    for span in value["spans"]:
                        self.assertTrue(segment["start"] <= span["start"] < span["end"] <= segment["end"])
                    said = set(words(" ".join(transcript[s["start"]:s["end"]] for s in value["spans"])))
                    self.assertTrue(all(covered(word, said) for word in words(value["text"])),
                                    (case["name"], field))
                    if field in LIMITS:
                        self.assertLessEqual(len(value["text"]), LIMITS[field], (case["name"], field))
                    for note in notes:
                        self.assertNotIn(normalise(note["text"])[0], normalise(value["text"])[0])
                if "equipmentType" in drafted["fields"]:
                    self.assertIn(drafted["fields"]["equipmentType"]["text"], self.types)

    def test_the_subject_follows_the_fields(self):
        for case in self.fixture["cases"]:
            for drafted in case["expected"]["drafts"]:
                fields, subject = drafted["fields"], drafted.get("subject")
                kind = subject["kind"] if subject else None
                if "modelToken" in drafted:
                    self.assertIn("model", fields, case["name"])
                    self.assertEqual(subject["modelToken"], drafted["modelToken"], case["name"])
                    self.assertEqual(kind, "model", case["name"])
                elif "equipmentType" in fields and "symptom" in fields:
                    self.assertEqual(subject, {"kind": "symptom",
                                               "equipmentType": fields["equipmentType"]["text"],
                                               "phrase": fields["symptom"]["text"]}, case["name"])
                else:
                    self.assertIsNone(subject, case["name"])

    def test_answers_the_rules_refuse(self):
        refusals = self.fixture["refusals"]
        self.assertEqual({r["refusal"]["kind"] for r in refusals}, REFUSAL_KINDS)
        cases = {case["name"]: case for case in self.fixture["cases"]}
        for refusal in refusals:
            case = cases[refusal["case"]]
            segment = case["segments"][refusal.get("segment", 0)]
            with self.assertRaises(Refused, msg=refusal["name"]) as caught:
                draft(case["transcript"], segment, refusal["answer"], case["duration"], self.types,
                      case["recordingID"])
            self.assertEqual((caught.exception.kind, caught.exception.field),
                             (refusal["refusal"]["kind"], refusal["refusal"].get("field")), refusal["name"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
