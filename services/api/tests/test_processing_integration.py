"""Integration test for the full processing pipeline with real DB."""

import asyncio
import io
import uuid
from pathlib import Path
from unittest.mock import AsyncMock

import asyncpg
import pytest
from api.config import Settings
from api.processing.embedder import Embedder
from api.processing.tagger import Tagger
from api.processing.worker import ProcessingWorker
from PIL import Image

TEST_DATABASE_URL = "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"


def _make_png(width: int = 200, height: int = 150) -> bytes:
    """Create a minimal valid PNG image."""
    img = Image.new("RGB", (width, height), color="blue")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


@pytest.fixture
def mock_llm() -> AsyncMock:
    """Mock LLM provider that returns valid tag JSON."""
    provider = AsyncMock()
    provider.complete.return_value = '["design", "ui-pattern", "mobile", "dark-mode"]'
    return provider


@pytest.fixture
def mock_embeddings() -> AsyncMock:
    """Mock embedding provider that returns 1024-dim vector."""
    provider = AsyncMock()
    provider.embed.return_value = [0.01 * i for i in range(1024)]
    provider.dimensions = 1024
    provider.model = "nvidia/nv-embedqa-e5-v5"
    return provider


@pytest.mark.asyncio
class TestProcessingIntegration:
    """Integration tests that exercise the full pipeline with a real PostgreSQL DB."""

    async def _create_pool(self) -> asyncpg.Pool:
        """Create a connection pool for the test database."""
        return await asyncpg.create_pool(dsn=TEST_DATABASE_URL, min_size=1, max_size=3)

    async def _insert_user(self, pool: asyncpg.Pool) -> uuid.UUID:
        """Insert a test user and return their ID."""
        async with pool.acquire() as conn:
            user_id = uuid.uuid4()
            await conn.execute(
                """
                INSERT INTO auth.users (id, email, password_hash)
                VALUES ($1, $2, $3)
                """,
                user_id,
                f"test-{user_id}@example.com",
                "$2b$04$fakehash",
            )
            return user_id

    async def _insert_artifact(
        self,
        pool: asyncpg.Pool,
        user_id: uuid.UUID,
        artifact_type: str,
        storage_path: str,
        content_text: str | None = None,
    ) -> uuid.UUID:
        """Insert a test artifact and return its ID."""
        artifact_id = uuid.uuid4()
        async with pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO artifacts (id, user_id, type, storage_path, content_text, status)
                VALUES ($1, $2, $3, $4, $5, 'pending')
                """,
                artifact_id,
                user_id,
                artifact_type,
                storage_path,
                content_text,
            )
        return artifact_id

    async def test_full_note_pipeline(
        self,
        mock_llm: AsyncMock,
        mock_embeddings: AsyncMock,
        _setup_test_db: None,
    ) -> None:
        """End-to-end: note artifact is tagged and embedded in real DB."""
        pool = await self._create_pool()
        try:
            user_id = await self._insert_user(pool)
            artifact_id = await self._insert_artifact(
                pool,
                user_id,
                "note",
                "test/note.md",
                content_text="Design patterns for responsive navigation",
            )

            settings = Settings(
                database_url=TEST_DATABASE_URL,
                nvidia_api_key="nvapi-test-key",
                max_processing_attempts=3,
                processing_poll_interval_seconds=1,
                artifacts_path="/tmp/test-artifacts",
            )

            tagger = Tagger(provider=mock_llm)
            embedder = Embedder(provider=mock_embeddings)
            worker = ProcessingWorker(
                pool=pool, settings=settings, tagger=tagger, embedder=embedder
            )

            # Start worker (it will find the pending artifact)
            await worker.start()

            # Give the worker time to process
            await asyncio.sleep(0.5)
            await worker.stop()

            # Verify artifact is completed
            async with pool.acquire() as conn:
                row = await conn.fetchrow(
                    "SELECT status FROM artifacts WHERE id = $1", artifact_id
                )
                assert row["status"] == "completed"

                # Verify tags were stored
                tags = await conn.fetch(
                    "SELECT name FROM artifact_tags WHERE artifact_id = $1 ORDER BY name",
                    artifact_id,
                )
                tag_names = [t["name"] for t in tags]
                assert "design" in tag_names
                assert "ui-pattern" in tag_names

                # Verify embedding was stored
                emb = await conn.fetchrow(
                    "SELECT model FROM artifact_embeddings WHERE artifact_id = $1",
                    artifact_id,
                )
                assert emb is not None
                assert emb["model"] == "nvidia/nv-embedqa-e5-v5"
        finally:
            await pool.close()

    async def test_full_screenshot_pipeline(
        self,
        mock_llm: AsyncMock,
        mock_embeddings: AsyncMock,
        tmp_path: Path,
        _setup_test_db: None,
    ) -> None:
        """End-to-end: screenshot artifact is tagged and embedded in real DB."""
        pool = await self._create_pool()
        try:
            user_id = await self._insert_user(pool)

            # Write a test image to the artifacts path
            relative_path = "test/image.png"
            image_file = tmp_path / relative_path
            image_file.parent.mkdir(parents=True, exist_ok=True)
            image_file.write_bytes(_make_png())

            artifact_id = await self._insert_artifact(
                pool, user_id, "screenshot", relative_path
            )

            settings = Settings(
                database_url=TEST_DATABASE_URL,
                nvidia_api_key="nvapi-test-key",
                max_processing_attempts=3,
                processing_poll_interval_seconds=1,
                artifacts_path=str(tmp_path),
            )

            tagger = Tagger(provider=mock_llm)
            embedder = Embedder(provider=mock_embeddings)
            worker = ProcessingWorker(
                pool=pool, settings=settings, tagger=tagger, embedder=embedder
            )

            await worker.start()
            await asyncio.sleep(0.5)
            await worker.stop()

            async with pool.acquire() as conn:
                row = await conn.fetchrow(
                    "SELECT status FROM artifacts WHERE id = $1", artifact_id
                )
                assert row["status"] == "completed"

                # Verify embedding text was the tags (not image bytes)
                mock_embeddings.embed.assert_called_once_with(
                    "Image: design, ui-pattern, mobile, dark-mode"
                )
        finally:
            await pool.close()

    async def test_startup_recovery(
        self,
        mock_llm: AsyncMock,
        mock_embeddings: AsyncMock,
        _setup_test_db: None,
    ) -> None:
        """Artifacts stuck in 'processing' for > 5 minutes are reset to 'pending' on startup."""
        pool = await self._create_pool()
        try:
            user_id = await self._insert_user(pool)
            artifact_id = await self._insert_artifact(
                pool, user_id, "note", "test/stuck.md", content_text="stuck note"
            )

            # Manually set status to 'processing' with updated_at > 5 minutes ago (simulates crash)
            async with pool.acquire() as conn:
                await conn.execute(
                    "UPDATE artifacts SET status = 'processing', updated_at = now() - interval '10 minutes' WHERE id = $1",
                    artifact_id,
                )

            settings = Settings(
                database_url=TEST_DATABASE_URL,
                nvidia_api_key="nvapi-test-key",
                max_processing_attempts=3,
                processing_poll_interval_seconds=1,
                artifacts_path="/tmp/test-artifacts",
            )

            tagger = Tagger(provider=mock_llm)
            embedder = Embedder(provider=mock_embeddings)
            worker = ProcessingWorker(
                pool=pool, settings=settings, tagger=tagger, embedder=embedder
            )

            # Start triggers recovery, which resets to pending, then processes
            await worker.start()
            await asyncio.sleep(0.5)
            await worker.stop()

            async with pool.acquire() as conn:
                row = await conn.fetchrow(
                    "SELECT status FROM artifacts WHERE id = $1", artifact_id
                )
                assert row["status"] == "completed"
        finally:
            await pool.close()

    async def test_retry_on_parse_error(
        self,
        mock_embeddings: AsyncMock,
        _setup_test_db: None,
    ) -> None:
        """Invalid JSON from LLM triggers retry with backoff."""
        pool = await self._create_pool()
        try:
            user_id = await self._insert_user(pool)
            artifact_id = await self._insert_artifact(
                pool, user_id, "note", "test/retry.md", content_text="test content"
            )

            # LLM returns invalid JSON
            bad_llm = AsyncMock()
            bad_llm.complete.return_value = "not valid json at all"

            settings = Settings(
                database_url=TEST_DATABASE_URL,
                nvidia_api_key="nvapi-test-key",
                max_processing_attempts=3,
                processing_poll_interval_seconds=1,
                artifacts_path="/tmp/test-artifacts",
            )

            tagger = Tagger(provider=bad_llm)
            embedder = Embedder(provider=mock_embeddings)
            worker = ProcessingWorker(
                pool=pool, settings=settings, tagger=tagger, embedder=embedder
            )

            await worker.start()
            await asyncio.sleep(0.5)
            await worker.stop()

            # Should be back to pending with attempts incremented and scheduled_after set
            async with pool.acquire() as conn:
                row = await conn.fetchrow(
                    "SELECT status, attempts, scheduled_after FROM artifacts WHERE id = $1",
                    artifact_id,
                )
                assert row["status"] == "pending"
                assert row["attempts"] == 1
                assert row["scheduled_after"] is not None
        finally:
            await pool.close()
