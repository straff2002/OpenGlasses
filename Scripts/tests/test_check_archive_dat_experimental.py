"""Scripts/check-archive-dat-experimental.sh on synthetic archives (Plan JV P0).

Run: python3 -I -m unittest discover -s Scripts/tests -p test_check_archive_dat_experimental.py
"""
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/check-archive-dat-experimental.sh"


class ArchiveCheckTests(unittest.TestCase):
    def archive(self, directory, stamp, modules=()):
        app = Path(directory) / "Avenkin.xcarchive/Products/Applications/OpenGlasses.app"
        (app / "Frameworks/MWDATCore.framework").mkdir(parents=True)
        info = {"CFBundleExecutable": "OpenGlasses"}
        if stamp is not None:
            info["AvenkinDATExperimental"] = stamp
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "OpenGlasses").write_bytes(b"not a mach-o")
        for module in modules:
            (app / f"Frameworks/{module}.framework").mkdir()
        return app.parents[2]

    def run_check(self, path):
        result = subprocess.run([str(SCRIPT), str(path)], capture_output=True, text=True)
        return result.returncode, result.stdout, result.stderr

    def test_an_unflagged_archive_is_store_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            code, out, _ = self.run_check(self.archive(directory, "NO"))
            self.assertEqual(code, 0)
            self.assertIn("STORE-SAFE", out)
            self.assertNotIn("TESTFLIGHT ONLY", out)

    def test_a_flagged_archive_is_testflight_only(self):
        with tempfile.TemporaryDirectory() as directory:
            code, out, _ = self.run_check(self.archive(directory, "YES", ["MWDATInputs"]))
            self.assertEqual(code, 0)
            self.assertIn("TESTFLIGHT ONLY — DO NOT SUBMIT", out)
            self.assertNotIn("STORE-SAFE", out)

    def test_a_module_without_the_stamp_fails(self):
        for module in ("MWDATInputs", "MWDATMotion", "MWDATSpeech"):
            with tempfile.TemporaryDirectory() as directory:
                code, out, err = self.run_check(self.archive(directory, "NO", [module]))
                self.assertEqual(code, 1, module)
                self.assertNotIn("STORE-SAFE", out)
                self.assertIn("Do not submit", err)

    def test_the_stamp_without_the_module_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            code, out, _ = self.run_check(self.archive(directory, "YES"))
            self.assertEqual(code, 1)
            self.assertNotIn("STORE-SAFE", out)

    def test_an_unstamped_or_unexpanded_stamp_fails(self):
        for stamp in (None, "$(AVENKIN_DAT_EXPERIMENTAL)", ""):
            with tempfile.TemporaryDirectory() as directory:
                code, out, _ = self.run_check(self.archive(directory, stamp))
                self.assertEqual(code, 1, stamp)
                self.assertNotIn("STORE-SAFE", out)

    def test_an_app_bundle_can_be_checked_directly(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(directory, "NO")
            code, out, _ = self.run_check(archive / "Products/Applications/OpenGlasses.app")
            self.assertEqual(code, 0)
            self.assertIn("STORE-SAFE", out)

    def test_a_path_that_is_not_an_archive_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as directory:
            code, _, _ = self.run_check(Path(directory))
            self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
