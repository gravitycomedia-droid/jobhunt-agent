"""Track B, R2 — section-level résumé tailoring (ADR-034).

Tailoring is SELECTION, not only rephrasing. Before a single word goes to the
LLM, we decide *which* bullets earn a place on a one-page résumé for THIS job,
in Python, deterministically (Golden Rule 2). The LLM then only rephrases the
survivors; the drops are disclosed to the user with one-tap restore.

Why deterministic selection matters (the acceptance bar): the same profile + the
same JD must produce the **identical** selection every run. If a human can't
predict what got cut, "we tailored your résumé" is a black box. So scoring is
keyword overlap (offline, exact) optionally blended with embedding cosine, and
the choose step is a pure sort with explicit tie-breaks — never an LLM judgment
and never randomised.

Convention: experiences arrive in résumé order, which is reverse-chronological
(most-recent first), so index 0 is the most-recent role. We don't parse the
free-text `duration` to infer recency — that's brittle and non-deterministic;
document order is the contract the parser already upholds.
"""

import re
from dataclasses import dataclass

from rapidfuzz import fuzz

from services.guardrail import SourceContext, verify_bullet_atoms

# Generic tokens that appear in nearly every JD and carry no matching signal.
_STOPWORDS: frozenset[str] = frozenset(
    {
        "a", "an", "the", "and", "or", "of", "for", "to", "with", "in", "on", "at",
        "by", "as", "is", "are", "be", "you", "we", "our", "your", "will", "have",
        "has", "this", "that", "who", "team", "work", "role", "job", "years",
        "experience", "including", "etc", "using", "across", "strong", "good",
        "ability", "skills", "knowledge", "understanding", "plus", "must", "should",
    }
)

# A one-page résumé holds only so many lines. Past this many bullets per role,
# the weakest are trimmed regardless of relevance (R6 tightens this to true
# cut-to-fit later; this is the coarse cap R2 needs).
PER_EXPERIENCE_CAP = 4

# Fraction of a bullet's own tokens that must be JD-relevant for it to survive
# on its merits. Deliberately low: the point is to trim the clearly-irrelevant
# ("Organised the office cricket league"), not to be aggressive. The most-recent
# role ignores this floor entirely (see below).
RELEVANCE_FLOOR = 0.12

# Weight given to embedding cosine when it's supplied. Keyword overlap stays the
# primary, always-available signal — on this corpus embeddings are squashed into
# a narrow band (see services/matching.py), so lexical overlap discriminates
# better; cosine only breaks ties and rescues a semantic match with no shared
# words. When no cosine is supplied the score is keyword overlap alone.
_COSINE_WEIGHT = 0.35


def _tokens(text: str) -> list[str]:
    return [t for t in re.split(r"[^a-z0-9+#]+", (text or "").lower()) if t and t not in _STOPWORDS]


def jd_token_set(job_description: str) -> set[str]:
    return set(_tokens(job_description))


def keyword_relevance(bullet: str, jd_tokens: set[str]) -> float:
    """Fraction of the bullet's meaningful tokens that also appear in the JD.
    Normalising by the bullet's length (not the JD's) keeps a short punchy
    bullet from being penalised against a long one — this is 'how on-topic is
    this line', not 'how much of the JD does it cover'."""
    toks = _tokens(bullet)
    if not toks:
        return 0.0
    hits = sum(1 for t in set(toks) if t in jd_tokens)
    return hits / len(set(toks))


@dataclass(frozen=True)
class ScoredBullet:
    experience_index: int
    bullet_index: int
    text: str
    relevance: float


def score_bullets(
    experiences: list[dict],
    job_description: str,
    cosine: dict[tuple[int, int], float] | None = None,
) -> list[ScoredBullet]:
    """Relevance for every bullet in every experience. Pure given its inputs —
    keyword overlap is exact; the optional `cosine` map (min-max normalised by
    the caller) is blended in at a fixed weight. Deterministic end to end."""
    jd_tokens = jd_token_set(job_description)
    scored: list[ScoredBullet] = []
    for ei, exp in enumerate(experiences):
        for bi, bullet in enumerate(exp.get("bullets") or []):
            kw = keyword_relevance(bullet, jd_tokens)
            if cosine is not None:
                cos = cosine.get((ei, bi), 0.0)
                rel = (1 - _COSINE_WEIGHT) * kw + _COSINE_WEIGHT * cos
            else:
                rel = kw
            scored.append(ScoredBullet(ei, bi, bullet, rel))
    return scored


@dataclass
class SelectionResult:
    # Bullets that earn a place, best-first WITHIN each experience. Each carries
    # its experience_index so the PDF can regroup them under the right role.
    selected: list[dict]
    # Bullets cut, with the reason — the "Trimmed" list the UI shows, each
    # restorable with one tap.
    trimmed: list[dict]


def _sort_key(sb: ScoredBullet) -> tuple[float, int]:
    # Highest relevance first; original order breaks ties so the choice is
    # reproducible (never dependent on dict/hash iteration order).
    return (-sb.relevance, sb.bullet_index)


def select_bullets(experiences: list[dict], scored: list[ScoredBullet]) -> SelectionResult:
    """Deterministically choose which bullets survive. Rules:

    - per-experience cap: at most PER_EXPERIENCE_CAP bullets from any one role.
    - relevance floor: below RELEVANCE_FLOOR a bullet is a drop candidate...
    - ...EXCEPT the most-recent role (index 0), whose top bullets are always
      kept regardless of floor — 'the most-recent role never drops'.
    - no bare headers: every other role keeps at least its single best bullet,
      so a listed job never renders as a title with no lines.
    """
    by_exp: dict[int, list[ScoredBullet]] = {}
    for sb in scored:
        by_exp.setdefault(sb.experience_index, []).append(sb)

    selected: list[dict] = []
    trimmed: list[dict] = []

    for ei in range(len(experiences)):
        bullets = sorted(by_exp.get(ei, []), key=_sort_key)
        if not bullets:
            continue
        capped = bullets[:PER_EXPERIENCE_CAP]
        overflow = bullets[PER_EXPERIENCE_CAP:]

        is_most_recent = ei == 0
        if is_most_recent:
            keep = capped  # floor ignored — the current role always stays
        else:
            keep = [sb for sb in capped if sb.relevance >= RELEVANCE_FLOOR]
            if not keep:  # never leave a role as a bare header
                keep = capped[:1]

        keep_ids = {id(sb) for sb in keep}
        for sb in keep:
            selected.append(
                {"experience_index": sb.experience_index, "original": sb.text, "relevance": round(sb.relevance, 4)}
            )
        for sb in capped:
            if id(sb) not in keep_ids:
                trimmed.append(_trim(sb, "Below relevance floor for this job"))
        for sb in overflow:
            trimmed.append(_trim(sb, f"Beyond the {PER_EXPERIENCE_CAP}-bullet cap for one role"))

    return SelectionResult(selected=selected, trimmed=trimmed)


def _trim(sb: ScoredBullet, reason: str) -> dict:
    return {
        "experience_index": sb.experience_index,
        "original": sb.text,
        "relevance": round(sb.relevance, 4),
        "reason": reason,
    }


# The LLM echoes each source bullet's `original`; we fuzzy-match it back to a
# selected source to recover its experience_index (the model can lightly reword
# `original`, so this is a match, not an equality). Below this ratio we treat it
# as "no confident match" and fall back to positional assignment.
_MATCH_THRESHOLD = 60


def _best_match_index(original: str, remaining: list[dict]) -> int | None:
    best_i, best = None, -1.0
    o = original.strip().lower()
    for i, sel in enumerate(remaining):
        score = fuzz.ratio(o, sel["original"].strip().lower())
        if score > best:
            best, best_i = score, i
    return best_i if best >= _MATCH_THRESHOLD else None


def _survivor(original: str, tailored: str, keyword: str, ctx: SourceContext, sel: dict) -> dict:
    v = verify_bullet_atoms(tailored, ctx)
    return {
        "original": original,
        "tailored": tailored,
        "keyword": keyword,
        "guardrail_pass": v.guardrail_pass,
        "flagged_atoms": v.flagged_atoms,
        "experience_index": sel["experience_index"],
        "relevance": sel.get("relevance", 0.0),
        "selected": True,
        # Survivors default to accepted iff they clear the guardrail; the user
        # can still reject. This is the same default the approve endpoint uses.
        "accepted": v.guardrail_pass,
    }


def assemble_bullets(selection: SelectionResult, tailored_bullets: list, ctx: SourceContext) -> tuple[list[dict], int]:
    """Merge the LLM's rephrased survivors back onto the deterministic selection
    and append the trimmed bullets, producing the full `tailored_resumes.bullets`
    array. Each entry carries `experience_index` (so the PDF regroups it under
    the right role), `relevance`, `selected` (survivor vs trimmed), and
    `accepted`. Trimmed bullets keep their ORIGINAL text (never sent to the LLM),
    are always guardrail-clean, and default to NOT accepted — the 'Trimmed' list
    the user can restore one-tap. Returns (bullets, guardrail_flag_count)."""
    remaining = [dict(s) for s in selection.selected]
    out: list[dict] = []

    for tb in tailored_bullets:
        idx = _best_match_index(tb.original, remaining)
        if idx is None:
            idx = 0 if remaining else None
        if idx is not None:
            sel = remaining.pop(idx)
        else:  # LLM returned more bullets than we selected — attach to most-recent
            sel = {"experience_index": 0, "relevance": 0.0}
        out.append(_survivor(tb.original, tb.tailored, tb.job_keyword_targeted, ctx, sel))

    # Selected sources the LLM never rephrased still belong on the résumé — keep
    # them verbatim rather than silently losing a chosen bullet.
    for sel in remaining:
        out.append(
            {
                "original": sel["original"],
                "tailored": sel["original"],
                "keyword": "",
                "guardrail_pass": True,
                "flagged_atoms": [],
                "experience_index": sel["experience_index"],
                "relevance": sel.get("relevance", 0.0),
                "selected": True,
                "accepted": True,
            }
        )

    for t in selection.trimmed:
        out.append(
            {
                "original": t["original"],
                "tailored": t["original"],
                "keyword": "",
                "guardrail_pass": True,
                "flagged_atoms": [],
                "experience_index": t["experience_index"],
                "relevance": t.get("relevance", 0.0),
                "selected": False,
                "trim_reason": t["reason"],
                "accepted": False,
            }
        )

    guardrail_flags = sum(1 for b in out if b["selected"] and not b["guardrail_pass"])
    return out, guardrail_flags
