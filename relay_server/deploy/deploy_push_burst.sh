#!/usr/bin/env bash
# Deploys the push-burst fix (deploy/patch_push_burst.py) to the running relay
# and restarts it (~15 s downtime). Run from relay_server/. Idempotent.
set -euo pipefail
KEY="${RELAY_KEY:-$HOME/.ssh/rlink_relay3}"
HOST="${RELAY_HOST:-root@185.244.172.90}"
retry() { for _ in $(seq 1 15); do "$@" && return 0; sleep 3; done; return 1; }
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/server.dart bin/server.dart.bak-pushburst-$(date +%s) && python3 - bin/server.dart' \
  < deploy/patch_push_burst.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && docker compose build relay && docker compose up -d relay && sleep 5 && docker logs --tail 5 rlink-relay'
echo "deployed. Check: docker logs --since 5m rlink-relay | grep -c 'Push\]'  (a video circle should now cause 1-2 pushes, not hundreds)"
