import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import component_fingerprints as fingerprints


class ComponentFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for entries in fingerprints.SPECS.values():
            for entry in entries:
                path = self.root / entry
                if path.name == 'Dockerfile' or path.suffix:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('FROM python:3.12-slim AS base\n' if path.name == 'Dockerfile' else entry)
                else:
                    path.mkdir(parents=True, exist_ok=True)
                    (path / 'sample.txt').write_text(entry)

    def test_only_the_component_with_changed_source_gets_a_new_fingerprint(self):
        with patch.object(fingerprints, 'image_id', return_value='sha256:' + 'a' * 64):
            before = fingerprints.fingerprints(self.root)
            (self.root / 'genkit_server/lib/sample.txt').write_text('changed')
            after = fingerprints.fingerprints(self.root)
        self.assertNotEqual(before['app']['fingerprint'], after['app']['fingerprint'])
        for name in ('runner', 'sandbox', 'proxy'):
            self.assertEqual(before[name]['fingerprint'], after[name]['fingerprint'])

    def test_base_image_identity_is_part_of_the_fingerprint(self):
        first_id = 'sha256:' + hashlib.sha256(b'first').hexdigest()
        second_id = 'sha256:' + hashlib.sha256(b'second').hexdigest()
        with patch.object(fingerprints, 'image_id', return_value=first_id):
            first = fingerprints.fingerprints(self.root)
        with patch.object(fingerprints, 'image_id', return_value=second_id):
            second = fingerprints.fingerprints(self.root)
        for name in fingerprints.SPECS:
            self.assertNotEqual(first[name]['fingerprint'], second[name]['fingerprint'])

    def test_plugin_owned_annotation_font_is_not_a_sandbox_image_input(self):
        self.assertNotIn('genkit_server/sandbox_image/fonts', fingerprints.SPECS['sandbox'])


if __name__ == '__main__':
    unittest.main()
