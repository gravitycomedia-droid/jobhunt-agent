import re
from dataclasses import dataclass, field

from rapidfuzz import fuzz

from models.tailor import TailoredBullet

# ADR-033: R1 — atom-level guardrail. The old whole-bullet check
# (fuzz.partial_ratio(original, raw_resume_text) >= 85) had a structural blind
# spot: it only proved the *original* bullet was real and then TRUSTED the LLM
# that `tailored` was a faithful rephrase. Nothing checked the tailored text
# itself, so an inflated metric ("40%" -> "60%") or an invented employer ("at
# Google") rode straight through as long as the untouched `original` traced.
#
# R1 replaces that with a decomposition of the TAILORED bullet into factual
# atoms, each of which must trace back to a real source (the profile's
# structured fields + raw resume text). Atoms may be DROPPED by tailoring, never
# added, inflated, or upgraded. Prose — verbs, connectives, framing — floats
# free and is never checked (Golden Rule 4 is about facts, not style).

# ADR-019: a skill "counts as present" if it fuzzy-matches something in the
# candidate's real skills OR appears in the raw resume text. Short skill names
# cost more ratio points per character of noise, so this is looser than a
# sentence-level match would be.
SKILL_MATCH_THRESHOLD = 80


# ---------- shared text-presence helpers (used by atoms + gap check) ----------


def _mentioned_in_text(needle_l: str, text_l: str) -> bool:
    """A whole-word (or whole-phrase) mention, NOT an arbitrary substring —
    substring matching gives false positives ("React" hiding inside
    "practices"). Tokens with non-word characters (C++, C#, .NET) can't use a
    \\b boundary, so they fall back to plain containment, which is safe for
    those precisely because the odd characters make accidental overlap
    vanishingly unlikely."""
    if not needle_l:
        return False
    if re.search(r"[^\w]", needle_l):
        return needle_l in text_l
    return re.search(rf"\b{re.escape(needle_l)}\b", text_l) is not None


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


# ---------- atom extraction ----------

# A curated tech lexicon. Its ONLY job is to catch *lowercase* technology names
# a rephrase might smuggle in ("added kubernetes") — uppercase tech is already
# caught by the proper-noun pass. Deliberately hand-maintained and non-
# exhaustive (a cheap fabrication filter, not a taxonomy): a miss here is a
# false negative that the unextractable-token log (migration 025) surfaces for
# later tuning, never a false positive. Compared case-insensitively.
TECH_LEXICON: frozenset[str] = frozenset(
    {
        "python", "java", "javascript", "typescript", "dart", "go", "golang", "rust",
        "ruby", "php", "kotlin", "swift", "scala", "c", "c++", "c#", ".net", "sql",
        "react", "angular", "vue", "svelte", "flutter", "django", "flask", "fastapi",
        "spring", "express", "node", "nodejs", "next", "nextjs", "rails", "laravel",
        "postgres", "postgresql", "mysql", "mongodb", "redis", "sqlite", "supabase",
        "firebase", "elasticsearch", "cassandra", "dynamodb", "kafka", "rabbitmq",
        "docker", "kubernetes", "terraform", "ansible", "jenkins", "graphql", "grpc",
        "aws", "gcp", "azure", "cloudflare", "vercel", "heroku", "lambda",
        "tensorflow", "pytorch", "pandas", "numpy", "sklearn", "langchain",
        "pgvector", "pinecone", "weaviate", "huggingface", "openai",
        "git", "linux", "nginx", "kafka", "spark", "hadoop", "airflow",
        "html", "css", "sass", "tailwind", "bootstrap", "figma", "webpack", "vite",
    }
)

# Generic words that are frequently capitalized inside a bullet but carry no
# proper-noun signal (sentence-initial verbs, roles, generic nouns). A token in
# here is never treated as an employer/product atom even when capitalized, which
# keeps ordinary rephrasing ("Led the team", "Improved throughput") from
# tripping the guardrail. This is about suppressing false positives; an invented
# EMPLOYER ("Google", "Meta") is never a generic word and still gets flagged.
_COMMON_CAPITALIZED: frozenset[str] = frozenset(
    {
        # action verbs that commonly open a bullet
        "led", "built", "managed", "developed", "designed", "implemented",
        "created", "improved", "reduced", "increased", "delivered", "launched",
        "owned", "drove", "spearheaded", "architected", "engineered", "shipped",
        "collaborated", "partnered", "coordinated", "oversaw", "streamlined",
        "optimized", "automated", "analyzed", "researched", "maintained",
        "supported", "enabled", "established", "founded", "scaled", "migrated",
        "refactored", "deployed", "integrated", "mentored", "wrote", "added",
        # generic nouns / connectives
        "team", "teams", "project", "projects", "product", "products", "company",
        "system", "systems", "platform", "service", "services", "application",
        "applications", "app", "apps", "feature", "features", "pipeline",
        "process", "processes", "the", "a", "an", "and", "or", "of", "for", "to",
        "with", "in", "on", "by", "across", "using", "via", "per", "at",
    }
)

# A number, optionally with a magnitude/percentage suffix. Captures "40%",
# "40 percent", "1,200", "3.5x", "12", "$4M", "2024". The suffix is normalized
# so "40%" and "40 percent" collapse to the same atom.
_NUMBER_RE = re.compile(r"(\d[\d,]*(?:\.\d+)?)\s*(%|percent|x\b|k\b|m\b|bn\b|b\b|\+)?", re.IGNORECASE)

# A capitalized word or dotted/plus token (proper-noun candidate). Allows the
# internal punctuation of tech names (Node.js, C++, .NET) so they survive intact.
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9.+#]*")

_SUFFIX_ALIASES = {"percent": "%", "bn": "b"}


def _normalize_number(digits: str, suffix: str | None) -> str:
    """Canonical form so equal magnitudes compare equal: strip thousands
    commas, drop a trailing '.0', fold 'percent'->'%' / 'bn'->'b'. A bare '+'
    (as in '500+') is dropped — '500+ users' still traces to a source '500'."""
    value = digits.replace(",", "")
    if value.endswith(".0"):
        value = value[:-2]
    suffix_l = (suffix or "").strip().lower()
    suffix_l = _SUFFIX_ALIASES.get(suffix_l, suffix_l)
    if suffix_l == "+":
        suffix_l = ""
    return f"{value}{suffix_l}"


def _number_atoms(text: str) -> list[str]:
    return [_normalize_number(m.group(1), m.group(2)) for m in _NUMBER_RE.finditer(text)]


@dataclass
class SourceContext:
    """Everything a tailored bullet is allowed to trace back to, precomputed
    once per tailor call (not per bullet). Built from the stored profile: raw
    resume text plus the structured fields, because an employer or a metric
    lives in a column, not only in the prose."""

    raw_text_lower: str
    skills: list[str]
    numbers: set[str]

    def has_number(self, atom: str) -> bool:
        return atom in self.numbers

    def has_tech(self, token: str) -> bool:
        return _skill_present(token, self.skills, self.raw_text_lower)

    def has_proper_noun(self, token: str) -> bool:
        return _mentioned_in_text(token.lower(), self.raw_text_lower)


def _profile_corpus(profile: dict) -> str:
    """Flatten every factual field of the profile into one searchable string.
    Structured fields matter because a company name or a metric a rephrase
    might echo can live in `experience[].company` / a duration, not only in the
    free-text `raw_resume_text`."""
    parts: list[str] = [profile.get("raw_resume_text") or "", profile.get("headline") or ""]
    parts.extend(profile.get("skills") or [])
    for exp in profile.get("experience") or []:
        parts += [exp.get("role") or "", exp.get("company") or "", exp.get("duration") or ""]
        parts.extend(exp.get("bullets") or [])
    for proj in profile.get("projects") or []:
        parts += [proj.get("name") or "", proj.get("description") or ""]
        parts.extend(proj.get("tech") or [])
    for edu in profile.get("education") or []:
        parts += [edu.get("degree") or "", edu.get("institution") or "", edu.get("year") or ""]
    parts.append(profile.get("name") or "")
    return "\n".join(p for p in parts if p)


def build_source_context(profile: dict) -> SourceContext:
    corpus = _profile_corpus(profile)
    return SourceContext(
        raw_text_lower=corpus.lower(),
        skills=list(profile.get("skills") or []),
        numbers=set(_number_atoms(corpus)),
    )


@dataclass
class BulletVerification:
    guardrail_pass: bool
    # Atoms in the TAILORED text that trace to nothing real, each tagged with
    # why it's suspicious. Surfaced in the diff UI so the user sees exactly
    # which fact was invented, not just a red bullet.
    flagged_atoms: list[dict] = field(default_factory=list)


def _proper_noun_atoms(tailored: str) -> list[str]:
    """Capitalized, non-sentence-initial tokens that look like a name — an
    employer, product, or org a rephrase may have introduced. The first token
    is skipped (bullets start capitalized regardless), tech names are handled by
    the tech pass, and generic capitalized words are excluded to keep ordinary
    rephrasing quiet."""
    atoms: list[str] = []
    for i, m in enumerate(_WORD_RE.finditer(tailored)):
        token = m.group(0)
        if i == 0:  # sentence-initial capitalization is not a name signal
            continue
        if not token[0].isupper():
            continue
        low = token.lower()
        if low in _COMMON_CAPITALIZED or low in TECH_LEXICON:
            continue
        if len(token) < 3:  # "AI", "ML" etc. are too short to disambiguate; leave to tech pass
            continue
        atoms.append(token)
    return atoms


def _tech_atoms(tailored: str) -> list[str]:
    """Lowercase-comparison tokens that ARE known technologies. Its purpose is
    the lowercase case ("added kubernetes"); anything uppercase is already a
    proper-noun candidate."""
    seen: set[str] = set()
    out: list[str] = []
    for m in _WORD_RE.finditer(tailored):
        low = m.group(0).lower()
        if low in TECH_LEXICON and low not in seen:
            seen.add(low)
            out.append(m.group(0))
    return out


def verify_bullet_atoms(tailored: str, ctx: SourceContext) -> BulletVerification:
    """Decompose one tailored bullet into factual atoms and prove each traces
    to the source. A number must appear in the source numbers (no inflation);
    a technology must be one the candidate actually has; a proper noun must be
    named somewhere real (no invented employer). Everything else is prose and
    passes untouched."""
    flagged: list[dict] = []

    for atom in _number_atoms(tailored):
        if not ctx.has_number(atom):
            flagged.append({"text": atom, "kind": "number"})

    for token in _tech_atoms(tailored):
        if not ctx.has_tech(token):
            flagged.append({"text": token, "kind": "tech"})

    for token in _proper_noun_atoms(tailored):
        if not ctx.has_proper_noun(token):
            flagged.append({"text": token, "kind": "proper_noun"})

    return BulletVerification(guardrail_pass=not flagged, flagged_atoms=flagged)


def verify_bullets(bullets: list[TailoredBullet], profile: dict) -> list[dict]:
    """Runs every LLM-tailored bullet through the atom-level post-check
    (Golden Rule 4 — this is the enforcement, not the prompt instructions).
    Returns the shape stored in tailored_resumes.bullets: [{original, tailored,
    keyword, guardrail_pass, flagged_atoms}]."""
    ctx = build_source_context(profile)
    results: list[dict] = []
    for b in bullets:
        v = verify_bullet_atoms(b.tailored, ctx)
        results.append(
            {
                "original": b.original,
                "tailored": b.tailored,
                "keyword": b.job_keyword_targeted,
                "guardrail_pass": v.guardrail_pass,
                "flagged_atoms": v.flagged_atoms,
            }
        )
    return results


def collect_untraceable_atoms(verified_bullets: list[dict]) -> list[dict]:
    """Flatten the flagged atoms across a tailor result for the migration-025
    log (routers/tailor.py persists these best-effort). Feeds later lexicon
    tuning and the R-E golden set — which words the guardrail keeps tripping on
    tells us where the atom extractor is wrong."""
    out: list[dict] = []
    for i, b in enumerate(verified_bullets):
        for atom in b.get("flagged_atoms") or []:
            out.append({"bullet_index": i, "text": atom["text"], "kind": atom["kind"]})
    return out


# ---------- ADR-019: skill subsetting + gap check (unchanged by R1) ----------


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
