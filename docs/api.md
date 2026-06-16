# API Reference

## Overview

The FastAPI backend exposes REST endpoints consumed by the macOS app. All authenticated endpoints require a `Bearer` token in the `Authorization` header.

Canonical source: `services/api/src/api/routers/`

## Endpoint Summary

### Auth (`/api/auth`)

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/api/auth/register` | Public | Create account, return tokens |
| POST | `/api/auth/login` | Public | Authenticate, return tokens |
| POST | `/api/auth/refresh` | Public (refresh token in body) | Rotate token pair |
| POST | `/api/auth/logout` | Authenticated | Blacklist refresh token |
| GET | `/api/auth/me` | Authenticated | Get current user profile |
| PUT | `/api/auth/me` | Authenticated | Update email |
| POST | `/api/auth/me/password` | Authenticated | Change password (revokes other sessions) |

### Artifacts (`/api/v1/artifacts`)

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/api/v1/artifacts` | Authenticated | Upload artifact (multipart: file + type + created_at) |
| GET | `/api/v1/artifacts` | Authenticated | List artifacts (paginated, supports `updated_since` for sync) |
| GET | `/api/v1/artifacts/search?q=` | Authenticated | Hybrid search (BM25 + vector) |
| GET | `/api/v1/artifacts/{id}/content` | Authenticated | Download artifact file content |
| POST | `/api/v1/artifacts/{id}/retry` | Authenticated | Retry failed processing |

### Tags (`/api/v1/tags`)

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/v1/tags` | Authenticated | List all tags with usage counts |

### System

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/health` | Public | Health check (DB connectivity) |

## Upload Details

`POST /api/v1/artifacts` accepts multipart form data:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `file` | File | Yes | Artifact content (PNG, markdown, JSON) |
| `type` | String | Yes | One of: `screenshot`, `note`, `link` |
| `created_at` | String | Yes | ISO 8601 timestamp |
| `content_text` | String | No | URL for links, text for notes (also extracted from file for notes) |

Max file size: 50 MB.

## List/Sync Details

`GET /api/v1/artifacts` supports two modes:

- **Standard list**: paginated, newest first. Params: `limit` (1-100, default 40), `offset` (default 0)
- **Delta sync**: when `updated_since` is provided (ISO 8601), returns artifacts modified after that timestamp, ordered by `updated_at ASC`

Both modes include tags for each artifact in the response.

## Search Details

`GET /api/v1/artifacts/search?q={query}` performs hybrid search:

- Embeds the query using the NIM embedding provider (input_type="query")
- Combines BM25 full-text ranking (weight 0.4) with vector cosine similarity (weight 0.6)
- Also matches against tag names via tsvector
- Returns up to 40 results
- Requires the embedding provider to be configured (returns 503 otherwise)
