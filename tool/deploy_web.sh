#!/usr/bin/env bash
# Deploy the web build to a server, served at http://<host>/second-reality-flutter/
#
#   ./tool/deploy_web.sh root@<server-ip>
#
# THE BASE HREF IS NOT OPTIONAL. Flutter web bakes its base path into
# index.html, so a build served from a SUBFOLDER must be built with
# --base-href /second-reality-flutter/ or every asset is fetched from the domain
# ROOT and the page comes up black with 404s. This script always rebuilds with
# it, so a root-relative build can never be shipped by accident.
#
# --pwa-strategy=none: a service worker from an older build will happily serve
# its cached main.dart.js AND the 22MB soundtrack forever, ignoring
# Cache-Control. Not worth the debugging.
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 user@host   (the server is an ARGUMENT, never committed)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="/second-reality-flutter/"
REMOTE_DIR="/var/www/second-reality-flutter"

echo "==> building (base-href $BASE)"
cd "$ROOT"
flutter build web --pwa-strategy=none --base-href "$BASE"

echo "==> installing nginx if it is not there, and opening the firewall"
ssh "$TARGET" 'set -e
  if ! command -v nginx >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq nginx
  fi
  mkdir -p /var/www/second-reality-flutter
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp || true
  fi'

echo "==> uploading $(du -sh build/web | cut -f1)"
# --delete so a removed asset does not linger and get served forever.
# NOTE: macOS ships Apple's openrsync, which has no --info=progress2 (it dies
# with a usage dump). Plain --progress works on both it and GNU rsync.
rsync -az --delete --progress build/web/ "$TARGET:$REMOTE_DIR/"

echo "==> nginx site"
scp -q "$ROOT/tool/nginx-second-reality.conf" "$TARGET:/etc/nginx/sites-available/second-reality-flutter"
ssh "$TARGET" 'set -e
  # Ubuntu ships a `default` site that already claims default_server on :80, and
  # nginx refuses to start with two. Drop the stock welcome page.
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/second-reality-flutter \
         /etc/nginx/sites-enabled/second-reality-flutter
  nginx -t
  systemctl reload nginx || systemctl restart nginx'

HOST="${TARGET#*@}"
echo
echo "deployed -> http://$HOST/second-reality-flutter/"
echo
echo "If it does not answer, the Hetzner CLOUD FIREWALL is the usual reason:"
echo "  nothing was listening on 80 or 443 before this ran, so check the"
echo "  firewall rules for this server in the Hetzner console and allow 80/tcp."
