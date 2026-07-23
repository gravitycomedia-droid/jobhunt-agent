"""Phase 4: the in-app notification feed (§4.13). Persistent record behind the
FCM push (Brick 8) — a push is ephemeral, these rows give the bell icon history
and an unread count. Writes happen in the pipeline (services hook); this router
only reads and marks-read."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query

from db.supabase_client import supabase
from services.auth import get_current_profile
from services.ownership import fetch_owned_or_404

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("")
async def list_notifications(limit: int = Query(50, le=100), profile: dict = Depends(get_current_profile)):
    """This profile's notifications newest-first, plus the unread count. The
    count lives INSIDE data (not beside it) so the response keeps the standard
    {"data": ..., "error": null} envelope — same principle as the wallet's
    `estimated` flag (R-C)."""
    profile_id = profile["id"]
    items = (
        supabase.table("notifications")
        .select("*")
        .eq("profile_id", profile_id)
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
        .data
    )
    unread = (
        supabase.table("notifications")
        .select("id", count="exact")
        .eq("profile_id", profile_id)
        .is_("read_at", "null")
        .execute()
    )
    unread_count = unread.count if unread.count is not None else len(unread.data or [])
    return {"data": {"items": items, "unread_count": unread_count}, "error": None}


@router.patch("/{notification_id}/read")
async def mark_read(notification_id: str, profile: dict = Depends(get_current_profile)):
    """Mark one notification read. 404 (not 403) if it isn't the caller's — the
    ownership check makes "not yours" and "not there" indistinguishable."""
    fetch_owned_or_404("notifications", notification_id, profile["id"], select="id", detail="Notification not found")
    now = datetime.now(timezone.utc).isoformat()
    updated = (
        supabase.table("notifications")
        .update({"read_at": now})
        .eq("id", notification_id)
        .eq("profile_id", profile["id"])
        .execute()
        .data
    )
    return {"data": updated[0] if updated else None, "error": None}


@router.post("/read-all")
async def mark_all_read(profile: dict = Depends(get_current_profile)):
    """Clear the whole unread badge in one call. Only touches this profile's
    still-unread rows (read_at is null), so re-running it is a no-op."""
    now = datetime.now(timezone.utc).isoformat()
    updated = (
        supabase.table("notifications")
        .update({"read_at": now})
        .eq("profile_id", profile["id"])
        .is_("read_at", "null")
        .execute()
        .data
    )
    return {"data": {"updated": len(updated or [])}, "error": None}
