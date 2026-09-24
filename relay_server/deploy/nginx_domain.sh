#!/usr/bin/env bash
# Adds a second hostname for the relay (same server) to nginx + a Let's Encrypt
# certificate for it, without downtime (webroot challenge).
#
# Why: some networks stall the TLS handshake for `*.nip.io` names (SNI
# filtering) while the very same server works under another name.
#
# Prerequisite: an A record  <domain> -> 185.244.172.90  already resolves.
# Run on the relay host:
#   ssh root@185.244.172.90 bash -s -- rlinkrelay.duckdns.org < deploy/nginx_domain.sh
# Idempotent: re-running only fills in whatever is missing.
set -euo pipefail
DOMAIN="${1:?usage: nginx_domain.sh <domain>}"
IP=185.244.172.90
SRC=/etc/nginx/sites-enabled/rlink
OUT=/etc/nginx/sites-available/rlink-domain-$DOMAIN

got=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
if [[ "$got" != *"$IP"* ]]; then
  echo "DNS: $DOMAIN -> '${got}' (expected $IP). Add the A record and wait for it to propagate."
  exit 1
fi

# 1. Port-80 vhost that only serves the ACME challenge.
mkdir -p /var/www/certbot
if [ ! -e "$OUT" ]; then
  cat > "$OUT" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
fi
# (a symlink, and NOT a backup copy: everything in sites-enabled is loaded)
ln -sfn "$OUT" "/etc/nginx/sites-enabled/rlink-domain-$DOMAIN"
nginx -t
systemctl reload nginx

# 2. Certificate (auto-renewed by certbot's timer through the same webroot).
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email
fi

# 3. HTTPS vhost = the existing nip.io one (updates, redirects, websocket
#    proxy) with the new server_name and certificate paths.
if ! grep -q "listen 443" "$OUT"; then
  python3 - "$DOMAIN" "$SRC" "$OUT" <<'PY'
import re, sys
domain, src, out = sys.argv[1:4]
s = open(src).read()
blocks, i = [], 0
while True:
    m = re.search(r'^server\s*\{', s[i:], re.M)
    if not m:
        break
    start = i + m.start()
    depth, j = 0, start
    while True:
        c = s[j]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    blocks.append(s[start:j + 1])
    i = j + 1
tls = next(b for b in blocks if 'listen 443' in b)
open(out, 'a').write('\n' + tls.replace('185.244.172.90.nip.io', domain) + '\n')
PY
fi
nginx -t
systemctl reload nginx

echo "--- check (through the new name, from this host)"
curl -s -m 10 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/health" | head -c 200; echo
echo "done: wss://$DOMAIN"
