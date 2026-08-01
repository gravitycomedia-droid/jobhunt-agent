"""Ingestion relevance gate (golden rule 2: code handles logic, not the LLM).

The user hunts ONE thing: fullstack / frontend / cloud-architect **internships and
fresher roles** in Hyderabad and Bengaluru. Everything else is noise that costs
embeddings to store and re-rank tokens to score.

Some sources can filter server-side (Naukri's experienceMax, an "intern" keyword
on LinkedIn/Indeed/Adzuna) and some cannot at all — Greenhouse and Lever hand
back a company's ENTIRE board, every role and every city. So the gate lives here,
once, and `_dedup_embed_insert()` applies it to every source. Pure functions, no
I/O, so the thresholds are unit-testable.

Amended 2026-07-26 (ADR-003 v3): the gate is no longer *uniform* across sources —
which of role/entry/location apply is per-source config, because a full-catalogue
crawl (Unstop) and a keyword API (Adzuna) need different strictness to mean the
same thing. See `gates_for_source()`. Sources without an override still get all
three, unchanged.

Design note on strictness: each of the three tests (role, seniority, city) reads
the TITLE first and falls back to the DESCRIPTION. A posting titled plainly
"SDE Intern" whose JD is all React and Node is a job the user wants, and a
title-only match would throw it away.
"""

import logging
import re

from config import settings

logger = logging.getLogger(__name__)

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


# --- per-source gate policy (ADR-003 v3) --------------------------------------
# The three tests above used to be applied as one fixed AND to every source. That
# is right for the API sources, which return a narrow slice already, and wrong for
# a full-catalogue crawl like Unstop's: measured 2026-07-26, the role gate alone
# discards ~92% of Unstop's 2,022 open postings, so the source could fetch
# perfectly and still land ~20 rows/day.
#
# So which gates run is now per-source config. Any source with no override gets
# ALL THREE, i.e. every existing source behaves exactly as before — this widens
# one source deliberately rather than loosening the pool globally.
_ALL_GATES = ("role", "entry", "location")


def _parse_gate_overrides(raw: str) -> dict[str, frozenset[str]]:
    """Parse "unstop:entry, foo:role+location" → {"unstop": {"entry"}, ...}.

    Gates are joined with "+" because "," already separates sources. The literal
    "none" (or an empty gate list) means "ingest everything this source returns",
    subject only to the freshness rule, which is NOT a gate here — is_fresh()
    runs upstream in _dedup_embed_insert() and applies to every source always.

    Unknown gate names are dropped with a warning rather than silently ignored: a
    typo'd gate would quietly widen the pool, which is the failure mode most
    likely to go unnoticed.
    """
    overrides: dict[str, frozenset[str]] = {}
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry or ":" not in entry:
            continue
        source, _, gate_spec = entry.partition(":")
        source = source.strip().lower()
        if not source:
            continue
        names = [g.strip().lower() for g in gate_spec.split("+") if g.strip()]
        if names == ["none"]:
            names = []
        unknown = [g for g in names if g not in _ALL_GATES]
        if unknown:
            logger.warning("Ingestion gate override for %r names unknown gate(s) %s — ignoring those", source, unknown)
        overrides[source] = frozenset(g for g in names if g in _ALL_GATES)
    return overrides


def gates_for_source(source: str | None) -> frozenset[str]:
    """Which of role/entry/location apply to postings from `source`."""
    overrides = _parse_gate_overrides(settings.ingestion_gate_overrides)
    return overrides.get((source or "").strip().lower(), frozenset(_ALL_GATES))


def is_relevant(
    title: str | None,
    location: str | None,
    description: str | None = None,
    source: str | None = None,
    entry_level_hint: bool | None = None,
) -> bool:
    """The gate every ingested posting passes through.

    `source` selects the gate set (see gates_for_source). Omitting it keeps the
    strict all-three behaviour, so a caller that hasn't been updated can only
    ever be *more* selective, never accidentally less.

    `entry_level_hint=True` means the FETCHER already knows this posting is
    entry-level from where it found it, so the text-based seniority guess is
    skipped. This is a correctness fix, not a loosening: Internshala's card
    titles are profile names ("Android App Development"), so only 3 of 50 carry
    the word "intern" and is_entry_level() was rejecting ~38% of listings pulled
    from the /internships/ URL — postings that are internships by definition.
    Structural knowledge beats inference from wording every time.

    None (the default) preserves the old behaviour exactly. False is treated the
    same as None rather than as a veto: a fetcher saying "I don't know" must not
    be able to reject a posting the text clearly marks as an internship.
    """
    gates = gates_for_source(source)
    if "role" in gates and not matches_target_role(title, description):
        return False
    if "entry" in gates and not entry_level_hint and not is_entry_level(title, description):
        return False
    if "location" in gates and not in_target_location(location, title, description):
        return False
    return True
