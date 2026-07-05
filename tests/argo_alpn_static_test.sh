#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

source <(sed '/^# 启动入口执行/,$ d' "$script")

ARGO_DOMAIN="argogh7.cj7.kdns.fr"
ARGO_UUID="11111111-1111-4111-8111-111111111111"
ARGO_WS_PATH="/argo-test"
ARGO_CLIENT_FINGERPRINT="chrome"
NODE_NAME_ARGO="test-Argo"
ARGO_MULTI_EDGE="0"
ARGO_EDGE_SERVER=""

uri="$(argo_uri)"

if [[ "$uri" != *"alpn=http%2F1.1"* ]]; then
  echo "Argo VLESS URI must force ALPN http/1.1 for Cloudflare WebSocket compatibility" >&2
  exit 1
fi

if (( "$(grep -c '      - http/1.1' "$script")" < 2 )); then
  echo "Clash and mihomo Argo proxies must include alpn http/1.1" >&2
  exit 1
fi

if ! awk '/^validate_argo_ws_reachable\(\)/,/^}/ { print }' "$script" | grep -q -- '--http1.1'; then
  echo "Argo reachability validation must force HTTP/1.1 WebSocket checks" >&2
  exit 1
fi

if ! awk '/^validate_argo_ws_reachable\(\)/,/^}/ { print }' "$script" | grep -q '101'; then
  echo "Argo reachability validation must require a 101 WebSocket upgrade" >&2
  exit 1
fi

if ! awk '/^do_one_click_all_with_cdn\(\)/,/^}/ { print }' "$script" | grep -q 'wait_argo_ws_reachable'; then
  echo "Menu 4 must validate Argo WebSocket reachability before emitting nodes" >&2
  exit 1
fi

if grep -q 'ExecStartPre=-/bin/bash .*--wait-tcp 127[.]0[.]0[.]1' "$script"; then
  echo "Argo systemd unit must not ignore local origin wait failures" >&2
  exit 1
fi
