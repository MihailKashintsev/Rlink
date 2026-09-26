#!/usr/bin/env bash
# Requires proof of key ownership on /push/subscribe (see patch_push_sig.py).
# RUN THIS ONLY AFTER the 2.5.0 apps are out — older PWAs can't sign yet and
# would be unable to (re)subscribe for push until they update.
# Run from relay_server/. Restarts the relay (~15 s).
set -euo pipefail
KEY="${RELAY_KEY:-$HOME/.ssh/rlink_relay3}"
HOST="${RELAY_HOST:-root@185.244.172.90}"
retry() { for _ in $(seq 1 15); do "$@" && return 0; sleep 3; done; return 1; }
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && cp bin/server.dart bin/server.dart.bak-pushsig-$(date +%s) && python3 - bin/server.dart' \
  < deploy/patch_push_sig.py
retry ssh -i "$KEY" -o ConnectTimeout=10 "$HOST" \
  'cd /root/rlink-relay && docker compose build relay && docker compose up -d relay && sleep 5 && docker logs --tail 5 rlink-relay'
echo "deployed: /push/subscribe now requires a signature from the key's owner"
