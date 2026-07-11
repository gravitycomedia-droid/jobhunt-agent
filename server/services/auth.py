from fastapi import Depends, Header, HTTPException
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token

from config import settings
from db.supabase_client import supabase


def get_current_user_id(authorization: str | None = Header(default=None)) -> str:
    """Brick 9: verifies the Supabase session JWT the Flutter app sends as
    `Authorization: Bearer <access_token>` after Google sign-in. Delegates
    verification to Supabase's own Auth API (`auth.get_user`) rather than
    decoding the JWT locally — one network round-trip per request, but no
    JWT secret to manage or rotate server-side, and it's automatically
    correct if Supabase ever rotates signing keys.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or malformed Authorization header")

    token = authorization.removeprefix("Bearer ").strip()
    try:
        response = supabase.auth.get_user(token)
    except Exception as e:
        raise HTTPException(status_code=401, detail="Invalid or expired session") from e

    if response is None or response.user is None:
        raise HTTPException(status_code=401, detail="Invalid or expired session")
    return response.user.id


def get_current_profile(user_id: str = Depends(get_current_user_id)) -> dict:
    """Requires an existing profile row for the authenticated user — same
    404 contract routers relied on pre-auth ("No profile found — upload a
    resume first"), just scoped per-user instead of assuming a single
    global row. POST /resume/parse is the only place a profile gets
    created; every other endpoint reads through here.
    """
    rows = supabase.table("profiles").select("*").eq("user_id", user_id).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="No profile found — upload a resume first")
    return rows[0]


def verify_pipeline_cron(
    x_pipeline_secret: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    """Guards POST /pipeline/run (Brick 9) — no per-user session to check
    a cron job against, so this route skips get_current_user_id entirely.
    Accepts either the original shared-secret header (Render's cron) or a
    Google-signed OIDC bearer token (Cloud Scheduler, Cloud Run migration)
    so both crons can trigger it during the cutover; drop the secret path
    once Render is decommissioned.
    """
    if settings.pipeline_secret and x_pipeline_secret == settings.pipeline_secret:
        return
    if _verify_scheduler_oidc(authorization):
        return
    raise HTTPException(status_code=401, detail="Invalid or missing pipeline credentials")


def _verify_scheduler_oidc(authorization: str | None) -> bool:
    if not authorization or not authorization.startswith("Bearer "):
        return False
    if not settings.pipeline_oidc_service_account or not settings.pipeline_oidc_audience:
        return False
    token = authorization.removeprefix("Bearer ").strip()
    try:
        claims = google_id_token.verify_oauth2_token(
            token, google_requests.Request(), audience=settings.pipeline_oidc_audience
        )
    except Exception:
        return False
    return claims.get("email") == settings.pipeline_oidc_service_account and claims.get("email_verified") is True
