"""Posting-legitimacy scoring (services/job_legitimacy.py, ADR-055).

Career-ops integration Brick 1. Cases below mirror the real shape of this
pool: most rows carry no salary at all (see ADR-054), so absence must never
be penalized — only presence is credited. The spam patterns are drawn from
what actually recurs in the India-heavy Unstop/Internshala pool, not
career-ops's own US/EU-oriented signals.
"""

from datetime import datetime, timedelta, timezone

from services.job_legitimacy import (
    HIGH_CONFIDENCE,
    PROCEED_WITH_CAUTION,
    SUSPICIOUS,
    score_posting,
)

NOW = datetime(2026, 8, 3, tzinfo=timezone.utc)

DETAILED_JD = (
    "We are looking for a Backend Engineer to join our 6-person platform team. "
    "You will design and ship APIs used by our mobile app, own our PostgreSQL "
    "schema migrations, and pair with the founding engineer on system design. "
    "Requirements: 2+ years with Python or Node, comfort with SQL, and a "
    "portfolio of shipped projects. This is a fully remote role reporting "
    "directly to the CTO, with a 90-day roadmap covering the payments "
    "rewrite and the new notifications service."
)


def _job(**overrides) -> dict:
    base = {
        "title": "Backend Engineer",
        "description": DETAILED_JD,
        "salary_min": 800000,
        "salary_max": 1200000,
        "posted_at": NOW - timedelta(days=1),
        "redirect_url": "https://boards.greenhouse.io/acme/jobs/123",
        "source": "greenhouse",
    }
    base.update(overrides)
    return base


def test_detailed_fresh_salaried_posting_is_high_confidence():
    result = score_posting(_job(), now=NOW)
    assert result["tier"] == HIGH_CONFIDENCE


def test_missing_salary_alone_is_not_penalized():
    # Most of the pool has no salary at all (ADR-054) — absence must not
    # drag an otherwise-solid posting down.
    result = score_posting(_job(salary_min=None, salary_max=None), now=NOW)
    assert result["tier"] in (HIGH_CONFIDENCE, PROCEED_WITH_CAUTION)
    assert not any(s["signal"] == "salary_disclosed" for s in result["signals"])


def test_empty_description_is_flagged_but_not_suspicious_alone():
    result = score_posting(_job(description=""), now=NOW)
    assert result["tier"] == PROCEED_WITH_CAUTION
    assert any(s["signal"] == "description_missing" for s in result["signals"])


def test_vague_short_description_with_no_link_is_suspicious():
    # Two independent concerning signals (vague JD + no application link)
    # is what pushes past "one flag, benefit of the doubt".
    result = score_posting(
        _job(description="Urgent hiring for freshers, apply now!", redirect_url=None, source="unstop"),
        now=NOW,
    )
    assert result["tier"] == SUSPICIOUS


def test_spam_earn_per_day_pattern_overrides_everything():
    result = score_posting(
        _job(description=DETAILED_JD + " Earn upto ₹5000 per day, work from home!"),
        now=NOW,
    )
    assert result["tier"] == SUSPICIOUS
    assert any(s["signal"] == "spam_pattern" for s in result["signals"])


def test_registration_fee_pattern_is_suspicious():
    result = score_posting(_job(description="Selected candidates must pay a registration fee required before onboarding."), now=NOW)
    assert result["tier"] == SUSPICIOUS


def test_unknown_posted_date_alone_is_neutral_not_concerning():
    result = score_posting(_job(posted_at=None), now=NOW)
    # Losing the freshness positive drops it out of high_confidence, but an
    # unknown date is never itself a concerning signal — career-ops's own
    # "never default to Suspicious without evidence" rule.
    assert result["tier"] != SUSPICIOUS
    assert any(s["signal"] == "posted_date_unknown" and s["weight"] == "neutral" for s in result["signals"])


def test_stale_posting_beyond_max_age_is_concerning():
    result = score_posting(_job(posted_at=NOW - timedelta(days=45), description=""), now=NOW, max_job_age_days=10)
    assert result["tier"] == SUSPICIOUS  # stale + empty description = two concerns


def test_manual_source_never_flagged_for_missing_link():
    # A user-pasted job legitimately has no redirect_url to check.
    result = score_posting(_job(redirect_url=None, source="manual"), now=NOW)
    assert not any(s["signal"] == "no_application_link" for s in result["signals"])


def test_contractor_language_note_is_orthogonal_to_tier():
    result = score_posting(
        _job(description=DETAILED_JD + " This role is offered as an independent contractor engagement; invoice for services monthly."),
        now=NOW,
    )
    # Still a detailed, salaried, fresh, linked posting — the contractor note
    # rides alongside high_confidence rather than downgrading it.
    assert result["tier"] == HIGH_CONFIDENCE
    assert result["contractor_language_note"] is not None


def test_no_contractor_language_returns_none():
    result = score_posting(_job(), now=NOW)
    assert result["contractor_language_note"] is None
