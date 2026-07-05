#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

if ! grep -q 'rm -f /etc/sysctl.d/99-agsb-proxy-tuning.conf' "$script"; then
  echo "uninstall_all must remove network tuning sysctl config" >&2
  exit 1
fi

if ! grep -q '99 卸载所有脚本产出内容' "$script"; then
  echo "menu item 99 must describe full uninstall of script outputs" >&2
  exit 1
fi

if ! grep -q '确认卸载? \[y/N\]' "$script"; then
  echo "menu item 99 uninstall confirmation must use y/N with default no" >&2
  exit 1
fi

if ! grep -Fq 'if [[ ! "$confirm" =~ ^[Yy]$ ]]; then' "$script"; then
  echo "menu item 99 must only uninstall when the user explicitly answers y/Y" >&2
  exit 1
fi

if ! grep -q '是否删除 node.config? \[y/N\]' "$script"; then
  echo "menu item 99 must ask whether to delete node.config with default no" >&2
  exit 1
fi

if ! grep -Fq 'if [[ "$confirm" =~ ^[Yy]$ ]]; then' "$script"; then
  echo "menu item 99 must only delete node.config when the user explicitly answers y/Y" >&2
  exit 1
fi

if ! grep -Fq 'rm -f "$NODE_CONFIG_FILE"' "$script"; then
  echo "menu item 99 must delete node.config instead of truncating it" >&2
  exit 1
fi

if ! grep -q '系统网络加速/优化配置' "$script"; then
  echo "uninstall warning must explicitly mention network tuning is removed" >&2
  exit 1
fi

if ! grep -q '/etc/letsencrypt/live/${SITE_DOMAIN}' "$script"; then
  echo "uninstall_all must remove Let's Encrypt live certs created for the mask site domain" >&2
  exit 1
fi

if ! grep -q '/etc/letsencrypt/archive/${SITE_DOMAIN}' "$script"; then
  echo "uninstall_all must remove Let's Encrypt archived certs created for the mask site domain" >&2
  exit 1
fi

if ! grep -q '/etc/letsencrypt/renewal/${SITE_DOMAIN}.conf' "$script"; then
  echo "uninstall_all must remove Let's Encrypt renewal config created for the mask site domain" >&2
  exit 1
fi
