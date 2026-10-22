import sqlite3
import tempfile
import unittest
from pathlib import Path

from verify_store import manifest


class StoreVerificationTests(unittest.TestCase):
    def test_document_content_and_file_bytes_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = sqlite3.connect(root / 'xiaoqi.sqlite3')
            database.executescript("CREATE TABLE documents(key TEXT PRIMARY KEY, document TEXT, revision INTEGER); CREATE TABLE objects(key TEXT PRIMARY KEY); INSERT INTO documents VALUES('private/test','original',1); INSERT INTO objects VALUES('one');")
            database.commit()
            (root / 'objects').mkdir()
            (root / 'objects/file').write_bytes(b'original')
            before = manifest(root)
            database.execute("UPDATE documents SET document='changed'")
            database.commit()
            self.assertNotEqual(before, manifest(root))
            database.close()
            (root / 'objects/file').write_bytes(b'changed')
            self.assertNotEqual(before['object_file_hashes'], manifest(root)['object_file_hashes'])
