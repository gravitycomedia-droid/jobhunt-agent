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
_PRICING_PER_MILLION_TOKENS: dict[str, tuple[float, float]] = {
    "gemini-2.5-flash": (0.30, 2.50),
    # old lite tier kept for pricing historical llm_calls rows; new lite
    # tier assumed same list price until Google publishes otherwise.
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-3.1-flash-lite": (0.10, 0.40),
    "gemini-embedding-001": (0.15, 0.0),
}
_FALLBACK_PRICING = (0.30, 2.50)

TASK_LABELS = {
    "parse": "Resume parsing",
    "rerank": "Job matching",
    "tailor": "Resume tailoring",
    "followup": "Follow-up drafts",
    "extract_job": "Manual job extraction",
    "embed": "Embeddings",
}


def estimate_call_cost(model: str | None, tokens_in: int | None, tokens_out: int | None) -> float:
    price_in, price_out = _PRICING_PER_MILLION_TOKENS.get(model or "", _FALLBACK_PRICING)
    return ((tokens_in or 0) / 1_000_000) * price_in + ((tokens_out or 0) / 1_000_000) * price_out


def summarize_costs(rows: list[dict]) -> dict:
    """`rows` are llm_calls rows (task/model/tokens_in/tokens_out) already
    scoped to one profile and one time window by the caller. Returns
    dollar totals and a per-task breakdown sorted highest-cost first,
    each with the % of the total it represents (for the progress bars).
    """
    total_cost = 0.0
    total_tokens = 0
    by_task: dict[str, dict] = {}

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

    breakdown = sorted(by_task.values(), key=lambda b: b["cost"], reverse=True)
    for b in breakdown:
        # pct first, from the unrounded cost — rounding cost to 4dp before
        # dividing skews a single-task month to ~99.9% instead of 100%.
        b["pct"] = round((b["cost"] / total_cost * 100), 1) if total_cost > 0 else 0.0
        b["cost"] = round(b["cost"], 4)

    return {
        "total_cost": round(total_cost, 4),
        "total_calls": len(rows),
        "total_tokens": total_tokens,
        "breakdown": breakdown,
    }
