"""Ops-console API tests. SQLite per test — no live Postgres needed."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from console.backend.config import Settings
from console.backend.main import create_app

ADMIN_EMAIL = "admin@agent-os.local"
ADMIN_PASSWORD = "changeme"


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        slack_bot_token=None,
        admin_email=ADMIN_EMAIL,
        admin_password=ADMIN_PASSWORD,
        database_url=f"sqlite:///{tmp_path}/test.db",
        secret_key="test-secret-at-least-32-bytes-long!!",
        brain_api_base_url="http://localhost:8080",
    )


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    # Isolate the local integrations store (console/backend/integrations_store.py) from the
    # real ~/.hermes/console-integrations.json — otherwise a token connected on this machine
    # via the Applications UI leaks into test assertions about "not_configured".
    monkeypatch.setenv("CONSOLE_INTEGRATIONS_PATH", str(tmp_path / "console-integrations.json"))
    app = create_app(_settings(tmp_path))
    with TestClient(app) as test_client:  # triggers lifespan (DB setup + seed)
        yield test_client


def _token(client: TestClient, email: str = ADMIN_EMAIL, password: str = ADMIN_PASSWORD) -> str:
    res = client.post("/auth/login", json={"email": email, "password": password})
    assert res.status_code == 200, res.text
    return str(res.json()["token"])


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_health_reports_configuration(client: TestClient) -> None:
    res = client.get("/health")
    assert res.status_code == 200
    names = {i["name"]: i["status"] for i in res.json()["integrations"]}
    assert names == {"slack": "not_configured"}


def test_seeded_admin_can_log_in(client: TestClient) -> None:
    assert _token(client)  # non-empty token


def test_login_rejects_bad_credentials(client: TestClient) -> None:
    res = client.post("/auth/login", json={"email": ADMIN_EMAIL, "password": "wrong"})
    assert res.status_code == 401


def test_me_returns_current_user(client: TestClient) -> None:
    res = client.get("/auth/me", headers=_bearer(_token(client)))
    assert res.status_code == 200
    assert res.json()["email"] == ADMIN_EMAIL
    assert res.json()["role"] == "admin"


def test_admin_can_create_user_who_can_then_log_in(client: TestClient) -> None:
    res = client.post(
        "/auth/users",
        json={"email": "gtm@agent-os.local", "password": "pw123456", "role": "gtm"},
        headers=_bearer(_token(client)),
    )
    assert res.status_code == 201, res.text
    # The new user can authenticate.
    assert _token(client, "gtm@agent-os.local", "pw123456")


def test_non_admin_cannot_create_user(client: TestClient) -> None:
    client.post(
        "/auth/users",
        json={"email": "sales@agent-os.local", "password": "pw123456", "role": "sales"},
        headers=_bearer(_token(client)),
    )
    sales_token = _token(client, "sales@agent-os.local", "pw123456")
    res = client.post(
        "/auth/users",
        json={"email": "x@agent-os.local", "password": "pw123456", "role": "sales"},
        headers=_bearer(sales_token),
    )
    assert res.status_code == 403


def test_chat_forwards_the_session_id_to_brain(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Console owns the conversation id; brain cannot resolve a follow-up without being told it."""
    captured: dict[str, Any] = {}

    class _Reply:
        status_code = 200

        def raise_for_status(self) -> None:
            return None

        def json(self) -> dict[str, str]:
            return {"answer": "Two deadlines this week."}

    def fake_post(url: str, **kwargs: Any) -> _Reply:
        captured["url"] = url
        captured["json"] = kwargs.get("json")
        return _Reply()

    # Patched on httpx itself rather than on the chat module, which does not re-export it.
    monkeypatch.setattr(httpx, "post", fake_post)

    token = _token(client)
    created = client.post("/chat/sessions", headers=_bearer(token))
    assert created.status_code in (200, 201), created.text
    session_id = int(created.json()["id"])

    res = client.post(
        f"/chat/sessions/{session_id}/messages",
        headers=_bearer(token),
        json={"question": "when is it due?"},
    )
    assert res.status_code == 200, res.text

    url = str(captured["url"])
    payload = captured["json"]
    assert isinstance(payload, dict)
    assert url.endswith("/api/mail/ask")
    assert payload["session_id"] == session_id
    assert payload["question"] == "when is it due?"
