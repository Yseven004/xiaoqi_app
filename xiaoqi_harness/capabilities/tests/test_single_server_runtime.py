"""Tests for single-server task recovery and the 24-hour content expiry."""

import hashlib
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from xiaoqi_harness.capabilities import api
from xiaoqi_harness.capabilities.storage import CloudStore


class SingleServerRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = CloudStore(self.temporary_directory.name)
        self.store_patch = patch("xiaoqi_harness.capabilities.api.store", return_value=self.store)
        self.store_patch.start()

    def tearDown(self):
        self.store_patch.stop()
        self.temporary_directory.cleanup()

    def _task(self, tenant, task_id, **overrides):
        value = {
            "task_id": task_id,
            "tenant_id": tenant,
            "status": "queued",
            "attempt": 1,
            "created_at": int(time.time()),
            "updated_at": int(time.time()),
            "events": [],
            **overrides,
        }
        self.store.put(f"task/{tenant}/{task_id}", value, None)
        return value

    def test_recovery_requeues_queued_and_marks_active_tasks_interrupted(self):
        self._task("personal", "queued-1", status="queued")
        self._task(
            "personal",
            "running-1",
            status="running",
            worker_id="old-worker",
            worker_lease_until=int(time.time()) + 300,
        )

        queued = api._recover_local_tasks()

        self.assertEqual(queued, [("personal", "queued-1", 1)])
        interrupted = self.store.get("task/personal/running-1").value
        self.assertEqual(interrupted["status"], "failed")
        self.assertEqual(interrupted["worker_id"], None)
        self.assertIsInstance(interrupted["finished_at"], int)
        self.assertIn("服务重启", interrupted["error"])

    def test_expiry_removes_server_content_and_keeps_minimal_status(self):
        tenant, task_id = "personal", "expired-1"
        tenant_hash = hashlib.sha256(tenant.encode()).hexdigest()[:24]
        task_hash = hashlib.sha256(task_id.encode()).hexdigest()[:24]
        snapshot_key = f"tenants/{tenant_hash}/tasks/{task_hash}/harness/snapshot.zip"
        input_key = f"tenants/{tenant}/tasks/{task_id}/input.zip"
        artifact_key = f"tenants/{tenant}/tasks/{task_id}/artifact.zip"
        self.store.put_immutable(input_key, {"input.json": b"private prompt"})
        self.store.put_immutable(artifact_key, {"answer.txt": b"private result"})
        self.store.put_task_blob(snapshot_key, b"private checkpoint")
        finished_at = int(time.time()) - api._TASK_RETENTION_SECONDS
        self._task(
            tenant,
            task_id,
            status="succeeded",
            finished_at=finished_at,
            updated_at=finished_at,
            request_hash="private-request-hash",
            input_object_key=input_key,
            transcript_object_key=input_key,
            harness_snapshot_key=snapshot_key,
            result="private result",
            draft_files={"SKILL.md": "private draft"},
            artifacts=[{"id": "file-1", "object_key": artifact_key}],
            events=[{"seq": 0, "type": "text", "text": "private response"}],
        )

        with patch(
            "xiaoqi_harness.capabilities.harness_worker.tempfile.gettempdir",
            return_value=self.temporary_directory.name,
        ):
            workspace = (
                Path(self.temporary_directory.name)
                / "xiaoqi-harness-workspaces"
                / hashlib.sha256(tenant.encode()).hexdigest()[:24]
                / task_hash
            )
            workspace.mkdir(parents=True)
            (workspace / "private.txt").write_text("private workspace", encoding="utf-8")
            api._expire_finished_tasks()
            self.assertFalse(workspace.exists())

        expired = self.store.get(f"task/{tenant}/{task_id}").value
        self.assertTrue(expired["content_expired"])
        self.assertEqual(expired["status"], "succeeded")
        self.assertNotIn("result", expired)
        self.assertNotIn("request_hash", expired)
        self.assertNotIn("artifacts", expired)
        self.assertEqual(expired["events"][0]["code"], "content_expired")
        for key in (input_key, artifact_key, snapshot_key):
            with self.assertRaises(FileNotFoundError):
                self.store.get_task_blob(key)


if __name__ == "__main__":
    unittest.main()
