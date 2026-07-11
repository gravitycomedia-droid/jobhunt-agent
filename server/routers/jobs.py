import io

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile
from pydantic import BaseModel
from pypdf import PdfReader

from config import settings
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


class JdResumeJobCreate(BaseModel):
    """JD-paste resume builder step 2: the reviewed/edited fields from
    POST /jobs/from-jd/parse. No `url` — unlike Add Job's fetched-page
    flow, a pasted or uploaded JD has no source link to redirect to."""

    title: str
    company: str | None = None
    location: str | None = None
    description: str | None = None
    salary_min: float | None = None
    salary_max: float | None = None


def _extract_pdf_text(pdf_bytes: bytes) -> str:
    reader = PdfReader(io.BytesIO(pdf_bytes))
    return "\n".join(page.extract_text() or "" for page in reader.pages)


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


@router.post("/from-jd/parse")
async def parse_jd(
    jd_text: str | None = Form(None),
    file: UploadFile | None = File(None),
    profile: dict = Depends(get_current_profile),
):
    """JD-paste resume builder (standalone from the matching pipeline) step
    1: paste a JD as text, or upload it as a PDF, and get back structured
    fields to review before a job/application row is created — same
    parse-then-review shape as /jobs/manual/parse. Runs on
    the GEMINI_MODEL_LITE tier (config.py), not settings.gemini_model — a lighter, cheaper
    tier for a convenience tool outside the core matching/tailoring
    quality bar (ADR-017).
    """
    if file is not None:
        if file.content_type != "application/pdf":
            raise HTTPException(status_code=400, detail="Only PDF uploads are supported")
        text = _extract_pdf_text(await file.read())
    else:
        text = (jd_text or "").strip()

    if not text:
        raise HTTPException(status_code=422, detail="Paste some JD text or upload a PDF")

    try:
        extraction = extract_job_from_text(text, profile_id=profile["id"], model=settings.gemini_model_lite)
    except JobExtractError as e:
        raise HTTPException(status_code=422, detail=f"Could not extract job details: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Job extraction is temporarily unavailable: {e}") from e

    return {"data": extraction.model_dump(), "error": None}


@router.post("/from-jd")
async def create_jd_resume_job(body: JdResumeJobCreate, profile: dict = Depends(get_current_profile)):
    """JD-paste resume builder step 2: creates the job (source='jd_paste',
    no redirect_url — a pasted JD has no source link) and a 'saved'
    application row (same idempotent-per-(profile,job) posture as POST
    /applications). Returns job_id/job_title; the app then reuses the
    existing tailoring flow (POST /tailor/{job_id}, ResumeDiffScreen etc.)
    unchanged — that flow doesn't know or care where a job came from, so
    nothing about it needed to change for this feature. Deliberately NOT
    routed through gemini_model_lite: the actual resume tailoring for a
    'jd_paste' job stays on that cheap model too, but that's
    tailor_and_store's decision (routers/tailor.py), not this endpoint's.
    """
    extraction = JobExtraction(
        title=body.title,
        company=body.company,
        location=body.location,
        description=body.description,
        salary_min=body.salary_min,
        salary_max=body.salary_max,
    )
    job = insert_manual_job(extraction, redirect_url=None, source="jd_paste")

    existing = (
        supabase.table("applications")
        .select("id")
        .eq("profile_id", profile["id"])
        .eq("job_id", job["id"])
        .limit(1)
        .execute()
        .data
    )
    if not existing:
        supabase.table("applications").insert({"profile_id": profile["id"], "job_id": job["id"]}).execute()

    return {"data": {"job_id": job["id"], "job_title": job["title"]}, "error": None}
