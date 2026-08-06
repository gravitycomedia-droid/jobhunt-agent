from typing import Literal

from pydantic import BaseModel

# Career-ops integration Brick 3 (docs/21-career-ops-integration-plan.md
# §1.6, DECISIONS.md ADR-057). Mirrors models/followup.py's FollowupDraft
# shape exactly — same "just drafted text, nothing sends anything" posture.
EmailKind = Literal["application", "referral", "cold"]


class ApplicationEmailLlmResponse(BaseModel):
    subject: str
    body: str
