"""Per-source ingestion health check + ops alert (plan 15, Phase F).

The daily cron fetches jobs from ~6 sources. When one quietly stops returning
data — an Apify actor gets deprecated, a public board moves its endpoint, a
scraper gets blocked — nothing crashes: the source just yields [] and the pool
silently narrows. This module is the smoke detector for exactly that.

Golden rule 2 (code handles logic, not the LLM): every threshold here is plain
Python arithmetic. There is no model in the loop and there must never be one —
"is this count anomalously low" is a comparison, not a judgement call.

Two halves, split so the decision logic is unit-testable without a database:
  - evaluate_ingestion_health(): PURE. Given today's counts and the trailing
    per-source averages, returns the sources worth alerting on. No I/O.
  - record_and_alert_ingestion(): the I/O shell. Writes the log rows, reads the
    trailing window back, calls the pure evaluator, and emails on any flag.
"""

import logging
from dataclasses import dataclass
from datetime import date, timedelta

from db.supabase_client import supabase
from services.email import send_ops_alert

logger = logging.getLogger(__name__)

# A source is flagged "low" when today's raw count falls below this fraction of
# its own trailing average. 0.2 = an 80% drop — loose enough that normal
# day-to-day variance (a board posting fewer roles today) doesn't cry wolf, tight
# enough to catch a source that's collapsed to a trickle without hitting exactly
# zero. Settings-driveable later if the beta's real variance demands it; a module
# constant for now, since there's no live data to tune against yet.
ANOMALY_FRACTION = 0.2

# How many prior days form the "normal" baseline. Excludes today.
TRAILING_DAYS = 7


@dataclass(frozen=True)
class SourceFlag:
    """One source worth alerting on, with a human-readable reason for the email."""

    source: str
    item_count: int
    reason: str


def evaluate_ingestion_health(
    today: list[dict],
    trailing_avgs: dict[str, float],
    anomaly_fraction: float = ANOMALY_FRACTION,
) -> list[SourceFlag]:
    """Pure: decide which of today's sources to alert on. No I/O, no clock.

    `today` is a list of {source, item_count, status, error_message} — one per
    source that actually RAN today (a source not due today isn't in here, so it
    can't be mis-flagged as "returned zero"). `trailing_avgs` maps source →
    average raw item_count over the trailing window, for sources with history.

    Three flag conditions, checked in this order so the reason is the most
    specific true one:
      1. status == 'error'  → the fetch raised. Always alert, regardless of
         count — a crashed source is a problem even at count 0 with no history.
      2. item_count == 0     → the source ran cleanly and returned nothing. The
         canonical "source went dark" signal.
      3. count < fraction × trailing_avg → an anomalous drop against this
         source's own norm (only when a positive baseline exists to compare to;
         a brand-new source with no history can't be "low", only "zero").
    """
    flags: list[SourceFlag] = []
    for row in today:
        source = row["source"]
        count = row.get("item_count") or 0
        status = row.get("status", "ok")

        if status == "error":
            detail = row.get("error_message") or "unknown error"
            flags.append(SourceFlag(source, count, f"fetch failed: {detail}"))
            continue

        if count == 0:
            flags.append(SourceFlag(source, count, "returned 0 items"))
            continue

        avg = trailing_avgs.get(source)
        if avg and avg > 0 and count < anomaly_fraction * avg:
            flags.append(
                SourceFlag(
                    source,
                    count,
                    f"returned {count} vs {avg:.0f} avg over the last {TRAILING_DAYS}d "
                    f"({count / avg:.0%} of normal)",
                )
            )

    return flags


def _format_alert(run_date: date, flags: list[SourceFlag]) -> tuple[str, str]:
    """(subject, body) for the ops email. Plain text — this goes to an inbox, not
    a UI, so no HTML and no branding."""
    subject = f"[JobHunt] {len(flags)} ingestion source(s) unhealthy on {run_date.isoformat()}"
    lines = [
        f"Ingestion health alert for the {run_date.isoformat()} pipeline run.",
        "",
        "The following sources need a look:",
        "",
    ]
    lines += [f"  • {flag.source}: {flag.reason}" for flag in flags]
    lines += [
        "",
        "This is automated observability, not a user-facing message. A source",
        "showing 0 items usually means its actor/endpoint changed or it's being",
        "blocked — check services/job_sources.py and the source's status.",
    ]
    return subject, "\n".join(lines)


def _trailing_averages(sources: list[str], run_date: date) -> dict[str, float]:
    """Average raw item_count per source over the TRAILING_DAYS days BEFORE
    run_date. Excludes today (the row we just wrote) and excludes 'error' rows,
    whose count of 0 would drag the baseline down and mask a later real drop.

    Averaged in Python rather than SQL: the window is ~7 days × ~6 sources ≈ 42
    rows, far too small to justify a Postgres aggregate/RPC, and keeping it here
    means the whole module tests against a plain list of dicts.
    """
    if not sources:
        return {}
    start = (run_date - timedelta(days=TRAILING_DAYS)).isoformat()
    end = run_date.isoformat()  # exclusive upper bound → excludes today
    rows = (
        supabase.table("source_ingestion_log")
        .select("source,item_count,status")
        .in_("source", sources)
        .gte("run_date", start)
        .lt("run_date", end)
        .execute()
        .data
    ) or []

    sums: dict[str, int] = {}
    counts: dict[str, int] = {}
    for row in rows:
        if row.get("status") == "error":
            continue
        src = row["source"]
        sums[src] = sums.get(src, 0) + (row.get("item_count") or 0)
        counts[src] = counts.get(src, 0) + 1

    return {src: sums[src] / counts[src] for src in sums if counts[src]}


def record_and_alert_ingestion(
    run_date: date,
    by_source: dict[str, int],
    errored: dict[str, str] | None = None,
) -> list[SourceFlag]:
    """The I/O shell (cron-only caller): write today's per-source counts to
    source_ingestion_log, then evaluate health against the trailing window and
    email OPS_ALERT_EMAIL on any flag.

    `by_source` maps source → raw fetched count for every source that ran.
    `errored` maps source → error string for any source whose fetch raised;
    those get status='error' and item_count 0, and are always flagged.

    Never raises: the caller wraps this in a try too, but a health check that
    can sink the pipeline it monitors is worse than useless, so failures here
    log and return [] rather than propagating.
    """
    errored = errored or {}
    if not by_source and not errored:
        return []

    today_rows: list[dict] = []
    for source, count in by_source.items():
        # An errored source overrides its count row — status must say 'error'
        # even if some partial count leaked through.
        if source in errored:
            continue
        today_rows.append({"source": source, "item_count": count, "status": "ok", "error_message": None})
    for source, message in errored.items():
        today_rows.append({"source": source, "item_count": 0, "status": "error", "error_message": message})

    try:
        payload = [{**row, "run_date": run_date.isoformat()} for row in today_rows]
        supabase.table("source_ingestion_log").insert(payload).execute()
    except Exception:
        # If we can't even record the counts we certainly can't trust a trailing
        # average, so log and bail rather than alert on half-written data.
        logger.exception("Failed to write source_ingestion_log for %s", run_date)
        return []

    trailing = _trailing_averages([row["source"] for row in today_rows], run_date)
    flags = evaluate_ingestion_health(today_rows, trailing)

    if flags:
        subject, body = _format_alert(run_date, flags)
        logger.warning("Ingestion health: %d source(s) flagged — %s", len(flags), subject)
        send_ops_alert(subject, body)
    else:
        logger.info("Ingestion health: all %d source(s) nominal on %s", len(today_rows), run_date)

    return flags
