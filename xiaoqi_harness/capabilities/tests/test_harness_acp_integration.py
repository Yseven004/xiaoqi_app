from __future__ import annotations

import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
import textwrap
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from xiaoqi_harness.capabilities import harness_worker, worker


class _MockModel(BaseHTTPRequestHandler):
    requests: list[dict[str, Any]] = []

    def log_message(self, *_args: Any) -> None:
        pass

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(body)
        tool_name = next(
            (
                item["function"]["name"]
                for item in body.get("tools", [])
                if item.get("function", {}).get("name", "").endswith("__ping")
            ),
            None,
        )
        if len(self.requests) == 1 and tool_name:
            delta = {
                "tool_calls": [
                    {
                        "index": 0,
                        "id": "call-smoke",
                        "type": "function",
                        "function": {"name": tool_name, "arguments": "{}"},
                    }
                ]
            }
            if str(body.get("model", "")).startswith("mimo"):
                delta["reasoning_content"] = "mock MiMo reasoning"
            finish = "tool_calls"
        else:
            delta = {"content": "Harness session continued."}
            finish = "stop"

        chunks = [
            {
                "id": "chatcmpl-smoke",
                "object": "chat.completion.chunk",
                "created": 1,
                "model": body.get("model", "mock"),
                "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
            },
            {
                "id": "chatcmpl-smoke",
                "object": "chat.completion.chunk",
                "created": 1,
                "model": body.get("model", "mock"),
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
            },
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")


class _Store:
    def __init__(self, model_id: str, with_image: bool) -> None:
        self.snapshot = b""
        self.model_id = model_id
        self.with_image = with_image

    def get_immutable(self, _key: str) -> dict[str, bytes]:
        image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        content: Any = "Call ping and remember this task."
        if self.with_image:
            content = [
                {"type": "text", "text": "Call ping and remember this task."},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image}"}},
            ]
        request = {
            "model_id": self.model_id,
            "reasoning_level": "medium",
            "messages": [{"role": "user", "content": content}],
        }
        return {"input.json": json.dumps(request).encode("utf-8")}

    def get_task_blob(self, _key: str) -> bytes:
        return self.snapshot


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _start_mcp(port: int) -> subprocess.Popen[bytes]:
    script = textwrap.dedent(
        """
        import sys
        from mcp.server.mcpserver import MCPServer
        server = MCPServer(name="xiaoqi", log_level="ERROR")
        @server.tool(name="ping", description="smoke test")
        def ping():
            return "mcp_round_trip_ok"
        server.run(transport="streamable-http", host="127.0.0.1", port=int(sys.argv[1]), streamable_http_path="/mcp", json_response=True, stateless_http=True)
        """
    )
    return subprocess.Popen(
        [sys.executable, "-c", script, str(port)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _wait_for_mcp(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("mock MCP process stopped before serving")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("mock MCP server did not start")


@pytest.mark.parametrize(
    ("model_id", "with_image"),
    [
        ("deepseek-flash", True),
        ("mimo-v2.6-flash", False),
        ("mimo-v2.6-flash", True),
    ],
)
def test_harness_mcp_round_trip_and_session_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, model_id: str, with_image: bool
) -> None:
    dsh = shutil.which("dsh") or str(
        Path(sys.executable).parent / ("dsh.exe" if os.name == "nt" else "dsh")
    )
    if not Path(dsh).is_file():
        pytest.skip("DeepSeek Harness Runtime is not installed in this test environment")

    _MockModel.requests = []
    model = ThreadingHTTPServer(("127.0.0.1", 0), _MockModel)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    mcp_port = _free_port()
    mcp_processes: list[subprocess.Popen[bytes]] = []

    def start_mcp(*_args: Any) -> tuple[subprocess.Popen[bytes], int]:
        process = _start_mcp(mcp_port)
        mcp_processes.append(process)
        _wait_for_mcp(process, mcp_port)
        return process, mcp_port

    store = _Store(model_id, with_image)
    monkeypatch.setattr(
        harness_worker,
        "_model_settings",
        lambda _model: ("mock-key", f"http://127.0.0.1:{model.server_port}/v1"),
    )
    monkeypatch.setattr(harness_worker, "_start_tool_server", start_mcp)
    monkeypatch.setattr(worker, "_ensure_active", lambda *_args: {})
    monkeypatch.setattr(worker, "_emit", lambda *_args: None)

    workspace = tmp_path / "workspace"
    workspace.mkdir()
    task_request = json.loads(store.get_immutable("input.json")["input.json"])
    first_task = {"input_object_key": "input.json"}
    try:
        session_id, first_text = asyncio.run(
            harness_worker._run_acp(
                store,
                first_task,
                task_request,
                "tenant",
                "task",
                1,
                "worker-1",
                tmp_path / "home-1",
                workspace,
            )
        )
        store.snapshot = harness_worker._make_snapshot(tmp_path / "home-1")
        second_task = {
            "input_object_key": "input.json",
            "harness_session_id": session_id,
            "harness_snapshot_key": "snapshot.zip",
        }
        resumed_id, resumed_text = asyncio.run(
            harness_worker._run_acp(
                store,
                second_task,
                task_request,
                "tenant",
                "task",
                2,
                "worker-2",
                tmp_path / "home-2",
                workspace,
            )
        )
    finally:
        for process in mcp_processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        model.shutdown()
        model.server_close()

    tools = [
        item["function"]["name"]
        for item in _MockModel.requests[0].get("tools", [])
    ]
    assert session_id == resumed_id
    assert "Harness session continued." in first_text
    assert "Harness session continued." in resumed_text
    assert tools == ["mcp__xiaoqi__ping"]
    assert any(name.startswith("sessions/") for name in zipfile_names(store.snapshot))
    request_contents = [message.get("content") for message in _MockModel.requests[0]["messages"]]
    if with_image:
        assert any(
            isinstance(content, list)
            and any(isinstance(part, dict) and part.get("type") == "image_url" for part in content)
            for content in request_contents
        )
    if model_id == "deepseek-flash":
        assert _MockModel.requests[0].get("thinking") == {"type": "enabled"}
        assert _MockModel.requests[0].get("reasoning_effort") == "high"
    else:
        assert _MockModel.requests[0].get("thinking") == {"type": "enabled"}
        assert "reasoning_effort" not in _MockModel.requests[0]
        replayed = [
            message
            for message in _MockModel.requests[1]["messages"]
            if message.get("role") == "assistant" and message.get("tool_calls")
        ]
        assert replayed
        assert replayed[-1].get("reasoning_content") == "mock MiMo reasoning"


def zipfile_names(snapshot: bytes) -> list[str]:
    import zipfile
    from io import BytesIO

    with zipfile.ZipFile(BytesIO(snapshot)) as archive:
        return archive.namelist()
