"""NVIDIA NIM LLM provider using Kimi K2.6 for text and vision."""

import base64

import openai
import structlog

logger = structlog.get_logger("api.processing.nim_llm")

NIM_BASE_URL = "https://integrate.api.nvidia.com/v1"


class NimLLMProvider:
    """LLM provider using NVIDIA NIM's Kimi K2.6 model for text and vision.

    Uses the OpenAI-compatible chat completions endpoint at integrate.api.nvidia.com.
    Images are passed as base64-encoded data URLs in the content array.
    """

    def __init__(
        self,
        api_key: str,
        model: str = "moonshotai/kimi-k2.6",
    ) -> None:
        self.client = openai.AsyncOpenAI(
            base_url=NIM_BASE_URL,
            api_key=api_key,
        )
        self.model = model

    async def complete(
        self,
        prompt: str,
        system: str | None = None,
        images: list[bytes] | None = None,
        max_tokens: int = 256,
    ) -> str:
        """Send a completion request to Kimi K2.6. Supports text and vision."""
        content = self._build_content(prompt, images)
        messages: list[dict] = []

        if system:
            messages.append({"role": "system", "content": system})

        messages.append({"role": "user", "content": content})

        logger.debug(
            "nim_llm_request",
            model=self.model,
            has_images=bool(images),
            max_tokens=max_tokens,
        )

        response = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            max_tokens=max_tokens,
            temperature=0.2,
        )

        text = response.choices[0].message.content or ""
        logger.debug("nim_llm_response", length=len(text))
        return text

    def _build_content(self, prompt: str, images: list[bytes] | None) -> str | list[dict]:
        """Build message content. Returns string for text-only, list for vision."""
        if not images:
            return prompt

        content: list[dict] = []

        for image_bytes in images:
            encoded = base64.standard_b64encode(image_bytes).decode("utf-8")
            content.append(
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/png;base64,{encoded}",
                    },
                }
            )

        content.append({"type": "text", "text": prompt})
        return content
