"""Tests for api.config module."""

import pytest
from api.config import Settings


class TestSettings:
    """Test pydantic-settings configuration loading."""

    def test_default_values(self) -> None:
        """Settings should have sensible defaults when no env vars are set."""
        settings = Settings(
            _env_file=None,
            database_url="postgresql://test:test@localhost:5432/test",
            jwt_secret="test-secret",
        )
        assert settings.db_pool_min_size == 2
        assert settings.db_pool_max_size == 10
        assert settings.jwt_access_ttl_minutes == 15
        assert settings.jwt_refresh_ttl_days == 7
        assert settings.bcrypt_cost == 12
        assert settings.log_level == "INFO"
        assert settings.sentry_dsn is None
        assert settings.artifacts_path == "/opt/bundle/artifacts"

    def test_loads_from_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Settings should load values from environment variables."""
        monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@db:5432/mydb")
        monkeypatch.setenv("JWT_SECRET", "super-secret")
        monkeypatch.setenv("LOG_LEVEL", "DEBUG")
        monkeypatch.setenv("DB_POOL_MIN_SIZE", "5")
        monkeypatch.setenv("DB_POOL_MAX_SIZE", "20")
        monkeypatch.setenv("SENTRY_DSN", "https://sentry.example.com/123")

        settings = Settings()
        assert settings.database_url == "postgresql://user:pass@db:5432/mydb"
        assert settings.jwt_secret == "super-secret"
        assert settings.log_level == "DEBUG"
        assert settings.db_pool_min_size == 5
        assert settings.db_pool_max_size == 20
        assert settings.sentry_dsn == "https://sentry.example.com/123"

    def test_optional_llm_keys_default_none(self) -> None:
        """NVIDIA API key should default to None."""
        settings = Settings(
            _env_file=None,
            database_url="postgresql://test:test@localhost:5432/test",
            jwt_secret="test-secret",
        )
        assert settings.nvidia_api_key is None
