"""Tests for brain/oauth_flow.py — the redirect-based Google consent flow.

Network-free: Google is never contacted. What's tested is the part that is ours to get right —
the signed `state` that lets an unauthenticated callback prove which user it belongs to, since
that is the piece standing in for a server-side pending-state table.
"""

from __future__ import annotations

import time

import jwt
import pytest

from brain import oauth_flow


def test_state_round_trips_user_and_service(monkeypatch):
    monkeypatch.setenv("OPS_SECRET_KEY", "test-secret-at-least-32-bytes-long!!")
    state = oauth_flow._sign_state(7, "gmail")
    assert oauth_flow._verify_state(state) == (7, "gmail")


def test_state_signed_with_another_key_is_rejected(monkeypatch):
    """The callback is unauthenticated, so an unforgeable state is the only thing standing
    between a stranger's redirect and writing tokens against someone else's account."""
    monkeypatch.setenv("OPS_SECRET_KEY", "the-real-secret-at-least-32-bytes!!")
    forged = jwt.encode(
        {"sub": "1", "svc": "gmail", "exp": int(time.time()) + 600},
        "an-attackers-own-key",
        algorithm="HS256",
    )
    with pytest.raises(oauth_flow.OAuthFlowError):
        oauth_flow._verify_state(forged)


def test_expired_state_is_rejected(monkeypatch):
    monkeypatch.setenv("OPS_SECRET_KEY", "test-secret-at-least-32-bytes-long!!")
    stale = jwt.encode(
        {"sub": "1", "svc": "gmail", "exp": int(time.time()) - 5},
        "test-secret-at-least-32-bytes-long!!",
        algorithm="HS256",
    )
    with pytest.raises(oauth_flow.OAuthFlowError):
        oauth_flow._verify_state(stale)


def test_state_naming_an_unknown_service_is_rejected(monkeypatch):
    monkeypatch.setenv("OPS_SECRET_KEY", "test-secret-at-least-32-bytes-long!!")
    bogus = jwt.encode(
        {"sub": "1", "svc": "dropbox", "exp": int(time.time()) + 600},
        "test-secret-at-least-32-bytes-long!!",
        algorithm="HS256",
    )
    with pytest.raises(oauth_flow.OAuthFlowError):
        oauth_flow._verify_state(bogus)


def test_redirect_uri_follows_the_configured_base(monkeypatch):
    monkeypatch.setenv("OAUTH_REDIRECT_BASE_URL", "https://agent-os.example.com/")
    assert oauth_flow.redirect_uri() == "https://agent-os.example.com/api/oauth/callback"


def test_redirect_uri_defaults_to_local_brain(monkeypatch):
    monkeypatch.delenv("OAUTH_REDIRECT_BASE_URL", raising=False)
    assert oauth_flow.redirect_uri() == "http://localhost:8080/api/oauth/callback"


def test_build_auth_url_rejects_an_unknown_service():
    with pytest.raises(oauth_flow.OAuthFlowError):
        oauth_flow.build_auth_url("dropbox", 1)


def test_build_auth_url_explains_a_missing_client_secret(tmp_path, monkeypatch):
    """The most common first-run failure — it must name the file rather than throw a traceback."""
    monkeypatch.setenv("GMAIL_CREDENTIALS_PATH", str(tmp_path / "nope.json"))
    with pytest.raises(oauth_flow.OAuthFlowError, match="Missing OAuth client secrets"):
        oauth_flow.build_auth_url("gmail", 1)


def test_both_services_are_registered_with_distinct_token_paths(tmp_path, monkeypatch):
    """Gmail and Calendar must never share a token file — different scopes, and refreshing one
    with the other's grant fails with invalid_scope."""
    monkeypatch.delenv("GMAIL_TOKEN_PATH", raising=False)
    monkeypatch.delenv("CALENDAR_TOKEN_PATH", raising=False)
    gmail = oauth_flow.SERVICES["gmail"].token_path(1)
    calendar = oauth_flow.SERVICES["calendar"].token_path(1)
    assert gmail != calendar
