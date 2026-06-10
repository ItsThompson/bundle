"""Tests for the hybrid search endpoint: GET /api/v1/artifacts/search."""

import asyncio
import uuid
from unittest.mock import AsyncMock

import asyncpg
from fastapi.testclient import TestClient

TEST_DATABASE_URL = "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"


def _fake_embedding(seed: float = 0.5) -> list[float]:
    """Generate a deterministic fake embedding vector (1536 dimensions)."""
    import math

    return [math.sin(i * seed) * 0.5 for i in range(1536)]


class TestSearchEndpoint:
    """Tests for GET /api/v1/artifacts/search?q={query}."""

    def test_search_requires_auth(self, client: TestClient) -> None:
        """Search without a token returns 401."""
        response = client.get("/api/v1/artifacts/search?q=test")
        assert response.status_code == 401

    def test_search_requires_query_param(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Search without q parameter returns 422."""
        response = client.get("/api/v1/artifacts/search", headers=auth_headers)
        assert response.status_code == 422

    def test_search_empty_query_rejected(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Search with empty string q returns 422 (min_length=1)."""
        response = client.get("/api/v1/artifacts/search?q=", headers=auth_headers)
        assert response.status_code == 422

    def test_search_returns_503_without_embedding_provider(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Search returns 503 when embedding provider is not configured."""
        # By default in tests, no embedding provider is set on app.state
        response = client.get("/api/v1/artifacts/search?q=test", headers=auth_headers)
        assert response.status_code == 503
        assert "embedding provider" in response.json()["detail"].lower()

    def test_search_returns_results_matching_text(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search returns artifacts matching full-text query."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload a note with searchable content
        note_content = b"Typography best practices for web design"
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", note_content, "text/markdown")},
            headers=auth_headers,
        )

        # Upload another note that won't match
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T13:00:00Z"},
            files={"file": ("other.md", b"Cooking recipes for dinner", "text/markdown")},
            headers=auth_headers,
        )

        # Mock embedding provider: return a fake embedding for the query
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=_fake_embedding(0.1))
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        response = client.get(
            "/api/v1/artifacts/search?q=typography", headers=auth_headers
        )

        assert response.status_code == 200
        data = response.json()
        assert data["query"] == "typography"
        assert data["total"] >= 1
        # The typography note should appear in results (FTS match)
        found = any(
            item["content_text"] and "typography" in item["content_text"].lower()
            for item in data["items"]
        )
        assert found, "Expected typography note in search results"

    def test_search_returns_results_with_tags(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search results include tags for each artifact."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload a note
        resp = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", b"Machine learning fundamentals guide", "text/markdown")},
            headers=auth_headers,
        )
        artifact_id = resp.json()["id"]

        # Manually insert tags
        async def add_tags() -> None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                await conn.execute(
                    "INSERT INTO artifact_tags (artifact_id, name) VALUES ($1, $2), ($1, $3)",
                    uuid.UUID(artifact_id),
                    "ml",
                    "tutorial",
                )
            finally:
                await conn.close()

        asyncio.run(add_tags())

        # Mock embedding provider
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=_fake_embedding(0.2))
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        response = client.get(
            "/api/v1/artifacts/search?q=machine+learning", headers=auth_headers
        )

        assert response.status_code == 200
        data = response.json()
        assert data["total"] >= 1

        # Find the artifact and check tags
        matching = [item for item in data["items"] if item["id"] == artifact_id]
        assert len(matching) == 1
        assert sorted(matching[0]["tags"]) == ["ml", "tutorial"]

    def test_search_empty_results(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search with no matches returns empty items list."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload a note that won't match the query
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", b"Some random content", "text/markdown")},
            headers=auth_headers,
        )

        # Mock embedding provider: return embedding far from any stored embedding
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=_fake_embedding(99.9))
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        response = client.get(
            "/api/v1/artifacts/search?q=zzzznonexistentxyz", headers=auth_headers
        )

        assert response.status_code == 200
        data = response.json()
        assert data["items"] == []
        assert data["total"] == 0
        assert data["query"] == "zzzznonexistentxyz"

    def test_search_limited_to_40_results(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search returns at most 40 results."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Create 50 notes all containing "python"
        for i in range(50):
            client.post(
                "/api/v1/artifacts",
                data={"type": "note", "created_at": f"2026-06-{10 + i % 20:02d}T{i % 24:02d}:00:00Z"},
                files={"file": (f"note{i}.md", f"Python programming tip #{i}".encode(), "text/markdown")},
                headers=auth_headers,
            )

        # Mock embedding provider
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=_fake_embedding(0.3))
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        response = client.get(
            "/api/v1/artifacts/search?q=python", headers=auth_headers
        )

        assert response.status_code == 200
        data = response.json()
        assert data["total"] <= 40

    def test_search_response_format(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search response has correct format with all expected fields."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload a note
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", b"Design system documentation", "text/markdown")},
            headers=auth_headers,
        )

        # Mock embedding provider
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=_fake_embedding(0.4))
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        response = client.get(
            "/api/v1/artifacts/search?q=design", headers=auth_headers
        )

        assert response.status_code == 200
        data = response.json()

        # Verify top-level response fields
        assert "items" in data
        assert "query" in data
        assert "total" in data
        assert data["query"] == "design"

        if data["total"] > 0:
            item = data["items"][0]
            # Verify item fields
            assert "id" in item
            assert "type" in item
            assert "content_text" in item
            assert "status" in item
            assert "created_at" in item
            assert "updated_at" in item
            assert "tags" in item
            assert "text_rank" in item
            assert "vector_similarity" in item

    def test_search_vector_similarity_match(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search finds artifacts via vector similarity even without text match."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload a note
        resp = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", b"Some content about cats", "text/markdown")},
            headers=auth_headers,
        )
        artifact_id = resp.json()["id"]

        # Insert a high-similarity embedding for this artifact
        query_embedding = [0.5] * 1536  # Simplified: same as query will produce

        async def insert_embedding() -> None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                await conn.execute(
                    """
                    INSERT INTO artifact_embeddings (artifact_id, embedding, model)
                    VALUES ($1, $2::vector, 'text-embedding-3-small')
                    """,
                    uuid.UUID(artifact_id),
                    str(query_embedding),
                )
            finally:
                await conn.close()

        asyncio.run(insert_embedding())

        # Mock embedding provider to return the same embedding (perfect similarity)
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=query_embedding)
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        # Search for something that won't text-match but will vector-match
        response = client.get(
            "/api/v1/artifacts/search?q=felines+pets", headers=auth_headers
        )

        assert response.status_code == 200
        data = response.json()
        # With perfect cosine similarity (1.0 > 0.3 threshold), should find the artifact
        assert data["total"] >= 1
        found_ids = [item["id"] for item in data["items"]]
        assert artifact_id in found_ids

    def test_search_only_returns_own_artifacts(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Search results are scoped to the authenticated user only."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload artifact as first user
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", b"Secret project notes", "text/markdown")},
            headers=auth_headers,
        )

        # Register and authenticate second user
        resp = client.post(
            "/api/auth/register",
            json={"email": "other@example.com", "password": "OtherPass1"},
        )
        other_token = resp.json()["access_token"]
        other_headers = {"Authorization": f"Bearer {other_token}"}

        # Mock embedding provider
        mock_provider = AsyncMock()
        mock_provider.embed = AsyncMock(return_value=_fake_embedding(0.5))
        mock_provider.dimensions = 1536
        client.app.state.embedding_provider = mock_provider

        # Second user searches: should find nothing
        response = client.get(
            "/api/v1/artifacts/search?q=secret+project", headers=other_headers
        )

        assert response.status_code == 200
        data = response.json()
        assert data["total"] == 0
        assert data["items"] == []
