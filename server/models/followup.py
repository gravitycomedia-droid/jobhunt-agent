from pydantic import BaseModel


class FollowupDraft(BaseModel):
    """Gemini response for the follow-up-email task — see docs/PROMPTS.md
    section 4. Just drafted text; nothing here sends anything (Golden
    Rule: no auto-submitting anywhere)."""

    subject: str
    body: str
