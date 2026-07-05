#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

grep -q '请输入订阅链接端口 (50000-60000):回车随机' "$script"
if grep -q '留空优先自动选择 CF 支持的 HTTPS 端口' "$script"; then
  echo "subscription port prompt must not prefer Cloudflare HTTPS ports" >&2
  exit 1
fi

source <(sed '/^# 启动入口执行/,$ d' "$script")

confirm_reuse_config_value() { return 1; }
pick_free_port() {
  [[ "$1" == "50000" && "$2" == "60000" ]]
  printf '57896\n'
}

SUB_CF_PROXY="1"
SELF_SIGN_CERT="0"
DOMAIN="site.example.com"
read_subscription_port <<< "" >/dev/null
[[ "$SUB_PORT" == "57896" ]]

read_subscription_port <<< "59000" >/dev/null
[[ "$SUB_PORT" == "59000" ]]
