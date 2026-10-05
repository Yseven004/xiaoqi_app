from __future__ import annotations

import argparse
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


WORKER_ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_NAMES = (
    "xiaoqi-agent-api-harness.zip",
    "xiaoqi-agent-worker-harness.zip",
    "xiaoqi-agent-runtime-layer.zip",
)


def _check_build_host() -> None:
    machine = platform.machine()
    if machine not in ("x86_64", "AMD64"):
        raise RuntimeError("只支持构建阿里云 FC Linux x86_64 运行包")
    if platform.system() == "Linux" and sys.version_info[:2] == (3, 10):
        return
    if os.name == "nt" and shutil.which("uv"):
        return
    raise RuntimeError(
        "请使用 Linux x86_64 Python 3.10，或在 Windows x86_64 安装 uv 进行 Linux 交叉打包"
    )


def _zip_tree(source: Path, destination: Path, *, excluded: set[Path] | None = None) -> None:
    excluded = excluded or set()
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_file() and path not in excluded:
                relative_path = path.relative_to(source).as_posix()
                info = zipfile.ZipInfo.from_file(path, relative_path)
                info.create_system = 3
                mode = 0o755 if _is_linux_executable(relative_path) else 0o644
                info.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(
                    info,
                    path.read_bytes(),
                    compress_type=zipfile.ZIP_DEFLATED,
                    compresslevel=6,
                )


def _is_linux_executable(relative_path: str) -> bool:
    return relative_path == "bin/dsh" or (
        relative_path.startswith("python/deepseek_harness_runtime/runtime/")
        and Path(relative_path).name.startswith("deepseek-harness-sdk-runtime-linux-x64")
    )


def _write_dsh_launcher(layer_root: Path) -> None:
    launcher = layer_root / "bin" / "dsh"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(
        "#!/usr/bin/env python3\n"
        "from deepseek_harness_runtime import main\n"
        "raise SystemExit(main())\n",
        encoding="utf-8",
        newline="\n",
    )
    launcher.chmod(0o755)


def _install_dependencies(python_root: Path, requirements: Path) -> None:
    if platform.system() == "Linux":
        command = [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "--no-compile",
            "--no-warn-script-location",
            "--target",
            str(python_root),
            "-r",
            str(requirements),
        ]
    else:
        command = [
            shutil.which("uv") or "uv",
            "pip",
            "install",
            "--system-certs",
            "--target",
            str(python_root),
            "--python-version",
            "3.10",
            "--python-platform",
            "x86_64-manylinux_2_28",
            "-r",
            str(requirements),
        ]
    subprocess.run(command, check=True)


def _verify_linux_x64_files(python_root: Path) -> None:
    for path in python_root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() in {".pyd", ".dll"}:
            raise RuntimeError(f"依赖层意外包含 Windows 原生文件：{path.name}")
        if path.suffix.lower() != ".so" or "darwin" in path.name.lower():
            continue
        with path.open("rb") as binary:
            header = binary.read(20)
        if header[:4] != b"\x7fELF" or int.from_bytes(header[18:20], "little") != 62:
            raise RuntimeError(f"依赖层包含非 Linux x86_64 原生文件：{path.name}")


def build(output_dir: Path, *, force: bool = False) -> tuple[Path, Path, Path]:
    _check_build_host()
    output_dir.mkdir(parents=True, exist_ok=True)
    api_zip, worker_zip, layer_zip = (output_dir / name for name in ARTIFACT_NAMES)
    existing = [path for path in (api_zip, worker_zip, layer_zip) if path.exists()]
    if existing and not force:
        raise FileExistsError(
            "构建产物已存在；请指定新的 --output-dir，或传入 --force 覆盖这三个明确命名的产物"
        )

    with tempfile.TemporaryDirectory(prefix="xiaoqi-harness-build-") as temp:
        temp_root = Path(temp)
        api_root = temp_root / "api"
        api_root.mkdir()
        shutil.copy2(WORKER_ROOT / "fc_proxy_function.py", api_root)
        shutil.copy2(WORKER_ROOT / "fc_capability_api_function.py", api_root)
        shutil.copy2(WORKER_ROOT / "requirements-api.txt", api_root)
        shutil.copytree(
            WORKER_ROOT / "capabilities",
            api_root / "capabilities",
            ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc"),
        )
        _install_dependencies(api_root, WORKER_ROOT / "requirements-api.txt")
        _verify_linux_x64_files(api_root)
        _zip_tree(api_root, api_zip)

        layer_root = temp_root / "layer"
        python_root = layer_root / "python"
        python_root.mkdir(parents=True)
        _install_dependencies(python_root, WORKER_ROOT / "requirements.txt")
        _verify_linux_x64_files(python_root)
        runtime_package = python_root / "deepseek_harness_runtime"
        if not runtime_package.joinpath("__init__.py").is_file():
            raise RuntimeError("依赖层中未找到 DeepSeek Harness Runtime Python 包")
        if not list(runtime_package.glob("runtime/*linux-x64")):
            raise RuntimeError("依赖层中未找到匹配的 Linux x64 Harness runtime")
        _write_dsh_launcher(layer_root)
        _zip_tree(layer_root, layer_zip)

        worker_root = temp_root / "worker"
        worker_root.mkdir()
        shutil.copy2(WORKER_ROOT / "fc_agent_worker_function.py", worker_root)
        shutil.copytree(
            WORKER_ROOT / "capabilities",
            worker_root / "capabilities",
            ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc"),
        )
        _zip_tree(worker_root, worker_zip)

    with zipfile.ZipFile(layer_zip) as archive:
        names = set(archive.namelist())
    required = {
        "bin/dsh",
        "python/deepseek_harness_runtime/__init__.py",
    }
    if not required.issubset(names):
        raise RuntimeError("依赖层 ZIP 缺少运行时启动文件")
    with zipfile.ZipFile(api_zip) as archive:
        api_names = set(archive.namelist())
    required_api = {
        "fc_proxy_function.py",
        "fc_capability_api_function.py",
        "capabilities/api.py",
        "requirements-api.txt",
    }
    if not required_api.issubset(api_names):
        raise RuntimeError("API ZIP 缺少入口、能力代码或依赖清单")
    if layer_zip.stat().st_size > 500 * 1024 * 1024:
        raise RuntimeError("依赖层 ZIP 超过阿里云函数计算文档列出的 500 MB 层上限")
    return api_zip, worker_zip, layer_zip


def main() -> None:
    parser = argparse.ArgumentParser(description="Build separate Xiaoqi API, worker, and FC runtime-layer ZIPs.")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "artifacts")
    parser.add_argument("--force", action="store_true", help="overwrite only the two named output ZIPs")
    args = parser.parse_args()
    api_zip, worker_zip, layer_zip = build(args.output_dir, force=args.force)
    for artifact in (api_zip, worker_zip, layer_zip):
        print(f"{artifact} ({artifact.stat().st_size / (1024 * 1024):.1f} MiB)")


if __name__ == "__main__":
    main()
