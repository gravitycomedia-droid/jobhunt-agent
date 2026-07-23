"""Phase 4: the fit-score delta chip (R-D). Pins that the delta is day-over-day
(against the latest snapshot >=24h older), stays None until such a prior exists,
and is never fabricated from near-simultaneous refresh snapshots."""

from datetime import datetime, timedelta, timezone

from services.score_history import compute_score_history

NOW = datetime(2026, 7, 23, 12, 0, tzinfo=timezone.utc)


def _snap(when, top, avg=50.0, count=10):
    return {
        "captured_at": when.isoformat(),
        "top_fit_score": top,
        "avg_fit_score": avg,
        "match_count": count,
    }


def test_no_snapshots_returns_empty():
    out = compute_score_history([])
    assert out == {"current": None, "delta": None, "history": []}


def test_single_snapshot_has_no_delta():
    out = compute_score_history([_snap(NOW, 80)])
    assert out["current"]["top_fit_score"] == 80
    assert out["delta"] is None  # nothing to diff against → hide the chip


def test_two_snapshots_minutes_apart_still_no_delta():
    """R-D's core failure mode: three refreshes in a minute must NOT produce a
    ~0 delta. Snapshots <24h apart yield no delta at all."""
    snaps = [_snap(NOW - timedelta(minutes=6), 79), _snap(NOW - timedelta(minutes=3), 80), _snap(NOW, 81)]
    out = compute_score_history(snaps)
    assert out["current"]["top_fit_score"] == 81
    assert out["delta"] is None


def test_delta_against_snapshot_at_least_24h_older():
    snaps = [_snap(NOW - timedelta(days=1, hours=1), 74), _snap(NOW, 80)]
    out = compute_score_history(snaps)
    assert out["delta"] == {"top_fit": 6, "avg_fit": 0.0}


def test_delta_picks_the_freshest_qualifying_prior():
    """With a valid ≥24h-older snapshot AND noise from same-day refreshes, the
    prior used is the freshest one that still clears the 24h cutoff."""
    snaps = [
        _snap(NOW - timedelta(days=3), 60),        # older still, ignored
        _snap(NOW - timedelta(days=1, hours=2), 70),  # the qualifying prior
        _snap(NOW - timedelta(minutes=5), 79),     # too recent to be the prior
        _snap(NOW, 82),                            # current
    ]
    out = compute_score_history(snaps)
    assert out["current"]["top_fit_score"] == 82
    assert out["delta"]["top_fit"] == 12  # 82 - 70, not 82 - 79


def test_history_is_ordered_oldest_to_newest():
    snaps = [_snap(NOW, 82), _snap(NOW - timedelta(days=2), 60), _snap(NOW - timedelta(days=1), 70)]
    out = compute_score_history(snaps)
    tops = [p["top_fit_score"] for p in out["history"]]
    assert tops == [60, 70, 82]


def test_negative_delta_when_score_dropped():
    snaps = [_snap(NOW - timedelta(days=1, hours=1), 85, avg=60.0), _snap(NOW, 80, avg=55.0)]
    out = compute_score_history(snaps)
    assert out["delta"] == {"top_fit": -5, "avg_fit": -5.0}
