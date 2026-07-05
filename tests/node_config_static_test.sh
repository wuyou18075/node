#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

if ! grep -q 'NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-${CONFIG_DIR}/node.config}"' "$script"; then
  echo "node.config path must be /etc/agsb/node.config by default" >&2
  exit 1
fi

if ! grep -q '配置文件: ${NODE_CONFIG_FILE}' "$script"; then
  echo "main panel must display node.config path" >&2
  exit 1
fi

if ! grep -q '配置文件管理' "$script"; then
  echo "main menu must provide config management entry" >&2
  exit 1
fi

if ! grep -q '清空 node.config' "$script"; then
  echo "config management must provide a clear node.config option" >&2
  exit 1
fi

if ! grep -q '删除 node.config' "$script"; then
  echo "config management must provide a delete node.config option" >&2
  exit 1
fi

if awk '/^uninstall_all\(\)/,/^do_one_click_all_with_cdn\(\)/ { print }' "$script" | grep -q 'NODE_CONFIG_FILE\|CONFIG_DIR'; then
  echo "uninstall_all must not delete node.config" >&2
  exit 1
fi

if ! grep -q 'recommend_argo_domain' "$script"; then
  echo "one-click CDN flow must recommend argo.<main-domain>" >&2
  exit 1
fi

if ! grep -q 'recommend_cdn_domain' "$script"; then
  echo "one-click CDN flow must recommend cdn.<main-domain>" >&2
  exit 1
fi

if ! grep -q 'save_node_config' "$script"; then
  echo "one-click flow must save reusable inputs to node.config" >&2
  exit 1
fi
