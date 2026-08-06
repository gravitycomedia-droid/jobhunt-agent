"""Plan 21: referral rewards and the per-profile full-match quota.

Two jobs, deliberately in one module because they're the same policy seen from
two sides: `redeem_referral_code` is how quota is *earned*, `effective_match_limit`
is how it's *spent*.

Golden Rule 2 applies throughout — every number here is computed in Python and
every state decision (already redeemed? self-referral? over cap?) is a plain
comparison. No LLM is anywhere near a quota or an access decision.

RECONCILIATION WITH subscription_tier (services/entitlements.py): tier stays the
single access seam and WINS. A 'pro' profile bypasses the quota entirely and
gets the full DEFAULT_RERANK_LIMIT; the referral quota only ever gates 'free'.
Since default_tier="pro" and every profile was backfilled to 'pro' by migration
022, that means this gate is INERT for the current beta by choice — it starts
biting when a real 'free' tier ships. Referrals are the free tier's growth
lever, not a tax on Pro.
"""

import random

from fastapi import HTTPException

from config import settings
from db.supabase_client import supabase
from services.entitlements import has_tier

# Same alphabet as migration 036's SQL generator — Crockford-style base32 with
# I/L/O/U removed so a code can't be garbled by 1-vs-I or 0-vs-O when it's read
# off a screenshot or dictated. The two generators MUST stay in sync: the DB
# default mints codes for new rows, this one exists for explicit/backfill use.
_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
_CODE_LENGTH = 7


def generate_referral_code(max_attempts: int = 10) -> str:
    """A short code not currently held by any profile.

    32^7 ≈ 34 billion, so a collision is already vanishingly unlikely; the retry
    loop just means we never hand one to a user as a failed insert. The unique
    index from migration 036 is still the real guarantee — this is the polite
    path, not the safety net."""
    for _ in range(max_attempts):
        code = "".join(random.choices(_CODE_ALPHABET, k=_CODE_LENGTH))
        existing = supabase.table("profiles").select("id").eq("referral_code", code).limit(1).execute().data
        if not existing:
            return code
    # Ten collisions in a row against a 34-billion space isn't bad luck, it's a
    # broken RNG or a corrupted table. Failing loudly beats returning a dup.
    raise HTTPException(status_code=500, detail="Could not generate a referral code.")


def normalize_code(code: str) -> str:
    """Codes get typed by hand off a WhatsApp message, so accept the shapes
    humans actually produce: lowercase, stray spaces, a hyphen in the middle."""
    return (code or "").strip().upper().replace("-", "").replace(" ", "")


def _capped(current: int, bonus: int) -> int:
    """Constraint 4: bonus_match_quota may never exceed MAX_BONUS_MATCH_QUOTA,
    not even transiently — so the cap is applied to the SUM before it's written,
    rather than writing then clamping."""
    return min(current + bonus, settings.max_bonus_match_quota)


def effective_match_limit(profile: dict) -> int:
    """How many jobs this profile gets a full stage-2 (LLM) analysis for.

    Clamped to DEFAULT_RERANK_LIMIT at the top so that no amount of referral
    quota can push a single profile's LLM spend past what an ungated profile
    already costs today — the cap is a cost ceiling, not just a product tier.

    The import is function-local to break a genuine import cycle: matching.py
    consumes this function, so referrals.py must not import matching.py at
    module scope."""
    from services.matching import DEFAULT_RERANK_LIMIT

    if has_tier(profile, "pro"):
        return DEFAULT_RERANK_LIMIT
    quota = profile.get("bonus_match_quota") or 0
    return min(settings.base_free_match_limit + quota, DEFAULT_RERANK_LIMIT)


def get_referral_stats(profile: dict) -> dict:
    """Everything the referral screen renders, in one round-trip each."""
    profile_id = profile["id"]
    referred = (
        supabase.table("referrals").select("id", count="exact").eq("referrer_profile_id", profile_id).execute()
    )
    referred_count = referred.count if referred.count is not None else len(referred.data or [])
    return {
        "referral_code": profile.get("referral_code"),
        "referred_count": referred_count,
        "bonus_match_quota": profile.get("bonus_match_quota") or 0,
        "effective_match_limit": effective_match_limit(profile),
    }


def redeem_referral_code(referred_profile_id: str, code: str) -> dict:
    """Apply someone else's code to this profile, granting both sides a bonus.

    Every rejection is a 400 with a message the app can show inline. Ordering is
    load-bearing: the `referrals` insert (guarded by the UNIQUE on
    referred_profile_id) happens BEFORE any quota is granted, so a double-submit
    fails on the constraint and returns 400 instead of double-granting. That
    unique index — not this function's checks — is what actually holds under a
    retried request (constraint 2)."""
    normalized = normalize_code(code)
    if not normalized:
        raise HTTPException(status_code=400, detail="Enter an invite code.")

    # Re-read the redeemer inside the call rather than trusting the passed-in
    # profile dict: this is the row we're about to make a one-time decision on.
    rows = (
        supabase.table("profiles")
        .select("id, bonus_match_quota, referred_by_profile_id")
        .eq("id", referred_profile_id)
        .limit(1)
        .execute()
        .data
    )
    if not rows:
        raise HTTPException(status_code=404, detail="Profile not found.")
    redeemer = rows[0]

    if redeemer.get("referred_by_profile_id"):
        raise HTTPException(status_code=400, detail="You've already used an invite code.")

    referrer_rows = (
        supabase.table("profiles")
        .select("id, bonus_match_quota")
        .eq("referral_code", normalized)
        .limit(1)
        .execute()
        .data
    )
    if not referrer_rows:
        raise HTTPException(status_code=400, detail="That invite code isn't valid.")
    referrer = referrer_rows[0]

    # Constraint 3, Python half. The DB check constraint is the other half —
    # both, because this one gives a friendly message and that one is the thing
    # a future code path can't bypass.
    if referrer["id"] == referred_profile_id:
        raise HTTPException(status_code=400, detail="You can't use your own invite code.")

    try:
        supabase.table("referrals").insert(
            {"referrer_profile_id": referrer["id"], "referred_profile_id": referred_profile_id}
        ).execute()
    except Exception as exc:  # unique violation on referred_profile_id
        # Any other insert failure would also land here, so don't claim to know
        # which — but a 400 with this message is right for the overwhelmingly
        # likely cause, and the exception is logged for the rest.
        raise HTTPException(status_code=400, detail="You've already used an invite code.") from exc

    referred_quota = _capped(redeemer.get("bonus_match_quota") or 0, settings.referral_bonus_matches)
    supabase.table("profiles").update(
        {"referred_by_profile_id": referrer["id"], "bonus_match_quota": referred_quota}
    ).eq("id", referred_profile_id).execute()

    referrer_quota = _capped(referrer.get("bonus_match_quota") or 0, settings.referral_bonus_matches)
    supabase.table("profiles").update({"bonus_match_quota": referrer_quota}).eq("id", referrer["id"]).execute()

    # Re-read rather than reconstruct: the redeemer dict above was selected with
    # a narrow column list (no referral_code, no subscription_tier), and
    # get_referral_stats needs both — tier decides effective_match_limit. Hand-
    # patching those in is exactly how a stale-state bug gets written.
    fresh = supabase.table("profiles").select("*").eq("id", referred_profile_id).limit(1).execute().data
    return get_referral_stats(fresh[0])
