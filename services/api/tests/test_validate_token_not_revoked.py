"""Unit tests for validate_token_not_revoked."""

import uuid
from datetime import UTC, datetime
from unittest.mock import AsyncMock

import pytest

from api.services.auth_service import TokenError, validate_token_not_revoked


@pytest.fixture
def mock_conn() -> AsyncMock:
    """Create a mock asyncpg connection."""
    return AsyncMock()


@pytest.fixture
def user_id() -> str:
    """A fixed user ID string for tests."""
    return str(uuid.uuid4())


class TestValidateTokenNotRevoked:
    """Tests for validate_token_not_revoked."""

    @pytest.mark.asyncio
    async def test_raises_when_iat_before_revoked_at(
        self, mock_conn: AsyncMock, user_id: str
    ) -> None:
        """Token issued before tokens_revoked_at is rejected."""
        # Revoked at unix timestamp 1000
        revoked_at = datetime.fromtimestamp(1000, tz=UTC)
        mock_conn.fetchval.return_value = revoked_at

        # Token issued at 999 (before revocation)
        with pytest.raises(TokenError, match="revoked"):
            await validate_token_not_revoked(mock_conn, user_id, token_iat=999)

    @pytest.mark.asyncio
    async def test_accepts_token_after_revoked_at(
        self, mock_conn: AsyncMock, user_id: str
    ) -> None:
        """Token issued after tokens_revoked_at is accepted."""
        revoked_at = datetime.fromtimestamp(1000, tz=UTC)
        mock_conn.fetchval.return_value = revoked_at

        # Token issued at 1001 (after revocation): should NOT raise
        await validate_token_not_revoked(mock_conn, user_id, token_iat=1001)

    @pytest.mark.asyncio
    async def test_accepts_when_revoked_at_is_null(
        self, mock_conn: AsyncMock, user_id: str
    ) -> None:
        """Null tokens_revoked_at means no revocation: token passes."""
        mock_conn.fetchval.return_value = None

        # Should not raise regardless of iat
        await validate_token_not_revoked(mock_conn, user_id, token_iat=500)

    @pytest.mark.asyncio
    async def test_rejects_token_at_exact_boundary(
        self, mock_conn: AsyncMock, user_id: str
    ) -> None:
        """Token issued at exact same second as revocation is accepted.

        The check is `iat < revoked_at_unix`, so equal timestamps pass.
        """
        revoked_at = datetime.fromtimestamp(1000, tz=UTC)
        mock_conn.fetchval.return_value = revoked_at

        # iat == revoked_at_unix: NOT less than, so it passes
        await validate_token_not_revoked(mock_conn, user_id, token_iat=1000)

    @pytest.mark.asyncio
    async def test_queries_correct_user(
        self, mock_conn: AsyncMock, user_id: str
    ) -> None:
        """Function queries the correct user_id from the database."""
        mock_conn.fetchval.return_value = None

        await validate_token_not_revoked(mock_conn, user_id, token_iat=500)

        call_args = mock_conn.fetchval.call_args[0]
        assert "tokens_revoked_at" in call_args[0]
        assert call_args[1] == uuid.UUID(user_id)
