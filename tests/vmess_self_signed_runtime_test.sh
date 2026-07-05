#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source <(sed '/^# 启动入口执行/,$ d' "$script")

SUBSCRIPTION_DIR="${tmp_dir}/subscription"
SUB_CLASH_YAML="${SUBSCRIPTION_DIR}/clash.yaml"
SUB_CLASH_STABLE_YAML="${SUBSCRIPTION_DIR}/clash-stable.yaml"

SELF_SIGN_CERT="1"
DOMAIN=""
SNI_VAL="www.apple.com"
REALITY_SNI="$SNI_VAL"
VMESS_TLS_ENABLED="1"
VMESS_TLS_SNI="$SNI_VAL"
VMESS_SERVER_ADDR="15.165.22.159"
VMESS_PORT="51596"
VMESS_UUID="b78b62de-4109-40c5-be79-4d016235b541"
VMESS_WS_PATH="/ws-a73447cea5312c37e"
VMESS_ENABLED="1"
VMESS_VIA_NGINX="0"
NODE_NAME_VMESS="kr7-VMess"

uri="$(vmess_uri)"
payload="$(printf '%s' "${uri#vmess://}" | base64 -d)"

[[ "$(jq -r '.add' <<<"$payload")" == "$VMESS_SERVER_ADDR" ]]
[[ "$(jq -r '.host' <<<"$payload")" == "$SNI_VAL" ]]
[[ "$(jq -r '.sni' <<<"$payload")" == "$SNI_VAL" ]]
[[ "$(jq -r '.tls' <<<"$payload")" == "tls" ]]
[[ "$(jq -r '.insecure' <<<"$payload")" == "1" ]]
[[ "$(jq -r '.allowInsecure' <<<"$payload")" == "1" ]]

build_subscription_clash_yaml
grep -q 'skip-cert-verify: true' "$SUB_CLASH_YAML"

build_subscription_clash_stable_yaml
grep -q 'skip-cert-verify: true' "$SUB_CLASH_STABLE_YAML"
