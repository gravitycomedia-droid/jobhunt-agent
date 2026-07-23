"""Phase 4: the grounded career-assistant chat (§ chat).

POST /chat follows the async pattern (ADR-011): persist the user's turn, kick
the LLM work into the background, and return 202 + a task the client polls via
GET /tasks/{id}. The reply is written to chat_messages when the task finishes.

Chat is the pro-gated feature — require_tier_dep("pro") means flipping
DEFAULT_TIER=free returns 402 here (the Phase 4 acceptance). It's also
rate-limited like every other LLM endpoint."""

from fastapi import APIRouter, BackgroundTasks, Depends
from pydantic import Field

from config import settings
from db.supabase_client import supabase
from models.common import StrictModel
from services.auth import get_current_profile
from services.background_tasks import create_task, run_task
from services.chat import run_chat_turn
from services.entitlements import require_tier_dep
from services.ownership import fetch_owned_or_404
from services.rate_limit import enforce_rate_limit

router = APIRouter(prefix="/chat", tags=["chat"])

MAX_CHAT_MESSAGE_LEN = 4000


class ChatSend(StrictModel):
    message: str = Field(min_length=1, max_length=MAX_CHAT_MESSAGE_LEN)
    # Omit to start a new thread; pass an existing (owned) thread id to continue.
    thread_id: str | None = None


@router.post(
    "",
    status_code=202,
    dependencies=[
        Depends(enforce_rate_limit("chat", settings.rate_limit_chat, settings.rate_limit_window_seconds)),
        Depends(require_tier_dep("pro")),
    ],
)
async def send_message(body: ChatSend, background: BackgroundTasks, profile: dict = Depends(get_current_profile)):
    profile_id = profile["id"]

    if body.thread_id:
        # Continue an existing thread — 404 if it isn't the caller's.
        thread = fetch_owned_or_404("chat_threads", body.thread_id, profile_id, select="id", detail="Thread not found")
        thread_id = thread["id"]
    else:
        # New conversation; seed the title from the first message.
        thread = (
            supabase.table("chat_threads")
            .insert({"profile_id": profile_id, "title": body.message[:60]})
            .execute()
            .data[0]
        )
        thread_id = thread["id"]

    # Persist the user turn now so it's in history even if the LLM task fails.
    supabase.table("chat_messages").insert(
        {"thread_id": thread_id, "profile_id": profile_id, "role": "user", "content": body.message}
    ).execute()

    task = create_task(profile_id, "chat")
    background.add_task(run_task, task["id"], lambda: run_chat_turn(profile, thread_id, body.message))
    return {"data": {**task, "thread_id": thread_id}, "error": None}


@router.get("/threads")
async def list_threads(profile: dict = Depends(get_current_profile)):
    """This profile's conversations, most-recently-active first."""
    rows = (
        supabase.table("chat_threads")
        .select("*")
        .eq("profile_id", profile["id"])
        .order("updated_at", desc=True)
        .execute()
        .data
    )
    return {"data": rows, "error": None}


@router.get("/threads/{thread_id}")
async def get_thread(thread_id: str, profile: dict = Depends(get_current_profile)):
    """One thread with its messages oldest-first. 404 if it isn't the caller's."""
    thread = fetch_owned_or_404("chat_threads", thread_id, profile["id"], detail="Thread not found")
    messages = (
        supabase.table("chat_messages")
        .select("*")
        .eq("thread_id", thread_id)
        .eq("profile_id", profile["id"])
        .order("created_at")
        .execute()
        .data
    )
    return {"data": {"thread": thread, "messages": messages}, "error": None}
