#!/bin/bash
# Wrapper script for webhook service that loads the secret into environment
set -e

# Load webhook secret from file into environment variable
if [ -f /etc/nomnom-deployment/webhook.secret ]; then
	export WEBHOOK_SECRET=$(cat /etc/nomnom-deployment/webhook.secret)
else
	echo "ERROR: /etc/nomnom-deployment/webhook.secret not found" >&2
	exit 1
fi

# Execute webhook with all arguments passed through
exec /usr/bin/webhook "$@"
