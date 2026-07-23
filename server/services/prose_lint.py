"""Track B, R3 — deterministic résumé-prose lint.

Pure Python, NO LLM (Golden Rule 2: code handles logic). Every check is a
function of the text alone, so the whole module is exhaustively unit-testable
and produces identical advice for identical input. Crucially this is **advice
only — it NEVER blocks tailoring or approval.** The output is a list of
suggestions the diff UI shows next to a bullet; the user decides. That's the
contract the master plan sets ("advice only — never blocks"), and it's why lint
findings live apart from the guardrail (`services/guardrail.py`), which DOES
gate: fabrication is a hard stop, weak prose is a nudge.
"""

import re
from dataclasses import dataclass

from services.guardrail import _number_atoms, _proper_noun_atoms, _tech_atoms

# Openers that signal duty-listing rather than achievement — the single most
# common résumé weakness. Matched as a phrase at the very start, case-folded.
_WEAK_OPENERS: tuple[str, ...] = (
    "responsible for",
    "worked on",
    "helped",
    "assisted with",
    "assisted",
    "participated in",
    "involved in",
    "tasked with",
    "duties included",
    "in charge of",
    "handled",
    "contributed to",
)

# Filler that adds length without information. Whole-word / phrase, case-folded.
_FILLER: tuple[str, ...] = (
    "very",
    "really",
    "successfully",
    "effectively",
    "efficiently",
    "various",
    "several",
    "a lot of",
    "lots of",
    "in order to",
    "basically",
    "actually",
    "utilize",
    "utilized",
)

# First person has no place on a résumé (every line is implicitly "I").
_PRONOUNS: frozenset[str] = frozenset({"i", "me", "my", "mine", "we", "us", "our", "ours"})

# "to be" auxiliaries that front a passive construction.
_TO_BE: frozenset[str] = frozenset({"is", "are", "was", "were", "be", "been", "being"})

# Irregular past-tense leading verbs (they don't end in -ed, so the -ed test
# alone would misread them as present tense).
_IRREGULAR_PAST: frozenset[str] = frozenset(
    {
        "led", "built", "ran", "wrote", "drove", "grew", "made", "gave", "took",
        "oversaw", "met", "held", "sold", "won", "brought", "taught", "set",
        "cut", "put", "began", "chose", "drew", "rebuilt", "spent", "sent",
    }
)

# A leading verb we can confidently read as base-form / present tense. Kept
# explicit (not "any word without -ed") so odd nouns don't get called a verb.
_PRESENT_VERBS: frozenset[str] = frozenset(
    {
        "lead", "build", "manage", "develop", "design", "create", "drive",
        "own", "ship", "deliver", "improve", "reduce", "increase", "maintain",
        "support", "mentor", "run", "write", "architect", "engineer", "scale",
        "automate", "optimize", "analyze", "research", "collaborate", "coordinate",
    }
)

_MAX_LEN = 180  # a bullet past this reads as a paragraph; trim it
_MAX_VERB_REPEATS = 2  # a leading verb used more than twice reads as monotonous

_PASSIVE_RE = re.compile(r"\b(is|are|was|were|be|been|being)\s+(\w*ed)\b", re.IGNORECASE)
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9.+#'-]*")


@dataclass
class ProseFinding:
    bullet_index: int
    code: str
    message: str
    severity: str  # "warn" (worth fixing) | "info" (stylistic nudge)


def _finding(i: int, code: str, message: str, severity: str = "warn") -> dict:
    return {"bullet_index": i, "code": code, "message": message, "severity": severity}


def _leading_verb(bullet: str) -> str | None:
    m = _WORD_RE.search(bullet)
    return m.group(0).lower() if m else None


def _tense_of(verb: str | None) -> str | None:
    """'past' | 'present' | None (can't tell). Deliberately conservative:
    an ambiguous opener returns None and never triggers a tense finding."""
    if not verb:
        return None
    if verb in _IRREGULAR_PAST or (verb.endswith("ed") and len(verb) > 3):
        return "past"
    if verb in _PRESENT_VERBS:
        return "present"
    return None


def _lint_single(bullet: str, i: int) -> list[dict]:
    findings: list[dict] = []
    text = bullet.strip()
    low = text.lower()

    for opener in _WEAK_OPENERS:
        if low.startswith(opener):
            findings.append(
                _finding(i, "weak_opener", f"Opens with '{opener}' — lead with a strong action verb instead.")
            )
            break

    if len(text) > _MAX_LEN:
        findings.append(
            _finding(i, "too_long", f"{len(text)} chars — over ~{_MAX_LEN}; split or trim to one crisp line.")
        )

    if _PASSIVE_RE.search(text):
        findings.append(_finding(i, "passive_voice", "Passive voice — say what you did, actively."))

    words = {w.lower() for w in _WORD_RE.findall(text)}
    pronoun_hit = sorted(words & _PRONOUNS)
    if pronoun_hit:
        findings.append(
            _finding(i, "pronoun", f"First-person pronoun ({', '.join(pronoun_hit)}) — drop it; résumés are implicitly 'I'.")
        )

    fillers = [f for f in _FILLER if re.search(rf"\b{re.escape(f)}\b", low)]
    if fillers:
        findings.append(_finding(i, "filler", f"Filler ({', '.join(fillers)}) — cut for a tighter line.", "info"))

    # Zero-atom density: no number, tech, or proper noun anywhere — a claim
    # with nothing concrete behind it. This is the hook R5 (metric prompting)
    # later attaches to; for now it's a nudge to add a measurable result.
    if not (_number_atoms(text) or _tech_atoms(text) or _proper_noun_atoms(text)):
        findings.append(
            _finding(i, "zero_atom", "No metric, technology, or named result — add something concrete.", "info")
        )

    return findings


def lint_bullets(bullets: list[str]) -> list[dict]:
    """Run every check across a set of bullets. Single-bullet checks run per
    line; verb-repetition and tense-consistency need the whole set, so they're
    computed here. Returns a flat, index-keyed list of advisory findings —
    ordered by bullet, then by the order checks fire — never a pass/fail."""
    findings: list[dict] = []
    for i, bullet in enumerate(bullets):
        findings.extend(_lint_single(bullet, i))

    # Verb repetition: a leading verb used more than twice across the résumé.
    # Flag every occurrence past the second so the UI can point at the specific
    # lines to vary.
    leading = [(i, _leading_verb(b)) for i, b in enumerate(bullets)]
    counts: dict[str, int] = {}
    for _, verb in leading:
        if verb:
            counts[verb] = counts.get(verb, 0) + 1
    seen: dict[str, int] = {}
    for i, verb in leading:
        if not verb or counts.get(verb, 0) <= _MAX_VERB_REPEATS:
            continue
        seen[verb] = seen.get(verb, 0) + 1
        if seen[verb] > _MAX_VERB_REPEATS:
            findings.append(
                _finding(i, "verb_repetition", f"'{verb.capitalize()}' opens {counts[verb]} bullets — vary the verb.")
            )

    # Tense consistency: if the set mixes past and present leading verbs, flag
    # the minority tense (the likelier mistakes). A résumé should be uniformly
    # past, or present only for the current role — we can't see recency here, so
    # we advise, never enforce.
    tenses = [(i, _tense_of(verb)) for i, verb in leading]
    present = {i for i, t in tenses if t == "present"}
    past = {i for i, t in tenses if t == "past"}
    if present and past:
        minority = present if len(present) <= len(past) else past
        label = "present" if minority is present else "past"
        for i in sorted(minority):
            findings.append(
                _finding(i, "tense_mixed", f"{label.capitalize()}-tense opener in an otherwise mixed set — keep tense consistent.", "info")
            )

    findings.sort(key=lambda f: f["bullet_index"])
    return findings
