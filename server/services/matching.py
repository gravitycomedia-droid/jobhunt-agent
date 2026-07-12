import re

from db.supabase_client import supabase
from services.llm import rerank_jobs

# Stage 2 only re-ranks the top N of the stage-1 shortlist (ADR-001) —
# sending every embedded job to the LLM would defeat the point of stage 1.
DEFAULT_RERANK_LIMIT = 20

# ADR-021: how many jobs go to Gemini in a single re-rank call. The candidate
# profile is identical for every job in a shortlist, so the old one-call-per-job
# loop re-sent the whole profile N times — 137 of this project's 247 Gemini
# calls and ~87% of its input tokens. Batching amortises the profile across the
# batch. 10 is deliberately not "all 20": a smaller batch keeps each job's slice
# of the model's attention meaningful, and one malformed batch only costs a
# retry of 10 jobs, not the whole shortlist.
RERANK_BATCH_SIZE = 10

# ADR-021: the role-intent boost, applied in PYTHON, never by the model
# (Golden Rule 2 — the LLM judges "is this the role they want" as a language
# question and returns role_alignment 0.0-1.0; the arithmetic is ours). A job
# that IS the target role earns the full bonus, an adjacent one earns half, a
# different discipline earns nothing. It is a boost and never a penalty — a
# strong off-target job can still outrank a mediocre on-target one, which is
# what "no hard exclusion" means.
ROLE_BONUS_POINTS = 15

# Verdict thresholds. These live here, not in the prompt, because a verdict is
# a state decision computed from the final (boosted) score — the model's own
# suggested verdict would be blind to the boost we just applied.
APPLY_THRESHOLD = 80
STRETCH_THRESHOLD = 65

# Stage-1 similarity on this corpus is squashed into a narrow band (measured:
# min 0.780, median 0.807, max 0.845 across 114 real matches) — embeddings of
# "any job" vs "any resume" are all mildly alike, so an ABSOLUTE similarity
# floor discriminates nothing. The prescreen below is lexical instead, which is
# what actually separates a "Frontend Developer" from a "Key Account Director"
# in the same pool.
#
# Role vocabulary: maps a target-role phrase to the tokens that identify that
# discipline in a job title. Deliberately small and hand-maintained — this is a
# cheap junk filter, not a taxonomy.
_ROLE_SYNONYMS: dict[str, set[str]] = {
    "frontend": {"frontend", "front", "ui", "react", "angular", "vue", "web", "javascript", "typescript"},
    "backend": {"backend", "back", "api", "server", "python", "java", "node", "golang", "django"},
    "fullstack": {"fullstack", "full", "stack", "web", "software", "developer", "engineer"},
    "mobile": {"mobile", "android", "ios", "flutter", "react", "native", "app"},
    "data": {"data", "analyst", "analytics", "scientist", "ml", "machine", "learning", "ai"},
    "devops": {"devops", "sre", "infrastructure", "cloud", "platform", "reliability"},
    "solutions": {"solutions", "solution", "sales", "presales", "consultant", "support", "customer"},
}

# Generic words that appear in almost every engineering title and therefore
# carry no discriminating signal on their own.
_STOPWORDS = {"a", "an", "the", "and", "or", "of", "for", "senior", "junior", "sr", "jr", "lead", "i", "ii", "iii"}


def _tokens(text: str) -> set[str]:
    return {t for t in re.split(r"[^a-z0-9+#]+", (text or "").lower()) if t and t not in _STOPWORDS}


def _expand_role_tokens(target_roles: list[str]) -> set[str]:
    """The tokens of the roles the user asked for, plus the discipline
    vocabulary those roles imply — so a "frontend developer" target also
    recognises a "React Engineer" posting."""
    out: set[str] = set()
    for role in target_roles:
        role_tokens = _tokens(role)
        out |= role_tokens
        for key, synonyms in _ROLE_SYNONYMS.items():
            # "full stack" tokenises to {full, stack}; match the key against
            # both the raw phrase and its tokens so either form hits.
            if key in role.lower().replace(" ", "") or key in role_tokens:
                out |= synonyms
    return out - _STOPWORDS


def _has_role_signal(job: dict, role_tokens: set[str], skill_tokens: set[str]) -> bool:
    """True if this job is plausibly in the candidate's discipline at all.

    Cheap, deterministic, and generous by design: a job survives on ANY overlap
    between its title and the target-role vocabulary, or failing that, on real
    skill overlap in its description. Only a posting with neither — a "Key
    Account Director" in a frontend developer's pool — is dropped, and dropping
    it is both the cost saving (it was a guaranteed `skip` verdict) and the
    match-quality win (it was polluting the board).
    """
    title_tokens = _tokens(job.get("title"))
    if title_tokens & role_tokens:
        return True
    body_tokens = _tokens((job.get("description") or "")[:1500])
    # Two or more real skills named in the JD body — one is too easy to hit by
    # coincidence ("communication", "excel").
    return len(body_tokens & skill_tokens) >= 2


def _prescreen(jobs: list[dict], target_roles: list[str], skills: list[str]) -> list[dict]:
    """ADR-021 stage 1.5: drop jobs that are obviously not this person's
    discipline BEFORE spending a Gemini call on them.

    Safety valve: if NOTHING survives the screen (a thin or badly-matched job
    pool, or a target role this vocabulary doesn't know), fall back to the
    similarity-ordered shortlist rather than showing the user an empty board — a
    weak match they can reject beats no matches at all. The valve deliberately
    fires only on empty: if the screen kept even one job, that one on-target job
    is a better board than one on-target job padded with nine sales postings.
    """
    if not target_roles:
        return jobs

    role_tokens = _expand_role_tokens(target_roles)
    if not role_tokens:
        return jobs

    skill_tokens = _tokens(" ".join(skills))
    # `jobs` arrives similarity-ordered, and this preserves that order.
    kept = [job for job in jobs if _has_role_signal(job, role_tokens, skill_tokens)]
    if not kept:
        return jobs[:RERANK_BATCH_SIZE]
    return kept


def _final_score(llm_fit: int, role_alignment: float) -> int:
    """Golden Rule 2: the model judged the language ("is this their role?"),
    Python does the arithmetic. Clamped to the 0-100 the `matches.fit_score`
    column and the UI both assume."""
    boost = ROLE_BONUS_POINTS * max(0.0, min(1.0, role_alignment))
    return max(0, min(100, round(llm_fit + boost)))


def _verdict_for(score: int) -> str:
    if score >= APPLY_THRESHOLD:
        return "apply"
    if score >= STRETCH_THRESHOLD:
        return "stretch"
    return "skip"


def _stage1_shortlist(profile_id: str, limit: int) -> list[dict]:
    ranked = supabase.rpc("match_jobs_by_similarity", {"p_profile_id": profile_id, "p_limit": limit}).execute().data
    if not ranked:
        return []
    job_ids = [row["job_id"] for row in ranked]
    jobs = supabase.table("jobs").select("*").in_("id", job_ids).execute().data
    jobs_by_id = {job["id"]: job for job in jobs}
    return [{**jobs_by_id[row["job_id"]], "similarity": row["similarity"]} for row in ranked if row["job_id"] in jobs_by_id]


def rerank_shortlist(profile: dict, limit: int = DEFAULT_RERANK_LIMIT) -> dict:
    """Runs stage 1 (similarity), the ADR-021 lexical prescreen, then stage 2
    (batched LLM re-rank) for the surviving jobs, skipping any (profile, job)
    pair already cached in `matches` — the table's unique constraint makes each
    job ranked once per profile, so re-running this is cheap and safe to call
    repeatedly.

    ADR-021 changes what stage 2 costs and what it knows:
      - jobs outside the candidate's discipline never reach Gemini (`_prescreen`)
      - the survivors are scored RERANK_BATCH_SIZE at a time, not one per call
      - the re-ranker is finally told the user's target_roles, and the
        role-intent boost is applied here, in Python
    """
    profile_id = profile["id"]
    # Stage 1 pulls a wider net than we'll re-rank, because the prescreen is
    # about to discard part of it — pulling exactly `limit` would leave us
    # re-ranking far fewer than `limit` jobs after screening.
    shortlist = _stage1_shortlist(profile_id, limit * 2)
    if not shortlist:
        return {"reranked": 0, "skipped": 0, "screened_out": 0}

    target_roles = profile.get("target_roles") or []
    skills = profile.get("skills") or []
    screened = _prescreen(shortlist, target_roles, skills)
    screened_out = len(shortlist) - len(screened)
    screened = screened[:limit]

    job_ids = [job["id"] for job in screened]
    if not job_ids:
        return {"reranked": 0, "skipped": 0, "screened_out": screened_out}

    already_ranked = (
        supabase.table("matches")
        .select("job_id")
        .eq("profile_id", profile_id)
        .in_("job_id", job_ids)
        .execute()
        .data
    )
    ranked_job_ids = {row["job_id"] for row in already_ranked}
    to_rank = [job for job in screened if job["id"] not in ranked_job_ids]

    reranked = 0
    for i in range(0, len(to_rank), RERANK_BATCH_SIZE):
        batch = to_rank[i : i + RERANK_BATCH_SIZE]
        results = rerank_jobs(profile, batch, target_roles=target_roles, profile_id=profile_id)

        rows = []
        for job, result in zip(batch, results):
            score = _final_score(result.fit_score, result.role_alignment)
            rows.append(
                {
                    "profile_id": profile_id,
                    "job_id": job["id"],
                    "similarity": job["similarity"],
                    "fit_score": score,
                    "strengths": result.strengths,
                    "gaps": result.gaps,
                    "compensators": result.compensators,
                    # Recomputed from the BOOSTED score — the model's own
                    # verdict predates the boost and would contradict it.
                    "verdict": _verdict_for(score),
                    "one_line_reason": result.one_line_reason,
                }
            )
        supabase.table("matches").insert(rows).execute()
        reranked += len(rows)

    return {
        "reranked": reranked,
        "skipped": len(screened) - reranked,
        "screened_out": screened_out,
    }


def get_ranked_matches(profile: dict, limit: int = 50) -> list[dict]:
    """Reads cached stage-2 results (Brick 5's persisted output) joined with
    their job rows, ordered best-fit first. Call rerank_shortlist() first
    to populate/refresh the cache."""
    matches = (
        supabase.table("matches")
        .select("*")
        .eq("profile_id", profile["id"])
        .order("fit_score", desc=True)
        .limit(limit)
        .execute()
        .data
    )
    if not matches:
        return []

    job_ids = [m["job_id"] for m in matches]
    jobs = supabase.table("jobs").select("*").in_("id", job_ids).execute().data
    jobs_by_id = {job["id"]: job for job in jobs}

    results = []
    for m in matches:
        job = jobs_by_id.get(m["job_id"])
        if job is None:
            continue
        results.append(
            {
                **job,
                "similarity": m["similarity"],
                "fit_score": m["fit_score"],
                "strengths": m["strengths"],
                "gaps": m["gaps"],
                "compensators": m["compensators"],
                "verdict": m["verdict"],
                "one_line_reason": m["one_line_reason"],
            }
        )
    return results
