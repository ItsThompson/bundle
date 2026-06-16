"""Unit tests for the RateLimiter class."""

import time
from unittest.mock import patch

import pytest
from fastapi import HTTPException

from api.middleware.rate_limiter import RateLimitConfig, RateLimiter


class TestRateLimiterCheck:
    """Test RateLimiter.check() sliding window behavior."""

    def test_allows_requests_within_limit(self) -> None:
        """Requests within limit should not raise."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=5, window_seconds=60)

        for _ in range(4):
            limiter.record("user:1")

        # 5th check should pass (4 recorded, limit is 5)
        limiter.check("user:1", config)

    def test_rejects_at_limit(self) -> None:
        """Exactly at limit should raise 429."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=3, window_seconds=60)

        for _ in range(3):
            limiter.record("user:1")

        with pytest.raises(HTTPException) as exc_info:
            limiter.check("user:1", config)

        assert exc_info.value.status_code == 429
        assert exc_info.value.headers["Retry-After"] == "60"

    def test_one_over_limit_rejects(self) -> None:
        """One request over limit should raise 429."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=2, window_seconds=60)

        limiter.record("user:1")
        limiter.record("user:1")
        limiter.record("user:1")

        with pytest.raises(HTTPException) as exc_info:
            limiter.check("user:1", config)

        assert exc_info.value.status_code == 429

    def test_different_keys_are_independent(self) -> None:
        """Rate limiting is per-key: different keys don't affect each other."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=2, window_seconds=60)

        limiter.record("user:1")
        limiter.record("user:1")

        # user:2 should be fine
        limiter.check("user:2", config)

    def test_window_expiry_allows_new_requests(self) -> None:
        """Entries outside the window are pruned; new requests succeed."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=2, window_seconds=10)

        # Simulate old entries by directly inserting timestamps
        old_time = time.time() - 20  # 20 seconds ago (outside 10s window)
        limiter._attempts["user:1"] = [old_time, old_time]

        # Should pass: old entries outside window
        limiter.check("user:1", config)

    def test_mixed_old_and_new_entries(self) -> None:
        """Only entries within window count toward the limit."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=2, window_seconds=10)

        now = time.time()
        limiter._attempts["user:1"] = [
            now - 15,  # outside window
            now - 5,   # inside window
        ]

        # Only 1 entry in window, limit is 2, should pass
        limiter.check("user:1", config)

    def test_retry_after_header_matches_window(self) -> None:
        """Retry-After header should equal the window_seconds."""
        limiter = RateLimiter()
        config = RateLimitConfig(max_requests=1, window_seconds=120)

        limiter.record("key:1")

        with pytest.raises(HTTPException) as exc_info:
            limiter.check("key:1", config)

        assert exc_info.value.headers["Retry-After"] == "120"


class TestRateLimiterCleanup:
    """Test periodic cleanup of stale entries."""

    def test_cleanup_removes_stale_entries(self) -> None:
        """Entries older than max_window are removed during cleanup."""
        limiter = RateLimiter(cleanup_interval=0, max_window=60)

        # Insert old entries
        old_time = time.time() - 120  # 2 minutes ago
        limiter._attempts["stale:key"] = [old_time]
        limiter._attempts["fresh:key"] = [time.time()]

        # Force cleanup by setting last_cleanup far in past
        limiter._last_cleanup = time.time() - 100

        # Trigger cleanup via check
        config = RateLimitConfig(max_requests=100, window_seconds=60)
        limiter.check("trigger", config)

        assert "stale:key" not in limiter._attempts
        assert "fresh:key" in limiter._attempts

    def test_cleanup_respects_interval(self) -> None:
        """Cleanup only runs when interval has elapsed."""
        limiter = RateLimiter(cleanup_interval=60, max_window=60)

        # Insert stale entry
        old_time = time.time() - 120
        limiter._attempts["stale:key"] = [old_time]

        # Last cleanup was recent: no cleanup should run
        limiter._last_cleanup = time.time()

        config = RateLimitConfig(max_requests=100, window_seconds=60)
        limiter.check("trigger", config)

        # Stale key should still exist (cleanup didn't run)
        assert "stale:key" in limiter._attempts

    def test_cleanup_removes_empty_keys(self) -> None:
        """Keys with no entries after pruning are deleted entirely."""
        limiter = RateLimiter(cleanup_interval=0, max_window=30)
        limiter._last_cleanup = time.time() - 100

        old_time = time.time() - 60
        limiter._attempts["empty:key"] = [old_time]

        config = RateLimitConfig(max_requests=100, window_seconds=30)
        limiter.check("trigger", config)

        assert "empty:key" not in limiter._attempts


class TestRateLimiterRecord:
    """Test RateLimiter.record() method."""

    def test_record_adds_timestamp(self) -> None:
        """record() appends a timestamp for the key."""
        limiter = RateLimiter()

        limiter.record("key:1")

        assert len(limiter._attempts["key:1"]) == 1
        assert limiter._attempts["key:1"][0] <= time.time()

    def test_multiple_records_accumulate(self) -> None:
        """Multiple records add multiple timestamps."""
        limiter = RateLimiter()

        limiter.record("key:1")
        limiter.record("key:1")
        limiter.record("key:1")

        assert len(limiter._attempts["key:1"]) == 3
