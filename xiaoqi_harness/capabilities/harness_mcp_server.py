from __future__ import annotations

import json
import os
import threading
import time
import uuid
from typing import Any, Literal

from mcp.server.mcpserver import MCPServer

from .storage import CloudStore


_TOOL_LOCK = threading.Lock()


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Harness tool server is missing {name}")
    return value


class XiaoqiToolServer:
    """Expose existing Xiaoqi task tools over local MCP HTTP."""

    def __init__(self) -> None:
        from .worker import _domain_list, _task_state

        self.store = CloudStore()
        self.tenant = _required_env("XIAOQI_TASK_TENANT")
        self.task_id = _required_env("XIAOQI_TASK_ID")
        self.attempt = int(_required_env("XIAOQI_TASK_ATTEMPT"))
        self.worker_id = _required_env("XIAOQI_WORKER_ID")
        self.task = _task_state(self.store, self.tenant, self.task_id)
        if int(self.task.get("attempt", 0)) != self.attempt:
            raise RuntimeError("stale Harness tool-server attempt")
        if self.task.get("worker_id") != self.worker_id:
            raise RuntimeError("Harness tool server does not own this task")

        objects = self.store.get_immutable(str(self.task["input_object_key"]))
        self.task_request = json.loads(objects["input.json"].decode("utf-8"))
        self._domain_list = _domain_list

    def invoke(self, name: str, arguments: dict[str, Any]) -> str:
        from .worker import (
            NetworkPermissionRequired,
            TaskCancelled,
            TaskNotOwned,
            _emit,
            _ensure_active,
            _mark_tool_started,
            _run_tool,
        )
        from .api import _mutate_task

        call = {
            "id": uuid.uuid4().hex,
            "type": "function",
            "function": {
                "name": name,
                "arguments": json.dumps(arguments, ensure_ascii=False),
            },
        }

        # The worker's lease and tool limits assume one active tool at a time.
        # MCP requests are serialized so parallel model calls cannot race those checks.
        with _TOOL_LOCK:
            _ensure_active(
                self.store,
                self.tenant,
                self.task_id,
                self.attempt,
                self.worker_id,
            )
            _mark_tool_started(
                self.tenant, self.task_id, self.attempt, self.worker_id, call
            )
            _emit(self.store, self.tenant, self.task_id, {"type": "tool_started", "tool": name})

            if name == "execute_python":
                def mark_python_called(old: dict[str, Any]) -> dict[str, Any]:
                    if old.get("worker_id") != self.worker_id or int(old.get("attempt", 0)) != self.attempt:
                        raise TaskNotOwned("worker lease was replaced")
                    if old.get("cancel_requested"):
                        raise TaskCancelled("task was cancelled")
                    return {**old, "harness_python_tool_called": True, "updated_at": int(time.time())}

                _mutate_task(self.tenant, self.task_id, mark_python_called)

            current = self.store.get(f"task/{self.tenant}/{self.task_id}")
            authorized = set(
                self._domain_list(
                    (current.value if current is not None else {}).get(
                        "authorized_network_domains", []
                    )
                )
            )
            try:
                output = _run_tool(
                    self.store,
                    self.tenant,
                    self.task_id,
                    self.task_request,
                    call,
                    authorized,
                    self.attempt,
                    self.worker_id,
                )
            except NetworkPermissionRequired as required:
                def suspend(old: dict[str, Any]) -> dict[str, Any]:
                    if old.get("worker_id") != self.worker_id or int(old.get("attempt", 0)) != self.attempt:
                        raise TaskNotOwned("worker lease was replaced")
                    if old.get("cancel_requested"):
                        raise TaskCancelled("task was cancelled")
                    return {
                        **old,
                        "status": "awaiting_network_permission",
                        "pending_tool_calls": [call],
                        "active_tool_call": None,
                        "worker_id": None,
                        "worker_lease_until": 0,
                        "requested_network_domains": required.domains,
                        "network_purpose": required.purpose,
                        "updated_at": int(time.time()),
                    }

                _mutate_task(self.tenant, self.task_id, suspend)
                _emit(
                    self.store,
                    self.tenant,
                    self.task_id,
                    {
                        "type": "network_permission_required",
                        "domains": required.domains,
                        "purpose": required.purpose,
                    },
                )
                raise RuntimeError("本次工具调用已暂停，等待用户授权联网") from required
            except (TaskCancelled, TaskNotOwned):
                raise
            except Exception as error:
                output = json.dumps({"error": str(error)[:500]}, ensure_ascii=False)

            _ensure_active(
                self.store,
                self.tenant,
                self.task_id,
                self.attempt,
                self.worker_id,
            )
            def finish(old: dict[str, Any]) -> dict[str, Any]:
                if old.get("worker_id") != self.worker_id or int(old.get("attempt", 0)) != self.attempt:
                    raise TaskNotOwned("worker lease was replaced")
                if old.get("cancel_requested"):
                    raise TaskCancelled("task was cancelled")
                return {
                    **old,
                    "active_tool_call": None,
                    "updated_at": int(time.time()),
                }

            _mutate_task(self.tenant, self.task_id, finish)
            _emit(
                self.store,
                self.tenant,
                self.task_id,
                {"type": "tool_finished", "tool": name, "output": output},
            )
            return output


def create_server(task: XiaoqiToolServer) -> MCPServer:
    server = MCPServer(name="xiaoqi", log_level="ERROR")

    @server.tool(
        name="read_task_material",
        description="读取本次任务明确附带的资料文本。只能使用资料 ID。",
    )
    def read_task_material(material_id: str) -> str:
        return task.invoke("read_task_material", {"material_id": material_id})

    @server.tool(
        name="read_skill_resource",
        description="读取已授权技能版本中的一个资源文件。",
    )
    def read_skill_resource(capability_id: str, version_id: str, path: str) -> str:
        return task.invoke(
            "read_skill_resource",
            {
                "capability_id": capability_id,
                "version_id": version_id,
                "path": path,
            },
        )

    @server.tool(
        name="draft_workspace",
        description="列出、读取或写入当前任务的临时草稿文件；不会直接保存正式技能。",
    )
    def draft_workspace(
        action: Literal["list", "read", "write"],
        path: str = "SKILL.md",
        content: str = "",
    ) -> str:
        arguments: dict[str, Any] = {"action": action}
        if action != "list":
            arguments["path"] = path
        if action == "write":
            arguments["content"] = content
        return task.invoke("draft_workspace", arguments)

    @server.tool(
        name="execute_python",
        description=(
            "在隔离的 E2B Python 沙箱运行计算或数据转换。默认断网；"
            "需要交付的文件写入 /home/user/workspace/output。"
        ),
    )
    def execute_python(
        code: str,
        network_domains: list[str] | None = None,
        network_purpose: str = "脚本需要访问指定网站",
    ) -> str:
        arguments: dict[str, Any] = {"code": code}
        if network_domains is not None:
            arguments["network_domains"] = network_domains
        if network_purpose:
            arguments["network_purpose"] = network_purpose
        return task.invoke("execute_python", arguments)

    return server


def main() -> None:
    port = int(_required_env("XIAOQI_MCP_PORT"))
    if not 1 <= port <= 65535:
        raise RuntimeError("XIAOQI_MCP_PORT must be between 1 and 65535")
    # ACP in the pinned Harness runtime accepts HTTP MCP servers. Bind only to
    # loopback because this endpoint carries task-scoped credentials.
    create_server(XiaoqiToolServer()).run(
        transport="streamable-http",
        host="127.0.0.1",
        port=port,
        streamable_http_path="/mcp",
        json_response=True,
        stateless_http=True,
    )


if __name__ == "__main__":
    main()
