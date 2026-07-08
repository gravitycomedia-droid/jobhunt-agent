from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    gemini_api_key: str
    gemini_model: str = "gemini-2.0-flash"
    gemini_embed_model: str = "text-embedding-004"

    supabase_url: str
    supabase_service_key: str
    supabase_anon_key: str = ""

    adzuna_app_id: str = ""
    adzuna_app_key: str = ""
    adzuna_country: str = "in"

    rapidapi_key: str = ""

    fcm_service_account_path: str = "./firebase-service-account.json"

    daily_pipeline_hour: int = 7
    target_roles: str = ""
    target_locations: str = ""
    environment: str = "development"

    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
