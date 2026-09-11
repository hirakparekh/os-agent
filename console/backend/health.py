"""Integration-health endpoint.

For v1 this reports configuration status (is each integration's secret present?). A later
iteration upgrades it to a real liveness probe (Slack `auth.test`). The route MUST go through
the typed clients, never raw third-party HTTP.
"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from console.backend.config import Settings, get_settings
from console.backend.integrations_store import get_secret

router = APIRouter(tags=["health"])

SettingsDep = Annotated[Settings, Depends(get_settings)]

Status = Literal["configured", "not_configured"]


class IntegrationHealth(BaseModel):
    name: str
    status: Status


class HealthReport(BaseModel):
    ok: bool
    integrations: list[IntegrationHealth]


def _status(secret: str | None) -> Status:
    return "configured" if secret else "not_configured"


@router.get("/health", response_model=HealthReport)
def health(settings: SettingsDep) -> HealthReport:
    # settings is a snapshot pinned at process startup (see main.py), but slack_bot_token can
    # also be set live from the Integrations UI after startup, so it's re-read from the store on
    # every call instead of trusting the stale snapshot value.
    slack_token = settings.slack_bot_token or get_secret("slack_bot_token")
    integrations = [IntegrationHealth(name="slack", status=_status(slack_token))]
    ok = all(i.status == "configured" for i in integrations)
    return HealthReport(ok=ok, integrations=integrations)
