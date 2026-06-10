# Bundle task runner

# Start development services (PostgreSQL + pgvector)
dev:
    docker compose -f docker-compose.dev.yml up -d

# Stop development services
dev-down:
    docker compose -f docker-compose.dev.yml down

# Run linting (ruff check + pyright)
lint:
    uv run ruff check .
    uv run pyright

# Run code formatter
format:
    uv run ruff format .

# Run tests
test:
    uv run pytest
