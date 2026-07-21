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


def send_ops_alert(subject: str, body: str) -> bool:
    """Sends an internal ops alert (plan 15, Phase F) to OPS_ALERT_EMAIL via the
    same Resend client — e.g. "a source stopped returning data".

    Deliberately the INVERSE of send_followup_email's contract: it never raises.
    A follow-up send is a user action that just failed and must surface; an ops
    alert fires from inside the daily cron, where a raise would sink the very
    pipeline run the alert is trying to report on. So every failure mode
    (no recipient, no Resend key, API error) logs and returns False — the alert
    is best-effort by design.

    Returns True only when an email was actually handed to Resend.
    """
    if not settings.ops_alert_email:
        # No ops mailbox configured → health is still logged to the DB, we just
        # can't email it. Not an error, same as a blank RESEND_API_KEY.
        logger.warning("Ops alert not sent (OPS_ALERT_EMAIL unset): %s", subject)
        return False
    try:
        _ensure_configured()
    except EmailSendError as e:
        logger.warning("Ops alert not sent (%s): %s", e, subject)
        return False
    try:
        resend.Emails.send(
            {
                "from": settings.resend_from_email,
                "to": [settings.ops_alert_email],
                "subject": subject,
                "text": body,
            }
        )
    except Exception:
        logger.exception("Ops alert send failed: %s", subject)
        return False
    return True
