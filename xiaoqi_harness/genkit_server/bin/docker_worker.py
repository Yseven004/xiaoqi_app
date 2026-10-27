#!/usr/bin/env python3
"""Private HTTP client for the server's constrained local Docker runner."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any


def _emit(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main() -> int:
    try:
        request = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        _emit({"type": "result", "ok": False, "error": "沙箱请求格式无效", "artifacts": []})
        return 1

    base_url = os.environ.get("SANDBOX_RUNNER_URL", "").strip().rstrip("/")
    token = os.environ.get("SANDBOX_RUNNER_TOKEN", "").strip()
    if not base_url or not token:
        _emit({
            "type": "result",
            "ok": False,
            "error": "服务器本机 Docker 沙箱执行器尚未配置",
            "artifacts": [],
        })
        return 1

    payload = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    disable_network = request.get("action") == "disable_network"
    cancel_execution = request.get('action') == 'cancel_execution'
    execution_action = {'cancel_execution': 'cancel', 'execution_result': 'result', 'ack_execution': 'ack'}.get(request.get('action'))
    control = disable_network or execution_action is not None
    task_id = request.get("task_id")
    if control and (
        not isinstance(task_id, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task_id)
    ):
        _emit({"type": "result", "ok": False, "error": "任务 ID 无效"})
        return 1
    execution_id = request.get('execution_id')
    if execution_action is not None and (not isinstance(execution_id, str) or not re.fullmatch(r'[a-f0-9]{32}', execution_id)):
        _emit({'type': 'result', 'ok': False, 'error': '执行 ID 无效'})
        return 1
    endpoint = f'{base_url}/v1/executions/{execution_id}/{execution_action}' if execution_action is not None else (
        f"{base_url}/v1/tasks/{task_id}/network/off"
        if disable_network
        else f"{base_url}/v1/execute"
    )
    outgoing = urllib.request.Request(
        endpoint,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json" if control else "application/x-ndjson",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(outgoing, timeout=5 if execution_action is not None else 30 if disable_network else 270) as response:
            if control:
                try:
                    raw = response.read(32 * 1024 * 1024 + 1)
                    if len(raw) > 32 * 1024 * 1024:
                        raise ValueError('Control response exceeds capacity')
                    result = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    result = {"ok": False, "error": "本机 Docker 沙箱返回了无效的控制响应"}
                if not isinstance(result, dict) or result.get("ok") is not True:
                    _emit({
                        "type": "result",
                        "ok": False,
                        "error": result.get("error", "无法完成沙箱控制请求")
                        if isinstance(result, dict)
                        else "本机 Docker 沙箱返回了无效的控制响应",
                    })
                    return 1
                _emit({"type": "result", "ok": True, **result})
                return 0
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                # Forward only protocol events. Runner diagnostics and access logs
                # are never mixed into the task's user-visible output.
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(event, dict) and event.get("type") in {"sandbox_started", "heartbeat", "result"}:
                    _emit(event)
    except urllib.error.HTTPError as error:
        _emit({
            "type": "result",
            "ok": False,
            "error": f"本机 Docker 沙箱拒绝了请求（HTTP {error.code}）",
            "transport_error": True,
            "artifacts": [],
        })
        return 1
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        _emit({
            "type": "result",
            "ok": False,
            "error": f"本机 Docker 沙箱连接失败（{type(error).__name__}）",
            "transport_error": True,
            "artifacts": [],
        })
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
