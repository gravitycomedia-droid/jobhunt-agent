from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from db.supabase_client import supabase
from models.application import ApplicationCreate, ApplicationStateUpdate
from services.auth import get_current_profile
from services.email import EmailSendError, send_followup_email
from services.llm import FollowupError, LlmApiError, generate_followup_draft

router = APIRouter(prefix="/applications", tags=["applications"])


@router.post("")
async def create_application(body: ApplicationCreate, profile: dict = Depends(get_current_profile)):
    """Adds a job to the Kanban tracker (Brick 7), defaulting to the
    'saved' stage. Idempotent per (profile, job) — re-saving an already
    tracked job returns the existing row rather than duplicating it, since
    there's no unique constraint on the table to enforce that server-side.
    """
    profile_id = profile["id"]

    job_rows = supabase.table("jobs").select("id").eq("id", body.job_id).limit(1).execute().data
    if not job_rows:
        raise HTTPException(status_code=404, detail="Job not found")

    existing = (
        supabase.table("applications")
        .select("*")
        .eq("profile_id", profile_id)
        .eq("job_id", body.job_id)
        .limit(1)
        .execute()
        .data
    )
    if existing:
        return {"data": existing[0], "error": None}

    row = (
        supabase.table("applications")
        .insert(
            {
                "profile_id": profile_id,
                "job_id": body.job_id,
                "resume_version_id": body.resume_version_id,
                "notes": body.notes,
            }
        )
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}


@router.get("")
async def list_applications(profile: dict = Depends(get_current_profile)):
    """All tracked applications for the caller's profile, job details
    joined in — what [ApplicationsScreen]'s Kanban board renders."""
    apps = (
        supabase.table("applications")
        .select("*")
        .eq("profile_id", profile["id"])
        .order("state_changed_at", desc=True)
        .execute()
        .data
    )
    if not apps:
        return {"data": [], "error": None}

    job_ids = list({a["job_id"] for a in apps})
    jobs = supabase.table("jobs").select("*").in_("id", job_ids).execute().data
    jobs_by_id = {j["id"]: j for j in jobs}

    merged = [{**a, "job": jobs_by_id.get(a["job_id"])} for a in apps]
    return {"data": merged, "error": None}


@router.patch("/{application_id}")
async def update_application(
    application_id: str, body: ApplicationStateUpdate, profile: dict = Depends(get_current_profile)
):
    """The Kanban drag action: moves an application to a new stage and/or
    updates its notes. `state_changed_at` only bumps when the stage
    actually changes, so it reflects "time in current stage" accurately."""
    existing = supabase.table("applications").select("*").eq("id", application_id).limit(1).execute().data
    if not existing:
        raise HTTPException(status_code=404, detail="Application not found")
    # Brick 9: with more than one beta user, application ids are no longer
    # implicitly scoped to "the" user — verify the caller actually owns
    # this row before letting them move or annotate it.
    if existing[0]["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Application not found")

    update: dict = {}
    if body.notes is not None:
        update["notes"] = body.notes
    if body.contact_email is not None:
        update["contact_email"] = body.contact_email
    if body.state is not None:
        update["state"] = body.state
        if body.state != existing[0]["state"]:
            update["state_changed_at"] = datetime.now(timezone.utc).isoformat()

    if not update:
        return {"data": existing[0], "error": None}

    row = supabase.table("applications").update(update).eq("id", application_id).execute().data[0]
    return {"data": row, "error": None}


@router.post("/{application_id}/followup")
async def draft_followup(application_id: str, profile: dict = Depends(get_current_profile)):
    """Frontend rebuild Phase 2: on-demand version of daily_pipeline.py's
    stale-application sweep, for one application the user explicitly asked
    about (from AppDetailScreen's "Draft a follow-up" button) — no 7-day
    staleness gate, since a human choosing to ask for a draft is itself the
    approval gate the automated sweep otherwise needs. Drafting only;
    nothing here sends anything (Golden Rule: no auto-submitting anywhere).
    """
    existing = supabase.table("applications").select("*").eq("id", application_id).limit(1).execute().data
    if not existing:
        raise HTTPException(status_code=404, detail="Application not found")
    app = existing[0]
    if app["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Application not found")

    job_rows = supabase.table("jobs").select("title,company").eq("id", app["job_id"]).limit(1).execute().data
    if not job_rows:
        raise HTTPException(status_code=404, detail="Job not found")
    job = job_rows[0]
    headline = profile.get("headline") or profile.get("name") or "a candidate"

    try:
        draft = generate_followup_draft(
            job_title=job["title"],
            company=job.get("company") or "the company",
            applied_date=app["state_changed_at"][:10],
            headline=headline,
            profile_id=profile["id"],
        )
    except FollowupError as e:
        raise HTTPException(status_code=422, detail=f"Could not draft a follow-up: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Follow-up drafting is temporarily unavailable: {e}") from e

    row = (
        supabase.table("applications")
        .update(
            {
                "followup_subject": draft.subject,
                "followup_body": draft.body,
                "followup_drafted_at": datetime.now(timezone.utc).isoformat(),
            }
        )
        .eq("id", application_id)
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}


@router.post("/{application_id}/followup/send")
async def send_followup(application_id: str, profile: dict = Depends(get_current_profile)):
    """Phase 4: the "Approve & send" action — the one place in this app
    that actually sends anything external. Requires both an existing draft
    and a contact_email set beforehand; the tap itself is the human
    approval gate (Golden Rule: no auto-submitting anywhere)."""
    existing = supabase.table("applications").select("*").eq("id", application_id).limit(1).execute().data
    if not existing:
        raise HTTPException(status_code=404, detail="Application not found")
    app = existing[0]
    if app["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Application not found")

    if not app.get("followup_subject") or not app.get("followup_body"):
        raise HTTPException(status_code=422, detail="Draft a follow-up first")
    if not app.get("contact_email"):
        raise HTTPException(status_code=422, detail="Add a contact email first")

    try:
        send_followup_email(to=app["contact_email"], subject=app["followup_subject"], body=app["followup_body"])
    except EmailSendError as e:
        raise HTTPException(status_code=502, detail=f"Could not send the follow-up: {e}") from e

    row = (
        supabase.table("applications")
        .update({"followup_sent_at": datetime.now(timezone.utc).isoformat()})
        .eq("id", application_id)
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}
