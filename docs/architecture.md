# Architecture

## Overview

Bundle is a monorepo containing a macOS native app (Swift) and a single FastAPI backend service (Python). The macOS app captures artifacts, stores them locally in SQLite, and syncs with the backend over REST. The backend handles auth, artifact storage, LLM-based processing (tagging + embedding), and hybrid search.

## Repository Structure

```
bundle/
├── apps/macos/              # Swift macOS menubar app (SPM)
├── services/api/            # FastAPI backend service
├── libs/common/             # Shared Python utilities (structlog config)
├── deployments/cloudflare/  # Tunnel config template
├── scripts/                 # deploy.sh
├── docker-compose.yml       # Production stack (API + PostgreSQL)
├── docker-compose.dev.yml   # Dev stack (PostgreSQL only)
├── justfile                 # Task orchestration
├── pyproject.toml           # Root uv workspace
└── lefthook.yml             # Pre-commit hooks (ruff)
```

## Component Roles

| Component | Location | Responsibility |
|-----------|----------|----------------|
| macOS App | `apps/macos/` | Menubar lifecycle, global hotkey, capture flows (screenshot/note/link), local SQLite cache, retrieval grid, tag filtering, sync with backend |
| FastAPI Service | `services/api/` | Auth (JWT), artifact upload/list/search, LLM processing worker, hybrid search |
| Common Lib | `libs/common/` | Shared structlog configuration |
| PostgreSQL + pgvector | Docker container | Source of truth: users, artifacts, tags, embeddings |

## High-Level Data Flow

```
┌────────────────────────────────┐
│ macOS App (Swift/SwiftUI)      │
│                                │
│  Capture → SQLite → Upload     │
│  Retrieval ← SQLite ← Sync     │
│  Search → Backend → Results    │
└────────────────────────────────┘
              │ HTTPS (REST + JSON)
              ▼
┌────────────────────────────────┐
│ FastAPI Backend                │
│                                │
│  Auth (JWT Bearer)             │
│  Artifacts (CRUD + file store) │
│  Processing Worker (async)     │
│  Search (BM25 + cosine)        │
└────────────────────────────────┘
         │               │
         ▼               ▼
┌──────────────┐  ┌───────────────────┐
│ PostgreSQL   │  │ File System       │
│ + pgvector   │  │ (artifact files)  │
└──────────────┘  └───────────────────┘
         │
         ▼
┌───────────────────┐
│ NVIDIA NIM APIs   │
│ (LLM + Embedding) │
└───────────────────┘
```

## Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| Single FastAPI service | Small endpoint count, single developer. Split when needed. |
| REST + JSON (not gRPC) | Native URLSession client, OpenAPI for free, simple CRUD. |
| Backend is source of truth | Multi-client future (iOS, web). SQLite is a local cache. |
| PostgreSQL + pgvector | Embeddings and relational data in one DB, joined in one query. |
| Artifact status column as job queue | At low volume, the artifact row IS the job. No separate queue. |
| NVIDIA NIM for LLM + embeddings | Single API key for both vision/text tagging and embedding generation. |
| JWT Bearer tokens (not cookies) | Native app stores tokens in macOS Keychain, not a browser. |
| uv workspaces | Single lockfile, shared libs, per-service Dockerfiles. |
| dbmate migrations | Plain SQL, language-agnostic. No ORM coupling. |
| Raw SQLite3 C API (no ORM) | Zero external dependencies on macOS side for local cache. |
| Cloudflare Tunnel | Zero-config TLS, no exposed ports, DDoS protection. |
| Swift Package Manager | Standard tooling, no Xcode project lock-in for building. |

## Technology Stack

| Layer | Technology |
|-------|-----------|
| macOS UI | Swift 6, SwiftUI, AppKit (NSPanel, CGEvent tap) |
| macOS networking | URLSession + Codable |
| macOS local storage | SQLite3 (raw C API) |
| macOS secrets | Keychain Services |
| Backend framework | FastAPI (Python 3.12) |
| Backend package mgmt | uv workspaces |
| Database | PostgreSQL 16 + pgvector |
| Database driver | asyncpg |
| Migrations | dbmate |
| Auth | PyJWT + bcrypt |
| LLM | NVIDIA NIM (Kimi K2.6 for vision/text, nv-embedqa-e5-v5 for embeddings) |
| HTTP client | httpx (async, for link fetching) |
| Image processing | Pillow (resize for vision model) |
| Logging | structlog |
| Error tracking | Sentry (optional) |
| Linting | Ruff (lint + format) |
| Type checking | Pyright |
| Testing | pytest + pytest-asyncio |
| Containerization | Docker (multi-stage) |
| Orchestration | Docker Compose |
| CI | GitHub Actions |
| Deployment | Hetzner VPS + SSH deploy script |
| Edge/TLS | Cloudflare Tunnel |
| Task runner | just |
| Git hooks | lefthook |
