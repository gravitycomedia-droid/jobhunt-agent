"""Ingestion relevance gate (golden rule 2: code handles logic, not the LLM).

The user hunts ONE thing: fullstack / frontend / cloud-architect **internships and
fresher roles** in Hyderabad and Bengaluru. Everything else is noise that costs
embeddings to store and re-rank tokens to score.

Some sources can filter server-side (Naukri's experienceMax, an "intern" keyword
on LinkedIn/Indeed/Adzuna) and some cannot at all — Greenhouse and Lever hand
back a company's ENTIRE board, every role and every city. So the gate lives here,
once, and `_dedup_embed_insert()` applies it to every source uniformly. Pure
functions, no I/O, so the thresholds are unit-testable.

Design note on strictness: each of the three tests (role, seniority, city) reads
the TITLE first and falls back to the DESCRIPTION. A posting titled plainly
"SDE Intern" whose JD is all React and Node is a job the user wants, and a
title-only match would throw it away.
"""

import re

# --- role ---------------------------------------------------------------------
# Deliberately wider than the three literal role names: postings say "MERN",
# "React Developer", "Web Developer" and mean the same jobs.
_ROLE = re.compile(
    r"""
    full[\s.-]?stack | frontend | front[\s.-]end | mern | mean\b
  | react | angular | vue | next\.?js | javascript | typescript
  | web\s+develop | ui\s+develop | cloud\s+architect | solutions?\s+architect
  | cloud\s+engineer | devops
    """,
    re.I | re.X,
)

# --- seniority ----------------------------------------------------------------
# A senior title is a hard veto: "Senior Frontend Engineer" matches the role and
# the city and is exactly what we're trying to keep out.
_SENIOR = re.compile(
    r"""
    \bsenior\b | \bsr\.? | \bstaff\b | \bprincipal\b | \blead\b | \bhead\b
  | \bmanager\b | \bdirector\b | \bvp\b | \bchief\b
  | \bii+\b | \b[3-9]\b\s*\+?\s*years | \bl[3-9]\b
    """,
    re.I | re.X,
)

_ENTRY = re.compile(
    r"""
    intern(ship)?\b | trainee | fresher | graduate | campus | apprentice
  | entry[\s-]?level | \bjunior\b | \bjr\.? | \bsde[\s-]?1\b | engineer\s+i\b
  | \b0\s*[-–to]+\s*[12]\s*(year|yr) | \b1\s*[-–to]+\s*2\s*(year|yr)
  | no\s+(prior\s+)?experience | freshers?\s+(can|may|are)
    """,
    re.I | re.X,
)

# --- location -----------------------------------------------------------------
_CITY = re.compile(r"hyderabad|bangalore|bengaluru|secunderabad|hyd\b|blr\b", re.I)

# Remote is location-independent — a fresher in Hyderabad can take a remote
# internship based anywhere, so remote roles pass the location gate without a
# Hyd/Blr mention (added 2026-07-21; Unstop internships are heavily WFH).
# Two patterns on purpose: the LOCATION field is a controlled value, so a bare
# "Remote" there is trustworthy; free text is not, so a JD must use a strong
# phrase ("work from home", "fully remote", "remote internship") — a bare
# "remote" in a JD usually means "remote team/repo", not the job's work mode.
_REMOTE_LOCATION = re.compile(r"\bremote\b|work\s*from\s*home|work-from-home|\bwfh\b", re.I)
_REMOTE_TEXT = re.compile(
    r"work\s*from\s*home | work-from-home | \bwfh\b | fully\s+remote | 100%\s+remote"
    r" | remote\s+(intern(ship)?|role|position|job|opportunity) | work\s+from\s+anywhere",
    re.I | re.X,
)


def _head(description: str | None, chars: int = 1200) -> str:
    """Only the top of a JD is worth scanning: the seniority and years-of-
    experience line lives near the top, while the boilerplate footer ("we are an
    equal-opportunity employer... we also hire senior staff") would otherwise
    trip the senior veto on a perfectly good internship."""
    return (description or "")[:chars]


def matches_target_role(title: str | None, description: str | None = None) -> bool:
    return bool(_ROLE.search(title or "") or _ROLE.search(_head(description)))


def is_entry_level(title: str | None, description: str | None = None) -> bool:
    """True for internships and fresher roles.

    The senior veto is checked on the TITLE ONLY. Checking it against the
    description would reject most internships outright — a JD routinely says
    "you'll work with senior engineers", and that sentence must not disqualify
    the job.
    """
    title = title or ""
    if _SENIOR.search(title):
        return False
    return bool(_ENTRY.search(title) or _ENTRY.search(_head(description)))


def in_target_city(location: str | None, description: str | None = None) -> bool:
    return bool(_CITY.search(location or "") or _CITY.search(_head(description, 400)))


def is_remote(location: str | None, title: str | None = None, description: str | None = None) -> bool:
    """True for work-from-home / fully-remote roles — accepted regardless of city.
    The location field gets the lenient pattern (it's a controlled value); title
    and description get the strict one (a bare 'remote' in prose is too noisy)."""
    return bool(
        _REMOTE_LOCATION.search(location or "")
        or _REMOTE_TEXT.search(title or "")
        or _REMOTE_TEXT.search(_head(description, 400))
    )


_HYBRID = re.compile(r"\bhybrid\b", re.I)


def classify_work_type(
    location: str | None, title: str | None = None, description: str | None = None
) -> str | None:
    """The value persisted to jobs.work_type (migration 019). Remote reuses
    is_remote (which the ingestion gate already computes); hybrid needs an
    explicit signal. Everything else returns None, NOT 'onsite': sources rarely
    state onsite, and an honest 'unknown' (which the filter buckets as such) beats
    guessing a work arrangement the posting never claimed."""
    if is_remote(location, title, description):
        return "remote"
    if _HYBRID.search(location or "") or _HYBRID.search(title or "") or _HYBRID.search(_head(description, 400)):
        return "hybrid"
    return None


def in_target_location(location: str | None, title: str | None = None, description: str | None = None) -> bool:
    """Hyd/Blr OR remote. Remote is location-independent, so it satisfies the
    location requirement on its own."""
    return in_target_city(location, description) or is_remote(location, title, description)


def is_relevant(title: str | None, location: str | None, description: str | None = None) -> bool:
    """The single gate every ingested posting passes through, whatever its source."""
    return (
        matches_target_role(title, description)
        and is_entry_level(title, description)
        and in_target_location(location, title, description)
    )
