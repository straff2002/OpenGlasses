#!/usr/bin/env python3
"""Keeps the extension targets' own string catalogs in step with the app's.

    python3 -I Scripts/sync-extension-catalogs.py            rewrite them from the app's catalog
    python3 -I Scripts/sync-extension-catalogs.py --check    report what would change, write nothing

Each extension (the Home Screen widget and Live Activity, the watch app and the watch widget) runs
in its own bundle, and `String(localized:)` and `Text("…")` look there, not in the app's bundle. So
each one carries a small `Localizable.xcstrings` with just the keys it shows. The app's catalog,
OpenGlasses/Sources/Resources/Localizable.xcstrings, is still the one place translations are made,
and this script copies each key's entry from it, minus `extractionState`, which is per catalog.

Which keys a catalog holds is the catalog's own business. Xcode adds them when it extracts the
target's strings. Headless, run `xcrun xcstringstool sync <target>/Localizable.xcstrings
--skip-marking-strings-stale --stringsdata …` with that target's `.stringsdata`, then this script.
A key the app's catalog lacks is reported (exit 1): sync the app's strings first.
ExtensionCatalogGuardTests fails when a catalog has drifted from the app's.

Keys keep the app catalog's order, which is Xcode's, and the file is written in Xcode's format by
translation-review.py's writer, so opening it in Xcode reorders nothing.
"""

import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "OpenGlasses/Sources/Resources/Localizable.xcstrings"
EXTENSION_CATALOGS = (
    "GlassesActivityWidget/Localizable.xcstrings",
    "OpenGlassesWatch/Localizable.xcstrings",
    "OpenGlassesWatchWidget/Localizable.xcstrings",
)


def writer():
    """translation-review.py owns the Xcode-format writer; using it keeps the two from drifting."""
    spec = importlib.util.spec_from_file_location("translation_review", ROOT / "Scripts/translation-review.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.dump_catalog


def refreshed(app, current):
    """`current` with every entry copied from `app`, in `app`'s order; and the keys `app` lacks."""
    wanted = current.get("strings", {})
    strings = {}
    for key, entry in app["strings"].items():
        if key in wanted:
            strings[key] = {name: value for name, value in entry.items() if name != "extractionState"}
    missing = [key for key in wanted if key not in app["strings"]]
    for key in missing:
        strings[key] = wanted[key]
    return {name: (strings if name == "strings" else value) for name, value in app.items()}, missing


def main(check):
    dump = writer()
    app = json.loads(CATALOG.read_bytes())
    failed = False
    for path in EXTENSION_CATALOGS:
        target = ROOT / path
        current = target.read_bytes()
        catalog, missing = refreshed(app, json.loads(current))
        for key in missing:
            print(f"{path}: {key!r} is not in the app's catalog; sync the app's strings first")
        failed = failed or bool(missing)
        text = dump(catalog)
        count = len(catalog["strings"])
        if text == current:
            print(f"{path}: up to date ({count} keys)")
        elif check:
            print(f"{path}: out of date ({count} keys)")
            failed = True
        else:
            target.write_bytes(text)
            print(f"{path}: wrote {count} keys")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main("--check" in sys.argv[1:]))
