#!/usr/bin/env bash
# =============================================================================
# net-deep-tune.sh - single-user high-RTT proxy network tuning
# =============================================================================

set -o pipefail

APP_NAME="AGSB Net Deep Tune"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/98-agsb-net-deep-tune.conf}"
SING_BOX_SERVICE="${SING_BOX_SERVICE:-sing-box.service}"
DROPIN_DIR="${DROPIN_DIR:-/etc/systemd/system/${SING_BOX_SERVICE}.d}"
DROPIN_FILE="${DROPIN_FILE:-${DROPIN_DIR}/98-agsb-net-deep-tune.conf}"
STATE_DIR="${STATE_DIR:-/etc/agsb-net-tune}"
BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR}/backups}"
REPORT_DIR="${REPORT_DIR:-${STATE_DIR}/reports}"
EDGE_POOL_FILE="${EDGE_POOL_FILE:-/etc/sing-box/state/argo-edge-pool.txt}"
NODE_STATE_FILE="${NODE_STATE_FILE:-/etc/sing-box/state/node-state.env}"
EDGE_TEST_YAML="${EDGE_TEST_YAML:-/etc/sing-box/node-info/argo-edge-test.yaml}"

red() { printf '\e[31m%s\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
cyan() { printf '\e[36m%s\e[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法：
  bash net-deep-tune.sh
  bash net-deep-tune.sh status
  bash net-deep-tune.sh apply [safe|aggressive|throughput|bbr-fq|cake]
  bash net-deep-tune.sh rollback
  bash net-deep-tune.sh edge-import <file> [dest]
  bash net-deep-tune.sh edge-status
  bash net-deep-tune.sh edge-rank
  bash net-deep-tune.sh reports

常用环境变量：
  RTT_MS=250                 国内到节点的预估延迟
  BANDWIDTH_MBPS=500         国内实际可跑带宽，不要填 VPS 国外测速峰值
  CAKE_IFACE=eth0            Cake 作用网卡，留空自动识别默认出口
  CAKE_BANDWIDTH_MBPS=300    Cake 限速带宽；没填时使用 BANDWIDTH_MBPS
  RESTART_SING_BOX=1         修改服务限制后自动重启 sing-box
  AGSB_TUNE_RPS=1            给默认出口网卡启用 RPS/XPS

说明：
  - 直接运行 bash net-deep-tune.sh 会进入中文看板菜单。
  - BBR3 取决于内核。本脚本只能启用系统已有的 bbr，不能把普通内核变成 BBR3。
  - Cake 是主动限速整形。带宽要填低于真实瓶颈的数值，填太高没意义，填太低会限速。
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请使用 root 权限运行：sudo bash $0 $*"
    return 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

sysctl_get() {
  sysctl -n "$1" 2>/dev/null || true
}

default_iface() {
  ip route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

detect_mem_mb() {
  awk '/MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null
}

detect_cpu_cores() {
  nproc 2>/dev/null || echo 1
}

clamp_int() {
  local value="$1" min="$2" max="$3"
  [[ "$value" =~ ^[0-9]+$ ]] || value="$min"
  (( value < min )) && value="$min"
  (( value > max )) && value="$max"
  printf '%s\n' "$value"
}

auto_bandwidth_default() {
  local mem_mb cpu estimate
  mem_mb="$(detect_mem_mb)"
  cpu="$(detect_cpu_cores)"
  [[ "$mem_mb" =~ ^[0-9]+$ && "$mem_mb" -gt 0 ]] || mem_mb=1024
  [[ "$cpu" =~ ^[0-9]+$ && "$cpu" -gt 0 ]] || cpu=1

  # Hardware only gives a sane starting point. Real domestic bandwidth should be
  # entered from local tests when known.
  estimate=$(( cpu * 160 + mem_mb / 12 ))
  clamp_int "$estimate" 100 3000
}

available_bbr() {
  modprobe tcp_bbr >/dev/null 2>&1 || true
  sysctl_get net.ipv4.tcp_available_congestion_control | grep -qw bbr
}

selected_cc() {
  if available_bbr; then
    printf 'bbr\n'
  else
    sysctl_get net.ipv4.tcp_congestion_control
  fi
}

format_mib() {
  local bytes="$1"
  [[ "$bytes" =~ ^[0-9]+$ ]] || { printf '%s' "$bytes"; return; }
  printf '%s MiB' "$(( (bytes + 1048575) / 1048576 ))"
}

calc_profile() {
  local profile="$1"
  local mem_mb cpu rtt bandwidth bdp target mem_bytes mem_cap min_floor mult mem_div
  local backlog_scale backlog_max budget_base budget_usecs_base udp_floor udp_max
  local somax_raw optmem_raw rcv_default_raw txq_raw

  mem_mb="$(detect_mem_mb)"
  cpu="$(detect_cpu_cores)"
  [[ "$mem_mb" =~ ^[0-9]+$ && "$mem_mb" -gt 0 ]] || mem_mb=1024
  [[ "$cpu" =~ ^[0-9]+$ && "$cpu" -gt 0 ]] || cpu=1
  rtt="${RTT_MS:-250}"
  [[ "$rtt" =~ ^[0-9]+$ && "$rtt" -gt 0 ]] || rtt=250
  bandwidth="${BANDWIDTH_MBPS:-$(auto_bandwidth_default)}"

  case "$profile" in
    safe)
      mult=$(( rtt >= 220 ? 3 : 2 ))
      mem_div=48
      backlog_scale=120
      budget_base=180
      budget_usecs_base=3000
      udp_floor=8192
      ;;
    aggressive|throughput)
      if (( rtt >= 260 )); then
        mult=7
      elif (( rtt >= 160 )); then
        mult=6
      else
        mult=5
      fi
      mem_div=12
      backlog_scale=320
      budget_base=360
      budget_usecs_base=6000
      udp_floor=65536
      ;;
    bbr-fq)
      mult=$(( rtt >= 220 ? 4 : 3 ))
      mem_div=24
      backlog_scale=180
      budget_base=240
      budget_usecs_base=4000
      udp_floor=32768
      ;;
    cake)
      mult=3
      mem_div=24
      backlog_scale=160
      budget_base=220
      budget_usecs_base=3500
      udp_floor=32768
      ;;
    *)
      red "未知 profile: $profile"
      return 1
      ;;
  esac
  [[ "$bandwidth" =~ ^[0-9]+$ && "$bandwidth" -gt 0 ]] || bandwidth="$(auto_bandwidth_default)"

  mem_bytes=$(( mem_mb * 1024 * 1024 ))
  bdp=$(( bandwidth * rtt * 125 ))
  mem_cap=$(( mem_bytes / mem_div ))
  min_floor="$(clamp_int "$(( mem_bytes / 96 ))" 8388608 134217728)"
  target=$(( bdp * mult ))
  target="$(clamp_int "$target" "$min_floor" "$mem_cap")"

  RMEM_MAX="$target"
  WMEM_MAX="$target"
  rcv_default_raw=$(( target / 64 ))
  RCV_DEFAULT="$(clamp_int "$rcv_default_raw" 262144 4194304)"
  optmem_raw=$(( target / 8 ))
  OPTMEM_MAX="$(clamp_int "$optmem_raw" 4194304 134217728)"
  somax_raw=$(( cpu * 8192 + mem_mb * 8 ))
  SOMAXCONN="$(clamp_int "$somax_raw" 16384 262144)"
  NETDEV_BACKLOG="$(( bandwidth * backlog_scale + cpu * 25000 + mem_mb * 8 ))"
  backlog_max="$(clamp_int "$(( mem_mb * 96 + cpu * 50000 ))" 100000 900000)"
  NETDEV_BACKLOG="$(clamp_int "$NETDEV_BACKLOG" 50000 "$backlog_max")"
  NETDEV_BUDGET="$(clamp_int "$(( budget_base + cpu * 35 + bandwidth / 20 ))" 180 1200)"
  NETDEV_BUDGET_USECS="$(clamp_int "$(( budget_usecs_base + rtt * 12 ))" 2500 12000)"
  TCP_NOTSENT_LOWAT="$(clamp_int "$(( target / 1024 ))" 16384 262144)"
  TCP_RMEM_MID="$(clamp_int "$(( target / 32 ))" 87380 2097152)"
  TCP_WMEM_MID="$(clamp_int "$(( target / 32 ))" 65536 2097152)"
  udp_max="$(clamp_int "$(( target / 64 ))" "$udp_floor" 524288)"
  UDP_MIN="$(clamp_int "$(( target / 512 ))" "$udp_floor" "$udp_max")"
  txq_raw=$(( 1000 + bandwidth * 4 + cpu * 350 ))
  TXQUEUELEN="$(clamp_int "$txq_raw" 2000 20000)"
  if [[ "$profile" == "aggressive" || "$profile" == "throughput" ]]; then
    TCP_NOTSENT_LOWAT="$(clamp_int "$(( target / 512 ))" 65536 524288)"
    TXQUEUELEN="$(clamp_int "$(( txq_raw * 2 ))" 4000 30000)"
  fi
  TUNE_RTT_MS="$rtt"
  TUNE_BANDWIDTH_MBPS="$bandwidth"
  TUNE_BDP_BYTES="$bdp"
  TUNE_BUFFER_MULT="$mult"
  TUNE_PROFILE="$profile"
  TUNE_MEM_MB="$mem_mb"
  TUNE_CPU="$cpu"
  TUNE_CC="$(selected_cc)"
  [[ -n "$TUNE_CC" ]] || TUNE_CC="cubic"
}

selected_keys() {
  cat <<'EOF'
net.core.default_qdisc
net.core.somaxconn
net.core.netdev_max_backlog
net.core.netdev_budget
net.core.netdev_budget_usecs
net.core.rmem_default
net.core.wmem_default
net.core.rmem_max
net.core.wmem_max
net.core.optmem_max
net.ipv4.tcp_congestion_control
net.ipv4.tcp_fastopen
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_no_metrics_save
net.ipv4.ip_local_port_range
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
EOF
}

backup_state() {
  local ts backup iface
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_DIR}/${ts}"
  iface="${1:-$(default_iface)}"
  mkdir -p "$backup"

  selected_keys | while IFS= read -r key; do
    val="$(sysctl_get "$key")"
    [[ -n "$val" ]] && printf '%s=%s\n' "$key" "$val"
  done > "${backup}/sysctl.restore"

  [[ -f "$SYSCTL_FILE" ]] && cp -a "$SYSCTL_FILE" "${backup}/sysctl-file.conf"
  [[ -f "$DROPIN_FILE" ]] && cp -a "$DROPIN_FILE" "${backup}/dropin.conf"
  if [[ -n "$iface" ]] && cmd_exists tc; then
    tc qdisc show dev "$iface" > "${backup}/tc-qdisc.txt" 2>/dev/null || true
  fi
  printf 'IFACE=%s\nHAD_SYSCTL_FILE=%s\nHAD_DROPIN_FILE=%s\n' \
    "$iface" "$([[ -f "$SYSCTL_FILE" ]] && echo 1 || echo 0)" "$([[ -f "$DROPIN_FILE" ]] && echo 1 || echo 0)" \
    > "${backup}/state.env"
  ln -sfn "$backup" "${BACKUP_DIR}/latest"
  printf '%s\n' "$backup"
}

write_sysctl_profile() {
  local profile="$1"
  calc_profile "$profile" || return 1
  mkdir -p "$(dirname "$SYSCTL_FILE")"

  cat > "$SYSCTL_FILE" <<EOF
# ${APP_NAME}
# profile=${TUNE_PROFILE} rtt_ms=${TUNE_RTT_MS} bandwidth_mbps=${TUNE_BANDWIDTH_MBPS}
net.core.default_qdisc = fq
net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}
net.core.rmem_default = ${RCV_DEFAULT}
net.core.wmem_default = ${RCV_DEFAULT}
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.optmem_max = ${OPTMEM_MAX}
net.ipv4.tcp_congestion_control = ${TUNE_CC}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = ${TCP_NOTSENT_LOWAT}
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 ${TCP_RMEM_MID} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_WMEM_MID} ${WMEM_MAX}
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.udp_rmem_min = ${UDP_MIN}
net.ipv4.udp_wmem_min = ${UDP_MIN}
EOF
}

write_service_dropin() {
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN_FILE" <<EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
LimitMEMLOCK=infinity
TasksMax=infinity
Nice=-5
EOF
}

cpu_mask() {
  local n mask
  n="$(detect_cpu_cores)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || n=1
  if (( n >= 32 )); then
    printf 'ffffffff\n'
  else
    mask=$(( (1 << n) - 1 ))
    printf '%x\n' "$mask"
  fi
}

apply_rps_xps() {
  local iface="$1" mask q
  [[ "${AGSB_TUNE_RPS:-1}" == "1" ]] || return 0
  [[ -n "$iface" && -d "/sys/class/net/${iface}" ]] || return 0
  mask="$(cpu_mask)"

  for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [[ -w "$q" ]] && printf '%s' "$mask" > "$q" 2>/dev/null || true
  done
  for q in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
    [[ -w "$q" ]] && printf '%s' "$mask" > "$q" 2>/dev/null || true
  done

  if [[ "${TXQUEUELEN:-}" =~ ^[0-9]+$ ]] && command -v ip >/dev/null 2>&1; then
    ip link set dev "$iface" txqueuelen "$TXQUEUELEN" >/dev/null 2>&1 || true
  fi
}

switch_qdisc_menu() {
  local iface choice bandwidth rtt
  require_root || return 1
  iface="${CAKE_IFACE:-$(default_iface)}"
  [[ -n "$iface" ]] || { red "未能识别默认出口网卡，请设置 CAKE_IFACE=eth0"; return 1; }
  cmd_exists tc || { red "缺少 tc 命令，请先安装 iproute2"; return 1; }

  echo "当前网卡: ${iface}"
  tc qdisc show dev "$iface" 2>/dev/null | sed 's/^/  /'
  echo
  echo "1) fq（推荐，配合 BBR，适合下载吞吐）"
  echo "2) fq_codel（稳妥低延迟，吞吐通常略保守）"
  echo "3) cake（主动限速整形，需要填真实瓶颈带宽）"
  echo "4) pfifo_fast（系统传统队列，仅用于回退测试）"
  echo "0) 取消"
  read -r -p "请选择队列算法 [默认 1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      tc qdisc replace dev "$iface" root fq || return 1
      green "已切换为 fq"
      ;;
    2)
      tc qdisc replace dev "$iface" root fq_codel || return 1
      green "已切换为 fq_codel"
      ;;
    3)
      read -r -p "请输入 Cake 限速带宽 Mbps [默认 ${CAKE_BANDWIDTH_MBPS:-${BANDWIDTH_MBPS:-300}}]: " bandwidth
      bandwidth="${bandwidth:-${CAKE_BANDWIDTH_MBPS:-${BANDWIDTH_MBPS:-300}}}"
      read -r -p "请输入 RTT ms [默认 ${RTT_MS:-250}]: " rtt
      rtt="${rtt:-${RTT_MS:-250}}"
      apply_cake "$iface" "$bandwidth" "$rtt"
      ;;
    4)
      tc qdisc replace dev "$iface" root pfifo_fast || return 1
      green "已切换为 pfifo_fast"
      ;;
    0)
      yellow "已取消。"
      ;;
    *)
      red "无效选择。"
      return 1
      ;;
  esac
}

apply_cake() {
  local iface="$1" bandwidth="$2" rtt="$3"
  [[ -n "$iface" ]] || { red "未能识别默认出口网卡，请设置 CAKE_IFACE=eth0"; return 1; }
  [[ "$bandwidth" =~ ^[0-9]+$ && "$bandwidth" -gt 0 ]] || {
    red "Cake 必须设置 CAKE_BANDWIDTH_MBPS 或 BANDWIDTH_MBPS"
    return 1
  }
  cmd_exists tc || { red "缺少 tc 命令，请先安装 iproute2"; return 1; }

  if tc qdisc replace dev "$iface" root cake bandwidth "${bandwidth}mbit" besteffort triple-isolate nat nowash rtt "${rtt}ms" 2>/dev/null; then
    green "Cake 已应用到 ${iface}: ${bandwidth}mbit rtt=${rtt}ms"
  else
    yellow "完整 Cake 参数失败，尝试基础参数。"
    tc qdisc replace dev "$iface" root cake bandwidth "${bandwidth}mbit" 2>/dev/null || {
      red "Cake 应用失败，当前内核可能不支持 sch_cake。"
      return 1
    }
  fi
}

restart_sing_box_if_needed() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ "${RESTART_SING_BOX:-1}" == "1" ]] || return 0
  if systemctl is-active --quiet "$SING_BOX_SERVICE" 2>/dev/null; then
    systemctl try-restart "$SING_BOX_SERVICE" >/dev/null 2>&1 || true
  fi
}

apply_profile() {
  local profile="${1:-aggressive}" iface backup cake_bw
  require_root || return 1
  iface="${CAKE_IFACE:-$(default_iface)}"
  backup="$(backup_state "$iface")"

  write_sysctl_profile "$profile" || return 1
  sysctl -p "$SYSCTL_FILE" >/dev/null || yellow "部分 sysctl 参数应用失败，请查看内核支持情况。"
  write_service_dropin
  apply_rps_xps "$iface"

  if [[ "$profile" == "cake" ]]; then
    cake_bw="${CAKE_BANDWIDTH_MBPS:-${BANDWIDTH_MBPS:-}}"
    apply_cake "$iface" "$cake_bw" "${RTT_MS:-250}" || return 1
    printf 'APPLIED_PROFILE=%s\nAPPLIED_CAKE=1\n' "$profile" >> "${backup}/state.env"
  else
    printf 'APPLIED_PROFILE=%s\nAPPLIED_CAKE=0\n' "$profile" >> "${backup}/state.env"
  fi

  restart_sing_box_if_needed

  green "网络调优已应用: profile=${profile}"
  echo "备份目录: ${backup}"
  echo "RTT=${TUNE_RTT_MS}ms bandwidth=${TUNE_BANDWIDTH_MBPS}Mbps buffer=$(format_mib "$RMEM_MAX") cc=${TUNE_CC}"
  echo "BDP=$(format_mib "$TUNE_BDP_BYTES") multiplier=${TUNE_BUFFER_MULT} netdev_backlog=${NETDEV_BACKLOG} udp_min=${UDP_MIN} txqueuelen=${TXQUEUELEN}"
}

rollback() {
  local backup="${1:-${BACKUP_DIR}/latest}" line key val state_iface had_sysctl had_dropin
  require_root || return 1
  [[ -e "$backup" ]] || { red "未找到备份: $backup"; return 1; }
  backup="$(readlink -f "$backup")"
  [[ -f "${backup}/sysctl.restore" && -f "${backup}/state.env" ]] || {
    red "备份不完整: $backup"
    return 1
  }

  while IFS='=' read -r key val; do
    [[ -n "$key" && -n "$val" ]] || continue
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
  done < "${backup}/sysctl.restore"

  # shellcheck disable=SC1090
  source "${backup}/state.env"
  state_iface="${IFACE:-}"
  had_sysctl="${HAD_SYSCTL_FILE:-0}"
  had_dropin="${HAD_DROPIN_FILE:-0}"
  if [[ "$had_sysctl" == "1" && -f "${backup}/sysctl-file.conf" ]]; then
    cp -a "${backup}/sysctl-file.conf" "$SYSCTL_FILE"
  else
    rm -f "$SYSCTL_FILE"
  fi
  if [[ "$had_dropin" == "1" && -f "${backup}/dropin.conf" ]]; then
    mkdir -p "$DROPIN_DIR"
    cp -a "${backup}/dropin.conf" "$DROPIN_FILE"
  else
    rm -f "$DROPIN_FILE"
  fi
  if [[ ( "${APPLIED_CAKE:-0}" == "1" || "${FORCE_QDISC_RESET:-0}" == "1" ) && -n "$state_iface" ]] && cmd_exists tc; then
    tc qdisc del dev "$state_iface" root >/dev/null 2>&1 || true
  fi
  restart_sing_box_if_needed
  green "已回退到备份: $backup"
}

clean_edge_line() {
  sed -E 's/#.*$//; s#^[[:space:]]*https?://##; s#/.*$##; s/[[:space:]]//g'
}

update_node_state_for_edge_pool() {
  local tmp
  [[ -f "$NODE_STATE_FILE" ]] || return 0
  tmp="$(mktemp)"
  grep -Ev '^(ARGO_MULTI_EDGE|ARGO_EDGE_POOL_FILE|ARGO_EDGE_SERVER)=' "$NODE_STATE_FILE" > "$tmp" 2>/dev/null || true
  {
    printf 'ARGO_MULTI_EDGE=1\n'
    printf 'ARGO_EDGE_POOL_FILE=%s\n' "$EDGE_POOL_FILE"
  } >> "$tmp"
  install -m 0600 "$tmp" "$NODE_STATE_FILE" 2>/dev/null || mv -f "$tmp" "$NODE_STATE_FILE"
  rm -f "$tmp"
}

edge_import() {
  local src="$1" dest="${2:-$EDGE_POOL_FILE}" tmp count
  require_root || return 1
  [[ -f "$src" ]] || { red "入口池文件不存在: $src"; return 1; }
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  while IFS= read -r line; do
    line="$(printf '%s\n' "$line" | clean_edge_line)"
    [[ -n "$line" ]] || continue
    printf '%s\n' "$line"
  done < "$src" | awk '!seen[$0]++' > "$tmp"
  count="$(wc -l < "$tmp" | tr -d ' ')"
  [[ "$count" -gt 0 ]] || { rm -f "$tmp"; red "入口池为空或格式无效"; return 1; }
  install -m 0600 "$tmp" "$dest"
  rm -f "$tmp"
  EDGE_POOL_FILE="$dest"
  update_node_state_for_edge_pool
  green "已导入入口池: $dest (${count} 条)"
  echo "node.sh 会在 ARGO_MULTI_EDGE=1 时读取该文件生成轮换订阅。"
}

edge_status() {
  local file="${1:-$EDGE_POOL_FILE}"
  if [[ ! -f "$file" ]]; then
    yellow "入口池不存在: $file"
    return 0
  fi
  cyan "=== Edge Pool ==="
  echo "file: $file"
  echo "count: $(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$file" | wc -l | tr -d ' ')"
  sed -n '1,20p' "$file"
}

report_slug_time() {
  date +%Y%m%d-%H%M%S
}

csv_escape() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

new_report_paths() {
  local name="$1" ts
  ts="$(report_slug_time)"
  mkdir -p "$REPORT_DIR"
  REPORT_CSV="${REPORT_DIR}/${ts}-${name}.csv"
  REPORT_MD="${REPORT_DIR}/${ts}-${name}.md"
}

write_measure_header() {
  local title="$1"
  printf '时间,实验,配置,下载Mbps,空载延迟ms,负载延迟ms,失败次数,备注\n' > "$REPORT_CSV"
  {
    printf '# %s\n\n' "$title"
    printf '| 时间 | 实验 | 配置 | 下载Mbps | 空载延迟ms | 负载延迟ms | 失败次数 | 备注 |\n'
    printf '|---|---|---|---:|---:|---:|---:|---|\n'
  } > "$REPORT_MD"
}

append_measure_row() {
  local experiment="$1" config="$2" down="$3" idle="$4" loaded="$5" fails="$6" note="$7" now
  now="$(date '+%F %T')"
  {
    csv_escape "$now"; printf ','
    csv_escape "$experiment"; printf ','
    csv_escape "$config"; printf ','
    csv_escape "$down"; printf ','
    csv_escape "$idle"; printf ','
    csv_escape "$loaded"; printf ','
    csv_escape "$fails"; printf ','
    csv_escape "$note"; printf '\n'
  } >> "$REPORT_CSV"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$now" "$experiment" "$config" "${down:-}" "${idle:-}" "${loaded:-}" "${fails:-0}" "${note:-}" >> "$REPORT_MD"
}

prompt_measure_result() {
  local experiment="$1" config="$2" down idle loaded fails note

  echo
  cyan "请在本地客户端测试：${config}"
  echo "建议记录下载、空载延迟、测速时延迟；不清楚的项可以留空。"
  read -r -p "下载 Mbps: " down
  read -r -p "空载延迟 ms: " idle
  read -r -p "负载/测速时延迟 ms: " loaded
  read -r -p "失败次数 [默认 0]: " fails
  fails="${fails:-0}"
  read -r -p "备注 [可留空]: " note

  append_measure_row "$experiment" "$config" "$down" "$idle" "$loaded" "$fails" "$note"
}

show_report_paths() {
  green "报告已生成："
  echo "CSV: ${REPORT_CSV}"
  echo "Markdown: ${REPORT_MD}"
}

status() {
  local iface
  iface="${CAKE_IFACE:-$(default_iface)}"
  cyan "=== ${APP_NAME} 状态 ==="
  echo "出口网卡: ${iface:-未知}"
  echo "内核版本: $(uname -r)"
  echo "CPU/内存: $(detect_cpu_cores) 核 / $(detect_mem_mb) MB"
  echo "当前拥塞控制: $(sysctl_get net.ipv4.tcp_congestion_control)"
  echo "可用拥塞控制: $(sysctl_get net.ipv4.tcp_available_congestion_control)"
  echo "默认队列算法: $(sysctl_get net.core.default_qdisc)"
  echo "接收缓冲上限: $(sysctl_get net.core.rmem_max) ($(format_mib "$(sysctl_get net.core.rmem_max)"))"
  echo "发送缓冲上限: $(sysctl_get net.core.wmem_max) ($(format_mib "$(sysctl_get net.core.wmem_max)"))"
  echo "netdev backlog/budget: $(sysctl_get net.core.netdev_max_backlog) / $(sysctl_get net.core.netdev_budget) / $(sysctl_get net.core.netdev_budget_usecs)us"
  echo "UDP 最小缓冲: r=$(sysctl_get net.ipv4.udp_rmem_min) w=$(sysctl_get net.ipv4.udp_wmem_min)"
  echo "TCP Fast Open: $(sysctl_get net.ipv4.tcp_fastopen)"
  echo "MTU 探测: $(sysctl_get net.ipv4.tcp_mtu_probing)"
  if [[ -n "$iface" ]] && cmd_exists tc; then
    echo "当前 tc 队列:"
    tc qdisc show dev "$iface" 2>/dev/null | sed 's/^/  /'
  fi
  if systemctl list-unit-files "$SING_BOX_SERVICE" >/dev/null 2>&1; then
    echo "sing-box 服务限制:"
    systemctl show "$SING_BOX_SERVICE" -p LimitNOFILE -p LimitNPROC -p TasksMax -p Nice --no-pager 2>/dev/null | sed 's/^/  /'
  fi
  [[ -f "$SYSCTL_FILE" ]] && echo "调优配置文件: $SYSCTL_FILE"
  [[ -f "$DROPIN_FILE" ]] && echo "服务覆盖配置: $DROPIN_FILE"
  return 0
}

edge_pool_count() {
  local file="${1:-$EDGE_POOL_FILE}"
  [[ -f "$file" ]] || { printf '0'; return; }
  sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$file" | wc -l | tr -d ' '
}

pause_return() {
  echo
  read -r -p "按回车键返回菜单..."
}

prompt_tune_inputs() {
  local input default_bw

  read -r -p "请输入国内到节点 RTT(ms) [默认 ${RTT_MS:-250}]: " input
  RTT_MS="${input:-${RTT_MS:-250}}"
  if [[ ! "$RTT_MS" =~ ^[0-9]+$ ]]; then
    RTT_MS="250"
  elif (( RTT_MS <= 0 )); then
    RTT_MS="250"
  fi

  default_bw="${BANDWIDTH_MBPS:-$(auto_bandwidth_default)}"
  read -r -p "请输入国内实际有效带宽 Mbps [默认 ${default_bw}，留空按硬件估算]: " input
  BANDWIDTH_MBPS="${input:-$default_bw}"
  if [[ ! "$BANDWIDTH_MBPS" =~ ^[0-9]+$ ]]; then
    BANDWIDTH_MBPS="500"
  elif (( BANDWIDTH_MBPS <= 0 )); then
    BANDWIDTH_MBPS="500"
  fi
}

prompt_cake_inputs() {
  local input default_iface_name

  prompt_tune_inputs
  default_iface_name="$(default_iface)"
  read -r -p "请输入 Cake 作用网卡 [默认 ${CAKE_IFACE:-${default_iface_name:-自动识别}}]: " input
  CAKE_IFACE="${input:-${CAKE_IFACE:-$default_iface_name}}"

  read -r -p "请输入 Cake 限速带宽 Mbps [建议低于实测瓶颈，默认 ${CAKE_BANDWIDTH_MBPS:-$BANDWIDTH_MBPS}]: " input
  CAKE_BANDWIDTH_MBPS="${input:-${CAKE_BANDWIDTH_MBPS:-$BANDWIDTH_MBPS}}"
  if [[ ! "$CAKE_BANDWIDTH_MBPS" =~ ^[0-9]+$ ]]; then
    CAKE_BANDWIDTH_MBPS="$BANDWIDTH_MBPS"
  elif (( CAKE_BANDWIDTH_MBPS <= 0 )); then
    CAKE_BANDWIDTH_MBPS="$BANDWIDTH_MBPS"
  fi
}

parse_csv_list() {
  local raw="$1" item
  printf '%s\n' "$raw" | tr ',' '\n' | while IFS= read -r item; do
    item="$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

load_node_state_for_read() {
  local f="${1:-$NODE_STATE_FILE}" k v
  [[ -f "$f" ]] || return 1
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == "#"* ]] && continue
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    declare -g "$k=$v"
  done < "$f"
}

experiment_edge_rank() {
  local file="${1:-$EDGE_POOL_FILE}" line idx note best_file tmp_sorted
  local edges=()

  require_root || return 1
  [[ -f "$file" ]] || { red "入口池不存在：$file"; return 1; }
  generate_edge_test_yaml "$file" || true
  new_report_paths "edge-rank"
  write_measure_header "优选入口池测速记录"

  mapfile -t edges < <(
    while IFS= read -r line; do
      line="$(printf '%s\n' "$line" | clean_edge_line)"
      [[ -n "$line" ]] && printf '%s\n' "$line"
    done < "$file"
  )

  yellow "本功能只按下载 Mbps 排序。延迟可以记录作参考，上传不参与也不再询问。"
  [[ -f "$EDGE_TEST_YAML" ]] && echo "请先把入口池测试 YAML 导入客户端逐个测速：${EDGE_TEST_YAML}"

  idx=0
  for line in "${edges[@]}"; do
    idx=$((idx + 1))
    prompt_measure_result "Edge-Pool" "edge-${idx}-${line}"
  done

  tmp_sorted="$(mktemp)"
  awk -F',' 'NR>1 {
    config=$3; down=$4;
    gsub(/^"|"$/, "", config); gsub(/^"|"$/, "", down);
    if (down == "") down=0;
    print down "\t" config
  }' "$REPORT_CSV" | sort -rn > "$tmp_sorted"

  best_file="${REPORT_DIR}/$(report_slug_time)-best-edge-pool.txt"
  awk -F'\t' '{
    cfg=$2
    sub(/^edge-[0-9]+-/, "", cfg)
    print cfg
  }' "$tmp_sorted" > "$best_file"
  rm -f "$tmp_sorted"

  {
    printf '\n## 排序结果\n\n'
    printf '按下载 Mbps 从高到低生成：`%s`\n' "$best_file"
  } >> "$REPORT_MD"

  show_report_paths
  echo "排序后的入口池: ${best_file}"
  [[ -f "$EDGE_TEST_YAML" ]] && echo "入口池测试 YAML: ${EDGE_TEST_YAML}"
  echo
  read -r -p "是否把排序结果应用为当前入口池？[y/N]: " note
  case "$note" in
    y|Y)
      edge_import "$best_file" "$EDGE_POOL_FILE"
      ;;
  esac
}

generate_edge_test_yaml() {
  local file="${1:-$EDGE_POOL_FILE}" line idx name names=()

  [[ -f "$file" ]] || return 1
  load_node_state_for_read || return 1
  [[ -n "${ARGO_UUID:-}" && -n "${ARGO_WS_PATH:-}" && -n "${ARGO_DOMAIN:-}" ]] || return 1

  mkdir -p "$(dirname "$EDGE_TEST_YAML")"
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
    "  nameserver:" \
    "    - 223.5.5.5" \
    "    - 119.29.29.29" \
    "    - 1.1.1.1" \
    "" \
    "proxies:" > "$EDGE_TEST_YAML"

  idx=0
  while IFS= read -r line; do
    line="$(printf '%s\n' "$line" | clean_edge_line)"
    [[ -n "$line" ]] || continue
    idx=$((idx + 1))
    name="$(printf '%s-Edge-%03d' "${NODE_NAME_ARGO:-Argo}" "$idx")"
    names+=("$name")
    printf '%s\n' \
      "  - name: \"${name}\"" \
      "    type: vless" \
      "    server: \"${line}\"" \
      "    port: 443" \
      "    uuid: \"${ARGO_UUID}\"" \
      "    encryption: \"\"" \
      "    network: ws" \
      "    tls: true" \
      "    udp: true" \
      "    ip-version: ipv4-prefer" \
      "    servername: \"${ARGO_DOMAIN}\"" \
      "    client-fingerprint: \"${ARGO_CLIENT_FINGERPRINT:-chrome}\"" \
      "    skip-cert-verify: false" \
      "    ws-opts:" \
      "      path: \"${ARGO_WS_PATH}\"" \
      "      headers:" \
      "        Host: \"${ARGO_DOMAIN}\"" >> "$EDGE_TEST_YAML"
  done < "$file"

  [[ "${#names[@]}" -gt 0 ]] || { rm -f "$EDGE_TEST_YAML"; return 1; }

  printf '%s\n' "" "proxy-groups:" \
    "  - name: ARGO-EDGE-TEST" \
    "    type: select" \
    "    proxies:" >> "$EDGE_TEST_YAML"
  for name in "${names[@]}"; do
    printf '      - "%s"\n' "$name" >> "$EDGE_TEST_YAML"
  done
  printf '%s\n' "" "rules:" "  - MATCH,ARGO-EDGE-TEST" >> "$EDGE_TEST_YAML"
  chmod 600 "$EDGE_TEST_YAML" 2>/dev/null || true
  green "入口池测试 YAML 已生成：${EDGE_TEST_YAML}"
}

show_reports() {
  mkdir -p "$REPORT_DIR" 2>/dev/null || true
  cyan "=== 历史测速报告 ==="
  if [[ ! -d "$REPORT_DIR" ]]; then
    yellow "暂无报告，或当前用户无权限访问：${REPORT_DIR}"
    return 0
  fi
  find "$REPORT_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.csv' -o -name '*best-edge-pool.txt' \) \
    | sort | tail -40
}

web_speedtest_hint() {
  cyan "=== 浏览器测速页 ==="
  echo "测速网页逻辑已拆到独立脚本：web-speedtest.sh"
  echo
  echo "启动：sudo bash web-speedtest.sh start"
  echo "停止：sudo bash web-speedtest.sh stop"
  echo "状态：bash web-speedtest.sh status"
  echo
  echo "用法："
  echo "1. 在 VPS 启动测速页。"
  echo "2. 在安徽移动本地浏览器打开脚本打印的 URL。"
  echo "3. 如果要测代理链路，确保浏览器访问该 URL 时走当前代理。"
  echo "4. 切换节点或参数后，在网页修改配置名称并点开始测速。"
  echo "5. 全部测完后导出 CSV。"
}

show_dashboard() {
  local iface cc qdisc rmem wmem profile_file dropin_file
  iface="${CAKE_IFACE:-$(default_iface)}"
  cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
  qdisc="$(sysctl_get net.core.default_qdisc)"
  rmem="$(sysctl_get net.core.rmem_max)"
  wmem="$(sysctl_get net.core.wmem_max)"
  [[ -f "$SYSCTL_FILE" ]] && profile_file="已写入" || profile_file="未写入"
  [[ -f "$DROPIN_FILE" ]] && dropin_file="已写入" || dropin_file="未写入"

  clear 2>/dev/null || true
  cyan "================================================="
  cyan "              网络深度调优看板"
  cyan "================================================="
  echo "内核版本: $(uname -r)"
  echo "出口网卡: ${iface:-未知}"
  echo "CPU/内存: $(detect_cpu_cores) 核 / $(detect_mem_mb) MB"
  echo "拥塞控制: ${cc:-未知}    默认队列: ${qdisc:-未知}"
  echo "TCP缓冲: rmem=$(format_mib "$rmem") / wmem=$(format_mib "$wmem")"
  echo "UDP最小缓冲: r=$(sysctl_get net.ipv4.udp_rmem_min) / w=$(sysctl_get net.ipv4.udp_wmem_min)"
  echo "调优配置: ${profile_file}    sing-box限制: ${dropin_file}"
  cyan "================================================="
  echo "  1) 查看完整网络状态"
  echo "  2) 应用保守调优（低风险，适合先试）"
  echo "  3) 应用激进调优（单人高 RTT 榨带宽，推荐）"
  echo "  4) 应用 BBR/FQ 稳定调优（低风险 / TCP-Argo-WS 推荐）"
  echo "  5) 切换阻塞队列"
  echo "  0) 退出"
  cyan "================================================="
}

main_menu() {
  local choice

  while true; do
    show_dashboard
    read -r -p "请输入序号: " choice
    case "$choice" in
      1)
        echo
        status
        pause_return
        ;;
      2)
        echo
        yellow "保守调优会扩大 TCP/UDP 缓冲、启用低延迟连接参数，并写入 sing-box 服务限制。"
        prompt_tune_inputs
        apply_profile safe
        pause_return
        ;;
      3)
        echo
        yellow "吞吐优先：按 BDP*6 放大 TCP/UDP 缓冲、netdev backlog/budget、txqueuelen，适合单人高 RTT 下载。"
        prompt_tune_inputs
        apply_profile aggressive
        pause_return
        ;;
      4)
        echo
        yellow "稳定调优：启用 BBR/FQ 和中等 BDP 缓冲，适合 TCP、Argo、WS、日常稳定使用。"
        prompt_tune_inputs
        apply_profile bbr-fq
        pause_return
        ;;
      5)
        echo
        switch_qdisc_menu
        pause_return
        ;;
      0)
        green "已退出。"
        return 0
        ;;
      *)
        red "无效序号，请重新输入。"
        sleep 1
        ;;
    esac
  done
}

main() {
  if [[ "$#" -eq 0 ]]; then
    main_menu
    return $?
  fi

  local cmd="$1"
  shift || true
  case "$cmd" in
    status) status "$@" ;;
    apply) apply_profile "${1:-aggressive}" ;;
    rollback) rollback "$@" ;;
    edge-import) edge_import "${1:-}" "${2:-}" ;;
    edge-status) edge_status "$@" ;;
    edge-rank) experiment_edge_rank "$@" ;;
    reports) show_reports "$@" ;;
    help|-h|--help) usage ;;
    *)
      red "未知命令: $cmd"
      usage
      return 1
      ;;
  esac
}

main "$@"
