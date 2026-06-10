"""FastAPI application entry point."""

from fastapi import FastAPI

from bundle_common import configure_logging, get_logger


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    configure_logging()
    logger = get_logger("api")

    app = FastAPI(
        title="Bundle API",
        version="0.1.0",
        description="Backend service for Bundle capture and retrieval app",
    )

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    logger.info("app_created")
    return app


app = create_app()
