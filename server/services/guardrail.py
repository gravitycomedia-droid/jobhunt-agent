from rapidfuzz import fuzz

from models.tailor import TailoredBullet

# ADR-004: every tailored bullet's `original` must be traceable to the real
# resume, verbatim-or-fuzzy at this threshold. partial_ratio (not ratio) is
# deliberate — `original` is one bullet, raw_resume_text is the whole
# document, so we're checking "is this bullet a substring-ish match
# somewhere in there", not "does the whole document equal this bullet".
GUARDRAIL_THRESHOLD = 85


def verify_bullet(original: str, raw_resume_text: str) -> bool:
    return fuzz.partial_ratio(original, raw_resume_text) >= GUARDRAIL_THRESHOLD


def verify_bullets(bullets: list[TailoredBullet], raw_resume_text: str) -> list[dict]:
    """Runs every LLM-tailored bullet through the deterministic post-check
    (Golden Rule 4 — this is the enforcement, not the prompt instructions).
    Returns the shape stored in tailored_resumes.bullets: [{original,
    tailored, keyword, guardrail_pass}]."""
    return [
        {
            "original": b.original,
            "tailored": b.tailored,
            "keyword": b.job_keyword_targeted,
            "guardrail_pass": verify_bullet(b.original, raw_resume_text),
        }
        for b in bullets
    ]
