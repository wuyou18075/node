#!/usr/bin/env bash
# =============================================================================
# node.sh - Node generation: protocols, configuration, subscription, share files
# Standalone capable: includes state management for independent use
# =============================================================================

# =============================================================================
# 核心依赖垫片 (Polyfill) 开始 - 解决脱离主控框架导致的 command not found 问题
# =============================================================================

# 基础环境变量
APP_NAME="AGSB-Standalone"
APP_VERSION="1.0.6"
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_VERSION=""  # 由 detect_sing_box_version() 自动检测填充
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
SING_BOX_SERVICE="sing-box.service"
ARGO_SERVICE="cloudflared.service"
ARGO_REFRESH_SERVICE="argo-refresh.service"
ARGO_REFRESH_TIMER="argo-refresh.timer"
ARGO_REFRESH_PATH="argo-refresh.path"
DEFAULT_ARGO_EDGE_SERVER="${DEFAULT_ARGO_EDGE_SERVER:-}"
LEGACY_ARGO_EDGE_SERVER="dajiba.cf.090227.xyz"
SUB_SERVICE="smart-sub.service"
SING_BOX_DIR="/etc/sing-box"
SING_BOX_CFG="${SING_BOX_DIR}/config.json"
SSL_DIR="/etc/sing-box/cert"
STATE_DIR="/etc/sing-box/state"
SITE_ROOT="/var/www/edupanel"
NGINX_SITE_CONF="/etc/nginx/conf.d/agsb-edupanel.conf"
ARGO_BOOT_LOG="/var/log/cloudflared.log"
SUBSCRIPTION_DIR="/var/www/subscription"
INSTALL_SCRIPT="$(realpath "$0")"
MASK_SITE_SCRIPT_URL="${MASK_SITE_SCRIPT_URL:-https://raw.githubusercontent.com/wuyou18075/node/refs/heads/main/mask-site.sh}"

# 颜色输出
red() { printf '\e[31m%s\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
cyan() { printf '\e[36m%s\e[0m\n' "$*"; }

# 核心二进制与环境准备
sing_box_cmd() {
  [[ -x "$SING_BOX_BIN" ]] && echo "$SING_BOX_BIN"
}

detect_sing_box_version() {
  if [[ -z "$SING_BOX_VERSION" ]]; then
    local latest
    latest="$(curl -sI "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -i "^location:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -n "$latest" ]]; then
      SING_BOX_VERSION="$latest"
    else
      SING_BOX_VERSION="1.13.14"
    fi
  fi
}

install_sing_box() {
  detect_sing_box_version
  local arch="amd64"
  [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
  local target_version="$SING_BOX_VERSION"
  local need_install=0
  
  if [[ -x "$SING_BOX_BIN" ]]; then
    # 检查已安装版本是否支持 anytls（需要 >= 1.11.0）
    local current_ver
    current_ver="$("$SING_BOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$current_ver" ]]; then
      yellow "无法解析当前 sing-box 版本，将重新安装 ${target_version}..."
      need_install=1
    else
      local major minor
      IFS='.' read -r major minor _ <<< "$current_ver"
      if [[ "${major:-0}" -lt 1 || ( "${major:-0}" -eq 1 && "${minor:-0}" -lt 11 ) ]]; then
        yellow "当前 sing-box ${current_ver} < 1.11，不支持 AnyTLS，正在升级到 ${target_version}..."
        need_install=1
      fi
    fi
    # 即使版本号>=1.11，额外兜底：实测 anytls inbound 是否有效
    if [[ "$need_install" == "0" ]]; then
      local anytls_testf anytls_rc
      local anytls_testf="$(mktemp)"
      printf '%s' '{"inbounds":[{"type":"anytls","tag":"test","listen":"127.0.0.1","listen_port":1,"users":[{"name":"t","password":"x"}],"tls":{"enabled":false,"certificate_path":"","key_path":""}}]}' > "$anytls_testf"
      "$SING_BOX_BIN" check -c "$anytls_testf" >/dev/null 2>&1
      anytls_rc=$?
      rm -f "$anytls_testf"
      if [[ "$anytls_rc" -ne 0 ]]; then
        yellow "当前 sing-box 不支持 anytls inbound，将重装..."
        need_install=1
      fi
    fi
  else
    yellow "未检测到 sing-box 核心，将安装 ${target_version}..."
    need_install=1
  fi

  if [[ "$need_install" == "1" ]]; then
    local tmp_dir tmp_file
    tmp_dir="$(mktemp -d)"
    tmp_file="${tmp_dir}/sing-box.tar.gz"
    yellow "正在下载 sing-box 核心 ${target_version} (${arch})..."
    wget -q --show-progress -O "$tmp_file" \
      "https://github.com/SagerNet/sing-box/releases/download/v${target_version}/sing-box-${target_version}-linux-${arch}.tar.gz" 2>&1 || {
      red "下载失败！请检查网络连接或版本号。"
      rm -rf "$tmp_dir"
      return 1
    }
    tar -xzf "$tmp_file" -C "$tmp_dir"
    # 找解压出的 sing-box 二进制
    local extracted
    extracted="$(find "$tmp_dir" -name 'sing-box' -type f | head -1)"
    if [[ -z "$extracted" || ! -x "$extracted" ]]; then
      red "解压后未找到 sing-box 二进制文件！"
      rm -rf "$tmp_dir"
      return 1
    fi
    rm -f "$SING_BOX_BIN"
    cp "$extracted" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "$tmp_dir"
    # 验证安装
    local new_ver
    new_ver="$("$SING_BOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$new_ver" ]]; then
      red "安装后无法验证 sing-box 版本，请手动检查。"
      return 1
    fi
    green "sing-box 核心 ${new_ver} 安装完成"
  fi
  return 0
}

github_api_json() { curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest"; }
detect_cloudflared_asset() {
  [[ "$(uname -m)" == "aarch64" ]] && echo "cloudflared-linux-arm64" || echo "cloudflared-linux-amd64"
}
curl_fsSL() { curl -fsSL "$@"; }

install_required_command() {
  local cmd="$1" pkg="${2:-$1}" manager=""

  command -v "$cmd" >/dev/null 2>&1 && return 0

  yellow "missing ${cmd}, trying to install ${pkg}..."
  if command -v apt-get >/dev/null 2>&1; then
    manager="apt"
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    manager="dnf"
    dnf install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    manager="yum"
    yum install -y "$pkg"
  elif command -v apk >/dev/null 2>&1; then
    manager="apk"
    apk add --no-cache "$pkg"
  elif command -v pacman >/dev/null 2>&1; then
    manager="pacman"
    pacman -Sy --noconfirm "$pkg"
  elif command -v zypper >/dev/null 2>&1; then
    manager="zypper"
    zypper --non-interactive install "$pkg"
  else
    red "missing ${cmd}; no supported package manager found. Please install ${pkg} manually."
    return 1
  fi

  if command -v "$cmd" >/dev/null 2>&1; then
    green "${cmd} installed by ${manager}."
    return 0
  fi

  red "failed to install ${cmd}. Please install ${pkg} manually and retry."
  return 1
}

# 网络与编码辅助函数
preferred_direct_server_addr() { curl -s4 icanhazip.com || echo "127.0.0.1"; }
detect_public_ipv4() { preferred_direct_server_addr; }
generate_alnum_secret() { openssl rand -hex "$((${1:-24}/2))"; }
generate_uuid_v4() { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || echo "$(openssl rand -hex 4)-$(openssl rand -hex 2)-4$(openssl rand -hex 3)-$(printf '%x' $((RANDOM%4+8)))$(openssl rand -hex 3)-$(openssl rand -hex 6)"; }
urlenc() { printf '%s' "$1" | jq -sRr @uri; }
yaml_quote() { printf '"%s"' "$1"; }
tls_insecure_flag() {
  if [[ "${SELF_SIGN_CERT:-1}" == "1" ]]; then
    printf '1'
  else
    printf '0'
  fi
}
tls_skip_verify_bool() {
  if [[ "${SELF_SIGN_CERT:-1}" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# 兜底空跑函数 (跳过主框架才需要处理的遗留逻辑)
disable_legacy_protocol_services() { :; }
sing_box_has_enabled_inbound() {
  has_vless_install || has_hy2_install || has_anytls_install || has_ss2022_install || \
    has_vmess_install || has_tuic_install || has_argo_install || has_cdn_vmess_install
}
ensure_dual_stack_ipv6_bind() {
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
}
public_sing_box_listen_addr() {
  local ipv6_disabled
  ipv6_disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)"
  if [[ -r /proc/net/if_inet6 && "$ipv6_disabled" != "1" ]]; then
    echo "::"
  else
    echo "0.0.0.0"
  fi
}
format_bytes_mib() {
  local bytes="$1"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s MiB' "$(( (bytes + 1048575) / 1048576 ))"
  else
    printf '%s' "$bytes"
  fi
}
parse_bandwidth_mbps() {
  local raw="$1"
  awk -v raw="$raw" '
    BEGIN {
      gsub(/^[ \t]+|[ \t]+$/, "", raw)
      gsub(/,/, "", raw)
      if (raw == "") {
        print 0
        exit
      }
      low = tolower(raw)
      if (match(low, /^[0-9]+([.][0-9]+)?/) == 0) {
        print 0
        exit
      }
      val = substr(low, RSTART, RLENGTH) + 0
      if (low ~ /gbps|gbit/) {
        mult = 1000
      } else if (raw ~ /GB\/s|GBps|GByte|GB$/ || low ~ /gb\/s|gbyte|gib\/s/ || low ~ /^[0-9]+([.][0-9]+)?[ \t]*(gb|gib)$/) {
        mult = 8000
      } else if (low ~ /mbps|mbit/) {
        mult = 1
      } else if (raw ~ /MB\/s|MBps|MByte|MB$/ || low ~ /mb\/s|mbyte|mib\/s/ || low ~ /^[0-9]+([.][0-9]+)?[ \t]*(mb|mib)$/) {
        mult = 8
      } else if (low ~ /kbps|kbit/) {
        mult = 0.001
      } else if (low ~ /kb\/s|kbyte|kib\/s/) {
        mult = 0.008
      } else {
        mult = 1
      }
      printf "%d\n", (val * mult) + 0.5
    }
  '
}
write_sing_box_service_tuning() {
  local sysctl_file="/etc/sysctl.d/99-agsb-proxy-tuning.conf"
  local override_dir="/etc/systemd/system/${SING_BOX_SERVICE}.d"
  local show_report="${1:-0}"
  local mem_kb mem_mb cpu_cores rtt_ms bandwidth_mbps bandwidth_label
  local congestion_control current_cc bbr_status profile
  local sock_default rmem_max wmem_max optmem_max netdev_backlog somaxconn udp_min cap_bytes bdp_bytes target_bytes
  local actual_cc actual_qdisc actual_rmem actual_wmem actual_somax actual_backlog

  mkdir -p /etc/sysctl.d "$override_dir"
  modprobe tcp_bbr >/dev/null 2>&1 || true

  mem_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  mem_mb="$(( ${mem_kb:-1048576} / 1024 ))"
  cpu_cores="$(nproc 2>/dev/null || echo 1)"
  [[ "$cpu_cores" =~ ^[0-9]+$ && "$cpu_cores" -gt 0 ]] || cpu_cores=1

  rtt_ms="${PROXY_TUNE_RTT_MS:-220}"
  [[ "$rtt_ms" =~ ^[0-9]+$ && "$rtt_ms" -gt 0 ]] || rtt_ms=220
  bandwidth_mbps="${PROXY_TUNE_BANDWIDTH_MBPS:-0}"
  [[ "$bandwidth_mbps" =~ ^[0-9]+$ ]] || bandwidth_mbps=0

  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    congestion_control="bbr"
    bbr_status="可用"
  else
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
    congestion_control="${current_cc:-cubic}"
    bbr_status="不可用，保留 ${congestion_control}"
  fi

  if (( mem_mb < 768 )); then
    profile="小内存"
    sock_default=262144
    rmem_max=16777216
    wmem_max=16777216
    optmem_max=4194304
    netdev_backlog=50000
    somaxconn=16384
    udp_min=8192
    cap_bytes=16777216
  elif (( mem_mb < 1536 )); then
    profile="低内存"
    sock_default=524288
    rmem_max=33554432
    wmem_max=33554432
    optmem_max=8388608
    netdev_backlog=100000
    somaxconn=32768
    udp_min=8192
    cap_bytes=33554432
  elif (( mem_mb < 4096 )); then
    profile="标准 VPS"
    sock_default=1048576
    rmem_max=67108864
    wmem_max=67108864
    optmem_max=16777216
    netdev_backlog=250000
    somaxconn=65535
    udp_min=16384
    cap_bytes=67108864
  elif (( mem_mb < 8192 )); then
    profile="高内存"
    sock_default=1048576
    rmem_max=134217728
    wmem_max=134217728
    optmem_max=33554432
    netdev_backlog=400000
    somaxconn=131072
    udp_min=16384
    cap_bytes=134217728
  else
    profile="大内存"
    sock_default=2097152
    rmem_max=268435456
    wmem_max=268435456
    optmem_max=67108864
    netdev_backlog=500000
    somaxconn=262144
    udp_min=32768
    cap_bytes=268435456
  fi

  if (( cpu_cores <= 1 && netdev_backlog > 100000 )); then
    netdev_backlog=100000
  elif (( cpu_cores >= 4 && mem_mb >= 2048 )); then
    netdev_backlog=$(( netdev_backlog + cpu_cores * 25000 ))
    (( netdev_backlog > 600000 )) && netdev_backlog=600000
  fi

  if (( bandwidth_mbps > 0 )); then
    bdp_bytes=$(( bandwidth_mbps * rtt_ms * 125 ))
    target_bytes=$(( bdp_bytes * 4 ))
    if (( target_bytes > rmem_max )); then
      rmem_max="$target_bytes"
      wmem_max="$target_bytes"
    fi
    if (( rmem_max > cap_bytes )); then
      rmem_max="$cap_bytes"
      wmem_max="$cap_bytes"
    fi
    bandwidth_label="${bandwidth_mbps} Mbps"
  else
    bandwidth_label="未填写，按内存/CPU档位"
  fi

  printf '%s\n' \
    "net.core.default_qdisc = fq" \
    "net.core.somaxconn = ${somaxconn}" \
    "net.core.netdev_max_backlog = ${netdev_backlog}" \
    "net.core.rmem_default = ${sock_default}" \
    "net.core.wmem_default = ${sock_default}" \
    "net.core.rmem_max = ${rmem_max}" \
    "net.core.wmem_max = ${wmem_max}" \
    "net.core.optmem_max = ${optmem_max}" \
    "net.ipv4.tcp_congestion_control = ${congestion_control}" \
    "net.ipv4.tcp_fastopen = 3" \
    "net.ipv4.tcp_mtu_probing = 1" \
    "net.ipv4.tcp_slow_start_after_idle = 0" \
    "net.ipv4.tcp_notsent_lowat = 16384" \
    "net.ipv4.tcp_keepalive_time = 60" \
    "net.ipv4.tcp_keepalive_intvl = 10" \
    "net.ipv4.tcp_keepalive_probes = 6" \
    "net.ipv4.tcp_tw_reuse = 1" \
    "net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}" \
    "net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}" \
    "net.ipv4.ip_local_port_range = 10000 65535" \
    "net.ipv4.udp_rmem_min = ${udp_min}" \
    "net.ipv4.udp_wmem_min = ${udp_min}" \
    "net.ipv6.bindv6only = 0" > "$sysctl_file"

  sysctl -p "$sysctl_file" >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  fi

  printf '%s\n' \
    "[Service]" \
    "LimitNOFILE=1048576" \
    "LimitNPROC=1048576" \
    "LimitMEMLOCK=infinity" \
    "TasksMax=infinity" \
    "Nice=-5" > "${override_dir}/tuning.conf"

  if [[ "$show_report" == "show" ]]; then
    actual_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    actual_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    actual_rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo "$rmem_max")"
    actual_wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || echo "$wmem_max")"
    actual_somax="$(sysctl -n net.core.somaxconn 2>/dev/null || echo "$somaxconn")"
    actual_backlog="$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "$netdev_backlog")"

    cyan "=== 动态网络调优明细 ==="
    echo "机器状态: 内存 ${mem_mb} MB / CPU ${cpu_cores} 核 / 档位 ${profile}"
    echo "线路假设: RTT ${rtt_ms} ms / 带宽 ${bandwidth_label}"
    echo "计算依据: 内存限制 buffer 上限，CPU 调整 backlog，RTT/带宽估算跨境链路 BDP"
    echo "1) 拥塞控制: ${actual_cc} + ${actual_qdisc}（BBR: ${bbr_status}）"
    echo "2) Socket buffer: rmem_max=${actual_rmem} ($(format_bytes_mib "$actual_rmem")) wmem_max=${actual_wmem} ($(format_bytes_mib "$actual_wmem"))"
    echo "3) TCP窗口: tcp_rmem/tcp_wmem 最大值按内存、RTT、带宽上限计算"
    echo "4) 排队能力: somaxconn=${actual_somax} netdev_backlog=${actual_backlog}"
    echo "5) 低延迟连接: tcp_fastopen=3 mtu_probing=1 slow_start_after_idle=0"
    echo "6) 保活回收: keepalive=60/10/6 tcp_tw_reuse=1"
    echo "7) 服务资源: NOFILE/NPROC=1048576 MEMLOCK/TasksMax=infinity Nice=-5"
    echo "配置文件: ${sysctl_file}"
  fi
}
cert_matches_domain() {
  [[ -n "${DOMAIN:-}" ]] || return 0
  [[ -f "$SSL_DIR/fullchain.cer" ]] || return 1
  openssl x509 -in "$SSL_DIR/fullchain.cer" -noout -checkhost "$DOMAIN" >/dev/null 2>&1
}
cert_is_currently_valid() {
  [[ -f "$SSL_DIR/fullchain.cer" ]] || return 1
  openssl x509 -in "$SSL_DIR/fullchain.cer" -noout -checkend 86400 >/dev/null 2>&1
}
cert_is_publicly_trusted() {
  local verify_domain="${1:-${DOMAIN:-}}" fullchain="${SSL_DIR}/fullchain.cer"
  local cert chain leaf rc tmp_dir

  [[ -n "$verify_domain" && -f "$fullchain" ]] || return 1
  tmp_dir="$(mktemp -d)" || return 1

  if ! awk -v dir="$tmp_dir" '
    /-----BEGIN CERTIFICATE-----/ {
      n++
      file = sprintf("%s/cert-%02d.pem", dir, n)
    }
    n > 0 {
      print > file
    }
    /-----END CERTIFICATE-----/ {
      close(file)
    }
    END {
      if (n == 0) exit 1
    }
  ' "$fullchain"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  leaf="${tmp_dir}/cert-01.pem"
  chain="${tmp_dir}/chain.pem"
  : > "$chain"
  for cert in "$tmp_dir"/cert-*.pem; do
    [[ "$cert" == "$leaf" ]] && continue
    sed -n '1,$p' "$cert" >> "$chain"
  done

  if [[ -s "$chain" ]]; then
    openssl verify -purpose sslserver -verify_hostname "$verify_domain" -untrusted "$chain" "$leaf" >/dev/null 2>&1
  else
    openssl verify -purpose sslserver -verify_hostname "$verify_domain" "$leaf" >/dev/null 2>&1
  fi
  rc=$?
  rm -rf "$tmp_dir"
  return "$rc"
}
cert_files_exist() { [[ -f "$SSL_DIR/fullchain.cer" && -f "$SSL_DIR/private.key" ]]; }
detect_cert_primary_name() {
  local san cn
  cert_files_exist || return 1
  san="$(openssl x509 -in "$SSL_DIR/fullchain.cer" -noout -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' | sed -nE 's/.*DNS:([^[:space:]]+).*/\1/p' | head -1)"
  if [[ -n "$san" ]]; then
    printf '%s\n' "$san"
    return 0
  fi
  cn="$(openssl x509 -in "$SSL_DIR/fullchain.cer" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -nE 's/.*CN=([^,]+).*/\1/p' | head -1)"
  [[ -n "$cn" ]] || return 1
  printf '%s\n' "$cn"
}

configure_domain_certificate() {
  local cert_domain use_existing

  SSL_DIR="${SSL_DIR:-/etc/sing-box/cert}"
  mkdir -p "$SSL_DIR"

  cert_domain="$(detect_cert_primary_name 2>/dev/null || true)"
  if [[ -n "$cert_domain" ]]; then
    read -r -p "检测到已存在 ${cert_domain} 的证书，是否继续使用? [Y/n]: " use_existing
    if [[ ! "$use_existing" =~ ^[Nn]$ ]]; then
      DOMAIN="$cert_domain"
      SNI_VAL="$DOMAIN"
      if cert_matches_domain && cert_is_currently_valid && cert_is_publicly_trusted "$DOMAIN"; then
        SELF_SIGN_CERT="0"
      else
        SELF_SIGN_CERT="1"
        yellow "现有证书不是系统信任的公开证书或已过期，分享链接将使用 insecure=1。"
      fi
      REALITY_SNI="${REALITY_SNI:-www.apple.com}"
      echo "已使用现有证书：${DOMAIN}"
      return 0
    fi
  fi

  read -r -p "请输入域名(留空使用自签证书): " DOMAIN
  if [[ -n "$DOMAIN" ]]; then
    if cert_files_exist && cert_matches_domain; then
      if cert_is_currently_valid && cert_is_publicly_trusted "$DOMAIN"; then
        echo "检测到服务器已存在匹配 ${DOMAIN} 的公开可信证书，将直接使用。"
        SELF_SIGN_CERT="0"
      else
        yellow "检测到匹配 ${DOMAIN} 的证书，但它不是系统信任的公开证书或已过期。"
        yellow "将继续使用该证书，并在分享链接中启用 insecure=1。"
        SELF_SIGN_CERT="1"
      fi
    else
      echo "未检测到匹配 ${DOMAIN} 的证书，生成自签证书。"
      SELF_SIGN_CERT="1"
      openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$SSL_DIR/private.key" -out "$SSL_DIR/fullchain.cer" \
        -days 3650 -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN}" 2>/dev/null
    fi
    SNI_VAL="$DOMAIN"
    REALITY_SNI="${REALITY_SNI:-www.apple.com}"
  else
    DOMAIN=""
    SNI_VAL="www.apple.com"
    REALITY_SNI="${REALITY_SNI:-$SNI_VAL}"
    SELF_SIGN_CERT="1"
    echo "未绑定域名，已为您生成自签证书，SNI 将使用：$SNI_VAL"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "$SSL_DIR/private.key" -out "$SSL_DIR/fullchain.cer" \
      -days 3650 -subj "/CN=${SNI_VAL}" -addext "subjectAltName=DNS:${SNI_VAL}" 2>/dev/null
  fi
}

install_mask_site_nginx() {
  require_root || return 1
  run_remote_mask_site_script deploy
}

refresh_mask_site_nginx() {
  run_remote_mask_site_script refresh-nginx
}

mask_site_script_fetch_url() {
  local sep="?"
  [[ "$MASK_SITE_SCRIPT_URL" == *\?* ]] && sep="&"
  printf '%s%s_t=%s\n' "$MASK_SITE_SCRIPT_URL" "$sep" "${RANDOM}${RANDOM}"
}

run_remote_mask_site_script() {
  local action="$1" tmp_script url rc
  command -v curl >/dev/null 2>&1 || { red "缺少 curl，无法拉取远程站点脚本。"; return 1; }
  url="$(mask_site_script_fetch_url)"
  yellow "正在从远程加载站点脚本：${MASK_SITE_SCRIPT_URL}"
  tmp_script="$(mktemp /tmp/mask-site.XXXXXX.sh)" || return 1
  if ! curl -fsSL -H "Cache-Control: no-cache" "$url" -o "$tmp_script"; then
    rm -f "$tmp_script"
    red "远程站点脚本下载失败：${MASK_SITE_SCRIPT_URL}"
    return 1
  fi
  bash "$tmp_script" "$action"
  rc=$?
  rm -f "$tmp_script"
  return "$rc"
}
clear_hy2_port_hopping_rules() { :; }
apply_hy2_port_hopping_rules() { :; }
install_hysteria2_binary() { :; } 
argo_is_named_tunnel() { [[ "${ARGO_TUNNEL_MODE:-quick}" == "named" ]]; }
normalize_argo_host() {
  printf '%s' "$1" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g'
}

cf_api_request() {
  local method="$1" path="$2" data="${3:-}" response body http_code errors codes debug_dir debug_file safe_name
  [[ -n "${CF_API_TOKEN:-}" ]] || { red "Cloudflare API Token 为空。"; return 1; }

  debug_dir="${STATE_DIR}/cf-api-debug"
  mkdir -p "$debug_dir"
  safe_name="$(printf '%s_%s' "$method" "$path" | sed -E 's#[^A-Za-z0-9._-]+#_#g; s#_+$##')"
  debug_file="${debug_dir}/$(date +%Y%m%d-%H%M%S)-${safe_name}.json"

  yellow "Cloudflare API: ${method} ${path}" >&2
  if [[ -n "$data" ]]; then
    response="$(curl -sS -w '\n%{http_code}' -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data")" || { red "Cloudflare API 网络请求失败。" >&2; return 1; }
  else
    response="$(curl -sS -w '\n%{http_code}' -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json")" || { red "Cloudflare API 网络请求失败。" >&2; return 1; }
  fi

  http_code="$(printf '%s' "$response" | tail -n 1)"
  body="$(printf '%s' "$response" | sed '$d')"
  printf '%s\n' "$body" > "$debug_file"

  if [[ "$http_code" =~ ^2 ]] && printf '%s' "$body" | jq -e '.success == true' >/dev/null 2>&1; then
    printf '%s\n' "$body"
    return 0
  fi

  errors="$(printf '%s' "$body" | jq -r '[.errors[]? | "\(.code // "no-code"): \(.message // "unknown")"] | join("; ")' 2>/dev/null)"
  codes="$(printf '%s' "$body" | jq -r '[.errors[]?.code] | join(",")' 2>/dev/null)"
  red "Cloudflare API 请求失败: HTTP ${http_code} ${errors:-unknown error}" >&2
  [[ -n "$codes" ]] && yellow "错误代码: ${codes}" >&2
  yellow "响应已保存: ${debug_file}" >&2
  return 1
}

cf_find_zone_for_host() {
  local host="$1" candidate response zone_id
  candidate="$host"
  while [[ "$candidate" == *.* ]]; do
    echo "尝试匹配 Zone: ${candidate}"
    response="$(cf_api_request GET "/zones?name=${candidate}&status=active&per_page=1")" || return 1
    zone_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
    if [[ -n "$zone_id" ]]; then
      ARGO_CF_ZONE_ID="$zone_id"
      ARGO_CF_ZONE_NAME="$(printf '%s' "$response" | jq -r '.result[0].name // empty')"
      ARGO_CF_ACCOUNT_ID="$(printf '%s' "$response" | jq -r '.result[0].account.id // empty')"
      [[ -n "$ARGO_CF_ACCOUNT_ID" ]] || { red "未能从 Zone 读取 Account ID。"; return 1; }
      green "匹配到 Zone: ${ARGO_CF_ZONE_NAME} (${ARGO_CF_ZONE_ID})"
      return 0
    fi
    candidate="${candidate#*.}"
  done
  red "未在 Cloudflare 账号中找到该域名所属 Zone: ${host}"
  return 1
}

cf_get_or_create_tunnel() {
  local tunnel_name="$1" response tunnel_id data token

  response="$(cf_api_request GET "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel?name=${tunnel_name}&is_deleted=false&per_page=1")" || return 1
  tunnel_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"

  if [[ -z "$tunnel_id" ]]; then
    data="$(jq -nc --arg name "$tunnel_name" '{name:$name, config_src:"cloudflare"}')"
    response="$(cf_api_request POST "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel" "$data")" || return 1
    tunnel_id="$(printf '%s' "$response" | jq -r '.result.id // empty')"
  fi

  [[ -n "$tunnel_id" ]] || { red "创建或读取 Cloudflare Tunnel 失败。"; return 1; }
  ARGO_TUNNEL_ID="$tunnel_id"

  response="$(cf_api_request GET "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel/${ARGO_TUNNEL_ID}/token")" || return 1
  token="$(printf '%s' "$response" | jq -r 'if (.result | type) == "object" then (.result.token // empty) elif (.result | type) == "string" then .result else empty end')"
  [[ -n "$token" && "$token" != "null" ]] || { red "未能获取 Cloudflare Tunnel Token。"; return 1; }
  ARGO_TUNNEL_TOKEN="$token"
}

cf_put_tunnel_public_hostname() {
  local data
  data="$(jq -nc \
    --arg hostname "$ARGO_FIXED_DOMAIN" \
    --arg service "http://localhost:${ARGO_LOCAL_PORT}" \
    '{config:{ingress:[{hostname:$hostname,service:$service},{service:"http_status:404"}],"warp-routing":{enabled:false}}}')"
  cf_api_request PUT "/accounts/${ARGO_CF_ACCOUNT_ID}/cfd_tunnel/${ARGO_TUNNEL_ID}/configurations" "$data" >/dev/null
}

cf_upsert_tunnel_dns() {
  local response record_id data content
  content="${ARGO_TUNNEL_ID}.cfargotunnel.com"
  response="$(cf_api_request GET "/zones/${ARGO_CF_ZONE_ID}/dns_records?name=${ARGO_FIXED_DOMAIN}&per_page=100")" || return 1
  record_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
  data="$(jq -nc --arg type "CNAME" --arg name "$ARGO_FIXED_DOMAIN" --arg content "$content" \
    '{type:$type,name:$name,content:$content,ttl:1,proxied:true}')"

  if [[ -n "$record_id" ]]; then
    cf_api_request PUT "/zones/${ARGO_CF_ZONE_ID}/dns_records/${record_id}" "$data" >/dev/null
  else
    cf_api_request POST "/zones/${ARGO_CF_ZONE_ID}/dns_records" "$data" >/dev/null
  fi
}

# =============================================================================
# CDN VMess WS: Cloudflare API 函数
# =============================================================================

cf_upsert_cdn_vmess_dns() {
  local cdn_domain="$1" vps_ip="$2" zone_id="$3"
  local response record_id record_type data conflict_ids

  # 查询该域名下所有类型的 DNS 记录
  response="$(cf_api_request GET "/zones/${zone_id}/dns_records?name=${cdn_domain}&per_page=100")" || return 1

  # 删除所有冲突记录（CNAME、AAAA 等不能与 A 记录共存的类型）
  conflict_ids="$(printf '%s' "$response" | jq -r '.result[]? | select(.type != "A" and .type != "TXT" and .type != "MX") | .id' 2>/dev/null)"
  if [[ -n "$conflict_ids" ]]; then
    local cid
    for cid in $conflict_ids; do
      yellow "删除冲突的 DNS 记录: ${cdn_domain} (id: ${cid})"
      cf_api_request DELETE "/zones/${zone_id}/dns_records/${cid}" >/dev/null 2>&1 || true
    done
  fi

  # 查找现有 A 记录
  record_id="$(printf '%s' "$response" | jq -r '.result[]? | select(.type == "A") | .id' 2>/dev/null | head -1)"
  data="$(jq -nc --arg type "A" --arg name "$cdn_domain" --arg content "$vps_ip" \
    '{type:$type,name:$name,content:$content,ttl:1,proxied:true}')"

  if [[ -n "$record_id" ]]; then
    yellow "更新已有 A 记录: ${cdn_domain} -> ${vps_ip} (橙云代理)"
    cf_api_request PUT "/zones/${zone_id}/dns_records/${record_id}" "$data" >/dev/null
  else
    yellow "创建新 A 记录: ${cdn_domain} -> ${vps_ip} (橙云代理)"
    cf_api_request POST "/zones/${zone_id}/dns_records" "$data" >/dev/null
  fi
}

cf_set_origin_port_rule() {
  local cdn_domain="$1" origin_port="$2" zone_id="$3"
  local response existing_rules new_rule merged_rules data rule_exists
  local phase_endpoint="/zones/${zone_id}/rulesets/phases/http_request_origin/entrypoint"

  # 读取当前 http_request_origin phase 的 ruleset（可能不存在，404 是正常的）
  response="$(cf_api_request GET "$phase_endpoint" 2>/dev/null)" || response=""
  if [[ -z "$response" ]] || ! printf '%s' "$response" | jq -e '.result.rules' >/dev/null 2>&1; then
    existing_rules="[]"
  else
    existing_rules="$(printf '%s' "$response" | jq -c '.result.rules // []')"
  fi

  # 构建新的 Origin Rule（用 --arg 传端口，jq 内 tonumber，避免 --argjson 空值问题）
  new_rule="$(jq -nc \
    --arg desc "CDN-VMess origin port: ${cdn_domain} -> ${origin_port}" \
    --arg expr "(http.host eq \"${cdn_domain}\")" \
    --arg port "${origin_port}" \
    '{
      action: "route",
      expression: $expr,
      description: $desc,
      action_parameters: {
        origin: {
          port: ($port | tonumber)
        }
      }
    }')"

  if [[ -z "$new_rule" ]]; then
    red "构建 Origin Rule JSON 失败。"
    return 1
  fi

  # 检查是否已有相同域名的规则
  rule_exists="$(printf '%s' "$existing_rules" | jq --arg domain "$cdn_domain" \
    '[.[] | select(.expression | contains($domain))] | length' 2>/dev/null)" || rule_exists="0"

  if [[ "$rule_exists" -gt 0 ]]; then
    merged_rules="$(printf '%s' "$existing_rules" | jq -c --arg domain "$cdn_domain" \
      '[.[] | select(.expression | contains($domain) | not)]')"
    merged_rules="$(printf '%s\n%s' "$merged_rules" "$new_rule" | jq -sc '.[0] + [.[1]]')"
    yellow "更新 Origin Rules: ${cdn_domain} 回源端口 -> ${origin_port}"
  else
    merged_rules="$(printf '%s\n%s' "$existing_rules" "$new_rule" | jq -sc '.[0] + [.[1]]')"
    yellow "创建 Origin Rules: ${cdn_domain} 回源端口 -> ${origin_port}"
  fi

  data="$(printf '%s' "$merged_rules" | jq -c '{rules:.}')"
  cf_api_request PUT "$phase_endpoint" "$data" >/dev/null
}

# Cloudflare CDN 支持的 HTTP 回源端口（不需要 Origin Rules）
CF_HTTP_PORTS=(80 8080 8880 2052 2082 2086 2095)

cf_is_standard_http_port() {
  local port="$1" p
  for p in "${CF_HTTP_PORTS[@]}"; do
    [[ "$port" == "$p" ]] && return 0
  done
  return 1
}

cf_configure_cdn_vmess() {
  local cdn_domain="$1" origin_port="$2" vps_ip="$3" need_origin_rule="$4"

  install_required_command jq || return 1
  install_required_command curl || return 1

  yellow "正在查找 Cloudflare Zone: ${cdn_domain}"
  cf_find_zone_for_host "$cdn_domain" || return 1
  CDN_VMESS_CF_ZONE_ID="$ARGO_CF_ZONE_ID"
  CDN_VMESS_CF_ZONE_NAME="$ARGO_CF_ZONE_NAME"

  yellow "正在配置 DNS A 记录 (橙云代理)..."
  cf_upsert_cdn_vmess_dns "$cdn_domain" "$vps_ip" "$CDN_VMESS_CF_ZONE_ID" || return 1

  if [[ "$need_origin_rule" == "1" ]]; then
    yellow "正在配置 Origin Rules (端口回源)..."
    cf_set_origin_port_rule "$cdn_domain" "$origin_port" "$CDN_VMESS_CF_ZONE_ID" || return 1
    green "Cloudflare CDN VMess 配置完成。"
    echo "域名: ${cdn_domain} (橙云代理已开启)"
    echo "Zone: ${CDN_VMESS_CF_ZONE_NAME}"
    echo "Origin Rule: 客户端 -> ${cdn_domain}:443 -> CF CDN -> VPS:${origin_port}"
  else
    green "Cloudflare CDN VMess 配置完成。"
    echo "域名: ${cdn_domain} (橙云代理已开启)"
    echo "Zone: ${CDN_VMESS_CF_ZONE_NAME}"
    echo "直连 CF 标准端口: 客户端 -> ${cdn_domain}:${origin_port} -> CF CDN -> VPS:${origin_port}"
  fi
}


cf_upsert_site_dns() {
  local site_domain="$1" vps_ip="$2" proxied="${3:-false}"
  local response record_id data zone_id proxied_json
  install_required_command jq || return 1
  cf_find_zone_for_host "$site_domain" || return 1
  zone_id="$ARGO_CF_ZONE_ID"
  response="$(cf_api_request GET "/zones/${zone_id}/dns_records?name=${site_domain}&per_page=100")" || return 1
  record_id="$(printf '%s' "$response" | jq -r '.result[]? | select(.type == "A") | .id' 2>/dev/null | head -1)"
  [[ "$proxied" == "true" ]] && proxied_json="true" || proxied_json="false"
  data="$(jq -nc --arg type "A" --arg name "$site_domain" --arg content "$vps_ip" --argjson proxied "$proxied_json" \
    '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')"
  if [[ -n "$record_id" ]]; then
    cf_api_request PUT "/zones/${zone_id}/dns_records/${record_id}" "$data" >/dev/null
  else
    cf_api_request POST "/zones/${zone_id}/dns_records" "$data" >/dev/null
  fi
}

issue_cf_dns_certificate() {
  local cert_domain="$1" acme_bin="${HOME}/.acme.sh/acme.sh"
  install_required_command curl || return 1
  mkdir -p "$SSL_DIR"
  if [[ ! -x "$acme_bin" ]]; then
    yellow "installing acme.sh..."
    curl https://get.acme.sh | sh || return 1
  fi
  [[ -x "$acme_bin" ]] || { red "acme.sh install failed"; return 1; }
  export CF_Token="$CF_API_TOKEN"
  "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$acme_bin" --issue --dns dns_cf -d "$cert_domain" --keylength ec-256 --force || return 1
  "$acme_bin" --install-cert -d "$cert_domain" --ecc \
    --fullchain-file "$SSL_DIR/fullchain.cer" \
    --key-file "$SSL_DIR/private.key" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true" || return 1
  DOMAIN="$cert_domain"
  SNI_VAL="$cert_domain"
  REALITY_SNI="${REALITY_SNI:-$cert_domain}"
  SELF_SIGN_CERT="0"
}

prepare_cf_proxy_mask_site() {
  local choice site_domain vps_ip has_site
  vps_ip="$(detect_public_ipv4 2>/dev/null || true)"
  if [[ -z "$vps_ip" ]]; then
    read -r -p "Input local public IP: " vps_ip
    [[ -n "$vps_ip" ]] || { red "public IP is required"; return 1; }
  fi

  has_site="0"
  if [[ "${SITE_ENABLED:-0}" == "1" && -n "${SITE_DOMAIN:-}" && -f "$NGINX_SITE_CONF" ]]; then
    has_site="1"
  fi

  echo ""
  cyan "--- Mask site / SNI ---"
  if [[ "$has_site" == "1" ]]; then
    echo "Found existing mask site: ${SITE_DOMAIN}"
    echo "1) Use existing site"
    echo "2) Create new site"
    echo "3) Use www.apple.com as fake SNI"
    read -r -p "Choose [default 1]: " choice
    choice="${choice:-1}"
  else
    echo "No existing mask site found."
    echo "1) Create new site"
    echo "2) Use www.apple.com as fake SNI"
    read -r -p "Choose [default 1]: " choice
    choice="${choice:-1}"
    [[ "$choice" == "2" ]] && choice="3"
  fi

  case "$choice" in
    1)
      if [[ "$has_site" == "1" ]]; then
        DOMAIN="$SITE_DOMAIN"
        SNI_VAL="$SITE_DOMAIN"
        REALITY_SNI="${REALITY_SNI:-$SITE_DOMAIN}"
        SELF_SIGN_CERT="0"
        return 0
      fi
      ;&
    2)
      read -r -p "Input mask site domain: " site_domain
      site_domain="$(normalize_argo_host "$site_domain")"
      [[ -n "$site_domain" ]] || { red "site domain is required"; return 1; }
      yellow "Upserting CF DNS A record (DNS only): ${site_domain} -> ${vps_ip}"
      cf_upsert_site_dns "$site_domain" "$vps_ip" false || return 1
      yellow "Issuing certificate by CF DNS: ${site_domain}"
      issue_cf_dns_certificate "$site_domain" || return 1
      SITE_ENABLED="1"
      SITE_DOMAIN="$site_domain"
      SITE_BRAND="${SITE_BRAND:-EduPanel}"
      install_mask_site_nginx || return 1
      save_state
      ;;
    3)
      DOMAIN=""
      SNI_VAL="www.apple.com"
      REALITY_SNI="www.apple.com"
      SELF_SIGN_CERT="1"
      ;;
    *)
      red "invalid choice"
      return 1
      ;;
  esac
}

create_cf_proxy_node() {
  clear
  load_state >/dev/null 2>&1 || true
  cyan "================ Create CF Proxy Node ================"

  read -r -p "Input UUID [empty = generate]: " input_uuid
  input_uuid="$(printf '%s' "${input_uuid:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$input_uuid" ]]; then
    UUID="$input_uuid"
  else
    UUID="$(generate_uuid_v4)"
    echo "Generated UUID: ${UUID}"
  fi
  sync_common_uuid "$UUID" 2>/dev/null || true

  read -r -p "Input Cloudflare multi-purpose API Token: " input_cf_token
  input_cf_token="$(printf '%s' "${input_cf_token:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$input_cf_token" ]] || { red "Cloudflare API Token is required."; return 1; }
  CF_API_TOKEN="$input_cf_token"

  prepare_cf_proxy_mask_site || return 1
  do_one_click_all_with_cdn
}

cf_configure_named_tunnel() {
  local tunnel_name
  install_required_command jq || return 1
  install_required_command curl || return 1

  yellow "正在查找 Cloudflare Zone..."
  cf_find_zone_for_host "$ARGO_FIXED_DOMAIN" || return 1
  tunnel_name="$(printf '%s' "$ARGO_FIXED_DOMAIN" | tr -c 'A-Za-z0-9._-' '-')"
  yellow "正在创建或复用 Cloudflare Tunnel..."
  cf_get_or_create_tunnel "$tunnel_name" || return 1
  yellow "正在写入 Tunnel Public Hostname..."
  cf_put_tunnel_public_hostname || return 1
  yellow "正在创建或更新 DNS CNAME..."
  cf_upsert_tunnel_dns || return 1

  green "Cloudflare Named Tunnel 已配置完成。"
  echo "域名: ${ARGO_FIXED_DOMAIN}"
  echo "Zone: ${ARGO_CF_ZONE_NAME}"
  echo "Tunnel ID: ${ARGO_TUNNEL_ID}"
}

pick_free_port() {
  local start="${1:-50000}" end="${2:-60000}" candidate i
  for i in $(seq 1 200); do
    candidate="$(shuf -i "${start}-${end}" -n 1)"
    if ! port_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
pick_argo_local_port() {
  local requested="${1:-}" picked
  if [[ -n "$requested" ]] && ! port_in_use "$requested"; then
    ARGO_LOCAL_PORT="$requested"
    return 0
  fi
  picked="$(pick_free_port 50000 60000)" || return 1
  ARGO_LOCAL_PORT="$picked"
}

detect_running_argo_tunnel() {
  local service_file="/etc/systemd/system/${ARGO_SERVICE}" state_file="${STATE_DIR}/node-state.env" found

  systemctl is-active --quiet "$ARGO_SERVICE" 2>/dev/null || return 1
  [[ -f "$service_file" ]] || return 1

  if [[ -f "$state_file" ]]; then
    [[ -z "${ARGO_TUNNEL_MODE:-}" ]] && ARGO_TUNNEL_MODE="$(sed -nE 's/^ARGO_TUNNEL_MODE=(.*)$/\1/p' "$state_file" | tail -1)"
    [[ -z "${ARGO_FIXED_DOMAIN:-}" ]] && ARGO_FIXED_DOMAIN="$(sed -nE 's/^ARGO_FIXED_DOMAIN=(.*)$/\1/p' "$state_file" | tail -1)"
    [[ -z "${ARGO_DOMAIN:-}" ]] && ARGO_DOMAIN="$(sed -nE 's/^ARGO_DOMAIN=(.*)$/\1/p' "$state_file" | tail -1)"
    [[ -z "${ARGO_LOCAL_PORT:-}" ]] && ARGO_LOCAL_PORT="$(sed -nE 's/^ARGO_LOCAL_PORT=(.*)$/\1/p' "$state_file" | tail -1)"
  fi

  found="$(sed -nE 's#^ExecStart=.* run --token[[:space:]]+([^[:space:]]+).*#\1#p' "$service_file" | head -1)"
  if [[ -n "$found" ]]; then
    ARGO_TUNNEL_TOKEN="$found"
    ARGO_TUNNEL_MODE="named"
  fi

  found="$(sed -nE 's#.*--wait-tcp 127[.]0[.]0[.]1[[:space:]]+([0-9]+).*#\1#p; s#.*--url http://127[.]0[.]0[.]1:([0-9]+).*#\1#p' "$service_file" | head -1)"
  [[ -n "$found" ]] && ARGO_LOCAL_PORT="$found"

  if [[ -z "${ARGO_FIXED_DOMAIN:-}" && -n "${ARGO_SHARE_TXT:-}" && -f "$ARGO_SHARE_TXT" ]]; then
    found="$(sed -nE 's#^tunnelHost:[[:space:]]*([^[:space:]]+).*#\1#p' "$ARGO_SHARE_TXT" | head -1)"
    [[ -n "$found" ]] && ARGO_FIXED_DOMAIN="$found"
  fi

  if [[ "${ARGO_TUNNEL_MODE:-quick}" == "named" && -n "${ARGO_FIXED_DOMAIN:-}" ]]; then
    ARGO_DOMAIN="$ARGO_FIXED_DOMAIN"
  elif [[ "${ARGO_TUNNEL_MODE:-quick}" != "named" ]]; then
    resolve_argo_domain "1" >/dev/null 2>&1 || true
  fi

  return 0
}
install_self_script() { :; }
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请使用 root 权限运行：sudo bash $INSTALL_SCRIPT"
    return 1
  fi
}
load_state() {
  local f="${STATE_DIR}/node-state.env"
  [[ -f "$f" ]] || return 1
  # 只加载确实存在的变量，不改写已设置的
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == "#"* ]] && continue
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    declare -g "${k}=${v}"
  done < "$f"
  return 0
}
save_state() {
  local f="${STATE_DIR}/node-state.env" tmp
  mkdir -p "$STATE_DIR"
  tmp="${f}.tmp"
  : > "$tmp"
  # 保存所有关键变量
  for var in UUID SHORT_ID PRIVATE_KEY PUBLIC_KEY \
             VLESS_PORT VLESS_SERVER_ADDR REALITY_SNI HANDSHAKE_SERVER HANDSHAKE_PORT \
             HY2_PORT HY2_PASSWORD HY2_TLS_SNI HY2_OBFS_ENABLED HY2_OBFS_PASSWORD HY2_PORT_RANGE HY2_SERVER_ADDR HY2_CLIENT_UP_MBPS HY2_CLIENT_DOWN_MBPS \
             ANYTLS_PORT ANYTLS_PASSWORD ANYTLS_TLS_SNI ANYTLS_SERVER_ADDR \
             SS2022_PORT SS2022_PASSWORD SS2022_CIPHER SS2022_SERVER_ADDR \
             VMESS_PORT VMESS_UUID VMESS_WS_PATH VMESS_SERVER_ADDR VMESS_TLS_ENABLED VMESS_TLS_SNI \
             TUIC_PORT TUIC_PASSWORD TUIC_UUID TUIC_TLS_SNI TUIC_SERVER_ADDR \
             ARGO_LOCAL_PORT ARGO_DOMAIN ARGO_UUID ARGO_WS_PATH ARGO_EDGE_SERVER ARGO_EDGE_POOL_FILE ARGO_PROTOCOL ARGO_EDGE_IP_VERSION ARGO_FIXED_DOMAIN ARGO_TUNNEL_TOKEN ARGO_TUNNEL_ID ARGO_CF_ACCOUNT_ID ARGO_CF_ZONE_ID ARGO_CF_ZONE_NAME ARGO_MULTI_EDGE \
             SUB_PORT SUB_PATH SUB_ENABLED \
             SITE_ENABLED SITE_DOMAIN SITE_BRAND SITE_ROOT NGINX_SITE_CONF VMESS_VIA_NGINX \
             DOMAIN SNI_VAL SELF_SIGN_CERT \
             NODE_NAME_VLESS NODE_NAME_HY2 NODE_NAME_SS2022 NODE_NAME_VMESS NODE_NAME_TUIC NODE_NAME_ARGO NODE_NAME_ANYTLS \
             VLESS_ENABLED HY2_ENABLED SS2022_ENABLED VMESS_ENABLED TUIC_ENABLED ARGO_ENABLED ANYTLS_ENABLED \
             CDN_VMESS_PORT CDN_VMESS_UUID CDN_VMESS_WS_PATH CDN_VMESS_CDN_DOMAIN CDN_VMESS_ORIGIN_PORT CDN_VMESS_SERVER_ADDR CDN_VMESS_ENABLED CDN_VMESS_CF_ZONE_ID CDN_VMESS_CF_ZONE_NAME NODE_NAME_CDN_VMESS \
             ARGO_TUNNEL_MODE; do
    val="${!var:-}"
    [[ -n "$val" ]] && printf '%s=%s\n' "$var" "$val" >> "$tmp"
  done
  install -m 0600 "$tmp" "$f" 2>/dev/null || mv -f "$tmp" "$f"
  rm -f "$tmp"
}

has_vless_install() { [[ "${VLESS_ENABLED:-}" != "0" && -n "${UUID:-}" && -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" && -n "${VLESS_PORT:-}" ]]; }
has_hy2_install() { [[ "${HY2_ENABLED:-}" != "0" && -n "${HY2_PORT:-}" && -n "${HY2_PASSWORD:-}" ]]; }
has_anytls_install() { [[ "${ANYTLS_ENABLED:-}" != "0" && -n "${ANYTLS_PORT:-}" && -n "${ANYTLS_PASSWORD:-}" ]]; }
has_ss2022_install() { return 1; }
has_vmess_install() { [[ "${VMESS_ENABLED:-}" != "0" && -n "${VMESS_PORT:-}" && -n "${VMESS_UUID:-}" && -n "${VMESS_WS_PATH:-}" ]]; }
has_tuic_install() { [[ "${TUIC_ENABLED:-}" != "0" && -n "${TUIC_PORT:-}" && -n "${TUIC_PASSWORD:-}" && -n "${TUIC_UUID:-}" ]]; }
has_argo_install() { [[ "${ARGO_ENABLED:-}" != "0" && -n "${ARGO_LOCAL_PORT:-}" && -n "${ARGO_UUID:-}" && -n "${ARGO_WS_PATH:-}" ]]; }
has_cdn_vmess_install() { [[ "${CDN_VMESS_ENABLED:-}" == "1" && -n "${CDN_VMESS_PORT:-}" && -n "${CDN_VMESS_UUID:-}" && -n "${CDN_VMESS_WS_PATH:-}" && -n "${CDN_VMESS_CDN_DOMAIN:-}" ]]; }
has_subscription_service() { [[ "${SUB_ENABLED:-}" != "0" && -n "${SUB_PORT:-}" && -n "${SUB_PATH:-}" ]]; }
load_argo_edge_pool() {
  if [[ "${ARGO_MULTI_EDGE:-0}" != "1" || ! -r "${ARGO_EDGE_POOL_FILE:-}" ]]; then
    return 0
  fi

  local cleaned=()
  local line
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
    [[ -n "$line" ]] || continue
    cleaned+=("$line")
  done < "$ARGO_EDGE_POOL_FILE"

  if [[ "${#cleaned[@]}" -gt 0 ]]; then
    ARGO_EDGE_SERVERS=("${cleaned[@]}")
    ARGO_EDGE_SERVER="${ARGO_EDGE_SERVER:-${ARGO_EDGE_SERVERS[0]}}"
  fi
}
cycle_argo_edge_server() {
  if [[ "${ARGO_MULTI_EDGE:-0}" != "1" ]]; then
    return 0
  fi
  load_argo_edge_pool
  if ! declare -p ARGO_EDGE_SERVERS >/dev/null 2>&1; then
    return 0
  fi
  local count="${#ARGO_EDGE_SERVERS[@]}"
  [[ "$count" -gt 0 ]] || return 0
  ARGO_EDGE_INDEX="$(( (${ARGO_EDGE_INDEX:-0} + 1) % count ))"
  ARGO_EDGE_SERVER="${ARGO_EDGE_SERVERS[$ARGO_EDGE_INDEX]}"
}
select_argo_edge_server() {
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" ]]; then
    return 0
  fi

  case "${ARGO_EDGE_SERVER:-}" in
    ""|www.cloudflare.com|198.41.200.113|"$LEGACY_ARGO_EDGE_SERVER")
      ARGO_EDGE_SERVER="${DEFAULT_ARGO_EDGE_SERVER:-}"
      ;;
  esac

  if [[ -z "${ARGO_EDGE_SERVER:-}" && -n "${DEFAULT_ARGO_EDGE_SERVER:-}" ]]; then
    ARGO_EDGE_SERVER="$DEFAULT_ARGO_EDGE_SERVER"
  fi
}

argo_client_server() {
  if [[ -n "${ARGO_EDGE_SERVER:-}" ]]; then
    printf '%s\n' "$ARGO_EDGE_SERVER"
  else
    printf '%s\n' "$ARGO_DOMAIN"
  fi
}
normalize_argo_tunnel_state() {
  ARGO_TUNNEL_MODE="${ARGO_TUNNEL_MODE:-quick}"
  ARGO_PROTOCOL="${ARGO_PROTOCOL:-http2}"
  ARGO_EDGE_IP_VERSION="${ARGO_EDGE_IP_VERSION:-auto}"
  load_argo_edge_pool
  select_argo_edge_server
}
pick_subscription_port() { SUB_PORT="$(pick_free_port 50000 60000)"; }
port_in_use() {
  local port="$1"
  [[ -n "$port" ]] || return 1
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[:.])${port}$" && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -iUDP:"$port" >/dev/null 2>&1 && return 0
  fi
  return 1
}
prompt_tuic_port() { TUIC_PORT="$(pick_free_port 50000 60000)"; }
prompt_hy2_port_range() {
  HY2_PORT="${HY2_PORT:-$(pick_free_port 50000 60000)}"
  HY2_PORT_RANGE="${HY2_PORT_RANGE:-}"
}
prompt_port() {
  local var="$1" min="${3:-50000}" max="${4:-60000}" picked
  picked="$(pick_free_port "$min" "$max")" || return 1
  export "$var=$picked"
}

# 默认配置变量
DEFAULT_TARGET_PORT="${DEFAULT_TARGET_PORT:-443}"
HY2_CLIENT_UP_MBPS="${HY2_CLIENT_UP_MBPS:-80}"
HY2_CLIENT_DOWN_MBPS="${HY2_CLIENT_DOWN_MBPS:-300}"
HY2_MASQUERADE_URL="${HY2_MASQUERADE_URL:-https://www.bing.com}"
HY2_OBFS_ENABLED="${HY2_OBFS_ENABLED:-0}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-}"
ARGO_CLIENT_FINGERPRINT="${ARGO_CLIENT_FINGERPRINT:-chrome}"
ARGO_MULTI_EDGE="${ARGO_MULTI_EDGE:-0}"
ARGO_EDGE_POOL_FILE="${ARGO_EDGE_POOL_FILE:-${STATE_DIR}/argo-edge-pool.txt}"
AGSB_NODE_AUTO_TUNING="${AGSB_NODE_AUTO_TUNING:-0}"

# 文件路径变量
NODE_INFO_DIR="/etc/sing-box/node-info"
CLIENT_JSON="${NODE_INFO_DIR}/vless-client.json"
SHARE_TXT="${NODE_INFO_DIR}/vless-share.txt"
SUB_RAW_TXT="${NODE_INFO_DIR}/vless-subscription-raw.txt"
SUB_B64_TXT="${NODE_INFO_DIR}/vless-subscription-base64.txt"
NODE_QR_PNG="${NODE_INFO_DIR}/vless-node-qr.png"
HY2_SHARE_TXT="${NODE_INFO_DIR}/hy2-share.txt"
HY2_SUB_RAW_TXT="${NODE_INFO_DIR}/hy2-subscription-raw.txt"
HY2_SUB_NOHOP_RAW_TXT="${NODE_INFO_DIR}/hy2-sub-nohop-raw.txt"
HY2_SUB_B64_TXT="${NODE_INFO_DIR}/hy2-subscription-base64.txt"
HY2_QR_PNG="${NODE_INFO_DIR}/hy2-node-qr.png"
HY2_CLIENT_YAML="${NODE_INFO_DIR}/hy2-client.yaml"
HY2_CLIENT_OFFICIAL_YAML="${NODE_INFO_DIR}/hy2-client-official.yaml"
HY2_CLIENT_SINGBOX_JSON="${NODE_INFO_DIR}/hy2-client-singbox.json"
ANYTLS_SHARE_TXT="${NODE_INFO_DIR}/anytls-share.txt"
ANYTLS_SUB_RAW_TXT="${NODE_INFO_DIR}/anytls-subscription-raw.txt"
ANYTLS_SUB_B64_TXT="${NODE_INFO_DIR}/anytls-subscription-base64.txt"
ANYTLS_QR_PNG="${NODE_INFO_DIR}/anytls-node-qr.png"
ANYTLS_CLIENT_YAML="${NODE_INFO_DIR}/anytls-client.yaml"
SS2022_SHARE_TXT="${NODE_INFO_DIR}/ss2022-share.txt"
SS2022_SUB_RAW_TXT="${NODE_INFO_DIR}/ss2022-subscription-raw.txt"
SS2022_SUB_B64_TXT="${NODE_INFO_DIR}/ss2022-subscription-base64.txt"
SS2022_QR_PNG="${NODE_INFO_DIR}/ss2022-node-qr.png"
SS2022_CLIENT_YAML="${NODE_INFO_DIR}/ss2022-client.yaml"
ARGO_SHARE_TXT="${NODE_INFO_DIR}/argo-share.txt"
ARGO_SUB_RAW_TXT="${NODE_INFO_DIR}/argo-subscription-raw.txt"
ARGO_SUB_B64_TXT="${NODE_INFO_DIR}/argo-subscription-base64.txt"
ARGO_QR_PNG="${NODE_INFO_DIR}/argo-node-qr.png"
CDN_VMESS_SHARE_TXT="${NODE_INFO_DIR}/cdn-vmess-share.txt"
CDN_VMESS_SUB_RAW_TXT="${NODE_INFO_DIR}/cdn-vmess-subscription-raw.txt"
CDN_VMESS_SUB_B64_TXT="${NODE_INFO_DIR}/cdn-vmess-subscription-base64.txt"
CDN_VMESS_QR_PNG="${NODE_INFO_DIR}/cdn-vmess-node-qr.png"
COMBO_SUB_RAW_TXT="${NODE_INFO_DIR}/combo-sub-raw.txt"
COMBO_SUB_B64_TXT="${NODE_INFO_DIR}/combo-sub-base64.txt"
SUB_URI_RAW_TXT="${SUBSCRIPTION_DIR}/raw.txt"
SUB_URI_B64_TXT="${SUBSCRIPTION_DIR}/base64.txt"
SUB_CLASH_YAML="${SUBSCRIPTION_DIR}/clash.yaml"
SUB_CLASH_STABLE_YAML="${SUBSCRIPTION_DIR}/clash-stable.yaml"
SUB_INDEX_HTML="${SUBSCRIPTION_DIR}/index.html"
SUB_SERVER_SCRIPT="${SUBSCRIPTION_DIR}/server.py"

ensure_node_info_dir() {
  mkdir -p "$NODE_INFO_DIR"
  chmod 700 "$NODE_INFO_DIR" 2>/dev/null || true
}

# 节点名称变量
NODE_NAME_VLESS="${NODE_NAME_VLESS:-VLESS-Reality}"
NODE_NAME_HY2="${NODE_NAME_HY2:-Hysteria2}"
NODE_NAME_ANYTLS="${NODE_NAME_ANYTLS:-AnyTLS}"
NODE_NAME_SS2022="${NODE_NAME_SS2022:-SS-2022}"
NODE_NAME_VMESS="${NODE_NAME_VMESS:-VMess-WS}"
NODE_NAME_TUIC="${NODE_NAME_TUIC:-TUIC-v5}"
NODE_NAME_ARGO="${NODE_NAME_ARGO:-Argo-VLESS}"
NODE_NAME_CDN_VMESS="${NODE_NAME_CDN_VMESS:-CDN-VMess}"

# 密码/密钥生成函数
generate_hy2_password() {
  HY2_PASSWORD="$(generate_alnum_secret 24)"
}
generate_anytls_password() {
  ANYTLS_PASSWORD="$(generate_alnum_secret 24)"
}
generate_ss2022_password() {
  SS2022_PASSWORD="$(generate_alnum_secret 24)"
}

# =============================================================================
# 垫片结束，下方为重构后的纯净业务代码
# =============================================================================

generate_keys_and_ids() {
  UUID="${UUID:-$(generate_uuid_v4)}"
  XHTTP_PATH=""
  SHORT_ID="$(openssl rand -hex 8)"

  local bin keys
  bin="$(sing_box_cmd 2>/dev/null || true)"
  if [[ -z "$bin" ]]; then
    install_sing_box
    bin="$(sing_box_cmd 2>/dev/null || true)"
  fi

  keys="$("$bin" generate reality-keypair)"
  PRIVATE_KEY="$(awk -F: 'tolower($1) ~ /private/ {v=$2; sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit}' <<<"$keys")"
  PUBLIC_KEY="$(awk -F: 'tolower($1) ~ /public/ {v=$2; sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit}' <<<"$keys")"

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    red "sing-box reality-keypair 生成失败"
    echo "$keys"
    exit 1
  fi
}

detect_existing_common_uuid() {
  local candidate
  for candidate in "${UUID:-}" "${ARGO_UUID:-}" "${VMESS_UUID:-}" "${TUIC_UUID:-}"; do
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

sync_common_uuid() {
  ARGO_UUID="$UUID"
  VMESS_UUID="$UUID"
  TUIC_UUID="$UUID"
}

read_common_uuid() {
  local input_uuid
  read -r -p "请输入通用 UUID (留空则自动生成): " input_uuid
  if [[ -z "$input_uuid" ]]; then
    UUID="$(generate_uuid_v4)"
    echo "已生成随机 UUID: $UUID"
  else
    UUID="$input_uuid"
  fi
  sync_common_uuid
}

prompt_common_uuid() {
  local previous_uuid use_previous

  previous_uuid="$(detect_existing_common_uuid 2>/dev/null || true)"
  if [[ -n "$previous_uuid" ]]; then
    echo "检测到之前节点使用的 UUID: $previous_uuid"
    read -r -p "是否继续使用该 UUID? [Y/n]: " use_previous
    if [[ ! "$use_previous" =~ ^[Nn]$ ]]; then
      UUID="$previous_uuid"
      sync_common_uuid
      echo "已继续使用历史 UUID: $UUID"
      return 0
    fi
  fi

  read_common_uuid
}

is_valid_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

read_subscription_port() {
  local input_port

  while :; do
    read -r -p "请输入订阅链接端口 (留空随机 50000-60000): " input_port
    if [[ -z "$input_port" ]]; then
      pick_subscription_port || SUB_PORT="$(shuf -i 50000-60000 -n 1)"
      echo "已自动生成订阅链接端口: $SUB_PORT"
      return 0
    fi
    if is_valid_port "$input_port"; then
      SUB_PORT="$input_port"
      return 0
    fi
    red "端口无效，请输入 1-65535 的数字。"
  done
}

prompt_subscription_port() {
  local previous_port use_previous

  previous_port="${SUB_PORT:-}"
  if is_valid_port "$previous_port"; then
    echo "检测到之前生成的订阅链接端口: $previous_port"
    read -r -p "是否继续使用该端口? [Y/n]: " use_previous
    if [[ ! "$use_previous" =~ ^[Nn]$ ]]; then
      SUB_PORT="$previous_port"
      echo "已继续使用订阅链接端口: $SUB_PORT"
      return 0
    fi
  fi

  read_subscription_port
}

write_sing_box_service() {
  printf '%s\n' \
    "[Unit]" \
    "Description=${APP_NAME} sing-box service" \
    "Documentation=https://sing-box.sagernet.org" \
    "After=network-online.target" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "Type=simple" \
    "ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_CFG}" \
    "Restart=on-failure" \
    "RestartSec=5s" \
    "LimitNOFILE=1048576" \
    "LimitMEMLOCK=infinity" \
    "Nice=-5" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" > "/etc/systemd/system/${SING_BOX_SERVICE}"
}

write_sing_box_config() {
  local public_listen tmp_cfg vmess_listen

  install_sing_box || { red "sing-box 核心安装失败，无法继续！"; return 1; }
  disable_legacy_protocol_services

  if ! sing_box_has_enabled_inbound; then
    systemctl disable --now "$SING_BOX_SERVICE" >/dev/null 2>&1 || true
    rm -f "$SING_BOX_CFG"
    return 0
  fi

  ensure_dual_stack_ipv6_bind
  public_listen="$(public_sing_box_listen_addr)"
  if [[ "${VMESS_VIA_NGINX:-0}" == "1" ]]; then
    vmess_listen="127.0.0.1"
  else
    vmess_listen="$public_listen"
  fi
  mkdir -p "$SING_BOX_DIR"
  ensure_node_info_dir
  tmp_cfg="$(mktemp)"

  # 最终兜底：在生成配置前验证 anytls 是否可用
  if [[ "${ANYTLS_ENABLED:-0}" == "1" ]]; then
    local _atf="$(mktemp)"
    printf '%s' '{"inbounds":[{"type":"anytls","tag":"t","listen":"127.0.0.1","listen_port":1,"users":[{"name":"x","password":"x"}],"tls":{"enabled":false,"certificate_path":"","key_path":""}}]}' > "$_atf"
    if ! "$SING_BOX_BIN" check -c "$_atf" >/dev/null 2>&1; then
      yellow "sing-box 不支持 anytls inbound，已跳过 AnyTLS 配置"
      ANYTLS_ENABLED="0"
    fi
    rm -f "$_atf"
  fi

  jq -n \
    --arg reality_sni "${REALITY_SNI:-${SNI_VAL:-${HANDSHAKE_SERVER:-www.apple.com}}}" \
    --arg tls_server_name "${VMESS_TLS_SNI:-${DOMAIN:-${SNI_VAL:-www.apple.com}}}" \
    --arg uuid "${UUID:-}" \
    --arg private_key "${PRIVATE_KEY:-}" \
    --arg public_key "${PUBLIC_KEY:-}" \
    --arg short_id "${SHORT_ID:-}" \
    --arg vless_port "${VLESS_PORT:-443}" \
    --arg handshake_server "${HANDSHAKE_SERVER:-${REALITY_SNI:-www.apple.com}}" \
    --arg handshake_port "${HANDSHAKE_PORT:-443}" \
    --arg cert_path "${SSL_DIR}/fullchain.cer" \
    --arg key_path "${SSL_DIR}/private.key" \
    --arg hy2_enabled "${HY2_ENABLED:-0}" \
    --arg hy2_port "${HY2_PORT:-}" \
    --arg hy2_password "${HY2_PASSWORD:-}" \
    --arg hy2_tls_sni "${HY2_TLS_SNI:-${DOMAIN:-}}" \
    --arg hy2_obfs_enabled "${HY2_OBFS_ENABLED:-0}" \
    --arg hy2_obfs_password "${HY2_OBFS_PASSWORD:-}" \
    --arg anytls_enabled "${ANYTLS_ENABLED:-0}" \
    --arg anytls_port "${ANYTLS_PORT:-}" \
    --arg anytls_password "${ANYTLS_PASSWORD:-}" \
    --arg anytls_tls_sni "${ANYTLS_TLS_SNI:-${DOMAIN:-}}" \
    --arg ss2022_enabled "0" \
    --arg ss2022_port "${SS2022_PORT:-}" \
    --arg ss2022_cipher "${SS2022_CIPHER:-}" \
    --arg ss2022_password "${SS2022_PASSWORD:-}" \
    --arg argo_enabled "${ARGO_ENABLED:-0}" \
    --arg argo_local_port "${ARGO_LOCAL_PORT:-}" \
    --arg argo_uuid "${ARGO_UUID:-}" \
    --arg argo_ws_path "${ARGO_WS_PATH:-}" \
    --arg vmess_enabled "${VMESS_ENABLED:-0}" \
    --arg vmess_port "${VMESS_PORT:-}" \
    --arg vmess_uuid "${VMESS_UUID:-}" \
    --arg vmess_ws_path "${VMESS_WS_PATH:-}" \
    --arg vmess_tls_enabled "${VMESS_TLS_ENABLED:-0}" \
    --arg vmess_listen "$vmess_listen" \
    --arg tuic_enabled "${TUIC_ENABLED:-0}" \
    --arg tuic_port "${TUIC_PORT:-}" \
    --arg tuic_password "${TUIC_PASSWORD:-}" \
    --arg tuic_uuid "${TUIC_UUID:-}" \
    --arg tuic_tls_sni "${TUIC_TLS_SNI:-${DOMAIN:-}}" \
    --arg cdn_vmess_enabled "${CDN_VMESS_ENABLED:-0}" \
    --arg cdn_vmess_port "${CDN_VMESS_PORT:-}" \
    --arg cdn_vmess_uuid "${CDN_VMESS_UUID:-}" \
    --arg cdn_vmess_ws_path "${CDN_VMESS_WS_PATH:-}" \
    --arg public_listen "$public_listen" '
[
  (if $uuid != "" and $private_key != "" and $public_key != "" and $short_id != "" then
    {
      "type": "vless",
      "tag": "vless-tcp-reality-in",
      "listen": $public_listen,
      "listen_port": ($vless_port | tonumber),
      "users": [
        {
          "name": "vless",
          "uuid": $uuid,
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": $reality_sni,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": $handshake_server,
            "server_port": ($handshake_port | tonumber)
          },
          "private_key": $private_key,
          "short_id": [
            $short_id
          ]
        }
      }
    }
  else empty end),
  (if $hy2_enabled == "1" and $hy2_port != "" and $hy2_password != "" then
    ({
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": $public_listen,
      "listen_port": ($hy2_port | tonumber),
      "users": [
        {
          "name": "hy2",
          "password": $hy2_password
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": $hy2_tls_sni,
        "alpn": [
          "h3"
        ],
        "certificate_path": $cert_path,
        "key_path": $key_path
      }
    } + (if $hy2_obfs_enabled == "1" and $hy2_obfs_password != "" then
      {
        "obfs": {
          "type": "salamander",
          "password": $hy2_obfs_password
        }
      }
    else {} end))
  else empty end),
  (if $anytls_enabled == "1" and $anytls_port != "" and $anytls_password != "" then
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": $public_listen,
      "listen_port": ($anytls_port | tonumber),
      "users": [
        {
          "name": "anytls",
          "password": $anytls_password
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": $anytls_tls_sni,
        "certificate_path": $cert_path,
        "key_path": $key_path
      }
    }
  else empty end),
  (if $ss2022_enabled == "1" and $ss2022_port != "" and $ss2022_cipher != "" and $ss2022_password != "" then
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": $public_listen,
      "listen_port": ($ss2022_port | tonumber),
      "method": $ss2022_cipher,
      "password": $ss2022_password
    }
  else empty end),
  (if $argo_enabled == "1" and $argo_local_port != "" and $argo_uuid != "" and $argo_ws_path != "" then
    {
      "type": "vless",
      "tag": "argo-vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": ($argo_local_port | tonumber),
      "users": [
        {
          "name": "argo",
          "uuid": $argo_uuid
        }
      ],
      "transport": {
        "type": "ws",
        "path": $argo_ws_path
      }
    }
  else empty end),
  (if $vmess_enabled == "1" and $vmess_port != "" and $vmess_uuid != "" and $vmess_ws_path != "" then
    {
      "type": "vmess",
      "tag": "vmess-ws-in",
      "listen": $vmess_listen,
      "listen_port": ($vmess_port | tonumber),
      "users": [
        {
          "name": "vmess",
          "uuid": $vmess_uuid,
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": $vmess_ws_path
      },
      "tls": (
        if $vmess_tls_enabled == "1" then
          {
            "enabled": true,
            "server_name": $tls_server_name,
            "certificate_path": $cert_path,
            "key_path": $key_path
          }
        else {
            "enabled": false
          }
        end
      )
    }
  else empty end),
  (if $tuic_enabled == "1" and $tuic_port != "" and $tuic_password != "" then
    {
      "type": "tuic",
      "tag": "tuic5-in",
      "listen": $public_listen,
      "listen_port": ($tuic_port | tonumber),
      "users": [
        {
          "uuid": (if $tuic_uuid != "" then $tuic_uuid else $uuid end),
          "password": $tuic_password
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": $tuic_tls_sni,
        "alpn": ["h3"],
        "certificate_path": $cert_path,
        "key_path": $key_path
      }
    }
  else empty end),
  (if $cdn_vmess_enabled == "1" and $cdn_vmess_port != "" and $cdn_vmess_uuid != "" and $cdn_vmess_ws_path != "" then
    {
      "type": "vmess",
      "tag": "cdn-vmess-ws-in",
      "listen": $public_listen,
      "listen_port": ($cdn_vmess_port | tonumber),
      "users": [
        {
          "name": "cdn-vmess",
          "uuid": $cdn_vmess_uuid,
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": $cdn_vmess_ws_path
      },
      "tls": {
        "enabled": false
      }
    }
  else empty end)
] as $inbounds
| if ($inbounds | length) == 0 then
    error("no sing-box inbounds enabled")
  else
    {
      "log": {
        "level": "warn",
        "timestamp": true
      },
      "inbounds": $inbounds,
      "outbounds": [
        {
          "type": "direct",
          "tag": "direct"
        },
        {
          "type": "block",
          "tag": "block"
        }
      ],
      "route": {
        "final": "direct"
      }
    }
  end
' > "$tmp_cfg"

  if ! "$SING_BOX_BIN" check -c "$tmp_cfg"; then
    red "sing-box 配置检查失败，请检查上方错误信息！"
    rm -f "$tmp_cfg"
    return 1
  fi
  install -m 0600 "$tmp_cfg" "$SING_BOX_CFG"
  rm -f "$tmp_cfg"

  write_sing_box_service
  if [[ "${AGSB_NODE_AUTO_TUNING:-0}" == "1" ]]; then
    write_sing_box_service_tuning
  fi
  systemctl daemon-reload
  systemctl enable "$SING_BOX_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SING_BOX_SERVICE"
}

write_xray_config() {
  write_sing_box_config
}

generate_subscription_path() {
  SUB_PATH="sub-$(openssl rand -hex 12)"
}

subscription_url() {
  local addr="" proto="https"
  if [[ "${SELF_SIGN_CERT:-0}" == "1" ]]; then
    addr="$(detect_public_ipv4 2>/dev/null || curl -s --connect-timeout 3 https://ip.sb 2>/dev/null || true)"
    proto="http"
  elif [[ -n "${DOMAIN:-}" ]]; then
    addr="$DOMAIN"
  else
    addr="$(preferred_direct_server_addr 2>/dev/null || curl -s --connect-timeout 3 https://ip.sb 2>/dev/null || true)"
  fi
  [[ -n "$addr" ]] || return 1
  if [[ -n "${SUB_PORT:-}" && -n "${SUB_PATH:-}" ]]; then
    printf '%s://%s:%s/%s' "$proto" "$addr" "$SUB_PORT" "$SUB_PATH"
  fi
}

print_subscription_links() {
  local sub_url="${1:-}"

  if [[ -z "$sub_url" ]]; then
    sub_url="$(subscription_url)"
  fi
  [[ -n "$sub_url" ]] || return 1

  echo "[智能订阅链接]"
  echo "Auto / 主链接: $sub_url"
  echo "Clash: ${sub_url}?target=clash-full"
  echo "mihomo: ${sub_url}?target=mihomo"
  echo "Shadowrocket: ${sub_url}?target=shadowrocket-full"
  echo "v2rayN / Base64: ${sub_url}?target=v2rayn"
  echo "Raw URI: ${sub_url}?target=raw"
  echo "All(所有协议URI): ${sub_url}/all"
}

anytls_uri() {
  local e_pass e_sni e_label insecure
  e_pass="$(urlenc "$ANYTLS_PASSWORD")"
  e_sni="$(urlenc "$ANYTLS_TLS_SNI")"
  e_label="$(urlenc "$NODE_NAME_ANYTLS")"
  insecure="${SELF_SIGN_CERT:-1}"
  printf 'anytls://%s@%s:%s/?sni=%s&insecure=%s#%s' \
    "$e_pass" "$ANYTLS_SERVER_ADDR" "$ANYTLS_PORT" "$e_sni" "$insecure" "$e_label"
}

ss2022_uri() {
  local e_label userinfo
  e_label="$(urlenc "$NODE_NAME_SS2022")"
  userinfo="$(printf '%s' "${SS2022_CIPHER}:${SS2022_PASSWORD}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')"
  printf 'ss://%s@%s:%s#%s' "$userinfo" "$SS2022_SERVER_ADDR" "$SS2022_PORT" "$e_label"
}

argo_uri() {
  local client_server e_host e_label e_path e_sni
  select_argo_edge_server
  client_server="$(argo_client_server)"
  e_sni="$(urlenc "$ARGO_DOMAIN")"
  e_host="$(urlenc "$ARGO_DOMAIN")"
  e_path="$(urlenc "$ARGO_WS_PATH")"
  e_label="$(urlenc "$NODE_NAME_ARGO")"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=%s&insecure=0&allowInsecure=0&type=ws&host=%s&path=%s#%s' \
    "$ARGO_UUID" "$client_server" "$e_sni" "$ARGO_CLIENT_FINGERPRINT" "$e_host" "$e_path" "$e_label"
}

calc_cert_pin_sha256() {
  openssl x509 -in "$SSL_DIR/fullchain.cer" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

calc_cert_public_key_pin_sha256() {
  openssl x509 -in "$SSL_DIR/fullchain.cer" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null \
    | openssl base64 -A 2>/dev/null
}

resolve_hy2_server_addr() {
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && -n "${ARGO_EDGE_SERVER:-}" ]]; then
    HY2_SERVER_ADDR="$ARGO_EDGE_SERVER"
  else
    HY2_SERVER_ADDR="$(preferred_direct_server_addr || printf '%s\n' "$DOMAIN")"
  fi
  HY2_TLS_SNI="${HY2_TLS_SNI:-${SNI_VAL:-${DOMAIN:-www.apple.com}}}"
}

build_client_files() {
  local e_sni e_pbk e_sid e_spx e_label server_addr uri
  ensure_node_info_dir
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && -n "${ARGO_EDGE_SERVER:-}" ]]; then
    server_addr="$ARGO_EDGE_SERVER"
  else
    server_addr="${VLESS_SERVER_ADDR:-$(preferred_direct_server_addr || printf '%s\n' "${DOMAIN:-127.0.0.1}")}"
  fi
  VLESS_SERVER_ADDR="$server_addr"
  REALITY_SNI="${REALITY_SNI:-${SNI_VAL:-${HANDSHAKE_SERVER:-www.apple.com}}}"
  e_sni="$(urlenc "$REALITY_SNI")"
  e_pbk="$(urlenc "$PUBLIC_KEY")"
  e_sid="$(urlenc "$SHORT_ID")"
  e_spx="$(urlenc "/")"
  e_label="$(urlenc "$NODE_NAME_VLESS")"

  printf '%s\n' \
    "{" \
    "  \"outbounds\": [" \
    "    {" \
    "      \"protocol\": \"vless\"," \
    "      \"settings\": {" \
    "        \"vnext\": [" \
    "          {" \
    "            \"address\": \"$server_addr\"," \
    "            \"port\": ${VLESS_PORT:-443}," \
    "            \"users\": [" \
    "              {" \
    "                \"id\": \"$UUID\"," \
    "                \"flow\": \"xtls-rprx-vision\"," \
    "                \"encryption\": \"none\"" \
    "              }" \
    "            ]" \
    "          }" \
    "        ]" \
    "      }," \
    "      \"streamSettings\": {" \
    "        \"network\": \"tcp\"," \
    "        \"security\": \"reality\"," \
    "        \"realitySettings\": {" \
    "          \"fingerprint\": \"chrome\"," \
    "          \"serverName\": \"${REALITY_SNI}\"," \
    "          \"publicKey\": \"$PUBLIC_KEY\"," \
    "          \"shortId\": \"$SHORT_ID\"," \
    "          \"spiderX\": \"/\"" \
    "        }" \
    "      }" \
    "    }" \
    "  ]" \
    "}" > "$CLIENT_JSON"

  uri="vless://${UUID}@${server_addr}:${VLESS_PORT:-443}?encryption=none&security=reality&sni=${e_sni}&fp=chrome&pbk=${e_pbk}&sid=${e_sid}&type=tcp&headerType=none&spx=${e_spx}&flow=xtls-rprx-vision#${e_label}"

  printf '%s\n' \
    "domain: $DOMAIN" \
    "serverAddress: $server_addr" \
    "uuid: $UUID" \
    "publicKey: $PUBLIC_KEY" \
    "shortId: $SHORT_ID" \
    "transport: tcp" \
    "mode: $INSTALL_MODE" \
    "targetPort: $TARGET_PORT" \
    "" \
    "=== VLESS URI ===" \
    "$uri" \
    "" \
    "=== Client JSON ===" > "$SHARE_TXT"
  cat "$CLIENT_JSON" >> "$SHARE_TXT"

  printf '%s\n' "$uri" > "$SUB_RAW_TXT"
  printf '%s\n' "$uri" | base64 -w 0 > "$SUB_B64_TXT"

  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -o "$NODE_QR_PNG" -t PNG -s 8 -m 2 >/dev/null 2>&1 || true
  fi
}


pick_tuic_server_addr() {
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && -n "${ARGO_EDGE_SERVER:-}" ]]; then
    TUIC_SERVER_ADDR="$ARGO_EDGE_SERVER"
  else
    TUIC_SERVER_ADDR="$(preferred_direct_server_addr || printf '%s\n' "$DOMAIN")"
  fi
  TUIC_TLS_SNI="${TUIC_TLS_SNI:-${SNI_VAL:-${DOMAIN:-www.apple.com}}}"
}

generate_tuic_password() {
  TUIC_UUID="${UUID:-$(generate_uuid_v4)}"
  TUIC_PASSWORD="$(generate_alnum_secret 24)"
}


generate_vmess_identity() {
  VMESS_UUID="$(generate_uuid_v4)"
  VMESS_WS_PATH="/ws-$(openssl rand -hex 6)"
  [[ -z "${VMESS_TLS_ENABLED:-}" ]] && VMESS_TLS_ENABLED="0"
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && -n "${ARGO_EDGE_SERVER:-}" ]]; then
    VMESS_SERVER_ADDR="$ARGO_EDGE_SERVER"
  else
    VMESS_SERVER_ADDR="$(preferred_direct_server_addr || printf '%s\n' "$DOMAIN")"
  fi
}

vmess_public_via_nginx() {
  [[ "${VMESS_VIA_NGINX:-0}" == "1" && -n "${SITE_DOMAIN:-${DOMAIN:-}}" ]]
}

vmess_public_addr() {
  if vmess_public_via_nginx; then
    printf '%s\n' "${SITE_DOMAIN:-$DOMAIN}"
  else
    printf '%s\n' "$VMESS_SERVER_ADDR"
  fi
}

vmess_public_port() {
  if vmess_public_via_nginx; then
    printf '443\n'
  else
    printf '%s\n' "$VMESS_PORT"
  fi
}

vmess_public_tls_enabled() {
  if vmess_public_via_nginx || [[ "${VMESS_TLS_ENABLED:-0}" == "1" ]]; then
    return 0
  fi
  return 1
}

vmess_public_sni() {
  if vmess_public_via_nginx; then
    printf '%s\n' "${SITE_DOMAIN:-$DOMAIN}"
  else
    printf '%s\n' "${VMESS_TLS_SNI:-${DOMAIN:-}}"
  fi
}

install_vmess_core() {
  install_sing_box
  generate_vmess_identity
  prompt_port VMESS_PORT "VMess" || return
  VMESS_ENABLED="1"
  write_sing_box_config
  build_vmess_share_files
  return 0
}

build_vmess_share_files() {
  local label uri public_addr public_port public_host public_tls public_sni
  ensure_node_info_dir
  label="$NODE_NAME_VMESS"
  public_addr="$(vmess_public_addr)"
  public_port="$(vmess_public_port)"
  if vmess_public_tls_enabled; then
    public_host="$(vmess_public_sni)"
    public_tls="tls"
    public_sni="$public_host"
    uri="vmess://$(echo -n '{"add":"'"$public_addr"'","aid":"0","host":"'"$public_host"'","id":"'"$VMESS_UUID"'","net":"ws","path":"'"$VMESS_WS_PATH"'","port":"'"$public_port"'","ps":"'"$label"'","tls":"'"$public_tls"'","sni":"'"$public_sni"'","fp":"chrome","type":"none","v":"2"}' | base64 -w 0)"
  else
    uri="vmess://$(echo -n '{"add":"'"$public_addr"'","aid":"0","id":"'"$VMESS_UUID"'","net":"ws","path":"'"$VMESS_WS_PATH"'","port":"'"$public_port"'","ps":"'"$label"'","type":"none","v":"2"}' | base64 -w 0)"
  fi

  printf '%s\n' \
    "domain: $DOMAIN" \
    "serverAddress: ${VMESS_SERVER_ADDR}" \
    "serverPort: ${VMESS_PORT}" \
    "publicAddress: ${public_addr}" \
    "publicPort: ${public_port}" \
    "publicViaNginx: ${VMESS_VIA_NGINX:-0}" \
    "uuid: ${VMESS_UUID}" \
    "wsPath: ${VMESS_WS_PATH}" \
    "tls: ${public_tls:-none}" \
    "" \
    "=== Vmess-WS URI ===" \
    "$uri" > /etc/sing-box/node-info/vmess-share.txt

  printf '%s\n' "$uri" > /etc/sing-box/node-info/vmess-subscription-raw.txt
  base64 -w 0 < /etc/sing-box/node-info/vmess-subscription-raw.txt > /etc/sing-box/node-info/vmess-subscription-base64.txt

  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -o "/etc/sing-box/node-info/vmess-node-qr.png" -t PNG -s 8 -m 2 >/dev/null 2>&1 || true
  fi
}

vmess_uri() {
  local public_addr public_host public_port public_sni
  public_addr="$(vmess_public_addr)"
  public_port="$(vmess_public_port)"
  if vmess_public_tls_enabled; then
    public_host="$(vmess_public_sni)"
    public_sni="$public_host"
    printf 'vmess://%s' "$(echo -n '{"add":"'"$public_addr"'","aid":"0","host":"'"$public_host"'","id":"'"$VMESS_UUID"'","net":"ws","path":"'"$VMESS_WS_PATH"'","port":"'"$public_port"'","ps":"'"$NODE_NAME_VMESS"'","tls":"tls","sni":"'"$public_sni"'","fp":"chrome","type":"none","v":"2"}' | base64 -w 0)"
  else
    printf 'vmess://%s' "$(echo -n '{"add":"'"$public_addr"'","aid":"0","id":"'"$VMESS_UUID"'","net":"ws","path":"'"$VMESS_WS_PATH"'","port":"'"$public_port"'","ps":"'"$NODE_NAME_VMESS"'","type":"none","v":"2"}' | base64 -w 0)"
  fi
}

install_tuic_core() {
  if [[ "${SELF_SIGN_CERT:-0}" != "1" ]] && { ! cert_matches_domain || ! cert_is_currently_valid; }; then
    red "当前域名证书不可用，请先执行菜单 3 修复证书。"
    return 1
  fi
  install_sing_box
  pick_tuic_server_addr
  generate_tuic_password
  prompt_tuic_port
  TUIC_ENABLED="1"
  write_sing_box_config
  build_tuic_share_files
  return 0
}

build_tuic_share_files() {
  local label e_sni e_pass uri
  ensure_node_info_dir
  [[ "${ARGO_MULTI_EDGE:-0}" != "1" ]] && pick_tuic_server_addr
  label="$NODE_NAME_TUIC"
  e_pass="$(urlenc "$TUIC_PASSWORD")"
  e_sni="$(urlenc "$TUIC_TLS_SNI")"
  local e_uuid
  e_uuid="$(urlenc "$TUIC_UUID")"
  uri="tuic://${e_uuid}:${e_pass}@${TUIC_SERVER_ADDR}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${e_sni}&insecure=${SELF_SIGN_CERT:-1}&allowInsecure=${SELF_SIGN_CERT:-1}#${label}"

  printf '%s\n' \
    "domain: $DOMAIN" \
    "serverAddress: ${TUIC_SERVER_ADDR}" \
    "serverPort: ${TUIC_PORT}" \
    "sni: ${TUIC_TLS_SNI}" \
    "password: ${TUIC_PASSWORD}" \
    "firewallRequired: allow TCP/UDP ${TUIC_PORT}" \
    "" \
    "=== Tuic-v5 URI ===" \
    "$uri" > /etc/sing-box/node-info/tuic5-share.txt

  printf '%s\n' "$uri" > /etc/sing-box/node-info/tuic5-subscription-raw.txt
  base64 -w 0 < /etc/sing-box/node-info/tuic5-subscription-raw.txt > /etc/sing-box/node-info/tuic5-subscription-base64.txt

  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -o "/etc/sing-box/node-info/tuic5-node-qr.png" -t PNG -s 8 -m 2 >/dev/null 2>&1 || true
  fi
}

tuic_uri() {
  local e_uuid e_pass e_sni e_label
  e_uuid="$(urlenc "$TUIC_UUID")"
  e_pass="$(urlenc "$TUIC_PASSWORD")"
  e_sni="$(urlenc "$TUIC_TLS_SNI")"
  e_label="$(urlenc "$NODE_NAME_TUIC")"
  printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&insecure=%s&allowInsecure=%s#%s' \
    "$e_uuid" "$e_pass" "$TUIC_SERVER_ADDR" "$TUIC_PORT" "$e_sni" "${SELF_SIGN_CERT:-1}" "${SELF_SIGN_CERT:-1}" "$e_label"
}

show_node_info() {
  if ! load_state; then
    red "未检测到安装记录"
    return
  fi

  if has_vless_install; then
    cycle_argo_edge_server
    build_client_files
  fi

  if has_hy2_install; then
    cycle_argo_edge_server
    build_hysteria2_share_files
  fi

  if has_anytls_install; then
    cycle_argo_edge_server
    build_anytls_share_files
  fi

  if has_ss2022_install; then
    cycle_argo_edge_server
    build_ss2022_share_files
  fi

  if has_vmess_install; then
    cycle_argo_edge_server
    build_vmess_share_files
  fi

  if has_tuic_install; then
    cycle_argo_edge_server
    build_tuic_share_files
  fi

  if has_argo_install; then
    cycle_argo_edge_server
    ensure_argo_quick_service
    build_argo_share_files "0" || true
    save_state
  fi

  if has_cdn_vmess_install; then
    build_cdn_vmess_share_files
  fi

  build_combined_subscription_files || true

  cyan "================ 节点信息 ================"
  echo "脚本版本: ${APP_VERSION}"
  echo

  if has_vless_install; then
    echo "[VLESS URL]"
    sed -n '/^=== VLESS URI ===$/ {n;p;}' "$SHARE_TXT"
    echo
  fi

  if has_hy2_install; then
    echo "[Hysteria2 URL]"
    sed -n '/^=== Hysteria2 URI ===$/ {n;p;}' "$HY2_SHARE_TXT"
    echo
  fi

  if has_anytls_install; then
    echo "[AnyTLS URL / mihomo YAML]"
    if [[ -f "$ANYTLS_SUB_RAW_TXT" ]]; then
      sed -n '1p' "$ANYTLS_SUB_RAW_TXT"
    fi
    echo
  fi

  if has_ss2022_install; then
    echo "[Shadowsocks-2022 URL]"
    if [[ -f "$SS2022_SUB_RAW_TXT" ]]; then
      sed -n '1p' "$SS2022_SUB_RAW_TXT"
    fi
    echo
  fi

  if has_vmess_install; then
    echo "[VMess-WS URL]"
    if [[ -f /etc/sing-box/node-info/vmess-subscription-raw.txt ]]; then
      sed -n '1p' /etc/sing-box/node-info/vmess-subscription-raw.txt
    fi
    echo
  fi

  if has_tuic_install; then
    echo "[TUIC v5 URL]"
    if [[ -f /etc/sing-box/node-info/tuic5-subscription-raw.txt ]]; then
      sed -n '1p' /etc/sing-box/node-info/tuic5-subscription-raw.txt
    fi
    echo
  fi

  if has_argo_install; then
    echo "[Argo / Cloudflare Tunnel URL]"
    if [[ -f "$ARGO_SUB_RAW_TXT" ]]; then
      sed '/^[[:space:]]*$/d' "$ARGO_SUB_RAW_TXT"
    else
      yellow "暂未获取到 trycloudflare.com 域名，请查看 cloudflared 日志。"
    fi
    echo
  fi

  if has_cdn_vmess_install; then
    echo "[CDN+VMess+WS URL]"
    if [[ -f "$CDN_VMESS_SUB_RAW_TXT" ]]; then
      sed -n '1p' "$CDN_VMESS_SUB_RAW_TXT"
    fi
    echo "  (客户端 → ${CDN_VMESS_CDN_DOMAIN}:443 → CF CDN → VPS:${CDN_VMESS_PORT})"
    echo
  fi

  if has_subscription_service; then
    local sub_url
    sub_url="$(subscription_url)"
    print_subscription_links "$sub_url"
    echo
    if command -v qrencode >/dev/null 2>&1 && [[ -n "$sub_url" ]]; then
      echo "----- 智能订阅二维码 -----"
      printf '%s' "$sub_url" | qrencode -t ANSIUTF8 || true
      echo
    fi
  elif [[ -f "$COMBO_SUB_RAW_TXT" || -f "$COMBO_SUB_B64_TXT" ]]; then
    echo "[本地合并订阅文件]"
    echo "raw: $COMBO_SUB_RAW_TXT"
    echo "base64: $COMBO_SUB_B64_TXT"
    echo
  fi

  if ! has_vless_install && ! has_hy2_install && ! has_anytls_install && ! has_ss2022_install && ! has_tuic_install && ! has_vmess_install && ! has_argo_install && ! has_cdn_vmess_install; then
    yellow "未检测到可展示的协议配置"
  fi

  cyan "========================================"
}

prompt_hy2_obfs() {
  HY2_OBFS_ENABLED="0"
  HY2_OBFS_PASSWORD=""
}

resolve_anytls_server_addr() {
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && -n "${ARGO_EDGE_SERVER:-}" ]]; then
    ANYTLS_SERVER_ADDR="$ARGO_EDGE_SERVER"
  else
    ANYTLS_SERVER_ADDR="$(preferred_direct_server_addr || printf '%s\n' "$DOMAIN")"
  fi
  ANYTLS_TLS_SNI="${ANYTLS_TLS_SNI:-${SNI_VAL:-${DOMAIN:-www.apple.com}}}"
}

resolve_ss2022_server_addr() {
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && -n "${ARGO_EDGE_SERVER:-}" ]]; then
    SS2022_SERVER_ADDR="$ARGO_EDGE_SERVER"
  else
    SS2022_SERVER_ADDR="$(preferred_direct_server_addr || printf '%s\n' "$DOMAIN")"
  fi
}

write_anytls_config() {
  write_sing_box_config
}

build_anytls_share_files() {
  local label
  ensure_node_info_dir
  resolve_anytls_server_addr
  label="$NODE_NAME_ANYTLS"

  printf '%s\n' \
    "mixed-port: 7890" \
    "allow-lan: false" \
    "mode: rule" \
    "log-level: info" \
    "ipv6: false" \
    "" \
    "dns:" \
    "  enable: true" \
    "  ipv6: false" \
    "  enhanced-mode: fake-ip" \
    "  default-nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "  nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "  proxy-server-nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "" \
    "proxies:" \
    "  - name: \"${label}\"" \
    "    type: anytls" \
    "    server: \"${ANYTLS_SERVER_ADDR}\"" \
    "    port: ${ANYTLS_PORT}" \
    "    password: \"${ANYTLS_PASSWORD}\"" \
    "    client-fingerprint: chrome" \
    "    udp: true" \
    "    sni: \"${ANYTLS_TLS_SNI}\"" \
    "    alpn:" \
    "      - h2" \
    "      - http/1.1" \
    "    skip-cert-verify: ${SELF_SIGN_CERT:-1}" \
    "" \
    "proxy-groups:" \
    "  - name: PROXY" \
    "    type: select" \
    "    proxies:" \
    "      - \"${label}\"" \
    "      - DIRECT" \
    "" \
    "rules:" \
    "  - GEOIP,CN,DIRECT" \
    "  - MATCH,PROXY" > "$ANYTLS_CLIENT_YAML"

  chmod 600 "$ANYTLS_CLIENT_YAML"

  printf '%s\n' \
    "domain: $DOMAIN" \
    "serverAddress: ${ANYTLS_SERVER_ADDR}" \
    "serverPort: ${ANYTLS_PORT}" \
    "sni: ${ANYTLS_TLS_SNI}" \
    "password: ${ANYTLS_PASSWORD}" \
    "client: mihomo / Clash Meta compatible" \
    "uri: $(anytls_uri)" \
    "note: 需要放行 TCP ${ANYTLS_PORT}，域名应直连服务器 IP（Cloudflare DNS-only/灰云），不能走橙云代理。" \
    "" \
    "=== AnyTLS mihomo Client YAML ===" > "$ANYTLS_SHARE_TXT"
  cat "$ANYTLS_CLIENT_YAML" >> "$ANYTLS_SHARE_TXT"

  anytls_uri > "$ANYTLS_SUB_RAW_TXT"
  printf '\n' >> "$ANYTLS_SUB_RAW_TXT"
  base64 -w 0 < "$ANYTLS_SUB_RAW_TXT" > "$ANYTLS_SUB_B64_TXT"

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$ANYTLS_QR_PNG" -t PNG -s 8 -m 2 < "$ANYTLS_SUB_RAW_TXT" >/dev/null 2>&1 || true
  fi
}

install_anytls_core() {
  if [[ "${SELF_SIGN_CERT:-0}" != "1" ]] && { ! cert_matches_domain || ! cert_is_currently_valid; }; then
    red "当前域名证书不可用，请先执行菜单 2 修复证书。"
    return 1
  fi

  install_sing_box
  resolve_anytls_server_addr
  prompt_port ANYTLS_PORT "AnyTLS" || return
  generate_anytls_password
  ANYTLS_ENABLED="1"
  write_anytls_config
  build_anytls_share_files
  return 0
}

write_ss2022_config() {
  write_sing_box_config
}

build_ss2022_share_files() {
  local label
  ensure_node_info_dir
  resolve_ss2022_server_addr
  label="$NODE_NAME_SS2022"

  printf '%s\n' \
    "mixed-port: 7890" \
    "allow-lan: false" \
    "mode: rule" \
    "log-level: info" \
    "ipv6: true" \
    "" \
    "dns:" \
    "  enable: true" \
    "  ipv6: true" \
    "  enhanced-mode: fake-ip" \
    "  nameserver:" \
    "    - https://1.1.1.1/dns-query" \
    "    - https://8.8.8.8/dns-query" \
    "" \
    "proxies:" \
    "  - name: \"${label}\"" \
    "    type: ss" \
    "    server: \"${SS2022_SERVER_ADDR}\"" \
    "    port: ${SS2022_PORT}" \
    "    cipher: \"${SS2022_CIPHER}\"" \
    "    password: \"${SS2022_PASSWORD}\"" \
    "    udp: true" \
    "    tfo: true" \
    "    ip-version: ipv4-prefer" \
    "" \
    "proxy-groups:" \
    "  - name: PROXY" \
    "    type: select" \
    "    proxies:" \
    "      - \"${label}\"" \
    "      - DIRECT" \
    "" \
    "rules:" \
    "  - GEOIP,CN,DIRECT" \
    "  - MATCH,PROXY" > "$SS2022_CLIENT_YAML"

  chmod 600 "$SS2022_CLIENT_YAML"

  printf '%s\n' \
    "domain: $DOMAIN" \
    "serverAddress: ${SS2022_SERVER_ADDR}" \
    "serverPort: ${SS2022_PORT}" \
    "cipher: ${SS2022_CIPHER}" \
    "password: ${SS2022_PASSWORD}" \
    "client: mihomo / Clash Meta compatible" \
    "uri: $(ss2022_uri)" \
    "note: 需要放行 TCP/UDP ${SS2022_PORT}，域名应直连服务器 IP（Cloudflare DNS-only/灰云），不能走橙云代理。" \
    "" \
    "=== Shadowsocks-2022 URI ===" \
    "$(ss2022_uri)" \
    "" \
    "=== Shadowsocks-2022 mihomo Client YAML ===" > "$SS2022_SHARE_TXT"
  cat "$SS2022_CLIENT_YAML" >> "$SS2022_SHARE_TXT"

  ss2022_uri > "$SS2022_SUB_RAW_TXT"
  printf '\n' >> "$SS2022_SUB_RAW_TXT"
  base64 -w 0 < "$SS2022_SUB_RAW_TXT" > "$SS2022_SUB_B64_TXT"

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$SS2022_QR_PNG" -t PNG -s 8 -m 2 < "$SS2022_SUB_RAW_TXT" >/dev/null 2>&1 || true
  fi
}

install_ss2022_core() {
  install_sing_box
  resolve_ss2022_server_addr
  prompt_port SS2022_PORT "Shadowsocks" 50000 60000 1 || return
  generate_ss2022_password
  SS2022_ENABLED="0"
  write_ss2022_config
  build_ss2022_share_files
  return 0
}

write_hysteria2_config() {
  write_sing_box_config
}

build_hysteria2_share_files() {
  local e_auth e_label e_obfs_pass e_sni insecure nohop_uri pin_sha256 pubkey_pin_sha256 skip_verify uri
  ensure_node_info_dir
  [[ "${ARGO_MULTI_EDGE:-0}" != "1" ]] && resolve_hy2_server_addr
  pin_sha256="$(calc_cert_pin_sha256)"
  pubkey_pin_sha256="$(calc_cert_public_key_pin_sha256)"
  e_auth="$(urlenc "$HY2_PASSWORD")"
  e_sni="$(urlenc "$HY2_TLS_SNI")"
  e_label="$(urlenc "$NODE_NAME_HY2")"
  insecure="$(tls_insecure_flag)"
  skip_verify="$(tls_skip_verify_bool)"
  if [[ -n "${HY2_PORT_RANGE:-}" ]]; then
    uri="hysteria2://${e_auth}@${HY2_SERVER_ADDR}:${HY2_PORT},${HY2_PORT_RANGE}/?sni=${e_sni}&insecure=${insecure}&allowInsecure=${insecure}&alpn=h3"
  else
    uri="hysteria2://${e_auth}@${HY2_SERVER_ADDR}:${HY2_PORT}/?sni=${e_sni}&insecure=${insecure}&allowInsecure=${insecure}&alpn=h3"
  fi
  nohop_uri="hysteria2://${e_auth}@${HY2_SERVER_ADDR}:${HY2_PORT}/?sni=${e_sni}&insecure=${insecure}&allowInsecure=${insecure}&alpn=h3"
  if [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]]; then
    e_obfs_pass="$(urlenc "$HY2_OBFS_PASSWORD")"
    uri="${uri}&obfs=salamander&obfs-password=${e_obfs_pass}"
    nohop_uri="${nohop_uri}&obfs=salamander&obfs-password=${e_obfs_pass}"
  fi
  uri="${uri}#${e_label}"
  nohop_uri="${nohop_uri}#${e_label}"

  printf '%s\n' \
    "server: ${HY2_SERVER_ADDR}:${HY2_PORT}${HY2_PORT_RANGE:+,}${HY2_PORT_RANGE}" \
    "auth: ${HY2_PASSWORD}" \
    "bandwidth:" \
    "  up: ${HY2_CLIENT_UP_MBPS} mbps" \
    "  down: ${HY2_CLIENT_DOWN_MBPS} mbps" \
    "tls:" \
    "  sni: ${HY2_TLS_SNI}" \
    "  insecure: ${skip_verify}" \
    "quic:" \
    "  initStreamReceiveWindow: 16777216" \
    "  maxStreamReceiveWindow: 16777216" \
    "  initConnReceiveWindow: 33554432" \
    "  maxConnReceiveWindow: 33554432" \
    "fastOpen: true" > "$HY2_CLIENT_YAML"

  if [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]]; then
    printf '%s\n' \
      "obfs:" \
      "  type: salamander" \
      "  salamander:" \
      "    password: ${HY2_OBFS_PASSWORD}" >> "$HY2_CLIENT_YAML"
  fi

  printf '%s\n' \
    "socks5:" \
    "  listen: 127.0.0.1:1080" \
    "transport:" \
    "  udp:" \
    "    hopInterval: 30s" >> "$HY2_CLIENT_YAML"

  printf '%s\n' \
    "server: ${HY2_SERVER_ADDR}:${HY2_PORT}${HY2_PORT_RANGE:+,}${HY2_PORT_RANGE}" \
    "auth: ${HY2_PASSWORD}" \
    "bandwidth:" \
    "  up: ${HY2_CLIENT_UP_MBPS} mbps" \
    "  down: ${HY2_CLIENT_DOWN_MBPS} mbps" \
    "tls:" \
    "  sni: ${HY2_TLS_SNI}" \
    "  insecure: ${skip_verify}" \
    "  # pinSHA256: ${pin_sha256}" \
    "quic:" \
    "  initStreamReceiveWindow: 16777216" \
    "  maxStreamReceiveWindow: 16777216" \
    "  initConnReceiveWindow: 33554432" \
    "  maxConnReceiveWindow: 33554432" \
    "fastOpen: true" \
    "socks5:" \
    "  listen: 127.0.0.1:1080" \
    "transport:" \
    "  udp:" \
    "    hopInterval: 30s" > "$HY2_CLIENT_OFFICIAL_YAML"

  if [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]]; then
    printf '%s\n' \
      "obfs:" \
      "  type: salamander" \
      "  salamander:" \
      "    password: ${HY2_OBFS_PASSWORD}" >> "$HY2_CLIENT_OFFICIAL_YAML"
  fi

  printf '%s\n' \
    "{" \
    "  \"outbounds\": [" \
    "    {" \
    "      \"type\": \"hysteria2\"," \
    "      \"tag\": \"hy2-out\"," \
    "      \"server\": \"${HY2_SERVER_ADDR}\"," \
    "      \"server_port\": ${HY2_PORT}," \
    "      \"server_ports\": [" \
    "        \"${HY2_PORT_RANGE}\"" \
    "      ]," \
    "      \"password\": \"${HY2_PASSWORD}\"," \
    "      \"up_mbps\": ${HY2_CLIENT_UP_MBPS}," \
    "      \"down_mbps\": ${HY2_CLIENT_DOWN_MBPS}," \
    "      \"tls\": {" \
    "        \"enabled\": true," \
    "        \"server_name\": \"${HY2_TLS_SNI}\"," \
    "        \"insecure\": ${skip_verify}," \
    "        \"alpn\": [" \
    "          \"h3\"" \
    "        ]" \
    "      }" > "$HY2_CLIENT_SINGBOX_JSON"
  if [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]]; then
    printf '%s\n' \
      "," \
      "      \"obfs\": {" \
      "        \"type\": \"salamander\"," \
      "        \"password\": \"${HY2_OBFS_PASSWORD}\"" \
      "      }" >> "$HY2_CLIENT_SINGBOX_JSON"
  fi
  printf '%s\n' \
    "    }" \
    "  ]" \
    "}" >> "$HY2_CLIENT_SINGBOX_JSON"

  printf '%s\n' \
    "domain: $DOMAIN" \
    "serverAddress: ${HY2_SERVER_ADDR}" \
    "serverPort: ${HY2_PORT}" \
    "serverPorts: ${HY2_PORT_RANGE:-none}" \
    "sni: ${HY2_TLS_SNI}" \
    "auth: $HY2_PASSWORD" \
    "obfs: $( [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]] && echo "salamander" || echo "off" )" \
    "obfsPassword: $( [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]] && echo "$HY2_OBFS_PASSWORD" || echo "-" )" \
    "masqueradeUrl: ${HY2_MASQUERADE_URL}" \
    "tlsInsecure: ${skip_verify}" \
    "clientBandwidth: up ${HY2_CLIENT_UP_MBPS} Mbps / down ${HY2_CLIENT_DOWN_MBPS} Mbps" \
    "serverBandwidth: unset" \
    "firewallRequired: allow UDP ${HY2_PORT}" \
    "firewallPortHoppingOptional: allow UDP ${HY2_PORT_RANGE:-none}" \
    "pinSHA256(optional): ${pin_sha256}" \
    "" \
    "=== Hysteria2 URI ===" \
    "$nohop_uri" \
    "" \
    "=== Hysteria2 URI (Port Hopping / Advanced) ===" \
    "$uri" \
    "" \
    "=== Client YAML ===" > "$HY2_SHARE_TXT"
  cat "$HY2_CLIENT_YAML" >> "$HY2_SHARE_TXT"
  printf '%s\n' "" "=== Official Client YAML ===" >> "$HY2_SHARE_TXT"
  cat "$HY2_CLIENT_OFFICIAL_YAML" >> "$HY2_SHARE_TXT"
  printf '%s\n' "" "=== sing-box Client JSON ===" >> "$HY2_SHARE_TXT"
  cat "$HY2_CLIENT_SINGBOX_JSON" >> "$HY2_SHARE_TXT"

  printf '%s\n' "$nohop_uri" > "$HY2_SUB_RAW_TXT"
  printf '%s\n' "$nohop_uri" > "$HY2_SUB_NOHOP_RAW_TXT"
  printf '%s\n' "$nohop_uri" | base64 -w 0 > "$HY2_SUB_B64_TXT"

  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$nohop_uri" | qrencode -o "$HY2_QR_PNG" -t PNG -s 8 -m 2 >/dev/null 2>&1 || true
  fi
}

install_cloudflared_binary() {
  local tag asset tmp_dir url release_json

  if [[ -x "$CLOUDFLARED_BIN" ]]; then
    "$CLOUDFLARED_BIN" version | head -n 1 || true
    return 0
  fi

  release_json="$(github_api_json)" || return 1
  tag="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    red "无法获取 cloudflared 最新版本"
    return 1
  fi

  asset="$(detect_cloudflared_asset)"
  tmp_dir="$(mktemp -d)"
  url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/${asset}"

  yellow "正在下载 cloudflared ${tag}: ${asset}"
  curl_fsSL "$url" -o "${tmp_dir}/cloudflared"
  install -m 0755 "${tmp_dir}/cloudflared" "$CLOUDFLARED_BIN"
  rm -rf "$tmp_dir"

  "$CLOUDFLARED_BIN" version | head -n 1 || true
}

generate_argo_identity() {
  ARGO_UUID="$(generate_uuid_v4)"
  ARGO_WS_PATH="/argo-$(openssl rand -hex 8)"
  if [[ -z "${ARGO_LOCAL_PORT:-}" ]]; then
    pick_argo_local_port
  fi
  if argo_is_named_tunnel; then
    ARGO_DOMAIN="$ARGO_FIXED_DOMAIN"
  else
    ARGO_DOMAIN=""
  fi
  ARGO_PROTOCOL="http2"
  ARGO_EDGE_IP_VERSION="${ARGO_EDGE_IP_VERSION:-auto}"
}

prompt_argo_tunnel_config() {
  local api_token fixed_domain input_port token_len token_tail confirm_quick use_running

  normalize_argo_tunnel_state

  echo
  echo "Argo 隧道配置："
  if detect_running_argo_tunnel; then
    echo "检测到本机已有隧道正在运行。"
    echo "隧道模式：${ARGO_TUNNEL_MODE:-quick}"
    echo "隧道域名：${ARGO_FIXED_DOMAIN:-${ARGO_DOMAIN:-未知}}"
    echo "本地服务端口：${ARGO_LOCAL_PORT:-未知}"
    read -r -p "是否继续使用现有隧道? [Y/n]: " use_running
    if [[ ! "$use_running" =~ ^[Nn]$ ]]; then
      [[ "${ARGO_TUNNEL_MODE:-quick}" == "named" && -n "${ARGO_FIXED_DOMAIN:-}" ]] && ARGO_DOMAIN="$ARGO_FIXED_DOMAIN"
      save_state
      return 0
    fi
  fi
  echo "输入 0 返回上一层；Cloudflare API Token 留空则使用临时隧道。"
  read -r -p "请输入 Cloudflare API Token（会明文显示，方便确认粘贴）: " api_token
  api_token="$(printf '%s' "$api_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$api_token" == "0" ]]; then
    return 2
  fi
  if [[ -z "$api_token" ]]; then
    yellow "未读取到 Cloudflare API Token。"
    read -r -p "确认使用临时隧道? [y/N]: " confirm_quick
    case "$confirm_quick" in
      y|Y) ;;
      *)
        red "已取消。请重新进入后粘贴 Token，或输入 0 返回。"
        return 1
        ;;
    esac
    ARGO_TUNNEL_MODE="quick"
    ARGO_FIXED_DOMAIN=""
    ARGO_TUNNEL_TOKEN=""
    ARGO_TUNNEL_ID=""
    ARGO_CF_ACCOUNT_ID=""
    ARGO_CF_ZONE_ID=""
    ARGO_CF_ZONE_NAME=""
    ARGO_DOMAIN=""
    return 0
  fi
  token_len="${#api_token}"
  token_tail="$api_token"
  if (( token_len > 6 )); then
    token_tail="${api_token: -6}"
  fi
  echo "Cloudflare API Token 已读取：长度 ${token_len}，结尾 ${token_tail}"
  if (( token_len < 20 )); then
    yellow "Token 长度看起来偏短，请确认没有粘贴失败。"
  fi

  read -r -p "请输入隧道域名（如 tunnel.example.com）: " fixed_domain
  ARGO_FIXED_DOMAIN="$(normalize_argo_host "${fixed_domain:-}")"
  if [[ -z "$ARGO_FIXED_DOMAIN" ]]; then
    red "固定隧道域名不能为空。"
    return 1
  fi

  read -r -p "请输入本地服务端口（留空随机 50000-60000）: " input_port
  if [[ -z "$input_port" ]]; then
    pick_argo_local_port || { red "未能选出可用本地服务端口。"; return 1; }
  elif [[ "$input_port" =~ ^[0-9]+$ && "$input_port" -gt 0 && "$input_port" -le 65535 ]]; then
    ARGO_LOCAL_PORT="$input_port"
  else
    red "端口无效。"
    return 1
  fi

  echo
  echo "将自动配置 Cloudflare Named Tunnel："
  echo "Token 长度: ${token_len}，结尾: ${token_tail}"
  echo "隧道域名: ${ARGO_FIXED_DOMAIN}"
  echo "本地服务: http://localhost:${ARGO_LOCAL_PORT}"
  echo

  CF_API_TOKEN="$api_token"
  ARGO_TUNNEL_MODE="named"
  ARGO_DOMAIN="$ARGO_FIXED_DOMAIN"
  if ! cf_configure_named_tunnel; then
    red "Cloudflare 自动配置失败。"
    yellow "调试响应目录: ${STATE_DIR}/cf-api-debug"
    echo "按回车键继续..."
    read -r
    return 1
  fi
  save_state
}

normalize_argo_tuning() {
  case "${ARGO_PROTOCOL:-http2}" in
    quic|http2|auto) ;;
    *) ARGO_PROTOCOL="http2" ;;
  esac

  case "${ARGO_EDGE_IP_VERSION:-auto}" in
    4|6|auto) ;;
    *) ARGO_EDGE_IP_VERSION="auto" ;;
  esac
}

wait_tcp_endpoint() {
  local attempts="${3:-45}" host="${1:-}" i port="${2:-}"

  [[ -n "$host" && -n "$port" ]] || return 1

  for i in $(seq 1 "$attempts"); do
    if timeout 1 bash -c ':</dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

write_argo_service() {
  local description edge_arg="" exec_start
  normalize_argo_tuning
  normalize_argo_tunnel_state
  mkdir -p "$STATE_DIR"
  rm -f "${STATE_DIR}/argo.env"
  install_self_script || true

  if [[ "${ARGO_EDGE_IP_VERSION:-auto}" != "auto" ]]; then
    edge_arg=" --edge-ip-version ${ARGO_EDGE_IP_VERSION}"
  fi

  if argo_is_named_tunnel; then
    description="${APP_NAME} Cloudflare Named Tunnel"
    exec_start="${CLOUDFLARED_BIN} tunnel --no-autoupdate --protocol ${ARGO_PROTOCOL:-http2}${edge_arg} --logfile ${ARGO_BOOT_LOG} --loglevel info run --token ${ARGO_TUNNEL_TOKEN}"
  else
    description="${APP_NAME} Cloudflare Quick Tunnel"
    exec_start="${CLOUDFLARED_BIN} tunnel --no-autoupdate --protocol ${ARGO_PROTOCOL:-http2}${edge_arg} --logfile ${ARGO_BOOT_LOG} --loglevel info --url http://127.0.0.1:${ARGO_LOCAL_PORT}"
  fi

  printf '%s\n' \
    "[Unit]" \
    "Description=${description}" \
    "After=network-online.target ${SING_BOX_SERVICE}" \
    "Wants=network-online.target ${SING_BOX_SERVICE}" \
    "StartLimitIntervalSec=300" \
    "StartLimitBurst=3" \
    "" \
    "[Service]" \
    "Type=simple" \
    "TimeoutStartSec=90s" \
    "ExecStartPre=/bin/mkdir -p ${STATE_DIR}" \
    "ExecStartPre=/bin/rm -f ${ARGO_BOOT_LOG}" \
    "ExecStartPre=-/bin/bash ${INSTALL_SCRIPT} --wait-tcp 127.0.0.1 ${ARGO_LOCAL_PORT} 45" \
    "ExecStart=${exec_start}" \
    "ExecStartPost=-/bin/systemctl --no-block start ${ARGO_REFRESH_SERVICE}" \
    "Restart=on-failure" \
    "RestartSec=30s" \
    "RestartMaxDelaySec=120" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" > "/etc/systemd/system/${ARGO_SERVICE}"

  write_argo_refresh_units
}

write_argo_refresh_units() {
  install_self_script || true

  printf '%s\n' \
    "[Unit]" \
    "Description=${APP_NAME} refresh Argo domain and subscription" \
    "After=network-online.target ${SING_BOX_SERVICE} ${ARGO_SERVICE}" \
    "Wants=network-online.target ${ARGO_SERVICE}" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "TimeoutStartSec=240s" \
    "ExecStart=/bin/bash ${INSTALL_SCRIPT} --refresh-argo-subscription systemd" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" > "/etc/systemd/system/${ARGO_REFRESH_SERVICE}"

  printf '%s\n' \
    "[Unit]" \
    "Description=${APP_NAME} periodic Argo subscription refresh" \
    "" \
    "[Timer]" \
    "OnBootSec=5s" \
    "OnUnitActiveSec=10min" \
    "AccuracySec=15s" \
    "Persistent=true" \
    "Unit=${ARGO_REFRESH_SERVICE}" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" > "/etc/systemd/system/${ARGO_REFRESH_TIMER}"

  printf '%s\n' \
    "[Unit]" \
    "Description=${APP_NAME} refresh Argo subscription when cloudflared log changes" \
    "" \
    "[Path]" \
    "PathExists=${ARGO_BOOT_LOG}" \
    "PathModified=${ARGO_BOOT_LOG}" \
    "Unit=${ARGO_REFRESH_SERVICE}" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" > "/etc/systemd/system/${ARGO_REFRESH_PATH}"
}

enable_argo_refresh_automation() {
  # 仅 enable oneshot 服务本身（用于 ExecStartPost 触发一次）
  # 不启用 Timer 定时器和 Path 监控，避免快速隧道疯狂重连
  systemctl enable "$ARGO_REFRESH_SERVICE" >/dev/null 2>&1 || true
}

argo_service_needs_rewrite() {
  local service_file="/etc/systemd/system/${ARGO_SERVICE}"

  normalize_argo_tunnel_state
  [[ -f "$service_file" ]] || return 0
  systemctl is-active --quiet "$ARGO_SERVICE" || return 0
  if argo_is_named_tunnel; then
    grep -Fq -- " run --token " "$service_file" || return 0
    grep -Fq -- "--url http://127.0.0.1:" "$service_file" && return 0
  else
    grep -Fq -- "--url http://127.0.0.1:${ARGO_LOCAL_PORT}" "$service_file" || return 0
  fi
  grep -Fq -- "--protocol ${ARGO_PROTOCOL:-http2}" "$service_file" || return 0
  grep -Fq -- "--logfile ${ARGO_BOOT_LOG}" "$service_file" || return 0
  grep -Fq -- "--wait-tcp 127.0.0.1 ${ARGO_LOCAL_PORT} 45" "$service_file" || return 0
  grep -Fq -- "systemctl --no-block start ${ARGO_REFRESH_SERVICE}" "$service_file" || return 0
  [[ -f "/etc/systemd/system/${ARGO_REFRESH_SERVICE}" ]] || return 0
  [[ -f "/etc/systemd/system/${ARGO_REFRESH_TIMER}" ]] || return 0
  [[ -f "/etc/systemd/system/${ARGO_REFRESH_PATH}" ]] || return 0
  if [[ "${ARGO_EDGE_IP_VERSION:-auto}" != "auto" ]]; then
    grep -Fq -- "--edge-ip-version ${ARGO_EDGE_IP_VERSION}" "$service_file" || return 0
  fi
  return 1
}

ensure_argo_quick_service() {
  if [[ "${ARGO_SKIP_SERVICE_ENSURE:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "$(systemctl is-active "$ARGO_SERVICE" 2>/dev/null || true)" == "activating" ]]; then
    return 0
  fi

  if argo_service_needs_rewrite; then
    yellow "检测到 Argo 服务配置需要刷新，正在重写 systemd 单元。"
    write_argo_service
    systemctl daemon-reload
    systemctl enable "$ARGO_SERVICE" >/dev/null 2>&1 || true
    enable_argo_refresh_automation
    timeout 60 systemctl restart "$ARGO_SERVICE" || yellow "Argo 服务重启超时，请稍后手动检查。"
    ARGO_DOMAIN=""
    refresh_argo_domain || true
  fi
}

extract_argo_domain_from_text() {
  grep -Eo 'https?://[A-Za-z0-9-]+\.trycloudflare\.com|[A-Za-z0-9-]+\.trycloudflare\.com' \
    | sed -E 's#^https?://##' \
    | tail -n 1
}

read_argo_domain_from_journal() {
  local found
  found="$(timeout 10 journalctl "$@" --no-pager 2>/dev/null | extract_argo_domain_from_text || true)"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

read_argo_domain_from_logfile() {
  local found

  [[ -f "$ARGO_BOOT_LOG" ]] || return 1
  found="$(extract_argo_domain_from_text < "$ARGO_BOOT_LOG" || true)"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

read_argo_domain_from_existing_files() {
  local found

  found="$(read_argo_domain_from_logfile || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi

  if [[ -f "$ARGO_SUB_RAW_TXT" ]]; then
    found="$(extract_argo_domain_from_text < "$ARGO_SUB_RAW_TXT" || true)"
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  fi

  if [[ -f "$ARGO_SHARE_TXT" ]]; then
    found="$(extract_argo_domain_from_text < "$ARGO_SHARE_TXT" || true)"
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  fi

  return 1
}

resolve_argo_domain() {
  local allow_existing_fallback="${1:-1}" found max_attempts="${2:-}"

  if [[ -z "$max_attempts" ]]; then
    if [[ "$allow_existing_fallback" == "1" ]]; then
      max_attempts="2"
    else
      max_attempts="20"
    fi
  fi

  refresh_argo_domain "$max_attempts" || true
  if [[ -z "${ARGO_DOMAIN:-}" && "$allow_existing_fallback" == "1" ]]; then
    found="$(read_argo_domain_from_existing_files || true)"
    if [[ -n "$found" ]]; then
      ARGO_DOMAIN="$found"
    fi
  fi

  [[ -n "${ARGO_DOMAIN:-}" ]]
}

refresh_argo_domain() {
  local active_since found i invocation_id max_attempts="${1:-20}"

  if argo_is_named_tunnel; then
    ARGO_DOMAIN="$ARGO_FIXED_DOMAIN"
    return 0
  fi

  invocation_id="$(systemctl show -p InvocationID --value "$ARGO_SERVICE" 2>/dev/null || true)"
  active_since="$(systemctl show -p ActiveEnterTimestamp --value "$ARGO_SERVICE" 2>/dev/null || true)"

  for i in $(seq 1 "$max_attempts"); do
    found=""

    found="$(read_argo_domain_from_logfile || true)"

    if [[ -n "$invocation_id" && "$invocation_id" != "n/a" ]]; then
      if [[ -z "$found" ]]; then
        found="$(read_argo_domain_from_journal -u "$ARGO_SERVICE" "_SYSTEMD_INVOCATION_ID=${invocation_id}" || true)"
      fi
    fi

    if [[ -z "$found" && -n "$active_since" && "$active_since" != "n/a" ]]; then
      found="$(read_argo_domain_from_journal -u "$ARGO_SERVICE" --since "$active_since" || true)"
    fi

    if [[ -n "$found" ]]; then
      ARGO_DOMAIN="$found"
      return 0
    fi

    sleep 2
  done

  ARGO_DOMAIN=""
  return 1
}

measure_argo_latency_ms() {
  local samples="${1:-2}" i result status seconds ms best=""

  if [[ -z "${ARGO_DOMAIN:-}" ]]; then
    return 1
  fi

  for i in $(seq 1 "$samples"); do
    result="$(curl -k -o /dev/null -sS --connect-timeout 3 --max-time 8 \
      -w '%{http_code} %{time_total}' "https://${ARGO_DOMAIN}/" 2>/dev/null || true)"
    read -r status seconds <<< "$result"
    if [[ "$status" =~ ^[0-9]{3}$ && "$status" != "000" && "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      ms="$(awk -v t="$seconds" 'BEGIN { printf "%d", (t * 1000) + 0.5 }')"
      if [[ -z "$best" || "$ms" -lt "$best" ]]; then
        best="$ms"
      fi
    fi
    sleep 1
  done

  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

validate_argo_https_reachable() {
  local status

  if [[ -z "${ARGO_DOMAIN:-}" ]]; then
    return 1
  fi

  status="$(curl -k -sS --connect-timeout 3 --max-time 8 \
    -o /dev/null -w '%{http_code}' "https://${ARGO_DOMAIN}/" 2>/dev/null || true)"

  [[ "$status" != "000" && -n "$status" ]]
}

wait_argo_https_reachable() {
  local attempts="${1:-8}" i

  for i in $(seq 1 "$attempts"); do
    if validate_argo_https_reachable; then
      return 0
    fi
    sleep 2
  done

  return 1
}

restart_argo_with_tuning() {
  local protocol="$1" edge_ip_version="$2" domain_attempts="${3:-20}"

  ARGO_PROTOCOL="$protocol"
  ARGO_EDGE_IP_VERSION="$edge_ip_version"
  normalize_argo_tuning
  ARGO_DOMAIN=""

  write_argo_service
  systemctl daemon-reload
  enable_argo_refresh_automation
  timeout 60 systemctl restart "$ARGO_SERVICE" || { yellow "Argo 服务重启超时"; return 1; }
  refresh_argo_domain "$domain_attempts"
}

build_argo_share_files() {
  local allow_existing_fallback="${1:-1}" client_server mode_note tunnel_label uri
  ensure_node_info_dir
  select_argo_edge_server

  resolve_argo_domain "$allow_existing_fallback" || true

  if [[ -z "${ARGO_DOMAIN:-}" ]]; then
    if argo_is_named_tunnel; then
      yellow "固定 Argo 域名为空，请检查安装状态。"
    else
      yellow "暂未从 cloudflared 日志中获取到 Argo 域名。"
    fi
    if [[ "$allow_existing_fallback" != "1" ]]; then
      rm -f "$ARGO_SHARE_TXT" "$ARGO_SUB_RAW_TXT" "$ARGO_SUB_B64_TXT" "$ARGO_QR_PNG"
    fi
    return 1
  fi

  client_server="$(argo_client_server)"
  uri="$(argo_uri)"
  if [[ -n "${ARGO_EDGE_SERVER:-}" ]]; then
    mode_note="客户端连接地址为 ${client_server}:443；SNI / Host 使用隧道域名 ${ARGO_DOMAIN}。"
  elif argo_is_named_tunnel; then
    tunnel_label="Cloudflare Named Tunnel"
    mode_note="客户端直接连接固定隧道域名 ${ARGO_DOMAIN}:443。"
  else
    tunnel_label="Cloudflare Quick Tunnel"
    mode_note="客户端直接连接当前 Quick Tunnel 域名 ${ARGO_DOMAIN}:443。"
  fi
  if [[ -n "${ARGO_EDGE_SERVER:-}" && -z "${tunnel_label:-}" ]]; then
    if argo_is_named_tunnel; then
      tunnel_label="Cloudflare Named Tunnel"
    else
      tunnel_label="Cloudflare Quick Tunnel"
    fi
  fi

  printf '%s\n' \
    "domain: $DOMAIN" \
    "tunnelMode: ${ARGO_TUNNEL_MODE:-quick}" \
    "cloudflareTunnel: ${tunnel_label}" \
    "tunnelHost: ${ARGO_DOMAIN}" \
    "clientServer: ${client_server}" \
    "edgeServer: ${ARGO_EDGE_SERVER:-none}" \
    "localPort: ${ARGO_LOCAL_PORT}" \
    "protocol: ${ARGO_PROTOCOL:-http2}" \
    "edgeIpVersion: ${ARGO_EDGE_IP_VERSION:-auto}" \
    "uuid: ${ARGO_UUID}" \
    "wsPath: ${ARGO_WS_PATH}" \
    "client: VLESS over WebSocket + TLS" \
    "note: ${mode_note}" \
    "" \
    "=== Argo VLESS-WS URI ===" \
    "$uri" > "$ARGO_SHARE_TXT"

  printf '%s\n' "$uri" > "$ARGO_SUB_RAW_TXT"
  base64 -w 0 < "$ARGO_SUB_RAW_TXT" > "$ARGO_SUB_B64_TXT"

  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -o "$ARGO_QR_PNG" -t PNG -s 8 -m 2 >/dev/null 2>&1 || true
  fi
}

# =============================================================================
# CDN+VMess+WS: 安装、URI 生成、分享文件
# =============================================================================

cdn_vmess_uri() {
  local client_port
  # 如果是 CF 标准 HTTP 端口，客户端直连该端口；否则客户端连 443 通过 Origin Rules 回源
  if cf_is_standard_http_port "$CDN_VMESS_PORT"; then
    client_port="$CDN_VMESS_PORT"
    # CF 标准 HTTP 端口不走 TLS
    printf 'vmess://%s' "$(echo -n '{"add":"'"${CDN_VMESS_CDN_DOMAIN}"'","aid":"0","host":"'"${CDN_VMESS_CDN_DOMAIN}"'","id":"'"${CDN_VMESS_UUID}"'","net":"ws","path":"'"${CDN_VMESS_WS_PATH}"'","port":"'"${client_port}"'","ps":"'"${NODE_NAME_CDN_VMESS}"'","type":"none","v":"2"}' | base64 -w 0)"
  else
    client_port="443"
    printf 'vmess://%s' "$(echo -n '{"add":"'"${CDN_VMESS_CDN_DOMAIN}"'","aid":"0","host":"'"${CDN_VMESS_CDN_DOMAIN}"'","id":"'"${CDN_VMESS_UUID}"'","net":"ws","path":"'"${CDN_VMESS_WS_PATH}"'","port":"'"${client_port}"'","ps":"'"${NODE_NAME_CDN_VMESS}"'","tls":"tls","sni":"'"${CDN_VMESS_CDN_DOMAIN}"'","fp":"chrome","type":"none","v":"2"}' | base64 -w 0)"
  fi
}

build_cdn_vmess_share_files() {
  local uri client_port
  ensure_node_info_dir
  uri="$(cdn_vmess_uri)"
  if cf_is_standard_http_port "$CDN_VMESS_PORT"; then
    client_port="$CDN_VMESS_PORT"
  else
    client_port="443"
  fi

  printf '%s\n' \
    "type: CDN+VMess+WS" \
    "cdnDomain: ${CDN_VMESS_CDN_DOMAIN}" \
    "clientPort: ${client_port}" \
    "originPort: ${CDN_VMESS_PORT} (VPS)" \
    "uuid: ${CDN_VMESS_UUID}" \
    "wsPath: ${CDN_VMESS_WS_PATH}" \
    "cfZone: ${CDN_VMESS_CF_ZONE_NAME:-unknown}" \
    "note: 客户端连接 ${CDN_VMESS_CDN_DOMAIN}:${client_port}，经 CF CDN 加速回源至 VPS:${CDN_VMESS_PORT}" \
    "" \
    "=== CDN VMess-WS URI ===" \
    "$uri" > "$CDN_VMESS_SHARE_TXT"

  printf '%s\n' "$uri" > "$CDN_VMESS_SUB_RAW_TXT"
  base64 -w 0 < "$CDN_VMESS_SUB_RAW_TXT" > "$CDN_VMESS_SUB_B64_TXT"

  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -o "$CDN_VMESS_QR_PNG" -t PNG -s 8 -m 2 >/dev/null 2>&1 || true
  fi
}

install_cdn_vmess_core() {
  local cdn_domain api_token input_port vps_ip port_mode need_origin_rule

  echo ""
  cyan "=== CDN+VMess+WS 节点安装 ==="
  echo "此模式通过 Cloudflare CDN 加速 VMess+WS 流量。"
  echo ""
  echo "端口模式说明："
  echo "  A) CF 标准 HTTP 端口 (80/8080/8880/2052/2082/2086/2095)"
  echo "     无需 Origin Rules，Token 只需 DNS 编辑权限即可"
  echo "     客户端直连 CDN域名:端口 → CF CDN → VPS:端口"
  echo ""
  echo "  B) 自定义端口 (需要 Origin Rules 权限)"
  echo "     客户端连 CDN域名:443 → CF Origin Rule 回源 → VPS:自定义端口"
  echo ""

  # 1. 选择端口模式
  read -r -p "请选择端口模式 [A=标准端口(推荐) / B=自定义端口]: " port_mode
  port_mode="$(printf '%s' "$port_mode" | tr '[:lower:]' '[:upper:]')"
  if [[ "$port_mode" != "B" ]]; then
    port_mode="A"
  fi

  # 2. 获取 CF API Token
  read -r -p "请输入 Cloudflare API Token: " api_token
  api_token="$(printf '%s' "$api_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$api_token" ]]; then
    red "API Token 不能为空。"
    return 1
  fi
  CF_API_TOKEN="$api_token"

  # 3. 获取 CDN 加速域名
  read -r -p "请输入 CDN 加速域名 (如 cdn.example.com): " cdn_domain
  cdn_domain="$(printf '%s' "$cdn_domain" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
  if [[ -z "$cdn_domain" ]]; then
    red "CDN 域名不能为空。"
    return 1
  fi

  # 4. 获取端口
  need_origin_rule="0"
  if [[ "$port_mode" == "A" ]]; then
    echo ""
    echo "可用的 CF 标准 HTTP 端口: 80, 8080, 8880, 2052, 2082, 2086, 2095"
    read -r -p "请选择端口 [默认 8880]: " input_port
    input_port="${input_port:-8880}"
    if ! cf_is_standard_http_port "$input_port"; then
      red "端口 ${input_port} 不是 CF 标准 HTTP 端口。"
      return 1
    fi
    CDN_VMESS_PORT="$input_port"
  else
    read -r -p "请输入 VPS 回源端口 (留空随机 50000-60000): " input_port
    if [[ -z "$input_port" ]]; then
      CDN_VMESS_PORT="$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)"
      echo "已自动分配回源端口: ${CDN_VMESS_PORT}"
    elif [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
      CDN_VMESS_PORT="$input_port"
    else
      red "端口无效。"
      return 1
    fi
    need_origin_rule="1"
  fi

  # 5. 检测 VPS 公网 IP
  vps_ip="$(detect_public_ipv4 2>/dev/null || true)"
  if [[ -z "$vps_ip" ]]; then
    read -r -p "未能自动检测 VPS IP，请手动输入: " vps_ip
    [[ -n "$vps_ip" ]] || { red "VPS IP 不能为空。"; return 1; }
  fi
  echo "VPS 公网 IP: ${vps_ip}"

  # 6. 生成 VMess 身份
  CDN_VMESS_UUID="${UUID:-$(generate_uuid_v4)}"
  CDN_VMESS_WS_PATH="/cdn-ws-$(openssl rand -hex 6)"
  CDN_VMESS_CDN_DOMAIN="$cdn_domain"
  CDN_VMESS_SERVER_ADDR="$vps_ip"
  CDN_VMESS_ORIGIN_PORT="$CDN_VMESS_PORT"

  # 7. 调用 CF API 配置
  echo ""
  if ! cf_configure_cdn_vmess "$cdn_domain" "$CDN_VMESS_PORT" "$vps_ip" "$need_origin_rule"; then
    red "Cloudflare CDN 配置失败。"
    return 1
  fi

  # 8. 安装 sing-box 并写入配置
  install_sing_box
  CDN_VMESS_ENABLED="1"
  write_sing_box_config || { red "sing-box 配置写入失败。"; return 1; }

  # 9. 构建分享文件
  build_cdn_vmess_share_files

  save_state

  local client_port
  if cf_is_standard_http_port "$CDN_VMESS_PORT"; then
    client_port="$CDN_VMESS_PORT"
    green "CDN+VMess+WS 节点安装成功！"
    echo ""
    echo "连接方式: 客户端 → ${cdn_domain}:${client_port} (HTTP) → CF CDN → VPS:${CDN_VMESS_PORT} (HTTP)"
  else
    client_port="443"
    green "CDN+VMess+WS 节点安装成功！"
    echo ""
    echo "连接方式: 客户端 → ${cdn_domain}:443 (TLS) → CF CDN (Origin Rule) → VPS:${CDN_VMESS_PORT} (HTTP)"
  fi
  echo ""
  echo "[CDN VMess-WS URI]"
  cdn_vmess_uri
  echo ""
  return 0
}

install_argo_core() {
  select_argo_edge_server
  install_sing_box
  install_cloudflared_binary
  normalize_argo_tunnel_state
  if [[ "${ARGO_TUNNEL_MODE:-quick}" == "named" && -z "${ARGO_TUNNEL_TOKEN:-}" ]]; then
    red "固定 Named Tunnel 缺少隧道 Token，请重新输入 Cloudflare API Token 自动配置。"
    return 1
  fi
  generate_argo_identity
  ARGO_ENABLED="1"
  write_sing_box_config
  write_argo_service
  systemctl daemon-reload
  systemctl enable "$ARGO_SERVICE" >/dev/null 2>&1 || true
  enable_argo_refresh_automation
  timeout 60 systemctl restart "$ARGO_SERVICE" || yellow "Argo 服务启动超时，将稍后重试。"

  if ! refresh_argo_domain; then
    if argo_is_named_tunnel; then
      yellow "cloudflared 已启动，但固定域名状态未写入；请检查 Tunnel Token。"
    else
      yellow "cloudflared 已启动，但暂未抓到 trycloudflare.com 域名；稍后可在节点信息里刷新查看。"
    fi
  fi

  build_argo_share_files "0" || true
}

apply_argo_tuning() {
  local protocol="$1" edge_ip_version="$2"

  require_root || return 1

  if ! load_state || ! has_argo_install; then
    red "未检测到 Argo 安装记录"
    return
  fi

  ARGO_PROTOCOL="$protocol"
  ARGO_EDGE_IP_VERSION="$edge_ip_version"
  normalize_argo_tuning
  ARGO_DOMAIN=""

  yellow "将切换 Argo: protocol=${ARGO_PROTOCOL}, edge-ip-version=${ARGO_EDGE_IP_VERSION}"
  if argo_is_named_tunnel; then
    yellow "固定 Named Tunnel 域名保持为：${ARGO_FIXED_DOMAIN}"
  else
    yellow "Quick Tunnel 重启后会换 trycloudflare.com 域名，客户端需要重新导入新节点。"
  fi

  if ! restart_argo_with_tuning "$protocol" "$edge_ip_version"; then
    yellow "cloudflared 已重启，但暂未抓到 trycloudflare.com 域名；稍后可再次查看节点信息。"
  fi
  build_argo_share_files "0" || true
  save_state
  refresh_subscription_service

  green "Argo 优选参数已切换"
  echo
  show_node_info
}

auto_tune_argo_core() {
  local refresh_sub="${1:-0}" best_edge="" best_ms="" best_protocol="" combo edge ip_label ms old_edge old_protocol protocol
  local combos=(
    "http2 auto"
    "http2 4"
    "http2 6"
    "quic auto"
    "quic 4"
    "quic 6"
  )

  if ! has_argo_install; then
    red "未检测到 Argo 安装记录"
    return 1
  fi

  normalize_argo_tuning
  old_protocol="$ARGO_PROTOCOL"
  old_edge="$ARGO_EDGE_IP_VERSION"

  yellow "开始自动优选 Argo。"
  if argo_is_named_tunnel; then
    yellow "脚本会逐个重启 Cloudflare Named Tunnel 测速，完成后自动保留最低延迟组合。"
  else
    yellow "脚本会逐个重启 Quick Tunnel 测速，完成后自动保留最低延迟组合。"
  fi
  yellow "测速只代表 VPS 到 Cloudflare Tunnel 这一段；客户端本地线路仍可能有差异。"
  echo

  for combo in "${combos[@]}"; do
    read -r protocol edge <<< "$combo"
    case "$edge" in
      4) ip_label="IPv4" ;;
      6) ip_label="IPv6" ;;
      *) ip_label="auto" ;;
    esac

    yellow "测试 ${protocol} + ${ip_label} ..."
    if ! restart_argo_with_tuning "$protocol" "$edge" 10; then
      yellow "  跳过：未获取到 trycloudflare.com 域名。"
      continue
    fi

    if ! wait_argo_https_reachable 6; then
      yellow "  跳过：HTTPS 暂未可达。"
      continue
    fi

    ms="$(measure_argo_latency_ms 2 || true)"
    if [[ -z "$ms" ]]; then
      yellow "  跳过：测速失败。"
      continue
    fi

    echo "  测得延迟：${ms} ms"
    if [[ -z "$best_ms" || "$ms" -lt "$best_ms" ]]; then
      best_ms="$ms"
      best_protocol="$protocol"
      best_edge="$edge"
    fi
  done

  echo
  if [[ -z "$best_ms" ]]; then
    red "自动优选失败：所有组合都未测出有效结果，恢复原参数。"
    restart_argo_with_tuning "$old_protocol" "$old_edge" 10 || true
    build_argo_share_files "0" || true
    save_state
    if [[ "$refresh_sub" == "1" ]]; then
      refresh_subscription_service
    fi
    return 1
  fi

  case "$best_edge" in
    4) ip_label="IPv4" ;;
    6) ip_label="IPv6" ;;
    *) ip_label="auto" ;;
  esac

  yellow "最佳组合：${best_protocol} + ${ip_label}，本轮最低 ${best_ms} ms。"
  if ! restart_argo_with_tuning "$best_protocol" "$best_edge"; then
    if argo_is_named_tunnel; then
      yellow "最佳组合已写入，但 cloudflared 重启可能尚未稳定；稍后可再次刷新节点信息。"
    else
      yellow "最佳组合已写入，但暂未抓到新域名；稍后可再次刷新节点信息。"
    fi
  fi

  build_argo_share_files "0" || true
  save_state
  if [[ "$refresh_sub" == "1" ]]; then
    refresh_subscription_service
  fi

  green "Argo 参数测试完成"
  return 0
}

argo_subscription_needs_refresh() {
  if [[ -z "${ARGO_DOMAIN:-}" ]]; then
    return 1
  fi

  if [[ ! -s "$ARGO_SUB_RAW_TXT" ]] || ! grep -Fq "$ARGO_DOMAIN" "$ARGO_SUB_RAW_TXT"; then
    return 0
  fi

  if [[ ! -s "$COMBO_SUB_RAW_TXT" ]] || ! grep -Fq "$ARGO_DOMAIN" "$COMBO_SUB_RAW_TXT"; then
    return 0
  fi

  if has_subscription_service; then
    if [[ ! -s "$SUB_URI_RAW_TXT" ]] || ! grep -Fq "$ARGO_DOMAIN" "$SUB_URI_RAW_TXT"; then
      return 0
    fi
    if [[ ! -s "$SUB_CLASH_YAML" ]] || ! grep -Fq "$ARGO_DOMAIN" "$SUB_CLASH_YAML"; then
      return 0
    fi
  fi

  return 1
}

clear_stale_argo_share_files() {
  ARGO_DOMAIN=""
  rm -f "$ARGO_SHARE_TXT" "$ARGO_SUB_RAW_TXT" "$ARGO_SUB_B64_TXT" "$ARGO_QR_PNG"
}

refresh_argo_subscription_once() {
  local domain_attempts="45" mode="${1:-manual}" old_domain="" saved_argo_enabled=""

  require_root || return 1

  if ! load_state || ! has_argo_install; then
    if [[ "$mode" == "manual" ]]; then
      yellow "未检测到 Argo 安装记录，已跳过刷新。"
    fi
    return 0
  fi

  normalize_argo_tuning
  old_domain="${ARGO_DOMAIN:-}"

  if [[ "$mode" == "manual" ]]; then
    install_self_script || true
    if [[ ! -f "/etc/systemd/system/${ARGO_SERVICE}" ]]; then
      write_argo_service
      systemctl daemon-reload
    fi
    systemctl enable "$ARGO_SERVICE" >/dev/null 2>&1 || true
    enable_argo_refresh_automation
    if ! systemctl is-active --quiet "$ARGO_SERVICE"; then
      timeout 60 systemctl restart "$ARGO_SERVICE" >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$mode" == "request" ]]; then
    domain_attempts="3"
  elif [[ "$mode" == "systemd" || "$mode" == "subscription-prestart" ]]; then
    domain_attempts="60"
  fi

  if ! refresh_argo_domain "$domain_attempts"; then
    if [[ "$mode" == "manual" ]]; then
      yellow "暂未获取到新的 trycloudflare.com 域名，稍后 cloudflared 启动稳定后会再刷新。"
    else
      ARGO_SKIP_SERVICE_ENSURE="1"
      clear_stale_argo_share_files
      save_state
      saved_argo_enabled="${ARGO_ENABLED:-0}"
      ARGO_ENABLED="0"
      build_subscription_payload_files || true
      build_combined_subscription_files || true
      if [[ "$mode" != "subscription-prestart" && "$mode" != "request" ]]; then
        systemctl restart "$SUB_SERVICE" >/dev/null 2>&1 || true
      fi
      ARGO_ENABLED="$saved_argo_enabled"
      ARGO_SKIP_SERVICE_ENSURE="0"
    fi
    return 0
  fi

  if [[ "$mode" != "manual" && "$old_domain" == "$ARGO_DOMAIN" ]] && ! argo_subscription_needs_refresh; then
    return 0
  fi

  ARGO_SKIP_SERVICE_ENSURE="1"
  build_argo_share_files "0" || true
  save_state

  if [[ "$mode" == "subscription-prestart" || "$mode" == "request" ]]; then
    build_subscription_payload_files || true
  else
    refresh_subscription_service || true
  fi
  build_combined_subscription_files || true
  ARGO_SKIP_SERVICE_ENSURE="0"

  if [[ "$mode" == "manual" ]]; then
    if [[ -n "$old_domain" && "$old_domain" != "$ARGO_DOMAIN" ]]; then
      yellow "Argo 临时域名已更新：${old_domain} -> ${ARGO_DOMAIN}"
    fi
    green "Argo 域名和订阅已刷新。"
  fi
}

build_combined_subscription_files() {
  ensure_node_info_dir
  if ! write_uri_subscription_raw "$COMBO_SUB_RAW_TXT"; then
    rm -f "$COMBO_SUB_RAW_TXT" "$COMBO_SUB_B64_TXT"
    return 1
  fi

  base64 -w 0 < "$COMBO_SUB_RAW_TXT" > "$COMBO_SUB_B64_TXT"
  if has_subscription_service; then
    build_subscription_payload_files || true
  fi
}

install_hysteria2_core() {
  if [[ "${SELF_SIGN_CERT:-0}" != "1" ]] && { ! cert_matches_domain || ! cert_is_currently_valid; }; then
    red "当前域名证书不可用，请先执行菜单 2 修复证书。"
    return 1
  fi

  if [[ -n "${HY2_PORT:-}" || -n "${HY2_PORT_RANGE:-}" ]]; then
    clear_hy2_port_hopping_rules
  fi

  install_hysteria2_binary
  resolve_hy2_server_addr
  prompt_hy2_port_range
  generate_hy2_password
  HY2_ENABLED="1"
  write_hysteria2_config
  apply_hy2_port_hopping_rules
  build_hysteria2_share_files
  return 0
}

# =============================================================================
# subscription.sh merged below
# =============================================================================

write_uri_subscription_raw() {
  local out_file="$1" saved_index="${ARGO_EDGE_INDEX:-0}"

  : > "$out_file"

  # Reset round-robin so subscription output starts from first domain
  ARGO_EDGE_INDEX=0
  if [[ "${ARGO_MULTI_EDGE:-0}" == "1" && "${#ARGO_EDGE_SERVERS[@]}" -gt 0 ]]; then
    ARGO_EDGE_SERVER="${ARGO_EDGE_SERVERS[0]}"
  fi

  if has_vless_install; then
    cycle_argo_edge_server
    build_client_files
    if [[ -f "$SUB_RAW_TXT" ]]; then
      sed '/^[[:space:]]*$/d' "$SUB_RAW_TXT" >> "$out_file"
    fi
  fi

  if has_hy2_install; then
    cycle_argo_edge_server
    build_hysteria2_share_files
    if [[ -f "$HY2_SUB_RAW_TXT" ]]; then
      sed '/^[[:space:]]*$/d' "$HY2_SUB_RAW_TXT" >> "$out_file"
    fi
  fi

  if has_anytls_install; then
    cycle_argo_edge_server
    build_anytls_share_files
    if [[ -f "$ANYTLS_SUB_RAW_TXT" ]]; then
      sed '/^[[:space:]]*$/d' "$ANYTLS_SUB_RAW_TXT" >> "$out_file"
    else
      anytls_uri >> "$out_file"
      printf '\n' >> "$out_file"
    fi
  fi

  if has_ss2022_install; then
    cycle_argo_edge_server
    build_ss2022_share_files
    if [[ -f "$SS2022_SUB_RAW_TXT" ]]; then
      sed '/^[[:space:]]*$/d' "$SS2022_SUB_RAW_TXT" >> "$out_file"
    else
      ss2022_uri >> "$out_file"
      printf '\n' >> "$out_file"
    fi
  fi

  if has_vmess_install; then
    cycle_argo_edge_server
    build_vmess_share_files
    if [[ -f /etc/sing-box/node-info/vmess-subscription-raw.txt ]]; then
      sed '/^[[:space:]]*$/d' /etc/sing-box/node-info/vmess-subscription-raw.txt >> "$out_file"
    else
      vmess_uri >> "$out_file"
      printf '\n' >> "$out_file"
    fi
  fi

  if has_tuic_install; then
    cycle_argo_edge_server
    build_tuic_share_files
    if [[ -f /etc/sing-box/node-info/tuic5-subscription-raw.txt ]]; then
      sed '/^[[:space:]]*$/d' /etc/sing-box/node-info/tuic5-subscription-raw.txt >> "$out_file"
    else
      tuic_uri >> "$out_file"
      printf "\n" >> "$out_file"
    fi
  fi

  if has_argo_install; then
    ensure_argo_quick_service
    resolve_argo_domain "0" || true
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
      build_argo_share_files "0" || true
      if [[ -f "$ARGO_SUB_RAW_TXT" ]]; then
        sed '/^[[:space:]]*$/d' "$ARGO_SUB_RAW_TXT" >> "$out_file"
      else
        argo_uri >> "$out_file"
        printf '\n' >> "$out_file"
      fi
    fi
  fi

  if has_cdn_vmess_install; then
    build_cdn_vmess_share_files
    if [[ -f "$CDN_VMESS_SUB_RAW_TXT" ]]; then
      sed '/^[[:space:]]*$/d' "$CDN_VMESS_SUB_RAW_TXT" >> "$out_file"
    else
      cdn_vmess_uri >> "$out_file"
      printf '\n' >> "$out_file"
    fi
  fi

  [[ -s "$out_file" ]]
  ARGO_EDGE_INDEX="$saved_index"
}

append_clash_proxy_names() {
  local name
  for name in "$@"; do
    printf '      - %s\n' "$(yaml_quote "$name")" >> "$SUB_CLASH_YAML"
  done
}

append_clash_stable_proxy_names() {
  local name
  for name in "$@"; do
    printf '      - %s\n' "$(yaml_quote "$name")" >> "$SUB_CLASH_STABLE_YAML"
  done
}

build_subscription_clash_yaml() {
  local proxies=()
  local argo_server name vless_server vless_sni vmess_host vmess_port vmess_server vmess_sni

  mkdir -p "$SUBSCRIPTION_DIR"

  printf '%s\n' \
    "mixed-port: 7890" \
    "allow-lan: false" \
    "mode: rule" \
    "log-level: info" \
    "ipv6: false" \
    "" \
    "dns:" \
    "  enable: true" \
    "  ipv6: false" \
    "  enhanced-mode: fake-ip" \
    "  default-nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "  nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "  proxy-server-nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "" \
    "proxies:" > "$SUB_CLASH_YAML"

  if has_vless_install; then
    name="$NODE_NAME_VLESS"
    proxies+=("$name")
    vless_server="${VLESS_SERVER_ADDR:-$(preferred_direct_server_addr || printf '%s\n' "${DOMAIN:-127.0.0.1}")}"
    VLESS_SERVER_ADDR="$vless_server"
    vless_sni="${REALITY_SNI:-${SNI_VAL:-${HANDSHAKE_SERVER:-www.apple.com}}}"
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: vless" \
      "    server: $(yaml_quote "$vless_server")" \
      "    port: ${VLESS_PORT:-443}" \
      "    uuid: $(yaml_quote "$UUID")" \
      "    encryption: \"\"" \
      "    flow: xtls-rprx-vision" \
      "    network: tcp" \
      "    tls: true" \
      "    udp: true" \
      "    ip-version: ipv4-prefer" \
      "    packet-encoding: xudp" \
      "    servername: $(yaml_quote "$vless_sni")" \
      "    client-fingerprint: chrome" \
      "    reality-opts:" \
      "      public-key: $(yaml_quote "$PUBLIC_KEY")" \
      "      short-id: $(yaml_quote "$SHORT_ID")" >> "$SUB_CLASH_YAML"
  fi

  if has_hy2_install; then
    name="$NODE_NAME_HY2"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: hysteria2" \
      "    server: $(yaml_quote "$HY2_SERVER_ADDR")" \
      "    port: ${HY2_PORT}" \
      "    password: $(yaml_quote "$HY2_PASSWORD")" \
      "    up: $(yaml_quote "${HY2_CLIENT_UP_MBPS} Mbps")" \
      "    down: $(yaml_quote "${HY2_CLIENT_DOWN_MBPS} Mbps")" \
      "    sni: $(yaml_quote "$HY2_TLS_SNI")" \
      "    skip-cert-verify: $(tls_skip_verify_bool)" \
      "    udp: true" \
      "    ip-version: ipv4-prefer" \
      "    alpn:" \
      "      - h3" >> "$SUB_CLASH_YAML"
    if [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]]; then
      printf '%s\n' \
        "    obfs: salamander" \
        "    obfs-password: $(yaml_quote "$HY2_OBFS_PASSWORD")" >> "$SUB_CLASH_YAML"
    fi
  fi

  if has_anytls_install; then
    name="$NODE_NAME_ANYTLS"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: anytls" \
      "    server: $(yaml_quote "$ANYTLS_SERVER_ADDR")" \
      "    port: ${ANYTLS_PORT}" \
      "    password: $(yaml_quote "$ANYTLS_PASSWORD")" \
      "    client-fingerprint: chrome" \
      "    udp: true" \
      "    sni: $(yaml_quote "$ANYTLS_TLS_SNI")" \
      "    alpn:" \
      "      - h2" \
      "      - http/1.1" \
      "    skip-cert-verify: ${SELF_SIGN_CERT:-1}" >> "$SUB_CLASH_YAML"
  fi

  if has_ss2022_install; then
    name="$NODE_NAME_SS2022"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: ss" \
      "    server: $(yaml_quote "$SS2022_SERVER_ADDR")" \
      "    port: ${SS2022_PORT}" \
      "    cipher: $(yaml_quote "$SS2022_CIPHER")" \
      "    password: $(yaml_quote "$SS2022_PASSWORD")" \
      "    udp: true" \
      "    tfo: true" \
      "    ip-version: ipv4-prefer" >> "$SUB_CLASH_YAML"
  fi

  if has_vmess_install; then
    name="$NODE_NAME_VMESS"
    proxies+=("$name")
    vmess_server="$(vmess_public_addr)"
    vmess_port="$(vmess_public_port)"
    if vmess_public_tls_enabled; then
      vmess_sni="$(vmess_public_sni)"
      vmess_host="$vmess_sni"
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$vmess_server")" \
        "    port: ${vmess_port}" \
        "    uuid: $(yaml_quote "$VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: true" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    servername: $(yaml_quote "$vmess_sni")" \
        "    client-fingerprint: chrome" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$VMESS_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$vmess_host")" >> "$SUB_CLASH_YAML"
    else
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$vmess_server")" \
        "    port: ${vmess_port}" \
        "    uuid: $(yaml_quote "$VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$VMESS_WS_PATH")" >> "$SUB_CLASH_YAML"
    fi
  fi
  if has_argo_install; then
    ensure_argo_quick_service
    resolve_argo_domain "0" || true
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
      argo_server="$(argo_client_server)"
      name="$NODE_NAME_ARGO"
      proxies+=("$name")
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vless" \
        "    server: $(yaml_quote "$argo_server")" \
        "    port: 443" \
        "    uuid: $(yaml_quote "$ARGO_UUID")" \
        "    encryption: \"\"" \
        "    network: ws" \
        "    tls: true" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    servername: $(yaml_quote "$ARGO_DOMAIN")" \
        "    client-fingerprint: $(yaml_quote "$ARGO_CLIENT_FINGERPRINT")" \
        "    skip-cert-verify: false" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$ARGO_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$ARGO_DOMAIN")" >> "$SUB_CLASH_YAML"
    fi
  fi

  if has_cdn_vmess_install; then
    name="$NODE_NAME_CDN_VMESS"
    proxies+=("$name")
    if cf_is_standard_http_port "$CDN_VMESS_PORT"; then
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" \
        "    port: ${CDN_VMESS_PORT}" \
        "    uuid: $(yaml_quote "$CDN_VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: false" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$CDN_VMESS_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" >> "$SUB_CLASH_YAML"
    else
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" \
        "    port: 443" \
        "    uuid: $(yaml_quote "$CDN_VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: true" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    servername: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" \
        "    client-fingerprint: chrome" \
        "    skip-cert-verify: false" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$CDN_VMESS_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" >> "$SUB_CLASH_YAML"
    fi
  fi

  if [[ "${#proxies[@]}" -eq 0 ]]; then
    rm -f "$SUB_CLASH_YAML"
    return 1
  fi

  printf '%s\n' \
    "" \
    "proxy-groups:" \
    "  - name: PROXY" \
    "    type: select" \
    "    proxies:" >> "$SUB_CLASH_YAML"

  append_clash_proxy_names "${proxies[@]}"

  printf '%s\n' \
    "      - DIRECT" \
    "" \
    "rules:" \
    "  - GEOIP,CN,DIRECT" \
    "  - MATCH,PROXY" >> "$SUB_CLASH_YAML"
}

build_subscription_clash_stable_yaml() {
  local proxies=()
  local argo_server name vless_server vless_sni vmess_host vmess_port vmess_server vmess_sni

  mkdir -p "$SUBSCRIPTION_DIR"
  rm -f "$SUB_CLASH_STABLE_YAML"

  printf '%s\n' \
    "mixed-port: 7890" \
    "allow-lan: false" \
    "mode: rule" \
    "log-level: info" \
    "ipv6: false" \
    "" \
    "dns:" \
    "  enable: true" \
    "  ipv6: false" \
    "  enhanced-mode: fake-ip" \
    "  default-nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "  nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "  proxy-server-nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "" \
    "proxies:" > "$SUB_CLASH_STABLE_YAML"

  if has_vless_install; then
    name="$NODE_NAME_VLESS"
    proxies+=("$name")
    vless_server="${VLESS_SERVER_ADDR:-$(preferred_direct_server_addr || printf '%s\n' "${DOMAIN:-127.0.0.1}")}"
    VLESS_SERVER_ADDR="$vless_server"
    vless_sni="${REALITY_SNI:-${SNI_VAL:-${HANDSHAKE_SERVER:-www.apple.com}}}"
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: vless" \
      "    server: $(yaml_quote "$vless_server")" \
      "    port: ${VLESS_PORT:-443}" \
      "    uuid: $(yaml_quote "$UUID")" \
      "    encryption: \"\"" \
      "    flow: xtls-rprx-vision" \
      "    network: tcp" \
      "    tls: true" \
      "    udp: true" \
      "    ip-version: ipv4-prefer" \
      "    packet-encoding: xudp" \
      "    servername: $(yaml_quote "$vless_sni")" \
      "    client-fingerprint: chrome" \
      "    reality-opts:" \
      "      public-key: $(yaml_quote "$PUBLIC_KEY")" \
      "      short-id: $(yaml_quote "$SHORT_ID")" >> "$SUB_CLASH_STABLE_YAML"
  fi

  if has_hy2_install; then
    name="$NODE_NAME_HY2"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: hysteria2" \
      "    server: $(yaml_quote "$HY2_SERVER_ADDR")" \
      "    port: ${HY2_PORT}" \
      "    password: $(yaml_quote "$HY2_PASSWORD")" \
      "    up: $(yaml_quote "${HY2_CLIENT_UP_MBPS} Mbps")" \
      "    down: $(yaml_quote "${HY2_CLIENT_DOWN_MBPS} Mbps")" \
      "    sni: $(yaml_quote "$HY2_TLS_SNI")" \
      "    skip-cert-verify: $(tls_skip_verify_bool)" \
      "    udp: true" \
      "    ip-version: ipv4-prefer" \
      "    alpn:" \
      "      - h3" >> "$SUB_CLASH_STABLE_YAML"
    if [[ "${HY2_OBFS_ENABLED:-0}" == "1" ]]; then
      printf '%s\n' \
        "    obfs: salamander" \
        "    obfs-password: $(yaml_quote "$HY2_OBFS_PASSWORD")" >> "$SUB_CLASH_STABLE_YAML"
    fi
  fi

  if has_anytls_install; then
    name="$NODE_NAME_ANYTLS"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: anytls" \
      "    server: $(yaml_quote "$ANYTLS_SERVER_ADDR")" \
      "    port: ${ANYTLS_PORT}" \
      "    password: $(yaml_quote "$ANYTLS_PASSWORD")" \
      "    client-fingerprint: chrome" \
      "    udp: true" \
      "    sni: $(yaml_quote "$ANYTLS_TLS_SNI")" \
      "    alpn:" \
      "      - h2" \
      "      - http/1.1" \
      "    skip-cert-verify: ${SELF_SIGN_CERT:-1}" >> "$SUB_CLASH_STABLE_YAML"
  fi

  if has_ss2022_install; then
    name="$NODE_NAME_SS2022"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: ss" \
      "    server: $(yaml_quote "$SS2022_SERVER_ADDR")" \
      "    port: ${SS2022_PORT}" \
      "    cipher: $(yaml_quote "$SS2022_CIPHER")" \
      "    password: $(yaml_quote "$SS2022_PASSWORD")" \
      "    udp: true" \
      "    tfo: true" \
      "    ip-version: ipv4-prefer" >> "$SUB_CLASH_STABLE_YAML"
  fi

  if has_vmess_install; then
    name="$NODE_NAME_VMESS"
    proxies+=("$name")
    vmess_server="$(vmess_public_addr)"
    vmess_port="$(vmess_public_port)"
    if vmess_public_tls_enabled; then
      vmess_sni="$(vmess_public_sni)"
      vmess_host="$vmess_sni"
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$vmess_server")" \
        "    port: ${vmess_port}" \
        "    uuid: $(yaml_quote "$VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: true" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    servername: $(yaml_quote "$vmess_sni")" \
        "    client-fingerprint: chrome" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$VMESS_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$vmess_host")" >> "$SUB_CLASH_STABLE_YAML"
    else
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$vmess_server")" \
        "    port: ${vmess_port}" \
        "    uuid: $(yaml_quote "$VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: false" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$VMESS_WS_PATH")" >> "$SUB_CLASH_STABLE_YAML"
    fi
  fi

  if has_tuic_install; then
    name="$NODE_NAME_TUIC"
    proxies+=("$name")
    printf '%s\n' \
      "  - name: $(yaml_quote "$name")" \
      "    type: tuic" \
      "    server: $(yaml_quote "$TUIC_SERVER_ADDR")" \
      "    port: ${TUIC_PORT}" \
      "    uuid: $(yaml_quote "$TUIC_UUID")" \
      "    password: $(yaml_quote "$TUIC_PASSWORD")" \
      "    congestion-controller: bbr" \
      "    udp-relay-mode: native" \
      "    udp: true" \
      "    ip-version: ipv4-prefer" \
      "    sni: $(yaml_quote "$TUIC_TLS_SNI")" \
      "    skip-cert-verify: ${SELF_SIGN_CERT:-1}" \
      "    alpn:" \
      "      - h3" >> "$SUB_CLASH_STABLE_YAML"
  fi

  if has_argo_install; then
    ensure_argo_quick_service
    resolve_argo_domain "0" || true
    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
      argo_server="$(argo_client_server)"
      name="$NODE_NAME_ARGO"
      proxies+=("$name")
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vless" \
        "    server: $(yaml_quote "$argo_server")" \
        "    port: 443" \
        "    uuid: $(yaml_quote "$ARGO_UUID")" \
        "    encryption: \"\"" \
        "    network: ws" \
        "    tls: true" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    servername: $(yaml_quote "$ARGO_DOMAIN")" \
        "    client-fingerprint: $(yaml_quote "$ARGO_CLIENT_FINGERPRINT")" \
        "    skip-cert-verify: false" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$ARGO_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$ARGO_DOMAIN")" >> "$SUB_CLASH_STABLE_YAML"
    fi
  fi

  if has_cdn_vmess_install; then
    name="$NODE_NAME_CDN_VMESS"
    proxies+=("$name")
    if cf_is_standard_http_port "$CDN_VMESS_PORT"; then
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" \
        "    port: ${CDN_VMESS_PORT}" \
        "    uuid: $(yaml_quote "$CDN_VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: false" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$CDN_VMESS_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" >> "$SUB_CLASH_STABLE_YAML"
    else
      printf '%s\n' \
        "  - name: $(yaml_quote "$name")" \
        "    type: vmess" \
        "    server: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" \
        "    port: 443" \
        "    uuid: $(yaml_quote "$CDN_VMESS_UUID")" \
        "    alterId: 0" \
        "    cipher: auto" \
        "    network: ws" \
        "    tls: true" \
        "    udp: true" \
        "    ip-version: ipv4-prefer" \
        "    servername: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" \
        "    client-fingerprint: chrome" \
        "    skip-cert-verify: false" \
        "    ws-opts:" \
        "      path: $(yaml_quote "$CDN_VMESS_WS_PATH")" \
        "      headers:" \
        "        Host: $(yaml_quote "$CDN_VMESS_CDN_DOMAIN")" >> "$SUB_CLASH_STABLE_YAML"
    fi
  fi

  if [[ "${#proxies[@]}" -eq 0 ]]; then
    rm -f "$SUB_CLASH_STABLE_YAML"
    return 1
  fi

  printf '%s\n' \
    "" \
    "proxy-groups:" \
    "  - name: PROXY" \
    "    type: select" \
    "    proxies:" >> "$SUB_CLASH_STABLE_YAML"

  append_clash_stable_proxy_names "${proxies[@]}"

  printf '%s\n' \
    "      - DIRECT" \
    "" \
    "rules:" \
    "  - GEOIP,CN,DIRECT" \
    "  - MATCH,PROXY" >> "$SUB_CLASH_STABLE_YAML"
}
build_subscription_index_html() {
  local url
  url="$(subscription_url)"

  printf '%s\n' \
    "<!doctype html>" \
    "<html lang=\"zh-CN\">" \
    "<head>" \
    "  <meta charset=\"utf-8\">" \
    "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
    "  <title>${APP_NAME} subscription</title>" \
    "  <style>" \
    "    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f7f7f8;color:#18181b}" \
    "    main{max-width:760px;margin:8vh auto;padding:0 20px}" \
    "    h1{font-size:28px;margin:0 0 10px}" \
    "    p{line-height:1.7;color:#52525b}" \
    "    a{display:block;margin:10px 0;padding:12px 14px;background:#fff;border:1px solid #e4e4e7;border-radius:8px;color:#18181b;text-decoration:none}" \
    "    code{word-break:break-all;background:#fff;border:1px solid #e4e4e7;border-radius:6px;padding:2px 6px}" \
    "  </style>" \
    "</head>" \
    "<body>" \
    "  <main>" \
    "    <h1>${APP_NAME}</h1>" \
    "    <p>主订阅链接会按客户端 User-Agent 自动返回 Clash / mihomo 全量 YAML、通用 Base64 URI 或浏览器页面。</p>" \
    "    <p><code>${url}</code></p>" \
    "    <a href=\"${url}?target=clash-full\">Clash YAML</a>" \
    "    <a href=\"${url}?target=mihomo\">mihomo YAML</a>" \
    "    <a href=\"${url}?target=shadowrocket-full\">Shadowrocket Base64</a>" \
    "    <a href=\"${url}?target=v2rayn\">v2rayN / Base64 URI</a>" \
    "    <a href=\"${url}?target=raw\">Raw URI</a>" \
    "    <a href=\"${url}/all\">All / 所有协议 URI（v2rayN 格式）</a>" \
    "  </main>" \
    "</body>" \
    "</html>" > "$SUB_INDEX_HTML"
}

write_subscription_server_script() {
  printf '%s\n' \
    '#!/usr/bin/env python3' \
    'import argparse' \
    'import http.server' \
    'import pathlib' \
    'import socket' \
    'import subprocess' \
    'import ssl' \
    'import threading' \
    'import time' \
    'import urllib.parse' \
    '' \
    '' \
    'TARGETS = {' \
    '    "clash": ("clash.yaml", "text/yaml; charset=utf-8"),' \
    '    "clash-verge": ("clash.yaml", "text/yaml; charset=utf-8"),' \
    '    "clash-compatible": ("clash.yaml", "text/yaml; charset=utf-8"),' \
    '    "clash-full": ("clash.yaml", "text/yaml; charset=utf-8"),' \
    '    "mihomo": ("clash.yaml", "text/yaml; charset=utf-8"),' \
    '    "stash": ("clash.yaml", "text/yaml; charset=utf-8"),' \
    '    "stable": ("clash-stable.yaml", "text/yaml; charset=utf-8"),' \
    '    "clash-stable": ("clash-stable.yaml", "text/yaml; charset=utf-8"),' \
    '    "mihomo-stable": ("clash-stable.yaml", "text/yaml; charset=utf-8"),' \
    '    "raw": ("raw.txt", "text/plain; charset=utf-8"),' \
    '    "all": ("raw.txt", "text/plain; charset=utf-8"),' \
    '    "base64": ("base64.txt", "text/plain; charset=utf-8"),' \
    '    "v2rayn": ("base64.txt", "text/plain; charset=utf-8"),' \
    '    "shadowrocket": ("base64.txt", "text/plain; charset=utf-8"),' \
    '    "shadowrocket-full": ("base64.txt", "text/plain; charset=utf-8"),' \
    '    "html": ("index.html", "text/html; charset=utf-8"),' \
    '}' \
    '' \
    'MIHOMO_UA = ("mihomo", "meta")' \
    'CLASH_UA = ("clash", "stash", "verge", "flclash")' \
    'SHADOWROCKET_UA = ("shadowrocket",)' \
    'BASE64_UA = ("v2ray", "v2rayn", "streisand", "nekobox", "hiddify")' \
    'BROWSER_UA = ("mozilla", "chrome", "safari", "firefox", "edge", "edg/", "opera")' \
    '' \
    '' \
    'class DualStackThreadingHTTPServer(http.server.ThreadingHTTPServer):' \
    '    address_family = socket.AF_INET6' \
    '' \
    '    def server_bind(self):' \
    '        if hasattr(socket, "IPV6_V6ONLY"):' \
    '            try:' \
    '                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)' \
    '            except OSError:' \
    '                pass' \
    '        super().server_bind()' \
    '' \
    '' \
    'class SubscriptionHandler(http.server.BaseHTTPRequestHandler):' \
    '    root = pathlib.Path(".")' \
    '    sub_path = ""' \
    '    refresh_script = ""' \
    '    refresh_ttl = 10' \
    '    last_refresh = 0.0' \
    '    refresh_lock = threading.Lock()' \
    '' \
    '    def log_message(self, fmt, *args):' \
    '        return' \
    '' \
    '    def do_GET(self):' \
    '        parsed = urllib.parse.urlsplit(self.path)' \
    '        normalized_path = parsed.path.strip("/")' \
    '        is_all = normalized_path.endswith("/all") and normalized_path[:normalized_path.rfind("/")] == self.sub_path' \
    '        if normalized_path != self.sub_path and not is_all:' \
    '            self.send_error(404)' \
    '            return' \
    '' \
    '        self.refresh_payload()' \
    '' \
    '        query = urllib.parse.parse_qs(parsed.query)' \
    '        target = (query.get("target", [""])[0] or "").lower()' \
    '        if is_all:' \
    '            filename, content_type = TARGETS["raw"]' \
    '        elif not target:' \
    '            target = self.detect_target()' \
    '            filename, content_type = TARGETS.get(target, TARGETS["base64"])' \
    '        else:' \
    '            filename, content_type = TARGETS.get(target, TARGETS["base64"])' \
    '        file_path = self.root / filename' \
    '        if target in ("clash", "clash-verge", "clash-compatible") and not file_path.is_file():' \
    '            filename, content_type = TARGETS["clash-full"]' \
    '            file_path = self.root / filename' \
    '        if not file_path.is_file():' \
    '            self.send_error(404)' \
    '            return' \
    '' \
    '        data = file_path.read_bytes()' \
    '        self.send_response(200)' \
    '        self.send_header("Content-Type", content_type)' \
    '        self.send_header("Cache-Control", "no-store")' \
    '        self.send_header("Content-Length", str(len(data)))' \
    '        self.end_headers()' \
    '        self.wfile.write(data)' \
    '' \
    '    def refresh_payload(self):' \
    '        if not self.refresh_script:' \
    '            return' \
    '' \
    '        now = time.monotonic()' \
    '        with self.refresh_lock:' \
    '            if now - self.last_refresh < self.refresh_ttl:' \
    '                return' \
    '            self.last_refresh = now' \
    '            try:' \
    '                subprocess.run(' \
    '                    ["/bin/bash", self.refresh_script, "--refresh-argo-subscription", "request"],' \
    '                    stdout=subprocess.DEVNULL,' \
    '                    stderr=subprocess.DEVNULL,' \
    '                    timeout=10,' \
    '                    check=False,' \
    '                )' \
    '            except Exception:' \
    '                return' \
    '' \
    '    def detect_target(self):' \
    '        ua = self.headers.get("User-Agent", "").lower()' \
    '        if any(item in ua for item in MIHOMO_UA):' \
    '            return "mihomo"' \
    '        if any(item in ua for item in CLASH_UA):' \
    '            return "clash"' \
    '        if any(item in ua for item in SHADOWROCKET_UA):' \
    '            return "shadowrocket-full"' \
    '        if any(item in ua for item in BASE64_UA):' \
    '            return "base64"' \
    '        if any(item in ua for item in BROWSER_UA):' \
    '            return "html"' \
    '        return "base64"' \
    '' \
    '' \
    'def make_http_server(host, port):' \
    '    if ":" in host:' \
    '        try:' \
    '            return DualStackThreadingHTTPServer((host, port), SubscriptionHandler)' \
    '        except OSError:' \
    '            if host == "::":' \
    '                return http.server.ThreadingHTTPServer(("0.0.0.0", port), SubscriptionHandler)' \
    '            raise' \
    '    return http.server.ThreadingHTTPServer((host, port), SubscriptionHandler)' \
    '' \
    '' \
    'def main():' \
    '    parser = argparse.ArgumentParser()' \
    '    parser.add_argument("--host", default="::")' \
    '    parser.add_argument("--port", type=int, required=True)' \
    '    parser.add_argument("--path", required=True)' \
    '    parser.add_argument("--dir", required=True)' \
    '    parser.add_argument("--cert", required=True)' \
    '    parser.add_argument("--key", required=True)' \
    '    parser.add_argument("--no-tls", action="store_true", default=False)' \
    '    parser.add_argument("--refresh-script", default="")' \
    '    parser.add_argument("--refresh-ttl", type=int, default=10)' \
    '    args = parser.parse_args()' \
    '' \
    '    SubscriptionHandler.root = pathlib.Path(args.dir)' \
    '    SubscriptionHandler.sub_path = args.path.strip("/")' \
    '    SubscriptionHandler.refresh_script = args.refresh_script' \
    '    SubscriptionHandler.refresh_ttl = max(args.refresh_ttl, 0)' \
    '' \
    '    httpd = make_http_server(args.host, args.port)' \
    '    if not args.no_tls:' \
    '        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)' \
    '        context.load_cert_chain(args.cert, args.key)' \
    '        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)' \
    '    httpd.serve_forever()' \
    '' \
    '' \
    'if __name__ == "__main__":' \
    '    main()' > "$SUB_SERVER_SCRIPT"

  chmod 0755 "$SUB_SERVER_SCRIPT"
}

write_subscription_service() {
  local argo_after="" argo_prestart="" argo_wants="" refresh_args="" tls_flag=""

  if [[ "${SELF_SIGN_CERT:-0}" == "1" ]]; then
    tls_flag=" --no-tls"
  fi

  if has_argo_install; then
    install_self_script || true
    argo_after=" ${ARGO_SERVICE}"
    argo_wants=" ${ARGO_SERVICE}"
    argo_prestart="ExecStartPre=-/bin/bash ${INSTALL_SCRIPT} --refresh-argo-subscription request"
    refresh_args=" --refresh-script ${INSTALL_SCRIPT} --refresh-ttl 15"
  fi

  printf '%s\n' \
    "[Unit]" \
    "Description=${APP_NAME} smart subscription service" \
    "After=network-online.target${argo_after}" \
    "Wants=network-online.target${argo_wants}" \
    "" \
    "[Service]" \
    "Type=simple" \
    "${argo_prestart}" \
    "ExecStart=/usr/bin/python3 ${SUB_SERVER_SCRIPT} --host :: --port ${SUB_PORT} --path ${SUB_PATH} --dir ${SUBSCRIPTION_DIR} --cert ${SSL_DIR}/fullchain.cer --key ${SSL_DIR}/private.key${tls_flag}${refresh_args}" \
    "Restart=on-failure" \
    "RestartSec=5s" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" > "/etc/systemd/system/${SUB_SERVICE}"
}

build_subscription_payload_files() {
  mkdir -p "$SUBSCRIPTION_DIR"

  if ! write_uri_subscription_raw "$SUB_URI_RAW_TXT"; then
    rm -f "$SUB_URI_RAW_TXT" "$SUB_URI_B64_TXT" "$SUB_CLASH_YAML" "$SUB_INDEX_HTML"
    return 1
  fi

  base64 -w 0 < "$SUB_URI_RAW_TXT" > "$SUB_URI_B64_TXT"
  build_subscription_clash_yaml
  build_subscription_clash_stable_yaml || true
  build_subscription_index_html
}

install_subscription_service() {
  # 无域名时自动走 HTTP 自签模式
  if [[ -z "${DOMAIN:-}" ]]; then
    SELF_SIGN_CERT="1"
  fi

  if [[ "${SELF_SIGN_CERT:-0}" != "1" ]]; then
    if ! cert_matches_domain || ! cert_is_currently_valid; then
      yellow "订阅服务需要可用域名证书，已跳过订阅服务。"
      return 1
    fi
  else
    # 自签证书模式：确保证书文件存在
    if ! cert_files_exist; then
      mkdir -p "$SSL_DIR"
      local sn="${DOMAIN:-selfsigned.localhost}"
      openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1)         -keyout "$SSL_DIR/private.key" -out "$SSL_DIR/fullchain.cer"         -days 3650 -subj "/CN=${sn}" -addext "subjectAltName=DNS:${sn}" 2>/dev/null
    fi
  fi

  systemctl stop "$SUB_SERVICE" >/dev/null 2>&1 || true
  ensure_dual_stack_ipv6_bind

  if [[ -z "${SUB_PORT:-}" ]]; then
    pick_subscription_port
  elif port_in_use "$SUB_PORT"; then
    yellow "订阅端口 ${SUB_PORT} 已被占用，重新选择随机高位端口。"
    pick_subscription_port
  fi

  if [[ -z "${SUB_PATH:-}" ]]; then
    generate_subscription_path
  fi

  SUB_ENABLED="1"
  if ! build_subscription_payload_files; then
    yellow "当前没有可发布的订阅内容，已跳过 HTTPS 订阅服务。"
    SUB_ENABLED="0"
    return 1
  fi
  write_subscription_server_script
  write_subscription_service
  systemctl daemon-reload
  systemctl enable "$SUB_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SUB_SERVICE"
}

refresh_subscription_service() {
  if ! has_subscription_service; then
    build_combined_subscription_files || true
    return 0
  fi

  if build_subscription_payload_files; then
    write_subscription_server_script
    write_subscription_service
    systemctl daemon-reload
    systemctl enable "$SUB_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SUB_SERVICE" >/dev/null 2>&1 || true
    build_combined_subscription_files || true
  else
    yellow "已无可用节点，关闭智能订阅服务。"
    systemctl disable --now "$SUB_SERVICE" >/dev/null 2>&1 || true
    rm -rf "$SUBSCRIPTION_DIR"
    SUB_ENABLED="0"
    SUB_PORT=""
    SUB_PATH=""
    save_state
    build_combined_subscription_files || true
  fi
}


# =============================================================================
# 新增执行入口及主控逻辑 (Interactive Menu)
# =============================================================================

do_one_click_all() {
  clear
  load_state >/dev/null 2>&1 || true
  cyan "================ 一键生成所有标准协议 ================"
  
  # 1. 引导获取 UUID
  prompt_common_uuid

  # 2. 引导获取必要协议的端口
  echo ""
  echo "本次安装将包含以下 6 个需要对外暴露端口的标准协议："
  echo "1. Hysteria2  2. Shadowsocks-2022  3. VMess  4. TUIC v5  5. AnyTLS  6. VLESS"
  read -r -p "请依次输入这 6 个协议的端口，用逗号隔开 (例如: 50001,50002,50003,50004,50005,50006，留空则全部自动随机分配 50000-60000): " custom_ports
  
  if [[ -z "$custom_ports" ]]; then
    local _used_ports=() _p
    for _proto in HY2 VMESS TUIC ANYTLS VLESS; do
      while :; do
        _p="$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)"
        [[ " ${_used_ports[*]} " != *" $_p "* ]] && break
      done
      _used_ports+=("$_p")
      case "$_proto" in
        HY2) HY2_PORT="$_p" ;;
        SS2022) SS2022_PORT="$_p" ;;
        VMESS) VMESS_PORT="$_p" ;;
        ANYTLS) ANYTLS_PORT="$_p" ;;
        VLESS) VLESS_PORT="$_p" ;;
        TUIC) TUIC_PORT="$_p" ;;
      esac
    done
    echo "已自动生成端口: HY2=$HY2_PORT, SS=$SS2022_PORT, VMess=$VMESS_PORT, TUIC=$TUIC_PORT, AnyTLS=$ANYTLS_PORT, VLESS=$VLESS_PORT"
  else
    IFS=',' read -r -a port_array <<< "$custom_ports"
    HY2_PORT="${port_array[0]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    SS2022_PORT="${port_array[1]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    VMESS_PORT="${port_array[2]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    TUIC_PORT="${port_array[3]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    ANYTLS_PORT="${port_array[4]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    VLESS_PORT="${port_array[5]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
  fi

  local _used_ports=() _port_var _port_val _new_port
  for _port_var in HY2_PORT VMESS_PORT TUIC_PORT ANYTLS_PORT VLESS_PORT; do
    _port_val="${!_port_var:-}"
    if [[ ! "$_port_val" =~ ^[0-9]+$ || " ${_used_ports[*]} " == *" $_port_val "* ]] || port_in_use "$_port_val"; then
      _new_port="$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)"
      printf -v "$_port_var" '%s' "$_new_port"
      _port_val="$_new_port"
    fi
    _used_ports+=("$_port_val")
  done

  # 3. 域名和证书检测处理
  echo ""
  configure_domain_certificate

  # 4. 获取节点名称前缀
  echo ""
  read -r -p "请输入节点名前缀 (留空默认使用服务器主机名 $(hostname)): " node_prefix
  node_prefix="${node_prefix:-$(hostname)}"
  
  NODE_NAME_VLESS="${node_prefix}-VLESS"
  NODE_NAME_HY2="${node_prefix}-HY2"
  NODE_NAME_SS2022="${node_prefix}-SS2022"
  NODE_NAME_VMESS="${node_prefix}-VMess"
  NODE_NAME_TUIC="${node_prefix}-TUIC"
  NODE_NAME_ARGO="${node_prefix}-Argo"

  # 5. 生成 24 位随机密码
  SHARED_PASS="$(openssl rand -hex 12)"
  HY2_PASSWORD="$SHARED_PASS"
  SS2022_PASSWORD="$SHARED_PASS"
  TUIC_PASSWORD="$SHARED_PASS"

  # 补全后续部署必需的参数
  SS2022_CIPHER="2022-blake3-aes-128-gcm"
  ARGO_WS_PATH="/argo-$(openssl rand -hex 8)"
  VMESS_WS_PATH="/ws-$(openssl rand -hex 8)"
  if [[ "${SITE_ENABLED:-0}" == "1" && -n "${SITE_DOMAIN:-}" && "${SITE_DOMAIN}" == "${DOMAIN}" && -f "$NGINX_SITE_CONF" && -f "$SSL_DIR/fullchain.cer" && -f "$SSL_DIR/private.key" ]]; then
    VMESS_VIA_NGINX="1"
    echo "检测到 EduPanel 站点和证书，VMess-WS 将通过 nginx 443 路径转发：${VMESS_WS_PATH}"
  else
    VMESS_VIA_NGINX="0"
  fi
  HY2_PORT_RANGE=""  # 端口跳跃留空，仅使用单端口
  HY2_OBFS_ENABLED="0"
  HY2_OBFS_PASSWORD=""
  NODE_NAME_ANYTLS="${node_prefix}-AnyTLS"
  select_argo_edge_server
  
  HY2_ENABLED="1"
  VLESS_ENABLED="1"
  ANYTLS_ENABLED="1"  # 启用 AnyTLS（sing-box 1.11+ 支持 inbound）
  SS2022_ENABLED="0"
  VMESS_ENABLED="1"
  TUIC_ENABLED="1"
  ARGO_ENABLED="1"

  HY2_TLS_SNI="$SNI_VAL"
  TUIC_TLS_SNI="$SNI_VAL"
  if [[ "${VMESS_VIA_NGINX:-0}" == "1" ]]; then
    VMESS_TLS_ENABLED="0"
    VMESS_TLS_SNI=""
  else
    VMESS_TLS_ENABLED="1"
    VMESS_TLS_SNI="$SNI_VAL"
  fi
  ANYTLS_PASSWORD="$SHARED_PASS"
  ANYTLS_TLS_SNI="$SNI_VAL"
  ANYTLS_SERVER_ADDR="${ANYTLS_SERVER_ADDR:-$(preferred_direct_server_addr)}"

  TARGET_PORT="443"
  HANDSHAKE_SERVER="${HANDSHAKE_SERVER:-$REALITY_SNI}"
  HANDSHAKE_PORT="443"
  prompt_argo_tunnel_config
  case "$?" in
    2)
      yellow "已取消创建节点。"
      return 0
      ;;
    0) ;;
    *)
      red "Argo 隧道配置失败。"
      return 1
      ;;
  esac
  if [[ -z "${ARGO_LOCAL_PORT:-}" ]]; then
    pick_argo_local_port || ARGO_LOCAL_PORT="$(shuf -i 50000-60000 -n 1)"
  fi

  # 补全各协议的 server_addr，确保构建文件时不会遗漏
  VMESS_SERVER_ADDR="${VMESS_SERVER_ADDR:-$(preferred_direct_server_addr)}"
  SS2022_SERVER_ADDR="${SS2022_SERVER_ADDR:-$(preferred_direct_server_addr)}"
  HY2_SERVER_ADDR="${HY2_SERVER_ADDR:-$(preferred_direct_server_addr)}"
  TUIC_SERVER_ADDR="${TUIC_SERVER_ADDR:-$(preferred_direct_server_addr)}"
  ANYTLS_SERVER_ADDR="${ANYTLS_SERVER_ADDR:-$(preferred_direct_server_addr)}"

  echo ""
  echo "正在生成 sing-box VLESS Reality 密钥对..."
  generate_keys_and_ids || true

  echo "正在写入主配置并拉起核心代理服务..."
  write_sing_box_config || return 1

  if [[ "${VMESS_VIA_NGINX:-0}" == "1" ]]; then
    echo "正在刷新 nginx 站点代理路径..."
    save_state
    refresh_mask_site_nginx || { red "nginx 代理路径刷新失败。"; return 1; }
  fi

  if argo_is_named_tunnel; then
    echo "正在拉起 Cloudflare 固定隧道..."
  else
    echo "正在拉起 Cloudflare 临时隧道..."
  fi
  install_cloudflared_binary

  # [关键修复] 清理之前残留的 cloudflared / wait_tcp / agent 孤儿进程
  pkill -f "wait-tcp 127.0.0.1" 2>/dev/null || true
  pkill -f "tunnel.*--url.*cloudflared" 2>/dev/null || true
  pkill -x agent 2>/dev/null || true
  # 如果 PID 1 是 systemd，可能还有旧框架的 agent 残留
  systemctl stop argo-refresh.timer argo-refresh.service vless-xhttp-reality-self-argo-refresh.timer vless-xhttp-reality-self-argo-refresh.service vless-xhttp-reality-self-argo.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  write_argo_service
  systemctl daemon-reload
  systemctl enable "$ARGO_SERVICE" >/dev/null 2>&1 || true
  enable_argo_refresh_automation
  echo ""
  echo "正在启动 cloudflared 服务..."
  if systemctl restart "$ARGO_SERVICE" >/dev/null 2>&1; then
    if refresh_argo_domain 8; then
      if argo_is_named_tunnel; then
        green "✓ Cloudflare Argo 固定隧道启动成功！域名: ${ARGO_DOMAIN}"
      else
        green "✓ Cloudflare Argo 临时隧道启动成功！域名: ${ARGO_DOMAIN}"
      fi
    else
      yellow "! Cloudflare Argo 已启动，暂未获取到域名，稍后可在节点信息中刷新。"
    fi
  else
    red "✗ Cloudflare Argo 隧道启动失败，跳过 Argo。"
  fi

  echo "正在构建全协议分享文件..."
  build_client_files || true
  build_hysteria2_share_files || true
  : # SS disabled
  build_anytls_share_files || true
  build_vmess_share_files || true
  build_tuic_share_files || true
  build_argo_share_files "0" || true

  echo "部署智能订阅服务..."
  prompt_subscription_port
  generate_subscription_path
  install_subscription_service || true

  save_state

  green "一键安装全标准协议结束！配置信息如下："
  echo ""
  echo "============ 节点连接信息 ============"
  local sip
  sip="$(preferred_direct_server_addr 2>/dev/null || echo "127.0.0.1")"
  echo ""
  if has_vless_install; then
    local e_sni e_pbk e_sid
    e_sni="$(urlenc "${REALITY_SNI:-www.apple.com}")"
    e_pbk="$(urlenc "$PUBLIC_KEY")"
    e_sid="$(urlenc "$SHORT_ID")"
    echo "[VLESS Reality]"
    echo "vless://${UUID}@${sip}:${VLESS_PORT}?encryption=none&security=reality&sni=${e_sni}&fp=chrome&pbk=${e_pbk}&sid=${e_sid}&type=tcp&headerType=none&spx=%2F&flow=xtls-rprx-vision#${NODE_NAME_VLESS}"
    echo ""
  fi
  if [[ "${HY2_ENABLED:-0}" == "1" ]]; then
    local e_auth e_sni_h hy2_insecure
    e_auth="$(urlenc "$HY2_PASSWORD")"
    e_sni_h="$(urlenc "$HY2_TLS_SNI")"
    hy2_insecure="$(tls_insecure_flag)"
    echo "[Hysteria2]"
    echo "hysteria2://${e_auth}@${sip}:${HY2_PORT}/?sni=${e_sni_h}&insecure=${hy2_insecure}&allowInsecure=${hy2_insecure}&alpn=h3#${NODE_NAME_HY2}"
    echo ""
  fi

  if [[ "${ANYTLS_ENABLED:-0}" == "1" ]]; then
    local e_apass e_asni
    e_apass="$(urlenc "$ANYTLS_PASSWORD")"
    e_asni="$(urlenc "$ANYTLS_TLS_SNI")"
    echo "[AnyTLS]"
    echo "anytls://${e_apass}@${sip}:${ANYTLS_PORT}/?sni=${e_asni}&insecure=${SELF_SIGN_CERT:-1}#${NODE_NAME_ANYTLS}"
    echo ""
  fi
  if [[ "${VMESS_ENABLED:-0}" == "1" ]]; then
    if vmess_public_tls_enabled; then
      echo "[VMess-WS/TLS]"
    else
      echo "[VMess-WS]"
    fi
    vmess_uri
    echo ""
    echo ""
  fi
  if [[ "${TUIC_ENABLED:-0}" == "1" ]]; then
    local e_uuid e_pass e_sni_t
    e_uuid="$(urlenc "$TUIC_UUID")"
    e_pass="$(urlenc "$TUIC_PASSWORD")"
    e_sni_t="$(urlenc "$TUIC_TLS_SNI")"
    echo "[TUIC v5]"
    echo "tuic://${e_uuid}:${e_pass}@${sip}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${e_sni_t}&insecure=${SELF_SIGN_CERT:-1}&allowInsecure=${SELF_SIGN_CERT:-1}#${NODE_NAME_TUIC}"
    echo ""
  fi
  if [[ "${ARGO_ENABLED:-0}" == "1" && -n "${ARGO_DOMAIN:-}" ]]; then
    local argo_server e_domain e_path e_label
    select_argo_edge_server
    argo_server="$(argo_client_server)"
    e_domain="$(urlenc "$ARGO_DOMAIN")"
    e_path="$(urlenc "$ARGO_WS_PATH")"
    e_label="$(urlenc "$NODE_NAME_ARGO")"
    echo "[Argo-VLESS]"
    echo "vless://${ARGO_UUID}@${argo_server}:443?encryption=none&security=tls&sni=${e_domain}&fp=chrome&insecure=0&allowInsecure=0&type=ws&host=${e_domain}&path=${e_path}#${e_label}"
    echo ""
  fi
  echo "======================================"
  echo "按任意键返回主菜单..."
  read -r -n 1
}

switch_to_fixed_tunnel() {
  clear
  cyan "=== 切换为固定隧道 (Named Tunnel) ==="
  prompt_argo_tunnel_config
  case "$?" in
    2)
      return 0
      ;;
    0) ;;
    *)
      echo "按回车键返回主菜单..."
      read -r
      return 1
      ;;
  esac
  if [[ "$ARGO_TUNNEL_MODE" == "named" ]]; then
    echo "正在重写 Argo 隧道服务并尝试重启..."
    write_argo_service
    systemctl daemon-reload
    timeout 60 systemctl restart "$ARGO_SERVICE" || yellow "Argo 服务重启超时，请稍后手动检查。"
    refresh_argo_domain 15 || true
    build_argo_share_files "0" || true
    refresh_subscription_service
    green "固定隧道切换及重启指令已下发！"
    show_node_info
  else
    yellow "未选择切换固定隧道，已取消操作。"
  fi
  echo "按回车键返回主菜单..."
  read -r
}

apply_network_tuning_menu() {
  local bandwidth_mbps input_rtt input_bandwidth

  require_root || return 1
  echo "动态网络调优会按内存、CPU、RTT 和国内有效带宽计算参数。"
  echo "带宽请填中国用户到此节点的实际速度，不要填服务器国外测速峰值。"
  echo "示例：30MB/s=240Mbps，50MB/s=400Mbps；纯数字按 Mbps 处理。"
  read -r -p "请输入预估 RTT(ms) [默认 220，中国到加拿大常见 180-260]: " input_rtt
  read -r -p "请输入国内实际有效带宽 [可留空按内存档位]: " input_bandwidth
  bandwidth_mbps="$(parse_bandwidth_mbps "$input_bandwidth")"
  if [[ -n "$input_bandwidth" && "$bandwidth_mbps" != "0" ]]; then
    echo "带宽换算: ${input_bandwidth} -> ${bandwidth_mbps} Mbps"
  fi

  PROXY_TUNE_RTT_MS="${input_rtt:-220}" \
  PROXY_TUNE_BANDWIDTH_MBPS="${bandwidth_mbps:-0}" \
  write_sing_box_service_tuning show

  systemctl daemon-reload >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$SING_BOX_SERVICE" 2>/dev/null; then
    systemctl restart "$SING_BOX_SERVICE" >/dev/null 2>&1 || true
  fi
  green "动态网络加速参数已应用。"
  echo "按回车键返回主菜单..."
  read -r
}

uninstall_all() {
  local units=(
    "$ARGO_REFRESH_TIMER"
    "$ARGO_REFRESH_PATH"
    "$ARGO_REFRESH_SERVICE"
    "$SUB_SERVICE"
    "$ARGO_SERVICE"
    "$SING_BOX_SERVICE"
    "vless-xhttp-reality-self-argo-refresh.timer"
    "vless-xhttp-reality-self-argo-refresh.service"
    "vless-xhttp-reality-self-argo.service"
  )
  local unit

  require_root || return 1

  yellow "正在停止并禁用 systemd 服务..."
  for unit in "${units[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl kill "$unit" --kill-who=all >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  done

  yellow "正在清理残留进程..."
  pkill -x sing-box >/dev/null 2>&1 || true
  pkill -x cloudflared >/dev/null 2>&1 || true
  pkill -x agent >/dev/null 2>&1 || true
  pkill -f "wait-tcp 127.0.0.1" >/dev/null 2>&1 || true
  pkill -f "${SUB_SERVER_SCRIPT}" >/dev/null 2>&1 || true

  yellow "正在删除 systemd 单元文件..."
  for unit in "${units[@]}"; do
    rm -f "/etc/systemd/system/${unit}"
    rm -rf "/etc/systemd/system/${unit}.d"
  done
  rm -rf "/etc/systemd/system/${SING_BOX_SERVICE}.d"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  yellow "正在删除二进制文件..."
  rm -f "$SING_BOX_BIN"
  rm -f "$CLOUDFLARED_BIN"

  yellow "正在删除配置和数据..."
  rm -rf "$SING_BOX_DIR"
  rm -rf "$SUBSCRIPTION_DIR"
  rm -rf "$SITE_ROOT"
  rm -f "$NGINX_SITE_CONF"
  rm -f "$ARGO_BOOT_LOG"
  rm -f /etc/sysctl.d/99-agsb-proxy-tuning.conf
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && (systemctl reload nginx >/dev/null 2>&1 || true)
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  if systemctl is-active --quiet "$SING_BOX_SERVICE" 2>/dev/null || [[ -x "$SING_BOX_BIN" ]]; then
    red "卸载后仍检测到 sing-box 残留，请执行：systemctl status ${SING_BOX_SERVICE}"
    return 1
  fi

  green "卸载完成，sing-box 服务和二进制已清理。"
}

do_one_click_all_with_cdn() {
  clear
  load_state >/dev/null 2>&1 || true
  cyan "================ 一键全协议 + CDN 加速 ================"

  # ===== 第1步: UUID =====
  prompt_common_uuid

  # ===== 第2步: 全局 CF Token =====
  echo ""
  cyan "--- Cloudflare API Token (全局) ---"
  echo "此 Token 将用于: Argo 隧道配置 + CDN+VMess+WS 的 DNS/Origin Rules"
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    read -r -p "Cloudflare API Token [empty = use current token]: " _global_cf_token
    _global_cf_token="$(printf '%s' "$_global_cf_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$_global_cf_token" ]] && CF_API_TOKEN="$_global_cf_token"
  else
    read -r -p "Cloudflare API Token: " _global_cf_token
    _global_cf_token="$(printf '%s' "$_global_cf_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$_global_cf_token" ]]; then
      red "Cloudflare API Token is required."
      return 1
    fi
    CF_API_TOKEN="$_global_cf_token"
  fi
  _global_cf_token="$CF_API_TOKEN"
  local token_len="${#_global_cf_token}"
  local token_tail="$_global_cf_token"
  if (( token_len > 6 )); then
    token_tail="${_global_cf_token: -6}"
  fi
  echo "Token 已读取: 长度 ${token_len}，结尾 ${token_tail}"

  # ===== 第3步: 端口分配（7个协议: HY2/SS/VMess/TUIC/AnyTLS/VLESS + CDN-VMess） =====
  echo ""
  echo "本次安装将包含以下 7 个需要端口的协议:"
  echo "1.Hysteria2 2.SS-2022 3.VMess 4.TUIC 5.AnyTLS 6.VLESS 7.CDN-VMess"
  read -r -p "请依次输入 7 个端口(逗号隔开)，留空全部随机 50000-60000: " custom_ports

  if [[ -z "$custom_ports" ]]; then
    local _used_ports=() _p
    for _proto in HY2 VMESS TUIC ANYTLS VLESS CDN_VMESS; do
      while :; do
        _p="$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)"
        [[ " ${_used_ports[*]} " != *" $_p "* ]] && break
      done
      _used_ports+=("$_p")
      case "$_proto" in
        HY2) HY2_PORT="$_p" ;;
        SS2022) SS2022_PORT="$_p" ;;
        VMESS) VMESS_PORT="$_p" ;;
        TUIC) TUIC_PORT="$_p" ;;
        ANYTLS) ANYTLS_PORT="$_p" ;;
        VLESS) VLESS_PORT="$_p" ;;
        CDN_VMESS) CDN_VMESS_PORT="$_p" ;;
      esac
    done
    echo "已自动生成端口: HY2=$HY2_PORT SS=$SS2022_PORT VMess=$VMESS_PORT TUIC=$TUIC_PORT AnyTLS=$ANYTLS_PORT VLESS=$VLESS_PORT CDN-VMess=$CDN_VMESS_PORT"
  else
    IFS=',' read -r -a port_array <<< "$custom_ports"
    HY2_PORT="${port_array[0]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    VMESS_PORT="${port_array[1]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    TUIC_PORT="${port_array[2]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    ANYTLS_PORT="${port_array[3]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    VLESS_PORT="${port_array[4]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
    CDN_VMESS_PORT="${port_array[6]:-$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)}"
  fi

  # 端口去重和冲突检测
  local _used_ports=() _port_var _port_val _new_port
  for _port_var in HY2_PORT VMESS_PORT TUIC_PORT ANYTLS_PORT VLESS_PORT CDN_VMESS_PORT; do
    _port_val="${!_port_var:-}"
    if [[ ! "$_port_val" =~ ^[0-9]+$ || " ${_used_ports[*]} " == *" $_port_val "* ]] || port_in_use "$_port_val"; then
      _new_port="$(pick_free_port 50000 60000 || shuf -i 50000-60000 -n 1)"
      printf -v "$_port_var" '%s' "$_new_port"
      _port_val="$_new_port"
    fi
    _used_ports+=("$_port_val")
  done

  # ===== 第4步: 域名和证书 =====
  echo ""
  configure_domain_certificate

  # ===== 第5步: 节点名前缀 =====
  echo ""
  read -r -p "请输入节点名前缀 (留空使用主机名 $(hostname)): " node_prefix
  node_prefix="${node_prefix:-$(hostname)}"

  NODE_NAME_VLESS="${node_prefix}-VLESS"
  NODE_NAME_HY2="${node_prefix}-HY2"
  NODE_NAME_VMESS="${node_prefix}-VMess"
  NODE_NAME_TUIC="${node_prefix}-TUIC"
  NODE_NAME_ARGO="${node_prefix}-Argo"
  NODE_NAME_ANYTLS="${node_prefix}-AnyTLS"
  NODE_NAME_CDN_VMESS="${node_prefix}-CDN"

  # ===== 第6步: Argo 隧道域名 =====
  echo ""
  cyan "--- Argo 隧道配置 ---"
  echo "CF Token 已就绪，输入隧道域名即可自动配置 Named Tunnel。"
  echo "留空则使用临时隧道(trycloudflare.com)，输入 0 跳过 Argo。"
  read -r -p "请输入 Argo 隧道域名 (如 tunnel.example.com): " argo_domain_input
  argo_domain_input="$(printf '%s' "${argo_domain_input:-}" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"

  if [[ "$argo_domain_input" == "0" ]]; then
    yellow "跳过 Argo 隧道。"
    ARGO_ENABLED="0"
  elif [[ -n "$argo_domain_input" ]]; then
    ARGO_FIXED_DOMAIN="$argo_domain_input"
    ARGO_TUNNEL_MODE="named"
    ARGO_DOMAIN="$ARGO_FIXED_DOMAIN"
    pick_argo_local_port || ARGO_LOCAL_PORT="$(shuf -i 50000-60000 -n 1)"
    echo "隧道域名: ${ARGO_FIXED_DOMAIN}  本地端口: ${ARGO_LOCAL_PORT}"
    if ! cf_configure_named_tunnel; then
      red "Argo Named Tunnel 配置失败，将跳过 Argo。"
      ARGO_ENABLED="0"
    else
      ARGO_ENABLED="1"
    fi
  else
    yellow "未输入域名，使用临时隧道。"
    ARGO_TUNNEL_MODE="quick"
    ARGO_FIXED_DOMAIN=""
    ARGO_TUNNEL_TOKEN=""
    ARGO_DOMAIN=""
    pick_argo_local_port || ARGO_LOCAL_PORT="$(shuf -i 50000-60000 -n 1)"
    ARGO_ENABLED="1"
  fi

  # ===== 第7步: CDN 加速域名 =====
  echo ""
  cyan "--- CDN+VMess+WS 配置 ---"
  read -r -p "请输入 CDN 加速域名 (如 cdn.example.com): " cdn_domain_input
  cdn_domain_input="$(printf '%s' "${cdn_domain_input:-}" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
  if [[ -z "$cdn_domain_input" ]]; then
    red "CDN 域名不能为空。"
    return 1
  fi

  echo ""
  echo "CDN 端口模式:"
  echo "  A) CF 标准 HTTP 端口 (无需 Origin Rules)"
  echo "  B) 自定义端口 ${CDN_VMESS_PORT} (需要 Origin Rules 权限)"
  read -r -p "请选择 [A/B，默认 A]: " cdn_port_mode
  cdn_port_mode="$(printf '%s' "${cdn_port_mode:-A}" | tr '[:lower:]' '[:upper:]')"

  local cdn_need_origin_rule="0"
  if [[ "$cdn_port_mode" == "B" ]]; then
    cdn_need_origin_rule="1"
  else
    echo "可用 CF 标准 HTTP 端口: 80, 8080, 8880, 2052, 2082, 2086, 2095"
    read -r -p "选择端口 [默认 8880]: " cdn_std_port
    CDN_VMESS_PORT="${cdn_std_port:-8880}"
    if ! cf_is_standard_http_port "$CDN_VMESS_PORT"; then
      red "端口 ${CDN_VMESS_PORT} 不是 CF 标准 HTTP 端口。"
      return 1
    fi
  fi

  # ===== 开始部署 =====
  echo ""
  cyan "===== 开始部署所有协议 ====="

  # 生成密码
  SHARED_PASS="$(openssl rand -hex 12)"
  HY2_PASSWORD="$SHARED_PASS"
  SS2022_PASSWORD="$SHARED_PASS"
  TUIC_PASSWORD="$SHARED_PASS"
  ANYTLS_PASSWORD="$SHARED_PASS"

  SS2022_CIPHER="2022-blake3-aes-128-gcm"
  ARGO_WS_PATH="/argo-$(openssl rand -hex 8)"
  VMESS_WS_PATH="/ws-$(openssl rand -hex 8)"
  CDN_VMESS_WS_PATH="/cdn-ws-$(openssl rand -hex 6)"

  if [[ "${SITE_ENABLED:-0}" == "1" && -n "${SITE_DOMAIN:-}" && "${SITE_DOMAIN}" == "${DOMAIN}" && -f "$NGINX_SITE_CONF" && -f "$SSL_DIR/fullchain.cer" && -f "$SSL_DIR/private.key" ]]; then
    VMESS_VIA_NGINX="1"
  else
    VMESS_VIA_NGINX="0"
  fi
  HY2_PORT_RANGE=""
  HY2_OBFS_ENABLED="0"
  HY2_OBFS_PASSWORD=""
  select_argo_edge_server

  HY2_ENABLED="1"
  VLESS_ENABLED="1"
  ANYTLS_ENABLED="1"
  SS2022_ENABLED="0"
  VMESS_ENABLED="1"
  TUIC_ENABLED="1"
  CDN_VMESS_ENABLED="1"

  HY2_TLS_SNI="$SNI_VAL"
  TUIC_TLS_SNI="$SNI_VAL"
  if [[ "${VMESS_VIA_NGINX:-0}" == "1" ]]; then
    VMESS_TLS_ENABLED="0"
    VMESS_TLS_SNI=""
  else
    VMESS_TLS_ENABLED="1"
    VMESS_TLS_SNI="$SNI_VAL"
  fi
  ANYTLS_TLS_SNI="$SNI_VAL"

  TARGET_PORT="443"
  HANDSHAKE_SERVER="${HANDSHAKE_SERVER:-$REALITY_SNI}"
  HANDSHAKE_PORT="443"

  # VPS IP
  local vps_ip
  vps_ip="$(detect_public_ipv4 2>/dev/null || true)"
  if [[ -z "$vps_ip" ]]; then
    read -r -p "未能自动检测 VPS IP，请手动输入: " vps_ip
    [[ -n "$vps_ip" ]] || { red "VPS IP 不能为空。"; return 1; }
  fi

  # server_addr
  VMESS_SERVER_ADDR="${vps_ip}"
  SS2022_SERVER_ADDR="${vps_ip}"
  HY2_SERVER_ADDR="${vps_ip}"
  TUIC_SERVER_ADDR="${vps_ip}"
  ANYTLS_SERVER_ADDR="${vps_ip}"
  CDN_VMESS_UUID="${UUID}"
  CDN_VMESS_CDN_DOMAIN="$cdn_domain_input"
  CDN_VMESS_SERVER_ADDR="${vps_ip}"
  CDN_VMESS_ORIGIN_PORT="$CDN_VMESS_PORT"

  # 生成 VLESS Reality 密钥对
  echo "正在生成 sing-box VLESS Reality 密钥对..."
  generate_keys_and_ids || true

  # CDN DNS + Origin Rules 配置
  echo ""
  echo "正在配置 CDN+VMess+WS 的 Cloudflare DNS..."
  if ! cf_configure_cdn_vmess "$cdn_domain_input" "$CDN_VMESS_PORT" "$vps_ip" "$cdn_need_origin_rule"; then
    yellow "CDN 配置失败，跳过 CDN+VMess+WS 节点。"
    CDN_VMESS_ENABLED="0"
  fi

  # 写入 sing-box 配置（包含所有协议 + CDN VMess inbound）
  echo "正在写入主配置并拉起核心代理服务..."
  write_sing_box_config || return 1

  if [[ "${VMESS_VIA_NGINX:-0}" == "1" ]]; then
    echo "正在刷新 nginx 站点代理路径..."
    save_state
    refresh_mask_site_nginx || { red "nginx 代理路径刷新失败。"; return 1; }
  fi

  # Argo 隧道
  if [[ "${ARGO_ENABLED:-0}" == "1" ]]; then
    if argo_is_named_tunnel; then
      echo "正在拉起 Cloudflare 固定隧道..."
    else
      echo "正在拉起 Cloudflare 临时隧道..."
    fi
    install_cloudflared_binary

    pkill -f "wait-tcp 127.0.0.1" 2>/dev/null || true
    pkill -f "tunnel.*--url.*cloudflared" 2>/dev/null || true
    pkill -x agent 2>/dev/null || true
    systemctl stop argo-refresh.timer argo-refresh.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    generate_argo_identity
    write_argo_service
    systemctl daemon-reload
    systemctl enable "$ARGO_SERVICE" >/dev/null 2>&1 || true
    enable_argo_refresh_automation
    echo "正在启动 cloudflared..."
    if systemctl restart "$ARGO_SERVICE" >/dev/null 2>&1; then
      if refresh_argo_domain 8; then
        green "Argo 隧道启动成功！域名: ${ARGO_DOMAIN}"
      else
        yellow "Argo 已启动，暂未获取到域名。"
      fi
    else
      red "Argo 隧道启动失败。"
    fi
  fi

  # 构建所有分享文件
  echo "正在构建全协议分享文件..."
  build_client_files || true
  build_hysteria2_share_files || true
  : # SS disabled
  build_anytls_share_files || true
  build_vmess_share_files || true
  build_tuic_share_files || true
  if [[ "${ARGO_ENABLED:-0}" == "1" ]]; then
    build_argo_share_files "0" || true
  fi
  if [[ "${CDN_VMESS_ENABLED:-0}" == "1" ]]; then
    build_cdn_vmess_share_files || true
  fi

  # 订阅服务
  echo "部署智能订阅服务..."
  prompt_subscription_port
  generate_subscription_path
  install_subscription_service || true

  save_state

  green "一键全协议 + CDN 安装完成！"
  echo ""
  show_node_info
  echo "按任意键返回主菜单..."
  read -r -n 1
}

create_node_submenu() {
  while true; do
    clear
    cyan "================================================="
    cyan "             创建代理节点"
    cyan "================================================="
    echo "  1) 一键生成所有标准协议 (VLESS/HY2/VMess/TUIC/AnyTLS/Argo)"
    echo "  2) 单独安装 CDN+VMess+WS 节点 (Cloudflare CDN 加速)"
    echo "  3) 一键全协议+CDN (VLESS/HY2/VMess/TUIC/AnyTLS/Argo/CDN)"
    echo "  4) Create CF proxy node"
    echo "  0) 返回主菜单"
    cyan "================================================="
    read -r -p "请输入对应的数字: " sub_choice

    case "$sub_choice" in
      1)
        if ! do_one_click_all; then
          red "创建代理节点失败。"
          echo "按回车键返回..."
          read -r
        fi
        ;;
      2)
        if ! install_cdn_vmess_core; then
          red "CDN+VMess+WS 节点安装失败。"
        fi
        echo "按回车键返回..."
        read -r
        ;;
      3)
        if ! do_one_click_all_with_cdn; then
          red "一键全协议+CDN 安装失败。"
          echo "按回车键返回..."
          read -r
        fi
        ;;
      4)
        if ! create_cf_proxy_node; then
          red "Create CF proxy node failed."
          echo "Press Enter to return..."
          read -r
        fi
        ;;
      0)
        return 0
        ;;
      *)
        red "无效输入。"
        sleep 1
        ;;
    esac
  done
}

main_menu() {
  while true; do
    load_state >/dev/null 2>&1 || true
    clear
    cyan "================================================="
    cyan "             节点配置与订阅管理面板"
    cyan "================================================="

    local sb_status sb_ver sb_latest
    if [[ -x "$SING_BOX_BIN" ]]; then
      if systemctl is-active --quiet "$SING_BOX_SERVICE" 2>/dev/null; then
        sb_status="运行中"
      elif [[ ! -s "$SING_BOX_CFG" ]]; then
        sb_status="已安装/未配置"
      else
        sb_status="未运行"
      fi
      sb_ver="$("$SING_BOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      sb_ver="${sb_ver:-未知}"
    elif systemctl is-active --quiet "$SING_BOX_SERVICE" 2>/dev/null; then
      sb_status="服务残留运行"
      sb_ver="-"
    else
      sb_status="未安装"
      sb_ver="-"
    fi
    detect_sing_box_version
    sb_latest="$SING_BOX_VERSION"
    echo "   sing-box: ${sb_ver}(${sb_status})    官网最新版本: ${sb_latest}"
    echo "  1  安装 sing-box"
    echo "  2  装站点且 nginx 代理"
    echo "  3) 创建代理节点"
    echo "  4) 应用系统网络加速"
    echo "  5) 查看所有节点"
    echo "  98 更新sing-box 版本"
    echo "  99 卸载sing-box和节点和伪装站"
    echo "  0) 退出脚本"
    cyan "================================================="
    read -r -p "请输入对应的数字: " choice

    case "$choice" in
      1)
        install_sing_box
        if [[ $? -eq 0 ]]; then
          green "sing-box 核心安装完成；创建节点后服务才会运行。"
        else
          red "sing-box 安装失败！"
        fi
        echo "按回车键返回主菜单..."
        read -r
        ;;
      2)
        if ! install_mask_site_nginx; then
          red "站点和 nginx 代理配置失败。"
        fi
        echo "按回车键返回主菜单..."
        read -r
        ;;
      3)
        create_node_submenu
        ;;
      4)
        apply_network_tuning_menu
        ;;
      5)
        show_node_info
        echo "按回车键返回主菜单..."
        read -r
        ;;
      98)
        yellow "正在更新 sing-box 版本..."
        rm -f "$SING_BOX_BIN"
        install_sing_box
        if [[ $? -eq 0 ]]; then
          green "sing-box 更新完成！"
        else
          red "sing-box 更新失败！"
        fi
        echo "按回车键返回主菜单..."
        read -r
        ;;
      99)
        echo ""
        red "警告：此操作将卸载 sing-box、所有节点配置和脚本创建的伪装站！"
        read -r -p "确认卸载? (请输入 YES 确认): " confirm
        if [[ "$confirm" != "YES" ]]; then
          yellow "已取消卸载。"
        else
          uninstall_all
        fi
        echo "按回车键返回主菜单..."
        read -r
        ;;
      0)
        green "退出脚本。"
        exit 0
        ;;
      *)
        red "无效输入，请重新选择数字。"
        sleep 1
        ;;
    esac
  done
}

# 启动入口执行
case "${1:-}" in
  --wait-tcp)
    wait_tcp_endpoint "$2" "$3" "${4:-45}"
    exit $?
    ;;
  --refresh-argo-subscription)
    refresh_argo_subscription_once "$2"
    exit $?
    ;;
  *)
    require_root || exit 1
    main_menu
    ;;
esac
