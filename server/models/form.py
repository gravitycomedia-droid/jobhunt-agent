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
    param (empty for llm_extracted forms — no prefill URL possible there)."""

    entry_id: str = ""
    text: str
    type: QuestionType = "unknown"
    options: list[str] = []
    required: bool = False


class FormSchema(BaseModel):
    title: str
    description: Optional[str] = None
    questions: list[FormQuestion]
    form_url: str = ""
    # 'google_form' = deterministic FB_PUBLIC_LOAD_DATA_ parse;
    # 'llm_extracted' = BeautifulSoup text + LLM best-effort (lower
    # confidence, flagged in the UI).
    source: Literal["google_form", "llm_extracted"] = "google_form"


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
