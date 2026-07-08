from typing import Optional

from pydantic import BaseModel


class ExperienceItem(BaseModel):
    role: str
    company: str
    duration: Optional[str] = None
    bullets: list[str] = []


class ProjectItem(BaseModel):
    name: str
    tech: list[str] = []
    description: Optional[str] = None


class EducationItem(BaseModel):
    degree: str
    institution: str
    year: Optional[str] = None


class ResumeProfile(BaseModel):
    """Shape returned by the Gemini parser — see docs/PROMPTS.md section 1."""

    name: str
    headline: Optional[str] = None
    skills: list[str] = []
    experience: list[ExperienceItem] = []
    projects: list[ProjectItem] = []
    education: list[EducationItem] = []


class ResumeProfileUpdate(BaseModel):
    """PATCH body — every field optional so the app can send only edited fields."""

    name: Optional[str] = None
    headline: Optional[str] = None
    skills: Optional[list[str]] = None
    experience: Optional[list[ExperienceItem]] = None
    projects: Optional[list[ProjectItem]] = None
    education: Optional[list[EducationItem]] = None
