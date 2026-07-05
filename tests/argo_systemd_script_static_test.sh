#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

if grep -q 'INSTALL_SCRIPT="$(realpath "$0")"' "$script"; then
  echo 'INSTALL_SCRIPT must not be derived from $0 because remote bash runners resolve it to bash itself' >&2
  exit 1
fi

if grep -q 'install_self_script() { :; }' "$script"; then
  echo "install_self_script must install node.sh to a stable path for systemd units" >&2
  exit 1
fi

if ! grep -q 'SELF_INSTALL_SCRIPT=' "$script"; then
  echo "script must define a stable self-install target" >&2
  exit 1
fi

if ! awk '/^install_self_script\(\)/,/^}/ { print }' "$script" | grep -q 'BASH_SOURCE'; then
  echo "install_self_script must copy from BASH_SOURCE when available" >&2
  exit 1
fi

if ! awk '/^write_argo_service\(\)/,/^}/ { print }' "$script" | grep -q 'install_self_script'; then
  echo "write_argo_service must ensure the stable script exists before writing systemd units" >&2
  exit 1
fi

if grep -q 'install_self_script || true' "$script"; then
  echo "systemd script installation failures must not be ignored" >&2
  exit 1
fi

if ! awk '/^print_argo_service_diagnostics\(\)/,/^}/ { print }' "$script" | grep -q 'journalctl -u "$ARGO_SERVICE"'; then
  echo "Argo service failures must print journal diagnostics" >&2
  exit 1
fi

if ! grep -q 'restart_argo_service_or_report 60' "$script"; then
  echo "Argo restarts must use the diagnostic restart wrapper" >&2
  exit 1
fi
