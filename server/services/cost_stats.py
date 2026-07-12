"""Phase 3: turns raw llm_calls rows into the aggregates CostStatsScreen
renders (Golden Rule 2 — the client does no math of its own here).
Pricing is approximate list price per 1M tokens, current as of when this
was written; this is a portfolio project's usage dashboard, not a
billing system, so "close enough to be useful" is the bar, not exact
reconciliation with a Google Cloud invoice.
"""

# (price per 1M input tokens, price per 1M output tokens) in USD.
# gemini-embedding-001 has no separate output cost (embeddings are
# input-only, tokens_out is always None for task="embed").
#
# DeepSeek (ADR-023) prices input twice: a cache HIT on a repeated prompt
# prefix costs $0.0028/1M — 50x less than the $0.14/1M cache MISS. We record
# the cache-miss rate deliberately: llm_calls stores `prompt_tokens` (hits +
# misses together, see services/llm.py::_call_deepseek), so pricing all of it
# at the miss rate OVERSTATES the bill slightly rather than flattering it.
# Verified against api-docs.deepseek.com 2026-07-12.
_PRICING_PER_MILLION_TOKENS: dict[str, tuple[float, float]] = {
    "gemini-2.5-flash": (0.30, 2.50),
    # old lite tier kept for pricing historical llm_calls rows; new lite
    # tier assumed same list price until Google publishes otherwise.
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-3.1-flash-lite": (0.10, 0.40),
    "gemini-embedding-001": (0.15, 0.0),
    "deepseek-v4-flash": (0.14, 0.28),
    "deepseek-v4-pro": (0.435, 0.87),
}
_FALLBACK_PRICING = (0.30, 2.50)

TASK_LABELS = {
    "parse": "Resume parsing",
    "rerank": "Job matching",
    "tailor": "Resume tailoring",
    "followup": "Follow-up drafts",
    "extract_job": "Manual job extraction",
    "skill_growth": "Skill growth",
    "extract_form": "Form extraction",
    "form_fill": "Form filling",
    "embed": "Embeddings",
}

PROVIDER_LABELS = {
    "gemini": "Gemini",
    "deepseek": "DeepSeek",
}


def estimate_call_cost(model: str | None, tokens_in: int | None, tokens_out: int | None) -> float:
    price_in, price_out = _PRICING_PER_MILLION_TOKENS.get(model or "", _FALLBACK_PRICING)
    return ((tokens_in or 0) / 1_000_000) * price_in + ((tokens_out or 0) / 1_000_000) * price_out


def _finalize(buckets: dict[str, dict], total_cost: float) -> list[dict]:
    """Sort highest-cost first and attach each bucket's % of the total (what
    the dashboard's progress bars render)."""
    ordered = sorted(buckets.values(), key=lambda b: b["cost"], reverse=True)
    for b in ordered:
        # pct first, from the unrounded cost — rounding cost to 4dp before
        # dividing skews a single-task month to ~99.9% instead of 100%.
        b["pct"] = round((b["cost"] / total_cost * 100), 1) if total_cost > 0 else 0.0
        b["cost"] = round(b["cost"], 4)
    return ordered


def summarize_costs(rows: list[dict]) -> dict:
    """`rows` are llm_calls rows (task/provider/model/tokens_in/tokens_out)
    already scoped to one profile and one time window by the caller. Returns
    dollar totals plus two breakdowns of the same spend: by task, and — since
    ADR-023 split the workload across two providers — by provider.

    `provider` defaults to 'gemini' for rows written before migration 016,
    which is correct: Gemini was the only provider that existed then.
    """
    total_cost = 0.0
    total_tokens = 0
    by_task: dict[str, dict] = {}
    by_provider: dict[str, dict] = {}

    for row in rows:
        cost = estimate_call_cost(row.get("model"), row.get("tokens_in"), row.get("tokens_out"))
        total_cost += cost
        total_tokens += (row.get("tokens_in") or 0) + (row.get("tokens_out") or 0)

        task = row.get("task") or "other"
        bucket = by_task.setdefault(
            task, {"task": task, "label": TASK_LABELS.get(task, task.replace("_", " ").title()), "cost": 0.0, "calls": 0}
        )
        bucket["cost"] += cost
        bucket["calls"] += 1

        provider = row.get("provider") or "gemini"
        pbucket = by_provider.setdefault(
            provider,
            {"provider": provider, "label": PROVIDER_LABELS.get(provider, provider.title()), "cost": 0.0, "calls": 0},
        )
        pbucket["cost"] += cost
        pbucket["calls"] += 1

    return {
        "total_cost": round(total_cost, 4),
        "total_calls": len(rows),
        "total_tokens": total_tokens,
        "breakdown": _finalize(by_task, total_cost),
        "by_provider": _finalize(by_provider, total_cost),
    }
