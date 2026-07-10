from pydantic import BaseModel


class SkillCourse(BaseModel):
    title: str
    provider: str
    duration: str


class SkillProject(BaseModel):
    title: str
    impact: str


class SkillGrowthItem(BaseModel):
    skill: str
    reason: str
    # Indices into the gap list the model was given — services/skill_growth.py
    # turns these into a real frequency count. Never trust an LLM-computed
    # number here (Golden Rule 2: LLMs handle language, code handles logic).
    gap_indices: list[int] = []
    courses: list[SkillCourse] = []
    projects: list[SkillProject] = []


class SkillGrowthResponse(BaseModel):
    items: list[SkillGrowthItem] = []
