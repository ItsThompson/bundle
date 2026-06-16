"""Shared tag fetching used by both artifact listing and search."""

import uuid

import asyncpg


async def fetch_tags_for_artifacts(
    conn: asyncpg.Connection,
    artifact_ids: list[uuid.UUID],
) -> dict[uuid.UUID, list[str]]:
    """Fetch tags for a batch of artifacts. Returns {artifact_id: [tag_names]}."""
    if not artifact_ids:
        return {}

    rows = await conn.fetch(
        """
        SELECT artifact_id, name
        FROM artifact_tags
        WHERE artifact_id = ANY($1::uuid[])
        """,
        artifact_ids,
    )

    tags_by_artifact: dict[uuid.UUID, list[str]] = {}
    for row in rows:
        tags_by_artifact.setdefault(row["artifact_id"], []).append(row["name"])
    return tags_by_artifact
