from __future__ import annotations

import io
import json
import os
import sqlite3
import tempfile
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterator


class ConfigurationError(RuntimeError):
    pass


class RevisionConflict(RuntimeError):
    pass


@dataclass(frozen=True)
class StoredDocument:
    value: dict[str, Any]
    revision: int


class CloudStore:
    """Single-server SQLite documents and private filesystem objects."""

    def __init__(self, root: str | Path | None = None) -> None:
        data_root = root or os.environ.get("XIAOQI_DATA_DIR")
        self.root = Path(data_root).expanduser() if data_root else Path.home() / ".local" / "share" / "xiaoqi"
        self.database = self.root / "xiaoqi.sqlite3"
        self.objects = self.root / "objects"
        self.root.mkdir(parents=True, exist_ok=True)
        self.objects.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._secure_mode(self.root, 0o700)
        self._secure_mode(self.objects, 0o700)
        with self._connection() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute(
                "CREATE TABLE IF NOT EXISTS documents ("
                "key TEXT PRIMARY KEY, document TEXT NOT NULL, revision INTEGER NOT NULL)"
            )
            connection.execute(
                "CREATE TABLE IF NOT EXISTS objects ("
                "key TEXT PRIMARY KEY, updated_at INTEGER NOT NULL)"
            )

    @staticmethod
    def _secure_mode(path: Path, mode: int) -> None:
        try:
            path.chmod(mode)
        except OSError:
            pass

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.database, timeout=15)
        connection.execute("PRAGMA busy_timeout=15000")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA secure_delete=ON")
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    @staticmethod
    def _safe_key(key: str) -> PurePosixPath:
        path = PurePosixPath(str(key))
        if (
            not str(key)
            or path.is_absolute()
            or "\\" in str(key)
            or any(part in ("", ".", "..") or ":" in part for part in path.parts)
        ):
            raise ValueError("存储路径无效")
        return path

    def _object_path(self, key: str) -> Path:
        return self.objects.joinpath(*self._safe_key(key).parts)

    def _index_object(self, key: str) -> None:
        with self._connection() as connection:
            connection.execute(
                "INSERT INTO objects(key, updated_at) VALUES(?, unixepoch()) "
                "ON CONFLICT(key) DO UPDATE SET updated_at=excluded.updated_at",
                (key,),
            )

    def _write_object(self, key: str, content: bytes, *, immutable: bool) -> None:
        path = self._object_path(key)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._secure_mode(path.parent, 0o700)
        if immutable and path.exists():
            self._index_object(key)
            return
        # Index first so a crash after the atomic rename still leaves the object
        # discoverable by the retention sweep.
        self._index_object(key)
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".tmp-", delete=False) as temporary:
                temporary_path = Path(temporary.name)
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
            self._secure_mode(temporary_path, 0o600)
            if immutable:
                try:
                    os.link(temporary_path, path)
                except FileExistsError:
                    pass
                else:
                    temporary_path.unlink()
                    temporary_path = None
            else:
                os.replace(temporary_path, path)
                temporary_path = None
            self._secure_mode(path, 0o600)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)

    def get(self, key: str) -> StoredDocument | None:
        with self._connection() as connection:
            row = connection.execute(
                "SELECT document, revision FROM documents WHERE key=?", (key,)
            ).fetchone()
        if row is None:
            return None
        return StoredDocument(json.loads(row[0]), int(row[1]))

    def list(
        self,
        prefix: str,
        limit: int = 200,
        *,
        after_key: str | None = None,
    ) -> list[tuple[str, StoredDocument]]:
        if limit < 1:
            return []
        with self._connection() as connection:
            if after_key is None:
                rows = connection.execute(
                    "SELECT key, document, revision FROM documents "
                    "WHERE key>=? AND key<? ORDER BY key LIMIT ?",
                    (prefix, prefix + "\uffff", limit),
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT key, document, revision FROM documents "
                    "WHERE key>? AND key<? ORDER BY key LIMIT ?",
                    (after_key, prefix + "\uffff", limit),
                ).fetchall()
        return [
            (str(key), StoredDocument(json.loads(document), int(revision)))
            for key, document, revision in rows
        ]

    def put(
        self, key: str, value: dict[str, Any], expected_revision: int | None
    ) -> StoredDocument:
        document = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                if expected_revision is None:
                    connection.execute(
                        "INSERT INTO documents(key, document, revision) VALUES(?, ?, 1)",
                        (key, document),
                    )
                    revision = 1
                else:
                    revision = expected_revision + 1
                    cursor = connection.execute(
                        "UPDATE documents SET document=?, revision=? "
                        "WHERE key=? AND revision=?",
                        (document, revision, key, expected_revision),
                    )
                    if cursor.rowcount != 1:
                        raise RevisionConflict(key)
        except sqlite3.IntegrityError as error:
            raise RevisionConflict(key) from error
        return StoredDocument(value, revision)

    def delete(self, key: str, expected_revision: int | None = None) -> bool:
        with self._connection() as connection:
            if expected_revision is None:
                cursor = connection.execute("DELETE FROM documents WHERE key=?", (key,))
            else:
                cursor = connection.execute(
                    "DELETE FROM documents WHERE key=? AND revision=?",
                    (key, expected_revision),
                )
        return cursor.rowcount == 1

    def put_immutable(self, key: str, files: dict[str, bytes]) -> None:
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content in files.items():
                safe_name = self._safe_key(name)
                archive.writestr(str(safe_name), content)
        self._write_object(key, payload.getvalue(), immutable=True)

    def get_immutable(self, key: str) -> dict[str, bytes]:
        with zipfile.ZipFile(self._object_path(key)) as archive:
            files: dict[str, bytes] = {}
            for name in archive.namelist():
                safe_name = self._safe_key(name)
                files[str(safe_name)] = archive.read(name)
            return files

    def put_task_blob(self, key: str, content: bytes) -> None:
        self._write_object(key, content, immutable=False)

    def get_task_blob(self, key: str) -> bytes:
        return self._object_path(key).read_bytes()

    def delete_immutable(self, key: str) -> None:
        path = self._object_path(key)
        path.unlink(missing_ok=True)
        with self._connection() as connection:
            connection.execute("DELETE FROM objects WHERE key=?", (key,))

    def delete_objects_prefix(self, prefix: str) -> int:
        upper = prefix + "\uffff"
        with self._connection() as connection:
            keys = [
                str(row[0])
                for row in connection.execute(
                    "SELECT key FROM objects WHERE key>=? AND key<?", (prefix, upper)
                )
            ]
        for key in keys:
            self._object_path(key).unlink(missing_ok=True)
        with self._connection() as connection:
            connection.execute(
                "DELETE FROM objects WHERE key>=? AND key<?", (prefix, upper)
            )
        return len(keys)

    def checkpoint_wal(self) -> bool:
        connection = sqlite3.connect(self.database, timeout=15)
        try:
            connection.execute("PRAGMA busy_timeout=15000")
            result = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
            return bool(result and int(result[0]) == 0)
        finally:
            connection.close()

    def remove_orphaned_temp_files(self) -> int:
        removed = 0
        for path in self.objects.rglob(".tmp-*"):
            if path.is_file() or path.is_symlink():
                path.unlink(missing_ok=True)
                removed += 1
        return removed


SQLiteStore = CloudStore
