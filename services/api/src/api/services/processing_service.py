"""Processing service: stub for LLM orchestration (implemented in ticket #10)."""

import uuid

import structlog

logger = structlog.get_logger("api.processing_service")


def notify(artifact_id: uuid.UUID) -> None:
    """Notify the processing worker that a new artifact is ready.

    This is a no-op stub. Ticket #10 implements the async processing worker
    with LLM tagging and embedding generation.
    """
    logger.info("processing_notify_stub", artifact_id=str(artifact_id))
