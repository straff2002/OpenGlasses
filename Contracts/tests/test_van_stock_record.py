#!/usr/bin/env python3
"""Check the work record's `van_stock` block against its fixture (Contracts/office-reports.md,
"Stock used from the van").

Standard library only, so it runs anywhere: `python3 -I Contracts/tests/test_van_stock_record.py`.
It reads `Contracts/fixtures/office-report-record-van-stock-v1.json` and asserts the shape a
reader relies on: every line states its scale, that scale is 3, no line carries the legacy
`quantity` member, units are on the closed list, and each/pack figures are whole units.

Since Plan MM P4 it also reads `Contracts/fixtures/office-report-record-van-stock-system-v1.json`:
lines noted for a business's own stock system carry `itemID`, `delivery` (one of the closed
states) and, for `not_sent` and `needs_attention`, a `deliveryReason` code; the record names the
system in `van_stock_system`. The members are additive: a phone-held line has none of them, and
the older fixture still passes unchanged.
"""
from pathlib import Path
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Contracts/fixtures/office-report-record-van-stock-v1.json"
SYSTEM_FIXTURE = ROOT / "Contracts/fixtures/office-report-record-van-stock-system-v1.json"
PLAIN = ROOT / "Contracts/fixtures/office-report-record-v1.json"

UNITS = {"each", "m", "ft", "kg", "lb", "l", "pack"}
WHOLE_UNITS = {"each", "pack"}
SCALE = 3
MAXIMUM_SCALED = 1_000_000 * 10 ** SCALE
KEYS = {"id", "number", "description", "unit", "quantityScaled", "quantityScale", "verified", "at"}
REQUIRED = KEYS - {"number"}
# Plan MM P4: a line noted for a business's own stock system.
SYSTEM_KEYS = {"itemID", "delivery", "deliveryReason"}
DELIVERY = {"staged", "queued", "sent", "not_sent", "needs_attention"}
NEEDS_REASON = {"not_sent", "needs_attention"}
CODE_CHARACTERS = set("abcdefghijklmnopqrstuvwxyz0123456789_")


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
    unknown = set(line) - KEYS - SYSTEM_KEYS - {"quantity"}
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
    found += system_problems(line)
    return found


def system_problems(line):
    """Why a reader must refuse a line's stock-system members, or an empty list. A line with none
    of them is a phone-held line and has nothing to check here."""
    found = []
    present = SYSTEM_KEYS & set(line)
    if not present:
        return found
    delivery = line.get("delivery")
    if delivery not in DELIVERY:
        found.append(f"delivery {delivery!r} is not one of {sorted(DELIVERY)}")
    item = line.get("itemID")
    if "itemID" in line and (not isinstance(item, str) or not item):
        found.append("itemID is not a non-empty string")
    reason = line.get("deliveryReason")
    if delivery in NEEDS_REASON:
        if not isinstance(reason, str) or not reason or not set(reason) <= CODE_CHARACTERS:
            found.append(f"{delivery} needs a deliveryReason code, not {reason!r}")
    elif "deliveryReason" in line:
        found.append(f"{delivery} carries a deliveryReason")
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


class VanStockSystemRecordTests(unittest.TestCase):
    """Plan MM P4: lines for a business's own stock system."""

    def setUp(self):
        with SYSTEM_FIXTURE.open(encoding="utf-8") as handle:
            self.record = json.load(handle, parse_float=lambda text: self.fail(f"a float in the record: {text}"))
        self.lines = self.record["van_stock"]

    def test_the_fixture_is_the_plain_record_plus_the_block_and_the_system(self):
        with PLAIN.open(encoding="utf-8") as handle:
            plain = json.load(handle)
        extended = dict(self.record)
        del extended["van_stock"]
        del extended["van_stock_system"]
        self.assertEqual(extended, plain)

    def test_the_system_is_named(self):
        system = self.record["van_stock_system"]
        self.assertEqual(set(system), {"connector", "name"})
        self.assertTrue(all(isinstance(value, str) and value for value in system.values()))

    def test_every_state_appears_and_every_line_is_accepted(self):
        self.assertEqual({line["delivery"] for line in self.lines}, DELIVERY)
        for line in self.lines:
            self.assertEqual(problems(line), [], line)

    def test_a_reason_goes_with_not_sent_and_needs_attention_only(self):
        for line in self.lines:
            self.assertEqual("deliveryReason" in line, line["delivery"] in NEEDS_REASON, line)

    def test_a_line_the_system_does_not_carry_has_no_item(self):
        not_carried = [line for line in self.lines if line.get("deliveryReason") == "not_carried"]
        self.assertEqual(len(not_carried), 1)
        self.assertNotIn("itemID", not_carried[0])

    def test_the_phone_held_fixture_has_no_system_members(self):
        with FIXTURE.open(encoding="utf-8") as handle:
            record = json.load(handle)
        self.assertNotIn("van_stock_system", record)
        for line in record["van_stock"]:
            self.assertEqual(SYSTEM_KEYS & set(line), set(), line)

    def test_a_reader_refuses_what_the_contract_refuses(self):
        sent = next(line for line in self.lines if line["delivery"] == "sent")
        kept = next(line for line in self.lines if line["delivery"] == "not_sent")
        refused = [
            {**sent, "delivery": "teleported"},
            {**sent, "delivery": None},
            {**sent, "deliveryReason": "not_carried"},
            {k: v for k, v in kept.items() if k != "deliveryReason"},
            {**kept, "deliveryReason": "Not In The Catalogue!"},
            {**sent, "itemID": ""},
            {**sent, "systemKey": "x"},
        ]
        for line in refused:
            self.assertNotEqual(problems(line), [], line)


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
