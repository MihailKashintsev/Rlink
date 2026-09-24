#!/usr/bin/env bash
# A valid TLS certificate for the relay's BARE IP, so clients can connect to
# wss://185.244.172.90 with no hostname at all.
#
# Why: some home ISPs filter TLS by the hostname in the handshake (SNI) and
# stall the connection — nip.io and duckdns.org names both did (verified: the
# server saw only the first segment of the ClientHello and nothing else). A
# handshake to a bare IP carries no SNI, so there is nothing to filter on.
#
# Let's Encrypt issues IP certificates since 2026-01-15, only with the
# "shortlived" profile (valid ~6.7 days) and certbot >= 5.4 (webroot) — the
# server's apt certbot is 2.9.0, so a newer one is installed from snap and used
# ONLY for this certificate (own config dir + own renewal cron): the existing
# nip.io / duckdns certificates and their apt timer are not touched.
#
# Run on the relay host:
#   ssh root@185.244.172.90 bash -s < deploy/nginx_ip_cert.sh
# Idempotent. If nginx -t fails the new vhost is removed again.
set -euo pipefail
IP=185.244.172.90
SRC=/etc/nginx/sites-enabled/rlink
OUT=/etc/nginx/sites-available/rlink-ip
LINK=/etc/nginx/sites-enabled/rlink-ip
CB=/snap/bin/certbot
CFG=/etc/letsencrypt-ip
WORK=/var/lib/letsencrypt-ip
LOGS=/var/log/letsencrypt-ip
CERT="$CFG/live/rlink-ip"

# 1. A certbot that can do IP certificates.
if [ ! -x "$CB" ]; then
  snap install --classic certbot
fi
ver=$("$CB" --version 2>&1 | awk '{print $2}')
if ! printf '5.4.0\n%s\n' "$ver" | sort -V -C; then
  echo "snap certbot is $ver, IP certificates need >= 5.4.0 — try: snap refresh certbot"
  exit 1
fi
echo "certbot $ver"

# 2. Port-80 vhost for the IP that only serves the ACME challenge.
mkdir -p /var/www/certbot
if [ ! -e "$OUT" ]; then
  cat > "$OUT" <<EOF
server {
    listen 80;
    server_name $IP;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
EOF
fi
ln -sfn "$OUT" "$LINK"
nginx -t || { rm -f "$LINK"; echo "nginx -t failed for the port-80 vhost"; exit 1; }
systemctl reload nginx

# 3. The certificate (own certbot config dir so the apt certbot ignores it).
if [ ! -d "$CERT" ]; then
  "$CB" certonly --webroot -w /var/www/certbot \
    --ip-address "$IP" --preferred-profile shortlived \
    --cert-name rlink-ip \
    --config-dir "$CFG" --work-dir "$WORK" --logs-dir "$LOGS" \
    --non-interactive --agree-tos --register-unsafely-without-email
fi

# 4. HTTPS vhost = the nip.io one (updates, redirects, websocket proxy), as the
#    DEFAULT server for connections that send no SNI (i.e. clients using the IP).
if ! grep -q "listen 443" "$OUT"; then
  python3 - "$IP" "$SRC" "$OUT" "$CERT" <<'PY'
import re, sys
ip, src, out, cert = sys.argv[1:5]
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
tls = tls.replace('/etc/letsencrypt/live/185.244.172.90.nip.io/', cert + '/')
tls = tls.replace('server_name 185.244.172.90.nip.io;', 'server_name ' + ip + ';')
tls = re.sub(r'listen 443 ssl;( # managed by Certbot)?', 'listen 443 ssl default_server;', tls)
assert 'default_server' in tls and cert in tls
open(out, 'a').write('\n' + tls + '\n')
PY
fi
nginx -t || { rm -f "$LINK"; echo "nginx -t failed for the HTTPS vhost — removed it"; exit 1; }
systemctl reload nginx

# 5. Renewal: the certificate lives only ~6 days, so check often.
cat > /etc/cron.d/rlink-ip-cert <<EOF
17 */6 * * * root $CB renew --config-dir $CFG --work-dir $WORK --logs-dir $LOGS --deploy-hook "systemctl reload nginx" -q
EOF
chmod 644 /etc/cron.d/rlink-ip-cert

echo "--- certificate served to a client that sends no SNI:"
echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -dates 2>/dev/null || true
echo "--- health through the bare IP (validated against the system CAs):"
curl -s -m 10 "https://$IP/health" | head -c 200; echo
echo "done: wss://$IP"
