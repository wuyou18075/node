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
issue_cf_origin_certificate() {
  echo "must not issue Cloudflare Origin CA fallback" >&2
  return 1
}
sleep() {
  sleep_count="$((sleep_count + 1))"
  [[ "$1" == "1" ]]
}

cert_files_exist() { [[ "${cert_ready:-0}" == "1" ]]; }
cert_matches_domain() { [[ "${cert_ready:-0}" == "1" && "$DOMAIN" == "site.example.com" ]]; }
cert_is_currently_valid() { [[ "${cert_ready:-0}" == "1" ]]; }
cert_is_publicly_trusted() { [[ "${cert_ready:-0}" == "1" ]]; }
cert_is_cf_origin_ca() { return 1; }

dns_upsert=""
install_count="0"
sleep_count="0"
cert_ready="0"
install_mask_site_nginx() {
  install_count="$((install_count + 1))"
  if [[ "$install_count" == "3" ]]; then
    cert_ready="1"
    return 0
  fi
  return 1
}

configure_domain_certificate_with_config <<< "site.example.com" >/dev/null

[[ "$dns_upsert" == "site.example.com|203.0.113.9|false" ]]
[[ "$install_count" == "3" ]]
[[ "$sleep_count" == "2" ]]
[[ "$SELF_SIGN_CERT" == "0" ]]
[[ "${USE_CF_ORIGIN_CA_CERT:-0}" == "0" ]]

dns_upsert=""
install_count="0"
sleep_count="0"
cert_ready="0"
unset DOMAIN SITE_DOMAIN SNI_VAL REALITY_SNI SELF_SIGN_CERT USE_CF_ORIGIN_CA_CERT
install_mask_site_nginx() {
  install_count="$((install_count + 1))"
  return 1
}

if configure_domain_certificate_with_config <<< "site.example.com" >/dev/null 2>&1; then
  echo "certificate configuration must fail after three failed attempts" >&2
  exit 1
fi

[[ "$dns_upsert" == "site.example.com|203.0.113.9|false" ]]
[[ "$install_count" == "3" ]]
[[ "$sleep_count" == "2" ]]
