"""Tests for the auth service: password validation, hashing, JWT lifecycle."""

from datetime import UTC, datetime, timedelta

import jwt
import pytest
from api.config import Settings
from api.services.auth_service import (
    PasswordValidationError,
    TokenError,
    decode_access_token,
    decode_refresh_token,
    generate_access_token,
    generate_refresh_token,
    generate_tokens,
    hash_password,
    validate_password_strength,
    verify_password,
)


@pytest.fixture
def settings() -> Settings:
    """Create test settings with known values."""
    return Settings(
        database_url="postgresql://test:test@localhost/test",
        jwt_secret="test-secret-key-minimum-32-chars!",
        jwt_access_ttl_minutes=15,
        jwt_refresh_ttl_days=7,
        bcrypt_cost=4,  # Low cost for fast tests
    )


class TestPasswordValidation:
    """Test password strength validation."""

    def test_valid_password(self) -> None:
        """Accepts password meeting all requirements."""
        validate_password_strength("ValidPass1")

    def test_too_short(self) -> None:
        """Rejects password shorter than 8 chars."""
        with pytest.raises(PasswordValidationError, match="at least 8"):
            validate_password_strength("Short1A")

    def test_too_long(self) -> None:
        """Rejects password longer than 72 chars."""
        with pytest.raises(PasswordValidationError, match="at most 72"):
            validate_password_strength("A1" + "a" * 71)

    def test_no_uppercase(self) -> None:
        """Rejects password without uppercase letter."""
        with pytest.raises(PasswordValidationError, match="uppercase"):
            validate_password_strength("nouppercase1")

    def test_no_lowercase(self) -> None:
        """Rejects password without lowercase letter."""
        with pytest.raises(PasswordValidationError, match="lowercase"):
            validate_password_strength("NOLOWERCASE1")

    def test_no_digit(self) -> None:
        """Rejects password without digit."""
        with pytest.raises(PasswordValidationError, match="digit"):
            validate_password_strength("NoDigitHere")

    def test_exact_minimum_length(self) -> None:
        """Accepts password at exactly 8 chars."""
        validate_password_strength("Abcdef1x")

    def test_exact_maximum_length(self) -> None:
        """Accepts password at exactly 72 chars."""
        validate_password_strength("A1" + "b" * 70)


class TestPasswordHashing:
    """Test bcrypt password hashing and verification."""

    def test_hash_and_verify(self) -> None:
        """Hashed password verifies correctly."""
        password = "TestPassword1"
        hashed = hash_password(password, cost=4)
        assert verify_password(password, hashed)

    def test_wrong_password_fails(self) -> None:
        """Wrong password fails verification."""
        hashed = hash_password("CorrectPassword1", cost=4)
        assert not verify_password("WrongPassword1", hashed)

    def test_hash_is_different_each_time(self) -> None:
        """Each hash is unique (different salt)."""
        password = "TestPassword1"
        hash1 = hash_password(password, cost=4)
        hash2 = hash_password(password, cost=4)
        assert hash1 != hash2


class TestAccessToken:
    """Test access token generation and decoding."""

    def test_generate_and_decode(self, settings: Settings) -> None:
        """Generated token decodes to original user_id."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        token = generate_access_token(user_id, settings)
        payload = decode_access_token(token, settings)

        assert payload["sub"] == user_id
        assert payload["type"] == "access"

    def test_expired_token_rejected(self, settings: Settings) -> None:
        """Expired access token raises TokenError."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        now = datetime.now(UTC)
        payload = {
            "sub": user_id,
            "iat": now - timedelta(hours=1),
            "exp": now - timedelta(minutes=1),
            "type": "access",
        }
        token = jwt.encode(payload, settings.jwt_secret, algorithm="HS256")

        with pytest.raises(TokenError, match="expired"):
            decode_access_token(token, settings)

    def test_invalid_signature_rejected(self, settings: Settings) -> None:
        """Token with wrong secret raises TokenError."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        token = generate_access_token(user_id, settings)

        wrong_settings = Settings(
            database_url="postgresql://test:test@localhost/test",
            jwt_secret="wrong-secret-but-still-32-chars!",
        )
        with pytest.raises(TokenError, match="Invalid token"):
            decode_access_token(token, wrong_settings)

    def test_refresh_token_type_rejected_as_access(self, settings: Settings) -> None:
        """Refresh token cannot be used as access token."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        refresh_token, _jti = generate_refresh_token(user_id, settings)

        with pytest.raises(TokenError, match="Invalid token type"):
            decode_access_token(refresh_token, settings)

    def test_revoked_token_rejected(self, settings: Settings) -> None:
        """Token issued before revocation time is rejected."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        token = generate_access_token(user_id, settings)

        # Revoke "after" the token was issued (future revocation time)
        revoked_at = datetime.now(UTC) + timedelta(seconds=1)

        with pytest.raises(TokenError, match="revoked"):
            decode_access_token(token, settings, tokens_revoked_at=revoked_at)

    def test_token_after_revocation_accepted(self, settings: Settings) -> None:
        """Token issued after revocation time is accepted."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"

        # Revoke in the past
        revoked_at = datetime.now(UTC) - timedelta(hours=1)
        token = generate_access_token(user_id, settings)

        payload = decode_access_token(token, settings, tokens_revoked_at=revoked_at)
        assert payload["sub"] == user_id


class TestRefreshToken:
    """Test refresh token generation and decoding."""

    def test_generate_and_decode(self, settings: Settings) -> None:
        """Generated refresh token decodes with correct jti."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        token, jti = generate_refresh_token(user_id, settings)
        payload = decode_refresh_token(token, settings)

        assert payload["sub"] == user_id
        assert payload["jti"] == jti
        assert payload["type"] == "refresh"

    def test_expired_refresh_token_rejected(self, settings: Settings) -> None:
        """Expired refresh token raises TokenError."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        now = datetime.now(UTC)
        payload = {
            "sub": user_id,
            "jti": "some-jti",
            "iat": now - timedelta(days=8),
            "exp": now - timedelta(days=1),
            "type": "refresh",
        }
        token = jwt.encode(payload, settings.jwt_secret, algorithm="HS256")

        with pytest.raises(TokenError, match="expired"):
            decode_refresh_token(token, settings)

    def test_access_token_rejected_as_refresh(self, settings: Settings) -> None:
        """Access token cannot be used as refresh token."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        access_token = generate_access_token(user_id, settings)

        with pytest.raises(TokenError, match="Invalid token type"):
            decode_refresh_token(access_token, settings)


class TestGenerateTokens:
    """Test the combined token generation function."""

    def test_generates_both_tokens(self, settings: Settings) -> None:
        """Returns access token, refresh token, and jti."""
        user_id = "550e8400-e29b-41d4-a716-446655440000"
        access_token, refresh_token, jti = generate_tokens(user_id, settings)

        # Verify access token
        access_payload = decode_access_token(access_token, settings)
        assert access_payload["sub"] == user_id

        # Verify refresh token
        refresh_payload = decode_refresh_token(refresh_token, settings)
        assert refresh_payload["sub"] == user_id
        assert refresh_payload["jti"] == jti
