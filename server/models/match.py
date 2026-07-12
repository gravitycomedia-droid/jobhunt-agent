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
    # ADR-021: how well the JD's own role matches what the user said they
    # want (profiles.target_roles). Judged by the LLM (a language call —
    # "is 'React Engineer' the frontend job this person asked for?"), but
    # never used for arithmetic by it: services/matching.py applies the
    # boost in Python (Golden Rule 2). 0.0 when the user set no targets.
    role_alignment: float = 0.0


class BatchMatchItem(MatchResult):
    """One job's verdict inside a batched re-rank response. `job_ref` is the
    1-based index the prompt listed the job under — the model echoes it back
    so Python can re-attach each verdict to the right job row rather than
    trusting output order (Golden Rule 2: code owns the bookkeeping)."""

    job_ref: int


class BatchMatchResponse(BaseModel):
    """ADR-021: N jobs scored in ONE Gemini call. The candidate profile is
    identical across every job in a shortlist, so the old one-call-per-job
    loop re-sent it N times — the single largest source of Gemini spend in
    this project (137 of 247 calls, ~87% of input tokens)."""

    results: list[BatchMatchItem] = []
