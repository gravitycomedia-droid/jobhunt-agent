"""Plan 21: the referral screen's two endpoints.

Both are scoped to the caller's own profile via get_current_profile — there is
no route here that takes someone else's profile id, which is the ownership
pattern from applications.py/tailor.py reduced to its simplest form (constraint
6). A caller can only ever read or mutate their own referral state."""

from fastapi import APIRouter, Depends

from models.referral import RedeemReferralRequest
from services.auth import get_current_profile
from services.referrals import get_referral_stats, redeem_referral_code

router = APIRouter(prefix="/referrals", tags=["referrals"])


@router.get("/me")
async def my_referrals(profile: dict = Depends(get_current_profile)):
    """This profile's code, how many people have used it, and what that has
    bought them. Everything referral_screen.dart renders."""
    return {"data": get_referral_stats(profile), "error": None}


@router.post("/redeem")
async def redeem(payload: RedeemReferralRequest, profile: dict = Depends(get_current_profile)):
    """Apply someone else's code to the caller's profile. Rejections come back
    as 400s from the service with a message written to be shown inline in the
    onboarding field, not swallowed."""
    return {"data": redeem_referral_code(profile["id"], payload.code), "error": None}
