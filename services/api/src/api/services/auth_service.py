"""Authentication service: JWT lifecycle, password hashing, token rotation, and user persistence."""

import re
import uuid
from datetime import UTC, datetime, timedelta

import asyncpg
import bcrypt
import jwt
import structlog

from api.config import Settings

logger = structlog.get_logger("api.auth_service")


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


# --- Token revocation ---


async def validate_token_not_revoked(
    conn: asyncpg.Connection,
    user_id: str,
    token_iat: int,
) -> None:
    """Check if a token was issued before the user's revocation timestamp.

    Raises TokenError if the token is revoked (iat < tokens_revoked_at).
    """
    revoked_at = await conn.fetchval(
        "SELECT tokens_revoked_at FROM auth.users WHERE id = $1",
        uuid.UUID(user_id),
    )
    if revoked_at is not None:
        revoked_at_unix = int(revoked_at.timestamp())
        if token_iat < revoked_at_unix:
            raise TokenError("Token has been revoked")


# --- Database operations ---


async def register_user(
    conn: asyncpg.Connection,
    *,
    email: str,
    password_hash: str,
) -> dict:
    """Insert a new user. Returns the created user record.

    Raises asyncpg.UniqueViolationError if email already exists.
    """
    row = await conn.fetchrow(
        """
        INSERT INTO auth.users (email, password_hash)
        VALUES ($1, $2)
        RETURNING id, email, created_at, updated_at
        """,
        email,
        password_hash,
    )
    return dict(row)


async def lookup_user_by_email(
    conn: asyncpg.Connection,
    *,
    email: str,
) -> dict | None:
    """Look up a user by email for login. Returns user row or None."""
    row = await conn.fetchrow(
        """
        SELECT id, email, password_hash, tokens_revoked_at, created_at, updated_at
        FROM auth.users
        WHERE email = $1
        """,
        email,
    )
    return dict(row) if row else None


async def is_token_blacklisted(
    conn: asyncpg.Connection,
    *,
    jti: uuid.UUID,
) -> bool:
    """Check if a refresh token JTI is blacklisted."""
    return await conn.fetchval(
        "SELECT EXISTS(SELECT 1 FROM auth.refresh_token_blacklist WHERE jti = $1)",
        jti,
    )


async def blacklist_token(
    conn: asyncpg.Connection,
    *,
    jti: uuid.UUID,
    user_id: uuid.UUID,
    expires_at: datetime,
) -> None:
    """Add a refresh token to the blacklist."""
    await conn.execute(
        """
        INSERT INTO auth.refresh_token_blacklist (jti, user_id, expires_at)
        VALUES ($1, $2, $3)
        ON CONFLICT (jti) DO NOTHING
        """,
        jti,
        user_id,
        expires_at,
    )


async def update_user_email(
    conn: asyncpg.Connection,
    *,
    user_id: uuid.UUID,
    new_email: str,
) -> dict | None:
    """Update a user's email. Returns updated row or None.

    Raises asyncpg.UniqueViolationError if email is already in use.
    """
    row = await conn.fetchrow(
        """
        UPDATE auth.users
        SET email = $2, updated_at = now()
        WHERE id = $1
        RETURNING id, email, created_at, updated_at
        """,
        user_id,
        new_email,
    )
    return dict(row) if row else None


async def get_password_hash(
    conn: asyncpg.Connection,
    *,
    user_id: uuid.UUID,
) -> str | None:
    """Get the current password hash for a user. Returns None if user not found."""
    return await conn.fetchval(
        "SELECT password_hash FROM auth.users WHERE id = $1",
        user_id,
    )


async def change_password(
    conn: asyncpg.Connection,
    *,
    user_id: uuid.UUID,
    new_password_hash: str,
) -> dict | None:
    """Update password and revoke all sessions. Returns updated user row or None."""
    row = await conn.fetchrow(
        """
        UPDATE auth.users
        SET password_hash = $2, tokens_revoked_at = now(), updated_at = now()
        WHERE id = $1
        RETURNING id, email, created_at, updated_at
        """,
        user_id,
        new_password_hash,
    )
    return dict(row) if row else None
