#!/usr/bin/env bash
# =============================================================================
# web-speedtest.sh - standalone browser speed test page for proxy experiments
# =============================================================================

set -o pipefail

APP_NAME="AGSB Web Speedtest"
WEBTEST_DIR="${WEBTEST_DIR:-/etc/agsb-web-speedtest}"
WEBTEST_SCRIPT="${WEBTEST_SCRIPT:-${WEBTEST_DIR}/server.py}"
WEBTEST_SERVICE="${WEBTEST_SERVICE:-agsb-web-speedtest.service}"
WEBTEST_BIND="${WEBTEST_BIND:-0.0.0.0}"
WEBTEST_PORT="${WEBTEST_PORT:-6080}"

red() { printf '\e[31m%s\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
cyan() { printf '\e[36m%s\e[0m\n' "$*"; }

usage() {
  cat <<EOF
用法：
  bash web-speedtest.sh start       启动 systemd 测速网页
  bash web-speedtest.sh stop        停止测速网页
  bash web-speedtest.sh restart     重启测速网页
  bash web-speedtest.sh status      查看状态和访问地址
  bash web-speedtest.sh doctor      诊断页面打不开的原因
  bash web-speedtest.sh run         前台运行，适合临时测试
  bash web-speedtest.sh uninstall   删除服务和生成文件

环境变量：
  WEBTEST_PORT=6080                 监听端口
  WEBTEST_BIND=0.0.0.0              监听地址
  WEBTEST_DIR=/etc/agsb-web-speedtest

说明：
  在本地浏览器打开脚本打印的 URL。浏览器走代理时，测的是代理链路；
  浏览器不走代理时，测的是你本地到 VPS 的直连链路。
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请使用 root 权限运行：sudo bash $0 $*"
    return 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_public_addr() {
  local ip
  ip="$(curl -fsS --connect-timeout 2 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s\n' "${ip:-127.0.0.1}"
}

webtest_url() {
  printf 'http://%s:%s/' "$(detect_public_addr)" "$WEBTEST_PORT"
}

local_health_url() {
  printf 'http://127.0.0.1:%s/health' "$WEBTEST_PORT"
}

port_listener() {
  cmd_exists ss || return 1
  ss -ltnp 2>/dev/null | awk -v p=":${WEBTEST_PORT}" '$4 ~ p "$" {print}'
}

show_existing_listener() {
  local line
  line="$(port_listener || true)"
  if [[ -n "$line" ]]; then
    yellow "TCP ${WEBTEST_PORT} 已被占用："
    echo "$line"
    echo
    echo "如果这是 ${WEBTEST_SERVICE}，说明测速网页已经在后台运行，直接打开：$(webtest_url)"
    echo "如需前台运行，请先执行：sudo bash web-speedtest.sh stop"
    return 0
  fi
  return 1
}

write_server() {
  mkdir -p "$WEBTEST_DIR"
  cat > "$WEBTEST_SCRIPT" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>AGSB 浏览器测速</title>
  <style>
    :root{color-scheme:light dark;font-family:system-ui,-apple-system,Segoe UI,Arial,sans-serif}
    body{margin:0;background:#f6f7f9;color:#15171a}
    main{max-width:980px;margin:0 auto;padding:24px}
    h1{font-size:24px;margin:0 0 6px}
    p{color:#5b6470;line-height:1.6}
    .panel{background:#fff;border:1px solid #dde1e7;border-radius:8px;padding:16px;margin:14px 0}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}
    label{display:block;font-size:13px;color:#46505c;margin-bottom:5px}
    input,button{box-sizing:border-box;width:100%;font:inherit;border-radius:6px;border:1px solid #cbd2dc;padding:9px 10px;background:#fff;color:#15171a}
    button{cursor:pointer;background:#1f6feb;color:#fff;border-color:#1f6feb;font-weight:600}
    button.secondary{background:#fff;color:#15171a;border-color:#cbd2dc}
    button:disabled{opacity:.6;cursor:not-allowed}
    table{width:100%;border-collapse:collapse;margin-top:10px;background:#fff}
    th,td{text-align:left;border-bottom:1px solid #e6e9ef;padding:8px;font-size:13px;white-space:nowrap}
    th{color:#46505c;background:#f1f3f6}
    .status{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;background:#0f1720;color:#d6e2f0;border-radius:8px;padding:12px;min-height:48px;white-space:pre-wrap}
    .metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px}
    .metric{background:#f8fafc;border:1px solid #e1e6ee;border-radius:8px;padding:12px}
    .metric b{display:block;font-size:22px;margin-top:3px}
    @media (prefers-color-scheme:dark){
      body{background:#0d1117;color:#e6edf3}.panel,table,input{background:#161b22;color:#e6edf3;border-color:#30363d}
      p,label,th{color:#9aa7b3}.metric{background:#111820;border-color:#30363d}.secondary{background:#161b22!important;color:#e6edf3!important}
      th{background:#111820}td,th{border-bottom-color:#30363d}
    }
  </style>
</head>
<body>
<main>
  <h1>AGSB 浏览器测速</h1>
  <p>在本地浏览器打开本页并按当前代理配置测试。切换节点或参数后，修改“配置名称”再点击开始，最后导出 CSV。</p>
  <section class="panel">
    <div class="grid">
      <div><label>配置名称</label><input id="label" value="baseline-当前配置"></div>
      <div><label>下载大小 MB</label><input id="downMb" type="number" min="1" max="2048" value="64"></div>
      <div><label>重复次数</label><input id="runs" type="number" min="1" max="10" value="2"></div>
    </div>
    <div class="grid" style="margin-top:12px">
      <button id="startBtn">开始测速</button>
      <button class="secondary" id="exportBtn">导出 CSV</button>
      <button class="secondary" id="clearBtn">清空结果</button>
    </div>
  </section>
  <section class="panel metrics">
    <div class="metric">下载 Mbps<b id="downNow">-</b></div>
    <div class="metric">空载延迟 ms<b id="idleNow">-</b></div>
    <div class="metric">负载延迟 ms<b id="loadedNow">-</b></div>
  </section>
  <section class="panel"><div class="status" id="status">等待测试。</div></section>
  <section class="panel">
    <table>
      <thead><tr><th>时间</th><th>配置</th><th>下载</th><th>空载延迟</th><th>负载延迟</th><th>失败</th><th>备注</th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
  </section>
</main>
<script>
const rows = [];
const $ = id => document.getElementById(id);
const mbps = (bytes, ms) => ((bytes * 8) / (ms / 1000) / 1000000);
function log(s){ $('status').textContent = s; }
function nowText(){ return new Date().toISOString().replace('T',' ').replace(/\..+/, ''); }
async function pingOnce() {
  const t0 = performance.now();
  await fetch('/ping?t=' + Math.random(), {cache:'no-store'});
  return performance.now() - t0;
}
async function measurePing(samples) {
  const arr = [];
  for (let i=0;i<samples;i++) arr.push(await pingOnce());
  arr.sort((a,b)=>a-b);
  return {avg: arr.reduce((a,b)=>a+b,0)/arr.length};
}
async function loadedPing(signal) {
  const arr = [];
  while (!signal.aborted) {
    try { arr.push(await pingOnce()); } catch(e) {}
    await new Promise(r => setTimeout(r, 150));
  }
  if (!arr.length) return null;
  arr.sort((a,b)=>a-b);
  return arr[Math.floor(arr.length * 0.8)];
}
async function measureDownload(mb) {
  const bytesTarget = Math.max(1, mb) * 1048576;
  const ctrl = new AbortController();
  const pingPromise = loadedPing(ctrl.signal);
  const t0 = performance.now();
  const res = await fetch('/download?bytes=' + bytesTarget + '&t=' + Math.random(), {cache:'no-store'});
  const reader = res.body.getReader();
  let bytes = 0;
  while (true) {
    const r = await reader.read();
    if (r.done) break;
    bytes += r.value.length;
  }
  const ms = performance.now() - t0;
  ctrl.abort();
  const loaded = await pingPromise;
  return {speed: mbps(bytes, ms), loaded};
}
function addRow(row) {
  rows.push(row);
  const tr = document.createElement('tr');
  tr.innerHTML = `<td>${row.time}</td><td>${row.label}</td><td>${row.down}</td><td>${row.idle}</td><td>${row.loaded}</td><td>${row.fail}</td><td>${row.note}</td>`;
  $('rows').appendChild(tr);
}
async function runTest() {
  $('startBtn').disabled = true;
  let fail = 0;
  const label = $('label').value || '未命名配置';
  const runs = Math.max(1, parseInt($('runs').value || '1', 10));
  const downMb = Math.max(1, parseInt($('downMb').value || '64', 10));
  const downs=[], idles=[], loadeds=[];
  try {
    for (let i=1;i<=runs;i++) {
      log(`第 ${i}/${runs} 轮：测空载延迟...`);
      const idle = await measurePing(5); idles.push(idle.avg); $('idleNow').textContent = idle.avg.toFixed(0);
      log(`第 ${i}/${runs} 轮：下载 ${downMb} MB...`);
      const d = await measureDownload(downMb); downs.push(d.speed); $('downNow').textContent = d.speed.toFixed(2);
      if (d.loaded) { loadeds.push(d.loaded); $('loadedNow').textContent = d.loaded.toFixed(0); }
    }
  } catch(e) {
    fail += 1;
    log('测试失败：' + e.message);
  } finally {
    const avg = arr => arr.length ? arr.reduce((a,b)=>a+b,0)/arr.length : 0;
    addRow({
      time: nowText(), label,
      down: avg(downs).toFixed(2),
      idle: avg(idles).toFixed(0), loaded: avg(loadeds).toFixed(0),
      fail, note: location.href
    });
    log('完成。切换配置后改配置名称，再继续测试。');
    $('startBtn').disabled = false;
  }
}
function exportCsv() {
  const header = ['时间','配置','下载Mbps','空载延迟ms','负载延迟ms','失败次数','备注'];
  const esc = v => `"${String(v ?? '').replaceAll('"','""')}"`;
  const csv = [header.map(esc).join(',')].concat(rows.map(r => [r.time,r.label,r.down,r.idle,r.loaded,r.fail,r.note].map(esc).join(','))).join('\n');
  const blob = new Blob([csv], {type:'text/csv;charset=utf-8'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'agsb-speedtest-' + Date.now() + '.csv';
  a.click();
  URL.revokeObjectURL(a.href);
}
$('startBtn').onclick = runTest;
$('exportBtn').onclick = exportCsv;
$('clearBtn').onclick = () => { rows.splice(0); $('rows').innerHTML=''; log('结果已清空。'); };
</script>
</body>
</html>
"""

class Handler(BaseHTTPRequestHandler):
    server_version = "AGSBWebTest/1.0"

    def log_message(self, fmt, *args):
        return

    def send_headers(self, code=200, content_type="text/plain", length=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Access-Control-Allow-Origin", "*")
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            data = HTML.encode("utf-8")
            self.send_headers(200, "text/html; charset=utf-8", len(data))
            self.wfile.write(data)
            return
        if parsed.path == "/ping":
            data = b"ok"
            self.send_headers(200, "text/plain", len(data))
            self.wfile.write(data)
            return
        if parsed.path == "/health":
            data = json.dumps({"ok": True, "time": time.time()}).encode()
            self.send_headers(200, "application/json", len(data))
            self.wfile.write(data)
            return
        if parsed.path == "/download":
            q = parse_qs(parsed.query)
            try:
                total = int(q.get("bytes", ["67108864"])[0])
            except ValueError:
                total = 67108864
            total = max(1024, min(total, 2147483648))
            block = (b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n" * 1024)
            self.send_headers(200, "application/octet-stream", total)
            sent = 0
            while sent < total:
                chunk = block[: min(len(block), total - sent)]
                self.wfile.write(chunk)
                sent += len(chunk)
            return
        self.send_headers(404, "text/plain")
        self.wfile.write(b"not found")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6080)
    args = parser.parse_args()
    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"AGSB web speedtest listening on {args.bind}:{args.port}", flush=True)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
PY
  chmod +x "$WEBTEST_SCRIPT"
}

write_service() {
  cat > "/etc/systemd/system/${WEBTEST_SERVICE}" <<EOF
[Unit]
Description=${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${WEBTEST_SCRIPT} --bind ${WEBTEST_BIND} --port ${WEBTEST_PORT}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
  require_root || return 1
  cmd_exists python3 || { red "缺少 python3，无法启动测速页。"; return 1; }
  write_server
  write_service
  systemctl daemon-reload
  systemctl enable "$WEBTEST_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$WEBTEST_SERVICE"
  green "浏览器测速网页已启动。"
  echo "访问地址: $(webtest_url)"
  echo "如果要测代理链路，请确保本地浏览器访问该地址时走当前代理。"
  echo "防火墙需要放行 TCP ${WEBTEST_PORT}。"
}

stop_service() {
  require_root || return 1
  systemctl disable --now "$WEBTEST_SERVICE" >/dev/null 2>&1 || true
  green "浏览器测速网页已停止。"
}

status_service() {
  echo "服务名: ${WEBTEST_SERVICE}"
  echo "监听: ${WEBTEST_BIND}:${WEBTEST_PORT}"
  echo "访问地址: $(webtest_url)"
  echo "本机健康检查: $(local_health_url)"
  if systemctl list-unit-files "$WEBTEST_SERVICE" >/dev/null 2>&1; then
    systemctl status "$WEBTEST_SERVICE" --no-pager -l || true
  else
    yellow "尚未安装 systemd 服务。"
  fi
}

doctor_service() {
  local public_url local_url active listen_line health

  public_url="$(webtest_url)"
  local_url="$(local_health_url)"
  cyan "=== ${APP_NAME} 诊断 ==="
  echo "服务名: ${WEBTEST_SERVICE}"
  echo "监听配置: ${WEBTEST_BIND}:${WEBTEST_PORT}"
  echo "公网访问地址: ${public_url}"
  echo "本机健康检查: ${local_url}"
  echo

  if ! cmd_exists python3; then
    red "python3 不存在，服务无法启动。"
  else
    green "python3: $(command -v python3)"
  fi

  if systemctl list-unit-files "$WEBTEST_SERVICE" >/dev/null 2>&1; then
    active="$(systemctl is-active "$WEBTEST_SERVICE" 2>/dev/null || true)"
    echo "systemd 状态: ${active}"
    if [[ "$active" != "active" ]]; then
      yellow "服务不是 active。最近日志："
      journalctl -u "$WEBTEST_SERVICE" -n 30 --no-pager 2>/dev/null || true
    fi
  else
    yellow "systemd 服务尚未安装，请先运行：sudo bash web-speedtest.sh start"
  fi

  echo
  echo "监听检查:"
  if cmd_exists ss; then
    listen_line="$(port_listener || true)"
    if [[ -n "$listen_line" ]]; then
      green "$listen_line"
    else
      red "没有进程监听 TCP ${WEBTEST_PORT}"
    fi
  else
    yellow "缺少 ss 命令，跳过监听检查。"
  fi

  echo
  echo "本机 HTTP 检查:"
  if cmd_exists curl; then
    health="$(curl -fsS --connect-timeout 2 --max-time 5 "$local_url" 2>&1 || true)"
    if [[ "$health" == *'"ok": true'* ]]; then
      green "本机访问正常: ${health}"
    else
      red "本机访问失败: ${health}"
      if systemctl list-unit-files "$WEBTEST_SERVICE" >/dev/null 2>&1; then
        yellow "最近服务日志："
        journalctl -u "$WEBTEST_SERVICE" -n 50 --no-pager -l 2>/dev/null || true
      fi
    fi
  else
    yellow "缺少 curl，跳过 HTTP 检查。"
  fi

  echo
  cyan "访问建议："
  echo "1. 先在 VPS 上确认本机 HTTP 检查正常。"
  echo "2. 本地浏览器先不要走代理，直接打开：${public_url}"
  echo "3. 如果直连能打开、走代理打不开，通常是代理回连本机公网 IP/NAT hairpin 问题。"
  echo "4. 如果直连也打不开，检查云厂商安全组/商家面板入站规则是否放行 TCP ${WEBTEST_PORT}。"
  echo "5. 也可以换端口测试：sudo WEBTEST_PORT=18080 bash web-speedtest.sh start"
}

run_foreground() {
  cmd_exists python3 || { red "缺少 python3。"; return 1; }
  if show_existing_listener; then
    return 1
  fi
  mkdir -p "$WEBTEST_DIR"
  write_server
  green "前台运行测速网页: $(webtest_url)"
  exec python3 "$WEBTEST_SCRIPT" --bind "$WEBTEST_BIND" --port "$WEBTEST_PORT"
}

uninstall_service() {
  require_root || return 1
  systemctl disable --now "$WEBTEST_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${WEBTEST_SERVICE}"
  rm -rf "$WEBTEST_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  green "已删除 ${WEBTEST_SERVICE} 和 ${WEBTEST_DIR}"
}

main_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    cyan "================================================="
    cyan "              浏览器测速网页"
    cyan "================================================="
    echo "监听地址: ${WEBTEST_BIND}:${WEBTEST_PORT}"
    echo "访问地址: $(webtest_url)"
    cyan "================================================="
    echo "  1) 启动测速网页"
    echo "  2) 停止测速网页"
    echo "  3) 重启测速网页"
    echo "  4) 查看状态"
    echo "  5) 前台运行（需先停止后台服务）"
    echo "  6) 卸载测速网页服务"
    echo "  0) 退出"
    cyan "================================================="
    read -r -p "请输入序号: " choice
    case "$choice" in
      1) start_service; read -r -p "按回车键继续..." ;;
      2) stop_service; read -r -p "按回车键继续..." ;;
      3) start_service; read -r -p "按回车键继续..." ;;
      4) status_service; read -r -p "按回车键继续..." ;;
      5) run_foreground ;;
      6) uninstall_service; read -r -p "按回车键继续..." ;;
      0) return 0 ;;
      *) red "无效序号"; sleep 1 ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    menu) main_menu ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) start_service ;;
    status) status_service ;;
    doctor) doctor_service ;;
    run) run_foreground ;;
    uninstall) uninstall_service ;;
    help|-h|--help) usage ;;
    *)
      red "未知命令: $cmd"
      usage
      return 1
      ;;
  esac
}

main "$@"
