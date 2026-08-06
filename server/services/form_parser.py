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
from bs4 import BeautifulSoup
from rapidfuzz import fuzz, process

from models.form import FormAnswer, FormQuestion, FormSchema
# ADR-024 SSRF gate, shared with the manual-job fetch (Phase 4 security fix).
from services.job_ingestion import _MAX_REDIRECTS, ManualJobFetchError, _assert_public_url

# How closely a current question's text must match a past one (after
# normalize_question) to reuse that past answer — see apply_answer_history.
_HISTORY_MATCH_THRESHOLD = 88

# §4.8 hard constraint: government ID, DOB, bank details, and passwords are
# filled ONCE (into the prefill URL the user reviews) and NEVER persisted to
# form_fills.answers. Detection is by QUESTION TEXT — reliable and low false-
# positive, unlike sniffing values. A sensitive answer is nulled before storage
# (redact_for_storage) so it can neither leak from the row nor be reused across
# forms by apply_answer_history (which reads from stored rows).
_SENSITIVE_QUESTION_RE = re.compile(
    r"\b("
    r"aadha?ar|pan\s*(card|number|no)|passport|ssn|social\s*security|national\s*id|"
    r"govern(ment|ing)?\s*id|govt\.?\s*id|voter\s*id|driv(er'?s|ing)\s*licen[cs]e|"
    r"date\s*of\s*birth|d\.?o\.?b\.?|birth\s*date|"
    r"bank\s*(account|acc|a/c)|account\s*number|ifsc|routing\s*number|"
    r"card\s*number|cvv|upi\s*(id|pin)?|"
    r"password|passcode|\botp\b|\bpin\b"
    r")\b",
    re.IGNORECASE,
)


def is_sensitive_question(question: str) -> bool:
    return _SENSITIVE_QUESTION_RE.search(question or "") is not None


def redact_for_storage(answers: list[FormAnswer]) -> list[FormAnswer]:
    """§4.8: return a copy of `answers` safe to persist — every sensitive
    answer's value is stripped (set to None) while its question/entry metadata
    is kept, so the fill row records that the question existed without ever
    storing the secret. The un-redacted answers still travel in the API response
    and the prefill URL (used once, in the user's own review), just never to the
    database."""
    out: list[FormAnswer] = []
    for a in answers:
        if is_sensitive_question(a.question) and a.answer is not None:
            out.append(a.model_copy(update={"answer": None, "source_field": "not stored (sensitive)"}))
        else:
            out.append(a)
    return out

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


async def fetch_form_html(url: str) -> tuple[str, str]:
    """Same posture as fetch_manual_job_text, but returns raw HTML (the Google
    parser needs the embedded JSON, not stripped text) alongside the RESOLVED
    final URL.

    ADR-053 bug fix: a `forms.gle` short link's redirect is a static,
    pre-registered mapping that DROPS any query string appended to it — so a
    prefill URL built on top of the short link (`forms.gle/xxx?entry.1=y`)
    silently loses every `entry.*` param on redirect, landing on the real form
    completely unfilled despite the app reporting success. The canonical
    `docs.google.com/forms/d/e/.../viewform` URL this function already
    resolves to (to follow the redirect chain below) does NOT have that
    problem — confirmed live: it carries prefill params through even a
    sign-in redirect via `continue=`. Every caller must build/store the
    prefill URL against THIS resolved URL, never the original possibly-short
    one.

    ADR-024 / Phase 4 SSRF fix: redirects are followed MANUALLY so every hop is
    re-validated through _assert_public_url — a forms.gle short link (or any
    open redirect) can't be used to reach 169.254.169.254 or our internal
    network. This reuses the exact gate the manual-job fetch already trusts."""
    headers = {"User-Agent": "Mozilla/5.0 (compatible; JobHuntAgent/1.0)"}
    current = url
    try:
        # follow_redirects=False: we follow them ourselves so each hop is checked.
        async with httpx.AsyncClient(timeout=15, follow_redirects=False) as client:
            for _ in range(_MAX_REDIRECTS + 1):
                _assert_public_url(current)
                response = await client.get(current, headers=headers)
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise FormFetchError("That URL redirected without saying where")
                    current = str(response.url.join(location))
                    continue
                response.raise_for_status()
                break
            else:
                raise FormFetchError("That URL redirected too many times")
    except ManualJobFetchError as e:
        # The SSRF gate speaks in ManualJobFetchError; the forms client expects
        # FormFetchError → a clean 422 with the "private or internal" message.
        raise FormFetchError(str(e)) from e
    except httpx.HTTPStatusError as e:
        # Some sign-in-gated forms answer with a direct 401/403 instead of a
        # redirect to accounts.google.com (the case handled below) — same
        # "you need to sign in" reality, just no location header to catch it
        # by. Route it to the same typed error so the client still shows the
        # open-in-browser fallback instead of a raw httpx message.
        if e.response.status_code in (401, 403):
            raise FormAuthRequiredError("This form requires sign-in to view") from e
        raise FormFetchError(f"Could not fetch that URL: {e}") from e
    except httpx.HTTPError as e:
        raise FormFetchError(f"Could not fetch that URL: {e}") from e

    final_url = str(response.url)
    if "accounts.google.com" in final_url or "ServiceLogin" in final_url:
        raise FormAuthRequiredError("This form requires sign-in to view")

    content_type = response.headers.get("content-type", "")
    if "html" not in content_type:
        raise FormFetchError(f"That URL didn't return a web page (content-type: {content_type or 'unknown'})")
    return response.text, final_url


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


# Smart AI Fill (Unstop/Internshala/Naukri/Indeed's own apply forms — real
# ATS pages, not Google Forms). Skipped entirely: hidden/submit/button/image/
# reset (not user-fillable), file (browsers block setting a file input's
# value from script — a platform rule, not a choice here), password/OTP-style
# inputs (never auto-filled, same posture as _SENSITIVE_QUESTION_RE below).
# Skipped for now (v1 is text/paragraph only — see extract_dom_fields' own
# docstring): checkbox/radio, which need group-aware handling a single
# selector can't express.
_SKIP_INPUT_TYPES = {"hidden", "submit", "button", "image", "reset", "file", "password", "checkbox", "radio"}
_TEXTLIKE_INPUT_TYPES = {"text", "email", "tel", "number", "search", "url", "date", "time"}

# Bounds the schema size (and therefore the map_profile_to_form prompt and
# the client's injection surface) on a page with an unusually large number
# of inputs — a long multi-page ATS wizard, a page with junk/decorative
# inputs, etc.
MAX_DOM_FIELDS = 40


def _field_label(soup: BeautifulSoup, el) -> str:
    """Best-effort human label for one form element, code-only (Golden Rule
    2) — no LLM involved in finding *which* text describes a field, only in
    (later, in map_profile_to_form) deciding what profile fact answers it."""
    el_id = el.get("id")
    if el_id:
        label = soup.find("label", attrs={"for": el_id})
        if label and label.get_text(strip=True):
            return label.get_text(strip=True)
    parent_label = el.find_parent("label")
    if parent_label and parent_label.get_text(strip=True):
        return parent_label.get_text(strip=True)
    aria = el.get("aria-label")
    if aria and aria.strip():
        return aria.strip()
    placeholder = el.get("placeholder")
    if placeholder and placeholder.strip():
        return placeholder.strip()
    name = el.get("name") or ""
    return name.replace("_", " ").replace("-", " ").strip()


def _dom_selector(el) -> str:
    """`name` before `id`: on the ATS pages this targets (server-rendered
    HTML, not Google's minified React — see extract_dom_fields' docstring),
    `name` is the attribute the page's own submit handler reads, so it's
    the more stable of the two across a reskin. Empty return = "don't
    inject into this one" (multiple elements could otherwise collide on the
    same generated selector, e.g. two unlabeled inputs with no name/id)."""
    name = el.get("name")
    if name:
        return f'[name="{name}"]'
    el_id = el.get("id")
    if el_id:
        return f"#{el_id}"
    return ""


def extract_dom_fields(html: str, form_url: str) -> FormSchema | None:
    """Smart AI Fill: deterministic (Golden Rule 2 — no LLM here) structural
    extraction of real <input>/<textarea>/<select> elements, each carrying a
    `dom_selector` the client can actually write a value into via JS —
    unlike extract_form_from_text's stripped-TEXT LLM guess (still the
    fallback below when this finds nothing), which has no DOM attachment
    point at all and can only ever produce a copy-paste answer sheet.

    v1 scope, deliberately conservative (ADR-053's "no DOM injection" rule
    stays intact for anything this function doesn't hand a real selector
    to): plain text-like inputs and textareas only. <select> is extracted
    (its options are useful context and it can legitimately be answered) but
    the client only ever offers it as a tap-to-apply suggestion, never
    blind-injects it — same for anything a field's `type` marks as complex.
    checkbox/radio groups are skipped entirely (see _SKIP_INPUT_TYPES).

    Returns None when the page has no usable fields — most commonly a
    JS-rendered SPA whose real inputs mount AFTER the WebView's one-time HTML
    read already happened (this is exactly why LinkedIn's heavily-dynamic
    Easy Apply modal is staged as a fast-follow, not v1 — see
    docs/21-career-ops-integration-plan.md). The caller falls back to
    extract_form_from_text in that case."""
    soup = BeautifulSoup(html, "html.parser")
    questions: list[FormQuestion] = []
    seen_selectors: set[str] = set()

    for el in soup.find_all(["input", "textarea", "select"]):
        if el.name == "input":
            input_type = (el.get("type") or "text").lower()
            if input_type in _SKIP_INPUT_TYPES:
                continue
            qtype = "short" if input_type in _TEXTLIKE_INPUT_TYPES else "unknown"
            if qtype == "unknown":
                continue  # an input type we don't have a fill story for yet
            options: list[str] = []
        elif el.name == "textarea":
            qtype = "paragraph"
            options = []
        else:  # select
            qtype = "dropdown"
            options = [o.get_text(strip=True) for o in el.find_all("option") if o.get_text(strip=True)]

        selector = _dom_selector(el)
        if not selector or selector in seen_selectors:
            continue
        label = _field_label(soup, el)
        if not label:
            continue
        seen_selectors.add(selector)

        questions.append(
            FormQuestion(
                entry_id=f"field_{len(questions)}",
                text=label,
                type=qtype,
                options=options,
                required=el.has_attr("required"),
                dom_selector=selector,
            )
        )
        if len(questions) >= MAX_DOM_FIELDS:
            break

    if not questions:
        return None

    title_tag = soup.find("title")
    return FormSchema(
        title=title_tag.get_text(strip=True) if title_tag and title_tag.get_text(strip=True) else "Application form",
        description=None,
        questions=questions,
        form_url=form_url,
        source="dom_extracted",
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
