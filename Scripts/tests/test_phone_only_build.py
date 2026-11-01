import importlib.util
import plistlib
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
