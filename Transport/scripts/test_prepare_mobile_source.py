import json
from pathlib import Path
import tempfile
import unittest
from prepare_mobile_source import prepare_source

class SourcePinTests(unittest.TestCase):
    def test_unreviewed_source_is_rejected_before_replacing_generated_tree(self):
        transport = Path(__file__).resolve().parents[1]
        pin = json.loads((transport / 'vendor/syncthing/mobile-extension/pin.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / f"github.com/syncthing/syncthing@{pin['moduleVersion']}" / pin['source']
            source.parent.mkdir(parents=True)
            source.write_text('package syncthing // unexpected source\n')
            with self.assertRaisesRegex(ValueError, 'Upstream source changed'):
                prepare_source(temporary, transport / '.tools/syncthing-mobile')
