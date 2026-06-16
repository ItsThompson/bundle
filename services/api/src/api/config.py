"""Environment-based application configuration using pydantic-settings."""

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

KNOWN_INSECURE_SECRETS = frozenset({"change-me-in-production", "secret", "dev-secret"})


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Database
    database_url: str = "postgresql://bundle:bundle_dev@localhost:5433/bundle"

    # Auth - NO DEFAULT: forces explicit setting
    jwt_secret: str

    jwt_access_ttl_minutes: int = 15
    jwt_refresh_ttl_days: int = 7
    bcrypt_cost: int = 12

    # Storage
    artifacts_path: str = "/opt/bundle/artifacts"

    # Connection pool
    db_pool_min_size: int = 2
    db_pool_max_size: int = 10

    # LLM (NVIDIA NIM)
    nvidia_api_key: str | None = None
    nim_llm_model: str = "nvidia/nemotron-nano-12b-v2-vl"
    nim_embedding_model: str = "nvidia/nv-embedqa-e5-v5"

    # Processing
    max_processing_attempts: int = 3
    processing_poll_interval_seconds: int = 5

    # Observability
    sentry_dsn: str | None = None
    log_level: str = "INFO"

    @model_validator(mode="after")
    def validate_secrets(self) -> "Settings":
        """Reject insecure or default secrets at startup."""
        if self.jwt_secret.lower() in KNOWN_INSECURE_SECRETS:
            raise ValueError(
                "JWT_SECRET is set to a known insecure value. "
                "Set a unique secret of 32+ characters."
            )
        if len(self.jwt_secret) < 32:
            raise ValueError(
                f"JWT_SECRET must be at least 32 characters (got {len(self.jwt_secret)}). "
                f'Generate one with: python -c "import secrets; print(secrets.token_urlsafe(48))"'
            )
        return self


def get_settings() -> Settings:
    """Load and return the application settings."""
    return Settings()
