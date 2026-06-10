#!/usr/bin/env bash
set -euo pipefail

# Deploy Bundle API to Hetzner VPS
# Usage: ./scripts/deploy.sh <host> [--rollback]

DEPLOY_HOST="${1:-}"
ROLLBACK="${2:-}"
DEPLOY_DIR="/opt/bundle"
COMPOSE_FILE="docker-compose.yml"
HEALTH_URL="http://localhost:8000/health"
HEALTH_TIMEOUT=30
HEALTH_INTERVAL=2

if [[ -z "$DEPLOY_HOST" ]]; then
    echo "Usage: $0 <host> [--rollback]"
    echo "  host: SSH host (e.g., user@server.example.com)"
    exit 1
fi

log() {
    echo "[deploy] $(date '+%H:%M:%S') $*"
}

ssh_cmd() {
    ssh -o StrictHostKeyChecking=accept-new "$DEPLOY_HOST" "$@"
}

health_check() {
    local elapsed=0
    while [[ $elapsed -lt $HEALTH_TIMEOUT ]]; do
        if ssh_cmd "curl -sf $HEALTH_URL" > /dev/null 2>&1; then
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
        elapsed=$((elapsed + HEALTH_INTERVAL))
    done
    return 1
}

rollback() {
    log "Rolling back to previous version..."
    ssh_cmd "cd $DEPLOY_DIR && docker compose -f $COMPOSE_FILE down && docker compose -f $COMPOSE_FILE up -d --no-build"
    log "Rollback complete. Checking health..."
    if health_check; then
        log "Rollback healthy."
    else
        log "ERROR: Rollback also failed. Manual intervention required."
        exit 2
    fi
}

if [[ "$ROLLBACK" == "--rollback" ]]; then
    rollback
    exit 0
fi

log "Deploying to $DEPLOY_HOST..."

# Pull latest images
log "Pulling latest images..."
ssh_cmd "cd $DEPLOY_DIR && docker compose -f $COMPOSE_FILE pull"

# Store current image digests for rollback
log "Saving current state for rollback..."
ssh_cmd "cd $DEPLOY_DIR && docker compose -f $COMPOSE_FILE images -q > .deploy-previous-images 2>/dev/null || true"

# Start updated services
log "Starting updated services..."
ssh_cmd "cd $DEPLOY_DIR && docker compose -f $COMPOSE_FILE up -d"

# Health check
log "Waiting for health check (timeout: ${HEALTH_TIMEOUT}s)..."
if health_check; then
    log "Deployment successful. Service is healthy."
else
    log "ERROR: Health check failed after ${HEALTH_TIMEOUT}s."
    rollback
    exit 1
fi
