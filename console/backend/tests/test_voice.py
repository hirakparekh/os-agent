"""Voice proxy tests. Sarvam is faked with an httpx MockTransport — no network, no real key."""

from __future__ import annotations

import base64
import io
import json
import wave
from collections.abc import Callable, Iterator
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from console.backend import voice
from console.backend.config import Settings
from console.backend.main import create_app

ADMIN_EMAIL = "admin@agent-os.local"
ADMIN_PASSWORD = "changeme"


def _settings(tmp_path: Path, sarvam_api_key: str | None) -> Settings:
    return Settings(
        clickup_token=None,
        slack_bot_token=None,
        fathom_api_key=None,
        admin_email=ADMIN_EMAIL,
        admin_password=ADMIN_PASSWORD,
        clickup_employees_list_id=None,
        database_url=f"sqlite:///{tmp_path}/test.db",
        secret_key="test-secret-at-least-32-bytes-long!!",
        brain_api_base_url="http://localhost:8080",
        sarvam_api_key=sarvam_api_key,
    )


def _client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, key: str | None) -> TestClient:
    monkeypatch.setenv("CONSOLE_INTEGRATIONS_PATH", str(tmp_path / "console-integrations.json"))
    return TestClient(create_app(_settings(tmp_path, key)))


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    with _client(tmp_path, monkeypatch, "sk-test") as c:
        yield c


@pytest.fixture
def unconfigured(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    with _client(tmp_path, monkeypatch, None) as c:
        yield c


def _auth(client: TestClient) -> dict[str, str]:
    res = client.post("/auth/login", json={"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD})
    return {"Authorization": f"Bearer {res.json()['token']}"}


def _wav(frames: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(voice.TTS_SAMPLE_RATE)
        w.writeframes(b"\x01\x00" * frames)
    return buf.getvalue()


def _fake_sarvam(
    monkeypatch: pytest.MonkeyPatch, handler: Callable[[httpx.Request], httpx.Response]
) -> None:
    real = httpx.AsyncClient
    monkeypatch.setattr(
        voice.httpx,
        "AsyncClient",
        lambda **kw: real(transport=httpx.MockTransport(handler), **kw),
    )


def test_voice_requires_auth(client: TestClient) -> None:
    assert client.get("/voice/options").status_code == 401
    assert client.post("/voice/speak", json={"text": "hi"}).status_code == 401


def test_options_report_unconfigured_without_key(unconfigured: TestClient) -> None:
    res = unconfigured.get("/voice/options", headers=_auth(unconfigured))
    assert res.status_code == 200
    assert res.json()["configured"] is False
    assert "shubh" in res.json()["speakers"]


def test_transcribe_without_key_is_503(unconfigured: TestClient) -> None:
    res = unconfigured.post(
        "/voice/transcribe",
        headers=_auth(unconfigured),
        files={"file": ("a.webm", b"audio", "audio/webm")},
    )
    assert res.status_code == 503
    assert "SARVAM_API_KEY" in res.json()["detail"]


def test_transcribe_forwards_audio_and_returns_transcript(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["key"] = request.headers.get("api-subscription-key")
        seen["body"] = request.read()
        return httpx.Response(
            200, json={"transcript": "  what did hevo say  ", "language_code": "en-IN"}
        )

    _fake_sarvam(monkeypatch, handler)
    res = client.post(
        "/voice/transcribe",
        headers=_auth(client),
        data={"language_code": "en-IN"},
        files={"file": ("rec.webm", b"fake-opus-bytes", "audio/webm;codecs=opus")},
    )
    assert res.status_code == 200, res.text
    assert res.json() == {"transcript": "what did hevo say", "language_code": "en-IN"}
    assert seen["url"] == "https://api.sarvam.ai/speech-to-text"
    assert seen["key"] == "sk-test"
    body = seen["body"]
    assert isinstance(body, bytes)
    assert b"fake-opus-bytes" in body
    assert b"Content-Type: audio/webm\r\n" in body  # codecs parameter stripped
    assert b"saaras:v3" in body


def test_speak_chunks_long_text_and_joins_wav(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    requests: list[dict[str, object]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.read())
        requests.append(payload)
        return httpx.Response(200, json={"audios": [base64.b64encode(_wav(100)).decode()]})

    _fake_sarvam(monkeypatch, handler)
    long_text = "This is a sentence about placements. " * 150  # ~5.5k chars → 3 chunks
    res = client.post(
        "/voice/speak",
        headers=_auth(client),
        json={"text": long_text, "speaker": "priya", "language_code": "en-IN"},
    )
    assert res.status_code == 200, res.text
    assert res.headers["content-type"] == "audio/wav"
    assert len(requests) == 3
    assert all(len(str(r["text"])) <= voice.TTS_CHUNK_CHARS for r in requests)
    assert requests[0]["model"] == "bulbul:v3"
    assert requests[0]["speaker"] == "priya"
    with wave.open(io.BytesIO(res.content)) as w:
        assert w.getnframes() == 300


def test_speak_surfaces_sarvam_error(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    _fake_sarvam(monkeypatch, lambda _r: httpx.Response(403, text="quota exhausted"))
    res = client.post("/voice/speak", headers=_auth(client), json={"text": "hello"})
    assert res.status_code == 502
    assert "quota exhausted" in res.json()["detail"]


def test_speak_rejects_unknown_speaker(client: TestClient) -> None:
    res = client.post("/voice/speak", headers=_auth(client), json={"text": "hi", "speaker": "zed"})
    assert res.status_code == 422


def test_speakable_strips_markdown() -> None:
    text = "## Summary\n- **Hevo** sent an `OA` link\n1. See [portal](http://x.y)"
    assert voice._speakable(text) == "Summary\nHevo sent an OA link\nSee portal"


def test_chunks_never_exceed_limit_or_split_words() -> None:
    text = ("word " * 60).strip()
    chunks = voice._chunks(text, limit=50)
    assert all(len(c) <= 50 for c in chunks)
    assert " ".join(chunks).split() == text.split()
