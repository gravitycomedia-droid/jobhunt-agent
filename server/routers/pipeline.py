from fastapi import APIRouter, Depends, Header, HTTPException

from config import settings
from jobs.daily_pipeline import run_daily_pipeline_for_all, run_daily_pipeline_for_profile
from services.auth import get_current_profile

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


@router.post("/run-mine")
async def run_pipeline_for_me(profile: dict = Depends(get_current_profile)):
    """The authenticated "Run agent now" trigger from the Flutter app —
    refreshes the shared job pool and processes only the caller's own
    profile, not every beta user's (that's POST /pipeline/run, cron-only).
    """
    summary = await run_daily_pipeline_for_profile(profile)
    return {"data": summary, "error": None}
