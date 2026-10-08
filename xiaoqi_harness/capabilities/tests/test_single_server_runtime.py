"""Tests for single-server task recovery and the 24-hour content expiry."""

import hashlib
import threading
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
        self.old_maintenance = api._LOCAL_DSH_MAINTENANCE
        self.old_active_tasks = api._LOCAL_DSH_ACTIVE_TASKS
        self.old_runtime_enabled = api._LOCAL_RUNTIME_ENABLED
        with api._LOCAL_TASK_CONDITION:
            api._LOCAL_DSH_MAINTENANCE = False
            api._LOCAL_DSH_ACTIVE_TASKS = 0
            api._LOCAL_TASKS_SUBMITTED.clear()
            api._LOCAL_RUNTIME_ENABLED = False

    def tearDown(self):
        with api._LOCAL_TASK_CONDITION:
            api._LOCAL_DSH_MAINTENANCE = self.old_maintenance
            api._LOCAL_DSH_ACTIVE_TASKS = self.old_active_tasks
            api._LOCAL_TASKS_SUBMITTED.clear()
            api._LOCAL_RUNTIME_ENABLED = self.old_runtime_enabled
            api._LOCAL_TASK_CONDITION.notify_all()
        self.store_patch.stop()
        self.temporary_directory.cleanup()

    def _client(self):
        from flask import Flask

        app = Flask(__name__)
        app.register_blueprint(api.capabilities, url_prefix="/v1")
        return app.test_client()

    def _device_headers(self):
        token = "device-token-" + ("x" * 32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        self.store.put(
            f"device/{digest}",
            {"tenant_id": "personal", "device_id": "device-1", "revoked_at": None},
            None,
        )
        return {"Authorization": f"Bearer {token}"}

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

    def test_maintenance_rejects_new_tasks_without_persisting_them(self):
        client = self._client()
        headers = {"X-DSH-Internal-Token": "i" * 40}
        task_headers = self._device_headers()
        with patch.dict(
            "os.environ",
            {"XIAOQI_DSH_INTERNAL_TOKEN": "i" * 40, "CAPABILITY_HARNESS_TENANTS": "personal"},
        ):
            request_body = {"task_id": "existing-task", "messages": [{"role": "user", "content": "hi"}]}
            with patch("xiaoqi_harness.capabilities.api._enqueue_task"):
                original = client.post("/v1/agent/tasks", json=request_body, headers=task_headers)
            self.assertEqual(original.status_code, 202)
            entered = client.post(
                "/v1/internal/dsh/maintenance",
                json={"action": "enter", "operation_id": "release-1"},
                headers=headers,
            )
            self.assertEqual(entered.status_code, 200)
            self.assertTrue(entered.json["maintenance"])

            with patch("xiaoqi_harness.capabilities.api._enqueue_task"):
                duplicate = client.post("/v1/agent/tasks", json=request_body, headers=task_headers)
            self.assertEqual(duplicate.status_code, 200)
            self.assertTrue(duplicate.json["deduplicated"])

            response = client.post(
                "/v1/agent/tasks",
                json={"task_id": "maintenance-task", "messages": [{"role": "user", "content": "hi"}]},
                headers=task_headers,
            )
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.headers.get("Retry-After"), "15")
            self.assertIsNone(self.store.get("task/personal/maintenance-task"))

            released = client.post(
                "/v1/internal/dsh/maintenance",
                json={"action": "release", "operation_id": "release-1"},
                headers=headers,
            )
            self.assertEqual(released.status_code, 200)
            self.assertFalse(released.json["maintenance"])
            with patch("xiaoqi_harness.capabilities.api._enqueue_task"):
                accepted = client.post(
                    "/v1/agent/tasks",
                    json={"task_id": "maintenance-task", "messages": [{"role": "user", "content": "hi"}]},
                    headers=task_headers,
                )
            self.assertEqual(accepted.status_code, 202)
            saved = self.store.get("task/personal/maintenance-task").value
            self.assertEqual(saved["status"], "queued")

    def test_maintenance_still_allows_existing_task_permission_and_resume(self):
        api._LOCAL_DSH_MAINTENANCE = True
        client = self._client()
        headers = self._device_headers()
        self._task(
            "personal",
            "permission-task",
            status="awaiting_network_permission",
            dsh_pinned=True,
            dsh_release_id="dsh-0.2.0",
            dsh_config_id="cfg-5",
            requested_network_domains=["example.com"],
        )
        self._task("personal", "resume-task", status="failed", dsh_pinned=True, dsh_release_id="dsh-0.2.0", dsh_config_id="cfg-5")
        with patch("xiaoqi_harness.capabilities.api._enqueue_task"):
            authorized = client.post(
                "/v1/agent/tasks/permission-task/authorize-network",
                json={"domains": ["example.com"]},
                headers=headers,
            )
            resumed = client.post("/v1/agent/tasks/resume-task/resume", json={}, headers=headers)
        self.assertEqual(authorized.status_code, 202)
        self.assertEqual(resumed.status_code, 202)
        permission_task = self.store.get("task/personal/permission-task").value
        resume_task = self.store.get("task/personal/resume-task").value
        self.assertEqual(permission_task["dsh_config_id"], "cfg-5")
        self.assertEqual(resume_task["dsh_config_id"], "cfg-5")

    def test_worker_start_captures_the_published_release_and_config_revision(self):
        self.store.put(
            "dsh/admin-state",
            {
                "maintenance": False,
                "operation_id": None,
                "active_release_id": "builtin",
                "dsh_version": "0.2.0-rc.2",
                "config_id": "builtin",
                "config_revision": 0,
            },
            None,
        )
        client = self._client()
        headers = self._device_headers()
        with patch.dict("os.environ", {"CAPABILITY_HARNESS_TENANTS": "personal"}):
            with patch("xiaoqi_harness.capabilities.api._enqueue_task"):
                response = client.post(
                    "/v1/agent/tasks",
                    json={"task_id": "pinned-task", "messages": [{"role": "user", "content": "hi"}]},
                    headers=headers,
                )
        self.assertEqual(response.status_code, 202)
        current = self.store.get("dsh/admin-state")
        self.store.put(
            "dsh/admin-state",
            {
                **current.value,
                "active_release_id": "dsh-0.2.1",
                "dsh_version": "0.2.1",
                "config_id": "cfg-7",
                "config_revision": 7,
            },
            current.revision,
        )
        api._pin_dsh_task_runtime("personal", "pinned-task", 1)
        saved = self.store.get("task/personal/pinned-task").value
        self.assertEqual(saved["runtime_version"], "0.2.1")
        self.assertEqual(saved["dsh_release_id"], "dsh-0.2.1")
        self.assertEqual(saved["dsh_config_id"], "cfg-7")
        self.assertEqual(saved["dsh_config_revision"], 7)

    def test_queued_worker_waits_for_maintenance_then_drains(self):
        api._LOCAL_DSH_MAINTENANCE = True
        running = threading.Event()
        completed = threading.Event()

        def run_task(*_args):
            running.set()
            completed.set()

        thread = threading.Thread(target=api._run_local_task, args=("personal", "held-task", 1))
        with patch("xiaoqi_harness.capabilities.worker.run_task", side_effect=run_task):
            thread.start()
            self.assertFalse(running.wait(0.05))
            with api._LOCAL_TASK_CONDITION:
                api._LOCAL_DSH_MAINTENANCE = False
                api._LOCAL_TASK_CONDITION.notify_all()
            self.assertTrue(completed.wait(2))
            thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(api._LOCAL_DSH_ACTIVE_TASKS, 0)

    def test_config_publication_is_blocked_during_maintenance_and_is_idempotent(self):
        import json

        with tempfile.TemporaryDirectory() as release_root:
            profile = Path(release_root) / "configs" / "cfg-1" / "profiles" / "xiaoqi-acp"
            profile.mkdir(parents=True)
            (profile / "package.json").write_text(
                json.dumps({"dsh": {"profile": {"bundles": []}}}),
                encoding="utf-8",
            )
            client = self._client()
            headers = {"X-DSH-Internal-Token": "i" * 40}
            with patch.dict(
                "os.environ",
                {
                    "XIAOQI_DSH_INTERNAL_TOKEN": "i" * 40,
                    "XIAOQI_DSH_RELEASE_ROOT": release_root,
                },
            ):
                entered = client.post(
                    "/v1/internal/dsh/maintenance",
                    json={"action": "enter", "operation_id": "release-2"},
                    headers=headers,
                )
                self.assertEqual(entered.status_code, 200)
                blocked = client.post(
                    "/v1/internal/dsh/apply-config",
                    json={"config_id": "cfg-1"},
                    headers=headers,
                )
                self.assertEqual(blocked.status_code, 409)

                client.post(
                    "/v1/internal/dsh/maintenance",
                    json={"action": "release", "operation_id": "release-2"},
                    headers=headers,
                )
                published = client.post(
                    "/v1/internal/dsh/apply-config",
                    json={"config_id": "cfg-1"},
                    headers=headers,
                )
                repeated = client.post(
                    "/v1/internal/dsh/apply-config",
                    json={"config_id": "cfg-1"},
                    headers=headers,
                )
            self.assertEqual(published.status_code, 200)
            self.assertEqual(published.json["config_revision"], 1)
            self.assertEqual(repeated.status_code, 200)
            self.assertEqual(repeated.json["config_revision"], 1)

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
