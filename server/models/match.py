from typing import Literal

from pydantic import BaseModel


class MatchResult(BaseModel):
    """Shape returned by the Gemini re-ranker — see docs/PROMPTS.md section 2.
    Mirrors the `matches` table columns (minus profile_id/job_id/similarity,
    which the caller already has)."""

    fit_score: int
    strengths: list[str] = []
    gaps: list[str] = []
    compensators: list[str] = []
    verdict: Literal["apply", "stretch", "skip"]
    one_line_reason: str
