#!/usr/bin/env bash
# Old versioned download links (still published on third-party sites, e.g.
# /updates/Rlink-v1.9.0-arm64.apk) 404 because the relay keeps only the current
# release. This adds nginx redirects to /updates/latest/* and creates those
# symlinks for the release that is currently published. CI re-points them on
# every release (see .github/workflows/release.yml).
# Run on the relay host:  ssh root@185.244.172.90 bash -s < deploy/nginx_latest.sh
set -e
CONF=/etc/nginx/sites-enabled/rlink
D=/var/www/rlink-updates
if grep -q "rlink-latest-redirect" "$CONF"; then
  echo "nginx already patched"
else
  # Backup OUTSIDE sites-enabled (everything in that dir is loaded by nginx).
  cp "$CONF" /root/nginx-rlink.bak-latest-$(date +%Y%m%d%H%M%S)
  python3 - <<'PY'
p = '/etc/nginx/sites-enabled/rlink'
s = open(p).read()
snip = '''    # rlink-latest-redirect: old versioned download links go to the current
    # release via /updates/latest/*.
    location ~ ^/updates/(?<fname>Rlink-v[0-9][0-9.]*-(?<arch>arm64|arm32)\\.apk)$ {
        alias /var/www/rlink-updates/$fname;
        if (!-f $request_filename) { return 302 /updates/latest/Rlink-$arch.apk; }
        add_header 'Access-Control-Allow-Origin' '*' always;
    }
    location ~ ^/updates/(?<fname>rlink_v[0-9][0-9.]*_(?<os>windows|macos)\\.zip)$ {
        alias /var/www/rlink-updates/$fname;
        if (!-f $request_filename) { return 302 /updates/latest/Rlink-$os.zip; }
        add_header 'Access-Control-Allow-Origin' '*' always;
    }

'''
anchor = '    location / {\n        proxy_pass'
assert s.count(anchor) == 1
open(p, 'w').write(s.replace(anchor, snip + anchor, 1))
PY
fi
# Stable "latest" symlinks for whatever version is currently published.
mkdir -p $D/latest
cd $D
for spec in "Rlink-*-arm64.apk:Rlink-arm64.apk" "Rlink-*-arm32.apk:Rlink-arm32.apk" \
            "rlink_*_windows.zip:Rlink-windows.zip" "rlink_*_macos.zip:Rlink-macos.zip"; do
  pat=${spec%%:*}; name=${spec##*:}
  f=$(ls -1 $pat 2>/dev/null | tail -1 || true)
  [ -n "$f" ] && ln -sfn "../$f" "latest/$name" && echo "latest/$name -> $f"
done
nginx -t
systemctl reload nginx && echo "nginx reloaded"
