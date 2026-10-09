from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from io import BytesIO
from pathlib import Path
from typing import Any

from .storage import CloudStore


_SNAPSHOT_LIMIT = 18 * 1024 * 1024
_ACP_CANCEL_TIMEOUT_SECONDS = 5
_SNAPSHOT_DIRS = ("sessions", "attachments", "storages")
_DISABLED_TOOLS = (
    "plan-mode",
    "mcp-resources",
    "tool-bash",
    "tool-pwsh",
    "tool-jobs",
    "tool-fs",
    "tool-fs-search",
    "tool-skill",
    "tool-subagent",
    "tool-subagent-fork",
    "tool-subagent-control",
    "tool-subagent-list-agents",
    "tool-workflow",
    "tool-todo",
    "tool-goal",
    "tool-ralph",
    "tool-web",
)


def _model_settings(model_id: str) -> tuple[str, str]:
    if model_id.startswith("mimo"):
        key = os.environ.get("MIMO_API_KEY", "").strip()
        url = "https://api.xiaomimimo.com/v1"
    else:
        key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
        url = "https://api.deepseek.com/v1"
    if not key:
        raise RuntimeError("所选模型的服务端密钥尚未配置")
    return key, url


def _yaml_scalar(value: str) -> str:
    # JSON quoted strings are valid YAML scalars and avoid hand-written escaping.
    return json.dumps(value, ensure_ascii=False)


def _write_profile_patch(
    path: Path,
    model_id: str,
    base_url: str,
    system_prompt: str,
    reasoning_level: str,
) -> None:
    disabled = "\n".join(f"- id: {tool}\n  disabled: true" for tool in _DISABLED_TOOLS)
    is_mimo = model_id.startswith("mimo")
    context_window = (
        1_000_000
        if model_id in {"deepseek-flash", "mimo-v2.6-flash"}
        else 65_536
    )
    if is_mimo:
        reasoning = "off" if reasoning_level == "low" else "high"
    else:
        reasoning = {"low": "low", "medium": "high", "high": "max"}.get(
            reasoning_level, "high"
        )
    compat = ["        compat:", "          thinkingFormat: deepseek"]
    if is_mimo:
        compat.extend(
            (
                "          supportsReasoningEffort: false",
                "          requiresReasoningContentOnAssistantMessages: true",
            )
        )
    model_capabilities = [
        "          input: [text, image]"
        if model_id in {"deepseek-flash", "mimo-v2.6-flash"}
        else "          input: [text]",
    ]
    if is_mimo:
        model_capabilities.extend(
            (
                "          reasoningEfforts:",
                "            off: null",
                "            high: high",
            )
        )
    else:
        model_capabilities.extend(
            (
                "          reasoningEfforts:",
                "            off: null",
                "            low: low",
                "            high: high",
                "            max: max",
            )
        )
    path.write_text(
        "\n".join(
            (
                "- id: llm-pi-ai",
                "  config:",
                "    providers:",
                "      xiaoqi:",
                "        apiKeyEnv: XIAOQI_MODEL_API_KEY",
                "        api: openai-completions",
                f"        baseURL: {_yaml_scalar(base_url)}",
                f"        reasoning: {reasoning}",
                *compat,
                "        models:",
                f"        - id: {_yaml_scalar(model_id)}",
                "          name: Xiaoqi model",
                f"          contextWindow: {context_window}",
                "          maxTokens: 8192",
                *model_capabilities,
                "- id: acp",
                "  config:",
                "    provider: xiaoqi",
                f"    model: {_yaml_scalar(model_id)}",
                "- id: system-prompt",
                "  config:",
                f"    personaPrefix: {_yaml_scalar(system_prompt)}",
                "    personaSuffix: You are working on a Xiaoqi user task. Use only the tools explicitly provided by Xiaoqi.",
                disabled,
                "",
            )
        ),
        encoding="utf-8",
    )


def _text_and_images(content: Any) -> list[Any]:
    from acp.schema import ImageContentBlock, TextContentBlock

    if isinstance(content, str):
        return [TextContentBlock(text=content)] if content else []
    if not isinstance(content, list):
        return [TextContentBlock(text=str(content))] if content is not None else []

    parts: list[Any] = []
    for item in content:
        if isinstance(item, str):
            if item:
                parts.append(TextContentBlock(text=item))
            continue
        if not isinstance(item, dict):
            continue
        if isinstance(item.get("text"), str):
            parts.append(TextContentBlock(text=item["text"]))
            continue
        image_url = item.get("image_url")
        if isinstance(image_url, dict):
            image_url = image_url.get("url")
        if not isinstance(image_url, str):
            continue
        match = re.fullmatch(r"data:(image/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=]+)", image_url)
        if match is None:
            raise ValueError("Harness 接入当前只支持随请求上传的图片，无法安全导入外部图片链接")
        # Validate before forwarding the data to ACP.
        base64.b64decode(match.group(2), validate=True)
        parts.append(ImageContentBlock(data=match.group(2), mimeType=match.group(1)))
    return parts


def _session_prompt(messages: list[dict[str, Any]]) -> list[Any]:
    from acp.schema import TextContentBlock

    prompt: list[Any] = [
        TextContentBlock(
            text=(
                "以下是小栖对话上下文。方括号中的角色标记用于区分历史发言；"
                "请处理最后一条用户消息，必须通过可用的小栖工具完成所需操作。\n"
            )
        )
    ]
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role", "unknown"))
        if role == "system":
            # System policy is placed in the Harness persona before the session starts.
            continue
        prompt.append(TextContentBlock(text=f"\n[{role}]\n"))
        prompt.extend(_text_and_images(message.get("content")))
        calls = message.get("tool_calls")
        if calls:
            prompt.append(TextContentBlock(text="\n[历史工具调用]\n" + json.dumps(calls, ensure_ascii=False)))
    return prompt


def _system_prompt(messages: list[dict[str, Any]]) -> str:
    from .worker import _xiaoqi_system_instructions

    base = "\n".join(
        str(item.get("content", ""))
        for item in messages
        if isinstance(item, dict) and item.get("role") == "system"
    )
    if "小栖工具规则" not in base:
        base += _xiaoqi_system_instructions()
    return (
        "你是小栖的任务 Agent。只使用已连接的小栖 MCP 工具，不得使用本地终端、"
        "文件系统、外部联网、子 Agent 或其他未授权工具。遵守以下小栖系统指令：\n\n"
        + base
    )


def _task_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def _stable_workspace(tenant: str, task_id: str) -> Path:
    root = Path(tempfile.gettempdir()) / "xiaoqi-harness-workspaces"
    path = root / _task_hash(tenant) / _task_hash(task_id)
    path.mkdir(parents=True, exist_ok=True)
    return path


def purge_task_workspace(tenant: str, task_id: str) -> None:
    root = (Path(tempfile.gettempdir()) / "xiaoqi-harness-workspaces").resolve()
    path = (root / _task_hash(tenant) / _task_hash(task_id)).resolve()
    if path.parent.parent != root:
        raise ValueError("Harness workspace path escaped its root")
    shutil.rmtree(path, ignore_errors=False)
    try:
        path.parent.rmdir()
    except OSError:
        pass


def _restore_snapshot(home: Path, snapshot: bytes) -> None:
    if len(snapshot) > _SNAPSHOT_LIMIT:
        raise ValueError("Harness 会话快照超过恢复上限")
    allowed = set(_SNAPSHOT_DIRS)
    with zipfile.ZipFile(BytesIO(snapshot)) as archive:
        for info in archive.infolist():
            path = Path(info.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] not in allowed:
                raise ValueError("Harness 会话快照包含无效路径")
            target = home.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.write_bytes(archive.read(info))


def _make_snapshot(home: Path) -> bytes:
    payload = BytesIO()
    with zipfile.ZipFile(payload, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in _SNAPSHOT_DIRS:
            root = home / name
            if not root.exists():
                continue
            for path in root.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(home).as_posix())
    snapshot = payload.getvalue()
    if len(snapshot) > _SNAPSHOT_LIMIT:
        raise ValueError("Harness 会话快照超过保存上限")
    return snapshot


def _runtime_environment(home: Path, api_key: str) -> dict[str, str]:
    allow = {
        "PATH",
        "HOME",
        "USERPROFILE",
        "SYSTEMROOT",
        "WINDIR",
        "TEMP",
        "TMP",
        "TMPDIR",
        "HOMEDRIVE",
        "HOMEPATH",
    }
    env = {key: value for key, value in os.environ.items() if key in allow}
    env["PATH"] = os.pathsep.join(
        item for item in (str(Path(sys.executable).parent), env.get("PATH", "")) if item
    )
    env["PYTHONPATH"] = os.pathsep.join(item for item in sys.path if item)
    env.update(
        {
            "DSH_HOME": str(home),
            "DSH_TELEMETRY_MODE": "DISABLED",
            "DSH_PERMISSION_MODE": "read-only",
            "XIAOQI_MODEL_API_KEY": api_key,
        }
    )
    return env


def _resolve_dsh_binary(task: dict[str, Any]) -> str:
    release_id = str(task.get("dsh_release_id", "builtin"))
    if release_id != "builtin":
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", release_id):
            raise ValueError("DSH 版本 ID 无效")
        root = Path(os.environ.get("XIAOQI_DSH_RELEASE_ROOT", "/opt/xiaoqi-dsh")).resolve()
        release_dir = (root / "releases" / release_id).resolve()
        try:
            release_dir.relative_to(root / "releases")
            manifest = json.loads((release_dir / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError) as error:
            raise RuntimeError("任务指定的 DSH 版本不可用") from error
        binary_relative = Path(str(manifest.get("binary", "")))
        if binary_relative.is_absolute() or ".." in binary_relative.parts:
            raise RuntimeError("DSH 版本清单中的可执行路径无效")
        binary = (release_dir / binary_relative).resolve()
        try:
            binary.relative_to(release_dir)
        except ValueError as error:
            raise RuntimeError("DSH 可执行文件路径无效") from error
        if not binary.is_file():
            raise RuntimeError("任务指定的 DSH 可执行文件缺失")
        return str(binary)

    dsh = shutil.which("dsh")
    if not dsh:
        candidate = Path(sys.executable).parent / ("dsh.exe" if os.name == "nt" else "dsh")
        if candidate.is_file():
            dsh = str(candidate)
    if not dsh:
        try:
            from deepseek_harness_runtime import bundled_runtime_path

            dsh = str(bundled_runtime_path())
        except (ImportError, FileNotFoundError):
            pass
    if not dsh:
        raise RuntimeError("DeepSeek Harness Runtime 未安装或 dsh 不在 PATH 中")
    return dsh


def _prepare_dsh_profile(home: Path, task: dict[str, Any]) -> None:
    config_id = str(task.get("dsh_config_id", "builtin"))
    if config_id == "builtin":
        return
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", config_id):
        raise ValueError("DSH 配置版本 ID 无效")
    root = Path(os.environ.get("XIAOQI_DSH_RELEASE_ROOT", "/opt/xiaoqi-dsh")).resolve()
    config_dir = (root / "configs" / config_id).resolve()
    profile = (config_dir / "profiles" / "xiaoqi-acp").resolve()
    try:
        config_dir.relative_to(root / "configs")
        profile.relative_to(config_dir)
    except ValueError as error:
        raise RuntimeError("DSH 配置路径无效") from error
    manifest_path = profile / "package.json"
    if not manifest_path.is_file():
        raise RuntimeError("任务指定的 DSH 插件配置缺失")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("DSH 插件配置无法读取") from error
    if not isinstance(manifest.get("dsh", {}).get("profile", {}).get("bundles", []), list):
        raise RuntimeError("DSH 插件配置格式无效")

    destination = home / "profiles" / "xiaoqi-acp"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(profile, destination, ignore=shutil.ignore_patterns("node_modules"))
    modules = profile / "node_modules"
    if modules.exists():
        modules.resolve().relative_to(config_dir)
        try:
            (destination / "node_modules").symlink_to(modules, target_is_directory=True)
        except OSError:
            shutil.copytree(modules, destination / "node_modules", symlinks=True)


def _copy_dsh_credentials(home: Path) -> None:
    web_home = Path(
        os.environ.get(
            "XIAOQI_DSH_WEB_HOME",
            str(Path(os.environ.get("XIAOQI_DSH_RELEASE_ROOT", "/opt/xiaoqi-dsh")) / "web-home"),
        )
    )
    source = web_home / ".credentials.yaml"
    destination = home / ".credentials.yaml"
    if not source.exists():
        destination.unlink(missing_ok=True)
        return
    if source.is_symlink() or not source.is_file():
        raise RuntimeError("DSH 插件凭据文件无效")

    home.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=home, prefix=".credentials-", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            os.chmod(temporary_path, 0o600)
            with source.open("rb") as credentials:
                shutil.copyfileobj(credentials, temporary)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, destination)
        os.chmod(destination, 0o600)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _tool_environment(tenant: str, task_id: str, attempt: int, worker_id: str, port: int) -> dict[str, str]:
    keys = {
        "PATH",
        "HOME",
        "USERPROFILE",
        "SYSTEMROOT",
        "WINDIR",
        "TEMP",
        "TMP",
        "HOMEDRIVE",
        "HOMEPATH",
        "XIAOQI_DATA_DIR",
        "XIAOQI_SINGLE_SERVER",
    }
    env = {key: value for key, value in os.environ.items() if key in keys}
    env["PATH"] = os.pathsep.join(
        item for item in (str(Path(sys.executable).parent), env.get("PATH", "")) if item
    )
    env["PYTHONPATH"] = os.pathsep.join(item for item in sys.path if item)
    env.update(
        {
            "XIAOQI_TASK_TENANT": tenant,
            "XIAOQI_TASK_ID": task_id,
            "XIAOQI_TASK_ATTEMPT": str(attempt),
            "XIAOQI_WORKER_ID": worker_id,
            "XIAOQI_MCP_PORT": str(port),
        }
    )
    return env


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _start_tool_server(tenant: str, task_id: str, attempt: int, worker_id: str) -> tuple[subprocess.Popen[bytes], int]:
    package_root = Path(__file__).resolve().parents[1]
    port = _free_loopback_port()
    process = subprocess.Popen(
        [sys.executable, "-m", "capabilities.harness_mcp_server"],
        cwd=package_root,
        env=_tool_environment(tenant, task_id, attempt, worker_id, port),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("小栖 MCP 工具服务启动失败")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return process, port
        except OSError:
            time.sleep(0.1)
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
    raise RuntimeError("小栖 MCP 工具服务启动超时")


def _stop_process(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def _checkpoint(store: CloudStore, tenant: str, task_id: str, attempt: int, worker_id: str, session_id: str, home: Path) -> None:
    from .api import _DSH_RUNTIME_VERSION, _mutate_task

    snapshot = _make_snapshot(home)
    key = (
        f"tenants/{_task_hash(tenant)}/tasks/{_task_hash(task_id)}"
        f"/harness/{attempt}-{uuid.uuid4().hex}.zip"
    )
    store.put_task_blob(key, snapshot)

    def save(old: dict[str, Any]) -> dict[str, Any]:
        if int(old.get("attempt", 0)) != attempt:
            raise RuntimeError("Harness checkpoint belongs to a stale task attempt")
        if old.get("worker_id") not in (worker_id, None):
            raise RuntimeError("Harness checkpoint lost the task lease")
        return {
            **old,
            "harness_session_id": session_id,
            "harness_snapshot_key": key,
            "harness_runtime_version": _DSH_RUNTIME_VERSION,
            "updated_at": int(time.time()),
        }

    _mutate_task(tenant, task_id, save)


class _AcpClient:
    def __init__(self, on_text: Any) -> None:
        self.on_text = on_text
        self.last_message_id: str | None = None
        self.final_text: list[str] = []

    async def session_update(self, session_id: str, update: Any, **kwargs: Any) -> None:
        from acp.schema import AgentMessageChunk, TextContentBlock

        if not isinstance(update, AgentMessageChunk) or not isinstance(update.content, TextContentBlock):
            return
        message_id = update.messageId
        if message_id and message_id != self.last_message_id:
            self.final_text.clear()
            self.last_message_id = message_id
        text = update.content.text
        if not text:
            return
        self.final_text.append(text)
        self.on_text(session_id, text)


async def _prompt_and_monitor(
    connection: Any,
    session_id: str,
    content: list[Any],
    store: CloudStore,
    tenant: str,
    task_id: str,
    attempt: int,
    worker_id: str,
) -> None:
    from .worker import TaskCancelled, TaskNotOwned, _ensure_active

    prompt_task = asyncio.create_task(connection.prompt(session_id=session_id, prompt=content))
    while not prompt_task.done():
        await asyncio.sleep(0.75)
        try:
            await asyncio.to_thread(_ensure_active, store, tenant, task_id, attempt, worker_id)
        except (TaskCancelled, TaskNotOwned) as stopped:
            try:
                await asyncio.wait_for(
                    connection.cancel(session_id=session_id),
                    timeout=_ACP_CANCEL_TIMEOUT_SECONDS,
                )
            except Exception:
                pass
            try:
                await asyncio.wait_for(
                    asyncio.shield(prompt_task),
                    timeout=_ACP_CANCEL_TIMEOUT_SECONDS,
                )
            except Exception:
                prompt_task.cancel()
                await asyncio.gather(prompt_task, return_exceptions=True)
            raise stopped
    await prompt_task


def _claim_python_reminder(
    store: CloudStore,
    tenant: str,
    task_id: str,
    attempt: int,
    worker_id: str,
    messages: list[dict[str, Any]],
) -> bool:
    from .api import _mutate_task
    from .worker import TaskCancelled, TaskNotOwned, _requires_python_execution, _task_state

    if os.environ.get("XIAOQI_SINGLE_SERVER") == "1":
        return False
    if not _requires_python_execution(messages):
        return False
    current = _task_state(store, tenant, task_id)
    if (
        current.get("python_succeeded")
        or current.get("harness_python_tool_called")
        or current.get("harness_python_reminder_sent")
    ):
        return False

    def claim(old: dict[str, Any]) -> dict[str, Any]:
        if old.get("worker_id") != worker_id or int(old.get("attempt", 0)) != attempt:
            raise TaskNotOwned("worker lease was replaced")
        if old.get("cancel_requested"):
            raise TaskCancelled("task was cancelled")
        if (
            old.get("python_succeeded")
            or old.get("harness_python_tool_called")
            or old.get("harness_python_reminder_sent")
        ):
            return old
        return {**old, "harness_python_reminder_sent": True, "updated_at": int(time.time())}

    updated = _mutate_task(tenant, task_id, claim).value
    return bool(updated.get("harness_python_reminder_sent")) and not bool(
        current.get("harness_python_reminder_sent")
    )


async def _run_acp(store: CloudStore, task: dict[str, Any], task_request: dict[str, Any], tenant: str, task_id: str, attempt: int, worker_id: str, home: Path, workspace: Path) -> tuple[str, str]:
    import acp
    from acp.schema import ClientCapabilities, HttpMcpServer, Implementation

    from .worker import _emit

    model_id = str(task_request.get("model_id", "deepseek-flash"))
    api_key, base_url = _model_settings(model_id)
    dsh = _resolve_dsh_binary(task)

    home.mkdir(parents=True, exist_ok=True)
    _prepare_dsh_profile(home, task)
    input_files = store.get_immutable(str(task["input_object_key"]))
    input_request = json.loads(input_files["input.json"].decode("utf-8"))
    messages = input_request.get("messages", [])
    if task.get("harness_session_id") and task.get("harness_snapshot_key"):
        _restore_snapshot(home, store.get_task_blob(str(task["harness_snapshot_key"])))
    elif task.get("harness_session_id"):
        raise RuntimeError("Harness 会话 ID 存在但会话快照缺失，拒绝从头重放任务")
    _copy_dsh_credentials(home)

    patch_path = home / "xiaoqi-cordis.patch.yml"
    _write_profile_patch(
        patch_path,
        model_id,
        base_url,
        _system_prompt(messages),
        str(task_request.get("reasoning_level", "medium")).lower(),
    )
    profile_name = "xiaoqi-acp"
    profile_exists = (home / "profiles" / profile_name / "package.json").exists()
    args = ["--profile", profile_name]
    if not profile_exists:
        args.extend(["--from-default-profile", "acp"])
    args.extend(["--patch", str(patch_path)])

    tool_process, port = _start_tool_server(tenant, task_id, attempt, worker_id)
    client = _AcpClient(
        lambda sid, text: _emit(store, tenant, task_id, {"type": "assistant_delta", "text": text})
    )
    runtime_env = _runtime_environment(home, api_key)
    session_id = str(task.get("harness_session_id") or "")
    try:
        async with acp.spawn_agent_process(
            client,
            dsh,
            *args,
            env=runtime_env,
            cwd=str(workspace),
            # The ACP SDK captures child stderr by default; inherit it so FC logs
            # retain the Harness startup failure instead of only "Connection closed".
            transport_kwargs={"stderr": None},
        ) as (connection, process):
            await connection.initialize(
                protocol_version=acp.PROTOCOL_VERSION,
                client_capabilities=ClientCapabilities(),
                client_info=Implementation(name="xiaoqi", version="1.0"),
            )
            mcp_servers = [
                HttpMcpServer(
                    name="xiaoqi",
                    url=f"http://127.0.0.1:{port}/mcp",
                    headers=[],
                )
            ]
            if session_id:
                await connection.resume_session(
                    session_id=session_id,
                    cwd=str(workspace),
                    mcp_servers=mcp_servers,
                )
            else:
                created = await connection.new_session(
                    cwd=str(workspace),
                    mcp_servers=mcp_servers,
                )
                session_id = created.session_id
            if task.get("harness_session_id"):
                from acp.schema import TextContentBlock

                prompt = [
                    TextContentBlock(
                        text=(
                            "请根据已恢复的会话继续完成原任务。先检查此前工具调用和已产生的结果，"
                            "不要重复已有副作用；若先前任务因等待授权而暂停，现在可使用已授权域名："
                            + ", ".join(task.get("authorized_network_domains", []))
                            + "。"
                        )
                    )
                ]
            else:
                prompt = _session_prompt(messages)
            await _prompt_and_monitor(
                connection,
                session_id,
                prompt,
                store,
                tenant,
                task_id,
                attempt,
                worker_id,
            )
            if _claim_python_reminder(store, tenant, task_id, attempt, worker_id, messages):
                from acp.schema import TextContentBlock

                await _prompt_and_monitor(
                    connection,
                    session_id,
                    [
                        TextContentBlock(
                            text=(
                                "当前请求明确要求真实运行 Python，但你尚未调用 execute_python。"
                                "请立即通过该小栖工具执行任务，再根据实际工具结果回复；不要伪称已经运行。"
                            )
                        )
                    ],
                    store,
                    tenant,
                    task_id,
                    attempt,
                    worker_id,
                )
            try:
                await asyncio.wait_for(connection.close_session(session_id=session_id), timeout=10)
            except Exception:
                pass
    finally:
        _stop_process(tool_process)
    return session_id, "".join(client.final_text).strip()


def run_task(store: CloudStore, tenant: str, task_id: str, attempt: int, worker_id: str, task: dict[str, Any]) -> None:
    from .api import _mutate_task
    from .worker import (
        TaskCancelled,
        TaskNotOwned,
        _emit,
        _ensure_active,
        _requires_python_execution,
        _task_state,
        _validate_python_requirements,
    )

    input_files = store.get_immutable(str(task["input_object_key"]))
    task_request = json.loads(input_files["input.json"].decode("utf-8"))
    messages = task_request.get("messages", [])
    if not isinstance(messages, list) or not messages:
        raise ValueError("任务中没有模型上下文")
    session_id = ""
    workspace = _stable_workspace(tenant, task_id)
    try:
        with tempfile.TemporaryDirectory(prefix="xiaoqi-dsh-") as home:
            home_path = Path(home)
            session_id, final_text = asyncio.run(
                _run_acp(store, task, task_request, tenant, task_id, attempt, worker_id, home_path, workspace)
            )
            _checkpoint(store, tenant, task_id, attempt, worker_id, session_id, home_path)
        current = _task_state(store, tenant, task_id)
        if current.get("status") == "awaiting_network_permission":
            return
        _ensure_active(store, tenant, task_id, attempt, worker_id)
        _validate_python_requirements(current, messages)

        def complete(old: dict[str, Any]) -> dict[str, Any]:
            if old.get("worker_id") != worker_id or int(old.get("attempt", 0)) != attempt:
                raise TaskNotOwned("worker lease was replaced")
            if old.get("cancel_requested"):
                raise TaskCancelled("task was cancelled")
            return {
                **old,
                "status": "succeeded",
                "result": final_text,
                "draft": old.get("draft_files", {}).get("SKILL.md"),
                "worker_id": None,
                "worker_lease_until": 0,
                "active_tool_call": None,
                "updated_at": int(time.time()),
            }

        completed = _mutate_task(tenant, task_id, complete).value
        _emit(
            store,
            tenant,
            task_id,
            {
                "type": "completed",
                "status": "succeeded",
                "text": final_text,
                "draft": completed.get("draft"),
                "files": {
                    path: base64.b64encode(content.encode("utf-8")).decode("ascii")
                    for path, content in completed.get("draft_files", {}).items()
                },
                "artifacts": completed.get("artifacts", []),
            },
        )
    except TaskCancelled:
        _mutate_task(
            tenant,
            task_id,
            lambda old: {
                **old,
                "status": "cancelled",
                "worker_id": None,
                "worker_lease_until": 0,
                "active_tool_call": None,
                "updated_at": int(time.time()),
            }
            if int(old.get("attempt", 0)) == attempt and old.get("worker_id") == worker_id
            else old,
        )
        _emit(store, tenant, task_id, {"type": "status", "status": "cancelled"})
    except TaskNotOwned:
        return
    except Exception as error:
        current = _task_state(store, tenant, task_id)
        if current.get("status") == "awaiting_network_permission":
            return
        _mutate_task(
            tenant,
            task_id,
            lambda old: {
                **old,
                "status": "failed",
                "error": str(error)[:500],
                "worker_id": None,
                "worker_lease_until": 0,
                "active_tool_call": None,
                "updated_at": int(time.time()),
            }
            if int(old.get("attempt", 0)) == attempt and old.get("worker_id") == worker_id
            else old,
        )
        _emit(store, tenant, task_id, {"type": "error", "status": "failed", "message": str(error)[:500]})
