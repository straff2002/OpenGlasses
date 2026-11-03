"""Text normalisation shared by the fixture validator and the scorer."""
import re

UNITS = {"zero": 0, "oh": None, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
         "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
         "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19}
TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
        "ninety": 90}
ORD = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
       "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
       "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
       "twentieth": 20}
UNITS.pop("oh")
WORDS = set(UNITS) | set(TENS) | {"hundred", "thousand"}
_word_re = re.compile(r"[a-z]+|-|\s+|[^a-z\s-]+")


def _parse_run(tokens):
    """tokens: number words (no separators). Returns the digits, with separate numbers kept apart:
    'seven forty five' -> '7 45', 'two hundred twelve' -> '212'."""
    numbers = []
    total, current, last = 0, 0, None
    def flush():
        nonlocal total, current
        if total or current or last is not None:
            numbers.append(total + current)
        total, current = 0, 0
    for t in tokens:
        if t in UNITS:
            if last in UNITS or (last in TENS and False) or (current % 100 >= 10 and current % 100 < 20 and last not in ("hundred", "thousand")) or (last in TENS and current % 10 != 0):
                flush()
            current += UNITS[t]
        elif t in TENS:
            if last is not None and last not in ("hundred", "thousand"):
                flush()
            current += TENS[t]
        elif t == "hundred":
            current = max(current, 1) * 100
        elif t == "thousand":
            total += max(current, 1) * 1000
            current = 0
        last = t
    numbers.append(total + current)
    return " ".join(str(n) for n in numbers)


def words_to_digits(text):
    """'thirty-eight psi' -> '38 psi'; 'four point five' -> '4.5'; 'one and a half' -> '1.5';
    'two hundred and twelve' -> '212'; 'fourteenth' -> '14th'. Lowercase input expected."""
    text = re.sub(r"\b(one|1) and a half\b", "1.5", text)
    text = re.sub(r"\b(two|2) and a half\b", "2.5", text)
    text = re.sub(r"\bhalf\b(?= (a )?turn)", "0.5", text)
    out = []
    pos = 0
    pattern = re.compile(r"\b(?:(?:%s)(?:[\s-]+(?:and[\s-]+)?(?=(?:%s)\b))?)+\b" % (
        "|".join(sorted(WORDS, key=len, reverse=True)), "|".join(sorted(WORDS, key=len, reverse=True))))
    for m in pattern.finditer(text):
        run = m.group(0)
        toks = [t for t in re.split(r"[\s-]+", run) if t and t != "and"]
        if not toks:
            continue
        out.append(text[pos:m.start()])
        out.append(_parse_run(toks))
        pos = m.end()
    out.append(text[pos:])
    text = "".join(out)
    # "4 point 5" -> "4.5" (digits after point may be several single digits)
    text = re.sub(r"(\d+) point (\d(?: \d)*)\b", lambda m: m.group(1) + "." + m.group(2).replace(" ", ""), text)
    for w, n in ORD.items():
        text = re.sub(r"\b%s\b" % w, "%dth" % n, text)
    return text


def normalise(text):
    t = (text or "").lower()
    for a, b in (("−", "-"), ("–", "-"), ("—", "-"), ("‑", "-"), ("‐", "-"),
                 ("’", "'"), ("‘", "'"), ("µ", "u"), ("μ", "u"), ("°", " deg "),
                 (" ", " "), (" ", " "), ("×", "x")):
        t = t.replace(a, b)
    t = re.sub(r"(\d)\s?\u00bd", r"\1.5", t).replace("\u00bd", "0.5")
    t = words_to_digits(t)
    t = re.sub(r"(?<=\d),(?=\d{3}\b)", "", t)
    t = re.sub(r"\s+", " ", t)
    return t
