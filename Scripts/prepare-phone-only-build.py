#!/usr/bin/env python3
"""Derive phone-only metadata from the common plist; never maintain a stale copy."""
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


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


if __name__ == "__main__":
    source = plistlib.loads((ROOT / "OpenGlasses/Info.plist").read_bytes())
    destination = ROOT / ".generated/Info.phone-only.plist"
    destination.parent.mkdir(exist_ok=True)
    destination.write_bytes(plistlib.dumps(phone_info(source), sort_keys=False))
    print("Derived phone-only Info.plist from the common metadata.")
