#!/bin/bash
# Quick installation checklist script for production/staging hosts
# Run this to verify prerequisites and guide setup

set -e

echo "============================================"
echo "NomNom Webhook Deployment Setup Checklist"
echo "============================================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_ok() {
	echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
	echo -e "${RED}✗${NC} $1"
}

check_warn() {
	echo -e "${YELLOW}!${NC} $1"
}

# Check webhook binary
echo "Checking prerequisites..."
if command -v webhook &>/dev/null; then
	check_ok "webhook binary installed: $(which webhook)"
else
	check_fail "webhook binary not found"
	exit 1
fi

# Check directory
if [ -d /etc/nomnom-deployment ]; then
	check_ok "/etc/nomnom-deployment directory exists"
else
	check_fail "/etc/nomnom-deployment directory missing"
	echo "  Run: sudo mkdir -p /etc/nomnom-deployment"
	echo "       sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment"
	exit 1
fi

# Check user
if id nomnom-deploy &>/dev/null; then
	check_ok "nomnom-deploy user exists"

	# Check docker group membership
	if groups nomnom-deploy | grep -q docker; then
		check_ok "nomnom-deploy is in docker group"
	else
		check_fail "nomnom-deploy is NOT in docker group"
		echo "  Run: sudo usermod -aG docker nomnom-deploy"
	fi
else
	check_fail "nomnom-deploy user does not exist"
	exit 1
fi

# Check ACLs on /opt/nomnom
if [ -d /opt/nomnom ]; then
	check_ok "/opt/nomnom directory exists"
	if getfacl /opt/nomnom/deploy 2>/dev/null | grep -q "user:nomnom-deploy:rwx"; then
		check_ok "nomnom-deploy has rwx access to /opt/nomnom/deploy"
	else
		check_warn "ACL for nomnom-deploy on /opt/nomnom/deploy not set correctly"
		echo "  Run: sudo setfacl -R -m u:nomnom-deploy:rx /opt/nomnom"
		echo "       sudo setfacl -R -m u:nomnom-deploy:rwx /opt/nomnom/deploy"
	fi
else
	check_fail "/opt/nomnom directory does not exist"
fi

echo ""
echo "============================================"
echo "Configuration Files"
echo "============================================"
echo ""

# Check for secret
if [ -f /etc/nomnom-deployment/webhook.secret ]; then
	check_ok "Webhook secret exists"
else
	check_warn "Webhook secret not found"
	echo ""
	echo "Generate webhook secret:"
	echo "  openssl rand -hex 32 | sudo tee /etc/nomnom-deployment/webhook.secret"
	echo "  sudo chmod 600 /etc/nomnom-deployment/webhook.secret"
	echo "  sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/webhook.secret"
	echo ""
fi

# Check for hooks.json
if [ -f /etc/nomnom-deployment/hooks.json ]; then
	check_ok "hooks.json installed"
else
	check_warn "hooks.json not found"
	echo "  Copy from: deploy/staging/webhook/hooks.json or deploy/production/webhook/hooks.json"
	echo "  sudo cp deploy/<stage>/webhook/hooks.json /etc/nomnom-deployment/"
	echo "  sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/hooks.json"
fi

# Check for deploy.sh (should be in repo, not copied)
if [ -f /opt/nomnom/deploy/webhook/deploy.sh ]; then
	check_ok "deploy.sh exists in repo"
	if [ -x /opt/nomnom/deploy/webhook/deploy.sh ]; then
		check_ok "deploy.sh is executable"
	else
		check_warn "deploy.sh is not executable"
		echo "  Run: sudo chmod 755 /opt/nomnom/deploy/webhook/deploy.sh"
	fi
else
	check_warn "deploy.sh not found in repo at /opt/nomnom/deploy/webhook/deploy.sh"
	echo "  This file should be pulled from git, not manually copied"
fi

# Check for deploy.env (should only contain NOMNOM_VERSION)
if [ -f /etc/nomnom-deployment/deploy.env ]; then
	check_ok "deploy.env exists"

	# Check if it has NOMNOM_VERSION
	if grep -q "^NOMNOM_VERSION=" /etc/nomnom-deployment/deploy.env 2>/dev/null; then
		VERSION=$(grep "^NOMNOM_VERSION=" /etc/nomnom-deployment/deploy.env | cut -d= -f2)
		check_ok "NOMNOM_VERSION is set: $VERSION"
	else
		check_warn "NOMNOM_VERSION not set in deploy.env"
		echo "  This file should contain only: NOMNOM_VERSION=sha-xxx (or main)"
	fi

	# Warn if old variables are present
	if grep -qE "^(DEPLOYMENT_HOSTNAME|LOGGING_HOSTNAME|NOM_DB_USER|DJANGO_SECRET_KEY)=" /etc/nomnom-deployment/deploy.env 2>/dev/null; then
		check_warn "deploy.env contains application config variables"
		echo "  These should be moved to /opt/nomnom/deploy/.env"
		echo "  /etc/nomnom-deployment/deploy.env should only contain NOMNOM_VERSION"
	fi
else
	check_warn "deploy.env not found"
	echo "  Create: echo 'NOMNOM_VERSION=main' | sudo tee /etc/nomnom-deployment/deploy.env"
	echo "  sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/deploy.env"
	echo "  sudo chmod 600 /etc/nomnom-deployment/deploy.env"
fi

# Check systemd service
if [ -f /etc/systemd/system/nomnom-webhook.service ]; then
	check_ok "systemd service installed"

	# Check service file paths
	if grep -q "WorkingDirectory=/etc/nomnom-deployment" /etc/systemd/system/nomnom-webhook.service &&
		grep -q "ExecStart=/usr/bin/webhook -hooks /etc/nomnom-deployment/hooks.json" /etc/systemd/system/nomnom-webhook.service; then
		check_ok "Service file paths are correct"
	else
		check_warn "Service file paths may be incorrect"
		echo "  Expected WorkingDirectory=/etc/nomnom-deployment"
		echo "  Expected ExecStart=/usr/bin/webhook -hooks /etc/nomnom-deployment/hooks.json -verbose"
		echo "  Current service file:"
		grep -E "(WorkingDirectory|ExecStart)" /etc/systemd/system/nomnom-webhook.service | sed 's/^/    /'
	fi

	if systemctl is-enabled nomnom-webhook.service &>/dev/null; then
		check_ok "Service is enabled"
	else
		check_warn "Service is not enabled"
		echo "  Run: sudo systemctl enable nomnom-webhook.service"
	fi

	if systemctl is-active nomnom-webhook.service &>/dev/null; then
		check_ok "Service is running"
	else
		check_warn "Service is not running"
		echo "  Run: sudo systemctl start nomnom-webhook.service"
	fi
else
	check_warn "systemd service not installed"
	echo "  Copy from: deploy/webhook/nomnom-webhook.service"
	echo "  sudo cp deploy/webhook/nomnom-webhook.service /etc/systemd/system/"
	echo "  sudo systemctl daemon-reload"
fi

# Check Caddyfile
echo ""
echo "Checking Caddy configuration..."
STAGE_CADDYFILE=""
if [ -f /opt/nomnom/deploy/staging/Caddyfile ]; then
	STAGE_CADDYFILE="/opt/nomnom/deploy/staging/Caddyfile"
	STAGE="staging"
elif [ -f /opt/nomnom/deploy/production/Caddyfile ]; then
	STAGE_CADDYFILE="/opt/nomnom/deploy/production/Caddyfile"
	STAGE="production"
fi

if [ -n "$STAGE_CADDYFILE" ]; then
	check_ok "Caddyfile exists at $STAGE_CADDYFILE"

	if grep -q "/hooks/deploy" "$STAGE_CADDYFILE"; then
		check_ok "Webhook route configured in Caddyfile"
	else
		check_warn "Webhook route NOT found in Caddyfile"
		echo "  The Caddyfile should include a handle block for /hooks/deploy"
	fi

	# Check Caddy is running and config is valid
	if command -v caddy &>/dev/null; then
		if systemctl is-active caddy &>/dev/null; then
			check_ok "Caddy service is running"

			# Check current Caddy config via API
			if curl -s http://localhost:2019/config/ >/tmp/caddy-config-check.json 2>&1; then
				check_ok "Caddy API is responding"

				# Verify webhook route exists in running config
				if grep -q "hooks/deploy" /tmp/caddy-config-check.json 2>/dev/null; then
					check_ok "Webhook route is active in Caddy"
				else
					check_warn "Webhook route not found in active Caddy config"
					echo "  The route may not be loaded yet"
					echo "  Run: sudo systemctl reload caddy"
				fi
				rm -f /tmp/caddy-config-check.json
			else
				check_warn "Caddy API not responding at localhost:2019"
				echo "  Caddy may not have admin API enabled"
			fi
		else
			check_warn "Caddy service is not running"
			echo "  Run: sudo systemctl start caddy"
		fi
	else
		check_warn "Caddy binary not found"
	fi
else
	check_warn "Caddyfile not found at expected location"
fi

# Check deploy directory
if [ -d /opt/nomnom/deploy ]; then
	check_ok "/opt/nomnom/deploy directory exists"

	# Check compose file
	if [ -f /opt/nomnom/deploy/compose.yml ]; then
		check_ok "compose.yml exists"
	else
		check_warn "compose.yml not found"
	fi

	# Check .env file (should contain app config)
	if [ -f /opt/nomnom/deploy/.env ]; then
		check_ok ".env file exists"

		# Check for required variables
		required_vars=(
			"DEPLOYMENT_HOSTNAME"
			"NOM_DB_USER"
			"NOM_DB_PASSWORD"
			"NOM_DB_HOST"
			"NOM_DB_NAME"
            "NOM_SECRET_KEY"
			"NOM_ALLOWED_HOSTS"
		)
		missing_vars=()
		for var in "${required_vars[@]}"; do
			if ! grep -q "^${var}=" /opt/nomnom/deploy/.env 2>/dev/null; then
				missing_vars+=("$var")
			fi
		done

		if [ ${#missing_vars[@]} -eq 0 ]; then
			check_ok "All required variables present in .env"
		else
			check_warn "Missing variables in .env:"
			for var in "${missing_vars[@]}"; do
				echo "    - $var"
			done
			echo "  See deploy/SETUP.md for configuration details"
		fi
	else
		check_fail ".env file not found"
		echo "  Create: sudo -u nomnom-deploy nano /opt/nomnom/deploy/.env"
		echo "  See deploy/SETUP.md for required variables"
	fi
else
	check_fail "/opt/nomnom/deploy directory does not exist"
fi

echo ""
echo "============================================"
echo "Testing"
echo "============================================"
echo ""

# Test webhook endpoint - try to determine hostname from .env
TEST_HOSTNAME="nomnom.lacon.org"
STAGE="production"
if [ -f /opt/nomnom/deploy/.env ]; then
	FOUND_HOSTNAME=$(grep "^DEPLOYMENT_HOSTNAME=" /opt/nomnom/deploy/.env 2>/dev/null | cut -d= -f2)
	if [ -n "$FOUND_HOSTNAME" ]; then
		TEST_HOSTNAME="$FOUND_HOSTNAME"
	fi
	# Detect stage from hostname
	if echo "$TEST_HOSTNAME" | grep -q "staging"; then
		STAGE="staging"
	fi
fi

echo "Testing webhook endpoint at https://${TEST_HOSTNAME}/hooks/deploy ..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${TEST_HOSTNAME}/hooks/deploy" 2>/dev/null)
if echo "$HTTP_CODE" | grep -q "405\|200"; then
	check_ok "Webhook endpoint is reachable (HTTP $HTTP_CODE)"
else
	check_warn "Webhook endpoint returned HTTP $HTTP_CODE"
	echo "  This is expected - the endpoint requires authentication"
fi

echo ""
echo "To test a deployment with a known-good SHA (e.g., 2e5e645):"
echo ""
echo "# On the deployment host, run:"
echo "cat > /tmp/test-deploy.sh << 'EOF'"
echo "#!/bin/bash"
echo "PAYLOAD='{\"hook_id\":\"deploy-${STAGE}\",\"sha\":\"2e5e645\"}'"
echo "SECRET=\$(cat /etc/nomnom-deployment/webhook.secret)"
echo "SIGNATURE=\"sha256=\$(echo -n \"\$PAYLOAD\" | openssl dgst -sha256 -hmac \"\$SECRET\" | sed 's/^.* //')\""
echo "curl -X POST https://${TEST_HOSTNAME}/hooks/deploy \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -H \"X-Hub-Signature-256: \$SIGNATURE\" \\"
echo "  -d \"\$PAYLOAD\""
echo "EOF"
echo "chmod +x /tmp/test-deploy.sh && /tmp/test-deploy.sh"
echo ""

echo ""
echo "============================================"
echo "Next Steps"
echo "============================================"
echo ""
echo "1. Complete any failed/warned checks above"
echo "2. Add WEBHOOK_SECRET to GitHub repository secrets"
echo "3. Test deployment with a known-good SHA"
echo "4. Monitor logs: sudo journalctl -u nomnom-webhook.service -f"
echo ""
