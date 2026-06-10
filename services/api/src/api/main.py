"""FastAPI application entry point with lifespan management."""

import time
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import asyncpg
import structlog
from fastapi import FastAPI, Request, Response

from api.config import Settings, get_settings
from api.routers.artifacts import router as artifacts_router
from api.routers.auth import router as auth_router
from api.routers.health import router as health_router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Manage application lifecycle: DB pool, processing worker."""
    settings: Settings = app.state.settings
    logger = structlog.get_logger("api.lifespan")

    logger.info("pool_creating", database_url=settings.database_url.split("@")[-1])
    app.state.pool = await asyncpg.create_pool(
        dsn=settings.database_url,
        min_size=settings.db_pool_min_size,
        max_size=settings.db_pool_max_size,
    )
    logger.info("pool_created")

    # Start the processing worker if LLM keys are configured
    worker = None
    if settings.anthropic_api_key and settings.openai_api_key:
        from api.processing.anthropic_provider import AnthropicProvider
        from api.processing.embedder import Embedder
        from api.processing.openai_provider import OpenAIEmbeddingProvider
        from api.processing.tagger import Tagger
        from api.processing.worker import ProcessingWorker
        from api.services import processing_service

        llm_provider = AnthropicProvider(api_key=settings.anthropic_api_key)
        embedding_provider = OpenAIEmbeddingProvider(api_key=settings.openai_api_key)
        tagger = Tagger(provider=llm_provider)
        embedder = Embedder(provider=embedding_provider)

        worker = ProcessingWorker(
            pool=app.state.pool,
            settings=settings,
            tagger=tagger,
            embedder=embedder,
        )
        processing_service.set_worker(worker)
        await worker.start()
        logger.info("processing_worker_started")
    else:
        logger.warning("processing_worker_skipped", reason="missing API keys")

    yield

    # Shutdown worker
    if worker:
        await worker.stop()
        logger.info("processing_worker_stopped")

    logger.info("pool_closing")
    await app.state.pool.close()
    logger.info("pool_closed")


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create and configure the FastAPI application."""
    from bundle_common import configure_logging

    if settings is None:
        settings = get_settings()

    configure_logging(log_level=settings.log_level)
    logger = structlog.get_logger("api")

    # Initialize Sentry if DSN is provided
    if settings.sentry_dsn:
        import sentry_sdk

        sentry_sdk.init(dsn=settings.sentry_dsn, traces_sample_rate=0.1)
        logger.info("sentry_initialized")

    app = FastAPI(
        title="Bundle API",
        version="0.1.0",
        description="Backend service for Bundle capture and retrieval app",
        lifespan=lifespan,
    )

    # Store settings in app state for access in lifespan and dependencies
    app.state.settings = settings

    # Request logging middleware
    @app.middleware("http")
    async def log_requests(request: Request, call_next) -> Response:
        start = time.perf_counter()
        response: Response = await call_next(request)
        duration_ms = (time.perf_counter() - start) * 1000
        structlog.get_logger("api.request").info(
            "request_completed",
            method=request.method,
            path=request.url.path,
            status=response.status_code,
            duration_ms=round(duration_ms, 2),
        )
        return response

    # Register routers
    app.include_router(artifacts_router)
    app.include_router(auth_router)
    app.include_router(health_router)

    logger.info("app_created")
    return app


app = create_app()
