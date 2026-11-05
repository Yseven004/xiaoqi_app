#!/usr/bin/env python3
"""Fingerprint the exact inputs and pinned local base images of each service image."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


SPECS = {
    "app": (
        "genkit_server/Dockerfile",
        "genkit_server/pubspec.yaml",
        "genkit_server/pubspec.lock",
        "genkit_server/lib",
        "genkit_server/bin",
        "genkit_server/context_compression",
    ),
    "runner": (
        "genkit_server/sandbox_runner/Dockerfile",
        "genkit_server/sandbox_runner/requirements.txt",
        "genkit_server/sandbox_runner/server.py",
        "genkit_server/sandbox_runner/stdio_channel.py",
        "genkit_server/sandbox_runner/mcp_journal.py",
        "genkit_server/sandbox_runner/mcp_recovery.py",
        "genkit_server/sandbox_runner/mcp_sessions.py",
        "genkit_server/sandbox_runner/execution_sessions.py",
    ),
    "sandbox": (
        "genkit_server/sandbox_image/Dockerfile",
    ),
    "proxy": (
        "genkit_server/sandbox_proxy/Dockerfile",
        "genkit_server/sandbox_proxy/entrypoint.py",
    ),
}


def files_for(root: Path, entries: tuple[str, ...]) -> list[Path]:
    result: list[Path] = []
    for entry in entries:
        path = root / entry
        if not path.exists():
            raise ValueError(f"Missing component input: {entry}")
        if path.is_file():
            result.append(path)
        else:
            result.extend(item for item in path.rglob("*") if item.is_file() and not item.is_symlink())
    return sorted(set(result), key=lambda path: path.relative_to(root).as_posix())


def base_references(dockerfile: Path) -> list[str]:
    aliases: set[str] = set()
    references: set[str] = set()
    for line in dockerfile.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s*FROM\s+(?:(?:--platform=\S+)\s+)?(\S+)(?:\s+AS\s+(\S+))?", line, re.I)
        if not match:
            continue
        image, alias = match.groups()
        if image.lower() != "scratch" and image.lower() not in aliases:
            references.add(image)
        if alias:
            aliases.add(alias.lower())
    return sorted(references)


def image_id(reference: str) -> str:
    result = json.loads(
        subprocess.check_output(["docker", "image", "inspect", reference], text=True)
    )[0]
    return str(result["Id"])


def fingerprints(root: Path) -> dict[str, dict[str, object]]:
    output = {}
    for name, entries in SPECS.items():
        files = files_for(root, entries)
        dockerfile = root / entries[0]
        bases = {reference: image_id(reference) for reference in base_references(dockerfile)}
        content = hashlib.sha256()
        for path in files:
            content.update(path.relative_to(root).as_posix().encode("utf-8"))
            content.update(b"\0")
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    content.update(block)
            content.update(b"\0")
        content.update(json.dumps(bases, sort_keys=True, separators=(",", ":")).encode())
        output[name] = {
            "fingerprint": content.hexdigest(),
            "base_images": bases,
            "inputs": [path.relative_to(root).as_posix() for path in files],
        }
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--list-base-images", action="store_true")
    args = parser.parse_args()
    if args.list_base_images:
        references = sorted({
            reference
            for name, entries in SPECS.items()
            for reference in base_references(args.root / entries[0])
        })
        print("\n".join(references))
        return
    if args.output is None:
        parser.error("--output is required unless --list-base-images is used")
    result = {"schema": 1, "components": fingerprints(args.root)}
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("COMPONENT_FINGERPRINTS_OK " + ",".join(result["components"]))


if __name__ == "__main__":
    main()
