from unittest.mock import MagicMock, patch

import pytest

from models.match import MatchResult
from services import matching

_PROFILE = {"id": "profile-1", "name": "Jane Doe", "skills": ["python"]}
_JOB_A = {"id": "job-a", "title": "Backend Engineer", "company": "Acme", "similarity": 0.9}
_JOB_B = {"id": "job-b", "title": "Frontend Engineer", "company": "Acme", "similarity": 0.8}


def _result(fit_score: int = 82, role_alignment: float = 0.0) -> MatchResult:
    return MatchResult(
        fit_score=fit_score,
        role_alignment=role_alignment,
        strengths=["Python"],
        gaps=[],
        compensators=[],
        verdict="apply",
        one_line_reason="Strong backend match.",
    )


def _table_mock(select_data):
    """Builds a chainable mock mirroring supabase-py's fluent query builder,
    where every method returns self and .execute() yields the given data."""
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.in_.return_value = table
    table.insert.return_value = table
    table.limit.return_value = table
    table.order.return_value = table
    table.execute.return_value = MagicMock(data=select_data)
    return table


def test_rerank_shortlist_skips_already_cached_jobs():
    """The unique (profile_id, job_id) constraint means each job should only
    ever be sent to the LLM once — a re-run must skip jobs already in
    `matches`, not re-score (and re-bill) them."""
    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_jobs") as mock_rerank:
        mock_supabase.table.side_effect = lambda name: {
            "profiles": _table_mock([_PROFILE]),
            "matches": _table_mock([{"job_id": "job-a"}]),  # job-a already ranked
        }[name]
        with patch.object(matching, "_stage1_shortlist", return_value=[_JOB_A, _JOB_B]):
            mock_rerank.return_value = [_result()]
            result = matching.rerank_shortlist(_PROFILE, limit=20)

    # ADR-021: one batched call carrying only the not-yet-ranked jobs.
    mock_rerank.assert_called_once_with(_PROFILE, [_JOB_B], target_roles=[], profile_id=_PROFILE["id"])
    assert result == {"reranked": 1, "skipped": 1, "screened_out": 0}


def test_rerank_shortlist_returns_zero_when_shortlist_empty():
    with patch.object(matching, "supabase") as mock_supabase:
        mock_supabase.table.return_value = _table_mock([_PROFILE])
        with patch.object(matching, "_stage1_shortlist", return_value=[]):
            result = matching.rerank_shortlist(_PROFILE)
    assert result == {"reranked": 0, "skipped": 0, "screened_out": 0}


def test_rerank_batches_in_chunks():
    """ADR-021: more jobs than RERANK_BATCH_SIZE must go out as several batched
    calls — not one call per job (the old behaviour, and the thing that made
    re-ranking 87% of this project's Gemini input tokens)."""
    jobs = [
        {"id": f"job-{i}", "title": "Backend Engineer", "company": "Acme", "similarity": 0.8}
        for i in range(matching.RERANK_BATCH_SIZE + 3)
    ]
    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_jobs") as mock_rerank:
        mock_supabase.table.side_effect = lambda name: {"matches": _table_mock([])}[name]
        with patch.object(matching, "_stage1_shortlist", return_value=jobs):
            mock_rerank.side_effect = lambda p, batch, **kw: [_result() for _ in batch]
            result = matching.rerank_shortlist(_PROFILE, limit=50)

    assert mock_rerank.call_count == 2  # 10 + 3, not 13 separate calls
    assert result["reranked"] == matching.RERANK_BATCH_SIZE + 3


# --- ADR-021 prescreen + role boost (the "fine-tune to target role" fix) ---


def test_prescreen_drops_jobs_outside_the_target_discipline():
    """A frontend developer's pool is full of "Key Account Director" postings
    (measured: 368-job pool, 94 of 114 matches were `skip`). Those must never
    reach Gemini — that's both the wasted spend and the polluted board."""
    frontend = {"id": "j1", "title": "React Frontend Engineer", "description": ""}
    sales = {"id": "j2", "title": "Key Account Director", "description": "Own the sales quota."}
    kept = matching._prescreen([frontend, sales], ["frontend developer"], ["react", "javascript"])
    assert kept == [frontend]


def test_prescreen_keeps_job_that_names_real_skills_even_if_title_is_odd():
    """The title gate is not the only door — a quirky title still survives on
    genuine skill overlap in the body, so we don't discard good jobs."""
    quirky = {"id": "j1", "title": "Product Ninja", "description": "You will use React and TypeScript daily."}
    kept = matching._prescreen([quirky], ["frontend developer"], ["react", "typescript"])
    assert kept == [quirky]


def test_prescreen_is_a_noop_without_target_roles():
    jobs = [{"id": "j1", "title": "Key Account Director", "description": ""}]
    assert matching._prescreen(jobs, [], ["python"]) == jobs


def test_prescreen_falls_back_rather_than_returning_an_empty_board():
    """Safety valve: a thin/badly-matched pool must still show the user
    something to reject, not nothing at all."""
    sales = [{"id": f"j{i}", "title": "Key Account Director", "description": "quota"} for i in range(4)]
    kept = matching._prescreen(sales, ["frontend developer"], ["react"])
    assert kept == sales


@pytest.mark.parametrize(
    "fit,alignment,expected_score,expected_verdict",
    [
        (70, 1.0, 85, "apply"),  # on-target: boosted over the apply line
        (70, 0.0, 70, "stretch"),  # off-target: unboosted, stays a stretch
        (70, 0.5, 78, "stretch"),  # adjacent: half boost
        (98, 1.0, 100, "apply"),  # clamped, never exceeds 100
        (0, 0.0, 0, "skip"),
    ],
)
def test_role_boost_and_verdict_are_computed_in_python(fit, alignment, expected_score, expected_verdict):
    """Golden Rule 2: the model judges "is this their role?" (role_alignment);
    Python does the arithmetic and the state decision."""
    score = matching._final_score(fit, alignment)
    assert score == expected_score
    assert matching._verdict_for(score) == expected_verdict
