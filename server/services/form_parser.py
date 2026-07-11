"""Phase 6: deterministic Google Forms parser + prefill-URL builder.

No LLM anywhere in this module (Golden Rule 2) — a public Google Form
embeds its full structure as JSON (`FB_PUBLIC_LOAD_DATA_`) in the viewform
HTML, so parsing it is pure code. The LLM only enters the picture for
non-Google forms (routers/forms.py sends stripped page text to
services/llm.py's extract_form_from_text) and for mapping profile facts to
questions (map_profile_to_form).
"""

import json
import re
from urllib.parse import urlencode

import httpx
from rapidfuzz import fuzz, process

from models.form import FormAnswer, FormQuestion, FormSchema

# How closely a current question's text must match a past one (after
# normalize_question) to reuse that past answer — see apply_answer_history.
_HISTORY_MATCH_THRESHOLD = 88

# Google's internal item-type enum inside FB_PUBLIC_LOAD_DATA_.
_GOOGLE_TYPE = {
    0: "short",
    1: "paragraph",
    2: "choice",
    3: "dropdown",
    4: "checkbox",
    5: "scale",
    9: "date",
    10: "time",
    13: "file_upload",
}


class FormFetchError(Exception):
    """The URL couldn't be fetched or wasn't an HTML page."""


class FormAuthRequiredError(Exception):
    """The form requires Google sign-in to view — the client maps this to
    the 'open it in your browser' fallback message."""


class FormParseError(Exception):
    """Fetched fine, but no parsable form structure was found."""


def is_google_form_url(url: str) -> bool:
    return "docs.google.com/forms" in url or "forms.gle/" in url


async def fetch_form_html(url: str) -> str:
    """Same httpx/user-agent/timeout posture as fetch_manual_job_text, but
    returns raw HTML (the Google parser needs the embedded JSON, not
    stripped text). Follows redirects so forms.gle short links work."""
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            response = await client.get(url, headers={"User-Agent": "Mozilla/5.0 (compatible; JobHuntAgent/1.0)"})
            response.raise_for_status()
    except httpx.HTTPError as e:
        raise FormFetchError(f"Could not fetch that URL: {e}") from e

    final_url = str(response.url)
    if "accounts.google.com" in final_url or "ServiceLogin" in final_url:
        raise FormAuthRequiredError("This form requires sign-in to view")

    content_type = response.headers.get("content-type", "")
    if "html" not in content_type:
        raise FormFetchError(f"That URL didn't return a web page (content-type: {content_type or 'unknown'})")
    return response.text


def parse_google_form(html: str, form_url: str) -> FormSchema:
    """Extracts FB_PUBLIC_LOAD_DATA_ and parses it into a FormSchema.

    Layout (reverse-engineered, stable for years): data[3] is the form
    title, data[1][0] the description, data[1][1] the item list. Each item:
    [item_id, title, help_text, type_enum, entries, ...] where entries[0]
    is [entry_id, options, required, ...] and each option is [text, ...].
    Everything is index-based, so every access below is defensive — a
    layout change should degrade to FormParseError, never a crash.
    """
    match = re.search(r"FB_PUBLIC_LOAD_DATA_\s*=\s*(.*?);\s*</script>", html, re.DOTALL)
    if match is None:
        if "ServiceLogin" in html or "accounts.google.com/v3/signin" in html:
            raise FormAuthRequiredError("This form requires sign-in to view")
        raise FormParseError("No FB_PUBLIC_LOAD_DATA_ found — is this a public Google Form?")

    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError as e:
        raise FormParseError(f"Could not decode the form's embedded JSON: {e}") from e

    def _get(seq, idx, default=None):
        try:
            value = seq[idx]
            return default if value is None else value
        except (IndexError, TypeError):
            return default

    title = _get(data, 3) or "Untitled form"
    body = _get(data, 1, [])
    description = _get(body, 0)
    items = _get(body, 1, []) or []

    questions: list[FormQuestion] = []
    for item in items:
        type_enum = _get(item, 3)
        qtype = _GOOGLE_TYPE.get(type_enum)
        if qtype is None:
            continue  # section headers, images, grids — nothing fillable
        entries = _get(item, 4, []) or []
        entry = _get(entries, 0, []) or []
        entry_id = _get(entry, 0)
        if entry_id is None:
            continue
        raw_options = _get(entry, 1, []) or []
        options = [str(_get(opt, 0, "")) for opt in raw_options if _get(opt, 0)]
        questions.append(
            FormQuestion(
                entry_id=str(entry_id),
                text=str(_get(item, 1, "") or ""),
                type=qtype,
                options=options,
                required=bool(_get(entry, 2, False)),
            )
        )

    if not questions:
        raise FormParseError("The form contained no fillable questions")

    return FormSchema(
        title=str(title),
        description=str(description) if description else None,
        questions=questions,
        form_url=form_url,
        source="google_form",
    )


def verify_choice_answers(schema: FormSchema, answers: list[FormAnswer]) -> list[FormAnswer]:
    """The mini-guardrail (deterministic post-check, Golden Rule 4 spirit):
    every choice/checkbox/dropdown answer must be an EXACT member of that
    question's options. Mismatches get guardrail_pass=False — flagged for
    the user, never silently accepted or auto-corrected."""
    options_by_entry = {q.entry_id: q for q in schema.questions}
    for answer in answers:
        question = options_by_entry.get(answer.entry_id)
        if question is None or question.type not in ("choice", "checkbox", "dropdown"):
            continue
        if answer.answer is None:
            continue
        values = answer.answer if isinstance(answer.answer, list) else [answer.answer]
        if not all(v in question.options for v in values):
            answer.guardrail_pass = False
    return answers


def normalize_question(text: str) -> str:
    """Collapses wording noise (punctuation, casing, extra whitespace) so
    the same real-world question asked slightly differently across two
    forms ("Phone number" vs "Your phone number:") still matches."""
    return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()


def apply_answer_history(answers: list[FormAnswer], history: dict[str, FormAnswer]) -> list[FormAnswer]:
    """Silently overrides each answer with one remembered from a past form
    fill whenever the current question closely fuzzy-matches a previously
    answered one — recurring questions (phone number, visa sponsorship,
    notice period, expected salary...) get the user's own last answer
    instead of a fresh LLM guess. Still shown as a normal editable row, so
    a wrong reuse is just as easy to fix as any other suggestion.

    Mutates and returns `answers` (same in-place style as
    verify_choice_answers). Caller must re-run verify_choice_answers
    afterward — a reused choice/checkbox answer might not be a valid
    option on THIS particular form even though it was on the one it came
    from.
    """
    if not history:
        return answers
    keys = list(history.keys())
    for answer in answers:
        key = normalize_question(answer.question)
        if not key:
            continue
        # token_set_ratio (not plain ratio) so "Phone number" still matches
        # "Your phone number:" — real forms wrap the same question in
        # different filler words, not just different punctuation/casing.
        match = process.extractOne(key, keys, scorer=fuzz.token_set_ratio, score_cutoff=_HISTORY_MATCH_THRESHOLD)
        if match is None:
            continue
        past = history[match[0]]
        answer.answer = past.answer
        answer.confidence = 1.0
        answer.source_field = "reused from a previous form"
        answer.guardrail_pass = True
    return answers


def build_prefill_url(schema: FormSchema, answers: list[FormAnswer]) -> str | None:
    """Pure-Python prefill URL: <form_url>?usp=pp_url&entry.<id>=<value>...
    (checkbox answers repeat the param). Only approved, non-null,
    guardrail-passing answers are included; file-upload questions can't be
    prefilled at all (Google doesn't allow programmatic file answers — the
    client lists them as 'attach manually'). None for llm_extracted forms,
    which have no Google entry ids."""
    if schema.source != "google_form" or not schema.form_url:
        return None

    types_by_entry = {q.entry_id: q.type for q in schema.questions}
    params: list[tuple[str, str]] = [("usp", "pp_url")]
    for answer in answers:
        if answer.answer is None or not answer.guardrail_pass or not answer.entry_id:
            continue
        if types_by_entry.get(answer.entry_id) == "file_upload":
            continue
        values = answer.answer if isinstance(answer.answer, list) else [answer.answer]
        for value in values:
            params.append((f"entry.{answer.entry_id}", str(value)))

    separator = "&" if "?" in schema.form_url else "?"
    return f"{schema.form_url}{separator}{urlencode(params)}"
