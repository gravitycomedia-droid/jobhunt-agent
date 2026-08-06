import io

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, HTTPException, Query, UploadFile
from pydantic import Field
from pypdf import PdfReader

from config import settings
from db.supabase_client import supabase
from models.common import (
    MAX_COMPANY_LEN,
    MAX_DESCRIPTION_LEN,
    MAX_JD_TEXT_LEN,
    MAX_LOCATION_LEN,
    MAX_TITLE_LEN,
    MAX_URL_LEN,
    StrictModel,
)
from models.job import JobExtraction
from services.auth import get_current_profile, get_current_user_id
from services.background_tasks import create_task, run_task
from services.job_category import CATEGORIES, UnknownCategoryError, parse_category_filter
from services.job_tech_category import TECH_CATEGORY_LABELS
from services.pdf_safety import PdfSafetyError, assert_is_pdf, assert_within_size_limit
from services.rate_limit import enforce_rate_limit, enforce_rate_limit_by_user
from services.job_ingestion import (
    ManualJobFetchError,
    backfill_job_embeddings,
    backfill_job_legitimacy,
    fetch_manual_job_text,
    insert_manual_job,
    refresh_job_pool,
)
from services.llm import JobExtractError, LlmApiError, extract_job_from_text

router = APIRouter(prefix="/jobs", tags=["jobs"])


class ManualJobUrl(StrictModel):
    """The pasted link for Add Job step 1. The length cap is the cheap half of
    the check — services/job_ingestion.py::_assert_public_url does the real work
    (scheme + no private/metadata addresses, ADR-024)."""

    url: str = Field(max_length=MAX_URL_LEN)


class ManualJobCreate(StrictModel):
    """Frontend rebuild Phase 2 (Add Job): the reviewed/edited fields from
    the parse step — the user can correct anything the LLM extraction got
    wrong before this actually creates a job row."""

    title: str = Field(max_length=MAX_TITLE_LEN)
    company: str | None = Field(default=None, max_length=MAX_COMPANY_LEN)
    location: str | None = Field(default=None, max_length=MAX_LOCATION_LEN)
    description: str | None = Field(default=None, max_length=MAX_DESCRIPTION_LEN)
    salary_min: float | None = None
    salary_max: float | None = None
    url: str = Field(max_length=MAX_URL_LEN)


class JdResumeJobCreate(StrictModel):
    """JD-paste resume builder step 2: the reviewed/edited fields from
    POST /jobs/from-jd/parse. No `url` — unlike Add Job's fetched-page
    flow, a pasted or uploaded JD has no source link to redirect to."""

    title: str = Field(max_length=MAX_TITLE_LEN)
    company: str | None = Field(default=None, max_length=MAX_COMPANY_LEN)
    location: str | None = Field(default=None, max_length=MAX_LOCATION_LEN)
    description: str | None = Field(default=None, max_length=MAX_DESCRIPTION_LEN)
    salary_min: float | None = None
    salary_max: float | None = None


def _extract_pdf_text(pdf_bytes: bytes) -> str:
    reader = PdfReader(io.BytesIO(pdf_bytes))
    return "\n".join(page.extract_text() or "" for page in reader.pages)


@router.post(
    "/refresh",
    status_code=202,
    dependencies=[
        Depends(
            enforce_rate_limit_by_user(
                "jobs_refresh", settings.rate_limit_jobs_refresh, settings.rate_limit_window_seconds
            )
        )
    ],
)
async def refresh_jobs(background: BackgroundTasks, profile: dict = Depends(get_current_profile)):
    """Requires login but isn't scoped to the caller — the job pool is
    shared across all beta users (the pool itself has no owner). Note: this
    endpoint hits API/board sources only; no-login Apify + Unstop scraping is
    cron-only and never reachable from here (ADR-003 v2, Golden Rule 8).

    ADR-011-shaped, same as /tailor/{job_id}: fanning out to four job
    sources routinely runs well past a minute (JSearch alone ~60s), which
    held the client's connection open long enough for Android's network
    stack to abort it (ClientException: Software caused connection abort).
    This now returns 202 + a task id immediately; the client polls
    GET /tasks/{id} for the `{fetched, inserted}` result.
    """
    task = create_task(profile["id"], "jobs_refresh")
    background.add_task(run_task, task["id"], refresh_job_pool)
    return {"data": {"task_id": task["id"]}, "error": None}


@router.get("")
async def list_jobs(
    limit: int = Query(20, le=100),
    offset: int = Query(0, ge=0),
    category: str | None = Query(
        None,
        description="Comma-separated categories to include (see services/job_category.CATEGORIES). Omit for all.",
    ),
    user_id: str = Depends(get_current_user_id),
):
    """The shared pool, newest first.

    `category` filters SERVER-side rather than in the client (ADR-003 v3). The
    work_type/source filters are a client-side narrowing of an already-fetched
    page, which was fine when the whole pool was on-target roles. It is not fine
    now: with the broad Unstop pool ~75% of rows are non-engineering, so a client
    filtering page-by-page would show two matching jobs on a page of twenty and
    make the list look empty. Filtering before pagination keeps every page full.
    """
    # Retired postings (migration 028) are excluded from browsing. This is a
    # DISCOVERY read; the reads that hydrate a job the user already applied to or
    # tailored against deliberately do NOT filter on is_active, which is the
    # whole point of retirement being a soft flag rather than a delete.
    query = supabase.table("jobs").select("*").eq("is_active", True)

    try:
        wanted = parse_category_filter(category)
    except UnknownCategoryError as e:
        # 422, not an empty 200: a typo'd filter must not be indistinguishable
        # from an empty pool.
        raise HTTPException(status_code=422, detail=str(e)) from e
    if wanted:
        query = query.in_("category", wanted)

    result = query.order("ingested_at", desc=True).range(offset, offset + limit - 1).execute()
    return {"data": result.data, "error": None}


def build_facets(jobs: list[dict]) -> dict:
    """Pure histogram of the shared job pool for the filter sheet (§4.4). Counts
    are computed in Python over the fetched rows rather than a SQL GROUP BY: the
    pool is a small fresh window (max_job_age_days) so one select + a Python pass
    beats a Supabase RPC, and it's unit-testable without a DB. NULL work_type
    (migration 019's honest "unclassified") buckets as 'unknown', never dropped."""
    work_type: dict[str, int] = {"remote": 0, "hybrid": 0, "onsite": 0, "unknown": 0}
    source: dict[str, int] = {}
    # Seeded with every known category at 0 so the client can render a stable set
    # of chips whose order doesn't shuffle as counts change day to day. (source is
    # NOT seeded — its values are open-ended.)
    category: dict[str, int] = {c: 0 for c in CATEGORIES}
    for j in jobs:
        wt = j.get("work_type") or "unknown"
        work_type[wt] = work_type.get(wt, 0) + 1
        src = j.get("source") or "unknown"
        source[src] = source.get(src, 0) + 1
        # NULL category = a row ingested before migration 027 that the backfill
        # couldn't place. Buckets as 'other' so it stays reachable through a real
        # filter chip rather than becoming invisible.
        cat = j.get("category") or "other"
        category[cat] = category.get(cat, 0) + 1
    return {
        "total": len(jobs),
        "work_type": work_type,
        # busiest source first — the client renders chips in this order
        "source": dict(sorted(source.items(), key=lambda kv: kv[1], reverse=True)),
        "category": dict(sorted(category.items(), key=lambda kv: kv[1], reverse=True)),
    }


@router.get("/facets")
async def job_facets(user_id: str = Depends(get_current_user_id)):
    """Filter-sheet histogram (§4.4): job counts per work_type, source and
    category across the shared pool. Login-gated like GET /jobs, not
    profile-scoped — the pool has no owner. These counts drive the filter chips;
    category is additionally applied server-side by GET /jobs."""
    # Same is_active exclusion as GET /jobs — the chip counts have to describe
    # the pool the user can actually browse, or every filter would look like it
    # lost jobs.
    rows = supabase.table("jobs").select("work_type,source,category").eq("is_active", True).execute().data
    return {"data": build_facets(rows), "error": None}


# Curated fallback list for the target-roles suggestion chips (routers/resume.py
# writes what the user picks to profiles.target_roles — free text, not this
# enum). Not everything a candidate might target shows up as a tech_category
# specialism (that vocabulary is engineering/data only, see job_tech_category.py),
# so this rounds it out with common roles this pool doesn't yet label distinctly.
# Deliberately hand-maintained and small, same spirit as matching.py's role/
# location synonym tables.
_OTHER_ROLE_SUGGESTIONS = (
    "Product Manager",
    "UI/UX Designer",
    "Business Analyst",
    "Technical Writer",
    "Solutions Engineer",
    "Sales Engineer",
    "Data Engineer",
    "Site Reliability Engineer",
    "Support Engineer",
)


def build_role_suggestions(jobs: list[dict]) -> dict:
    """Pure function (unit-testable without a DB): `db_roles` is every
    tech_category actually present in the live, active job pool, busiest
    first — roles the agent can realistically find postings for TODAY.
    `other_roles` is the curated static list above, roles the pool doesn't
    label distinctly, with anything already surfaced in db_roles removed so
    the same role never appears twice."""
    counts: dict[str, int] = {}
    for j in jobs:
        tc = j.get("tech_category")
        if tc and tc in TECH_CATEGORY_LABELS:
            counts[tc] = counts.get(tc, 0) + 1
    db_roles = [TECH_CATEGORY_LABELS[tc] for tc, _ in sorted(counts.items(), key=lambda kv: kv[1], reverse=True)]
    db_roles_set = {r.lower() for r in db_roles}
    other_roles = [r for r in _OTHER_ROLE_SUGGESTIONS if r.lower() not in db_roles_set]
    return {"db_roles": db_roles, "other_roles": other_roles}


@router.get("/role-suggestions")
async def role_suggestions(user_id: str = Depends(get_current_user_id)):
    """Target-roles onboarding/Settings screen (app/lib/screens/
    target_roles_screen.dart): suggestion chips backed by what's actually in
    the job pool right now, so a candidate isn't offered a role the agent has
    nothing to match it against, followed by a curated list of common roles
    the pool doesn't specifically label."""
    rows = supabase.table("jobs").select("tech_category").eq("is_active", True).execute().data
    return {"data": build_role_suggestions(rows), "error": None}


@router.post("/backfill-embeddings")
async def backfill_embeddings(user_id: str = Depends(get_current_user_id)):
    result = backfill_job_embeddings()
    return {"data": result, "error": None}


@router.post("/backfill-legitimacy")
async def backfill_legitimacy(user_id: str = Depends(get_current_user_id)):
    """Career-ops integration Brick 1 (ADR-055): one-off catch-up for jobs
    ingested before migration 031. Same shape as /backfill-embeddings —
    an ops-triggered, idempotent, repeatable call, not something the app
    surfaces to end users."""
    result = backfill_job_legitimacy()
    return {"data": result, "error": None}


@router.post(
    "/manual/parse",
    dependencies=[
        Depends(
            enforce_rate_limit("manual_parse", settings.rate_limit_manual_parse, settings.rate_limit_window_seconds)
        )
    ],
)
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


@router.post(
    "/from-jd/parse",
    dependencies=[
        Depends(
            enforce_rate_limit("manual_parse", settings.rate_limit_manual_parse, settings.rate_limit_window_seconds)
        )
    ],
)
async def parse_jd(
    # ADR-024: capped at the edge (422) rather than truncated silently inside
    # the LLM call — the user gets told why, instead of being billed for tokens
    # from a paste that was quietly cut off. This is a multipart Form field, so
    # the cap goes here rather than in a StrictModel.
    jd_text: str | None = Form(None, max_length=MAX_JD_TEXT_LEN),
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
        pdf_bytes = await file.read()
        # ADR-026: this path only extracts a TEXT layer (no rasterizing), but a
        # non-PDF or an oversized upload should still be rejected up front with
        # the same magic-byte + size gates as /resume/parse — a claimed
        # content-type isn't evidence.
        try:
            assert_is_pdf(pdf_bytes)
            assert_within_size_limit(pdf_bytes)
        except PdfSafetyError as e:
            raise HTTPException(status_code=422, detail=str(e))
        text = _extract_pdf_text(pdf_bytes)
    else:
        text = (jd_text or "").strip()

    if not text:
        raise HTTPException(status_code=422, detail="Paste some JD text or upload a PDF")

    try:
        # Provider pinned alongside the model — a Gemini model name means
        # nothing to DeepSeek (ADR-023, see services/llm.py::_run_llm_task).
        extraction = extract_job_from_text(
            text,
            profile_id=profile["id"],
            model=settings.gemini_model_lite,
            provider="gemini",
        )
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
