# Data Model

## Source of Truth: PostgreSQL (Backend)

All authoritative data lives in PostgreSQL on the backend. The macOS app's SQLite is a read cache synced via delta polling.

Canonical source: `services/api/db/migrations/`

## Schema Overview

```
┌─────────────────────────┐       ┌──────────────────────────────────┐
│ auth.users              │       │ public.artifacts                 │
├─────────────────────────┤       ├──────────────────────────────────┤
│ id (UUID, PK)           │──┐    │ id (UUID, PK)                    │
│ email (VARCHAR, UNIQUE) │  │    │ user_id (UUID, FK → users)       │
│ password_hash (VARCHAR) │  └───▶│ type (TEXT: screenshot|note|link)│
│ tokens_revoked_at (TSZ) │       │ storage_path (TEXT)              │
│ created_at (TSZ)        │       │ content_text (TEXT, nullable)    │
│ updated_at (TSZ)        │       │ status (TEXT: pending|processing │
└─────────────────────────┘       │         |completed|failed)       │
                                  │ attempts (INT, default 0)        │
┌─────────────────────────┐       │ max_attempts (INT, default 3)    │
│ auth.refresh_blacklist  │       │ scheduled_after (TSZ, nullable)  │
├─────────────────────────┤       │ search_vector (tsvector, gen'd)  │
│ jti (UUID, PK)          │       │ created_at (TSZ)                 │
│ user_id (UUID, FK)      │       │ updated_at (TSZ)                 │
│ expires_at (TSZ)        │       └──────────────────────────────────┘
│ revoked_at (TSZ)        │                    │
└─────────────────────────┘                    │ 1:N
                                               ▼
                                  ┌─────────────────────────────────┐
                                  │ public.artifact_tags            │
                                  ├─────────────────────────────────┤
                                  │ id (UUID, PK)                   │
                                  │ artifact_id (UUID, FK)          │
                                  │ name (TEXT)                     │
                                  │ created_at (TSZ)                │
                                  │ UNIQUE (artifact_id, name)      │
                                  └─────────────────────────────────┘

                                  ┌─────────────────────────────────┐
                                  │ public.artifact_embeddings      │
                                  ├─────────────────────────────────┤
                                  │ artifact_id (UUID, PK, FK)      │
                                  │ embedding (VECTOR(1024))        │
                                  │ model (TEXT)                    │
                                  │ created_at (TSZ)                │
                                  └─────────────────────────────────┘
```

## Artifact Status State Machine

| From | To | Trigger |
|------|----|---------|
| (new) | pending | Artifact uploaded |
| pending | processing | Worker claims the artifact |
| processing | completed | Tags + embedding stored |
| processing | pending | Retryable failure (attempts < max) |
| processing | failed | Non-retryable error or max attempts reached |
| failed | pending | Manual retry via `POST /artifacts/{id}/retry` |

## Indexes

| Index | Table | Type | Purpose |
|-------|-------|------|---------|
| `idx_artifacts_user_created` | artifacts | B-tree (composite) | List by user, newest first |
| `idx_artifacts_status` | artifacts | B-tree (partial: pending, processing) | Worker: find processable artifacts |
| `idx_artifacts_updated` | artifacts | B-tree | Delta sync queries |
| `idx_artifacts_fts` | artifacts | GIN (tsvector) | Full-text search on content_text |
| `idx_tags_artifact` | artifact_tags | B-tree | Join tags to artifacts |
| `idx_tags_name` | artifact_tags | B-tree | Filter by tag name |
| `idx_embeddings_hnsw` | artifact_embeddings | HNSW (cosine) | Approximate nearest neighbor search |
| `idx_refresh_blacklist_user` | refresh_token_blacklist | B-tree | Per-user token queries |
| `idx_refresh_blacklist_expires` | refresh_token_blacklist | B-tree | Expired token cleanup |

## SQLite Cache (macOS App)

The local SQLite mirrors artifact metadata for fast reads and offline browsing. Schema is defined in `apps/macos/Sources/App/Storage/LocalDatabase.swift`.

Tables: `artifacts`, `tags`, `sync_state`

The cache does NOT store embeddings or full-text search vectors. Search queries always hit the backend.

## Sync Strategy

1. **On capture**: artifact inserted into SQLite with a local UUID, then uploaded to backend
2. **On upload success**: local UUID replaced with backend-assigned UUID
3. **Polling sync**: every 5 seconds while the retrieval panel is open
4. **Delta sync**: `GET /api/v1/artifacts?updated_since={timestamp}` fetches only changed artifacts
5. **Initial sync**: full paginated download with progress indicator on first open
6. **Conflict resolution**: backend wins (source of truth)
7. **Retry uploads**: pending local artifacts are retried on each sync cycle
