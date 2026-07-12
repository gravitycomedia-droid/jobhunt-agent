"""ADR-024: request bodies reject unknown fields and over-length text at the
edge (a 422 the user sees) instead of silently ignoring or truncating them."""

import pytest
from pydantic import ValidationError

from models.application import ApplicationCreate, ApplicationStateUpdate
from models.common import MAX_DESCRIPTION_LEN, MAX_NOTES_LEN
from routers.jobs import ManualJobCreate, ManualJobUrl
from routers.resume import OnboardingStepUpdate, StudentInfoUpdate, TargetRolesUpdate


# --- extra="forbid": unknown fields are rejected, not ignored --------------


def test_extra_fields_are_rejected():
    with pytest.raises(ValidationError, match="[Ee]xtra"):
        ApplicationCreate(job_id="j1", surprise="whoops")


def test_manual_job_url_rejects_extra_fields():
    with pytest.raises(ValidationError, match="[Ee]xtra"):
        ManualJobUrl(url="https://x.example.com", follow_redirects_to="http://169.254.169.254")


# --- length caps: over-length free text is a 422, not a silent truncation ---


def test_description_over_cap_is_rejected():
    with pytest.raises(ValidationError):
        ManualJobCreate(title="Dev", description="x" * (MAX_DESCRIPTION_LEN + 1), url="https://x.example.com")


def test_notes_over_cap_is_rejected():
    with pytest.raises(ValidationError):
        ApplicationStateUpdate(notes="n" * (MAX_NOTES_LEN + 1))


def test_a_normal_body_still_validates():
    body = ManualJobCreate(title="Backend Engineer", description="Build APIs.", url="https://x.example.com")
    assert body.title == "Backend Engineer"


# --- Literals: status-like strings can't be arbitrary ----------------------


def test_application_state_rejects_unknown_stage():
    with pytest.raises(ValidationError):
        ApplicationStateUpdate(state="ghosted")  # not one of the six real stages


def test_onboarding_step_rejects_unknown_step():
    with pytest.raises(ValidationError):
        OnboardingStepUpdate(step="halfway")


def test_employment_type_rejects_unknown_value():
    with pytest.raises(ValidationError):
        StudentInfoUpdate(employment_type="freelancer")


def test_valid_literals_pass():
    assert ApplicationStateUpdate(state="interview").state == "interview"
    assert OnboardingStepUpdate(step="roles").step == "roles"
    assert StudentInfoUpdate(employment_type="student").employment_type == "student"


# --- list-length caps ------------------------------------------------------


def test_target_roles_list_is_length_capped():
    with pytest.raises(ValidationError):
        TargetRolesUpdate(target_roles=[f"role {i}" for i in range(1000)])
