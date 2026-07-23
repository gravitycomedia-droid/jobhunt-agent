from pydantic import BaseModel, Field


class ChatReply(BaseModel):
    """Golden Rule 3: even a free-text chat answer is schema-validated. The model
    is instructed to return {"reply": "..."} so the loop in llm.py can validate,
    retry once on malformed output, and log the call like every other task.

    Plain BaseModel (not StrictModel): this parses LLM output, and extra="forbid"
    would turn a harmless extra key the model invents into a hard failure — the
    same reasoning models/common.py gives for generated models."""

    reply: str = Field(min_length=1, max_length=4000)
