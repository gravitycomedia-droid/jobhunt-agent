from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from db.supabase_client import supabase
from models.job import JobExtraction
from services.auth import get_current_profile, get_current_user_id
from services.job_ingestion import (
    ManualJobFetchError,
    backfill_job_embeddings,
    fetch_manual_job_text,
    insert_manual_job,
    refresh_job_pool,
)
from services.llm import JobExtractError, LlmApiError, extract_job_from_text

router = APIRouter(prefix="/jobs", tags=["jobs"])


class ManualJobUrl(BaseModel):
    url: str


class ManualJobCreate(BaseModel):
    """Frontend rebuild Phase 2 (Add Job): the reviewed/edited fields from
    the parse step — the user can correct anything the LLM extraction got
    wrong before this actually creates a job row."""

    title: str
    company: str | None = None
    location: str | None = None
    description: str | None = None
    salary_min: float | None = None
    salary_max: float | None = None
    url: str


@router.post("/refresh")
async def refresh_jobs(user_id: str = Depends(get_current_user_id)):
    """Requires login but isn't scoped to the caller — the job pool is
    shared across all beta users (Golden Rule: no scraping, legal APIs
    only; the pool itself has no owner)."""
    result = await refresh_job_pool()
    return {"data": result, "error": None}


@router.get("")
async def list_jobs(limit: int = Query(20, le=100), offset: int = Query(0, ge=0), user_id: str = Depends(get_current_user_id)):
    result = (
        supabase.table("jobs")
        .select("*")
        .order("ingested_at", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )
    return {"data": result.data, "error": None}


@router.post("/backfill-embeddings")
async def backfill_embeddings(user_id: str = Depends(get_current_user_id)):
    result = backfill_job_embeddings()
    return {"data": result, "error": None}


@router.post("/manual/parse")
async def parse_manual_job(body: ManualJobUrl, profile: dict = Depends(get_current_profile)):
    """Add Job step 1 (frontend rebuild Phase 2): fetches the pasted URL
    and asks Gemini to extract job fields — returns them for the user to
    review/edit, doesn't create anything yet. See DECISIONS.md ADR-009 for
    why fetching one user-supplied link here is judged distinct from
    ADR-003's no-scraping stance. Needs a profile (not just a session) to
    attribute the extraction's llm_calls row (Phase 3 cost stats) — every
    screen that reaches Add Job already requires onboarding to be done, so
    this doesn't newly gate anything.
    """
    try:
        page_text = await fetch_manual_job_text(body.url)
    except ManualJobFetchError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e

    try:
        extraction = extract_job_from_text(page_text, profile_id=profile["id"])
    except JobExtractError as e:
        raise HTTPException(status_code=422, detail=f"Could not extract job details: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Job extraction is temporarily unavailable: {e}") from e

    return {"data": extraction.model_dump(), "error": None}


@router.post("/manual")
async def create_manual_job(body: ManualJobCreate, user_id: str = Depends(get_current_user_id)):
    """Add Job step 2: creates (or returns the existing duplicate of) a
    job from the user-reviewed fields — a separate, explicit action from
    the parse step, so nothing gets added to the shared pool without the
    user seeing and confirming what was extracted first.
    """
    extraction = JobExtraction(
        title=body.title,
        company=body.company,
        location=body.location,
        description=body.description,
        salary_min=body.salary_min,
        salary_max=body.salary_max,
    )
    row = insert_manual_job(extraction, redirect_url=body.url)
    return {"data": row, "error": None}
