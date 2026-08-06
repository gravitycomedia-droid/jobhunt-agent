"""Posting-legitimacy signal (career-ops integration, Brick 1 — see
docs/21-career-ops-integration-plan.md §1.5 / DECISIONS.md ADR-055).

Inspired by career-ops's Block G ("Posting Legitimacy"), but adapted to
Golden Rule 2: every signal here is computed from data already sitting on
the `jobs` row (description, salary, posted_at, expires_at, redirect_url) —
no LLM call, no web research, nothing that costs money or needs a retry
path. This runs on every ingested row (hundreds a day, same volume as
job_category.py/job_filter.py), which is itself the argument for keeping it
regex-and-arithmetic rather than a model call.

Ethical framing carried over from career-ops directly: these are
OBSERVATIONS, not accusations. Every signal has legitimate explanations
(a terse posting from a small startup, a niche role that genuinely stays
open for months, an evergreen/rolling internship listing). The tier is a
prioritization hint for the user's own attention, never a hard filter —
nothing here removes a job from the pool or blocks an application.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone

# Closed vocabulary. Mirrored by the CHECK constraint in migration 031 and
# by the app's badge widget (StatusPill's PillContext.legitimacy) — adding a
# value means touching both.
HIGH_CONFIDENCE = "high_confidence"
PROCEED_WITH_CAUTION = "proceed_with_caution"
SUSPICIOUS = "suspicious"

# --- Description quality thresholds -----------------------------------
# Measured against nothing scientific — these are the same "close enough to
# be useful" bar cost_stats.py sets for pricing. A one-line posting
# ("Urgent hiring, DM now") reads as vague at any length; a real JD for even
# an entry-level role tends to clear 40 words once role + responsibilities +
# a line of requirements are stated.
_VAGUE_WORD_COUNT = 40
_DETAILED_WORD_COUNT = 150

# --- Spam / scam phrasing ------------------------------------------------
# This app's pool is India-heavy (Unstop/Internshala/Instahyre are ~80%+ of
# volume — see ADR-003 v3/v4), so the patterns that actually recur in this
# specific pool are Indian "earn from home" spam, not career-ops's
# Glassdoor/Blind-oriented US signals. A match here is a STRONG, mostly
# unambiguous indicator (unlike the softer word-count/salary signals below),
# so it overrides the point system entirely rather than contributing to it —
# same "multiple ghost-job indicators → Suspicious" posture career-ops uses,
# just collapsed to a single high-confidence pattern class instead of a tally.
_SPAM_PATTERNS = re.compile(
    r"""
      earn\s+(up\s*to\s+)?[₹$]?\s*\d[\d,]*\s*(per\s+(day|week)|/\s*day|/\s*week)
    | work\s+from\s+home.{0,20}(earn|income|salary)
    | no\s+experience\s+(needed|required).{0,30}(earn|income|salary)
    | (registration|processing|training)\s+fee\s+(required|applicable|mandatory)
    | pay\s+(a\s+)?(registration|joining|security)\s+(fee|deposit)
    | (whatsapp|telegram)\s+only
    | 100%\s+(guaranteed|assured)\s+(job|placement|income)
    | part[\s-]?time.{0,20}earn.{0,10}(lakh|lac)
    """,
    re.I | re.X,
)

# --- Employment-classification language (career-ops offer-prep-style table,
# trimmed to the jurisdictions this pool actually surfaces). Orthogonal to
# the tier — reported as a separate note, never moves high_confidence to
# suspicious on its own, mirroring career-ops's "descriptive, never
# prescriptive" framing.
_CONTRACTOR_LANGUAGE = re.compile(
    r"""
      \b1099\b | independent\s+contractor | invoice\s+for\s+services
    | consulting\s+agreement | \bfreelance\s+basis\b
    | labou?r\s+contract | service\s+agreement(?!\s+with\s+our\s+clients)
    | no\s+(benefits|pf|provident\s+fund)\s+(provided|included)
    """,
    re.I | re.X,
)


def _word_count(description: str | None) -> int:
    return len((description or "").split())


def _age_days(posted_at, now: datetime) -> float | None:
    """Mirrors job_ingestion.is_fresh()'s tz handling — posted_at may come in
    naive (from a source that doesn't say) or aware."""
    if posted_at is None:
        return None
    if isinstance(posted_at, str):
        try:
            posted_at = datetime.fromisoformat(posted_at.replace("Z", "+00:00"))
        except ValueError:
            return None
    if posted_at.tzinfo is None:
        posted_at = posted_at.replace(tzinfo=timezone.utc)
    return (now - posted_at).total_seconds() / 86400


# Sources that always carry a genuine redirect_url by construction (Adzuna,
# JSearch, Greenhouse, Lever always echo one; 'manual'/'jd_paste' are a
# deliberate user paste, not a discovery listing). A source outside this set
# arriving with no redirect_url is the one signal here that's closer to a
# data-integrity problem than a legitimacy one, but the two are
# indistinguishable to the user looking at the card, so it's folded in here.
_ALWAYS_HAS_LINK_SOURCES = frozenset({"manual", "jd_paste"})


def score_posting(job: dict, now: datetime | None = None, max_job_age_days: int = 10) -> dict:
    """Pure function: `job` is a payload dict with (at least) `description`,
    `salary_min`, `salary_max`, `posted_at`, `redirect_url`, `source` — the
    same shape available in job_ingestion.py's payload dict before insert,
    and identical to a row already in the `jobs` table for backfill.

    Returns `{"tier": ..., "signals": [...], "contractor_language_note": ...}`.
    Never raises — a posting this can't confidently read scores
    proceed_with_caution, never suspicious without positive evidence (same
    "never default to Suspicious without evidence" rule career-ops states
    for its own liveness gate).
    """
    now = now or datetime.now(timezone.utc)
    description = job.get("description") or ""
    signals: list[dict] = []
    concerns = 0
    positives = 0

    # Strong override: recognizable spam/scam phrasing settles the tier on
    # its own, before the point system below even runs.
    spam_match = _SPAM_PATTERNS.search(description) or _SPAM_PATTERNS.search(job.get("title") or "")
    if spam_match:
        signals.append(
            {
                "signal": "spam_pattern",
                "weight": "concerning",
                "detail": f"Matched common scam/spam phrasing: {spam_match.group(0)!r}",
            }
        )
        return {
            "tier": SUSPICIOUS,
            "signals": signals,
            "contractor_language_note": _contractor_note(description),
        }

    # --- Description quality ---
    words = _word_count(description)
    if words == 0:
        signals.append({"signal": "description_missing", "weight": "concerning", "detail": "No job description text"})
        concerns += 1
    elif words < _VAGUE_WORD_COUNT:
        signals.append(
            {"signal": "description_vague", "weight": "concerning", "detail": f"Only {words} words — too short to convey a real role"}
        )
        concerns += 1
    elif words >= _DETAILED_WORD_COUNT:
        signals.append({"signal": "description_detailed", "weight": "positive", "detail": f"{words} words — a substantive JD"})
        positives += 1
    # A middle-length description (40-149 words) is common and unremarkable
    # — neither flagged nor credited.

    # --- Salary disclosed ---
    # Absence is NOT penalized: most postings in this pool carry no salary at
    # all (see DECISIONS.md ADR-054), so treating that as concerning would
    # flag the majority of the honest pool. Presence is a genuine positive
    # signal, though, since it's the source actually committing to a number.
    if job.get("salary_min") is not None or job.get("salary_max") is not None:
        signals.append({"signal": "salary_disclosed", "weight": "positive", "detail": "Compensation range stated"})
        positives += 1

    # --- Freshness ---
    age = _age_days(job.get("posted_at"), now)
    if age is None:
        signals.append({"signal": "posted_date_unknown", "weight": "neutral", "detail": "No posted date available"})
    elif age <= 3:
        signals.append({"signal": "freshly_posted", "weight": "positive", "detail": f"Posted {age:.0f} day(s) ago"})
        positives += 1
    elif age > max_job_age_days:
        # Shouldn't normally happen for a row that just passed the ingestion
        # freshness gate — this branch mainly protects backfill runs against
        # rows admitted under an older, looser max_job_age_days.
        signals.append({"signal": "stale_posting", "weight": "concerning", "detail": f"Posted {age:.0f} days ago"})
        concerns += 1

    # --- Application link present ---
    source = job.get("source") or ""
    if source not in _ALWAYS_HAS_LINK_SOURCES and not job.get("redirect_url"):
        signals.append({"signal": "no_application_link", "weight": "concerning", "detail": "No link back to the original posting"})
        concerns += 1

    if concerns >= 2:
        tier = SUSPICIOUS
    elif concerns == 1 and positives == 0:
        tier = PROCEED_WITH_CAUTION
    elif positives >= 2 and concerns == 0:
        tier = HIGH_CONFIDENCE
    else:
        # The deliberate middle default for anything ambiguous — mirrors
        # career-ops's "limited data available → Proceed with Caution, never
        # guess Suspicious."
        tier = PROCEED_WITH_CAUTION

    return {
        "tier": tier,
        "signals": signals,
        "contractor_language_note": _contractor_note(description),
    }


def _contractor_note(description: str) -> str | None:
    """Orthogonal to the tier (career-ops's own framing — see module
    docstring). Returns the matched phrase verbatim so the badge's detail
    view can show exactly what triggered it, or None."""
    match = _CONTRACTOR_LANGUAGE.search(description)
    return match.group(0) if match else None
