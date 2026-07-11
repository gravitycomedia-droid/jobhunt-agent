"""Phase 6: form autofill. Product rule (non-negotiable): the agent fills,
the human reviews and taps submit. Nothing in this router ever POSTs to a
form's response endpoint — the output is a prefill URL the user opens in
their own browser, signed into whatever Google account they choose."""

from bs4 import BeautifulSoup
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from db.supabase_client import supabase
from models.form import FormQuestion, FormSchema
from services.auth import get_current_profile
from services.form_parser import (
    FormAuthRequiredError,
    FormFetchError,
    FormParseError,
    build_prefill_url,
    fetch_form_html,
    is_google_form_url,
    parse_google_form,
    verify_choice_answers,
)
from services.job_ingestion import insert_manual_job
from services.llm import (
    FormExtractError,
    FormFillError,
    LlmApiError,
    extract_form_from_text,
    extract_job_from_text,
    map_profile_to_form,
)

router = APIRouter(prefix="/forms", tags=["forms"])

# A form description this long very likely embeds the job description —
# worth creating a job row so the existing tailoring pipeline can run.
JD_MIN_CHARS = 600


class ParseFormRequest(BaseModel):
    url: str


class FillFormRequest(BaseModel):
    form: FormSchema


@router.post("/parse")
async def parse_form(body: ParseFormRequest, profile: dict = Depends(get_current_profile)):
    """Fetch + parse a form URL. Google Forms parse deterministically from
    FB_PUBLIC_LOAD_DATA_ (no LLM); anything else falls back to
    BeautifulSoup text + LLM extraction flagged source='llm_extracted'.
    If the form's description looks like a full JD, a job row is created
    via the existing manual-job flow so 'Tailor resume for this JD' can
    jump straight into the normal tailoring pipeline."""
    try:
        html = await fetch_form_html(body.url)
    except FormAuthRequiredError as e:
        # Typed for the client: it shows the open-in-browser fallback.
        raise HTTPException(status_code=403, detail=f"form_auth_required: {e}") from e
    except FormFetchError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e

    if is_google_form_url(body.url) or "FB_PUBLIC_LOAD_DATA_" in html:
        try:
            schema = parse_google_form(html, form_url=body.url)
        except FormAuthRequiredError as e:
            raise HTTPException(status_code=403, detail=f"form_auth_required: {e}") from e
        except FormParseError as e:
            raise HTTPException(status_code=422, detail=str(e)) from e
    else:
        soup = BeautifulSoup(html, "html.parser")
        for tag in soup(["script", "style", "noscript"]):
            tag.decompose()
        text = soup.get_text(separator="\n", strip=True)
        if not text:
            raise HTTPException(status_code=422, detail="That page had no readable text to extract from")
        try:
            extraction = extract_form_from_text(text, profile_id=profile["id"])
        except FormExtractError as e:
            raise HTTPException(status_code=422, detail=f"Could not extract a form from that page: {e}") from e
        except LlmApiError as e:
            raise HTTPException(status_code=502, detail=f"Form extraction is temporarily unavailable: {e}") from e
        schema = FormSchema(
            title=extraction.title,
            description=extraction.description,
            questions=[FormQuestion(**q.model_dump()) for q in extraction.questions],
            form_url=body.url,
            source="llm_extracted",
        )

    # JD heuristic (plain len() — Golden Rule 2): a long description is
    # probably the job posting itself. Best-effort — a failed extraction
    # must not sink the parse the user actually asked for.
    job_id = None
    job_title = None
    description = schema.description or ""
    if len(description) >= JD_MIN_CHARS:
        try:
            extraction = extract_job_from_text(description, profile_id=profile["id"])
            job_row = insert_manual_job(extraction, redirect_url=body.url)
            job_id = job_row["id"]
            job_title = job_row["title"]
        except Exception:  # noqa: BLE001 — incl. JobExtractError/LlmApiError; JD capture is a bonus, not the request
            pass

    return {"data": {"form": schema.model_dump(), "job_id": job_id, "job_title": job_title}, "error": None}


@router.post("/fill")
async def fill_form(body: FillFormRequest, profile: dict = Depends(get_current_profile)):
    """Map the caller's profile onto the parsed form. LLM answers from
    profile facts only (nulls where unknown), then the deterministic
    choice-membership mini-guardrail flags anything not an exact option.
    Returns the reviewed-and-editable answers + the prefill URL."""
    schema = body.form
    try:
        llm_response = map_profile_to_form(
            profile,
            schema.model_dump_json(include={"title", "description", "questions"}),
            profile_id=profile["id"],
        )
    except FormFillError as e:
        raise HTTPException(status_code=422, detail=f"Could not map your profile to this form: {e}") from e
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Form filling is temporarily unavailable: {e}") from e

    answers = verify_choice_answers(schema, llm_response.answers)
    prefill_url = build_prefill_url(schema, answers)

    supabase.table("form_fills").insert(
        {
            "profile_id": profile["id"],
            "form_url": schema.form_url,
            "form_title": schema.title,
            "answers": [a.model_dump() for a in answers],
            "prefill_url": prefill_url,
        }
    ).execute()

    return {
        "data": {"answers": [a.model_dump() for a in answers], "prefill_url": prefill_url},
        "error": None,
    }
