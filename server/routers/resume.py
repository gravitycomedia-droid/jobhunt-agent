import io

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pdf2image import convert_from_bytes
from pydantic import BaseModel
from pypdf import PdfReader

from db.supabase_client import supabase
from models.resume import ResumeProfile, ResumeProfileUpdate
from services.auth import get_current_profile, get_current_user_id
from services.embeddings import embed_text, profile_embedding_text
from services.llm import LlmApiError, ResumeParseError, parse_resume

router = APIRouter(prefix="/resume", tags=["resume"])


class FcmTokenUpdate(BaseModel):
    fcm_token: str


class TargetRolesUpdate(BaseModel):
    target_roles: list[str]
    min_salary: float | None = None


class NotificationPrefsUpdate(BaseModel):
    alerts: bool
    followup_nudge: bool


def _page_to_png_bytes(page_image) -> bytes:
    buf = io.BytesIO()
    page_image.save(buf, format="PNG")
    return buf.getvalue()


def _extract_raw_text(pdf_bytes: bytes) -> str:
    reader = PdfReader(io.BytesIO(pdf_bytes))
    return "\n".join(page.extract_text() or "" for page in reader.pages)


def _upsert_profile(user_id: str, profile: ResumeProfile, raw_text: str) -> dict:
    payload = {
        "user_id": user_id,
        "name": profile.name,
        "headline": profile.headline,
        "skills": profile.skills,
        "experience": [e.model_dump() for e in profile.experience],
        "projects": [p.model_dump() for p in profile.projects],
        "education": [ed.model_dump() for ed in profile.education],
        "raw_resume_text": raw_text,
    }
    payload["embedding"] = embed_text(profile_embedding_text(payload))
    # Brick 9: one profile row per authenticated user — was "the one global
    # row" pre-auth (see DECISIONS.md ADR-008).
    existing = supabase.table("profiles").select("id").eq("user_id", user_id).limit(1).execute()
    if existing.data:
        profile_id = existing.data[0]["id"]
        result = supabase.table("profiles").update(payload).eq("id", profile_id).execute()
    else:
        result = supabase.table("profiles").insert(payload).execute()
    return result.data[0]


@router.post("/parse")
async def parse_resume_endpoint(file: UploadFile = File(...), user_id: str = Depends(get_current_user_id)):
    if file.content_type != "application/pdf":
        raise HTTPException(status_code=400, detail="Only PDF uploads are supported")

    pdf_bytes = await file.read()
    raw_text = _extract_raw_text(pdf_bytes)
    page_images = [_page_to_png_bytes(img) for img in convert_from_bytes(pdf_bytes)]

    try:
        profile = parse_resume(page_images)
    except ResumeParseError as e:
        raise HTTPException(status_code=422, detail=f"Could not parse resume: {e}")
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Resume parser is temporarily unavailable: {e}")

    row = _upsert_profile(user_id, profile, raw_text)
    return {"data": row, "error": None}


@router.get("/profile")
async def get_my_profile(user_id: str = Depends(get_current_user_id)):
    """The caller's own profile, or null if they haven't uploaded a resume
    yet. Soft-missing (not a 404) — used by PushService to discover the
    profile id for FCM registration, which should silently no-op pre-resume
    rather than error."""
    rows = supabase.table("profiles").select("*").eq("user_id", user_id).limit(1).execute().data
    return {"data": rows[0] if rows else None, "error": None}


@router.patch("/profile")
async def update_my_profile(update: ResumeProfileUpdate, profile: dict = Depends(get_current_profile)):
    payload = update.model_dump(exclude_unset=True)

    # Re-embed from the merged (existing + edited) fields, not just the ones
    # this PATCH touched — the embedding has to reflect the whole profile.
    merged = {**profile, **payload}
    payload["embedding"] = embed_text(profile_embedding_text(merged), profile_id=profile["id"])

    result = supabase.table("profiles").update(payload).eq("id", profile["id"]).execute()
    return {"data": result.data[0], "error": None}


@router.patch("/profile/fcm-token")
async def update_fcm_token(body: FcmTokenUpdate, profile: dict = Depends(get_current_profile)):
    """Brick 8: registers this device's FCM token so the agent loop can
    push to it (services/notify.py). Deliberately separate from PATCH
    /resume/profile — that endpoint re-embeds the whole profile on every
    call, which a token refresh has no business triggering.
    """
    result = supabase.table("profiles").update({"fcm_token": body.fcm_token}).eq("id", profile["id"]).execute()
    return {"data": result.data[0], "error": None}


@router.patch("/profile/target-roles")
async def update_target_roles(body: TargetRolesUpdate, profile: dict = Depends(get_current_profile)):
    """Onboarding (frontend rebuild Phase 1): the roles/min-salary the agent
    should match against. Deliberately separate from PATCH /resume/profile
    for the same reason as fcm-token — a preferences update has no business
    triggering a profile re-embed. Not yet wired into daily_pipeline.py's
    job-fetch step, which still reads the global TARGET_ROLES env var — see
    DECISIONS.md for that gap.
    """
    result = (
        supabase.table("profiles")
        .update({"target_roles": body.target_roles, "min_salary": body.min_salary})
        .eq("id", profile["id"])
        .execute()
    )
    return {"data": result.data[0], "error": None}


@router.patch("/profile/notification-prefs")
async def update_notification_prefs(body: NotificationPrefsUpdate, profile: dict = Depends(get_current_profile)):
    """Phase 4 Settings screen: gates the two calls jobs/daily_pipeline.py
    already makes unconditionally (send_push_notification, stale-follow-up
    drafting) — not new pipeline behavior, just an on/off switch. Same
    dedicated-endpoint pattern as fcm-token/target-roles.
    """
    result = (
        supabase.table("profiles")
        .update({"notification_prefs": {"alerts": body.alerts, "followup_nudge": body.followup_nudge}})
        .eq("id", profile["id"])
        .execute()
    )
    return {"data": result.data[0], "error": None}
