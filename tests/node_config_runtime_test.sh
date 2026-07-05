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

rm -f "$NODE_CONFIG_FILE"
load_node_config >/dev/null 2>&1 || true

UUID="state-uuid"
CF_API_TOKEN="state-token"
DOMAIN="state.example.com"
clear_unconfigured_node_config_values
[[ -z "${UUID+x}" ]]
[[ -z "${CF_API_TOKEN+x}" ]]
[[ -z "${DOMAIN+x}" ]]

generate_uuid_v4() { printf '22222222-2222-4222-8222-222222222222\n'; }

UUID="99999999-9999-4999-8999-999999999999"
ARGO_UUID=""
VMESS_UUID=""
TUIC_UUID=""
uuid_output_file="${tmp_dir}/uuid-output.txt"
prompt_common_uuid <<< "" > "$uuid_output_file" 2>&1
uuid_output="$(<"$uuid_output_file")"
[[ "$uuid_output" != *"检测到之前节点使用的 UUID"* ]]
[[ "$uuid_output" != *"检测到 node.config 中的通用 UUID"* ]]
[[ "$UUID" == "22222222-2222-4222-8222-222222222222" ]]

CF_API_TOKEN="state_token_should_not_be_reused"
token_output_file="${tmp_dir}/token-output.txt"
prompt_cf_api_token <<< "new_token_1234567890" > "$token_output_file" 2>&1
token_output="$(<"$token_output_file")"
[[ "$token_output" != *"state_token_should_not_be_reused"* ]]
[[ "$token_output" != *"检测到 node.config 中的Cloudflare API Token"* ]]
[[ "$CF_API_TOKEN" == "new_token_1234567890" ]]

SUB_PORT="57896"
sub_port_output_file="${tmp_dir}/sub-port-output.txt"
prompt_subscription_port <<< "59000" > "$sub_port_output_file" 2>&1
sub_port_output="$(<"$sub_port_output_file")"
[[ "$sub_port_output" != *"检测到之前生成的订阅链接端口"* ]]
[[ "$sub_port_output" != *"检测到 node.config 中的订阅链接端口"* ]]
[[ "$SUB_PORT" == "59000" ]]

printf 'UUID=33333333-3333-4333-8333-333333333333\nCF_API_TOKEN=config_token_abcdef\nSUB_PORT=59100\n' > "$NODE_CONFIG_FILE"
unset UUID CF_API_TOKEN SUB_PORT
load_node_config

prompt_common_uuid <<< "" > "$uuid_output_file" 2>&1
uuid_config_output="$(<"$uuid_output_file")"
[[ "$uuid_config_output" == *"检测到 node.config 中的通用 UUID"* ]]
[[ "$UUID" == "33333333-3333-4333-8333-333333333333" ]]

prompt_cf_api_token <<< "" > "$token_output_file" 2>&1
token_config_output="$(<"$token_output_file")"
[[ "$token_config_output" == *"检测到 node.config 中的Cloudflare API Token"* ]]
[[ "$CF_API_TOKEN" == "config_token_abcdef" ]]

prompt_subscription_port <<< "" > "$sub_port_output_file" 2>&1
sub_port_config_output="$(<"$sub_port_output_file")"
[[ "$sub_port_config_output" == *"检测到 node.config 中的订阅链接端口"* ]]
[[ "$SUB_PORT" == "59100" ]]

NODE_CONFIG_LOADED_KEYS=""
unset DOMAIN SITE_DOMAIN SITE_ENABLED SNI_VAL REALITY_SNI SELF_SIGN_CERT USE_CF_ORIGIN_CA_CERT generated_cert_domain
generate_self_signed_domain_cert() {
  generated_cert_domain="$1"
}
configure_domain_certificate_without_cf <<< "" >/dev/null
[[ -z "${DOMAIN:-}" ]]
[[ -z "${SITE_DOMAIN:-}" ]]
[[ "${SITE_ENABLED:-}" == "0" ]]
[[ "$SNI_VAL" == "www.apple.com" ]]
[[ "$REALITY_SNI" == "www.apple.com" ]]
[[ "$SELF_SIGN_CERT" == "1" ]]
[[ "$USE_CF_ORIGIN_CA_CERT" == "0" ]]
[[ "$generated_cert_domain" == "www.apple.com" ]]
