from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException

from config import settings
from jobs.daily_pipeline import run_daily_pipeline_for_all, run_daily_pipeline_for_profile
from services.auth import get_current_profile
from services.background_tasks import create_task, run_task

router = APIRouter(prefix="/pipeline", tags=["pipeline"])


@router.post("/run")
async def run_pipeline_for_all(x_pipeline_secret: str | None = Header(default=None)):
    """The Render cron path (Brick 9): runs the agent loop for every beta
    user. There's no per-user session to authenticate a cron job with, so
    this is guarded by a shared secret (PIPELINE_SECRET) instead of
    services/auth.py's JWT check — set X-Pipeline-Secret on the Render cron
    job's request to match server/.env's PIPELINE_SECRET.
    """
    if not settings.pipeline_secret or x_pipeline_secret != settings.pipeline_secret:
        raise HTTPException(status_code=401, detail="Invalid or missing X-Pipeline-Secret")
    summary = await run_daily_pipeline_for_all()
    return {"data": summary, "error": None}


@router.post("/run-mine", status_code=202)
async def run_pipeline_for_me(background: BackgroundTasks, profile: dict = Depends(get_current_profile)):
    """The authenticated "Run agent now" trigger from the Flutter app —
    refreshes the shared job pool and processes only the caller's own
    profile, not every beta user's (that's POST /pipeline/run, cron-only).

    ADR-011: same async job pattern as POST /matches/rerank — the full loop
    (fetch + embed + rerank) runs for minutes, so return a task id and let
    the client poll GET /tasks/{id}. The cron path above stays synchronous:
    Render's cron runner has no socket-timeout problem.
    """
    task = create_task(profile["id"], "pipeline")
    background.add_task(run_task, task["id"], lambda: run_daily_pipeline_for_profile(profile))
    return {"data": {"task_id": task["id"]}, "error": None}
