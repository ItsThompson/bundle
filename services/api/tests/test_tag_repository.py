"""Unit tests for tag_repository: mock asyncpg connection."""

import uuid
from unittest.mock import AsyncMock

import pytest

from api.services.tag_repository import fetch_tags_for_artifacts


@pytest.fixture
def mock_conn() -> AsyncMock:
    """Create a mock asyncpg connection."""
    return AsyncMock()


class TestFetchTagsForArtifacts:
    """Tests for fetch_tags_for_artifacts."""

    @pytest.mark.asyncio
    async def test_empty_ids_returns_empty_dict(self, mock_conn: AsyncMock) -> None:
        """No artifact IDs means no DB call, empty dict returned."""
        result = await fetch_tags_for_artifacts(mock_conn, [])
        assert result == {}
        mock_conn.fetch.assert_not_called()

    @pytest.mark.asyncio
    async def test_single_artifact_with_tags(self, mock_conn: AsyncMock) -> None:
        """Returns tags grouped by artifact ID for a single artifact."""
        aid = uuid.uuid4()
        mock_conn.fetch.return_value = [
            {"artifact_id": aid, "name": "python"},
            {"artifact_id": aid, "name": "code"},
        ]

        result = await fetch_tags_for_artifacts(mock_conn, [aid])

        assert result == {aid: ["python", "code"]}
        mock_conn.fetch.assert_called_once()

    @pytest.mark.asyncio
    async def test_multiple_artifacts_grouped(self, mock_conn: AsyncMock) -> None:
        """Tags from multiple artifacts are correctly grouped."""
        aid1 = uuid.uuid4()
        aid2 = uuid.uuid4()
        mock_conn.fetch.return_value = [
            {"artifact_id": aid1, "name": "design"},
            {"artifact_id": aid2, "name": "meeting"},
            {"artifact_id": aid2, "name": "notes"},
        ]

        result = await fetch_tags_for_artifacts(mock_conn, [aid1, aid2])

        assert result == {aid1: ["design"], aid2: ["meeting", "notes"]}

    @pytest.mark.asyncio
    async def test_artifact_with_no_tags_absent_from_dict(
        self, mock_conn: AsyncMock
    ) -> None:
        """Artifacts that have no tags don't appear in the returned dict."""
        aid = uuid.uuid4()
        mock_conn.fetch.return_value = []

        result = await fetch_tags_for_artifacts(mock_conn, [aid])

        assert result == {}

    @pytest.mark.asyncio
    async def test_passes_ids_as_parameter(self, mock_conn: AsyncMock) -> None:
        """Verifies the artifact IDs are passed to the SQL query."""
        aid1 = uuid.uuid4()
        aid2 = uuid.uuid4()
        mock_conn.fetch.return_value = []

        await fetch_tags_for_artifacts(mock_conn, [aid1, aid2])

        call_args = mock_conn.fetch.call_args
        assert [aid1, aid2] == call_args[0][1]
