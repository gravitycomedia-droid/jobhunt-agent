from services.llm import generate_skill_growth
from services.matching import get_ranked_matches

DEFAULT_LIMIT = 5


def get_skill_growth(profile: dict, limit: int = DEFAULT_LIMIT) -> list[dict]:
    """Phase 4: aggregates real gaps from the caller's cached matches
    (services/matching.py::get_ranked_matches) into skills-to-learn,
    grounded in a real "N of M matches" frequency — never a fabricated
    percentage. The LLM only clusters/labels raw gap text (Golden Rule 2);
    all counting and sorting happens here in Python.
    """
    matches = get_ranked_matches(profile, limit=50)
    if not matches:
        return []

    # get_ranked_matches spreads the job row directly (**job), so "id" here
    # is the job id, not a nested "job" key.
    gaps: list[tuple[str, str]] = [(m["id"], g) for m in matches for g in (m.get("gaps") or [])]
    if not gaps:
        return []

    result = generate_skill_growth([g for _, g in gaps], profile_id=profile["id"])
    total_matches = len(matches)

    scored = []
    for item in result.items:
        match_ids = {gaps[i][0] for i in item.gap_indices if 0 <= i < len(gaps)}
        scored.append(
            {
                "skill": item.skill,
                "reason": item.reason,
                "frequency": len(match_ids),
                "frequency_label": f"{len(match_ids)} of {total_matches} matches",
                "courses": [c.model_dump() for c in item.courses],
                "projects": [p.model_dump() for p in item.projects],
            }
        )

    scored.sort(key=lambda x: -x["frequency"])
    return scored[:limit]
