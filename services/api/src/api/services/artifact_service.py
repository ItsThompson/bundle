"""Artifact service: file storage and upload orchestration."""

import uuid
from datetime import datetime
from pathlib import Path

import asyncpg
import structlog
from fastapi import HTTPException, UploadFile, status

from api.config import Settings
from api.models.domain import ARTIFACT_EXTENSIONS, ArtifactType
from api.services import artifact_repository

logger = structlog.get_logger("api.artifact_service")

MAX_FILE_SIZE = 10 * 1024 * 1024  # 10 MB
CHUNK_SIZE = 64 * 1024  # 64 KB
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


async def read_upload(file: UploadFile, artifact_type: ArtifactType | None = None) -> bytes:
    """Read and validate uploaded file content with streaming size check.

    Never loads more than MAX_FILE_SIZE into memory.
    Validates PNG magic bytes for screenshot uploads.

    Raises HTTPException on oversized, empty, or invalid files.
    """
    chunks: list[bytes] = []
    total_bytes = 0

    while True:
        chunk = await file.read(CHUNK_SIZE)
        if not chunk:
            break
        total_bytes += len(chunk)
        if total_bytes > MAX_FILE_SIZE:
            raise HTTPException(
                status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                detail=f"File too large. Maximum size is {MAX_FILE_SIZE // (1024 * 1024)} MB",
            )
        chunks.append(chunk)

    content = b"".join(chunks)

    if not content:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="File must not be empty",
        )

    # Validate PNG magic bytes for screenshots
    if artifact_type == ArtifactType.SCREENSHOT and not content.startswith(PNG_MAGIC):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Screenshot must be a valid PNG file",
        )

    return content


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

    full_path.parent.mkdir(parents=True, exist_ok=True)
    full_path.write_bytes(file_content)
    logger.info("artifact_file_saved", artifact_id=str(artifact_id), path=str(relative_path), size_bytes=len(file_content))

    # Determine content_text: explicit value takes precedence,
    # otherwise extract from file content for notes
    if content_text is None and artifact_type == ArtifactType.NOTE:
        content_text = file_content.decode("utf-8", errors="replace")

    async with pool.acquire() as conn:
        row = await artifact_repository.create_artifact(
            conn,
            artifact_id=artifact_id,
            user_id=user_id,
            artifact_type=artifact_type,
            storage_path=relative_path,
            content_text=content_text,
            created_at=created_at,
        )

    logger.info("artifact_created", artifact_id=str(artifact_id), type=artifact_type)
    return row
