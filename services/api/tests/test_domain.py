"""Tests for api.models.domain module."""

from api.models.domain import (
    ARTIFACT_EXTENSIONS,
    ARTIFACT_MEDIA_TYPES,
    ArtifactType,
    ProcessingStatus,
)


class TestArtifactType:
    """Tests for ArtifactType enum."""

    def test_values(self) -> None:
        """ArtifactType should have exactly three values."""
        assert ArtifactType.SCREENSHOT == "screenshot"
        assert ArtifactType.NOTE == "note"
        assert ArtifactType.LINK == "link"
        assert len(ArtifactType) == 3

    def test_str_serialization(self) -> None:
        """StrEnum values should serialize to plain strings."""
        assert str(ArtifactType.SCREENSHOT) == "screenshot"
        assert f"{ArtifactType.NOTE}" == "note"

    def test_construction_from_string(self) -> None:
        """StrEnum should construct from matching string values."""
        assert ArtifactType("screenshot") is ArtifactType.SCREENSHOT
        assert ArtifactType("note") is ArtifactType.NOTE
        assert ArtifactType("link") is ArtifactType.LINK

    def test_invalid_value_raises(self) -> None:
        """StrEnum should raise ValueError for unknown values."""
        import pytest

        with pytest.raises(ValueError, match="'invalid' is not a valid ArtifactType"):
            ArtifactType("invalid")


class TestProcessingStatus:
    """Tests for ProcessingStatus enum."""

    def test_values(self) -> None:
        """ProcessingStatus should have exactly four values."""
        assert ProcessingStatus.PENDING == "pending"
        assert ProcessingStatus.PROCESSING == "processing"
        assert ProcessingStatus.COMPLETED == "completed"
        assert ProcessingStatus.FAILED == "failed"
        assert len(ProcessingStatus) == 4

    def test_str_serialization(self) -> None:
        """StrEnum values should serialize to plain strings."""
        assert str(ProcessingStatus.PENDING) == "pending"

    def test_construction_from_string(self) -> None:
        """StrEnum should construct from matching string values."""
        assert ProcessingStatus("pending") is ProcessingStatus.PENDING
        assert ProcessingStatus("failed") is ProcessingStatus.FAILED


class TestArtifactMediaTypes:
    """Tests for ARTIFACT_MEDIA_TYPES mapping."""

    def test_all_types_covered(self) -> None:
        """Every ArtifactType must have a media type mapping."""
        for artifact_type in ArtifactType:
            assert artifact_type in ARTIFACT_MEDIA_TYPES

    def test_values(self) -> None:
        """Media types should be correct MIME types."""
        assert ARTIFACT_MEDIA_TYPES[ArtifactType.SCREENSHOT] == "image/png"
        assert ARTIFACT_MEDIA_TYPES[ArtifactType.NOTE] == "text/markdown"
        assert ARTIFACT_MEDIA_TYPES[ArtifactType.LINK] == "application/json"


class TestArtifactExtensions:
    """Tests for ARTIFACT_EXTENSIONS mapping."""

    def test_all_types_covered(self) -> None:
        """Every ArtifactType must have an extension mapping."""
        for artifact_type in ArtifactType:
            assert artifact_type in ARTIFACT_EXTENSIONS

    def test_values(self) -> None:
        """Extensions should start with a dot."""
        assert ARTIFACT_EXTENSIONS[ArtifactType.SCREENSHOT] == ".png"
        assert ARTIFACT_EXTENSIONS[ArtifactType.NOTE] == ".md"
        assert ARTIFACT_EXTENSIONS[ArtifactType.LINK] == ".json"
