"""Tests for worker_main: standalone worker entrypoint."""

import asyncio
import signal
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from api.processing.worker import ProcessingWorker


class TestWorkerCurrentArtifactId:
    """Test the current_artifact_id property for graceful shutdown."""

    def test_initially_none(self) -> None:
        """Worker starts with no current artifact."""
        pool = MagicMock()
        settings = MagicMock()
        settings.processing_poll_interval_seconds = 5
        tagger = MagicMock()
        embedder = MagicMock()

        worker = ProcessingWorker(
            pool=pool, settings=settings, tagger=tagger, embedder=embedder
        )
        assert worker.current_artifact_id is None

    @pytest.mark.asyncio
    async def test_tracks_artifact_during_processing(self) -> None:
        """current_artifact_id is set during processing and cleared after."""
        pool = MagicMock()
        mock_conn = AsyncMock()
        pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        pool.acquire.return_value.__aexit__ = AsyncMock(return_value=None)

        settings = MagicMock()
        settings.processing_poll_interval_seconds = 5
        settings.max_processing_attempts = 3
        settings.artifacts_path = "/tmp"

        tagger = MagicMock()
        tagger.tag_text = AsyncMock(return_value=["test"])
        embedder = MagicMock()
        embedder.embed = AsyncMock(return_value=[0.1] * 1024)
        embedder.model_name = "test-model"

        worker = ProcessingWorker(
            pool=pool, settings=settings, tagger=tagger, embedder=embedder
        )

        artifact_id = uuid.uuid4()
        artifact = {
            "id": artifact_id,
            "user_id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/note.md",
            "content_text": "test content",
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        # Track artifact_id during processing
        captured_ids: list[uuid.UUID | None] = []
        original_generate = worker._generate_tags_and_embedding

        async def track_and_generate(art):
            captured_ids.append(worker.current_artifact_id)
            return ["tag1"], [0.1] * 1024

        worker._generate_tags_and_embedding = track_and_generate
        mock_conn.execute = AsyncMock()
        mock_conn.transaction = MagicMock(return_value=AsyncMock(
            __aenter__=AsyncMock(), __aexit__=AsyncMock(return_value=None)
        ))

        await worker._process_artifact(mock_record)

        # During processing, artifact_id should have been set
        assert captured_ids == [artifact_id]
        # After processing, it should be cleared
        assert worker.current_artifact_id is None

    @pytest.mark.asyncio
    async def test_cleared_on_failure(self) -> None:
        """current_artifact_id is cleared even when processing fails."""
        pool = MagicMock()
        mock_conn = AsyncMock()
        pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        pool.acquire.return_value.__aexit__ = AsyncMock(return_value=None)

        settings = MagicMock()
        settings.processing_poll_interval_seconds = 5
        settings.max_processing_attempts = 3

        tagger = MagicMock()
        embedder = MagicMock()

        worker = ProcessingWorker(
            pool=pool, settings=settings, tagger=tagger, embedder=embedder
        )

        artifact_id = uuid.uuid4()
        artifact = {
            "id": artifact_id,
            "user_id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/note.md",
            "content_text": "",
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]
        mock_conn.execute = AsyncMock()

        # Process will fail due to empty content_text
        await worker._process_artifact(mock_record)

        # Should be cleared even after failure
        assert worker.current_artifact_id is None


class TestWorkerMainExitsWithoutKey:
    """Test that worker exits if NVIDIA_API_KEY is unset."""

    @pytest.mark.asyncio
    async def test_exits_without_nvidia_key(self) -> None:
        """Worker exits with code 1 if NVIDIA_API_KEY is unset."""
        from api.worker_main import run_worker

        with patch("api.worker_main.get_settings") as mock_settings:
            settings = MagicMock()
            settings.nvidia_api_key = None
            mock_settings.return_value = settings

            with pytest.raises(SystemExit) as exc_info:
                await run_worker()

            assert exc_info.value.code == 1


class TestPgNotifyOnCreate:
    """Test that pg_notify is called after artifact creation."""

    @pytest.mark.asyncio
    async def test_pg_notify_called_after_insert(self) -> None:
        """create_artifact sends pg_notify with the artifact ID."""
        from datetime import UTC, datetime

        from api.models.domain import ArtifactType
        from api.services.artifact_repository import create_artifact

        mock_conn = AsyncMock()
        artifact_id = uuid.uuid4()
        mock_conn.fetchrow.return_value = {
            "id": artifact_id,
            "user_id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/note.md",
            "content_text": "test",
            "status": "pending",
            "attempts": 0,
            "scheduled_after": None,
            "created_at": datetime.now(UTC),
            "updated_at": datetime.now(UTC),
        }

        await create_artifact(
            mock_conn,
            artifact_id=artifact_id,
            user_id=uuid.uuid4(),
            artifact_type=ArtifactType.NOTE,
            storage_path="test/note.md",
            content_text="test content",
            created_at=datetime.now(UTC),
        )

        # Verify pg_notify was called
        assert mock_conn.execute.call_count == 1
        notify_sql = mock_conn.execute.call_args[0][0]
        notify_arg = mock_conn.execute.call_args[0][1]
        assert "pg_notify" in notify_sql
        assert "artifact_ready" in notify_sql
        assert notify_arg == str(artifact_id)


class TestScopedRecovery:
    """Test that recovery only resets artifacts stuck > 5 minutes."""

    @pytest.mark.asyncio
    async def test_recovery_includes_time_condition(self) -> None:
        """Recovery SQL includes the 5-minute threshold."""
        pool = MagicMock()
        mock_conn = AsyncMock()
        pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        pool.acquire.return_value.__aexit__ = AsyncMock(return_value=None)
        mock_conn.fetch.return_value = []

        settings = MagicMock()
        settings.processing_poll_interval_seconds = 5
        tagger = MagicMock()
        embedder = MagicMock()

        worker = ProcessingWorker(
            pool=pool, settings=settings, tagger=tagger, embedder=embedder
        )

        await worker._recover_stuck_artifacts()

        mock_conn.fetch.assert_called_once()
        sql = mock_conn.fetch.call_args[0][0]
        assert "interval '5 minutes'" in sql
        assert "updated_at <" in sql

    @pytest.mark.asyncio
    async def test_recovery_logs_count(self) -> None:
        """Recovery logs the count of reset artifacts."""
        pool = MagicMock()
        mock_conn = AsyncMock()
        pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        pool.acquire.return_value.__aexit__ = AsyncMock(return_value=None)

        # Simulate 3 artifacts being reset
        mock_conn.fetch.return_value = [
            {"id": uuid.uuid4()},
            {"id": uuid.uuid4()},
            {"id": uuid.uuid4()},
        ]

        settings = MagicMock()
        settings.processing_poll_interval_seconds = 5
        tagger = MagicMock()
        embedder = MagicMock()

        worker = ProcessingWorker(
            pool=pool, settings=settings, tagger=tagger, embedder=embedder
        )

        with patch("api.processing.worker.logger") as mock_logger:
            await worker._recover_stuck_artifacts()
            mock_logger.info.assert_called_with("worker_recovery_complete", reset_count=3)
