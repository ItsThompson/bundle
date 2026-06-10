# Stage 1: Install dependencies
FROM python:3.12-slim AS deps

WORKDIR /app

# Install uv for fast dependency resolution
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Copy workspace definition files
COPY pyproject.toml uv.lock ./
COPY libs/common/pyproject.toml libs/common/
COPY services/api/pyproject.toml services/api/

# Install production dependencies only
RUN uv sync --frozen --no-dev --all-packages --no-install-workspace

# Stage 2: Production image
FROM python:3.12-slim AS runtime

WORKDIR /app

# Copy installed packages from deps stage
COPY --from=deps /app/.venv /app/.venv

# Copy source code
COPY libs/common/src/ libs/common/src/
COPY services/api/src/ services/api/src/

# Install workspace packages (editable) in the existing venv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock ./
COPY libs/common/pyproject.toml libs/common/
COPY services/api/pyproject.toml services/api/
RUN uv sync --frozen --no-dev --all-packages

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
