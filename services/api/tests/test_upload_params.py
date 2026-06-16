"""Tests for ArtifactUploadParams validation model."""

from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from api.models.domain import ArtifactType
from api.models.requests import ArtifactUploadParams


class TestArtifactUploadParams:
    """Tests for ArtifactUploadParams Pydantic model."""

    def test_valid_screenshot(self) -> None:
        """Valid screenshot params should pass validation."""
        params = ArtifactUploadParams(
            type=ArtifactType.SCREENSHOT,
            content_text=None,
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert params.type == ArtifactType.SCREENSHOT
        assert params.content_text is None

    def test_valid_note(self) -> None:
        """Valid note params with content_text should pass."""
        params = ArtifactUploadParams(
            type=ArtifactType.NOTE,
            content_text="Some note content",
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert params.content_text == "Some note content"

    def test_valid_link(self) -> None:
        """Valid link with http URL should pass."""
        params = ArtifactUploadParams(
            type=ArtifactType.LINK,
            content_text="https://example.com/page",
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert params.content_text == "https://example.com/page"

    def test_link_http_scheme_valid(self) -> None:
        """Link with http:// scheme should pass."""
        params = ArtifactUploadParams(
            type=ArtifactType.LINK,
            content_text="http://example.com",
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert params.content_text == "http://example.com"

    def test_link_ftp_scheme_rejected(self) -> None:
        """Link with ftp:// scheme should be rejected."""
        with pytest.raises(ValidationError, match="http or https"):
            ArtifactUploadParams(
                type=ArtifactType.LINK,
                content_text="ftp://files.example.com/doc.pdf",
                created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
            )

    def test_link_file_scheme_rejected(self) -> None:
        """Link with file:// scheme should be rejected."""
        with pytest.raises(ValidationError, match="http or https"):
            ArtifactUploadParams(
                type=ArtifactType.LINK,
                content_text="file:///etc/passwd",
                created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
            )

    def test_link_gopher_scheme_rejected(self) -> None:
        """Link with gopher:// scheme should be rejected."""
        with pytest.raises(ValidationError, match="http or https"):
            ArtifactUploadParams(
                type=ArtifactType.LINK,
                content_text="gopher://example.com/resource",
                created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
            )

    def test_link_url_too_long(self) -> None:
        """Link with URL > 2048 chars should be rejected."""
        long_url = "https://example.com/" + "a" * 2030
        assert len(long_url) > 2048
        with pytest.raises(ValidationError, match="2048"):
            ArtifactUploadParams(
                type=ArtifactType.LINK,
                content_text=long_url,
                created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
            )

    def test_link_url_exactly_2048_chars(self) -> None:
        """Link with URL exactly 2048 chars should pass."""
        url = "https://example.com/" + "a" * (2048 - len("https://example.com/"))
        assert len(url) == 2048
        params = ArtifactUploadParams(
            type=ArtifactType.LINK,
            content_text=url,
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert len(params.content_text) == 2048

    def test_content_text_max_length(self) -> None:
        """content_text exceeding 50,000 chars should be rejected."""
        long_text = "x" * 50_001
        with pytest.raises(ValidationError, match="50000"):
            ArtifactUploadParams(
                type=ArtifactType.NOTE,
                content_text=long_text,
                created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
            )

    def test_content_text_at_limit(self) -> None:
        """content_text at exactly 50,000 chars should pass."""
        text = "x" * 50_000
        params = ArtifactUploadParams(
            type=ArtifactType.NOTE,
            content_text=text,
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert len(params.content_text) == 50_000

    def test_invalid_type_rejected(self) -> None:
        """Invalid artifact type should be rejected."""
        with pytest.raises(ValidationError):
            ArtifactUploadParams(
                type="video",  # type: ignore[arg-type]
                content_text=None,
                created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
            )

    def test_url_validation_only_for_links(self) -> None:
        """URL validation should not apply to non-link types."""
        # A note with ftp:// in content_text should be fine
        params = ArtifactUploadParams(
            type=ArtifactType.NOTE,
            content_text="ftp://not-a-link-just-text",
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert params.content_text == "ftp://not-a-link-just-text"

    def test_link_with_none_content_text(self) -> None:
        """Link with None content_text should pass (no URL to validate)."""
        params = ArtifactUploadParams(
            type=ArtifactType.LINK,
            content_text=None,
            created_at=datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC),
        )
        assert params.content_text is None
