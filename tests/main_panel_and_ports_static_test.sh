#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

require_pattern() {
  local pattern="$1" message="$2"
  if ! grep -q "$pattern" "$script"; then
    echo "$message" >&2
    exit 1
  fi
}

require_absent_in_function() {
  local function_name="$1" pattern="$2" message="$3" body
  body="$(awk "/^${function_name}\\(\\)/,/^}/ { print }" "$script")"
  if grep -q "$pattern" <<<"$body"; then
    echo "$message" >&2
    exit 1
  fi
}

require_pattern '本次安装将包含以下 5 个需要端口的协议' \
  "one-click CDN flow must only ask for the five direct protocol ports"
require_pattern '1.Hysteria2 2.VMess 3.TUIC 4.AnyTLS 5.VLESS' \
  "one-click CDN flow must remove deprecated SS-2022 and separate CDN-VMess from the shared port prompt"
require_pattern '全协议cf灰云+橙云+argo+cdn' \
  "main panel option 4 must use the requested label"
if grep -q '一键全协议+CDN 橙云回源443版' "$script"; then
  echo "menus must not show the old orange-cloud option label" >&2
  exit 1
fi
require_pattern '  8) 节点订阅链接' \
  "main panel must expose subscription link management as option 8"
require_pattern '  97 装站点且 nginx 代理' \
  "main panel must move mask-site/nginx setup to option 97"
require_pattern '一键全协议+CDN 黄云版 (VLESS/HY2/VMess/TUIC/AnyTLS/Argo/CDN)' \
  "create-node submenu must not mention deprecated SS-2022"
require_pattern 'print_sing_box_panel_status' \
  "main panel must render sing-box status through a dedicated formatter"
require_pattern '配置文件: 无' \
  "main panel must display config as none when node.config is missing"
require_pattern '可升级' \
  "main panel must mark non-latest sing-box versions as upgradeable"
require_pattern '最新版' \
  "main panel must mark latest sing-box versions"

require_absent_in_function 'do_one_click_all_with_cdn' 'SS-2022' \
  "one-click CDN flow must not mention SS-2022 in its port prompt"
require_absent_in_function 'do_one_click_all_with_cdn' 'CDN-VMess=.*CDN_VMESS_PORT' \
  "one-click CDN flow must not allocate CDN-VMess in the shared direct port prompt"
