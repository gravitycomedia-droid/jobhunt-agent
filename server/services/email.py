import logging

import resend

from config import settings

logger = logging.getLogger("jobhunt.email")

_configured = False


class EmailSendError(Exception):
    """Raised on any failure to send — unlike notify.py's push path, a
    follow-up send is a synchronous action the user just explicitly
    approved, so failures must surface to the caller instead of being
    logged and swallowed."""


def _ensure_configured() -> None:
    global _configured
    if _configured:
        return
    if not settings.resend_api_key:
        raise EmailSendError("Resend is not configured yet (no RESEND_API_KEY) — set it in server/.env")
    resend.api_key = settings.resend_api_key
    _configured = True


def send_followup_email(*, to: str, subject: str, body: str) -> None:
    """Sends a follow-up email via Resend. Raises EmailSendError on any
    failure — missing config, invalid recipient, or a Resend API error —
    so POST /applications/{id}/followup/send can turn it into a clear 502
    rather than silently reporting success."""
    _ensure_configured()
    try:
        resend.Emails.send(
            {
                "from": settings.resend_from_email,
                "to": [to],
                "subject": subject,
                "text": body,
            }
        )
    except Exception as e:
        logger.exception("Resend send failed")
        raise EmailSendError(str(e)) from e
