#!/bin/bash
# NomNom Deployment Configuration Checker
# This script verifies all aspects of the deployment setup on a staging or production host
# Must be run with sudo to perform all permission checks
#
# Usage: sudo ./check-setup.sh <stage>
#   stage: production or staging

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
	echo "ERROR: This script must be run with sudo"
	echo "Usage: sudo $0 <stage>"
	exit 1
fi

# Check stage argument
if [ $# -ne 1 ]; then
	echo "Usage: sudo $0 <stage>"
	echo "  stage: production or staging"
	exit 1
fi

STAGE="$1"
if [ "$STAGE" != "production" ] && [ "$STAGE" != "staging" ]; then
	echo "ERROR: Stage must be 'production' or 'staging', got: $STAGE"
	exit 1
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track failures
FAILURES=0
WARNINGS=0

check_ok() {
	echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
	echo -e "${RED}✗${NC} $1"
	((FAILURES++))
}

check_warn() {
	echo -e "${YELLOW}!${NC} $1"
	((WARNINGS++))
}

section() {
	echo ""
	echo -e "${BLUE}============================================${NC}"
	echo -e "${BLUE}$1${NC}"
	echo -e "${BLUE}============================================${NC}"
	echo ""
}

remediation() {
	echo "  $1"
}

# Required environment variables in /opt/nomnom/deploy/.env
REQUIRED_ENV_VARS=(
	"NOM_DB_NAME"
	"NOM_DB_USER"
	"NOM_DB_PASSWORD"
	"NOM_SECRET_KEY"
	"NOM_ALLOWED_HOSTS"
	"DEPLOYMENT_HOSTNAME"
	"LOGGING_HOSTNAME"
)

section "NomNom Deployment Setup Check - ${STAGE}"
echo "Started: $(date)"
echo ""

###############################################################################
section "Prerequisites"
###############################################################################

# Check webhook binary
if command -v webhook &>/dev/null; then
	check_ok "webhook binary installed at $(which webhook)"
else
	check_fail "webhook binary not found"
	remediation "Install webhook: https://github.com/adnanh/webhook"
fi

# Check docker
if command -v docker &>/dev/null; then
	check_ok "docker binary installed"
	if systemctl is-active --quiet docker; then
		check_ok "docker daemon is running"
	else
		check_fail "docker daemon is not running"
		remediation "sudo systemctl start docker"
	fi
else
	check_fail "docker not found"
	remediation "Install docker"
fi

# Check caddy
if command -v caddy &>/dev/null; then
	check_ok "caddy binary installed"
else
	check_warn "caddy binary not found (may be OK if using different proxy)"
fi

# Check nomnom-deploy user
if id nomnom-deploy &>/dev/null; then
	check_ok "nomnom-deploy user exists"

	# Check docker group membership
	if groups nomnom-deploy | grep -q docker; then
		check_ok "nomnom-deploy is in docker group"
	else
		check_fail "nomnom-deploy is NOT in docker group"
		remediation "sudo usermod -aG docker nomnom-deploy"
	fi
else
	check_fail "nomnom-deploy user does not exist"
	remediation "sudo useradd -r -s /bin/bash -d /home/nomnom-deploy -m nomnom-deploy"
fi

###############################################################################
section "Directory Structure"
###############################################################################

# /etc/nomnom-deployment/
if [ -d /etc/nomnom-deployment ]; then
	check_ok "/etc/nomnom-deployment/ exists"

	# Check ownership
	OWNER=$(stat -c '%U:%G' /etc/nomnom-deployment)
	if [ "$OWNER" = "nomnom-deploy:nomnom-deploy" ]; then
		check_ok "/etc/nomnom-deployment/ owned by nomnom-deploy"
	else
		check_warn "/etc/nomnom-deployment/ owned by $OWNER (expected nomnom-deploy:nomnom-deploy)"
		remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment"
	fi
else
	check_fail "/etc/nomnom-deployment/ does not exist"
	remediation "sudo mkdir -p /etc/nomnom-deployment"
	remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment"
fi

# /opt/nomnom/
if [ -d /opt/nomnom ]; then
	check_ok "/opt/nomnom/ exists (git clone)"

	# Check if it's a git repo
	if [ -d /opt/nomnom/.git ]; then
		check_ok "/opt/nomnom/ is a git repository"
	else
		check_warn "/opt/nomnom/ is not a git repository"
	fi
else
	check_fail "/opt/nomnom/ does not exist"
	remediation "This should be a git clone of the repository"
fi

# /opt/nomnom/deploy/
if [ -d /opt/nomnom/deploy ]; then
	check_ok "/opt/nomnom/deploy/ exists"
else
	check_fail "/opt/nomnom/deploy/ does not exist"
fi

# Check compose.yml
if [ -f /opt/nomnom/deploy/compose.yml ]; then
	check_ok "compose.yml exists"
else
	check_fail "compose.yml not found at /opt/nomnom/deploy/compose.yml"
fi

# Check deploy.sh
if [ -f /opt/nomnom/deploy/webhook/deploy.sh ]; then
	check_ok "deploy.sh exists in repo"

	if [ -x /opt/nomnom/deploy/webhook/deploy.sh ]; then
		check_ok "deploy.sh is executable"
	else
		check_fail "deploy.sh is not executable"
		remediation "sudo chmod +x /opt/nomnom/deploy/webhook/deploy.sh"
	fi
else
	check_fail "deploy.sh not found at /opt/nomnom/deploy/webhook/deploy.sh"
fi

# Check pgbouncer directory
if [ -d /opt/nomnom/deploy/pgbouncer ]; then
	check_ok "pgbouncer directory exists"

	if [ -f /opt/nomnom/deploy/pgbouncer/pgbouncer.ini ]; then
		check_ok "pgbouncer.ini exists (configured)"
	else
		check_fail "pgbouncer.ini not found"
		remediation "Copy from template: cp /opt/nomnom/deploy/pgbouncer.template/pgbouncer.ini.template /opt/nomnom/deploy/pgbouncer/pgbouncer.ini"
		remediation "Then edit with correct database settings"
	fi

	if [ -f /opt/nomnom/deploy/pgbouncer/userlist.txt ]; then
		check_ok "userlist.txt exists (configured)"

		# Check permissions (should be 600)
		PERMS=$(stat -c '%a' /opt/nomnom/deploy/pgbouncer/userlist.txt)
		if [ "$PERMS" = "600" ]; then
			check_ok "userlist.txt has correct permissions (600)"
		else
			check_warn "userlist.txt has permissions $PERMS (expected 600)"
			remediation "sudo chmod 600 /opt/nomnom/deploy/pgbouncer/userlist.txt"
		fi
	else
		check_fail "userlist.txt not found"
		remediation "Copy from template: cp /opt/nomnom/deploy/pgbouncer.template/userlist.txt.template /opt/nomnom/deploy/pgbouncer/userlist.txt"
		remediation "Then edit with correct password hash"
	fi
else
	check_fail "pgbouncer directory not found at /opt/nomnom/deploy/pgbouncer"
	remediation "Create it: sudo mkdir -p /opt/nomnom/deploy/pgbouncer"
fi

# Check stage-specific Caddyfile
if [ -f "/opt/nomnom/deploy/${STAGE}/Caddyfile" ]; then
	check_ok "Caddyfile exists for $STAGE"

	# Check if it contains webhook route
	if grep -q "/hooks/deploy" "/opt/nomnom/deploy/${STAGE}/Caddyfile"; then
		check_ok "Caddyfile contains webhook route"
	else
		check_warn "Caddyfile does not contain /hooks/deploy route"
	fi
else
	check_fail "Caddyfile not found at /opt/nomnom/deploy/${STAGE}/Caddyfile"
fi

###############################################################################
section "Configuration Files - /etc/nomnom-deployment/"
###############################################################################

# webhook.secret
if [ -f /etc/nomnom-deployment/webhook.secret ]; then
	check_ok "webhook.secret exists"

	# Check ownership
	OWNER=$(stat -c '%U:%G' /etc/nomnom-deployment/webhook.secret)
	if [ "$OWNER" = "nomnom-deploy:nomnom-deploy" ]; then
		check_ok "webhook.secret owned by nomnom-deploy"
	else
		check_warn "webhook.secret owned by $OWNER"
		remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/webhook.secret"
	fi

	# Check permissions (should be 600)
	PERMS=$(stat -c '%a' /etc/nomnom-deployment/webhook.secret)
	if [ "$PERMS" = "600" ]; then
		check_ok "webhook.secret has correct permissions (600)"
	else
		check_warn "webhook.secret has permissions $PERMS (expected 600)"
		remediation "sudo chmod 600 /etc/nomnom-deployment/webhook.secret"
	fi
else
	check_fail "webhook.secret not found"
	remediation "Generate: openssl rand -hex 32 | sudo tee /etc/nomnom-deployment/webhook.secret"
	remediation "sudo chmod 600 /etc/nomnom-deployment/webhook.secret"
	remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/webhook.secret"
fi

# hooks.json
if [ -f /etc/nomnom-deployment/hooks.json ]; then
	check_ok "hooks.json exists"

	# Verify it's valid JSON
	if jq empty /etc/nomnom-deployment/hooks.json 2>/dev/null; then
		check_ok "hooks.json is valid JSON"

		# Check hook_id matches stage
		HOOK_ID=$(jq -r '.[0].trigger_rule.and[0].match.value' /etc/nomnom-deployment/hooks.json 2>/dev/null)
		if [ "$HOOK_ID" = "deploy-${STAGE}" ]; then
			check_ok "hook_id matches stage (deploy-${STAGE})"
		else
			check_fail "hook_id is '$HOOK_ID' but expected 'deploy-${STAGE}'"
			remediation "Copy correct hooks.json: sudo cp /opt/nomnom/deploy/${STAGE}/webhook/hooks.json /etc/nomnom-deployment/"
		fi

		# Check it references correct env file for version tag
		ENV_FILE_REF=$(jq -r '.[0].pass_arguments_to_command[] | select(.name | contains("deploy.env")) | .name' /etc/nomnom-deployment/hooks.json 2>/dev/null | head -1)
		if [ "$ENV_FILE_REF" = "/etc/nomnom-deployment/deploy.env" ]; then
			check_ok "hooks.json references /etc/nomnom-deployment/deploy.env"
		else
			check_fail "hooks.json references '$ENV_FILE_REF' instead of /etc/nomnom-deployment/deploy.env"
			remediation "Copy correct hooks.json: sudo cp /opt/nomnom/deploy/${STAGE}/webhook/hooks.json /etc/nomnom-deployment/"
		fi

		# Check it sources the main .env for DEPLOYMENT_HOSTNAME
		SOURCE_CMD=$(jq -r '.[0].pass_arguments_to_command[] | select(.name | contains("source")) | .name' /etc/nomnom-deployment/hooks.json 2>/dev/null)
		if echo "$SOURCE_CMD" | grep -q "source /opt/nomnom/deploy/.env"; then
			check_ok "hooks.json sources /opt/nomnom/deploy/.env"
		else
			check_warn "hooks.json may not source /opt/nomnom/deploy/.env correctly"
			remediation "Verify line 14 in hooks.json sources /opt/nomnom/deploy/.env"
		fi
	else
		check_fail "hooks.json is not valid JSON"
		remediation "Copy from repo: sudo cp /opt/nomnom/deploy/${STAGE}/webhook/hooks.json /etc/nomnom-deployment/"
	fi
else
	check_fail "hooks.json not found"
	remediation "sudo cp /opt/nomnom/deploy/${STAGE}/webhook/hooks.json /etc/nomnom-deployment/"
	remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/hooks.json"
fi

# deploy.env (should contain ONLY NOMNOM_VERSION)
if [ -f /etc/nomnom-deployment/deploy.env ]; then
	check_ok "deploy.env exists"

	# Check if writable by nomnom-deploy
	if sudo -u nomnom-deploy test -w /etc/nomnom-deployment/deploy.env; then
		check_ok "deploy.env is writable by nomnom-deploy"
	else
		check_fail "deploy.env is NOT writable by nomnom-deploy"
		remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/deploy.env"
		remediation "sudo chmod 664 /etc/nomnom-deployment/deploy.env"
	fi

	# Check contents - should only have NOMNOM_VERSION
	LINE_COUNT=$(grep -v '^#' /etc/nomnom-deployment/deploy.env | grep -v '^$' | wc -l)
	if [ "$LINE_COUNT" -le 1 ]; then
		check_ok "deploy.env contains only version tag (correct)"

		if grep -q "^NOMNOM_VERSION=" /etc/nomnom-deployment/deploy.env; then
			VERSION=$(grep "^NOMNOM_VERSION=" /etc/nomnom-deployment/deploy.env | cut -d= -f2)
			check_ok "NOMNOM_VERSION is set to: $VERSION"
		else
			check_warn "NOMNOM_VERSION not set (will be set on first deploy)"
		fi
	else
		check_warn "deploy.env contains $LINE_COUNT non-comment lines (expected 0-1)"
		echo "  Current contents:"
		grep -v '^#' /etc/nomnom-deployment/deploy.env | grep -v '^$' | sed 's/^/    /'
		echo "  This file should contain ONLY: NOMNOM_VERSION=sha-xxx"
		echo "  All other config should be in /opt/nomnom/deploy/.env"
	fi
else
	check_warn "deploy.env not found (will be created on first deploy)"
	remediation "Create it now: echo 'NOMNOM_VERSION=main' | sudo tee /etc/nomnom-deployment/deploy.env"
	remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/deploy.env"
	remediation "sudo chmod 664 /etc/nomnom-deployment/deploy.env"
fi

# rollback.log (optional, will be created by deploy.sh)
if [ -f /etc/nomnom-deployment/rollback.log ]; then
	check_ok "rollback.log exists"

	if sudo -u nomnom-deploy test -w /etc/nomnom-deployment/rollback.log; then
		check_ok "rollback.log is writable by nomnom-deploy"
	else
		check_fail "rollback.log is NOT writable by nomnom-deploy"
		remediation "sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/rollback.log"
	fi
else
	check_ok "rollback.log does not exist yet (will be created by deploy.sh)"
fi

###############################################################################
section "Configuration Files - /opt/nomnom/deploy/"
###############################################################################

# .env (main application config)
if [ -f /opt/nomnom/deploy/.env ]; then
	check_ok ".env exists (application configuration)"

	# Check it's readable
	if sudo -u nomnom-deploy test -r /opt/nomnom/deploy/.env; then
		check_ok ".env is readable by nomnom-deploy"
	else
		check_fail ".env is NOT readable by nomnom-deploy"
		remediation "sudo chmod 644 /opt/nomnom/deploy/.env"
	fi

	# Check it's NOT writable by nomnom-deploy (should be manually managed)
	if sudo -u nomnom-deploy test -w /opt/nomnom/deploy/.env; then
		check_warn ".env is writable by nomnom-deploy (should be manually managed only)"
		remediation "This file should be manually managed, consider: sudo chmod 644 /opt/nomnom/deploy/.env"
	else
		check_ok ".env is not writable by nomnom-deploy (correct - manually managed)"
	fi

	# Check for required variables
	MISSING_VARS=()
	for VAR in "${REQUIRED_ENV_VARS[@]}"; do
		if ! grep -q "^${VAR}=" /opt/nomnom/deploy/.env; then
			MISSING_VARS+=("$VAR")
		fi
	done

	if [ ${#MISSING_VARS[@]} -eq 0 ]; then
		check_ok "All required variables present in .env"
	else
		check_fail "Missing required variables in .env: ${MISSING_VARS[*]}"
		remediation "Add missing variables to /opt/nomnom/deploy/.env"
	fi

	# Verify NOMNOM_VERSION is NOT in this file
	if grep -q "^NOMNOM_VERSION=" /opt/nomnom/deploy/.env; then
		check_warn "NOMNOM_VERSION found in .env (should only be in /etc/nomnom-deployment/deploy.env)"
		remediation "Remove NOMNOM_VERSION from /opt/nomnom/deploy/.env"
	else
		check_ok "NOMNOM_VERSION not in .env (correct)"
	fi
else
	check_fail ".env not found at /opt/nomnom/deploy/.env"
	remediation "Copy template: cp /opt/nomnom/deploy/production/.env.template /opt/nomnom/deploy/.env"
	remediation "Then edit with correct values for all required variables"
fi

###############################################################################
section "Permissions & ACLs"
###############################################################################

# Check nomnom-deploy can read /opt/nomnom
if sudo -u nomnom-deploy test -r /opt/nomnom/deploy/webhook/deploy.sh; then
	check_ok "nomnom-deploy can read /opt/nomnom/deploy/webhook/deploy.sh"
else
	check_fail "nomnom-deploy cannot read /opt/nomnom/deploy/webhook/deploy.sh"
	remediation "sudo setfacl -R -m u:nomnom-deploy:rx /opt/nomnom"
fi

# Check nomnom-deploy can execute deploy.sh
if sudo -u nomnom-deploy test -x /opt/nomnom/deploy/webhook/deploy.sh; then
	check_ok "nomnom-deploy can execute deploy.sh"
else
	check_fail "nomnom-deploy cannot execute deploy.sh"
	remediation "sudo chmod +x /opt/nomnom/deploy/webhook/deploy.sh"
fi

# Check nomnom-deploy can run docker
if sudo -u nomnom-deploy docker ps >/dev/null 2>&1; then
	check_ok "nomnom-deploy can run docker commands"
else
	check_fail "nomnom-deploy cannot run docker commands"
	remediation "sudo usermod -aG docker nomnom-deploy"
	remediation "User may need to log out and back in for group changes to take effect"
fi

###############################################################################
section "Systemd Service"
###############################################################################

if [ -f /etc/systemd/system/nomnom-webhook.service ]; then
	check_ok "nomnom-webhook.service exists"

	# Check service file contents
	if grep -q "WorkingDirectory=/etc/nomnom-deployment" /etc/systemd/system/nomnom-webhook.service; then
		check_ok "Service has correct WorkingDirectory"
	else
		check_fail "Service has incorrect WorkingDirectory"
		remediation "sudo cp /opt/nomnom/deploy/webhook/nomnom-webhook.service /etc/systemd/system/"
		remediation "sudo systemctl daemon-reload"
	fi

	if grep -q "ExecStart=/usr/bin/webhook -hooks /etc/nomnom-deployment/hooks.json" /etc/systemd/system/nomnom-webhook.service; then
		check_ok "Service has correct ExecStart path"
	else
		check_fail "Service has incorrect ExecStart path"
		remediation "sudo cp /opt/nomnom/deploy/webhook/nomnom-webhook.service /etc/systemd/system/"
		remediation "sudo systemctl daemon-reload"
	fi

	if grep -q "User=nomnom-deploy" /etc/systemd/system/nomnom-webhook.service; then
		check_ok "Service runs as nomnom-deploy user"
	else
		check_warn "Service may not run as nomnom-deploy user"
	fi

	# Check if enabled
	if systemctl is-enabled nomnom-webhook.service &>/dev/null; then
		check_ok "Service is enabled"
	else
		check_fail "Service is not enabled"
		remediation "sudo systemctl enable nomnom-webhook.service"
	fi

	# Check if running
	if systemctl is-active nomnom-webhook.service &>/dev/null; then
		check_ok "Service is running"
	else
		check_fail "Service is not running"
		remediation "sudo systemctl start nomnom-webhook.service"
		remediation "Check logs: sudo journalctl -u nomnom-webhook.service -n 50"
	fi

	# Check recent logs for errors
	if systemctl is-active nomnom-webhook.service &>/dev/null; then
		ERROR_COUNT=$(journalctl -u nomnom-webhook.service --since "5 minutes ago" | grep -ci error || true)
		if [ "$ERROR_COUNT" -eq 0 ]; then
			check_ok "No recent errors in service logs"
		else
			check_warn "Found $ERROR_COUNT error(s) in recent service logs"
			remediation "Check logs: sudo journalctl -u nomnom-webhook.service -n 50"
		fi
	fi
else
	check_fail "nomnom-webhook.service not installed"
	remediation "sudo cp /opt/nomnom/deploy/webhook/nomnom-webhook.service /etc/systemd/system/"
	remediation "sudo systemctl daemon-reload"
	remediation "sudo systemctl enable nomnom-webhook.service"
	remediation "sudo systemctl start nomnom-webhook.service"
fi

###############################################################################
section "Caddy Configuration"
###############################################################################

if command -v caddy &>/dev/null; then
	# Check if Caddy is running
	if systemctl is-active caddy &>/dev/null; then
		check_ok "Caddy service is running"

		# Check Caddy API
		if curl -s http://localhost:2019/config/ >/dev/null 2>&1; then
			check_ok "Caddy admin API is responding"

			# Check for webhook route in active config
			if curl -s http://localhost:2019/config/ 2>/dev/null | grep -q "hooks/deploy"; then
				check_ok "Webhook route is active in Caddy"
			else
				check_warn "Webhook route not found in active Caddy config"
				remediation "The route may not be loaded yet"
				remediation "sudo systemctl reload caddy"
			fi
		else
			check_warn "Caddy admin API not responding at localhost:2019"
		fi
	else
		check_warn "Caddy service is not running"
		remediation "sudo systemctl start caddy"
	fi
else
	check_warn "Caddy not found (skipping Caddy checks)"
fi

###############################################################################
section "Docker Containers"
###############################################################################

# Check if docker compose can run
if [ -f /opt/nomnom/deploy/compose.yml ]; then
	# Try to check container status
	cd /opt/nomnom/deploy
	if docker compose ps >/dev/null 2>&1; then
		check_ok "docker compose can query containers"

		# Show container status
		CONTAINER_COUNT=$(docker compose ps -q | wc -l)
		RUNNING_COUNT=$(docker compose ps --status running -q | wc -l)

		if [ "$CONTAINER_COUNT" -gt 0 ]; then
			check_ok "Found $RUNNING_COUNT/$CONTAINER_COUNT containers running"

			# Show status
			echo "  Container status:"
			docker compose ps --format "table {{.Name}}\t{{.Status}}" | grep -v "^NAME" | sed 's/^/    /'
		else
			check_warn "No containers found (may not be deployed yet)"
		fi
	else
		check_warn "Could not query docker containers"
	fi
	cd - >/dev/null
else
	check_warn "compose.yml not found, skipping container checks"
fi

###############################################################################
section "Connectivity Tests"
###############################################################################

# Get hostname from .env if it exists
if [ -f /opt/nomnom/deploy/.env ]; then
	HOSTNAME=$(grep "^DEPLOYMENT_HOSTNAME=" /opt/nomnom/deploy/.env | cut -d= -f2 | tr -d '"' | tr -d "'")

	if [ -n "$HOSTNAME" ]; then
		echo "Testing webhook endpoint at https://${HOSTNAME}/hooks/deploy ..."

		HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${HOSTNAME}/hooks/deploy" 2>/dev/null || echo "000")

		if [ "$HTTP_CODE" = "000" ]; then
			check_fail "Could not connect to webhook endpoint"
			remediation "Check DNS and firewall for $HOSTNAME"
		elif [ "$HTTP_CODE" = "405" ] || [ "$HTTP_CODE" = "200" ]; then
			check_ok "Webhook endpoint is reachable (HTTP $HTTP_CODE)"
		else
			check_warn "Webhook endpoint returned HTTP $HTTP_CODE"
			remediation "Expected 405 (Method Not Allowed) or 200 without proper auth"
		fi
	else
		check_warn "DEPLOYMENT_HOSTNAME not set in .env, skipping connectivity test"
	fi
else
	check_warn ".env not found, skipping connectivity test"
fi

###############################################################################
section "Summary"
###############################################################################

echo ""
echo "Checks completed: $(date)"
echo ""

if [ $FAILURES -eq 0 ] && [ $WARNINGS -eq 0 ]; then
	echo -e "${GREEN}✓ All checks passed!${NC}"
	echo ""
	echo "The deployment system is properly configured."
	echo "You can now trigger deployments via webhook or manually."
	exit 0
elif [ $FAILURES -eq 0 ]; then
	echo -e "${YELLOW}⚠ ${WARNINGS} warning(s) found${NC}"
	echo ""
	echo "The system should work, but review warnings above."
	exit 0
else
	echo -e "${RED}✗ ${FAILURES} failure(s) and ${WARNINGS} warning(s) found${NC}"
	echo ""
	echo "Please fix the failures above before deploying."
	exit 1
fi
