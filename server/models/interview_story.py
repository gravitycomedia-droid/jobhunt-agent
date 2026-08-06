from pydantic import Field

from models.common import MAX_STORY_FIELD_LEN, StrictModel


class InterviewStoryCreate(StrictModel):
    """A story bank entry — manually written, or saved from a generated
    interview pack's suggested answer (routers/interview_prep.py).
    `reflection` is optional at create time: nothing in this app can know
    how a real interview actually went, so it's usually added later."""

    situation: str = Field(max_length=MAX_STORY_FIELD_LEN)
    task: str = Field(max_length=MAX_STORY_FIELD_LEN)
    action: str = Field(max_length=MAX_STORY_FIELD_LEN)
    result: str = Field(max_length=MAX_STORY_FIELD_LEN)
    reflection: str | None = Field(default=None, max_length=MAX_STORY_FIELD_LEN)
    source_job_id: str | None = None


class InterviewStoryUpdate(StrictModel):
    """Every field optional — PATCH semantics, only sent fields change
    (routers/interview_prep.py's update_story uses `exclude_unset`)."""

    situation: str | None = Field(default=None, max_length=MAX_STORY_FIELD_LEN)
    task: str | None = Field(default=None, max_length=MAX_STORY_FIELD_LEN)
    action: str | None = Field(default=None, max_length=MAX_STORY_FIELD_LEN)
    result: str | None = Field(default=None, max_length=MAX_STORY_FIELD_LEN)
    reflection: str | None = Field(default=None, max_length=MAX_STORY_FIELD_LEN)
