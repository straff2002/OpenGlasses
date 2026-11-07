#!/usr/bin/env python3
"""Keep every UI-test class in exactly one bounded accessibility audit group."""
import argparse
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
# Balanced using the last complete CI run: roughly 14 minutes of tests per group.
GROUPS = {
    "jobs": ["JobTabAccessibilityTests", "WorkizLightAccessibilityTests",
             "WorkizDarkAccessibilityTests", "WorkizLargestLightAccessibilityTests",
             "WorkizLargestDarkAccessibilityTests"],
    "signoff-settings": ["JobSignOffScreenshotTests", "SettingsAccessibilityTests",
                         "DynamicTypeAccessibilityTests"],
    "day-debrief": ["GoalsActivityAccessibilityTests", "JobDebriefScreenshotTests",
                    "FieldAssistModeUITests"],
    "conversation-setup": ["OnboardingAccessibilityTests", "SessionSurfaceAccessibilityTests",
                           "VaultLinkScreenshotTests", "AdaptiveWorkspaceUITests",
                           "ConversationPageTests", "RealtimeModelSetupUITests"],
}


def validate():
    # Every class with its superclass, so a suite that inherits from a shared case (which
    # itself inherits from AccessibilityAuditCase) is found too.
    declaration = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*(\w+)", re.MULTILINE)
    parents = {}
    for path in (ROOT / "OpenGlassesUITests").glob("*.swift"):
        parents.update(declaration.findall(path.read_text()))

    def is_test_case(name, seen=()):
        parent = parents.get(name)
        if parent in ("AccessibilityAuditCase", "XCTestCase"):
            return True
        return parent in parents and parent not in seen and is_test_case(parent, seen + (name,))

    test_cases = {name for name in parents if is_test_case(name)}
    # A shared case that other suites subclass holds no tests of its own: selecting it would
    # run nothing, so its subclasses are what get grouped.
    bases = {parents[name] for name in test_cases}
    discovered = test_cases - bases
    discovered.discard("AccessibilityAuditCase")
    assigned = collections.Counter(name for names in GROUPS.values() for name in names)
    missing = sorted(discovered - assigned.keys())
    unknown = sorted(assigned.keys() - discovered)
    duplicates = sorted(name for name, count in assigned.items() if count != 1)
    if missing or unknown or duplicates:
        raise ValueError(f"UI test grouping is incomplete: missing={missing}, unknown={unknown}, duplicates={duplicates}")
    return discovered


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--matrix", action="store_true")
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--group", choices=GROUPS)
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="Optional command after --; must start with xcodebuild")
    args = parser.parse_args()
    try:
        discovered = validate()
    except ValueError as error:
        parser.error(str(error))
    if args.matrix:
        print(json.dumps({"group": list(GROUPS)}))
    elif args.check:
        print(f"All {len(discovered)} UI-test classes assigned exactly once across {len(GROUPS)} groups.")
    else:
        selectors = ["-only-testing:OpenGlassesUITests/" + name for name in GROUPS[args.group]]
        command = args.command
        if command[:1] == ["--"]:
            command = command[1:]
        if not command:
            print(json.dumps(selectors))
            return 0
        if command[0] != "xcodebuild":
            parser.error("The group runner only accepts an xcodebuild command")
        return subprocess.call(command + selectors, cwd=ROOT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
