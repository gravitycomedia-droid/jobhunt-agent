from fastapi import APIRouter, Depends, HTTPException

from services.auth import get_current_profile
from services.background_tasks import get_task

router = APIRouter(prefix="/tasks", tags=["tasks"])


@router.get("/{task_id}")
async def task_status(task_id: str, profile: dict = Depends(get_current_profile)):
    """Polling endpoint for the async job pattern (ADR-010). Ownership is
    enforced in the query itself — someone else's task id 404s exactly like
    a nonexistent one."""
    task = get_task(task_id, profile["id"])
    if task is None:
        raise HTTPException(status_code=404, detail="Task not found")
    return {"data": task, "error": None}
