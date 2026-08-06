from pydantic import BaseModel

# Career-ops integration Brick 2 (docs/21-career-ops-integration-plan.md §1.1,
# DECISIONS.md ADR-056). Same shape-of-reasoning as models/tailor.py's
# TailorLlmResponse: the LLM produces LANGUAGE only (an opening hook, a
# handful of achievement-grounded paragraphs, a closing line); whether each
# paragraph actually traces to something real in the profile is verified
# afterward by services/guardrail.py, not trusted from the prompt (Golden
# Rule 4). Flat list of paragraphs — no bullet-selection/scoring step like
# résumé tailoring has, because a cover letter is 3-5 sentences of prose,
# not a set of interchangeable bullets to trim to fit a page.


class CoverLetterLlmResponse(BaseModel):
    opening: str
    body_paragraphs: list[str]
    closing: str
