#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source <(sed '/^# 启动入口执行/,$ d' "$script")

STATE_DIR="$tmp_dir/state"
CONFIG_DIR="$tmp_dir/config"
NODE_CONFIG_FILE="$CONFIG_DIR/node.config"
SSL_DIR="$tmp_dir/ssl"

ensure_packages_for_commands() { return 0; }
detect_public_ipv4() { printf '203.0.113.9\n'; }
save_state() { printf 'save_state\n' >> "$calls_file"; }
save_node_config() { printf 'save_node_config\n' >> "$calls_file"; }
install_sing_box() { echo "must not install sing-box" >&2; return 1; }
write_sing_box_config() { echo "must not write sing-box config" >&2; return 1; }
do_one_click_all_with_cdn() { echo "must not run one-click protocols" >&2; return 1; }

calls_file="$tmp_dir/calls.log"

cf_api_request() {
  local method="$1" path="$2" data="${3:-}"
  printf '%s\t%s\t%s\n' "$method" "$path" "$data" >> "$calls_file"

  case "${method} ${path}" in
    "GET /zones?name=edge.example.com&status=active&per_page=1")
      printf '{"success":true,"result":[]}\n'
      ;;
    "GET /zones?name=example.com&status=active&per_page=1")
      printf '{"success":true,"result":[{"id":"zone_test","name":"example.com","account":{"id":"acct_test"}}]}\n'
      ;;
    "GET /zones/zone_test/dns_records?name=edge.example.com&per_page=100")
      printf '{"success":true,"result":[]}\n'
      ;;
    "POST /zones/zone_test/dns_records")
      printf '{"success":true,"result":{"id":"dns_test"}}\n'
      ;;
    "PATCH /zones/zone_test/ssl/universal/settings")
      printf '{"success":true,"result":{"enabled":true}}\n'
      ;;
    "GET /zones/zone_test/ssl/certificate_packs?per_page=100")
      printf '{"success":true,"result":[{"id":"pack_test","type":"universal","status":"active","hosts":["example.com","*.example.com"]}]}\n'
      ;;
    *)
      echo "unexpected CF API call: ${method} ${path}" >&2
      return 1
      ;;
  esac
}

configure_cf_orange_edge_certificate <<< $'edge.example.com\ntoken_test_123' >/dev/null

grep -q $'POST\t/zones/zone_test/dns_records' "$calls_file"
grep -q $'PATCH\t/zones/zone_test/ssl/universal/settings' "$calls_file"
grep -q $'GET\t/zones/zone_test/ssl/certificate_packs?per_page=100' "$calls_file"
grep -q $'save_state' "$calls_file"
grep -q $'save_node_config' "$calls_file"

dns_payload="$(awk -F '\t' '$1 == "POST" && $2 == "/zones/zone_test/dns_records" { print $3 }' "$calls_file")"
printf '%s' "$dns_payload" | jq -e '.type == "A" and .name == "edge.example.com" and .content == "203.0.113.9" and .proxied == true' >/dev/null

ssl_payload="$(awk -F '\t' '$1 == "PATCH" && $2 == "/zones/zone_test/ssl/universal/settings" { print $3 }' "$calls_file")"
printf '%s' "$ssl_payload" | jq -e '.enabled == true' >/dev/null

[[ "$DOMAIN" == "edge.example.com" ]]
[[ "$SITE_DOMAIN" == "edge.example.com" ]]
[[ "$CF_API_TOKEN" == "token_test_123" ]]
