#!/usr/bin/env bash
# notify-discord.sh — post a message to Discord via webhook stored in Doppler.
#
# Usage:
#   notify-discord.sh <title> <body>           # body as arg
#   notify-discord.sh <title> < body.txt       # body from stdin
#
# Webhook resolution order:
#   1. $DISCORD_WEBHOOK environment variable
#   2. Doppler secret: project=personal, config=dev, name=DISCORD_WEBHOOK
#
# Exit codes:
#   0 — posted successfully
#   1 — doppler CLI missing and no $DISCORD_WEBHOOK env var
#   2 — failed to fetch DISCORD_WEBHOOK from Doppler
#   3 — curl failed or Discord returned a non-2xx status
#   4 — missing python3 (needed for JSON payload construction)

set -euo pipefail

TITLE="${1:-Notification}"
if [ $# -ge 2 ]; then
  BODY="$2"
else
  BODY="$(cat)"
fi

# Resolve webhook URL.
WEBHOOK="${DISCORD_WEBHOOK:-}"
if [ -z "$WEBHOOK" ]; then
  if ! command -v doppler >/dev/null 2>&1; then
    echo "notify-discord: doppler CLI not installed and \$DISCORD_WEBHOOK not set" >&2
    echo "notify-discord: install with 'brew install dopplerhq/cli/doppler', then 'doppler login'" >&2
    exit 1
  fi
  WEBHOOK="$(doppler secrets get DISCORD_WEBHOOK --plain --project personal --config dev 2>/dev/null || true)"
  if [ -z "$WEBHOOK" ]; then
    echo "notify-discord: failed to fetch DISCORD_WEBHOOK from Doppler (project=personal, config=dev)" >&2
    echo "notify-discord: verify with 'doppler secrets get DISCORD_WEBHOOK --project personal --config dev'" >&2
    exit 2
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "notify-discord: python3 required to build JSON payload" >&2
  exit 4
fi

# Discord caps message content at 2000 chars; truncate with a marker if over.
PAYLOAD="$(python3 -c '
import json, sys
title, body = sys.argv[1], sys.stdin.read()
content = f"**{title}**\n{body}"
if len(content) > 1900:
    content = content[:1900] + "\n...(truncated)"
print(json.dumps({"content": content}))
' "$TITLE" <<< "$BODY")"

TMP_OUT="$(mktemp -t notify-discord.XXXXXX)"
trap 'rm -f "$TMP_OUT"' EXIT

HTTP_CODE="$(curl -sS -o "$TMP_OUT" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-raw "$PAYLOAD" \
  "$WEBHOOK" || echo "000")"

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
  echo "notify-discord: Discord returned HTTP $HTTP_CODE" >&2
  cat "$TMP_OUT" >&2 || true
  exit 3
fi

echo "notify-discord: posted (HTTP $HTTP_CODE)"
