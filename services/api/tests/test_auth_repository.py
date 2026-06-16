"""Unit tests for auth_service DB operations: mock asyncpg connection."""

import uuid
from datetime import UTC, datetime
from unittest.mock import AsyncMock

import pytest

from api.services.auth_service import (
    blacklist_token,
    change_password,
    get_password_hash,
    is_token_blacklisted,
    lookup_user_by_email,
    register_user,
    update_user_email,
)


@pytest.fixture
def mock_conn() -> AsyncMock:
    """Create a mock asyncpg connection."""
    return AsyncMock()


@pytest.fixture
def user_id() -> uuid.UUID:
    """A fixed user ID for tests."""
    return uuid.uuid4()


class TestRegisterUser:
    """Tests for register_user."""

    @pytest.mark.asyncio
    async def test_inserts_and_returns_user(self, mock_conn: AsyncMock) -> None:
        """register_user inserts a row and returns the created user."""
        now = datetime.now(UTC)
        uid = uuid.uuid4()
        mock_conn.fetchrow.return_value = {
            "id": uid,
            "email": "new@example.com",
            "created_at": now,
            "updated_at": now,
        }

        result = await register_user(
            mock_conn, email="new@example.com", password_hash="$2b$hash"
        )

        assert result["email"] == "new@example.com"
        assert result["id"] == uid
        call_args = mock_conn.fetchrow.call_args[0]
        assert "INSERT INTO auth.users" in call_args[0]
        assert call_args[1] == "new@example.com"
        assert call_args[2] == "$2b$hash"


class TestLookupUserByEmail:
    """Tests for lookup_user_by_email."""

    @pytest.mark.asyncio
    async def test_returns_user_when_found(self, mock_conn: AsyncMock) -> None:
        """Returns user dict when email exists."""
        uid = uuid.uuid4()
        mock_conn.fetchrow.return_value = {
            "id": uid,
            "email": "found@example.com",
            "password_hash": "$2b$hash",
            "tokens_revoked_at": None,
            "created_at": datetime.now(UTC),
            "updated_at": datetime.now(UTC),
        }

        result = await lookup_user_by_email(mock_conn, email="found@example.com")

        assert result is not None
        assert result["email"] == "found@example.com"

    @pytest.mark.asyncio
    async def test_returns_none_when_not_found(self, mock_conn: AsyncMock) -> None:
        """Returns None when email does not exist."""
        mock_conn.fetchrow.return_value = None

        result = await lookup_user_by_email(mock_conn, email="missing@example.com")

        assert result is None


class TestIsTokenBlacklisted:
    """Tests for is_token_blacklisted."""

    @pytest.mark.asyncio
    async def test_returns_true_when_blacklisted(self, mock_conn: AsyncMock) -> None:
        """Returns True when JTI is in the blacklist."""
        mock_conn.fetchval.return_value = True
        jti = uuid.uuid4()

        result = await is_token_blacklisted(mock_conn, jti=jti)

        assert result is True

    @pytest.mark.asyncio
    async def test_returns_false_when_not_blacklisted(self, mock_conn: AsyncMock) -> None:
        """Returns False when JTI is not blacklisted."""
        mock_conn.fetchval.return_value = False

        result = await is_token_blacklisted(mock_conn, jti=uuid.uuid4())

        assert result is False


class TestBlacklistToken:
    """Tests for blacklist_token."""

    @pytest.mark.asyncio
    async def test_executes_insert(self, mock_conn: AsyncMock, user_id: uuid.UUID) -> None:
        """blacklist_token executes an INSERT with ON CONFLICT DO NOTHING."""
        jti = uuid.uuid4()
        expires = datetime(2026, 7, 1, 0, 0, 0, tzinfo=UTC)

        await blacklist_token(
            mock_conn, jti=jti, user_id=user_id, expires_at=expires
        )

        mock_conn.execute.assert_called_once()
        call_args = mock_conn.execute.call_args[0]
        assert "INSERT INTO auth.refresh_token_blacklist" in call_args[0]
        assert call_args[1] == jti
        assert call_args[2] == user_id
        assert call_args[3] == expires


class TestUpdateUserEmail:
    """Tests for update_user_email."""

    @pytest.mark.asyncio
    async def test_returns_updated_row(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns updated user row on success."""
        now = datetime.now(UTC)
        mock_conn.fetchrow.return_value = {
            "id": user_id,
            "email": "new@example.com",
            "created_at": now,
            "updated_at": now,
        }

        result = await update_user_email(
            mock_conn, user_id=user_id, new_email="new@example.com"
        )

        assert result is not None
        assert result["email"] == "new@example.com"

    @pytest.mark.asyncio
    async def test_returns_none_when_user_not_found(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns None when user ID does not exist."""
        mock_conn.fetchrow.return_value = None

        result = await update_user_email(
            mock_conn, user_id=user_id, new_email="x@y.com"
        )

        assert result is None


class TestGetPasswordHash:
    """Tests for get_password_hash."""

    @pytest.mark.asyncio
    async def test_returns_hash_when_found(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns the password hash string when user exists."""
        mock_conn.fetchval.return_value = "$2b$04$somehash"

        result = await get_password_hash(mock_conn, user_id=user_id)

        assert result == "$2b$04$somehash"

    @pytest.mark.asyncio
    async def test_returns_none_when_not_found(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns None when user does not exist."""
        mock_conn.fetchval.return_value = None

        result = await get_password_hash(mock_conn, user_id=user_id)

        assert result is None


class TestChangePassword:
    """Tests for change_password."""

    @pytest.mark.asyncio
    async def test_returns_updated_user(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns updated user row after password change."""
        now = datetime.now(UTC)
        mock_conn.fetchrow.return_value = {
            "id": user_id,
            "email": "user@example.com",
            "created_at": now,
            "updated_at": now,
        }

        result = await change_password(
            mock_conn, user_id=user_id, new_password_hash="$2b$newhash"
        )

        assert result is not None
        assert result["id"] == user_id
        call_args = mock_conn.fetchrow.call_args[0]
        assert "tokens_revoked_at = now()" in call_args[0]

    @pytest.mark.asyncio
    async def test_returns_none_when_user_not_found(
        self, mock_conn: AsyncMock, user_id: uuid.UUID
    ) -> None:
        """Returns None when user does not exist."""
        mock_conn.fetchrow.return_value = None

        result = await change_password(
            mock_conn, user_id=user_id, new_password_hash="$2b$x"
        )

        assert result is None
