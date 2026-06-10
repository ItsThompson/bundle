"""Artifacts router: upload, list, and manage artifacts."""

from datetime import UTC, datetime
from typing import Annotated

import asyncpg
import structlog
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status

from api.dependencies import get_pool
from api.middleware.auth import CurrentUser, get_current_user
from api.models.artifact_responses import ArtifactResponse
from api.services import artifact_service, processing_service

router = APIRouter(prefix="/api/v1/artifacts", tags=["artifacts"])
logger = structlog.get_logger("api.artifacts")

MAX_FILE_SIZE = 50 * 1024 * 1024  # 50 MB


@router.post("", response_model=ArtifactResponse, status_code=status.HTTP_201_CREATED)
async def upload_artifact(
    file: Annotated[UploadFile, File()],
    type: Annotated[str, Form()],
    created_at: Annotated[str, Form()],
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> ArtifactResponse:
    """Upload a new artifact (multipart: file + type + created_at).

    Returns 201 with artifact id and status on success.
    Requires authentication (returns 401 without valid token).
    """
    settings = request.app.state.settings

    # Validate type
    if type not in ("screenshot", "note", "link"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="type must be one of: screenshot, note, link",
        )

    # Parse created_at timestamp
    try:
        parsed_created_at = datetime.fromisoformat(created_at)
        if parsed_created_at.tzinfo is None:
            parsed_created_at = parsed_created_at.replace(tzinfo=UTC)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="created_at must be a valid ISO 8601 timestamp",
        ) from None

    # Read file content with size limit
    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File too large. Maximum size is {MAX_FILE_SIZE // (1024 * 1024)} MB",
        )

    if len(content) == 0:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="File must not be empty",
        )

    # Create artifact (save file + insert DB row)
    artifact = await artifact_service.create_artifact(
        pool=pool,
        settings=settings,
        user_id=current_user.id,
        artifact_type=type,
        file_content=content,
        created_at=parsed_created_at,
    )

    # Fire-and-forget: notify processing worker (stub for now)
    processing_service.notify(artifact["id"])

    logger.info(
        "artifact_uploaded",
        artifact_id=str(artifact["id"]),
        user_id=str(current_user.id),
        type=type,
    )

    return ArtifactResponse(
        id=artifact["id"],
        type=artifact["type"],
        status=artifact["status"],
        created_at=artifact["created_at"],
        updated_at=artifact["updated_at"],
    )
