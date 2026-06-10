"""Artifact response schemas."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class ArtifactResponse(BaseModel):
    """Response for a single artifact."""

    id: UUID
    type: str
    status: str
    created_at: datetime
    updated_at: datetime
