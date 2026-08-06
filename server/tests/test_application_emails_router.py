"""Career-ops integration Brick 3 (ADR-057): routers/application_emails.py.
Same mocking shape as test_tailor_router.py/test_cover_letter_router.py."""

from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from models.application_email import ApplicationEmailLlmResponse
from routers import application_emails as router_module

_APPLICATION = {
    "id": "app-1",
    "profile_id": "profile-1",
    "job_id": "job-1",
    "contact_email": "recruiter@acme.com",
}
_JOB = {"id": "job-1", "title": "Frontend Developer Intern", "company": "Acme", "description": "React role."}


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

    def _insert(payload):
        table.execute.return_value = MagicMock(data=[payload])
        return table

    table.insert.side_effect = _insert
    return table


def _fake_llm_response(body="Thanks for considering my application for this role.") -> ApplicationEmailLlmResponse:
    return ApplicationEmailLlmResponse(subject="Application for Frontend Developer Intern", body=body)


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
        router_module, "generate_application_email"
    ) as mock_generate:
        mock_supabase.table.side_effect = lambda name: {
            "applications": _table([_APPLICATION]),
            "jobs": _table([_JOB]),
        }[name]
        try:
            router_module.draft_and_store_application_email(profile, "app-1", "application")
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 422
            assert e.detail.startswith("PROFILE_INCOMPLETE:")
    mock_generate.assert_not_called()


def test_wrong_owner_is_404_not_leaked():
    other_profile = _profile(id="someone-else")
    with patch.object(router_module, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = lambda name: {"applications": _table([_APPLICATION])}[name]
        try:
            router_module._owned_application("app-1", other_profile["id"])
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 404


def test_drafts_and_stores_a_row():
    profile = _profile()
    applications_table = _table([_APPLICATION])
    jobs_table = _table([_JOB])
    emails_table = _insert_echo_table()
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "generate_application_email", return_value=_fake_llm_response()
    ) as mock_generate:
        mock_supabase.table.side_effect = lambda name: {
            "applications": applications_table,
            "jobs": jobs_table,
            "application_emails": emails_table,
        }[name]
        row = router_module.draft_and_store_application_email(profile, "app-1", "referral")

    assert row["kind"] == "referral"
    assert row["guardrail_pass"] is True
    args, _kwargs = mock_generate.call_args
    assert args[0] == "referral"  # kind travels through


def test_fabricated_claim_is_flagged():
    profile = _profile()
    applications_table = _table([_APPLICATION])
    jobs_table = _table([_JOB])
    emails_table = _insert_echo_table()
    fabricated = _fake_llm_response(body="I led a team of 50 engineers at Globex Corporation to ship this feature.")
    with patch.object(router_module, "supabase") as mock_supabase, patch.object(
        router_module, "generate_application_email", return_value=fabricated
    ):
        mock_supabase.table.side_effect = lambda name: {
            "applications": applications_table,
            "jobs": jobs_table,
            "application_emails": emails_table,
            "guardrail_atom_log": _insert_echo_table(),
        }[name]
        row = router_module.draft_and_store_application_email(profile, "app-1", "cold")

    assert row["guardrail_pass"] is False
    assert any(a["text"] == "Globex" for a in row["flagged_atoms"])


def test_send_requires_contact_email():
    import asyncio

    app_no_contact = {**_APPLICATION, "contact_email": None}
    with patch.object(router_module, "supabase") as mock_supabase:
        mock_supabase.table.side_effect = lambda name: {"applications": _table([app_no_contact])}[name]
        try:
            asyncio.run(router_module.send_application_email_endpoint("app-1", "email-1", _profile()))
            assert False, "expected HTTPException"
        except HTTPException as e:
            assert e.status_code == 422
            assert "contact email" in e.detail.lower()
