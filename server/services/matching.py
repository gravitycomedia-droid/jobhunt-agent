import re

from db.supabase_client import supabase
from services.llm import rerank_jobs
from services.referrals import effective_match_limit

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

# ADR-054: location and salary preference boosts, same shape as the role
# boost above and for the same reason: both are STRUCTURED facts (a city
# name, a number), not a language judgment, so they're computed here in
# Python and never sent to the LLM. Also boost-only, deliberately — job
# `location` text is inconsistent ("Hyderabad, Telangana" vs "Hyderabad" vs
# blank) and most postings in this pool list no salary at all, so excluding
# on either would silently wipe out otherwise-strong matches (the same
# reasoning that keeps the role prescreen a safety-valved filter rather than
# a hard one). Smaller than the role bonus — role is what the candidate SAID
# they want; location/salary are secondary preferences on top of that.
LOCATION_BONUS_POINTS = 10
SALARY_BONUS_POINTS = 10

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

# ADR-054: same hand-maintained-synonym pattern as _ROLE_SYNONYMS, for the
# city-name variants this job pool actually contains (Adzuna/JSearch/Apify
# each spell these differently). Deliberately small — this is a preference
# boost, not a gazetteer.
_LOCATION_SYNONYMS: dict[str, set[str]] = {
    "bangalore": {"bangalore", "bengaluru"},
    "bombay": {"bombay", "mumbai"},
    "gurgaon": {"gurgaon", "gurugram"},
    "delhi": {"delhi", "ncr"},
    "hyderabad": {"hyderabad", "secunderabad"},
    "chennai": {"chennai", "madras"},
    "kolkata": {"kolkata", "calcutta"},
    "pune": {"pune"},
}

# "Remote" always satisfies any location preference — it's compatible with
# every city the candidate could have listed, so it earns the bonus even if
# the candidate never typed the word "remote" themselves.
_REMOTE_TOKENS = {"remote", "wfh", "workfromhome", "anywhere"}


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


def _expand_location_tokens(target_locations: list[str]) -> set[str]:
    """Mirrors _expand_role_tokens: the candidate's preferred-city tokens,
    plus whatever city-name variants that city is known to have."""
    out: set[str] = set()
    for loc in target_locations:
        loc_tokens = _tokens(loc)
        out |= loc_tokens
        for key, synonyms in _LOCATION_SYNONYMS.items():
            if key in loc.lower().replace(" ", "") or key in loc_tokens:
                out |= synonyms
    return out


def _location_bonus(job: dict, location_tokens: set[str]) -> float:
    """0.0-1.0 boost input for ADR-054: 1.0 when the job's location overlaps
    a preferred city (or the job is remote), 0.0 otherwise — including when
    the job lists no location at all, or the candidate stated no preference.
    Never a penalty: this only ever adds, and only when there's a positive
    signal to add for."""
    if not location_tokens:
        return 0.0
    job_tokens = _tokens(job.get("location"))
    if not job_tokens:
        return 0.0
    if job_tokens & _REMOTE_TOKENS:
        return 1.0
    return 1.0 if job_tokens & location_tokens else 0.0


def _salary_bonus(job: dict, min_salary: float | None) -> float:
    """0.0-1.0 boost input for ADR-054: full boost when the job's own listed
    ceiling clears the candidate's stated floor, half when it's close (within
    15%), none when it falls short OR the job lists no salary at all — most
    postings in this pool don't, and treating "unknown" as "below the floor"
    would punish the majority of otherwise-good jobs."""
    if not min_salary:
        return 0.0
    job_ceiling = job.get("salary_max") or job.get("salary_min")
    if not job_ceiling:
        return 0.0
    if job_ceiling >= min_salary:
        return 1.0
    if job_ceiling >= min_salary * 0.85:
        return 0.5
    return 0.0


# ADR-054: the message appended to `matches.gaps` when a job scores as a
# genuine "apply" but the profile has nothing services/section_tailor.py can
# build a tailored resume from — a fixed string so a later rescore can find
# and de-duplicate its own prior insert (see rescore_cached_matches).
_PROFILE_GAP_MESSAGE = "Add work experience or project details to your profile — this job scores well but there's nothing yet to build a tailored resume from"


def _has_tailorable_content(profile: dict) -> bool:
    """True if the profile has real bullets a tailored resume could be built
    from: at least one experience bullet, or at least one project with a
    description. A profile that fails this can still be an honest, strong
    fit (the LLM's fit_score isn't wrong) — but POST /tailor/{job_id} has
    nothing to select (services/section_tailor.py) and a bare "apply" verdict
    promises the candidate something the agent can't yet deliver."""
    for exp in profile.get("experience") or []:
        if exp.get("bullets"):
            return True
    for proj in profile.get("projects") or []:
        if (proj.get("description") or "").strip():
            return True
    return False


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


def _final_score(
    llm_fit: int, role_alignment: float, location_bonus: float = 0.0, salary_bonus: float = 0.0
) -> int:
    """Golden Rule 2: the model judged the language ("is this their role?"),
    Python does the arithmetic — role_alignment from the LLM, location_bonus
    and salary_bonus (ADR-054) computed purely from structured job/profile
    fields and never seen by the model at all. Clamped to the 0-100
    `matches.fit_score` column and the UI both assume."""
    boost = (
        ROLE_BONUS_POINTS * max(0.0, min(1.0, role_alignment))
        + LOCATION_BONUS_POINTS * max(0.0, min(1.0, location_bonus))
        + SALARY_BONUS_POINTS * max(0.0, min(1.0, salary_bonus))
    )
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
    # Plan 21, constraint 1: the quota is a COST control, so it clamps here —
    # before any LLM call is planned — not in the response serializer. A caller
    # hitting POST /matches/rerank?limit=50 on a 3-limit profile gets 3 jobs
    # re-ranked, because `limit` is dead from this line onward.
    limit = min(limit, effective_match_limit(profile))
    if limit <= 0:
        return {"reranked": 0, "skipped": 0, "screened_out": 0}
    # Stage 1 pulls a wider net than we'll re-rank, because the prescreen is
    # about to discard part of it — pulling exactly `limit` would leave us
    # re-ranking far fewer than `limit` jobs after screening.
    shortlist = _stage1_shortlist(profile_id, limit * 2)
    if not shortlist:
        return {"reranked": 0, "skipped": 0, "screened_out": 0}

    target_roles = profile.get("target_roles") or []
    skills = profile.get("skills") or []
    # ADR-054: location/salary tokens + profile completeness are the same for
    # every job in this call, so compute them once rather than per job.
    location_tokens = _expand_location_tokens(profile.get("target_locations") or [])
    min_salary = profile.get("min_salary")
    has_content = _has_tailorable_content(profile)
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
            location_bonus = _location_bonus(job, location_tokens)
            salary_bonus = _salary_bonus(job, min_salary)
            score = _final_score(result.fit_score, result.role_alignment, location_bonus, salary_bonus)
            verdict = _verdict_for(score)
            gaps = list(result.gaps)
            # ADR-054: an honestly-computed "apply" is still a dead end if
            # there's nothing in the profile to tailor into a resume — don't
            # let the board promise more than /tailor can deliver.
            if verdict == "apply" and not has_content:
                verdict = "stretch"
                gaps = gaps + [_PROFILE_GAP_MESSAGE]
            rows.append(
                {
                    "profile_id": profile_id,
                    "job_id": job["id"],
                    "similarity": job["similarity"],
                    "fit_score": score,
                    "raw_fit_score": result.fit_score,
                    "role_alignment": result.role_alignment,
                    "strengths": result.strengths,
                    "gaps": gaps,
                    "compensators": result.compensators,
                    # Recomputed from the BOOSTED score — the model's own
                    # verdict predates the boost and would contradict it.
                    "verdict": verdict,
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


def rescore_cached_matches(profile: dict) -> int:
    """ADR-054: recompute fit_score/verdict for every cached match of this
    profile from the CURRENT target_locations/min_salary — pure Python
    arithmetic, no LLM call, no token cost. Called synchronously right after
    the location/salary preference PATCH endpoints save, so the Matches
    board reorders the moment the user changes a preference instead of
    waiting on the next full re-rank.

    Only location/salary can be refreshed this way. role_alignment was the
    LLM's judgment of "is this posting the role they want" against whatever
    target_roles were current AT SCORE TIME — re-judging that for a changed
    target_roles list is a language call (Golden Rule 2), so a role-target
    change still needs a real rerank_shortlist() run.

    Rows scored before ADR-054 (raw_fit_score is null) are skipped rather
    than guessed at, and simply get the new boost on their next real re-rank.
    Returns the number of rows updated.
    """
    profile_id = profile["id"]
    rows = (
        supabase.table("matches")
        .select("id, job_id, raw_fit_score, role_alignment, gaps")
        .eq("profile_id", profile_id)
        .not_.is_("raw_fit_score", "null")
        .execute()
        .data
    )
    if not rows:
        return 0

    job_ids = [r["job_id"] for r in rows]
    jobs = (
        supabase.table("jobs")
        .select("id, location, salary_min, salary_max")
        .in_("id", job_ids)
        .execute()
        .data
    )
    jobs_by_id = {j["id"]: j for j in jobs}

    location_tokens = _expand_location_tokens(profile.get("target_locations") or [])
    min_salary = profile.get("min_salary")
    has_content = _has_tailorable_content(profile)

    updates = []
    for row in rows:
        job = jobs_by_id.get(row["job_id"])
        if job is None:  # job retired/removed since this match was cached
            continue
        location_bonus = _location_bonus(job, location_tokens)
        salary_bonus = _salary_bonus(job, min_salary)
        score = _final_score(row["raw_fit_score"], row["role_alignment"] or 0.0, location_bonus, salary_bonus)
        verdict = _verdict_for(score)
        gaps = [g for g in (row.get("gaps") or []) if g != _PROFILE_GAP_MESSAGE]
        if verdict == "apply" and not has_content:
            verdict = "stretch"
            gaps = gaps + [_PROFILE_GAP_MESSAGE]
        updates.append({"id": row["id"], "fit_score": score, "verdict": verdict, "gaps": gaps})

    if updates:
        supabase.table("matches").upsert(updates).execute()
    return len(updates)


def get_ranked_matches(profile: dict, limit: int = 50) -> list[dict]:
    """Reads cached stage-2 results (Brick 5's persisted output) joined with
    their job rows, ordered best-fit first. Call rerank_shortlist() first
    to populate/refresh the cache.

    Plan 21: clamped to effective_match_limit here as well as in
    rerank_shortlist, and the second clamp is not redundant. rerank_shortlist
    caps LLM calls PER RUN, so a 3-limit profile legitimately accumulates more
    than 3 cached `matches` rows across daily pipeline runs as the job pool
    turns over. Without this clamp the gate would quietly widen a little every
    day. Best-fit-first ordering means the user keeps the best 3 they've ever
    been matched to, not the oldest 3."""
    limit = min(limit, effective_match_limit(profile))
    if limit <= 0:
        return []
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
                # Frontend rebuild v2 §4.5: the Matches "NEW" badge is derived
                # client-side from how recently this row was (re)ranked.
                "ranked_at": m.get("ranked_at"),
            }
        )
    return results


# How many teaser rows a gated profile sees below their unlocked matches. Enough
# to make the locked value legible, few enough that the screen doesn't become a
# wall of blur.
LOCKED_TEASER_CAP = 10


def get_locked_matches(profile: dict, unlocked: list[dict], cap: int = LOCKED_TEASER_CAP) -> list[dict]:
    """Stage-1-only teasers for jobs past this profile's quota.

    These rows deliberately carry NO stage-2 output — no fit_score, no verdict,
    no reasoning, no gaps — because none was ever computed for them. That's the
    honest consequence of constraint 1: the LLM never saw these jobs, so there
    is nothing to blur out. The app renders the blur; the server simply has
    nothing more to send. `similarity_pct` is stage-1 cosine distance, which is
    free (it's already in the pgvector query) and gives the teaser something
    truthful to show.

    Returns [] for an ungated profile — if nothing is locked, there is no
    upsell to render."""
    if not has_locked_matches(profile):
        return []

    limit = effective_match_limit(profile)
    unlocked_ids = {m["id"] for m in unlocked}
    # Pull past the limit plus the cap so that filtering out the already-shown
    # rows still leaves a full teaser list.
    candidates = _stage1_shortlist(profile["id"], limit + cap + 5)

    teasers = []
    for job in candidates:
        if job["id"] in unlocked_ids:
            continue
        teasers.append(
            {
                "id": job["id"],
                "title": job.get("title"),
                "company": job.get("company"),
                "similarity_pct": round((job.get("similarity") or 0.0) * 100),
            }
        )
        if len(teasers) >= cap:
            break
    return teasers


def has_locked_matches(profile: dict) -> bool:
    """Whether this profile is gated at all. A 'pro' profile's effective limit
    is DEFAULT_RERANK_LIMIT, which is also everything rerank_shortlist would
    ever produce, so nothing is withheld and no teaser should be rendered."""
    return effective_match_limit(profile) < DEFAULT_RERANK_LIMIT
