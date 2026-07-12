"""Phase 14 / ADR-027: a Postgres-backed per-caller rate limiter for the
LLM-backed endpoints.

The shape is a FastAPI dependency factory. Two flavors, because callers are
identified two ways in this app:

  enforce_rate_limit("rerank", 5, 300)        -> keyed on the caller's PROFILE id
  enforce_rate_limit_by_user("resume_parse",  -> keyed on the caller's USER id
                             3, 300)              (POST /resume/parse runs before
                                                   a profile row exists — it's the
                                                   call that creates it — so there
                                                   is no profile to key on yet)

Either way the stored `subject` is just an opaque string; the table doesn't care
which kind of id it is (see migration 017).

Why a table and not an in-memory counter: Cloud Run runs N instances and an
in-process counter would grant N times the quota. Golden Rule 2 also applies —
this is pure counting logic, no LLM anywhere near it.

Deliberately NOT a token bucket or a sub-second sliding log. This is a coarse
abuse/cost guard for a beta with a handful of users; a fixed trailing-window
count is the right amount of machinery, and the whole check is one COUNT plus
one INSERT.
"""

from datetime import datetime, timedelta, timezone

from fastapi import Depends, HTTPException

from db.supabase_client import supabase
from services.auth import get_current_profile, get_current_user_id


class RateLimitExceeded(HTTPException):
    """429 with a Retry-After header. A distinct class so it reads clearly at
    the call site and in tests, but it IS an HTTPException so FastAPI renders it
    (and the client's api_client.dart surfaces the 429) without special
    handling."""

    def __init__(self, retry_after: int):
        super().__init__(
            status_code=429,
            detail="You're doing that too fast — please wait a few minutes and try again.",
            headers={"Retry-After": str(retry_after)},
        )


def _count_recent(subject: str, endpoint: str, window_start: datetime) -> int:
    result = (
        supabase.table("rate_limit_events")
        .select("id", count="exact")
        .eq("subject", subject)
        .eq("endpoint", endpoint)
        .gte("created_at", window_start.isoformat())
        .execute()
    )
    # supabase-py populates `.count` for a count="exact" query; fall back to
    # len(data) if a client version doesn't.
    return result.count if result.count is not None else len(result.data or [])


def _prune_old(subject: str, endpoint: str, window_start: datetime) -> None:
    """Opportunistic cleanup on each check — no separate cron needed. Only ever
    deletes THIS subject+endpoint's expired rows, so it's cheap and can't touch
    a row still inside anyone's window."""
    supabase.table("rate_limit_events").delete().eq("subject", subject).eq("endpoint", endpoint).lt(
        "created_at", window_start.isoformat()
    ).execute()


def check_rate_limit(subject: str, endpoint: str, limit: int, window_seconds: int) -> None:
    """The core, extracted from the dependency so it's testable without FastAPI.
    Raises RateLimitExceeded when the (limit+1)th request in the window arrives;
    otherwise records this request and returns.

    Order matters: prune first (so expired rows never count), then count, then —
    only if under the limit — insert. Inserting after the count check is what
    makes the Nth request pass and the (N+1)th fail, rather than off-by-one.
    """
    now = datetime.now(timezone.utc)
    window_start = now - timedelta(seconds=window_seconds)

    _prune_old(subject, endpoint, window_start)
    used = _count_recent(subject, endpoint, window_start)

    if used >= limit:
        # Coarse but honest: tell the client to wait one full window. Computing
        # the exact time the oldest event ages out would need another query for
        # a guess that's only ever a few minutes off anyway.
        raise RateLimitExceeded(retry_after=window_seconds)

    supabase.table("rate_limit_events").insert({"subject": subject, "endpoint": endpoint}).execute()


def enforce_rate_limit(endpoint: str, limit: int, window_seconds: int):
    """Dependency enforcing `limit` requests per `window_seconds` for
    `endpoint`, keyed on the authenticated caller's PROFILE id. FastAPI caches
    get_current_profile within a request, so sharing it with the endpoint's own
    `Depends(get_current_profile)` costs no extra DB round-trip.

    A limit <= 0 disables the check (an escape hatch for config/tests) rather
    than locking the endpoint out entirely.
    """

    async def _dependency(profile: dict = Depends(get_current_profile)) -> None:
        if limit <= 0:
            return
        check_rate_limit(profile["id"], endpoint, limit, window_seconds)

    return _dependency


def enforce_rate_limit_by_user(endpoint: str, limit: int, window_seconds: int):
    """Like enforce_rate_limit but keyed on the auth USER id — for endpoints
    that must run before a profile exists (POST /resume/parse). Keying on the
    user id means even the very first parse, and any FAILED parse that never
    creates a profile, still counts against the limit — closing the "spam the
    vision model with garbage PDFs" gap a profile-scoped limit would leave open.
    """

    async def _dependency(user_id: str = Depends(get_current_user_id)) -> None:
        if limit <= 0:
            return
        check_rate_limit(user_id, endpoint, limit, window_seconds)

    return _dependency
