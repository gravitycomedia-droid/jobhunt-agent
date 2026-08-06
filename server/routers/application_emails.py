"""Career-ops integration Brick 3 (docs/21-career-ops-integration-plan.md
§1.6, DECISIONS.md ADR-057): first-contact application/referral/cold email
drafts, distinct from routers/applications.py's follow-up (a 7-day-silence
nudge). Synchronous, not 202-plus-poll — a ~150-word single Gemini call is
the same shape as draft_followup below it, which has never needed the
202/background-task pattern tailoring and cover letters do."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from config import settings
from db.supabase_client import supabase
from models.application_email import EmailKind
from models.common import StrictModel
from services.auth import get_current_profile
from services.email import EmailSendError, send_application_email
from services.guardrail import build_source_context, verify_bullet_atoms
from services.llm import ApplicationEmailError, LlmApiError, generate_application_email
from services.rate_limit import enforce_rate_limit

router = APIRouter(prefix="/application-emails", tags=["application-emails"])


class DraftApplicationEmailRequest(StrictModel):
    kind: EmailKind


def _log_untraceable_atoms(profile_id: str, job_id: str, flagged_atoms: list[dict]) -> None:
    """Same diagnostic log (migration 025) as routers/tailor.py and
    routers/cover_letters.py use — best-effort, never gates drafting."""
    if not flagged_atoms:
        return
    try:
        supabase.table("guardrail_atom_log").insert(
            [{"profile_id": profile_id, "job_id": job_id, "atom": a["text"], "kind": a["kind"]} for a in flagged_atoms]
        ).execute()
    except Exception:  # noqa: BLE001 — diagnostic log, never gates drafting
        pass


def _owned_application(application_id: str, profile_id: str) -> dict:
    """Same ownership-as-404 posture as every other application_id lookup
    in this app (routers/applications.py) — a wrong-owner id looks
    identical to a missing one, no existence leak."""
    rows = supabase.table("applications").select("*").eq("id", application_id).limit(1).execute().data
    if not rows or rows[0]["profile_id"] != profile_id:
        raise HTTPException(status_code=404, detail="Application not found")
    return rows[0]


def draft_and_store_application_email(profile: dict, application_id: str, kind: str) -> dict:
    """The Brick 3 core, factored out from the route handler the same way
    tailor_and_store (routers/tailor.py) and
    generate_and_store_cover_letter (routers/cover_letters.py) are — plain
    sync function, directly unit-testable, no event loop required.

    Drafts ONE new email variant and inserts it — unlike follow-up's
    overwrite-in-place columns, every draft here is its own row (migration
    033's docstring explains why: a candidate reasonably wants more than
    one on file, redrafted for a different contact or kept as history)."""
    app = _owned_application(application_id, profile["id"])

    job_rows = supabase.table("jobs").select("*").eq("id", app["job_id"]).limit(1).execute().data
    if not job_rows:
        raise HTTPException(status_code=404, detail="Job not found")
    job = job_rows[0]

    experiences = profile.get("experience") or []
    bullets = [b for exp in experiences for b in (exp.get("bullets") or [])]
    projects = profile.get("projects") or []
    if not bullets and not projects:
        raise HTTPException(
            status_code=422,
            detail="PROFILE_INCOMPLETE: add work experience or at least one project to your profile before an application email can be drafted",
        )

    try:
        llm_response = generate_application_email(
            kind,
            bullets,
            projects,
            job.get("title") or "",
            job.get("company") or "",
            job.get("description") or "",
            profile_id=profile["id"],
            skills=profile.get("skills") or [],
            headline=profile.get("headline") or "",
        )
    except ApplicationEmailError as e:
        raise HTTPException(status_code=422, detail=f"Could not draft email: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Email drafting is temporarily unavailable: {e}") from e

    # Same atom-level guardrail as résumé bullets / cover letter paragraphs
    # (services/guardrail.py, ADR-033/056) — applied once to the whole body
    # since this is one short block, not several paragraphs to review
    # individually.
    ctx = build_source_context(profile)
    verdict = verify_bullet_atoms(llm_response.body, ctx)
    _log_untraceable_atoms(profile["id"], app["job_id"], verdict.flagged_atoms)

    row = (
        supabase.table("application_emails")
        .insert(
            {
                "application_id": application_id,
                "profile_id": profile["id"],
                "kind": kind,
                "subject": llm_response.subject,
                "body": llm_response.body,
                "guardrail_pass": verdict.guardrail_pass,
                "flagged_atoms": verdict.flagged_atoms,
            }
        )
        .execute()
        .data[0]
    )
    return row


@router.post(
    "/{application_id}",
    dependencies=[
        Depends(
            enforce_rate_limit(
                "application_email", settings.rate_limit_application_email, settings.rate_limit_window_seconds
            )
        )
    ],
)
async def draft_application_email(
    application_id: str, body: DraftApplicationEmailRequest, profile: dict = Depends(get_current_profile)
):
    row = draft_and_store_application_email(profile, application_id, body.kind)
    return {"data": row, "error": None}


@router.get("/{application_id}")
async def list_application_emails(application_id: str, profile: dict = Depends(get_current_profile)):
    """Every drafted variant for this application, newest first, plus a
    deterministic (Golden Rule 2 — computed here, not asked of the LLM)
    attachment checklist: whether a tailored résumé and/or an approved
    cover letter already exist for this job, so the review screen can tell
    the user what to actually attach before they hit send."""
    app = _owned_application(application_id, profile["id"])

    drafts = (
        supabase.table("application_emails")
        .select("*")
        .eq("application_id", application_id)
        .order("created_at", desc=True)
        .execute()
        .data
    )

    resume_rows = (
        supabase.table("tailored_resumes")
        .select("id")
        .eq("profile_id", profile["id"])
        .eq("job_id", app["job_id"])
        .limit(1)
        .execute()
        .data
    )
    cover_letter_rows = (
        supabase.table("cover_letters")
        .select("id")
        .eq("profile_id", profile["id"])
        .eq("job_id", app["job_id"])
        .limit(1)
        .execute()
        .data
    )

    return {
        "data": {
            "drafts": drafts,
            "attachments": {"resume": bool(resume_rows), "cover_letter": bool(cover_letter_rows)},
        },
        "error": None,
    }


@router.post("/{application_id}/{email_id}/send")
async def send_application_email_endpoint(application_id: str, email_id: str, profile: dict = Depends(get_current_profile)):
    """The "Approve & send" action — same posture as POST
    /applications/{id}/followup/send: requires a contact_email already set
    on the application, and the tap itself is the human approval gate
    (Golden Rule: no auto-submitting anywhere)."""
    app = _owned_application(application_id, profile["id"])
    if not app.get("contact_email"):
        raise HTTPException(status_code=422, detail="Add a contact email first")

    email_rows = (
        supabase.table("application_emails")
        .select("*")
        .eq("id", email_id)
        .eq("application_id", application_id)
        .limit(1)
        .execute()
        .data
    )
    if not email_rows:
        raise HTTPException(status_code=404, detail="Email draft not found")
    email = email_rows[0]

    try:
        send_application_email(to=app["contact_email"], subject=email["subject"], body=email["body"])
    except EmailSendError as e:
        raise HTTPException(status_code=502, detail=f"Could not send the email: {e}") from e

    row = (
        supabase.table("application_emails")
        .update({"sent_at": datetime.now(timezone.utc).isoformat()})
        .eq("id", email_id)
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}
