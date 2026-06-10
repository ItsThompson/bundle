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


class SearchResultResponse(BaseModel):
    """A single search result with relevance scores."""

    id: UUID
    type: str
    content_text: str | None = None
    status: str
    created_at: datetime
    updated_at: datetime
    tags: list[str] = []
    text_rank: float = 0.0
    vector_similarity: float = 0.0


class SearchResponse(BaseModel):
    """Search results from hybrid search."""

    items: list[SearchResultResponse]
    query: str
    total: int


class TagWithCountResponse(BaseModel):
    """A tag name with its usage count."""

    name: str
    count: int
