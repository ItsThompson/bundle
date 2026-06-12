"""Embedder: generates vector embeddings for semantic similarity search."""

import structlog

from api.processing.providers import EmbeddingProvider

logger = structlog.get_logger("api.processing.embedder")


class Embedder:
    """Generates vector embeddings for artifacts using an embedding provider."""

    def __init__(self, provider: EmbeddingProvider) -> None:
        self.provider = provider

    @property
    def model_name(self) -> str:
        """The model identifier used by the underlying provider."""
        model = getattr(self.provider, "model", "unknown")
        return model if isinstance(model, str) else "unknown"

    async def embed(self, text: str) -> list[float]:
        """Generate an embedding vector for the given text.

        Returns a list of floats with dimensionality matching the provider.
        """
        if not text.strip():
            logger.warning("embed_empty_text")
            # Return zero vector for empty text rather than failing
            return [0.0] * self.provider.dimensions

        embedding = await self.provider.embed(text)

        if len(embedding) != self.provider.dimensions:
            raise ValueError(
                f"Embedding dimensions mismatch: expected {self.provider.dimensions}, "
                f"got {len(embedding)}"
            )

        return embedding
