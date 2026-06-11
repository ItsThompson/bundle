# Bundle task runner

set dotenv-load

# Database URL for dbmate
db_url := env("DATABASE_URL", "postgresql://bundle:bundle_dev@localhost:5433/bundle?sslmode=disable")

# Start development services (PostgreSQL + pgvector)
dev:
    docker compose -f docker-compose.dev.yml up -d
    @echo "Starting API with hot reload..."
    uv run --package bundle-api uvicorn api.main:app --reload --host 0.0.0.0 --port 8018 --app-dir services/api/src

# Start only the database
dev-db:
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

# Run database migrations
db-migrate:
    dbmate --url "{{db_url}}" --migrations-dir services/api/db/migrations up

# Create a new migration
db-new name:
    dbmate --url "{{db_url}}" --migrations-dir services/api/db/migrations new {{name}}

# Rollback last migration
db-rollback:
    dbmate --url "{{db_url}}" --migrations-dir services/api/db/migrations down

# Build production Docker image
docker-build:
    docker build -t bundle-api:latest -f services/api/Dockerfile .

# Build macOS app (debug)
macos-build:
    cd apps/macos && swift build

# Build + sign macOS app (requires "Bundle Dev" cert in Keychain)
# Create cert: Keychain Access → Certificate Assistant → Create a Certificate
#   Name: "Bundle Dev", Type: Self Signed Root, Cert Type: Code Signing
macos-run:
    cd apps/macos && swift build
    codesign -f -s "Bundle Dev" --entitlements apps/macos/Bundle.entitlements --identifier com.thompsnt.bundle apps/macos/.build/debug/Bundle
    @echo "Launching Bundle..."
    apps/macos/.build/debug/Bundle &
