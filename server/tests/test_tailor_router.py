"""ADR-054: a profile with no work-experience bullets is only a dead end for
tailoring when it *also* has no projects. Pins the relaxed guard in
routers/tailor.py::tailor_and_store and the stable PROFILE_INCOMPLETE prefix
the client matches on to swap a doomed "Retry" for a real CTA."""

from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from models.tailor import JdAnalysis, TailorLlmResponse
from routers import tailor as tailor_router

_JOB = {"id": "job-1", "description": "We need a React developer.", "source": "adzuna"}


def _jobs_table(select_data):
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.limit.return_value = table
    table.execute.return_value = MagicMock(data=select_data)
    return table


def _insert_echo_table():
    """Mimics supabase-py's insert().execute().data[0] by echoing back
    whatever payload was inserted — good enough to assert on without
    hand-writing the exact stored row shape."""
    table = MagicMock()

    def _insert(payload):
        table.execute.return_value = MagicMock(data=[payload])
        return table

    table.insert.side_effect = _insert
    return table


def _fake_llm_response() -> TailorLlmResponse:
    return TailorLlmResponse(
        analysis=JdAnalysis(
            role_type="frontend",
            hard_requirements=["React"],
            culture_signal="startup",
            jd_title="Frontend Developer Intern",
            summary_line="Final-year CS student who built a React dashboard.",
        ),
        tailored_bullets=[],
        skills_ordered=["react"],
    )


def test_raises_profile_incomplete_when_truly_empty():
    profile = {"id": "profile-1", "experience": [], "projects": [], "skills": []}
    with patch.object(tailor_router, "supabase") as mock_supabase, patch.object(
        tailor_router, "tailor_resume"
    ) as mock_tailor:
        mock_supabase.table.return_value = _jobs_table([_JOB])
        try:
            tailor_router.tailor_and_store(profile, "job-1")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 422
            assert e.detail.startswith("PROFILE_INCOMPLETE:")
    mock_tailor.assert_not_called()


def test_uses_projects_when_no_experience_bullets():
    profile = {
        "id": "profile-1",
        "experience": [],
        "projects": [{"name": "Dashboard", "tech": ["react"], "description": "Built a React dashboard."}],
        "skills": ["react"],
        "raw_resume_text": "Built a React dashboard.",
        "headline": "CS student",
    }
    jobs_table = _jobs_table([_JOB])
    tailored_table = _insert_echo_table()
    with patch.object(tailor_router, "supabase") as mock_supabase, patch.object(
        tailor_router, "tailor_resume", return_value=_fake_llm_response()
    ) as mock_tailor:
        mock_supabase.table.side_effect = lambda name: {
            "jobs": jobs_table,
            "tailored_resumes": tailored_table,
        }[name]
        row = tailor_router.tailor_and_store(profile, "job-1")

    assert row["bullets"] == []
    # survivor_originals is empty (no experience bullets); projects passed through.
    args, kwargs = mock_tailor.call_args
    assert args[0] == []
    assert kwargs["projects"] == profile["projects"]
