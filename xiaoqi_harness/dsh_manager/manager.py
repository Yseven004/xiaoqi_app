from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from contextlib import contextmanager
from functools import wraps
from pathlib import Path
from typing import Any, Callable

from flask import Flask, jsonify, request, send_from_directory
from werkzeug.security import check_password_hash


ROOT = Path(os.environ.get("XIAOQI_DSH_RELEASE_ROOT", "/opt/xiaoqi-dsh")).resolve()
STATIC_ROOT = Path(os.environ.get("XIAOQI_DSH_STATIC_ROOT", "/app/static")).resolve()
DB_PATH = ROOT / "manager.sqlite3"
STATE_PATH = ROOT / "manager-state.json"
ADMIN_COOKIE = "xiaoqi_dsh_admin"
SESSION_TTL = 8 * 60 * 60
CATALOG_URL = (
    "https://raw.githubusercontent.com/hrhgit/deepseek-harness-plugin-manager/"
    "main/catalog/v2/catalog.json"
)
NPM_REGISTRY = "https://registry.npmjs.org"
GITHUB_RELEASES = "https://api.github.com/repos/deepseek-ai/deepseek-harness/releases?per_page=50"
_SAFE_PACKAGE = re.compile(r"^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*$", re.I)
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")
_OPERATION_LOCK = threading.RLock()
_MUTATION_LOCK = threading.Lock()
_OPERATION_THREADS: dict[str, threading.Thread] = {}
_LOGIN_FAILURES: dict[str, tuple[int, float]] = {}
_SEMVER_CACHE: dict[tuple[str, str], bool | None] = {}
_STATE_LOCK = threading.RLock()
_READY = False

app = Flask(__name__)


def _error(message: str, status: int):
    return jsonify({"error": {"message": message}}), status


def _serialize_admin_mutation(handler: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(handler)
    def wrapped(*args: Any, **kwargs: Any) -> Any:
        if request.method in ("GET", "HEAD", "OPTIONS"):
            return handler(*args, **kwargs)
        with _MUTATION_LOCK:
            return handler(*args, **kwargs)

    return wrapped


@contextmanager
def _connect():
    ROOT.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH, timeout=10)
    connection.row_factory = sqlite3.Row
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _ensure_ready() -> None:
    global _READY
    if _READY:
        return
    with _OPERATION_LOCK:
        if _READY:
            return
        for name in ("releases", "configs", "draft", "operations"):
            (ROOT / name).mkdir(parents=True, exist_ok=True)
        with _connect() as connection:
            connection.executescript(
                "CREATE TABLE IF NOT EXISTS sessions ("
                "token_hash TEXT PRIMARY KEY, csrf TEXT NOT NULL, expires_at INTEGER NOT NULL);"
                "CREATE TABLE IF NOT EXISTS operations ("
                "id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, step TEXT NOT NULL,"
                "message TEXT NOT NULL, error TEXT, payload TEXT NOT NULL, result TEXT,"
                "cancel_requested INTEGER NOT NULL DEFAULT 0, cancellable INTEGER NOT NULL DEFAULT 0,"
                "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);"
            )
            connection.commit()
        _recover_interrupted_operations()
        _READY = True
        threading.Thread(target=_run_update_scheduler, name="dsh-update-check", daemon=True).start()


def _body(limit: int = 64 * 1024) -> dict[str, Any]:
    if request.content_length is not None and request.content_length > limit:
        raise ValueError("请求内容过大")
    value = request.get_json(force=True, silent=False)
    if not isinstance(value, dict) or len(request.get_data(cache=True)) > limit:
        raise ValueError("请求内容格式无效")
    return value


def _request_json(url: str, *, body: dict[str, Any] | None = None, headers: dict[str, str] | None = None, timeout: int = 15, limit: int = 3_000_000) -> Any:
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    request_headers = {"Accept": "application/json", "User-Agent": "xiaoqi-dsh-admin/1.0"}
    if headers:
        request_headers.update(headers)
    if data is not None:
        request_headers["Content-Type"] = "application/json"
    request_object = urllib.request.Request(url, data=data, headers=request_headers)
    with urllib.request.urlopen(request_object, timeout=timeout) as response:
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("远端响应超过限制")
    return json.loads(raw.decode("utf-8"))


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp-" + uuid.uuid4().hex)
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _read_state() -> dict[str, Any]:
    try:
        value = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_state(update: dict[str, Any]) -> dict[str, Any]:
    with _STATE_LOCK:
        current = _read_state()
        saved = {**current, **update}
        _atomic_json(STATE_PATH, saved)
        return saved


def _admin_token() -> str:
    return os.environ.get("XIAOQI_DSH_INTERNAL_TOKEN", "")


def _internal(path: str, body: dict[str, Any] | None = None, timeout: int = 12) -> dict[str, Any]:
    token = _admin_token()
    if len(token) < 32:
        raise RuntimeError("DSH 内部控制凭据未配置")
    url = os.environ.get("XIAOQI_DSH_INTERNAL_API_URL", "http://app:8080/v1/internal/dsh").rstrip("/") + path
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    request_object = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-DSH-Internal-Token": token,
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if data is not None else {}),
        },
        method="GET" if data is None else "POST",
    )
    try:
        with urllib.request.urlopen(request_object, timeout=timeout) as response:
            result = json.loads(response.read(128 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            result = json.loads(error.read(16 * 1024).decode("utf-8"))
            message = result.get("error", {}).get("message", "DSH 运行服务拒绝了管理操作")
        except Exception:
            message = "DSH 运行服务暂不可用"
        raise RuntimeError(message) from error
    if not isinstance(result, dict):
        raise RuntimeError("DSH 运行服务返回了无效结果")
    return result


def _session() -> tuple[str, str] | None:
    token = request.cookies.get(ADMIN_COOKIE, "")
    if len(token) < 32:
        return None
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    with _connect() as connection:
        row = connection.execute(
            "SELECT csrf, expires_at FROM sessions WHERE token_hash=?", (token_hash,)
        ).fetchone()
        if row is None or int(row["expires_at"]) < int(time.time()):
            connection.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash,))
            return None
    return token_hash, str(row["csrf"])


def _require_admin(handler: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(handler)
    def wrapped(*args: Any, **kwargs: Any) -> Any:
        current = _session()
        if current is None:
            return _error("登录状态已过期，请重新登录", 401)
        if request.method not in ("GET", "HEAD", "OPTIONS"):
            supplied = request.headers.get("X-CSRF-Token", "")
            if not secrets.compare_digest(supplied, current[1]):
                return _error("页面安全校验失败，请刷新后重试", 403)
        return handler(*args, **kwargs)

    return wrapped


def _origin_matches() -> bool:
    origin = request.headers.get("Origin", "")
    if not origin:
        return True
    try:
        return urllib.parse.urlsplit(origin).netloc.lower() == request.host.lower()
    except ValueError:
        return False


@app.before_request
def _prepare_request() -> Any:
    _ensure_ready()
    if request.path.startswith("/api/") and request.path not in (
        "/api/auth",
        "/api/auth/login",
    ):
        current = _session()
        if current is None:
            return _error("登录状态已过期，请重新登录", 401)
        if request.method not in ("GET", "HEAD", "OPTIONS"):
            supplied = request.headers.get("X-CSRF-Token", "")
            if not secrets.compare_digest(supplied, current[1]):
                return _error("页面安全校验失败，请刷新后重试", 403)


@app.after_request
def _security_headers(response):
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; "
        "form-action 'self'; frame-ancestors 'none'"
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    if request.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.get("/")
def index():
    return send_from_directory(STATIC_ROOT, "index.html")


@app.get("/assets/<path:name>")
def assets(name: str):
    return send_from_directory(STATIC_ROOT / "assets", name)


@app.get("/api/auth")
def auth_state():
    current = _session()
    if current is None:
        return jsonify({"authenticated": False})
    return jsonify({"authenticated": True, "csrf": current[1]})


@app.post("/api/auth/login")
def login():
    if not _origin_matches():
        return _error("登录请求来源无效", 403)
    address = request.remote_addr or "unknown"
    attempts, blocked_until = _LOGIN_FAILURES.get(address, (0, 0.0))
    if blocked_until > time.monotonic():
        return _error("登录尝试过多，请稍后再试", 429)
    try:
        body = _body(2048)
        password = str(body.get("password", ""))
        configured_hash = os.environ.get("XIAOQI_DSH_ADMIN_PASSWORD_HASH", "")
        if len(password) > 1024 or len(configured_hash) < 30 or not check_password_hash(configured_hash, password):
            attempts += 1
            _LOGIN_FAILURES[address] = (attempts, time.monotonic() + (300 if attempts >= 5 else 0))
            return _error("管理员密码不正确", 401)
        _LOGIN_FAILURES.pop(address, None)
        token = secrets.token_urlsafe(48)
        csrf = secrets.token_urlsafe(32)
        token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        with _connect() as connection:
            connection.execute("DELETE FROM sessions WHERE expires_at < ?", (int(time.time()),))
            connection.execute(
                "INSERT INTO sessions(token_hash, csrf, expires_at) VALUES(?,?,?)",
                (token_hash, csrf, int(time.time()) + SESSION_TTL),
            )
        response = jsonify({"authenticated": True, "csrf": csrf})
        response.set_cookie(
            ADMIN_COOKIE,
            token,
            max_age=SESSION_TTL,
            secure=os.environ.get("XIAOQI_DSH_COOKIE_SECURE", "1") != "0",
            httponly=True,
            samesite="Strict",
            path="/",
        )
        return response
    except (ValueError, TypeError) as error:
        return _error(str(error), 400)


@app.post("/api/auth/logout")
@_require_admin
def logout():
    current = _session()
    if current is not None:
        with _connect() as connection:
            connection.execute("DELETE FROM sessions WHERE token_hash=?", (current[0],))
    response = jsonify({"ok": True})
    response.delete_cookie(ADMIN_COOKIE, path="/", secure=os.environ.get("XIAOQI_DSH_COOKIE_SECURE", "1") != "0", httponly=True, samesite="Strict")
    return response


def _semver_satisfies(version_range: str | None, version: str) -> bool | None:
    if not version_range:
        return None
    cache_key = (version_range, version)
    if cache_key in _SEMVER_CACHE:
        return _SEMVER_CACHE[cache_key]
    try:
        npm_root = subprocess.run(
            ["npm", "root", "-g"], capture_output=True, text=True, timeout=5, check=True
        ).stdout.strip()
        semver_path = str(Path(npm_root) / "npm" / "node_modules" / "semver")
        script = "const s=require(process.argv[1]);process.stdout.write(String(s.satisfies(process.argv[2],process.argv[3],{includePrerelease:true})))"
        result = subprocess.run(
            ["node", "-e", script, semver_path, version, version_range],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        value: bool | None = result.stdout.strip() == "true"
    except (OSError, subprocess.SubprocessError, IndexError):
        value = None
    _SEMVER_CACHE[cache_key] = value
    return value


def _compatibility(package: dict[str, Any], runtime_version: str) -> str:
    peers = package.get("peerDependencies", {})
    if not isinstance(peers, dict):
        return "unknown"
    version_range = peers.get("@deepseek-ai/dsh") or peers.get("deepseek-harness")
    result = _semver_satisfies(str(version_range) if version_range else None, runtime_version)
    if result is True:
        return "compatible"
    if result is False:
        return "incompatible"
    return "unknown"


def _package_path(profile: Path, name: str) -> Path:
    parts = name.split("/")
    return profile / "node_modules" / Path(*parts) / "package.json"


def _profile_for_config(config_id: str) -> Path:
    if not _SAFE_ID.fullmatch(config_id) or config_id == "builtin":
        raise ValueError("插件配置 ID 无效")
    path = (ROOT / "configs" / config_id / "profiles" / "xiaoqi-acp").resolve()
    path.relative_to((ROOT / "configs").resolve())
    if not (path / "package.json").is_file():
        raise RuntimeError("当前发布的插件配置不存在")
    return path


def _active_binary(state: dict[str, Any]) -> str:
    release_id = str(state.get("active_release_id", "builtin"))
    if release_id == "builtin":
        binary = shutil.which("dsh")
        if not binary:
            raise RuntimeError("管理服务中未找到基线 DSH CLI")
        return binary
    if not _SAFE_ID.fullmatch(release_id):
        raise RuntimeError("当前 DSH 版本标识无效")
    release_dir = (ROOT / "releases" / release_id).resolve()
    release_dir.relative_to((ROOT / "releases").resolve())
    manifest = json.loads((release_dir / "manifest.json").read_text(encoding="utf-8"))
    relative = Path(str(manifest.get("binary", "")))
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("当前 DSH 版本清单无效")
    binary = (release_dir / relative).resolve()
    binary.relative_to(release_dir)
    if not binary.is_file():
        raise RuntimeError("当前 DSH 可执行文件缺失")
    lock_path = release_dir / "package-lock.json"
    expected_lock = str(manifest.get("lock_sha256", ""))
    if not lock_path.is_file() or len(expected_lock) != 64 or hashlib.sha256(lock_path.read_bytes()).hexdigest() != expected_lock:
        raise RuntimeError("当前 DSH 版本完整性检查失败")
    return str(binary)


def _release_integrity_ok(release_dir: Path, manifest: dict[str, Any]) -> bool:
    try:
        lock_path = release_dir / "package-lock.json"
        expected_lock = str(manifest.get("lock_sha256", ""))
        if not lock_path.is_file() or len(expected_lock) != 64 or hashlib.sha256(lock_path.read_bytes()).hexdigest() != expected_lock:
            return False
        relative = Path(str(manifest.get("binary", "")))
        if relative.is_absolute() or ".." in relative.parts:
            return False
        binary = (release_dir / relative).resolve()
        binary.relative_to(release_dir.resolve())
        return binary.is_file()
    except (OSError, ValueError):
        return False


def _run_command(command: list[str], *, home: Path, operation_id: str | None = None, timeout: int = 900) -> str:
    env = {
        key: value
        for key, value in os.environ.items()
        if key in {"PATH", "HOME", "TMPDIR", "TEMP", "TMP", "SYSTEMROOT", "WINDIR"}
    }
    env["DSH_HOME"] = str(home)
    env["DSH_TELEMETRY_MODE"] = "DISABLED"
    env["npm_config_ignore_scripts"] = "true"
    env["CI"] = "1"
    home.mkdir(parents=True, exist_ok=True)
    log_root = ROOT / "operations"
    log_root.mkdir(parents=True, exist_ok=True)
    log_name = (operation_id or uuid.uuid4().hex) + ".log"
    log_path = log_root / log_name
    with log_path.open("ab") as log_file:
        process = subprocess.Popen(
            command,
            cwd=str(home),
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            shell=False,
            start_new_session=os.name != "nt",
        )

    def stop_process() -> None:
        if process.poll() is not None:
            return
        if os.name == "nt":
            process.terminate()
        else:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                process.kill()
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)

    deadline = time.monotonic() + timeout
    while process.poll() is None:
        if operation_id and _cancel_requested(operation_id):
            stop_process()
            raise InterruptedError("操作已取消")
        if time.monotonic() >= deadline:
            stop_process()
            raise TimeoutError("命令执行超时")
        time.sleep(0.04)
    try:
        with log_path.open("rb") as log_file:
            log_file.seek(max(0, log_file.seek(0, os.SEEK_END) - 20_000))
            output = log_file.read().decode("utf-8", errors="replace")
    except OSError:
        output = ""
    if process.returncode != 0:
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        diagnostic_lines = [
            line for line in lines
            if re.search(r"(?i)(npm error|err!|error:|eai_again|enotfound|econn|etarget|enospc|eacces|unsupported|failed)", line)
        ]
        detail = "\n".join((diagnostic_lines or lines)[-4:])
        detail = re.sub(
            r"(?i)((?:_authToken|access[_-]?token|api[_-]?key|password|secret|authorization)\s*(?:=|:)\s*)(?:(?:bearer|basic)\s+)?[^\s,;]+",
            r"\1[已隐藏]",
            detail,
        )
        detail = re.sub(r"https?://[^/\s:@]+:[^/\s@]+@", "https://[已隐藏]@", detail)[-360:]
        suffix = f"\n{detail}" if detail else "；请查看对应操作日志"
        raise RuntimeError(f"DSH 命令失败（退出码 {process.returncode}）{suffix}")
    return output


def _initialize_draft(state: dict[str, Any]) -> dict[str, Any]:
    draft = ROOT / "draft"
    profile = draft / "profiles" / "xiaoqi-acp"
    metadata_path = ROOT / "draft-state.json"
    metadata = _read_json(metadata_path)
    if profile.is_dir() and (profile / "package.json").is_file() and metadata:
        return metadata
    if draft.exists():
        shutil.rmtree(draft)
    draft.mkdir(parents=True)
    config_id = str(state.get("config_id", "builtin"))
    if config_id != "builtin":
        active = _profile_for_config(config_id)
        shutil.copytree(active, profile, symlinks=True)
    else:
        profile.parent.mkdir(parents=True, exist_ok=True)
        home = draft
        binary = _active_binary(state)
        _run_command(
            [binary, "--profile", "xiaoqi-acp", "--from-default-profile", "acp", "--dump-config"],
            home=home,
            timeout=90,
        )
    metadata = {
        "base_config_id": config_id,
        "dirty": False,
        "created_at": int(time.time()),
    }
    _atomic_json(metadata_path, metadata)
    return metadata


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_draft_profile(profile: Path, manifest: dict[str, Any]) -> None:
    path = profile / "package.json"
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o640)
    os.replace(temporary, path)
    metadata = _read_json(ROOT / "draft-state.json")
    _atomic_json(ROOT / "draft-state.json", {**metadata, "dirty": True, "updated_at": int(time.time())})


def _copy_immutable_profile(source: Path, destination: Path) -> None:
    manifest = _plugin_manifest(source)
    modules = source / "node_modules"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True, ignore=shutil.ignore_patterns("node_modules"))
    if modules.exists() or modules.is_symlink():
        try:
            resolved_modules = modules.resolve(strict=True)
            resolved_modules.relative_to(ROOT)
            shutil.copytree(resolved_modules, destination / "node_modules", symlinks=True)
        except (OSError, ValueError) as error:
            shutil.rmtree(destination, ignore_errors=True)
            raise RuntimeError("插件依赖目录缺失或超出 DSH 管理目录") from error
        return
    dependencies = manifest.get("dependencies", {})
    if isinstance(dependencies, dict) and dependencies:
        shutil.rmtree(destination, ignore_errors=True)
        raise RuntimeError("ACP profile 引用了插件依赖，但没有可发布的 node_modules")


def _plugin_rows(profile: Path, runtime_version: str) -> list[dict[str, Any]]:
    manifest = json.loads((profile / "package.json").read_text(encoding="utf-8"))
    dependencies = manifest.get("dependencies", {})
    selected = manifest.get("dsh", {}).get("profile", {}).get("bundles", [])
    if not isinstance(dependencies, dict) or not isinstance(selected, list):
        raise RuntimeError("DSH profile manifest 格式无效")
    rows = []
    for name, spec in sorted(dependencies.items()):
        if name in {"@deepseek-ai/dsh-base", "@deepseek-ai/dsh-acp-app"}:
            continue
        package_path = _package_path(profile, str(name))
        try:
            package = json.loads(package_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        bundle = package.get("dsh", {}).get("bundle")
        if not isinstance(bundle, dict) or not bundle.get("patch"):
            continue
        compatibility = _compatibility(package, runtime_version)
        rows.append(
            {
                "name": str(name),
                "version": str(package.get("version", spec)),
                "description": str(package.get("description", ""))[:300],
                "source": "official" if str(name).startswith("@deepseek-ai/") else "community",
                "distribution": "github" if re.search(r"github\.com|^github:", str(spec), re.I) else "npm",
                "enabled": name in selected,
                "compatibility": compatibility,
                "peer_range": package.get("peerDependencies", {}).get("@deepseek-ai/dsh")
                or package.get("peerDependencies", {}).get("deepseek-harness"),
                "update_version": package.get("xiaoqiUpdateVersion"),
            }
        )
    return rows


def _verify_profile(binary: str, home: Path, operation_id: str | None = None) -> None:
    _run_command([binary, "--profile", "xiaoqi-acp", "--dump-config"], home=home, operation_id=operation_id, timeout=90)


def _verify_release_profile(binary: str, config_id: str, operation_id: str) -> None:
    home = ROOT / "operations" / operation_id / "compatibility-check"
    if home.exists():
        shutil.rmtree(home)
    try:
        if config_id == "builtin":
            _run_command(
                [binary, "--profile", "xiaoqi-acp", "--from-default-profile", "acp", "--dump-config"],
                home=home,
                operation_id=operation_id,
                timeout=90,
            )
        else:
            profile = _profile_for_config(config_id)
            _copy_immutable_profile(profile, home / "profiles" / "xiaoqi-acp")
            _verify_profile(binary, home, operation_id)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _check_peer_package(package: dict[str, Any], runtime_version: str) -> None:
    peers = package.get("peerDependencies", {})
    version_range = peers.get("@deepseek-ai/dsh") or peers.get("deepseek-harness") if isinstance(peers, dict) else ""
    if not version_range:
        return
    compatibility = _compatibility(package, runtime_version)
    if compatibility == "incompatible":
        raise ValueError(f"插件要求 DSH {version_range}，与当前版本不兼容")
    if compatibility != "compatible":
        raise ValueError(f"无法解析插件声明的 DSH 版本要求：{version_range}")


def _catalog() -> list[dict[str, Any]]:
    catalog = _request_json(CATALOG_URL, timeout=15, limit=4_000_000)
    records = catalog.get("entries", []) if isinstance(catalog, dict) else []
    if not isinstance(records, list):
        raise RuntimeError("社区目录格式暂不支持")
    result = []
    for item in records:
        if not isinstance(item, dict):
            continue
        name = str(item.get("packageName", ""))
        version = str(item.get("version", ""))
        if (
            item.get("availability") != "installable"
            or not _SAFE_PACKAGE.fullmatch(name)
            or not _SEMVER.fullmatch(version)
        ):
            continue
        display_name = item.get("displayName", {})
        summary = item.get("summary", {})
        compatibility = str(item.get("compatibility", "unverified"))
        result.append(
            {
                "name": name,
                "version": version,
                "display_name": str(display_name.get("zh-CN") or display_name.get("en") or name) if isinstance(display_name, dict) else name,
                "description": str(summary.get("zh-CN") or summary.get("en") or "") if isinstance(summary, dict) else str(summary),
                "repository": str(item.get("repositoryUrl", "")),
                "repository_full_name": str(item.get("repositoryFullName", "")),
                "manifest_url": str(item.get("manifestUrl", "")),
                "license": str(item.get("license", "")),
                "source": "community",
                "catalog_compatibility": compatibility,
            }
        )
    return result


def _refresh_catalog_cache() -> dict[str, Any]:
    plugins = _catalog()
    cached = {
        "plugins": plugins,
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "checked_at_epoch": int(time.time()),
    }
    _write_state({"catalog": cached})
    return cached


def _npm_package(name: str, version: str | None = None) -> dict[str, Any]:
    if not _SAFE_PACKAGE.fullmatch(name):
        raise ValueError("npm 包名格式无效")
    suffix = urllib.parse.quote(version, safe=".-+_") if version else "latest"
    package_url = urllib.parse.quote(name, safe="@")
    value = _request_json(f"{NPM_REGISTRY}/{package_url}/{suffix}", timeout=15, limit=1_000_000)
    if not isinstance(value, dict):
        raise RuntimeError("npm registry 返回了无效包信息")
    return value


def _parse_spec(spec: str) -> tuple[str, str, str]:
    value = spec.strip()
    github = re.fullmatch(r"github:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9a-fA-F]{40})", value)
    if github:
        return "github:" + github.group(1) + "/" + github.group(2) + "#" + github.group(3).lower(), "", "github"
    url_github = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?#([0-9a-fA-F]{40})", value)
    if url_github:
        return "github:" + url_github.group(1) + "/" + url_github.group(2) + "#" + url_github.group(3).lower(), "", "github"
    match = re.fullmatch(r"(@[a-z0-9._-]+/[a-z0-9._-]+|[a-z0-9][a-z0-9._-]*)(?:@([^@]+))?", value, re.I)
    if not match or not _SAFE_PACKAGE.fullmatch(match.group(1)):
        raise ValueError("请输入 npm 包名，或 GitHub 仓库与 40 位 commit")
    name, supplied_version = match.groups()
    metadata = _npm_package(name, supplied_version if supplied_version else None)
    version = str(metadata.get("version", ""))
    if not _SEMVER.fullmatch(version):
        raise ValueError("npm 没有返回可固定的精确版本")
    if supplied_version and supplied_version != version:
        raise ValueError("插件版本必须是精确版本号，不能使用版本范围或标签")
    return f"{name}@{version}", version, "npm"


def _source_package(spec: str, version: str, source: str) -> dict[str, Any]:
    if source == "npm":
        name = spec.rsplit("@", 1)[0]
        return _npm_package(name, version)
    return {}


def _draft_profile(state: dict[str, Any] | None = None) -> tuple[Path, dict[str, Any]]:
    current = state or _internal("/status")
    metadata = _initialize_draft(current)
    profile = ROOT / "draft" / "profiles" / "xiaoqi-acp"
    if not (profile / "package.json").is_file():
        raise RuntimeError("DSH ACP 插件配置初始化失败")
    return profile, metadata


def _plugin_manifest(profile: Path) -> dict[str, Any]:
    value = json.loads((profile / "package.json").read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("DSH profile manifest 格式无效")
    dsh = value.get("dsh", {})
    profile_info = dsh.get("profile", {}) if isinstance(dsh, dict) else {}
    if not isinstance(profile_info, dict) or not isinstance(profile_info.get("bundles", []), list):
        raise RuntimeError("DSH profile bundle 列表无效")
    return value


def _restore_plugin_backup(profile: Path, backup: Path) -> None:
    if not backup.is_dir():
        return
    if profile.exists():
        shutil.rmtree(profile)
    shutil.copytree(backup, profile, symlinks=True)


def _perform_plugin_install(operation_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    state = _internal("/status")
    profile, _ = _draft_profile(state)
    home = ROOT / "draft"
    backup = ROOT / "operations" / operation_id / "draft-backup"
    if backup.exists():
        shutil.rmtree(backup)
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(profile, backup, symlinks=True)
    binary = _active_binary(state)
    kind = str(payload.get("action", "install"))
    spec = str(payload.get("spec", ""))
    remove_name = str(payload.get("name", ""))
    original_manifest = _plugin_manifest(profile)
    original_dependencies = set(original_manifest.get("dependencies", {}))
    try:
        if kind == "remove":
            if not _SAFE_PACKAGE.fullmatch(remove_name):
                raise ValueError("插件包名无效")
            _set_step(operation_id, "移除插件", "正在从待应用配置中移除插件")
            _run_command([binary, "plugin", "--profile", "xiaoqi-acp", "remove", remove_name], home=home, operation_id=operation_id)
        else:
            normalized, version, source = _parse_spec(spec)
            package_name = normalized.rsplit("@", 1)[0]
            package = _source_package(normalized, version, source)
            if source == "npm":
                _check_peer_package(package, str(state.get("dsh_version", "")))
            _set_step(operation_id, "安装插件", "正在安装固定版本并检查插件声明")
            _run_command(
                [binary, "plugin", "--profile", "xiaoqi-acp", "add", "--save-exact", normalized],
                home=home,
                operation_id=operation_id,
            )
            if source == "github":
                updated_manifest = _plugin_manifest(profile)
                added = sorted(set(updated_manifest.get("dependencies", {})) - original_dependencies)
                if len(added) != 1:
                    raise ValueError("GitHub 插件安装结果无法唯一识别插件包")
                package_name = added[0]
            package_path = _package_path(profile, package_name)
            installed = json.loads(package_path.read_text(encoding="utf-8"))
            if not isinstance(installed.get("dsh", {}).get("bundle"), dict):
                raise ValueError("该 npm 包没有声明 DSH 插件包，不能作为插件启用")
            _check_peer_package(installed, str(state.get("dsh_version", "")))
            if version and str(installed.get("version", "")) != version:
                raise ValueError("安装结果版本与已检查的精确版本不一致")
        _set_step(operation_id, "检查配置", "正在验证 ACP profile 与插件配置")
        _verify_profile(binary, home, operation_id)
        manifest = _plugin_manifest(profile)
        _atomic_json(profile / "package.json", manifest)
        metadata = _read_json(ROOT / "draft-state.json")
        _atomic_json(ROOT / "draft-state.json", {**metadata, "dirty": True, "updated_at": int(time.time())})
        return {"message": "插件已加入待应用配置", "name": remove_name or payload.get("spec")}
    except Exception:
        _restore_plugin_backup(profile, backup)
        raise


def _perform_release_prepare(operation_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    version = str(payload.get("version", ""))
    if not _SEMVER.fullmatch(version):
        raise ValueError("DSH 版本必须是精確版本号")
    cached = _read_state().get("updates", {})
    candidate = next((item for item in cached.get("releases", []) if item.get("version") == version), None)
    if candidate is None or candidate.get("compatibility") != "compatible":
        raise ValueError("该版本尚未通过已启用插件的兼容性检查")
    release_id = "dsh-" + version
    destination = ROOT / "releases" / release_id
    if destination.is_dir():
        manifest = _read_json(destination / "manifest.json")
        if manifest.get("version") == version and manifest.get("compatibility_checked") is True and _release_integrity_ok(destination, manifest):
            return {"message": "候选版本已经准备完成", "release_id": release_id}
        raise RuntimeError("此版本目录已存在，但完整性检查未通过")
    staging = ROOT / "releases" / (".staging-" + operation_id)
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        _set_step(operation_id, "下载 DSH", f"正在从官方 npm registry 准备 DSH {version}")
        _run_command(
            ["npm", "install", "--prefix", str(staging), "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", f"@deepseek-ai/dsh@{version}"],
            home=staging,
            operation_id=operation_id,
            timeout=1200,
        )
        binary_path = staging / "node_modules" / ".bin" / ("dsh.cmd" if os.name == "nt" else "dsh")
        if not binary_path.is_file():
            raise RuntimeError("候选 DSH 没有提供 CLI 可执行文件")
        binary = str(binary_path.resolve())
        _set_step(operation_id, "检查版本", "正在核对安装版本与 profile 启动配置")
        version_output = _run_command([binary, "--version"], home=staging, operation_id=operation_id, timeout=30)
        observed = (version_output.strip().splitlines() or [""])[-1].split()[-1:]
        if observed != [version]:
            raise RuntimeError("候选 DSH 的实际版本与所选版本不一致")
        state = _internal("/status")
        config_id = str(state.get("config_id", "builtin"))
        if config_id != "builtin":
            profile = _profile_for_config(config_id)
            compatibility, failures = _check_release_compatibility(profile, version)
            if compatibility != "compatible":
                package_names = ", ".join(item["name"] for item in failures if item["result"] != "compatible")
                raise ValueError(f"候選版本與已啟用插件不兼容或尚未確認：{package_names}")
        _verify_release_profile(binary, config_id, operation_id)
        _set_step(operation_id, "记录版本", "正在写入不可变版本清单")
        lock_bytes = (staging / "package-lock.json").read_bytes() if (staging / "package-lock.json").is_file() else b""
        lock_manifest = json.loads(lock_bytes.decode("utf-8")) if lock_bytes else {}
        lock_package = lock_manifest.get("packages", {}).get("node_modules/@deepseek-ai/dsh", {}) if isinstance(lock_manifest, dict) else {}
        if lock_package.get("version") != version or not lock_package.get("integrity"):
            raise RuntimeError("候选 DSH 缺少精确的 npm 完整性记录")
        manifest = {
            "release_id": release_id,
            "version": version,
            "binary": str(binary_path.relative_to(staging).as_posix()),
            "node_version": subprocess.run(["node", "--version"], capture_output=True, text=True, timeout=5, check=True).stdout.strip(),
            "package_integrity": lock_package.get("integrity"),
            "lock_sha256": hashlib.sha256(lock_bytes).hexdigest(),
            "compatibility_checked": True,
            "installed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        _atomic_json(staging / "manifest.json", manifest)
        os.replace(staging, destination)
        return {"message": f"DSH {version} 已准备完成，可在版本管理页切换", "release_id": release_id}
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _perform_plugin_apply(operation_id: str) -> dict[str, Any]:
    state = _internal("/status")
    profile, metadata = _draft_profile(state)
    if not metadata.get("dirty"):
        raise ValueError("没有待应用的插件修改")
    binary = _active_binary(state)
    runtime_version = str(state.get("dsh_version", ""))
    rows = _plugin_rows(profile, runtime_version)
    incompatible = [row["name"] for row in rows if row["enabled"] and row["compatibility"] == "incompatible"]
    unknown = [row["name"] for row in rows if row["enabled"] and row["compatibility"] not in {"compatible", "incompatible"}]
    if incompatible:
        raise ValueError("以下插件声明与当前 DSH 版本不兼容，不能发布：" + ", ".join(incompatible))
    if unknown:
        raise ValueError("以下插件尚未确认兼容当前 DSH 版本，不能发布到小七：" + ", ".join(unknown))
    _set_step(operation_id, "检查配置", "正在验证小七 ACP profile")
    _verify_profile(binary, ROOT / "draft", operation_id)
    config_id = "cfg-" + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S") + "-" + uuid.uuid4().hex[:8]
    destination = ROOT / "configs" / config_id
    destination_profile = destination / "profiles" / "xiaoqi-acp"
    try:
        _set_step(operation_id, "发布配置", "正在生成只读配置版本")
        _copy_immutable_profile(profile, destination_profile)
        config_manifest = {
            "config_id": config_id,
            "runtime_version": runtime_version,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "plugins": [{"name": row["name"], "version": row["version"], "enabled": row["enabled"]} for row in rows],
        }
        _atomic_json(destination / "manifest.json", config_manifest)
        _verify_profile(binary, destination, operation_id)
        published = _internal("/apply-config", {"config_id": config_id})
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    previous_id = str(state.get("config_id", "builtin"))
    if previous_id != config_id:
        history = _read_state().get("config_history", [])
        previous_manifest = _read_json(ROOT / "configs" / previous_id / "manifest.json") if previous_id != "builtin" else {}
        previous_entry = {
            "config_id": previous_id,
            "config_revision": state.get("config_revision", 0),
            "created_at": previous_manifest.get("created_at", datetime.now(timezone.utc).isoformat(timespec="seconds")),
            "plugin_count": len(previous_manifest.get("plugins", [])),
        }
        history = [previous_entry] + [item for item in history if item.get("config_id") != previous_id]
        _write_state({"config_history": history[:20]})
    _atomic_json(ROOT / "draft-state.json", {"base_config_id": config_id, "dirty": False, "created_at": int(time.time())})
    return {"message": "配置已应用，下一条消息生效；正在回答的任务会继续使用旧配置", "config_id": config_id, "config_revision": published.get("config_revision")}


def _perform_release_switch(operation_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    release_id = str(payload.get("release_id", ""))
    if not _SAFE_ID.fullmatch(release_id):
        raise ValueError("目标 DSH 版本 ID 无效")
    state = _internal("/status")
    target = next((item for item in _prepared_releases(state) if item["id"] == release_id), None)
    if target is None or not target.get("prepared"):
        raise ValueError("目标 DSH 版本尚未准备完成")
    if target.get("compatibility") != "compatible":
        raise ValueError("目标 DSH 版本与已启用插件的兼容性尚未確認")
    if release_id == state.get("active_release_id"):
        return {"message": "该版本已经在运行", "release_id": release_id}
    binary = _active_binary({**state, "active_release_id": release_id})
    _verify_release_profile(binary, str(state.get("config_id", "builtin")), operation_id)
    _set_step(operation_id, "暂停新任务", "正在暂停接收新任务", True)
    previous = {
        "release_id": str(state.get("active_release_id", "builtin")),
        "config_id": str(state.get("config_id", "builtin")),
    }
    rollback_failed = False
    try:
        maintenance_state = _internal("/maintenance", {"action": "enter", "operation_id": operation_id})
        previous = {
            "release_id": str(maintenance_state.get("previous_release_id") or maintenance_state.get("active_release_id", "builtin")),
            "config_id": str(maintenance_state.get("previous_config_id") or maintenance_state.get("config_id", "builtin")),
        }
        _update_operation(operation_id, payload={**payload, "previous": previous})
        target = next((item for item in _prepared_releases(maintenance_state) if item["id"] == release_id), None)
        if target is None or not target.get("prepared") or target.get("compatibility") != "compatible":
            raise ValueError("目标版本与当前配置的兼容性检查已变化，请重新检查后再切换")
        if str(maintenance_state.get("config_id", "builtin")) != str(state.get("config_id", "builtin")):
            _verify_release_profile(binary, str(maintenance_state.get("config_id", "builtin")), operation_id)
        deadline = time.monotonic() + 600
        while True:
            if _cancel_requested(operation_id):
                raise InterruptedError("切换已取消，原版本保持运行")
            state = _internal("/status")
            active = int(state.get("active_tasks", 0))
            if active == 0:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("等待当前回答超过 10 分钟，已取消切换并恢复接收任务")
            _set_step(operation_id, "等待当前回答", f"正在等待 {active} 个回答完成，排队任务已暂停", True)
            time.sleep(2)
        if _cancel_requested(operation_id):
            raise InterruptedError("切换已取消，原版本保持运行")
        _set_step(operation_id, "切换版本", "当前回答已完成，正在切换并检查新版本", False)
        _internal("/activate-release", {"release_id": release_id, "config_id": previous["config_id"]})
        health = _internal("/health", timeout=12)
        if not health.get("healthy"):
            _set_step(operation_id, "恢復旧版本", "新版本健康检查失败，正在恢复上一个版本", False)
            _internal("/activate-release", {"release_id": previous["release_id"], "config_id": previous["config_id"]})
            old_health = _internal("/health", timeout=12)
            if not old_health.get("healthy"):
                rollback_failed = True
                raise RuntimeError("新版本检查失败，旧版本恢复也未通过；系统保持维护状态")
            raise RuntimeError("新版本健康检查失败，已自动恢复上一个版本")
        self_release = _internal("/maintenance", {"action": "release", "operation_id": operation_id})
        return {"message": f"已切换到 DSH {target['version']}，新任务已恢复", "release_id": release_id, "active_tasks": self_release.get("active_tasks", 0)}
    except Exception:
        if not rollback_failed:
            try:
                current = _internal("/status")
                if current.get("maintenance") and current.get("operation_id") == operation_id and (
                    current.get("active_release_id") != previous["release_id"]
                    or current.get("config_id") != previous["config_id"]
                ):
                    _internal("/activate-release", {"release_id": previous["release_id"], "config_id": previous["config_id"]})
                    old_health = _internal("/health", timeout=12)
                    if not old_health.get("healthy"):
                        rollback_failed = True
                if not rollback_failed and current.get("maintenance") and current.get("operation_id") == operation_id:
                    _internal("/maintenance", {"action": "release", "operation_id": operation_id})
            except Exception:
                rollback_failed = True
        if rollback_failed:
            raise RuntimeError("版本切换恢复未完成；系统保持维护状态，请检查管理服务")
        raise


def _recover_interrupted_operations() -> None:
    with _connect() as connection:
        rows = connection.execute("SELECT id, kind, payload FROM operations WHERE status IN ('queued','running')").fetchall()
    for row in rows:
        operation_id, kind = str(row["id"]), str(row["kind"])
        try:
            if kind == "release_switch":
                state = _internal("/status", timeout=5)
                if state.get("maintenance") and state.get("operation_id") == operation_id:
                    payload = json.loads(row["payload"])
                    target_id = str(payload.get("release_id", ""))
                    previous = {
                        "release_id": str(state.get("previous_release_id") or payload.get("previous", {}).get("release_id", "builtin")),
                        "config_id": str(state.get("previous_config_id") or payload.get("previous", {}).get("config_id", "builtin")),
                    }
                    if state.get("active_release_id") == target_id:
                        health = _internal("/health", timeout=12)
                        if health.get("healthy"):
                            _internal("/maintenance", {"action": "release", "operation_id": operation_id})
                        else:
                            _internal("/activate-release", {"release_id": previous["release_id"], "config_id": previous["config_id"]})
                            if _internal("/health", timeout=12).get("healthy"):
                                _internal("/maintenance", {"action": "release", "operation_id": operation_id})
                    else:
                        _internal("/maintenance", {"action": "release", "operation_id": operation_id})
            if kind == "plugin_install":
                backup = ROOT / "operations" / operation_id / "draft-backup"
                if backup.is_dir():
                    profile = ROOT / "draft" / "profiles" / "xiaoqi-acp"
                    _restore_plugin_backup(profile, backup)
            _update_operation(operation_id, status="failed", step="服务重启", message="管理服务重启，未完成的操作已恢复或停止", error="服务重启后需要重新发起操作", cancellable=0)
        except Exception:
            _update_operation(operation_id, status="failed", step="需要检查", message="操作中断，服务无法自动确认恢复状态", error="运行状态无法确认；请检查版本管理页和服务日志", cancellable=0)


def _check_plugin_updates_for_profile(profile: Path, runtime_version: str) -> tuple[dict[str, dict[str, str]], str]:
    rows = _plugin_rows(profile, runtime_version)
    updates: dict[str, dict[str, str]] = {}
    for row in rows:
        if row.get("distribution") != "npm":
            continue
        try:
            metadata = _npm_package(row["name"])
            version = str(metadata.get("version", ""))
            if not _SEMVER.fullmatch(version):
                continue
            updates[row["name"]] = {
                "version": version,
                "compatibility": _compatibility(metadata, runtime_version),
            }
        except (OSError, ValueError, urllib.error.URLError):
            continue
    checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    _write_state({"plugin_updates": updates, "plugins_last_check": checked_at})
    return updates, checked_at


def _run_update_scheduler() -> None:
    while True:
        try:
            state = _read_state()
            last = state.get("updates", {}).get("last_check")
            if not last or time.time() - datetime.fromisoformat(last).timestamp() >= 6 * 60 * 60:
                _check_release_updates()
        except Exception:
            pass
        try:
            last = _read_state().get("plugins_last_check")
            if not last or time.time() - datetime.fromisoformat(last).timestamp() >= 6 * 60 * 60:
                state = _internal("/status")
                profile, _ = _draft_profile(state)
                _check_plugin_updates_for_profile(profile, str(state.get("dsh_version", "")))
        except Exception:
            pass
        try:
            checked_at = int(_read_state().get("catalog", {}).get("checked_at_epoch", 0))
            if time.time() - checked_at >= 6 * 60 * 60:
                _refresh_catalog_cache()
        except Exception:
            pass
        time.sleep(6 * 60 * 60)


def _active_plugins(state: dict[str, Any]) -> list[dict[str, Any]]:
    config_id = str(state.get("config_id", "builtin"))
    if config_id == "builtin":
        return []
    try:
        return _plugin_rows(_profile_for_config(config_id), str(state.get("dsh_version", "")))
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError):
        return []


def _version_parts(value: str) -> tuple[int, int, int, str] | None:
    if not _SEMVER.fullmatch(value):
        return None
    main, _, prerelease = value.partition("-")
    core = main.split("+", 1)[0]
    return (*map(int, core.split(".")), prerelease)


def _check_release_compatibility(profile: Path | None, version: str) -> tuple[str, list[dict[str, str]]]:
    if profile is None:
        return "compatible", []
    rows = _plugin_rows(profile, version)
    checks = [{"name": row["name"], "result": row["compatibility"]} for row in rows if row["enabled"]]
    if any(item["result"] == "incompatible" for item in checks):
        return "incompatible", checks
    if any(item["result"] != "compatible" for item in checks):
        return "unknown", checks
    return "compatible", checks


def _check_release_updates() -> dict[str, Any]:
    metadata = _npm_package("@deepseek-ai/dsh")
    all_metadata = _request_json(
        f"{NPM_REGISTRY}/@deepseek-ai%2fdsh", timeout=20, limit=5_000_000
    )
    github_releases = []
    github_error = None
    try:
        github_releases = _request_json(GITHUB_RELEASES, timeout=15, limit=4_000_000)
    except (OSError, ValueError, urllib.error.URLError) as error:
        github_error = str(error)[:200]
    state = _internal("/status")
    active_profile = None if state.get("config_id") == "builtin" else _profile_for_config(str(state["config_id"]))
    github_by_version = {}
    if isinstance(github_releases, list):
        for release in github_releases:
            if not isinstance(release, dict):
                continue
            tag = str(release.get("tag_name", "")).removeprefix("v")
            if _SEMVER.fullmatch(tag):
                github_by_version[tag] = release
    versions = all_metadata.get("versions", {}) if isinstance(all_metadata, dict) else {}
    times = all_metadata.get("time", {}) if isinstance(all_metadata, dict) else {}
    candidates = []
    for version in versions:
        parts = _version_parts(str(version))
        if not parts:
            continue
        compatibility, checks = _check_release_compatibility(active_profile, str(version))
        release = github_by_version.get(str(version), {})
        candidates.append(
            {
                "id": "dsh-" + str(version),
                "version": str(version),
                "compatibility": compatibility,
                "plugin_checks": checks,
                "released_at": times.get(str(version)),
                "notes": str(release.get("name") or release.get("body") or "官方 npm 版本")[:240],
                "github_release_found": bool(release),
                "source": "npm registry",
            }
        )
    candidates.sort(key=lambda item: (times.get(item["version"], ""), _version_parts(item["version"]) or (0, 0, 0, "")), reverse=True)
    cache = {
        "last_check": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "npm_latest": str(metadata.get("version", "")),
        "github_checked": github_error is None,
        "github_error": github_error,
        "releases": candidates[:30],
    }
    _write_state({"updates": cache})
    return cache


def _prepared_releases(state: dict[str, Any]) -> list[dict[str, Any]]:
    active = str(state.get("active_release_id", "builtin"))
    config_id = str(state.get("config_id", "builtin"))
    active_profile = None if config_id == "builtin" else _profile_for_config(config_id)
    result = []
    directory = ROOT / "releases"
    for child in directory.iterdir():
        if not child.is_dir() or not _SAFE_ID.fullmatch(child.name):
            continue
        manifest = _read_json(child / "manifest.json")
        if not manifest or not _release_integrity_ok(child, manifest):
            continue
        compatibility, plugin_checks = _check_release_compatibility(active_profile, str(manifest.get("version", "")))
        result.append(
            {
                "id": child.name,
                "version": str(manifest.get("version", "")),
                "current": child.name == active,
                "prepared": True,
                "compatibility": compatibility if manifest.get("compatibility_checked") is True else "unknown",
                "plugin_checks": plugin_checks,
                "notes": "已安装并通过候选版本启动检查。",
            }
        )
    if active == "builtin":
        result.append(
            {
                "id": "builtin",
                "version": str(state.get("dsh_version", "")),
                "current": True,
                "prepared": True,
                "compatibility": "compatible",
                "notes": "镜像内置版本。",
            }
        )
    return sorted(result, key=lambda item: (not item["current"], item["version"]))


def _operation_record(operation_id: str) -> dict[str, Any] | None:
    with _connect() as connection:
        row = connection.execute("SELECT * FROM operations WHERE id=?", (operation_id,)).fetchone()
    if row is None:
        return None
    return {
        "id": row["id"],
        "kind": row["kind"],
        "status": row["status"],
        "step": row["step"],
        "message": row["message"],
        "error": row["error"],
        "result": json.loads(row["result"]) if row["result"] else None,
        "cancellable": bool(row["cancellable"]),
    }


def _update_operation(operation_id: str, **values: Any) -> None:
    allowed = {"status", "step", "message", "error", "result", "payload", "cancellable", "cancel_requested"}
    updates = {key: value for key, value in values.items() if key in allowed}
    if "result" in updates and updates["result"] is not None:
        updates["result"] = json.dumps(updates["result"], ensure_ascii=False)
    if "payload" in updates:
        updates["payload"] = json.dumps(updates["payload"], ensure_ascii=False)
    if not updates:
        return
    query = ",".join(f"{key}=?" for key in updates) + ",updated_at=?"
    with _connect() as connection:
        connection.execute(
            f"UPDATE operations SET {query} WHERE id=?",
            (*updates.values(), int(time.time()), operation_id),
        )


def _cancel_requested(operation_id: str) -> bool:
    with _connect() as connection:
        row = connection.execute("SELECT cancel_requested FROM operations WHERE id=?", (operation_id,)).fetchone()
    return bool(row[0]) if row else False


def _start_operation(kind: str, payload: dict[str, Any]) -> str:
    operation_id = uuid.uuid4().hex
    cancellable = kind in {"plugin_install", "release_prepare", "release_switch"}
    now = int(time.time())
    with _connect() as connection:
        connection.execute(
            "INSERT INTO operations(id,kind,status,step,message,payload,cancellable,created_at,updated_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (operation_id, kind, "queued", "排队中", "操作即将开始", json.dumps(payload), int(cancellable), now, now),
        )
    thread = threading.Thread(target=_run_operation, args=(operation_id, kind, payload), daemon=True, name="dsh-op-" + operation_id[:8])
    with _OPERATION_LOCK:
        _OPERATION_THREADS[operation_id] = thread
    thread.start()
    return operation_id


def _set_step(operation_id: str, step: str, message: str, cancellable: bool = True) -> None:
    _update_operation(operation_id, step=step, message=message, cancellable=int(cancellable))


def _run_operation(operation_id: str, kind: str, payload: dict[str, Any]) -> None:
    if _cancel_requested(operation_id):
        _update_operation(operation_id, status="cancelled", step="已取消", message="操作已取消", cancellable=0)
        with _OPERATION_LOCK:
            _OPERATION_THREADS.pop(operation_id, None)
        return
    _update_operation(operation_id, status="running", step="准备中", message="正在准备操作")
    try:
        with _MUTATION_LOCK:
            if _cancel_requested(operation_id):
                raise InterruptedError("操作已取消")
            if kind == "plugin_install":
                result = _perform_plugin_install(operation_id, payload)
            elif kind == "release_prepare":
                result = _perform_release_prepare(operation_id, payload)
            elif kind == "release_switch":
                result = _perform_release_switch(operation_id, payload)
            elif kind == "plugin_apply":
                result = _perform_plugin_apply(operation_id)
            else:
                raise ValueError("不支持的管理操作")
        _update_operation(operation_id, status="completed", step="已完成", message=str(result.get("message", "操作已完成")), result=result, cancellable=0)
    except InterruptedError as error:
        _update_operation(operation_id, status="cancelled", step="已取消", message=str(error), error=None, cancellable=0)
    except Exception as error:
        _update_operation(operation_id, status="failed", step="失败", message="操作未完成", error=str(error)[:400], cancellable=0)
    finally:
        with _OPERATION_LOCK:
            _OPERATION_THREADS.pop(operation_id, None)


@app.get("/api/status")
def manager_status():
    try:
        state = _internal("/status")
        profile, draft = _draft_profile(state)
        plugins = _plugin_rows(profile, str(state.get("dsh_version", "")))
        local_state = _read_state()
        config_history = local_state.get("config_history", [])
        if not isinstance(config_history, list):
            config_history = []
        config_history = [
            item for item in config_history
            if isinstance(item, dict)
            and _SAFE_ID.fullmatch(str(item.get("config_id", "")))
            and item.get("config_id") != state.get("config_id")
            and (item.get("config_id") == "builtin" or (ROOT / "configs" / str(item.get("config_id")) / "manifest.json").is_file())
        ][:20]
        for plugin in plugins:
            update = local_state.get("plugin_updates", {}).get(plugin["name"], {})
            if update and update.get("version") != plugin["version"]:
                plugin["update_version"] = update["version"]
                plugin["update_compatibility"] = update.get("compatibility", "unknown")
        state.update(
            {
                "draft_dirty": bool(draft.get("dirty")),
                "draft_plugins": plugins,
                "config_history": config_history,
                "last_check": local_state.get("updates", {}).get("last_check"),
                "plugins_last_check": local_state.get("plugins_last_check"),
                "github_checked": local_state.get("updates", {}).get("github_checked"),
                "github_error": local_state.get("updates", {}).get("github_error"),
            }
        )
        return jsonify(state)
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as error:
        return _error(str(error)[:400], 503)


@app.get("/api/releases")
def list_releases():
    try:
        state = _internal("/status")
        cache = _read_state().get("updates", {})
        prepared = _prepared_releases(state)
        prepared_versions = {release["version"] for release in prepared}
        releases = list(prepared)
        for candidate in cache.get("releases", []):
            if candidate.get("version") in prepared_versions or candidate.get("version") == state.get("dsh_version"):
                continue
            releases.append({**candidate, "current": False, "prepared": False})
        return jsonify({"current": state, "last_check": cache.get("last_check"), "releases": releases})
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        return _error(str(error)[:400], 503)


@app.post("/api/releases/check")
def check_release_updates():
    try:
        return jsonify(_check_release_updates())
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as error:
        return _error("检查官方发行信息失败：" + str(error)[:240], 503)


@app.post("/api/releases/prepare")
def prepare_release():
    try:
        body = _body(2048)
        version = str(body.get("version", ""))
        if not _SEMVER.fullmatch(version):
            return _error("请输入官方发行的精确版本", 400)
        candidates = _read_state().get("updates", {}).get("releases", [])
        candidate = next((item for item in candidates if item.get("version") == version), None)
        if candidate is None:
            return _error("请先检查更新并选择官方可用版本", 409)
        if candidate.get("compatibility") != "compatible":
            return _error("此版本与已启用插件的兼容性尚未确认", 409)
        operation_id = _start_operation("release_prepare", {"version": version})
        return jsonify({"operation_id": operation_id}), 202
    except (ValueError, TypeError) as error:
        return _error(str(error), 400)


@app.post("/api/releases/switch")
def switch_release():
    try:
        body = _body(2048)
        release_id = str(body.get("release_id", ""))
        if not _SAFE_ID.fullmatch(release_id):
            return _error("DSH 版本 ID 无效", 400)
        state = _internal("/status")
        payload = {
            "release_id": release_id,
            "previous": {
                "release_id": str(state.get("active_release_id", "builtin")),
                "config_id": str(state.get("config_id", "builtin")),
            },
        }
        operation_id = _start_operation("release_switch", payload)
        return jsonify({"operation_id": operation_id}), 202
    except (ValueError, TypeError, RuntimeError) as error:
        return _error(str(error), 503 if isinstance(error, RuntimeError) else 400)


@app.get("/api/plugins/catalog")
def plugin_catalog():
    query = request.args.get("q", "").strip().lower()
    cached = _read_state().get("catalog", {})
    plugins = cached.get("plugins", []) if isinstance(cached, dict) else []
    stale = False
    if not cached.get("checked_at") or time.time() - int(cached.get("checked_at_epoch", 0)) > 6 * 60 * 60:
        try:
            cached = _refresh_catalog_cache()
            plugins = cached["plugins"]
        except (OSError, ValueError, RuntimeError, urllib.error.URLError):
            stale = True
    if query:
        plugins = [item for item in plugins if query in (item["name"] + " " + item["display_name"] + " " + item["description"]).lower()]
    return jsonify(
        {
            "plugins": plugins[:100],
            "checked_at": cached.get("checked_at"),
            "stale": stale,
            "source": "hrhgit/deepseek-harness-plugin-manager catalog/v2",
        }
    )


@app.post("/api/plugins/check")
def check_plugin_updates():
    try:
        state = _internal("/status")
        profile, _ = _draft_profile(state)
        updates, checked_at = _check_plugin_updates_for_profile(profile, str(state.get("dsh_version", "")))
        return jsonify({"checked": len(updates), "last_check": checked_at})
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as error:
        return _error("检查插件更新失败：" + str(error)[:240], 503)


@app.post("/api/plugins/install")
def install_plugin():
    try:
        body = _body(4096)
        normalized, version, source = _parse_spec(str(body.get("spec", "")))
        if source == "npm":
            state = _internal("/status")
            _check_peer_package(_source_package(normalized, version, source), str(state.get("dsh_version", "")))
        operation_id = _start_operation("plugin_install", {"action": "install", "spec": normalized})
        return jsonify({"operation_id": operation_id, "version": version, "source": source}), 202
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as error:
        return _error(str(error)[:400], 400 if isinstance(error, ValueError) else 503)


@app.post("/api/plugins/update")
def update_plugin():
    try:
        body = _body(2048)
        name = str(body.get("name", ""))
        if not _SAFE_PACKAGE.fullmatch(name):
            return _error("插件包名无效", 400)
        state = _internal("/status")
        profile, _ = _draft_profile(state)
        current = next((item for item in _plugin_rows(profile, str(state.get("dsh_version", ""))) if item["name"] == name), None)
        if current is None:
            return _error("插件未安装到待应用配置", 404)
        if current.get("distribution") == "github":
            return _error("此插件固定到 GitHub commit；请使用新的 40 位 commit 重新添加", 409)
        metadata = _npm_package(name)
        version = str(metadata.get("version", ""))
        if not _SEMVER.fullmatch(version):
            return _error("npm 没有返回可固定的版本", 503)
        _check_peer_package(metadata, str(state.get("dsh_version", "")))
        operation_id = _start_operation("plugin_install", {"action": "install", "spec": f"{name}@{version}"})
        return jsonify({"operation_id": operation_id, "version": version}), 202
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        return _error(str(error)[:400], 409 if isinstance(error, ValueError) else 503)


@app.post("/api/plugins/remove")
def remove_plugin():
    try:
        body = _body(2048)
        name = str(body.get("name", ""))
        if not _SAFE_PACKAGE.fullmatch(name):
            return _error("插件包名无效", 400)
        operation_id = _start_operation("plugin_install", {"action": "remove", "name": name})
        return jsonify({"operation_id": operation_id}), 202
    except (ValueError, TypeError) as error:
        return _error(str(error), 400)


@app.post("/api/plugins/toggle")
@_serialize_admin_mutation
def toggle_plugin():
    try:
        body = _body(2048)
        name = str(body.get("name", ""))
        enabled = body.get("enabled")
        if not _SAFE_PACKAGE.fullmatch(name) or not isinstance(enabled, bool):
            return _error("插件开关请求无效", 400)
        state = _internal("/status")
        profile, _ = _draft_profile(state)
        manifest = _plugin_manifest(profile)
        dependencies = manifest.get("dependencies", {})
        package_path = _package_path(profile, name)
        if name not in dependencies or not package_path.is_file():
            return _error("插件尚未安装到待应用配置", 404)
        package = json.loads(package_path.read_text(encoding="utf-8"))
        dsh_package = package.get("dsh", {})
        if not isinstance(dsh_package, dict) or not isinstance(dsh_package.get("bundle"), dict):
            return _error("此包没有 DSH bundle，无法切换插件状态", 409)
        old = _plugin_manifest(profile)
        dsh = manifest.setdefault("dsh", {})
        profile_info = dsh.setdefault("profile", {})
        bundles = list(profile_info.get("bundles", []))
        if enabled and name not in bundles:
            bundles.append(name)
        if not enabled:
            bundles = [item for item in bundles if item != name]
        profile_info["bundles"] = bundles
        metadata_before = _read_json(ROOT / "draft-state.json")
        try:
            _write_draft_profile(profile, manifest)
            _verify_profile(_active_binary(state), ROOT / "draft")
        except Exception:
            _atomic_json(profile / "package.json", old)
            _atomic_json(ROOT / "draft-state.json", metadata_before)
            raise
        return jsonify({"ok": True, "enabled": enabled, "draft_dirty": True})
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        return _error(str(error)[:400], 400)


@app.route("/api/plugins/config", methods=["GET", "POST"])
@_serialize_admin_mutation
def plugin_config():
    try:
        state = _internal("/status")
        profile, _ = _draft_profile(state)
        path = profile / "cordis.patch.yml"
        if request.method == "GET":
            return jsonify({"config": path.read_text(encoding="utf-8") if path.exists() else ""})
        body = _body(256 * 1024)
        config = body.get("config")
        if not isinstance(config, str) or len(config.encode("utf-8")) > 256 * 1024:
            return _error("插件配置不能超过 256 KB", 400)
        previous = path.read_text(encoding="utf-8") if path.exists() else None
        metadata_before = _read_json(ROOT / "draft-state.json")
        try:
            temporary = path.with_suffix(".yml.tmp")
            temporary.write_text(config, encoding="utf-8")
            os.chmod(temporary, 0o640)
            os.replace(temporary, path)
            _verify_profile(_active_binary(state), ROOT / "draft")
        except Exception:
            if previous is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(previous, encoding="utf-8")
            _atomic_json(ROOT / "draft-state.json", metadata_before)
            raise
        metadata = _read_json(ROOT / "draft-state.json")
        _atomic_json(ROOT / "draft-state.json", {**metadata, "dirty": True, "updated_at": int(time.time())})
        return jsonify({"ok": True, "draft_dirty": True})
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        return _error(str(error)[:400], 400)


@app.post("/api/plugins/apply")
def apply_plugins():
    operation_id = _start_operation("plugin_apply", {})
    return jsonify({"operation_id": operation_id}), 202


@app.post("/api/plugins/discard")
def discard_plugins():
    try:
        state = _internal("/status")
        shutil.rmtree(ROOT / "draft", ignore_errors=True)
        (ROOT / "draft-state.json").unlink(missing_ok=True)
        profile, metadata = _draft_profile(state)
        return jsonify(
            {
                "ok": True,
                "draft_dirty": bool(metadata.get("dirty")),
                "plugin_count": len(_plugin_rows(profile, str(state.get("dsh_version", "")))),
            }
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        return _error(str(error)[:400], 503)


@app.post("/api/plugins/restore")
@_serialize_admin_mutation
def restore_plugins():
    try:
        body = _body(2048)
        config_id = str(body.get("config_id", ""))
        if config_id != "builtin":
            if not _SAFE_ID.fullmatch(config_id):
                return _error("配置版本 ID 无效", 400)
            profile = _profile_for_config(config_id)
        else:
            profile = None
        previous = _internal("/status")
        if previous.get("config_id") == config_id:
            return jsonify({"ok": True, "config_id": config_id, "config_revision": previous.get("config_revision"), "plugin_count": 0 if profile is None else len(_plugin_rows(profile, str(previous.get("dsh_version", ""))))})
        state = _internal("/apply-config", {"config_id": config_id})
        history = _read_state().get("config_history", [])
        previous_id = str(previous.get("config_id", "builtin"))
        previous_manifest = _read_json(ROOT / "configs" / previous_id / "manifest.json") if previous_id != "builtin" else {}
        previous_entry = {
            "config_id": previous_id,
            "config_revision": previous.get("config_revision", 0),
            "created_at": previous_manifest.get("created_at", datetime.now(timezone.utc).isoformat(timespec="seconds")),
            "plugin_count": len(previous_manifest.get("plugins", [])),
        }
        history = [previous_entry] + [item for item in history if item.get("config_id") != previous_id]
        _write_state({"config_history": history[:20]})
        shutil.rmtree(ROOT / "draft", ignore_errors=True)
        (ROOT / "draft-state.json").unlink(missing_ok=True)
        return jsonify(
            {
                "ok": True,
                "config_id": config_id,
                "config_revision": state.get("config_revision"),
                "plugin_count": 0 if profile is None else len(_plugin_rows(profile, str(state.get("dsh_version", "")))),
            }
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        return _error(str(error)[:400], 409 if isinstance(error, ValueError) else 503)


@app.get("/api/operations/<operation_id>")
def get_operation(operation_id: str):
    if not _SAFE_ID.fullmatch(operation_id):
        return _error("操作 ID 无效", 400)
    operation = _operation_record(operation_id)
    if operation is None:
        return _error("操作不存在", 404)
    return jsonify(operation)


@app.post("/api/operations/<operation_id>/cancel")
def cancel_operation(operation_id: str):
    operation = _operation_record(operation_id)
    if operation is None:
        return _error("操作不存在", 404)
    if operation["status"] not in ("queued", "running") or not operation["cancellable"]:
        return _error("当前阶段不能取消", 409)
    _update_operation(operation_id, cancel_requested=1, message="正在安全取消操作")
    return jsonify({"ok": True})
