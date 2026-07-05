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

require_function_pattern() {
  local function_name="$1" pattern="$2" message="$3"
  if ! awk "/^${function_name}\\(\\)/,/^}/ { print }" "$script" | grep -q "$pattern"; then
    echo "$message" >&2
    exit 1
  fi
}

require_pattern '^install_packages()' "script must provide reusable package installation helper"
require_pattern '^ensure_packages_for_commands()' "script must provide command dependency helper"

require_function_pattern 'cf_configure_cdn_vmess' 'ensure_packages_for_commands curl jq' \
  "Cloudflare CDN VMess flow must auto-install curl and jq"
require_function_pattern 'cf_configure_named_tunnel' 'ensure_packages_for_commands curl jq' \
  "Cloudflare named tunnel flow must auto-install curl and jq"
require_function_pattern 'write_sing_box_config' 'ensure_packages_for_commands jq' \
  "sing-box config generation must auto-install jq"
require_function_pattern 'install_cloudflared_binary' 'ensure_packages_for_commands curl jq' \
  "cloudflared installer must auto-install curl and jq"

if grep -q '缺少 jq，无法调用 Cloudflare API' "$script"; then
  echo "Cloudflare API helpers must not stop at missing jq without attempting install" >&2
  exit 1
fi
