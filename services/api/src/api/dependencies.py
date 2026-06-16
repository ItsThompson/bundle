"""FastAPI dependency injection providers."""

from collections.abc import AsyncGenerator

import asyncpg
from fastapi import Request

from api.middleware.rate_limiter import RateLimiter

# Single shared instance: state is lost on restart (acceptable for rate limiting)
_rate_limiter = RateLimiter()


async def get_pool(request: Request) -> AsyncGenerator[asyncpg.Pool, None]:
    """Provide the database connection pool from app state.

    Yields the pool for the duration of the request.
    """
    yield request.app.state.pool


def get_rate_limiter() -> RateLimiter:
    """Provide the shared rate limiter instance."""
    return _rate_limiter
