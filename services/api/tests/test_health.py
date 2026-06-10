"""Tests for the API health endpoint."""

from api.main import app
from fastapi.testclient import TestClient


def test_health_endpoint_returns_ok() -> None:
    """GET /health returns 200 with status ok."""
    client = TestClient(app)
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
