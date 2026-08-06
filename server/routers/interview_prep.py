"""Career-ops integration Brick 4 (docs/21-career-ops-integration-plan.md
§1.2, DECISIONS.md ADR-058): two independent surfaces sharing one router —

- POST /interview-prep/{application_id}: generates a disposable, per-job
  interview pack. Nothing here is stored (migration 034's docstring
  explains why) — cheap enough to just regenerate on request.
- /interview-stories: CRUD for the persistent story bank a candidate
  builds up across every job they prep for, independent of any one pack.
"""

from fastapi import APIRouter, Depends, HTTPException

from config import settings
from db.supabase_client import supabase
from models.interview_story import InterviewStoryCreate, InterviewStoryUpdate
from services.auth import get_current_profile
from services.guardrail import build_source_context, verify_bullet_atoms
from services.llm import InterviewPrepError, LlmApiError, generate_interview_pack
from services.rate_limit import enforce_rate_limit

router = APIRouter(tags=["interview-prep"])


def _log_untraceable_atoms(profile_id: str, job_id: str | None, flagged_atoms: list[dict]) -> None:
    """Same diagnostic log (migration 025) as every other generative brick
    — best-effort, never gates the pack from being returned."""
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
    in this app."""
    rows = supabase.table("applications").select("*").eq("id", application_id).limit(1).execute().data
    if not rows or rows[0]["profile_id"] != profile_id:
        raise HTTPException(status_code=404, detail="Application not found")
    return rows[0]


def generate_pack_for_application(profile: dict, application_id: str) -> dict:
    """Brick 4 core, same sync-core-plus-thin-endpoint convention as
    tailor_and_store / generate_and_store_cover_letter /
    draft_and_store_application_email. Returns a plain dict; nothing here
    writes a row — see this module's own docstring for why a pack is
    disposable while a saved story (below) persists."""
    app = _owned_application(application_id, profile["id"])

    job_rows = supabase.table("jobs").select("*").eq("id", app["job_id"]).limit(1).execute().data
    if not job_rows:
        raise HTTPException(status_code=404, detail="Job not found")
    job = job_rows[0]

    # Best-effort: a manually-added job (Add Job / JD-paste builder) may
    # have no cached match row at all. Gaps/strengths are then simply
    # empty — the prompt still works fine off the JD text and profile
    # alone (INTERVIEW_PREP_SYSTEM_PROMPT handles an empty gaps list).
    match_rows = (
        supabase.table("matches")
        .select("gaps,strengths")
        .eq("profile_id", profile["id"])
        .eq("job_id", app["job_id"])
        .limit(1)
        .execute()
        .data
    )
    gaps = (match_rows[0].get("gaps") or []) if match_rows else []
    strengths = (match_rows[0].get("strengths") or []) if match_rows else []

    experiences = profile.get("experience") or []
    bullets = [b for exp in experiences for b in (exp.get("bullets") or [])]
    projects = profile.get("projects") or []
    if not bullets and not projects:
        raise HTTPException(
            status_code=422,
            detail="PROFILE_INCOMPLETE: add work experience or at least one project to your profile before an interview pack can be prepared",
        )

    try:
        llm_response = generate_interview_pack(
            job.get("title") or "",
            job.get("company") or "",
            job.get("description") or "",
            gaps,
            strengths,
            bullets,
            projects,
            profile_id=profile["id"],
            skills=profile.get("skills") or [],
            headline=profile.get("headline") or "",
        )
    except InterviewPrepError as e:
        raise HTTPException(status_code=422, detail=f"Could not prepare interview pack: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Interview prep is temporarily unavailable: {e}") from e

    # Same atom-level guardrail as résumé bullets / cover letter paragraphs
    # / application emails (services/guardrail.py, Golden Rule 4) — applied
    # once per question, over the concatenated STAR fields, since that's
    # the unit a user would save as one story.
    ctx = build_source_context(profile)
    questions = []
    for q in llm_response.questions:
        # Checked field-by-field, not joined into one block: each STAR field
        # is its own sentence, and verify_bullet_atoms' proper-noun pass
        # deliberately skips a sentence's FIRST word (ordinary capitalization,
        # not a name signal) — joining four sentences into one string would
        # make three of those first words look mid-sentence and wrongly
        # flaggable. Flags from every field are pooled onto the one question.
        flagged_atoms: list[dict] = []
        for field_text in (q.situation, q.task, q.action, q.result):
            if not field_text:
                continue
            flagged_atoms.extend(verify_bullet_atoms(field_text, ctx).flagged_atoms)
        if flagged_atoms:
            _log_untraceable_atoms(profile["id"], app["job_id"], flagged_atoms)
        questions.append(
            {
                "question": q.question,
                "category": q.category,
                "inferred": q.inferred,
                "situation": q.situation,
                "task": q.task,
                "action": q.action,
                "result": q.result,
                "guardrail_pass": not flagged_atoms,
                "flagged_atoms": flagged_atoms,
            }
        )
    return {"job_id": app["job_id"], "questions": questions}


@router.post(
    "/interview-prep/{application_id}",
    dependencies=[
        Depends(
            enforce_rate_limit(
                "interview_prep", settings.rate_limit_interview_prep, settings.rate_limit_window_seconds
            )
        )
    ],
)
async def draft_interview_pack(application_id: str, profile: dict = Depends(get_current_profile)):
    result = generate_pack_for_application(profile, application_id)
    return {"data": result, "error": None}


# ---------------------------------------------------------------------------
# Story bank (migration 034) — persistent, independent of any one pack.
# Plain CRUD, no LLM involved, so no rate limit (same posture as
# updateApplicationNotes/updateApplicationContactEmail elsewhere).
# ---------------------------------------------------------------------------


@router.get("/interview-stories")
async def list_stories(profile: dict = Depends(get_current_profile)):
    rows = (
        supabase.table("interview_stories")
        .select("*")
        .eq("profile_id", profile["id"])
        .order("created_at", desc=True)
        .execute()
        .data
    )
    return {"data": rows, "error": None}


@router.post("/interview-stories")
async def create_story(body: InterviewStoryCreate, profile: dict = Depends(get_current_profile)):
    row = (
        supabase.table("interview_stories")
        .insert(
            {
                "profile_id": profile["id"],
                "situation": body.situation,
                "task": body.task,
                "action": body.action,
                "result": body.result,
                "reflection": body.reflection,
                "source_job_id": body.source_job_id,
            }
        )
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}


def _owned_story(story_id: str, profile_id: str) -> dict:
    rows = supabase.table("interview_stories").select("*").eq("id", story_id).limit(1).execute().data
    if not rows or rows[0]["profile_id"] != profile_id:
        raise HTTPException(status_code=404, detail="Story not found")
    return rows[0]


@router.patch("/interview-stories/{story_id}")
async def update_story(story_id: str, body: InterviewStoryUpdate, profile: dict = Depends(get_current_profile)):
    _owned_story(story_id, profile["id"])
    patch = body.model_dump(exclude_unset=True)
    if not patch:
        raise HTTPException(status_code=422, detail="No fields to update")
    row = supabase.table("interview_stories").update(patch).eq("id", story_id).execute().data[0]
    return {"data": row, "error": None}


@router.delete("/interview-stories/{story_id}")
async def delete_story(story_id: str, profile: dict = Depends(get_current_profile)):
    _owned_story(story_id, profile["id"])
    supabase.table("interview_stories").delete().eq("id", story_id).execute()
    return {"data": {"deleted": True}, "error": None}
