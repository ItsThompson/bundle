"""NVIDIA NIM embedding provider using nv-embedqa-e5-v5."""

import httpx
import structlog

logger = structlog.get_logger("api.processing.nim_embedding")

NIM_BASE_URL = "https://integrate.api.nvidia.com/v1"


class NimEmbeddingProvider:
    """Embedding provider using NVIDIA NIM's nv-embedqa-e5-v5 model.

    Outputs 1024-dimensional vectors via the /v1/embeddings endpoint.
    Uses input_type="passage" for document indexing by default.
    """

    def __init__(
        self,
        api_key: str,
        model: str = "nvidia/nv-embedqa-e5-v5",
    ) -> None:
        self.api_key = api_key
        self.model = model
        self._client: httpx.AsyncClient | None = None

    @property
    def dimensions(self) -> int:
        """nv-embedqa-e5-v5 outputs 1024-dimensional vectors."""
        return 1024

    async def embed(self, text: str) -> list[float]:
        """Generate an embedding vector for the given text.

        Uses input_type="passage" for document/artifact indexing.
        For search queries, use embed_query() instead.
        """
        return await self._embed_with_type(text, input_type="passage")

    async def embed_query(self, text: str) -> list[float]:
        """Generate an embedding vector optimized for search queries.

        Uses input_type="query" which improves retrieval quality
        when searching against passage-indexed documents.
        """
        return await self._embed_with_type(text, input_type="query")

    async def _embed_with_type(self, text: str, *, input_type: str) -> list[float]:
        """Generate embedding with the specified input_type."""
        logger.debug(
            "nim_embed_request",
            model=self.model,
            text_length=len(text),
            input_type=input_type,
        )

        client = self._get_client()
        response = await client.post(
            f"{NIM_BASE_URL}/embeddings",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            json={
                "input": [text],
                "model": self.model,
                "input_type": input_type,
            },
        )
        response.raise_for_status()

        data = response.json()
        embedding: list[float] = data["data"][0]["embedding"]
        logger.debug("nim_embed_response", dimensions=len(embedding))
        return embedding

    async def close(self) -> None:
        """Close the underlying HTTP client. Call during app shutdown."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def _get_client(self) -> httpx.AsyncClient:
        """Lazy-init the httpx client."""
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=30.0)
        return self._client
