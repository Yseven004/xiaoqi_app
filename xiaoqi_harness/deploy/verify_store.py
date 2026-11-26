#!/usr/bin/env python3
"""Create or compare a privacy-safe manifest of the persisted Xiaoqi store."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
import time
import tarfile
import tempfile
from pathlib import Path


def _reading_books(connection: sqlite3.Connection) -> tuple[dict, dict, set, dict]:
    """Preserve committed units while a candidate resumes unfinished parsing."""
    required_tables = {
        "reading_book_sources",
        "reading_book_units",
        "reading_book_passages",
        "reading_book_fts",
    }
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'reading_book_%'"
        )
    }
    if not (required_tables & tables):
        return {}, {}, set(), {}
    if not required_tables <= tables:
        raise ValueError("Incomplete reading book database schema")

    def digest(value):
        return hashlib.sha256(
            json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    books: dict = {}
    originals: dict = {}
    revoked: set = set()
    bindings: dict = {}
    if "reading_book_bindings" in tables:
        for tenant, book, version, binding, generation, active in connection.execute(
            "SELECT tenant, book_key, version, binding, generation, active FROM reading_book_bindings"
        ):
            if not all((tenant, book, version, binding, generation)) or active not in (0, 1):
                raise ValueError("Invalid reading book authorization binding")
            bindings[digest([tenant, book, version, binding])] = digest([generation, active])
    for source, tenant, book, version, kind, sha256, key, generation, status, catalog in connection.execute(
        """
        SELECT id, tenant, book_key, version, format, sha256, original_key,
               generation, status, catalog
        FROM reading_book_sources
        """
    ):
        if key != f"reading_book_original/{source}/{generation}":
            raise ValueError("Invalid reading book object binding")
        if status == "revoked":
            revoked.add(key)
            continue
        books[source] = {
            "binding": digest([tenant, book, version, kind, sha256, key, generation]),
            "catalog": digest(catalog) if catalog is not None else None,
            "units": {},
        }
        if status != "uploading":
            originals[key] = sha256

    units: dict = {}
    for source, unit, state, size in connection.execute(
        "SELECT source, unit, state, bytes FROM reading_book_units"
    ):
        if (
            source not in books or unit < 1 or size < 0 or
            state not in {"ready", "no_text", "failed"}
        ):
            raise ValueError("Invalid reading book unit")
        if (state == "ready") != (size > 0):
            raise ValueError("Inconsistent reading book unit size")
        units[source, unit] = (state, size, None)

    columns = {
        row[1] for row in connection.execute("PRAGMA table_info(reading_book_passages)")
    }
    locator = "locator" if "locator" in columns else "NULL"
    for source, unit, part, quote, searchable, anchor in connection.execute(
        f"""
        SELECT source, unit, part, quote, searchable, {locator}
        FROM reading_book_passages ORDER BY source, unit, part
        """
    ):
        row = units.get((source, unit))
        if row is None or row[0] != "ready" or not quote:
            raise ValueError("Reading book passage lacks a committed unit")
        state, size, hasher = row
        if hasher is None:
            hasher = hashlib.sha256()
            units[source, unit] = state, size, hasher
        hasher.update(digest([part, quote, searchable, anchor]).encode("ascii"))

    for (source, unit), (state, size, hasher) in units.items():
        if state == "ready" and hasher is None:
            raise ValueError("Readable book unit has no passages")
        if state != "failed":
            books[source]["units"][str(unit)] = {
                "state": state,
                "bytes": size,
                "hash": hasher.hexdigest() if hasher is not None else None,
            }

    missing_index = connection.execute(
        """
        SELECT 1 FROM reading_book_passages p
          LEFT JOIN reading_book_fts_docsize d ON p.id=d.id
          WHERE d.id IS NULL
        UNION ALL
        SELECT 1 FROM reading_book_fts_docsize d
          LEFT JOIN reading_book_passages p ON d.id=p.id
          WHERE p.id IS NULL
        LIMIT 1
        """
    ).fetchone()
    if missing_index:
        raise ValueError("Reading book index and passages are inconsistent")

    for passage, searchable in connection.execute(
        "SELECT id, searchable FROM reading_book_passages WHERE length(searchable)>=3 LIMIT 30"
    ):
        term = re.search(r"[a-zA-Z0-9\u3400-\u9fff]{3}", searchable)
        if term is None:
            continue
        if connection.execute(
            "SELECT rowid FROM reading_book_fts WHERE reading_book_fts MATCH ? AND rowid=?",
            (f'"{term[0]}"', passage),
        ).fetchone() is None:
            raise ValueError("Reading book index could not retrieve a known passage")
        break
    return books, originals, revoked, bindings


def manifest(root: Path, *, verify_reading_books: bool = True) -> dict[str, object]:
    database = root / "xiaoqi.sqlite3"
    if not database.is_file():
        raise FileNotFoundError(f"SQLite database not found: {database}")

    # Read committed WAL data too: activation checks run while health is serving.
    connection = sqlite3.connect(
        f"file:{database.as_posix()}?mode=ro", uri=True
    )
    try:
        connection.execute("PRAGMA query_only=ON")
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
        document_expirations: dict[str, int] = {}
        for row in connection.execute(
            "SELECT key, document FROM documents WHERE key LIKE 'attachment/%'"
        ):
            try:
                record = json.loads(str(row[1]))
            except (TypeError, json.JSONDecodeError):
                continue
            expires_at = record.get("expires_at") if isinstance(record, dict) else None
            if type(expires_at) in (int, float):
                document_expirations[str(row[0])] = int(expires_at)
        object_rows = [
            str(row[0])
            for row in connection.execute("SELECT key FROM objects ORDER BY key")
        ]
        reading_books, reading_originals, revoked_originals, reading_bindings = (
            _reading_books(connection) if verify_reading_books else ({}, {}, set(), {})
        )
    finally:
        connection.close()

    objects_root = root / "objects"
    hashes: dict[str, str] = {}
    for path in sorted(objects_root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(objects_root).as_posix()
        if relative in revoked_originals:
            continue
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        hashes[relative] = digest.hexdigest()
    object_rows = [key for key in object_rows if key not in revoked_originals]
    for key, sha256 in reading_originals.items():
        if key not in object_rows or hashes.get(key) != sha256:
            raise ValueError("Reading book original is missing or differs from its hash")

    return {
        "documents": documents,
        "document_hashes": document_hashes,
        "document_expirations": document_expirations,
        "object_keys": object_rows,
        "object_file_hashes": hashes,
        **({"reading_books": reading_books} if reading_books else {}),
        **({"reading_book_bindings": reading_bindings} if reading_bindings else {}),
        "counts": {
            "documents": len(documents),
            "objects": len(object_rows),
            "object_files": len(hashes),
        },
    }


def matches_manifest(current: dict, expected: dict) -> bool:
    actual_books = current.get("reading_books", {})
    previous_books = expected.get("reading_books", {})
    if set(actual_books) != set(previous_books):
        return False
    for source, previous in previous_books.items():
        actual = actual_books[source]
        if actual["binding"] != previous["binding"]:
            return False
        if previous["catalog"] is not None and actual["catalog"] != previous["catalog"]:
            return False
        if any(actual["units"].get(unit) != value for unit, value in previous["units"].items()):
            return False
    return {k: v for k, v in current.items() if k != "reading_books"} == {
        k: v for k, v in expected.items() if k != "reading_books"
    }


def exclude_expired_attachments(value: dict, now_ms: int) -> dict:
    """Ignore attachment records the service is designed to prune on startup."""
    expirations = value.get("document_expirations", {})
    expired = {
        key
        for key, expires_at in expirations.items()
        if key.startswith("attachment/")
        and type(expires_at) is int
        and expires_at <= now_ms
    }
    if not expired:
        return value

    result = dict(value)
    result["documents"] = [row for row in value["documents"] if row[0] not in expired]
    result["document_hashes"] = {
        key: digest
        for key, digest in value["document_hashes"].items()
        if key not in expired
    }
    result["document_expirations"] = {
        key: expires_at
        for key, expires_at in expirations.items()
        if key not in expired
    }
    result["counts"] = {
        **value["counts"],
        "documents": len(result["documents"]),
    }
    return result


def recover_manifest_metadata(expected: dict, archive: Path) -> dict:
    """Enrich a legacy baseline only from its verified original backup.

    Never use the live database to manufacture missing baseline evidence.
    Extract regular files ourselves so archive links cannot escape the scratch dir.
    """
    with tempfile.TemporaryDirectory(prefix="xiaoqi-baseline-") as scratch:
        root = Path(scratch)
        with tarfile.open(archive, "r:*") as source:
            for member in source.getmembers():
                relative = Path(member.name)
                if relative.is_absolute() or ".." in relative.parts or "\\" in member.name or ":" in member.name or member.issym() or member.islnk():
                    raise ValueError("Unsafe recovery archive entry")
                target = root / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    stream = source.extractfile(member)
                    if stream is None:
                        raise ValueError("Unreadable recovery archive entry")
                    with stream, target.open("xb") as output:
                        while chunk := stream.read(1024 * 1024):
                            output.write(chunk)
                else:
                    raise ValueError("Unsupported recovery archive entry")
        original = manifest(root)
        original_legacy_layout = (
            manifest(root, verify_reading_books=False)
            if "reading_books" not in expected and "reading_book_bindings" not in expected
            else original
        )
        introduced_fields = {"document_expirations", "reading_books", "reading_book_bindings"}
        legacy = {
            key: value for key, value in original_legacy_layout.items()
            if key not in introduced_fields or key in expected
        }
        if legacy != expected:
            raise ValueError("Recovery backup does not match the original manifest")
        return original


def with_catalog_changes(expected: dict, changes: dict) -> dict:
    """Apply only the exact deployment-owned catalog delta to the baseline."""
    names = ("study-notes-studio", "book-to-skill", "original-reading-annotations", "learning-notes-manager")
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
    pattern = r"official-catalog/(study-notes-studio|book-to-skill|original-reading-annotations|learning-notes-manager)/[a-f0-9]{64}\.zip"
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
        **expected,
        "documents": sorted([key, value] for key, value in merged_documents.items()),
        "document_hashes": dict(expected["document_hashes"], **hashes),
        "document_expirations": dict(expected.get("document_expirations", {})),
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
    parser.add_argument("--baseline-archive", type=Path)
    args = parser.parse_args()

    current = manifest(args.root)
    encoded = json.dumps(current, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)

    if args.compare:
        expected = json.loads(args.compare.read_text(encoding="utf-8"))
        baseline_has_book_files = any(
            key.startswith("reading_book_original/") for key in expected["object_keys"]
        )
        missing_book_metadata = "reading_books" not in expected and (
            "reading_books" in current or baseline_has_book_files
        )
        missing_book_bindings = "reading_book_bindings" in current and "reading_book_bindings" not in expected
        if "document_expirations" not in expected or missing_book_metadata or missing_book_bindings:
            if args.baseline_archive is None:
                raise ValueError("Legacy manifest requires its original backup archive")
            expected = recover_manifest_metadata(expected, args.baseline_archive)
        now_ms = int(time.time() * 1000)
        current = exclude_expired_attachments(current, now_ms)
        expected = exclude_expired_attachments(expected, now_ms)
        if args.catalog_changes:
            expected = with_catalog_changes(expected, json.loads(args.catalog_changes.read_text(encoding="utf-8")))
        if not matches_manifest(current, expected):
            print("STORE_MANIFEST_MISMATCH", file=sys.stderr)
            return 1
        print("STORE_MANIFEST_MATCH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
