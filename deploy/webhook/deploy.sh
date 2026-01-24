#!/bin/bash
set -euo pipefail

# NomNom Deployment Script (Environment-Agnostic)
# This script deploys to any environment by accepting configuration as parameters
# Usage: deploy.sh <sha> <compose_file> <env_file> <hostname> <rollback_log>

DEPLOYMENT_TIMEOUT=300 # 5 minutes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
	echo "[$(date -Iseconds)] $*" | tee -a "$ROLLBACK_LOG"
}

log_error() {
	echo -e "${RED}[$(date -Iseconds)] ERROR: $*${NC}" | tee -a "$ROLLBACK_LOG" >&2
}

log_success() {
	echo -e "${GREEN}[$(date -Iseconds)] SUCCESS: $*${NC}" | tee -a "$ROLLBACK_LOG"
}

log_warning() {
	echo -e "${YELLOW}[$(date -Iseconds)] WARNING: $*${NC}" | tee -a "$ROLLBACK_LOG"
}

# Parse arguments
if [ $# -lt 5 ]; then
	echo "Usage: $0 <sha> <compose_file> <env_file> <hostname> <rollback_log>" >&2
	echo "Example: $0 abc123 /opt/nomnom/deploy/compose.yml /etc/nomnom-deployment/deploy.env nomnom.lacon.org /etc/nomnom-deployment/rollback.log" >&2
	echo "  Note: <env_file> should be the version-only file (/etc/nomnom-deployment/deploy.env)" >&2
	echo "        that gets updated with NOMNOM_VERSION. Application config lives in /opt/nomnom/deploy/.env" >&2
	exit 1
fi

FULL_SHA="$1"
COMPOSE_FILE="$2"
ENV_FILE="$3"
HOSTNAME="$4"
ROLLBACK_LOG="$5"

# Convert full SHA to short SHA (first 7 characters)
# This matches the docker image tag format: sha-<short-sha>
NEW_SHA="${FULL_SHA:0:7}"

log "=========================================="
log "Starting deployment of SHA: $NEW_SHA (from full SHA: $FULL_SHA)"
log "Environment: $HOSTNAME"
log "Compose file: $COMPOSE_FILE"
log "Env file: $ENV_FILE"
log "Triggered by: ${sender:-unknown} for ${repository:-unknown}"
log "=========================================="

# Validate inputs
if [ ! -f "$COMPOSE_FILE" ]; then
	log_error "Compose file not found: $COMPOSE_FILE"
	exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
	log_error "Env file not found: $ENV_FILE"
	exit 1
fi

# Get current SHA from .env file (for rollback)
CURRENT_SHA=""
if [ -f "$ENV_FILE" ]; then
	CURRENT_SHA=$(grep -oP '^NOMNOM_VERSION=\K.*' "$ENV_FILE" || echo "main")
	log "Current version: $CURRENT_SHA"
fi

# Function to update .env file with new SHA
# Expects a SHORT SHA (7 characters) as input
update_env() {
	local short_sha="$1"
	local temp_env
	temp_env="$(mktemp)"

	# Preserve original file ownership and permissions
	if [ -f "$ENV_FILE" ]; then
		chmod --reference="$ENV_FILE" "$temp_env" 2>/dev/null || true
		chown --reference="$ENV_FILE" "$temp_env" 2>/dev/null || true
	fi

	if grep -q '^NOMNOM_VERSION=' "$ENV_FILE"; then
		# Update existing NOMNOM_VERSION
		sed "s|^NOMNOM_VERSION=.*|NOMNOM_VERSION=sha-${short_sha}|" "$ENV_FILE" >"$temp_env"
	else
		# Add NOMNOM_VERSION to the file
		cp "$ENV_FILE" "$temp_env"
		echo "" >>"$temp_env"
		echo "NOMNOM_VERSION=sha-${short_sha}" >>"$temp_env"
	fi

	# Restore permissions again after writing (in case they changed)
	if [ -f "$ENV_FILE" ]; then
		chmod --reference="$ENV_FILE" "$temp_env" 2>/dev/null || true
		chown --reference="$ENV_FILE" "$temp_env" 2>/dev/null || true
	fi

	mv "$temp_env" "$ENV_FILE"
	log "Updated $ENV_FILE with NOMNOM_VERSION=sha-${short_sha}"
}

# Function to check deployment health
check_health() {
	log "Checking deployment health..."

	# Wait a moment for services to settle
	sleep 5

	# Check if containers are running
	if ! docker compose -f "$COMPOSE_FILE" ps --status running | grep -q web; then
		log_error "Web container is not running"
		return 1
	fi

	# Try to hit the watchman endpoint
	log "Checking /watchman/ endpoint..."
	local max_attempts=12 # 60 seconds total (12 * 5s)
	local attempt=1

	while [ $attempt -le $max_attempts ]; do
		if curl -s --fail -H "Host: $HOSTNAME" http://localhost:8000/watchman/ | jq -e '.databases[].default.ok == true' >/dev/null 2>&1; then
			log_success "Health check passed"
			return 0
		fi

		log "Health check attempt $attempt/$max_attempts failed, waiting..."
		sleep 5
		((attempt++))
	done

	log_error "Health check failed after $max_attempts attempts"
	return 1
}

# Function to perform deployment
# Expects a SHORT SHA (7 characters) as input
deploy() {
	local short_sha="$1"

	log "Pulling image for sha-${short_sha}..."
	if ! docker compose -f "$COMPOSE_FILE" pull; then
		log_error "Failed to pull image"
		return 1
	fi

	log "Starting containers with --wait (timeout: ${DEPLOYMENT_TIMEOUT}s)..."
	if ! timeout "$DEPLOYMENT_TIMEOUT" docker compose -f "$COMPOSE_FILE" up -d --wait; then
		log_error "Deployment failed or timed out"
		return 1
	fi

	# Additional health check
	if ! check_health; then
		return 1
	fi

	return 0
}

# Perform the deployment
update_env "$NEW_SHA"

if deploy "$NEW_SHA"; then
	log_success "Deployment of sha-${NEW_SHA} completed successfully"
	echo "$(date -Iseconds) [$HOSTNAME] deployed sha-${NEW_SHA} (success) previous: ${CURRENT_SHA}" >>"$ROLLBACK_LOG"
	exit 0
else
	log_error "Deployment of sha-${NEW_SHA} failed"

	# Rollback if we have a previous version
	if [ -n "$CURRENT_SHA" ] && [ "$CURRENT_SHA" != "main" ]; then
		log_warning "Attempting rollback to ${CURRENT_SHA}..."
		# Extract short SHA from CURRENT_SHA (remove sha- prefix if present, then take first 7 chars)
		ROLLBACK_SHA="${CURRENT_SHA#sha-}"
		ROLLBACK_SHA="${ROLLBACK_SHA:0:7}"
		update_env "${ROLLBACK_SHA}"

		if deploy "${ROLLBACK_SHA}"; then
			log_success "Rollback to ${CURRENT_SHA} succeeded"
			echo "$(date -Iseconds) [$HOSTNAME] deployed sha-${NEW_SHA} (FAILED, rolled back to ${CURRENT_SHA})" >>"$ROLLBACK_LOG"
			exit 1
		else
			log_error "Rollback failed! Manual intervention required!"
			echo "$(date -Iseconds) [$HOSTNAME] deployed sha-${NEW_SHA} (FAILED, rollback to ${CURRENT_SHA} also FAILED)" >>"$ROLLBACK_LOG"
			exit 2
		fi
	else
		log_error "No previous version to rollback to"
		echo "$(date -Iseconds) [$HOSTNAME] deployed sha-${NEW_SHA} (FAILED, no rollback available)" >>"$ROLLBACK_LOG"
		exit 1
	fi
fi
