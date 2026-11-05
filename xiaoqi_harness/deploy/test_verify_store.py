import hashlib
import sqlite3
import tempfile
import unittest
import tarfile
from pathlib import Path

from verify_store import manifest, with_catalog_changes, recover_manifest_metadata, exclude_expired_attachments


class StoreVerificationTests(unittest.TestCase):
    def test_legacy_expiration_requires_matching_original_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = sqlite3.connect(root / 'xiaoqi.sqlite3')
            database.executescript('CREATE TABLE documents(key TEXT PRIMARY KEY, document TEXT, revision INTEGER); CREATE TABLE objects(key TEXT PRIMARY KEY);')
            database.execute('INSERT INTO documents VALUES(?,?,?)', ('attachment/old', '{"expires_at":10}', 1))
            database.commit()
            database.close()
            original = manifest(root)
            legacy = {k: v for k, v in original.items() if k != 'document_expirations'}
            archive = root / 'data.tgz'
            with tarfile.open(archive, 'w:gz') as output:
                output.add(root / 'xiaoqi.sqlite3', arcname='./xiaoqi.sqlite3')
            recovered = recover_manifest_metadata(legacy, archive)
            self.assertEqual(recovered, original)
            self.assertNotIn('document_expirations', legacy)
            self.assertEqual(exclude_expired_attachments(recovered, 10)['documents'], [])
            forged = dict(legacy, document_hashes={'attachment/old': '0' * 64})
            with self.assertRaisesRegex(ValueError, 'does not match'):
                recover_manifest_metadata(forged, archive)

    def test_legacy_manifest_cannot_use_live_data_as_recovery_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = sqlite3.connect(root / 'xiaoqi.sqlite3')
            database.executescript('CREATE TABLE documents(key TEXT PRIMARY KEY, document TEXT, revision INTEGER); CREATE TABLE objects(key TEXT PRIMARY KEY);')
            database.execute("INSERT INTO documents VALUES('private/note','original',1)")
            database.commit()
            database.close()
            legacy = {'documents': [['private/note', 1]],
                      'document_hashes': {'private/note': hashlib.sha256(b'original').hexdigest()},
                      'object_keys': [], 'object_file_hashes': {},
                      'counts': {'documents': 1, 'objects': 0, 'object_files': 0}}
            forged = dict(legacy, document_hashes={'private/note': '0' * 64})
            with self.assertRaises(FileNotFoundError):
                recover_manifest_metadata(forged, root / 'missing-backup.tgz')

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
        names = ['book-to-skill', 'study-notes-studio', 'original-reading-annotations', 'learning-notes-manager']
        keys = ['skill-market/' + hashlib.sha256(f'_official-curated/{name}'.encode()).hexdigest() for name in names]
        objects = [f'official-catalog/{name}/' + 'a'*64 + '.zip' for name in names]
        changes = {'schema': 1, 'documents': [[key, 1] for key in keys],
                   'document_hashes': {key: '3'*64 for key in keys}, 'object_keys': objects,
                   'object_file_hashes': {key: '4'*64 for key in objects}}
        expected = with_catalog_changes(baseline, changes)
        self.assertEqual(expected['document_hashes']['private/note'], '1'*64)
        self.assertEqual(expected['object_file_hashes']['private/file'], '2'*64)
        self.assertEqual(expected['counts'], {'documents': 5, 'objects': 5, 'object_files': 5})
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
