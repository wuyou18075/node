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
CF_API_TOKEN="token_test_123"

confirm_reuse_config_value() { return 1; }
detect_public_ipv4() { printf '203.0.113.9\n'; }
save_state() { :; }
cf_upsert_site_dns() {
  dns_upsert="$1|$2|$3"
}
sleep() {
  sleep_count="$((sleep_count + 1))"
  [[ "$1" == "1" ]]
}

cert_files_exist() { [[ "${site_installed:-0}" == "1" ]]; }
cert_matches_domain() { [[ "${site_installed:-0}" == "1" && "$DOMAIN" == "site.example.com" ]]; }
cert_is_currently_valid() { [[ "${site_installed:-0}" == "1" ]]; }
cert_is_publicly_trusted() { [[ "${site_installed:-0}" == "1" ]]; }
cert_is_cf_origin_ca() { return 1; }

dns_upsert=""
resolve_count="0"
sleep_count="0"
site_install_count="0"
site_installed="0"
domain_resolves_to_ip() {
  resolve_count="$((resolve_count + 1))"
  [[ "$1" == "site.example.com" ]]
  [[ "$2" == "203.0.113.9" ]]
  [[ "$resolve_count" == "3" ]]
}
install_mask_site_nginx() {
  site_install_count="$((site_install_count + 1))"
  site_installed="1"
}

configure_domain_certificate_with_config <<< "site.example.com" >/dev/null

[[ "$dns_upsert" == "site.example.com|203.0.113.9|false" ]]
[[ "$resolve_count" == "3" ]]
[[ "$sleep_count" == "2" ]]
[[ "$site_install_count" == "1" ]]
[[ "$SELF_SIGN_CERT" == "0" ]]

dns_upsert=""
resolve_count="0"
sleep_count="0"
site_install_count="0"
site_installed="0"
unset DOMAIN SITE_DOMAIN SNI_VAL REALITY_SNI SELF_SIGN_CERT USE_CF_ORIGIN_CA_CERT
domain_resolves_to_ip() {
  resolve_count="$((resolve_count + 1))"
  return 1
}

if configure_domain_certificate_with_config <<< "site.example.com" >/dev/null 2>&1; then
  echo "certificate configuration must fail when DNS never resolves to the VPS IP" >&2
  exit 1
fi

[[ "$dns_upsert" == "site.example.com|203.0.113.9|false" ]]
[[ "$resolve_count" == "3" ]]
[[ "$sleep_count" == "2" ]]
[[ "$site_install_count" == "0" ]]
