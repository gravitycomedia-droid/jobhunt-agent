"""Plan 21: referral rewards + the full-match quota.

The tests that matter most here are the cost ones. `effective_match_limit` is
cheap to get right and cheap to assert; the constraint that actually protects
the LLM bill is that rerank_shortlist can't be talked past it by a caller-
supplied `limit`, so that one is tested against the real function with the LLM
mocked and the CALL COUNT asserted.
"""

from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

from models.match import MatchResult
from services import matching, referrals

_PRO = {"id": "p-pro", "subscription_tier": "pro", "bonus_match_quota": 0}
_FREE = {"id": "p-free", "subscription_tier": "free", "bonus_match_quota": 0}


def _result() -> MatchResult:
    return MatchResult(
        fit_score=82,
        role_alignment=0.0,
        strengths=["Python"],
        gaps=[],
        compensators=[],
        verdict="apply",
        one_line_reason="Strong backend match.",
    )


def _table_mock(select_data):
    table = MagicMock()
    for method in ("select", "eq", "in_", "insert", "upsert", "update", "limit", "order"):
        getattr(table, method).return_value = table
    table.execute.return_value = MagicMock(data=select_data, count=len(select_data))
    return table


# --- effective_match_limit -------------------------------------------------


def test_pro_tier_bypasses_the_quota_entirely():
    """The reconciliation decision: subscription_tier stays the single access
    seam and wins. A pro profile is never gated, whatever its bonus quota."""
    assert referrals.effective_match_limit(_PRO) == matching.DEFAULT_RERANK_LIMIT


def test_free_tier_gets_the_base_limit_with_no_referrals():
    assert referrals.effective_match_limit(_FREE) == 3


def test_referral_bonus_raises_the_free_limit():
    assert referrals.effective_match_limit({**_FREE, "bonus_match_quota": 5}) == 8


def test_limit_is_clamped_to_the_rerank_ceiling():
    """Constraint 4's real purpose: quota is a product lever, but it must never
    become a way to buy unbounded LLM spend with referrals."""
    assert referrals.effective_match_limit({**_FREE, "bonus_match_quota": 999}) == matching.DEFAULT_RERANK_LIMIT


def test_missing_quota_column_is_treated_as_zero():
    """A profile row predating migration 036 has no bonus_match_quota — it
    should read as "no bonus", not crash the matches screen."""
    assert referrals.effective_match_limit({"id": "p", "subscription_tier": "free"}) == 3


# --- the cost control (constraint 1) ---------------------------------------


def test_rerank_never_exceeds_the_quota_however_high_the_caller_asks():
    """THE cost test. A caller hitting POST /matches/rerank?limit=50 on a
    3-limit profile must produce 3 re-ranked jobs, not 50 — enforced inside
    matching.py, so no router or serializer can be bypassed to get around it."""
    jobs = [{"id": f"job-{i}", "title": "Backend Engineer", "company": "Acme", "similarity": 0.8} for i in range(30)]
    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_jobs") as mock_rerank:
        mock_supabase.table.side_effect = lambda name: {"matches": _table_mock([])}[name]
        with patch.object(matching, "_stage1_shortlist", return_value=jobs):
            mock_rerank.side_effect = lambda p, batch, **kw: [_result() for _ in batch]
            result = matching.rerank_shortlist(_FREE, limit=50)

    assert result["reranked"] == 3
    # And the LLM genuinely saw only those 3 — the number of jobs handed to
    # rerank_jobs across every batch is what shows up on the bill.
    assert sum(len(call.args[1]) for call in mock_rerank.call_args_list) == 3


def test_pro_profile_is_not_throttled_by_the_new_clamp():
    """Guards the reconciliation from the other side: adding the gate must not
    quietly shrink what today's (all-pro) beta users get."""
    jobs = [{"id": f"job-{i}", "title": "Backend Engineer", "company": "Acme", "similarity": 0.8} for i in range(30)]
    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_jobs") as mock_rerank:
        mock_supabase.table.side_effect = lambda name: {"matches": _table_mock([])}[name]
        with patch.object(matching, "_stage1_shortlist", return_value=jobs):
            mock_rerank.side_effect = lambda p, batch, **kw: [_result() for _ in batch]
            result = matching.rerank_shortlist(_PRO, limit=matching.DEFAULT_RERANK_LIMIT)

    assert result["reranked"] == matching.DEFAULT_RERANK_LIMIT


# --- locked teasers --------------------------------------------------------


def test_ungated_profile_gets_no_locked_teasers():
    """No upsell should render for someone who isn't actually missing out."""
    assert matching.get_locked_matches(_PRO, []) == []


def test_locked_teasers_carry_no_stage_two_fields():
    """These jobs never reached the LLM, so there is no fit_score/verdict/
    reasoning to leak — the teaser is similarity-only by construction."""
    jobs = [{"id": f"job-{i}", "title": "Dev", "company": "Acme", "similarity": 0.75} for i in range(20)]
    with patch.object(matching, "_stage1_shortlist", return_value=jobs):
        teasers = matching.get_locked_matches(_FREE, [{"id": "job-0"}, {"id": "job-1"}, {"id": "job-2"}])

    assert len(teasers) == matching.LOCKED_TEASER_CAP
    assert {t["id"] for t in teasers}.isdisjoint({"job-0", "job-1", "job-2"})
    for t in teasers:
        assert set(t) == {"id", "title", "company", "similarity_pct"}
        assert t["similarity_pct"] == 75


# --- redemption ------------------------------------------------------------


def test_cap_is_applied_to_the_sum_never_exceeded_transiently():
    """Constraint 4 — the cap goes on the total before it's written, so the
    column never even briefly holds a value above the maximum."""
    assert referrals._capped(48, 5) == 50
    assert referrals._capped(50, 5) == 50
    assert referrals._capped(0, 5) == 5


def test_codes_are_normalized_the_way_people_actually_type_them():
    assert referrals.normalize_code(" ab-cd efg ") == "ABCDEFG"


def test_self_referral_is_rejected():
    """Constraint 3, Python half. The DB check constraint is the other half."""
    profile_rows = _table_mock([{"id": "p-1", "bonus_match_quota": 0, "referred_by_profile_id": None}])
    referrer_rows = _table_mock([{"id": "p-1", "bonus_match_quota": 0}])
    with patch.object(referrals, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = [profile_rows, referrer_rows]
        with pytest.raises(HTTPException) as exc:
            referrals.redeem_referral_code("p-1", "ABCDEFG")
    assert exc.value.status_code == 400
    assert "own invite code" in exc.value.detail


def test_second_redemption_is_rejected_not_double_granted():
    """The user-visible half of constraint 2 — someone who already redeemed
    can't come back for another +5."""
    already = _table_mock([{"id": "p-2", "bonus_match_quota": 5, "referred_by_profile_id": "p-1"}])
    with patch.object(referrals, "supabase") as mock_supabase:
        mock_supabase.table.return_value = already
        with pytest.raises(HTTPException) as exc:
            referrals.redeem_referral_code("p-2", "ABCDEFG")
    assert exc.value.status_code == 400
    assert "already used" in exc.value.detail


def test_unknown_code_is_rejected():
    profile_rows = _table_mock([{"id": "p-2", "bonus_match_quota": 0, "referred_by_profile_id": None}])
    with patch.object(referrals, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = [profile_rows, _table_mock([])]
        with pytest.raises(HTTPException) as exc:
            referrals.redeem_referral_code("p-2", "NOTREAL")
    assert exc.value.status_code == 400
    assert "isn't valid" in exc.value.detail


def test_duplicate_ledger_insert_becomes_a_400_not_a_double_grant():
    """Constraint 2's real guarantee: if the UNIQUE on referrals.
    referred_profile_id fires (concurrent double-POST), no quota is written."""
    profile_rows = _table_mock([{"id": "p-2", "bonus_match_quota": 0, "referred_by_profile_id": None}])
    referrer_rows = _table_mock([{"id": "p-1", "bonus_match_quota": 0}])
    ledger = _table_mock([])
    ledger.insert.side_effect = Exception("duplicate key value violates unique constraint")

    with patch.object(referrals, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = [profile_rows, referrer_rows, ledger]
        with pytest.raises(HTTPException) as exc:
            referrals.redeem_referral_code("p-2", "ABCDEFG")

    assert exc.value.status_code == 400
    # The grant path must not have run — no profile row was updated.
    profile_rows.update.assert_not_called()


def test_successful_redemption_grants_both_sides():
    profile_rows = _table_mock([{"id": "p-2", "bonus_match_quota": 0, "referred_by_profile_id": None}])
    referrer_rows = _table_mock([{"id": "p-1", "bonus_match_quota": 0}])
    ledger = _table_mock([])
    redeemer_update = _table_mock([])
    referrer_update = _table_mock([])
    fresh = _table_mock([{"id": "p-2", "subscription_tier": "free", "bonus_match_quota": 5, "referral_code": "XYZ1234"}])
    stats_referrals = _table_mock([])

    with patch.object(referrals, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = [
            profile_rows,
            referrer_rows,
            ledger,
            redeemer_update,
            referrer_update,
            fresh,
            stats_referrals,
        ]
        stats = referrals.redeem_referral_code("p-2", "abcdefg")

    ledger.insert.assert_called_once_with({"referrer_profile_id": "p-1", "referred_profile_id": "p-2"})
    # Both sides credited, and the redeemer is marked so they can't redeem again.
    redeemer_update.update.assert_called_once_with({"referred_by_profile_id": "p-1", "bonus_match_quota": 5})
    referrer_update.update.assert_called_once_with({"bonus_match_quota": 5})
    # 3 base + 5 bonus, reported back so the app needn't recompute the rules.
    assert stats["effective_match_limit"] == 8
    assert stats["bonus_match_quota"] == 5
