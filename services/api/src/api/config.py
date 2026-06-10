"""Environment-based application configuration using pydantic-settings."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Database
    database_url: str = "postgresql://bundle:bundle_dev@localhost:5432/bundle"

    # Auth
    jwt_secret: str = "change-me-in-production"
    jwt_access_ttl_minutes: int = 15
    jwt_refresh_ttl_days: int = 7
    bcrypt_cost: int = 12

    # Storage
    artifacts_path: str = "/opt/bundle/artifacts"

    # Connection pool
    db_pool_min_size: int = 2
    db_pool_max_size: int = 10

    # LLM
    anthropic_api_key: str | None = None
    openai_api_key: str | None = None
    llm_provider: str = "anthropic"
    embedding_provider: str = "openai"

    # Processing
    max_processing_attempts: int = 3
    processing_poll_interval_seconds: int = 5

    # Observability
    sentry_dsn: str | None = None
    log_level: str = "INFO"


def get_settings() -> Settings:
    """Load and return the application settings."""
    return Settings()
