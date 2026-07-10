from unittest.mock import MagicMock, patch

from models.match import MatchResult
from services import matching

_PROFILE = {"id": "profile-1", "name": "Jane Doe", "skills": ["python"]}
_JOB_A = {"id": "job-a", "title": "Backend Engineer", "company": "Acme", "similarity": 0.9}
_JOB_B = {"id": "job-b", "title": "Frontend Engineer", "company": "Acme", "similarity": 0.8}

_RESULT = MatchResult(
    fit_score=82,
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
    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_job") as mock_rerank:
        mock_supabase.table.side_effect = lambda name: {
            "profiles": _table_mock([_PROFILE]),
            "matches": _table_mock([{"job_id": "job-a"}]),  # job-a already ranked
        }[name]
        mock_supabase.rpc.return_value.execute.return_value = MagicMock(
            data=[{"job_id": "job-a", "similarity": 0.9}, {"job_id": "job-b", "similarity": 0.8}]
        )
        with patch.object(matching, "_stage1_shortlist", return_value=[_JOB_A, _JOB_B]):
            mock_rerank.return_value = _RESULT
            result = matching.rerank_shortlist(_PROFILE, limit=20)

    # Phase 3: rerank_job also takes profile_id, so cost stats can attribute
    # this call back to the caller.
    mock_rerank.assert_called_once_with(_PROFILE, _JOB_B, profile_id=_PROFILE["id"])
    assert result == {"reranked": 1, "skipped": 1}


def test_rerank_shortlist_returns_zero_when_shortlist_empty():
    with patch.object(matching, "supabase") as mock_supabase:
        mock_supabase.table.return_value = _table_mock([_PROFILE])
        with patch.object(matching, "_stage1_shortlist", return_value=[]):
            result = matching.rerank_shortlist(_PROFILE)
    assert result == {"reranked": 0, "skipped": 0}
