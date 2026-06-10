"""Artifacts router: upload, list, and manage artifacts."""

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

from api.dependencies import get_pool
from api.middleware.auth import CurrentUser, get_current_user
from api.models.artifact_responses import (
    ArtifactListResponse,
    ArtifactResponse,
    ArtifactWithTagsResponse,
    SearchResponse,
    SearchResultResponse,
)
from api.services import artifact_service, processing_service, search_service

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
    content_text: Annotated[str | None, Form()] = None,
) -> ArtifactResponse:
    """Upload a new artifact (multipart: file + type + created_at).

    Returns 201 with artifact id and status on success.
    Requires authentication (returns 401 without valid token).
    """
    settings = request.app.state.settings

    # Validate type
    if type not in ("screenshot", "note", "link"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="type must be one of: screenshot, note, link",
        )

    # Parse created_at timestamp
    try:
        parsed_created_at = datetime.fromisoformat(created_at)
        if parsed_created_at.tzinfo is None:
            parsed_created_at = parsed_created_at.replace(tzinfo=UTC)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="created_at must be a valid ISO 8601 timestamp",
        ) from None

    # Reject early if Content-Length header indicates file is too large
    if file.size is not None and file.size > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File too large. Maximum size is {MAX_FILE_SIZE // (1024 * 1024)} MB",
        )

    # Read file content with size limit
    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File too large. Maximum size is {MAX_FILE_SIZE // (1024 * 1024)} MB",
        )

    if len(content) == 0:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="File must not be empty",
        )

    # Create artifact (save file + insert DB row)
    artifact = await artifact_service.create_artifact(
        pool=pool,
        settings=settings,
        user_id=current_user.id,
        artifact_type=type,
        file_content=content,
        content_text=content_text,
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


@router.get("/search", response_model=SearchResponse)
async def search_artifacts(
    q: Annotated[str, Query(min_length=1, max_length=500)],
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    request: Request,
) -> SearchResponse:
    """Hybrid search across artifacts using BM25 full-text + vector similarity.

    Combines text ranking (0.4 weight) and embedding cosine similarity (0.6 weight).
    Searches note text, link URLs, and tag-derived content via tsvector.
    Returns up to 40 ranked results.
    """
    embedding_provider = _get_embedding_provider(request)
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

    logger.info(
        "search_request",
        user_id=str(current_user.id),
        query=q,
        result_count=len(items),
    )

    return SearchResponse(items=items, query=q, total=len(items))


@router.get("", response_model=ArtifactListResponse)
async def list_artifacts(
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
    limit: Annotated[int, Query(ge=1, le=100)] = 40,
    offset: Annotated[int, Query(ge=0)] = 0,
    updated_since: Annotated[str | None, Query()] = None,
) -> ArtifactListResponse:
    """List artifacts for the current user, paginated, newest first.

    When `updated_since` is provided (ISO 8601 timestamp), returns only
    artifacts modified after that timestamp, ordered by updated_at ASC.
    This is used by the sync mechanism for delta updates.
    """
    async with pool.acquire() as conn:
        if updated_since is not None:
            # Delta sync mode: return artifacts modified after the given timestamp
            try:
                since_dt = datetime.fromisoformat(updated_since)
                if since_dt.tzinfo is None:
                    since_dt = since_dt.replace(tzinfo=UTC)
            except ValueError:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                    detail="updated_since must be a valid ISO 8601 timestamp",
                ) from None

            rows = await conn.fetch(
                """
                SELECT a.id, a.type, a.storage_path, a.content_text, a.status,
                       a.created_at, a.updated_at
                FROM artifacts a
                WHERE a.user_id = $1 AND a.updated_at > $2
                ORDER BY a.updated_at ASC
                LIMIT $3 OFFSET $4
                """,
                current_user.id,
                since_dt,
                limit,
                offset,
            )

            total = await conn.fetchval(
                "SELECT COUNT(*) FROM artifacts WHERE user_id = $1 AND updated_at > $2",
                current_user.id,
                since_dt,
            )
        else:
            # Standard list mode: paginated, newest first
            rows = await conn.fetch(
                """
                SELECT a.id, a.type, a.storage_path, a.content_text, a.status,
                       a.created_at, a.updated_at
                FROM artifacts a
                WHERE a.user_id = $1
                ORDER BY a.created_at DESC
                LIMIT $2 OFFSET $3
                """,
                current_user.id,
                limit,
                offset,
            )

            total = await conn.fetchval(
                "SELECT COUNT(*) FROM artifacts WHERE user_id = $1",
                current_user.id,
            )

        # Fetch tags for all artifacts in one query
        artifact_ids = [row["id"] for row in rows]
        tag_rows = await conn.fetch(
            """
            SELECT artifact_id, name
            FROM artifact_tags
            WHERE artifact_id = ANY($1::uuid[])
            """,
            artifact_ids,
        ) if artifact_ids else []

    # Group tags by artifact ID
    tags_by_artifact: dict[UUID, list[str]] = {}
    for tag_row in tag_rows:
        aid = tag_row["artifact_id"]
        tags_by_artifact.setdefault(aid, []).append(tag_row["name"])

    items = [
        ArtifactWithTagsResponse(
            id=row["id"],
            type=row["type"],
            content_text=row["content_text"],
            status=row["status"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            tags=tags_by_artifact.get(row["id"], []),
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
    """Serve the file content for a specific artifact.

    Returns the raw file (image/PNG for screenshots, text for notes, etc.).
    """
    settings = request.app.state.settings

    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT storage_path, type FROM artifacts
            WHERE id = $1 AND user_id = $2
            """,
            artifact_id,
            current_user.id,
        )

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Artifact not found",
        )

    file_path = Path(settings.artifacts_path) / row["storage_path"]
    if not file_path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Artifact file not found on disk",
        )

    media_type = _media_type_for_artifact(row["type"])
    return FileResponse(path=str(file_path), media_type=media_type)


@router.post("/{artifact_id}/retry", response_model=ArtifactResponse)
async def retry_artifact(
    artifact_id: UUID,
    current_user: Annotated[CurrentUser, Depends(get_current_user)],
    pool: Annotated[asyncpg.Pool, Depends(get_pool)],
) -> ArtifactResponse:
    """Retry processing for a failed artifact.

    Resets attempts to 0, status to 'pending', clears scheduled_after,
    and notifies the processing worker to pick it up immediately.
    """
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            UPDATE artifacts
            SET status = 'pending', attempts = 0, scheduled_after = NULL, updated_at = now()
            WHERE id = $1 AND user_id = $2 AND status = 'failed'
            RETURNING id, type, status, created_at, updated_at
            """,
            artifact_id,
            current_user.id,
        )

    if row is None:
        # Check if artifact exists at all for this user
        async with pool.acquire() as conn:
            exists = await conn.fetchval(
                "SELECT 1 FROM artifacts WHERE id = $1 AND user_id = $2",
                artifact_id,
                current_user.id,
            )
        if not exists:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Artifact not found",
            )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Artifact is not in failed state",
        )

    # Notify the processing worker to pick up the retried artifact
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


def _media_type_for_artifact(artifact_type: str) -> str:
    """Return the MIME type for serving artifact files."""
    match artifact_type:
        case "screenshot":
            return "image/png"
        case "note":
            return "text/markdown"
        case "link":
            return "application/json"
        case _:
            return "application/octet-stream"


def _get_embedding_provider(request: Request):
    """Retrieve the embedding provider from app state, or None if not configured."""
    return getattr(request.app.state, "embedding_provider", None)
