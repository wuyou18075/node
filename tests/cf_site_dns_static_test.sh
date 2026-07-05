#!/usr/bin/env bash
set -euo pipefail

node_script="${1:-node.sh}"
mask_script="${2:-mask-site.sh}"

require_in_file() {
  local file="$1" pattern="$2" message="$3"
  if ! grep -q "$pattern" "$file"; then
    echo "$message" >&2
    exit 1
  fi
}

require_in_file "$node_script" 'cf_upsert_site_dns "$DOMAIN" "$vps_ip" false' \
  "main certificate flow must upsert the primary domain as a DNS-only Cloudflare A record"
require_in_file "$node_script" 'CF_API_TOKEN="${CF_API_TOKEN:-}"' \
  "node.sh must pass CF_API_TOKEN to mask-site.sh"
require_in_file "$node_script" 'SITE_VPS_IP="${SITE_VPS_IP:-$vps_ip}"' \
  "node.sh must pass the detected VPS IP to mask-site.sh"
require_in_file "$node_script" '检测到已有 A 记录' \
  "site DNS upsert must explicitly handle existing A records"

require_in_file "$mask_script" '^CF_API_TOKEN=' \
  "mask-site.sh must accept CF_API_TOKEN from the environment"
require_in_file "$mask_script" '^SITE_VPS_IP=' \
  "mask-site.sh must accept SITE_VPS_IP from the environment"
require_in_file "$mask_script" '^ensure_cloudflare_site_dns()' \
  "mask-site.sh must define a Cloudflare DNS preflight"
require_in_file "$mask_script" 'cf_upsert_site_dns "$SITE_DOMAIN" "$vps_ip" false' \
  "mask-site.sh must upsert the site domain as a DNS-only Cloudflare A record"
require_in_file "$mask_script" 'ensure_cloudflare_site_dns || return 1' \
  "mask-site.sh must run Cloudflare DNS preflight before requesting a certificate"

dns_line="$(grep -n 'ensure_cloudflare_site_dns || return 1' "$mask_script" | head -1 | cut -d: -f1)"
certbot_line="$(grep -n 'certbot certonly --webroot' "$mask_script" | head -1 | cut -d: -f1)"
if [[ -z "$dns_line" || -z "$certbot_line" || "$dns_line" -ge "$certbot_line" ]]; then
  echo "Cloudflare DNS preflight must run before certbot" >&2
  exit 1
fi
