"""Phase 4: the cosmetic wallet (R-B / R-C). Pins that the balance is derived
(not a stuck counter), resets on the period rollover, and that actions_remaining
falls back to the config constant with estimated=True when there's no history."""

from datetime import datetime, timedelta, timezone

from config import settings
from services.wallet import USD_TO_PAISE, compute_wallet

NOW = datetime(2026, 7, 23, 12, 0, tzinfo=timezone.utc)


def _call(created_at, tokens_in=0, tokens_out=0, model="gemini-2.5-flash"):
    return {"model": model, "tokens_in": tokens_in, "tokens_out": tokens_out, "created_at": created_at.isoformat()}


# One gemini-2.5-flash call of exactly 1M input tokens costs $0.30 → a round
# 2490 paise, so the arithmetic below is exact, not approximate.
ONE_MILLION_IN = 1_000_000
SPEND_PER_CALL_PAISE = round(0.30 * USD_TO_PAISE)  # 2490


def _profile(grant=20000, period_end=None):
    p = {"wallet_balance_paise": grant}
    if period_end is not None:
        p["subscription_period_end"] = period_end.isoformat()
    return p


# --- R-C: empty history falls back, and says so ----------------------------


def test_empty_history_uses_fallback_and_full_balance():
    w = compute_wallet(_profile(grant=20000), [], now=NOW)
    assert w["spend_paise"] == 0
    assert w["balance_paise"] == 20000
    assert w["estimated"] is True
    assert w["actions_remaining"] == 20000 // settings.wallet_fallback_cost_paise


# --- real spend derives both the balance and the mean cost -----------------


def test_spend_lowers_balance_and_derives_mean():
    rows = [_call(NOW - timedelta(days=1), tokens_in=ONE_MILLION_IN)]
    w = compute_wallet(_profile(grant=20000), rows, now=NOW)
    assert w["spend_paise"] == SPEND_PER_CALL_PAISE  # 2490
    assert w["balance_paise"] == 20000 - SPEND_PER_CALL_PAISE  # 17510
    assert w["estimated"] is False
    # mean == the single call's cost → 17510 // 2490 == 7
    assert w["actions_remaining"] == (20000 - SPEND_PER_CALL_PAISE) // SPEND_PER_CALL_PAISE


# --- R-B: the balance is never a permanent zero — it resets on rollover -----


def test_balance_restores_after_period_rollover():
    """All spend happened BEFORE period_end; now has passed it. The window start
    is the rollover boundary, so none of that spend counts and the balance reads
    as the full grant again — no stored reset needed."""
    period_end = NOW - timedelta(hours=1)  # just rolled over
    rows = [_call(NOW - timedelta(days=5), tokens_in=ONE_MILLION_IN)]  # pre-rollover
    w = compute_wallet(_profile(grant=20000, period_end=period_end), rows, now=NOW)
    assert w["spend_paise"] == 0
    assert w["balance_paise"] == 20000


def test_spend_within_current_period_counts_but_older_is_excluded():
    period_end = NOW + timedelta(days=10)  # period is now-20d .. now+10d
    rows = [
        _call(NOW - timedelta(days=5), tokens_in=ONE_MILLION_IN),   # in period
        _call(NOW - timedelta(days=25), tokens_in=ONE_MILLION_IN),  # before start → excluded
    ]
    w = compute_wallet(_profile(grant=20000, period_end=period_end), rows, now=NOW)
    assert w["spend_paise"] == SPEND_PER_CALL_PAISE  # only the in-period call


# --- display clamp: over-budget floors at 0 (still resets next period) ------


def test_overspend_clamps_to_zero_not_negative():
    rows = [_call(NOW, tokens_in=ONE_MILLION_IN)]  # 2490 paise
    w = compute_wallet(_profile(grant=1000), rows, now=NOW)  # grant < spend
    assert w["balance_paise"] == 0
    assert w["actions_remaining"] == 0
    assert w["estimated"] is False


# --- the number never gates: it's pure display, callers must not read it -----


def test_output_is_plain_data_with_estimated_inside():
    w = compute_wallet(_profile(), [], now=NOW)
    # R-C requires `estimated` INSIDE the data object, not beside it.
    assert set(w) >= {"balance_paise", "actions_remaining", "estimated", "period_end"}
