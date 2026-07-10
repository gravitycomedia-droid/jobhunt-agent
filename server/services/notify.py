import logging
import os

import firebase_admin
from firebase_admin import credentials, messaging

from config import settings

logger = logging.getLogger("jobhunt.notify")

_app: firebase_admin.App | None = None
_init_failed = False


def _get_app() -> firebase_admin.App | None:
    """Lazy-init so a missing/invalid service-account file doesn't crash
    import at server startup — it just disables push and logs instead
    (see DECISIONS.md ADR-007). Cached after the first attempt so a bad
    credential doesn't retry firebase_admin.initialize_app() on every call.
    """
    global _app, _init_failed
    if _app is not None or _init_failed:
        return _app

    if not os.path.exists(settings.fcm_service_account_path):
        _init_failed = True
        logger.warning("FCM_SERVICE_ACCOUNT_PATH not found at %s — push disabled", settings.fcm_service_account_path)
        return None

    try:
        cred = credentials.Certificate(settings.fcm_service_account_path)
        _app = firebase_admin.initialize_app(cred)
    except Exception:
        _init_failed = True
        logger.exception("Could not initialize Firebase Admin SDK — push disabled")
        return None
    return _app


def send_push_notification(title: str, body: str, *, token: str | None = None) -> None:
    """Sends an FCM push to one device token, or logs (rather than sends)
    when there's no token yet — either no profile has registered a device
    (Flutter side: firebase_messaging not wired in yet), or the Admin SDK
    itself couldn't initialize. A notification failure here should never
    take down the daily pipeline, so every failure mode logs and returns
    instead of raising.
    """
    if not token:
        logger.info("no device token registered — would notify: %s — %s", title, body)
        return

    app = _get_app()
    if app is None:
        logger.info("FCM unavailable — would notify: %s — %s", title, body)
        return

    message = messaging.Message(
        notification=messaging.Notification(title=title, body=body),
        token=token,
    )
    try:
        messaging.send(message, app=app)
    except Exception:
        logger.exception("FCM send failed")
