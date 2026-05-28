#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/dist/tilda-web"
BASE_HREF="${RLINK_WEB_BASE_HREF:-/rlink_web/}"

cd "$ROOT_DIR"
git_sha="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
build_stamp="$(date -u +%Y%m%d%H%M%S)"
WEB_PUSH_ID="${RLINK_WEB_PUSH_ID:-$build_stamp-$git_sha}"

flutter build web --release \
  --pwa-strategy=none \
  --base-href "$BASE_HREF" \
  --dart-define="RLINK_WEB_PUSH_ID=$WEB_PUSH_ID"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$ROOT_DIR/build/web/"* "$OUT_DIR/"
cp "$ROOT_DIR/docs/tilda/rlink-tilda-embed.html" "$OUT_DIR/embed.html"
cp "$ROOT_DIR/docs/tilda/rlink-tilda-block-config.html" "$OUT_DIR/block-config.html"
cp "$ROOT_DIR/docs/tilda/rlink-tilda-block-app.html" "$OUT_DIR/block-app.html"

ver_line="$(grep '^version:' "$ROOT_DIR/pubspec.yaml" | head -1 | sed 's/^version:[[:space:]]*//;s/[[:space:]]*$//')"
app_ver="${ver_line%%+*}"
build_num="${ver_line#*+}"
[ "$build_num" = "$ver_line" ] && build_num="0"
printf '{"app_name":"rlink","version":"%s","build_number":"%s","package_name":"rlink","web_push_id":"%s"}\n' \
  "$app_ver" "$build_num" "$WEB_PUSH_ID" > "$OUT_DIR/version.json"

echo "Tilda bundle created: $OUT_DIR (base-href=$BASE_HREF, web-push=$WEB_PUSH_ID)"
