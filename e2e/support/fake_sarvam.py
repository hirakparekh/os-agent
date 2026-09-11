"""A stand-in for Sarvam AI's speech APIs, so the end-to-end suite needs no key or network.

console/backend calls Sarvam from its own process, so `SARVAM_BASE_URL` (see
console/backend/config.py) points it here. Speech-to-text always "hears" TRANSCRIPT; text-to-
speech returns a short silent WAV and records what it was asked to say, which `GET /spoken`
exposes so a spec can prove an answer was sent for synthesis.

    uv run python -m e2e.support.fake_sarvam --port 8114
"""

from __future__ import annotations

import argparse
import base64
import io
import wave

import uvicorn
from fastapi import FastAPI, Request

app = FastAPI(title="Fake Sarvam")

TRANSCRIPT = "What did Accenture say?"
_spoken: list[str] = []


def _silent_wav(seconds: float = 0.3, rate: int = 24000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * int(seconds * rate))
    return buf.getvalue()


@app.post("/speech-to-text")
async def speech_to_text(request: Request) -> dict[str, str]:
    form = await request.form()
    upload = form.get("file")
    if upload is None or isinstance(upload, str) or not await upload.read():
        return {"transcript": "", "language_code": "en-IN"}
    return {"transcript": TRANSCRIPT, "language_code": str(form.get("language_code", "en-IN"))}


@app.post("/text-to-speech")
async def text_to_speech(request: Request) -> dict[str, object]:
    body = await request.json()
    _spoken.append(str(body.get("text", "")))
    return {"request_id": "fake", "audios": [base64.b64encode(_silent_wav()).decode()]}


@app.get("/spoken")
def spoken() -> list[str]:
    return _spoken


@app.delete("/spoken")
def reset_spoken() -> None:
    _spoken.clear()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8114)
    args = parser.parse_args()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
