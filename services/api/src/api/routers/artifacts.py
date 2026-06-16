"""Artifacts router: parse requests, call services, format responses."""

from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated
from uuid import UUID

import asyncpg
import structlog
from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Request,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse
from pydantic import ValidationError

from api.dependencies import get_pool
from api.middleware.auth import CurrentUser, get_current_user
from api.models.artifact_responses import (
    ArtifactListResponse,
    ArtifactResponse,
    ArtifactWithTagsResponse,
    SearchResponse,
    SearchResultResponse,
)
from api.models.domain import ARTIFACT_MEDIA_TYPES, ArtifactType
from api.models.requests import ArtifactUploadParams
from api.services import (
    artifact_repository,
    artifact_service,
    processing_service,
    search_service,
    tag_repository,
)

router = APIRouter(prefix="/api/v1/artifacts", tags=["artifacts"])
logger = structlog.get_logger("api.artifacts")


def _parse_type(s: str) -> ArtifactType:
    try:
        return ArtifactType(s)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="type must be one of: screenshot, note, link",
        ) from None


def _parse_ts(s: str) -> datetime:
    try:
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=UTC)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Timestamp must be a valid ISO 8601 value",
        ) from None


@router.post("", response_model=ArtifactResponse, status_code=status.HTTP_201_CREATED)
async def upload_artifact(
    file: Annotated[UploadFile, File()],
    type: Annotated[str, Form()],
    created_at: Annotated[str, Form()],
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
    content_text: Annotated[str | None, Form()] = None,
) -> ArtifactResponse:
    """Upload a new artifact (multipart: file + type + created_at)."""
    artifact_type = _parse_type(type)
    parsed_ts = _parse_ts(created_at)

    # Validate upload params (URL scheme/length for links, content_text length)
    try:
        params = ArtifactUploadParams(
            type=artifact_type,
            content_text=content_text,
            created_at=parsed_ts,
        )
    except ValidationError as exc:
        errors = exc.errors()
        msg = errors[0]["msg"] if errors else str(exc)
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=msg,
        ) from exc

    content = await artifact_service.read_upload(file, artifact_type=artifact_type)
    artifact = await artifact_service.create_artifact(
        pool=pool,
        settings=request.app.state.settings,
        user_id=current_user.id,
        artifact_type=artifact_type,
        file_content=content,
        content_text=params.content_text,
        created_at=parsed_ts,
    )
    processing_service.notify(artifact["id"])
    logger.info(
        "artifact_uploaded",
        artifact_id=str(artifact["id"]),
        user_id=str(current_user.id),
    )
    return ArtifactResponse(
        id=artifact["id"],
        type=artifact["type"],
        status=artifact["status"],
        created_at=artifact["created_at"],
        updated_at=artifact["updated_at"],
    )


@router.get("/search", response_model=SearchResponse)
async def search_artifacts(
    q: Annotated[str, Query(min_length=1, max_length=500)],
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> SearchResponse:
    """Hybrid search across artifacts using BM25 + vector similarity."""
    embedding_provider = getattr(request.app.state, "embedding_provider", None)
    if embedding_provider is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Search is unavailable: embedding provider not configured",
        )
    results = await search_service.hybrid_search(
        pool=pool,
        embedding_provider=embedding_provider,
        user_id=current_user.id,
        query=q,
    )
    items = [
        SearchResultResponse(
            id=r["id"],
            type=r["type"],
            content_text=r["content_text"],
            status=r["status"],
            created_at=r["created_at"],
            updated_at=r["updated_at"],
            tags=r["tags"],
            text_rank=r["text_rank"],
            vector_similarity=r["vector_similarity"],
        )
        for r in results
    ]
    return SearchResponse(items=items, query=q, total=len(items))


@router.get("", response_model=ArtifactListResponse)
async def list_artifacts(
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    limit: Annotated[int, Query(ge=1, le=100)] = 40,
    offset: Annotated[int, Query(ge=0)] = 0,
    updated_since: Annotated[str | None, Query()] = None,
) -> ArtifactListResponse:
    """List artifacts for the current user, paginated."""
    async with pool.acquire() as conn:
        if updated_since is not None:
            rows, total = await artifact_repository.list_artifacts_since(
                conn, user_id=current_user.id, since=_parse_ts(updated_since), limit=limit, offset=offset
            )
        else:
            rows, total = await artifact_repository.list_artifacts(
                conn, user_id=current_user.id, limit=limit, offset=offset
            )
        tags_map = await tag_repository.fetch_tags_for_artifacts(conn, [r["id"] for r in rows])
    items = [
        ArtifactWithTagsResponse(
            id=row["id"],
            type=row["type"],
            content_text=row["content_text"],
            status=row["status"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            tags=tags_map.get(row["id"], []),
        )
        for row in rows
    ]
    return ArtifactListResponse(items=items, total=total, limit=limit, offset=offset)


@router.get("/{artifact_id}/content")
async def get_artifact_content(
    artifact_id: UUID,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> FileResponse:
    """Serve the raw file content for an artifact."""
    async with pool.acquire() as conn:
        result = await artifact_repository.get_storage_path(
            conn, artifact_id=artifact_id, user_id=current_user.id
        )
    if result is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Artifact not found")
    storage_path, type_str = result
    file_path = Path(request.app.state.settings.artifacts_path) / storage_path
    if not file_path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Artifact file not found on disk"
        )
    return FileResponse(
        path=str(file_path),
        media_type=ARTIFACT_MEDIA_TYPES.get(ArtifactType(type_str), "application/octet-stream"),
    )


@router.post("/{artifact_id}/retry", response_model=ArtifactResponse)
async def retry_artifact(
    artifact_id: UUID,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
) -> ArtifactResponse:
    """Retry processing for a failed artifact."""
    async with pool.acquire() as conn:
        row = await artifact_repository.retry_artifact(
            conn, artifact_id=artifact_id, user_id=current_user.id
        )
        if row is None:
            exists = await artifact_repository.artifact_exists(
                conn, artifact_id=artifact_id, user_id=current_user.id
            )
    if row is None:
        if not exists:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Artifact not found")
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Artifact is not in failed state"
        )
    processing_service.notify(row["id"])
    logger.info(
        "artifact_retry_requested",
        artifact_id=str(artifact_id),
        user_id=str(current_user.id),
    )
    return ArtifactResponse(
        id=row["id"],
        type=row["type"],
        status=row["status"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )
