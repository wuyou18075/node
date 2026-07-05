#!/usr/bin/env bash
set -euo pipefail

script="${1:-node.sh}"

source <(sed '/^# 启动入口执行/,$ d' "$script")

ARGO_CF_ZONE_NAME="cj7.kdns.fr"

[[ "$(recommend_argo_domain "gf7.cj7.kdns.fr")" == "argogf7.cj7.kdns.fr" ]] || {
  echo "Argo recommendation must stay one label below the Cloudflare zone" >&2
  exit 1
}

[[ "$(recommend_cdn_domain "gf7.cj7.kdns.fr")" == "cdngf7.cj7.kdns.fr" ]] || {
  echo "CDN recommendation must stay one label below the Cloudflare zone" >&2
  exit 1
}

ARGO_CF_ZONE_NAME="bbb.com"

[[ "$(recommend_argo_domain "aaa.bbb.com")" == "argoaaa.bbb.com" ]] || {
  echo "Argo recommendation must concatenate prefix and host label without a separator" >&2
  exit 1
}

ARGO_CF_ZONE_NAME="cj7.kdns.fr"

[[ "$(recommend_saved_or_cf_edge_domain "argo.gf7.cj7.kdns.fr" argo "gf7.cj7.kdns.fr")" == "argogf7.cj7.kdns.fr" ]] || {
  echo "saved legacy Argo subdomain must be replaced by a Cloudflare edge-safe recommendation" >&2
  exit 1
}

[[ "$(recommend_saved_or_cf_edge_domain "tunnel.cj7.kdns.fr" argo "gf7.cj7.kdns.fr")" == "tunnel.cj7.kdns.fr" ]] || {
  echo "custom saved Argo domains must be preserved" >&2
  exit 1
}

ARGO_CF_ZONE_NAME=""

[[ "$(recommend_argo_domain "aaa.bbb.com")" == "argo.aaa.bbb.com" ]] || {
  echo "Argo recommendation must preserve the legacy fallback without zone context" >&2
  exit 1
}

[[ "$(recommend_cdn_domain "aaa.bbb.com")" == "cdn.aaa.bbb.com" ]] || {
  echo "CDN recommendation must preserve the legacy fallback without zone context" >&2
  exit 1
}
