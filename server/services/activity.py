"""Phase 3: turns a profile's applications + tailored_resumes rows into
the "what the agent did on your behalf" feed ActivityLogScreen (and
Home's "Recent activity" section) render. Built from these existing
timelines rather than a new activity-log table, to avoid a write-path
change to daily_pipeline.py. Deliberately excludes jobs.ingested_at —
job ingestion is a global pipeline event shared by every user, not
something this specific user did.
"""

_STAGE_TITLES = {
    "saved": "Saved a job",
    "applied": "Marked as applied",
    "replied": "Got a reply",
    "interview": "Moved to interview",
    "offer": "Received an offer",
    "rejected": "Marked as rejected",
}


def _job_detail(job: dict | None) -> str:
    if not job:
        return "a job"
    title = job.get("title") or "a job"
    company = job.get("company")
    return f"{title} at {company}" if company else title


def build_activity_feed(applications: list[dict], tailored_resumes: list[dict]) -> list[dict]:
    """`applications` and `tailored_resumes` rows must already have `job`
    joined in (the `{**row, "job": {...}}` shape routers/applications.py
    and this module's caller both produce) — every entry needs a job
    title to be legible. Only the *current* state per application shows
    (state history isn't stored), plus a separate entry when a follow-up
    was drafted.
    """
    entries: list[dict] = []

    for app in applications:
        detail = _job_detail(app.get("job"))
        state = app["state"]
        entries.append(
            {
                "type": "stage_change",
                "stage": state,
                "title": _STAGE_TITLES.get(state, state.replace("_", " ").title()),
                "detail": detail,
                "timestamp": app["state_changed_at"],
            }
        )
        if app.get("followup_drafted_at"):
            entries.append(
                {
                    "type": "followup",
                    "title": "Drafted a follow-up",
                    "detail": detail,
                    "timestamp": app["followup_drafted_at"],
                }
            )

    for tr in tailored_resumes:
        entries.append(
            {
                "type": "tailored",
                "title": "Tailored a resume",
                "detail": _job_detail(tr.get("job")),
                "timestamp": tr["created_at"],
            }
        )

    entries.sort(key=lambda e: e["timestamp"], reverse=True)
    return entries
