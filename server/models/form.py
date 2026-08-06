"""Phase 6 (form autofill) schemas.

Product rule: the agent fills, the human reviews and taps submit — nothing
in these models or their consumers ever POSTs to a form endpoint."""

from typing import Literal, Optional, Union

from pydantic import BaseModel

QuestionType = Literal[
    "short", "paragraph", "choice", "checkbox", "dropdown", "date", "time", "scale", "file_upload", "unknown"
]


class FormQuestion(BaseModel):
    """One question in a parsed form. `entry_id` is Google's entry.<id>
    param for a google_form (empty for llm_extracted forms — no prefill URL
    possible there); for a dom_extracted form it's a synthetic `field_<i>`
    key used the same way verify_choice_answers/apply_answer_history already
    key on entry_id — just not a Google param.

    `dom_selector` (Smart AI Fill, non-Google sites): a CSS selector
    (`[name="..."]` or `#id`) built deterministically from the page's raw
    HTML by services/form_parser.extract_dom_fields — never LLM-generated.
    Empty for google_form/llm_extracted questions, which have no DOM
    attachment point to inject into."""

    entry_id: str = ""
    text: str
    type: QuestionType = "unknown"
    options: list[str] = []
    required: bool = False
    dom_selector: str = ""


class FormSchema(BaseModel):
    title: str
    description: Optional[str] = None
    questions: list[FormQuestion]
    form_url: str = ""
    # 'google_form' = deterministic FB_PUBLIC_LOAD_DATA_ parse;
    # 'dom_extracted' = deterministic <input>/<textarea>/<select> parse
    # (Smart AI Fill non-Google sites) — real DOM selectors, still no LLM;
    # 'llm_extracted' = BeautifulSoup TEXT + LLM best-effort fallback for
    # whatever dom_extracted couldn't find fillable elements in (lower
    # confidence, flagged in the UI, no dom_selector to inject into).
    source: Literal["google_form", "dom_extracted", "llm_extracted"] = "google_form"


class LlmFormExtraction(BaseModel):
    """What the LLM extraction task returns for non-Google forms — no entry
    ids (the page's field names aren't Google entry params)."""

    title: str
    description: Optional[str] = None
    questions: list[FormQuestion] = []


class FormAnswer(BaseModel):
    """One mapped answer. `answer` is a string, a list of strings (checkbox
    questions), or null when the profile simply doesn't contain the fact —
    null is the honest output, never a guess (anti-fabrication)."""

    entry_id: str = ""
    question: str
    answer: Union[str, list[str], None] = None
    confidence: float = 0.0
    source_field: Optional[str] = None
    # Set False by the deterministic post-check when a choice/checkbox/
    # dropdown answer isn't an exact member of the question's options.
    guardrail_pass: bool = True


class FormFillResponse(BaseModel):
    answers: list[FormAnswer]
