from pydantic import BaseModel, Field

from models.common import MAX_OFFER_TEXT_LEN, StrictModel


class OfferClause(BaseModel):
    """One clause the model identified, verbatim-quoted so
    services/offer_review.py::verify_clause_grounding can prove it. NEVER
    carries a verdict field (ADR-059's hard guard #1) — there is
    deliberately nowhere in this schema to put "safe to sign" or a risk
    score even if the model tried to produce one."""

    clause_text: str
    category: str
    plain_english: str


class OfferReviewLlmResponse(BaseModel):
    clauses: list[OfferClause]
    # Jurisdiction-dependent or legally uncertain points the model deferred
    # rather than answering from memory (ADR-059's hard guard #2).
    questions_for_lawyer: list[str]


class AnalyzeOfferRequest(StrictModel):
    raw_text: str = Field(max_length=MAX_OFFER_TEXT_LEN)
