"""Tests for sync-related endpoints: updated_since filtering and tags list."""

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import asyncpg
from fastapi.testclient import TestClient

TEST_DATABASE_URL = "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"


class TestUpdatedSinceFilter:
    """Tests for GET /api/v1/artifacts?updated_since={timestamp}."""

    def test_updated_since_returns_modified_artifacts(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Artifacts modified after the given timestamp are returned."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload two artifacts
        client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-09T10:00:00Z"},
            files={"file": ("old.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("new.md", b"# Note", "text/markdown")},
            headers=auth_headers,
        )

        # Both have similar updated_at (just inserted), so use a timestamp before them
        past = "2026-06-08T00:00:00Z"
        response = client.get(
            f"/api/v1/artifacts?updated_since={past}", headers=auth_headers
        )
        assert response.status_code == 200
        data = response.json()
        assert data["total"] == 2
        assert len(data["items"]) == 2

    def test_updated_since_excludes_older_artifacts(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Artifacts not modified after the timestamp are excluded."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload an artifact
        client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("shot.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )

        # Use a timestamp in the future: nothing should match
        future = "2099-01-01T00:00:00Z"
        response = client.get(
            f"/api/v1/artifacts?updated_since={future}", headers=auth_headers
        )
        assert response.status_code == 200
        data = response.json()
        assert data["total"] == 0
        assert data["items"] == []

    def test_updated_since_ordered_by_updated_at_asc(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Delta sync results are ordered by updated_at ascending."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload artifacts and manually set different updated_at timestamps
        resp1 = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-09T10:00:00Z"},
            files={"file": ("a.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        resp2 = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("b.md", b"# Note", "text/markdown")},
            headers=auth_headers,
        )

        id1 = resp1.json()["id"]
        id2 = resp2.json()["id"]

        # Set distinct updated_at values
        async def set_updated_at() -> None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                now = datetime.now(UTC)
                await conn.execute(
                    "UPDATE artifacts SET updated_at = $1 WHERE id = $2",
                    now - timedelta(hours=2),
                    uuid.UUID(id1),
                )
                await conn.execute(
                    "UPDATE artifacts SET updated_at = $1 WHERE id = $2",
                    now - timedelta(hours=1),
                    uuid.UUID(id2),
                )
            finally:
                await conn.close()

        asyncio.run(set_updated_at())

        past = "2026-06-08T00:00:00Z"
        response = client.get(
            f"/api/v1/artifacts?updated_since={past}", headers=auth_headers
        )
        data = response.json()
        assert len(data["items"]) == 2
        # First item should be the older updated_at (screenshot), second the newer (note)
        assert data["items"][0]["id"] == id1
        assert data["items"][1]["id"] == id2

    def test_updated_since_includes_tags(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Delta sync results include tags for each artifact."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        resp = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("shot.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        artifact_id = resp.json()["id"]

        # Insert tags directly
        async def add_tags() -> None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                await conn.execute(
                    "INSERT INTO artifact_tags (artifact_id, name) VALUES ($1, $2), ($1, $3)",
                    uuid.UUID(artifact_id),
                    "design",
                    "typography",
                )
            finally:
                await conn.close()

        asyncio.run(add_tags())

        past = "2026-06-08T00:00:00Z"
        response = client.get(
            f"/api/v1/artifacts?updated_since={past}", headers=auth_headers
        )
        data = response.json()
        assert len(data["items"]) == 1
        assert sorted(data["items"][0]["tags"]) == ["design", "typography"]

    def test_updated_since_invalid_timestamp(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Invalid updated_since value returns 422."""
        response = client.get(
            "/api/v1/artifacts?updated_since=not-a-date", headers=auth_headers
        )
        assert response.status_code == 422
        assert "ISO 8601" in response.json()["detail"]

    def test_updated_since_requires_auth(self, client: TestClient) -> None:
        """Updated_since query without auth returns 401."""
        response = client.get("/api/v1/artifacts?updated_since=2026-06-08T00:00:00Z")
        assert response.status_code == 401

    def test_updated_since_respects_limit(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Delta sync respects the limit parameter for pagination."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload 3 artifacts
        for i in range(3):
            client.post(
                "/api/v1/artifacts",
                data={"type": "screenshot", "created_at": f"2026-06-1{i}T10:00:00Z"},
                files={"file": (f"s{i}.png", b"\x89PNG" + bytes([i]) * 10, "image/png")},
                headers=auth_headers,
            )

        past = "2026-06-08T00:00:00Z"
        response = client.get(
            f"/api/v1/artifacts?updated_since={past}&limit=2", headers=auth_headers
        )
        data = response.json()
        assert len(data["items"]) == 2
        assert data["total"] == 3


class TestTagsList:
    """Tests for GET /api/v1/tags."""

    def test_tags_requires_auth(self, client: TestClient) -> None:
        """Tags list without token returns 401."""
        response = client.get("/api/v1/artifacts/tags")
        assert response.status_code == 401

    def test_tags_empty(self, client: TestClient, auth_headers: dict[str, str]) -> None:
        """Tags list with no artifacts returns empty list."""
        response = client.get("/api/v1/artifacts/tags", headers=auth_headers)
        assert response.status_code == 200
        assert response.json() == []

    def test_tags_returns_counts(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Tags list returns tag names with artifact counts."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload two artifacts
        resp1 = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("a.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        resp2 = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T11:00:00Z"},
            files={"file": ("b.md", b"# Note", "text/markdown")},
            headers=auth_headers,
        )

        id1 = resp1.json()["id"]
        id2 = resp2.json()["id"]

        # Add tags: "design" on both, "typography" on first only
        async def add_tags() -> None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                await conn.execute(
                    "INSERT INTO artifact_tags (artifact_id, name) VALUES ($1, $2), ($1, $3), ($4, $2)",
                    uuid.UUID(id1),
                    "design",
                    "typography",
                    uuid.UUID(id2),
                )
            finally:
                await conn.close()

        asyncio.run(add_tags())

        response = client.get("/api/v1/artifacts/tags", headers=auth_headers)
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 2

        # Ordered by count descending
        assert data[0]["name"] == "design"
        assert data[0]["count"] == 2
        assert data[1]["name"] == "typography"
        assert data[1]["count"] == 1

    def test_tags_only_for_current_user(
        self, client: TestClient, tmp_path, monkeypatch
    ) -> None:
        """Tags list only includes tags from current user's artifacts."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Register user 1
        resp1 = client.post(
            "/api/auth/register",
            json={"email": "user1@test.com", "password": "TestPass1"},
        )
        headers1 = {"Authorization": f"Bearer {resp1.json()['access_token']}"}

        # Register user 2
        resp2 = client.post(
            "/api/auth/register",
            json={"email": "user2@test.com", "password": "TestPass1"},
        )
        headers2 = {"Authorization": f"Bearer {resp2.json()['access_token']}"}

        # User 1 uploads and gets tags
        upload_resp = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("a.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=headers1,
        )
        artifact_id = upload_resp.json()["id"]

        async def add_tags() -> None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                await conn.execute(
                    "INSERT INTO artifact_tags (artifact_id, name) VALUES ($1, $2)",
                    uuid.UUID(artifact_id),
                    "user1-tag",
                )
            finally:
                await conn.close()

        asyncio.run(add_tags())

        # User 2 should see no tags
        response = client.get("/api/v1/artifacts/tags", headers=headers2)
        assert response.status_code == 200
        assert response.json() == []

        # User 1 should see their tag
        response = client.get("/api/v1/artifacts/tags", headers=headers1)
        assert response.status_code == 200
        assert len(response.json()) == 1
        assert response.json()[0]["name"] == "user1-tag"
