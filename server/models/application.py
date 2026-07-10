from typing import Literal

from pydantic import BaseModel

ApplicationState = Literal["saved", "applied", "replied", "interview", "offer", "rejected"]

APPLICATION_STATES: list[ApplicationState] = [
    "saved",
    "applied",
    "replied",
    "interview",
    "offer",
    "rejected",
]


class ApplicationCreate(BaseModel):
    """POST /applications body — mirrors the `applications` table (migration
    001, Brick 7). `resume_version_id` is optional: a job can be saved to
    the tracker before a tailored resume exists for it."""

    job_id: str
    resume_version_id: str | None = None
    notes: str | None = None


class ApplicationStateUpdate(BaseModel):
    """PATCH /applications/{id} body — the Kanban drag action. `notes` can
    be updated independently of `state`, or alongside it. `contact_email`
    (Phase 4) is the recruiter address "Approve & send" delivers a drafted
    follow-up to — set independently too, same pattern as notes."""

    state: ApplicationState | None = None
    notes: str | None = None
    contact_email: str | None = None
