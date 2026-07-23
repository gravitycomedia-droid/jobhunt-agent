"""Phase 4: account-level endpoints — subscription status, the cosmetic wallet
(§4.12), and account deletion (§4.15).

Subscription and wallet are two different things the UI shows on one screen but
the code keeps apart: subscription_tier is the only real entitlement
(services/entitlements.py), the wallet is display-only telemetry that never
gates (R-B, services/wallet.py)."""

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException

from db.supabase_client import supabase
from services.auth import get_current_profile
from services.wallet import compute_wallet

router = APIRouter(tags=["account"])


@router.get("/subscription")
async def get_subscription(profile: dict = Depends(get_current_profile)):
    """The caller's plan state. tier is what actually gates things; status and
    period_end are lifecycle display fields for the billing card."""
    return {
        "data": {
            "tier": profile.get("subscription_tier") or "pro",
            "status": profile.get("subscription_status") or "active",
            "period_end": profile.get("subscription_period_end"),
        },
        "error": None,
    }


@router.get("/wallet")
async def get_wallet(profile: dict = Depends(get_current_profile)):
    """The cosmetic credits meter. Derived live from this profile's recent
    llm_calls — never a stored counter — so it moves with real spend and resets
    on the period rollover on its own (R-B). `estimated` is inside data (R-C).
    This number NEVER gates anything."""
    # A ~40-day trailing window comfortably covers any monthly period start
    # compute_wallet might pick (period_end − 30d, or the rollover boundary).
    since = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat()
    rows = (
        supabase.table("llm_calls")
        .select("model,tokens_in,tokens_out,created_at")
        .eq("profile_id", profile["id"])
        .gte("created_at", since)
        .execute()
        .data
    )
    return {"data": compute_wallet(profile, rows), "error": None}


@router.delete("/account")
async def delete_account(profile: dict = Depends(get_current_profile)):
    """Irreversibly delete the caller's account (§4.15 — the client gates this
    behind a HoldButton, never a plain tap). Deleting the profile row cascades
    to every table that FKs profiles ON DELETE CASCADE (applications, matches,
    tailored_resumes, notifications, chat_threads/messages, score_snapshots,
    form_fills, background_tasks). llm_calls is FK ON DELETE SET NULL by design
    (migration 006): those rows anonymize rather than vanish, so aggregate cost
    telemetry survives without staying linked to a deleted person. Finally the
    Supabase auth user is removed so the login can't return — profiles.user_id
    is a value link, not a FK, so this does NOT cascade and must be explicit."""
    profile_id = profile["id"]
    user_id = profile.get("user_id")

    supabase.table("profiles").delete().eq("id", profile_id).execute()

    if user_id:
        try:
            supabase.auth.admin.delete_user(user_id)
        except Exception as e:
            # Data is already gone; a lingering auth user with no profile can't
            # read anything (every route 404s on get_current_profile). Surface
            # it so it can be retried/cleaned, rather than pretending success.
            raise HTTPException(
                status_code=502,
                detail="Your data was deleted, but removing the sign-in failed. Contact support to finish.",
            ) from e

    return {"data": {"deleted": True}, "error": None}
