import importlib.util
import json
import plistlib
import re
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


prepare = module("prepare_phone_only", "prepare-phone-only-build.py")
check = module("check_phone_only", "check-phone-only-artifact.py")


class PhoneOnlyBuildTests(unittest.TestCase):
    def setUp(self):
        self.common = plistlib.loads((ROOT / "OpenGlasses/Info.plist").read_bytes())

    def test_common_metadata_is_not_mutated_and_phone_fields_are_preserved(self):
        before = plistlib.dumps(self.common)
        phone = prepare.phone_info(self.common)
        self.assertEqual(plistlib.dumps(self.common), before)
        for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSHealthShareUsageDescription",
                    "NSLocalNetworkUsageDescription", "CFBundleVersion", "CFBundleShortVersionString"):
            self.assertEqual(phone.get(key), self.common.get(key), key)
        self.assertIn("audio", phone["UIBackgroundModes"])
        self.assertEqual(check.metadata_errors(phone), [])

    def test_real_beta_metadata_would_be_rejected(self):
        errors = check.metadata_errors(self.common)
        self.assertTrue(any("AvenkinBuildVariant" in error for error in errors))
        self.assertTrue(any("MWDAT" in error for error in errors))

    def test_reintroduced_hardware_metadata_is_detected(self):
        for key, value in (("MWDAT", {}), ("NSBluetoothAlwaysUsageDescription", "Bluetooth"),
                           ("UIBackgroundModes", ["audio", "external-accessory"]),
                           ("CFBundleURLTypes", [{"CFBundleURLSchemes": ["mwdat-123"]}])):
            phone = prepare.phone_info(self.common)
            phone[key] = value
            self.assertTrue(check.metadata_errors(phone), key)

    def test_derivation_is_idempotent(self):
        phone = prepare.phone_info(self.common)
        self.assertEqual(prepare.phone_info(phone), phone)

    def test_published_shortcuts_cannot_advertise_unsupported_hardware(self):
        self.assertTrue(check.intent_metadata_errors({"actions": {"StartGlassesCaptureIntent": {}}}))
        self.assertTrue(check.intent_metadata_errors({"actions": {}, "autoShortcuts": [
            {"actionIdentifier": "ConnectGlassesIntent", "shortTitle": {"key": "Connect Glasses"}, "systemImageName": "eyeglasses"}]}))
        self.assertEqual(check.intent_metadata_errors({"actions": {"TakePhotoIntent": {}}, "autoShortcuts": [
            {"actionIdentifier": "ConnectGlassesIntent", "shortTitle": {"key": "Start Listening"}, "systemImageName": "mic"}]}), [])


class BannedTextTests(unittest.TestCase):
    def test_every_banned_form_is_found(self):
        for text in ("https://api2.ar.meta.com/mwsdk/telemetry", "developers.meta.com", "Open the Meta AI app",
                     "your Meta glasses", "Meta Glasses", "the Meta Wearables SDK", "MetaWearablesDAT.log",
                     "Meta's release channel", "Meta\u2019s release channel", "Meta SDK unavailable", "open Meta app",
                     "Meta / Facebook Calls", "Ray-Ban Display", "ray-ban", "Hey Rayban", "hey ray ban", "Oakley Vanguard",
                     "oakley", "the Neural Band", "fb-viewapp", "mwdat-1234", "MWDAT", "在Meta AI中"):
            self.assertTrue(check.banned_terms(text), text)
            self.assertTrue(check.BANNED_BYTES.search(text.encode("utf-8")), text)

    def test_unrelated_meanings_are_left_alone(self):
        for text in ("metadata", "Metadata", "Metal", "metal.default", "<meta charset=\"utf-8\">", "meta-commentary",
                     "mlx-community/Meta-Llama-3-8B-Instruct-4bit", "creating a Meta device", "Meta", "Meta Agent",
                     "Oakley-EC2N-3", "OAKLEY-EC2N-4", "arrayBan", "13raybanDisplay", "metaRayBan"):
            self.assertEqual(check.banned_terms(text), [], text)
            self.assertIsNone(check.BANNED_BYTES.search(text.encode("utf-8")), text)

    def test_the_bare_company_name_counts_only_in_the_apps_catalogs(self):
        self.assertEqual(check.catalog_entry_terms("Uploads go to Meta.", {}), ["Meta"])
        self.assertEqual(check.catalog_entry_terms("Uploads", {"de": {"stringUnit": {"value": "An Meta"}}}), ["Meta"])
        self.assertEqual(check.catalog_entry_terms("Goal", {"es": {"stringUnit": {"value": "Meta"}}}), [])
        self.assertEqual(check.catalog_entry_terms("Meta Agent", {"es": {"stringUnit": {"value": "Agente Meta"}}}), [])

    def test_a_binary_is_searched_past_non_ascii_text(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "OpenGlasses.debug.dylib"
            binary.write_bytes(b"\xcf\xfa\xed\xfe\x00" + "Update — Meta AI — now".encode("utf-8") + b"\x00MWDATCore\x00")
            self.assertEqual(check.binary_terms(binary), ["MWDAT", "Meta AI"])
            binary.write_bytes(b"\xcf\xfa\xed\xfe\x00metadata\x00Metal\x00")
            self.assertEqual(check.binary_terms(binary), [])

    def test_compiled_strings_are_parsed_in_every_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            table = Path(directory) / "Localizable.strings"
            # A non-ASCII value makes a binary plist store it as UTF-16, which a byte search misses.
            for content in (plistlib.dumps({"Connect": "Öffne die Meta AI-App"}, fmt=plistlib.FMT_BINARY),
                            plistlib.dumps({"Connect": "Open the Meta AI app"}, fmt=plistlib.FMT_XML),
                            '"Connect" = "Öffne die Meta AI-App";'.encode("utf-16"),
                            '"Connect" = "Open the Meta AI app";'.encode("utf-8")):
                table.write_bytes(content)
                self.assertIn("Meta AI", check.compiled_strings_terms(table))
            table.write_bytes(plistlib.dumps({"Goal": "Meta", "Metadata": "Métadonnées"}, fmt=plistlib.FMT_BINARY))
            self.assertEqual(check.compiled_strings_terms(table), [])


class PhoneCatalogTests(unittest.TestCase):
    @staticmethod
    def entry(value):
        return {"localizations": {"es": {"stringUnit": {"state": "translated", "value": value}}}}

    def test_entries_are_dropped_by_key_or_by_any_translation(self):
        catalog = {"sourceLanguage": "en", "version": "1.1", "strings": {
            "Connect to Meta AI": self.entry("Conectar"),
            "Connect": self.entry("Conectar a Meta AI"),
            "Files": {"localizations": {"es": {"variations": {"plural": {
                "one": {"stringUnit": {"value": "Archivo"}}, "other": {"stringUnit": {"value": "Ray-Ban"}}}}}}},
            "Goal": self.entry("Meta"),
            "Save": self.entry("Guardar"),
            "Untranslated": {}}}
        phone = prepare.phone_catalog(catalog, check)
        self.assertEqual(sorted(phone["strings"]), ["Goal", "Save", "Untranslated"])
        self.assertEqual((phone["sourceLanguage"], phone["version"]), ("en", "1.1"))
        self.assertEqual(len(catalog["strings"]), 6, "the source catalog is not mutated")

    def test_the_real_catalogs_filter_clean_and_keep_the_rest(self):
        for name in prepare.CATALOGS:
            catalog = json.loads((ROOT / "OpenGlasses/Sources/Resources" / name).read_text(encoding="utf-8"))
            phone = prepare.phone_catalog(catalog, check)
            self.assertLess(len(phone["strings"]), len(catalog["strings"]), name)
            self.assertGreater(len(phone["strings"]), 15, name)
            for key, entry in phone["strings"].items():
                self.assertEqual(check.catalog_entry_terms(key, entry.get("localizations", {})), [], key)


class PhoneProjectTests(unittest.TestCase):
    @staticmethod
    def source_paths(spec, key):
        """The target's source paths, read by indentation: the standard library has no YAML parser."""
        lines = spec.splitlines()
        start = next(index for index, line in enumerate(lines) if line.strip() == key)
        indent = len(lines[start]) - len(lines[start].lstrip())
        paths = []
        for line in lines[start + 1:]:
            depth = len(line) - len(line.lstrip())
            if line.strip() and not line.strip().startswith("#") and depth <= indent:
                break
            match = re.fullmatch(r"\s*- path: (\S+)", line)
            if match and depth == indent + 2:
                paths.append(match.group(1))
        return paths

    def test_the_phone_overlay_restates_the_base_sources_and_swaps_the_catalogs(self):
        base = self.source_paths((ROOT / "project.base.yml").read_text(encoding="utf-8"), "sources:")
        overlay = (ROOT / "project.phone-only.yml").read_text(encoding="utf-8")
        generated = [f".generated/{name}" for name in prepare.CATALOGS]
        self.assertEqual(self.source_paths(overlay, "sources:REPLACE:"), base + generated)
        for name in prepare.CATALOGS:
            self.assertIn(f'- "Resources/{name}"', overlay)
        self.assertIn('SWIFT_EMIT_LOC_STRINGS: "NO"', overlay)


class ArtifactTextTests(unittest.TestCase):
    def inspected(self, build):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Avenkin.app"
            (app / "Metadata.appintents").mkdir(parents=True)
            (app / "en.lproj").mkdir()
            info = {"AvenkinBuildVariant": "phone-only", "CFBundleExecutable": "OpenGlasses"}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "Metadata.appintents/extract.actionsdata").write_text('{"actions": {}}')
            (app / "OpenGlasses").write_bytes(b"\xcf\xfa\xed\xfe\x00")
            (app / "OpenGlasses.debug.dylib").write_bytes(b"\xcf\xfa\xed\xfe\x00metadata\x00")
            (app / "en.lproj/Localizable.strings").write_bytes(plistlib.dumps({"Save": "Save"}, fmt=plistlib.FMT_BINARY))
            build(app)
            unsigned = types.SimpleNamespace(returncode=1, stdout=b"")
            with mock.patch.object(check, "run", return_value=""), mock.patch.object(check.subprocess, "run", return_value=unsigned), \
                    mock.patch("builtins.print"):
                return check.check(app)[0]

    def test_a_clean_artifact_passes(self):
        self.assertEqual(self.inspected(lambda app: None), [])

    def test_a_failure_names_the_file_and_the_term(self):
        def debug_binary(app):
            (app / "OpenGlasses.debug.dylib").write_bytes(b"\xcf\xfa\xed\xfe\x00api2.ar.meta.com\x00")
        self.assertEqual(self.inspected(debug_binary), ["Banned text in OpenGlasses.debug.dylib: meta.com"])

        def extension(app):
            plugin = app / "PlugIns/Share.appex"
            plugin.mkdir(parents=True)
            (plugin / "Share").write_bytes(b"\xcf\xfa\xed\xfe\x00Neural Band\x00")
        self.assertEqual(self.inspected(extension), ["Banned text in PlugIns/Share.appex/Share: Neural Band"])

        def strings_table(app):
            (app / "de.lproj").mkdir()
            (app / "de.lproj/InfoPlist.strings").write_bytes(plistlib.dumps({"NSUsage": "Für Ray-Ban Brillen"}, fmt=plistlib.FMT_BINARY))
        self.assertEqual(self.inspected(strings_table), ["Banned text in de.lproj/InfoPlist.strings: Ray-Ban"])

    def test_missing_string_tables_fail_closed(self):
        errors = self.inspected(lambda app: (app / "en.lproj/Localizable.strings").unlink())
        self.assertEqual(errors, ["No compiled string tables found; localized text could not be checked"])

    def test_a_test_bundles_fixtures_are_not_product_text(self):
        def test_bundle(app):
            plugin = app / "PlugIns/OpenGlassesTests.xctest"
            plugin.mkdir(parents=True)
            (plugin / "OpenGlassesTests").write_bytes(b"\xcf\xfa\xed\xfe\x00Ray-Ban Meta\x00")
        self.assertEqual(self.inspected(test_bundle), [])


if __name__ == "__main__":
    unittest.main()
