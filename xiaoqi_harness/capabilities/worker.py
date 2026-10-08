from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import os
import re
import time
import uuid
from pathlib import PurePosixPath
from typing import Any

from .storage import CloudStore


_MAX_TOOL_OUTPUT = 128 * 1024
_MAX_TOOL_READ_CHARS = 20_000
_MAX_TRANSCRIPT = 3 * 1024 * 1024
_MAX_ARTIFACTS = 10
_MAX_ARTIFACT_SIZE = 10 * 1024 * 1024
_MAX_ARTIFACT_TOTAL = 20 * 1024 * 1024
_WORKER_LEASE_SECONDS = 300
_SAFE_FILE = re.compile(r"^[A-Za-z0-9._/-]{1,240}$")



class TaskCancelled(Exception):
    pass


class TaskNotOwned(Exception):
    pass


class TaskAlreadyRunning(Exception):
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


def _read_text_chunk(text: str, offset: Any, limit: Any) -> str:
    if type(offset) is not int or offset < 0:
        raise ValueError("资料读取 offset 必须是非负整数")
    if type(limit) is not int or limit < 1:
        raise ValueError("资料读取 limit 必须是正整数")
    if offset > len(text):
        raise ValueError("资料读取 offset 超出文本长度")

    end = min(len(text), offset + min(limit, _MAX_TOOL_READ_CHARS))
    if offset == 0 and end == len(text):
        return text
    continuation = (
        f"继续读取请使用 offset={end}。" if end < len(text) else "已到末尾。"
    )
    return f"[全文共 {len(text)} 个字符，当前 {offset}–{end}。{continuation}]\n{text[offset:end]}"


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


def _claim_task(
    store: CloudStore, tenant: str, task_id: str, attempt: int, worker_id: str
) -> bool:
    from .api import _mutate_task

    claimed = False
    now = int(time.time())

    def claim(old: dict[str, Any]) -> dict[str, Any]:
        nonlocal claimed
        if int(old.get("attempt", 0)) != attempt:
            raise TaskNotOwned("stale task attempt")
        if old.get("cancel_requested"):
            events = list(old.get("events", []))
            if old.get("status") != "cancelled":
                events.append({"seq": int(events[-1].get("seq", -1)) + 1 if events else 0, "type": "status", "status": "cancelled", "created_at": now})
            return {**old, "status": "cancelled", "worker_id": None, "worker_lease_until": 0, "events": events[-200:], "updated_at": now}
        status = old.get("status")
        if status in ("succeeded", "failed", "cancelled", "awaiting_network_permission"):
            return old
        if status == "running" and int(old.get("worker_lease_until", 0)) > now:
            raise TaskAlreadyRunning(task_id)
        active_call = old.get("active_tool_call")
        if (
            status == "running"
            and int(old.get("worker_lease_until", 0)) <= now
            and isinstance(active_call, dict)
            and active_call.get("name") == "execute_python"
        ):
            error = "Python 执行中断，结果无法确认。为避免重复运行，请重新发起任务。"
            events = list(old.get("events", []))
            events.append({"seq": int(events[-1].get("seq", -1)) + 1 if events else 0, "type": "error", "status": "failed", "message": error, "created_at": now})
            return {**old, "status": "failed", "error": error, "active_tool_call": None, "worker_id": None, "worker_lease_until": 0, "sandbox_cleanup_pending": bool(old.get("sandbox_id")), "sandbox_cleanup_deadline": now + 300 if old.get("sandbox_id") else None, "events": events[-200:], "updated_at": now}
        claimed = True
        return {**old, "status": "running", "worker_id": worker_id, "worker_lease_until": now + _WORKER_LEASE_SECONDS, "updated_at": now}

    task = _mutate_task(tenant, task_id, claim).value
    return claimed and task.get("worker_id") == worker_id


def _ensure_active(
    store: CloudStore,
    tenant: str,
    task_id: str,
    attempt: int,
    worker_id: str | None = None,
) -> dict[str, Any]:
    from .api import _mutate_task

    task = _task_state(store, tenant, task_id)
    if int(task.get("attempt", 0)) != attempt:
        raise TaskNotOwned("stale task attempt")
    if worker_id is not None and task.get("worker_id") != worker_id:
        raise TaskNotOwned("worker lease was replaced")
    if task.get("cancel_requested"):
        raise TaskCancelled("task was cancelled")
    if worker_id is None:
        return task
    now = int(time.time())

    def renew(old: dict[str, Any]) -> dict[str, Any]:
        if old.get("worker_id") != worker_id or int(old.get("attempt", 0)) != attempt:
            raise TaskNotOwned("worker lease was replaced")
        if old.get("cancel_requested"):
            raise TaskCancelled("task was cancelled")
        return {**old, "worker_lease_until": now + _WORKER_LEASE_SECONDS, "updated_at": now}

    return _mutate_task(tenant, task_id, renew).value


def _mark_tool_started(
    tenant: str, task_id: str, attempt: int, worker_id: str, call: dict[str, Any]
) -> None:
    from .api import _mutate_task

    function = call.get("function") or {}
    call_id = str(call.get("id") or uuid.uuid4().hex)
    now = int(time.time())

    def mark(old: dict[str, Any]) -> dict[str, Any]:
        if old.get("worker_id") != worker_id or int(old.get("attempt", 0)) != attempt:
            raise TaskNotOwned("worker lease was replaced")
        if old.get("cancel_requested"):
            raise TaskCancelled("task was cancelled")
        return {
            **old,
            "active_tool_call": {
                "id": call_id,
                "name": str(function.get("name", "")),
                "started_at": now,
            },
            "updated_at": now,
        }

    _mutate_task(tenant, task_id, mark)


def _last_user_text(messages: list[dict[str, Any]]) -> str:
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict) and isinstance(item.get("text"), str):
                    parts.append(item["text"])
            return "\n".join(parts)
        return ""
    return ""


def _requires_python_execution(messages: list[dict[str, Any]]) -> bool:
    text = _last_user_text(messages).lower()
    if not re.search(r"python|蟒蛇", text):
        return False
    if re.search(r"(?:不要|不必|无需|不需要|禁止).{0,24}(?:调用|执行|运行).{0,24}python", text):
        return False
    explicit_run = re.search(
        r"(?:真实|实际|必须|请|务必).{0,24}(?:调用|执行|运行).{0,24}python"
        r"|(?:调用|执行|运行).{0,24}python"
        r"|python.{0,24}(?:真实|实际).{0,8}(?:运行|执行)"
        r"|(?:用|使用).{0,8}python.{0,20}(?:计算|生成|写入|导出)",
        text,
    )
    return explicit_run is not None


def _requested_python_output_names(messages: list[dict[str, Any]]) -> set[str]:
    text = _last_user_text(messages)
    paths = re.findall(
        r"/home/user/workspace/output/([^\s`\"'<>，。;；)）]+)", text
    )
    return {
        PurePosixPath(path.rstrip(".,，。;；:：")).name
        for path in paths
        if path.rstrip(".,，。;；:：")
    }


def _xiaoqi_system_instructions() -> str:
    if os.environ.get("XIAOQI_SINGLE_SERVER") == "1":
        return (
            "\n\n小栖当前开放的能力：读取本次任务附带的资料、读取已授权文字技能及其文字资源、"
            "创建或修改等待用户确认保存的技能草稿。当前单机服务没有开放 Python 或其他代码执行，"
            "也不能用代码处理数据或生成可下载文件。用户提出这类请求时，明确说明暂未开放；"
            "可以提供文字分析或示例代码，但不能声称已经运行。"
            "联网默认关闭。确需联网时列出精确域名和用途，等待系统单独授权。"
            "长文本按工具提示的 offset 分段读取，直到到达末尾。"
            "创建或修改技能时，若目的不明确，直接在普通聊天回复中用一句简短纯文本问题澄清，"
            "不要返回结构化问题或选项面板；目的明确后将完整技能和资源写入 draft_workspace，"
            "读回最终 SKILL.md 后再依据该版本完成一次代表性试用。"
            "最终回复展示完整 SKILL.md、试用输入与实际结果；未执行的试用必须标为文字演示，不能声称已运行。"
            "草稿工作区不是正式保存；只有用户点击保存才创建正式版本。"
        )
    return (
        "\n\n小栖工具规则：需要实际运行 Python 时调用 execute_python，不要只描述执行结果；需要交付的文件写到 /home/user/workspace/output；"
        "如果 Python 工具返回‘执行失败’，必须明确告诉用户失败，不得描述成成功。"
        "联网默认关闭。确需联网时列出精确域名和用途，等待系统单独授权。"
        "附件、技能资源和草稿可用对应工具完整读取；长文本按工具提示的 offset 分段读取，直到到达末尾。"
        "创建或修改技能时，若目的不明确，直接在普通聊天回复中用一句简短纯文本问题澄清，不要返回结构化问题或选项面板；目的明确后将完整技能和资源写入 draft_workspace，读回最终 SKILL.md 后再依据该版本完成一次代表性试用。"
        "最终回复展示完整 SKILL.md、试用输入与实际结果；未执行的试用必须标为文字演示，不能声称已运行。"
        "草稿工作区不是正式保存；只有用户点击保存才创建正式版本。"
    )


def _validate_python_requirements(
    task: dict[str, Any], messages: list[dict[str, Any]]
) -> None:
    if os.environ.get("XIAOQI_SINGLE_SERVER") == "1":
        return
    if not _requires_python_execution(messages):
        return
    if not task.get("python_succeeded"):
        raise RuntimeError("本次请求要求真实运行 Python，但执行未成功")
    required_files = _requested_python_output_names(messages)
    artifact_names = {
        str(item.get("name", ""))
        for item in task.get("artifacts", [])
        if isinstance(item, dict)
    }
    missing_files = sorted(required_files - artifact_names)
    if missing_files:
        raise RuntimeError(
            "Python 已运行，但未生成要求的文件：" + ", ".join(missing_files)
        )



def _safe_resource_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    if not _SAFE_FILE.fullmatch(normalized) or normalized.startswith("/") or any(part in ("", ".", "..") for part in normalized.split("/")):
        raise ValueError("资源路径无效")
    return normalized


def _persist_artifacts(
    sandbox: Any,
    store: CloudStore,
    tenant: str,
    task_id: str,
    attempt: int | None,
    worker_id: str | None,
    execution: Any,
) -> list[dict[str, Any]]:
    output_root = "/home/user/workspace/output"
    candidates: list[tuple[str, bytes]] = []
    entries = sandbox.files.list(output_root, depth=6)
    for entry in entries:
        if getattr(getattr(entry, "type", None), "value", "") != "file":
            continue
        if getattr(entry, "symlink_target", None):
            continue
        path = str(getattr(entry, "path", ""))
        prefix = output_root + "/"
        if not path.startswith(prefix):
            continue
        relative = path[len(prefix):]
        if not relative or any(part in ("", ".", "..") for part in PurePosixPath(relative).parts):
            continue
        name = PurePosixPath(relative).name
        name = re.sub(r'[\\/\x00-\x1f<>:"|?*]', "_", name).strip(" .")[:120]
        if not name:
            continue
        if int(getattr(entry, "size", 0) or 0) > _MAX_ARTIFACT_SIZE:
            raise ValueError(f"产物 {name} 超过 10 MB")
        data = bytes(sandbox.files.read(path, format="bytes"))
        if len(data) > _MAX_ARTIFACT_SIZE:
            raise ValueError(f"产物 {name} 超过 10 MB")
        candidates.append((name, data))
        if len(candidates) > _MAX_ARTIFACTS:
            raise ValueError("每个任务最多回传 10 个文件")

    for index, result in enumerate(getattr(execution, "results", []) or [], start=1):
        for field, extension, media_type in (("png", "png", "image/png"), ("jpeg", "jpg", "image/jpeg"), ("pdf", "pdf", "application/pdf")):
            encoded = getattr(result, field, None)
            if not isinstance(encoded, str) or not encoded:
                continue
            if encoded.startswith("data:"):
                encoded = encoded.partition(",")[2]
            if len(encoded) > (_MAX_ARTIFACT_SIZE * 4 // 3 + 8):
                raise ValueError("Python 返回的图片或 PDF 超过 10 MB")
            try:
                data = base64.b64decode(encoded, validate=True)
            except ValueError as error:
                raise ValueError("Python 返回的图片或 PDF 格式无效") from error
            candidates.append((f"python-result-{index}.{extension}", data))
            if len(candidates) > _MAX_ARTIFACTS:
                raise ValueError("每个任务最多回传 10 个文件")

    if sum(len(data) for _, data in candidates) > _MAX_ARTIFACT_TOTAL:
        raise ValueError("本次任务产物总大小超过 20 MB")
    if not candidates:
        return []
    if worker_id is not None and attempt is not None:
        _ensure_active(store, tenant, task_id, attempt, worker_id)

    archive_files: dict[str, bytes] = {}
    artifacts = []
    for index, (name, data) in enumerate(candidates):
        archive_path = f"{index:02d}-{name}"
        archive_files[archive_path] = data
        artifacts.append({
            "id": uuid.uuid4().hex,
            "name": name,
            "media_type": mimetypes.guess_type(name)[0] or "application/octet-stream",
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "archive_path": archive_path,
        })
    object_key = f"tenants/{tenant}/tasks/{task_id}/artifacts/{uuid.uuid4().hex}.zip"
    store.put_immutable(object_key, archive_files)
    from .api import _mutate_task

    now = int(time.time())

    def save(old: dict[str, Any]) -> dict[str, Any]:
        if (
            old.get("cancel_requested")
            or (worker_id is not None and old.get("worker_id") != worker_id)
            or (attempt is not None and int(old.get("attempt", 0)) != attempt)
        ):
            raise TaskCancelled("task was cancelled before artifact commit")
        current = list(old.get("artifacts", []))
        saved = [{**item, "object_key": object_key} for item in artifacts]
        return {**old, "artifacts": current + saved, "updated_at": now}

    saved_task = _mutate_task(tenant, task_id, save).value
    saved_artifacts = saved_task["artifacts"][-len(artifacts):]
    _emit(store, tenant, task_id, {"type": "artifacts_ready", "artifacts": saved_artifacts})
    return saved_artifacts


def _execute_python(
    store: CloudStore,
    tenant: str,
    task_id: str,
    code: str,
    domains: list[str],
    task_request: dict[str, Any],
    attempt: int | None = None,
    worker_id: str | None = None,
) -> str:
    if len(code.encode("utf-8")) > 64 * 1024:
        raise ValueError("Python 脚本超过 64 KB")
    if os.environ.get("XIAOQI_SINGLE_SERVER") == "1":
        raise RuntimeError(
            "单机版暂未启用 Python 执行：需先在目标 Linux 服务器验证低权限隔离和联网域名限制。"
            "当前可以继续使用文字任务。"
        )
    sandbox_connection = {
        "api_key": os.environ.get("E2B_API_KEY", "").strip(),
        "api_url": os.environ.get("E2B_API_URL", "").strip(),
        "domain": os.environ.get("E2B_DOMAIN", "").strip(),
    }
    missing = [name for name, value in sandbox_connection.items() if not value]
    if missing:
        print(
            f"AGENT_PYTHON_EXECUTION task_id={task_id} status=config_missing "
            f"missing={','.join(missing)}",
            flush=True,
        )
        raise RuntimeError(
            f"阿里云 Agent Sandbox 未配置：{', '.join(missing)}；纯文字能力仍可继续使用"
        )
    from e2b_code_interpreter import Sandbox

    sandbox = None
    try:
        sandbox_options: dict[str, Any] = {
            "timeout": 300,
            "allow_internet_access": False,
            "network": {
                "allow_out": domains,
                "deny_out": ["0.0.0.0/0"],
            },
            "metadata": {"xiaoqi_task_id": task_id},
        }
        sandbox = Sandbox.create(**sandbox_connection, **sandbox_options)
        from .api import _mutate_task

        _mutate_task(tenant, task_id, lambda old: {**old, "sandbox_id": sandbox.sandbox_id, "updated_at": int(time.time())})
        if worker_id is not None and attempt is not None:
            _ensure_active(store, tenant, task_id, attempt, worker_id)

        # Only explicitly attached materials are copied into this sandbox.
        for index, material in enumerate(task_request.get("materials", [])):
            if worker_id is not None and attempt is not None:
                _ensure_active(store, tenant, task_id, attempt, worker_id)
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
                        if worker_id is not None and attempt is not None:
                            _ensure_active(store, tenant, task_id, attempt, worker_id)
                        path = _safe_resource_path(name)
                        sandbox.files.write(f"/home/user/workspace/skill/{path}", data)

        sandbox.commands.run("mkdir -p /home/user/workspace/output")
        if worker_id is not None and attempt is not None:
            _ensure_active(store, tenant, task_id, attempt, worker_id)
        execution = sandbox.run_code(code, language="python", timeout=120)
        logs = execution.logs
        stdout = str(getattr(logs, "stdout", "") or "")
        stderr = str(getattr(logs, "stderr", "") or "")
        result_items = []
        for item in getattr(execution, "results", []) or []:
            text = getattr(item, "text", None)
            if text:
                result_items.append(str(text))
        artifacts = _persist_artifacts(sandbox, store, tenant, task_id, attempt, worker_id, execution)
        execution_error = getattr(execution, "error", None)
        if execution_error:
            raise RuntimeError(
                "Python 执行失败："
                f"{getattr(execution_error, 'name', 'Error')}: "
                f"{getattr(execution_error, 'value', '未知错误')}"
            )
        if artifacts:
            result_items.append("已生成文件：" + ", ".join(item["name"] for item in artifacts))
        output = "\n".join(part for part in [stdout, stderr, *result_items] if part)
        _mutate_task(
            tenant,
            task_id,
            lambda old: {**old, "python_succeeded": True, "updated_at": int(time.time())},
        )
        print(
            f"AGENT_PYTHON_EXECUTION task_id={task_id} status=ok "
            f"artifacts={len(artifacts)}",
            flush=True,
        )
        return _clean_output(output or "Python 已执行，没有标准输出。")
    finally:
        cleanup_failed = False
        if sandbox is not None:
            try:
                sandbox.kill()
            except Exception:
                cleanup_failed = True
        from .api import _mutate_task

        try:
            def update_cleanup(old: dict[str, Any]) -> dict[str, Any]:
                if (
                    int(old.get("attempt", 0)) != attempt
                    or (worker_id is not None and old.get("worker_id") != worker_id)
                ):
                    return old
                cleanup_pending = cleanup_failed
                return {
                    **old,
                    "sandbox_id": old.get("sandbox_id") if cleanup_pending else None,
                    "sandbox_cleanup_pending": cleanup_pending,
                    "sandbox_cleanup_deadline": int(time.time()) + 300 if cleanup_pending else None,
                    "updated_at": int(time.time()),
                }

            _mutate_task(tenant, task_id, update_cleanup)
        except Exception:
            pass


def _run_tool(
    store: CloudStore,
    tenant: str,
    task_id: str,
    task_request: dict[str, Any],
    call: dict[str, Any],
    authorized_domains: set[str],
    attempt: int | None = None,
    worker_id: str | None = None,
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
                text = str(material.get("text") or "")
                if not text:
                    return "[该资料只提供了二进制附件]"
                return _clean_output(
                    _read_text_chunk(
                        text,
                        arguments.get("offset", 0),
                        arguments.get("limit", _MAX_TOOL_READ_CHARS),
                    )
                )
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
        return _clean_output(
            _read_text_chunk(
                files[path].decode("utf-8", errors="replace"),
                arguments.get("offset", 0),
                arguments.get("limit", _MAX_TOOL_READ_CHARS),
            )
        )

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
            return _clean_output(
                _read_text_chunk(
                    files[path],
                    arguments.get("offset", 0),
                    arguments.get("limit", _MAX_TOOL_READ_CHARS),
                )
            )
        if action == "write":
            if path != "SKILL.md" and not path.startswith(("scripts/", "references/", "assets/")):
                raise ValueError("草稿资源只能放在 scripts、references 或 assets 目录")
            if path.startswith("scripts/") and not path.lower().endswith(
                (".py", ".js", ".mjs", ".cjs", ".ts", ".mts")
            ):
                raise ValueError("脚本文件支持 Python、JavaScript 或 TypeScript")
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
        return _execute_python(store, tenant, task_id, str(arguments.get("code", "")), domains, task_request, attempt, worker_id)

    raise ValueError("工具未开放")


def run_task(store: CloudStore, tenant: str, task_id: str, attempt: int) -> None:
    from .api import _mutate_task

    worker_id = uuid.uuid4().hex
    try:
        if not _claim_task(store, tenant, task_id, attempt, worker_id):
            return
    except TaskCancelled:
        _mutate_task(tenant, task_id, lambda old: {**old, "status": "cancelled", "worker_id": None, "worker_lease_until": 0, "updated_at": int(time.time())} if int(old.get("attempt", 0)) == attempt else old)
        _emit(store, tenant, task_id, {"type": "status", "status": "cancelled"})
        return
    except TaskNotOwned:
        return

    try:
        task = _ensure_active(store, tenant, task_id, attempt, worker_id)
    except TaskNotOwned:
        return
    except TaskCancelled:
        _mutate_task(tenant, task_id, lambda old: {**old, "status": "cancelled", "worker_id": None, "worker_lease_until": 0, "updated_at": int(time.time())} if int(old.get("attempt", 0)) == attempt and old.get("worker_id") == worker_id else old)
        _emit(store, tenant, task_id, {"type": "status", "status": "cancelled"})
        return

    _emit(store, tenant, task_id, {"type": "status", "status": "running"})
    try:
        if task.get("runtime") != "deepseek-harness":
            raise ValueError("不支持的任务运行时")
        from .harness_worker import run_task as run_harness_task

        run_harness_task(store, tenant, task_id, attempt, worker_id, task)
    except TaskCancelled:
        current = _task_state(store, tenant, task_id)
        if int(current.get("attempt", 0)) == attempt and current.get("worker_id") == worker_id:
            _mutate_task(tenant, task_id, lambda old: {**old, "status": "cancelled", "sandbox_id": None, "worker_id": None, "worker_lease_until": 0, "active_tool_call": None, "updated_at": int(time.time())})
            _emit(store, tenant, task_id, {"type": "status", "status": "cancelled"})
    except TaskNotOwned:
        return
    except Exception as error:
        now = int(time.time())
        owned = False
        cancelled = False

        def finish_error(old: dict[str, Any]) -> dict[str, Any]:
            nonlocal owned, cancelled
            if int(old.get("attempt", 0)) != attempt or old.get("worker_id") != worker_id:
                return old
            owned = True
            cancelled = bool(old.get("cancel_requested"))
            return {
                **old,
                "status": "cancelled" if cancelled else "failed",
                "error": None if cancelled else str(error)[:500],
                "worker_id": None,
                "worker_lease_until": 0,
                "active_tool_call": None,
                "updated_at": now,
            }

        _mutate_task(tenant, task_id, finish_error)
        if owned:
            if cancelled:
                _emit(store, tenant, task_id, {"type": "status", "status": "cancelled"})
            else:
                _emit(store, tenant, task_id, {"type": "error", "status": "failed", "message": str(error)[:500]})
