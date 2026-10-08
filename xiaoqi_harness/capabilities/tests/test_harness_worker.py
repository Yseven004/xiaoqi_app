from __future__ import annotations

import base64
import asyncio
import os
import zipfile
from io import BytesIO

import pytest

from xiaoqi_harness.capabilities import harness_worker


def test_tool_environment_preserves_python_module_paths(monkeypatch) -> None:
    monkeypatch.setattr(harness_worker.sys, "path", ["/opt/python", "/app", ""])
    monkeypatch.setenv("XIAOQI_DATA_DIR", "/var/lib/xiaoqi")
    monkeypatch.setenv("XIAOQI_SINGLE_SERVER", "1")
    monkeypatch.setenv("ALIBABA_CLOUD_ACCESS_KEY_SECRET", "must-not-cross-process")
    monkeypatch.setenv("E2B_API_KEY", "must-not-cross-process")

    env = harness_worker._tool_environment("personal", "task", 1, "worker", 8000)

    assert env["PYTHONPATH"] == os.pathsep.join(("/opt/python", "/app"))
    assert env["XIAOQI_DATA_DIR"] == "/var/lib/xiaoqi"
    assert env["XIAOQI_SINGLE_SERVER"] == "1"
    assert "ALIBABA_CLOUD_ACCESS_KEY_SECRET" not in env
    assert "E2B_API_KEY" not in env


def test_session_prompt_preserves_history_and_inline_images() -> None:
    image = base64.b64encode(b"fake-image-bytes").decode("ascii")
    prompt = harness_worker._session_prompt(
        [
            {"role": "system", "content": "Use the task tools."},
            {"role": "user", "content": [
                {"type": "text", "text": "Read this image."},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image}"}},
            ]},
        ]
    )

    assert any(getattr(part, "text", "") == "Read this image." for part in prompt)
    image_parts = [part for part in prompt if getattr(part, "type", None) == "image"]
    assert len(image_parts) == 1
    assert image_parts[0].mimeType == "image/png"
    assert image_parts[0].data == image


def test_session_prompt_rejects_remote_images() -> None:
    with pytest.raises(ValueError, match="外部图片链接"):
        harness_worker._session_prompt(
            [{"role": "user", "content": [{"type": "image_url", "image_url": "https://example.com/a.png"}]}]
        )


def test_mimo_profile_advertises_image_input(tmp_path) -> None:
    profile = tmp_path / "profile.yaml"

    harness_worker._write_profile_patch(
        profile,
        "mimo-v2.6-flash",
        "https://api.xiaomimimo.com/v1",
        "Use tools safely.",
        "medium",
    )

    assert "input: [text, image]" in profile.read_text(encoding="utf-8")


def test_snapshot_round_trip_keeps_only_runtime_session_data(tmp_path) -> None:
    home = tmp_path / "home"
    (home / "sessions").mkdir(parents=True)
    (home / "sessions" / "one.jsonl").write_text("session", encoding="utf-8")
    (home / "profiles" / "acp").mkdir(parents=True)
    (home / "profiles" / "acp" / "package.json").write_text("profile", encoding="utf-8")

    snapshot = harness_worker._make_snapshot(home)
    restored = tmp_path / "restored"
    harness_worker._restore_snapshot(restored, snapshot)

    assert (restored / "sessions" / "one.jsonl").read_text(encoding="utf-8") == "session"
    assert not (restored / "profiles").exists()


def test_snapshot_rejects_path_traversal(tmp_path) -> None:
    payload = BytesIO()
    with zipfile.ZipFile(payload, "w") as archive:
        archive.writestr("sessions/../../outside", "bad")

    with pytest.raises(ValueError, match="无效路径"):
        harness_worker._restore_snapshot(tmp_path / "home", payload.getvalue())


def test_cancelled_task_sends_acp_cancel(monkeypatch) -> None:
    class _Connection:
        cancelled = False

        async def prompt(self, **_kwargs):
            while not self.cancelled:
                await asyncio.sleep(0.01)

        async def cancel(self, **_kwargs):
            self.cancelled = True

    def cancelled(*_args):
        from xiaoqi_harness.capabilities.worker import TaskCancelled

        raise TaskCancelled()

    monkeypatch.setattr("xiaoqi_harness.capabilities.worker._ensure_active", cancelled)
    connection = _Connection()

    from xiaoqi_harness.capabilities.worker import TaskCancelled

    with pytest.raises(TaskCancelled):
        asyncio.run(
            harness_worker._prompt_and_monitor(
                connection,
                "session",
                [],
            object(),
            "tenant",
            "task",
                1,
                "worker",
            )
        )

    assert connection.cancelled


def test_cancelled_task_does_not_wait_forever_for_prompt(monkeypatch) -> None:
    class _Connection:
        cancel_called = False
        prompt_cancelled = False

        async def prompt(self, **_kwargs):
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                self.prompt_cancelled = True
                raise

        async def cancel(self, **_kwargs):
            self.cancel_called = True

    def cancelled(*_args):
        from xiaoqi_harness.capabilities.worker import TaskCancelled

        raise TaskCancelled()

    monkeypatch.setattr("xiaoqi_harness.capabilities.worker._ensure_active", cancelled)
    monkeypatch.setattr(harness_worker, "_ACP_CANCEL_TIMEOUT_SECONDS", 0.01)
    connection = _Connection()

    from xiaoqi_harness.capabilities.worker import TaskCancelled

    with pytest.raises(TaskCancelled):
        asyncio.run(
            harness_worker._prompt_and_monitor(
                connection,
                "session",
                [],
                object(),
                "tenant",
                "task",
                1,
                "worker",
            )
        )

    assert connection.cancel_called
    assert connection.prompt_cancelled


def test_python_reminder_is_claimed_once_only_when_tool_was_not_called(monkeypatch) -> None:
    task = {"worker_id": "worker", "attempt": 1}

    monkeypatch.setattr(
        "xiaoqi_harness.capabilities.worker._requires_python_execution",
        lambda _messages: True,
    )
    monkeypatch.setattr(
        "xiaoqi_harness.capabilities.worker._task_state",
        lambda *_args: dict(task),
    )

    class _Record:
        def __init__(self, value):
            self.value = value

    def mutate(_tenant, _task_id, update):
        task.update(update(dict(task)))
        return _Record(dict(task))

    monkeypatch.setattr("xiaoqi_harness.capabilities.api._mutate_task", mutate)

    assert harness_worker._claim_python_reminder(
        object(), "tenant", "task", 1, "worker", [{"role": "user", "content": "use python"}]
    )
    assert not harness_worker._claim_python_reminder(
        object(), "tenant", "task", 1, "worker", [{"role": "user", "content": "use python"}]
    )

    task["harness_python_reminder_sent"] = False
    task["harness_python_tool_called"] = True
    assert not harness_worker._claim_python_reminder(
        object(), "tenant", "task", 1, "worker", [{"role": "user", "content": "use python"}]
    )
