"""Protocol definitions for LLM and embedding providers."""

from typing import Protocol


class LLMProvider(Protocol):
    """Abstract interface for LLM API providers."""

    async def complete(
        self,
        prompt: str,
        system: str | None = None,
        images: list[bytes] | None = None,
        max_tokens: int = 256,
    ) -> str:
        """Send a completion request. Supports text and optional vision."""
        ...


class EmbeddingProvider(Protocol):
    """Abstract interface for embedding API providers."""

    async def embed(self, text: str) -> list[float]:
        """Generate an embedding vector for the given text."""
        ...

    @property
    def dimensions(self) -> int:
        """The dimensionality of the output vectors."""
        ...
