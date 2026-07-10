from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    gemini_api_key: str
    gemini_model: str = "gemini-2.5-flash"
    gemini_embed_model: str = "gemini-embedding-001"

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
    environment: str = "development"

    # Brick 9: shared secret the Render cron job sends in X-Pipeline-Secret
    # to trigger the all-users batch run (POST /pipeline/run) — distinct
    # from the per-user POST /pipeline/run-mine, which uses the caller's
    # own Supabase session instead.
    pipeline_secret: str = ""

    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
