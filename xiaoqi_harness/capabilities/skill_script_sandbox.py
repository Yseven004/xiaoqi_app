from __future__ import annotations

import ctypes
import errno
import json
import os
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
_LANDLOCK_CREATE_RULESET_VERSION = 1
_LANDLOCK_RULE_PATH_BENEATH = 1
_LANDLOCK_FS_EXECUTE = 1 << 0
_LANDLOCK_FS_WRITE_FILE = 1 << 1
_LANDLOCK_FS_READ_FILE = 1 << 2
_LANDLOCK_FS_READ_DIR = 1 << 3
_LANDLOCK_FS_REMOVE_DIR = 1 << 4
_LANDLOCK_FS_REMOVE_FILE = 1 << 5
_LANDLOCK_FS_MAKE_CHAR = 1 << 6
_LANDLOCK_FS_MAKE_DIR = 1 << 7
_LANDLOCK_FS_MAKE_REG = 1 << 8
_LANDLOCK_FS_MAKE_SOCK = 1 << 9
_LANDLOCK_FS_MAKE_FIFO = 1 << 10
_LANDLOCK_FS_MAKE_BLOCK = 1 << 11
_LANDLOCK_FS_MAKE_SYM = 1 << 12
_LANDLOCK_FS_REFER = 1 << 13
_LANDLOCK_FS_TRUNCATE = 1 << 14
_LANDLOCK_FS_IOCTL_DEV = 1 << 15
_LANDLOCK_SCOPE_SIGNAL = 1 << 1


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
        return sys.executable, ["-I", "-B"]
    if language == "javascript":
        return "/usr/local/bin/node", ["--disable-proto=throw"]
    if language == "typescript":
        return "/usr/local/bin/tsx", []
    raise SkillScriptSandboxError("不支持的脚本运行格式")


def _runtime_environment(home_dir: Path, tmp_dir: Path) -> dict[str, str]:
    return {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": str(home_dir),
        "TMPDIR": str(tmp_dir),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "LANG": "C.UTF-8",
        "XDG_CACHE_HOME": str(home_dir),
    }


def _landlock_syscall(number: int, *arguments: object) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    syscall = libc.syscall
    syscall.restype = ctypes.c_long
    result = syscall(ctypes.c_long(number), *arguments)
    if result < 0:
        error_code = ctypes.get_errno()
        raise OSError(error_code, os.strerror(error_code))
    return int(result)


class _LandlockRulesetAttr(ctypes.Structure):
    _fields_ = [
        ("handled_access_fs", ctypes.c_uint64),
        ("handled_access_net", ctypes.c_uint64),
        ("scoped", ctypes.c_uint64),
    ]


class _LandlockPathBeneathAttr(ctypes.Structure):
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
    ]


def _install_landlock(workspace: Path) -> None:
    version = _landlock_syscall(444, ctypes.c_void_p(), ctypes.c_size_t(0), ctypes.c_uint32(_LANDLOCK_CREATE_RULESET_VERSION))
    if version < 1:
        raise SkillScriptSandboxError("当前 Linux 内核不支持技能脚本文件隔离")

    handled_fs = (
        _LANDLOCK_FS_EXECUTE
        | _LANDLOCK_FS_WRITE_FILE
        | _LANDLOCK_FS_READ_FILE
        | _LANDLOCK_FS_READ_DIR
        | _LANDLOCK_FS_REMOVE_DIR
        | _LANDLOCK_FS_REMOVE_FILE
        | _LANDLOCK_FS_MAKE_CHAR
        | _LANDLOCK_FS_MAKE_DIR
        | _LANDLOCK_FS_MAKE_REG
        | _LANDLOCK_FS_MAKE_SOCK
        | _LANDLOCK_FS_MAKE_FIFO
        | _LANDLOCK_FS_MAKE_BLOCK
        | _LANDLOCK_FS_MAKE_SYM
        | _LANDLOCK_FS_REFER
        | _LANDLOCK_FS_TRUNCATE
        | _LANDLOCK_FS_IOCTL_DEV
    )
    if version < 2:
        handled_fs &= ~_LANDLOCK_FS_REFER
    if version < 3:
        handled_fs &= ~_LANDLOCK_FS_TRUNCATE
    if version < 5:
        handled_fs &= ~_LANDLOCK_FS_IOCTL_DEV
    # Network stays available to skills; only signal delivery is scoped when
    # the kernel supports it so a script cannot stop the app service.
    scoped = _LANDLOCK_SCOPE_SIGNAL if version >= 6 else 0
    attr = _LandlockRulesetAttr(handled_fs, 0, scoped)
    attr_size = 8 + (8 if version >= 4 else 0) + (8 if version >= 6 else 0)
    ruleset_fd = _landlock_syscall(
        444,
        ctypes.byref(attr),
        ctypes.c_size_t(attr_size),
        ctypes.c_uint32(0),
    )
    path_fds: list[int] = []
    try:
        readonly_access = _LANDLOCK_FS_EXECUTE | _LANDLOCK_FS_READ_FILE | _LANDLOCK_FS_READ_DIR
        # /proc is intentionally excluded: the service and the sandbox share
        # the container UID, so procfs could otherwise expose the service env.
        allowed_roots = {Path("/usr"), Path("/etc"), Path("/dev"), Path(sys.prefix)}
        seen: set[Path] = set()
        for root in allowed_roots:
            if not root.exists():
                continue
            resolved = root.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            path_fd = os.open(resolved, os.O_PATH | os.O_CLOEXEC)
            path_fds.append(path_fd)
            rule = _LandlockPathBeneathAttr(readonly_access, path_fd)
            _landlock_syscall(
                445,
                ctypes.c_int(ruleset_fd),
                ctypes.c_uint32(_LANDLOCK_RULE_PATH_BENEATH),
                ctypes.byref(rule),
                ctypes.c_uint32(0),
            )

        workspace_fd = os.open(workspace, os.O_PATH | os.O_CLOEXEC)
        path_fds.append(workspace_fd)
        workspace_rule = _LandlockPathBeneathAttr(handled_fs, workspace_fd)
        _landlock_syscall(
            445,
            ctypes.c_int(ruleset_fd),
            ctypes.c_uint32(_LANDLOCK_RULE_PATH_BENEATH),
            ctypes.byref(workspace_rule),
            ctypes.c_uint32(0),
        )
        _landlock_syscall(446, ctypes.c_int(ruleset_fd), ctypes.c_uint32(0))
    finally:
        for path_fd in path_fds:
            os.close(path_fd)
        os.close(ruleset_fd)


def _install_syscall_filter() -> None:
    try:
        library = ctypes.CDLL("libseccomp.so.2", use_errno=True)
    except OSError as error:
        raise SkillScriptSandboxError("技能脚本系统调用限制库未安装") from error
    library.seccomp_init.argtypes = [ctypes.c_uint32]
    library.seccomp_init.restype = ctypes.c_void_p
    library.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
    library.seccomp_syscall_resolve_name.restype = ctypes.c_int
    library.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    library.seccomp_rule_add.restype = ctypes.c_int
    library.seccomp_load.argtypes = [ctypes.c_void_p]
    library.seccomp_load.restype = ctypes.c_int
    library.seccomp_release.argtypes = [ctypes.c_void_p]
    library.seccomp_release.restype = None

    default_allow = 0x7FFF0000
    deny_with_permission_error = 0x00050000 | errno.EPERM
    context = library.seccomp_init(default_allow)
    if not context:
        raise SkillScriptSandboxError("无法初始化技能脚本系统调用限制")
    try:
        blocked = (
            "ptrace",
            "kcmp",
            "process_vm_readv",
            "process_vm_writev",
            "pidfd_open",
            "pidfd_getfd",
            "mount",
            "umount2",
            "pivot_root",
            "unshare",
            "setns",
            "bpf",
            "perf_event_open",
            "keyctl",
            "add_key",
            "request_key",
        )
        for name in blocked:
            syscall_number = library.seccomp_syscall_resolve_name(name.encode("ascii"))
            if syscall_number < 0:
                continue
            result = library.seccomp_rule_add(
                context,
                deny_with_permission_error,
                syscall_number,
                0,
            )
            if result != 0:
                raise SkillScriptSandboxError(f"无法限制系统调用：{name}")
        if library.seccomp_load(context) != 0:
            raise SkillScriptSandboxError("无法启用技能脚本系统调用限制")
    finally:
        library.seccomp_release(context)


def _sandbox_launch(spec_path: Path) -> None:
    import resource

    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    workspace = Path(spec["workspace"]).resolve()
    script_relative = _safe_relative_path(str(spec["script_path"]))
    language = str(spec["language"])
    script_path = workspace / "skill" / script_relative
    arguments = spec["arguments"]
    if not isinstance(arguments, list) or any(not isinstance(value, str) for value in arguments):
        raise SkillScriptSandboxError("技能脚本参数无效")

    resource.setrlimit(resource.RLIMIT_CPU, (_TIMEOUT_SECONDS, _TIMEOUT_SECONDS))
    resource.setrlimit(resource.RLIMIT_FSIZE, (_MAX_OUTPUT_FILE_BYTES, _MAX_OUTPUT_FILE_BYTES))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
    resource.setrlimit(resource.RLIMIT_NPROC, (96, 96))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    _install_landlock(workspace)
    _install_syscall_filter()
    os.umask(0o022)
    os.chdir(workspace)

    binary, runtime_args = _runtime_binary(language)
    environment = _runtime_environment(workspace / "home", workspace / "tmp")
    os.execve(binary, [binary, *runtime_args, str(script_path), *arguments], environment)


def _prepare_workspace_permissions(
    workspace: Path,
    skill_dir: Path,
    materials_dir: Path,
    output_dir: Path,
    home_dir: Path,
    tmp_dir: Path,
) -> None:
    # Landlock gives each child access only to its own task tree; these POSIX
    # modes keep bundled skill and material files read-only to the script.
    os.chmod(workspace, 0o711)
    for root in (skill_dir, materials_dir):
        for path in root.rglob("*"):
            if path.is_symlink():
                raise SkillScriptSandboxError("技能脚本资源不能包含符号链接")
            os.chmod(path, 0o755 if path.is_dir() else 0o444)
        os.chmod(root, 0o755)
    for path in (output_dir, home_dir, tmp_dir):
        os.chmod(path, 0o777)


def run_skill_script(
    *,
    language: str,
    script_path: str,
    script_files: Mapping[str, bytes],
    materials: Mapping[str, str],
    arguments: Sequence[str],
    should_cancel: Callable[[], bool] | None = None,
) -> tuple[int, str, list[tuple[str, bytes]]]:
    """Run one task-approved skill script with Landlock and seccomp restrictions."""
    if os.environ.get("XIAOQI_SKILL_SCRIPT_SANDBOX_ENABLED") != "1":
        raise SkillScriptSandboxError("技能脚本沙箱尚未在此服务实例启用")
    if not sys.platform.startswith("linux"):
        raise SkillScriptSandboxError("技能脚本沙箱仅支持 Linux 服务端")
    script_relative = _safe_relative_path(script_path)
    script_data = script_files.get(script_relative.as_posix())
    if not isinstance(script_data, bytes):
        raise SkillScriptSandboxError("脚本不在本次已授权的技能版本中")

    with tempfile.TemporaryDirectory(prefix="xiaoqi-skill-", dir="/tmp") as temporary:
        workspace = Path(temporary)
        skill_dir = workspace / "skill"
        materials_dir = workspace / "materials"
        output_dir = workspace / "output"
        home_dir = workspace / "home"
        tmp_dir = workspace / "tmp"
        skill_dir.mkdir(mode=0o700)
        materials_dir.mkdir(mode=0o700)
        output_dir.mkdir(mode=0o700)
        home_dir.mkdir(mode=0o700)
        tmp_dir.mkdir(mode=0o700)
        _write_files(skill_dir, script_files, _MAX_PACKAGE_BYTES)
        material_files = {
            f"{index:03d}-{Path(name).name or 'material.txt'}": value.encode("utf-8")
            for index, (name, value) in enumerate(materials.items(), start=1)
        }
        _write_files(materials_dir, material_files, _MAX_MATERIAL_BYTES)
        _prepare_workspace_permissions(
            workspace,
            skill_dir,
            materials_dir,
            output_dir,
            home_dir,
            tmp_dir,
        )

        launch_spec = workspace / "launch.json"
        launch_spec.write_text(
            json.dumps(
                {
                    "workspace": str(workspace),
                    "script_path": script_relative.as_posix(),
                    "language": language,
                    "arguments": list(arguments),
                }
            ),
            encoding="utf-8",
        )
        os.chmod(launch_spec, 0o444)

        output_log = workspace / "stdout.log"
        with output_log.open("wb") as log:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-I",
                    "-B",
                    str(Path(__file__).resolve()),
                    "--sandbox-launch",
                    str(launch_spec),
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                close_fds=True,
                cwd=workspace,
                env=_runtime_environment(home_dir, tmp_dir),
                start_new_session=True,
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
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

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


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "--sandbox-launch":
    try:
        _sandbox_launch(Path(sys.argv[2]))
    except Exception as error:
        print(f"技能脚本沙箱启动失败：{error}", file=sys.stderr)
        raise SystemExit(125) from None
