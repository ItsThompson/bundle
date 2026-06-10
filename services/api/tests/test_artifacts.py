"""Tests for artifact endpoints: upload, list, and content retrieval."""

from fastapi.testclient import TestClient

TEST_DATABASE_URL = "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"


class TestArtifactUpload:
    """Tests for POST /api/v1/artifacts."""

    def test_upload_requires_auth(self, client: TestClient) -> None:
        """Upload without a token returns 401."""
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("test.png", b"fake-png-data", "image/png")},
        )
        assert response.status_code == 401

    def test_upload_screenshot_success(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Valid screenshot upload returns 201 with artifact data."""
        # Use tmp_path for artifact storage
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("screenshot.png", b"\x89PNG\r\n\x1a\n" + b"\x00" * 100, "image/png")},
            headers=auth_headers,
        )

        assert response.status_code == 201
        data = response.json()
        assert data["type"] == "screenshot"
        assert data["status"] == "pending"
        assert "id" in data
        assert "created_at" in data
        assert "updated_at" in data

    def test_upload_invalid_type(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Upload with invalid type returns 422."""
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "video", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("test.mp4", b"data", "video/mp4")},
            headers=auth_headers,
        )
        assert response.status_code == 422
        assert "type must be one of" in response.json()["detail"]

    def test_upload_invalid_timestamp(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Upload with unparseable timestamp returns 422."""
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "not-a-date"},
            files={"file": ("test.png", b"data", "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 422
        assert "ISO 8601" in response.json()["detail"]

    def test_upload_empty_file(
        self, client: TestClient, auth_headers: dict[str, str]
    ) -> None:
        """Upload with empty file returns 422."""
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("empty.png", b"", "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 422
        assert "empty" in response.json()["detail"].lower()

    def test_upload_creates_file_on_disk(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Upload saves the file to the configured artifacts path."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        file_content = b"\x89PNG\r\n\x1a\n" + b"\x00" * 50
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("shot.png", file_content, "image/png")},
            headers=auth_headers,
        )

        assert response.status_code == 201

        # Verify file exists on disk
        png_files = list(tmp_path.rglob("*.png"))
        assert len(png_files) == 1
        assert png_files[0].read_bytes() == file_content


class TestArtifactList:
    """Tests for GET /api/v1/artifacts."""

    def test_list_requires_auth(self, client: TestClient) -> None:
        """List without a token returns 401."""
        response = client.get("/api/v1/artifacts")
        assert response.status_code == 401

    def test_list_empty(self, client: TestClient, auth_headers: dict[str, str]) -> None:
        """List with no artifacts returns empty list."""
        response = client.get("/api/v1/artifacts", headers=auth_headers)
        assert response.status_code == 200
        data = response.json()
        assert data["items"] == []
        assert data["total"] == 0
        assert data["limit"] == 40
        assert data["offset"] == 0

    def test_list_returns_artifacts_newest_first(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """List returns artifacts ordered by created_at descending."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload two artifacts with different timestamps
        client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-09T10:00:00Z"},
            files={"file": ("older.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("newer.md", b"# Hello", "text/markdown")},
            headers=auth_headers,
        )

        response = client.get("/api/v1/artifacts", headers=auth_headers)
        assert response.status_code == 200
        data = response.json()
        assert data["total"] == 2
        assert len(data["items"]) == 2
        # Newest first
        assert data["items"][0]["type"] == "note"
        assert data["items"][1]["type"] == "screenshot"

    def test_list_pagination(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """List respects limit and offset parameters."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload 3 artifacts
        for i in range(3):
            client.post(
                "/api/v1/artifacts",
                data={"type": "screenshot", "created_at": f"2026-06-1{i}T10:00:00Z"},
                files={"file": (f"shot{i}.png", b"\x89PNG" + bytes([i]) * 10, "image/png")},
                headers=auth_headers,
            )

        # Request with limit=2
        response = client.get(
            "/api/v1/artifacts?limit=2&offset=0", headers=auth_headers
        )
        data = response.json()
        assert len(data["items"]) == 2
        assert data["total"] == 3

        # Request second page
        response = client.get(
            "/api/v1/artifacts?limit=2&offset=2", headers=auth_headers
        )
        data = response.json()
        assert len(data["items"]) == 1
        assert data["total"] == 3

    def test_list_includes_tags(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """List returns tags associated with each artifact."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        # Upload an artifact
        resp = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T10:00:00Z"},
            files={"file": ("shot.png", b"\x89PNG" + b"\x00" * 10, "image/png")},
            headers=auth_headers,
        )
        artifact_id = resp.json()["id"]

        # Manually insert tags
        import asyncio

        import asyncpg

        async def add_tags() -> None:
            conn = await asyncpg.connect(
                "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"
            )
            try:
                await conn.execute(
                    "INSERT INTO artifact_tags (artifact_id, name) VALUES ($1, $2), ($1, $3)",
                    artifact_id,
                    "design",
                    "ui",
                )
            finally:
                await conn.close()

        asyncio.run(add_tags())

        response = client.get("/api/v1/artifacts", headers=auth_headers)
        data = response.json()
        assert len(data["items"]) == 1
        assert sorted(data["items"][0]["tags"]) == ["design", "ui"]


class TestArtifactContent:
    """Tests for GET /api/v1/artifacts/{id}/content."""

    def test_content_requires_auth(self, client: TestClient) -> None:
        """Content retrieval without token returns 401."""
        import uuid

        response = client.get(f"/api/v1/artifacts/{uuid.uuid4()}/content")
        assert response.status_code == 401

    def test_content_not_found(self, client: TestClient, auth_headers: dict[str, str]) -> None:
        """Content for non-existent artifact returns 404."""
        import uuid

        response = client.get(
            f"/api/v1/artifacts/{uuid.uuid4()}/content", headers=auth_headers
        )
        assert response.status_code == 404

    def test_content_serves_file(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Content endpoint serves the artifact file."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        file_content = b"\x89PNG\r\n\x1a\n" + b"\x00" * 50
        resp = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("shot.png", file_content, "image/png")},
            headers=auth_headers,
        )
        artifact_id = resp.json()["id"]

        response = client.get(
            f"/api/v1/artifacts/{artifact_id}/content", headers=auth_headers
        )
        assert response.status_code == 200
        assert response.headers["content-type"] == "image/png"
        assert response.content == file_content


class TestNoteUpload:
    """Tests for POST /api/v1/artifacts with type='note'."""

    def test_upload_note_success(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Valid note upload returns 201 and saves .md file."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        note_content = b"# My Note\n\nThis is a test note with some content."
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", note_content, "text/markdown")},
            headers=auth_headers,
        )

        assert response.status_code == 201
        data = response.json()
        assert data["type"] == "note"
        assert data["status"] == "pending"

    def test_upload_note_stores_content_text(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Note upload stores content_text in the database for full-text search."""
        import asyncio

        import asyncpg

        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        note_text = "Design ideas for the navigation refactor"
        note_content = note_text.encode("utf-8")
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T14:30:00Z"},
            files={"file": ("idea.md", note_content, "text/markdown")},
            headers=auth_headers,
        )

        assert response.status_code == 201
        artifact_id = response.json()["id"]

        # Verify content_text is stored in DB
        async def check_content_text() -> str | None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                row = await conn.fetchrow(
                    "SELECT content_text FROM artifacts WHERE id = $1",
                    __import__("uuid").UUID(artifact_id),
                )
                return row["content_text"] if row else None
            finally:
                await conn.close()

        content_text = asyncio.run(check_content_text())
        assert content_text == note_text

    def test_upload_note_creates_md_file(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Note upload saves the .md file to disk."""
        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        note_content = b"Some quick thoughts about typography."
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("thoughts.md", note_content, "text/markdown")},
            headers=auth_headers,
        )

        assert response.status_code == 201

        md_files = list(tmp_path.rglob("*.md"))
        assert len(md_files) == 1
        assert md_files[0].read_bytes() == note_content

    def test_upload_note_screenshot_has_no_content_text(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Screenshot uploads do NOT populate content_text."""
        import asyncio

        import asyncpg

        monkeypatch.setattr(
            client.app.state.settings, "artifacts_path", str(tmp_path)
        )

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("shot.png", b"\x89PNG" + b"\x00" * 50, "image/png")},
            headers=auth_headers,
        )

        assert response.status_code == 201
        artifact_id = response.json()["id"]

        async def check_content_text() -> str | None:
            conn = await asyncpg.connect(TEST_DATABASE_URL)
            try:
                row = await conn.fetchrow(
                    "SELECT content_text FROM artifacts WHERE id = $1",
                    __import__("uuid").UUID(artifact_id),
                )
                return row["content_text"] if row else None
            finally:
                await conn.close()

        content_text = asyncio.run(check_content_text())
        assert content_text is None
