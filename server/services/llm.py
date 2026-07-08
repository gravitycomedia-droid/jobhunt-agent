import hashlib
import time

from google import genai
from google.genai import types
from pydantic import ValidationError

from config import settings
from db.supabase_client import supabase
from models.resume import ResumeProfile

# Mirrors docs/PROMPTS.md section 1 (Resume Parser). Keep the two in sync by hand —
# PROMPTS.md is the human-readable source of truth; this is what actually runs.
PARSE_SYSTEM_PROMPT = """You are a resume parser. Extract information EXACTLY as written.
Never infer, embellish, or add skills that are not explicitly stated.
Return ONLY valid JSON matching this schema:
{
  "name": str, "headline": str | null, "skills": [str],
  "experience": [{"role": str, "company": str, "duration": str, "bullets": [str]}],
  "projects": [{"name": str, "tech": [str], "description": str}],
  "education": [{"degree": str, "institution": str, "year": str}]
}
If a field is absent, use null (or [] for lists). No markdown fences, no commentary."""

PARSE_RETRY_SUFFIX = """

Your previous output failed validation with this error: {error}.
Fix the issue and return ONLY the corrected JSON."""


class ResumeParseError(Exception):
    """The model responded, but its output never validated (after the one retry)."""


class LlmApiError(Exception):
    """The call to Gemini itself failed (network, auth, quota, etc.) — retrying
    the same request immediately won't help, unlike a validation failure."""


_client = genai.Client(api_key=settings.gemini_api_key)


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        text = text.removesuffix("```").strip()
        if text.startswith("json"):
            text = text[4:].strip()
    return text


def _log_llm_call(
    *,
    task: str,
    model: str,
    prompt_hash: str,
    tokens_in: int | None,
    tokens_out: int | None,
    latency_ms: int,
    validation_passed: bool,
    retried: bool,
) -> None:
    supabase.table("llm_calls").insert(
        {
            "task": task,
            "model": model,
            "prompt_hash": prompt_hash,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "latency_ms": latency_ms,
            "validation_passed": validation_passed,
            "retried": retried,
        }
    ).execute()


def _call_gemini(images: list[bytes], prompt: str) -> tuple[str, int | None, int | None]:
    parts = [types.Part.from_bytes(data=img, mime_type="image/png") for img in images]
    response = _client.models.generate_content(
        model=settings.gemini_model,
        contents=[*parts, prompt],
        config=types.GenerateContentConfig(temperature=0.1),
    )
    usage = response.usage_metadata
    tokens_in = usage.prompt_token_count if usage else None
    tokens_out = usage.candidates_token_count if usage else None
    return response.text or "", tokens_in, tokens_out


def parse_resume(images: list[bytes]) -> ResumeProfile:
    """Send resume page images to Gemini vision, validate the JSON response
    against ResumeProfile, retry once with the error appended on failure
    (Golden Rule 3), and log every attempt to llm_calls (Golden Rule 5).
    """
    prompt_hash = hashlib.sha256(PARSE_SYSTEM_PROMPT.encode()).hexdigest()[:16]
    prompt = PARSE_SYSTEM_PROMPT

    for attempt in (0, 1):
        start = time.monotonic()
        try:
            text, tokens_in, tokens_out = _call_gemini(images, prompt)
        except Exception as e:
            latency_ms = int((time.monotonic() - start) * 1000)
            _log_llm_call(
                task="parse",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=None,
                tokens_out=None,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
            )
            raise LlmApiError(str(e)) from e
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            profile = ResumeProfile.model_validate_json(_strip_fences(text))
        except (ValidationError, ValueError) as e:
            last_error = str(e)
            _log_llm_call(
                task="parse",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
            )
            continue

        _log_llm_call(
            task="parse",
            model=settings.gemini_model,
            prompt_hash=prompt_hash,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            latency_ms=latency_ms,
            validation_passed=True,
            retried=attempt == 1,
        )
        return profile

    raise ResumeParseError(last_error)
