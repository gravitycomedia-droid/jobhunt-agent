"""Phase 4: the single per-profile ownership check the new routes share.

Every "fetch one row by id" route (mark a notification read, open a chat thread)
must return 404 — not 403 — when the row belongs to someone else, so a caller
can't even probe which ids exist. Scoping the query by profile_id AND id makes
"not yours" and "not there" indistinguishable, which is the point.

FastAPI's per-profile scoping is the real authorization boundary in this app
(RLS is defense-in-depth only — see services/auth.py); this helper is where that
boundary lives for single-row reads."""

from fastapi import HTTPException

from db.supabase_client import supabase


def fetch_owned_or_404(table: str, row_id: str, profile_id: str, *, select: str = "*", detail: str = "Not found") -> dict:
    """Return the row iff it exists AND belongs to profile_id, else raise 404.

    The two .eq() filters are the whole security property: a cross-user id
    resolves to zero rows exactly like a nonexistent one, so both surface as the
    same 404 with no information leak."""
    rows = (
        supabase.table(table)
        .select(select)
        .eq("id", row_id)
        .eq("profile_id", profile_id)
        .limit(1)
        .execute()
        .data
    )
    if not rows:
        raise HTTPException(status_code=404, detail=detail)
    return rows[0]
