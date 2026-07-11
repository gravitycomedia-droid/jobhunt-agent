from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
from slugify import slugify

from config import settings
from db.supabase_client import supabase
from services.auth import get_current_profile
from services.background_tasks import create_task, run_task
from services.guardrail import compute_gaps, verify_bullets, verify_skills
from services.llm import LlmApiError, TailorError, tailor_resume
from services.resume_pdf import compile_ats_pdf

router = APIRouter(prefix="/tailor", tags=["tailor"])


class ApproveTailorRequest(BaseModel):
    """Frontend rebuild Phase 2: per-bullet accept/reject, one bool per
    bullet in the same order as `tailored_resumes.bullets`. Optional and
    backward compatible — omitting it (or sending `{}`) keeps the original
    Brick 6 behavior of a single global approve, defaulting each bullet's
    `accepted` to whether it passed the guardrail."""

    accepted: list[bool] | None = None


def _flatten_bullets(profile: dict) -> list[str]:
    bullets: list[str] = []
    for exp in profile.get("experience") or []:
        bullets.extend(exp.get("bullets") or [])
    return bullets


def tailor_and_store(profile: dict, job_id: str) -> dict:
    """Brick 6 core: tailor the stored resume's bullets toward one job, run
    every bullet through the anti-fabrication guardrail (ADR-004), store the
    result — unapproved — for the diff view. Raises HTTPException with a
    human-readable detail; run_task() surfaces that detail when this runs
    as a background task."""
    job_rows = supabase.table("jobs").select("*").eq("id", job_id).limit(1).execute().data
    if not job_rows:
        raise HTTPException(status_code=404, detail="Job not found")
    job = job_rows[0]

    bullets = _flatten_bullets(profile)
    if not bullets:
        raise HTTPException(status_code=422, detail="Stored profile has no experience bullets to tailor")

    # JD-paste resume builder jobs (routers/jobs.py's `from-jd` flow) run on
    # the cheap tier end-to-end (ADR-017) — this is the only place that
    # decides that, so every OTHER caller of tailor_and_store (matched
    # jobs, Add Job) is unaffected and keeps using settings.gemini_model.
    model = settings.gemini_model_lite if job.get("source") == "jd_paste" else None
    skills = profile.get("skills") or []
    try:
        llm_response = tailor_resume(
            bullets,
            job.get("description") or "",
            profile_id=profile["id"],
            model=model,
            skills=skills,
            headline=profile.get("headline") or "",
        )
    except TailorError as e:
        raise HTTPException(status_code=422, detail=f"Could not tailor resume: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Resume tailor is temporarily unavailable: {e}") from e

    raw_resume_text = profile.get("raw_resume_text") or ""
    verified_bullets = verify_bullets(llm_response.tailored_bullets, raw_resume_text)
    guardrail_flags = sum(1 for b in verified_bullets if not b["guardrail_pass"])

    analysis = llm_response.analysis
    # ADR-019: the LLM's skill reordering is intersected back to real skills
    # (never a source of new skills), and the gap check is computed in Python —
    # both enforcement steps, not prompt promises (Golden Rule 2/4).
    skills_ordered = verify_skills(llm_response.skills_ordered, skills)
    gaps = compute_gaps(analysis.hard_requirements, skills, raw_resume_text)

    stored_analysis = {
        "role_type": analysis.role_type,
        "culture_signal": analysis.culture_signal,
        "jd_title": analysis.jd_title,
        "summary_line": analysis.summary_line,
        "hard_requirements": analysis.hard_requirements,
        "skills_ordered": skills_ordered,
    }

    row = (
        supabase.table("tailored_resumes")
        .insert(
            {
                "profile_id": profile["id"],
                "job_id": job_id,
                "bullets": verified_bullets,
                "guardrail_flags": guardrail_flags,
                "approved": False,
                "analysis": stored_analysis,
                "gaps": gaps,
            }
        )
        .execute()
        .data[0]
    )
    return row


@router.post("/{job_id}", status_code=202)
async def tailor(job_id: str, background: BackgroundTasks, profile: dict = Depends(get_current_profile)):
    """Brick 6 endpoint, now ADR-011-shaped: one Gemini tailoring call runs
    20-60s — too long to hold a mobile connection — so this returns 202 +
    a task id and the client polls GET /tasks/{id}, then reads the stored
    result back via GET /tailor/{job_id}. Nothing here submits an
    application; that's a separate, explicit human action (Golden Rule:
    no auto-submitting anywhere).
    """
    task = create_task(profile["id"], "tailor")
    background.add_task(run_task, task["id"], lambda: tailor_and_store(profile, job_id))
    return {"data": {"task_id": task["id"]}, "error": None}


@router.get("/{job_id}")
async def get_tailored(job_id: str, profile: dict = Depends(get_current_profile)):
    """Reads back the most recent tailored resume for this job, if any."""
    rows = (
        supabase.table("tailored_resumes")
        .select("*")
        .eq("profile_id", profile["id"])
        .eq("job_id", job_id)
        .order("created_at", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return {"data": rows[0] if rows else None, "error": None}


@router.get("/{tailored_resume_id}/pdf")
async def tailored_resume_pdf(tailored_resume_id: str, profile: dict = Depends(get_current_profile)):
    """Phase 4B: compiles the accepted bullets + stored profile into a
    single-column, ATS-friendly PDF (services/resume_pdf.py — deterministic
    Python, no LLM call).

    Envelope exception: this endpoint returns raw `application/pdf` bytes,
    not the usual `{"data": ..., "error": null}` JSON — a binary body can't
    carry the envelope. Errors still raise HTTPException (JSON) as normal.
    """
    rows = supabase.table("tailored_resumes").select("*").eq("id", tailored_resume_id).limit(1).execute().data
    # Same ownership-as-404 posture as the approve endpoint below.
    if not rows or rows[0]["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Tailored resume not found")

    pdf_bytes = compile_ats_pdf(profile, rows[0])
    filename = f"{slugify(profile.get('name') or 'resume')}-resume.pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.patch("/{tailored_resume_id}/approve")
async def approve_tailored(
    tailored_resume_id: str,
    body: ApproveTailorRequest | None = None,
    profile: dict = Depends(get_current_profile),
):
    """The human approval gate: nothing downstream (Brick 7's applications)
    should use a tailored resume until the user has explicitly reviewed the
    diff and approved it here, guardrail flags included. Frontend rebuild
    Phase 2: also records each bullet's accept/reject choice — the tailored
    resume preview (ResumePreviewScreen) reads `accepted` to decide which
    text to render per bullet.
    """
    existing = supabase.table("tailored_resumes").select("*").eq("id", tailored_resume_id).limit(1).execute().data
    if not existing:
        raise HTTPException(status_code=404, detail="Tailored resume not found")
    # Brick 9: verify ownership before letting the caller approve someone
    # else's tailored resume — see the same check in routers/applications.py.
    if existing[0]["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Tailored resume not found")

    bullets = existing[0]["bullets"]
    if body is not None and body.accepted is not None:
        if len(body.accepted) != len(bullets):
            raise HTTPException(status_code=422, detail="accepted must have one entry per bullet")
        for bullet, accepted in zip(bullets, body.accepted):
            bullet["accepted"] = accepted
    else:
        for bullet in bullets:
            bullet.setdefault("accepted", bullet["guardrail_pass"])

    row = (
        supabase.table("tailored_resumes")
        .update({"approved": True, "bullets": bullets})
        .eq("id", tailored_resume_id)
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}
