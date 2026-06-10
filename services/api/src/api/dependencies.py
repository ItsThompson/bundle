"""FastAPI dependency injection providers."""

from collections.abc import AsyncGenerator

import asyncpg
from fastapi import Request


async def get_pool(request: Request) -> AsyncGenerator[asyncpg.Pool, None]:
    """Provide the database connection pool from app state.

    Yields the pool for the duration of the request.
    """
    yield request.app.state.pool
