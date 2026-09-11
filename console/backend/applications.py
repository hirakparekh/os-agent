"""Connect/disconnect endpoints for org-wide, token-based integrations (Applications UI).

Only Slack lives here. Gmail and Google Calendar are OAuth flows hosted by the brain service
(brain/viz_server.py's /api/mail/* and /api/calendar/*) — this router deliberately doesn't
proxy those, since the browser talks to brain directly for them (see console/frontend/src/
lib/brainApi.ts).
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

from console.backend.auth import require_admin
from console.backend.integrations_store import clear_secret, set_secret
from console.backend.models import User

router = APIRouter(prefix="/applications", tags=["applications"])

AdminUser = Annotated[User, Depends(require_admin)]


class ConnectRequest(BaseModel):
    credential: str


@router.post("/{app_id}/connect")
def connect_app(app_id: str, body: ConnectRequest, _admin: AdminUser) -> dict[str, str]:
    if app_id != "slack":
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"No connect flow for '{app_id}'")

    token = body.credential.strip()
    if not token:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "A bot token is required")

    try:
        resp = WebClient(token=token).auth_test()
    except SlackApiError as exc:
        detail = exc.response.get("error", str(exc)) if exc.response is not None else str(exc)
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, f"Slack rejected this token: {detail}"
        ) from exc

    set_secret("slack_bot_token", token)
    return {"team": resp.get("team", ""), "bot_user": resp.get("user", "")}


@router.post("/{app_id}/disconnect")
def disconnect_app(app_id: str, _admin: AdminUser) -> dict[str, bool]:
    if app_id != "slack":
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"No disconnect flow for '{app_id}'")
    clear_secret("slack_bot_token")
    return {"disconnected": True}
