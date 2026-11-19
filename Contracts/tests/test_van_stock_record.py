#!/usr/bin/env python3
"""Check the work record's `van_stock` block against its fixture (Contracts/office-reports.md,
"Stock used from the van").

Standard library only, so it runs anywhere: `python3 -I Contracts/tests/test_van_stock_record.py`.
It reads `Contracts/fixtures/office-report-record-van-stock-v1.json` and asserts the shape a
reader relies on: every line states its scale, that scale is 3, no line carries the legacy
`quantity` member, units are on the closed list, and each/pack figures are whole units.
"""
from pathlib import Path
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Contracts/fixtures/office-report-record-van-stock-v1.json"
PLAIN = ROOT / "Contracts/fixtures/office-report-record-v1.json"

UNITS = {"each", "m", "ft", "kg", "lb", "l", "pack"}
WHOLE_UNITS = {"each", "pack"}
SCALE = 3
MAXIMUM_SCALED = 1_000_000 * 10 ** SCALE
KEYS = {"id", "number", "description", "unit", "quantityScaled", "quantityScale", "verified", "at"}
REQUIRED = KEYS - {"number"}


def is_integer(value):
    """A JSON integer: not a boolean, not a float."""
    return isinstance(value, int) and not isinstance(value, bool)


def problems(line):
    """Why a reader must refuse this line, or an empty list."""
    found = []
    if "quantity" in line:
        found.append("carries the legacy `quantity` member")
    missing = REQUIRED - set(line)
    if missing:
        found.append(f"lacks {sorted(missing)}")
    unknown = set(line) - KEYS - {"quantity"}
    if unknown:
        found.append(f"has members this check does not know: {sorted(unknown)}")
    scale = line.get("quantityScale")
    if not is_integer(scale) or scale != SCALE:
        found.append(f"quantityScale is {scale!r}, not {SCALE}")
    unit = line.get("unit")
    if unit not in UNITS:
        found.append(f"unit {unit!r} is not on the closed list")
    scaled = line.get("quantityScaled")
    if not is_integer(scaled) or not 0 <= scaled <= MAXIMUM_SCALED:
        found.append(f"quantityScaled {scaled!r} is not an integer in 0…{MAXIMUM_SCALED}")
    elif unit in WHOLE_UNITS and scaled % 10 ** SCALE != 0:
        found.append(f"{unit} is counted whole, and {scaled} thousandths is not")
    return found


class VanStockRecordTests(unittest.TestCase):

    def setUp(self):
        with FIXTURE.open(encoding="utf-8") as handle:
            self.record = json.load(handle, parse_float=lambda text: self.fail(f"a float in the record: {text}"))
        self.lines = self.record["van_stock"]

    def test_the_fixture_is_the_plain_record_plus_the_block(self):
        with PLAIN.open(encoding="utf-8") as handle:
            plain = json.load(handle)
        extended = dict(self.record)
        del extended["van_stock"]
        self.assertEqual(extended, plain)

    def test_it_holds_an_each_line_and_a_litre_line(self):
        self.assertEqual([(line["unit"], line["quantityScaled"]) for line in self.lines],
                         [("each", 2000), ("l", 4250)])

    def test_no_line_carries_a_quantity_member(self):
        for line in self.lines:
            self.assertNotIn("quantity", line)

    def test_every_line_is_at_scale_three(self):
        for line in self.lines:
            self.assertTrue(is_integer(line["quantityScale"]))
            self.assertEqual(line["quantityScale"], SCALE)

    def test_units_are_on_the_closed_list_and_each_and_pack_are_whole(self):
        for line in self.lines:
            self.assertIn(line["unit"], UNITS)
            if line["unit"] in WHOLE_UNITS:
                self.assertEqual(line["quantityScaled"] % 1000, 0, line)

    def test_every_fixture_line_is_accepted(self):
        for line in self.lines:
            self.assertEqual(problems(line), [], line)

    def test_a_reader_refuses_what_the_contract_refuses(self):
        good = self.lines[1]
        refused = [
            {**good, "quantityScale": 4},
            {k: v for k, v in good.items() if k != "quantityScale"},
            {**{k: v for k, v in good.items() if k not in ("quantityScaled", "quantityScale")}, "quantity": 4},
            {**good, "quantity": 4250},
            {**good, "unit": "qt"},
            {**self.lines[0], "quantityScaled": 2500},
            {**good, "quantityScaled": -1},
            {**good, "quantityScaled": True},
        ]
        for line in refused:
            self.assertNotEqual(problems(line), [], line)


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
