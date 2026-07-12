"""Shared request-model base and field caps (Phase 14 / ADR-024).

Two rules, applied to every model that carries a request BODY:

1. `extra="forbid"` — an unexpected field is a bug (a typo'd key, a stale
   client, someone probing), and failing at the edge with a 422 beats silently
   ignoring it and writing a half-correct row.

2. Explicit `max_length` on every free-text field. Without a cap, a megabyte of
   pasted text flows all the way into an LLM prompt and gets truncated silently
   somewhere deep in services/llm.py — the user is billed for the tokens and
   never told why their input was cut. A 422 at the edge is cheaper and honest.

These caps deliberately do NOT apply to the LLM RESPONSE models (models/job.py's
JobExtraction, models/match.py, etc.): those are validated against what a model
generated, and `extra="forbid"` there would turn a harmless extra key into a
spurious retry. Requests are hostile; responses are merely unreliable.
"""

from pydantic import BaseModel, ConfigDict


class StrictModel(BaseModel):
    """Base for request bodies: reject unknown fields rather than ignore them."""

    model_config = ConfigDict(extra="forbid")


# Generous enough that no honest input is ever rejected, small enough that no
# single request can blow up a prompt. A real job description runs ~3-6k chars;
# _RERANK_JD_CHARS (services/llm.py) only ever reads the first 2000 anyway.
MAX_URL_LEN = 2048
MAX_TITLE_LEN = 300
MAX_COMPANY_LEN = 200
MAX_LOCATION_LEN = 300
MAX_DESCRIPTION_LEN = 20_000
# The JD-paste builder's whole point is pasting a full posting, so it gets more
# room than a description field — but still bounded.
MAX_JD_TEXT_LEN = 50_000
MAX_NOTES_LEN = 5_000
MAX_NAME_LEN = 200
MAX_HEADLINE_LEN = 1_000
MAX_EMAIL_LEN = 320  # RFC 5321: 64-char local part + @ + 255-char domain
MAX_FCM_TOKEN_LEN = 512
MAX_USN_LEN = 64
MAX_ROLE_LEN = 120
MAX_SKILL_LEN = 120
MAX_BULLET_LEN = 2_000

# List-length caps: max_length on a str caps one item, not how many items are
# sent. A 10k-entry skills array is as effective a token bomb as one 10k-char
# skill, so the collections are bounded too.
MAX_SKILLS = 200
MAX_TARGET_ROLES = 25
MAX_EXPERIENCE_ITEMS = 50
MAX_PROJECT_ITEMS = 50
MAX_EDUCATION_ITEMS = 25
MAX_BULLETS_PER_ITEM = 50
