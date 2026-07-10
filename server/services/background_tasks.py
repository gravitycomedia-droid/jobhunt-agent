"""Async job pattern (ADR-010): long-running work runs in a FastAPI
background task while the endpoint returns 202 + a task id immediately.
Progress lives in the `background_tasks` table (migration 009); the client
polls GET /tasks/{id}.

Golden Rule 2: all state transitions here are plain Python — pending →
running → done|failed, enforced by the table's CHECK constraint.
"""

import inspect
import logging
import traceback
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable

from db.supabase_client import supabase

logger = logging.getLogger(__name__)

TaskFn = Callable[[], dict | Awaitable[dict]]


def create_task(profile_id: str, task_type: str) -> dict:
    """Inserts a `pending` background_tasks row and returns it."""
    return (
        supabase.table("background_tasks")
        .insert({"profile_id": profile_id, "task_type": task_type, "status": "pending"})
        .execute()
        .data[0]
    )


def get_task(task_id: str, profile_id: str) -> dict | None:
    """Ownership-checked read — returns None for missing OR not-yours, so
    the router can 404 both identically (no existence leak)."""
    rows = (
        supabase.table("background_tasks")
        .select("*")
        .eq("id", task_id)
        .eq("profile_id", profile_id)
        .limit(1)
        .execute()
        .data
    )
    return rows[0] if rows else None


def _set_status(task_id: str, status: str, *, result: dict | None = None, error: str | None = None) -> None:
    supabase.table("background_tasks").update(
        {
            "status": status,
            "result": result,
            "error": error,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
    ).eq("id", task_id).execute()


async def run_task(task_id: str, fn: TaskFn) -> None:
    """Wrapper scheduled via FastAPI BackgroundTasks: marks the row running,
    executes fn (sync or async), records done+result or failed+error. Never
    raises — a background task has no response to propagate into.
    """
    _set_status(task_id, "running")
    try:
        result = fn()
        if inspect.isawaitable(result):
            result = await result
        _set_status(task_id, "done", result=result)
    except Exception as e:  # noqa: BLE001 — must catch everything; the error goes to the row
        logger.error("background task %s failed: %s\n%s", task_id, e, traceback.format_exc())
        _set_status(task_id, "failed", error=str(e))
