#!/usr/bin/env bash
# Deploys Web Push payload encryption (bin/webpush_crypto.dart + server.dart
# patch) to the running relay and restarts it (~15 s of downtime; clients
# reconnect). The host's server.dart has diverged from git, so it is patched IN
# PLACE (idempotent) instead of being replaced. Run from relay_server/.
# SSH to the relay often times out at connect — every step retries.
set -euo pipefail
KEY="${RELAY_KEY:-$HOME/.ssh/rlink_relay3}"
HOST="${RELAY_HOST:-root@185.244.172.90}"
retry() { for _ in $(seq 1 15); do "$@" && return 0; sleep 3; done; return 1; }

retry scp -i "$KEY" -o ConnectTimeout=10 bin/webpush_crypto.dart \
  "$HOST:/root/rlink-relay/bin/webpush_crypto.dart"
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/server.dart bin/server.dart.bak-webpush-$(date +%s) && python3 - bin/server.dart' \
  < deploy/patch_webpush.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && docker compose build relay && docker compose up -d relay && sleep 5 && docker logs --tail 5 rlink-relay'
echo 'deployed. Check: curl -s -X POST https://185.244.172.90.nip.io/push/test -d "{\"publicKey\":\"<64-hex>\"}"'
echo 'and look for "201 web.push.apple.com" (no more "400") in: docker logs rlink-relay'
