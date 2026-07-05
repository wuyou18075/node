#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

source <(sed '/^# 启动入口执行/,$ d' "$script")

ensure_packages_for_commands() { return 0; }

cf_find_zone_for_host() {
  ARGO_CF_ZONE_ID="zone_test"
  ARGO_CF_ZONE_NAME="example.com"
  return 0
}

calls_file="$(mktemp)"
trap 'rm -f "$calls_file"' EXIT
get_count=0

cf_api_request() {
  local method="$1" path="$2" data="${3:-}"
  printf '%s\t%s\t%s\n' "$method" "$path" "$data" >> "$calls_file"

  if [[ "$method" == "GET" && "$path" == "/zones/zone_test/dns_records?name=site.example.com&per_page=100" ]]; then
    get_count=$((get_count + 1))
    if (( get_count == 1 )); then
      cat <<'JSON'
{"success":true,"result":[
  {"id":"old_a","type":"A","content":"198.51.100.7","proxied":true},
  {"id":"extra_a","type":"A","content":"198.51.100.8","proxied":false},
  {"id":"old_aaaa","type":"AAAA","content":"2001:db8::1","proxied":false}
]}
JSON
    else
      cat <<'JSON'
{"success":true,"result":[
  {"id":"old_a","type":"A","content":"198.51.100.7","proxied":true},
  {"id":"extra_a","type":"A","content":"198.51.100.8","proxied":false}
]}
JSON
    fi
    return 0
  fi

  printf '{"success":true,"result":{}}\n'
}

cf_upsert_site_dns "site.example.com" "203.0.113.9" false >/dev/null

grep -q $'DELETE\t/zones/zone_test/dns_records/old_aaaa' "$calls_file" || {
  echo "site DNS upsert must delete stale AAAA/conflicting records" >&2
  exit 1
}

grep -q $'DELETE\t/zones/zone_test/dns_records/extra_a' "$calls_file" || {
  echo "site DNS upsert must delete extra A records" >&2
  exit 1
}

put_payload="$(awk -F '\t' '$1 == "PUT" && $2 == "/zones/zone_test/dns_records/old_a" { print $3 }' "$calls_file")"
[[ -n "$put_payload" ]] || {
  echo "site DNS upsert must update the existing A record" >&2
  exit 1
}

printf '%s' "$put_payload" | jq -e '.type == "A" and .name == "site.example.com" and .content == "203.0.113.9" and .proxied == false and .ttl == 1' >/dev/null || {
  echo "site DNS upsert must update the record to the VPS IP with DNS-only mode" >&2
  exit 1
}
