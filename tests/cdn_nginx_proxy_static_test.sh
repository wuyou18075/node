#!/usr/bin/env bash
set -euo pipefail

node_script="${1:-node.sh}"
mask_script="${2:-mask-site.sh}"

require_pattern() {
  local file="$1" pattern="$2" message="$3"
  if ! grep -q "$pattern" "$file"; then
    echo "$message" >&2
    exit 1
  fi
}

require_pattern "$node_script" 'CDN_VMESS_CLIENT_PORT' \
  "node.sh must track the CDN client edge port separately from the local inbound port"
require_pattern "$node_script" 'CDN_VMESS_VIA_NGINX="1"' \
  "option 4 must route CDN VMess through nginx on origin port 443"
require_pattern "$node_script" '指定端口443/2053/2083/2087/2096/8443/自定义回源，回车随机50000-60000' \
  "option 4 must show the requested CDN port prompt"
require_pattern "$node_script" 'CDN_VMESS_CLIENT_PORT=""' \
  "non-option-4 CDN flows must clear the option-4 client edge port"
require_pattern "$node_script" 'CDN_VMESS_VIA_NGINX="0"' \
  "non-option-4 CDN flows must clear the option-4 nginx routing mode"
require_pattern "$node_script" 'cf_configure_cdn_vmess "$cdn_domain_input" "$(cdn_vmess_origin_port)"' \
  "Cloudflare Origin Rule must use the explicit CDN origin port"
require_pattern "$node_script" 'VMESS_VIA_NGINX:-0.*CDN_VMESS_VIA_NGINX:-0' \
  "nginx refresh must run when either VMess or CDN VMess uses nginx"

require_pattern "$mask_script" 'CDN_VMESS_VIA_NGINX' \
  "mask-site.sh must load CDN VMess nginx proxy state"
require_pattern "$mask_script" 'CDN_VMESS_CDN_DOMAIN' \
  "mask-site.sh must load the CDN VMess hostname for nginx server_name"
require_pattern "$mask_script" 'nginx_server_names' \
  "mask-site.sh must include CDN VMess hostname in nginx server names"
require_pattern "$mask_script" 'location ${CDN_VMESS_WS_PATH}' \
  "mask-site.sh must create an nginx location for the CDN VMess WebSocket path"
require_pattern "$mask_script" 'proxy_pass http://127.0.0.1:${CDN_VMESS_PORT}' \
  "mask-site.sh must proxy CDN VMess WebSocket traffic to the local sing-box inbound"
