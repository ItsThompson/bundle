"""Structured logging configuration using structlog."""

import structlog


def configure_logging(*, json_output: bool = True, log_level: str = "INFO") -> None:
    """Configure structlog with JSON output, timestamps, and log level.

    Args:
        json_output: If True, render logs as JSON. If False, use console renderer.
        log_level: Minimum log level to emit (DEBUG, INFO, WARNING, ERROR, CRITICAL).
    """
    processors: list[structlog.types.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
    ]

    if json_output:
        processors.append(structlog.processors.JSONRenderer())
    else:
        processors.append(structlog.dev.ConsoleRenderer())

    structlog.configure(
        processors=processors,
        wrapper_class=structlog.make_filtering_bound_logger(
            structlog.processors.NAME_TO_LEVEL[log_level.lower()]
        ),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str | None = None) -> structlog.BoundLogger:
    """Get a configured structlog logger.

    Args:
        name: Optional logger name for identification.

    Returns:
        A bound structlog logger instance.
    """
    logger = structlog.get_logger()
    if name:
        logger = logger.bind(logger_name=name)
    return logger
