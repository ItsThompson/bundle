"""Tests for input validation and SSRF protection at the upload endpoint."""

from fastapi.testclient import TestClient


class TestLinkURLValidation:
    """Tests for URL validation on link artifacts at upload time."""

    def test_link_non_https_scheme_rejected(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Link with ftp:// scheme returns 422."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={
                "type": "link",
                "created_at": "2026-06-10T12:00:00Z",
                "content_text": "ftp://files.example.com/doc.pdf",
            },
            files={"file": ("link.json", b'{"url": "ftp://example.com"}', "application/json")},
            headers=auth_headers,
        )
        assert response.status_code == 422

    def test_link_file_scheme_rejected(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Link with file:// scheme returns 422."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={
                "type": "link",
                "created_at": "2026-06-10T12:00:00Z",
                "content_text": "file:///etc/passwd",
            },
            files={"file": ("link.json", b'{"url": "x"}', "application/json")},
            headers=auth_headers,
        )
        assert response.status_code == 422

    def test_link_gopher_scheme_rejected(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Link with gopher:// scheme returns 422."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={
                "type": "link",
                "created_at": "2026-06-10T12:00:00Z",
                "content_text": "gopher://evil.example.com/resource",
            },
            files={"file": ("link.json", b'{"url": "x"}', "application/json")},
            headers=auth_headers,
        )
        assert response.status_code == 422

    def test_link_url_over_2048_chars_rejected(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Link with URL > 2048 chars returns 422."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        long_url = "https://example.com/" + "a" * 2030
        assert len(long_url) > 2048

        response = client.post(
            "/api/v1/artifacts",
            data={
                "type": "link",
                "created_at": "2026-06-10T12:00:00Z",
                "content_text": long_url,
            },
            files={"file": ("link.json", b'{"url": "x"}', "application/json")},
            headers=auth_headers,
        )
        assert response.status_code == 422

    def test_link_valid_https_accepted(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Link with valid https URL returns 201."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={
                "type": "link",
                "created_at": "2026-06-10T12:00:00Z",
                "content_text": "https://example.com/article",
            },
            files={"file": ("link.json", b'{"url": "https://example.com"}', "application/json")},
            headers=auth_headers,
        )
        assert response.status_code == 201

    def test_link_valid_http_accepted(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Link with valid http URL returns 201."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={
                "type": "link",
                "created_at": "2026-06-10T12:00:00Z",
                "content_text": "http://example.com/article",
            },
            files={"file": ("link.json", b'{"url": "http://example.com"}', "application/json")},
            headers=auth_headers,
        )
        assert response.status_code == 201


class TestFileSizeValidation:
    """Tests for streaming file size validation (10MB cap)."""

    def test_file_over_10mb_returns_413(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """File uploads > 10MB return 413."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        # 10MB + 1 byte (exceed the limit)
        large_content = b"\x89PNG\r\n\x1a\n" + b"\x00" * (10 * 1024 * 1024)

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("big.png", large_content, "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 413
        assert "10 MB" in response.json()["detail"]

    def test_file_at_10mb_accepted(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """File at exactly 10MB should be accepted."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        # Exactly 10MB
        content = b"\x89PNG\r\n\x1a\n" + b"\x00" * (10 * 1024 * 1024 - 8)
        assert len(content) == 10 * 1024 * 1024

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("exact.png", content, "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 201

    def test_empty_file_returns_422(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Empty file upload returns 422."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("empty.md", b"", "text/markdown")},
            headers=auth_headers,
        )
        assert response.status_code == 422
        assert "empty" in response.json()["detail"].lower()


class TestPNGMagicBytesValidation:
    """Tests for PNG magic bytes validation on screenshot uploads."""

    def test_screenshot_without_png_magic_returns_422(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Screenshot upload without PNG magic bytes returns 422."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("fake.png", b"not-a-png-file-at-all", "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 422
        assert "PNG" in response.json()["detail"]

    def test_screenshot_with_jpeg_magic_returns_422(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Screenshot with JPEG magic bytes returns 422 (not PNG)."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        jpeg_content = b"\xff\xd8\xff\xe0" + b"\x00" * 100
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("photo.png", jpeg_content, "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 422
        assert "PNG" in response.json()["detail"]

    def test_screenshot_with_valid_png_accepted(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Screenshot with valid PNG magic bytes returns 201."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        png_content = b"\x89PNG\r\n\x1a\n" + b"\x00" * 100
        response = client.post(
            "/api/v1/artifacts",
            data={"type": "screenshot", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("valid.png", png_content, "image/png")},
            headers=auth_headers,
        )
        assert response.status_code == 201

    def test_note_without_png_magic_accepted(
        self, client: TestClient, auth_headers: dict[str, str], tmp_path, monkeypatch
    ) -> None:
        """Note upload does not require PNG magic bytes."""
        monkeypatch.setattr(client.app.state.settings, "artifacts_path", str(tmp_path))

        response = client.post(
            "/api/v1/artifacts",
            data={"type": "note", "created_at": "2026-06-10T12:00:00Z"},
            files={"file": ("note.md", b"# Hello World", "text/markdown")},
            headers=auth_headers,
        )
        assert response.status_code == 201
