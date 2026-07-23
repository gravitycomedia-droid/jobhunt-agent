"""Phase 4 (frontend rebuild v2): the one real entitlement seam.

`subscription_tier` (migration 022) is the ONLY thing that gates access in this
app. The cosmetic wallet never does (R-B — see docs/20-frontend-rebuild-master-plan.md).
`require_tier` is the single check every pro-only endpoint routes through, so
when a paid tier actually ships the gating lives in one place instead of being
scattered across routers.

Today `default_tier="pro"` and every existing profile was backfilled to 'pro',
so `require_tier(profile, "pro")` passes for everyone — the seam is live but
open. Flipping `DEFAULT_TIER=free` in the environment closes it globally (the
Phase 4 acceptance test asserts the resulting 402), without touching code.

Golden Rule 2: tiers are a plain comparison in Python — no LLM anywhere near an
access decision.
"""

from fastapi import Depends, HTTPException

from config import settings
from services.auth import get_current_profile

# Ordered low→high so a required tier is satisfied by anything at least as high.
# A dict (not an Enum) keeps unknown/legacy values from raising — they rank 0.
_TIER_RANK = {"free": 0, "pro": 1}


class TierRequired(HTTPException):
    """402 Payment Required — the honest status for "your plan doesn't include
    this". A distinct class so it reads clearly at the call site and in tests,
    but it IS an HTTPException so FastAPI renders it and api_client.dart surfaces
    it without special handling."""

    def __init__(self, required: str):
        super().__init__(
            status_code=402,
            detail=f"This feature needs the {required.capitalize()} plan.",
        )


def _tier_of(profile: dict) -> str:
    """A profile's effective tier, falling back to the configured default when
    the column is absent or NULL — a row predating migration 022, or a test
    fixture that doesn't set it. This fallback is exactly what makes
    DEFAULT_TIER a global on/off switch for the whole gate."""
    return profile.get("subscription_tier") or settings.default_tier


def has_tier(profile: dict, required: str) -> bool:
    """True if the profile is at or above `required`. Pure — safe in tests."""
    return _TIER_RANK.get(_tier_of(profile), 0) >= _TIER_RANK.get(required, 0)


def require_tier(profile: dict, required: str) -> None:
    """Raise 402 unless the profile is at or above `required`. Call from inside
    an endpoint that already holds the profile, or use `require_tier_dep` as a
    route dependency."""
    if not has_tier(profile, required):
        raise TierRequired(required)


def require_tier_dep(required: str):
    """FastAPI dependency form:
    `dependencies=[Depends(require_tier_dep("pro"))]`. Shares the request-cached
    get_current_profile, so gating costs no extra DB round-trip."""

    async def _dependency(profile: dict = Depends(get_current_profile)) -> None:
        require_tier(profile, required)

    return _dependency
