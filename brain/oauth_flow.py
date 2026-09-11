"""brain/oauth_flow.py — redirect-based Google OAuth, shared by Gmail and Calendar.

Replaces `InstalledAppFlow.run_local_server`, which opened a consent window on the *server* and
blocked the request until somebody completed it. That only worked because the server and the
browser were the same machine — it is the single reason this project could not be hosted.

The flow here is the ordinary three-legged one:

  1. the client asks POST /api/{gmail,calendar}/connect for an auth URL
  2. the user's own browser completes consent at Google
  3. Google redirects to GET /api/oauth/callback, which exchanges the code server-side
  4. the client polls /api/{...}/status until it flips to connected

`state` is a short-lived JWT signed with OPS_SECRET_KEY carrying (user_id, service). The
callback arrives with no Authorization header — a browser redirect from Google can't carry
one — so the state is how the server knows whose token it just received. Signing it (rather
than keeping a server-side pending-state table) means no shared mutable state, so this works
unchanged under multiple uvicorn workers, and a forged callback is useless without the key.

Note on `prompt="consent"`: this project requests https://mail.google.com/, a *restricted*
scope, on an unverified app — so refresh tokens expire after 7 days and users re-consent
routinely. Google only reliably returns a refresh_token when consent is re-prompted, so we ask
for it every time rather than relying on Google remembering a prior grant.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import jwt

from brain import calendar_tool, emailtool
from security.tokens import get_secret_key

# A consent round trip is a human clicking through Google; 10 minutes is generous for that and
# short enough that a leaked URL stops working quickly.
STATE_TTL_SECONDS = 600


class OAuthFlowError(RuntimeError):
    """Anything that stops a consent round trip — surfaced to the caller as a 4xx/5xx reason."""


@dataclass(frozen=True)
class _Service:
    name: str
    scopes: list[str]
    credentials_path: Callable[[], Path]
    token_path: Callable[[Any], Path]
    meta_path: Callable[[Any], Path]
    # Runs once after a successful exchange — Gmail uses it to discover which mailbox was
    # actually authorised, since there's no static address to fall back on per user.
    on_connected: Callable[[Any, Any], dict[str, Any]] | None = None


def _gmail_on_connected(creds: Any, user_id: Any) -> dict[str, Any]:
    address = emailtool._fetch_gmail_address(creds)
    return {"email": address} if address else {}


SERVICES: dict[str, _Service] = {
    "gmail": _Service(
        name="gmail",
        scopes=emailtool.GMAIL_OAUTH_SCOPES,
        credentials_path=emailtool._credentials_path,
        token_path=emailtool._token_path,
        meta_path=emailtool._meta_path,
        on_connected=_gmail_on_connected,
    ),
    "calendar": _Service(
        name="calendar",
        scopes=calendar_tool.CALENDAR_OAUTH_SCOPES,
        credentials_path=calendar_tool._credentials_path,
        token_path=calendar_tool._token_path,
        meta_path=calendar_tool._meta_path,
    ),
}


def redirect_uri() -> str:
    """Where Google sends the user back. Must be registered verbatim on the OAuth client in
    Google Cloud Console — a mismatch fails with redirect_uri_mismatch before consent."""
    base = os.environ.get("OAUTH_REDIRECT_BASE_URL", "http://localhost:8080").rstrip("/")
    return f"{base}/api/oauth/callback"


def _sign_state(user_id: Any, service: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {"sub": str(user_id), "svc": service, "iat": now, "exp": now + STATE_TTL_SECONDS},
        get_secret_key(),
        algorithm="HS256",
    )


def _verify_state(state: str) -> tuple[int, str]:
    try:
        payload = jwt.decode(state, get_secret_key(), algorithms=["HS256"])
    except jwt.PyJWTError as exc:
        raise OAuthFlowError(f"invalid or expired consent state: {exc}") from exc
    service = payload.get("svc")
    sub = payload.get("sub")
    if service not in SERVICES or not (isinstance(sub, str) and sub.isdigit()):
        raise OAuthFlowError("consent state did not identify a known service/user")
    return int(sub), service


def _flow(service: _Service) -> Any:
    from google_auth_oauthlib.flow import Flow

    creds_path = service.credentials_path()
    if not creds_path.exists():
        raise OAuthFlowError(
            f"Missing OAuth client secrets at {creds_path}. Download it from Google Cloud "
            "Console (see SETUP.md) and save it there."
        )
    # Google grants `openid` alongside userinfo.email without being asked, and oauthlib treats
    # any difference between requested and granted scopes as fatal — which would raise *after*
    # the user has already consented. Accept the superset Google actually returns.
    os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")
    return Flow.from_client_secrets_file(
        str(creds_path), scopes=service.scopes, redirect_uri=redirect_uri()
    )


def build_auth_url(service_name: str, user_id: Any) -> str:
    """The Google consent URL to send this user's browser to."""
    service = SERVICES.get(service_name)
    if service is None:
        raise OAuthFlowError(f"unknown service '{service_name}'")
    url, _ = _flow(service).authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",  # see module docstring — we need a refresh_token every time
        state=_sign_state(user_id, service_name),
    )
    return str(url)


def complete(state: str, code: str) -> tuple[int, str]:
    """Exchange an authorization code for tokens and persist them. Returns (user_id, service)."""
    user_id, service_name = _verify_state(state)
    service = SERVICES[service_name]

    flow = _flow(service)
    try:
        flow.fetch_token(code=code)
    except Exception as exc:
        raise OAuthFlowError(f"Google rejected the authorization code: {exc}") from exc

    creds = flow.credentials
    token_path = service.token_path(user_id)
    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(creds.to_json(), encoding="utf-8")

    # connected_at lets the UI warn *before* the 7-day refresh-token expiry rather than only
    # reporting failure after it. Cheap to record here, awkward to reconstruct later.
    meta: dict[str, Any] = {"connected_at": int(time.time())}
    if service.on_connected:
        meta.update(service.on_connected(creds, user_id))
    _write_meta(service.meta_path(user_id), meta)

    return user_id, service_name


def _write_meta(path: Path, meta: dict[str, Any]) -> None:
    import json

    path.parent.mkdir(parents=True, exist_ok=True)
    existing: dict[str, Any] = {}
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            existing = {}
    path.write_text(json.dumps({**existing, **meta}), encoding="utf-8")
