"""Shared domain constants: artifact types and processing statuses.

Used across routers, services, and the processing worker for type-safe
dispatch and validation. StrEnum values serialize naturally to/from JSON
and match the existing database string columns (no migration needed).
"""

from enum import StrEnum


class ArtifactType(StrEnum):
    """Valid artifact types."""

    SCREENSHOT = "screenshot"
    NOTE = "note"
    LINK = "link"


class ProcessingStatus(StrEnum):
    """Artifact processing lifecycle states."""

    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


# Media type mapping for file serving
ARTIFACT_MEDIA_TYPES: dict[ArtifactType, str] = {
    ArtifactType.SCREENSHOT: "image/png",
    ArtifactType.NOTE: "text/markdown",
    ArtifactType.LINK: "application/json",
}

# File extension mapping for storage
ARTIFACT_EXTENSIONS: dict[ArtifactType, str] = {
    ArtifactType.SCREENSHOT: ".png",
    ArtifactType.NOTE: ".md",
    ArtifactType.LINK: ".json",
}
