"""Async processing worker for artifact tagging and embedding generation."""

import asyncio
import contextlib
import re
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import assert_never

import asyncpg
import httpx
import structlog

from api.config import Settings
from api.models.domain import ArtifactType, ProcessingStatus
from api.processing.embedder import Embedder
from api.processing.image_utils import resize_for_vision
from api.processing.safe_url_fetcher import FetchResult, SafeURLFetcher, SSRFError
from api.processing.tagger import Tagger, TagParseError

logger = structlog.get_logger("api.processing.worker")

LINK_FETCH_TIMEOUT = 10.0
LINK_CONTENT_MAX_CHARS = 4000


class ProcessingWorker:
    """Async worker that processes pending artifacts: generates tags and embeddings.

    Runs as an asyncio task within the FastAPI process. Polls for pending artifacts
    on a configurable interval and wakes immediately when notified of new uploads.
    """

    def __init__(
        self,
        pool: asyncpg.Pool,
        settings: Settings,
        tagger: Tagger,
        embedder: Embedder,
        url_fetcher: SafeURLFetcher | None = None,
    ) -> None:
        self.pool = pool
        self.settings = settings
        self.tagger = tagger
        self.embedder = embedder
        self.url_fetcher = url_fetcher or SafeURLFetcher()
        self.event = asyncio.Event()
        self._task: asyncio.Task | None = None
        self._current_artifact_id: uuid.UUID | None = None

    @property
    def current_artifact_id(self) -> uuid.UUID | None:
        """The ID of the artifact currently being processed (for graceful shutdown)."""
        return self._current_artifact_id

    def notify(self) -> None:
        """Wake the worker immediately (called when a new artifact is uploaded)."""
        self.event.set()

    async def start(self) -> None:
        """Start the worker and run startup recovery."""
        await self._recover_stuck_artifacts()
        self._task = asyncio.create_task(self._run_loop())
        logger.info("worker_started")

    async def stop(self) -> None:
        """Gracefully stop the worker."""
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        logger.info("worker_stopped")

    async def _recover_stuck_artifacts(self) -> None:
        """Reset artifacts stuck in 'processing' longer than 5 minutes (scoped recovery)."""
        async with self.pool.acquire() as conn:
            result = await conn.fetch(
                """
                UPDATE artifacts
                SET status = $1, updated_at = now()
                WHERE status = $2
                  AND updated_at < now() - interval '5 minutes'
                RETURNING id
                """,
                ProcessingStatus.PENDING,
                ProcessingStatus.PROCESSING,
            )
        count = len(result)
        logger.info("worker_recovery_complete", reset_count=count)

    async def _run_loop(self) -> None:
        """Main processing loop: poll for pending artifacts."""
        poll_interval = self.settings.processing_poll_interval_seconds

        while True:
            try:
                await self._process_next_batch()

                # Wait for notification or poll interval
                self.event.clear()
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self.event.wait(), timeout=poll_interval)

            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("worker_loop_error")
                await asyncio.sleep(poll_interval)

    async def _process_next_batch(self) -> None:
        """Claim and process one pending artifact at a time."""
        while True:
            artifact = await self._claim_next_artifact()
            if artifact is None:
                break
            await self._process_artifact(artifact)

    async def _claim_next_artifact(self) -> asyncpg.Record | None:
        """Claim the next pending artifact that is ready for processing."""
        async with self.pool.acquire() as conn:
            return await conn.fetchrow(
                """
                UPDATE artifacts
                SET status = $1, updated_at = now()
                WHERE id = (
                    SELECT id FROM artifacts
                    WHERE status = $2
                      AND (scheduled_after IS NULL OR scheduled_after <= now())
                    ORDER BY created_at ASC
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED
                )
                RETURNING id, user_id, type, storage_path, content_text, attempts
                """,
                ProcessingStatus.PROCESSING,
                ProcessingStatus.PENDING,
            )

    async def _process_artifact(self, artifact: asyncpg.Record) -> None:
        """Process a single artifact: generate tags and embedding."""
        artifact_id = artifact["id"]
        artifact_type = artifact["type"]
        self._current_artifact_id = artifact_id

        logger.info(
            "processing_started",
            artifact_id=str(artifact_id),
            type=artifact_type,
            attempt=artifact["attempts"] + 1,
        )

        try:
            tags, embedding = await self._generate_tags_and_embedding(artifact)
            await self._store_results(artifact_id, tags, embedding)
            logger.info(
                "processing_completed",
                artifact_id=str(artifact_id),
                tag_count=len(tags),
            )
        except Exception as exc:
            await self._handle_failure(artifact, exc)
        finally:
            self._current_artifact_id = None

    async def _generate_tags_and_embedding(
        self, artifact: asyncpg.Record
    ) -> tuple[list[str], list[float]]:
        """Generate tags and embedding based on artifact type."""
        artifact_type = ArtifactType(artifact["type"])

        match artifact_type:
            case ArtifactType.SCREENSHOT:
                return await self._process_screenshot(artifact)
            case ArtifactType.NOTE:
                return await self._process_note(artifact)
            case ArtifactType.LINK:
                return await self._process_link(artifact)
            case _ as unreachable:
                assert_never(unreachable)

    async def _process_screenshot(self, artifact: asyncpg.Record) -> tuple[list[str], list[float]]:
        """Process screenshot: read image, tag via vision, embed tags."""
        storage_path = Path(self.settings.artifacts_path) / artifact["storage_path"]
        image_bytes = storage_path.read_bytes()

        # Resize for vision model (max 2048px on longest side)
        image_bytes = resize_for_vision(image_bytes)

        tags = await self.tagger.tag_image(image_bytes)

        # Embed the generated tags, not the image bytes
        embedding_text = f"Image: {', '.join(tags)}"
        embedding = await self.embedder.embed(embedding_text)

        return tags, embedding

    async def _process_note(self, artifact: asyncpg.Record) -> tuple[list[str], list[float]]:
        """Process note: tag text, embed full text."""
        text = artifact["content_text"] or ""

        if not text.strip():
            raise ValueError("Note artifact has no content text")

        tags = await self.tagger.tag_text(text)
        embedding = await self.embedder.embed(text)

        return tags, embedding

    async def _process_link(self, artifact: asyncpg.Record) -> tuple[list[str], list[float]]:
        """Process link: fetch URL content safely, tag it; fallback to URL-only tagging."""
        url = artifact["content_text"] or ""

        if not url.strip():
            raise ValueError("Link artifact has no URL in content_text")

        try:
            result: FetchResult = await self.url_fetcher.fetch(url)
            content_type = result.content_type
            text = result.content.decode("utf-8", errors="replace")

            # Strip HTML tags if content is HTML
            if "html" in content_type:
                text = self._strip_html(text)

            truncated = text.strip()[:LINK_CONTENT_MAX_CHARS]
            tags = await self.tagger.tag_text(truncated)
            embedding = await self.embedder.embed(truncated)
        except SSRFError as exc:
            logger.warning(
                "link_ssrf_blocked",
                url=url,
                error=str(exc),
            )
            tags = await self.tagger.tag_url_only(url)
            embedding = await self.embedder.embed(url)
        except (httpx.HTTPError, httpx.TimeoutException) as exc:
            logger.warning(
                "link_fetch_failed",
                url=url,
                error=str(exc),
            )
            tags = await self.tagger.tag_url_only(url)
            embedding = await self.embedder.embed(url)

        return tags, embedding

    def _strip_html(self, html: str) -> str:
        """Simple HTML tag stripping for link content extraction."""
        # Remove script and style blocks
        text = re.sub(r"<script[^>]*>.*?</script>", "", html, flags=re.DOTALL)
        text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.DOTALL)
        # Remove HTML tags
        text = re.sub(r"<[^>]+>", " ", text)
        # Collapse whitespace
        text = re.sub(r"\s+", " ", text)
        return text.strip()

    async def _store_results(
        self, artifact_id: uuid.UUID, tags: list[str], embedding: list[float]
    ) -> None:
        """Store tags and embedding in DB, mark artifact as completed."""
        async with self.pool.acquire() as conn, conn.transaction():
            # Insert tags
            for tag in tags:
                await conn.execute(
                    """
                        INSERT INTO artifact_tags (artifact_id, name)
                        VALUES ($1, $2)
                        ON CONFLICT (artifact_id, name) DO NOTHING
                        """,
                    artifact_id,
                    tag,
                )

            # Insert embedding
            embedding_str = "[" + ",".join(str(v) for v in embedding) + "]"
            await conn.execute(
                """
                    INSERT INTO artifact_embeddings (artifact_id, embedding, model)
                    VALUES ($1, $2::vector, $3)
                    ON CONFLICT (artifact_id) DO UPDATE
                    SET embedding = EXCLUDED.embedding, model = EXCLUDED.model
                    """,
                artifact_id,
                embedding_str,
                self.embedder.model_name,
            )

            # Mark as completed
            await conn.execute(
                """
                    UPDATE artifacts
                    SET status = $2, updated_at = now()
                    WHERE id = $1
                    """,
                artifact_id,
                ProcessingStatus.COMPLETED,
            )

    async def _handle_failure(self, artifact: asyncpg.Record, exc: Exception) -> None:
        """Handle processing failure: increment attempts, apply backoff or mark failed."""
        artifact_id = artifact["id"]
        attempts = artifact["attempts"] + 1
        max_attempts = self.settings.max_processing_attempts

        is_retryable = isinstance(exc, TagParseError) or not isinstance(exc, ValueError)

        if not is_retryable or attempts >= max_attempts:
            # Mark as permanently failed
            async with self.pool.acquire() as conn:
                await conn.execute(
                    """
                    UPDATE artifacts
                    SET status = $3, attempts = $2, updated_at = now()
                    WHERE id = $1
                    """,
                    artifact_id,
                    attempts,
                    ProcessingStatus.FAILED,
                )
            logger.error(
                "processing_failed_permanent",
                artifact_id=str(artifact_id),
                attempts=attempts,
                error=str(exc),
            )
        else:
            # Retry with exponential backoff: attempts² × 30 seconds
            backoff_seconds = (attempts**2) * 30
            scheduled_after = datetime.now(UTC) + timedelta(seconds=backoff_seconds)

            async with self.pool.acquire() as conn:
                await conn.execute(
                    """
                    UPDATE artifacts
                    SET status = $4, attempts = $2,
                        scheduled_after = $3, updated_at = now()
                    WHERE id = $1
                    """,
                    artifact_id,
                    attempts,
                    scheduled_after,
                    ProcessingStatus.PENDING,
                )
            logger.warning(
                "processing_failed_retry",
                artifact_id=str(artifact_id),
                attempts=attempts,
                backoff_seconds=backoff_seconds,
                error=str(exc),
            )
