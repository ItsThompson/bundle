"""Artifact response schemas."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class ArtifactResponse(BaseModel):
    """Response for a single artifact (upload response)."""

    id: UUID
    type: str
    status: str
    created_at: datetime
    updated_at: datetime


class ArtifactWithTagsResponse(BaseModel):
    """Response for an artifact including tags (list response)."""

    id: UUID
    type: str
    content_text: str | None = None
    status: str
    created_at: datetime
    updated_at: datetime
    tags: list[str] = []


class ArtifactListResponse(BaseModel):
    """Paginated list of artifacts."""

    items: list[ArtifactWithTagsResponse]
    total: int
    limit: int
    offset: int
