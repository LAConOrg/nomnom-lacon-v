#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "httpx>=0.27.0",
# ]
# ///
"""Send a signed webhook to trigger deployments.

Usage:
    send_webhook.py <url> <secret> <hook_id> <sha> [options]

Arguments:
    url         Webhook URL to send to
    secret      HMAC secret for signing
    hook_id     Hook identifier (e.g., deploy-staging, deploy-production)
    sha         Git SHA to deploy

Options:
    --ref REF                Git ref (default: refs/heads/main)
    --repository REPO        Repository name (default: laconorg/nomnom-lacon-v)
    --sender SENDER          Sender username (default: github-actions)
    --workflow-run-id ID     GitHub workflow run ID (default: "")

Example:
    send_webhook.py https://example.com/webhook secret123 deploy-staging abc1234567890
"""

import argparse
import hashlib
import hmac
import json
import sys


def create_signature(payload: str, secret: str) -> str:
    """Create HMAC-SHA256 signature for webhook payload."""
    signature = hmac.new(
        secret.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    return f"sha256={signature}"


def send_webhook(url: str, payload: dict, secret: str) -> tuple[int, str]:
    """Send webhook with HMAC signature."""
    import httpx

    payload_json = json.dumps(payload)
    signature = create_signature(payload_json, secret)

    headers = {
        "Content-Type": "application/json",
        "X-Hub-Signature-256": signature,
    }

    print(f"Webhook URL: {url}")
    print(f"Signature: {signature}")
    print(f"Payload:\n{json.dumps(payload, indent=2)}")

    response = httpx.post(url, content=payload_json, headers=headers, timeout=30.0)
    return response.status_code, response.text


def main():
    parser = argparse.ArgumentParser(
        description="Send a signed webhook to trigger deployments",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
  %(prog)s https://example.com/webhook secret123 deploy-staging abc1234567890
        """,
    )

    parser.add_argument("url", help="Webhook URL to send to")
    parser.add_argument("secret", help="HMAC secret for signing")
    parser.add_argument(
        "hook_id", help="Hook identifier (e.g., deploy-staging, deploy-production)"
    )
    parser.add_argument("sha", help="Git SHA to deploy")
    parser.add_argument("--ref", default="refs/heads/main", help="Git ref")
    parser.add_argument(
        "--repository", default="laconorg/nomnom-lacon-v", help="Repository name"
    )
    parser.add_argument("--sender", default="github-actions", help="Sender username")
    parser.add_argument("--workflow-run-id", default="", help="GitHub workflow run ID")

    args = parser.parse_args()

    # Build payload
    payload = {
        "hook_id": args.hook_id,
        "sha": args.sha,
        "ref": args.ref,
        "repository": args.repository,
        "sender": args.sender,
        "triggered_by": "github-actions",
        "workflow_run_id": args.workflow_run_id,
    }

    # Send webhook
    try:
        status_code, response_text = send_webhook(args.url, payload, args.secret)

        print(f"\nHTTP Status: {status_code}")
        print(f"Response: {response_text}")

        if status_code != 200:
            print(f"❌ Webhook failed with status {status_code}")
            print(f"Response body: {response_text}")
            sys.exit(1)

        print("✅ Webhook sent successfully")
    except Exception as e:
        print(f"❌ Error sending webhook: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
