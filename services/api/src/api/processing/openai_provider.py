"""OpenAI embedding provider implementation."""

import openai
import structlog

logger = structlog.get_logger("api.processing.openai_embedding")


class OpenAIEmbeddingProvider:
    """Embedding provider using OpenAI's text-embedding-3-small model."""

    def __init__(
        self, api_key: str, model: str = "text-embedding-3-small"
    ) -> None:
        self.client = openai.AsyncOpenAI(api_key=api_key)
        self.model = model

    async def embed(self, text: str) -> list[float]:
        """Generate an embedding vector for the given text."""
        logger.debug("openai_embed_request", model=self.model, text_length=len(text))

        response = await self.client.embeddings.create(
            model=self.model,
            input=text,
        )

        embedding = response.data[0].embedding
        logger.debug("openai_embed_response", dimensions=len(embedding))
        return embedding

    @property
    def dimensions(self) -> int:
        """The dimensionality of text-embedding-3-small output vectors."""
        return 1536
