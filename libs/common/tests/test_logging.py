"""Tests for bundle_common.logging module."""

import json
from io import StringIO

import structlog

from bundle_common import configure_logging, get_logger


def test_configure_logging_produces_json() -> None:
    """Verify structlog produces JSON with expected fields."""
    configure_logging(json_output=True, log_level="DEBUG")

    output = StringIO()
    structlog.configure(logger_factory=structlog.PrintLoggerFactory(file=output))

    logger = get_logger("test_module")
    logger.info("test_event", key="value")

    log_line = output.getvalue().strip()
    parsed = json.loads(log_line)

    assert parsed["event"] == "test_event"
    assert parsed["key"] == "value"
    assert parsed["level"] == "info"
    assert "timestamp" in parsed


def test_get_logger_binds_name() -> None:
    """Verify logger binds the logger_name context."""
    configure_logging(json_output=True)

    output = StringIO()
    structlog.configure(logger_factory=structlog.PrintLoggerFactory(file=output))

    logger = get_logger("my_service")
    logger.info("hello")

    log_line = output.getvalue().strip()
    parsed = json.loads(log_line)

    assert parsed["logger_name"] == "my_service"


def test_get_logger_without_name_has_no_logger_name_field() -> None:
    """Verify logger works without explicit name."""
    configure_logging(json_output=True)

    output = StringIO()
    structlog.configure(logger_factory=structlog.PrintLoggerFactory(file=output))

    logger = get_logger()
    logger.info("anonymous_event")

    log_line = output.getvalue().strip()
    parsed = json.loads(log_line)

    assert parsed["event"] == "anonymous_event"
    assert "logger_name" not in parsed
