"""Phase 6 (§4.1) — the onboarding fork: student vs. professional detail steps
between 'student_info' and 'roles'. Covers the pure step-machine logic (routing
+ forward-only advance) and the new request models' validation, in the
model/logic-level style of test_request_validation.py — no live Supabase."""

import types

import pytest
from pydantic import ValidationError

from models.common import MAX_TARGET_LOCATIONS
from routers import resume as resume_router
from routers.resume import (
    ONBOARDING_STEPS,
    AcademicsUpdate,
    ExperienceUpdate,
    TargetLocationsUpdate,
    _advance_onboarding,
    _fork_step,
)


# --- fork routing ----------------------------------------------------------


def test_student_forks_to_academics():
    assert _fork_step("student") == "academics"


def test_professional_forks_to_experience():
    # Anything that isn't a student is treated as the working-candidate branch.
    assert _fork_step("experienced") == "experience"


# --- step machine ordering (load-bearing for _advance_onboarding) ----------


def test_new_fork_steps_sit_between_student_info_and_roles():
    for step in ("academics", "experience", "locations"):
        assert step in ONBOARDING_STEPS, f"{step} missing from the state machine"
        assert ONBOARDING_STEPS.index("student_info") < ONBOARDING_STEPS.index(step) < ONBOARDING_STEPS.index("roles")


def test_both_branches_are_strictly_increasing_to_locations():
    idx = ONBOARDING_STEPS.index
    # student branch and professional branch must each be monotonic so the
    # forward-only guard never treats a legitimate advance as a regression.
    assert idx("student_info") < idx("academics") < idx("locations")
    assert idx("student_info") < idx("experience") < idx("locations")
    assert idx("locations") < idx("roles") < idx("done")


# --- forward-only advance --------------------------------------------------


class _FakeQuery:
    def __init__(self, recorder):
        self._rec = recorder

    def update(self, payload):
        self._rec.append(payload)
        return self

    def eq(self, *args, **kwargs):
        return self

    def execute(self):
        return types.SimpleNamespace(data=[{}])


class _FakeSupabase:
    def __init__(self, recorder):
        self._rec = recorder

    def table(self, _name):
        return _FakeQuery(self._rec)


@pytest.fixture
def advance_writes(monkeypatch):
    """Captures every profiles.update payload _advance_onboarding writes."""
    writes: list[dict] = []
    monkeypatch.setattr(resume_router, "supabase", _FakeSupabase(writes))
    return writes


def test_fork_advance_writes_academics_for_student(advance_writes):
    _advance_onboarding("p1", "student_info", _fork_step("student"))
    assert advance_writes == [{"onboarding_step": "academics"}]


def test_advance_from_academics_to_locations(advance_writes):
    _advance_onboarding("p1", "academics", "locations")
    assert advance_writes == [{"onboarding_step": "locations"}]


def test_advance_is_a_noop_going_backward(advance_writes):
    # A stale client at 'locations' PATCHing an earlier step must not regress it.
    _advance_onboarding("p1", "locations", "academics")
    assert advance_writes == []


def test_advance_is_a_noop_when_already_done(advance_writes):
    _advance_onboarding("p1", "done", "locations")
    assert advance_writes == []


# --- new request models validate/reject like the rest (ADR-024) ------------


def test_academics_rejects_extra_fields():
    with pytest.raises(ValidationError, match="[Ee]xtra"):
        AcademicsUpdate(branch="CSE", surprise="whoops")


def test_academics_cgpa_out_of_range_is_rejected():
    with pytest.raises(ValidationError):
        AcademicsUpdate(cgpa=11.0)  # scale tops out at 10


def test_academics_all_blank_is_valid_a_skip():
    # Every field optional — an all-blank submit is a valid skip.
    assert AcademicsUpdate().branch is None


def test_experience_negative_years_is_rejected():
    with pytest.raises(ValidationError):
        ExperienceUpdate(experience_years=-1)


def test_experience_notice_over_a_year_is_rejected():
    with pytest.raises(ValidationError):
        ExperienceUpdate(notice_period_days=400)


def test_target_locations_list_is_length_capped():
    with pytest.raises(ValidationError):
        TargetLocationsUpdate(target_locations=[f"City {i}" for i in range(MAX_TARGET_LOCATIONS + 1)])


def test_target_locations_normal_body_validates():
    body = TargetLocationsUpdate(target_locations=["Bengaluru", "Remote"])
    assert body.target_locations == ["Bengaluru", "Remote"]
