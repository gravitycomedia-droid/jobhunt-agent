"""Career-ops integration Brick 5 (ADR-059): routers/offer_reviews.py.
Same mocking shape as test_application_emails_router.py."""

from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from models.offer_review import OfferClause, OfferReviewLlmResponse
from routers import offer_reviews as router_module

_APPLICATION = {"id": "app-1", "profile_id": "profile-1", "job_id": "job-1"}
_RAW_TEXT = "This offer includes a base salary of $80,000 and a 2-year non-compete clause covering the tri-state area."


def _table(select_data):
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.order.return_value = table
    table.limit.return_value = table
    table.execute.return_value = MagicMock(data=select_data)
    return table


def _insert_echo_table():
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.limit.return_value = table
    table.order.return_value = table

    def _insert(payload):
        table.execute.return_value = MagicMock(data=[payload])
        return table

    table.insert.side_effect = _insert
    return table


def _fake_response(clause_text: str = "a 2-year non-compete clause covering the tri-state area") -> OfferReviewLlmResponse:
    return OfferReviewLlmResponse(
        clauses=[OfferClause(clause_text=clause_text, category="non_compete", plain_english="You cannot work for a competitor for 2 years in this area.")],
        questions_for_lawyer=["Is a 2-year non-compete enforceable in the employee's state?"],
    )


def test_wrong_owner_is_404_not_leaked():
    with patch.object(router_module, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = lambda name: {"applications": _table([_APPLICATION])}[name]
        try:
            router_module._owned_application("app-1", "someone-else")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 404


def test_analyzes_and_marks_grounded_clause():
    applications_table = _table([_APPLICATION])
    offer_reviews_table = _insert_echo_table()
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "analyze_offer", return_value=_fake_response()
    ):
        mock_supabase.table.side_effect = lambda name: {
            "applications": applications_table,
            "offer_reviews": offer_reviews_table,
        }[name]
        row = router_module.analyze_and_store_offer({"id": "profile-1"}, "app-1", _RAW_TEXT)

    assert row["application_id"] == "app-1"
    assert len(row["clauses"]) == 1
    assert row["clauses"][0]["grounded"] is True
    assert row["questions_for_lawyer"] == ["Is a 2-year non-compete enforceable in the employee's state?"]


def test_invented_clause_is_not_grounded():
    applications_table = _table([_APPLICATION])
    offer_reviews_table = _insert_echo_table()
    fabricated = _fake_response(clause_text="a clause about a golden parachute that was never actually in the document")
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "analyze_offer", return_value=fabricated
    ):
        mock_supabase.table.side_effect = lambda name: {
            "applications": applications_table,
            "offer_reviews": offer_reviews_table,
        }[name]
        row = router_module.analyze_and_store_offer({"id": "profile-1"}, "app-1", _RAW_TEXT)

    assert row["clauses"][0]["grounded"] is False


def test_schema_has_no_verdict_field():
    """Structural guard (ADR-059): the response schema itself has nowhere
    to put a verdict, independent of what the prompt asks for."""
    assert "verdict" not in OfferReviewLlmResponse.model_fields
    assert "risk_score" not in OfferReviewLlmResponse.model_fields
    assert set(OfferClause.model_fields) == {"clause_text", "category", "plain_english"}
