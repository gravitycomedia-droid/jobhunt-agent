"""Career-ops integration Brick 4 (ADR-058): routers/interview_prep.py.
Same mocking shape as test_application_emails_router.py."""

from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from models.interview_prep import InterviewPackLlmResponse, InterviewQuestionLlm
from routers import interview_prep as router_module

_APPLICATION = {"id": "app-1", "profile_id": "profile-1", "job_id": "job-1"}
_JOB = {"id": "job-1", "title": "Frontend Developer Intern", "company": "Acme", "description": "React role."}
_MATCH = {"gaps": ["No testing experience"], "strengths": ["Strong React"]}


def _table(select_data):
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.order.return_value = table
    table.limit.return_value = table
    table.execute.return_value = MagicMock(data=select_data)
    return table


def _insert_echo_table():
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.limit.return_value = table
    table.order.return_value = table

    def _insert(payload):
        table.execute.return_value = MagicMock(data=[payload])
        return table

    table.insert.side_effect = _insert
    return table


def _fake_pack(situation="Built a dashboard at Acme", result="Cut load time 40%") -> InterviewPackLlmResponse:
    return InterviewPackLlmResponse(
        questions=[
            InterviewQuestionLlm(
                question="Tell me about a time you improved performance.",
                category="behavioral",
                inferred=False,
                situation=situation,
                task="Needed to speed up the dashboard",
                action="Profiled and optimized the render path",
                result=result,
            )
        ]
    )


def _profile(**overrides):
    base = {
        "id": "profile-1",
        "experience": [{"role": "Intern", "company": "Acme", "bullets": ["Built a React dashboard, cut load time 40%."]}],
        "projects": [],
        "skills": ["react"],
        "raw_resume_text": "Intern at Acme. Built a React dashboard, cut load time 40%.",
        "headline": "CS student",
    }
    base.update(overrides)
    return base


def test_raises_profile_incomplete_when_truly_empty():
    profile = _profile(experience=[], projects=[])
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "generate_interview_pack"
    ) as mock_generate:
        mock_supabase.table.side_effect = lambda name: {
            "applications": _table([_APPLICATION]),
            "jobs": _table([_JOB]),
            "matches": _table([]),
        }[name]
        try:
            router_module.generate_pack_for_application(profile, "app-1")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 422
            assert e.detail.startswith("PROFILE_INCOMPLETE:")
    mock_generate.assert_not_called()


def test_wrong_owner_is_404_not_leaked():
    with patch.object(router_module, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = lambda name: {"applications": _table([_APPLICATION])}[name]
        try:
            router_module._owned_application("app-1", "someone-else")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 404


def test_generates_pack_with_match_gaps():
    profile = _profile()
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "generate_interview_pack", return_value=_fake_pack()
    ) as mock_generate:
        mock_supabase.table.side_effect = lambda name: {
            "applications": _table([_APPLICATION]),
            "jobs": _table([_JOB]),
            "matches": _table([_MATCH]),
            "guardrail_atom_log": _insert_echo_table(),
        }[name]
        result = router_module.generate_pack_for_application(profile, "app-1")

    assert result["job_id"] == "job-1"
    assert len(result["questions"]) == 1
    assert result["questions"][0]["guardrail_pass"] is True
    # gaps/strengths from the match row travel into the prompt call
    args, _kwargs = mock_generate.call_args
    assert args[3] == ["No testing experience"]  # gaps
    assert args[4] == ["Strong React"]  # strengths


def test_no_match_row_falls_back_to_empty_gaps():
    profile = _profile()
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "generate_interview_pack", return_value=_fake_pack()
    ) as mock_generate:
        mock_supabase.table.side_effect = lambda name: {
            "applications": _table([_APPLICATION]),
            "jobs": _table([_JOB]),
            "matches": _table([]),  # no cached match row (e.g. manually-added job)
            "guardrail_atom_log": _insert_echo_table(),
        }[name]
        router_module.generate_pack_for_application(profile, "app-1")

    args, _kwargs = mock_generate.call_args
    assert args[3] == []
    assert args[4] == []


def test_fabricated_claim_is_flagged():
    profile = _profile()
    fabricated = _fake_pack(situation="Led a team of 50 engineers at Globex Corporation")
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "generate_interview_pack", return_value=fabricated
    ):
        mock_supabase.table.side_effect = lambda name: {
            "applications": _table([_APPLICATION]),
            "jobs": _table([_JOB]),
            "matches": _table([]),
            "guardrail_atom_log": _insert_echo_table(),
        }[name]
        result = router_module.generate_pack_for_application(profile, "app-1")

    q = result["questions"][0]
    assert q["guardrail_pass"] is False
    assert any(a["text"] == "Globex" for a in q["flagged_atoms"])


def test_story_crud_roundtrip():
    profile = _profile()
    story_row = {
        "id": "story-1",
        "profile_id": "profile-1",
        "situation": "s",
        "task": "t",
        "action": "a",
        "result": "r",
        "reflection": None,
        "source_job_id": None,
    }
    stories_table = _insert_echo_table()
    with patch.object(router_module, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = lambda name: {"interview_stories": stories_table}[name]
        import asyncio

        from models.interview_story import InterviewStoryCreate

        created = asyncio.run(
            router_module.create_story(
                InterviewStoryCreate(situation="s", task="t", action="a", result="r"), profile
            )
        )
    assert created["data"]["situation"] == "s"


def test_update_story_wrong_owner_is_404():
    with patch.object(router_module, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = lambda name: {
            "interview_stories": _table([{"id": "story-1", "profile_id": "someone-else"}])
        }[name]
        try:
            router_module._owned_story("story-1", "profile-1")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 404
