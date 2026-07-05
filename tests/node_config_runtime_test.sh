#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source <(sed '/^# 启动入口执行/,$ d' "$script")

CONFIG_DIR="$tmp_dir"
NODE_CONFIG_FILE="${tmp_dir}/node.config"

DOMAIN="aaa.bbb.com"
UUID="11111111-1111-4111-8111-111111111111"
CF_API_TOKEN="tok_test_abcdef"
NODE_PREFIX="testnode"
ARGO_FIXED_DOMAIN="$(recommend_argo_domain "$DOMAIN")"
CDN_VMESS_CDN_DOMAIN="$(recommend_cdn_domain "$DOMAIN")"

save_node_config

unset UUID CF_API_TOKEN DOMAIN NODE_PREFIX ARGO_FIXED_DOMAIN CDN_VMESS_CDN_DOMAIN
load_node_config

[[ "$DOMAIN" == "aaa.bbb.com" ]]
[[ "$UUID" == "11111111-1111-4111-8111-111111111111" ]]
[[ "$CF_API_TOKEN" == "tok_test_abcdef" ]]
[[ "$NODE_PREFIX" == "testnode" ]]
[[ "$ARGO_FIXED_DOMAIN" == "argo.aaa.bbb.com" ]]
[[ "$CDN_VMESS_CDN_DOMAIN" == "cdn.aaa.bbb.com" ]]
