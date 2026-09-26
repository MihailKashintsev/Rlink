#!/usr/bin/env bash
# Deploys the second red-team pass's relay fixes (see patch_security_phase2.py
# for the list) and the oauth token-map bound. Restarts the relay (~15 s
# downtime; clients reconnect). Idempotent — safe to re-run.
# Run from relay_server/.
set -euo pipefail
KEY="${RELAY_KEY:-$HOME/.ssh/rlink_relay3}"
HOST="${RELAY_HOST:-root@185.244.172.90}"
retry() { for _ in $(seq 1 15); do "$@" && return 0; sleep 3; done; return 1; }

retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/server.dart bin/server.dart.bak-secphase2-$(date +%s) && python3 - bin/server.dart' \
  < deploy/patch_security_phase2.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/oauth.dart bin/oauth.dart.bak-secphase2-$(date +%s) && python3 - bin/oauth.dart' \
  < deploy/patch_oauth_bound.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && docker compose build relay && docker compose up -d relay && sleep 5 && docker logs --tail 5 rlink-relay'

echo 'deployed. Sanity check afterwards: watch that relay_mailbox.json does not'
echo 'suddenly shrink to {} under normal traffic (the bug this fixes).'
