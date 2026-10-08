"""Regression tests for the single-server SQLite and file store."""

import tempfile
import unittest
from pathlib import Path

from xiaoqi_harness.capabilities.storage import CloudStore, RevisionConflict


class LocalStorageTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = CloudStore(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_documents_keep_compare_and_swap_revisions(self):
        first = self.store.put("tenant/one", {"value": 1}, None)
        self.assertEqual(first.revision, 1)

        second = self.store.put("tenant/one", {"value": 2}, first.revision)
        self.assertEqual(second.revision, 2)
        self.assertEqual(self.store.get("tenant/one").value, {"value": 2})
        with self.assertRaises(RevisionConflict):
            self.store.put("tenant/one", {"value": 3}, first.revision)

    def test_prefix_listing_is_ordered_and_paginates(self):
        for key in ("task/a", "task/b", "task/c", "other/a"):
            self.store.put(key, {"key": key}, None)

        first = self.store.list("task/", limit=2)
        second = self.store.list("task/", limit=2, after_key=first[-1][0])
        self.assertEqual([key for key, _ in first], ["task/a", "task/b"])
        self.assertEqual([key for key, _ in second], ["task/c"])

    def test_database_uses_private_deletion_and_can_truncate_its_wal(self):
        with self.store._connection() as connection:
            self.assertEqual(connection.execute("PRAGMA secure_delete").fetchone()[0], 1)
            self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        self.assertTrue(self.store.checkpoint_wal())

    def test_zip_objects_blobs_and_prefix_deletion(self):
        self.store.put_immutable("tenant/tasks/t1/input.zip", {"input.json": b"{}"})
        self.store.put_task_blob("tenant/tasks/t1/snapshot", b"snapshot")
        self.store.put_immutable("tenant/tasks/t2/input.zip", {"input.json": b"other"})

        self.assertEqual(
            self.store.get_immutable("tenant/tasks/t1/input.zip"),
            {"input.json": b"{}"},
        )
        self.assertEqual(
            self.store.get_task_blob("tenant/tasks/t1/snapshot"), b"snapshot"
        )
        self.assertEqual(self.store.delete_objects_prefix("tenant/tasks/t1/"), 2)
        self.assertFalse(Path(self.store.objects / "tenant/tasks/t1/input.zip").exists())
        self.assertEqual(
            self.store.get_immutable("tenant/tasks/t2/input.zip"),
            {"input.json": b"other"},
        )

    def test_zip_member_path_traversal_is_rejected(self):
        with self.assertRaises(ValueError):
            self.store.put_immutable("safe/archive.zip", {"../escape": b"x"})
        with self.assertRaises(ValueError):
            self.store.put_task_blob("../outside", b"x")

    def test_startup_cleanup_removes_abandoned_atomic_write_files(self):
        object_directory = self.store.objects / "tenant" / "task"
        object_directory.mkdir(parents=True)
        temporary_file = object_directory / ".tmp-abandoned"
        temporary_file.write_bytes(b"incomplete write")

        self.assertEqual(self.store.remove_orphaned_temp_files(), 1)
        self.assertFalse(temporary_file.exists())


if __name__ == "__main__":
    unittest.main()
