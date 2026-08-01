from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    gemini_api_key: str
    gemini_model: str = "gemini-2.5-flash"
    gemini_embed_model: str = "gemini-embedding-001"
    # JD-paste resume builder only (routers/jobs.py's `from-jd` flow,
    # services/llm.py's tailor_resume/extract_job_from_text `model` param)
    # — a standalone convenience tool outside the core matching/tailoring
    # pipeline, so it defaults to the cheapest current Gemini text tier
    # instead of gemini_model. See DECISIONS.md ADR-017.
    # 2026-07-11: was gemini-2.5-flash-lite, which Google now 404s for new
    # API keys ("no longer available to new users"); gemini-3.1-flash-lite
    # verified working with this project's key.
    gemini_model_lite: str = "gemini-3.1-flash-lite"

    # Phase 14 / ADR-023: DeepSeek as the second provider. Its API is
    # OpenAI-compatible, so services/llm.py drives it with the `openai` SDK
    # pointed at this base_url rather than a bespoke HTTP client.
    #
    # Model names are explicit and current: the `deepseek-chat` /
    # `deepseek-reasoner` aliases (non-thinking / thinking modes of
    # deepseek-v4-flash) are deprecated 2026-07-24, so this project never
    # names them. Empty api_key is a supported state — every DeepSeek-routed
    # task falls back to Gemini when the key is missing (see
    # services/llm.py::_provider_for), so the server still boots and works
    # with a Gemini key alone.
    deepseek_api_key: str = ""
    deepseek_model: str = "deepseek-v4-flash"
    deepseek_base_url: str = "https://api.deepseek.com"

    # ADR-023: `tailor` is the one guardrail-adjacent generation task, so it
    # does NOT follow the other tasks to DeepSeek by default. Flipping this to
    # "deepseek" is a deliberate opt-in, gated on measuring guardrail-pass
    # rates against the Gemini baseline first (see DECISIONS.md ADR-023).
    tailor_provider: str = "gemini"

    # --- Phase 4 (frontend rebuild v2): entitlements, chat, cosmetic wallet ---
    # The ONLY real entitlement seam. services/entitlements.py::require_tier
    # reads a profile's subscription_tier, but falls back to THIS when a row
    # predates migration 022 — so flipping default_tier="free" makes every
    # pro-gated endpoint return 402 across the board (the Phase 4 acceptance
    # test does exactly this). "pro" keeps the whole beta unrestricted.
    default_tier: str = "pro"

    # Which provider services/chat.py routes the grounded assistant through.
    # "deepseek" per the plan (cheap, thinking disabled per ADR-023); an absent
    # DEEPSEEK_API_KEY still falls back to Gemini via llm.py::_provider_for, so
    # chat works on a Gemini-only deploy.
    chat_provider: str = "deepseek"

    # R-C: when a new user has no llm_calls history to derive a mean per-action
    # cost from, /wallet computes actions_remaining against this constant and
    # marks "estimated": true inside data. ~₹1/action → ~200 actions on a full
    # ₹200 wallet. Once real rows exist the derived mean takes over. Never a
    # hardcoded action COUNT — always balance ÷ a per-action cost.
    wallet_fallback_cost_paise: int = 100

    supabase_url: str
    supabase_service_key: str
    supabase_anon_key: str = ""

    adzuna_app_id: str = ""
    adzuna_app_key: str = ""
    adzuna_country: str = "in"

    rapidapi_key: str = ""

    fcm_service_account_path: str = "./firebase-service-account.json"

    # Phase 4: real follow-up email sending. Optional so the app still
    # boots without it (services/email.py raises a clear error on send
    # attempts, rather than the whole server failing to start) — same
    # posture as adzuna/rapidapi above.
    resend_api_key: str = ""
    resend_from_email: str = "onboarding@resend.dev"

    # Postings older than this are skipped at ingestion and purged from the pool.
    # Originally 60 (Phase 1D), to catch a board returning years-old rows (the
    # "2591d ago" bug). Tightened to 10 on request: an internship posted three
    # weeks ago is usually already filled, and a small fast-moving pool beats a
    # large stale one. This is the single most aggressive filter in the system —
    # it drops more postings than the role and seniority gates combined.
    max_job_age_days: int = 10

    daily_pipeline_hour: int = 7
    target_roles: str = ""
    target_locations: str = ""
    # Job source expansion Phase 1: Adzuna's free tier has far more headroom
    # than JSearch's 200/month RapidAPI cap, so Adzuna can query more Indian
    # cities without touching JSearch's shared target_locations. Empty →
    # falls back to target_locations (see services/job_sources.py).
    adzuna_locations: str = ""
    environment: str = "development"

    # Job source expansion Phase 2/3: Greenhouse/Lever public job-board APIs
    # — free, unauthenticated, no key to manage. Both take comma-separated
    # "slug" or "slug:Display Name" entries. Greenhouse postings carry their
    # own `company_name`, so the name half is optional there and only worth
    # setting when the registered legal name reads badly on a job card (e.g.
    # razorpaysoftwareprivatelimited returns "Razorpay Software Private
    # Limited"). Lever postings carry no company name at all, so its entries
    # always need one.
    greenhouse_boards: str = "postman,groww,razorpaysoftwareprivatelimited:Razorpay,phonepe"
    lever_companies: str = "cred:CRED,meesho:Meesho,zeta:Zeta,freshworks:Freshworks"

    # Scraping source expansion (ADR-003, amended 2026-07-13): LinkedIn/Indeed/
    # Naukri via no-login Apify actors. Golden rule 1 holds — the token is read
    # here and used server-side only; it never reaches the Flutter app.
    #
    # The token defaults to "" rather than being a required field on purpose,
    # even though the plan said "no defaults for the token". A required field
    # makes Settings() raise at import time, so a missing/rotated token would
    # take down the whole server — including the Gemini/Adzuna paths that have
    # nothing to do with Apify. That directly contradicts the plan's own
    # acceptance criterion ("killing the Apify token doesn't crash the daily
    # pipeline — it logs and the rest continues"). Empty token → the Apify
    # fetchers no-op and log, exactly like deepseek_api_key above.
    apify_api_token: str = ""

    # Actor IDs are config, not code (format: "owner~actor-name"). Apify actors
    # get deprecated/replaced often, so swapping one is an env-var change and a
    # redeploy, not a code edit. Empty → that source is skipped.
    apify_linkedin_actor_id: str = ""
    apify_indeed_actor_id: str = ""
    apify_naukri_actor_id: str = ""

    # --- Per-source cadence + caps ------------------------------------------
    # Apify bills per RESULT, not per call, and dedup runs *after* you've paid —
    # so re-scraping the same listings daily means re-buying rows you already
    # own. The three sources cost wildly different amounts per job (measured live
    # on the free tier, 2026-07-13):
    #
    #     LinkedIn  $0.001/job   ← cheap: can run often
    #     Indeed    $0.006/job   ← 6x LinkedIn
    #     Naukri    $0.0095/job  ← priciest (fetchDetails), but best Indian
    #                              coverage + pre-parsed INR salaries
    #
    # So cadence and cap are per-source, not global: run the cheap source often
    # and the expensive one weekly, instead of compromising on one shared number.
    # Weekdays are mon..sun; empty string disables that source (kill switch).
    #
    # Budget math for the defaults below, at 2 roles × 3 locations = 6 calls/run:
    #     LinkedIn  mon,wed,fri × 6 × 10 × $0.001  ≈ $0.78/mo
    #     Indeed    mon,thu     × 6 ×  5 × $0.006  ≈ $1.57/mo
    #     Naukri    mon         × 6 ×  8 × $0.0095 ≈ $1.98/mo
    #                                        total ≈ $4.33/mo
    # That fits Apify's FREE plan, which HARD-CAPS usage at $5/month and starts
    # returning 402s the moment you cross it. Raising any of these means paying
    # for an Apify plan, not just editing a number.
    apify_linkedin_weekdays: str = "mon,wed,fri"
    apify_indeed_weekdays: str = "mon,thu"
    apify_naukri_weekdays: str = "mon"

    apify_linkedin_max_results: int = 10  # actor 400s below 10 — this is its floor
    apify_indeed_max_results: int = 5
    apify_naukri_max_results: int = 8

    # --- Internship / fresher targeting -------------------------------------
    # fetch_adzuna() surfaces internships by running a SECOND query per role
    # ("<role>" and "<role> intern"), because Adzuna India has no internship
    # filter. Doing that here would double the Apify call count and the bill
    # (~$4.33/mo → ~$8.70/mo, over the free plan's $5 hard cap).
    #
    # So the scraped sources filter at the source instead — same call count, no
    # extra cost. This WIDENS what we keep rather than narrowing it: internships
    # and fresher full-time roles both come back, and only senior postings (which
    # would never match a fresher's resume) are dropped.
    #
    # Query-text suffix per source. Set to "" to search the bare role.
    #
    # NOT LinkedIn's f_E experience-level URL param, which would have been the
    # elegant answer: tested live 2026-07-13, the curious_coder actor IGNORES it.
    # Even f_E=1 ("internships only") still returned "Senior Full-Stack Software
    # Engineer" at seniority=Mid-Senior. It would have looked right in the code
    # and quietly done nothing. The query text is the only lever that actually
    # moves this actor's results.
    apify_linkedin_query_suffix: str = "intern"
    apify_indeed_query_suffix: str = "intern"

    # Naukri DOES filter natively on years of experience (verified: returns
    # seniority=fresher/junior rows). It's an overlap filter — a "1-4 yrs" job
    # matches a 0..2 window — which is what we want, since those are still real
    # fresher postings.
    apify_naukri_max_experience_years: int = 2

    # Apify's free plan allows 16GB of actor memory in flight, and each run
    # reserves ~4GB. Firing all 6+ queries at once therefore asks for ~24-48GB
    # and the overflow is rejected with HTTP 402 — which reads like "out of
    # credit" but is really "out of memory" (verified live: 402s at $0.84 of a
    # $5 budget). Cap concurrency so we stay under the ceiling.
    #
    # This also limits the blast radius of an abandoned run: our client-side
    # timeout does NOT abort the actor server-side, so a run we give up on keeps
    # executing and billing. Fewer in flight = fewer we can strand.
    apify_max_concurrent_runs: int = 3

    # Naukri's search page only carries a ~90-char truncated description stub.
    # fetchDetails pulls the full ~2000-char JD (verified live: 90 → 2219 chars)
    # at a higher per-job price. Worth it: description text is what gets embedded
    # and re-ranked, so the stub would systematically under-score Naukri jobs.
    apify_naukri_fetch_details: bool = True

    # --- India source expansion (plan 15) -----------------------------------
    # New scraped sources beyond ADR-003's original three. These stay INERT
    # until two independent gates are both satisfied: (1) enable_india_sources
    # flipped true, and (2) ADR-003 v2 signed off (see DECISIONS.md). The caps
    # are settings-driven from day one so turning a source on is an env change,
    # never a code edit — same posture as the existing Apify knobs above.
    #
    # enable_india_sources is the master kill switch for BOTH Internshala and
    # Unstop. Default false: nothing new scrapes on a fresh deploy, so the ADR
    # sign-off gate can't be bypassed by simply shipping the code.
    enable_india_sources: bool = False

    # --- Internshala (ADR-003 v4, 2026-07-27: free HTML, was paid Apify) ------
    # The Apify actor knobs (apify_internshala_actor_id / _weekdays /
    # internshala_max_results) are GONE, not deprecated: recon on 2026-07-27
    # showed the category listing pages are fully server-rendered, so the actor
    # was paying per result for HTML that a bare GET already returns. Being free
    # is what lets this run daily at full page depth instead of tue/fri × 10.
    #
    # Slugs default to the ~12 technical categories confirmed from Internshala's
    # own nav. This list is the FIRST IT filter (it excludes the marketing/
    # finance/HR categories wholesale); the category classifier is the second,
    # because non-technical postings do leak onto technical category pages.
    internshala_slugs: str = (
        "computer-science,web-development,mobile-app-development,programming,"
        "software-development,software-testing,cloud-computing,cyber-security,"
        "network-engineering,blockchain-development,data-science,machine-learning"
    )
    # 50 cards/page, across 12 slugs × 2 stems.
    #
    # Raised 1 → 2 on 2026-08-01 after measuring, having initially assumed page 2
    # would be mostly stale listings the freshness gate discards. It isn't: the
    # marginal page yielded +238 relevant postings for +435 fetched (55%
    # survival, versus 48% on page 1), taking Internshala from 432 to 670
    # relevant/day. The cost is 12 extra HTTP requests and ~6s of politeness
    # delay — nothing.
    #
    # Don't raise it further without measuring again. Survival per page will fall
    # off eventually; the point at which it does is an empirical question, not a
    # thing to guess at, which is exactly the mistake the 1 → 2 change corrected.
    internshala_pages_per_slug: int = 2
    # The fresher-jobs catalogue (full-time entry roles) alongside internships.
    # Free, so unlike the Apify path there's no per-result reason to skip it.
    internshala_include_fresher_jobs: bool = True

    # --- Instahyre (ADR-003 v4) ---------------------------------------------
    # Public JSON API, no auth (confirmed live 2026-07-27). Cap is a runaway
    # guard, not a target: the full-time catalogue is ~7,900 rows but skews
    # heavily senior, so the entry-level gate — not this number — is what
    # actually decides the yield.
    instahyre_max_results: int = 300

    # Pass 2 of technical sub-categorization (services/job_tech_category.py):
    # ONE batched DeepSeek call per ingestion run for the rows keyword matching
    # couldn't place. Off → those rows fall back to 'other_it' and ingestion
    # makes no LLM calls at all. On by default because the residue is small and
    # the call is batched, but it's a kill switch worth having: if a source ever
    # floods the pool with untitled rows, this is the line item that would grow.
    enable_tech_category_llm: bool = True

    # --- Unstop volume (ADR-003 v3, 2026-07-26) -----------------------------
    # Was 20, and searched once per target_role — which capped the pool at the
    # three fullstack/frontend/cloud keywords and landed ~20 rows/day. Measured
    # live 2026-07-26: the open catalogue is 836 internships + 1,186 jobs, of
    # which 1,443 are within max_job_age_days and ~131/day are genuinely new.
    #
    # This is a cap PER (opportunity type × search term), not a grand total, so
    # 1000 means "don't runaway-crawl if Unstop's catalogue 10x's overnight"
    # rather than a number we expect to hit. The real volume control is the
    # freshness early-stop in _crawl_unstop(), which ends the crawl once results
    # go older than max_job_age_days — typically ~3 requests/day in steady state.
    unstop_max_results: int = 1000

    # Which Unstop catalogues to crawl. "internships,jobs" are the only two
    # values that carry hiring listings — probed live 2026-07-26: "freshers" and
    # "entry-level" are NOT opportunity types (they return total=0), they're
    # filters inside `jobs`, so the fresher cut is job_filter.py's entry-level
    # gate rather than a query param. "competitions"/"hiring-challenges" respond
    # but are contests, not postings, and are deliberately excluded.
    unstop_opportunity_types: str = "internships,jobs"

    # Comma-separated keyword searches. EMPTY (the default) = one unfiltered
    # crawl of the whole catalogue, which is what the broad pool wants and is
    # also fewer requests than one pass per keyword. Set this to narrow the
    # fetch back to specific roles without touching code.
    unstop_search_terms: str = ""

    # --- per-source relevance gates (ADR-003 v3) ----------------------------
    # Format: "source:gate+gate, source2:none". Gates are role / entry / location
    # (services/job_filter.py). A source NOT named here gets all three, so every
    # existing source is unaffected by this setting existing.
    #
    # Default "unstop:entry" is the measured sweet spot for the broad pool. Live
    # counts over Unstop's full open catalogue, 2026-07-26:
    #
    #     gates applied        day-one backfill   new per day
    #     all three (old)              441             55
    #     entry only  (this)           791             87   ← chosen
    #     location only                711             76
    #     none                       1,443            131
    #
    # Entry-level stays ON because a senior sales role is dead weight in a
    # fresher's pool no matter how the app filters it. The role and location cuts
    # move to the APP as user-facing filters (category chips, city filter), which
    # is reversible per-user — an ingestion gate is not, since a posting we never
    # stored can't be un-filtered later.
    # Amended 2026-08-01 (ADR-003 v4): internshala and instahyre join unstop on
    # entry-only. They were on the strict default and it was starving them —
    # measured live, Internshala stored 85/day of 540 fresh postings and
    # Instahyre 2 of 300, against Unstop's ~174. The pool was 91% Unstop not
    # because Unstop fetches more but because it was the only source allowed to
    # keep what it found.
    #
    # The cut being removed is mostly `role`: it admits only fullstack/frontend/
    # cloud, so ai_ml, data_science, mobile, backend, cybersecurity and
    # qa_testing postings were discarded at ingestion — exactly the specialisms
    # migration 028's tech_category exists to let users browse. Same reasoning
    # v3 used for Unstop: role and city are reversible per-user in the app, an
    # ingestion gate is not, and a posting we never stored can't be un-filtered.
    ingestion_gate_overrides: str = "unstop:entry,internshala:entry,instahyre:entry"

    # --- Ingestion health alerting (plan 15, Phase F) -----------------------
    # Ops mailbox for "a source stopped returning data" alerts — NOT a
    # user-facing address. Empty → health is still logged to
    # source_ingestion_log, but no email is sent (the alert no-ops, same
    # graceful-degrade posture as resend_api_key). Golden rule 1: server-side
    # only, lives in Secret Manager / .env.
    ops_alert_email: str = ""

    # Brick 9: shared secret the Render cron job sends in X-Pipeline-Secret
    # to trigger the all-users batch run (POST /pipeline/run) — distinct
    # from the per-user POST /pipeline/run-mine, which uses the caller's
    # own Supabase session instead.
    pipeline_secret: str = ""

    # Cloud Run migration: Cloud Scheduler authenticates the same route with
    # a Google-signed OIDC bearer token instead of a shared secret — no
    # value to leak from job config. Both are accepted at once (see
    # services/auth.py::verify_pipeline_cron) so Render's cron keeps working
    # until it's decommissioned.
    pipeline_oidc_service_account: str = ""
    pipeline_oidc_audience: str = ""

    # Phase 14 / ADR-027: per-profile rate limits on the LLM-backed endpoints,
    # as "<max requests> per <window seconds>". Config, not hardcoded, so the
    # beta's real usage can tune them without a redeploy. The cron path (POST
    # /pipeline/run) is deliberately exempt — it's the one legitimate
    # high-volume caller. See services/rate_limit.py.
    rate_limit_window_seconds: int = 300  # 5 minutes
    rate_limit_rerank: int = 5  # POST /matches/rerank
    rate_limit_tailor: int = 5  # POST /tailor/{job_id}
    rate_limit_pipeline_mine: int = 5  # POST /pipeline/run-mine
    rate_limit_resume_parse: int = 3  # POST /resume/parse
    rate_limit_manual_parse: int = 5  # POST /jobs/manual/parse & /jobs/from-jd/parse
    rate_limit_jobs_refresh: int = 10  # POST /jobs/refresh
    # Phase 4: the grounded chat is an LLM call, so it gets the same coarse guard.
    rate_limit_chat: int = 10  # POST /chat
    # Phase 4 security fixes: LLM/URL-fetch endpoints that were previously
    # unthrottled. /forms/parse fetches a remote URL AND calls the vision model;
    # /forms/fill and /applications/{id}/followup are both LLM generations;
    # /stats/skill-growth fans out to the LLM for course suggestions.
    rate_limit_forms_parse: int = 5  # POST /forms/parse
    rate_limit_forms_fill: int = 5  # POST /forms/fill
    rate_limit_followup: int = 5  # POST /applications/{id}/followup
    rate_limit_skill_growth: int = 10  # GET /stats/skill-growth

    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
