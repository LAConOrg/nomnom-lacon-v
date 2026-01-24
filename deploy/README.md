# NomNom Deployment Operations

This guide covers day-to-day deployment operations after initial setup.

## Deployment System Overview

- **Application config**: `/opt/nomnom/deploy/.env` (secrets, DB credentials, OAuth)
- **Version tracking**: `/etc/nomnom-deployment/deploy.env` (auto-updated with `NOMNOM_VERSION=sha-xxx`)
- **Deploy script**: `/opt/nomnom/deploy/webhook/deploy.sh` (stays in repo)
- **Webhook config**: `/etc/nomnom-deployment/hooks.json`

## Normal Deployment Flow

1. Push to `main` branch on GitHub
2. GitHub webhook triggers deployment on staging/production
3. `deploy.sh` pulls new image and restarts containers
4. Health checks run automatically
5. On failure: automatic rollback to previous version

## Manual Deployment

Deploy a specific commit:

```bash
sudo -u nomnom-deploy /opt/nomnom/deploy/webhook/deploy.sh \
  <full-commit-sha> \
  /opt/nomnom/deploy/compose.yml \
  /etc/nomnom-deployment/deploy.env \
  nomnom.lacon.org \
  /etc/nomnom-deployment/rollback.log
```

## Rollback

### Automatic Rollback

Built into `deploy.sh` - triggers on:
- Docker image pull failure
- Container startup failure
- Health check failure

Monitor:
```bash
sudo tail -f /etc/nomnom-deployment/rollback.log
```

### Manual Rollback

Find a good SHA:
```bash
sudo grep 'success' /etc/nomnom-deployment/rollback.log | tail -5
```

Rollback to it:
```bash
sudo -u nomnom-deploy /opt/nomnom/deploy/webhook/deploy.sh \
  <good-sha> \
  /opt/nomnom/deploy/compose.yml \
  /etc/nomnom-deployment/deploy.env \
  nomnom.lacon.org \
  /etc/nomnom-deployment/rollback.log
```

### Emergency Rollback (if deploy.sh is broken)

```bash
# Edit version file
sudo nano /etc/nomnom-deployment/deploy.env
# Change to: NOMNOM_VERSION=sha-<good-version>

# Deploy manually
cd /opt/nomnom/deploy
sudo docker compose pull
sudo docker compose up -d --wait
```

## Monitoring

```bash
# Current version
cat /etc/nomnom-deployment/deploy.env

# Deployment history
sudo tail -20 /etc/nomnom-deployment/rollback.log

# Container status
sudo docker compose -f /opt/nomnom/deploy/compose.yml ps

# Container logs
sudo docker compose -f /opt/nomnom/deploy/compose.yml logs -f

# Webhook service logs
sudo journalctl -u nomnom-webhook.service -f

# Health check
curl -H "Host: nomnom.lacon.org" http://localhost:8000/watchman/ | jq
```

## Updating Configuration

### Update Application Secrets/Config

Edit `/opt/nomnom/deploy/.env`:
```bash
sudo nano /opt/nomnom/deploy/.env
```

Restart containers:
```bash
cd /opt/nomnom/deploy
sudo docker compose up -d
```

### Update Webhook Config

If hooks.json changes in the repo:
```bash
sudo cp /opt/nomnom/deploy/production/webhook/hooks.json /etc/nomnom-deployment/
sudo systemctl restart nomnom-webhook.service
```

### Update Repo Files

The `/opt/nomnom/` directory is a git clone:
```bash
cd /opt/nomnom
git fetch
git checkout <branch-or-tag>
```

This updates compose.yml, deploy.sh, etc. without affecting running containers.

## Common Tasks

### Check Current Deployed Version

```bash
cat /etc/nomnom-deployment/deploy.env
# Output: NOMNOM_VERSION=sha-abc1234
```

### View Deployment History

```bash
sudo tail -20 /etc/nomnom-deployment/rollback.log
```

Entries show:
```
2026-01-25T10:15:30-08:00 [nomnom.lacon.org] deployed sha-abc1234 (success) previous: sha-xyz5678
```

### Test Webhook Endpoint

```bash
curl -v https://nomnom.lacon.org/hooks/nomnom-deploy
# Should return webhook info (not 404)
```

### Restart Containers

```bash
cd /opt/nomnom/deploy
sudo docker compose restart
```

### View Container Logs

```bash
sudo docker compose -f /opt/nomnom/deploy/compose.yml logs web -f
```

### Clean Up Old Docker Images

```bash
sudo docker image prune -a --filter "until=720h"  # Remove images older than 30 days
```

## Troubleshooting

### Deployment Hangs

```bash
# Check if containers are starting
sudo docker compose -f /opt/nomnom/deploy/compose.yml ps

# Check logs
sudo docker compose -f /opt/nomnom/deploy/compose.yml logs

# Kill and restart
sudo docker compose -f /opt/nomnom/deploy/compose.yml down
sudo docker compose -f /opt/nomnom/deploy/compose.yml up -d
```

### Database Connection Issues

```bash
# Check pgbouncer
sudo docker compose -f /opt/nomnom/deploy/compose.yml logs pgbouncer

# Verify credentials in .env
sudo grep NOM_DB /opt/nomnom/deploy/.env

# Test pgbouncer config
sudo cat /opt/nomnom/deploy/pgbouncer/pgbouncer.ini
```

### Webhook Not Triggering

```bash
# Check service status
sudo systemctl status nomnom-webhook.service

# Check recent logs
sudo journalctl -u nomnom-webhook.service --since "10 minutes ago"

# Verify GitHub webhook deliveries (in GitHub repo settings)

# Test webhook manually
curl -X POST https://nomnom.lacon.org/hooks/nomnom-deploy \
  -H "Content-Type: application/json" \
  -d '{"ref":"refs/heads/main","after":"<commit-sha>"}'
```

### Health Check Failures

```bash
# Test health endpoint
curl -H "Host: nomnom.lacon.org" http://localhost:8000/watchman/ | jq

# Check database connectivity
sudo docker compose -f /opt/nomnom/deploy/compose.yml exec web python manage.py check --database default

# Check application logs
sudo docker compose -f /opt/nomnom/deploy/compose.yml logs web
```

## Setup

For initial setup on a new host, see [SETUP.md](./SETUP.md).

## Verification

Verify deployment system health:
```bash
sudo /opt/nomnom/deploy/check-setup.sh production  # or staging
```
