"""Voice: speech-to-text and text-to-speech via Sarvam AI, proxied server-side.

The browser never sees the Sarvam key (ADR-0002: no third-party tokens in the frontend) — it
uploads recorded audio / sends answer text here, and this router calls Sarvam with the key from
`SARVAM_API_KEY`. Voice is a transport layer only: a transcript goes back into the normal chat
flow (console/backend/chat.py) exactly as if it had been typed.
"""

from __future__ import annotations

import base64
import io
import re
import wave
from typing import Annotated

import httpx
from fastapi import APIRouter, Depends, File, Form, HTTPException, Response, UploadFile, status
from pydantic import BaseModel

from console.backend.auth import CurrentUser
from console.backend.config import Settings, get_settings

router = APIRouter(prefix="/voice", tags=["voice"])

SettingsDep = Annotated[Settings, Depends(get_settings)]

STT_MODEL = "saaras:v3"
TTS_MODEL = "bulbul:v3"
TTS_SAMPLE_RATE = 24000
# bulbul:v3 rejects text over 2500 characters; leave headroom for the split point.
TTS_CHUNK_CHARS = 2400
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

LANGUAGES = (
    "en-IN",
    "hi-IN",
    "bn-IN",
    "gu-IN",
    "kn-IN",
    "ml-IN",
    "mr-IN",
    "od-IN",
    "pa-IN",
    "ta-IN",
    "te-IN",
)
SPEAKERS = (
    "shubh",
    "aditya",
    "ritu",
    "priya",
    "neha",
    "rahul",
    "pooja",
    "rohan",
    "simran",
    "kavya",
    "amit",
    "dev",
    "ishita",
    "shreya",
    "ratan",
    "varun",
    "manan",
    "sumit",
    "roopa",
    "kabir",
    "aayan",
    "ashutosh",
    "advait",
    "anand",
    "tanya",
    "tarun",
    "sunny",
    "mani",
    "gokul",
    "vijay",
    "shruti",
    "suhani",
    "mohit",
    "kavitha",
    "rehan",
    "soham",
    "rupali",
)
DEFAULT_LANGUAGE = "en-IN"
DEFAULT_SPEAKER = "shubh"


class VoiceOptions(BaseModel):
    configured: bool
    languages: list[str]
    speakers: list[str]
    default_language: str
    default_speaker: str


class TranscriptOut(BaseModel):
    transcript: str
    language_code: str | None


class SpeakRequest(BaseModel):
    text: str
    language_code: str = DEFAULT_LANGUAGE
    speaker: str = DEFAULT_SPEAKER
    pace: float = 1.0


def _require_key(settings: Settings) -> str:
    if not settings.sarvam_api_key:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Voice isn't configured — set SARVAM_API_KEY in .env and restart the console backend.",
        )
    return settings.sarvam_api_key


def _sarvam_error(resp: httpx.Response) -> HTTPException:
    # Surface Sarvam's own message: a rejected field or an exhausted quota is only diagnosable
    # from their wording, not from a generic "upstream failed".
    return HTTPException(
        status.HTTP_502_BAD_GATEWAY, f"Sarvam returned {resp.status_code}: {resp.text[:500]}"
    )


def _speakable(text: str) -> str:
    """Strip markdown the LLM answers contain, so TTS doesn't read out asterisks and hashes."""
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"^\s{0,3}(#{1,6}|[-*+]|\d+[.)])\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[*_`#>|]", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return re.sub(r"[ \t]+", " ", text).strip()


def _chunks(text: str, limit: int = TTS_CHUNK_CHARS) -> list[str]:
    """Split at sentence boundaries so no chunk exceeds `limit` and no word is cut in half."""
    sentences = re.split(r"(?<=[.!?।])\s+|\n+", text)
    chunks: list[str] = []
    current = ""
    for sentence in (s.strip() for s in sentences):
        if not sentence:
            continue
        while len(sentence) > limit:
            cut = sentence.rfind(" ", 0, limit)
            cut = cut if cut > 0 else limit
            if current:
                chunks.append(current)
                current = ""
            chunks.append(sentence[:cut].strip())
            sentence = sentence[cut:].strip()
        if current and len(current) + 1 + len(sentence) > limit:
            chunks.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    if current:
        chunks.append(current)
    return chunks


def _join_wavs(parts: list[bytes]) -> bytes:
    if len(parts) == 1:
        return parts[0]
    out = io.BytesIO()
    with wave.open(io.BytesIO(parts[0])) as first:
        params = first.getparams()
    with wave.open(out, "wb") as writer:
        writer.setparams(params)
        for part in parts:
            with wave.open(io.BytesIO(part)) as reader:
                writer.writeframes(reader.readframes(reader.getnframes()))
    return out.getvalue()


@router.get("/options", response_model=VoiceOptions)
def voice_options(_user: CurrentUser, settings: SettingsDep) -> VoiceOptions:
    return VoiceOptions(
        configured=bool(settings.sarvam_api_key),
        languages=list(LANGUAGES),
        speakers=list(SPEAKERS),
        default_language=DEFAULT_LANGUAGE,
        default_speaker=DEFAULT_SPEAKER,
    )


@router.post("/transcribe", response_model=TranscriptOut)
async def transcribe(
    _user: CurrentUser,
    settings: SettingsDep,
    file: Annotated[UploadFile, File()],
    language_code: Annotated[str, Form()] = DEFAULT_LANGUAGE,
) -> TranscriptOut:
    key = _require_key(settings)
    if language_code not in LANGUAGES and language_code != "unknown":
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Unsupported language_code")

    audio = await file.read(MAX_UPLOAD_BYTES + 1)
    if not audio:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "No audio received")
    if len(audio) > MAX_UPLOAD_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Recording is too long")

    # MediaRecorder reports e.g. "audio/webm;codecs=opus"; Sarvam wants the bare media type.
    content_type = (file.content_type or "audio/webm").split(";")[0].strip()
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                f"{settings.sarvam_base_url}/speech-to-text",
                headers={"api-subscription-key": key},
                data={"model": STT_MODEL, "language_code": language_code},
                files={"file": (file.filename or "recording.webm", audio, content_type)},
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"Couldn't reach Sarvam: {exc}") from exc
    if resp.status_code >= 400:
        raise _sarvam_error(resp)

    body = resp.json()
    return TranscriptOut(
        transcript=str(body.get("transcript") or "").strip(),
        language_code=body.get("language_code"),
    )


@router.post("/speak")
async def speak(body: SpeakRequest, _user: CurrentUser, settings: SettingsDep) -> Response:
    key = _require_key(settings)
    if body.language_code not in LANGUAGES:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Unsupported language_code")
    if body.speaker not in SPEAKERS:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Unsupported speaker")
    if not 0.5 <= body.pace <= 2.0:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "pace must be 0.5–2.0")

    chunks = _chunks(_speakable(body.text))
    if not chunks:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Nothing to speak")

    parts: list[bytes] = []
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            for chunk in chunks:
                resp = await client.post(
                    f"{settings.sarvam_base_url}/text-to-speech",
                    headers={"api-subscription-key": key},
                    json={
                        "text": chunk,
                        "language_code": body.language_code,
                        "speaker": body.speaker,
                        "model": TTS_MODEL,
                        "pace": body.pace,
                        "speech_sample_rate": TTS_SAMPLE_RATE,
                    },
                )
                if resp.status_code >= 400:
                    raise _sarvam_error(resp)
                audios = resp.json().get("audios") or []
                if not audios:
                    raise HTTPException(status.HTTP_502_BAD_GATEWAY, "Sarvam returned no audio")
                parts.append(base64.b64decode(audios[0]))
    except httpx.HTTPError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"Couldn't reach Sarvam: {exc}") from exc

    try:
        audio = _join_wavs(parts)
    except wave.Error as exc:
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, "Sarvam returned audio that isn't WAV"
        ) from exc
    return Response(content=audio, media_type="audio/wav")
