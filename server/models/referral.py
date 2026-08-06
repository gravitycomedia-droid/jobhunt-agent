"""Plan 21: request/response shapes for the referral endpoints."""

from pydantic import BaseModel, Field


class RedeemReferralRequest(BaseModel):
    """The code as the user typed it. Length bounds are generous on purpose —
    normalize_code() strips spaces and hyphens before matching, so "ab cd-efg"
    is a legitimate 9-character way to type a 7-character code. Validating the
    exact 7-char shape here would reject it before normalization ever ran."""

    code: str = Field(min_length=1, max_length=32)


class ReferralStats(BaseModel):
    """What GET /referrals/me returns, and what POST /referrals/redeem echoes
    back so the app can update its quota display without a second round-trip."""

    referral_code: str | None
    referred_count: int
    bonus_match_quota: int
    effective_match_limit: int
