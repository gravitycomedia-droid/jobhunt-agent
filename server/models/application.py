from typing import Literal

from pydantic import Field

from models.common import MAX_EMAIL_LEN, MAX_NOTES_LEN, StrictModel

ApplicationState = Literal["saved", "applied", "replied", "interview", "offer", "rejected"]

APPLICATION_STATES: list[ApplicationState] = [
    "saved",
    "applied",
    "replied",
    "interview",
    "offer",
    "rejected",
]


class ApplicationCreate(StrictModel):
    """POST /applications body — mirrors the `applications` table (migration
    001, Brick 7). `resume_version_id` is optional: a job can be saved to
    the tracker before a tailored resume exists for it."""

    job_id: str = Field(max_length=64)
    resume_version_id: str | None = Field(default=None, max_length=64)
    notes: str | None = Field(default=None, max_length=MAX_NOTES_LEN)


class ApplicationStateUpdate(StrictModel):
    """PATCH /applications/{id} body — the Kanban drag action. `notes` can
    be updated independently of `state`, or alongside it. `contact_email`
    (Phase 4) is the recruiter address "Approve & send" delivers a drafted
    follow-up to — set independently too, same pattern as notes.

    `state` is a Literal, so an unknown stage is a 422 and never reaches the
    table — the state machine is code, not a free string (Golden Rule 2)."""

    state: ApplicationState | None = None
    notes: str | None = Field(default=None, max_length=MAX_NOTES_LEN)
    contact_email: str | None = Field(default=None, max_length=MAX_EMAIL_LEN)
