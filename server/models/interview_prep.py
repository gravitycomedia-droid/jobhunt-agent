from typing import Literal

from pydantic import BaseModel

# Career-ops integration Brick 4 (docs/21-career-ops-integration-plan.md
# §1.2, DECISIONS.md ADR-058). 'gap' is distinct from career-ops's own
# categories — a question this app specifically generates from the match's
# already-computed `gaps` (services/matching.py), so the candidate can
# prepare an honest answer for exactly the weak spot a recruiter is most
# likely to probe.
QuestionCategory = Literal["behavioral", "technical", "gap", "company_fit"]


class InterviewQuestionLlm(BaseModel):
    """One question + a STAR-format suggested answer draft, grounded only in
    the candidate's real profile facts (services/llm.py::
    INTERVIEW_PREP_SYSTEM_PROMPT). `inferred` is the model's own honest
    label for whether the JD literally states this question's premise —
    mirrors career-ops's own `[inferred from JD]` tagging for anything it
    couldn't ground in real page text."""

    question: str
    category: QuestionCategory
    inferred: bool
    situation: str
    task: str
    action: str
    result: str


class InterviewPackLlmResponse(BaseModel):
    questions: list[InterviewQuestionLlm]
