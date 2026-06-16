# Testing

## Test Stack

- **Framework**: pytest + pytest-asyncio
- **Test client**: FastAPI `TestClient` (sync, handles lifespan)
- **Database**: real PostgreSQL (pgvector/pgvector:pg16) on port 5433
- **Fixtures**: session-scoped DB setup, per-test table cleanup

Canonical source: `services/api/tests/`

## Running Tests

```bash
# All tests
just test

# Requires PostgreSQL running:
just dev-db
```

Tests require a running PostgreSQL instance. The test fixtures create a `bundle_test` database automatically and set up all tables/indexes.

## Test Configuration

- bcrypt cost: 4 (fast for tests)
- JWT secret: hardcoded test value
- Log level: WARNING (quiet output)
- No NVIDIA API key (processing worker not started in tests)

See `services/api/tests/conftest.py` for fixture details.

## Test Files

| File | Coverage Area |
|------|---------------|
| `test_auth.py` | Registration, login, refresh, logout, email update, password change |
| `test_auth_service.py` | JWT generation/validation, password hashing, token decoding |
| `test_artifacts.py` | Upload, list, content download, pagination |
| `test_artifact_retry.py` | Retry endpoint for failed artifacts |
| `test_search.py` | Hybrid search endpoint |
| `test_sync.py` | Delta sync via `updated_since` parameter |
| `test_processing.py` | Tagger, embedder, worker unit tests |
| `test_processing_integration.py` | End-to-end processing with mocked LLM providers |
| `test_health.py` | Health check endpoint |
| `test_config.py` | Settings loading |

## CI

Tests run in GitHub Actions after lint passes. The CI workflow provisions a PostgreSQL service container and runs dbmate migrations before pytest.

See `.github/workflows/ci.yml`.
