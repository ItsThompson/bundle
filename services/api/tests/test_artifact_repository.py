"""Unit tests for artifact_repository: mock asyncpg connection."""

import uuid
from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch

import pytest

from api.models.domain import ArtifactType, ProcessingStatus
from api.services.artifact_repository import (
    artifact_exists,
    create_artifact,
    get_storage_path,
    list_artifacts,
    list_artifacts_since,
    retry_artifact,
)


@pytest.fixture
def mock_conn() -> AsyncMock:
    """Create a mock asyncpg connection."""
    return AsyncMock()


@pytest.fixture
def user_id() -> uuid.UUID:
    """A fixed user ID for tests."""
    return uuid.uuid4()


class TestCreateArtifact:
    """Tests for create_artifact."""

    @pytest.mark.asyncio
    async def test_inserts_artifact_and_returns_dict(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """create_artifact inserts with correct params and returns row as dict."""
        now = datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC)
        expected_row = {
            "id": uuid.uuid4(),
            "user_id": user_id,
            "type": "screenshot",
            "storage_path": "some/path.png",
            "content_text": None,
            "status": "pending",
            "attempts": 0,
            "scheduled_after": None,
            "created_at": now,
            "updated_at": now,
        }
        mock_conn.fetchrow.return_value = expected_row

        result = await create_artifact(
            mock_conn,
            user_id=user_id,
            artifact_type=ArtifactType.SCREENSHOT,
            storage_path="some/path.png",
            content_text=None,
            created_at=now,
        )

        assert result == expected_row
        mock_conn.fetchrow.assert_called_once()
        call_args = mock_conn.fetchrow.call_args[0]
        # Verify SQL contains INSERT
        assert "INSERT INTO artifacts" in call_args[0]
        # Verify user_id, type value, status value are passed
        assert call_args[2] == user_id
        assert call_args[3] == "screenshot"
        assert call_args[6] == "pending"

    @pytest.mark.asyncio
    async def test_uses_enum_values_in_sql(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Enum .value is used for type and status parameters."""
        now = datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC)
        mock_conn.fetchrow.return_value = {"id": uuid.uuid4()}

        await create_artifact(
            mock_conn,
            user_id=user_id,
            artifact_type=ArtifactType.NOTE,
            storage_path="path/note.md",
            content_text="hello",
            created_at=now,
        )

        call_args = mock_conn.fetchrow.call_args[0]
        assert call_args[3] == "note"  # ArtifactType.NOTE.value
        assert call_args[6] == "pending"  # ProcessingStatus.PENDING.value

    @pytest.mark.asyncio
    async def test_generates_uuid_for_artifact_id(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """create_artifact generates a new UUID for the artifact."""
        now = datetime(2026, 6, 10, 12, 0, 0, tzinfo=UTC)
        mock_conn.fetchrow.return_value = {"id": uuid.uuid4()}

        with patch("api.services.artifact_repository.uuid.uuid4") as mock_uuid:
            fixed_id = uuid.uuid4()
            mock_uuid.return_value = fixed_id

            await create_artifact(
                mock_conn,
                user_id=user_id,
                artifact_type=ArtifactType.LINK,
                storage_path="path/link.json",
                content_text="https://example.com",
                created_at=now,
            )

            call_args = mock_conn.fetchrow.call_args[0]
            assert call_args[1] == fixed_id


class TestListArtifacts:
    """Tests for list_artifacts."""

    @pytest.mark.asyncio
    async def test_returns_rows_and_total(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """list_artifacts returns (rows, total) tuple."""
        mock_rows = [
            {"id": uuid.uuid4(), "type": "note", "status": "completed"},
            {"id": uuid.uuid4(), "type": "screenshot", "status": "pending"},
        ]
        mock_conn.fetch.return_value = mock_rows
        mock_conn.fetchval.return_value = 5

        rows, total = await list_artifacts(
            mock_conn, user_id=user_id, limit=10, offset=0
        )

        assert len(rows) == 2
        assert total == 5
        assert rows[0]["type"] == "note"

    @pytest.mark.asyncio
    async def test_passes_pagination_params(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Limit and offset are passed to the query."""
        mock_conn.fetch.return_value = []
        mock_conn.fetchval.return_value = 0

        await list_artifacts(mock_conn, user_id=user_id, limit=20, offset=5)

        call_args = mock_conn.fetch.call_args[0]
        assert call_args[1] == user_id
        assert call_args[2] == 20
        assert call_args[3] == 5


class TestListArtifactsSince:
    """Tests for list_artifacts_since."""

    @pytest.mark.asyncio
    async def test_returns_rows_and_total(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """list_artifacts_since filters by timestamp."""
        since = datetime(2026, 6, 1, 0, 0, 0, tzinfo=UTC)
        mock_conn.fetch.return_value = [{"id": uuid.uuid4()}]
        mock_conn.fetchval.return_value = 1

        rows, total = await list_artifacts_since(
            mock_conn, user_id=user_id, since=since, limit=40, offset=0
        )

        assert len(rows) == 1
        assert total == 1

    @pytest.mark.asyncio
    async def test_passes_since_timestamp(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """The since datetime is passed to the query."""
        since = datetime(2026, 6, 5, 10, 0, 0, tzinfo=UTC)
        mock_conn.fetch.return_value = []
        mock_conn.fetchval.return_value = 0

        await list_artifacts_since(
            mock_conn, user_id=user_id, since=since, limit=40, offset=0
        )

        call_args = mock_conn.fetch.call_args[0]
        assert call_args[2] == since


class TestGetStoragePath:
    """Tests for get_storage_path."""

    @pytest.mark.asyncio
    async def test_returns_path_and_type_when_found(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns (storage_path, type) tuple when artifact exists."""
        aid = uuid.uuid4()
        mock_conn.fetchrow.return_value = {
            "storage_path": "user/2026/06/10/abc.png",
            "type": "screenshot",
        }

        result = await get_storage_path(
            mock_conn, artifact_id=aid, user_id=user_id
        )

        assert result == ("user/2026/06/10/abc.png", "screenshot")

    @pytest.mark.asyncio
    async def test_returns_none_when_not_found(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns None when artifact does not exist."""
        mock_conn.fetchrow.return_value = None

        result = await get_storage_path(
            mock_conn, artifact_id=uuid.uuid4(), user_id=user_id
        )

        assert result is None


class TestRetryArtifact:
    """Tests for retry_artifact."""

    @pytest.mark.asyncio
    async def test_returns_updated_row_on_success(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """retry_artifact returns the updated row when successful."""
        aid = uuid.uuid4()
        now = datetime.now(UTC)
        mock_conn.fetchrow.return_value = {
            "id": aid,
            "type": "note",
            "status": "pending",
            "created_at": now,
            "updated_at": now,
        }

        result = await retry_artifact(
            mock_conn, artifact_id=aid, user_id=user_id
        )

        assert result is not None
        assert result["status"] == "pending"

    @pytest.mark.asyncio
    async def test_returns_none_when_not_failed(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """retry_artifact returns None when artifact is not in failed state."""
        mock_conn.fetchrow.return_value = None

        result = await retry_artifact(
            mock_conn, artifact_id=uuid.uuid4(), user_id=user_id
        )

        assert result is None

    @pytest.mark.asyncio
    async def test_uses_enum_values_for_status(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Uses ProcessingStatus enum values in the UPDATE query."""
        mock_conn.fetchrow.return_value = None

        await retry_artifact(
            mock_conn, artifact_id=uuid.uuid4(), user_id=user_id
        )

        call_args = mock_conn.fetchrow.call_args[0]
        assert ProcessingStatus.PENDING.value in call_args
        assert ProcessingStatus.FAILED.value in call_args


class TestArtifactExists:
    """Tests for artifact_exists."""

    @pytest.mark.asyncio
    async def test_returns_true_when_exists(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns True when artifact exists for user."""
        mock_conn.fetchval.return_value = True

        result = await artifact_exists(
            mock_conn, artifact_id=uuid.uuid4(), user_id=user_id
        )

        assert result is True

    @pytest.mark.asyncio
    async def test_returns_false_when_not_exists(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns False when artifact does not exist."""
        mock_conn.fetchval.return_value = False

        result = await artifact_exists(
            mock_conn, artifact_id=uuid.uuid4(), user_id=user_id
        )

        assert result is False
