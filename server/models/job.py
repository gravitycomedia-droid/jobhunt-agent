from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class JobIn(BaseModel):
    """Normalized shape both Adzuna and JSearch results get mapped into
    before dedup + insert. Mirrors the `jobs` table columns (minus
    dedup_key/embedding, which are computed separately)."""

    source: str
    external_id: str
    title: str
    company: Optional[str] = None
    location: Optional[str] = None
    description: Optional[str] = None
    salary_min: Optional[float] = None
    salary_max: Optional[float] = None
    # Phase 1D: ISO 4217 code ("INR", "USD"). Adzuna reports salaries in the
    # search country's currency; JSearch sends an explicit field. Without
    # this the app assumed "$" for Hyderabad postings.
    salary_currency: Optional[str] = None
    redirect_url: Optional[str] = None
    posted_at: Optional[datetime] = None

    # Set by a fetcher that KNOWS the posting is entry-level from where it found
    # it, rather than leaving job_filter.is_entry_level() to infer seniority from
    # wording. Internshala is the motivating case: its card titles are the
    # profile name ("Android App Development"), not the job title, so only 3 of
    # 50 contain the word "intern" and the text-based gate rejected ~38% of
    # listings fetched from the /internships/ URL — postings that are internships
    # by definition. A hint of True skips the entry check; None/False changes
    # nothing, so every other source behaves exactly as before.
    #
    # exclude=True is LOAD-BEARING: JobIn.model_dump() is written straight into
    # the `jobs` upsert, and a field with no matching column makes PostgREST
    # reject the whole batch. This is a transport-only hint, never a column.
    entry_level_hint: Optional[bool] = Field(default=None, exclude=True)


class JobExtraction(BaseModel):
    """Frontend rebuild Phase 2 (Add Job, task: `extract_job`): Gemini's
    best-effort read of a single pasted-URL posting's page text — see
    docs/PROMPTS.md section 6. Only `title` is required; everything else
    is null when the page doesn't clearly state it, never guessed."""

    title: str
    company: Optional[str] = None
    location: Optional[str] = None
    description: Optional[str] = None
    salary_min: Optional[float] = None
    salary_max: Optional[float] = None
