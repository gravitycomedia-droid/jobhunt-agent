"""Phase 4: the tier gate. subscription_tier is the ONLY real entitlement;
the cosmetic wallet never gates (R-B). These pin the two behaviours the plan's
acceptance calls out: pro passes while DEFAULT_TIER=pro, and flipping
DEFAULT_TIER=free makes require_tier('pro') a 402 across the board."""

import pytest

from config import settings
from services.entitlements import TierRequired, has_tier, require_tier


@pytest.fixture
def default_tier(monkeypatch):
    """Set settings.default_tier for one test, restored automatically."""

    def _set(value: str):
        monkeypatch.setattr(settings, "default_tier", value)

    return _set


# --- happy path: a pro profile passes -------------------------------------


def test_pro_profile_passes_pro_gate():
    require_tier({"subscription_tier": "pro"}, "pro")  # no raise
    assert has_tier({"subscription_tier": "pro"}, "pro")


def test_pro_profile_passes_free_gate():
    # A higher tier satisfies a lower requirement.
    assert has_tier({"subscription_tier": "pro"}, "free")


# --- the gate actually gates ----------------------------------------------


def test_free_profile_is_blocked_from_pro_with_402():
    with pytest.raises(TierRequired) as exc:
        require_tier({"subscription_tier": "free"}, "pro")
    assert exc.value.status_code == 402


def test_free_profile_passes_free_gate():
    require_tier({"subscription_tier": "free"}, "free")  # no raise


# --- the DEFAULT_TIER global switch (R: absent column falls back) ----------


def test_missing_tier_column_falls_back_to_default_pro(default_tier):
    """A profile row predating migration 022 has no subscription_tier key. With
    default_tier=pro (the beta's state) it must pass the pro gate."""
    default_tier("pro")
    require_tier({}, "pro")  # no raise
    require_tier({"subscription_tier": None}, "pro")  # NULL column, same


def test_flipping_default_tier_to_free_closes_the_gate_globally(default_tier):
    """The plan's acceptance: flip DEFAULT_TIER=free and a profile with no
    explicit tier is now blocked from pro features with a 402."""
    default_tier("free")
    with pytest.raises(TierRequired) as exc:
        require_tier({}, "pro")
    assert exc.value.status_code == 402


def test_explicit_pro_beats_a_free_default(default_tier):
    """default_tier is only a FALLBACK — an explicitly pro row is unaffected by
    flipping the default to free."""
    default_tier("free")
    require_tier({"subscription_tier": "pro"}, "pro")  # no raise


# --- unknown/legacy tier values don't crash the comparison ----------------


def test_unknown_tier_value_ranks_lowest_not_error():
    assert not has_tier({"subscription_tier": "enterprise_typo"}, "pro")
