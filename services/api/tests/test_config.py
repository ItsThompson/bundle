"""Tests for api.config module."""

import pytest
from pydantic import ValidationError

from api.config import KNOWN_INSECURE_SECRETS, Settings

# Valid secret for use in tests that don't test validation
VALID_SECRET = "test-secret-key-minimum-32-chars!"


class TestSettings:
    """Test pydantic-settings configuration loading."""

    def test_default_values(self) -> None:
        """Settings should have sensible defaults when no env vars are set."""
        settings = Settings(
            _env_file=None,
            database_url="postgresql://test:test@localhost:5432/test",
            jwt_secret=VALID_SECRET,
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
        monkeypatch.setenv("JWT_SECRET", "a-secure-secret-that-is-at-least-32-chars-long!")
        monkeypatch.setenv("LOG_LEVEL", "DEBUG")
        monkeypatch.setenv("DB_POOL_MIN_SIZE", "5")
        monkeypatch.setenv("DB_POOL_MAX_SIZE", "20")
        monkeypatch.setenv("SENTRY_DSN", "https://sentry.example.com/123")

        settings = Settings()
        assert settings.database_url == "postgresql://user:pass@db:5432/mydb"
        assert settings.jwt_secret == "a-secure-secret-that-is-at-least-32-chars-long!"
        assert settings.log_level == "DEBUG"
        assert settings.db_pool_min_size == 5
        assert settings.db_pool_max_size == 20
        assert settings.sentry_dsn == "https://sentry.example.com/123"

    def test_optional_llm_keys_default_none(self) -> None:
        """NVIDIA API key should default to None."""
        settings = Settings(
            _env_file=None,
            database_url="postgresql://test:test@localhost:5432/test",
            jwt_secret=VALID_SECRET,
        )
        assert settings.nvidia_api_key is None

    def test_database_url_has_working_default(self) -> None:
        """DATABASE_URL default should work for local dev."""
        settings = Settings(
            _env_file=None,
            jwt_secret=VALID_SECRET,
        )
        assert settings.database_url == "postgresql://bundle:bundle_dev@localhost:5433/bundle"


class TestJwtSecretValidation:
    """Test JWT_SECRET startup validation."""

    def test_rejects_unset_jwt_secret(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """API should fail to start if JWT_SECRET is unset."""
        monkeypatch.delenv("JWT_SECRET", raising=False)
        with pytest.raises((ValidationError, Exception)):
            Settings(_env_file=None)

    def test_rejects_short_jwt_secret(self) -> None:
        """API should fail to start if JWT_SECRET is less than 32 chars."""
        with pytest.raises(ValidationError, match="JWT_SECRET must be at least 32 characters"):
            Settings(_env_file=None, jwt_secret="too-short")

    def test_rejects_known_insecure_values(self) -> None:
        """API should fail to start if JWT_SECRET is a known insecure value."""
        for insecure_value in KNOWN_INSECURE_SECRETS:
            with pytest.raises(ValidationError, match="known insecure value"):
                Settings(_env_file=None, jwt_secret=insecure_value)

    def test_rejects_change_me_default(self) -> None:
        """The old default 'change-me-in-production' should be rejected."""
        with pytest.raises(ValidationError, match="known insecure value"):
            Settings(_env_file=None, jwt_secret="change-me-in-production")

    def test_error_message_names_variable(self) -> None:
        """Error message should name the specific misconfigured variable."""
        with pytest.raises(ValidationError, match="JWT_SECRET"):
            Settings(_env_file=None, jwt_secret="short")

    def test_accepts_valid_secret(self) -> None:
        """A secure 32+ char secret should be accepted."""
        settings = Settings(_env_file=None, jwt_secret=VALID_SECRET)
        assert settings.jwt_secret == VALID_SECRET

    def test_accepts_long_secret(self) -> None:
        """Longer secrets should work fine."""
        long_secret = "a" * 64
        settings = Settings(_env_file=None, jwt_secret=long_secret)
        assert settings.jwt_secret == long_secret
