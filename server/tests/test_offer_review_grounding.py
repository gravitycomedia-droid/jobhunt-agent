"""Career-ops integration Brick 5 (ADR-059): services/offer_review.py's
pure-Python grounding check. No DB/LLM deps needed."""

from services.offer_review import verify_clause_grounding

_RAW = "Base salary is $80,000/year. Employee agrees to a 2-year non-compete in the tri-state area."


def test_verbatim_clause_is_grounded():
    clauses = [{"clause_text": "a 2-year non-compete in the tri-state area", "category": "non_compete"}]
    result = verify_clause_grounding(clauses, _RAW)
    assert result[0]["grounded"] is True


def test_whitespace_and_case_differences_still_match():
    clauses = [{"clause_text": "  A 2-YEAR non-compete   in the tri-state area  ", "category": "non_compete"}]
    result = verify_clause_grounding(clauses, _RAW)
    assert result[0]["grounded"] is True


def test_invented_clause_is_not_grounded():
    clauses = [{"clause_text": "a golden parachute worth $1,000,000", "category": "other"}]
    result = verify_clause_grounding(clauses, _RAW)
    assert result[0]["grounded"] is False


def test_empty_clause_text_is_not_grounded():
    clauses = [{"clause_text": "", "category": "other"}]
    result = verify_clause_grounding(clauses, _RAW)
    assert result[0]["grounded"] is False


def test_preserves_other_fields():
    clauses = [{"clause_text": "Base salary is $80,000/year.", "category": "compensation", "plain_english": "You get paid $80k/year."}]
    result = verify_clause_grounding(clauses, _RAW)
    assert result[0]["category"] == "compensation"
    assert result[0]["plain_english"] == "You get paid $80k/year."
    assert result[0]["grounded"] is True
