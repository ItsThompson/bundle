# Processing Pipeline

## Overview

The processing pipeline transforms raw artifacts into tagged, searchable items. It runs as an async task within the FastAPI process (not a separate service or container).

Canonical source: `services/api/src/api/processing/`

## Components

| File | Responsibility |
|------|----------------|
| `worker.py` | Async processing loop: claims pending artifacts, orchestrates tagging + embedding, handles failures |
| `tagger.py` | Generates 3-7 descriptive tags per artifact via LLM |
| `embedder.py` | Generates embedding vectors via embedding provider |
| `providers.py` | Protocol definitions for LLM and embedding providers |
| `nim_llm_provider.py` | NVIDIA NIM LLM provider (Kimi K2.6, OpenAI-compatible API) |
| `nim_embedding_provider.py` | NVIDIA NIM embedding provider (nv-embedqa-e5-v5, 1024 dimensions) |
| `image_utils.py` | Resize images to max 2048px for vision model |

## Worker Lifecycle

1. **Startup recovery**: resets any artifacts stuck in `processing` status (crash recovery)
2. **Poll loop**: waits for notification or 5-second timeout, then claims and processes pending artifacts
3. **Notification**: `processing_service.notify()` wakes the worker immediately on new uploads
4. **Shutdown**: task is cancelled gracefully during app lifespan teardown

The worker is only started if `NVIDIA_API_KEY` is configured. Without it, artifacts remain in `pending` status indefinitely.

## Processing by Artifact Type

| Type | Tag Input | Embedding Input |
|------|-----------|-----------------|
| Screenshot | Image bytes sent to vision model | Generated tags as text |
| Note | Full note text | Full note text |
| Link | Fetched page content (HTML stripped, truncated to 4000 chars) | Same fetched content |
| Link (fetch fails) | URL string only (fallback) | URL string only |

## Retry Strategy

| Attempt | Backoff Formula | Wait Before Retry |
|---------|-----------------|-------------------|
| 1 | 1² × 30s | 30 seconds |
| 2 | 2² × 30s | 2 minutes |
| 3 | (max_attempts reached) | Marked as `failed` |

Non-retryable errors (e.g., empty content) mark the artifact as `failed` immediately regardless of attempt count.

Manual retry (`POST /artifacts/{id}/retry`) resets attempts to 0 and status to `pending`.

## LLM Provider Configuration

Both providers use the NVIDIA NIM API at `https://integrate.api.nvidia.com/v1`:

| Provider | Model | Purpose | Dimensions |
|----------|-------|---------|------------|
| NimLLMProvider | `moonshotai/kimi-k2.6` | Vision + text tagging | N/A |
| NimEmbeddingProvider | `nvidia/nv-embedqa-e5-v5` | Passage/query embeddings | 1024 |

The embedding provider distinguishes between `passage` embeddings (for indexing artifacts) and `query` embeddings (for search queries) via the `input_type` parameter.

## Search

Hybrid search combines two signals:

| Signal | Weight | Source |
|--------|--------|--------|
| BM25 full-text | 0.4 | `search_vector` (tsvector on content_text) + tag name tsvector |
| Vector cosine similarity | 0.6 | `artifact_embeddings` via pgvector HNSW index |

Results include artifacts matching either full-text search, tag name match, or vector similarity above 0.3 threshold. Maximum 40 results returned.

Search service: `services/api/src/api/services/search_service.py`
