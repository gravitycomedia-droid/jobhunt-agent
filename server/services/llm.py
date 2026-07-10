import hashlib
import time

from google import genai
from google.genai import types
from pydantic import ValidationError

from config import settings
from db.supabase_client import supabase
from models.followup import FollowupDraft
from models.job import JobExtraction
from models.match import MatchResult
from models.resume import ResumeProfile
from models.skill_growth import SkillGrowthResponse
from models.tailor import TailorLlmResponse

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

# Mirrors docs/PROMPTS.md section 2 (Match Re-Ranker, Brick 5).
RERANK_SYSTEM_PROMPT = """You evaluate job fit. Compare the CANDIDATE PROFILE to the JOB POSTING.
Be honest about gaps — an inflated score harms the candidate.
Score guide: 80+ strong apply, 65-79 stretch worth trying, <65 skip.
Return ONLY JSON:
{
  "fit_score": int,
  "strengths": [str],       // max 3, where candidate clearly matches
  "gaps": [str],            // max 3, requirements candidate lacks
  "compensators": [str],    // max 2, candidate assets that offset gaps
  "verdict": "apply" | "stretch" | "skip",
  "one_line_reason": str
}"""

RERANK_RETRY_SUFFIX = PARSE_RETRY_SUFFIX

# Mirrors docs/PROMPTS.md section 3 (Resume Tailor, Brick 6).
TAILOR_SYSTEM_PROMPT = """You tailor resumes. You may REPHRASE, REORDER, and EMPHASIZE existing
content to align with the job description. You may NEVER:
- invent experience, skills, metrics, or employers
- change dates, titles, or durations
- add technologies the candidate has not listed
Every output bullet must be traceable to a source bullet.
Return ONLY JSON:
{
  "tailored_bullets": [
    {
      "original": str,            // the exact source bullet you started from
      "tailored": str,            // your rephrased version
      "job_keyword_targeted": str // which JD requirement this addresses
    }
  ]
}"""

TAILOR_RETRY_SUFFIX = PARSE_RETRY_SUFFIX

# Mirrors docs/PROMPTS.md section 4 (Follow-up Draft, Brick 8).
FOLLOWUP_SYSTEM_PROMPT = """You draft brief, warm, professional follow-up emails for job applications
with no response after 7+ days. Rules: 90-120 words, no desperation, no
guilt-tripping, reference the specific role, end with a light call to action.
Return ONLY JSON: {"subject": str, "body": str}"""

FOLLOWUP_RETRY_SUFFIX = PARSE_RETRY_SUFFIX

# Mirrors docs/PROMPTS.md section 6 (Add Job extraction, frontend rebuild
# Phase 2). Extraction only — never invents a field the page doesn't state,
# same "extract, don't infer" discipline as PARSE_SYSTEM_PROMPT.
JOB_EXTRACT_SYSTEM_PROMPT = """You extract job posting details from a web page's raw text. Extract information
EXACTLY as stated. Never infer, embellish, or guess a field that isn't
clearly present — use null instead.
Return ONLY valid JSON matching this schema:
{
  "title": str, "company": str | null, "location": str | null,
  "description": str | null, "salary_min": number | null, "salary_max": number | null
}
If the page doesn't look like a job posting at all, still return your best
guess for "title" from the page's main heading — the caller decides
whether to accept it. No markdown fences, no commentary."""

JOB_EXTRACT_RETRY_SUFFIX = PARSE_RETRY_SUFFIX

# Mirrors docs/PROMPTS.md section 7 (Skill Growth, Phase 4). Clustering and
# suggestion only — the model must NEVER invent a match-rate percentage or
# any other number; services/skill_growth.py computes the one real stat
# that ships (Golden Rule 2: LLMs handle language, code handles logic).
SKILL_GROWTH_SYSTEM_PROMPT = """You help a job seeker close skill gaps found across their job matches.
You will receive a numbered list of gap notes (one per match, may repeat
similar skills in different words). Group them into distinct skills, and
for each skill suggest realistic courses and small project ideas.
Do NOT invent or estimate any percentage, score, or "impact" number —
only the caller computes real statistics from your gap_indices.
Return ONLY JSON:
{
  "items": [
    {
      "skill": str,
      "reason": str,                 // one sentence, grounded in the gap notes for this skill
      "gap_indices": [int],          // indices (0-based) into the input list that this skill covers
      "courses": [{"title": str, "provider": str, "duration": str}],   // max 2
      "projects": [{"title": str, "impact": str}]                      // max 2
    }
  ]
}"""

SKILL_GROWTH_RETRY_SUFFIX = PARSE_RETRY_SUFFIX


class ResumeParseError(Exception):
    """The model responded, but its output never validated (after the one retry)."""


class RerankError(Exception):
    """The model responded, but its output never validated (after the one retry)."""


class TailorError(Exception):
    """The model responded, but its output never validated (after the one retry)."""


class FollowupError(Exception):
    """The model responded, but its output never validated (after the one retry)."""


class JobExtractError(Exception):
    """The model responded, but its output never validated (after the one retry)."""


class SkillGrowthError(Exception):
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
    profile_id: str | None = None,
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
            "profile_id": profile_id,
        }
    ).execute()


def _call_gemini(images: list[bytes], prompt: str, temperature: float = 0.1) -> tuple[str, int | None, int | None]:
    parts = [types.Part.from_bytes(data=img, mime_type="image/png") for img in images]
    response = _client.models.generate_content(
        model=settings.gemini_model,
        contents=[*parts, prompt],
        config=types.GenerateContentConfig(temperature=temperature),
    )
    usage = response.usage_metadata
    tokens_in = usage.prompt_token_count if usage else None
    tokens_out = usage.candidates_token_count if usage else None
    return response.text or "", tokens_in, tokens_out


def parse_resume(images: list[bytes], profile_id: str | None = None) -> ResumeProfile:
    """Send resume page images to Gemini vision, validate the JSON response
    against ResumeProfile, retry once with the error appended on failure
    (Golden Rule 3), and log every attempt to llm_calls (Golden Rule 5).
    `profile_id` is None here in practice — this is the one task that runs
    before a profile row exists (POST /resume/parse creates it from the
    result), so this call can't be attributed to one yet.
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
                profile_id=profile_id,
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
                profile_id=profile_id,
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
            profile_id=profile_id,
        )
        return profile

    raise ResumeParseError(last_error)


def _rerank_user_prompt(profile: dict, job: dict) -> str:
    return f"""CANDIDATE PROFILE:
{ResumeProfile.model_validate(profile).model_dump_json()}

JOB POSTING:
{job.get('title', '')} at {job.get('company', '')}, {job.get('location', '')}
{job.get('description', '')}"""


def rerank_job(profile: dict, job: dict, profile_id: str | None = None) -> MatchResult:
    """Stage 2 of the two-stage RAG match (ADR-001, Brick 5): ask Gemini to
    score fit between a stored profile and one shortlisted job, validate
    against MatchResult, retry once with the error appended on failure
    (Golden Rule 3), and log every attempt to llm_calls (Golden Rule 5).
    """
    prompt_hash = hashlib.sha256(RERANK_SYSTEM_PROMPT.encode()).hexdigest()[:16]
    user_prompt = _rerank_user_prompt(profile, job)
    prompt = f"{RERANK_SYSTEM_PROMPT}\n\n{user_prompt}"

    for attempt in (0, 1):
        start = time.monotonic()
        try:
            text, tokens_in, tokens_out = _call_gemini([], prompt, temperature=0.2)
        except Exception as e:
            latency_ms = int((time.monotonic() - start) * 1000)
            _log_llm_call(
                task="rerank",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=None,
                tokens_out=None,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            raise LlmApiError(str(e)) from e
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            result = MatchResult.model_validate_json(_strip_fences(text))
        except (ValidationError, ValueError) as e:
            last_error = str(e)
            _log_llm_call(
                task="rerank",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            prompt = f"{RERANK_SYSTEM_PROMPT}\n\n{user_prompt}{RERANK_RETRY_SUFFIX.format(error=last_error)}"
            continue

        _log_llm_call(
            task="rerank",
            model=settings.gemini_model,
            prompt_hash=prompt_hash,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            latency_ms=latency_ms,
            validation_passed=True,
            retried=attempt == 1,
            profile_id=profile_id,
        )
        return result

    raise RerankError(last_error)


def _tailor_user_prompt(bullets: list[str], job_description: str) -> str:
    bullets_list = "\n".join(f"- {b}" for b in bullets)
    return f"""CANDIDATE RESUME BULLETS:
{bullets_list}

TARGET JOB POSTING:
{job_description}"""


def tailor_resume(bullets: list[str], job_description: str, profile_id: str | None = None) -> TailorLlmResponse:
    """Brick 6: ask Gemini to rephrase resume bullets toward a job posting,
    validate against TailorLlmResponse, retry once with the error appended
    on failure (Golden Rule 3), and log every attempt to llm_calls (Golden
    Rule 5). The anti-fabrication guarantee is NOT this function's job —
    services/guardrail.py's post-check on the result is (ADR-004).
    """
    prompt_hash = hashlib.sha256(TAILOR_SYSTEM_PROMPT.encode()).hexdigest()[:16]
    user_prompt = _tailor_user_prompt(bullets, job_description)
    prompt = f"{TAILOR_SYSTEM_PROMPT}\n\n{user_prompt}"

    for attempt in (0, 1):
        start = time.monotonic()
        try:
            text, tokens_in, tokens_out = _call_gemini([], prompt, temperature=0.6)
        except Exception as e:
            latency_ms = int((time.monotonic() - start) * 1000)
            _log_llm_call(
                task="tailor",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=None,
                tokens_out=None,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            raise LlmApiError(str(e)) from e
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            result = TailorLlmResponse.model_validate_json(_strip_fences(text))
        except (ValidationError, ValueError) as e:
            last_error = str(e)
            _log_llm_call(
                task="tailor",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            prompt = f"{TAILOR_SYSTEM_PROMPT}\n\n{user_prompt}{TAILOR_RETRY_SUFFIX.format(error=last_error)}"
            continue

        _log_llm_call(
            task="tailor",
            model=settings.gemini_model,
            prompt_hash=prompt_hash,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            latency_ms=latency_ms,
            validation_passed=True,
            retried=attempt == 1,
            profile_id=profile_id,
        )
        return result

    raise TailorError(last_error)


def _followup_user_prompt(job_title: str, company: str, applied_date: str, headline: str) -> str:
    return f"""Role applied for: {job_title} at {company}
Applied on: {applied_date}
One line about the candidate: {headline}"""


def generate_followup_draft(
    job_title: str, company: str, applied_date: str, headline: str, profile_id: str | None = None
) -> FollowupDraft:
    """Brick 8: drafts a follow-up email for an application sitting in
    'applied' with no response after 7+ days. Validates against
    FollowupDraft, retries once with the error appended on failure
    (Golden Rule 3), and logs every attempt to llm_calls (Golden Rule 5).
    Drafting only — nothing here sends an email (Golden Rule: no
    auto-submitting anywhere).
    """
    prompt_hash = hashlib.sha256(FOLLOWUP_SYSTEM_PROMPT.encode()).hexdigest()[:16]
    user_prompt = _followup_user_prompt(job_title, company, applied_date, headline)
    prompt = f"{FOLLOWUP_SYSTEM_PROMPT}\n\n{user_prompt}"

    for attempt in (0, 1):
        start = time.monotonic()
        try:
            text, tokens_in, tokens_out = _call_gemini([], prompt, temperature=0.7)
        except Exception as e:
            latency_ms = int((time.monotonic() - start) * 1000)
            _log_llm_call(
                task="followup",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=None,
                tokens_out=None,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            raise LlmApiError(str(e)) from e
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            result = FollowupDraft.model_validate_json(_strip_fences(text))
        except (ValidationError, ValueError) as e:
            last_error = str(e)
            _log_llm_call(
                task="followup",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            prompt = f"{FOLLOWUP_SYSTEM_PROMPT}\n\n{user_prompt}{FOLLOWUP_RETRY_SUFFIX.format(error=last_error)}"
            continue

        _log_llm_call(
            task="followup",
            model=settings.gemini_model,
            prompt_hash=prompt_hash,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            latency_ms=latency_ms,
            validation_passed=True,
            retried=attempt == 1,
            profile_id=profile_id,
        )
        return result

    raise FollowupError(last_error)


def extract_job_from_text(page_text: str, profile_id: str | None = None) -> JobExtraction:
    """Add Job (frontend rebuild Phase 2): asks Gemini to pull structured
    fields out of a fetched page's raw text, validates against
    JobExtraction, retries once with the error appended on failure (Golden
    Rule 3), and logs every attempt to llm_calls (Golden Rule 5). The page
    itself was fetched by the caller (routers/jobs.py) — this function only
    ever sees text, never touches the network.
    """
    prompt_hash = hashlib.sha256(JOB_EXTRACT_SYSTEM_PROMPT.encode()).hexdigest()[:16]
    # Page text can be long; Gemini's context window handles it, but there's
    # no reason to pay for tokens past what a posting realistically needs.
    user_prompt = f"PAGE TEXT:\n{page_text[:12000]}"
    prompt = f"{JOB_EXTRACT_SYSTEM_PROMPT}\n\n{user_prompt}"

    for attempt in (0, 1):
        start = time.monotonic()
        try:
            text, tokens_in, tokens_out = _call_gemini([], prompt, temperature=0.1)
        except Exception as e:
            latency_ms = int((time.monotonic() - start) * 1000)
            _log_llm_call(
                task="extract_job",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=None,
                tokens_out=None,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            raise LlmApiError(str(e)) from e
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            result = JobExtraction.model_validate_json(_strip_fences(text))
        except (ValidationError, ValueError) as e:
            last_error = str(e)
            _log_llm_call(
                task="extract_job",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            prompt = f"{JOB_EXTRACT_SYSTEM_PROMPT}\n\n{user_prompt}{JOB_EXTRACT_RETRY_SUFFIX.format(error=last_error)}"
            continue

        _log_llm_call(
            task="extract_job",
            model=settings.gemini_model,
            prompt_hash=prompt_hash,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            latency_ms=latency_ms,
            validation_passed=True,
            retried=attempt == 1,
            profile_id=profile_id,
        )
        return result

    raise JobExtractError(last_error)


def generate_skill_growth(gaps: list[str], profile_id: str | None = None) -> SkillGrowthResponse:
    """Phase 4 Skill Growth screen: clusters raw gap notes (from
    services/matching.py's cached `matches.gaps`) into skills and suggests
    courses/projects. Validates against SkillGrowthResponse, retries once
    with the error appended on failure (Golden Rule 3), and logs every
    attempt to llm_calls (Golden Rule 5). Frequency/sorting is NOT this
    function's job — services/skill_growth.py does that from gap_indices.
    """
    prompt_hash = hashlib.sha256(SKILL_GROWTH_SYSTEM_PROMPT.encode()).hexdigest()[:16]
    numbered_gaps = "\n".join(f"{i}. {g}" for i, g in enumerate(gaps))
    user_prompt = f"GAP NOTES:\n{numbered_gaps}"
    prompt = f"{SKILL_GROWTH_SYSTEM_PROMPT}\n\n{user_prompt}"

    for attempt in (0, 1):
        start = time.monotonic()
        try:
            text, tokens_in, tokens_out = _call_gemini([], prompt, temperature=0.4)
        except Exception as e:
            latency_ms = int((time.monotonic() - start) * 1000)
            _log_llm_call(
                task="skill_growth",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=None,
                tokens_out=None,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            raise LlmApiError(str(e)) from e
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            result = SkillGrowthResponse.model_validate_json(_strip_fences(text))
        except (ValidationError, ValueError) as e:
            last_error = str(e)
            _log_llm_call(
                task="skill_growth",
                model=settings.gemini_model,
                prompt_hash=prompt_hash,
                tokens_in=tokens_in,
                tokens_out=tokens_out,
                latency_ms=latency_ms,
                validation_passed=False,
                retried=attempt == 1,
                profile_id=profile_id,
            )
            prompt = f"{SKILL_GROWTH_SYSTEM_PROMPT}\n\n{user_prompt}{SKILL_GROWTH_RETRY_SUFFIX.format(error=last_error)}"
            continue

        _log_llm_call(
            task="skill_growth",
            model=settings.gemini_model,
            prompt_hash=prompt_hash,
            tokens_in=tokens_in,
            tokens_out=tokens_out,
            latency_ms=latency_ms,
            validation_passed=True,
            retried=attempt == 1,
            profile_id=profile_id,
        )
        return result

    raise SkillGrowthError(last_error)
