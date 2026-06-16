"""Auth router: parse requests, call auth_service, format responses."""
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID
import asyncpg
import structlog
from fastapi import APIRouter, Depends, HTTPException, Request, status
from api.config import Settings
from api.dependencies import get_pool, get_rate_limiter
from api.middleware.auth import CurrentUser, get_current_user
from api.middleware.rate_limiter import RateLimitConfig, RateLimiter
from api.models.requests import (ChangePasswordRequest, LoginRequest, RefreshRequest, RegisterRequest, UpdateEmailRequest)
from api.models.responses import AuthResponse, MessageResponse, TokenResponse, UserResponse
from api.services import quota_service
from api.services.auth_service import (
    PasswordValidationError, TokenError, blacklist_token, change_password, decode_refresh_token,
    generate_tokens, get_password_hash, hash_password, is_token_blacklisted, lookup_user_by_email,
    register_user, update_user_email, validate_password_strength, validate_token_not_revoked,
    verify_password,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])
logger = structlog.get_logger("api.auth")

LOGIN_RATE_CONFIG = RateLimitConfig(max_requests=10, window_seconds=60)
REGISTER_RATE_CONFIG = RateLimitConfig(max_requests=3, window_seconds=3600)

def _validate_pw(pw: str) -> None:
    try: validate_password_strength(pw)
    except PasswordValidationError as e: raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=e.message) from None

@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterRequest, pool: Annotated[asyncpg.Pool, Depends(get_pool)], request: Request, limiter: Annotated[RateLimiter, Depends(get_rate_limiter)]) -> AuthResponse:
    """Create a new user account and return tokens."""
    settings: Settings = request.app.state.settings
    ip = request.client.host if request.client else "unknown"
    limiter.check(f"register:{ip}", REGISTER_RATE_CONFIG)
    limiter.record(f"register:{ip}")
    _validate_pw(body.password)
    try:
        async with pool.acquire() as conn:
            row = await register_user(conn, email=body.email, password_hash=hash_password(body.password, cost=settings.bcrypt_cost))
            await quota_service.create_quota_row(conn, user_id=row["id"])
    except asyncpg.UniqueViolationError:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered") from None
    access_token, refresh_token, _ = generate_tokens(str(row["id"]), settings)
    logger.info("user_registered", user_id=str(row["id"]))
    return AuthResponse(user=UserResponse(id=row["id"], email=row["email"], created_at=row["created_at"], updated_at=row["updated_at"]), access_token=access_token, refresh_token=refresh_token)

@router.post("/login", response_model=AuthResponse)
async def login(body: LoginRequest, pool: Annotated[asyncpg.Pool, Depends(get_pool)], request: Request, limiter: Annotated[RateLimiter, Depends(get_rate_limiter)]) -> AuthResponse:
    """Authenticate with email and password, return tokens."""
    settings: Settings = request.app.state.settings
    ip = request.client.host if request.client else "unknown"
    limiter.check(f"login:{ip}", LOGIN_RATE_CONFIG)
    limiter.record(f"login:{ip}")
    async with pool.acquire() as conn:
        row = await lookup_user_by_email(conn, email=body.email)
    if row is None or not verify_password(body.password, row["password_hash"]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    access_token, refresh_token, _ = generate_tokens(str(row["id"]), settings)
    logger.info("user_logged_in", user_id=str(row["id"]))
    return AuthResponse(user=UserResponse(id=row["id"], email=row["email"], created_at=row["created_at"], updated_at=row["updated_at"]), access_token=access_token, refresh_token=refresh_token)

@router.post("/refresh", response_model=TokenResponse)
async def refresh(body: RefreshRequest, pool: Annotated[asyncpg.Pool, Depends(get_pool)], request: Request) -> TokenResponse:
    """Rotate tokens: validate refresh token, blacklist it, issue new pair."""
    settings: Settings = request.app.state.settings
    try: payload = decode_refresh_token(body.refresh_token, settings)
    except TokenError as e: raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=e.message) from None
    jti, user_id, exp = UUID(payload["jti"]), payload["sub"], payload["exp"]
    async with pool.acquire() as conn:
        if await is_token_blacklisted(conn, jti=jti):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token has been revoked")
        try:
            await validate_token_not_revoked(conn, user_id, payload["iat"])
        except TokenError as e:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=e.message) from None
        await blacklist_token(conn, jti=jti, user_id=UUID(user_id), expires_at=datetime.fromtimestamp(exp, tz=UTC))
    access_token, new_refresh_token, _ = generate_tokens(user_id, settings)
    return TokenResponse(access_token=access_token, refresh_token=new_refresh_token)

@router.post("/logout", response_model=MessageResponse)
async def logout(body: RefreshRequest, pool: Annotated[asyncpg.Pool, Depends(get_pool)], current_user: Annotated[CurrentUser, Depends(get_current_user)], request: Request) -> MessageResponse:
    """Blacklist the current refresh token."""
    try: payload = decode_refresh_token(body.refresh_token, request.app.state.settings)
    except TokenError as e: raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=e.message) from None
    async with pool.acquire() as conn:
        await blacklist_token(conn, jti=UUID(payload["jti"]), user_id=current_user.id, expires_at=datetime.fromtimestamp(payload["exp"], tz=UTC))
    return MessageResponse(message="Logged out successfully")

@router.get("/me", response_model=UserResponse)
async def get_me(current_user: Annotated[CurrentUser, Depends(get_current_user)]) -> UserResponse:
    """Get current user profile."""
    return UserResponse(id=current_user.id, email=current_user.email, created_at=current_user.created_at, updated_at=current_user.updated_at)

@router.put("/me", response_model=UserResponse)
async def update_email_endpoint(body: UpdateEmailRequest, current_user: Annotated[CurrentUser, Depends(get_current_user)], pool: Annotated[asyncpg.Pool, Depends(get_pool)]) -> UserResponse:
    """Update current user's email."""
    try:
        async with pool.acquire() as conn:
            row = await update_user_email(conn, user_id=current_user.id, new_email=body.email)
    except asyncpg.UniqueViolationError:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already in use") from None
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return UserResponse(id=row["id"], email=row["email"], created_at=row["created_at"], updated_at=row["updated_at"])

@router.post("/me/password", response_model=AuthResponse)
async def change_password_endpoint(body: ChangePasswordRequest, current_user: Annotated[CurrentUser, Depends(get_current_user)], pool: Annotated[asyncpg.Pool, Depends(get_pool)], request: Request) -> AuthResponse:
    """Change password, revoke all sessions, issue new tokens."""
    settings: Settings = request.app.state.settings
    _validate_pw(body.new_password)
    async with pool.acquire() as conn:
        pw_hash = await get_password_hash(conn, user_id=current_user.id)
    if pw_hash is None or not verify_password(body.current_password, pw_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Current password is incorrect")
    async with pool.acquire() as conn:
        row = await change_password(conn, user_id=current_user.id, new_password_hash=hash_password(body.new_password, cost=settings.bcrypt_cost))
    access_token, refresh_token, _ = generate_tokens(str(current_user.id), settings)
    return AuthResponse(user=UserResponse(id=row["id"], email=row["email"], created_at=row["created_at"], updated_at=row["updated_at"]), access_token=access_token, refresh_token=refresh_token)
