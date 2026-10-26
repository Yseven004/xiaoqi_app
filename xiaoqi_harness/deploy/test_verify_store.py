import hashlib
import sqlite3
import tempfile
import unittest
from pathlib import Path

from verify_store import manifest, with_catalog_changes


class StoreVerificationTests(unittest.TestCase):
    def test_live_manifest_reads_committed_wal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = sqlite3.connect(root / 'xiaoqi.sqlite3')
            database.executescript('PRAGMA journal_mode=WAL; CREATE TABLE documents(key TEXT PRIMARY KEY, document TEXT, revision INTEGER); CREATE TABLE objects(key TEXT PRIMARY KEY);')
            database.execute("INSERT INTO documents VALUES('private/wal','committed',1)")
            database.commit()
            try:
                current = manifest(root)
                self.assertEqual(current['document_hashes']['private/wal'], hashlib.sha256(b'committed').hexdigest())
            finally:
                database.close()

    def test_exact_catalog_delta_keeps_every_private_hash_in_the_comparison(self):
        baseline = {'documents': [['private/note', 1]], 'document_hashes': {'private/note': '1'*64},
                    'object_keys': ['private/file'], 'object_file_hashes': {'private/file': '2'*64},
                    'counts': {'documents': 1, 'objects': 1, 'object_files': 1}}
        names = ['book-to-skill', 'study-notes-studio']
        keys = ['skill-market/' + hashlib.sha256(f'_official-curated/{name}'.encode()).hexdigest() for name in names]
        objects = [f'official-catalog/{name}/' + 'a'*64 + '.zip' for name in names]
        changes = {'schema': 1, 'documents': [[key, 1] for key in keys],
                   'document_hashes': {key: '3'*64 for key in keys}, 'object_keys': objects,
                   'object_file_hashes': {key: '4'*64 for key in objects}}
        expected = with_catalog_changes(baseline, changes)
        self.assertEqual(expected['document_hashes']['private/note'], '1'*64)
        self.assertEqual(expected['object_file_hashes']['private/file'], '2'*64)
        self.assertEqual(expected['counts'], {'documents': 3, 'objects': 3, 'object_files': 3})
        actual = dict(expected, document_hashes=dict(expected['document_hashes'], **{'private/note': '5'*64}))
        self.assertNotEqual(actual, expected)
        forged = dict(changes, documents=[['private/note', 2], changes['documents'][1]])
        with self.assertRaises(ValueError):
            with_catalog_changes(baseline, forged)
        forged = dict(changes, object_keys=['private/file', objects[1]], object_file_hashes={'private/file': '4'*64, objects[1]: '4'*64})
        with self.assertRaises(ValueError):
            with_catalog_changes(baseline, forged)
        previous = dict(baseline, object_file_hashes=dict(baseline['object_file_hashes'], **{objects[0]: '6'*64}))
        with self.assertRaises(ValueError):
            with_catalog_changes(previous, changes)
        previous = dict(baseline, documents=[*baseline['documents'], [keys[0], 2]])
        with self.assertRaises(ValueError):
            with_catalog_changes(previous, changes)

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
