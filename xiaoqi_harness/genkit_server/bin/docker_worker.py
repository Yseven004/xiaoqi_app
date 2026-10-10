#!/usr/bin/env python3
"""Private HTTP client for the server's constrained local Docker runner."""

from __future__ import annotations

import json
import os
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
    outgoing = urllib.request.Request(
        f"{base_url}/v1/execute",
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/x-ndjson",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(outgoing, timeout=270) as response:
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
            "artifacts": [],
        })
        return 1
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        _emit({
            "type": "result",
            "ok": False,
            "error": f"本机 Docker 沙箱连接失败（{type(error).__name__}）",
            "artifacts": [],
        })
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
