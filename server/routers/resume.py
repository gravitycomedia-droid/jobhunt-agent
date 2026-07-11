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


class OnboardingStepUpdate(BaseModel):
    step: str


# Phase 3B: the onboarding state machine, in code (Golden Rule 2 — states
# are never an LLM's call). Steps only ever move forward; a re-upload or
# an out-of-order PATCH can't bounce a finished user back into onboarding.
ONBOARDING_STEPS = ["welcome", "resume", "review", "roles", "done"]


def _advance_onboarding(profile_id: str, current: str | None, target: str) -> None:
    """Moves onboarding_step forward to `target` iff that's actually an
    advance from `current` (missing/unknown current counts as 'welcome')."""
    current_idx = ONBOARDING_STEPS.index(current) if current in ONBOARDING_STEPS else 0
    if ONBOARDING_STEPS.index(target) > current_idx:
        supabase.table("profiles").update({"onboarding_step": target}).eq("id", profile_id).execute()


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
    existing = supabase.table("profiles").select("id,onboarding_step").eq("user_id", user_id).limit(1).execute()
    if existing.data:
        # Phase 3B: a re-upload mid-onboarding advances to the review step,
        # but only forward — a done user re-uploading from the Profile tab
        # is never pulled back into onboarding.
        current = existing.data[0].get("onboarding_step")
        if current in ("welcome", "resume", None):
            payload["onboarding_step"] = "review"
        result = supabase.table("profiles").update(payload).eq("id", existing.data[0]["id"]).execute()
    else:
        # A brand-new profile is created BY the resume upload, so the user
        # has by definition completed welcome + resume — start at review.
        payload["onboarding_step"] = "review"
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
    # Phase 3B: saving the review during onboarding completes the review
    # step (forward-only — no-op for done users editing from Profile).
    _advance_onboarding(profile["id"], profile.get("onboarding_step"), "roles")
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
    # Phase 3B: target roles is onboarding's last input step — saving it
    # completes onboarding (forward-only; no-op for revisits from Profile).
    _advance_onboarding(profile["id"], profile.get("onboarding_step"), "done")
    return {"data": result.data[0], "error": None}


@router.patch("/profile/onboarding-step")
async def update_onboarding_step(body: OnboardingStepUpdate, profile: dict = Depends(get_current_profile)):
    """Phase 3B: explicit step advance for the skip buttons (ProfileReview
    skip → 'roles', TargetRoles skip → 'done'). Forward-only — the state
    machine in _advance_onboarding silently ignores backward requests, so
    a stale client can't regress a finished user.
    """
    if body.step not in ONBOARDING_STEPS:
        raise HTTPException(status_code=422, detail=f"Unknown onboarding step: {body.step}")
    _advance_onboarding(profile["id"], profile.get("onboarding_step"), body.step)
    row = supabase.table("profiles").select("*").eq("id", profile["id"]).limit(1).execute().data[0]
    return {"data": row, "error": None}


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
