"""Tagger: generates descriptive tags for artifacts using LLM APIs."""

import json

import structlog

from api.processing.providers import LLMProvider

logger = structlog.get_logger("api.processing.tagger")

TAGGING_SYSTEM_PROMPT = """You are a content categorization engine. Analyze the provided content \
and return descriptive tags that capture the key themes, topics, and attributes. \
Tags should be lowercase, 1-3 words each, hyphenated if multi-word.

Rules:
- Return exactly 3-7 tags
- Tags must be descriptive and specific (not generic like "interesting")
- For images: describe visual elements, style, subject matter
- For text: identify topics, domains, concepts
- For URLs: infer from domain, path, and any visible content
- Return tags as a JSON array of strings, nothing else"""


class TagParseError(Exception):
    """Raised when the LLM response cannot be parsed as a valid tag array."""


class Tagger:
    """Generates descriptive tags for artifacts using an LLM provider."""

    def __init__(self, provider: LLMProvider) -> None:
        self.provider = provider

    async def tag_image(self, image_bytes: bytes) -> list[str]:
        """Send image to vision model, return 3-7 tags."""
        prompt = "Analyze this image. Return 3-7 descriptive tags as a JSON array of strings."
        response = await self.provider.complete(
            prompt=prompt,
            system=TAGGING_SYSTEM_PROMPT,
            images=[image_bytes],
            max_tokens=256,
        )
        return self._parse_tags(response)

    async def tag_text(self, text: str) -> list[str]:
        """Send text to LLM, return 3-7 tags."""
        prompt = f"Analyze this content and return 3-7 descriptive tags as a JSON array:\n\n{text}"
        response = await self.provider.complete(
            prompt=prompt,
            system=TAGGING_SYSTEM_PROMPT,
            max_tokens=256,
        )
        return self._parse_tags(response)

    async def tag_url_only(self, url: str) -> list[str]:
        """Generate tags from URL structure alone (fallback when fetch fails)."""
        prompt = (
            f"Generate 3-7 descriptive tags based solely on this URL: {url}\n"
            "Return tags as a JSON array of strings."
        )
        response = await self.provider.complete(
            prompt=prompt,
            system=TAGGING_SYSTEM_PROMPT,
            max_tokens=256,
        )
        return self._parse_tags(response)

    def _parse_tags(self, response: str) -> list[str]:
        """Parse LLM response into a list of tag strings.

        Raises TagParseError if the response is not valid JSON or not a list of strings.
        """
        response = response.strip()

        # Handle case where LLM wraps response in markdown code block
        if response.startswith("```"):
            lines = response.split("\n")
            # Remove first and last lines (``` markers)
            response = "\n".join(lines[1:-1]).strip()

        try:
            parsed = json.loads(response)
        except json.JSONDecodeError as exc:
            logger.warning("tag_parse_failed", response=response[:200])
            raise TagParseError(f"Invalid JSON in LLM response: {response[:100]}") from exc

        if not isinstance(parsed, list):
            raise TagParseError(f"Expected JSON array, got {type(parsed).__name__}")

        # Filter to only string values
        tags = [tag for tag in parsed if isinstance(tag, str)]

        if len(tags) < 3:
            raise TagParseError(f"Too few tags returned: {len(tags)}")

        # Clamp to max 7 tags
        return tags[:7]
