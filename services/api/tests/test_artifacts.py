"""Tests for the artifact upload endpoint."""

from fastapi.testclient import TestClient


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
