#!/usr/bin/env python3
"""
brain/emailtool.py - IMAP helper for the mail knowledge-tree pipeline.

Fetches mail over IMAP (imaplib + email, stdlib). Two auth modes are supported:

  - App password (default, if EMAIL_APP_PASSWORD is set): plain IMAP login. See SETUP.md.
  - OAuth (if EMAIL_APP_PASSWORD is unset): XOAUTH2 over IMAP, for accounts where Google
    doesn't offer App Passwords. Needs the `google-auth` / `google-auth-oauthlib` packages.

Reads connection details from environment variables (the project's own `.env`, auto-loaded by
`brain/__init__.py`):
    EMAIL_EMAIL
    EMAIL_APP_PASSWORD          (app-password mode)
    GMAIL_CREDENTIALS_PATH      (OAuth mode, default ~/.hermes/mail/credentials.json)
    GMAIL_TOKEN_PATH            (OAuth mode, default ~/.hermes/mail/token.json)
    EMAIL_IMAP_HOST
    EMAIL_IMAP_PORT (optional, defaults to 993)

Modes
-----
    python emailtool.py list [--since-minutes N]
        Print a JSON array of unread emails to stdout. Each entry includes
        sender, subject, body text, and a list of attachments (saved to the
        cache directory as files). With --since-minutes, only unread emails
        whose Date header falls within the last N minutes are included.

    python emailtool.py mark-read <uid>
        Mark a specific email as read (\\Seen flag) by UID.

    python emailtool.py auth
        Report the stored grant (address + token path), or explain how to connect.
        Consent itself is a browser redirect flow served by the brain API
        (brain/oauth_flow.py) — never a window opened by this script.

Output is a single line of JSON to stdout. Errors go to stderr and exit non-zero.
"""

import email
import email.policy
import email.utils
import imaplib
import json
import os
import re
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

try:
    from dotenv import load_dotenv

    load_dotenv()  # .env isn't auto-loaded here when run as a standalone script (not `-m brain...`)
except Exception:
    pass

# IMAP OAuth2 requires the full-mailbox scope — Gmail's `gmail.readonly` scope is for the
# Gmail REST API only and doesn't work over IMAP (and wouldn't let us mark messages read,
# which the pipeline needs to avoid reprocessing the same email). userinfo.email lets us
# discover *which* mailbox was just authorized (needed for the per-user OAuth path, where
# there's no static EMAIL_EMAIL to fall back on) — this is a scope change from earlier
# single-tenant deployments, so any previously cached token.json needs one-time re-consent.
GMAIL_OAUTH_SCOPES = [
    "https://mail.google.com/",
    "https://www.googleapis.com/auth/userinfo.email",
]

# Force UTF-8 stdout/stderr on Windows so emojis and zero-width chars in emails
# don't crash json.dumps output with cp1252 UnicodeEncodeError.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ATTACHMENT_CACHE = Path(__file__).resolve().parent / ".cache" / "email-att"
ATTACHMENT_CACHE.mkdir(parents=True, exist_ok=True)


def _default_path(env_var: str, filename: str, user_id: str | int | None = None) -> Path:
    # An explicit env override always wins verbatim — that's the single-tenant/local-dev
    # escape hatch (D4/D8 in the plan) and must not be silently re-nested per user.
    override = os.environ.get(env_var)
    if override:
        return Path(override).expanduser()
    base = Path.home() / ".hermes" / "mail"
    if user_id is not None:
        base = base / str(user_id)
    return base / filename


def _credentials_path() -> Path:
    # The OAuth *client* secret identifies the app registered with Google — legitimately
    # shared infrastructure, never per-user (contrast with _token_path below).
    return _default_path("GMAIL_CREDENTIALS_PATH", "credentials.json")


def _token_path(user_id: str | int | None = None) -> Path:
    return _default_path("GMAIL_TOKEN_PATH", "token.json", user_id)


def _meta_path(user_id: str | int | None = None) -> Path:
    """Sibling of the token file: caches the mailbox address discovered from the OAuth grant
    itself, since a per-user deployment has no static EMAIL_EMAIL to read instead."""
    return _token_path(user_id).with_name("meta.json")


def _fetch_gmail_address(creds) -> str | None:
    import requests

    try:
        resp = requests.get(
            "https://www.googleapis.com/oauth2/v2/userinfo",
            headers={"Authorization": f"Bearer {creds.token}"},
            timeout=10,
        )
        resp.raise_for_status()
        email = resp.json().get("email")
        return email if isinstance(email, str) else None
    except Exception:
        return None


def _connected_at(user_id: str | int | None = None) -> int | None:
    """Unix time of the last successful consent, recorded by brain/oauth_flow.py.

    Surfaced so the UI can warn *before* the ~7-day refresh-token expiry rather than only
    reporting failure once it has already bitten.
    """
    meta_path = _meta_path(user_id)
    if not meta_path.exists():
        return None
    try:
        value = json.loads(meta_path.read_text(encoding="utf-8")).get("connected_at")
        return int(value) if isinstance(value, (int, float)) else None
    except Exception:
        return None


def _mailbox_email(user_id: str | int | None = None) -> str | None:
    """The mailbox address to log into IMAP as. Per-user: read from the cached OAuth
    discovery (_meta_path). Legacy/global (user_id=None): the static EMAIL_EMAIL env var."""
    if user_id is None:
        return os.environ.get("EMAIL_EMAIL")
    meta_path = _meta_path(user_id)
    if not meta_path.exists():
        return None
    try:
        email = json.loads(meta_path.read_text(encoding="utf-8")).get("email")
        return email if isinstance(email, str) else None
    except Exception:
        return None


class ReconnectRequired(RuntimeError):
    """The stored grant is gone or unusable and only a fresh consent can fix it.

    Distinct from a generic error on purpose: on this project it is a *routine* state, not an
    exceptional one. The OAuth client is unverified and requests a restricted scope
    (https://mail.google.com/), so Google expires refresh tokens after 7 days — every user
    reconnects roughly weekly. Callers should render this as a "Reconnect" action, never as a
    crash. See brain/oauth_flow.py.
    """


def _load_oauth_credentials(user_id: str | int | None = None):
    """Load this user's stored credentials, refreshing them if needed.

    Consent is *not* handled here — it's a redirect flow owned by brain/oauth_flow.py. This
    function only ever reads and refreshes an existing grant, which is what makes it safe to
    call from a headless subprocess (emailtool runs that way during ingest).
    """
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials

    token_path = _token_path(user_id)
    if not token_path.exists():
        raise ReconnectRequired(f"No Gmail grant stored at {token_path} — connect Gmail first.")

    # Load with whatever scopes the token was actually granted, not the scopes we would
    # request today: refreshing a token with a wider set than it was issued for fails with
    # `invalid_scope`. userinfo.email is only needed to discover the mailbox address during
    # a fresh consent, so an older mail-only token stays perfectly usable for IMAP.
    creds = Credentials.from_authorized_user_file(str(token_path))
    if creds and creds.valid:
        return creds

    if not (creds and creds.refresh_token):
        raise ReconnectRequired("Stored Gmail grant has no refresh token — reconnect Gmail.")

    try:
        creds.refresh(Request())
    except Exception as exc:
        # invalid_grant is the expected weekly outcome, not a bug — see ReconnectRequired.
        raise ReconnectRequired(
            f"Gmail access expired or was revoked — reconnect Gmail. ({exc})"
        ) from exc

    # Owner-only (0o600): this file holds a live OAuth credential. write_text alone leaves the
    # platform default, often world-readable.
    fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(creds.to_json())
    return creds


def mailbox_status(user_id: str | int | None = None) -> dict[str, Any]:
    """Whether this user's mailbox can actually be authenticated as, not merely whether a file
    exists on disk.

    A token file can exist and still be useless — revoked, expired past refresh, or written by
    something that wasn't a real consent. Reporting "connected" off `Path.exists()` is how you
    end up with a UI claiming a connection that fails the moment mail is fetched, so this
    loads the credentials (refreshing if needed) and reports what went wrong when it can't.
    """
    if not _token_path(user_id).exists():
        return {"connected": False, "reason": "no mailbox connected yet"}
    try:
        creds = _load_oauth_credentials(user_id)
    except ReconnectRequired as exc:
        # Routine on this project (weekly refresh-token expiry) — flagged so the UI can offer
        # a Reconnect button instead of rendering it as a failure.
        return {"connected": False, "reason": str(exc), "needs_reconnect": True}
    except Exception as exc:  # malformed token file, unreadable path, …
        return {"connected": False, "reason": f"stored credentials are unusable: {exc}"}
    if not creds or not creds.valid:
        return {
            "connected": False,
            "reason": "stored credentials could not be refreshed",
            "needs_reconnect": True,
        }
    return {
        "connected": True,
        "email": _mailbox_email(user_id),
        "connected_at": _connected_at(user_id),
    }


def _oauth_login(
    conn: imaplib.IMAP4_SSL,
    user: str,
    user_id: str | int | None = None,
) -> None:
    creds = _load_oauth_credentials(user_id)
    auth_string = f"user={user}\1auth=Bearer {creds.token}\1\1"
    conn.authenticate("XOAUTH2", lambda _challenge: auth_string.encode("ascii"))


def _connect(user_id: str | int | None = None):
    host = os.environ.get("EMAIL_IMAP_HOST")
    port = int(os.environ.get("EMAIL_IMAP_PORT") or 993)
    # EMAIL_APP_PASSWORD is a single global mailbox login — only meaningful on the legacy
    # (no user_id) path; the multi-user path is OAuth-only (see D4 in the plan).
    pw = os.environ.get("EMAIL_APP_PASSWORD") if user_id is None else None
    user = _mailbox_email(user_id)
    if not (user and host):
        if user_id is not None:
            raise RuntimeError(
                "No Gmail account connected for this user yet. Run the OAuth connect flow "
                "first (POST /api/mail/connect)."
            )
        raise RuntimeError("Missing EMAIL_EMAIL / EMAIL_IMAP_HOST in .env.")

    conn = imaplib.IMAP4_SSL(host, port)
    if pw:
        conn.login(user, pw)
    else:
        _oauth_login(conn, user, user_id=user_id)
    conn.select("INBOX")
    return conn


def _safe_filename(name: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
    return name[:120] or "attachment.bin"


def _decode_part(part) -> str:
    payload = part.get_payload(decode=True)
    if payload is None:
        return ""
    charset = part.get_content_charset() or "utf-8"
    try:
        return payload.decode(charset, errors="replace")
    except LookupError:
        return payload.decode("utf-8", errors="replace")


def _extract_body(msg) -> str:
    if msg.is_multipart():
        plain_parts = []
        html_parts = []
        for part in msg.walk():
            ctype = part.get_content_type()
            disp = (part.get("Content-Disposition") or "").lower()
            if "attachment" in disp:
                continue
            if ctype == "text/plain":
                plain_parts.append(_decode_part(part))
            elif ctype == "text/html":
                html_parts.append(_decode_part(part))
        if plain_parts:
            return "\n".join(plain_parts).strip()
        # Strip tags crudely if only HTML is available
        if html_parts:
            text = "\n".join(html_parts)
            text = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", text, flags=re.S | re.I)
            text = re.sub(r"<[^>]+>", " ", text)
            text = re.sub(r"\s+", " ", text).strip()
            return text
        return ""
    return _decode_part(msg).strip()


def _save_attachments(uid: str, msg):
    out = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        disp = (part.get("Content-Disposition") or "").lower()
        filename = part.get_filename()
        if "attachment" not in disp and not filename:
            continue
        if not filename:
            filename = "attachment.bin"
        safe = _safe_filename(filename)
        path = ATTACHMENT_CACHE / f"{uid}__{safe}"
        try:
            data = part.get_payload(decode=True)
            if data:
                path.write_bytes(data)
                out.append(
                    {
                        "filename": filename,
                        "content_type": part.get_content_type(),
                        "saved_to": str(path),
                        "size_bytes": len(data),
                    }
                )
        except Exception as e:
            out.append({"filename": filename, "error": str(e)})
    return out


def cmd_list(since_minutes: int | None = None, user_id: str | None = None):
    cutoff = None
    if since_minutes is not None:
        cutoff = datetime.now(UTC) - timedelta(minutes=since_minutes)

    conn = _connect(user_id=user_id)
    try:
        # IMAP SINCE only has day granularity, so it's a coarse prefilter (avoids fetching a
        # whole old unread backlog) — the precise per-message Date check below does the rest.
        if cutoff is not None:
            since_date = cutoff.strftime("%d-%b-%Y")
            typ, data = conn.uid("search", None, f'(UNSEEN SINCE "{since_date}")')
        else:
            typ, data = conn.uid("search", None, "UNSEEN")
        if typ != "OK":
            raise RuntimeError(f"IMAP search failed: {typ} {data}")
        uids = data[0].split()
        results = []
        for uid_bytes in uids:
            uid = uid_bytes.decode("ascii")
            typ, msg_data = conn.uid("fetch", uid_bytes, "(BODY.PEEK[])")
            if typ != "OK" or not msg_data or msg_data[0] is None:
                continue
            raw = msg_data[0][1]
            msg = email.message_from_bytes(raw, policy=email.policy.default)
            if cutoff is not None:
                try:
                    msg_date = email.utils.parsedate_to_datetime(str(msg.get("Date", "")))
                    if msg_date.tzinfo is None:
                        msg_date = msg_date.replace(tzinfo=UTC)
                except (TypeError, ValueError):
                    continue
                if msg_date < cutoff:
                    continue
            results.append(
                {
                    "uid": uid,
                    "from": str(msg.get("From", "")),
                    "to": str(msg.get("To", "")),
                    "subject": str(msg.get("Subject", "")),
                    "date": str(msg.get("Date", "")),
                    "body_text": _extract_body(msg),
                    "attachments": _save_attachments(uid, msg),
                    # This message's own id, and what it's a reply to (if anything) — real,
                    # mechanical reply-chain identity from the mail client itself, not a guess.
                    # Empty for a forward (a forward starts a fresh Message-ID chain) or a
                    # message with no thread history, which is the correct, honest result.
                    "message_id": str(msg.get("Message-ID", "") or ""),
                    "in_reply_to": str(msg.get("In-Reply-To", "") or ""),
                    "references": str(msg.get("References", "") or ""),
                }
            )
        print(json.dumps(results, ensure_ascii=False))
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def cmd_mark_read(uid: str, user_id: str | None = None):
    conn = _connect(user_id=user_id)
    try:
        typ, _ = conn.uid("store", uid.encode("ascii"), "+FLAGS", "(\\Seen)")
        if typ != "OK":
            raise RuntimeError(f"IMAP STORE failed for uid {uid}: {typ}")
        print(json.dumps({"uid": uid, "marked_read": True}))
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def cmd_auth(user_id: str | None = None):
    """Report the stored grant. Consent itself is no longer a CLI concern: it is a browser
    redirect flow served by the brain API (see brain/oauth_flow.py), because a consent window
    opened on the server only ever worked when the server *was* your laptop."""
    status = mailbox_status(user_id)
    if not status.get("connected"):
        raise RuntimeError(
            f"{status.get('reason', 'not connected')} — connect Gmail from the console "
            "(Integrations -> Gmail), which opens Google consent in your own browser."
        )
    print(
        json.dumps({"authenticated": status.get("email"), "token_path": str(_token_path(user_id))})
    )


def main():
    usage = (
        "usage: emailtool.py list [--since-minutes N] [--user-id ID] | "
        "mark-read <uid> [--user-id ID] | auth [--user-id ID]"
    )
    argv = sys.argv[1:]
    user_id: str | None = None
    if "--user-id" in argv:
        idx = argv.index("--user-id")
        if idx + 1 >= len(argv):
            print(usage, file=sys.stderr)
            sys.exit(2)
        user_id = argv[idx + 1]
        del argv[idx : idx + 2]
    if not argv:
        print(usage, file=sys.stderr)
        sys.exit(2)
    mode = argv[0]
    try:
        if mode == "list":
            since_minutes = None
            if "--since-minutes" in argv:
                idx = argv.index("--since-minutes")
                if idx + 1 >= len(argv):
                    print(usage, file=sys.stderr)
                    sys.exit(2)
                since_minutes = int(argv[idx + 1])
            cmd_list(since_minutes, user_id=user_id)
        elif mode == "mark-read" and len(argv) >= 2:
            cmd_mark_read(argv[1], user_id=user_id)
        elif mode == "auth":
            cmd_auth(user_id=user_id)
        else:
            print(usage, file=sys.stderr)
            sys.exit(2)
    except Exception as e:
        print(json.dumps({"error": str(e), "type": type(e).__name__}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
