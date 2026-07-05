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
