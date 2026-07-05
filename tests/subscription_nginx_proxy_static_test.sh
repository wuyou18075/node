#!/usr/bin/env bash
set -euo pipefail

node_script="${1:-node.sh}"
mask_script="${2:-mask-site.sh}"
subscription_script="${3:-subscription-link.sh}"

require_pattern() {
  local file="$1" pattern="$2" message="$3"
  if ! grep -q "$pattern" "$file"; then
    echo "$message" >&2
    exit 1
  fi
}

require_pattern "$node_script" 'SUBSCRIPTION_LINK_SCRIPT_URL' \
  "node.sh must know how to fetch the standalone subscription link manager"
require_pattern "$node_script" 'subscription-link.sh' \
  "node.sh must call the standalone subscription-link.sh script"
require_pattern "$node_script" 'run_subscription_link_script configure' \
  "menu option 8 must delegate subscription link setup to the standalone script"

require_pattern "$subscription_script" 'SUB_NGINX_ENABLED="1"' \
  "subscription nginx setup must persist an enabled flag"
require_pattern "$subscription_script" 'SUB_NGINX_PATH' \
  "subscription nginx setup must persist a custom public path"
require_pattern "$subscription_script" 'SUB_NGINX_AUTH_FILE' \
  "subscription nginx setup must persist the nginx basic-auth file"
require_pattern "$subscription_script" 'openssl passwd -apr1' \
  "subscription nginx setup must store an Apache MD5 htpasswd hash instead of plaintext"
require_pattern "$subscription_script" 'run_mask_site_script refresh-nginx' \
  "subscription nginx setup must refresh nginx after saving state"

require_pattern "$mask_script" 'SUB_NGINX_ENABLED' \
  "mask-site.sh must load subscription nginx proxy state"
require_pattern "$mask_script" 'auth_basic' \
  "subscription nginx proxy must require browser basic auth"
require_pattern "$mask_script" 'limit_req_zone' \
  "subscription nginx proxy must define request rate limiting"
require_pattern "$mask_script" 'limit_req zone=agsb_sub_auth' \
  "subscription nginx proxy must apply request rate limiting to the protected path"
require_pattern "$mask_script" 'proxy_pass ${sub_proxy_scheme}://127.0.0.1:${SUB_PORT}' \
  "subscription nginx proxy must proxy to the local subscription service port"
