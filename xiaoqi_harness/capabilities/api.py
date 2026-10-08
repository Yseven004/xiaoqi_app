from __future__ import annotations

import base64
import concurrent.futures
import hashlib
import hmac
import io
import json
import logging
import os
import re
import secrets
import smtplib
import shutil
import subprocess
import threading
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from email.message import EmailMessage
from functools import wraps
from pathlib import Path
from typing import Any, Callable

from flask import Blueprint, Response, current_app, g, jsonify, request, send_file

from .storage import CloudStore, ConfigurationError, RevisionConflict, StoredDocument


capabilities = Blueprint("xiaoqi_capabilities", __name__)
_store: CloudStore | None = None
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_MAX_SKILL_BYTES = 2 * 1024 * 1024
_MAX_TASK_BYTES = 18 * 1024 * 1024
_SAFE_ARTIFACT_NAME = re.compile(r"[^A-Za-z0-9._-]")
_EMAIL_ADDRESS = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
_AUTH_CODE_TTL_SECONDS = 600
_AUTH_CODE_RESEND_SECONDS = 60
_AUTH_CODE_MAX_SENDS_PER_HOUR = 5
_AUTH_CODE_MAX_ATTEMPTS = 5
_TASK_RETENTION_SECONDS = 24 * 60 * 60
_TERMINAL_TASK_STATUSES = {"succeeded", "failed", "cancelled"}
_DSH_RUNTIME_VERSION = os.environ.get("XIAOQI_DSH_VERSION", "0.1.5rc1")
_LOCAL_TASK_EXECUTOR = concurrent.futures.ThreadPoolExecutor(
    max_workers=1, thread_name_prefix="xiaoqi-task"
)
_LOCAL_TASK_LOCK = threading.RLock()
_LOCAL_TASK_CONDITION = threading.Condition(_LOCAL_TASK_LOCK)
_LOCAL_TASKS_SUBMITTED: set[tuple[str, str, int]] = set()
_LOCAL_DSH_ACTIVE_TASKS = 0
_LOCAL_DSH_MAINTENANCE = False
_RUNTIME_LOCK = threading.Lock()
_RUNTIME_STARTED = False
_LOCAL_RUNTIME_ENABLED = False
_LOGGER = logging.getLogger(__name__)


def _agent_runtime_for_task(tenant_id: str, task_request: dict[str, Any]) -> str:
    tenants = {
        item.strip()
        for item in os.environ.get("CAPABILITY_HARNESS_TENANTS", "").split(",")
        if item.strip()
    }
    if tenant_id not in tenants:
        raise PermissionError("当前账号未启用后台 Agent 任务")
    model_id = str(task_request.get("model_id", "deepseek-flash")).lower()
    if model_id not in {"deepseek-flash", "mimo-v2.6-flash"}:
        raise ValueError("所选模型暂不支持后台 Agent 任务")
    return "deepseek-harness"


def store() -> CloudStore:
    global _store
    if _store is None:
        _store = CloudStore()
    return _store


def _json_body(max_bytes: int = _MAX_TASK_BYTES) -> dict[str, Any]:
    if request.content_length is not None and request.content_length > max_bytes:
        raise ValueError("请求超过大小限制")
    value = request.get_json(force=True, silent=False)
    if not isinstance(value, dict):
        raise ValueError("请求内容必须是 JSON 对象")
    if len(request.get_data(cache=True)) > max_bytes:
        raise ValueError("请求超过大小限制")
    return value


def _error(message: str, status: int) -> tuple[Response, int]:
    return jsonify({"error": {"message": message}}), status


def _device_auth(handler: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(handler)
    def wrapped(*args: Any, **kwargs: Any) -> Any:
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            return _error("尚未登录个人账号", 401)
        token = authorization[7:].strip()
        if len(token) < 24:
            return _error("登录凭证无效，请重新登录", 401)
        try:
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            device = store().get(f"device/{token_hash}")
        except ConfigurationError as error:
            return _error(str(error), 503)
        except Exception:
            return _error("暂时无法读取设备凭证", 503)
        if device is None or device.value.get("revoked_at"):
            return _error("个人账号会话已退出，请重新登录", 401)
        g.tenant_id = str(device.value["tenant_id"])
        g.device_id = str(device.value["device_id"])
        g.device_record = device.value
        return handler(*args, **kwargs)

    return wrapped


def _accepts_dsh_tasks(handler: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(handler)
    def wrapped(*args: Any, **kwargs: Any) -> Any:
        with _LOCAL_TASK_CONDITION:
            if _LOCAL_DSH_MAINTENANCE:
                body = request.get_json(force=True, silent=True)
                task_id = str(body.get("task_id", "")) if isinstance(body, dict) else ""
                if task_id and store().get(f"task/{g.tenant_id}/{task_id}") is not None:
                    return handler(*args, **kwargs)
                response, status = _error("DSH 正在维护，请稍后重试", 503)
                response.headers["Retry-After"] = "15"
                return response, status
            return handler(*args, **kwargs)

    return wrapped


def _dsh_admin_state() -> dict[str, Any]:
    saved = store().get("dsh/admin-state")
    if saved is not None:
        return saved.value
    return {
        "maintenance": False,
        "operation_id": None,
        "active_release_id": "builtin",
        "dsh_version": _DSH_RUNTIME_VERSION,
        "config_id": "builtin",
        "config_revision": 0,
        "updated_at": int(time.time()),
    }


def _save_dsh_admin_state(value: dict[str, Any]) -> dict[str, Any]:
    for _ in range(5):
        current = store().get("dsh/admin-state")
        try:
            saved = store().put(
                "dsh/admin-state",
                {**value, "updated_at": int(time.time())},
                current.revision if current else None,
            )
            return saved.value
        except RevisionConflict:
            continue
    raise RevisionConflict("DSH 管理状态已变化，请重试")


def _authorize_dsh_internal() -> bool:
    expected = os.environ.get("XIAOQI_DSH_INTERNAL_TOKEN", "")
    supplied = request.headers.get("X-DSH-Internal-Token", "")
    return len(expected) >= 32 and secrets.compare_digest(supplied, expected)


def _dsh_release_root() -> Path:
    return Path(os.environ.get("XIAOQI_DSH_RELEASE_ROOT", "/opt/xiaoqi-dsh")).resolve()


def _dsh_release(release_id: str) -> dict[str, Any]:
    if release_id == "builtin":
        return {"id": "builtin", "version": _DSH_RUNTIME_VERSION, "binary": None}
    root = _dsh_release_root()
    release_dir = (root / "releases" / _safe_id(release_id, "DSH 版本 ID")).resolve()
    try:
        release_dir.relative_to(root / "releases")
    except ValueError as error:
        raise ValueError("DSH 版本路径无效") from error
    manifest_path = release_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("DSH 版本清单无效")
    lock_path = release_dir / "package-lock.json"
    expected_lock = str(manifest.get("lock_sha256", ""))
    if not lock_path.is_file() or len(expected_lock) != 64 or hashlib.sha256(lock_path.read_bytes()).hexdigest() != expected_lock:
        raise ValueError("DSH 版本完整性检查失败")
    version = str(manifest.get("version", ""))
    binary_relative = str(manifest.get("binary", ""))
    if not version or not binary_relative or Path(binary_relative).is_absolute() or ".." in Path(binary_relative).parts:
        raise ValueError("DSH 版本清单无效")
    binary = (release_dir / binary_relative).resolve()
    try:
        binary.relative_to(release_dir)
    except ValueError as error:
        raise ValueError("DSH 可执行文件路径无效") from error
    if not binary.is_file() or (os.name != "nt" and not os.access(binary, os.X_OK)):
        raise ValueError("DSH 版本文件缺失")
    return {"id": release_id, "version": version, "binary": str(binary)}


def _dsh_config_exists(config_id: str) -> bool:
    if config_id == "builtin":
        return True
    root = _dsh_release_root()
    config_dir = (root / "configs" / _safe_id(config_id, "配置版本 ID")).resolve()
    try:
        config_dir.relative_to(root / "configs")
    except ValueError:
        return False
    manifest_path = config_dir / "profiles" / "xiaoqi-acp" / "package.json"
    try:
        profile = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(profile, dict):
        return False
    dsh = profile.get("dsh", {})
    profile_info = dsh.get("profile", {}) if isinstance(dsh, dict) else {}
    bundles = profile_info.get("bundles", []) if isinstance(profile_info, dict) else None
    return isinstance(bundles, list)


def _dsh_admin_counts() -> dict[str, int]:
    queued = 0
    cursor: str | None = None
    while True:
        page = store().list("task/", limit=200, after_key=cursor)
        if not page:
            break
        for key, document in page:
            cursor = key
            if key.count("/") == 2 and document.value.get("status") == "queued":
                queued += 1
        if len(page) < 200:
            break
    with _LOCAL_TASK_CONDITION:
        active = _LOCAL_DSH_ACTIVE_TASKS
    return {"active_tasks": active, "queued_tasks": queued}


@capabilities.get("/internal/dsh/status")
def internal_dsh_status() -> Any:
    if not _authorize_dsh_internal():
        return _error("无权读取 DSH 管理状态", 401)
    try:
        return jsonify({**_dsh_admin_state(), **_dsh_admin_counts()})
    except ConfigurationError as error:
        return _error(str(error), 503)


@capabilities.get("/internal/dsh/health")
def internal_dsh_health() -> Any:
    if not _authorize_dsh_internal():
        return _error("无权检查 DSH 运行状态", 401)
    try:
        state = _dsh_admin_state()
        release = _dsh_release(str(state.get("active_release_id", "builtin")))
        config_id = str(state.get("config_id", "builtin"))
        if not _dsh_config_exists(config_id):
            return jsonify({"healthy": False, "reason": "当前插件配置缺失或损坏", "state": state}), 503
        binary = str(release["binary"] or shutil.which("dsh") or "")
        if not binary:
            return jsonify({"healthy": False, "reason": "DSH 可执行文件未找到", "state": state}), 503
        result = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=8, check=False, env={"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "/tmp")})
        observed = (result.stdout or result.stderr).strip().splitlines()[0][:120] if (result.stdout or result.stderr).strip() else ""
        version_ok = result.returncode == 0 and observed.split()[-1:] == [str(release["version"])]
        if not version_ok:
            return jsonify({"healthy": False, "expected_version": release["version"], "observed_version": observed, "state": state}), 503
        with tempfile.TemporaryDirectory(prefix="xiaoqi-dsh-health-") as temporary_home:
            home = Path(temporary_home)
            args = [binary, "--profile", "xiaoqi-acp"]
            if config_id == "builtin":
                args.extend(["--from-default-profile", "acp"])
            else:
                from .harness_worker import _prepare_dsh_profile

                _prepare_dsh_profile(home, {"dsh_config_id": config_id})
            args.append("--dump-config")
            profile_check = subprocess.run(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
                check=False,
                cwd=str(home),
                env={"PATH": os.environ.get("PATH", ""), "HOME": str(home), "DSH_HOME": str(home), "DSH_TELEMETRY_MODE": "DISABLED", "CI": "1"},
            )
        healthy = profile_check.returncode == 0
        return jsonify({"healthy": healthy, "expected_version": release["version"], "observed_version": observed, "profile_checked": healthy, "reason": None if healthy else "DSH ACP profile 启动检查失败", "state": state}), 200 if healthy else 503
    except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError) as error:
        return jsonify({"healthy": False, "reason": str(error)[:240]}), 503


@capabilities.post("/internal/dsh/maintenance")
def internal_dsh_maintenance() -> Any:
    global _LOCAL_DSH_MAINTENANCE
    if not _authorize_dsh_internal():
        return _error("无权修改 DSH 维护状态", 401)
    try:
        body = _json_body(2048)
        action = str(body.get("action", ""))
        operation_id = _safe_id(body.get("operation_id", ""), "操作 ID")
        if action not in ("enter", "release"):
            return _error("维护操作无效", 400)
        with _LOCAL_TASK_CONDITION:
            current = _dsh_admin_state()
            if action == "enter":
                if current.get("maintenance") and current.get("operation_id") != operation_id:
                    return _error("另一个 DSH 维护操作正在进行", 409)
                updated = _save_dsh_admin_state({
                    **current,
                    "maintenance": True,
                    "operation_id": operation_id,
                    "previous_release_id": current.get("active_release_id", "builtin"),
                    "previous_config_id": current.get("config_id", "builtin"),
                })
                _LOCAL_DSH_MAINTENANCE = True
            else:
                if not current.get("maintenance"):
                    return jsonify({**current, **_dsh_admin_counts()})
                if current.get("operation_id") != operation_id:
                    return _error("维护操作 ID 不匹配", 409)
                updated = _save_dsh_admin_state({
                    **current,
                    "maintenance": False,
                    "operation_id": None,
                    "previous_release_id": None,
                    "previous_config_id": None,
                })
                _LOCAL_DSH_MAINTENANCE = False
                _LOCAL_TASK_CONDITION.notify_all()
        return jsonify({**updated, **_dsh_admin_counts()})
    except ConfigurationError as error:
        return _error(str(error), 503)
    except (ValueError, TypeError) as error:
        return _error(str(error), 400)


@capabilities.post("/internal/dsh/apply-config")
def internal_dsh_apply_config() -> Any:
    if not _authorize_dsh_internal():
        return _error("无权发布 DSH 配置", 401)
    try:
        body = _json_body(2048)
        config_id = _safe_id(body.get("config_id", ""), "配置版本 ID")
        if not _dsh_config_exists(config_id):
            return _error("配置版本不存在或不完整", 404)
        with _LOCAL_TASK_CONDITION:
            current = _dsh_admin_state()
            if current.get("maintenance"):
                return _error("DSH 正在切换版本，请稍后再应用配置", 409)
            if current.get("config_id") == config_id:
                return jsonify(current), 200
            updated = _save_dsh_admin_state({
                **current,
                "config_id": config_id,
                "config_revision": int(current.get("config_revision", 0)) + 1,
            })
        return jsonify(updated), 200
    except ConfigurationError as error:
        return _error(str(error), 503)
    except (ValueError, TypeError) as error:
        return _error(str(error), 400)


@capabilities.post("/internal/dsh/activate-release")
def internal_dsh_activate_release() -> Any:
    if not _authorize_dsh_internal():
        return _error("无权切换 DSH 版本", 401)
    try:
        body = _json_body(2048)
        release_id = _safe_id(body.get("release_id", ""), "DSH 版本 ID")
        config_id = _safe_id(body.get("config_id", "builtin"), "配置版本 ID")
        release = _dsh_release(release_id)
        if not _dsh_config_exists(config_id):
            return _error("目标配置不存在或不完整", 404)
        with _LOCAL_TASK_CONDITION:
            current = _dsh_admin_state()
            if not current.get("maintenance"):
                return _error("切换版本前必须进入维护状态", 409)
            if _LOCAL_DSH_ACTIVE_TASKS:
                return _error("仍有任务正在运行", 409)
            updated = _save_dsh_admin_state({
                **current,
                "active_release_id": release_id,
                "dsh_version": release["version"],
                "config_id": config_id,
                "config_revision": int(current.get("config_revision", 0)) + int(config_id != current.get("config_id", "builtin")),
            })
        return jsonify(updated), 200
    except ConfigurationError as error:
        return _error(str(error), 503)
    except (OSError, json.JSONDecodeError, ValueError, TypeError) as error:
        return _error(str(error), 400)


def _safe_id(value: Any, field: str = "id") -> str:
    result = str(value or "")
    if not _SAFE_ID.fullmatch(result):
        raise ValueError(f"{field} 格式无效")
    return result


def _public_artifact(artifact: dict[str, Any], task_id: str | None = None) -> dict[str, Any]:
    return {
        **({"task_id": task_id} if task_id else {}),
        **{
            key: artifact[key]
            for key in ("id", "name", "media_type", "size", "sha256")
            if key in artifact
        },
    }


def _public_task_event(event: dict[str, Any], task_id: str) -> dict[str, Any]:
    result = dict(event)
    if isinstance(result.get("artifacts"), list):
        result["artifacts"] = [
            _public_artifact(item, task_id) for item in result["artifacts"] if isinstance(item, dict)
        ]
    return result


def _revision(document: StoredDocument | None) -> int | None:
    return document.revision if document is not None else None


def _put_or_conflict(key: str, value: dict[str, Any], expected: int | None) -> StoredDocument:
    try:
        return store().put(key, value, expected)
    except RevisionConflict:
        raise


def _public_capability(
    tenant: str,
    document: dict[str, Any],
    include_content: bool,
    cloud_revision: int | None = None,
) -> dict[str, Any]:
    result = dict(document)
    result["cloud_revision"] = cloud_revision if cloud_revision is not None else document.get("cloud_revision", 0)
    versions = []
    for version in document.get("versions", []):
        current = dict(version)
        artifact_key = current.pop("artifact_key", "")
        if include_content and artifact_key:
            files = store().get_immutable(artifact_key)
            current["content"] = files.get("SKILL.md", b"").decode("utf-8")
            current["files"] = {
                name: base64.b64encode(contents).decode("ascii")
                for name, contents in files.items()
                if name != "SKILL.md"
            }
        versions.append(current)
    result["versions"] = versions
    return result


def _normalize_record(tenant: str, raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("技能记录格式无效")
    capability_id = _safe_id(raw.get("id"), "能力 ID")
    kind = raw.get("kind", "skill")
    if kind not in ("skill", "plugin"):
        raise ValueError("能力类型无效")
    name = str(raw.get("name", "")).strip()
    description = str(raw.get("description", "")).strip()
    if not name or len(name) > 128 or len(description) > 2048:
        raise ValueError("技能名称或用途说明不符合长度限制")

    versions = raw.get("versions", [])
    if not isinstance(versions, list) or len(versions) > 100:
        raise ValueError("技能版本列表无效")
    normalized_versions: list[dict[str, Any]] = []
    for version in versions:
        if not isinstance(version, dict):
            raise ValueError("技能版本格式无效")
        version_id = _safe_id(version.get("id"), "版本 ID")
        content = str(version.get("content", ""))
        content_bytes = content.encode("utf-8")
        if len(content_bytes) > _MAX_SKILL_BYTES:
            raise ValueError("技能版本超过 2 MB")
        frontmatter = re.match(
            r"\A---\s*\r?\n(?P<header>[\s\S]*?)\r?\n---(?:\r?\n|$)",
            content,
        )
        if frontmatter is None:
            raise ValueError("SKILL.md 必须以 YAML frontmatter 开始")
        header = frontmatter.group("header")
        skill_name = re.search(r"(?m)^name:\s*([a-z0-9]+(?:-[a-z0-9]+)*)\s*$", header)
        skill_description = re.search(r"(?m)^description:\s*(.*?)\s*$", header)
        if skill_name is None or len(skill_name.group(1)) > 64:
            raise ValueError("技能 name 必须是 1-64 位小写字母、数字或连字符")
        if skill_description is None:
            raise ValueError("SKILL.md 必须包含 description")
        description_value = skill_description.group(1).strip().strip(chr(34) + "'")
        if description_value in ("", ">", ">-", ">+", "|", "|-", "|+"):
            trailing = header[skill_description.end() :]
            description_value = " ".join(
                line.strip() for line in trailing.splitlines() if line[:1].isspace()
            ).strip()
        if not description_value or len(description_value) > 1024:
            raise ValueError("技能 description 必须为 1-1024 个字符")
        if not content[frontmatter.end() :].strip():
            raise ValueError("SKILL.md 必须包含 Markdown 技能指令")
        files = {"SKILL.md": content_bytes}
        additional = version.get("files", {})
        if additional:
            if not isinstance(additional, dict):
                raise ValueError("技能资源格式无效")
            for path, encoded in additional.items():
                path = str(path).replace("\\", "/")
                parts = path.split("/")
                if (
                    path.startswith("/")
                    or any(part in ("", ".", "..") for part in parts)
                    or not re.fullmatch(r"[A-Za-z0-9._/-]{1,240}", path)
                    or parts[0] not in ("scripts", "references", "assets")
                    or (
                        parts[0] == "scripts"
                        and not path.lower().endswith(
                            (".py", ".js", ".mjs", ".cjs", ".ts", ".mts")
                        )
                    )
                ):
                    raise ValueError("技能资源路径无效")
                if len(path) > 240 or path == "SKILL.md":
                    raise ValueError("技能资源路径无效")
                file_bytes = base64.b64decode(str(encoded), validate=True)
                files[path] = file_bytes
        if sum(map(len, files.values())) > _MAX_SKILL_BYTES:
            raise ValueError("技能包超过 2 MB")
        if len(files) == 1:
            digest = hashlib.sha256(content_bytes).hexdigest()
        else:
            package_manifest = {
                path: base64.b64encode(data).decode("ascii")
                for path, data in files.items()
            }
            canonical = json.dumps(package_manifest, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
            digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        supplied_hash = str(version.get("content_hash", ""))
        if supplied_hash and supplied_hash != digest:
            raise ValueError("技能版本校验值不匹配")
        artifact_key = (
            f"tenants/{tenant}/capabilities/{capability_id}/versions/"
            f"{version_id}-{digest}.zip"
        )
        store().put_immutable(artifact_key, files)
        normalized_versions.append(
            {
                "id": version_id,
                "number": int(version.get("number", len(normalized_versions) + 1)),
                "content_hash": digest,
                "created_at": str(version.get("created_at", "")),
                "parent_version_id": version.get("parent_version_id"),
                "artifact_key": artifact_key,
            }
        )
    current_version_id = _safe_id(raw.get("current_version_id", ""), "当前版本 ID") if versions else ""
    if versions and current_version_id not in {item["id"] for item in normalized_versions}:
        raise ValueError("当前版本不在技能版本列表中")
    return {
        "schema_version": 1,
        "id": capability_id,
        "kind": kind,
        "name": name,
        "description": description,
        "versions": normalized_versions,
        "current_version_id": current_version_id,
        "created_at": str(raw.get("created_at", "")),
        "updated_at": str(raw.get("updated_at", "")),
        "show_in_menu": raw.get("show_in_menu") is not False,
        "deleted_at": raw.get("deleted_at"),
    }


def _mutate_task(tenant: str, task_id: str, transform: Callable[[dict[str, Any]], dict[str, Any]]) -> StoredDocument:
    key = f"task/{tenant}/{task_id}"
    for _ in range(6):
        existing = store().get(key)
        if existing is None:
            raise KeyError(task_id)
        updated = transform(dict(existing.value))
        if updated.get("status") in _TERMINAL_TASK_STATUSES:
            updated.setdefault("finished_at", int(time.time()))
        else:
            updated.pop("finished_at", None)
        try:
            return store().put(key, updated, existing.revision)
        except RevisionConflict:
            continue
    raise RevisionConflict(task_id)


def _run_local_task(tenant: str, task_id: str, attempt: int) -> None:
    global _LOCAL_DSH_ACTIVE_TASKS
    started = False
    try:
        with _LOCAL_TASK_CONDITION:
            while _LOCAL_DSH_MAINTENANCE:
                _LOCAL_TASK_CONDITION.wait()
            _pin_dsh_task_runtime(tenant, task_id, attempt)
            _LOCAL_DSH_ACTIVE_TASKS += 1
            started = True
        from .worker import run_task

        run_task(store(), tenant, task_id, attempt)
    finally:
        with _LOCAL_TASK_CONDITION:
            if started:
                _LOCAL_DSH_ACTIVE_TASKS = max(0, _LOCAL_DSH_ACTIVE_TASKS - 1)
            _LOCAL_TASKS_SUBMITTED.discard((tenant, task_id, attempt))
            _LOCAL_TASK_CONDITION.notify_all()


def _pin_dsh_task_runtime(tenant: str, task_id: str, attempt: int) -> None:
    current = store().get(f"task/{tenant}/{task_id}")
    if current is None:
        return
    value = current.value
    if value.get("dsh_pinned") or value.get("status") != "queued" or int(value.get("attempt", 0)) != attempt:
        return
    state = _dsh_admin_state()

    def pin(old: dict[str, Any]) -> dict[str, Any]:
        if (
            old.get("dsh_pinned")
            or old.get("status") != "queued"
            or int(old.get("attempt", 0)) != attempt
        ):
            return old
        return {
            **old,
            "runtime_version": str(state.get("dsh_version", _DSH_RUNTIME_VERSION)),
            "dsh_release_id": str(state.get("active_release_id", "builtin")),
            "dsh_config_id": str(state.get("config_id", "builtin")),
            "dsh_config_revision": int(state.get("config_revision", 0)),
            "dsh_pinned": True,
        }

    _mutate_task(tenant, task_id, pin)


def _enqueue_local_task(tenant: str, task_id: str, attempt: int) -> None:
    identity = (tenant, task_id, attempt)
    with _LOCAL_TASK_LOCK:
        if identity in _LOCAL_TASKS_SUBMITTED:
            return
        _LOCAL_TASKS_SUBMITTED.add(identity)
    try:
        _LOCAL_TASK_EXECUTOR.submit(_run_local_task, tenant, task_id, attempt)
    except Exception:
        with _LOCAL_TASK_LOCK:
            _LOCAL_TASKS_SUBMITTED.discard(identity)
        raise


def _enqueue_task(tenant: str, task_id: str, attempt: int) -> None:
    """Use the local single-server queue, retaining the old FC route for rollback."""
    if _LOCAL_RUNTIME_ENABLED:
        _enqueue_local_task(tenant, task_id, attempt)
        return
    invoke_url = os.environ.get("CAPABILITY_TASK_FUNCTION_URL", "").strip()
    internal_token = os.environ.get("CAPABILITY_TASK_INTERNAL_TOKEN", "")
    if not invoke_url:
        raise ConfigurationError("单机任务运行时未启动")
    if len(internal_token) < 32:
        raise ConfigurationError("后台任务函数鉴权未配置")
    payload = json.dumps(
        {"tenant_id": tenant, "task_id": task_id, "attempt": attempt}
    ).encode("utf-8")
    request_object = urllib.request.Request(
        invoke_url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {internal_token}",
            "X-Fc-Invocation-Type": "Async",
            "X-Fc-Async-Task-Id": f"{task_id}-{attempt}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request_object, timeout=8) as response:
            if response.status not in (200, 202):
                raise RuntimeError(f"异步任务入队失败: HTTP {response.status}")
    except urllib.error.HTTPError as error:
        # A retry with the same Function Compute task id is already enqueued.
        if error.code != 409:
            raise


def _task_identity_from_key(key: str) -> tuple[str, str] | None:
    parts = key.split("/")
    if len(parts) != 3 or parts[0] != "task":
        return None
    return parts[1], parts[2]


def _expire_task_content(tenant: str, task_id: str) -> bool:
    current = store().get(f"task/{tenant}/{task_id}")
    if current is None or current.value.get("content_expired"):
        return True
    if current.value.get("status") not in _TERMINAL_TASK_STATUSES:
        return False

    def mark_expiring(old: dict[str, Any]) -> dict[str, Any]:
        if old.get("status") not in _TERMINAL_TASK_STATUSES:
            return old
        return {**old, "retention_state": "expiring", "updated_at": int(time.time())}

    marked = _mutate_task(tenant, task_id, mark_expiring).value
    if marked.get("content_expired"):
        return True
    if marked.get("retention_state") != "expiring":
        return False

    try:
        object_keys: set[str] = set()
        for field in ("input_object_key", "transcript_object_key", "harness_snapshot_key"):
            value = marked.get(field)
            if value:
                object_keys.add(str(value))
        for artifact in marked.get("artifacts", []):
            if isinstance(artifact, dict) and artifact.get("object_key"):
                object_keys.add(str(artifact["object_key"]))
        for key in object_keys:
            store().delete_immutable(key)
        store().delete_objects_prefix(f"tenants/{tenant}/tasks/{task_id}/")
        tenant_hash = hashlib.sha256(tenant.encode("utf-8")).hexdigest()[:24]
        task_hash = hashlib.sha256(task_id.encode("utf-8")).hexdigest()[:24]
        store().delete_objects_prefix(f"tenants/{tenant_hash}/tasks/{task_hash}/")
        from .harness_worker import purge_task_workspace

        purge_task_workspace(tenant, task_id)
    except Exception:
        _LOGGER.exception("Temporary task content cleanup failed for task %s", task_id)
        return False

    now = int(time.time())

    def finish_expiry(old: dict[str, Any]) -> dict[str, Any]:
        if old.get("content_expired"):
            return old
        if (
            old.get("status") not in _TERMINAL_TASK_STATUSES
            or old.get("retention_state") != "expiring"
        ):
            return old
        expired = {
            "task_id": task_id,
            "status": old.get("status", "failed"),
            "attempt": old.get("attempt", 1),
            "created_at": old.get("created_at", now),
            "updated_at": now,
            "finished_at": old.get("finished_at", now),
            "content_expired": True,
            "cancel_requested": bool(old.get("cancel_requested")),
            "events": [{
                "seq": 0,
                "type": "error",
                "code": "content_expired",
                "message": "服务器临时任务副本已过期；手机本地聊天记录仍保留。",
                "created_at": now,
            }],
        }
        for field in (
            "sandbox_id",
            "sandbox_cleanup_pending",
            "sandbox_cleanup_retry_at",
            "sandbox_cleanup_deadline",
        ):
            if field in old:
                expired[field] = old[field]
        return expired

    final = _mutate_task(tenant, task_id, finish_expiry)
    return bool(final.value.get("content_expired"))


def _expire_finished_tasks() -> None:
    now = int(time.time())
    cursor: str | None = None
    content_was_purged = False
    while True:
        page = store().list("task/", limit=200, after_key=cursor)
        if not page:
            if content_was_purged:
                checkpoint = getattr(store(), "checkpoint_wal", None)
                if callable(checkpoint) and not checkpoint():
                    _LOGGER.warning("SQLite WAL could not be truncated after task expiry")
            return
        for key, document in page:
            cursor = key
            identity = _task_identity_from_key(key)
            if identity is None:
                continue
            tenant, task_id = identity
            value = document.value
            if value.get("sandbox_cleanup_pending"):
                try:
                    _retry_pending_task_sandbox_cleanup(tenant, task_id, value)
                except Exception:
                    _LOGGER.exception("Sandbox cleanup retry failed for task %s", task_id)
            if value.get("content_expired"):
                continue
            if value.get("status") not in _TERMINAL_TASK_STATUSES:
                continue
            finished_at = int(value.get("finished_at") or value.get("updated_at") or now)
            if now - finished_at >= _TASK_RETENTION_SECONDS:
                content_was_purged = _expire_task_content(tenant, task_id) or content_was_purged
        if len(page) < 200:
            if content_was_purged:
                checkpoint = getattr(store(), "checkpoint_wal", None)
                if callable(checkpoint) and not checkpoint():
                    _LOGGER.warning("SQLite WAL could not be truncated after task expiry")
            return


def _recover_local_tasks() -> list[tuple[str, str, int]]:
    queued: list[tuple[str, str, int]] = []
    cursor: str | None = None
    while True:
        page = store().list("task/", limit=200, after_key=cursor)
        if not page:
            return queued
        for key, document in page:
            cursor = key
            identity = _task_identity_from_key(key)
            if identity is None:
                continue
            tenant, task_id = identity
            value = document.value
            status = value.get("status")
            if status == "queued":
                queued.append((tenant, task_id, int(value.get("attempt", 1))))
            elif status in ("running", "cancelling"):
                now = int(time.time())
                cancelled = bool(value.get("cancel_requested")) or status == "cancelling"
                terminal_status = "cancelled" if cancelled else "failed"

                def interrupt(old: dict[str, Any]) -> dict[str, Any]:
                    if old.get("status") not in ("running", "cancelling"):
                        return old
                    events = list(old.get("events", []))
                    events.append({
                        "seq": int(events[-1].get("seq", -1)) + 1 if events else 0,
                        "type": "status" if cancelled else "error",
                        "status": terminal_status,
                        "message": None if cancelled else "服务重启，任务已中断；为避免重复操作，请重新发起。",
                        "created_at": now,
                    })
                    return {
                        **old,
                        "status": terminal_status,
                        "error": None if cancelled else "服务重启，任务已中断；为避免重复操作，请重新发起。",
                        "worker_id": None,
                        "worker_lease_until": 0,
                        "active_tool_call": None,
                        "updated_at": now,
                        "events": events[-200:],
                    }

                _mutate_task(tenant, task_id, interrupt)
        if len(page) < 200:
            return queued


def _retention_loop() -> None:
    while True:
        time.sleep(60)
        try:
            _expire_finished_tasks()
        except Exception:
            _LOGGER.exception("Task retention sweep failed")


def start_background_runtime() -> None:
    """Enable the in-process queue and recover persisted tasks before serving."""
    global _LOCAL_RUNTIME_ENABLED, _RUNTIME_STARTED, _LOCAL_DSH_MAINTENANCE
    with _RUNTIME_LOCK:
        if _RUNTIME_STARTED:
            return
        _LOCAL_RUNTIME_ENABLED = True
        os.environ["XIAOQI_SINGLE_SERVER"] = "1"
        try:
            with _LOCAL_TASK_CONDITION:
                _LOCAL_DSH_MAINTENANCE = bool(_dsh_admin_state().get("maintenance"))
            store().remove_orphaned_temp_files()
            _expire_finished_tasks()
            queued = _recover_local_tasks()
            for tenant, task_id, attempt in queued:
                _enqueue_local_task(tenant, task_id, attempt)
            threading.Thread(
                target=_retention_loop,
                name="xiaoqi-retention",
                daemon=True,
            ).start()
        except Exception:
            _LOCAL_RUNTIME_ENABLED = False
            raise
        _RUNTIME_STARTED = True


@capabilities.post("/pairing-codes")
def create_pairing_code() -> Any:
    expected_admin = os.environ.get("CAPABILITY_ADMIN_TOKEN", "")
    supplied = request.headers.get("X-Admin-Token", "")
    if len(expected_admin) < 32 or not secrets.compare_digest(supplied, expected_admin):
        return _error("无权生成配对码", 401)
    try:
        body = _json_body(1024)
        tenant_id = _safe_id(body.get("tenant_id", "personal"), "测试身份")
        code = secrets.token_urlsafe(12)
        code_hash = hashlib.sha256(code.encode()).hexdigest()
        expires_at = int(time.time()) + 600
        store().put(
            f"pair/{code_hash}",
            {"tenant_id": tenant_id, "expires_at": expires_at, "consumed": False},
            None,
        )
        return jsonify({"code": code, "expires_at": expires_at}), 201
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception as error:
        return _error(str(error), 400)


@capabilities.post("/pair")
def exchange_pairing_code() -> Any:
    try:
        body = _json_body(1024)
        code = str(body.get("code", "")).strip()
        if len(code) < 12 or len(code) > 64:
            return _error("配对码无效或已过期", 400)
        code_hash = hashlib.sha256(code.encode()).hexdigest()
        code_key = f"pair/{code_hash}"
        pairing = store().get(code_key)
        if pairing is None or pairing.value.get("consumed"):
            return _error("配对码无效或已使用", 409)
        if int(pairing.value.get("expires_at", 0)) < int(time.time()):
            return _error("配对码已过期", 410)

        token = secrets.token_urlsafe(36)
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        device_id = "device-" + uuid.uuid4().hex
        tenant_id = str(pairing.value["tenant_id"])
        store().put(
            f"device/{token_hash}",
            {"tenant_id": tenant_id, "device_id": device_id, "revoked_at": None},
            None,
        )
        consumed = dict(pairing.value)
        consumed.update({"consumed": True, "device_id": device_id, "consumed_at": int(time.time())})
        try:
            store().put(code_key, consumed, pairing.revision)
        except RevisionConflict:
            device = store().get(f"device/{token_hash}")
            if device:
                store().put(
                    f"device/{token_hash}",
                    {**device.value, "revoked_at": int(time.time())},
                    device.revision,
                )
            return _error("配对码已被另一台设备使用，请生成新配对码", 409)
        return jsonify({"access_token": token, "device_id": device_id}), 201
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("配对失败，请重新生成配对码", 500)


def _normalized_email(value: Any) -> str:
    email = str(value or "").strip().lower()
    if len(email) > 254 or not _EMAIL_ADDRESS.fullmatch(email):
        raise ValueError("邮箱地址格式无效")
    return email


def _email_auth_config() -> tuple[str, str, str, int, str, str]:
    owner_email = os.environ.get("CAPABILITY_OWNER_EMAIL", "").strip().lower()
    smtp_host = os.environ.get("CAPABILITY_SMTP_HOST", "smtp.qq.com").strip()
    smtp_username = os.environ.get("CAPABILITY_SMTP_USERNAME", "").strip()
    smtp_password = os.environ.get("CAPABILITY_SMTP_PASSWORD", "")
    pepper = os.environ.get("CAPABILITY_AUTH_CODE_PEPPER", "")
    try:
        smtp_port = int(os.environ.get("CAPABILITY_SMTP_PORT", "465"))
    except ValueError as error:
        raise ConfigurationError("登录服务暂未配置") from error
    if (
        not _EMAIL_ADDRESS.fullmatch(owner_email)
        or not smtp_host
        or not smtp_username
        or not smtp_password
        or len(pepper) < 32
        or not (1 <= smtp_port <= 65535)
    ):
        raise ConfigurationError("登录服务暂未配置")
    return owner_email, smtp_host, smtp_username, smtp_port, smtp_password, pepper


def _auth_code_key(email: str) -> str:
    return "auth-code/" + hashlib.sha256(email.encode("utf-8")).hexdigest()


def _auth_code_digest(email: str, code: str, pepper: str) -> str:
    message = f"{email}:{code}".encode("utf-8")
    return hmac.new(pepper.encode("utf-8"), message, hashlib.sha256).hexdigest()


def _send_email_login_code(
    email: str,
    code: str,
    *,
    smtp_host: str,
    smtp_username: str,
    smtp_port: int,
    smtp_password: str,
) -> None:
    message = EmailMessage()
    message["Subject"] = "小七登录验证码"
    message["From"] = smtp_username
    message["To"] = email
    message.set_content(f"你的小七登录验证码是：{code}\n验证码 10 分钟内有效，请勿转发给他人。")
    with smtplib.SMTP_SSL(smtp_host, smtp_port, timeout=12) as client:
        client.login(smtp_username, smtp_password)
        client.send_message(message)


def _generic_email_code_response() -> Any:
    return jsonify({"ok": True, "message": "如果该邮箱已获准登录，验证码会发送到邮箱"}), 202


@capabilities.post("/auth/email/start")
def start_email_login() -> Any:
    try:
        body = _json_body(1024)
        email = _normalized_email(body.get("email"))
        owner_email, smtp_host, smtp_username, smtp_port, smtp_password, pepper = (
            _email_auth_config()
        )
        if not hmac.compare_digest(email, owner_email):
            return _generic_email_code_response()

        now = int(time.time())
        key = _auth_code_key(email)
        current = store().get(key)
        send_times = [
            int(value)
            for value in (current.value.get("send_times", []) if current else [])
            if now - int(value) < 3600
        ]
        if current and (
            now - int(current.value.get("sent_at", 0)) < _AUTH_CODE_RESEND_SECONDS
            or len(send_times) >= _AUTH_CODE_MAX_SENDS_PER_HOUR
        ):
            return _generic_email_code_response()

        code = f"{secrets.randbelow(1_000_000):06d}"
        challenge = {
            "email": email,
            "code_hash": _auth_code_digest(email, code, pepper),
            "expires_at": now + _AUTH_CODE_TTL_SECONDS,
            "sent_at": now,
            "send_times": (send_times + [now])[-_AUTH_CODE_MAX_SENDS_PER_HOUR:],
            "attempts": 0,
            "consumed": False,
        }
        saved = store().put(key, challenge, current.revision if current else None)
        try:
            _send_email_login_code(
                email,
                code,
                smtp_host=smtp_host,
                smtp_username=smtp_username,
                smtp_port=smtp_port,
                smtp_password=smtp_password,
            )
        except Exception:
            try:
                store().put(
                    key,
                    {**challenge, "consumed": True},
                    saved.revision,
                )
            except Exception:
                pass
            current_app.logger.warning("Email login code delivery failed")
            return _generic_email_code_response()
        return _generic_email_code_response()
    except ValueError as error:
        return _error(str(error), 400)
    except ConfigurationError:
        return _error("登录服务暂不可用", 503)
    except RevisionConflict:
        return _generic_email_code_response()
    except Exception:
        return _error("登录服务暂不可用", 503)


@capabilities.post("/auth/email/verify")
def verify_email_login() -> Any:
    token = ""
    token_hash = ""
    try:
        body = _json_body(1024)
        email = _normalized_email(body.get("email"))
        code = str(body.get("code", "")).strip()
        owner_email, _, _, _, _, pepper = _email_auth_config()
        if not hmac.compare_digest(email, owner_email) or not re.fullmatch(r"\d{6}", code):
            return _error("验证码无效或已过期", 401)

        key = _auth_code_key(email)
        challenge = store().get(key)
        now = int(time.time())
        if (
            challenge is None
            or challenge.value.get("consumed")
            or int(challenge.value.get("expires_at", 0)) < now
            or int(challenge.value.get("attempts", 0)) >= _AUTH_CODE_MAX_ATTEMPTS
            or not hmac.compare_digest(
                str(challenge.value.get("code_hash", "")),
                _auth_code_digest(email, code, pepper),
            )
        ):
            if challenge and not challenge.value.get("consumed"):
                attempts = int(challenge.value.get("attempts", 0)) + 1
                try:
                    store().put(
                        key,
                        {
                            **challenge.value,
                            "attempts": attempts,
                            "consumed": attempts >= _AUTH_CODE_MAX_ATTEMPTS,
                        },
                        challenge.revision,
                    )
                except RevisionConflict:
                    pass
            return _error("验证码无效或已过期", 401)

        token = secrets.token_urlsafe(36)
        token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        device_id = "device-" + uuid.uuid4().hex
        device_key = f"device/{token_hash}"
        store().put(
            device_key,
            {
                "tenant_id": "personal",
                "device_id": device_id,
                "auth_method": "email",
                "account_email": email,
                "created_at": now,
                "revoked_at": None,
            },
            None,
        )
        try:
            store().put(
                key,
                {**challenge.value, "consumed": True, "consumed_at": now},
                challenge.revision,
            )
        except RevisionConflict:
            issued = store().get(device_key)
            if issued:
                store().put(
                    device_key,
                    {**issued.value, "revoked_at": now},
                    issued.revision,
                )
            return _error("验证码已使用，请重新获取", 409)
        return jsonify({"access_token": token, "device_id": device_id, "email": email}), 201
    except ValueError as error:
        return _error(str(error), 400)
    except ConfigurationError:
        return _error("登录服务暂不可用", 503)
    except Exception:
        if token_hash:
            try:
                issued = store().get(f"device/{token_hash}")
                if issued:
                    store().put(
                        f"device/{token_hash}",
                        {**issued.value, "revoked_at": int(time.time())},
                        issued.revision,
                    )
            except Exception:
                pass
        return _error("登录失败，请重新获取验证码", 503)


@capabilities.get("/auth/me")
@_device_auth
def get_email_session() -> Any:
    if g.device_record.get("auth_method") != "email":
        return _error("请先使用个人邮箱登录", 401)
    return jsonify(
        {
            "authenticated": True,
            "email": g.device_record.get("account_email", ""),
            "tenant_id": g.tenant_id,
        }
    )


@capabilities.delete("/auth/session")
@_device_auth
def revoke_email_session() -> Any:
    if g.device_record.get("auth_method") != "email":
        return _error("会话无效", 401)
    return revoke_device()


@capabilities.delete("/devices/me")
@_device_auth
def revoke_device() -> Any:
    token = request.headers.get("Authorization", "")[7:].strip()
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    key = f"device/{token_hash}"
    device = store().get(key)
    if device is not None:
        store().put(key, {**device.value, "revoked_at": int(time.time())}, device.revision)
    return jsonify({"ok": True})


@capabilities.get("/capabilities")
@_device_auth
def list_capabilities() -> Any:
    try:
        rows = store().list(f"cap/{g.tenant_id}/", limit=200)
        records = [
            _public_capability(g.tenant_id, item.value, include_content=True, cloud_revision=item.revision)
            for _, item in rows
        ]
        return jsonify({"items": records})
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("读取云端能力失败", 503)


@capabilities.post("/capabilities/sync")
@_device_auth
def sync_capability() -> Any:
    try:
        body = _json_body(_MAX_SKILL_BYTES * 100)
        raw = body.get("record")
        normalized = _normalize_record(g.tenant_id, raw)
        key = f"cap/{g.tenant_id}/{normalized['id']}"
        current = store().get(key)
        expected = body.get("expected_revision")
        if expected is not None:
            expected = int(expected)
        if current is None and expected not in (None, 0):
            raise RevisionConflict(normalized["id"])
        if current is not None and expected != current.revision:
            return jsonify({"error": {"message": "云端版本已变化", "current": _public_capability(g.tenant_id, current.value, True, current.revision), "cloud_revision": current.revision}}), 409
        if current is None and expected not in (None, 0):
            return _error("云端版本已变化", 409)
        normalized["cloud_revision"] = (current.revision + 1) if current else 1
        saved = store().put(key, normalized, _revision(current))
        return jsonify({"record": _public_capability(g.tenant_id, saved.value, True, saved.revision), "cloud_revision": saved.revision})
    except RevisionConflict:
        current = store().get(f"cap/{g.tenant_id}/{str((request.get_json(silent=True) or {}).get('record', {}).get('id', ''))}")
        if current:
            return jsonify({"error": {"message": "云端版本已变化", "current": _public_capability(g.tenant_id, current.value, True, current.revision), "cloud_revision": current.revision}}), 409
        return _error("云端版本已变化", 409)
    except ConfigurationError as error:
        return _error(str(error), 503)
    except (ValueError, TypeError, KeyError) as error:
        return _error(str(error), 400)
    except Exception:
        return _error("同步能力失败", 503)


@capabilities.patch("/capabilities/<capability_id>/visibility")
@_device_auth
def set_visibility(capability_id: str) -> Any:
    try:
        capability_id = _safe_id(capability_id, "能力 ID")
        body = _json_body(1024)
        key = f"cap/{g.tenant_id}/{capability_id}"
        current = store().get(key)
        if current is None or current.value.get("deleted_at"):
            return _error("能力不存在", 404)
        expected = int(body.get("expected_revision", -1))
        if expected != current.revision:
            return jsonify({"error": {"message": "云端版本已变化", "current": _public_capability(g.tenant_id, current.value, True, current.revision), "cloud_revision": current.revision}}), 409
        updated = dict(current.value)
        updated["show_in_menu"] = body.get("show_in_menu") is True
        updated["updated_at"] = str(body.get("updated_at") or time.time())
        updated["cloud_revision"] = current.revision + 1
        saved = store().put(key, updated, expected)
        return jsonify({"record": _public_capability(g.tenant_id, saved.value, False, saved.revision), "cloud_revision": saved.revision})
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("更新展示偏好失败", 503)


@capabilities.delete("/capabilities/<capability_id>")
@_device_auth
def delete_capability(capability_id: str) -> Any:
    try:
        capability_id = _safe_id(capability_id, "能力 ID")
        expected = int(request.args.get("expected_revision", "-1"))
        key = f"cap/{g.tenant_id}/{capability_id}"
        current = store().get(key)
        if current is None:
            return jsonify({"ok": True})
        if current.revision != expected:
            return jsonify({"error": {"message": "云端版本已变化", "current": _public_capability(g.tenant_id, current.value, True, current.revision), "cloud_revision": current.revision}}), 409
        updated = dict(current.value)
        updated["deleted_at"] = str(time.time())
        updated["updated_at"] = updated["deleted_at"]
        updated["cloud_revision"] = current.revision + 1
        saved = store().put(key, updated, expected)
        return jsonify({"ok": True, "cloud_revision": saved.revision})
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("同步删除标记失败", 503)


@capabilities.route("/drafts", methods=["GET", "PUT"])
@_device_auth
def drafts() -> Any:
    try:
        prefix = f"draft/{g.tenant_id}/"
        if request.method == "GET":
            return jsonify({"items": [{**item.value, "cloud_revision": item.revision} for _, item in store().list(prefix, limit=200)]})
        body = _json_body(_MAX_SKILL_BYTES)
        draft = body.get("draft")
        if not isinstance(draft, dict):
            return _error("草稿格式无效", 400)
        draft_id = _safe_id(draft.get("id"), "草稿 ID")
        key = prefix + draft_id
        current = store().get(key)
        expected = body.get("expected_revision")
        expected = int(expected) if expected is not None else None
        if current is not None and current.value.get("deleted_at") is not None:
            current_draft = {
                **current.value,
                "cloud_revision": current.revision,
            }
            return jsonify({
                "error": {
                    "message": "云端草稿已删除",
                    "current": current_draft,
                    "cloud_revision": current.revision,
                }
            }), 409
        draft["cloud_revision"] = (current.revision + 1) if current else 1
        if current is None and expected not in (None, 0):
            raise RevisionConflict(draft_id)
        if current is not None and expected != current.revision:
            return jsonify({"error": {"message": "云端草稿已变化", "current": {**current.value, "cloud_revision": current.revision}, "cloud_revision": current.revision}}), 409
        if current is not None and {key: value for key, value in current.value.items() if key != "cloud_revision"} == {key: value for key, value in draft.items() if key != "cloud_revision"}:
            return jsonify({"draft": current.value, "cloud_revision": current.revision})
        saved = store().put(key, draft, _revision(current))
        return jsonify({"draft": saved.value, "cloud_revision": saved.revision})
    except RevisionConflict:
        return _error("云端草稿已变化", 409)
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("同步草稿失败", 503)


@capabilities.delete("/drafts/<draft_id>")
@_device_auth
def delete_draft(draft_id: str) -> Any:
    try:
        safe_id = _safe_id(draft_id, "草稿 ID")
        key = f"draft/{g.tenant_id}/{safe_id}"
        current = store().get(key)
        if current is not None and current.value.get("deleted_at") is not None:
            return jsonify({"ok": True, "cloud_revision": current.revision})
        revision = current.revision + 1 if current is not None else 1
        tombstone = {
            "id": safe_id,
            "deleted_at": str(time.time()),
            "cloud_revision": revision,
        }
        saved = store().put(key, tombstone, _revision(current))
        return jsonify({"ok": True, "cloud_revision": saved.revision})
    except RevisionConflict:
        return _error("云端草稿已变化，请重试删除", 409)
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("删除云端草稿失败", 503)


@capabilities.post("/agent/tasks")
@_device_auth
@_accepts_dsh_tasks
def create_agent_task() -> Any:
    try:
        body = _json_body(_MAX_TASK_BYTES)
        task_id = str(body.get("task_id") or "task-" + uuid.uuid4().hex)
        task_id = _safe_id(task_id, "任务 ID")
        key = f"task/{g.tenant_id}/{task_id}"
        request_hash = hashlib.sha256(
            json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        existing = store().get(key)
        if existing is not None:
            if existing.value.get("content_expired"):
                return _error("任务服务器副本已过期，请使用新的任务 ID 重新发送", 410)
            if existing.value.get("retention_state") == "expiring":
                return _error("任务临时副本正在清理，请稍后重试", 503)
            if existing.value.get("request_hash") != request_hash:
                return _error("任务 ID 已用于另一份请求", 409)
            return jsonify({"task_id": task_id, "status": existing.value["status"], "deduplicated": True})
        if not isinstance(body.get("messages"), list):
            return _error("messages 必须是列表", 400)
        runtime = _agent_runtime_for_task(g.tenant_id, body)
        transcript_key = f"tenants/{g.tenant_id}/tasks/{task_id}/input.json"
        store().put_immutable(transcript_key, {"input.json": json.dumps(body, ensure_ascii=False).encode("utf-8")})
        now = int(time.time())
        task = {
            "task_id": task_id,
            "request_hash": request_hash,
            "tenant_id": g.tenant_id,
            "device_id": g.device_id,
            "runtime": runtime,
            "dsh_pinned": False,
            "status": "queued",
            "attempt": 1,
            "input_object_key": transcript_key,
            "transcript_object_key": transcript_key,
            "events": [{"seq": 0, "type": "status", "status": "queued", "created_at": now}],
            "draft_files": {},
            "artifacts": [],
            "cancel_requested": False,
            "authorized_network_domains": [],
            "requested_network_domains": [],
            "created_at": now,
            "updated_at": now,
        }
        try:
            store().put(key, task, None)
        except RevisionConflict:
            existing = store().get(key)
            if existing is not None and existing.value.get("request_hash") == request_hash:
                return jsonify({"task_id": task_id, "status": existing.value["status"], "deduplicated": True})
            return _error("任务 ID 已用于另一份请求", 409)
        try:
            _enqueue_task(g.tenant_id, task_id, 1)
        except Exception as error:
            _mutate_task(g.tenant_id, task_id, lambda old: {
                **old,
                "status": "failed",
                "error": str(error)[:500],
                "updated_at": int(time.time()),
                "events": old["events"] + [{"seq": len(old["events"]), "type": "error", "message": "后台任务服务暂不可用", "created_at": int(time.time())}],
            })
            return _error("后台任务服务暂不可用，草稿仍保留在本机", 503)
        return jsonify({"task_id": task_id, "status": "queued"}), 202
    except PermissionError as error:
        return _error(str(error), 403)
    except ConfigurationError as error:
        return _error(str(error), 503)
    except (ValueError, TypeError) as error:
        return _error(str(error), 400)
    except Exception:
        return _error("创建后台任务失败", 503)


@capabilities.get("/agent/tasks/<task_id>")
@_device_auth
def get_agent_task(task_id: str) -> Any:
    try:
        task_id = _safe_id(task_id, "任务 ID")
        task = store().get(f"task/{g.tenant_id}/{task_id}")
        if task is None:
            return _error("任务不存在", 404)
        value = task.value
        if value.get("retention_state") == "expiring":
            return _error("任务临时副本正在清理，请稍后重试", 503)
        if value.get("content_expired"):
            return jsonify({
                "task_id": task_id,
                "status": value.get("status", "unknown"),
                "attempt": value.get("attempt", 1),
                "content_expired": True,
                "cloud_revision": task.revision,
            })
        draft_files = value.get("draft_files", {})
        encoded_files = {
            name: base64.b64encode(str(content).encode("utf-8")).decode("ascii")
            for name, content in draft_files.items()
        }
        return jsonify({"task_id": task_id, "status": value["status"], "attempt": value["attempt"], "error": value.get("error"), "result": value.get("result"), "draft": draft_files.get("SKILL.md"), "files": encoded_files, "artifacts": [_public_artifact(item, task_id) for item in value.get("artifacts", []) if isinstance(item, dict)], "requested_network_domains": value.get("requested_network_domains", []), "network_purpose": value.get("network_purpose"), "cloud_revision": task.revision})
    except ConfigurationError as error:
        return _error(str(error), 503)


@capabilities.get("/agent/tasks/<task_id>/events")
@_device_auth
def get_agent_task_events(task_id: str) -> Any:
    try:
        task_id = _safe_id(task_id, "任务 ID")
        after = max(-1, int(request.args.get("after", "-1")))
        task = store().get(f"task/{g.tenant_id}/{task_id}")
        if task is None:
            return _error("任务不存在", 404)
        if task.value.get("retention_state") == "expiring":
            return _error("任务临时副本正在清理，请稍后重试", 503)
        if task.value.get("content_expired"):
            return jsonify({
                "events": task.value.get("events", []),
                "status": task.value.get("status", "unknown"),
                "content_expired": True,
                "sandbox_cleanup_pending": bool(task.value.get("sandbox_cleanup_pending")),
            })
        value = _retry_pending_task_sandbox_cleanup(
            g.tenant_id, task_id, task.value
        )
        return jsonify({
            "events": [
                _public_task_event(event, task_id)
                for event in value.get("events", [])
                if int(event.get("seq", 0)) > after
            ],
            "status": value.get("status", "unknown"),
            "sandbox_cleanup_pending": bool(value.get("sandbox_cleanup_pending")),
        })
    except ConfigurationError as error:
        return _error(str(error), 503)


def _kill_task_sandbox(sandbox_id: str) -> bool:
    cancel_url = os.environ.get("CAPABILITY_TASK_CANCEL_FUNCTION_URL", "").strip()
    internal_token = os.environ.get("CAPABILITY_TASK_INTERNAL_TOKEN", "")
    if not cancel_url or len(internal_token) < 32:
        return False

    payload = json.dumps({"sandbox_id": sandbox_id}).encode("utf-8")
    for cleanup_attempt in range(2):
        try:
            req = urllib.request.Request(
                cancel_url,
                data=payload,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {internal_token}",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=8) as response:
                if 200 <= response.status < 300:
                    return True
        except Exception:
            pass
        if cleanup_attempt == 0:
            time.sleep(0.2)
    return False


def _retry_pending_task_sandbox_cleanup(
    tenant: str, task_id: str, current: dict[str, Any]
) -> dict[str, Any]:
    sandbox_id = current.get("sandbox_id")
    checked_at = int(time.time())
    if (
        not current.get("sandbox_cleanup_pending")
        or not sandbox_id
        or int(current.get("sandbox_cleanup_retry_at") or 0) > checked_at
    ):
        return current

    cleanup_ok = _kill_task_sandbox(str(sandbox_id))
    now = int(time.time())

    def update(old: dict[str, Any]) -> dict[str, Any]:
        if (
            old.get("sandbox_id") != sandbox_id
            or not old.get("sandbox_cleanup_pending")
        ):
            return old
        if not cleanup_ok:
            return {
                **old,
                "sandbox_cleanup_retry_at": now + 5,
                "updated_at": now,
            }

        events = list(old.get("events", []))
        worker_is_active = bool(
            old.get("worker_id")
            and int(old.get("worker_lease_until") or 0) > now
        )
        finish_cancel = (
            old.get("cancel_requested")
            and old.get("status") == "cancelling"
            and not worker_is_active
        )
        if finish_cancel and old.get("status") != "cancelled":
            events.append({
                "seq": int(events[-1].get("seq", -1)) + 1 if events else 0,
                "type": "status",
                "status": "cancelled",
                "created_at": now,
            })
        return {
            **old,
            "sandbox_id": None,
            "sandbox_cleanup_pending": False,
            "sandbox_cleanup_retry_at": None,
            "sandbox_cleanup_deadline": None,
            "status": "cancelled" if finish_cancel else old.get("status"),
            "worker_id": None if finish_cancel else old.get("worker_id"),
            "worker_lease_until": 0 if finish_cancel else old.get("worker_lease_until", 0),
            "active_tool_call": None if finish_cancel else old.get("active_tool_call"),
            "events": events[-200:],
            "updated_at": now,
        }

    return _mutate_task(tenant, task_id, update).value


@capabilities.get("/agent/tasks/<task_id>/artifacts/<artifact_id>")
@_device_auth
def download_agent_task_artifact(task_id: str, artifact_id: str) -> Any:
    try:
        task_id = _safe_id(task_id, "任务 ID")
        artifact_id = _safe_id(artifact_id, "产物 ID")
        task = store().get(f"task/{g.tenant_id}/{task_id}")
        if task is None:
            return _error("任务不存在", 404)
        if task.value.get("content_expired"):
            return _error("文件已过期；手机本地聊天记录仍保留，请重新生成文件", 410)
        if task.value.get("retention_state") == "expiring":
            return _error("文件临时副本正在清理，请稍后重试", 503)
        artifact = next(
            (item for item in task.value.get("artifacts", []) if item.get("id") == artifact_id),
            None,
        )
        if artifact is None:
            return _error("文件不存在或已过期", 404)
        files = store().get_immutable(str(artifact["object_key"]))
        data = files.get(str(artifact["archive_path"]))
        if data is None or hashlib.sha256(data).hexdigest() != artifact.get("sha256"):
            return _error("文件校验失败", 410)
        filename = _SAFE_ARTIFACT_NAME.sub("_", str(artifact.get("name") or "download"))[:120] or "download"
        return send_file(
            io.BytesIO(data),
            mimetype=str(artifact.get("media_type") or "application/octet-stream"),
            as_attachment=True,
            download_name=filename,
            max_age=0,
        )
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("下载文件失败", 503)


@capabilities.post("/agent/tasks/<task_id>/cancel")
@_device_auth
def cancel_agent_task(task_id: str) -> Any:
    try:
        task_id = _safe_id(task_id, "任务 ID")
        def cancel(old: dict[str, Any]) -> dict[str, Any]:
            now = int(time.time())
            status = old.get("status")
            if status in ("succeeded", "failed", "cancelled"):
                return old
            terminal_now = status in ("queued", "awaiting_network_permission")
            events = list(old.get("events", []))
            if terminal_now:
                events.append({"seq": int(events[-1].get("seq", -1)) + 1 if events else 0, "type": "status", "status": "cancelled", "created_at": now})
            return {
                **old,
                "cancel_requested": True,
                "status": "cancelled" if terminal_now else "cancelling" if status == "running" else status,
                "events": events[-200:],
                "updated_at": now,
            }

        task = _mutate_task(g.tenant_id, task_id, cancel)
        sandbox_id = task.value.get("sandbox_id")
        cleanup_ok = not sandbox_id
        if sandbox_id:
            cleanup_ok = _kill_task_sandbox(str(sandbox_id))
        if sandbox_id:
            now = int(time.time())
            task = _mutate_task(g.tenant_id, task_id, lambda old: {
                **old,
                "sandbox_id": None if cleanup_ok else sandbox_id,
                "sandbox_cleanup_pending": not cleanup_ok,
                "sandbox_cleanup_retry_at": None if cleanup_ok else now + 5,
                "sandbox_cleanup_deadline": None if cleanup_ok else now + 300,
                "updated_at": now,
            } if old.get("sandbox_id") == sandbox_id else old)
            if not cleanup_ok and task.value.get("sandbox_id") == sandbox_id:
                return jsonify({
                    "error": "任务已请求停止，但沙箱清理未确认",
                    "task_id": task_id,
                    "status": task.value.get("status"),
                    "cancel_requested": bool(task.value.get("cancel_requested")),
                    "sandbox_cleanup_pending": True,
                }), 503
        return jsonify({"task_id": task_id, "status": task.value.get("status")})
    except KeyError:
        return _error("任务不存在", 404)
    except ConfigurationError as error:
        return _error(str(error), 503)


@capabilities.post("/agent/tasks/<task_id>/authorize-network")
@_device_auth
def authorize_agent_task_network(task_id: str) -> Any:
    try:
        task_id = _safe_id(task_id, "任务 ID")
        body = _json_body(2048)
        requested = body.get("domains", [])
        if not isinstance(requested, list) or not requested:
            return _error("需要明确授权至少一个域名", 400)
        normalized = sorted({str(domain).strip().lower().rstrip(".") for domain in requested})
        for domain in normalized:
            if not re.fullmatch(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain):
                return _error("域名格式无效", 400)
        current = store().get(f"task/{g.tenant_id}/{task_id}")
        if current is None:
            return _error("任务不存在", 404)
        if current.value.get("status") != "awaiting_network_permission":
            return _error("任务当前没有待确认的联网请求", 409)
        requested_domains = set(current.value.get("requested_network_domains", []))
        if not set(normalized).issubset(requested_domains):
            return _error("只能授权本次任务已说明的域名", 400)
        task = _mutate_task(g.tenant_id, task_id, lambda old: {
            **old,
            "status": "queued",
            "attempt": int(old.get("attempt", 1)) + 1,
            "authorized_network_domains": sorted(set(old.get("authorized_network_domains", [])) | set(normalized)),
            "requested_network_domains": [],
            "updated_at": int(time.time()),
        })
        _enqueue_task(g.tenant_id, task_id, int(task.value["attempt"]))
        return jsonify({"task_id": task_id, "status": "queued", "attempt": task.value["attempt"]}), 202
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("授权联网任务失败", 503)


@capabilities.post("/agent/tasks/<task_id>/resume")
@_device_auth
def resume_agent_task(task_id: str) -> Any:
    try:
        task_id = _safe_id(task_id, "任务 ID")
        current = store().get(f"task/{g.tenant_id}/{task_id}")
        if current is None:
            return _error("任务不存在", 404)
        if current.value.get("content_expired"):
            return _error("任务服务器副本已过期，请使用新的任务 ID 重新发送", 410)
        if current.value.get("retention_state") == "expiring":
            return _error("任务临时副本正在清理，请稍后重试", 503)
        if current.value.get("status") not in ("failed", "cancelled"):
            return _error("只有失败或已取消的任务可以恢复", 409)

        def resume(old: dict[str, Any]) -> dict[str, Any]:
            if old.get("retention_state") == "expiring" or old.get("content_expired"):
                raise ValueError("任务临时副本已进入清理，暂时无法恢复")
            if old.get("status") not in ("failed", "cancelled"):
                raise ValueError("任务状态已变化，请刷新后重试")
            return {
                **old,
                "status": "queued",
                "attempt": int(old.get("attempt", 1)) + 1,
                "cancel_requested": False,
                "error": None,
                "updated_at": int(time.time()),
            }

        task = _mutate_task(g.tenant_id, task_id, resume)
        _enqueue_task(g.tenant_id, task_id, int(task.value["attempt"]))
        return jsonify({"task_id": task_id, "status": "queued", "attempt": task.value["attempt"]}), 202
    except KeyError:
        return _error("任务不存在", 404)
    except ConfigurationError as error:
        return _error(str(error), 503)
    except Exception:
        return _error("恢复任务失败", 503)
