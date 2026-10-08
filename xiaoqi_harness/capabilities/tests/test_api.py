from __future__ import annotations

import base64
import hashlib
import json
import sys
from types import ModuleType
from typing import Any

import pytest
from flask import Flask

from xiaoqi_harness.capabilities import api, worker
from xiaoqi_harness.capabilities.storage import RevisionConflict, StoredDocument


class MemoryStore:
    def __init__(self) -> None:
        self.documents: dict[str, StoredDocument] = {}
        self.objects: dict[str, dict[str, bytes]] = {}
        self.task_blobs: dict[str, bytes] = {}

    def get(self, key: str) -> StoredDocument | None:
        return self.documents.get(key)

    def list(self, prefix: str, limit: int = 200) -> list[tuple[str, StoredDocument]]:
        return [
            (key, document)
            for key, document in sorted(self.documents.items())
            if key.startswith(prefix)
        ][:limit]

    def put(self, key: str, value: dict[str, Any], expected_revision: int | None) -> StoredDocument:
        current = self.documents.get(key)
        if expected_revision is None:
            if current is not None:
                raise RevisionConflict(key)
            revision = 1
        else:
            if current is None or current.revision != expected_revision:
                raise RevisionConflict(key)
            revision = expected_revision + 1
        document = StoredDocument(dict(value), revision)
        self.documents[key] = document
        return document

    def put_immutable(self, key: str, files: dict[str, bytes]) -> None:
        self.objects.setdefault(key, dict(files))

    def get_immutable(self, key: str) -> dict[str, bytes]:
        return self.objects[key]

    def put_task_blob(self, key: str, content: bytes) -> None:
        self.task_blobs[key] = content

    def get_task_blob(self, key: str) -> bytes:
        return self.task_blobs[key]


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch):
    memory = MemoryStore()
    monkeypatch.setattr(api, "_store", memory)
    app = Flask(__name__)
    app.register_blueprint(api.capabilities, url_prefix="/v1")
    return app.test_client(), memory


def _paired_device(memory: MemoryStore, tenant: str = "personal") -> str:
    token = "device-token-" + "x" * 40
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    memory.put(
        f"device/{token_hash}",
        {"tenant_id": tenant, "device_id": "device-test", "revoked_at": None},
        None,
    )
    return token


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_explicit_python_requests_require_execution_and_requested_file() -> None:
    messages = [
        {
            "role": "user",
            "content": "必须真实调用 Python，生成 /home/user/workspace/output/result.csv",
        }
    ]

    assert worker._requires_python_execution(messages)
    assert worker._requested_python_output_names(messages) == {"result.csv"}
    assert not worker._requires_python_execution(
        [{"role": "user", "content": "不要运行 Python，只写示例脚本。"}]
    )

    with pytest.raises(RuntimeError, match="要求真实运行 Python"):
        worker._validate_python_requirements({}, messages)

    with pytest.raises(RuntimeError, match="未生成要求的文件：result.csv"):
        worker._validate_python_requirements(
            {
                "python_succeeded": True,
                "artifacts": [{"name": "other.csv"}],
            },
            messages,
        )

    worker._validate_python_requirements(
        {
            "python_succeeded": True,
            "artifacts": [{"name": "result.csv"}],
        },
        messages,
    )



def _record(
    content: str = "---\nname: sample\ndescription: Example skill\n---\n\n# Instructions\n\nFollow the example.\n",
    **updates: Any,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "id": "sample-skill",
        "kind": "skill",
        "name": "Sample",
        "description": "Example skill",
        "versions": [
            {
                "id": "version-1",
                "number": 1,
                "content": content,
                "files": {
                    "scripts/run.py": base64.b64encode(b"print('ok')").decode("ascii")
                },
                "content_hash": "",
                "created_at": "2026-01-01T00:00:00Z",
            }
        ],
        "current_version_id": "version-1",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "show_in_menu": True,
    }
    value.update(updates)
    return value


def test_pairing_code_is_single_use_and_device_can_be_revoked(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    admin = "admin-token-" + "a" * 40
    monkeypatch.setenv("CAPABILITY_ADMIN_TOKEN", admin)

    created = http.post("/v1/pairing-codes", headers={"X-Admin-Token": admin}, json={})
    assert created.status_code == 201
    code = created.json["code"]
    exchanged = http.post("/v1/pair", json={"code": code})
    assert exchanged.status_code == 201
    token = exchanged.json["access_token"]
    assert http.post("/v1/pair", json={"code": code}).status_code == 409
    assert all(token not in repr(value.value) for value in memory.documents.values())

    assert http.get("/v1/capabilities", headers=_auth(token)).status_code == 200
    assert http.delete("/v1/devices/me", headers=_auth(token)).status_code == 200
    assert http.get("/v1/capabilities", headers=_auth(token)).status_code == 401


def test_capability_sync_returns_content_and_rejects_stale_revision(
    client: tuple[Any, MemoryStore],
) -> None:
    http, memory = client
    token = _paired_device(memory)
    response = http.post(
        "/v1/capabilities/sync",
        headers=_auth(token),
        json={"record": _record(), "expected_revision": 0},
    )
    assert response.status_code == 200, response.get_json()
    assert response.json["cloud_revision"] == 1

    changed = _record(name="Changed")
    conflict = http.post(
        "/v1/capabilities/sync",
        headers=_auth(token),
        json={"record": changed, "expected_revision": 0},
    )
    assert conflict.status_code == 409
    assert conflict.json["error"]["current"]["name"] == "Sample"

    listed = http.get("/v1/capabilities", headers=_auth(token))
    version = listed.json["items"][0]["versions"][0]
    assert version["content"].startswith("---\nname: sample")
    assert base64.b64decode(version["files"]["scripts/run.py"]) == b"print('ok')"

    deleted = http.delete(
        "/v1/capabilities/sample-skill?expected_revision=1", headers=_auth(token)
    )
    assert deleted.status_code == 200
    tombstone = http.get("/v1/capabilities", headers=_auth(token)).json["items"][0]
    assert tombstone["deleted_at"]


@pytest.mark.parametrize("path", ["private/key.txt", "scripts/run.sh", "scripts/../secret.py"])
def test_capability_sync_rejects_unsupported_resource_paths(
    client: tuple[Any, MemoryStore], path: str
) -> None:
    http, memory = client
    token = _paired_device(memory)
    record = _record()
    record["versions"][0]["files"] = {
        path: base64.b64encode(b"secret").decode("ascii")
    }
    response = http.post(
        "/v1/capabilities/sync",
        headers=_auth(token),
        json={"record": record, "expected_revision": 0},
    )
    assert response.status_code == 400
    assert not memory.objects


@pytest.mark.parametrize(
    "content",
    [
        "No frontmatter\n",
        "---\nname: Bad_Name\ndescription: Invalid name\n---\nbody\n",
        "---\nname: valid-name\ndescription:\n---\nbody\n",
        "---\nname: valid-name\ndescription: Valid description\n---\n",
    ],
)
def test_capability_sync_enforces_agent_skill_frontmatter(
    client: tuple[Any, MemoryStore], content: str
) -> None:
    http, memory = client
    token = _paired_device(memory)
    response = http.post(
        "/v1/capabilities/sync",
        headers=_auth(token),
        json={"record": _record(content), "expected_revision": 0},
    )
    assert response.status_code == 400
    assert not memory.objects


def test_task_cancellation_marks_queued_task_terminal(client: tuple[Any, MemoryStore]) -> None:
    http, memory = client
    token = _paired_device(memory)
    memory.put(
        "task/personal/task-test",
        {
            "task_id": "task-test",
            "status": "queued",
            "attempt": 1,
            "events": [{"seq": 0, "type": "status", "status": "queued"}],
            "cancel_requested": False,
        },
        None,
    )

    response = http.post(
        "/v1/agent/tasks/task-test/cancel", headers=_auth(token)
    )
    assert response.status_code == 200
    task = memory.get("task/personal/task-test")
    assert task is not None
    assert task.value["status"] == "cancelled"
    assert task.value["cancel_requested"] is True


def test_running_task_cancellation_retries_transient_sandbox_cleanup_failure(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    memory.put(
        "task/personal/task-test",
        {
            "task_id": "task-test",
            "status": "running",
            "attempt": 1,
            "events": [{"seq": 0, "type": "status", "status": "running"}],
            "cancel_requested": False,
            "sandbox_id": "sandbox-test",
        },
        None,
    )
    monkeypatch.setenv("CAPABILITY_TASK_CANCEL_FUNCTION_URL", "https://worker.test/cancel")
    monkeypatch.setenv("CAPABILITY_TASK_INTERNAL_TOKEN", "x" * 32)

    calls = 0

    class WorkerResponse:
        status = 200

        def __enter__(self) -> WorkerResponse:
            return self

        def __exit__(self, *_args: Any) -> None:
            return None

    def fail_once(_request: Any, timeout: int) -> WorkerResponse:
        nonlocal calls
        assert timeout == 8
        calls += 1
        if calls == 1:
            raise OSError("temporary worker connection failure")
        return WorkerResponse()

    monkeypatch.setattr(api.urllib.request, "urlopen", fail_once)

    response = http.post("/v1/agent/tasks/task-test/cancel", headers=_auth(token))

    assert calls == 2
    assert response.status_code == 200
    task = memory.get("task/personal/task-test")
    assert task is not None
    assert task.value["status"] == "cancelling"
    assert task.value["sandbox_id"] is None
    assert task.value["sandbox_cleanup_pending"] is False


def test_running_task_cancellation_reports_unconfirmed_sandbox_cleanup(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    memory.put(
        "task/personal/task-test",
        {
            "task_id": "task-test",
            "status": "running",
            "attempt": 1,
            "events": [{"seq": 0, "type": "status", "status": "running"}],
            "cancel_requested": False,
            "sandbox_id": "sandbox-test",
        },
        None,
    )
    monkeypatch.setenv("CAPABILITY_TASK_CANCEL_FUNCTION_URL", "https://worker.test/cancel")
    monkeypatch.setenv("CAPABILITY_TASK_INTERNAL_TOKEN", "x" * 32)

    calls = 0

    def always_fail(_request: Any, timeout: int) -> Any:
        nonlocal calls
        assert timeout == 8
        calls += 1
        raise OSError("worker remains unavailable")

    monkeypatch.setattr(api.urllib.request, "urlopen", always_fail)

    response = http.post("/v1/agent/tasks/task-test/cancel", headers=_auth(token))

    assert calls == 2
    assert response.status_code == 503
    task = memory.get("task/personal/task-test")
    assert task is not None
    assert task.value["status"] == "cancelling"
    assert task.value["sandbox_id"] == "sandbox-test"
    assert task.value["sandbox_cleanup_pending"] is True


def test_new_task_runtime_is_selected_by_server_tenant_allowlist(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    monkeypatch.setenv("CAPABILITY_HARNESS_TENANTS", "other-tenant,personal")
    monkeypatch.setattr(api, "_enqueue_task", lambda *_: None)

    response = http.post(
        "/v1/agent/tasks",
        headers=_auth(token),
        json={"task_id": "task-harness", "runtime": "legacy", "messages": [{"role": "user", "content": "Hi"}]},
    )

    assert response.status_code == 202
    task = memory.get("task/personal/task-harness")
    assert task is not None
    assert task.value["runtime"] == "deepseek-harness"
    assert task.value["runtime_version"] == "0.1.5rc1"


def test_mimo_text_task_uses_harness_after_compatibility_is_configured(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    monkeypatch.setenv("CAPABILITY_HARNESS_TENANTS", "personal")
    monkeypatch.setattr(api, "_enqueue_task", lambda *_: None)

    response = http.post(
        "/v1/agent/tasks",
        headers=_auth(token),
        json={
            "task_id": "task-mimo",
            "model_id": "mimo-v2.6-flash",
            "messages": [{"role": "user", "content": "Hi"}],
        },
    )

    assert response.status_code == 202
    task = memory.get("task/personal/task-mimo")
    assert task is not None
    assert task.value["runtime"] == "deepseek-harness"


def test_deepseek_flash_image_uses_harness(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    monkeypatch.setenv("CAPABILITY_HARNESS_TENANTS", "personal")
    monkeypatch.setattr(api, "_enqueue_task", lambda *_: None)

    response = http.post(
        "/v1/agent/tasks",
        headers=_auth(token),
        json={
            "task_id": "task-image",
            "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,eA=="}}]}],
        },
    )

    assert response.status_code == 202
    task = memory.get("task/personal/task-image")
    assert task is not None
    assert task.value["runtime"] == "deepseek-harness"


def test_mimo_image_task_uses_harness(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    monkeypatch.setenv("CAPABILITY_HARNESS_TENANTS", "personal")
    monkeypatch.setattr(api, "_enqueue_task", lambda *_: None)

    response = http.post(
        "/v1/agent/tasks",
        headers=_auth(token),
        json={
            "task_id": "task-mimo-image",
            "model_id": "mimo-v2.6-flash",
            "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,eA=="}}]}],
        },
    )

    assert response.status_code == 202
    task = memory.get("task/personal/task-mimo-image")
    assert task is not None
    assert task.value["runtime"] == "deepseek-harness"


def test_task_creation_rejects_tenants_outside_harness_allowlist(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    monkeypatch.setenv("CAPABILITY_HARNESS_TENANTS", "another-tenant")

    response = http.post(
        "/v1/agent/tasks",
        headers=_auth(token),
        json={"task_id": "task-not-allowed", "messages": [{"role": "user", "content": "Hi"}]},
    )

    assert response.status_code == 403
    assert memory.get("task/personal/task-not-allowed") is None


def test_worker_dispatches_harness_tasks_to_the_harness_runner(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, memory = client
    input_key = "tenants/personal/tasks/task-harness/input.json"
    memory.put_immutable(
        input_key,
        {"input.json": json.dumps({"messages": [{"role": "user", "content": "Hi"}]}).encode()},
    )
    task = {"input_object_key": input_key, "runtime": "deepseek-harness"}
    called: list[tuple[Any, ...]] = []
    from xiaoqi_harness.capabilities import harness_worker

    monkeypatch.setattr(worker, "_claim_task", lambda *_: True)
    monkeypatch.setattr(worker, "_ensure_active", lambda *_: task)
    monkeypatch.setattr(worker, "_emit", lambda *_: None)
    monkeypatch.setattr(harness_worker, "run_task", lambda *args: called.append(args))

    worker.run_task(memory, "personal", "task-harness", 1)

    assert len(called) == 1
    assert called[0][1:4] == ("personal", "task-harness", 1)
    assert called[0][-1] == task


def test_network_authorization_only_accepts_requested_exact_domains(
    client: tuple[Any, MemoryStore], monkeypatch: pytest.MonkeyPatch
) -> None:
    http, memory = client
    token = _paired_device(memory)
    memory.put(
        "task/personal/task-test",
        {
            "task_id": "task-test",
            "status": "awaiting_network_permission",
            "attempt": 1,
            "events": [],
            "requested_network_domains": ["api.example.com"],
            "authorized_network_domains": [],
        },
        None,
    )
    monkeypatch.setattr(api, "_enqueue_task", lambda *_: None)

    rejected = http.post(
        "/v1/agent/tasks/task-test/authorize-network",
        headers=_auth(token),
        json={"domains": ["example.com"]},
    )
    assert rejected.status_code == 400

    allowed = http.post(
        "/v1/agent/tasks/task-test/authorize-network",
        headers=_auth(token),
        json={"domains": ["api.example.com"]},
    )
    assert allowed.status_code == 202
    task = memory.get("task/personal/task-test")
    assert task is not None
    assert task.value["authorized_network_domains"] == ["api.example.com"]



@pytest.mark.parametrize(
    ("cancel_during_cleanup", "kill_fails", "expected_sandbox_id", "expected_cleanup_pending"),
    [
        (False, False, None, False),
        (True, True, "sandbox-test", True),
    ],
)
def test_python_execution_uses_isolated_sandbox_and_cleans_it_up(
    client: tuple[Any, MemoryStore],
    monkeypatch: pytest.MonkeyPatch,
    cancel_during_cleanup: bool,
    kill_fails: bool,
    expected_sandbox_id: str | None,
    expected_cleanup_pending: bool,
) -> None:
    _, memory = client
    memory.put(
        "task/personal/task-test",
        {
            "task_id": "task-test",
            "status": "running",
            "attempt": 1,
            "events": [],
            "sandbox_id": None,
        },
        None,
    )
    memory.put(
        "cap/personal/sample-skill",
        {
            "id": "sample-skill",
            "versions": [{"id": "version-1", "artifact_key": "skill-package"}],
        },
        None,
    )
    memory.objects["skill-package"] = {
        "SKILL.md": b"# Skill",
        "scripts/run.py": b"print('skill')",
    }
    writes: list[tuple[str, bytes]] = []
    options: dict[str, Any] = {}
    state = {"killed": False}

    class FakeFiles:
        def write(self, path: str, content: bytes) -> None:
            writes.append((path, content))

        def list(self, _path: str, *, depth: int) -> list[Any]:
            assert depth == 6
            return []

    class FakeSandbox:
        sandbox_id = "sandbox-test"
        files = FakeFiles()

        class Commands:
            def run(self, command: str) -> None:
                assert command == "mkdir -p /home/user/workspace/output"

        commands = Commands()

        @classmethod
        def create(cls, **kwargs: Any) -> "FakeSandbox":
            options.update(kwargs)
            return cls()

        def run_code(self, code: str, *, language: str, timeout: int) -> Any:
            assert code == "print('ok')"
            assert language == "python"
            assert timeout == 120
            return type(
                "Execution",
                (),
                {
                    "logs": type("Logs", (), {"stdout": "ok", "stderr": ""})(),
                    "results": [],
                },
            )()

        def kill(self) -> None:
            state["killed"] = True
            if cancel_during_cleanup:
                api._mutate_task(
                    "personal",
                    "task-test",
                    lambda old: {**old, "status": "cancelling", "cancel_requested": True},
                )
            if kill_fails:
                raise OSError("sandbox cleanup failed")

    fake_module = ModuleType("e2b_code_interpreter")
    fake_module.Sandbox = FakeSandbox  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "e2b_code_interpreter", fake_module)
    monkeypatch.setenv("E2B_API_KEY", "e2b-test-key")
    monkeypatch.setenv("E2B_API_URL", "https://api.cn-hangzhou.sandbox.aliyuncs.com")
    monkeypatch.setenv("E2B_DOMAIN", "cn-hangzhou.sandbox.aliyuncs.com")

    output = worker._execute_python(
        memory,
        "personal",
        "task-test",
        "print('ok')",
        [],
        {
            "materials": [{"name": "notes.txt", "text": "task material"}],
            "capability": {"id": "sample-skill", "version_id": "version-1"},
        },
        attempt=1,
    )

    assert output == "ok"
    assert options["api_key"] == "e2b-test-key"
    assert options["api_url"] == "https://api.cn-hangzhou.sandbox.aliyuncs.com"
    assert options["domain"] == "cn-hangzhou.sandbox.aliyuncs.com"
    assert options["allow_internet_access"] is False
    assert options["network"] == {
        "allow_out": [],
        "deny_out": ["0.0.0.0/0"],
    }
    assert options["timeout"] == 300
    assert state["killed"] is True
    assert ("/home/user/workspace/materials/0-notes.txt", b"task material") in writes
    assert ("/home/user/workspace/skill/scripts/run.py", b"print('skill')") in writes
    task = memory.get("task/personal/task-test")
    assert task is not None and task.value["sandbox_id"] == expected_sandbox_id
    assert task.value["sandbox_cleanup_pending"] is expected_cleanup_pending
    if expected_cleanup_pending:
        assert task.value["sandbox_cleanup_deadline"] is not None
    assert task.value["python_succeeded"] is True


def test_single_server_disables_unverified_python_execution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("XIAOQI_SINGLE_SERVER", "1")

    with pytest.raises(RuntimeError, match="低权限隔离"):
        worker._execute_python(None, "personal", "task-test", "print('x')", [], {})


def test_single_server_dispatches_tasks_to_its_local_queue(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[str, str, int]] = []
    monkeypatch.setattr(api, "_LOCAL_RUNTIME_ENABLED", True)
    monkeypatch.setattr(api, "_enqueue_local_task", lambda *args: calls.append(args))

    api._enqueue_task("personal", "task-local", 3)

    assert calls == [("personal", "task-local", 3)]
