from datetime import datetime, timedelta, timezone

from models.job import JobIn
from services.job_ingestion import is_fresh


def _job(posted_at) -> JobIn:
    return JobIn(source="adzuna", external_id="x", title="Engineer", posted_at=posted_at)


NOW = datetime(2026, 7, 10, tzinfo=timezone.utc)


def test_recent_job_is_fresh():
    assert is_fresh(_job(NOW - timedelta(days=5)), now=NOW)


def test_job_older_than_60_days_is_stale():
    assert not is_fresh(_job(NOW - timedelta(days=61)), now=NOW)


def test_2591_day_old_job_is_stale():
    # The observed bug: a ~7-year-old posting rendered as "2591d ago".
    assert not is_fresh(_job(NOW - timedelta(days=2591)), now=NOW)


def test_unknown_posted_at_passes():
    # Missing date ≠ stale — the app shows "date unknown" instead.
    assert is_fresh(_job(None), now=NOW)


def test_naive_datetime_treated_as_utc():
    assert is_fresh(_job(datetime(2026, 7, 1)), now=NOW)
