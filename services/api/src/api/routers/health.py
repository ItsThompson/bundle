"""Health check endpoint."""

import asyncio
from typing import Annotated

import asyncpg
from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from api.dependencies import get_pool

router = APIRouter()

HEALTH_CHECK_TIMEOUT_SECONDS = 3.0


@router.get("/health")
async def health(pool: Annotated[asyncpg.Pool, Depends(get_pool)]) -> JSONResponse:
    """Check service and database health.

    Returns 200 with connected status when DB is reachable,
    503 with disconnected status when DB is unreachable.
    """
    try:
        async with asyncio.timeout(HEALTH_CHECK_TIMEOUT_SECONDS):
            async with pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
        return JSONResponse(
            content={"status": "healthy", "db": "connected"},
            status_code=200,
        )
    except Exception:
        return JSONResponse(
            content={"status": "unhealthy", "db": "disconnected"},
            status_code=503,
        )
