#!/usr/bin/env bash
# =============================================================================
# cf-tunnel.sh - Cloudflare Tunnel Manager
# 功能: 新建隧道 / 查看所有隧道(连通性) / 删除隧道
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置
# =============================================================================
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
STATE_DIR="/etc/sing-box/state"
CF_API_BASE="https://api.cloudflare.com/client/v4"

# =============================================================================
# 颜色输出
# =============================================================================
red()     { printf '\e[31m%s\e[0m\n' "$*"; }
green()   { printf '\e[32m%s\e[0m\n' "$*"; }
yellow()  { printf '\e[33m%s\e[0m\n' "$*"; }
cyan()    { printf '\e[36m%s\e[0m\n' "$*"; }
bold()    { printf '\e[1m%s\e[0m\n' "$*"; }

# =============================================================================
# 工具函数
# =============================================================================

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请使用 root 权限运行: sudo bash $0"
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    yellow "安装依赖: ${missing[*]}"
    if command -v apt >/dev/null 2>&1; then
      apt update -qq && apt install -y -qq "${missing[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q "${missing[@]}" >/dev/null 2>&1
    else
      red "请手动安装: ${missing[*]}"
      exit 1
    fi
  fi
}

pick_free_port() {
  local start="${1:-50000}" end="${2:-60000}" port
  for _ in $(seq 1 50); do
    port="$(shuf -i "${start}-${end}" -n 1)"
    if ! ss -H -ltnu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[:.])${port}$" 2>/dev/null; then
      echo "$port"
      return 0
    fi
  done
  echo "$(( RANDOM % 10000 + 50000 ))"
}

install_cloudflared() {
  if [[ -x "$CLOUDFLARED_BIN" ]]; then
    green "cloudflared 已安装: $("$CLOUDFLARED_BIN" version 2>/dev/null | head -1)"
    return 0
  fi
  yellow "正在安装 cloudflared..."
  local arch asset url tmp_dir
  [[ "$(uname -m)" == "aarch64" ]] && asset="cloudflared-linux-arm64" || asset="cloudflared-linux-amd64"
  tmp_dir="$(mktemp -d)"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
  curl -fsSL "$url" -o "${tmp_dir}/cloudflared" || { red "下载失败"; rm -rf "$tmp_dir"; return 1; }
  install -m 0755 "${tmp_dir}/cloudflared" "$CLOUDFLARED_BIN"
  rm -rf "$tmp_dir"
  green "cloudflared 安装完成: $("$CLOUDFLARED_BIN" version 2>/dev/null | head -1)"
}

# =============================================================================
# Cloudflare API 请求
# =============================================================================
cf_api_request() {
  local method="$1" path="$2" data="${3:-}" response body http_code
  [[ -n "${CF_API_TOKEN:-}" ]] || { red "CF_API_TOKEN 为空"; return 1; }
  if [[ -n "$data" ]]; then
    response="$(curl -sS -w '\n%{http_code}' -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data")" || { red "API 网络请求失败"; return 1; }
  else
    response="$(curl -sS -w '\n%{http_code}' -X "$method" "${CF_API_BASE}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json")" || { red "API 网络请求失败"; return 1; }
  fi
  http_code="$(printf '%s' "$response" | tail -n 1)"
  body="$(printf '%s' "$response" | sed '$d')"
  if [[ "$http_code" =~ ^2 ]] && printf '%s' "$body" | jq -e '.success == true' >/dev/null 2>&1; then
    printf '%s\n' "$body"
    return 0
  fi
  local errors
  errors="$(printf '%s' "$body" | jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' 2>/dev/null)"
  red "API 请求失败: HTTP ${http_code} ${errors:-unknown}"
  return 1
}

cf_verify_token() {
  local response
  response="$(curl -sS -X GET "${CF_API_BASE}/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")" || return 1
  if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    local err
    err="$(printf '%s' "$response" | jq -r '.errors[0].message // "Token 无效"')"
    red "Token 验证失败: ${err}"
    return 1
  fi
  local account_id account_name
  account_id="$(printf '%s' "$response" | jq -r '.result.accounts[0].id // empty')"
  account_name="$(printf '%s' "$response" | jq -r '.result.accounts[0].name // empty')"
  if [[ -z "$account_id" ]]; then
    response="$(cf_api_request GET "/accounts?per_page=1")" || return 1
    account_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
    account_name="$(printf '%s' "$response" | jq -r '.result[0].name // empty')"
  fi
  [[ -n "$account_id" ]] || { red "无法获取 Account ID"; return 1; }
  ARGO_CF_ACCOUNT_ID="$account_id"
  green "Account: ${account_name} (${account_id})"
  return 0
}

cf_find_zone() {
  local host="$1" candidate response zone_id
  candidate="$host"
  while [[ "$candidate" == *.* ]]; do
    response="$(cf_api_request GET "/zones?name=${candidate}&status=active&per_page=1")" || return 1
    zone_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
    if [[ -n "$zone_id" ]]; then
      ARGO_CF_ZONE_ID="$zone_id"
      ARGO_CF_ZONE_NAME="$(printf '%s' "$response" | jq -r '.result[0].name // empty')"
      green "Zone: ${ARGO_CF_ZONE_NAME} (${ARGO_CF_ZONE_ID})"
      return 0
    fi
    candidate="${candidate#*.}"
  done
  red "未找到域名所属 Zone: ${host}"
  return 1
}

# =============================================================================
# 1. 新建隧道
# =============================================================================
cmd_create() {
  echo ""
  bold "=== 新建 Cloudflare Tunnel ==="
  echo ""
  read -r -p "输入 Cloudflare API Token（留空使用随机临时隧道）: " api_token
  api_token="$(printf '%s' "$api_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -z "$api_token" ]]; then
    cmd_create_quick
  else
    cmd_create_named "$api_token"
  fi
}

# --- 随机隧道 (Quick Tunnel, trycloudflare) ---
cmd_create_quick() {
  install_cloudflared || return 1

  local local_port
  read -r -p "输入本地服务端口（留空自动分配 50000-60000）: " local_port
  if [[ -z "$local_port" ]]; then
    local_port="$(pick_free_port)"
  fi
  echo ""
  yellow "正在启动临时隧道，指向 http://127.0.0.1:${local_port} ..."
  echo ""

  local logfile tmpfile pid domain i
  logfile="$(mktemp)"

  "$CLOUDFLARED_BIN" tunnel --no-autoupdate --protocol http2 \
    --url "http://127.0.0.1:${local_port}" \
    --loglevel info >"$logfile" 2>&1 &
  pid=$!

  echo -n "等待隧道域名"
  domain=""
  for i in $(seq 1 30); do
    sleep 1
    echo -n "."
    domain="$(grep -Eo 'https?://[A-Za-z0-9-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | tail -1)"
    [[ -n "$domain" ]] && break
  done
  echo ""

  if [[ -n "$domain" ]]; then
    green ""
    green "============================================"
    green "  临时隧道已启动！"
    green "  隧道域名: ${domain#https://}"
    green "  本地端口: ${local_port}"
    green "  PID: ${pid}"
    green "============================================"
    green ""
    echo "  日志文件: ${logfile}"
    echo "  停止隧道: kill ${pid}"
  else
    yellow "隧道启动中，但未在 30s 内捕获到域名。"
    yellow "  查看日志: tail -f ${logfile}"
    yellow "  PID: ${pid}"
  fi
  echo ""
}

# --- 固定隧道 (Named Tunnel) ---
cmd_create_named() {
  local api_token="$1"
  CF_API_TOKEN="$api_token"

  cf_verify_token || return 1

  local fixed_domain tunnel_name
  read -r -p "输入隧道域名 (如 tunnel.example.com): " fixed_domain
  fixed_domain="$(printf '%s' "$fixed_domain" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
  [[ -n "$fixed_domain" ]] || { red "域名不能为空"; return 1; }

  local input_port
  read -r -p "输入本地服务端口（留空自动分配 50000-60000）: " input_port
  if [[ -z "$input_port" ]]; then
    input_port="$(pick_free_port)"
  elif [[ ! "$input_port" =~ ^[0-9]+$ || "$input_port" -lt 1 || "$input_port" -gt 65535 ]]; then
    red "端口无效"; return 1
  fi
  echo ""

  yellow "配置 Named Tunnel ..."

  cf_find_zone "$fixed_domain" || return 1
  tunnel_name="$(printf '%s' "$fixed_domain" | tr -c 'A-Za-z0-9._-' '-')"

  # 查询或创建隧道
  yellow "创建/复用隧道: ${tunnel_name}"
  local response tunnel_id data token
  response="$(cf_api_request GET "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel?name=${tunnel_name}&is_deleted=false&per_page=1")" || return 1
  tunnel_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"

  if [[ -z "$tunnel_id" ]]; then
    data="$(jq -nc --arg name "$tunnel_name" '{name:$name, config_src:"cloudflare"}')"
    response="$(cf_api_request POST "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel" "$data")" || return 1
    tunnel_id="$(printf '%s' "$response" | jq -r '.result.id // empty')"
    green "  ✅ 新隧道已创建"
  else
    green "  ✅ 复用已有隧道"
  fi
  [[ -n "$tunnel_id" ]] || { red "隧道 ID 获取失败"; return 1; }
  echo "  Tunnel ID: ${tunnel_id}"
  echo "  Tunnel Name: ${tunnel_name}"

  # 获取 Token
  response="$(cf_api_request GET "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token")" || return 1
  token="$(printf '%s' "$response" | jq -r 'if (.result | type) == "object" then (.result.token // empty) elif (.result | type) == "string" then .result else empty end')"
  [[ -n "$token" && "$token" != "null" ]] || { red "Token 获取失败"; return 1; }

  # 配置 Public Hostname
  yellow "配置 Public Hostname ..."
  local cfg_data
  cfg_data="$(jq -nc \
    --arg hostname "$fixed_domain" \
    --arg service "http://localhost:${input_port}" \
    '{config:{ingress:[{hostname:$hostname,service:$service},{service:"http_status:404"}],"warp-routing":{enabled:false}}}')"
  cf_api_request PUT "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" "$cfg_data" >/dev/null || {
    red "Public Hostname 配置失败"; return 1
  }
  green "  ✅ Public Hostname 已配置"

  # 配置 DNS CNAME
  yellow "配置 DNS CNAME ..."
  local dns_response record_id content subdomain
  content="${tunnel_id}.cfargotunnel.com"
  dns_response="$(cf_api_request GET "/zones/${ARGO_CF_ZONE_ID}/dns_records?name=${fixed_domain}&per_page=100")" || return 1

  # 删除冲突记录
  local conflict_ids cid
  conflict_ids="$(printf '%s' "$dns_response" | jq -r '.result[]? | select(.type != "CNAME") | .id' 2>/dev/null)"
  for cid in $conflict_ids; do
    cf_api_request DELETE "/zones/${ARGO_CF_ZONE_ID}/dns_records/${cid}" >/dev/null 2>&1 || true
  done

  # 查找或创建 CNAME
  record_id="$(printf '%s' "$dns_response" | jq -r '.result[]? | select(.type == "CNAME") | .id // empty' 2>/dev/null | head -1)"
  subdomain="$(printf '%s' "$fixed_domain" | sed 's/\.[^.]*\.[^.]*$//')"
  if [[ -n "$record_id" ]]; then
    cf_api_request PATCH "/zones/${ARGO_CF_ZONE_ID}/dns_records/${record_id}" \
      "$(jq -nc --arg target "$content" '{type:"CNAME",name:"'"$subdomain"'",content:$target,ttl:1,proxied:false}')" >/dev/null
  else
    cf_api_request POST "/zones/${ARGO_CF_ZONE_ID}/dns_records" \
      "$(jq -nc --arg target "$content" '{type:"CNAME",name:"'"$subdomain"'",content:$target,ttl:1,proxied:false}')" >/dev/null
  fi
  green "  ✅ DNS CNAME 已配置"

  echo ""
  green "============================================"
  green "  Named Tunnel 配置完成！"
  green "  域名: ${fixed_domain}"
  green "  Tunnel ID: ${tunnel_id}"
  green "  本地端口: ${input_port}"
  green "  Zone: ${ARGO_CF_ZONE_NAME}"
  green "============================================"
  echo ""
  green "在目标服务器上运行:"
  echo "  ${CLOUDFLARED_BIN} tunnel --no-autoupdate run --token ${token}"
  echo ""
}

# =============================================================================
# 2. 查看所有隧道 (连通性检测)
# =============================================================================
cmd_list() {
  echo ""
  bold "=== 查看所有 Tunnel ==="
  echo ""

  local api_token
  read -r -s -p "输入 Cloudflare API Token: " api_token
  echo ""
  api_token="$(printf '%s' "$api_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$api_token" ]] || { red "Token 不能为空"; return 1; }

  CF_API_TOKEN="$api_token"
  cf_verify_token || return 1

  local response
  response="$(cf_api_request GET "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=100")" || return 1

  local tunnel_count
  tunnel_count="$(printf '%s' "$response" | jq -r '.result | length')"
  if [[ "$tunnel_count" -eq 0 ]]; then
    yellow "当前账号下没有隧道。"
    return 0
  fi

  echo ""
  printf "%-4s %-30s %-12s %-24s %s\n" "序号" "隧道名称" "状态" "创建时间" "连接"
  printf -- "---- ------------------------------ ------------ ------------------------ --------------------\n"

  local i name id status created_at connections conn_count conn_info
  for i in $(seq 0 $(( tunnel_count - 1 ))); do
    name="$(printf '%s' "$response" | jq -r ".result[${i}].name // empty")"
    id="$(printf '%s' "$response" | jq -r ".result[${i}].id // empty")"
    status="$(printf '%s' "$response" | jq -r ".result[${i}].status // empty")"
    created_at="$(printf '%s' "$response" | jq -r ".result[${i}].created_at // empty" | sed 's/T/ /; s/\..*//')"
    connections="$(printf '%s' "$response" | jq -c ".result[${i}].connections // []" 2>/dev/null)"
    conn_count="$(printf '%s' "$connections" | jq 'length' 2>/dev/null || echo 0)"

    if [[ "$conn_count" -gt 0 ]]; then
      conn_info="$(green "✅ 在线 ${conn_count}")"
    elif [[ "$status" == "healthy" ]]; then
      conn_info="$(green "✅ 健康")"
    elif [[ "$status" == "degraded" ]]; then
      conn_info="$(yellow "⚠️ 降级")"
    elif [[ "$status" == "down" ]]; then
      conn_info="$(red "❌ 离线")"
    else
      conn_info="$(yellow "❓ ${status}")"
    fi

    local status_display
    case "$status" in
      healthy)  status_display="$(green "healthy")" ;;
      degraded) status_display="$(yellow "degraded")" ;;
      down)     status_display="$(red "down")" ;;
      inactive) status_display="$(yellow "inactive")" ;;
      *)        status_display="$status" ;;
    esac

    printf "%-4s %-30s %-12s %-24s %s\n" "$(( i + 1 ))" "${name:0:28}" "$status_display" "${created_at}" "$conn_info"
  done
  echo ""
  green "总计 ${tunnel_count} 个隧道"
  echo ""
}

# =============================================================================
# 3. 删除隧道（带序号选择）
# =============================================================================
cmd_delete() {
  echo ""
  bold "=== 删除 Tunnel ==="
  echo ""

  local api_token
  read -r -s -p "输入 Cloudflare API Token: " api_token
  echo ""
  api_token="$(printf '%s' "$api_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$api_token" ]] || { red "Token 不能为空"; return 1; }

  CF_API_TOKEN="$api_token"
  cf_verify_token || return 1

  local response
  response="$(cf_api_request GET "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=100")" || return 1

  local tunnel_count
  tunnel_count="$(printf '%s' "$response" | jq -r '.result | length')"
  if [[ "$tunnel_count" -eq 0 ]]; then
    yellow "当前账号下没有隧道。"
    return 0
  fi

  echo ""
  printf "%-4s %-30s %-12s %-24s %s\n" "序号" "隧道名称" "状态" "创建时间" "Tunnel ID"
  printf -- "---- ------------------------------ ------------ ------------------------ --------------------------------\n"

  local i name id status created_at
  for i in $(seq 0 $(( tunnel_count - 1 ))); do
    name="$(printf '%s' "$response" | jq -r ".result[${i}].name // empty")"
    id="$(printf '%s' "$response" | jq -r ".result[${i}].id // empty")"
    status="$(printf '%s' "$response" | jq -r ".result[${i}].status // empty")"
    created_at="$(printf '%s' "$response" | jq -r ".result[${i}].created_at // empty" | sed 's/T/ /; s/\..*//')"

    local status_display
    case "$status" in
      healthy)  status_display="$(green "healthy")" ;;
      degraded) status_display="$(yellow "degraded")" ;;
      down)     status_display="$(red "down")" ;;
      inactive) status_display="$(yellow "inactive")" ;;
      *)        status_display="$status" ;;
    esac
    printf "%-4s %-30s %-12s %-24s %s\n" "$(( i + 1 ))" "${name:0:28}" "$status_display" "${created_at}" "$id"
  done
  echo ""

  read -r -p "输入要删除的序号（多个用逗号分隔，如 1,2,3）: " raw_input
  [[ -n "$raw_input" ]] || { yellow "已取消"; return 0; }

  echo ""
  yellow "即将删除以下隧道:"
  local selected_ids=() selected_names=() idx
  IFS=',' read -ra selected <<< "$raw_input"
  for sel in "${selected[@]}"; do
    sel="$(printf '%s' "$sel" | tr -d ' ')"
    [[ -n "$sel" ]] || continue
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= tunnel_count )); then
      idx=$(( sel - 1 ))
      name="$(printf '%s' "$response" | jq -r ".result[${idx}].name // empty")"
      id="$(printf '%s' "$response" | jq -r ".result[${idx}].id // empty")"
      selected_ids+=("$id")
      selected_names+=("$name")
      echo "  - ${name} (${id})"
    else
      yellow "  跳过无效序号: ${sel}"
    fi
  done

  if [[ ${#selected_ids[@]} -eq 0 ]]; then
    yellow "没有有效选择，已取消。"
    return 0
  fi

  echo ""
  local confirm
  read -r -p "确认删除以上 ${#selected_ids[@]} 个隧道? [y/N]: " confirm
  case "$confirm" in
    y|Y) ;;
    *) yellow "已取消"; return 0 ;;
  esac

  local del_count=0 fail_count=0 tid tname
  for idx in "${!selected_ids[@]}"; do
    tid="${selected_ids[$idx]}"
    tname="${selected_names[$idx]}"
    echo -n "  删除 ${tname} ... "
    if cf_api_request DELETE "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel/${tid}" >/dev/null 2>&1; then
      green "✅ 已删除"
      del_count=$(( del_count + 1 ))
    else
      red "❌ 失败"
      fail_count=$(( fail_count + 1 ))
    fi
  done

  echo ""
  green "操作完成: ${del_count} 个隧道已删除"
  [[ "$fail_count" -gt 0 ]] && red "${fail_count} 个隧道删除失败"
  echo ""
}

# =============================================================================
# 主菜单
# =============================================================================
main_menu() {
  while true; do
    clear
    echo ""
    bold "╔══════════════════════════════════════════════╗"
    bold "║        Cloudflare Tunnel 管理工具           ║"
    bold "╚══════════════════════════════════════════════╝"
    echo ""
    echo "  1) 新建隧道"
    echo "     - 输入 Token → 创建 Named Tunnel"
    echo "     - 留空 Token → 快速随机隧道 (trycloudflare)"
    echo ""
    echo "  2) 查看所有隧道 (带连通性检测)"
    echo ""
    echo "  3) 删除隧道"
    echo ""
    echo "  0) 退出"
    echo ""
    read -r -p "请选择: " choice
    echo ""

    case "$choice" in
      1) cmd_create ;;
      2) cmd_list   ;;
      3) cmd_delete ;;
      0) green "再见"; exit 0 ;;
      *) red "无效选项" ;;
    esac
    echo ""
    read -r -p "按回车键返回主菜单..."
  done
}

# =============================================================================
# 入口
# =============================================================================
require_root
check_deps

case "${1:-}" in
  create|new|1)  cmd_create ;;
  list|ls|2)     cmd_list ;;
  delete|del|rm|3) cmd_delete ;;
  *)             main_menu ;;
esac
