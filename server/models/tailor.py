from pydantic import BaseModel


class TailoredBullet(BaseModel):
    """One bullet from the Gemini tailor response — see docs/PROMPTS.md
    section 3. `original` must be traceable to the stored resume; that's
    verified by services/guardrail.py, not by the LLM."""

    original: str
    tailored: str
    job_keyword_targeted: str


class TailorLlmResponse(BaseModel):
    tailored_bullets: list[TailoredBullet]
