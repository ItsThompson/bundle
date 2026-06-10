"""Tests for the processing pipeline: tagger, embedder, image utils, and worker."""

import io
import json
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from api.config import Settings
from api.processing.embedder import Embedder
from api.processing.image_utils import MAX_DIMENSION, resize_for_vision
from api.processing.tagger import Tagger, TagParseError
from api.processing.worker import ProcessingWorker
from PIL import Image

# --- Fixtures ---


@pytest.fixture
def mock_llm_provider() -> AsyncMock:
    """Mock LLM provider that returns a valid tag JSON array."""
    provider = AsyncMock()
    provider.complete.return_value = '["tag-one", "tag-two", "tag-three"]'
    return provider


@pytest.fixture
def mock_embedding_provider() -> AsyncMock:
    """Mock embedding provider that returns a 1536-dim vector."""
    provider = AsyncMock()
    provider.embed.return_value = [0.1] * 1536
    provider.dimensions = 1536
    return provider


@pytest.fixture
def tagger(mock_llm_provider: AsyncMock) -> Tagger:
    return Tagger(provider=mock_llm_provider)


@pytest.fixture
def embedder(mock_embedding_provider: AsyncMock) -> Embedder:
    return Embedder(provider=mock_embedding_provider)


def _make_png(width: int = 100, height: int = 100) -> bytes:
    """Create a minimal valid PNG image."""
    img = Image.new("RGB", (width, height), color="red")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# --- Image Utils Tests ---


class TestImageUtils:
    def test_resize_small_image_unchanged(self) -> None:
        """Images within limits are returned unchanged."""
        original = _make_png(800, 600)
        result = resize_for_vision(original)
        assert result == original

    def test_resize_wide_image(self) -> None:
        """Wide images are resized to MAX_DIMENSION width."""
        original = _make_png(4096, 2048)
        result = resize_for_vision(original)

        img = Image.open(io.BytesIO(result))
        assert img.width == MAX_DIMENSION
        assert img.height == 1024  # Aspect ratio preserved

    def test_resize_tall_image(self) -> None:
        """Tall images are resized to MAX_DIMENSION height."""
        original = _make_png(1024, 4096)
        result = resize_for_vision(original)

        img = Image.open(io.BytesIO(result))
        assert img.height == MAX_DIMENSION
        assert img.width == 512  # Aspect ratio preserved

    def test_resize_exactly_at_limit(self) -> None:
        """Images at exactly MAX_DIMENSION are returned unchanged."""
        original = _make_png(MAX_DIMENSION, MAX_DIMENSION)
        result = resize_for_vision(original)
        assert result == original


# --- Tagger Tests ---


class TestTagger:
    @pytest.mark.asyncio
    async def test_tag_text_returns_tags(self, tagger: Tagger) -> None:
        """tag_text returns parsed tags from LLM response."""
        tags = await tagger.tag_text("Some note about design systems")
        assert tags == ["tag-one", "tag-two", "tag-three"]

    @pytest.mark.asyncio
    async def test_tag_image_calls_vision(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """tag_image passes image bytes to provider."""
        image = _make_png()
        await tagger.tag_image(image)

        mock_llm_provider.complete.assert_called_once()
        call_kwargs = mock_llm_provider.complete.call_args.kwargs
        assert call_kwargs["images"] == [image]

    @pytest.mark.asyncio
    async def test_tag_url_only(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """tag_url_only sends URL to LLM for structure-based tagging."""
        tags = await tagger.tag_url_only("https://example.com/design/typography")
        assert tags == ["tag-one", "tag-two", "tag-three"]

        call_kwargs = mock_llm_provider.complete.call_args.kwargs
        assert "https://example.com/design/typography" in call_kwargs["prompt"]

    @pytest.mark.asyncio
    async def test_parse_error_on_invalid_json(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """TagParseError raised when LLM returns invalid JSON."""
        mock_llm_provider.complete.return_value = "not json at all"

        with pytest.raises(TagParseError, match="Invalid JSON"):
            await tagger.tag_text("test content")

    @pytest.mark.asyncio
    async def test_parse_error_on_too_few_tags(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """TagParseError raised when LLM returns fewer than 3 tags."""
        mock_llm_provider.complete.return_value = '["one", "two"]'

        with pytest.raises(TagParseError, match="Too few tags"):
            await tagger.tag_text("test content")

    @pytest.mark.asyncio
    async def test_clamp_excess_tags(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """Tags are clamped to max 7."""
        mock_llm_provider.complete.return_value = json.dumps(
            ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
        )
        tags = await tagger.tag_text("test")
        assert len(tags) == 7

    @pytest.mark.asyncio
    async def test_handles_markdown_code_block(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """Parser strips markdown code blocks from LLM response."""
        mock_llm_provider.complete.return_value = (
            '```json\n["design", "ui", "mobile"]\n```'
        )
        tags = await tagger.tag_text("test")
        assert tags == ["design", "ui", "mobile"]

    @pytest.mark.asyncio
    async def test_filters_non_string_tags(
        self, tagger: Tagger, mock_llm_provider: AsyncMock
    ) -> None:
        """Non-string values in the array are filtered out."""
        mock_llm_provider.complete.return_value = '["valid", 123, "also-valid", null, "third"]'
        tags = await tagger.tag_text("test")
        assert tags == ["valid", "also-valid", "third"]


# --- Embedder Tests ---


class TestEmbedder:
    @pytest.mark.asyncio
    async def test_embed_returns_vector(self, embedder: Embedder) -> None:
        """embed returns vector from provider."""
        result = await embedder.embed("some text")
        assert len(result) == 1536
        assert all(v == 0.1 for v in result)

    @pytest.mark.asyncio
    async def test_embed_empty_text_returns_zero_vector(
        self, embedder: Embedder
    ) -> None:
        """Empty text returns zero vector without calling provider."""
        result = await embedder.embed("   ")
        assert len(result) == 1536
        assert all(v == 0.0 for v in result)

    @pytest.mark.asyncio
    async def test_embed_dimension_mismatch_raises(
        self, mock_embedding_provider: AsyncMock
    ) -> None:
        """ValueError raised if provider returns wrong dimensions."""
        mock_embedding_provider.embed.return_value = [0.1] * 100
        embedder = Embedder(provider=mock_embedding_provider)

        with pytest.raises(ValueError, match="dimensions mismatch"):
            await embedder.embed("test text")


# --- Worker Tests ---


class TestProcessingWorker:
    @pytest.fixture
    def mock_conn(self) -> AsyncMock:
        """Mock asyncpg connection."""
        conn = AsyncMock()
        # transaction() also returns an async context manager
        txn_cm = AsyncMock()
        txn_cm.__aenter__.return_value = None
        txn_cm.__aexit__.return_value = None
        conn.transaction.return_value = txn_cm
        return conn

    @pytest.fixture
    def mock_pool(self, mock_conn: AsyncMock) -> MagicMock:
        """Mock asyncpg pool with async context manager support."""
        pool = MagicMock()
        # pool.acquire() is a sync call that returns an async context manager
        cm = AsyncMock()
        cm.__aenter__.return_value = mock_conn
        cm.__aexit__.return_value = None
        pool.acquire.return_value = cm
        return pool

    @pytest.fixture
    def worker_settings(self) -> Settings:
        """Settings for worker tests."""
        return Settings(
            database_url="postgresql://test:test@localhost:5433/test",
            anthropic_api_key="test-key",
            openai_api_key="test-key",
            max_processing_attempts=3,
            processing_poll_interval_seconds=1,
            artifacts_path="/tmp/test-artifacts",
        )

    @pytest.fixture
    def worker(
        self,
        mock_pool: AsyncMock,
        worker_settings: Settings,
        tagger: Tagger,
        embedder: Embedder,
    ) -> ProcessingWorker:
        return ProcessingWorker(
            pool=mock_pool,
            settings=worker_settings,
            tagger=tagger,
            embedder=embedder,
        )

    def test_notify_sets_event(self, worker: ProcessingWorker) -> None:
        """notify() wakes the worker immediately."""
        assert not worker.event.is_set()
        worker.notify()
        assert worker.event.is_set()

    @pytest.mark.asyncio
    async def test_recover_stuck_artifacts(
        self, worker: ProcessingWorker, mock_conn: AsyncMock
    ) -> None:
        """Startup recovery resets 'processing' artifacts to 'pending'."""
        await worker._recover_stuck_artifacts()

        mock_conn.execute.assert_called_once()
        sql = mock_conn.execute.call_args[0][0]
        assert "SET status = 'pending'" in sql
        assert "WHERE status = 'processing'" in sql

    @pytest.mark.asyncio
    async def test_claim_next_artifact(
        self, worker: ProcessingWorker, mock_conn: AsyncMock
    ) -> None:
        """Claim query uses FOR UPDATE SKIP LOCKED and respects scheduled_after."""
        mock_conn.fetchrow.return_value = None

        result = await worker._claim_next_artifact()

        assert result is None
        sql = mock_conn.fetchrow.call_args[0][0]
        assert "FOR UPDATE SKIP LOCKED" in sql
        assert "scheduled_after IS NULL OR scheduled_after <= now()" in sql

    @pytest.mark.asyncio
    async def test_process_note_success(
        self,
        worker: ProcessingWorker,
        mock_pool: AsyncMock,
        mock_llm_provider: AsyncMock,
        mock_embedding_provider: AsyncMock,
    ) -> None:
        """Successful note processing generates tags and embedding."""
        artifact_id = uuid.uuid4()
        artifact = {
            "id": artifact_id,
            "user_id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/path.md",
            "content_text": "Design patterns for mobile navigation",
            "attempts": 0,
        }
        # Make it behave like asyncpg.Record
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        tags, embedding = await worker._generate_tags_and_embedding(mock_record)

        assert tags == ["tag-one", "tag-two", "tag-three"]
        assert len(embedding) == 1536
        mock_llm_provider.complete.assert_called_once()
        mock_embedding_provider.embed.assert_called_once_with(
            "Design patterns for mobile navigation"
        )

    @pytest.mark.asyncio
    async def test_process_screenshot_reads_file_and_embeds_tags(
        self,
        worker: ProcessingWorker,
        mock_llm_provider: AsyncMock,
        mock_embedding_provider: AsyncMock,
        tmp_path: Path,
    ) -> None:
        """Screenshot processing reads image, tags it, and embeds the tag string."""
        worker.settings.artifacts_path = str(tmp_path)

        # Write a test image
        image = _make_png(800, 600)
        artifact_dir = tmp_path / "user" / "2026" / "06" / "10"
        artifact_dir.mkdir(parents=True)
        image_path = artifact_dir / "test.png"
        image_path.write_bytes(image)

        artifact = {
            "id": uuid.uuid4(),
            "type": "screenshot",
            "storage_path": "user/2026/06/10/test.png",
            "content_text": None,
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        tags, embedding = await worker._generate_tags_and_embedding(mock_record)

        assert tags == ["tag-one", "tag-two", "tag-three"]
        # Embedding should be for the tag string, not raw image
        mock_embedding_provider.embed.assert_called_once_with(
            "Image: tag-one, tag-two, tag-three"
        )

    @pytest.mark.asyncio
    async def test_process_link_fetches_and_tags(
        self,
        worker: ProcessingWorker,
        mock_llm_provider: AsyncMock,
        mock_embedding_provider: AsyncMock,
    ) -> None:
        """Link processing fetches URL content and tags the text."""
        artifact = {
            "id": uuid.uuid4(),
            "type": "link",
            "storage_path": "test/path.json",
            "content_text": "https://example.com/article",
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        with patch("api.processing.worker.httpx.AsyncClient") as mock_client_cls:
            mock_response = MagicMock()
            mock_response.text = "<html><body><p>Article content here</p></body></html>"
            mock_response.headers = {"content-type": "text/html"}
            mock_response.raise_for_status = MagicMock()

            mock_client = AsyncMock()
            mock_client.get.return_value = mock_response
            mock_client_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_client_cls.return_value.__aexit__ = AsyncMock(return_value=None)

            tags, embedding = await worker._generate_tags_and_embedding(mock_record)

        assert tags == ["tag-one", "tag-two", "tag-three"]
        # Verify the text was stripped of HTML
        embed_call = mock_embedding_provider.embed.call_args[0][0]
        assert "<html>" not in embed_call
        assert "Article content here" in embed_call

    @pytest.mark.asyncio
    async def test_process_link_fallback_on_fetch_failure(
        self,
        worker: ProcessingWorker,
        mock_llm_provider: AsyncMock,
        mock_embedding_provider: AsyncMock,
    ) -> None:
        """Link processing falls back to URL-only tagging when fetch fails."""
        import httpx

        artifact = {
            "id": uuid.uuid4(),
            "type": "link",
            "storage_path": "test/path.json",
            "content_text": "https://private.example.com/secret",
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        with patch("api.processing.worker.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.get.side_effect = httpx.HTTPStatusError(
                "403", request=MagicMock(), response=MagicMock()
            )
            mock_client_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_client_cls.return_value.__aexit__ = AsyncMock(return_value=None)

            tags, embedding = await worker._generate_tags_and_embedding(mock_record)

        assert tags == ["tag-one", "tag-two", "tag-three"]
        # Should embed the URL itself as fallback
        mock_embedding_provider.embed.assert_called_once_with(
            "https://private.example.com/secret"
        )

    @pytest.mark.asyncio
    async def test_handle_failure_retry_with_backoff(
        self,
        worker: ProcessingWorker,
        mock_conn: AsyncMock,
    ) -> None:
        """First failure sets status back to pending with backoff."""
        artifact = {
            "id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/path.md",
            "content_text": "test",
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        await worker._handle_failure(mock_record, TagParseError("bad json"))

        # Should set status='pending' with scheduled_after
        sql = mock_conn.execute.call_args[0][0]
        assert "SET status = 'pending'" in sql
        assert "scheduled_after" in sql

    @pytest.mark.asyncio
    async def test_handle_failure_permanent_on_max_attempts(
        self,
        worker: ProcessingWorker,
        mock_conn: AsyncMock,
    ) -> None:
        """After max attempts, artifact is marked as failed."""
        artifact = {
            "id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/path.md",
            "content_text": "test",
            "attempts": 2,  # This will be attempt 3 (>= max of 3)
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        await worker._handle_failure(mock_record, TagParseError("bad json"))

        sql = mock_conn.execute.call_args[0][0]
        assert "SET status = 'failed'" in sql

    @pytest.mark.asyncio
    async def test_handle_failure_non_retryable_error(
        self,
        worker: ProcessingWorker,
        mock_conn: AsyncMock,
    ) -> None:
        """ValueError (e.g., empty content) fails immediately."""
        artifact = {
            "id": uuid.uuid4(),
            "type": "note",
            "storage_path": "test/path.md",
            "content_text": "",
            "attempts": 0,
        }
        mock_record = MagicMock()
        mock_record.__getitem__ = lambda self, key: artifact[key]

        await worker._handle_failure(mock_record, ValueError("empty content"))

        sql = mock_conn.execute.call_args[0][0]
        assert "SET status = 'failed'" in sql
