#!/usr/bin/env python3
"""Derive phone-only metadata and catalogs from the common files; never maintain a stale copy."""
import importlib.util
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = ("Localizable.xcstrings", "InfoPlist.xcstrings")


def artifact_check():
    """The artifact check owns the banned-text rule, so the filter and the check cannot disagree."""
    spec = importlib.util.spec_from_file_location("check_phone_only", ROOT / "Scripts/check-phone-only-artifact.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def phone_info(info):
    info = dict(info)
    for key in ("MWDAT", "UISupportedExternalAccessoryProtocols",
                "NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"):
        info.pop(key, None)
    info["UIBackgroundModes"] = [value for value in info.get("UIBackgroundModes", [])
                                 if value not in ("external-accessory", "bluetooth-central", "bluetooth-peripheral")]
    info["LSApplicationQueriesSchemes"] = [value for value in info.get("LSApplicationQueriesSchemes", [])
                                          if value != "fb-viewapp"]
    url_types = []
    for entry in info.get("CFBundleURLTypes", []):
        entry = dict(entry)
        entry["CFBundleURLSchemes"] = [value for value in entry.get("CFBundleURLSchemes", [])
                                       if not value.startswith("mwdat-")]
        if entry["CFBundleURLSchemes"]:
            url_types.append(entry)
    info["CFBundleURLTypes"] = url_types
    info["AvenkinBuildVariant"] = "phone-only"
    return info


def phone_catalog(catalog, check=None):
    """Drops every entry that carries banned text in its key or in any translation."""
    check = check or artifact_check()
    kept = {key: entry for key, entry in catalog["strings"].items()
            if not check.catalog_entry_terms(key, entry.get("localizations", {}))}
    return dict(catalog, strings=kept)


if __name__ == "__main__":
    source = plistlib.loads((ROOT / "OpenGlasses/Info.plist").read_bytes())
    destination = ROOT / ".generated/Info.phone-only.plist"
    destination.parent.mkdir(exist_ok=True)
    destination.write_bytes(plistlib.dumps(phone_info(source), sort_keys=False))
    print("Derived phone-only Info.plist from the common metadata.")
    check = artifact_check()
    for name in CATALOGS:
        catalog = json.loads((ROOT / "OpenGlasses/Sources/Resources" / name).read_text(encoding="utf-8"))
        phone = phone_catalog(catalog, check)
        (destination.parent / name).write_text(json.dumps(phone, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Derived phone-only {name}: dropped {len(catalog['strings']) - len(phone['strings'])} entries.")
