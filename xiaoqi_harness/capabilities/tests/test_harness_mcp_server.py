from __future__ import annotations

import asyncio

from xiaoqi_harness.capabilities import harness_mcp_server


class _Task:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    def invoke(self, name: str, arguments: dict[str, object]) -> str:
        self.calls.append((name, arguments))
        return "ok"


def test_server_exposes_only_existing_xiaoqi_tools() -> None:
    task = _Task()
    server = harness_mcp_server.create_server(task)  # type: ignore[arg-type]

    tools = asyncio.run(server.list_tools())

    assert [tool.name for tool in tools] == [
        "read_task_material",
        "read_skill_resource",
        "draft_workspace",
        "execute_python",
    ]
    python_tool = next(tool for tool in tools if tool.name == "execute_python")
    assert python_tool.input_schema["required"] == ["code"]


def test_main_binds_streamable_http_to_loopback(monkeypatch) -> None:
    captured: dict[str, object] = {}

    class _Server:
        def run(self, **kwargs: object) -> None:
            captured.update(kwargs)

    monkeypatch.setenv("XIAOQI_MCP_PORT", "18765")
    monkeypatch.setattr(harness_mcp_server, "XiaoqiToolServer", lambda: object())
    monkeypatch.setattr(harness_mcp_server, "create_server", lambda _: _Server())

    harness_mcp_server.main()

    assert captured == {
        "transport": "streamable-http",
        "host": "127.0.0.1",
        "port": 18765,
        "streamable_http_path": "/mcp",
        "json_response": True,
        "stateless_http": True,
    }
