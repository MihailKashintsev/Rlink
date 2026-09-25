#!/usr/bin/env bash
# Deploys the 2026-09-25 "phase 1" security fixes (no protocol/client change)
# to the running relay and restarts it (~15 s downtime; clients reconnect).
# The host's server.dart/oauth.dart have diverged from git, so both are
# patched IN PLACE (idempotent — safe to re-run) instead of being replaced.
# Run from relay_server/. SSH to the relay often times out at connect — every
# step retries.
set -euo pipefail
KEY="${RELAY_KEY:-$HOME/.ssh/rlink_relay3}"
HOST="${RELAY_HOST:-root@185.244.172.90}"
retry() { for _ in $(seq 1 15); do "$@" && return 0; sleep 3; done; return 1; }

retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/server.dart bin/server.dart.bak-secphase1-$(date +%s) && python3 - bin/server.dart' \
  < deploy/patch_security_phase1.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/oauth.dart bin/oauth.dart.bak-secphase1-$(date +%s) && python3 - bin/oauth.dart' \
  < deploy/patch_oauth_ratelimit.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && docker compose build relay && docker compose up -d relay && sleep 5 && docker logs --tail 5 rlink-relay'

echo 'deployed. Sanity checks:'
echo '  curl -s https://185.244.172.90/health   (no more "peers" list)'
echo '  set HEALTH_DETAIL_TOKEN=<a random string you pick> in /root/rlink-relay/.env'
echo '  + add it to docker-compose.yml environment: block, then `docker compose up -d relay`'
echo '  to get the peer list back for your own diagnostics via header X-Health-Token.'
