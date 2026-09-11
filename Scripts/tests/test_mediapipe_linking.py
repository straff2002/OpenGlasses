import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "linking", Path(__file__).resolve().parents[1] / "prepare-mediapipe-linking.py"
)
linking = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linking)


class MediaPipeLinkingTests(unittest.TestCase):
    anchors = {"graph.o": "__ZGraph", "calculator.o": "__ZCalculator"}
    valid = ["lib.a:graph.o: 0000000000000010 T __ZGraph",
             "lib.a:calculator.o: 0000000000000020 D __ZCalculator"]

    def test_external_function_and_data_anchors(self):
        linking.validate_symbols(self.anchors, self.valid)

    def test_local_registration_cannot_satisfy_anchor(self):
        with self.assertRaises(ValueError):
            linking.validate_symbols(self.anchors, [self.valid[0], self.valid[1].replace(" D ", " b ")])

    def test_missing_anchor_fails(self):
        with self.assertRaises(ValueError):
            linking.validate_symbols(self.anchors, self.valid[:1])

    def test_anchor_in_wrong_member_fails(self):
        with self.assertRaises(ValueError):
            linking.validate_symbols(self.anchors, [self.valid[0].replace("graph.o", "other.o"), self.valid[1]])

    def test_ambiguous_anchor_fails(self):
        with self.assertRaises(ValueError):
            linking.validate_symbols(self.anchors, self.valid + [self.valid[0].replace("graph.o", "other.o")])

    def test_configuration_contains_explicit_linker_roots(self):
        config = linking.config_text(self.anchors)
        self.assertIn("MEDIAPIPE_HOLISTIC_LDFLAGS = -ObjC -Wl,-u,__ZGraph -Wl,-u,__ZCalculator\n", config)
        self.assertNotIn("@", config)  # ld response-file content is not an Xcode build input.


if __name__ == "__main__":
    unittest.main()
