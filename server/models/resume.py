from typing import Annotated, Optional

from pydantic import BaseModel, Field

from models.common import (
    MAX_BULLET_LEN,
    MAX_BULLETS_PER_ITEM,
    MAX_COMPANY_LEN,
    MAX_DESCRIPTION_LEN,
    MAX_EDUCATION_ITEMS,
    MAX_EXPERIENCE_ITEMS,
    MAX_HEADLINE_LEN,
    MAX_NAME_LEN,
    MAX_PROJECT_ITEMS,
    MAX_ROLE_LEN,
    MAX_SKILL_LEN,
    MAX_SKILLS,
    MAX_TITLE_LEN,
    MAX_USN_LEN,
    StrictModel,
)


# A capped free-text item inside a list. `max_length` on `list[str]` bounds how
# MANY items arrive, not how long each one is — a single 10MB "skill" would sail
# straight through a list-only cap and into a prompt. Both bounds are needed.
Skill = Annotated[str, Field(max_length=MAX_SKILL_LEN)]
Bullet = Annotated[str, Field(max_length=MAX_BULLET_LEN)]


class ExperienceItem(BaseModel):
    role: str = Field(max_length=MAX_ROLE_LEN)
    company: str = Field(max_length=MAX_COMPANY_LEN)
    duration: Optional[str] = Field(default=None, max_length=100)
    bullets: list[Bullet] = Field(default=[], max_length=MAX_BULLETS_PER_ITEM)


class ProjectItem(BaseModel):
    name: str = Field(max_length=MAX_TITLE_LEN)
    tech: list[Skill] = Field(default=[], max_length=MAX_SKILLS)
    description: Optional[str] = Field(default=None, max_length=MAX_DESCRIPTION_LEN)


class EducationItem(BaseModel):
    degree: str = Field(max_length=MAX_TITLE_LEN)
    institution: str = Field(max_length=MAX_COMPANY_LEN)
    year: Optional[str] = Field(default=None, max_length=50)


class ResumeProfile(BaseModel):
    """Shape returned by the Gemini parser — see docs/PROMPTS.md section 1.

    An LLM RESPONSE model, so deliberately NOT strict: an extra key invented by
    the model should be dropped, not turned into a retry (see models/common.py).
    """

    name: str
    headline: Optional[str] = None
    skills: list[str] = []
    experience: list[ExperienceItem] = []
    projects: list[ProjectItem] = []
    education: list[EducationItem] = []
    # USN (Indian engineering college register number) or an equivalent
    # roll/registration number — most resumes won't have one, that's fine.
    usn: Optional[str] = None


class ResumeProfileUpdate(StrictModel):
    """PATCH /resume/profile body — every field optional so the app can send
    only edited fields. Strict + capped (ADR-024): these values are re-embedded
    and fed into tailoring prompts, so an unbounded `headline` is an unbounded
    prompt."""

    name: Optional[str] = Field(default=None, max_length=MAX_NAME_LEN)
    headline: Optional[str] = Field(default=None, max_length=MAX_HEADLINE_LEN)
    skills: Optional[list[Skill]] = Field(default=None, max_length=MAX_SKILLS)
    experience: Optional[list[ExperienceItem]] = Field(default=None, max_length=MAX_EXPERIENCE_ITEMS)
    projects: Optional[list[ProjectItem]] = Field(default=None, max_length=MAX_PROJECT_ITEMS)
    education: Optional[list[EducationItem]] = Field(default=None, max_length=MAX_EDUCATION_ITEMS)
