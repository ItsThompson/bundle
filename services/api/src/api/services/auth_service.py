"""Authentication service: JWT lifecycle, password hashing, token rotation."""

import re
import uuid
from datetime import UTC, datetime, timedelta

import bcrypt
import jwt

from api.config import Settings


class PasswordValidationError(Exception):
    """Raised when a password does not meet strength requirements."""

    def __init__(self, message: str) -> None:
        self.message = message
        super().__init__(message)


class InvalidCredentialsError(Exception):
    """Raised when login credentials are invalid."""


class TokenError(Exception):
    """Raised when a token is invalid, expired, or revoked."""

    def __init__(self, message: str = "Invalid token") -> None:
        self.message = message
        super().__init__(message)


PASSWORD_PATTERN = re.compile(r"^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,72}$")


def validate_password_strength(password: str) -> None:
    """Validate password meets strength requirements.

    Requirements: 8-72 chars, 1 uppercase, 1 lowercase, 1 digit.
    """
    if len(password) < 8:
        raise PasswordValidationError("Password must be at least 8 characters")
    if len(password) > 72:
        raise PasswordValidationError("Password must be at most 72 characters")
    if not re.search(r"[a-z]", password):
        raise PasswordValidationError("Password must contain at least one lowercase letter")
    if not re.search(r"[A-Z]", password):
        raise PasswordValidationError("Password must contain at least one uppercase letter")
    if not re.search(r"\d", password):
        raise PasswordValidationError("Password must contain at least one digit")


def hash_password(password: str, cost: int = 12) -> str:
    """Hash a password with bcrypt."""
    salt = bcrypt.gensalt(rounds=cost)
    return bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    """Verify a password against its bcrypt hash."""
    return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))


def generate_access_token(user_id: str, settings: Settings) -> str:
    """Generate a short-lived access token containing user_id."""
    now = datetime.now(UTC)
    payload = {
        "sub": user_id,
        "iat": now,
        "exp": now + timedelta(minutes=settings.jwt_access_ttl_minutes),
        "type": "access",
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def generate_refresh_token(user_id: str, settings: Settings) -> tuple[str, str]:
    """Generate a long-lived refresh token with a unique jti.

    Returns (token, jti) tuple.
    """
    now = datetime.now(UTC)
    jti = str(uuid.uuid4())
    payload = {
        "sub": user_id,
        "jti": jti,
        "iat": now,
        "exp": now + timedelta(days=settings.jwt_refresh_ttl_days),
        "type": "refresh",
    }
    token = jwt.encode(payload, settings.jwt_secret, algorithm="HS256")
    return token, jti


def generate_tokens(user_id: str, settings: Settings) -> tuple[str, str, str]:
    """Generate both access and refresh tokens.

    Returns (access_token, refresh_token, refresh_jti).
    """
    access_token = generate_access_token(user_id, settings)
    refresh_token, jti = generate_refresh_token(user_id, settings)
    return access_token, refresh_token, jti


def decode_access_token(
    token: str, settings: Settings, tokens_revoked_at: datetime | None = None
) -> dict:
    """Decode and validate an access token.

    Raises TokenError if the token is invalid, expired, or issued before revocation.
    """
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise TokenError("Token has expired") from None
    except jwt.InvalidTokenError:
        raise TokenError("Invalid token") from None

    if payload.get("type") != "access":
        raise TokenError("Invalid token type")

    if tokens_revoked_at is not None:
        issued_at = datetime.fromtimestamp(payload["iat"], tz=UTC)
        if issued_at < tokens_revoked_at:
            raise TokenError("Token has been revoked")

    return payload


def decode_refresh_token(token: str, settings: Settings) -> dict:
    """Decode and validate a refresh token.

    Raises TokenError if the token is invalid or expired.
    """
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        raise TokenError("Refresh token has expired") from None
    except jwt.InvalidTokenError:
        raise TokenError("Invalid refresh token") from None

    if payload.get("type") != "refresh":
        raise TokenError("Invalid token type")

    if "jti" not in payload:
        raise TokenError("Invalid refresh token: missing jti")

    return payload
