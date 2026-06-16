"""Repository for artifact persistence: all SQL lives here."""

import uuid
from datetime import UTC, datetime

import asyncpg
import structlog

from api.models.domain import ArtifactType, ProcessingStatus

logger = structlog.get_logger("api.artifact_repository")


async def create_artifact(
    conn: asyncpg.Connection,
    *,
    artifact_id: uuid.UUID,
    user_id: uuid.UUID,
    artifact_type: ArtifactType,
    storage_path: str,
    content_text: str | None,
    created_at: datetime,
) -> dict:
    """Insert a new artifact row. Returns the created record."""
    row = await conn.fetchrow(
        """
        INSERT INTO artifacts (id, user_id, type, storage_path, content_text, status, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
        RETURNING id, user_id, type, storage_path, content_text, status, attempts,
                  scheduled_after, created_at, updated_at
        """,
        artifact_id,
        user_id,
        artifact_type.value,
        storage_path,
        content_text,
        ProcessingStatus.PENDING.value,
        created_at.astimezone(UTC),
    )
    await conn.execute("SELECT pg_notify('artifact_ready', $1::text)", str(artifact_id))
    logger.info("artifact_notify_sent", artifact_id=str(artifact_id))
    return dict(row)


async def list_artifacts(
    conn: asyncpg.Connection,
    *,
    user_id: uuid.UUID,
    limit: int,
    offset: int,
) -> tuple[list[dict], int]:
    """List artifacts for a user, paginated, newest first. Returns (rows, total)."""
    rows = await conn.fetch(
        """
        SELECT id, type, storage_path, content_text, status, created_at, updated_at
        FROM artifacts
        WHERE user_id = $1
        ORDER BY created_at DESC
        LIMIT $2 OFFSET $3
        """,
        user_id,
        limit,
        offset,
    )
    total = await conn.fetchval(
        "SELECT COUNT(*) FROM artifacts WHERE user_id = $1",
        user_id,
    )
    return [dict(r) for r in rows], total


async def list_artifacts_since(
    conn: asyncpg.Connection,
    *,
    user_id: uuid.UUID,
    since: datetime,
    limit: int,
    offset: int,
) -> tuple[list[dict], int]:
    """List artifacts modified after a timestamp (delta sync). Returns (rows, total)."""
    rows = await conn.fetch(
        """
        SELECT id, type, storage_path, content_text, status, created_at, updated_at
        FROM artifacts
        WHERE user_id = $1 AND updated_at > $2
        ORDER BY updated_at ASC
        LIMIT $3 OFFSET $4
        """,
        user_id,
        since,
        limit,
        offset,
    )
    total = await conn.fetchval(
        "SELECT COUNT(*) FROM artifacts WHERE user_id = $1 AND updated_at > $2",
        user_id,
        since,
    )
    return [dict(r) for r in rows], total


async def get_storage_path(
    conn: asyncpg.Connection,
    *,
    artifact_id: uuid.UUID,
    user_id: uuid.UUID,
) -> tuple[str, str] | None:
    """Get storage_path and type for an artifact. Returns None if not found."""
    row = await conn.fetchrow(
        "SELECT storage_path, type FROM artifacts WHERE id = $1 AND user_id = $2",
        artifact_id,
        user_id,
    )
    return (row["storage_path"], row["type"]) if row else None


async def retry_artifact(
    conn: asyncpg.Connection,
    *,
    artifact_id: uuid.UUID,
    user_id: uuid.UUID,
) -> dict | None:
    """Reset a failed artifact to pending for reprocessing. Returns updated row or None."""
    row = await conn.fetchrow(
        """
        UPDATE artifacts
        SET status = $3, attempts = 0, scheduled_after = NULL, updated_at = now()
        WHERE id = $1 AND user_id = $2 AND status = $4
        RETURNING id, type, status, created_at, updated_at
        """,
        artifact_id,
        user_id,
        ProcessingStatus.PENDING.value,
        ProcessingStatus.FAILED.value,
    )
    return dict(row) if row else None


async def artifact_exists(
    conn: asyncpg.Connection,
    *,
    artifact_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    """Check if an artifact exists for a user."""
    return await conn.fetchval(
        "SELECT EXISTS(SELECT 1 FROM artifacts WHERE id = $1 AND user_id = $2)",
        artifact_id,
        user_id,
    )
