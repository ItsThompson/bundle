"""Artifact service: file storage, DB operations, processing notification."""

import uuid
from datetime import UTC, datetime
from pathlib import Path

import asyncpg
import structlog

from api.config import Settings
from api.models.domain import ARTIFACT_EXTENSIONS, ArtifactType, ProcessingStatus

logger = structlog.get_logger("api.artifact_service")


async def create_artifact(
    pool: asyncpg.Pool,
    settings: Settings,
    user_id: uuid.UUID,
    artifact_type: ArtifactType,
    file_content: bytes,
    created_at: datetime,
    content_text: str | None = None,
) -> dict:
    """Save artifact file to disk and create DB row.

    For notes, the file content is stored in content_text for full-text search.
    For links, content_text is the URL string passed explicitly.
    Returns the artifact record as a dict.
    """
    artifact_id = uuid.uuid4()
    date_str = created_at.strftime("%Y/%m/%d")
    file_ext = ARTIFACT_EXTENSIONS[artifact_type]
    relative_path = f"{user_id}/{date_str}/{artifact_id}{file_ext}"
    full_path = Path(settings.artifacts_path) / relative_path

    # Ensure directory exists
    full_path.parent.mkdir(parents=True, exist_ok=True)

    # Write file to disk
    full_path.write_bytes(file_content)
    logger.info(
        "artifact_file_saved",
        artifact_id=str(artifact_id),
        path=str(relative_path),
        size_bytes=len(file_content),
    )

    # Determine content_text: explicit value takes precedence,
    # otherwise extract from file content for notes
    if content_text is None and artifact_type == ArtifactType.NOTE:
        content_text = file_content.decode("utf-8", errors="replace")

    # Insert DB row
    async with pool.acquire() as conn:
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
            relative_path,
            content_text,
            ProcessingStatus.PENDING.value,
            created_at.astimezone(UTC),
        )

    logger.info("artifact_created", artifact_id=str(artifact_id), type=artifact_type)
    return dict(row)
