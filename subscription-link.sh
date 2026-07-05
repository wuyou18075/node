#!/usr/bin/env bash
set -euo pipefail

# subscription-link.sh - Manage nginx-protected subscription entry points.

STATE_DIR="${STATE_DIR:-/etc/sing-box/state}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/node-state.env}"
NODE_CONFIG_FILE="${NODE_CONFIG_FILE:-/etc/agsb/node.config}"
SUB_NGINX_AUTH_FILE="${SUB_NGINX_AUTH_FILE:-/etc/nginx/.agsb-subscription.htpasswd}"
MASK_SITE_SCRIPT_URL="${MASK_SITE_SCRIPT_URL:-https://raw.githubusercontent.com/wuyou18075/node/refs/heads/main/mask-site.sh}"

red() { printf '\e[31m%s\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
cyan() { printf '\e[36m%s\e[0m\n' "$*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请使用 root 权限运行。"
    return 1
  fi
}

install_packages() {
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}" >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y "${pkgs[@]}" >/dev/null 2>&1
  else
    red "未找到支持的包管理器，无法自动安装依赖: ${pkgs[*]}"
    return 1
  fi
}

ensure_packages_for_commands() {
  local item cmd pkg missing_pkgs=() missing_cmds=()
  for item in "$@"; do
    cmd="${item%%:*}"
    pkg="${item#*:}"
    [[ "$pkg" == "$item" ]] && pkg="$cmd"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
      missing_pkgs+=("$pkg")
    fi
  done
  [[ "${#missing_pkgs[@]}" -eq 0 ]] && return 0
  yellow "缺少依赖: ${missing_cmds[*]}，正在自动安装..."
  install_packages "${missing_pkgs[@]}" || return 1
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == "#"* ]] && continue
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    declare -g "${k}=${v}"
  done < "$STATE_FILE"
}

state_set_subscription_nginx() {
  local tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp)"
  if [[ -f "$STATE_FILE" ]]; then
    grep -Ev '^(SUB_NGINX_ENABLED|SUB_NGINX_PATH|SUB_NGINX_AUTH_FILE)=' "$STATE_FILE" > "$tmp" || true
  fi
  printf 'SUB_NGINX_ENABLED=%s\n' "$SUB_NGINX_ENABLED" >> "$tmp"
  printf 'SUB_NGINX_PATH=%s\n' "$SUB_NGINX_PATH" >> "$tmp"
  printf 'SUB_NGINX_AUTH_FILE=%s\n' "$SUB_NGINX_AUTH_FILE" >> "$tmp"
  install -m 0600 "$tmp" "$STATE_FILE" 2>/dev/null || mv -f "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

has_subscription_service() {
  [[ "${SUB_ENABLED:-}" != "0" && -n "${SUB_PORT:-}" && -n "${SUB_PATH:-}" ]]
}

detect_public_ipv4() {
  curl -4 -fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null \
    || curl -4 -fsS --connect-timeout 3 https://ip.sb 2>/dev/null
}

subscription_url() {
  local addr="" proto="https"
  if [[ "${SELF_SIGN_CERT:-0}" == "1" ]]; then
    proto="http"
    addr="$(detect_public_ipv4 2>/dev/null || true)"
  elif [[ -n "${DOMAIN:-}" ]]; then
    addr="$DOMAIN"
  elif [[ -n "${SITE_DOMAIN:-}" ]]; then
    addr="$SITE_DOMAIN"
  else
    addr="$(detect_public_ipv4 2>/dev/null || true)"
  fi
  [[ -n "$addr" && -n "${SUB_PORT:-}" && -n "${SUB_PATH:-}" ]] || return 1
  printf '%s://%s:%s/%s\n' "$proto" "$addr" "$SUB_PORT" "$SUB_PATH"
}

subscription_all_url() {
  local url
  url="$(subscription_url)" || return 1
  printf '%s/all\n' "$url"
}

normalize_subscription_nginx_path() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  raw="${raw#/}"
  raw="${raw%/}"
  [[ "$raw" =~ ^[A-Za-z0-9_-]{3,64}$ ]] || return 1
  case "$raw" in
    login|pricing|docs|status|api|admin|.well-known)
      return 1
      ;;
  esac
  printf '/%s\n' "$raw"
}

mask_site_script_fetch_url() {
  local sep="?"
  [[ "$MASK_SITE_SCRIPT_URL" == *\?* ]] && sep="&"
  printf '%s%s_t=%s\n' "$MASK_SITE_SCRIPT_URL" "$sep" "${RANDOM}${RANDOM}"
}

run_mask_site_script() {
  local action="$1" tmp_script url local_script script_dir rc
  script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || true)"
  local_script="${script_dir}/mask-site.sh"
  if [[ -n "$script_dir" && -f "$local_script" ]]; then
    STATE_DIR="$STATE_DIR" bash "$local_script" "$action"
    return $?
  fi
  ensure_packages_for_commands curl || return 1
  url="$(mask_site_script_fetch_url)"
  yellow "正在从远程加载站点脚本：${MASK_SITE_SCRIPT_URL}"
  tmp_script="$(mktemp /tmp/mask-site.XXXXXX.sh)" || return 1
  if ! curl -fsSL -H "Cache-Control: no-cache" "$url" -o "$tmp_script"; then
    rm -f "$tmp_script"
    red "远程站点脚本下载失败：${MASK_SITE_SCRIPT_URL}"
    return 1
  fi
  STATE_DIR="$STATE_DIR" bash "$tmp_script" "$action"
  rc=$?
  rm -f "$tmp_script"
  return "$rc"
}

configure_subscription_nginx_link() {
  local raw_path public_path sub_user sub_pass sub_hash public_url auth_file
  require_root || return 1
  load_state || {
    red "未检测到运行状态，请先创建节点。"
    return 1
  }
  if ! has_subscription_service; then
    red "未检测到可用订阅服务，请先创建节点并生成订阅。"
    return 1
  fi
  if [[ -z "${SITE_DOMAIN:-${DOMAIN:-}}" ]]; then
    red "未检测到站点域名，请先配置站点和 nginx。"
    return 1
  fi

  public_url="$(subscription_all_url)" || {
    red "无法生成原始订阅链接。"
    return 1
  }

  echo ""
  cyan "=== 节点订阅链接 nginx 代理 ==="
  echo "原始订阅链接: ${public_url}"
  echo "nginx 会为公开子路径启用 Basic Auth 和访问限速，降低暴力尝试风险。"
  read -r -p "请输入 nginx 访问子路径 (如 test，3-64位字母数字-_): " raw_path
  public_path="$(normalize_subscription_nginx_path "$raw_path")" || {
    red "路径无效，只允许 3-64 位字母、数字、-、_，且不能使用保留路径。"
    return 1
  }

  read -r -p "请输入访问用户名: " sub_user
  if [[ ! "$sub_user" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    red "用户名无效，只允许 1-64 位字母、数字、点、下划线和横线。"
    return 1
  fi
  read -r -s -p "请输入访问密码(至少8位): " sub_pass
  echo ""
  if (( ${#sub_pass} < 8 )); then
    red "密码至少需要 8 位。"
    return 1
  fi

  ensure_packages_for_commands openssl || return 1
  auth_file="${SUB_NGINX_AUTH_FILE:-/etc/nginx/.agsb-subscription.htpasswd}"
  mkdir -p "$(dirname "$auth_file")"
  sub_hash="$(printf '%s\n' "$sub_pass" | openssl passwd -apr1 -stdin)" || return 1
  printf '%s:%s\n' "$sub_user" "$sub_hash" > "$auth_file"
  chmod 0644 "$auth_file" 2>/dev/null || true

  SUB_NGINX_ENABLED="1"
  SUB_NGINX_PATH="$public_path"
  SUB_NGINX_AUTH_FILE="$auth_file"
  state_set_subscription_nginx
  run_mask_site_script refresh-nginx || { red "nginx 订阅代理刷新失败。"; return 1; }

  green "订阅代理已配置。"
  echo "访问地址: https://${SITE_DOMAIN:-$DOMAIN}${SUB_NGINX_PATH}"
  echo "登录后页面会显示原始订阅链接: ${public_url}"
}

case "${1:-configure}" in
  configure)
    configure_subscription_nginx_link
    ;;
  *)
    red "未知操作: ${1:-}"
    exit 1
    ;;
esac
