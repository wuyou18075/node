#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

source <(sed '/^# 启动入口执行/,$ d' "$script")

pick_free_port() { printf '57000\n'; }
port_in_use() { return 1; }

CDN_VMESS_PORT="56000"
configure_cdn_vmess_proxy_ports "" "" "" <<<"8443" >/dev/null
[[ "$CDN_VMESS_CLIENT_PORT" == "8443" ]]
[[ "$CDN_VMESS_PORT" == "57000" ]]
[[ "$CDN_VMESS_ORIGIN_PORT" == "443" ]]
[[ "$CDN_VMESS_CF_PROXY" == "1" ]]
[[ "$CDN_VMESS_VIA_NGINX" == "1" ]]
[[ "$(cdn_vmess_client_port)" == "8443" ]]
cdn_vmess_client_tls_enabled

unset CDN_VMESS_CLIENT_PORT CDN_VMESS_ORIGIN_PORT CDN_VMESS_VIA_NGINX
CDN_VMESS_PORT="56000"
configure_cdn_vmess_proxy_ports "" "" "" <<<"55001" >/dev/null
[[ "$CDN_VMESS_CLIENT_PORT" == "443" ]]
[[ "$CDN_VMESS_PORT" == "55001" ]]
[[ "$CDN_VMESS_ORIGIN_PORT" == "443" ]]
[[ "$CDN_VMESS_CF_PROXY" == "1" ]]
[[ "$CDN_VMESS_VIA_NGINX" == "1" ]]
[[ "$(cdn_vmess_client_port)" == "443" ]]

CDN_VMESS_CLIENT_PORT="8443"
CDN_VMESS_VIA_NGINX="0"
CDN_VMESS_CF_PROXY="1"
CDN_VMESS_PORT="8880"
[[ "$(cdn_vmess_client_port)" == "8880" ]]

unset CDN_VMESS_CLIENT_PORT CDN_VMESS_ORIGIN_PORT CDN_VMESS_VIA_NGINX CDN_VMESS_PORT
configure_cdn_vmess_proxy_ports "" "" "" <<<"" >/dev/null
[[ "$CDN_VMESS_CLIENT_PORT" == "443" ]]
[[ "$CDN_VMESS_PORT" == "57000" ]]
[[ "$CDN_VMESS_ORIGIN_PORT" == "443" ]]

unset CDN_VMESS_CLIENT_PORT CDN_VMESS_ORIGIN_PORT CDN_VMESS_VIA_NGINX CDN_VMESS_PORT
configure_cdn_vmess_proxy_ports "2053" "443" "55002" <<<"" >/dev/null
[[ "$CDN_VMESS_CLIENT_PORT" == "2053" ]]
[[ "$CDN_VMESS_PORT" == "55002" ]]
[[ "$CDN_VMESS_ORIGIN_PORT" == "443" ]]
