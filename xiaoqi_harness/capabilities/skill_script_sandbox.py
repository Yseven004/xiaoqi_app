from __future__ import annotations

import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence


_MAX_PACKAGE_BYTES = 2 * 1024 * 1024
_MAX_MATERIAL_BYTES = 20 * 1024 * 1024
_MAX_OUTPUT_FILE_BYTES = 10 * 1024 * 1024
_MAX_OUTPUT_TOTAL_BYTES = 20 * 1024 * 1024
_MAX_OUTPUT_FILES = 10
_MAX_STDOUT_BYTES = 1024 * 1024
_TIMEOUT_SECONDS = 120


class SkillScriptSandboxError(RuntimeError):
    pass


def _safe_relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        not value
        or "\\" in value
        or "\x00" in value
        or path.is_absolute()
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise SkillScriptSandboxError("技能脚本包含不安全的文件路径")
    return path


def _write_files(root: Path, files: Mapping[str, bytes], max_total: int) -> None:
    total = 0
    for name, data in files.items():
        relative = _safe_relative_path(name)
        if len(data) > max_total:
            raise SkillScriptSandboxError("技能包或任务资料超过大小限制")
        total += len(data)
        if total > max_total:
            raise SkillScriptSandboxError("技能包或任务资料超过大小限制")
        target = root.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        # Parents are created only from validated components inside a new private
        # temporary directory; O_EXCL also prevents file/directory collisions.
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)


def _runtime_binary(language: str) -> tuple[str, list[str]]:
    if language == "python":
        return "/usr/bin/python3", ["-I", "-B"]
    if language == "javascript":
        return "/usr/local/bin/node", ["--disable-proto=throw"]
    if language == "typescript":
        return "/usr/local/bin/node", ["--disable-proto=throw", "--experimental-strip-types"]
    raise SkillScriptSandboxError("不支持的脚本运行格式")


def _preexec_limits() -> None:
    resource.setrlimit(resource.RLIMIT_CPU, (_TIMEOUT_SECONDS, _TIMEOUT_SECONDS))
    resource.setrlimit(resource.RLIMIT_FSIZE, (_MAX_OUTPUT_FILE_BYTES, _MAX_OUTPUT_FILE_BYTES))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _bwrap_command(
    bwrap: str,
    language: str,
    script_path: str,
    arguments: Sequence[str],
    workspace: Path,
    skill_dir: Path,
    materials_dir: Path,
    output_dir: Path,
) -> list[str]:
    command = [
        bwrap,
        "--die-with-parent",
        "--new-session",
        "--unshare-user",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-net",
        "--unshare-uts",
    ]

    # Mount only operating-system runtime files and the three task-scoped
    # directories. The server's data volume, DSH runtime, and credentials are
    # deliberately absent from this namespace.
    for source in ("/usr", "/etc", "/lib", "/lib64", "/bin", "/sbin"):
        path = Path(source)
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_symlink():
            command.extend(("--symlink", os.readlink(path), source))
        else:
            command.extend(("--ro-bind", source, source))
    command.extend(("--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"))
    command.extend(("--dir", "/workspace"))
    command.extend(("--ro-bind", str(skill_dir), "/workspace/skill"))
    command.extend(("--ro-bind", str(materials_dir), "/workspace/materials"))
    command.extend(("--bind", str(output_dir), "/workspace/output"))
    command.extend(("--chdir", "/workspace", "--clearenv"))
    for key, value in (
        ("PATH", "/usr/local/bin:/usr/bin:/bin"),
        ("HOME", "/tmp"),
        ("TMPDIR", "/tmp"),
        ("PYTHONDONTWRITEBYTECODE", "1"),
        ("PYTHONNOUSERSITE", "1"),
        ("LANG", "C.UTF-8"),
    ):
        command.extend(("--setenv", key, value))

    binary, runtime_args = _runtime_binary(language)
    command.append(binary)
    command.extend(runtime_args)
    command.append(f"/workspace/skill/{_safe_relative_path(script_path).as_posix()}")
    command.extend(arguments)
    return command


def run_skill_script(
    *,
    language: str,
    script_path: str,
    script_files: Mapping[str, bytes],
    materials: Mapping[str, str],
    arguments: Sequence[str],
    should_cancel: Callable[[], bool] | None = None,
) -> tuple[int, str, list[tuple[str, bytes]]]:
    """Run one task-approved skill script with Bubblewrap; never fall back to host execution."""
    if os.environ.get("XIAOQI_SKILL_SCRIPT_SANDBOX_ENABLED") != "1":
        raise SkillScriptSandboxError("技能脚本沙箱尚未在此服务实例启用")
    if not sys.platform.startswith("linux"):
        raise SkillScriptSandboxError("技能脚本沙箱仅支持 Linux 服务端")
    bwrap = shutil.which("bwrap")
    if not bwrap:
        raise SkillScriptSandboxError("技能脚本沙箱不可用：Bubblewrap 未安装")
    script_relative = _safe_relative_path(script_path)
    script_data = script_files.get(script_relative.as_posix())
    if not isinstance(script_data, bytes):
        raise SkillScriptSandboxError("脚本不在本次已授权的技能版本中")

    with tempfile.TemporaryDirectory(prefix="xiaoqi-skill-", dir=os.environ.get("TMPDIR")) as temporary:
        workspace = Path(temporary)
        skill_dir = workspace / "skill"
        materials_dir = workspace / "materials"
        output_dir = workspace / "output"
        skill_dir.mkdir(mode=0o700)
        materials_dir.mkdir(mode=0o700)
        output_dir.mkdir(mode=0o700)
        _write_files(skill_dir, script_files, _MAX_PACKAGE_BYTES)
        material_files = {
            f"{index:03d}-{Path(name).name or 'material.txt'}": value.encode("utf-8")
            for index, (name, value) in enumerate(materials.items(), start=1)
        }
        _write_files(materials_dir, material_files, _MAX_MATERIAL_BYTES)

        output_log = workspace / "stdout.log"
        command = _bwrap_command(
            bwrap,
            language,
            script_relative.as_posix(),
            arguments,
            workspace,
            skill_dir,
            materials_dir,
            output_dir,
        )
        with output_log.open("wb") as log:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                close_fds=True,
                start_new_session=True,
                preexec_fn=_preexec_limits,
            )
            deadline = time.monotonic() + _TIMEOUT_SECONDS
            while True:
                try:
                    return_code = process.wait(timeout=min(0.5, max(0.05, deadline - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    if should_cancel is not None and should_cancel():
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        raise SkillScriptSandboxError("技能脚本已按用户请求停止") from None
                    if time.monotonic() >= deadline:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        raise SkillScriptSandboxError("技能脚本运行超过 120 秒，已终止") from None

        output = output_log.read_bytes()[:_MAX_STDOUT_BYTES].decode("utf-8", errors="replace")
        if output_log.stat().st_size > _MAX_STDOUT_BYTES:
            output += "\n[输出已截断]"
        artifacts = _collect_output_files(output_dir)
        return return_code, output, artifacts


def _collect_output_files(output_dir: Path) -> list[tuple[str, bytes]]:
    candidates: list[tuple[str, bytes]] = []
    total = 0
    for current, directories, names in os.walk(output_dir, followlinks=False):
        base = Path(current)
        directories[:] = [name for name in directories if not (base / name).is_symlink()]
        for name in names:
            path = base / name
            if path.is_symlink() or not path.is_file():
                continue
            data = path.read_bytes()
            if len(data) > _MAX_OUTPUT_FILE_BYTES:
                raise SkillScriptSandboxError(f"产物 {name} 超过 10 MB")
            total += len(data)
            if total > _MAX_OUTPUT_TOTAL_BYTES:
                raise SkillScriptSandboxError("本次技能试用产物总大小超过 20 MB")
            safe_name = "_".join(path.relative_to(output_dir).parts)
            candidates.append((safe_name[:120], data))
            if len(candidates) > _MAX_OUTPUT_FILES:
                raise SkillScriptSandboxError("每次技能试用最多回传 10 个文件")
    return candidates
