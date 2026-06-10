"""Processing service: notification bridge between upload endpoint and worker."""

import uuid

import structlog

from api.processing.worker import ProcessingWorker

logger = structlog.get_logger("api.processing_service")

# Module-level reference to the active worker (set during lifespan startup)
_worker: ProcessingWorker | None = None


def set_worker(worker: ProcessingWorker) -> None:
    """Register the active processing worker (called during lifespan startup)."""
    global _worker  # noqa: PLW0603
    _worker = worker


def notify(artifact_id: uuid.UUID) -> None:
    """Notify the processing worker that a new artifact is ready.

    Wakes the worker immediately so it picks up the new artifact
    without waiting for the next poll interval.
    """
    logger.info("processing_notify", artifact_id=str(artifact_id))
    if _worker is not None:
        _worker.notify()
    else:
        logger.warning("processing_notify_no_worker", artifact_id=str(artifact_id))
