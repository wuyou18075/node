#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

line_in_function() {
  local pattern="$1"
  awk '/^do_one_click_all_with_cdn\(\)/,/^}/ { print NR ":" $0 }' "$script" \
    | grep -n "$pattern" | head -1 | cut -d: -f2
}

cdn_domain_line="$(line_in_function '请输入 CDN 加速域名')"
cdn_port_line="$(line_in_function 'configure_cdn_vmess_proxy_ports')"
argo_line="$(line_in_function 'cyan "--- Argo 隧道配置 ---"')"
node_prefix_line="$(line_in_function 'prompt_node_prefix_with_config')"
enable_line="$(line_in_function 'CDN_VMESS_ENABLED="1"')"

[[ -n "$cdn_domain_line" && -n "$cdn_port_line" && -n "$argo_line" && -n "$node_prefix_line" && -n "$enable_line" ]]

if (( cdn_domain_line >= cdn_port_line )); then
  echo "CDN domain prompt must appear before CDN port prompt" >&2
  exit 1
fi

if (( cdn_port_line >= argo_line )); then
  echo "CDN port prompt must appear before Argo prompt" >&2
  exit 1
fi

if (( argo_line >= node_prefix_line )); then
  echo "Argo prompt must appear before node prefix prompt in menu 4" >&2
  exit 1
fi

if ! awk '/^do_one_click_all_with_cdn\(\)/,/^}/ { print }' "$script" \
  | grep -q 'CDN_VMESS_ENABLED="1"'; then
  echo "CDN flow must explicitly enable CDN-VMess when CDN is requested" >&2
  exit 1
fi
