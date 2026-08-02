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
    table.upsert.return_value = table
    table.limit.return_value = table
    table.order.return_value = table
    table.not_ = MagicMock()
    table.not_.is_.return_value = table
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


# --- ADR-054: location/salary preference boost + thin-profile verdict cap ---


def test_location_bonus_matches_a_preferred_city_via_synonym():
    job = {"location": "Bengaluru, Karnataka"}
    tokens = matching._expand_location_tokens(["Bangalore"])
    assert matching._location_bonus(job, tokens) == 1.0


def test_location_bonus_always_matches_remote():
    job = {"location": "Remote"}
    tokens = matching._expand_location_tokens(["Hyderabad"])
    assert matching._location_bonus(job, tokens) == 1.0


def test_location_bonus_is_zero_without_a_preference():
    job = {"location": "Chennai"}
    assert matching._location_bonus(job, set()) == 0.0


def test_location_bonus_is_zero_when_job_has_no_location_or_no_overlap():
    tokens = matching._expand_location_tokens(["Hyderabad"])
    assert matching._location_bonus({"location": None}, tokens) == 0.0
    assert matching._location_bonus({"location": "Pune"}, tokens) == 0.0


@pytest.mark.parametrize(
    "job,min_salary,expected",
    [
        ({"salary_max": 900000}, 800000, 1.0),  # clears the floor
        ({"salary_max": 700000}, 800000, 0.5),  # within 15% — partial
        ({"salary_max": 500000}, 800000, 0.0),  # well short
        ({"salary_max": None}, 800000, 0.0),  # unlisted — never penalized
        ({"salary_max": 500000}, None, 0.0),  # no stated preference
    ],
)
def test_salary_bonus_thresholds(job, min_salary, expected):
    assert matching._salary_bonus(job, min_salary) == expected


def test_final_score_combines_role_location_and_salary_boosts():
    # 70 base + 15 (full role) + 10 (full location) + 5 (half salary) = 100
    assert matching._final_score(70, 1.0, 1.0, 0.5) == 100


def test_has_tailorable_content_true_with_only_a_project():
    profile = {"experience": [], "projects": [{"name": "X", "description": "Built a thing"}]}
    assert matching._has_tailorable_content(profile) is True


def test_has_tailorable_content_false_when_totally_empty():
    profile = {"experience": [], "projects": []}
    assert matching._has_tailorable_content(profile) is False
    assert matching._has_tailorable_content({}) is False


def test_rerank_shortlist_caps_apply_to_stretch_for_a_profile_with_nothing_to_tailor():
    """A fresher with no experience bullets and no project descriptions can
    still score an honest 'apply' from the LLM — but POST /tailor/{job_id}
    has nothing to build a resume from, so the board must not promise it."""
    thin_profile = {"id": "profile-2", "skills": ["python"], "experience": [], "projects": []}
    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_jobs") as mock_rerank:
        matches_table = _table_mock([])
        mock_supabase.table.side_effect = lambda name: {"matches": matches_table}[name]
        with patch.object(matching, "_stage1_shortlist", return_value=[_JOB_A]):
            mock_rerank.return_value = [_result(fit_score=90, role_alignment=0.0)]
            matching.rerank_shortlist(thin_profile, limit=20)

    inserted_rows = matches_table.insert.call_args[0][0]
    assert inserted_rows[0]["verdict"] == "stretch"
    assert matching._PROFILE_GAP_MESSAGE in inserted_rows[0]["gaps"]


def test_rescore_cached_matches_recomputes_from_stored_raw_score_without_llm():
    profile = {
        "id": "profile-1",
        "target_locations": ["Hyderabad"],
        "min_salary": None,
        "experience": [],
        "projects": [{"name": "X", "description": "Built a thing"}],
    }
    cached = [{"id": "match-1", "job_id": "job-a", "raw_fit_score": 70, "role_alignment": 1.0, "gaps": []}]
    jobs = [{"id": "job-a", "location": "Hyderabad", "salary_min": None, "salary_max": None}]

    with patch.object(matching, "supabase") as mock_supabase, patch.object(matching, "rerank_jobs"):
        matches_table = _table_mock(cached)
        jobs_table = _table_mock(jobs)
        mock_supabase.table.side_effect = lambda name: {"matches": matches_table, "jobs": jobs_table}[name]
        updated = matching.rescore_cached_matches(profile)

    assert updated == 1
    upserted = matches_table.upsert.call_args[0][0]
    # 70 (raw) + 15 (full role) + 10 (full location, Hyderabad matches) = 95
    assert upserted[0]["fit_score"] == 95
    assert upserted[0]["verdict"] == "apply"


def test_rescore_cached_matches_is_a_noop_with_nothing_cached():
    with patch.object(matching, "supabase") as mock_supabase:
        mock_supabase.table.return_value = _table_mock([])
        assert matching.rescore_cached_matches(_PROFILE) == 0
