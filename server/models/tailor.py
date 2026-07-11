from typing import Literal

from pydantic import BaseModel

# The role types the JD-analysis step classifies into (framework §1/§2). Code
# only uses this as an opaque label to show the user; it never branches on it,
# so adding a new type here needs no other code change.
RoleType = Literal[
    "frontend",
    "full_stack",
    "backend",
    "solutions_support",
    "ai_adjacent",
    "mobile",
    "data",
    "general",
]

# Startup/product vs corporate/formal. THIS one drives logic — resume_pdf.py
# picks a two-column (startup) vs single-column (corporate) layout from it
# (framework §3.2/§3.3) — so it's a closed enum, not free text.
CultureSignal = Literal["startup", "corporate"]


class TailoredBullet(BaseModel):
    """One bullet from the Gemini tailor response — see docs/PROMPTS.md
    section 3. `original` must be traceable to the stored resume; that's
    verified by services/guardrail.py, not by the LLM."""

    original: str
    tailored: str
    job_keyword_targeted: str


class JdAnalysis(BaseModel):
    """The framework's §1 JD-analysis, produced alongside the tailored
    bullets. Everything here is LANGUAGE (classification / rephrasing);
    the LOGIC it feeds — layout choice, gap disclosure, skill subsetting —
    is all done in Python downstream (Golden Rule 2). `hard_requirements`
    is ordered by the JD's own stated priority so both the skills column
    and the gap check inherit that order."""

    role_type: RoleType
    hard_requirements: list[str]
    culture_signal: CultureSignal
    jd_title: str
    summary_line: str


class TailorLlmResponse(BaseModel):
    analysis: JdAnalysis
    tailored_bullets: list[TailoredBullet]
    # A REORDERING of the candidate's existing skills to mirror the JD's
    # priority (framework §3.4). Never a source of new skills — guardrail.py
    # intersects this back against the real profile skills before it's stored.
    skills_ordered: list[str]
