#!/usr/bin/env bash
set -euo pipefail

mask_script="${1:-mask-site.sh}"

source <(sed '/^case "\${1:-}"/,$ d' "$mask_script")

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

SITE_DOMAIN="aaa.bbb.com"
SITE_ROOT="${tmpdir}/site"
NGINX_SITE_CONF="${tmpdir}/nginx.conf"
SSL_DIR="${tmpdir}/ssl"
CDN_VMESS_VIA_NGINX="1"
CDN_VMESS_CDN_DOMAIN="cdnaaa.bbb.com"
CDN_VMESS_WS_PATH="/cdn-test"
CDN_VMESS_PORT="55001"

write_https_nginx_config

grep -q 'server_name aaa.bbb.com cdnaaa.bbb.com;' "$NGINX_SITE_CONF"
grep -q 'location /cdn-test' "$NGINX_SITE_CONF"
grep -q 'proxy_pass http://127.0.0.1:55001;' "$NGINX_SITE_CONF"
