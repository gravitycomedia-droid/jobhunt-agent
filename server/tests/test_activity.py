from services.activity import build_activity_feed

_JOB = {"id": "job-1", "title": "Backend Engineer", "company": "Acme"}


def test_build_activity_feed_sorts_newest_first():
    applications = [
        {
            "job_id": "job-1",
            "job": _JOB,
            "state": "applied",
            "state_changed_at": "2026-07-01T10:00:00+00:00",
            "followup_drafted_at": None,
        }
    ]
    tailored = [
        {"job_id": "job-1", "job": _JOB, "created_at": "2026-07-05T10:00:00+00:00"},
    ]

    feed = build_activity_feed(applications, tailored)

    assert [e["type"] for e in feed] == ["tailored", "stage_change"]
    assert feed[0]["timestamp"] == "2026-07-05T10:00:00+00:00"


def test_build_activity_feed_adds_followup_entry_when_drafted():
    applications = [
        {
            "job_id": "job-1",
            "job": _JOB,
            "state": "applied",
            "state_changed_at": "2026-07-01T10:00:00+00:00",
            "followup_drafted_at": "2026-07-08T10:00:00+00:00",
        }
    ]

    feed = build_activity_feed(applications, [])

    assert len(feed) == 2
    followup = next(e for e in feed if e["type"] == "followup")
    assert followup["detail"] == "Backend Engineer at Acme"


def test_build_activity_feed_handles_missing_job_gracefully():
    applications = [
        {
            "job_id": "missing",
            "job": None,
            "state": "saved",
            "state_changed_at": "2026-07-01T10:00:00+00:00",
            "followup_drafted_at": None,
        }
    ]

    feed = build_activity_feed(applications, [])

    assert feed[0]["detail"] == "a job"
    assert feed[0]["title"] == "Saved a job"
