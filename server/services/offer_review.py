"""Career-ops integration Brick 5 (docs/21-career-ops-integration-plan.md
§1.3, DECISIONS.md ADR-059).

One deterministic Python check (Golden Rule 2 — code handles logic): does
the LLM's clause_text actually appear in the document it was reading? Every
other generative surface in this app (tailoring, cover letters, application
emails, interview prep) has an atom-level guardrail proving a claim traces
to the candidate's real profile (services/guardrail.py). Offer review isn't
generating claims about the candidate — it's reading a document handed to
it — so the equivalent check here is different in shape but the same in
spirit: prove a quoted clause traces to the real source text instead of
trusting the model's quote at face value.
"""

import re

_WS_RE = re.compile(r"\s+")


def _normalize(text: str) -> str:
    return _WS_RE.sub(" ", (text or "").lower()).strip()


def verify_clause_grounding(clauses: list[dict], raw_text: str) -> list[dict]:
    """Marks each clause `grounded: True` only when its clause_text is
    found, whitespace/case-normalized, inside `raw_text`. A clause the
    model paraphrased or invented comes back False — surfaced to the user
    (routers/offer_reviews.py) rather than silently trusted.

    Deliberately an exact (normalized) substring match, not fuzzy —
    OFFER_REVIEW_SYSTEM_PROMPT explicitly instructs the model to copy
    clause_text verbatim, so a failed match is a real signal, not prompt
    noise to be tolerated away.
    """
    norm_raw = _normalize(raw_text)
    out: list[dict] = []
    for c in clauses:
        norm_clause = _normalize(c.get("clause_text", ""))
        grounded = bool(norm_clause) and norm_clause in norm_raw
        out.append({**c, "grounded": grounded})
    return out
