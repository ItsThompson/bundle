"""Per-user storage quota enforcement."""

import uuid

import asyncpg
from fastapi import HTTPException, status

# 1 GB storage limit per user
STORAGE_QUOTA_BYTES = 1 * 1024 * 1024 * 1024


async def check_storage_quota(
    conn: asyncpg.Connection,
    user_id: uuid.UUID,
    incoming_bytes: int,
) -> None:
    """Check if user has enough storage quota for the incoming file.

    Creates quota row on-demand if it doesn't exist (handles existing users).
    Raises HTTPException 413 if quota would be exceeded.
    """
    current_usage = await conn.fetchval(
        "SELECT storage_bytes_used FROM user_quotas WHERE user_id = $1",
        user_id,
    )
    if current_usage is None:
        await conn.execute(
            "INSERT INTO user_quotas (user_id) VALUES ($1) ON CONFLICT DO NOTHING",
            user_id,
        )
        current_usage = 0

    if current_usage + incoming_bytes > STORAGE_QUOTA_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail="Storage quota exceeded (1 GB limit)",
        )


async def increment_storage(
    conn: asyncpg.Connection,
    user_id: uuid.UUID,
    bytes_added: int,
) -> None:
    """Increment user's storage usage after successful upload.

    Uses ON CONFLICT to handle race condition where quota row might not exist yet.
    """
    await conn.execute(
        """
        INSERT INTO user_quotas (user_id, storage_bytes_used, updated_at)
        VALUES ($1, $2, now())
        ON CONFLICT (user_id) DO UPDATE
        SET storage_bytes_used = user_quotas.storage_bytes_used + $2,
            updated_at = now()
        """,
        user_id,
        bytes_added,
    )


async def create_quota_row(
    conn: asyncpg.Connection,
    user_id: uuid.UUID,
) -> None:
    """Create an initial quota row for a new user (called at registration)."""
    await conn.execute(
        "INSERT INTO user_quotas (user_id) VALUES ($1) ON CONFLICT DO NOTHING",
        user_id,
    )
