from __future__ import annotations

import hashlib
from typing import Any

import pytest
from flask import Flask

from xiaoqi_harness.capabilities import api
from xiaoqi_harness.capabilities.storage import RevisionConflict, StoredDocument


class MemoryStore:
    def __init__(self) -> None:
        self.documents: dict[str, StoredDocument] = {}

    def get(self, key: str) -> StoredDocument | None:
        return self.documents.get(key)

    def put(
        self, key: str, value: dict[str, Any], expected_revision: int | None
    ) -> StoredDocument:
        current = self.documents.get(key)
        if expected_revision is None:
            if current is not None:
                raise RevisionConflict(key)
            revision = 1
        else:
            if current is None or current.revision != expected_revision:
                raise RevisionConflict(key)
            revision = expected_revision + 1
        document = StoredDocument(dict(value), revision)
        self.documents[key] = document
        return document

    def list(self, prefix: str, limit: int = 200) -> list[tuple[str, StoredDocument]]:
        return [
            (key, value)
            for key, value in sorted(self.documents.items())
            if key.startswith(prefix)
        ][:limit]


@pytest.fixture
def email_auth(monkeypatch: pytest.MonkeyPatch):
    memory = MemoryStore()
    sent: list[tuple[str, str, dict[str, Any]]] = []
    owner = "lucky@example.com"
    monkeypatch.setattr(api, "_store", memory)
    monkeypatch.setenv("CAPABILITY_OWNER_EMAIL", owner)
    monkeypatch.setenv("CAPABILITY_SMTP_HOST", "smtp.qq.com")
    monkeypatch.setenv("CAPABILITY_SMTP_USERNAME", owner)
    monkeypatch.setenv("CAPABILITY_SMTP_PORT", "465")
    monkeypatch.setenv("CAPABILITY_SMTP_PASSWORD", "test-smtp-auth-code")
    monkeypatch.setenv("CAPABILITY_AUTH_CODE_PEPPER", "p" * 40)
    monkeypatch.setattr(
        api,
        "_send_email_login_code",
        lambda email, code, **kwargs: sent.append((email, code, kwargs)),
    )
    app = Flask(__name__)
    app.register_blueprint(api.capabilities, url_prefix="/v1")
    return app.test_client(), memory, sent, owner


def _device_token(owner: str, token: str) -> str:
    return f"device/{hashlib.sha256(token.encode()).hexdigest()}"


def test_email_code_sign_in_uses_personal_tenant_and_revocable_session(email_auth):
    client, memory, sent, owner = email_auth

    started = client.post("/v1/auth/email/start", json={"email": owner})
    assert started.status_code == 202
    assert len(sent) == 1
    assert sent[0][0] == owner

    verified = client.post(
        "/v1/auth/email/verify",
        json={"email": owner, "code": sent[0][1]},
    )
    assert verified.status_code == 201
    token = verified.json["access_token"]
    row = memory.get(_device_token(owner, token))
    assert row is not None
    assert row.value["tenant_id"] == "personal"
    assert row.value["auth_method"] == "email"

    session = client.get(
        "/v1/auth/me", headers={"Authorization": f"Bearer {token}"}
    )
    assert session.status_code == 200
    assert session.json["email"] == owner

    signed_out = client.delete(
        "/v1/auth/session", headers={"Authorization": f"Bearer {token}"}
    )
    assert signed_out.status_code == 200
    assert client.get(
        "/v1/auth/me", headers={"Authorization": f"Bearer {token}"}
    ).status_code == 401


def test_login_code_is_single_use_and_invalid_attempts_are_limited(
    email_auth, monkeypatch: pytest.MonkeyPatch
):
    client, _memory, sent, owner = email_auth
    monkeypatch.setattr(api.secrets, "randbelow", lambda _upper: 123456)
    client.post("/v1/auth/email/start", json={"email": owner})
    correct_code = sent[0][1]

    for _ in range(api._AUTH_CODE_MAX_ATTEMPTS):
        response = client.post(
            "/v1/auth/email/verify", json={"email": owner, "code": "111111"}
        )
        assert response.status_code == 401

    assert client.post(
        "/v1/auth/email/verify", json={"email": owner, "code": correct_code}
    ).status_code == 401


def test_unknown_email_gets_same_public_response_without_sending(email_auth):
    client, memory, sent, _owner = email_auth

    response = client.post(
        "/v1/auth/email/start", json={"email": "someone@example.com"}
    )

    assert response.status_code == 202
    assert response.json["message"] == "如果该邮箱已获准登录，验证码会发送到邮箱"
    assert sent == []
    assert memory.documents == {}


def test_resend_cooldown_does_not_send_a_second_email(email_auth):
    client, _memory, sent, owner = email_auth

    first = client.post("/v1/auth/email/start", json={"email": owner})
    second = client.post("/v1/auth/email/start", json={"email": owner})

    assert first.status_code == second.status_code == 202
    assert len(sent) == 1


def test_smtp_failure_does_not_expose_provider_error(email_auth, monkeypatch):
    client, memory, _sent, owner = email_auth
    monkeypatch.setattr(
        api,
        "_send_email_login_code",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            RuntimeError("smtp-secret-detail")
        ),
    )

    response = client.post("/v1/auth/email/start", json={"email": owner})

    assert response.status_code == 202
    assert "smtp-secret-detail" not in response.get_data(as_text=True)
    challenge = memory.get(api._auth_code_key(owner))
    assert challenge is not None and challenge.value["consumed"] is True
