from __future__ import annotations

import hmac
import os
from typing import Any

from flask import Blueprint, jsonify, request

from .api import _error, _json_body, _safe_id, store


worker_api = Blueprint("xiaoqi_agent_worker", __name__)


def _authorized() -> bool:
    expected = os.environ.get("CAPABILITY_TASK_INTERNAL_TOKEN", "")
    supplied = request.headers.get("Authorization", "").removeprefix("Bearer ")
    return len(expected) >= 32 and hmac.compare_digest(supplied, expected)


@worker_api.post("/v1/internal/agent/tasks/run")
def run_agent_task() -> Any:
    if not _authorized():
        return _error("not found", 404)
    try:
        body = _json_body(1024)
        tenant_id = _safe_id(body.get("tenant_id"), "测试身份")
        task_id = _safe_id(body.get("task_id"), "任务 ID")
        attempt = int(body.get("attempt", 0))
        from .worker import run_task

        run_task(store(), tenant_id, task_id, attempt)
        return jsonify({"ok": True})
    except Exception as error:
        from .worker import TaskAlreadyRunning, TaskNotOwned

        if isinstance(error, (TaskAlreadyRunning, TaskNotOwned)):
            return jsonify({"ok": True, "duplicate": True})
        return jsonify({"error": "task failed"}), 500


@worker_api.post("/v1/internal/agent/tasks/cancel")
def cancel_agent_sandbox() -> Any:
    if not _authorized():
        return _error("not found", 404)
    try:
        body = _json_body(1024)
        sandbox_id = _safe_id(body.get("sandbox_id"), "沙箱 ID")
        connection = {
            "api_key": os.environ.get("E2B_API_KEY", "").strip(),
            "api_url": os.environ.get("E2B_API_URL", "").strip(),
            "domain": os.environ.get("E2B_DOMAIN", "").strip(),
        }
        if not all(connection.values()):
            return _error("Agent Sandbox 未配置", 503)
        from e2b_code_interpreter import Sandbox

        Sandbox.kill(sandbox_id, **connection)
        return jsonify({"ok": True})
    except Exception:
        return _error("停止 Python 沙箱失败", 503)
