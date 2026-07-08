from datetime import datetime
from typing import Optional

from pydantic import BaseModel


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
    redirect_url: Optional[str] = None
    posted_at: Optional[datetime] = None
