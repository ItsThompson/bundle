"""Tags router: list all tags with counts for the current user."""

from typing import Annotated

import asyncpg
from fastapi import APIRouter, Depends

from api.dependencies import get_pool
from api.middleware.auth import CurrentUser, get_current_user
from api.models.artifact_responses import TagWithCountResponse

router = APIRouter(prefix="/api/v1/tags", tags=["tags"])


@router.get("", response_model=list[TagWithCountResponse])
async def list_tags(
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
) -> list[TagWithCountResponse]:
    """List all tag names with counts for the current user.

    Returns tags ordered by count descending.
    """
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT at.name, COUNT(*) AS count
            FROM artifact_tags at
            JOIN artifacts a ON a.id = at.artifact_id
            WHERE a.user_id = $1
            GROUP BY at.name
            ORDER BY count DESC
            """,
            current_user.id,
        )

    return [
        TagWithCountResponse(name=row["name"], count=row["count"])
        for row in rows
    ]
