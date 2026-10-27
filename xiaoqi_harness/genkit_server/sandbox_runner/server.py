#!/usr/bin/env python3
"""Private, allowlisted Docker executor for Xiaoqi code tasks."""

from __future__ import annotations

import base64
import binascii
import hmac
import io
import json
import mimetypes
import os
import re
import tarfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import PurePosixPath
from typing import Any, Iterable

import docker
from docker.errors import APIError, DockerException, ImageNotFound, NotFound
from mcp_sessions import LeaseError, McpSessions
from execution_sessions import ExecutionError, Executions, StorageUnavailable
from stdio_channel import StdioChannel


MAX_BODY_BYTES = 100 * 1024 * 1024
MAX_CODE_BYTES = 64 * 1024
MAX_MATERIAL_BYTES = 20 * 1024 * 1024
MAX_SKILL_BYTES = 50 * 1024 * 1024
MAX_SINGLE_FILE_BYTES = 20 * 1024 * 1024
MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
MAX_ARTIFACT_TOTAL_BYTES = 20 * 1024 * 1024
MAX_ARTIFACTS = 10
MAX_LOG_BYTES = 1024 * 1024
MAX_RUN_SECONDS = 120
MAX_DOMAINS = 10
MAX_SCRIPT_ARGUMENTS = 32
OWNER_LABEL = os.environ.get("XIAOQI_SANDBOX_OWNER_LABEL", "com.xiaoqi.local-sandbox")
if not re.fullmatch(r"com\.xiaoqi\.[a-z0-9.-]+", OWNER_LABEL):
    raise ValueError("Invalid sandbox resource owner label")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
SAFE_NAME_RE = re.compile(r"[\\/\x00-\x1f<>:\"|?*]")

RUNNER_TOKEN = os.environ.get("SANDBOX_RUNNER_TOKEN", "").strip()
SANDBOX_IMAGE = os.environ.get("XIAOQI_SANDBOX_IMAGE", "xiaoqi-code-sandbox:local")
PROXY_IMAGE = os.environ.get("XIAOQI_SANDBOX_PROXY_IMAGE", "xiaoqi-sandbox-proxy:local")
DOCKER_SOCKET = os.environ.get("DOCKER_HOST", "unix:///var/run/docker.sock")
RUNNER_HOST = os.environ.get("SANDBOX_RUNNER_HOST", "0.0.0.0")
RUNNER_PORT = int(os.environ.get("SANDBOX_RUNNER_PORT", "8090"))

_docker: docker.DockerClient | None = None
_slots = threading.BoundedSemaphore(1)
_executions = Executions(db_path=os.environ.get('XIAOQI_EXECUTION_DB'))
_network_policy_lock = threading.Lock()
_disabled_task_networks: dict[str, float] = {}


def _task_network_is_disabled(task_id: str) -> bool:
    now = time.monotonic()
    with _network_policy_lock:
        expires_at = _disabled_task_networks.get(task_id)
        if expires_at is None:
            return False
        if expires_at <= now:
            _disabled_task_networks.pop(task_id, None)
            return False
        return True


def _disable_task_network(task_id: str) -> dict[str, Any]:
    client = _get_client()
    with _network_policy_lock:
        # Keep the deny in place briefly so a queued execute request cannot
        # recreate its proxy after this control request wins the race.
        expires_at = time.monotonic() + MAX_RUN_SECONDS + 180
        for old_task_id, old_expiry in list(_disabled_task_networks.items()):
            if old_expiry <= time.monotonic():
                _disabled_task_networks.pop(old_task_id, None)
        _disabled_task_networks[task_id] = expires_at
        proxies = client.containers.list(
            all=True,
            filters={
                "label": [
                    f"{OWNER_LABEL}=true",
                    f"com.xiaoqi.task-id={task_id}",
                    "com.xiaoqi.role=network-proxy",
                ],
            },
        )
        stopped = 0
        for proxy in proxies:
            if not str(getattr(proxy, "name", "")).startswith("xq-code-proxy-"):
                continue
            try:
                proxy.reload()
            except NotFound:
                continue
            if proxy.attrs.get("State", {}).get("Running"):
                proxy.kill()
                stopped += 1
    return {"ok": True, "network": "off", "terminated_proxies": stopped}


class RequestError(ValueError):
    pass


class ClientDisconnected(Exception):
    pass


def _safe_relative(value: Any) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise RequestError("文件路径无效")
    if any(part in {"", ".", ".."} for part in value.split("/")):
        raise RequestError("文件路径无效")
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts:
        raise RequestError("文件路径无效")
    return path.as_posix()


def _normalize_domains(raw: Any) -> list[str]:
    if raw is None:
        return []
    if not isinstance(raw, list) or len(raw) > MAX_DOMAINS:
        raise RequestError("联网域名列表无效")
    domains = sorted({str(item).strip().lower().rstrip(".") for item in raw})
    if any(not DOMAIN_RE.fullmatch(domain) for domain in domains):
        raise RequestError("联网域名格式无效")
    return domains


def _decode_b64(value: Any, label: str) -> bytes:
    if not isinstance(value, str):
        raise RequestError(f"{label}内容无效")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise RequestError(f"{label}内容无效") from error


def _safe_filename(value: Any, fallback: str) -> str:
    raw = str(value or fallback).replace("\\", "/").split("/")[-1]
    safe = SAFE_NAME_RE.sub("_", raw).strip(" .")[:120]
    return safe or fallback


def _request_files(request: dict[str, Any]) -> tuple[list[tuple[str, bytes]], str, list[str], list[str]]:
    script_path = request.get("script_path")
    code = request.get("code")
    if script_path is None and (not isinstance(code, str) or not code.strip() or len(code.encode("utf-8")) > MAX_CODE_BYTES):
        raise RequestError("代码不能为空且不能超过 64 KB")
    language = str(request.get("language") or "").lower()
    if language not in {"python", "javascript", "typescript", "shell"}:
        raise RequestError("不支持的代码语言")

    arguments = request.get("arguments", [])
    if script_path is not None:
        script_path = _safe_relative(script_path)
        if not script_path.startswith("scripts/"):
            raise RequestError("技能脚本必须位于 scripts/ 目录")
        extension = PurePosixPath(script_path).suffix.lower()
        allowed = {
            "python": {".py"},
            "javascript": {".js", ".mjs", ".cjs"},
            "typescript": {".ts", ".mts"},
            "shell": {".sh", ".bash"},
        }[language]
        if extension not in allowed:
            raise RequestError("技能脚本扩展名与语言不匹配")
        if not isinstance(arguments, list) or len(arguments) > MAX_SCRIPT_ARGUMENTS:
            raise RequestError("技能脚本参数无效")
        if any(not isinstance(item, str) for item in arguments):
            raise RequestError("技能脚本参数无效")
        if sum(len(item.encode("utf-8")) for item in arguments) > 8 * 1024:
            raise RequestError("技能脚本参数超过 8 KB")
    if not isinstance(arguments, list) or len(arguments) > MAX_SCRIPT_ARGUMENTS or any(not isinstance(item, str) or "\x00" in item for item in arguments):
        raise RequestError("代码参数必须是独立文本值")
    if sum(len(item.encode("utf-8")) for item in arguments) > 8 * 1024:
        raise RequestError("代码参数超过 8 KB")

    files: list[tuple[str, bytes]] = []
    input_manifest: list[dict[str, Any]] = []
    material_total = 0
    materials = request.get("materials", [])
    if not isinstance(materials, list):
        raise RequestError("任务资料格式无效")
    for index, item in enumerate(materials):
        if not isinstance(item, dict):
            continue
        name = _safe_filename(item.get("name") or item.get("filename"), f"material-{index + 1}.txt")
        if isinstance(item.get("base64"), str):
            data = _decode_b64(item["base64"], "任务资料")
        else:
            content = item.get("content", item.get("text", ""))
            data = str(content).encode("utf-8")
        material_total += len(data)
        if len(data) > MAX_SINGLE_FILE_BYTES or material_total > MAX_MATERIAL_BYTES:
            raise RequestError("任务资料超过 20 MB")
        relative = f"materials/{index + 1}-{name}"
        files.append((relative, data))
        input_manifest.append({
            "id": item.get("artifact_id") or item.get("id"),
            "name": name,
            "path": f"/workspace/{relative}",
            "media_type": item.get("media_type"),
            "size": len(data),
        })

    files.append(("input_manifest.json", json.dumps({
        "schema_version": 1,
        "inputs": input_manifest,
        "work_dir": "/workspace/work",
        "output_dir": "/workspace/output",
        "skill_dir": "/workspace/skill",
    }, ensure_ascii=False).encode("utf-8")))

    skill_files = request.get("skill_files", {})
    if not isinstance(skill_files, dict):
        raise RequestError("技能文件格式无效")
    skill_total = 0
    for raw_path, encoded in skill_files.items():
        relative = _safe_relative(raw_path)
        data = _decode_b64(encoded, "技能文件")
        skill_total += len(data)
        if len(data) > MAX_SINGLE_FILE_BYTES or skill_total > MAX_SKILL_BYTES:
            raise RequestError("技能文件总大小超过 50 MB")
        files.append((f"skill/{relative}", data))

    if script_path is not None and f"skill/{script_path}" not in {name for name, _ in files}:
        raise RequestError("技能脚本文件不存在")
    if script_path is None:
        extension = {"python": ".py", "javascript": ".js", "typescript": ".ts", "shell": ".sh"}[language]
        files.append((f"main{extension}", code.encode("utf-8")))
    return files, language, arguments, ([script_path] if script_path else [])


def _make_archive(files: Iterable[tuple[str, bytes]]) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        directories = {"materials", "skill", "skill/scripts", "output", "work", ".home", ".python"}
        for name, _ in files:
            parent = PurePosixPath(name).parent
            while parent.as_posix() not in {".", ""}:
                directories.add(parent.as_posix())
                parent = parent.parent
        for name in sorted(directories):
            entry = tarfile.TarInfo(name + "/")
            entry.type = tarfile.DIRTYPE
            entry.uid = 10001
            entry.gid = 10001
            entry.mode = 0o777 if name in {"output", "work", ".home", ".python"} else 0o755
            archive.addfile(entry)
        for name, data in files:
            entry = tarfile.TarInfo(name)
            entry.uid = 10001
            entry.gid = 10001
            entry.mode = 0o644
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    return output.getvalue()


def _command(language: str, arguments: list[str], script_paths: list[str]) -> list[str]:
    if script_paths:
        path = "/workspace/skill/" + script_paths[0]
        if language == "python":
            return ["python3", "-B", path, *arguments]
        if language == "javascript":
            return ["node", "--disable-proto=throw", path, *arguments]
        if language == "shell":
            return ["bash", "--noprofile", "--norc", path, *arguments]
        return ["node", "--experimental-strip-types", path, *arguments]
    if language == "python":
        return ["python3", "-B", "/workspace/main.py", *arguments]
    if language == "javascript":
        return ["node", "--disable-proto=throw", "/workspace/main.js", *arguments]
    if language == "shell":
        return ["bash", "--noprofile", "--norc", "/workspace/main.sh", *arguments]
    return ["node", "--experimental-strip-types", "/workspace/main.ts", *arguments]


def _get_client() -> docker.DockerClient:
    global _docker
    if _docker is None:
        _docker = docker.DockerClient(base_url=DOCKER_SOCKET, timeout=20)
    _docker.ping()
    return _docker


def _create_task_network(client: Any, name: str, labels: dict[str, str]) -> Any:
    return client.networks.create(
        name=name,
        driver="bridge",
        internal=True,
        options={"com.docker.network.bridge.gateway_mode_ipv4": "isolated"},
        labels=labels,
    )


def _remove_stale_resources(client: docker.DockerClient) -> None:
    filters = {"label": OWNER_LABEL}
    for container in client.containers.list(all=True, filters=filters):
        try:
            container.remove(force=True, v=True)
        except DockerException:
            pass
    for network in client.networks.list(filters=filters):
        try:
            network.remove()
        except DockerException:
            pass
    for volume in client.volumes.list(filters=filters):
        try:
            volume.remove(force=True)
        except DockerException:
            pass


def _recover_interrupted_executions(client: docker.DockerClient) -> None:
    for execution in _executions.interrupted():
        result = execution.result or {'type': 'result', 'execution_id': execution.execution_id, 'ok': False, 'error': 'Runner restarted; the original execution was stopped. External effects may already have occurred; do not automatically replay it.', 'stdout': '', 'stderr': '', 'artifacts': []}
        result = {**result, 'restarted': True, 'cleanup_pending': True}
        filters = {'label': [f'{OWNER_LABEL}=true', f'com.xiaoqi.execution-id={execution.execution_id}', f'com.xiaoqi.task-id={execution.task_id}']}
        containers = client.containers.list(all=True, filters=filters)
        for container in containers:
            try:
                container.reload()
                if container.attrs.get('State', {}).get('Running'):
                    container.kill()
            except NotFound:
                continue
        for container in containers:
            if container.labels.get('com.xiaoqi.role') == 'network-proxy':
                continue
            try:
                result['artifacts'] = _safe_artifacts(container)
                result['stdout'] = _decode_logs(container, 'stdout')[-40000:]
                result['stderr'] = _decode_logs(container, 'stderr')[-20000:]
                result['sandbox_id'] = container.id
            except (RequestError, DockerException, OSError):
                result['error'] = (result.get('error') or '') + ' Some output could not be recovered.'
        # Persist the files before removing any workspace. A later startup must
        # not overwrite this terminal result if cleanup or the runner crashes.
        _executions.finish(execution, result)


def _reconcile_restarted_cleanup(client: docker.DockerClient) -> None:
    if not _executions.healthy:
        return
    for execution in _executions.pending_cleanup():
        filters = {'label': [f'{OWNER_LABEL}=true', f'com.xiaoqi.execution-id={execution.execution_id}', f'com.xiaoqi.task-id={execution.task_id}']}
        for container in client.containers.list(all=True, filters=filters):
            try:
                container.remove(force=True, v=True)
            except DockerException:
                pass
        for network in client.networks.list(filters=filters):
            try:
                network.remove()
            except DockerException:
                pass
        for volume in client.volumes.list(filters=filters):
            try:
                volume.remove(force=True)
            except DockerException:
                pass
        if not client.containers.list(all=True, filters=filters) and not client.networks.list(filters=filters) and not client.volumes.list(filters=filters):
            _executions.cleaned(execution)


def _safe_artifacts(container: Any) -> list[dict[str, str]]:
    try:
        stream, _stat = container.get_archive("/workspace/output")
    except NotFound:
        return []
    archive_bytes = bytearray()
    for chunk in stream:
        archive_bytes.extend(chunk)
        if len(archive_bytes) > MAX_ARTIFACT_TOTAL_BYTES + 1024 * 1024:
            raise RequestError("任务产物总大小超过 20 MB")
    candidates: list[dict[str, str]] = []
    total = 0
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:*") as archive:
        for entry in archive.getmembers():
            if not entry.isfile():
                continue
            relative = entry.name.removeprefix("output/").lstrip("/")
            if not relative or relative.startswith("../") or "/../" in relative:
                continue
            if entry.size > MAX_ARTIFACT_BYTES:
                raise RequestError("单个任务产物超过 10 MB")
            source = archive.extractfile(entry)
            if source is None:
                continue
            data = source.read(MAX_ARTIFACT_BYTES + 1)
            if len(data) > MAX_ARTIFACT_BYTES:
                raise RequestError("单个任务产物超过 10 MB")
            total += len(data)
            if total > MAX_ARTIFACT_TOTAL_BYTES:
                raise RequestError("任务产物总大小超过 20 MB")
            candidates.append({
                "name": _safe_filename(PurePosixPath(relative).name, "artifact"),
                "media_type": mimetypes.guess_type(relative)[0] or "application/octet-stream",
                "base64": base64.b64encode(data).decode("ascii"),
            })
            if len(candidates) > MAX_ARTIFACTS:
                raise RequestError("任务最多可返回 10 个产物")
    return candidates


def _decode_logs(container: Any, stream: str) -> str:
    value = bytes(container.logs(stdout=stream == "stdout", stderr=stream == "stderr", tail=10000))
    expected = 1 if stream == "stdout" else 2
    frames: list[bytes] = []
    offset = 0
    while offset + 8 <= len(value):
        kind = value[offset]
        size = int.from_bytes(value[offset + 4:offset + 8], "big")
        start = offset + 8
        end = start + size
        if kind not in {1, 2} or end > len(value):
            return value[-MAX_LOG_BYTES:].decode("utf-8", errors="replace")
        if kind == expected:
            frames.append(value[start:end])
        offset = end
    decoded = b"".join(frames) if offset == len(value) else value
    return decoded[-MAX_LOG_BYTES:].decode("utf-8", errors="replace")


def _run_sandbox(request: dict[str, Any], send: Any, stdio: StdioChannel | None = None, cancellation: threading.Event | None = None, checkpoint: Any = None) -> dict[str, Any]:
    if cancellation is not None and cancellation.is_set():
        raise RequestError('Execution was cancelled before startup')
    client = _get_client()
    task_id = str(request.get("task_id") or "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task_id):
        raise RequestError("任务 ID 无效")
    command = None
    extra_environment = {}
    if stdio is not None:
        command = request.get("command")
        if (not isinstance(command, list) or not 1 <= len(command) <= 64
                or not command[0]
                or any(not isinstance(arg, str) or "\x00" in arg or len(arg) > 4096 for arg in command)
                or sum(len(arg.encode("utf-8")) for arg in command) > 65536):
            raise RequestError("MCP command must contain separate executable/argument values")
        extra_environment = request.get("environment", {})
        reserved = {"HOME", "PATH", "PYTHONPATH", "PYTHONUSERBASE", "NODE_PATH", "DOCKER_HOST", "SANDBOX_RUNNER_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"}
        if (not isinstance(extra_environment, dict) or len(extra_environment) > 32
                or any(not isinstance(key, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", key)
                       or key.upper() in reserved or not isinstance(value, str) or "\x00" in value or len(value.encode("utf-8")) > 4096
                       for key, value in extra_environment.items())):
            raise RequestError("Invalid MCP process environment")
        request = {**request, "code": "pass", "language": "python"}
        request.pop("script_path", None)
        request.pop("arguments", None)
    files, language, arguments, script_paths = _request_files(request)
    domains = _normalize_domains(request.get("authorized_domains"))
    payload = _make_archive(files)
    suffix = uuid.uuid4().hex
    labels = {OWNER_LABEL: "true", "com.xiaoqi.task-id": task_id[:128]}
    if stdio is None and isinstance(request.get('execution_id'), str) and re.fullmatch(r'[a-f0-9]{32}', request['execution_id']):
        labels['com.xiaoqi.execution-id'] = request['execution_id']
    volume = None
    network = None
    proxy = None
    container = None
    attached = None
    cleanup_pending = False
    run_error: str | None = None
    sandbox_id: str | None = None
    stdout = ""
    stderr = ""
    artifacts: list[dict[str, str]] = []
    process_finished = False
    try:
        volume = client.volumes.create(
            name=f"xq-code-{suffix}",
            labels=labels,
        )
        environment = {
            "HOME": "/workspace/.home",
            "TMPDIR": "/tmp",
            "PYTHONUSERBASE": "/workspace/.python",
            "PYTHONPATH": "/workspace/skill/.xiaoqi/python",
            "NODE_PATH": "/workspace/skill/node_modules",
            "npm_config_cache": "/tmp/npm-cache",
            "PATH": "/workspace/.python/bin:/usr/local/bin:/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "0",
            "LANG": "C.UTF-8",
        }
        environment.update(extra_environment)
        if stdio is not None and stdio.closed:
            raise RequestError("MCP startup was cancelled")
        if domains:
            with _network_policy_lock:
                disabled_until = _disabled_task_networks.get(task_id, 0)
                if disabled_until <= time.monotonic():
                    _disabled_task_networks.pop(task_id, None)
                    disabled_until = 0
                if disabled_until == 0:
                    network = _create_task_network(client, f"xq-code-net-{suffix}", labels)
                    proxy = client.containers.create(
                        image=PROXY_IMAGE,
                        name=f"xq-code-proxy-{suffix}",
                        environment={"XIAOQI_ALLOWED_DOMAINS": json.dumps(domains)},
                        network="bridge",
                        read_only=True,
                        tmpfs={"/tmp": "rw,nosuid,nodev,size=16m"},
                        user="10001:10001",
                        cap_drop=["ALL"],
                        security_opt=["no-new-privileges:true"],
                        pids_limit=32,
                        mem_limit="64m",
                        nano_cpus=100_000_000,
                        labels={**labels, "com.xiaoqi.role": "network-proxy"},
                        log_config=docker.types.LogConfig(type="json-file", config={"max-size": "64k", "max-file": "1"}),
                    )
                    network.connect(proxy, aliases=["sandbox-proxy"])
                    proxy.start()
            if proxy is not None:
                if not _wait_for_proxy(proxy) and not _task_network_is_disabled(task_id):
                    raise RuntimeError("服务器本机联网代理启动失败")
            environment.update({
                "HTTP_PROXY": "http://sandbox-proxy:3128",
                "HTTPS_PROXY": "http://sandbox-proxy:3128",
                "http_proxy": "http://sandbox-proxy:3128",
                "https_proxy": "http://sandbox-proxy:3128",
                "NO_PROXY": "localhost,127.0.0.1",
                "no_proxy": "localhost,127.0.0.1",
            })

        container = client.containers.create(
            image=SANDBOX_IMAGE,
            name=f"xq-code-{suffix}",
            command=command if command is not None else _command(language, arguments, script_paths),
            stdin_open=stdio is not None,
            working_dir="/workspace/skill" if script_paths else "/workspace/work",
            environment=environment,
            user="10001:10001",
            network=network.name if network else "none",
            volumes={volume.name: {"bind": "/workspace", "mode": "rw"}},
            read_only=True,
            tmpfs={"/tmp": "rw,nosuid,nodev,size=128m"},
            cap_drop=["ALL"],
            security_opt=["no-new-privileges:true"],
            pids_limit=32 if stdio is not None else 64,
            mem_limit="256m" if stdio is not None else "384m",
            memswap_limit="256m" if stdio is not None else "384m",
            nano_cpus=250_000_000 if stdio is not None else 500_000_000,
            labels=labels,
            log_config=docker.types.LogConfig(type="json-file", config={"max-size": "1m", "max-file": "1"}),
        )
        sandbox_id = container.id
        if not container.put_archive("/workspace", payload):
            raise RuntimeError("无法准备本次任务的临时工作区")
        if stdio is not None and stdio.closed:
            raise RequestError("MCP startup was cancelled")
        if cancellation is not None and cancellation.is_set():
            raise RequestError('Execution was cancelled before startup')
        container.start()
        if stdio is not None:
            attached = container.attach_socket(params={"stdin": True, "stdout": True, "stderr": True, "stream": True, "logs": True})
            stdio.exporter = lambda: _safe_artifacts(container)
            stdio.attach(attached._sock)
        send({"type": "sandbox_started", "sandbox_id": sandbox_id})
        started_at = time.monotonic()
        exit_code: int | None = None
        while True:
            container.reload()
            state = container.attrs.get("State", {})
            if state.get("Status") in {"exited", "dead"}:
                exit_code = int(state.get("ExitCode", 1))
                break
            if cancellation is not None and cancellation.is_set():
                run_error = 'Execution cancelled; existing files were retained'
                try:
                    container.kill()
                except DockerException:
                    pass
                break
            if stdio is not None and stdio.closed:
                run_error = stdio.error or "MCP connection closed"
                try:
                    container.kill()
                except DockerException:
                    pass
                break
            if time.monotonic() - started_at >= MAX_RUN_SECONDS:
                run_error = "代码执行超过 120 秒，沙箱已停止"
                try:
                    container.kill()
                except DockerException:
                    pass
                break
            send({"type": "heartbeat"})
            time.sleep(1)

        if run_error is None and exit_code not in {None, 0}:
            run_error = f"脚本退出码：{exit_code}"
        try:
            stdout = _decode_logs(container, "stdout")
            stderr = _decode_logs(container, "stderr")
        except DockerException:
            pass
        # Failed and timed-out scripts may already have produced useful files.
        # Export only through the same bounded path/size validator as success.
        artifacts = _safe_artifacts(container)
        process_finished = True
    except (RequestError, DockerException, RuntimeError, OSError) as error:
        # Preserve the cleanup outcome even when preparation or export failed.
        # An exception escaping the finally block used to lose that outcome.
        run_error = str(error)[:500]
    finally:
        if checkpoint is not None:
            try:
                checkpoint({'type': 'result', 'execution_id': request['execution_id'], 'ok': process_finished and run_error is None, 'stdout': stdout[-40000:], 'stderr': stderr[-20000:], 'error': run_error if process_finished or run_error else 'Execution outcome is unknown', 'artifacts': artifacts, 'cleanup_pending': True, 'sandbox_id': sandbox_id})
            except Exception:
                # Stop effects but retain workspaces if durable result storage
                # failed. Startup recovery can still export these exact files.
                for running in (container, proxy):
                    if running is not None:
                        try:
                            running.kill()
                        except DockerException:
                            pass
                raise
        if stdio is not None:
            stdio.close()
        if attached is not None:
            try:
                attached.close()
            except OSError:
                pass
        for resource, action in ((container, "container"), (proxy, "container"), (network, "network"), (volume, "volume")):
            if resource is None:
                continue
            try:
                if action == "container":
                    try:
                        resource.reload()
                        if resource.attrs.get("State", {}).get("Running"):
                            resource.stop(timeout=2)
                    except NotFound:
                        continue
                    resource.remove(force=True, v=True)
                elif action == "network":
                    resource.remove()
                else:
                    resource.remove(force=True)
            except DockerException:
                cleanup_pending = True
        with _network_policy_lock:
            _disabled_task_networks.pop(task_id, None)

    return {
        "type": "result",
        "ok": run_error is None,
        "stdout": stdout[-40000:],
        "stderr": stderr[-20000:],
        "error": run_error,
        "artifacts": artifacts,
        "cleanup_pending": cleanup_pending,
        "sandbox_id": sandbox_id if cleanup_pending else None,
    }


# An idle MCP connection must not hold the only ordinary-code slot: a task may
# call MCP, run helper code, and return to the same MCP process.
_mcp_sessions = McpSessions(_run_sandbox, threading.BoundedSemaphore(1), lifetime=MAX_RUN_SECONDS)


def _wait_for_proxy(proxy: Any) -> bool:
    for _ in range(30):
        try:
            result = proxy.exec_run([
                "python3", "-c",
                "import socket; s=socket.create_connection(('127.0.0.1',3128),timeout=0.5); s.close()",
            ])
            if result.exit_code == 0:
                return True
        except DockerException:
            pass
        try:
            proxy.reload()
            if proxy.attrs.get("State", {}).get("Status") != "running":
                return False
        except DockerException:
            return False
        time.sleep(0.25)
    return False


def _authorized(handler: BaseHTTPRequestHandler) -> bool:
    header = handler.headers.get("Authorization", "")
    prefix = "Bearer "
    return bool(RUNNER_TOKEN) and header.startswith(prefix) and hmac.compare_digest(header[len(prefix):], RUNNER_TOKEN)


class RunnerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _unauthorized(self) -> None:
        # Closing a socket with an unread small POST body can reset TCP before
        # the client sees its 401 (notably on Windows). Never parse the body;
        # bound both bytes and time spent draining an unauthenticated request.
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = 0
        if 0 < length <= 4096:
            previous_timeout = self.connection.gettimeout()
            try:
                self.connection.settimeout(1)
                self.rfile.read(length)
            except OSError:
                pass
            finally:
                self.connection.settimeout(previous_timeout)
        self._json_response(401, {'error': 'unauthorized'})

    def _json_response(self, status: int, data: dict[str, Any]) -> None:
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _start_stream(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def _send(self, event: dict[str, Any]) -> None:
        body = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        self.wfile.write(f"{len(body):X}\r\n".encode("ascii") + body + b"\r\n")
        self.wfile.flush()

    def _finish_stream(self) -> None:
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self) -> None:
        if self.path.startswith("/v1/mcp"):
            self._handle_mcp("GET")
            return
        if self.path != "/health":
            self._json_response(404, {"error": "not found"})
            return
        if not _executions.healthy:
            self._json_response(503, {'status': 'unavailable', 'reason': 'execution_journal_unavailable'})
            return
        try:
            client = _get_client()
            client.images.get(SANDBOX_IMAGE)
            client.images.get(PROXY_IMAGE)
            self._json_response(200, {"status": "ready"})
        except (DockerException, ImageNotFound):
            self._json_response(503, {"status": "unavailable"})

    def do_POST(self) -> None:
        if self.path.startswith("/v1/mcp"):
            self._handle_mcp("POST")
            return
        disable_match = re.fullmatch(
            r"/v1/tasks/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/network/off",
            self.path,
        )
        execution_match = re.fullmatch(r'/v1/executions/([a-f0-9]{32})/(cancel|result|ack)', self.path)
        if self.path != "/v1/execute" and disable_match is None and execution_match is None:
            self._json_response(404, {"error": "not found"})
            return
        if not _authorized(self):
            self._unauthorized()
            return
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            self._json_response(400, {"error": "invalid content length"})
            return
        if length < 0 or length > MAX_BODY_BYTES:
            self._json_response(413, {"error": "request too large"})
            return
        try:
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise RequestError("沙箱请求格式无效")
        except (json.JSONDecodeError, UnicodeDecodeError, RequestError) as error:
            self._json_response(400, {"error": str(error)})
            return
        if disable_match is not None:
            task_id = disable_match.group(1)
            if request.get("task_id") != task_id:
                self._json_response(400, {"error": "task ID does not match request path"})
                return
            try:
                result = _disable_task_network(task_id)
                self._json_response(200, result)
            except (DockerException, RuntimeError) as error:
                self._json_response(503, {"error": str(error)[:300]})
            return
        if execution_match is not None:
            if request.get('execution_id') != execution_match.group(1):
                self._json_response(400, {'error': 'Execution ID does not match request path'})
                return
            try:
                operation = {'cancel': _executions.cancel, 'result': _executions.read, 'ack': _executions.acknowledge}[execution_match.group(2)]
                self._json_response(200, operation(request))
            except StorageUnavailable:
                self._json_response(503, {'error': 'execution_journal_unavailable'})
            except ExecutionError as error:
                self._json_response(409, {'error': str(error)})
            return
        try:
            execution = _executions.claim(request)
        except StorageUnavailable:
            self._json_response(503, {'error': 'execution_journal_unavailable'})
            return
        except ExecutionError as error:
            self._json_response(409, {'error': str(error)})
            return
        acquired = False
        slots = _slots
        deadline = time.monotonic() + 180
        while not execution.cancelled.is_set() and time.monotonic() < deadline:
            if slots.acquire(timeout=0.25):
                acquired = True
                break
        if not acquired:
            result = {'type': 'result', 'ok': False, 'execution_id': request['execution_id'], 'error': 'Execution cancelled before startup' if execution.cancelled.is_set() else 'Execution queue wait expired', 'artifacts': [], 'cleanup_pending': False}
            _executions.finish(execution, result)
            if execution.cancelled.is_set():
                self._start_stream()
                self._send(result)
                self._finish_stream()
            else:
                self._json_response(429, {"error": "服务器代码沙箱正在处理其他任务，请稍后重试"})
            return
        connected = True
        def send(event):
            nonlocal connected
            if not connected:
                return
            try:
                self._send(event)
            except (BrokenPipeError, ConnectionResetError, OSError):
                connected = False
        result = None
        try:
            try:
                self._start_stream()
            except (BrokenPipeError, ConnectionResetError, OSError):
                connected = False
            try:
                result = _run_sandbox(request, send, cancellation=execution.cancelled, checkpoint=lambda result: _executions.checkpoint(execution, result))
            except StorageUnavailable:
                result = {**(execution.result or {}), 'type': 'result', 'ok': False, 'error': 'Execution journal unavailable; original workspace retained', 'cleanup_pending': True}
            except (RequestError, DockerException, RuntimeError, OSError) as error:
                result = {'type': 'result', 'ok': False, 'error': str(error)[:500], 'artifacts': [], 'cleanup_pending': False}
            except Exception:
                result = {'type': 'result', 'ok': False, 'error': '服务器本机 Docker 沙箱执行失败', 'artifacts': [], 'cleanup_pending': True}
            result = {**result, 'execution_id': request['execution_id']}
            _executions.finish(execution, result)
            send(result)
        finally:
            _executions.finish(execution, result)
            slots.release()
            try:
                self._finish_stream()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    def do_DELETE(self) -> None:
        self._handle_mcp("DELETE")

    def _handle_mcp(self, method: str) -> None:
        route = re.fullmatch(r"/v1/mcp(?:/([a-f0-9]{32})(?:/(messages|events|artifacts|ack))?)?", self.path)
        if route is None:
            self._json_response(404, {"error": "not found"})
            return
        if not _authorized(self):
            self._unauthorized()
            return
        lease_id, action = route.groups()
        token = self.headers.get("X-Xiaoqi-Lease-Token", "")
        try:
            body = None
            if method == "POST":
                length = int(self.headers.get("Content-Length", "-1"))
                maximum = MAX_BODY_BYTES if lease_id is None else 2 * 1024 * 1024
                if length < 0 or length > maximum:
                    self._json_response(413, {"error": "request too large"})
                    return
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise LeaseError("Invalid MCP request")
            if method == "POST" and lease_id is None:
                if not isinstance(body.get("lease_token"), str) or not hmac.compare_digest(body["lease_token"], token):
                    raise LeaseError("Invalid lease token")
                lease = _mcp_sessions.create(body)
                if not lease.ready.wait(timeout=15):
                    lease.stop()
                    self._json_response(503, {"error": "MCP process startup timed out"})
                    return
                if lease.done.is_set():
                    self._json_response(503, {"error": "MCP process did not start"})
                    return
                result = {"ready": True}
            elif lease_id is not None:
                lease = _mcp_sessions.get(lease_id, token)
                if method == "GET" and action == "events":
                    result = lease.channel.poll()
                    if lease.done.is_set():
                        result["completion"] = {key: value for key, value in (lease.result or {}).items()
                                                if key in {"ok", "error", "cleanup_pending"}}
                elif method == "GET" and action == "artifacts":
                    if lease.done.is_set():
                        result = {"artifacts":(lease.result or {}).get("artifacts", [])}
                    elif lease.channel.exporter is not None:
                        result = {"artifacts":lease.channel.exporter()}
                    else:
                        raise RuntimeError("MCP workspace is not ready")
                elif method == "POST" and action == "messages":
                    lease.channel.send(body)
                    result = {"ok": True}
                elif method == "DELETE" and action is None:
                    lease.stop()
                    result = {"closed": True, "cleanup_pending": not lease.done.wait(timeout=5)}
                    result["completion"] = lease.result
                elif method == "POST" and action == "ack" and lease.done.is_set():
                    lease.discard()
                    result = {"acknowledged": True}
                else:
                    self._json_response(405, {"error": "method not allowed"})
                    return
            else:
                self._json_response(405, {"error": "method not allowed"})
                return
            self._json_response(200, result)
        except (LeaseError, ValueError, UnicodeDecodeError):
            self._json_response(400, {"error": "Invalid or unavailable MCP lease"})
        except (RuntimeError, OSError, DockerException):
            self._json_response(503, {"error": "MCP process connection unavailable"})


def main() -> int:
    if len(RUNNER_TOKEN) < 32:
        raise RuntimeError("SANDBOX_RUNNER_TOKEN must contain at least 32 characters")
    client = _get_client()
    _recover_interrupted_executions(client)
    _remove_stale_resources(client)
    _reconcile_restarted_cleanup(client)
    for image in (SANDBOX_IMAGE, PROXY_IMAGE):
        try:
            client.images.get(image)
        except ImageNotFound as error:
            raise RuntimeError(f"required local image is missing: {image}") from error
    server = ThreadingHTTPServer((RUNNER_HOST, RUNNER_PORT), RunnerHandler)
    server.daemon_threads = True
    cleanup_stop = threading.Event()
    def retry_cleanup():
        while not cleanup_stop.wait(2):
            try:
                _reconcile_restarted_cleanup(_get_client())
            except (DockerException, RuntimeError, OSError):
                pass
    cleanup_thread = threading.Thread(target=retry_cleanup, daemon=True)
    cleanup_thread.start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        cleanup_stop.set()
        cleanup_thread.join(timeout=5)
        _mcp_sessions.close()
        _executions.close()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
