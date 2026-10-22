#!/usr/bin/env python3
"""Build and verify the secret-free, single-platform deployment artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tarfile
from pathlib import Path, PurePosixPath

IMAGES = ("xiaoqi-genkit-server", "xiaoqi-sandbox-runner", "xiaoqi-code-sandbox", "xiaoqi-sandbox-proxy")
MAX_BUNDLE_BYTES = 8 * 1024**3
MAX_SOURCE_BYTES = 32 * 1024**2


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_extract(archive: Path, output: Path, *, bundle: bool = False) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        total = 0
        names = set()
        for member in members:
            name = member.name.rstrip("/")
            parts = PurePosixPath(name).parts
            if not parts or ".." in parts or "\\" in name or name.startswith("/") or ":" in name:
                raise ValueError("Unsafe archive path")
            if name in names or not (member.isfile() or member.isdir()):
                raise ValueError("Duplicate path, link or special file in archive")
            names.add(name)
            if bundle:
                if name not in {"manifest.json", "source.tgz", "images.tar.gz"} or not member.isfile():
                    raise ValueError("Unexpected release bundle member")
            elif parts[0] not in {"genkit_server", "deploy"} or any(
                p.endswith((".env", ".pem", ".key", ".sqlite3")) or p in {".dart_tool", ".genkit", "node_modules", "__pycache__"}
                for p in parts
            ):
                raise ValueError("Private or unexpected source path")
            total += member.size
        if total > (MAX_BUNDLE_BYTES if bundle else MAX_SOURCE_BYTES):
            raise ValueError("Archive exceeds size limit")
        if bundle and names != {"manifest.json", "source.tgz", "images.tar.gz"}:
            raise ValueError("Incomplete release bundle")
        output.mkdir(parents=True, exist_ok=True)
        # All paths, file types and size bounds were checked before any write.
        tar.extractall(output, members=members, filter="data")


def release_ids(source: Path) -> tuple[str, str]:
    text = (source / "genkit_server/lib/src/release.dart").read_text(encoding="utf-8")
    return tuple(re.search(r"const " + key + r" = '([^']+)'", text)[1] for key in ("releaseId", "apiContractVersion"))


def unpack(archive: Path, output: Path, commit: str, product: str, contract: str) -> dict:
    safe_extract(archive, output, bundle=True)
    manifest = json.loads((output / "manifest.json").read_text())
    if manifest.get("schema") != 1 or not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Unsupported manifest or invalid source commit")
    if (manifest.get("source_commit"), manifest.get("release_id"), manifest.get("api_contract_version")) != (commit, product, contract):
        raise ValueError("Release/contract/source mismatch")
    for name in ("source.tgz", "images.tar.gz"):
        if sha(output / name) != manifest.get("sha256", {}).get(name):
            raise ValueError("Artifact checksum mismatch: " + name)
    images = manifest.get("images", [])
    if len(images) != len(IMAGES) or {i.get("name") for i in images} != set(IMAGES):
        raise ValueError("Incomplete image set")
    for item in images:
        if item.get("tag") != item["name"] + ":build-" + commit or not re.fullmatch(r"sha256:[a-f0-9]{64}", item.get("id", "")):
            raise ValueError("Invalid image identity")
        if (item.get("os"), item.get("architecture")) != ("linux", "amd64") or not isinstance(item.get("size"), int) or item["size"] <= 0:
            raise ValueError("Wrong image platform or size")
    safe_extract(output / "source.tgz", output / "source")
    if release_ids(output / "source") != (product, contract):
        raise ValueError("Source release identifiers do not match manifest")
    return manifest


def pack(root: Path, output: Path, commit: str) -> None:
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Expected full Git commit")
    output.mkdir(parents=True, exist_ok=True)
    product, contract = release_ids(root / "xiaoqi_harness")
    client = (root / "lib/config/release.dart").read_text()
    if f"const releaseId = '{product}'" not in client or f"const apiContractVersion = '{contract}'" not in client:
        raise ValueError("Client/server release mismatch")
    paths = subprocess.check_output(["git", "ls-files", "-z", "xiaoqi_harness/genkit_server", "xiaoqi_harness/deploy"], cwd=root).decode().split("\0")
    with tarfile.open(output / "source.tgz", "w:gz") as tar:
        for name in filter(None, paths):
            path = root / name
            if path.is_symlink() or name.endswith((".env", ".pem", ".key", ".sqlite3")):
                raise ValueError("Refusing private source")
            tar.add(path, arcname=name.removeprefix("xiaoqi_harness/"), recursive=False)
    images = []
    for name in IMAGES:
        tag = name + ":build-" + commit
        subprocess.run(["docker", "tag", name + ":local", tag], check=True)
        image = json.loads(subprocess.check_output(["docker", "inspect", tag]))[0]
        images.append(dict(name=name, tag=tag, id=image["Id"], architecture=image["Architecture"], os=image["Os"], size=image["Size"]))
    # Stream compressed bytes to disk; never hold the image archive in memory.
    with (output / "images.tar.gz").open("wb") as stream:
        save = subprocess.Popen(["docker", "save", *[i["tag"] for i in images]], stdout=subprocess.PIPE)
        compress = subprocess.Popen(["gzip", "-1"], stdin=save.stdout, stdout=stream)
        save.stdout.close()
        if compress.wait() or save.wait():
            raise RuntimeError("Image export failed")
    manifest = dict(schema=1, release_id=product, api_contract_version=contract, source_commit=commit, images=images,
                    sha256={n: sha(output / n) for n in ("source.tgz", "images.tar.gz")})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with tarfile.open(output / "release.tgz", "w:gz", compresslevel=1) as tar:
        for name in ("manifest.json", "source.tgz", "images.tar.gz"):
            tar.add(output / name, arcname=name)
    (output / "release.sha256").write_text(sha(output / "release.tgz") + "\n")
    print("ARTIFACT_OK source=" + commit)


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("pack")
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--commit", required=True)
    p = sub.add_parser("unpack")
    p.add_argument("--archive", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--product", required=True)
    p.add_argument("--contract", required=True)
    args = parser.parse_args()
    if args.action == "pack":
        pack(args.root, args.output, args.commit)
    else:
        unpack(args.archive, args.output, args.commit, args.product, args.contract)
        print("ARTIFACT_VERIFIED source=" + args.commit)


if __name__ == "__main__":
    main()
