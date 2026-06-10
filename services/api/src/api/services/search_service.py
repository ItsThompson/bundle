"""Search service: hybrid search combining BM25 text ranking and vector similarity."""

import uuid

import asyncpg
import structlog

from api.processing.providers import EmbeddingProvider

logger = structlog.get_logger("api.search_service")

# Scoring weights
BM25_WEIGHT = 0.4
VECTOR_WEIGHT = 0.6

# Maximum results returned
MAX_RESULTS = 40


async def hybrid_search(
    pool: asyncpg.Pool,
    embedding_provider: EmbeddingProvider,
    user_id: uuid.UUID,
    query: str,
) -> list[dict]:
    """Perform hybrid search combining BM25 full-text ranking with vector cosine similarity.

    Steps:
    1. Generate embedding for the search query
    2. Execute hybrid SQL: combines ts_rank (BM25) with cosine similarity
    3. Return ranked results (BM25 weight 0.4, vector weight 0.6)

    Results include items matching either:
    - Full-text search (tsvector match)
    - Vector similarity > 0.3 threshold
    """
    query_text = query.strip()
    if not query_text:
        return []

    # Embed the search query using the same model as artifact embeddings
    logger.info("search_embedding_query", query_length=len(query_text))
    query_embedding = await embedding_provider.embed(query_text)

    # Execute hybrid search query
    # Matches artifacts where:
    # 1. content_text matches via full-text search (tsvector)
    # 2. tag names match the query text
    # 3. vector similarity exceeds 0.3 threshold
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT a.id, a.type, a.storage_path, a.content_text, a.status,
                   a.created_at, a.updated_at,
                   ts_rank(a.search_vector, plainto_tsquery('english', $2)) AS text_rank,
                   1 - (e.embedding <=> $3::vector) AS vector_similarity
            FROM artifacts a
            LEFT JOIN artifact_embeddings e ON e.artifact_id = a.id
            WHERE a.user_id = $1
              AND (
                a.search_vector @@ plainto_tsquery('english', $2)
                OR 1 - (e.embedding <=> $3::vector) > 0.3
                OR EXISTS (
                    SELECT 1 FROM artifact_tags t
                    WHERE t.artifact_id = a.id
                      AND to_tsvector('english', t.name) @@ plainto_tsquery('english', $2)
                )
              )
            ORDER BY (
                COALESCE(ts_rank(a.search_vector, plainto_tsquery('english', $2)), 0) * $4 +
                COALESCE(1 - (e.embedding <=> $3::vector), 0) * $5
            ) DESC
            LIMIT $6
            """,
            user_id,
            query_text,
            str(query_embedding),
            BM25_WEIGHT,
            VECTOR_WEIGHT,
            MAX_RESULTS,
        )

        # Fetch tags for all result artifacts in one query
        artifact_ids = [row["id"] for row in rows]
        tag_rows = (
            await conn.fetch(
                """
                SELECT artifact_id, name
                FROM artifact_tags
                WHERE artifact_id = ANY($1::uuid[])
                """,
                artifact_ids,
            )
            if artifact_ids
            else []
        )

    # Group tags by artifact ID
    tags_by_artifact: dict[uuid.UUID, list[str]] = {}
    for tag_row in tag_rows:
        aid = tag_row["artifact_id"]
        tags_by_artifact.setdefault(aid, []).append(tag_row["name"])

    results = [
        {
            "id": row["id"],
            "type": row["type"],
            "content_text": row["content_text"],
            "status": row["status"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "tags": tags_by_artifact.get(row["id"], []),
            "text_rank": float(row["text_rank"]) if row["text_rank"] else 0.0,
            "vector_similarity": float(row["vector_similarity"]) if row["vector_similarity"] else 0.0,
        }
        for row in rows
    ]

    logger.info(
        "search_completed",
        user_id=str(user_id),
        query=query_text,
        result_count=len(results),
    )

    return results
