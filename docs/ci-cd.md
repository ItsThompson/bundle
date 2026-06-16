# CI/CD

## CI Pipeline

GitHub Actions runs on every push/PR to `main`. Two sequential jobs:

```
push/PR → lint → test
```

### Lint Job

- Installs uv + Python 3.12
- Runs `ruff check .` (lint)
- Runs `pyright` (type checking)

### Test Job (gated by lint)

- Provisions a `pgvector/pgvector:pg16` service container
- Installs dbmate, runs migrations against `bundle_test` database
- Runs `pytest`

Canonical source: `.github/workflows/ci.yml`

## Pre-commit Hooks

lefthook runs on pre-commit:
- `ruff check` on staged `.py` files
- `ruff format --check` on staged `.py` files

Canonical source: `lefthook.yml`

## Deployment

### Infrastructure

- Single Hetzner VPS
- Cloudflare Tunnel for HTTPS ingress (no exposed ports)
- Docker Compose for orchestration (API + PostgreSQL)

### Deploy Script

`scripts/deploy.sh` performs:

1. SSH to host
2. Pull/build updated images
3. Save current state for rollback
4. `docker compose up -d`
5. Health check loop (30s timeout, 2s interval)
6. On failure: automatic rollback to previous images

Usage:
```bash
./scripts/deploy.sh user@server.example.com
./scripts/deploy.sh user@server.example.com --rollback  # Manual rollback
```

### Production Docker Image

Multi-stage build defined in `services/api/Dockerfile`:

1. **deps stage**: installs production Python dependencies via uv
2. **runtime stage**: copies venv + source, runs uvicorn with 2 workers on port 8000

### Cloudflare Tunnel

Config template: `deployments/cloudflare/config.yml`

Routes `api.bundle.app` → `http://localhost:8000`

## No CD Workflow

Deployment is currently manual via the deploy script. There is no automated CD pipeline triggered on merge to main.
