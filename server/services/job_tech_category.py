"""Technical sub-specialism for an engineering posting (ADR-003 v4).

Answers a different question from services/job_category.py, and the two run
together on every ingested row:

    job_category.py      → which FUNCTION    → engineering | sales | hr | …
    job_tech_category.py → which SPECIALISM  → frontend | backend | ai_ml | …

`category` is what keeps the broad pool navigable at all; it cannot express
"Frontend vs. Backend" because every one of those collapses to `engineering`.
This module splits that bucket, and ONLY that bucket — see classify_tech_category's
`category` argument.

Non-technical postings get None, not a member of the enum. "Which engineering
specialism is this telecalling role?" has no answer, and `category` already
records that it's sales. Storing a redundant 'non_it' here would be a second way
to spell something the schema already says.

## Two passes, LLM strictly second

Pass 1 is keyword/skill-tag matching in Python and resolves the large majority of
rows at zero cost. Pass 2 is ONE batched DeepSeek call for whatever Pass 1 leaves
genuinely ambiguous.

This is a narrower use of the LLM than job_category.py's docstring argues
against, and the difference is worth stating because the two modules would
otherwise look contradictory. That module rejects an LLM for the FUNCTION call
because it runs on every row (hundreds a day) and the function vocabulary is
stable and title-visible — a regex gets it right ~90% of the time for free.
Specialism is the harder problem: a posting titled plainly "Software Engineer"
whose only signal is a skill list is not decidable by keyword at all, and it is
the single most common title in the pool. So the LLM sees only the residue —
already-known-to-be-engineering rows that keyword logic explicitly could not
place — batched into one call per ingestion run, never one call per job. On a
typical run that is a single request, and golden rule 2 still holds: code decides
everything code can decide.

Pass 2 degrades to 'other_it' on any failure. A missing specialism label must
never be able to fail an ingestion run.
"""

import logging
import re

from pydantic import BaseModel, field_validator

logger = logging.getLogger(__name__)

# The closed vocabulary. Mirrored by the CHECK constraint in migration 028 and by
# the app's filter chips — adding a value means touching all three.
TECH_CATEGORIES = (
    "frontend",
    "backend",
    "full_stack",
    "mobile",
    "ai_ml",
    "data_science",
    "devops_cloud",
    "cybersecurity",
    "qa_testing",
    "blockchain",
    "other_it",
)

# The `category` values (migration 027) this module applies to. Everything else
# is non-technical and gets None.
_TECHNICAL_CATEGORIES = frozenset({"engineering", "data"})

# (tech_category, pattern) in PRIORITY order — first match wins, so the list runs
# most- to least-specific. The ordering carries real weight:
#
#   * full_stack before frontend/backend: "Full Stack (React + Node)" contains
#     both of their strongest tokens and is neither.
#   * mobile before frontend: React Native is mobile, but "react" is the
#     frontend pattern's most common hit.
#   * ai_ml before data_science: "ML Engineer" is not a data analyst, and
#     "data scientist" would otherwise claim ML rows through `data`.
#   * blockchain/cybersecurity/qa/devops before the generic web ones: those are
#     specialisms whose postings routinely also list React or Python.
_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "full_stack",
        re.compile(r"full[\s.\-_]?stack | \bmern\b | \bmean\b | front\s*and\s*back\s*end", re.I | re.X),
    ),
    (
        "mobile",
        re.compile(
            r"""
            react[\s-]*native | \bflutter\b | \bdart\b | android\s+(develop|engineer|intern|app)
          | \bios\s+(develop|engineer|intern|app) | \bswift(ui)?\b | \bkotlin\b | \bjetpack\s+compose\b
          | mobile\s+(app|develop|engineer) | \bxamarin\b | \bionic\b
            """,
            re.I | re.X,
        ),
    ),
    (
        "ai_ml",
        re.compile(
            r"""
            machine\s+learning | deep\s+learning | \bnlp\b | natural\s+language
          | computer\s+vision | \bllm\b | generative\s+ai | \bgenai\b | \brag\b
          | tensorflow | pytorch | \bkeras\b | scikit | hugging\s*face | \bopencv\b
          | prompt\s+engineer | neural\s+network | \bml\s*ops\b
          # Bare AI/ML need ROLE context — unqualified they match marketing prose
          # ("powered by cutting-edge AI"), the exact bug job_category.py hit.
          | (?:\bai\b|\bml\b)[\s/&\-]{0,3}(?:(?:ai|ml)[\s/&\-]{0,3})?
            (?:engineer|intern|develop|scientist|research|model)
            """,
            re.I | re.X,
        ),
    ),
    (
        "data_science",
        re.compile(
            r"""
            data\s+(scien|analy|engineer) | data[\s-]?analyst | business\s+intelligence
          | \bbi\b\s+(analyst|developer) | power\s?bi | \btableau\b | \blooker\b
          | data\s+visuali[sz]ation | big\s+data | \betl\b | \bspark\b | \bhadoop\b
          | \bairflow\b | \bpandas\b | \bnumpy\b | data\s+warehouse | \bdbt\b
            """,
            re.I | re.X,
        ),
    ),
    (
        "devops_cloud",
        re.compile(
            r"""
            devops | \bsre\b | site\s+reliability | platform\s+engineer
          | cloud\s+(engineer|architect|develop|intern) | kubernetes | \bk8s\b
          | docker | terraform | ansible | jenkins | \bci\s*/?\s*cd\b
          | \baws\b | \bazure\b | \bgcp\b | infrastructure\s+engineer
            """,
            re.I | re.X,
        ),
    ),
    (
        "cybersecurity",
        re.compile(
            r"""
            cyber\s*security | \binfosec\b | information\s+security
          | security\s+(engineer|analyst|intern|research|operations)
          | penetration\s+test | \bpentest\b | ethical\s+hack | vulnerability\s+assess
          | \bsoc\s+analyst | threat\s+(intel|hunt) | \bsiem\b
            """,
            re.I | re.X,
        ),
    ),
    (
        "qa_testing",
        re.compile(
            r"""
            \bqa\b | quality\s+assurance | \bsdet\b | test(ing)?\s+(engineer|intern|analyst)
          | automation\s+test | manual\s+test | \bselenium\b | \bcypress\b
          | \bappium\b | test\s+automation | software\s+testing
            """,
            re.I | re.X,
        ),
    ),
    (
        "blockchain",
        re.compile(
            r"blockchain | \bweb3\b | \bsolidity\b | smart\s+contract | \bethereum\b | \bdefi\b | \bnft\b | \bsolana\b",
            re.I | re.X,
        ),
    ),
    (
        "frontend",
        re.compile(
            r"""
            front[\s.\-_]?end | \breact(\.?js)?\b | \bangular(js)?\b | \bvue(\.?js)?\b
          | \bnext\.?js\b | \bsvelte\b | \bhtml\b | \bcss\b | \bsass\b | \bscss\b
          | \btailwind\b | \bbootstrap\b | \bjquery\b | \bredux\b
          | ui\s+develop | web\s+design(er)? | \bwebflow\b | \bwordpress\b
            """,
            re.I | re.X,
        ),
    ),
    (
        "backend",
        re.compile(
            r"""
            back[\s.\-_]?end | \bnode(\.?js)?\b | \bexpress(\.?js)?\b | \bdjango\b
          | \bflask\b | \bfastapi\b | \bspring(\s*boot)?\b | \blaravel\b | \b\.net\b
          | \brails\b | \bgolang\b | \bgo\s+develop | \brust\b | \bscala\b
          | api\s+develop | \brest\s*ful?\s+api | \bgraphql\b | microservice
          | \bsql\b | \bpostgres(ql)?\b | \bmysql\b | \bmongodb\b | \bredis\b
          | database\s+(develop|admin) | server[\s-]?side | \bphp\b
            """,
            re.I | re.X,
        ),
    ),
]


def _text_for(title: str | None, skills: list[str] | None, description: str | None) -> tuple[str, str]:
    """(title-ish text, body text) for the two-stage match below.

    Skill tags ride with the TITLE rather than the body on purpose. For both new
    sources they are a curated list of what the role actually uses — Instahyre's
    `keywords[]` and Internshala's `.job_skill` chips — which makes them as
    trustworthy as the title and far more so than JD prose. A posting titled
    "Software Engineer" tagged React/Redux/CSS is a frontend role, and only the
    tags say so.
    """
    head = title or ""
    if skills:
        head = f"{head} {' '.join(skills)}"
    # Only the top of the JD — the footer is boilerplate and reliably
    # misclassifies ("we also use AWS internally"). Same rationale as
    # job_filter._head and job_category._head.
    return head, (description or "")[:600]


def classify_tech_category_pass1(
    title: str | None,
    skills: list[str] | None = None,
    description: str | None = None,
) -> str | None:
    """Free keyword pass. Returns a TECH_CATEGORIES member, or None when nothing
    matched (the caller decides whether that's worth an LLM call).

    Title+skills are tried against every pattern before the body is tried against
    any, so an incidental mention deep in a JD can never outrank the plain
    statement of what the job is.
    """
    head, body = _text_for(title, skills, description)
    for tech_category, pattern in _PATTERNS:
        if pattern.search(head):
            return tech_category
    for tech_category, pattern in _PATTERNS:
        if pattern.search(body):
            return tech_category
    return None


def classify_tech_category(
    title: str | None,
    category: str | None,
    skills: list[str] | None = None,
    description: str | None = None,
) -> str | None:
    """Single-row classification, Pass 1 only. Never raises.

    Returns None for a non-technical posting (`category` outside engineering/data)
    without looking at the text at all — "which engineering specialism is this
    sales role?" is a category error, and the patterns would occasionally find a
    false match in one ("Growth Engineer", "Security Guard").

    A technical row that Pass 1 can't place also returns None here. The batched
    entry point below is what turns those into 'other_it' or an LLM answer;
    keeping this function pure and Pass-1-only is what makes it unit-testable
    without mocking a provider.
    """
    if (category or "").strip().lower() not in _TECHNICAL_CATEGORIES:
        return None
    return classify_tech_category_pass1(title, skills, description)


# --- Pass 2: one batched DeepSeek call for the residue -------------------------


class _TechCategoryVerdict(BaseModel):
    """One row's verdict. `index` ties it back to the batch position — asking the
    model to echo an id is far more reliable than trusting list order."""

    index: int
    tech_category: str

    @field_validator("tech_category")
    @classmethod
    def _known(cls, v: str) -> str:
        # Golden rule 3: the closed enum is enforced here, so an invented
        # category ("ml_ops", "web") fails validation and triggers the standard
        # retry-once rather than reaching the CHECK constraint as a 500.
        normalized = (v or "").strip().lower()
        if normalized not in TECH_CATEGORIES:
            raise ValueError(f"Unknown tech_category {v!r}. Valid: {', '.join(TECH_CATEGORIES)}")
        return normalized


class TechCategoryBatch(BaseModel):
    verdicts: list[_TechCategoryVerdict]


_PASS2_SYSTEM = f"""You classify software engineering job postings by technical specialism.

For each posting you are given, choose EXACTLY ONE value from this closed list:
{', '.join(TECH_CATEGORIES)}

Rules:
- full_stack when the role clearly spans both client and server work.
- other_it for a genuine engineering role whose specialism is none of the above
  (embedded, firmware, VLSI, ERP, technical support engineering, hardware).
- Never invent a value outside the list. Never omit a posting.
- Judge the role itself, not the company's industry.

Every posting given to you has ALREADY been confirmed to be a technical role, so
"not a tech job" is not an available answer.

Return ONLY JSON, no prose, no code fences:
{{"verdicts": [{{"index": 0, "tech_category": "backend"}}]}}
Return one verdict for every index you were given."""


def _pass2_user_prompt(rows: list[dict]) -> str:
    lines = []
    for i, row in enumerate(rows):
        skills = ", ".join(row.get("skills") or []) or "none listed"
        blurb = (row.get("description") or "")[:300].replace("\n", " ")
        lines.append(f"[{i}] title: {row.get('title') or 'unknown'} | skills: {skills} | description: {blurb}")
    return "\n".join(lines)


def classify_tech_categories_batch(rows: list[dict], use_llm: bool = True) -> list[str | None]:
    """Classify a whole ingestion batch. Returns one value per input row, aligned
    by position — a TECH_CATEGORIES member, or None for a non-technical posting.

    Each row is a dict of {title, category, skills, description}.

    Pass 1 runs on everything. Only rows that are technical AND unresolved go to
    Pass 2, as a SINGLE batched LLM call regardless of how many there are. With
    `use_llm=False` (or on any LLM failure) those rows fall back to 'other_it',
    which is a real, browsable bucket rather than a hole.
    """
    results: list[str | None] = []
    unresolved: list[int] = []

    for i, row in enumerate(rows):
        if (row.get("category") or "").strip().lower() not in _TECHNICAL_CATEGORIES:
            results.append(None)
            continue
        hit = classify_tech_category_pass1(row.get("title"), row.get("skills"), row.get("description"))
        results.append(hit)
        if hit is None:
            unresolved.append(i)

    if not unresolved:
        return results

    if not use_llm:
        for i in unresolved:
            results[i] = "other_it"
        return results

    logger.info(
        "Tech category: %d/%d rows unresolved by keywords → 1 batched LLM call",
        len(unresolved),
        len(rows),
    )
    try:
        # Imported lazily so this module stays importable (and unit-testable)
        # without a configured LLM provider — Pass 1 has no LLM dependency and
        # is the path that runs on the overwhelming majority of rows.
        from services.llm import run_tech_category_batch

        verdicts = run_tech_category_batch([rows[i] for i in unresolved])
    except Exception as e:
        # Golden rule: a missing specialism label must never fail ingestion.
        logger.warning("Tech category Pass 2 failed, defaulting to other_it: %s: %s", type(e).__name__, e)
        for i in unresolved:
            results[i] = "other_it"
        return results

    by_index = {v.index: v.tech_category for v in verdicts.verdicts}
    for position, row_index in enumerate(unresolved):
        # A row the model skipped entirely still gets a value — 'other_it' rather
        # than None, since we already know it IS a technical posting.
        results[row_index] = by_index.get(position, "other_it")
    return results
