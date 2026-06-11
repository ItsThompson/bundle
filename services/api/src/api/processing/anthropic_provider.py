"""Anthropic LLM provider implementation."""

import base64
from typing import cast

import anthropic
import structlog
from anthropic.types import (
    ImageBlockParam,
    MessageParam,
    TextBlock,
    TextBlockParam,
)

logger = structlog.get_logger("api.processing.anthropic")


class AnthropicProvider:
    """LLM provider using Anthropic's Claude API for text and vision."""

    def __init__(self, api_key: str, model: str = "claude-sonnet-4-20250514") -> None:
        self.client = anthropic.AsyncAnthropic(api_key=api_key)
        self.model = model

    async def complete(
        self,
        prompt: str,
        system: str | None = None,
        images: list[bytes] | None = None,
        max_tokens: int = 256,
    ) -> str:
        """Send a completion request to Claude. Supports text and vision."""
        content = self._build_content(prompt, images)
        messages: list[MessageParam] = [{"role": "user", "content": content}]

        logger.debug(
            "anthropic_request",
            model=self.model,
            has_images=bool(images),
            max_tokens=max_tokens,
        )

        response = await self.client.messages.create(
            model=self.model,
            system=system or "",
            messages=messages,
            max_tokens=max_tokens,
        )

        first_block = response.content[0]
        text = cast("TextBlock", first_block).text
        logger.debug("anthropic_response", length=len(text))
        return text

    def _build_content(
        self, prompt: str, images: list[bytes] | None
    ) -> list[TextBlockParam | ImageBlockParam]:
        """Build message content with optional image blocks."""
        content: list[TextBlockParam | ImageBlockParam] = []

        if images:
            for image_bytes in images:
                encoded = base64.standard_b64encode(image_bytes).decode("utf-8")
                content.append(ImageBlockParam(
                    type="image",
                    source={
                        "type": "base64",
                        "media_type": "image/png",
                        "data": encoded,
                    },
                ))

        content.append(TextBlockParam(type="text", text=prompt))
        return content
