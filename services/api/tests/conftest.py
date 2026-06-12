"""Shared test fixtures for integration tests."""

import asyncio
from collections.abc import Generator
from typing import Any

import asyncpg
import pytest
from api.config import Settings
from api.main import create_app
from fastapi import FastAPI
from fastapi.testclient import TestClient

TEST_DATABASE_URL = "postgresql://bundle:bundle_dev@localhost:5433/bundle_test"


@pytest.fixture(scope="session")
def settings() -> Settings:
    """Test settings with test database."""
    return Settings(
        database_url=TEST_DATABASE_URL,
        jwt_secret="test-secret-key-minimum-32-chars!",
        jwt_access_ttl_minutes=15,
        jwt_refresh_ttl_days=7,
        bcrypt_cost=4,  # Fast for tests
        log_level="WARNING",
    )


@pytest.fixture(scope="session")
def _setup_test_db() -> Generator[None, None, None]:
    """Create test database and schema once per session."""

    async def setup() -> None:
        # Create the test database if it doesn't exist
        sys_conn = await asyncpg.connect(
            "postgresql://bundle:bundle_dev@localhost:5433/postgres"
        )
        try:
            exists = await sys_conn.fetchval(
                "SELECT 1 FROM pg_database WHERE datname = 'bundle_test'"
            )
            if not exists:
                await sys_conn.execute("CREATE DATABASE bundle_test")
        finally:
            await sys_conn.close()

        # Create schema and tables
        conn = await asyncpg.connect(TEST_DATABASE_URL)
        try:
            await conn.execute("CREATE SCHEMA IF NOT EXISTS auth")
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS auth.users (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    email VARCHAR(255) NOT NULL UNIQUE,
                    password_hash VARCHAR(255) NOT NULL,
                    tokens_revoked_at TIMESTAMPTZ,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS auth.refresh_token_blacklist (
                    jti UUID PRIMARY KEY,
                    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
                    expires_at TIMESTAMPTZ NOT NULL,
                    revoked_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
            await conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.artifacts (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
                    type TEXT NOT NULL CHECK (type IN ('screenshot', 'note', 'link')),
                    storage_path TEXT NOT NULL,
                    content_text TEXT,
                    status TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
                    attempts INT NOT NULL DEFAULT 0,
                    max_attempts INT NOT NULL DEFAULT 3,
                    scheduled_after TIMESTAMPTZ,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    search_vector tsvector GENERATED ALWAYS AS (
                        to_tsvector('english', COALESCE(content_text, ''))
                    ) STORED
                )
            """)
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.artifact_tags (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    artifact_id UUID NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    UNIQUE (artifact_id, name)
                )
            """)
            await conn.execute("DROP TABLE IF EXISTS public.artifact_embeddings")
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.artifact_embeddings (
                    artifact_id UUID PRIMARY KEY REFERENCES artifacts(id) ON DELETE CASCADE,
                    embedding vector(1024) NOT NULL,
                    model TEXT NOT NULL DEFAULT 'nvidia/nv-embedqa-e5-v5',
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
            # Ensure search_vector column exists (may be missing from prior schema)
            await conn.execute("""
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM information_schema.columns
                        WHERE table_name = 'artifacts' AND column_name = 'search_vector'
                    ) THEN
                        ALTER TABLE artifacts ADD COLUMN search_vector tsvector
                            GENERATED ALWAYS AS (
                                to_tsvector('english', COALESCE(content_text, ''))
                            ) STORED;
                    END IF;
                END $$
            """)
            # Ensure GIN index exists for full-text search
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_artifacts_fts
                ON artifacts USING gin(search_vector)
            """)
            # Ensure HNSW index exists for vector search
            await conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_embeddings_hnsw
                ON artifact_embeddings USING hnsw (embedding vector_cosine_ops)
                WITH (m = 16, ef_construction = 64)
            """)
        finally:
            await conn.close()

    asyncio.run(setup())
    yield


@pytest.fixture(autouse=True)
def _clean_tables(_setup_test_db: None) -> Generator[None, None, None]:
    """Clean all auth tables and rate limit state after each test."""
    # Clear rate limit state before each test
    from api.routers.auth import _login_attempts

    _login_attempts.clear()
    yield

    async def cleanup() -> None:
        conn = await asyncpg.connect(TEST_DATABASE_URL)
        try:
            await conn.execute("DELETE FROM public.artifact_embeddings")
            await conn.execute("DELETE FROM public.artifact_tags")
            await conn.execute("DELETE FROM public.artifacts")
            await conn.execute("DELETE FROM auth.refresh_token_blacklist")
            await conn.execute("DELETE FROM auth.users")
        finally:
            await conn.close()

    asyncio.run(cleanup())


@pytest.fixture
def app(settings: Settings, _setup_test_db: None) -> FastAPI:
    """Create test FastAPI app with real DB pool (lifespan-managed)."""
    return create_app(settings=settings)


@pytest.fixture
def client(app: FastAPI) -> Generator[TestClient, None, None]:
    """Create sync HTTP test client that handles lifespan."""
    with TestClient(app) as tc:
        yield tc


@pytest.fixture
def registered_user(client: TestClient) -> dict[str, Any]:
    """Register a test user and return the response data."""
    response = client.post(
        "/api/auth/register",
        json={"email": "test@example.com", "password": "TestPass1"},
    )
    assert response.status_code == 201
    return response.json()


@pytest.fixture
def auth_headers(registered_user: dict[str, Any]) -> dict[str, str]:
    """Return Authorization headers for the registered user."""
    return {"Authorization": f"Bearer {registered_user['access_token']}"}
