# NomNom Deployment Setup

This guide covers initial setup and validation of the NomNom deployment system.

## Prerequisites

- Ubuntu/Debian Linux (tested on Ubuntu 22.04)
- Docker and Docker Compose V2
- Caddy web server
- sudo access

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 webhook caddy jq curl acl
```

## User Setup

```bash
sudo useradd -r -s /bin/bash -d /var/lib/nomnom-deploy nomnom-deploy
sudo usermod -aG docker nomnom-deploy
```

## Installation Steps

### 1. Clone Repository

```bash
sudo mkdir -p /opt/nomnom
sudo chown nomnom-deploy:nomnom-deploy /opt/nomnom
sudo -u nomnom-deploy git clone https://github.com/offbyone/lacon-2025.git /opt/nomnom
```

### 2. Create Deployment State Directory

```bash
sudo mkdir -p /etc/nomnom-deployment
sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment
echo "NOMNOM_VERSION=main" | sudo tee /etc/nomnom-deployment/deploy.env
sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/deploy.env
sudo chmod 600 /etc/nomnom-deployment/deploy.env
```

### 3. Configure Application Environment

Create `/opt/nomnom/deploy/.env` with your configuration:

```bash
sudo -u nomnom-deploy nano /opt/nomnom/deploy/.env
```

**For production:**
```bash
DEPLOYMENT_HOSTNAME=nomnom.lacon.org
LOGGING_HOSTNAME=nomnom-lacon-logs
EXPORT_DATA_PATH=/opt/nomnom/deploy/local

NOM_DB_USER=nomnom_prod
NOM_DB_PASSWORD=<generate-password>
NOM_DB_HOST=pgbouncer
NOM_DB_NAME=nomnom_prod
NOM_DB_PORT=6432

DJANGO_SECRET_KEY=<generate-secret>
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=nomnom.lacon.org

EMAIL_HOST=smtp.example.com
EMAIL_PORT=587
EMAIL_HOST_USER=noreply@lacon.org
EMAIL_HOST_PASSWORD=<password>
EMAIL_USE_TLS=True
DEFAULT_FROM_EMAIL=noreply@lacon.org
```

**For staging**, change hostnames and database names accordingly.

Set permissions:
```bash
sudo chmod 600 /opt/nomnom/deploy/.env
```

### 4. Configure pgbouncer

```bash
sudo mkdir -p /opt/nomnom/deploy/pgbouncer
sudo cp /opt/nomnom/deploy/pgbouncer.template/pgbouncer.ini.template \
   /opt/nomnom/deploy/pgbouncer/pgbouncer.ini
sudo cp /opt/nomnom/deploy/pgbouncer.template/userlist.txt.template \
   /opt/nomnom/deploy/pgbouncer/userlist.txt
```

Edit the files:
```bash
sudo -u nomnom-deploy nano /opt/nomnom/deploy/pgbouncer/pgbouncer.ini
sudo -u nomnom-deploy nano /opt/nomnom/deploy/pgbouncer/userlist.txt
```

Generate password hash for userlist.txt:
```bash
echo -n "<password><username>" | md5sum
# Format: "username" "md5<hash>"
```

Set permissions:
```bash
sudo chown -R nomnom-deploy:nomnom-deploy /opt/nomnom/deploy/pgbouncer
sudo chmod 600 /opt/nomnom/deploy/pgbouncer/userlist.txt
```

### 5. Setup Webhook

Copy hooks.json for your stage:
```bash
# Production:
sudo cp /opt/nomnom/deploy/production/webhook/hooks.json /etc/nomnom-deployment/

# Staging:
sudo cp /opt/nomnom/deploy/staging/webhook/hooks.json /etc/nomnom-deployment/
```

Generate webhook secret:
```bash
openssl rand -hex 32 | sudo tee /etc/nomnom-deployment/webhook.secret
sudo chmod 600 /etc/nomnom-deployment/webhook.secret
sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/webhook.secret
```

Set ownership:
```bash
sudo chown nomnom-deploy:nomnom-deploy /etc/nomnom-deployment/hooks.json
```

### 6. Install Webhook Service

Make the wrapper script executable:
```bash
sudo chmod +x /opt/nomnom/deploy/webhook/webhook-wrapper.sh
```

Copy the systemd service file:
```bash
sudo cp /opt/nomnom/deploy/webhook/nomnom-webhook.service /etc/systemd/system/
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable nomnom-webhook.service
sudo systemctl start nomnom-webhook.service
sudo systemctl status nomnom-webhook.service
```

### 7. Configure Caddy

Enable the site Caddy:

```bash
sudo mkdir -p /etc/caddy/site-enabled/
sudo ln -s /opt/nomnom/deploy/<stage>/Caddyfile /etc/caddy/site-enabled/nomnom.conf
```

Ensure that this line is in the `/etc/caddy/Caddyfile`:

```caddy
# Import site-specific configurations
import sites-enabled/*
```

Reload:
```bash
sudo systemctl reload caddy
```

### 8. Test Initial Deployment

```bash
sudo -u nomnom-deploy /opt/nomnom/deploy/webhook/deploy.sh \
  <commit-sha> \
  /opt/nomnom/deploy/compose.yml \
  /etc/nomnom-deployment/deploy.env \
  nomnom.lacon.org \
  /etc/nomnom-deployment/rollback.log
```

### 9. Configure GitHub Environments

The deployment system uses GitHub Actions workflows that trigger webhook calls to the deployment hosts.

#### Environment Setup

In your GitHub repository, configure two environments:

**Staging Environment:**
1. Settings → Environments → New environment → "staging"
2. Add environment secret:
   - `WEBHOOK_SECRET`: Contents of `/etc/nomnom-deployment/webhook.secret` from staging host
3. Add environment variable:
   - `DEPLOY_WEBHOOK_URL`: `https://<staging-hostname>/hooks/deploy-staging`

**Production Environment:**
1. Settings → Environments → New environment → "production"
2. Add environment protection rules:
   - Required reviewers (recommended)
   - Deployment branches: Only protected branches
3. Add environment secret:
   - `WEBHOOK_SECRET`: Contents of `/etc/nomnom-deployment/webhook.secret` from production host
4. Add environment variable:
   - `DEPLOY_WEBHOOK_URL`: `https://nomnom.lacon.org/hooks/deploy-production`

**Note:** `WEBHOOK_SECRET` is stored as a secret (encrypted), while `DEPLOY_WEBHOOK_URL` is stored as a variable (not encrypted) since it's not sensitive information.

#### Deployment Workflows

**Automatic Staging Deployment:**
- Staging is automatically deployed when Docker images are built and pushed to main
- This happens on every push to the main branch
- The full commit SHA is used to identify the deployment

**Manual Production Deployment:**
- Production requires manual workflow trigger
- Go to Actions → Deploy Production → Run workflow
- Optionally specify a SHA to deploy (defaults to latest main)
- Requires environment approval if configured

**Manual Staging Deployment:**
- Can also manually trigger staging deployments via Actions → Deploy Staging
- Useful for deploying specific commits or testing before production

## Validation

Run the verification script:
```bash
sudo /opt/nomnom/deploy/check-setup.sh production  # or staging
```

Fix any issues reported by the script.

## Monitoring

```bash
# Webhook logs
sudo journalctl -u nomnom-webhook.service -f

# Deployment logs
sudo tail -f /etc/nomnom-deployment/rollback.log

# Container logs
sudo docker compose -f /opt/nomnom/deploy/compose.yml logs -f
```

## Troubleshooting

**Webhook not triggering:**
- Check service: `sudo systemctl status nomnom-webhook.service`
- Check Caddy: `sudo systemctl status caddy`
- Test endpoint: `curl https://nomnom.lacon.org/hooks/nomnom-deploy`
- Review GitHub webhook delivery logs

**Deployment failing:**
- Check rollback log: `/etc/nomnom-deployment/rollback.log`
- Check container logs: `sudo docker compose -f /opt/nomnom/deploy/compose.yml logs`
- Verify env vars: `sudo docker compose -f /opt/nomnom/deploy/compose.yml config`

**Permission errors:**
- Verify nomnom-deploy owns files
- Check Docker group: `groups nomnom-deploy`
- Check file permissions: `ls -la /opt/nomnom/deploy/.env /etc/nomnom-deployment/deploy.env`
