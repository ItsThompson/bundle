"""Tests for the health endpoint."""

from unittest.mock import AsyncMock, MagicMock

from api.routers.health import router
from fastapi import FastAPI
from fastapi.testclient import TestClient


def create_test_app(pool_mock: MagicMock) -> FastAPI:
    """Create a test FastAPI app with a mocked pool in state."""
    app = FastAPI()
    app.state.pool = pool_mock
    app.include_router(router)
    return app


class TestHealthEndpoint:
    """Test the /health endpoint behavior."""

    def test_healthy_when_db_connected(self) -> None:
        """Returns 200 with healthy status when DB query succeeds."""
        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(return_value=1)

        mock_pool = MagicMock()
        mock_pool.acquire = MagicMock(return_value=AsyncMock(
            __aenter__=AsyncMock(return_value=mock_conn),
            __aexit__=AsyncMock(return_value=None),
        ))

        app = create_test_app(mock_pool)
        client = TestClient(app)
        response = client.get("/health")

        assert response.status_code == 200
        assert response.json() == {"status": "healthy", "db": "connected"}

    def test_unhealthy_when_db_disconnected(self) -> None:
        """Returns 503 with unhealthy status when DB query fails."""
        mock_pool = MagicMock()
        mock_pool.acquire = MagicMock(return_value=AsyncMock(
            __aenter__=AsyncMock(side_effect=ConnectionError("Connection refused")),
            __aexit__=AsyncMock(return_value=None),
        ))

        app = create_test_app(mock_pool)
        client = TestClient(app)
        response = client.get("/health")

        assert response.status_code == 503
        assert response.json() == {"status": "unhealthy", "db": "disconnected"}

    def test_unhealthy_when_query_times_out(self) -> None:
        """Returns 503 when DB query raises a timeout."""
        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(side_effect=TimeoutError("query timed out"))

        mock_pool = MagicMock()
        mock_pool.acquire = MagicMock(return_value=AsyncMock(
            __aenter__=AsyncMock(return_value=mock_conn),
            __aexit__=AsyncMock(return_value=None),
        ))

        app = create_test_app(mock_pool)
        client = TestClient(app)
        response = client.get("/health")

        assert response.status_code == 503
        assert response.json() == {"status": "unhealthy", "db": "disconnected"}
