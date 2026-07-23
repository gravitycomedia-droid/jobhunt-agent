"""Phase 4 (frontend rebuild v2): the fit-score delta chip (R-D).

score_snapshots (migration 020) gets a row on every pipeline run — batch AND
per-user run-mine. run-mine is rate-limited to 5/300s, so a user refreshing
three times a minute writes three snapshots minutes apart. Diffing the newest
against the immediately-previous row would therefore be ~0 almost always and the
chip would be permanently meaningless.

So the READ diffs against the latest snapshot AT LEAST 24h older than the newest
one — day-over-day, which was the point. Until such a prior snapshot exists the
delta is None and the client hides the chip entirely (never a fabricated 0).

Golden Rule 2: the delta is subtraction in Python, not an LLM's guess.
"""

from datetime import datetime, timedelta, timezone

_MIN_AGE = timedelta(hours=24)


def _parse_ts(value) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _point(row: dict) -> dict:
    return {
        "captured_at": row.get("captured_at"),
        "top_fit_score": row.get("top_fit_score"),
        "avg_fit_score": row.get("avg_fit_score"),
        "match_count": row.get("match_count"),
    }


def compute_score_history(snapshots: list[dict], now: datetime | None = None) -> dict:
    """Pure. `snapshots` are this profile's score_snapshots rows in any order.
    Returns what GET /stats/score-history wraps in the envelope:

        {"current": <newest point or None>,
         "delta":   {"top_fit": int, "avg_fit": float} | None,   # None → hide the chip
         "history": [<points oldest→newest, for the sparkline>]}
    """
    dated = [(ts, r) for r in snapshots if (ts := _parse_ts(r.get("captured_at"))) is not None]
    dated.sort(key=lambda pair: pair[0])  # oldest → newest

    if not dated:
        return {"current": None, "delta": None, "history": []}

    current_ts, current = dated[-1]
    history = [_point(r) for _, r in dated]

    # Latest snapshot at least 24h older than the current one. Walking backwards
    # from the newest returns the freshest qualifying prior — the tightest true
    # day-over-day comparison available.
    cutoff = current_ts - _MIN_AGE
    prior = next((r for ts, r in reversed(dated) if ts <= cutoff), None)

    delta = None
    if prior is not None:
        delta = {
            "top_fit": (current.get("top_fit_score") or 0) - (prior.get("top_fit_score") or 0),
            "avg_fit": round((current.get("avg_fit_score") or 0.0) - (prior.get("avg_fit_score") or 0.0), 2),
        }

    return {"current": _point(current), "delta": delta, "history": history}
