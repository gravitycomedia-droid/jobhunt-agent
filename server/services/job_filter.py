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


def is_relevant(title: str | None, location: str | None, description: str | None = None) -> bool:
    """The single gate every ingested posting passes through, whatever its source."""
    return (
        matches_target_role(title, description)
        and is_entry_level(title, description)
        and in_target_city(location, description)
    )
