#!/usr/bin/env python3
"""Fail closed on a phone-only .app or .xcarchive containing glasses integration.

Run against the actual archive before uploading, not just generated project settings.
This checks dependency load commands as well as Swift symbols, including statically linked SDKs,
and the text in every Mach-O and compiled string table. It never changes an artifact.
"""
import argparse
import json
import mmap
import plistlib
import re
import subprocess
from pathlib import Path

SDK = re.compile(r"MWDAT(?:Core|Camera|Display|MockDevice)|MetaWearablesDAT")
SYMBOL = re.compile(r"(?:\$s|\$S)(?:9MWDATCore|11MWDATCamera|12MWDATDisplay|15MWDATMockDevice)")
# Product and company text. The bare word "Meta" is allowed because it means "goal" in several
# translations and is a device kind in llama.cpp, so only a phrase counts. Boundaries are ASCII so
# that a phrase next to CJK text still matches. "Oakley-EC2N" is a key-exchange group in WebRTC, and
# "oakley" before "parallax" is an unrelated entry in MediaPipe's internal list of graph names.
BANNED = (r"(?i:\bmeta\.com\b|\bray[- ]?ban|\boakley\b(?!-ec2n|\x00parallax)|neural band|fb-viewapp|mwdat)"
          r"|\bMeta(?:(?:'|’)s\b| (?:AI|[Gg]lasses|SDK|app)\b| ?Wearables| / Facebook)")
BANNED_TEXT = re.compile(BANNED, re.ASCII)
BANNED_BYTES = re.compile(BANNED.encode("utf-8"))
# In the app's own catalogs the bare word counts as well, outside the entries that mean something
# else by it ("Goal" is "Meta" in Spanish and Portuguese).
BARE_COMPANY = re.compile(r"\bMeta\b", re.ASCII)
UNRELATED_CATALOG_KEYS = {"Goal", "Meta Agent"}
COMPILED_STRINGS = {".strings", ".stringsdict", ".loctable"}
MACH_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def metadata_errors(info):
    errors = []
    if info.get("AvenkinBuildVariant") != "phone-only":
        errors.append("AvenkinBuildVariant is not phone-only")
    for key in ("MWDAT", "UISupportedExternalAccessoryProtocols", "NSBluetoothAlwaysUsageDescription",
                "NSBluetoothPeripheralUsageDescription"):
        if key in info:
            errors.append(f"Unexpected hardware metadata: {key}")
    if set(info.get("UIBackgroundModes", [])) & {"external-accessory", "bluetooth-central", "bluetooth-peripheral"}:
        errors.append("Unexpected glasses background modes")
    if "fb-viewapp" in info.get("LSApplicationQueriesSchemes", []):
        errors.append("Unexpected Meta companion query scheme")
    for entry in info.get("CFBundleURLTypes", []):
        if any(scheme.startswith("mwdat-") for scheme in entry.get("CFBundleURLSchemes", [])):
            errors.append("Unexpected Meta callback scheme")
    return errors


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout


def intent_metadata_errors(metadata):
    errors = []
    actions = metadata.get("actions")
    if not isinstance(actions, dict):
        return ["App Intents action metadata is missing or unreadable"]
    forbidden = {"CaptureGlassesPhotoIntent", "RecordGlassesVideoIntent", "DisconnectGlassesIntent",
                 "StartGlassesCaptureIntent", "StopGlassesCaptureIntent"}
    for name in sorted(forbidden.intersection(actions)):
        errors.append(f"Unsupported hardware intent published: {name}")
    for shortcut in metadata.get("autoShortcuts", []):
        if shortcut.get("actionIdentifier") == "ConnectGlassesIntent":
            if "glasses" in shortcut.get("shortTitle", {}).get("key", "").lower() or shortcut.get("systemImageName") == "eyeglasses":
                errors.append("Phone listening shortcut still advertises glasses")
    return errors


def banned_terms(text):
    return sorted({match.group() for match in BANNED_TEXT.finditer(text)})


def catalog_entry_terms(key, value):
    """Banned text in one catalog entry: its key and every translation or plural form of it."""
    texts = [key, *plist_texts(value)]
    terms = {term for text in texts for term in banned_terms(text)}
    if key not in UNRELATED_CATALOG_KEYS:
        terms.update(match.group() for text in texts for match in BARE_COMPANY.finditer(text))
    return sorted(terms)


def binary_terms(path):
    """Reads the file itself, not `strings`, which cuts a run at the first non-ASCII character."""
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        return sorted({match.group().decode("utf-8", "replace") for match in BANNED_BYTES.finditer(data)})


def plist_texts(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from plist_texts(item)
    elif isinstance(value, list):
        for item in value:
            yield from plist_texts(item)


def compiled_strings_terms(path):
    """Parsed, not searched: a binary plist keeps any string with a non-ASCII character as UTF-16."""
    data = path.read_bytes()
    try:
        content = plistlib.loads(data)
    except plistlib.InvalidFileException:
        content = data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", "replace")
    if isinstance(content, dict):
        return sorted({term for key, value in content.items() for term in catalog_entry_terms(key, value)})
    return sorted({term for text in plist_texts(content) for term in banned_terms(text)})


def banned_text_error(path, root, terms):
    return f"Banned text in {path.relative_to(root)}: {', '.join(terms)}"


def is_test_bundle_content(path, root):
    """Test fixtures name real hardware on purpose, and a test bundle never reaches an archive."""
    return any(part.endswith(".xctest") for part in path.relative_to(root).parts)


def check(path, require_signed=False):
    if path.suffix == ".xcarchive":
        apps = list((path / "Products/Applications").glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError("Archive must contain exactly one application")
        path = apps[0]
    if path.suffix != ".app" or not path.is_dir():
        raise RuntimeError("Expected an existing .app or .xcarchive")
    info = plistlib.loads((path / "Info.plist").read_bytes())
    errors = metadata_errors(info)
    intent_metadata = path / "Metadata.appintents/extract.actionsdata"
    if intent_metadata.is_file():
        errors.extend(intent_metadata_errors(json.loads(intent_metadata.read_bytes())))
    else:
        errors.append("App Intents metadata missing; discovery surfaces could not be checked")
    executable = path / info.get("CFBundleExecutable", "")
    if not executable.is_file():
        errors.append("Application executable missing")
    binaries = []
    string_tables = 0
    for item in path.rglob("*"):
        if SDK.search(item.name):
            errors.append(f"Embedded SDK resource: {item.relative_to(path)}")
        if not item.is_file():
            continue
        if item.suffix in COMPILED_STRINGS:
            string_tables += 1
            terms = compiled_strings_terms(item)
            if terms:
                errors.append(banned_text_error(item, path, terms))
            continue
        with item.open("rb") as stream:
            magic = stream.read(4)
        if magic not in MACH_MAGICS:
            continue
        binaries.append(item)
        loaded = run("xcrun", "otool", "-L", str(item))
        symbols = run("xcrun", "nm", "-j", str(item))
        if SDK.search(loaded) or SYMBOL.search(symbols):
            errors.append(f"SDK linked into {item.relative_to(path)}")
        if not is_test_bundle_content(item, path):
            terms = binary_terms(item)
            if terms:
                errors.append(banned_text_error(item, path, terms))
    if not binaries:
        errors.append("No Mach-O binaries found; no dependency inspection was possible")
    if not string_tables:
        errors.append("No compiled string tables found; localized text could not be checked")
    signature = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)], capture_output=True)
    if signature.returncode == 0 and signature.stdout.strip():
        entitlements = plistlib.loads(signature.stdout)
        for key in ("com.apple.developer.networking.HotspotConfiguration", "com.apple.developer.networking.wifi-info"):
            if entitlements.get(key):
                errors.append(f"Unexpected glasses entitlement: {key}")
    elif require_signed:
        errors.append("No signed entitlements found; use a distribution-signed archive")
    else:
        print("Unsigned artifact: signed entitlements were not verified.")
    return errors, len(binaries)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--require-signed", action="store_true", help="Required for the final distribution archive")
    args = parser.parse_args()
    try:
        errors, inspected = check(args.artifact, args.require_signed)
    except (OSError, RuntimeError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Artifact inspection failed: {error}\n")
    if errors:
        parser.exit(1, "Phone-only artifact rejected:\n" + "\n".join(f"- {error}" for error in errors) + "\n")
    print(f"Phone-only artifact passed: metadata and {inspected} Mach-O binaries checked.")
