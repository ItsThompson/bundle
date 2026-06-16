"""Authentication middleware: JWT validation and current user extraction."""

from datetime import datetime
from typing import Annotated
from uuid import UUID

import asyncpg
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from api.config import Settings  # noqa: TC001
from api.dependencies import get_pool
from api.services.auth_service import TokenError, decode_access_token, validate_token_not_revoked

security = HTTPBearer()


class CurrentUser:
    """Represents the authenticated user extracted from JWT."""

    def __init__(
        self,
        id: UUID,
        email: str,
        tokens_revoked_at: datetime | None,
        created_at: datetime,
        updated_at: datetime,
    ) -> None:
        self.id = id
        self.email = email
        self.tokens_revoked_at = tokens_revoked_at
        self.created_at = created_at
        self.updated_at = updated_at


async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials, Depends(security)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> CurrentUser:
    """Extract and validate the current user from the Authorization header.

    Validates the access token and checks it hasn't been revoked.
    """
    settings: Settings = request.app.state.settings
    token = credentials.credentials

    try:
        payload = decode_access_token(token, settings)
    except TokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=e.message,
            headers={"WWW-Authenticate": "Bearer"},
        ) from None

    user_id = payload["sub"]

    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, email, tokens_revoked_at, created_at, updated_at FROM auth.users WHERE id = $1",
            UUID(user_id),
        )

        if row is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="User not found",
                headers={"WWW-Authenticate": "Bearer"},
            )

        try:
            await validate_token_not_revoked(conn, user_id, payload["iat"])
        except TokenError as e:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=e.message,
                headers={"WWW-Authenticate": "Bearer"},
            ) from None

    return CurrentUser(
        id=row["id"],
        email=row["email"],
        tokens_revoked_at=row["tokens_revoked_at"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )
