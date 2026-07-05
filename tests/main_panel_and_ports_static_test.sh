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
require_pattern '  2) 基础协议(无cf版)' \
  "main panel must expose the no-CF basic protocol flow as option 2"
require_pattern 'do_one_click_all_basic_without_cf' \
  "main panel option 2 must call the no-CF basic protocol flow"
if grep -q '基础协议(无cf,橙云+argo+cdn版)' "$script"; then
  echo "no-CF basic flow must not advertise Argo or CDN in its label" >&2
  exit 1
fi
if grep -Eq 'Argo 临时隧道配置 \(无 CF API\)|无 CF 模式不创建 Named Tunnel，自动使用 trycloudflare.com 临时隧道|无 CF 模式只生成节点和 nginx 回源配置' "$script"; then
  echo "no-CF basic flow must not prompt for Argo temporary tunnel or CDN" >&2
  exit 1
fi
require_pattern 'ARGO_ENABLED="0"' \
  "no-CF basic flow must explicitly disable Argo"
require_pattern 'CDN_VMESS_ENABLED="0"' \
  "no-CF basic flow must explicitly disable CDN-VMess"
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
require_absent_in_function 'configure_domain_certificate_without_cf' 'cf_upsert_site_dns\|cf_find_zone_for_host\|CF_API_TOKEN' \
  "no-CF domain certificate flow must not use Cloudflare API state"
