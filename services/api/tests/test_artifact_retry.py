"""Tests for POST /api/v1/artifacts/{id}/retry endpoint."""

import asyncio
import uuid

import asyncpg
from fastapi.testclient import TestClient

TEST_DATABASE_URL = "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"


def _create_failed_artifact(
    client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
) -> str:
    """Helper: upload an artifact and set it to failed status in DB."""
    monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

    resp = client.post(
        "/api/v1/artifacts",
        data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
        files={"file": ("shot.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
        headers=auth_headers,
    )
    assert resp.status_code == 201
    artifact_id = resp.json()["id"]

    # Set artifact to failed state with attempts=3
    async def set_failed() -> None:
        conn = await asyncpg.connect(TEST_DATABASE_URL)
        try:
            await conn.execute(
                """
                UPDATE artifacts
                SET status = 'failed', attempts = 3,
                    scheduled_after = '2026-06-10T00:00:00Z'
                WHERE id = $1
                """,
                uuid.UUID(artifact_id),
            )
        finally:
            await conn.close()

    asyncio.run(set_failed())
    return artifact_id


class TestArtifactRetry:
    """Tests for POST /api/v1/artifacts/{id}/retry."""

    def test_retry_requires_auth(self, client: TestClient) -> None:
        """Retry without a token returns 401."""
        response = client.post(f"/api/v1/artifacts/{uuid.uuid4()}/retry")
        assert response.status_code == 401

    def test_retry_not_found(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Retry for non-existent artifact returns 404."""
        response = client.post(
            f"/api/v1/artifacts/{uuid.uuid4()}/retry", headers=auth_headers
        )
        assert response.status_code == 404
        assert "not found" in response.json()["detail"].lower()

    def test_retry_failed_artifact_succeeds(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Retry on a failed artifact resets status to pending."""
        artifact_id = _create_failed_artifact(
            client, auth_headers, tmp_path, monkeypatch
        )

        response = client.post(
            f"/api/v1/artifacts/{artifact_id}/retry", headers=auth_headers
        )
        assert response.status_code == 200
        data = response.json()
        assert data["id"] == artifact_id
        assert data["status"] == "pending"

    def test_retry_resets_attempts_to_zero(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Retry resets attempts counter to 0."""
        artifact_id = _create_failed_artifact(
            client, auth_headers, tmp_path, monkeypatch
        )

        client.post(f"/api/v1/artifacts/{artifact_id}/retry", headers=auth_headers)

        async def check_attempts() -> int:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                return await conn.fetchval(
                    "SELECT attempts FROM artifacts WHERE id = $1",
                    uuid.UUID(artifact_id),
                )
            finally:
                await conn.close()

        attempts = asyncio.run(check_attempts())
        assert attempts == 0

    def test_retry_clears_scheduled_after(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Retry clears the scheduled_after backoff timestamp."""
        artifact_id = _create_failed_artifact(
            client, auth_headers, tmp_path, monkeypatch
        )

        client.post(f"/api/v1/artifacts/{artifact_id}/retry", headers=auth_headers)

        async def check_scheduled_after():
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                return await conn.fetchval(
                    "SELECT scheduled_after FROM artifacts WHERE id = $1",
                    uuid.UUID(artifact_id),
                )
            finally:
                await conn.close()

        scheduled_after = asyncio.run(check_scheduled_after())
        assert scheduled_after is None

    def test_retry_non_failed_artifact_returns_409(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Retry on a pending artifact returns 409 conflict."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        resp = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("shot.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        artifact_id = resp.json()["id"]

        response = client.post(
            f"/api/v1/artifacts/{artifact_id}/retry", headers=auth_headers
        )
        assert response.status_code == 409
        assert "not in failed state" in response.json()["detail"].lower()

    def test_retry_other_users_artifact_returns_404(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Retry on another user's artifact returns 404 (no info leak)."""
        artifact_id = _create_failed_artifact(
            client, auth_headers, tmp_path, monkeypatch
        )

        # Register a second user
        resp = client.post(
            "/api/auth/register",
            json={"email": "other@example.com", "password": "TestPass1"},
        )
        other_headers = {"Authorization": f"Bearer {resp.json()['access_token']}"}

        response = client.post(
            f"/api/v1/artifacts/{artifact_id}/retry", headers=other_headers
        )
        assert response.status_code == 404
