"""In-memory sliding window rate limiter.

Appropriate for single-worker deployment. State is lost on restart
(acceptable: rate limits are transient protection, not persistent policy).
Includes periodic cleanup to prevent memory leaks.
"""

import time
from collections import defaultdict
from dataclasses import dataclass

from fastapi import HTTPException, status


@dataclass
class RateLimitConfig:
    """Configuration for a rate limit window."""

    max_requests: int
    window_seconds: int


class RateLimiter:
    """Sliding window rate limiter with automatic cleanup of stale entries.

    Per-key pruning occurs on every check(). Periodic cleanup (every 60s)
    evicts all entries older than max_window across all keys, bounding memory
    even for keys that stop being checked.
    """

    def __init__(
        self, cleanup_interval: float = 60.0, max_window: int = 3600
    ) -> None:
        self._attempts: dict[str, list[float]] = defaultdict(list)
        self._last_cleanup: float = time.time()
        self._cleanup_interval: float = cleanup_interval
        self._max_window: int = max_window

    def check(self, key: str, config: RateLimitConfig) -> None:
        """Check if the key has exceeded its rate limit.

        Prunes entries older than the window for this key, then checks count.
        Raises HTTPException 429 if limit exceeded.
        """
        self._maybe_cleanup()

        now = time.time()
        window_start = now - config.window_seconds

        # Prune old entries for this key
        self._attempts[key] = [t for t in self._attempts[key] if t > window_start]

        if len(self._attempts[key]) >= config.max_requests:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Rate limit exceeded. Please try again later.",
                headers={"Retry-After": str(config.window_seconds)},
            )

    def record(self, key: str) -> None:
        """Record a request timestamp for the given key."""
        self._attempts[key].append(time.time())

    def _maybe_cleanup(self) -> None:
        """Periodically evict all entries older than max_window to bound memory."""
        now = time.time()
        if now - self._last_cleanup < self._cleanup_interval:
            return

        cutoff = now - self._max_window
        keys_to_delete: list[str] = []

        for key, timestamps in self._attempts.items():
            self._attempts[key] = [t for t in timestamps if t > cutoff]
            if not self._attempts[key]:
                keys_to_delete.append(key)

        for key in keys_to_delete:
            del self._attempts[key]

        self._last_cleanup = now
