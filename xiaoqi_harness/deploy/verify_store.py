#!/usr/bin/env python3
"""Create or compare a privacy-safe manifest of the persisted Xiaoqi store."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path


def manifest(root: Path) -> dict[str, object]:
    database = root / "xiaoqi.sqlite3"
    if not database.is_file():
        raise FileNotFoundError(f"SQLite database not found: {database}")

    # Read committed WAL data too: activation checks run while health is serving.
    connection = sqlite3.connect(
        f"file:{database.as_posix()}?mode=ro", uri=True
    )
    try:
        connection.execute("BEGIN")
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


def with_catalog_changes(expected: dict, changes: dict) -> dict:
    """Apply only the exact deployment-owned catalog delta to the baseline."""
    names = ("study-notes-studio", "book-to-skill")
    allowed = {
        "skill-market/" + hashlib.sha256(f"_official-curated/{name}".encode()).hexdigest()
        for name in names
    }
    rows = changes.get("documents", [])
    documents = dict(rows)
    hashes = changes.get("document_hashes", {})
    objects = changes.get("object_keys", [])
    files = changes.get("object_file_hashes", {})
    if changes.get("schema") != 1 or len(rows) != len(names) or set(documents) != allowed or set(hashes) != allowed:
        raise ValueError("Unexpected catalog document delta")
    if len(objects) != len(names) or set(objects) != set(files):
        raise ValueError("Unexpected catalog object delta")
    pattern = r"official-catalog/(study-notes-studio|book-to-skill)/[a-f0-9]{64}\.zip"
    if any(not re.fullmatch(pattern, key) for key in objects):
        raise ValueError("Catalog object outside the declared namespace")
    if any(type(revision) is not int or revision < 1 for revision in documents.values()):
        raise ValueError("Invalid catalog revision")
    if any(not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value) for value in [*hashes.values(), *files.values()]):
        raise ValueError("Invalid catalog content hash")
    baseline_documents = dict(expected["documents"])
    if any(revision < baseline_documents.get(key, 0) for key, revision in documents.items()):
        raise ValueError("Catalog revision regressed")
    for key, value in files.items():
        previous = expected["object_file_hashes"].get(key)
        if previous is not None and previous != value:
            raise ValueError("Immutable catalog object was overwritten")
    merged_documents = dict(expected["documents"])
    merged_documents.update(documents)
    merged_objects = sorted(set(expected["object_keys"]) | set(objects))
    merged_files = dict(expected["object_file_hashes"], **files)
    return {
        "documents": sorted([key, value] for key, value in merged_documents.items()),
        "document_hashes": dict(expected["document_hashes"], **hashes),
        "object_keys": merged_objects,
        "object_file_hashes": merged_files,
        "counts": {"documents": len(merged_documents), "objects": len(merged_objects), "object_files": len(merged_files)},
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("/var/lib/xiaoqi"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--compare", type=Path)
    parser.add_argument("--catalog-changes", type=Path)
    args = parser.parse_args()

    current = manifest(args.root)
    encoded = json.dumps(current, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)

    if args.compare:
        expected = json.loads(args.compare.read_text(encoding="utf-8"))
        if args.catalog_changes:
            expected = with_catalog_changes(expected, json.loads(args.catalog_changes.read_text(encoding="utf-8")))
        if current != expected:
            print("STORE_MANIFEST_MISMATCH", file=sys.stderr)
            return 1
        print("STORE_MANIFEST_MATCH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
