"""Auth router: register, login, refresh, logout, me, update email, change password."""

import time
from collections import defaultdict
from typing import Annotated
from uuid import UUID

import asyncpg
import structlog
from fastapi import APIRouter, Depends, HTTPException, Request, status

from api.config import Settings  # noqa: TC001
from api.dependencies import get_pool
from api.middleware.auth import CurrentUser, get_current_user
from api.models.requests import (
    ChangePasswordRequest,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    UpdateEmailRequest,
)
from api.models.responses import AuthResponse, MessageResponse, TokenResponse, UserResponse
from api.services.auth_service import (
    PasswordValidationError,
    TokenError,
    decode_refresh_token,
    generate_tokens,
    hash_password,
    validate_password_strength,
    verify_password,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])
logger = structlog.get_logger("api.auth")

# Rate limiting state: IP -> list of timestamps
_login_attempts: dict[str, list[float]] = defaultdict(list)
LOGIN_RATE_LIMIT = 10  # max attempts
LOGIN_RATE_WINDOW = 60  # seconds


def _check_rate_limit(ip: str) -> None:
    """Check if an IP has exceeded the login rate limit.

    Raises HTTPException 429 if the limit is exceeded.
    """
    now = time.time()
    # Clean old entries outside the window
    _login_attempts[ip] = [t for t in _login_attempts[ip] if now - t < LOGIN_RATE_WINDOW]

    if len(_login_attempts[ip]) >= LOGIN_RATE_LIMIT:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many login attempts. Please try again later.",
        )


def _record_login_attempt(ip: str) -> None:
    """Record a login attempt for rate limiting."""
    _login_attempts[ip].append(time.time())


@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
async def register(
    body: RegisterRequest,
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> AuthResponse:
    """Create a new user account and return tokens."""
    settings: Settings = request.app.state.settings

    try:
        validate_password_strength(body.password)
    except PasswordValidationError as e:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=e.message,
        ) from None

    password_hash = hash_password(body.password, cost=settings.bcrypt_cost)

    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                INSERT INTO auth.users (email, password_hash)
                VALUES ($1, $2)
                RETURNING id, email, created_at, updated_at
                """,
                body.email,
                password_hash,
            )
    except asyncpg.UniqueViolationError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered",
        ) from None

    user_id = str(row["id"])
    access_token, refresh_token, _jti = generate_tokens(user_id, settings)

    logger.info("user_registered", user_id=user_id, email=body.email)

    return AuthResponse(
        user=UserResponse(
            id=row["id"],
            email=row["email"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        ),
        access_token=access_token,
        refresh_token=refresh_token,
    )


@router.post("/login", response_model=AuthResponse)
async def login(
    body: LoginRequest,
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> AuthResponse:
    """Authenticate with email and password, return tokens."""
    settings: Settings = request.app.state.settings
    client_ip = request.client.host if request.client else "unknown"

    _check_rate_limit(client_ip)
    _record_login_attempt(client_ip)

    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT id, email, password_hash, tokens_revoked_at, created_at, updated_at
            FROM auth.users
            WHERE email = $1
            """,
            body.email,
        )

    # Always return generic error to not reveal if email exists
    if row is None or not verify_password(body.password, row["password_hash"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
        )

    user_id = str(row["id"])
    access_token, refresh_token, _jti = generate_tokens(user_id, settings)

    logger.info("user_logged_in", user_id=user_id)

    return AuthResponse(
        user=UserResponse(
            id=row["id"],
            email=row["email"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        ),
        access_token=access_token,
        refresh_token=refresh_token,
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(
    body: RefreshRequest,
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> TokenResponse:
    """Rotate tokens: validate refresh token, blacklist it, issue new pair."""
    settings: Settings = request.app.state.settings

    try:
        payload = decode_refresh_token(body.refresh_token, settings)
    except TokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=e.message,
        ) from None

    jti = payload["jti"]
    user_id = payload["sub"]
    exp = payload["exp"]

    async with pool.acquire() as conn:
        # Check if token is already blacklisted
        is_blacklisted = await conn.fetchval(
            "SELECT EXISTS(SELECT 1 FROM auth.refresh_token_blacklist WHERE jti = $1)",
            UUID(jti),
        )
        if is_blacklisted:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Token has been revoked",
            )

        # Blacklist the old refresh token
        from datetime import UTC, datetime

        await conn.execute(
            """
            INSERT INTO auth.refresh_token_blacklist (jti, user_id, expires_at)
            VALUES ($1, $2, $3)
            """,
            UUID(jti),
            UUID(user_id),
            datetime.fromtimestamp(exp, tz=UTC),
        )

    # Issue new token pair
    access_token, new_refresh_token, _new_jti = generate_tokens(user_id, settings)

    logger.info("tokens_refreshed", user_id=user_id)

    return TokenResponse(
        access_token=access_token,
        refresh_token=new_refresh_token,
    )


@router.post("/logout", response_model=MessageResponse)
async def logout(
    body: RefreshRequest,
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    request: Request,
) -> MessageResponse:
    """Blacklist the current refresh token."""
    settings: Settings = request.app.state.settings

    try:
        payload = decode_refresh_token(body.refresh_token, settings)
    except TokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=e.message,
        ) from None

    jti = payload["jti"]
    exp = payload["exp"]

    from datetime import UTC, datetime

    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO auth.refresh_token_blacklist (jti, user_id, expires_at)
            VALUES ($1, $2, $3)
            ON CONFLICT (jti) DO NOTHING
            """,
            UUID(jti),
            current_user.id,
            datetime.fromtimestamp(exp, tz=UTC),
        )

    logger.info("user_logged_out", user_id=str(current_user.id))

    return MessageResponse(message="Logged out successfully")


@router.get("/me", response_model=UserResponse)
async def get_me(
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
) -> UserResponse:
    """Get current user profile."""
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, email, created_at, updated_at FROM auth.users WHERE id = $1",
            current_user.id,
        )

    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    return UserResponse(
        id=row["id"],
        email=row["email"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


@router.put("/me", response_model=UserResponse)
async def update_email(
    body: UpdateEmailRequest,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
) -> UserResponse:
    """Update current user's email."""
    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                UPDATE auth.users
                SET email = $2, updated_at = now()
                WHERE id = $1
                RETURNING id, email, created_at, updated_at
                """,
                current_user.id,
                body.email,
            )
    except asyncpg.UniqueViolationError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already in use",
        ) from None

    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    logger.info("email_updated", user_id=str(current_user.id), new_email=body.email)

    return UserResponse(
        id=row["id"],
        email=row["email"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


@router.post("/me/password", response_model=MessageResponse)
async def change_password(
    body: ChangePasswordRequest,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> MessageResponse:
    """Change password and revoke all existing sessions."""
    settings: Settings = request.app.state.settings

    try:
        validate_password_strength(body.new_password)
    except PasswordValidationError as e:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=e.message,
        ) from None

    # Verify current password
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT password_hash FROM auth.users WHERE id = $1",
            current_user.id,
        )

    if row is None or not verify_password(body.current_password, row["password_hash"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Current password is incorrect",
        )

    # Hash new password and update (sets tokens_revoked_at = now())
    new_hash = hash_password(body.new_password, cost=settings.bcrypt_cost)

    async with pool.acquire() as conn:
        await conn.execute(
            """
            UPDATE auth.users
            SET password_hash = $2, tokens_revoked_at = now(), updated_at = now()
            WHERE id = $1
            """,
            current_user.id,
            new_hash,
        )

    logger.info("password_changed", user_id=str(current_user.id))

    return MessageResponse(message="Password changed successfully. All sessions revoked.")
