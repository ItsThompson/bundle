"""Standalone worker entrypoint: processes artifacts via LISTEN/NOTIFY + polling."""

import asyncio
import signal
import sys

import asyncpg
import structlog

from api.config import Settings, get_settings
from api.processing.embedder import Embedder
from api.processing.nim_embedding_provider import NimEmbeddingProvider
from api.processing.nim_llm_provider import NimLLMProvider
from api.processing.tagger import Tagger
from api.processing.worker import ProcessingWorker

logger = structlog.get_logger("api.worker_main")

LISTEN_CHANNEL = "artifact_ready"
RECONNECT_BASE_DELAY = 1.0
RECONNECT_MAX_DELAY = 60.0


async def run_worker() -> None:
    """Bootstrap the worker: DB pool, LLM providers, LISTEN connection, signal handlers."""
    settings = get_settings()

    if not settings.nvidia_api_key:
        logger.error("worker_missing_nvidia_key", reason="NVIDIA_API_KEY is required")
        sys.exit(1)

    from bundle_common import configure_logging

    configure_logging(log_level=settings.log_level)

    logger.info("worker_starting")

    pool = await asyncpg.create_pool(
        dsn=settings.database_url,
        min_size=1,
        max_size=3,
    )
    logger.info("worker_pool_created", min_size=1, max_size=3)

    llm_provider = NimLLMProvider(
        api_key=settings.nvidia_api_key,
        model=settings.nim_llm_model,
    )
    embedding_provider = NimEmbeddingProvider(
        api_key=settings.nvidia_api_key,
        model=settings.nim_embedding_model,
    )
    tagger = Tagger(provider=llm_provider)
    embedder = Embedder(provider=embedding_provider)

    worker = ProcessingWorker(
        pool=pool,
        settings=settings,
        tagger=tagger,
        embedder=embedder,
    )

    shutdown_event = asyncio.Event()

    def handle_shutdown(signum: int) -> None:
        sig_name = signal.Signals(signum).name
        logger.info("worker_signal_received", signal=sig_name)
        shutdown_event.set()

    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGTERM, handle_shutdown, signal.SIGTERM)
    loop.add_signal_handler(signal.SIGINT, handle_shutdown, signal.SIGINT)

    await worker.start()
    logger.info("worker_started")

    listen_task = asyncio.create_task(_listen_loop(settings, worker, shutdown_event))

    await shutdown_event.wait()

    logger.info("worker_shutting_down")
    listen_task.cancel()

    artifact_id = worker.current_artifact_id
    if artifact_id is not None:
        logger.info("worker_resetting_inflight_artifact", artifact_id=str(artifact_id))
        async with pool.acquire() as conn:
            await conn.execute(
                "UPDATE artifacts SET status = 'pending', updated_at = now() WHERE id = $1",
                artifact_id,
            )
        logger.info("worker_inflight_artifact_reset", artifact_id=str(artifact_id))

    await worker.stop()
    await pool.close()
    logger.info("worker_stopped")


async def _listen_loop(
    settings: Settings,
    worker: ProcessingWorker,
    shutdown_event: asyncio.Event,
) -> None:
    """Maintain a persistent LISTEN connection with exponential backoff reconnection."""
    delay = RECONNECT_BASE_DELAY

    while not shutdown_event.is_set():
        conn: asyncpg.Connection | None = None
        try:
            conn = await asyncpg.connect(dsn=settings.database_url)
            logger.info("listen_connection_established")
            delay = RECONNECT_BASE_DELAY

            def on_notify(
                connection: asyncpg.Connection,
                pid: int,
                channel: str,
                payload: str,
            ) -> None:
                logger.info("listen_notification_received", artifact_id=payload)
                worker.notify()

            await conn.add_listener(LISTEN_CHANNEL, on_notify)
            logger.info("listen_channel_active", channel=LISTEN_CHANNEL)

            while not shutdown_event.is_set():
                await asyncio.sleep(1.0)
                try:
                    await conn.fetchval("SELECT 1")
                except Exception:
                    logger.warning("listen_connection_health_check_failed")
                    break

        except asyncio.CancelledError:
            break
        except Exception as exc:
            logger.warning(
                "listen_connection_failed",
                error=str(exc),
                reconnect_delay=delay,
            )
            await asyncio.sleep(delay)
            delay = min(delay * 2, RECONNECT_MAX_DELAY)
        finally:
            if conn is not None:
                try:
                    await conn.close()
                except Exception:
                    pass


def main() -> None:
    """Entry point for `python -m api.worker_main`."""
    asyncio.run(run_worker())


if __name__ == "__main__":
    main()
