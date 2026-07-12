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

    # Phase 1D: postings older than this are skipped at ingestion — a job
    # board occasionally returns years-old rows ("2591d ago" bug), which
    # are useless to rank and pollute the shortlist.
    max_job_age_days: int = 60

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

    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
