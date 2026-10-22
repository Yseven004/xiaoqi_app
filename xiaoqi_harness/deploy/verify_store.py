#!/usr/bin/env python3
"""Create or compare a privacy-safe manifest of the persisted Xiaoqi store."""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path


def manifest(root: Path) -> dict[str, object]:
    database = root / "xiaoqi.sqlite3"
    if not database.is_file():
        raise FileNotFoundError(f"SQLite database not found: {database}")

    # Deployment verification runs against a stopped, read-only volume snapshot.
    connection = sqlite3.connect(
        f"file:{database.as_posix()}?mode=ro&immutable=1", uri=True
    )
    try:
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError("SQLite integrity check failed")
        documents = [
            [str(row[0]), int(row[1])]
            for row in connection.execute(
                "SELECT key, revision FROM documents ORDER BY key"
            )
        ]
        document_hashes = {
            str(row[0]): hashlib.sha256(str(row[1]).encode("utf-8")).hexdigest()
            for row in connection.execute("SELECT key, document FROM documents ORDER BY key")
        }
        object_rows = [
            str(row[0])
            for row in connection.execute("SELECT key FROM objects ORDER BY key")
        ]
    finally:
        connection.close()

    objects_root = root / "objects"
    hashes: dict[str, str] = {}
    for path in sorted(objects_root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(objects_root).as_posix()
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        hashes[relative] = digest.hexdigest()

    return {
        "documents": documents,
        "document_hashes": document_hashes,
        "object_keys": object_rows,
        "object_file_hashes": hashes,
        "counts": {
            "documents": len(documents),
            "objects": len(object_rows),
            "object_files": len(hashes),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("/var/lib/xiaoqi"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()

    current = manifest(args.root)
    encoded = json.dumps(current, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)

    if args.compare:
        expected = json.loads(args.compare.read_text(encoding="utf-8"))
        if current != expected:
            print("STORE_MANIFEST_MISMATCH", file=sys.stderr)
            return 1
        print("STORE_MANIFEST_MATCH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
