"""Deterministic scorer for the KK P0 probes.

Classes: correct, wrong, outdated, hedged, declined, plus 'unplaced' for hand adjudication.
  - expected value present and nothing competing -> correct
  - expected + an outdated/lookalike value: a correction marker ("not", "instead of", "moved from",
    "changed from", "was ... now", "rather than", "corrected", "originally", "earlier") -> correct, but
    only when every competing value is the one set aside and the expected one is not ("212 psi, not
    221" is correct; "221 psi, not 212" is unplaced); an "or"/"either" between them -> hedged;
    otherwise unplaced
  - only an outdated value -> outdated; only a lookalike/wrong value -> wrong, unless it is named inside
    a decline ("I don't have the first reading; the only one is 198 psi") -> declined
  - a decline phrase and no expected value -> declined
  - anything else: a figure or code present -> wrong; no figure -> unplaced
Hand adjudications are read from adjudications.json
({"<run>|<fixture>|<arm>|<id>": {"class": ..., "answer": <answer_digest>}}). A call applies only to the
answer it was made on: a rerun under the same label writes new answers, and the old call is ignored.
"""
import hashlib, json, os, re, sys
from collections import Counter, defaultdict

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import fixture_spec as F
from textnorm import normalise

DECLINE = re.compile(r"don'?t have|do not have|couldn'?t find|could not find|can'?t find|cannot find|no record|"
                     r"don'?t see|do not see|isn'?t in|not in (our|my|the|this)|don'?t know|do not know|not sure|"
                     r"i'?m not able|can'?t see|lost track|no longer (have|see)|not available|can'?t recall|"
                     r"don'?t recall|didn'?t catch|did not catch|haven'?t (mentioned|told|said|got)|you haven'?t|"
                     r"not mentioned|wasn'?t mentioned|no mention|nothing (about|on|in)|don'?t have access|"
                     r"can'?t access|unable to|not able to|can you (tell|remind|check|read)|could you (tell|remind|check|read)|"
                     r"do you (have|know|remember)|what (was|is) it\?|let me know|if you (tell|give|read)|"
                     r"isn'?t (something|anything) i|no (saved|stored)|not (saved|stored|recorded)|"
                     r"left out|not included|aren'?t included|older messages|"
                     r"didn'?t (mention|say|give|record|note|tell)|did not (mention|say|give|record|note|tell)|"
                     r"can'?t (verify|confirm|retrieve|determine|identify)|couldn'?t (verify|confirm|retrieve)|"
                     r"cannot (verify|confirm|determine)")
CORRECTION = re.compile(r"\bnot\b|n't\b|instead of|moved from|changed from|rather than|correct|originally|original|"
                        r"earlier|previous|replac|supersed|misread|backwards|flipped|upside down|updated|"
                        r"\bwas\b.{0,40}\bnow\b|\bfrom\b.{0,30}\bto\b|no longer|old one|used to|after (you|they)|"
                        r"\brated\b|\brla\b|nameplate|in the van|van shelf|won'?t fit|target|spec|rear|later one|"
                        r"\bother\b|too late|too small|runs? out|\bmade\b|manufactur|return(ing)? (flight|leg)|"
                        r"coming back|\bcurrent|\bnow\b|\bset at\b|\bwas set\b|lights|outer|good ones?|"
                        r"barista|scarf|thriller|pale linen|cheaper|quote of|other quote|bill")
# A competing value set aside: a rejection cue shortly before it, or a reason shortly after it.
SET_ASIDE_BEFORE = re.compile(r"(\bnot\b|n't\b|rather than|instead of|\bother\b|original|previous|earlier|"
                              r"\bwas\b|\bwere\b|\bfrom\b|\bold\b|used to|currently|\bthan\b|no longer|"
                              r"replac|misread)[^.;]{0,40}$")
SET_ASIDE_AFTER = re.compile(r"^[^.;]{0,40}?(too late|too small|too short|runs? out|won'?t fit|was wrong|"
                             r"is wrong|no longer|was the old|replaced|superseded)")
# The expected value itself set aside: "not 212", "rather than the 212".
EXPECTED_SET_ASIDE = re.compile(r"(\bnot\b|n't\b|rather than|instead of|no longer)\s*(the\s+)?[^.;\s]{0,6}$")
HEDGE = re.compile(r"\bor\b|\beither\b|not sure (if|whether)|\bmaybe\b|\bpossibly\b")
FIGURE = re.compile(r"\d")


def spec_items():
    out = {}
    for fx in F.FIXTURES:
        for kind, rows in (("old", fx["details"]), ("control", fx["controls"])):
            for d in rows:
                out[(fx["id"], d[0])] = {"kind": kind, "expected": d[3], "outdated": d[4], "wrong": d[5],
                                         "question": d[2]}
    return out


SPEC = spec_items()


def present(patterns, text):
    return any(re.search(p, text) for p in patterns)


def spans(patterns, text):
    return [m.span() for p in patterns for m in re.finditer(p, text)]


def endorses_expected(s, t):
    """Whether an answer naming both values sets aside every competing one and not the expected one."""
    exp, comp = spans(s["expected"], t), spans(s["outdated"] + s["wrong"], t)
    # A value inside a longer one ("212" inside "2120") is the longer one's.
    exp = [e for e in exp if not any(c[0] <= e[0] and e[1] <= c[1] and c != e for c in comp)]
    comp = [c for c in comp if not any(e[0] <= c[0] and c[1] <= e[1] for e in exp)]
    if not exp or any(EXPECTED_SET_ASIDE.search(t[:a]) for a, _ in exp):
        return False
    return all(SET_ASIDE_BEFORE.search(t[max(0, a - 60):a]) or SET_ASIDE_AFTER.search(t[b:b + 60])
               for a, b in comp)


def answer_digest(answer):
    return hashlib.sha256((answer or "").encode()).hexdigest()[:16]


def classify(fid, did, answer):
    s = SPEC[(fid, did)]
    t = normalise(answer)
    exp = present(s["expected"], t)
    old = present(s["outdated"], t)
    wrong = present(s["wrong"], t)
    if exp and not old and not wrong:
        return "correct", "expected only"
    if exp and (old or wrong):
        if DECLINE.search(t) and re.search(r"\bwhether\b|\bwhich\b", t):
            return "declined", "both echoed inside a decline"
        if CORRECTION.search(t):
            if HEDGE.search(t) and not re.search(r"\bnot\b|n't\b|instead|rather|moved|changed|now", t):
                return "hedged", "both, or-without-correction"
            if endorses_expected(s, t):
                return "correct", "both, correction marker"
            return "unplaced", "both, correction marker, direction unclear"
        if HEDGE.search(t):
            return "hedged", "both, or"
        return "unplaced", "both, no marker"
    if old:
        return "outdated", "outdated only"
    if wrong:
        if DECLINE.search(t):
            return "declined", "lookalike named inside a decline"
        return "wrong", "lookalike only"
    if DECLINE.search(t) or not t.strip():
        return "declined", "decline phrase" if t.strip() else "empty answer"
    if FIGURE.search(t):
        return "wrong", "other figure"
    return "unplaced", "no figure"


def load_adjudications():
    p = os.path.join(BASE, "adjudications.json")
    return json.load(open(p)) if os.path.exists(p) else {}


def score_file(path, adjud=None):
    adjud = adjud if adjud is not None else load_adjudications()
    rows = []
    for line in open(path):
        r = json.loads(line)
        cls, why = classify(r["fixture"], r["id"], r.get("answer", ""))
        key = f"{r['run']}|{r['fixture']}|{r['arm']}|{r['id']}"
        call = adjud.get(key)
        if isinstance(call, dict) and call.get("answer") == answer_digest(r.get("answer", "")):
            cls, why = call["class"], "hand"
        r["class"], r["why"] = cls, why
        r["kind"] = SPEC[(r["fixture"], r["id"])]["kind"]
        rows.append(r)
    return rows


if __name__ == "__main__":
    for path in sys.argv[1:]:
        rows = score_file(path)
        c = defaultdict(Counter)
        for r in rows:
            c[r["kind"]][r["class"]] += 1
        print(os.path.basename(path), {k: dict(v) for k, v in c.items()})
