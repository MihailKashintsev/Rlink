#!/usr/bin/env bash
# Deploys the `backup_redeemed` advisory endpoint (file-based account backup
# feature). Restarts the relay (~15 s downtime; clients reconnect).
# Idempotent — safe to re-run. Run from relay_server/.
set -euo pipefail
KEY="${RELAY_KEY:-$HOME/.ssh/rlink_relay3}"
HOST="${RELAY_HOST:-root@185.244.172.90}"
retry() { for _ in $(seq 1 15); do "$@" && return 0; sleep 3; done; return 1; }

retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/server.dart bin/server.dart.bak-backupredeemed-$(date +%s) && python3 - bin/server.dart' \
  < deploy/patch_backup_redeemed.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && docker compose build relay && docker compose up -d relay && sleep 5 && docker logs --tail 5 rlink-relay'

echo 'deployed: backup_redeemed handler is live.'
