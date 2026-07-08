from rapidfuzz import fuzz
from slugify import slugify

from models.job import JobIn


def make_dedup_key(title: str, company: str | None, location: str | None) -> str:
    """Exact-match key: catches the common case of the identical posting
    reappearing (e.g. a re-fetch of the same Adzuna listing)."""
    return "|".join(
        [
            slugify(title or ""),
            slugify(company or ""),
            slugify(location or ""),
        ]
    )


def is_duplicate(candidate: JobIn, existing: list[dict], threshold: int = 90) -> bool:
    """Fuzzy check against recently-ingested jobs: catches near-duplicates
    that don't hash identically, e.g. the same posting surfaced by both
    Adzuna and JSearch with slightly different title/whitespace/casing.
    Pure function (no I/O) so the caller decides what "existing" means —
    easy to unit test with hand-built fixtures.
    """
    candidate_text = f"{candidate.title} {candidate.company or ''} {candidate.location or ''}".lower()
    for job in existing:
        existing_text = f"{job.get('title', '')} {job.get('company', '')} {job.get('location', '')}".lower()
        if fuzz.ratio(candidate_text, existing_text) >= threshold:
            return True
    return False
