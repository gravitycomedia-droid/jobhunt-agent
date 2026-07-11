import re

from rapidfuzz import fuzz

from models.tailor import TailoredBullet

# ADR-004: every tailored bullet's `original` must be traceable to the real
# resume, verbatim-or-fuzzy at this threshold. partial_ratio (not ratio) is
# deliberate — `original` is one bullet, raw_resume_text is the whole
# document, so we're checking "is this bullet a substring-ish match
# somewhere in there", not "does the whole document equal this bullet".
GUARDRAIL_THRESHOLD = 85

# ADR-019: the same idea applied to individual skills. A skill "counts as
# present" if it fuzzy-matches something in the candidate's real skills OR
# appears in the raw resume text (a skill named only inside a bullet still
# counts). Slightly looser than the bullet threshold — skill names are short,
# so token-level noise costs more ratio points per character.
SKILL_MATCH_THRESHOLD = 80


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


def _mentioned_in_text(skill_l: str, text_l: str) -> bool:
    """A whole-word (or whole-phrase) mention, NOT an arbitrary substring —
    substring matching gives false positives ("React" hiding inside
    "practices"). Skills with non-word characters (C++, C#, .NET) can't use a
    \\b boundary, so they fall back to plain containment, which is safe for
    those precisely because the odd characters make accidental overlap
    vanishingly unlikely."""
    if re.search(r"[^\w]", skill_l):
        return skill_l in text_l
    return re.search(rf"\b{re.escape(skill_l)}\b", text_l) is not None


def _skill_present(skill: str, real_skills: list[str], raw_resume_text: str) -> bool:
    """A skill is genuinely the candidate's if it fuzzy-matches one of their
    listed skills (handles React/React.js, Postgres/PostgreSQL), or is named
    as a whole word anywhere in the raw resume text (a skill that only shows up
    inside a bullet still counts)."""
    skill_l = skill.strip().lower()
    if not skill_l:
        return False
    for real in real_skills:
        if fuzz.ratio(skill_l, real.strip().lower()) >= SKILL_MATCH_THRESHOLD:
            return True
    return _mentioned_in_text(skill_l, raw_resume_text.lower())


def verify_skills(skills_ordered: list[str], real_skills: list[str]) -> list[str]:
    """ADR-019: the LLM's JD-priority reordering of skills, intersected back
    against the candidate's ACTUAL skills so it can never introduce a skill
    they don't have (Golden Rule 4). Keeps the LLM's order for skills it kept,
    then appends any real skills it dropped, so the column is always the full
    real skill set — just reprioritized. Case-insensitive de-dup by the real
    skill's own casing."""
    result: list[str] = []
    seen: set[str] = set()
    remaining = list(real_skills)

    for skill in skills_ordered:
        # Match this LLM-ordered skill to a real one, preferring the real
        # spelling (the LLM may have re-cased or lightly reworded it).
        match = next(
            (r for r in remaining if fuzz.ratio(skill.strip().lower(), r.strip().lower()) >= SKILL_MATCH_THRESHOLD),
            None,
        )
        if match is not None and match.lower() not in seen:
            result.append(match)
            seen.add(match.lower())
            remaining.remove(match)

    # Any real skill the LLM didn't reorder still belongs on the resume.
    for real in remaining:
        if real.lower() not in seen:
            result.append(real)
            seen.add(real.lower())
    return result


def compute_gaps(hard_requirements: list[str], real_skills: list[str], raw_resume_text: str) -> list[str]:
    """The framework's §1 GAP CHECK, done in code (Golden Rule 2): which of
    the JD's stated hard requirements the candidate can't back up with a real
    skill or resume mention. Returned for disclosure to the user — NEVER
    written onto the resume, exactly like a guardrail-flagged bullet. Preserves
    the LLM's JD-priority order and de-dups case-insensitively."""
    gaps: list[str] = []
    seen: set[str] = set()
    for req in hard_requirements:
        key = req.strip().lower()
        if not key or key in seen:
            continue
        seen.add(key)
        if not _skill_present(req, real_skills, raw_resume_text):
            gaps.append(req.strip())
    return gaps
