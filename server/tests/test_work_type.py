"""Phase 4: jobs.work_type classification (migration 019 backfill + ingestion
hook). Remote reuses is_remote; hybrid needs an explicit signal; everything else
is None ('unknown'), never a guessed 'onsite'."""

from services.job_filter import classify_work_type


def test_remote_from_location():
    assert classify_work_type("Remote", "Backend Intern") == "remote"
    assert classify_work_type("Work from home") == "remote"


def test_hybrid_from_any_field():
    assert classify_work_type("Bangalore (Hybrid)", "Dev") == "hybrid"
    assert classify_work_type("Bangalore", "Hybrid Frontend Intern") == "hybrid"


def test_remote_wins_over_hybrid_when_both_present():
    # is_remote is checked first; a "remote-first, occasionally hybrid" posting
    # reads as remote, which is the more permissive/accurate filter bucket.
    assert classify_work_type("Remote", "Hybrid option available") == "remote"


def test_plain_onsite_is_unknown_not_guessed():
    assert classify_work_type("Bangalore", "Backend Intern") is None
    assert classify_work_type(None, None, None) is None
