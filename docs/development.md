# Development Guide

## Prerequisites

- macOS 14+ (Sonoma)
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Just](https://github.com/casey/just) command runner
- [dbmate](https://github.com/amacneil/dbmate) (database migrations)
- Swift 6 toolchain or Xcode (for macOS app)

## Environment Setup

```bash
cp .env.example .env
# Fill in NVIDIA_API_KEY for LLM processing
```

Key variables documented in `.env.example`. The processing worker is disabled if `NVIDIA_API_KEY` is not set: artifacts will be uploaded but remain in `pending` status.

## Development Workflows

### Full Stack (Backend + DB)

```bash
just dev
```

Starts PostgreSQL (via Docker Compose) and runs the API with uvicorn hot reload on port 8018.

### Database Only

```bash
just dev-db       # Start PostgreSQL
just dev-down     # Stop PostgreSQL
```

### Migrations

```bash
just db-migrate          # Apply all pending migrations
just db-new <name>       # Create a new migration file
just db-rollback         # Rollback last migration
```

### macOS App

```bash
just macos-build    # Build (debug)
just macos-run      # Build, sign, and run
```

The app defaults to `http://localhost:8018` for the backend URL. Override with `BUNDLE_API_URL` env var.

### Code Quality

```bash
just lint       # ruff check + pyright
just format     # ruff format
just test       # pytest (all services)
```

## Code Signing (Required for Hotkey)

The global hotkey uses a CGEvent tap, which requires Accessibility and Input Monitoring permissions. macOS ties these permissions to the code signature.

Create a self-signed certificate once:

1. Open Keychain Access
2. Menu: Keychain Access → Certificate Assistant → Create a Certificate
3. Name: `Bundle Dev`, Type: Self Signed Root, Certificate Type: Code Signing

`just macos-run` signs the binary with this identity. Grant Accessibility + Input Monitoring permissions once in System Settings and they persist across rebuilds.

Override the signing identity: `BUNDLE_SIGN_IDENTITY="My Cert" just macos-run`

## Project Layout

### Python (uv workspace)

Root `pyproject.toml` defines the workspace with two members:
- `services/api` (bundle-api): FastAPI service with all backend dependencies
- `libs/common` (bundle-common): shared structlog configuration

All Python dependencies resolved via a single `uv.lock`.

### Swift (SPM)

`apps/macos/Package.swift` defines the executable target and test target. No external dependencies: uses raw SQLite3, URLSession, and Keychain APIs directly.

## Available Commands

| Command | Description |
|---------|-------------|
| `just dev` | Start PostgreSQL + API with hot reload |
| `just dev-db` | Start only PostgreSQL |
| `just dev-down` | Stop development services |
| `just lint` | Run ruff check + pyright |
| `just format` | Run ruff formatter |
| `just test` | Run all Python tests |
| `just db-migrate` | Apply database migrations |
| `just db-new <name>` | Create a new migration |
| `just db-rollback` | Rollback last migration |
| `just docker-build` | Build production Docker image |
| `just macos-build` | Build macOS app (debug) |
| `just macos-run` | Build, sign, and run macOS app |
