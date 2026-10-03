from __future__ import annotations

import io
import json
import os
import zipfile
from dataclasses import dataclass
from typing import Any


class ConfigurationError(RuntimeError):
    pass


class RevisionConflict(RuntimeError):
    pass


def _attribute_map(row: Any) -> dict[str, Any]:
    if row is None:
        return {}
    result: dict[str, Any] = {}
    for item in row.attribute_columns or []:
        if len(item) >= 2:
            result[str(item[0])] = item[1]
    return result


@dataclass(frozen=True)
class StoredDocument:
    value: dict[str, Any]
    revision: int


class CloudStore:
    """Small adapter over Tablestore CAS and private, immutable OSS objects."""

    def __init__(self) -> None:
        required = (
            "OTS_ENDPOINT",
            "OTS_INSTANCE",
            "OSS_ENDPOINT",
            "OSS_BUCKET",
            "OSS_REGION",
            "ALIBABA_CLOUD_ACCESS_KEY_ID",
            "ALIBABA_CLOUD_ACCESS_KEY_SECRET",
        )
        missing = [name for name in required if not os.environ.get(name)]
        if missing:
            raise ConfigurationError("云端技能存储未配置: " + ", ".join(missing))

        try:
            import oss2
            import tablestore
        except ImportError as error:
            raise ConfigurationError("缺少云存储依赖，请安装 capabilities/requirements.txt") from error

        access_key_id = os.environ["ALIBABA_CLOUD_ACCESS_KEY_ID"]
        access_key_secret = os.environ["ALIBABA_CLOUD_ACCESS_KEY_SECRET"]
        security_token = os.environ.get("ALIBABA_CLOUD_SECURITY_TOKEN")
        self._tablestore = tablestore
        self._table = os.environ.get("CAPABILITY_TABLE", "xiaoqi_capabilities_v1")
        self._client = tablestore.OTSClient(
            os.environ["OTS_ENDPOINT"],
            access_key_id,
            access_key_secret,
            os.environ["OTS_INSTANCE"],
            sts_token=security_token,
            region=os.environ.get("OTS_REGION") or None,
        )
        self._bucket = oss2.Bucket(
            oss2.Auth(access_key_id, access_key_secret, security_token),
            os.environ["OSS_ENDPOINT"],
            os.environ["OSS_BUCKET"],
            region=os.environ["OSS_REGION"],
        )

    def get(self, key: str) -> StoredDocument | None:
        _, row, _ = self._client.get_row(
            self._table, [("pk", key)], max_version=1
        )
        attrs = _attribute_map(row)
        raw = attrs.get("document")
        if raw is None:
            return None
        return StoredDocument(json.loads(raw), int(attrs.get("revision", 0)))

    def list(self, prefix: str, limit: int = 200) -> list[tuple[str, StoredDocument]]:
        ts = self._tablestore
        start = [("pk", prefix)]
        end = [("pk", prefix + "\uffff")]
        result: list[tuple[str, StoredDocument]] = []
        token = None
        while len(result) < limit:
            _, next_start, rows, _ = self._client.get_range(
                self._table,
                ts.Direction.FORWARD,
                start,
                end,
                limit=min(100, limit - len(result)),
                max_version=1,
                token=token,
            )
            for row in rows:
                primary_key = dict(row.primary_key)
                attrs = _attribute_map(row)
                raw = attrs.get("document")
                if raw is not None:
                    result.append(
                        (
                            str(primary_key["pk"]),
                            StoredDocument(
                                json.loads(raw), int(attrs.get("revision", 0))
                            ),
                        )
                    )
            if not next_start or not rows:
                break
            start = next_start
        return result

    def put(
        self, key: str, value: dict[str, Any], expected_revision: int | None
    ) -> StoredDocument:
        ts = self._tablestore
        if expected_revision is None:
            condition = ts.Condition(ts.RowExistenceExpectation.EXPECT_NOT_EXIST)
            next_revision = 1
        else:
            column = ts.SingleColumnCondition(
                "revision",
                expected_revision,
                ts.ComparatorType.EQUAL,
                pass_if_missing=False,
            )
            condition = ts.Condition(
                ts.RowExistenceExpectation.EXPECT_EXIST, column
            )
            next_revision = expected_revision + 1

        row = ts.Row(
            [("pk", key)],
            [
                ("revision", next_revision),
                ("document", json.dumps(value, ensure_ascii=False, separators=(",", ":"))),
            ],
        )
        try:
            self._client.put_row(self._table, row, condition)
        except Exception as error:
            message = f"{getattr(error, 'error_code', '')} {error}".lower()
            if any(marker in message for marker in ("conditioncheckfail", "condition check", "condition_not_match")):
                raise RevisionConflict(key) from error
            raise
        return StoredDocument(value, next_revision)

    def put_immutable(self, key: str, files: dict[str, bytes]) -> None:
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content in files.items():
                archive.writestr(name, content)
        try:
            self._bucket.put_object(
                key,
                payload.getvalue(),
                headers={
                    "Content-Type": "application/zip",
                    "x-oss-forbid-overwrite": "true",
                },
            )
        except Exception as error:
            if "filealreadyexists" not in str(getattr(error, "code", "")).lower():
                raise

    def get_immutable(self, key: str) -> dict[str, bytes]:
        body = self._bucket.get_object(key).read()
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            files: dict[str, bytes] = {}
            for name in archive.namelist():
                if name.startswith("/") or ".." in name.split("/"):
                    raise ValueError("技能包包含越界路径")
                files[name] = archive.read(name)
            return files

    def put_task_blob(self, key: str, content: bytes) -> None:
        """Task checkpoints are private, short-lived, and intentionally mutable."""
        self._bucket.put_object(
            key,
            content,
            headers={"Content-Type": "application/json; charset=utf-8"},
        )

    def get_task_blob(self, key: str) -> bytes:
        return self._bucket.get_object(key).read()

    def delete_immutable(self, key: str) -> None:
        self._bucket.delete_object(key)
