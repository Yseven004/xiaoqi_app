from __future__ import annotations

import base64
import json
import os
import re
import time
import urllib.error
import urllib.request
from typing import Any

from .storage import CloudStore


_MAX_STEPS = 16
_MAX_TOOL_OUTPUT = 128 * 1024
_MAX_TRANSCRIPT = 3 * 1024 * 1024
_SAFE_FILE = re.compile(r"^[A-Za-z0-9._/-]{1,240}$")

_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_task_material",
            "description": "读取本次任务明确附带的资料文本。只能使用资料 ID，不得读取其他账户或设备文件。",
            "parameters": {
                "type": "object",
                "properties": {"material_id": {"type": "string"}},
                "required": ["material_id"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_skill_resource",
            "description": "读取已授权技能版本中的一个资源文件。",
            "parameters": {
                "type": "object",
                "properties": {
                    "capability_id": {"type": "string"},
                    "version_id": {"type": "string"},
                    "path": {"type": "string"},
                },
                "required": ["capability_id", "version_id", "path"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "draft_workspace",
            "description": "列出、读取或写入当前任务的临时草稿文件。只能改临时区，不会直接保存正式技能。",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["list", "read", "write"]},
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["action"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "execute_python",
            "description": "在隔离的 E2B Python 沙箱运行需要真正计算、数据转换或脚本试用的代码。每个任务最多运行一次，默认断网；只有用户另行授权的域名才可联网。",
            "parameters": {
                "type": "object",
                "properties": {
                    "code": {"type": "string"},
                    "network_domains": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "确需联网时列出精确域名；未列出时保持断网。",
                    },
                    "network_purpose": {"type": "string"},
                },
                "required": ["code"],
                "additionalProperties": False,
            },
        },
    },
]


class TaskCancelled(Exception):
    pass


class NetworkPermissionRequired(Exception):
    def __init__(self, domains: list[str], purpose: str) -> None:
        self.domains = domains
        self.purpose = purpose


def _json_zip(store: CloudStore, key: str) -> dict[str, Any]:
    files = store.get_immutable(key)
    raw = files.get("input.json", b"{}")
    return json.loads(raw.decode("utf-8"))


def _clean_output(value: Any) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    encoded = text.encode("utf-8")
    if len(encoded) > _MAX_TOOL_OUTPUT:
        text = encoded[:_MAX_TOOL_OUTPUT].decode("utf-8", errors="ignore") + "\n[输出已截断]"
    return text


def _domain_list(value: Any) -> list[str]:
    if not isinstance(value, list) or len(value) > 8:
        raise ValueError("联网域名列表最多 8 项")
    domains: list[str] = []
    for raw in value:
        domain = str(raw).strip().lower().rstrip(".")
        if not domain or ":" in domain or "/" in domain or "*" in domain or "@" in domain:
            raise ValueError("联网权限只接受精确域名")
        if not re.fullmatch(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain):
            raise ValueError("联网权限域名格式无效")
        domains.append(domain)
    return sorted(set(domains))


def _read_history(store: CloudStore, task: dict[str, Any]) -> list[dict[str, Any]] | None:
    key = task.get("transcript_blob_key")
    if not key:
        return None
    raw = store.get_task_blob(str(key))
    value = json.loads(raw.decode("utf-8"))
    return value if isinstance(value, list) else None


def _save_history(store: CloudStore, tenant: str, task_id: str, messages: list[dict[str, Any]]) -> None:
    raw = json.dumps(messages, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(raw) > _MAX_TRANSCRIPT:
        raise ValueError("任务对话超过恢复上限")
    key = f"tenants/{tenant}/tasks/{task_id}/transcript.json"
    store.put_task_blob(key, raw)
    from .api import _mutate_task

    _mutate_task(
        tenant,
        task_id,
        lambda old: {**old, "transcript_blob_key": key, "updated_at": int(time.time())},
    )


def _task_state(store: CloudStore, tenant: str, task_id: str) -> dict[str, Any]:
    task = store.get(f"task/{tenant}/{task_id}")
    if task is None:
        raise KeyError(task_id)
    return task.value


def _emit(store: CloudStore, tenant: str, task_id: str, event: dict[str, Any]) -> dict[str, Any]:
    from .api import _mutate_task

    now = int(time.time())

    def update(old: dict[str, Any]) -> dict[str, Any]:
        events = list(old.get("events", []))
        events.append({"seq": int(events[-1].get("seq", -1)) + 1 if events else 0, "created_at": now, **event})
        return {**old, "events": events[-200:], "updated_at": now}

    return _mutate_task(tenant, task_id, update).value


def _ensure_active(store: CloudStore, tenant: str, task_id: str, attempt: int) -> dict[str, Any]:
    task = _task_state(store, tenant, task_id)
    if int(task.get("attempt", 0)) != attempt:
        raise TaskCancelled("stale task attempt")
    if task.get("cancel_requested"):
        raise TaskCancelled("task was cancelled")
    return task


def _model_request(
    model_id: str,
    reasoning_level: str,
    messages: list[dict[str, Any]],
    on_delta: Any,
) -> dict[str, Any]:
    is_mimo = model_id.startswith("mimo")
    key = os.environ.get("MIMO_API_KEY" if is_mimo else "DEEPSEEK_API_KEY", "")
    if not key:
        raise RuntimeError("所选模型的服务端密钥尚未配置")
    url = (
        "https://api.xiaomimimo.com/v1/chat/completions"
        if is_mimo
        else "https://api.deepseek.com/chat/completions"
    )
    payload: dict[str, Any] = {
        "model": model_id,
        "messages": messages,
        "tools": _TOOLS,
        "tool_choice": "auto",
        "stream": True,
    }
    if is_mimo:
        payload["thinking"] = {"type": "disabled" if reasoning_level == "low" else "enabled"}
    else:
        payload["reasoning_effort"] = {"low": "low", "medium": "high", "high": "max"}.get(reasoning_level, "high")
    req = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "Accept": "text/event-stream"},
        method="POST",
    )
    content: list[str] = []
    reasoning: list[str] = []
    tools: dict[int, dict[str, Any]] = {}
    pending_text = ""
    try:
        response = urllib.request.urlopen(req, timeout=100)
    except urllib.error.HTTPError as error:
        error.read(4096)
        raise RuntimeError(f"模型服务暂不可用（HTTP {error.code}）") from error
    with response:
        if "text/event-stream" not in response.headers.get("Content-Type", ""):
            decoded = json.loads(response.read().decode("utf-8"))
            message = decoded["choices"][0]["message"]
            if message.get("content"):
                on_delta(message["content"])
            return message
        for line in response:
            line = line.decode("utf-8", errors="ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                event = json.loads(data)
            except json.JSONDecodeError:
                continue
            choices = event.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            text = delta.get("content")
            if isinstance(text, str) and text:
                content.append(text)
                pending_text += text
                if len(pending_text) >= 240:
                    on_delta(pending_text)
                    pending_text = ""
            thought = delta.get("reasoning_content")
            if isinstance(thought, str) and thought:
                reasoning.append(thought)
            for item in delta.get("tool_calls") or []:
                index = int(item.get("index", 0))
                call = tools.setdefault(index, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                if item.get("id"):
                    call["id"] = item["id"]
                function = item.get("function") or {}
                call["function"]["name"] += function.get("name", "")
                call["function"]["arguments"] += function.get("arguments", "")
    if pending_text:
        on_delta(pending_text)
    result: dict[str, Any] = {"role": "assistant", "content": "".join(content)}
    if reasoning:
        result["reasoning_content"] = "".join(reasoning)
    if tools:
        result["tool_calls"] = [tools[index] for index in sorted(tools)]
    return result


def _safe_resource_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    if not _SAFE_FILE.fullmatch(normalized) or normalized.startswith("/") or any(part in ("", ".", "..") for part in normalized.split("/")):
        raise ValueError("资源路径无效")
    return normalized


def _execute_python(
    store: CloudStore,
    tenant: str,
    task_id: str,
    code: str,
    domains: list[str],
    task_request: dict[str, Any],
) -> str:
    if len(code.encode("utf-8")) > 64 * 1024:
        raise ValueError("Python 脚本超过 64 KB")
    if not os.environ.get("E2B_API_KEY"):
        raise RuntimeError("E2B 尚未配置，纯文字能力仍可继续使用")
    from e2b_code_interpreter import Sandbox

    sandbox = None
    try:
        sandbox_options: dict[str, Any] = {
            "timeout": 300,
            "allow_internet_access": bool(domains),
            "metadata": {"xiaoqi_task_id": task_id},
        }
        if domains:
            sandbox_options["network"] = {"allow_out": domains}
        sandbox = Sandbox.create(api_key=os.environ["E2B_API_KEY"], **sandbox_options)
        from .api import _mutate_task

        _mutate_task(tenant, task_id, lambda old: {**old, "sandbox_id": sandbox.sandbox_id, "updated_at": int(time.time())})

        # Only explicitly attached materials are copied into this sandbox.
        for index, material in enumerate(task_request.get("materials", [])):
            if not isinstance(material, dict):
                continue
            name = os.path.basename(str(material.get("name") or f"material-{index}.txt"))
            name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:100] or f"material-{index}.txt"
            content = material.get("text")
            if isinstance(content, str):
                data = content.encode("utf-8")
            elif material.get("base64"):
                data = base64.b64decode(str(material["base64"]), validate=True)
            else:
                continue
            if len(data) > 20 * 1024 * 1024:
                raise ValueError("单个任务资料超过 20 MB")
            sandbox.files.write(f"/home/user/workspace/materials/{index}-{name}", data)

        capability_ref = task_request.get("capability")
        if isinstance(capability_ref, dict):
            capability_id = str(capability_ref.get("id", ""))
            version_id = str(capability_ref.get("version_id", ""))
            record = store.get(f"cap/{tenant}/{capability_id}")
            if record and not record.value.get("deleted_at"):
                version = next((item for item in record.value.get("versions", []) if item.get("id") == version_id), None)
                if version:
                    files = store.get_immutable(version["artifact_key"])
                    for name, data in files.items():
                        path = _safe_resource_path(name)
                        sandbox.files.write(f"/home/user/workspace/skill/{path}", data)

        execution = sandbox.run_code(code, language="python", timeout=120)
        logs = execution.logs
        stdout = str(getattr(logs, "stdout", "") or "")
        stderr = str(getattr(logs, "stderr", "") or "")
        result_items = []
        for item in getattr(execution, "results", []) or []:
            text = getattr(item, "text", None)
            if text:
                result_items.append(str(text))
        output = "\n".join(part for part in [stdout, stderr, *result_items] if part)
        return _clean_output(output or "Python 已执行，没有标准输出。")
    finally:
        if sandbox is not None:
            try:
                sandbox.kill()
            except Exception:
                pass
        from .api import _mutate_task

        try:
            _mutate_task(tenant, task_id, lambda old: {**old, "sandbox_id": None, "updated_at": int(time.time())})
        except Exception:
            pass


def _run_tool(
    store: CloudStore,
    tenant: str,
    task_id: str,
    task_request: dict[str, Any],
    call: dict[str, Any],
    authorized_domains: set[str],
) -> str:
    function = call.get("function") or {}
    name = str(function.get("name", ""))
    try:
        arguments = json.loads(function.get("arguments") or "{}")
    except json.JSONDecodeError as error:
        raise ValueError("工具参数不是有效 JSON") from error

    if name == "read_task_material":
        material_id = str(arguments.get("material_id", ""))
        for material in task_request.get("materials", []):
            if isinstance(material, dict) and str(material.get("id", "")) == material_id:
                return _clean_output(material.get("text") or "[该资料只提供了二进制附件]")
        raise ValueError("该资料不在本次任务授权范围内")

    if name == "read_skill_resource":
        capability_id = str(arguments.get("capability_id", ""))
        version_id = str(arguments.get("version_id", ""))
        path = _safe_resource_path(str(arguments.get("path", "")))
        record = store.get(f"cap/{tenant}/{capability_id}")
        if record is None or record.value.get("deleted_at"):
            raise ValueError("技能不存在或已删除")
        version = next((item for item in record.value.get("versions", []) if item.get("id") == version_id), None)
        if version is None:
            raise ValueError("技能版本不存在")
        files = store.get_immutable(version["artifact_key"])
        if path not in files:
            raise ValueError("技能版本中没有这个资源")
        return _clean_output(files[path].decode("utf-8", errors="replace"))

    if name == "draft_workspace":
        action = arguments.get("action")
        path = _safe_resource_path(str(arguments.get("path", "SKILL.md"))) if action != "list" else ""
        task = _task_state(store, tenant, task_id)
        files = dict(task.get("draft_files", {}))
        if action == "list":
            return json.dumps(sorted(files), ensure_ascii=False)
        if action == "read":
            if path not in files:
                raise ValueError("草稿文件不存在")
            return _clean_output(files[path])
        if action == "write":
            if path != "SKILL.md" and not path.startswith(("scripts/", "references/", "assets/")):
                raise ValueError("草稿资源只能放在 scripts、references 或 assets 目录")
            if path.startswith("scripts/") and not path.lower().endswith(".py"):
                raise ValueError("首版只支持 Python 脚本")
            content = str(arguments.get("content", ""))
            files[path] = content
            if sum(len(str(value).encode("utf-8")) for value in files.values()) > _MAX_TRANSCRIPT:
                raise ValueError("草稿工作区超过大小限制")
            from .api import _mutate_task

            _mutate_task(tenant, task_id, lambda old: {**old, "draft_files": files, "updated_at": int(time.time())})
            _emit(store, tenant, task_id, {"type": "draft_updated", "path": path, "size": len(content.encode("utf-8"))})
            return "草稿已写入临时工作区，等待用户确认保存。"
        raise ValueError("草稿操作无效")

    if name == "execute_python":
        task = _task_state(store, tenant, task_id)
        if int(task.get("python_runs", 0)) >= 1:
            raise ValueError("本次任务的 Python 执行次数已用完")
        domains = _domain_list(arguments.get("network_domains", []))
        if not set(domains).issubset(authorized_domains):
            raise NetworkPermissionRequired(domains, str(arguments.get("network_purpose", "脚本需要访问指定网站"))[:500])
        from .api import _mutate_task

        _mutate_task(tenant, task_id, lambda old: {**old, "python_runs": int(old.get("python_runs", 0)) + 1, "updated_at": int(time.time())})
        return _execute_python(store, tenant, task_id, str(arguments.get("code", "")), domains, task_request)

    raise ValueError("工具未开放")


def run_task(store: CloudStore, tenant: str, task_id: str, attempt: int) -> None:
    from .api import _mutate_task

    task = _ensure_active(store, tenant, task_id, attempt)
    if task.get("status") == "awaiting_network_permission" and not task.get("authorized_network_domains"):
        return
    input_files = store.get_immutable(str(task["input_object_key"]))
    task_request = json.loads(input_files["input.json"].decode("utf-8"))
    if task.get("transcript_blob_key"):
        messages = _read_history(store, task) or []
    else:
        messages = list(task_request.get("messages", []))
    if not isinstance(messages, list) or not messages:
        raise ValueError("任务中没有模型上下文")

    system_addition = (
        "\n\n小栖工具规则：需要实际运行 Python 时直接调用 execute_python，不要只描述执行结果；"
        "联网默认关闭。若脚本确实需要联网，在工具参数里列出具体域名并说明用途，系统会单独请求用户授权。"
        "创建技能时请将最终 SKILL.md 写入 draft_workspace，并在最终回复中展示代表性试用结果。"
        "你只能修改临时草稿，不能声称已保存；正式保存由用户点击完成。"
    )
    already_has_rules = bool(
        messages
        and messages[0].get("role") == "system"
        and "小栖工具规则" in str(messages[0].get("content", ""))
    )
    if messages and messages[0].get("role") == "system" and not already_has_rules:
        messages[0] = {**messages[0], "content": str(messages[0].get("content", "")) + system_addition}
    elif not messages or messages[0].get("role") != "system":
        messages.insert(0, {"role": "system", "content": system_addition.strip()})

    task = _mutate_task(tenant, task_id, lambda old: {**old, "status": "running", "updated_at": int(time.time())}).value
    _emit(store, tenant, task_id, {"type": "status", "status": "running"})

    try:
        pending_calls = list(task.get("pending_tool_calls", []))
        if pending_calls:
            authorized = set(_domain_list(task.get("authorized_network_domains", [])))
            for call in pending_calls:
                _ensure_active(store, tenant, task_id, attempt)
                try:
                    output = _run_tool(store, tenant, task_id, task_request, call, authorized)
                except NetworkPermissionRequired as required:
                    _mutate_task(tenant, task_id, lambda old: {**old, "status": "awaiting_network_permission", "pending_tool_calls": pending_calls, "requested_network_domains": required.domains, "network_purpose": required.purpose, "updated_at": int(time.time())})
                    _emit(store, tenant, task_id, {"type": "network_permission_required", "domains": required.domains, "purpose": required.purpose})
                    return
                messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": output})
                _save_history(store, tenant, task_id, messages)
            _mutate_task(tenant, task_id, lambda old: {**old, "pending_tool_calls": [], "requested_network_domains": [], "network_purpose": None, "updated_at": int(time.time())})

        for step in range(_MAX_STEPS):
            _ensure_active(store, tenant, task_id, attempt)
            model_id = str(task_request.get("model_id", "deepseek-flash"))
            reasoning_level = str(task_request.get("reasoning_level", "medium"))

            def on_delta(text: str) -> None:
                _emit(store, tenant, task_id, {"type": "assistant_delta", "text": text})

            assistant = _model_request(model_id, reasoning_level, messages, on_delta)
            _ensure_active(store, tenant, task_id, attempt)
            assistant["role"] = "assistant"
            messages.append(assistant)
            _save_history(store, tenant, task_id, messages)
            calls = assistant.get("tool_calls") or []
            if not calls:
                final_text = str(assistant.get("content", ""))
                task = _mutate_task(tenant, task_id, lambda old: {**old, "status": "succeeded", "result": final_text, "draft": old.get("draft_files", {}).get("SKILL.md"), "updated_at": int(time.time())}).value
                encoded_files = {
                    name: base64.b64encode(str(content).encode("utf-8")).decode("ascii")
                    for name, content in task.get("draft_files", {}).items()
                }
                _emit(store, tenant, task_id, {"type": "completed", "status": "succeeded", "text": final_text, "draft": task.get("draft"), "files": encoded_files})
                return

            authorized = set(_domain_list(_task_state(store, tenant, task_id).get("authorized_network_domains", [])))
            for call_index, call in enumerate(calls):
                _ensure_active(store, tenant, task_id, attempt)
                function_name = str((call.get("function") or {}).get("name", ""))
                _emit(store, tenant, task_id, {"type": "tool_started", "tool": function_name})
                try:
                    output = _run_tool(store, tenant, task_id, task_request, call, authorized)
                except NetworkPermissionRequired as required:
                    remaining = calls[call_index:]
                    _mutate_task(tenant, task_id, lambda old: {**old, "status": "awaiting_network_permission", "pending_tool_calls": remaining, "requested_network_domains": required.domains, "network_purpose": required.purpose, "updated_at": int(time.time())})
                    _emit(store, tenant, task_id, {"type": "network_permission_required", "domains": required.domains, "purpose": required.purpose})
                    _save_history(store, tenant, task_id, messages)
                    return
                except Exception as error:
                    output = json.dumps({"error": str(error)[:500]}, ensure_ascii=False)
                messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": _clean_output(output)})
                _save_history(store, tenant, task_id, messages)
                _emit(store, tenant, task_id, {"type": "tool_finished", "tool": function_name, "output": _clean_output(output)})
        raise RuntimeError("工具调用次数达到本次任务上限")
    except TaskCancelled:
        _mutate_task(tenant, task_id, lambda old: {**old, "status": "cancelled", "sandbox_id": None, "updated_at": int(time.time())})
        _emit(store, tenant, task_id, {"type": "status", "status": "cancelled"})
    except Exception as error:
        _mutate_task(tenant, task_id, lambda old: {**old, "status": "failed", "error": str(error)[:500], "sandbox_id": None, "updated_at": int(time.time())})
        _emit(store, tenant, task_id, {"type": "error", "status": "failed", "message": str(error)[:500]})
