"""Career-ops integration Brick 5 (docs/21-career-ops-integration-plan.md
§1.3, DECISIONS.md ADR-059): a clause-by-clause plain-English reader for
an offer letter/contract, paired with the Kanban's existing 'offer' state.
Hard guards (no verdict, no law-from-memory, no web research) are copied
directly from career-ops's own offer-prep mode — see
services/llm.py::OFFER_REVIEW_SYSTEM_PROMPT and services/offer_review.py's
deterministic clause-grounding check."""

from fastapi import APIRouter, Depends, HTTPException

from config import settings
from db.supabase_client import supabase
from models.offer_review import AnalyzeOfferRequest
from services.auth import get_current_profile
from services.llm import LlmApiError, OfferReviewError, analyze_offer
from services.offer_review import verify_clause_grounding
from services.rate_limit import enforce_rate_limit

router = APIRouter(prefix="/offer-reviews", tags=["offer-reviews"])


def _owned_application(application_id: str, profile_id: str) -> dict:
    """Same ownership-as-404 posture as every other application_id lookup
    in this app."""
    rows = supabase.table("applications").select("*").eq("id", application_id).limit(1).execute().data
    if not rows or rows[0]["profile_id"] != profile_id:
        raise HTTPException(status_code=404, detail="Application not found")
    return rows[0]


def analyze_and_store_offer(profile: dict, application_id: str, raw_text: str) -> dict:
    """Brick 5 core, same sync-core convention as the other generation
    bricks — plain function, directly unit-testable, no event loop
    required. See migration 035's docstring for why the hard guards are
    structural (no verdict column) rather than something a prompt alone
    is trusted to enforce."""
    _owned_application(application_id, profile["id"])

    try:
        llm_response = analyze_offer(raw_text, profile_id=profile["id"])
    except OfferReviewError as e:
        raise HTTPException(status_code=422, detail=f"Could not read this document: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Offer reading is temporarily unavailable: {e}") from e

    clauses = verify_clause_grounding([c.model_dump() for c in llm_response.clauses], raw_text)

    row = (
        supabase.table("offer_reviews")
        .insert(
            {
                "profile_id": profile["id"],
                "application_id": application_id,
                "raw_text": raw_text,
                "clauses": clauses,
                "questions_for_lawyer": llm_response.questions_for_lawyer,
            }
        )
        .execute()
        .data[0]
    )
    return row


@router.post(
    "/{application_id}",
    dependencies=[
        Depends(
            enforce_rate_limit("offer_review", settings.rate_limit_offer_review, settings.rate_limit_window_seconds)
        )
    ],
)
async def draft_offer_review(
    application_id: str, body: AnalyzeOfferRequest, profile: dict = Depends(get_current_profile)
):
    row = analyze_and_store_offer(profile, application_id, body.raw_text)
    return {"data": row, "error": None}


@router.get("/{application_id}")
async def list_offer_reviews(application_id: str, profile: dict = Depends(get_current_profile)):
    """Every offer read for this application, newest first — insert-only
    (migration 035's docstring), so a re-paste after negotiating shows up
    as a new entry rather than overwriting the first read."""
    _owned_application(application_id, profile["id"])
    rows = (
        supabase.table("offer_reviews")
        .select("*")
        .eq("application_id", application_id)
        .order("created_at", desc=True)
        .execute()
        .data
    )
    return {"data": rows, "error": None}
