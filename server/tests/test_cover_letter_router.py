"""Career-ops integration Brick 2 (ADR-056): routers/cover_letters.py's
orchestration. Same mocking shape as test_tailor_router.py, since
generate_and_store_cover_letter mirrors tailor_and_store's structure."""

from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from models.cover_letter import CoverLetterLlmResponse
from routers import cover_letters as cover_letters_router

_JOB = {
    "id": "job-1",
    "title": "Frontend Developer Intern",
    "company": "Acme",
    "description": "We need a React developer who has shipped production UI.",
    "source": "adzuna",
}


def _jobs_table(select_data):
    table = MagicMock()
    table.select.return_value = table
    table.eq.return_value = table
    table.limit.return_value = table
    table.execute.return_value = MagicMock(data=select_data)
    return table


def _insert_echo_table():
    table = MagicMock()

    def _insert(payload):
        table.execute.return_value = MagicMock(data=[payload])
        return table

    table.insert.side_effect = _insert
    return table


def _fake_llm_response(body_paragraphs=None) -> CoverLetterLlmResponse:
    return CoverLetterLlmResponse(
        opening="I'm excited to apply for the Frontend Developer Intern role at Acme.",
        body_paragraphs=body_paragraphs
        if body_paragraphs is not None
        else ["I built a React dashboard that cut load time by 40%, directly matching this role's focus on performance."],
        closing="I'd welcome the chance to discuss how I can contribute.",
    )


def test_raises_profile_incomplete_when_truly_empty():
    profile = {"id": "profile-1", "experience": [], "projects": []}
    with patch.object(cover_letters_router, "supabase") as mock_supabase, patch.object(
        cover_letters_router, "generate_cover_letter"
    ) as mock_generate:
        mock_supabase.table.return_value = _jobs_table([_JOB])
        try:
            cover_letters_router.generate_and_store_cover_letter(profile, "job-1")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 422
            assert e.detail.startswith("PROFILE_INCOMPLETE:")
    mock_generate.assert_not_called()


def test_uses_projects_when_no_experience_bullets():
    profile = {
        "id": "profile-1",
        "experience": [],
        "projects": [{"name": "Dashboard", "tech": ["react"], "description": "Built a React dashboard, cut load time 40%."}],
        "skills": ["react"],
        "raw_resume_text": "Built a React dashboard, cut load time 40%.",
        "headline": "CS student",
    }
    jobs_table = _jobs_table([_JOB])
    cover_letters_table = _insert_echo_table()
    with patch.object(cover_letters_router, "supabase") as mock_supabase, patch.object(
        cover_letters_router, "generate_cover_letter", return_value=_fake_llm_response(body_paragraphs=[])
    ) as mock_generate:
        mock_supabase.table.side_effect = lambda name: {
            "jobs": jobs_table,
            "cover_letters": cover_letters_table,
            "guardrail_atom_log": _insert_echo_table(),
        }[name]
        row = cover_letters_router.generate_and_store_cover_letter(profile, "job-1")

    assert row["approved"] is False
    # opening + closing always present even with zero body paragraphs.
    assert [p["role"] for p in row["paragraphs"]] == ["opening", "closing"]
    args, _kwargs = mock_generate.call_args
    assert args[0] == []  # bullets
    assert args[1] == profile["projects"]  # projects


def test_fabricated_claim_is_flagged_and_counted():
    """The guardrail decision lives in guardrail.py and is already tested
    there — this pins that generate_and_store_cover_letter actually WIRES
    it in: a paragraph inventing a company the profile never mentions must
    come back guardrail_pass=False and count toward guardrail_flags."""
    profile = {
        "id": "profile-1",
        "experience": [{"role": "Intern", "company": "Acme", "bullets": ["Built a React dashboard, cut load time 40%."]}],
        "projects": [],
        "skills": ["react"],
        "raw_resume_text": "Intern at Acme. Built a React dashboard, cut load time 40%.",
        "headline": "CS student",
    }
    jobs_table = _jobs_table([_JOB])
    cover_letters_table = _insert_echo_table()
    fabricated = _fake_llm_response(
        body_paragraphs=["At Globex Corporation I redesigned the checkout flow, lifting conversion by 90%."]
    )
    with patch.object(cover_letters_router, "supabase") as mock_supabase, patch.object(
        cover_letters_router, "generate_cover_letter", return_value=fabricated
    ):
        mock_supabase.table.side_effect = lambda name: {
            "jobs": jobs_table,
            "cover_letters": cover_letters_table,
            "guardrail_atom_log": _insert_echo_table(),
        }[name]
        row = cover_letters_router.generate_and_store_cover_letter(profile, "job-1")

    body_paragraph = next(p for p in row["paragraphs"] if p["role"] == "body")
    assert body_paragraph["guardrail_pass"] is False
    assert any(a["text"] == "Globex" for a in body_paragraph["flagged_atoms"])
    assert row["guardrail_flags"] >= 1
