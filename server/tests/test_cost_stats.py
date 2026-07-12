from services.cost_stats import estimate_call_cost, summarize_costs


def test_estimate_call_cost_uses_known_model_pricing():
    # 1M input tokens @ $0.30 + 1M output tokens @ $2.50 for gemini-2.5-flash.
    cost = estimate_call_cost("gemini-2.5-flash", 1_000_000, 1_000_000)
    assert cost == 2.80


def test_estimate_call_cost_embed_model_has_no_output_cost():
    cost = estimate_call_cost("gemini-embedding-001", 1_000_000, None)
    assert cost == 0.15


def test_estimate_call_cost_falls_back_for_unknown_model():
    cost = estimate_call_cost("some-future-model", 1_000_000, 0)
    assert cost == 0.30


def test_summarize_costs_groups_by_task_and_computes_percentages():
    rows = [
        {"task": "tailor", "model": "gemini-2.5-flash", "tokens_in": 1000, "tokens_out": 1000},
        {"task": "tailor", "model": "gemini-2.5-flash", "tokens_in": 1000, "tokens_out": 1000},
        {"task": "rerank", "model": "gemini-2.5-flash", "tokens_in": 500, "tokens_out": 500},
    ]
    summary = summarize_costs(rows)

    assert summary["total_calls"] == 3
    assert summary["total_tokens"] == 5000
    assert {b["task"] for b in summary["breakdown"]} == {"tailor", "rerank"}

    tailor_bucket = next(b for b in summary["breakdown"] if b["task"] == "tailor")
    assert tailor_bucket["calls"] == 2
    # tailor: 2 calls x 2x the tokens of rerank's 1 call = 4x the total cost.
    rerank_bucket = next(b for b in summary["breakdown"] if b["task"] == "rerank")
    assert tailor_bucket["cost"] == round(rerank_bucket["cost"] * 4, 4)
    assert sum(b["pct"] for b in summary["breakdown"]) == 100.0


def test_estimate_call_cost_prices_deepseek_at_the_cache_miss_rate():
    # ADR-023: $0.14/1M in + $0.28/1M out for deepseek-v4-flash. We price ALL
    # input at the cache-MISS rate deliberately — overstating beats flattering.
    cost = estimate_call_cost("deepseek-v4-flash", 1_000_000, 1_000_000)
    assert round(cost, 4) == 0.42


def test_deepseek_flash_is_an_order_of_magnitude_cheaper_than_gemini_flash():
    """The whole point of ADR-023 — if this ever stops holding, the migration
    has lost its reason to exist."""
    same_tokens = (1_000_000, 1_000_000)
    assert estimate_call_cost("deepseek-v4-flash", *same_tokens) < estimate_call_cost("gemini-2.5-flash", *same_tokens) / 5


def test_summarize_costs_splits_spend_by_provider():
    rows = [
        {"task": "rerank", "provider": "deepseek", "model": "deepseek-v4-flash", "tokens_in": 1_000_000, "tokens_out": 0},
        {"task": "tailor", "provider": "gemini", "model": "gemini-2.5-flash", "tokens_in": 1_000_000, "tokens_out": 0},
    ]
    summary = summarize_costs(rows)

    by_provider = {b["provider"]: b for b in summary["by_provider"]}
    assert by_provider["deepseek"]["cost"] == 0.14
    assert by_provider["deepseek"]["label"] == "DeepSeek"
    assert by_provider["gemini"]["cost"] == 0.30
    assert by_provider["deepseek"]["calls"] == 1
    # Highest-cost first, and the two shares account for the whole bill.
    assert summary["by_provider"][0]["provider"] == "gemini"
    assert sum(b["pct"] for b in summary["by_provider"]) == 100.0


def test_summarize_costs_treats_pre_migration_rows_as_gemini():
    """llm_calls rows written before migration 016 have no `provider`. Gemini is
    the correct backfill — it was the only provider that existed."""
    rows = [{"task": "tailor", "model": "gemini-2.5-flash", "tokens_in": 1000, "tokens_out": 1000}]
    summary = summarize_costs(rows)
    assert [b["provider"] for b in summary["by_provider"]] == ["gemini"]


def test_summarize_costs_empty_rows():
    summary = summarize_costs([])
    assert summary == {
        "total_cost": 0.0,
        "total_calls": 0,
        "total_tokens": 0,
        "breakdown": [],
        "by_provider": [],
    }
