"""Phase 4 (frontend rebuild v2): the COSMETIC wallet (R-B / R-C).

The wallet is telemetry, never a gate. It answers "how much of this period's
credit have my agent's LLM calls used?" and nothing reads it in an
authorization path — tier (services/entitlements.py) is the only real gate.

Design choice that kills R-B's "stuck at ₹0 forever" bug: the displayed balance
is DERIVED at read time as `grant − spend-this-period`, not a stored counter
that gets decremented and clamped. Two consequences fall straight out of that:

  * it "moves as real spend accrues" (spend is summed live from llm_calls), and
  * it "resets to ₹200 on the subscription_period_end rollover" for free — once
    `now` passes period_end we measure spend only from that boundary, so the
    balance snaps back to the full grant with no cron and no write.

Golden Rule 2: all arithmetic here is Python; the LLM is nowhere near it.
"""

from datetime import datetime, timedelta, timezone

from config import settings
from services.cost_stats import estimate_call_cost

# LLM costs come out of cost_stats in USD; the wallet is denominated in paise.
# This is a portfolio project's cosmetic meter, not a billing system, so an
# approximate fixed rate is the right amount of machinery (see cost_stats.py's
# same "close enough to be useful" bar). ~₹83/USD × 100 paise.
USD_TO_PAISE = 8300

# A period is monthly. Used to place the window start when period_end is known.
_PERIOD_DAYS = 30


def _parse_ts(value) -> datetime | None:
    """Parse an ISO timestamp (str or datetime) to an aware UTC datetime, or
    None. Supabase returns ISO strings; tests may pass datetimes directly."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _period_start(period_end: datetime | None, now: datetime) -> datetime:
    """Start of the window whose spend counts against the current grant.

    - No period_end (row predates migration 022): a plain trailing 30 days.
    - now still inside the period: the period is [period_end − 30d, period_end].
    - now past period_end (rolled over): count only spend since the rollover
      boundary, so the balance reads as restored. This is what makes
      "advancing past subscription_period_end restores the balance" true without
      any stored reset."""
    if period_end is None:
        return now - timedelta(days=_PERIOD_DAYS)
    if now <= period_end:
        return period_end - timedelta(days=_PERIOD_DAYS)
    return period_end


def compute_wallet(profile: dict, llm_rows: list[dict], now: datetime | None = None) -> dict:
    """Pure. `llm_rows` are this profile's llm_calls rows (model/tokens/created_at),
    fetched by the caller over a window that covers the period start. Returns the
    dict GET /wallet wraps in the standard envelope — `estimated` lives INSIDE it
    (R-C), never beside it.
    """
    now = now or datetime.now(timezone.utc)
    grant_paise = int(profile.get("wallet_balance_paise") or 0)
    period_end = _parse_ts(profile.get("subscription_period_end"))
    start = _period_start(period_end, now)

    spend_usd = 0.0
    calls_in_period = 0
    for row in llm_rows:
        ts = _parse_ts(row.get("created_at"))
        if ts is None or ts < start:
            continue
        spend_usd += estimate_call_cost(row.get("model"), row.get("tokens_in"), row.get("tokens_out"))
        calls_in_period += 1

    spend_paise = round(spend_usd * USD_TO_PAISE)
    # Clamp for DISPLAY only — the number never gates, and it's restored next
    # period, so a within-period floor of 0 is honest rather than "stuck".
    balance_paise = max(0, min(grant_paise, grant_paise - spend_paise))

    # R-C: with no history to average, fall back to the config constant and flag
    # the number as estimated. Once real calls exist, use their mean cost.
    if calls_in_period == 0:
        mean_cost_paise = max(1, settings.wallet_fallback_cost_paise)
        estimated = True
    else:
        mean_cost_paise = max(1, round(spend_paise / calls_in_period))
        estimated = False

    return {
        "balance_paise": balance_paise,
        "grant_paise": grant_paise,
        "spend_paise": spend_paise,
        "actions_remaining": balance_paise // mean_cost_paise,
        "estimated": estimated,
        "period_end": period_end.isoformat() if period_end else None,
    }
