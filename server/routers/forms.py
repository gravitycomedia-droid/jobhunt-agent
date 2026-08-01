"""Phase 6: form autofill. Product rule (non-negotiable): the agent fills,
the human reviews and taps submit. Nothing in this router ever POSTs to a
form's response endpoint — the output is a prefill URL the user opens in
their own browser, signed into whatever Google account they choose."""

from bs4 import BeautifulSoup
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from config import settings
from db.supabase_client import supabase
from models.common import MAX_FORM_HTML_LEN, MAX_URL_LEN, StrictModel
from models.form import FormAnswer, FormQuestion, FormSchema
from services.auth import get_current_profile
from services.rate_limit import enforce_rate_limit
from services.form_parser import (
    FormAuthRequiredError,
    FormFetchError,
    FormParseError,
    apply_answer_history,
    build_prefill_url,
    fetch_form_html,
    is_google_form_url,
    normalize_question,
    parse_google_form,
    redact_for_storage,
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


class ParseFormRequest(StrictModel):
    # ADR-024: StrictModel rejects unknown fields, and the length cap stops an
    # absurdly long URL from ever reaching the fetch/SSRF path.
    url: str = Field(min_length=1, max_length=MAX_URL_LEN)


class ParseFormHtmlRequest(StrictModel):
    """ADR-053: a sign-in-gated form can't be fetched server-side (no Google
    session), so the client fetches the page itself — inside an authenticated
    in-app WebView the user signed into with their own Google account — and
    hands the resulting HTML here for the identical parse /forms/parse
    already does. No SSRF surface: this endpoint makes no outbound fetch at
    all, so the ADR-024 URL-fetch gate doesn't apply; `form_url` is only used
    as the parsed schema's `form_url` and this row's prefill/redirect target."""

    html: str = Field(min_length=1, max_length=MAX_FORM_HTML_LEN)
    form_url: str = Field(min_length=1, max_length=MAX_URL_LEN)


class FillFormRequest(BaseModel):
    form: FormSchema


class UpdateFillAnswersRequest(BaseModel):
    answers: list[FormAnswer]


def _build_answer_history(profile_id: str) -> dict[str, FormAnswer]:
    """Most-recent non-null answer per normalized question text, across
    this profile's past form fills (most-recent-first, first-seen-wins).
    The real signal is the user's own final edits — PATCH /forms/fills/{id}
    (below) overwrites a fill's `answers` with those once the user opens
    the prefilled form — but a fill nobody ever opened still has the raw
    LLM guess stored at /forms/fill time as a fallback."""
    rows = (
        supabase.table("form_fills")
        .select("answers")
        .eq("profile_id", profile_id)
        .order("created_at", desc=True)
        .limit(50)
        .execute()
        .data
    )
    history: dict[str, FormAnswer] = {}
    for row in rows:
        for raw in row.get("answers") or []:
            if not raw.get("answer"):
                continue
            key = normalize_question(raw.get("question") or "")
            if not key or key in history:
                continue
            history[key] = FormAnswer(**raw)
    return history


async def _parse_schema_from_html(html: str, form_url: str, profile: dict) -> FormSchema:
    """Shared by /parse (server-fetched HTML) and /parse-html (client-fetched
    HTML): Google Forms parse deterministically from FB_PUBLIC_LOAD_DATA_ (no
    LLM); anything else falls back to BeautifulSoup text + LLM extraction
    flagged source='llm_extracted'."""
    if is_google_form_url(form_url) or "FB_PUBLIC_LOAD_DATA_" in html:
        try:
            return parse_google_form(html, form_url=form_url)
        except FormAuthRequiredError as e:
            raise HTTPException(status_code=403, detail=f"form_auth_required: {e}") from e
        except FormParseError as e:
            raise HTTPException(status_code=422, detail=str(e)) from e

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
    return FormSchema(
        title=extraction.title,
        description=extraction.description,
        questions=[FormQuestion(**q.model_dump()) for q in extraction.questions],
        form_url=form_url,
        source="llm_extracted",
    )


def _create_job_from_description(description: str, form_url: str, profile: dict) -> tuple[str | None, str | None]:
    """JD heuristic (plain len() — Golden Rule 2): a long description is
    probably the job posting itself. Best-effort — a failed extraction must
    never sink the parse the caller actually asked for."""
    if len(description) < JD_MIN_CHARS:
        return None, None
    try:
        extraction = extract_job_from_text(description, profile_id=profile["id"])
        job_row = insert_manual_job(extraction, redirect_url=form_url)
        return job_row["id"], job_row["title"]
    except Exception:  # noqa: BLE001 — incl. JobExtractError/LlmApiError; JD capture is a bonus, not the request
        return None, None


@router.post(
    "/parse",
    dependencies=[
        Depends(enforce_rate_limit("forms_parse", settings.rate_limit_forms_parse, settings.rate_limit_window_seconds))
    ],
)
async def parse_form(body: ParseFormRequest, profile: dict = Depends(get_current_profile)):
    """Fetch + parse a form URL. If the form's description looks like a full
    JD, a job row is created via the existing manual-job flow so 'Tailor
    resume for this JD' can jump straight into the normal tailoring
    pipeline."""
    try:
        html, final_url = await fetch_form_html(body.url)
    except FormAuthRequiredError as e:
        # Typed for the client: it shows the sign-in-and-autofill fallback
        # (ADR-053) rather than a raw error.
        raise HTTPException(status_code=403, detail=f"form_auth_required: {e}") from e
    except FormFetchError as e:
        raise HTTPException(status_code=422, detail=str(e)) from e

    # ADR-053 bug fix: build everything off the RESOLVED url (final_url), not
    # body.url — if the user pasted a forms.gle short link, appending
    # ?entry.*=... to THAT and later navigating to it silently drops every
    # param on the short link's own redirect (see fetch_form_html's doc).
    schema = await _parse_schema_from_html(html, final_url, profile)
    job_id, job_title = _create_job_from_description(schema.description or "", final_url, profile)
    return {"data": {"form": schema.model_dump(), "job_id": job_id, "job_title": job_title}, "error": None}


@router.post(
    "/parse-html",
    dependencies=[
        Depends(enforce_rate_limit("forms_parse", settings.rate_limit_forms_parse, settings.rate_limit_window_seconds))
    ],
)
async def parse_form_html(body: ParseFormHtmlRequest, profile: dict = Depends(get_current_profile)):
    """ADR-053: the sign-in-gated counterpart to /parse. When /parse comes
    back `form_auth_required`, the app opens the form in an in-app WebView so
    the user can sign into their own Google account (we never see the
    credentials, same guarantee as the existing WebView flow), waits for the
    real form page to load, and does a ONE-TIME read of that page's HTML —
    never an injection into the page, never a fill or submit happening there.
    That HTML lands here and goes through the exact same deterministic parse
    /parse uses; the client then calls the existing /forms/fill and opens the
    resulting prefill URL, same as the public-form path."""
    schema = await _parse_schema_from_html(body.html, body.form_url, profile)
    job_id, job_title = _create_job_from_description(schema.description or "", body.form_url, profile)
    return {"data": {"form": schema.model_dump(), "job_id": job_id, "job_title": job_title}, "error": None}


@router.post(
    "/fill",
    dependencies=[
        Depends(enforce_rate_limit("forms_fill", settings.rate_limit_forms_fill, settings.rate_limit_window_seconds))
    ],
)
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

    # Silently reuse answers to recurring questions (phone number, visa
    # sponsorship, notice period...) from past forms instead of a fresh LLM
    # guess. Re-verify afterward — a reused choice/checkbox answer might not
    # be a valid option on THIS form even though it was on the one it came
    # from.
    history = _build_answer_history(profile["id"])
    answers = apply_answer_history(answers, history)
    answers = verify_choice_answers(schema, answers)

    prefill_url = build_prefill_url(schema, answers)

    # §4.8: sensitive answers (govt ID, DOB, bank, passwords) are returned to
    # the client and go into the prefill URL for ONE-TIME use, but are never
    # persisted. Both the stored answers AND the stored prefill URL are built
    # from the redacted set so no secret lands in a row (the prefill URL carries
    # answers as query params, so it would leak them just as `answers` would).
    stored_answers = redact_for_storage(answers)
    fill_row = (
        supabase.table("form_fills")
        .insert(
            {
                "profile_id": profile["id"],
                "form_url": schema.form_url,
                "form_title": schema.title,
                "answers": [a.model_dump() for a in stored_answers],
                "prefill_url": build_prefill_url(schema, stored_answers),
            }
        )
        .execute()
        .data[0]
    )

    return {
        "data": {"fill_id": fill_row["id"], "answers": [a.model_dump() for a in answers], "prefill_url": prefill_url},
        "error": None,
    }


@router.patch("/fills/{fill_id}")
async def update_fill_answers(fill_id: str, body: UpdateFillAnswersRequest, profile: dict = Depends(get_current_profile)):
    """Called right before the app opens the prefilled form (form_fill_screen
    .dart's "Open prefilled form" tap) — persists the user's FINAL,
    possibly-edited answers over the original LLM guess, so
    _build_answer_history above learns from what the user actually
    confirmed rather than the first draft. Best-effort from the app's side
    (fire-and-forget) — never blocks or fails the actual form-opening
    action.
    """
    result = (
        supabase.table("form_fills")
        # §4.8: redact here too — the user's final edits may have typed a
        # sensitive value into a sensitive question, and history reuse reads
        # this row back.
        .update({"answers": [a.model_dump() for a in redact_for_storage(body.answers)]})
        .eq("id", fill_id)
        .eq("profile_id", profile["id"])  # owner-scoped — can't touch another profile's history
        .execute()
    )
    if not result.data:
        raise HTTPException(status_code=404, detail="Fill not found")
    return {"data": result.data[0], "error": None}
