#!/usr/bin/env bash
set -euo pipefail

mask_script="${1:-mask-site.sh}"

source <(sed '/^case "\${1:-}"/,$ d' "$mask_script")

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

SITE_DOMAIN="gf7.cj7.kdns.fr"
SITE_ROOT="${tmpdir}/site"
NGINX_SITE_CONF="${tmpdir}/nginx.conf"
SSL_DIR="${tmpdir}/ssl"
SUB_NGINX_ENABLED="1"
SUB_NGINX_PATH="/test"
SUB_NGINX_AUTH_FILE="${tmpdir}/sub.htpasswd"
SUB_PORT="57896"
SUB_PATH="sub-60713a3101616eb06d65c64c"
SELF_SIGN_CERT="0"

write_https_nginx_config

grep -q 'limit_req_zone $binary_remote_addr zone=agsb_sub_auth:10m rate=5r/m;' "$NGINX_SITE_CONF"
grep -q 'location \^~ /test' "$NGINX_SITE_CONF"
grep -q 'auth_basic "Subscription";' "$NGINX_SITE_CONF"
grep -q "auth_basic_user_file ${SUB_NGINX_AUTH_FILE};" "$NGINX_SITE_CONF"
grep -q 'limit_req zone=agsb_sub_auth burst=5 nodelay;' "$NGINX_SITE_CONF"
grep -q 'rewrite \^/test/?(.*)$ /sub-60713a3101616eb06d65c64c/$1 break;' "$NGINX_SITE_CONF"
grep -q 'proxy_pass https://127.0.0.1:57896;' "$NGINX_SITE_CONF"
grep -q 'proxy_ssl_verify off;' "$NGINX_SITE_CONF"
