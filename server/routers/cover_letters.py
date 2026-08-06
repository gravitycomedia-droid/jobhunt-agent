"""Career-ops integration Brick 2 (docs/21-career-ops-integration-plan.md
§1.1, DECISIONS.md ADR-056): cover letter generation, reusing the tailor →
guardrail → human-approval → PDF chain routers/tailor.py already
established. Deliberately its own router/table rather than folded into
/tailor — a cover letter and a tailored résumé have independent lifecycles
(see migration 032's docstring)."""

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
from slugify import slugify

from config import settings
from db.supabase_client import supabase
from services.auth import get_current_profile
from services.background_tasks import create_task, run_task
from services.cover_letter_pdf import compile_cover_letter_pdf
from services.guardrail import build_source_context, collect_untraceable_atoms, verify_bullet_atoms
from services.llm import CoverLetterError, LlmApiError, generate_cover_letter
from services.rate_limit import enforce_rate_limit

router = APIRouter(prefix="/cover-letters", tags=["cover-letters"])


class ApproveCoverLetterRequest(BaseModel):
    """Same shape as tailor.py's ApproveTailorRequest: one bool per paragraph,
    same order as the stored `paragraphs` list. Optional — omitting it
    approves every paragraph that passed the guardrail, same default as the
    résumé flow."""

    accepted: list[bool] | None = None


def _log_untraceable_atoms(profile_id: str, job_id: str, verified_paragraphs: list[dict]) -> None:
    """Same diagnostic log as routers/tailor.py's helper (migration 025) —
    best-effort, never gates generation. collect_untraceable_atoms() only
    needs a `flagged_atoms` key per item, which verified paragraphs carry
    just like verified bullets do."""
    atoms = collect_untraceable_atoms(verified_paragraphs)
    if not atoms:
        return
    try:
        supabase.table("guardrail_atom_log").insert(
            [{"profile_id": profile_id, "job_id": job_id, "atom": a["text"], "kind": a["kind"]} for a in atoms]
        ).execute()
    except Exception:  # noqa: BLE001 — diagnostic log, never gates generation
        pass


def generate_and_store_cover_letter(profile: dict, job_id: str) -> dict:
    """The Brick 2 core, mirroring routers/tailor.py::tailor_and_store's
    shape. No bullet-selection step (services/section_tailor.py) — see
    services/llm.py::generate_cover_letter's docstring for why a cover
    letter doesn't need one."""
    job_rows = supabase.table("jobs").select("*").eq("id", job_id).limit(1).execute().data
    if not job_rows:
        raise HTTPException(status_code=404, detail="Job not found")
    job = job_rows[0]

    experiences = profile.get("experience") or []
    bullets = [b for exp in experiences for b in (exp.get("bullets") or [])]
    projects = profile.get("projects") or []
    if not bullets and not projects:
        # Same PROFILE_INCOMPLETE stable prefix as tailor_and_store — the
        # client already knows to swap Retry for "Add resume" on this string
        # (task_center.dart), so this reuses that handling for free.
        raise HTTPException(
            status_code=422,
            detail="PROFILE_INCOMPLETE: add work experience or at least one project to your profile before a cover letter can be drafted",
        )

    try:
        llm_response = generate_cover_letter(
            bullets,
            projects,
            job.get("title") or "",
            job.get("company") or "",
            job.get("description") or "",
            profile_id=profile["id"],
            skills=profile.get("skills") or [],
            headline=profile.get("headline") or "",
        )
    except CoverLetterError as e:
        raise HTTPException(status_code=422, detail=f"Could not draft cover letter: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Cover letter drafting is temporarily unavailable: {e}") from e

    # Same atom-level guardrail the résumé bullets and the reframed summary
    # line use (services/guardrail.py, ADR-033/R1) — provider-agnostic and
    # already generic over any piece of tailored prose, not résumé-specific.
    ctx = build_source_context(profile)
    labeled = (
        [("opening", llm_response.opening)]
        + [("body", p) for p in llm_response.body_paragraphs]
        + [("closing", llm_response.closing)]
    )
    verified_paragraphs = []
    for role, text in labeled:
        v = verify_bullet_atoms(text, ctx)
        verified_paragraphs.append(
            {"role": role, "text": text, "guardrail_pass": v.guardrail_pass, "flagged_atoms": v.flagged_atoms}
        )
    _log_untraceable_atoms(profile["id"], job_id, verified_paragraphs)
    guardrail_flags = sum(1 for p in verified_paragraphs if not p["guardrail_pass"])

    row = (
        supabase.table("cover_letters")
        .insert(
            {
                "profile_id": profile["id"],
                "job_id": job_id,
                "paragraphs": verified_paragraphs,
                "guardrail_flags": guardrail_flags,
                "approved": False,
            }
        )
        .execute()
        .data[0]
    )
    return row


@router.post(
    "/{job_id}",
    status_code=202,
    dependencies=[
        Depends(enforce_rate_limit("cover_letter", settings.rate_limit_cover_letter, settings.rate_limit_window_seconds))
    ],
)
async def generate_cover_letter_endpoint(job_id: str, background: BackgroundTasks, profile: dict = Depends(get_current_profile)):
    """Same 202-plus-poll shape as POST /tailor/{job_id} (ADR-011) — a
    Gemini call runs long enough that holding a mobile connection open for
    it risks the same connection-abort issue tailoring already worked
    around."""
    task = create_task(profile["id"], "cover_letter")
    background.add_task(run_task, task["id"], lambda: generate_and_store_cover_letter(profile, job_id))
    return {"data": {"task_id": task["id"]}, "error": None}


@router.get("/{job_id}")
async def get_cover_letter(job_id: str, profile: dict = Depends(get_current_profile)):
    """Reads back the most recent cover letter for this job, if any — same
    shape as GET /tailor/{job_id}."""
    rows = (
        supabase.table("cover_letters")
        .select("*")
        .eq("profile_id", profile["id"])
        .eq("job_id", job_id)
        .order("created_at", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return {"data": rows[0] if rows else None, "error": None}


@router.patch("/{cover_letter_id}/approve")
async def approve_cover_letter(
    cover_letter_id: str,
    body: ApproveCoverLetterRequest | None = None,
    profile: dict = Depends(get_current_profile),
):
    """The human approval gate — nothing downstream should treat a cover
    letter as final until the user has reviewed it, guardrail flags
    included. Same ownership-as-404 posture as PATCH /tailor/{id}/approve."""
    existing = supabase.table("cover_letters").select("*").eq("id", cover_letter_id).limit(1).execute().data
    if not existing or existing[0]["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Cover letter not found")

    paragraphs = existing[0]["paragraphs"]
    if body is not None and body.accepted is not None:
        if len(body.accepted) != len(paragraphs):
            raise HTTPException(status_code=422, detail="accepted must have one entry per paragraph")
        for paragraph, accepted in zip(paragraphs, body.accepted):
            paragraph["accepted"] = accepted
    else:
        for paragraph in paragraphs:
            paragraph.setdefault("accepted", paragraph["guardrail_pass"])

    row = (
        supabase.table("cover_letters")
        .update({"approved": True, "paragraphs": paragraphs})
        .eq("id", cover_letter_id)
        .execute()
        .data[0]
    )
    return {"data": row, "error": None}


@router.get("/{cover_letter_id}/pdf")
async def cover_letter_pdf(cover_letter_id: str, profile: dict = Depends(get_current_profile)):
    """Same binary-response exception as GET /tailor/{id}/pdf — raw
    `application/pdf` bytes, not the usual JSON envelope."""
    rows = supabase.table("cover_letters").select("*").eq("id", cover_letter_id).limit(1).execute().data
    if not rows or rows[0]["profile_id"] != profile["id"]:
        raise HTTPException(status_code=404, detail="Cover letter not found")
    cover_letter = rows[0]

    job_rows = supabase.table("jobs").select("*").eq("id", cover_letter["job_id"]).limit(1).execute().data
    job = job_rows[0] if job_rows else {}

    pdf_bytes = compile_cover_letter_pdf(profile, cover_letter, job)
    filename = f"{slugify(profile.get('name') or 'candidate')}-cover-letter.pdf"
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
