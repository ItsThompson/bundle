"""Artifact request schemas."""

from datetime import datetime

from pydantic import BaseModel, Field


class ArtifactUploadMetadata(BaseModel):
    """Metadata sent alongside file upload."""

    type: str = Field(pattern=r"^(screenshot|note|link)$")
    created_at: datetime
