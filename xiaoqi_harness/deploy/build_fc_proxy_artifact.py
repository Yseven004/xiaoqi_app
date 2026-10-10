from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HARNESS_ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_NAME = "xiaoqi-chat-proxy.zip"


def _check_build_host() -> None:
    if platform.machine() not in ("x86_64", "AMD64"):
        raise RuntimeError("只支持构建阿里云 FC Linux x86_64 运行包")
    if platform.system() == "Linux" and sys.version_info[:2] == (3, 10):
        return
    if os.name == "nt" and shutil.which("uv"):
        return
    raise RuntimeError(
        "请使用 Linux x86_64 Python 3.10，或在 Windows x86_64 安装 uv 进行 Linux 交叉打包"
    )


def _install_dependencies(package_root: Path) -> None:
    requirements = HARNESS_ROOT / "requirements-api.txt"
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
            str(package_root),
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
            str(package_root),
            "--python-version",
            "3.10",
            "--python-platform",
            "x86_64-manylinux_2_28",
            "-r",
            str(requirements),
        ]
    subprocess.run(command, check=True)


def build(output_dir: Path, *, force: bool = False) -> Path:
    _check_build_host()
    output_dir.mkdir(parents=True, exist_ok=True)
    artifact = output_dir / ARTIFACT_NAME
    if artifact.exists() and not force:
        raise FileExistsError(
            f"{artifact} 已存在；请指定新的 --output-dir，或传入 --force 覆盖此产物"
        )

    with tempfile.TemporaryDirectory(prefix="xiaoqi-fc-proxy-") as temp:
        package_root = Path(temp)
        shutil.copy2(HARNESS_ROOT / "fc_proxy_function.py", package_root)
        shutil.copy2(HARNESS_ROOT / "requirements-api.txt", package_root)
        _install_dependencies(package_root)
        with zipfile.ZipFile(
            artifact, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            for path in sorted(package_root.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(package_root).as_posix())

    with zipfile.ZipFile(artifact) as archive:
        names = set(archive.namelist())
    if "fc_proxy_function.py" not in names or "flask/__init__.py" not in names:
        artifact.unlink(missing_ok=True)
        raise RuntimeError("代理 ZIP 缺少入口或 Flask 依赖")
    return artifact


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the existing Xiaoqi chat proxy FC ZIP."
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "artifacts",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite only xiaoqi-chat-proxy.zip",
    )
    args = parser.parse_args()
    artifact = build(args.output_dir, force=args.force)
    print(f"{artifact} ({artifact.stat().st_size / (1024 * 1024):.1f} MiB)")


if __name__ == "__main__":
    main()
