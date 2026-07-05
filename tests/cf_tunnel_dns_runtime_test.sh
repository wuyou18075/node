#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

source <(sed '/^# 启动入口执行/,$ d' "$script")

ARGO_CF_ZONE_ID="zone_test"
ARGO_FIXED_DOMAIN="argo.example.com"
ARGO_TUNNEL_ID="11111111-2222-3333-4444-555555555555"

calls_file="$(mktemp)"
trap 'rm -f "$calls_file"' EXIT
get_count=0

cf_api_request() {
  local method="$1" path="$2" data="${3:-}"
  printf '%s\t%s\t%s\n' "$method" "$path" "$data" >> "$calls_file"

  if [[ "$method" == "GET" && "$path" == "/zones/zone_test/dns_records?name=argo.example.com&per_page=100" ]]; then
    get_count=$((get_count + 1))
    if (( get_count == 1 )); then
      cat <<'JSON'
{"success":true,"result":[
  {"id":"old_a_1","type":"A","content":"104.21.74.6","proxied":true},
  {"id":"old_a_2","type":"A","content":"172.67.152.118","proxied":true}
]}
JSON
    else
      printf '{"success":true,"result":[]}\n'
    fi
    return 0
  fi

  printf '{"success":true,"result":{}}\n'
}

cf_upsert_tunnel_dns >/dev/null

grep -q $'DELETE\t/zones/zone_test/dns_records/old_a_1' "$calls_file" || {
  echo "tunnel DNS upsert must delete the first stale A record" >&2
  exit 1
}

grep -q $'DELETE\t/zones/zone_test/dns_records/old_a_2' "$calls_file" || {
  echo "tunnel DNS upsert must delete all stale A records" >&2
  exit 1
}

post_payload="$(awk -F '\t' '$1 == "POST" && $2 == "/zones/zone_test/dns_records" { print $3 }' "$calls_file")"
[[ -n "$post_payload" ]] || {
  echo "tunnel DNS upsert must create a CNAME record after deleting stale records" >&2
  exit 1
}

printf '%s' "$post_payload" | jq -e \
  '.type == "CNAME" and .name == "argo.example.com" and .content == "11111111-2222-3333-4444-555555555555.cfargotunnel.com" and .proxied == true and .ttl == 1' >/dev/null || {
    echo "tunnel DNS upsert must point the hostname at the Cloudflare tunnel CNAME" >&2
    exit 1
  }
