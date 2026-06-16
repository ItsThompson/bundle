"""Unit tests for the quota_service module."""

import uuid
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from api.services.quota_service import (
    STORAGE_QUOTA_BYTES,
    check_storage_quota,
    create_quota_row,
    increment_storage,
)


class TestCheckStorageQuota:
    """Test check_storage_quota enforcement."""

    @pytest.mark.asyncio
    async def test_allows_upload_within_quota(self) -> None:
        """Upload within remaining quota should not raise."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        # User has used 500 MB, uploading 1 MB
        conn.fetchval.return_value = 500 * 1024 * 1024

        await check_storage_quota(conn, user_id, 1 * 1024 * 1024)

    @pytest.mark.asyncio
    async def test_rejects_when_quota_exceeded(self) -> None:
        """Upload that would exceed quota raises 413."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        # User has used 1023 MB, uploading 2 MB would exceed 1 GB
        conn.fetchval.return_value = 1023 * 1024 * 1024

        with pytest.raises(HTTPException) as exc_info:
            await check_storage_quota(conn, user_id, 2 * 1024 * 1024)

        assert exc_info.value.status_code == 413
        assert "Storage quota exceeded (1 GB limit)" in exc_info.value.detail

    @pytest.mark.asyncio
    async def test_exactly_at_quota_allows(self) -> None:
        """Upload that brings usage exactly to quota limit should pass."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        # User has used (1 GB - 100 bytes), uploading exactly 100 bytes
        current = STORAGE_QUOTA_BYTES - 100
        conn.fetchval.return_value = current

        await check_storage_quota(conn, user_id, 100)

    @pytest.mark.asyncio
    async def test_one_byte_over_rejects(self) -> None:
        """Upload that exceeds quota by 1 byte should raise 413."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        # User exactly at quota
        conn.fetchval.return_value = STORAGE_QUOTA_BYTES

        with pytest.raises(HTTPException) as exc_info:
            await check_storage_quota(conn, user_id, 1)

        assert exc_info.value.status_code == 413

    @pytest.mark.asyncio
    async def test_creates_row_on_demand_for_new_user(self) -> None:
        """When no quota row exists, creates one via ON CONFLICT DO NOTHING."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        # fetchval returns None (no row)
        conn.fetchval.return_value = None

        # Should not raise (0 + incoming < quota)
        await check_storage_quota(conn, user_id, 1024)

        # Should have called execute to insert the row
        conn.execute.assert_called_once()
        call_args = conn.execute.call_args
        assert "ON CONFLICT DO NOTHING" in call_args[0][0]

    @pytest.mark.asyncio
    async def test_new_user_exceeds_quota_rejects(self) -> None:
        """New user uploading more than quota immediately should be rejected."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        conn.fetchval.return_value = None

        with pytest.raises(HTTPException) as exc_info:
            await check_storage_quota(conn, user_id, STORAGE_QUOTA_BYTES + 1)

        assert exc_info.value.status_code == 413


class TestIncrementStorage:
    """Test increment_storage SQL operations."""

    @pytest.mark.asyncio
    async def test_calls_upsert_with_correct_params(self) -> None:
        """increment_storage should execute an upsert query."""
        conn = AsyncMock()
        user_id = uuid.uuid4()
        bytes_added = 5 * 1024 * 1024

        await increment_storage(conn, user_id, bytes_added)

        conn.execute.assert_called_once()
        call_args = conn.execute.call_args
        assert "ON CONFLICT" in call_args[0][0]
        assert call_args[0][1] == user_id
        assert call_args[0][2] == bytes_added


class TestCreateQuotaRow:
    """Test create_quota_row for registration flow."""

    @pytest.mark.asyncio
    async def test_inserts_with_conflict_handling(self) -> None:
        """create_quota_row uses ON CONFLICT DO NOTHING."""
        conn = AsyncMock()
        user_id = uuid.uuid4()

        await create_quota_row(conn, user_id)

        conn.execute.assert_called_once()
        call_args = conn.execute.call_args
        assert "ON CONFLICT DO NOTHING" in call_args[0][0]
        assert call_args[0][1] == user_id
