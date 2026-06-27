#!/usr/bin/env bash
# =============================================================================
# mask-site.sh - Standalone fake business site + nginx reverse proxy manager
# =============================================================================

APP_NAME="AGSB-MaskSite"
STATE_DIR="/etc/sing-box/state"
STATE_FILE="${STATE_DIR}/node-state.env"
SSL_DIR="/etc/sing-box/cert"
SITE_BASE="/var/www"
SITE_ROOT="${SITE_ROOT:-/var/www/edupanel}"
NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/conf.d/agsb-edupanel.conf}"
SITE_DOMAIN="${SITE_DOMAIN:-}"
SITE_TEMPLATE="${SITE_TEMPLATE:-edupanel}"

red() { printf '\e[31m%s\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
cyan() { printf '\e[36m%s\e[0m\n' "$*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    red "请使用 root 权限运行：sudo bash $0"
    return 1
  fi
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == "#"* ]] && continue
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$k" in
      SITE_DOMAIN|SITE_TEMPLATE|SITE_ROOT|NGINX_SITE_CONF|DOMAIN|SNI_VAL|SELF_SIGN_CERT|VMESS_VIA_NGINX|VMESS_WS_PATH|VMESS_PORT)
        declare -g "${k}=${v}"
        ;;
    esac
  done < "$STATE_FILE"
}

state_set() {
  local key="$1" value="$2" tmp
  mkdir -p "$STATE_DIR"
  tmp="${STATE_FILE}.tmp"
  if [[ -f "$STATE_FILE" ]]; then
    grep -v -E "^${key}=" "$STATE_FILE" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  install -m 0600 "$tmp" "$STATE_FILE" 2>/dev/null || mv -f "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

save_site_state() {
  state_set SITE_ENABLED "1"
  state_set SITE_DOMAIN "$SITE_DOMAIN"
  state_set SITE_TEMPLATE "$SITE_TEMPLATE"
  state_set SITE_ROOT "$SITE_ROOT"
  state_set NGINX_SITE_CONF "$NGINX_SITE_CONF"
  state_set DOMAIN "$SITE_DOMAIN"
  state_set SNI_VAL "$SITE_DOMAIN"
  state_set SELF_SIGN_CERT "0"
}

install_packages() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}" >/dev/null 2>&1
  else
    red "未找到 apt/dnf/yum，无法自动安装依赖。"
    return 1
  fi
}

install_nginx_if_needed() {
  command -v nginx >/dev/null 2>&1 && return 0
  yellow "未检测到 nginx，正在安装..."
  install_packages nginx
}

install_certbot_if_needed() {
  command -v certbot >/dev/null 2>&1 && return 0
  yellow "未检测到 certbot，正在安装..."
  install_packages certbot
}

cert_matches_domain() {
  local cert="$1" domain="$2"
  [[ -f "$cert" && -n "$domain" ]] || return 1
  openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1
}

cert_is_valid() {
  local cert="$1"
  [[ -f "$cert" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1
}

cert_is_publicly_trusted() {
  local cert_path="$1" domain="$2"
  local cert chain leaf rc tmp_dir

  [[ -f "$cert_path" && -n "$domain" ]] || return 1
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
  ' "$cert_path"; then
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
    openssl verify -purpose sslserver -verify_hostname "$domain" -untrusted "$chain" "$leaf" >/dev/null 2>&1
  else
    openssl verify -purpose sslserver -verify_hostname "$domain" "$leaf" >/dev/null 2>&1
  fi
  rc=$?
  rm -rf "$tmp_dir"
  return "$rc"
}

copy_letsencrypt_cert() {
  local live_dir="/etc/letsencrypt/live/${SITE_DOMAIN}"
  [[ -f "${live_dir}/fullchain.pem" && -f "${live_dir}/privkey.pem" ]] || return 1
  mkdir -p "$SSL_DIR"
  install -m 0644 "${live_dir}/fullchain.pem" "${SSL_DIR}/fullchain.cer"
  install -m 0600 "${live_dir}/privkey.pem" "${SSL_DIR}/private.key"
}

write_cert_renew_hook() {
  local hook="/etc/letsencrypt/renewal-hooks/deploy/agsb-copy-${SITE_DOMAIN}.sh"
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<HOOK
#!/usr/bin/env bash
set -e
if [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem" ]]; then
  mkdir -p "${SSL_DIR}"
  install -m 0644 "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" "${SSL_DIR}/fullchain.cer"
  install -m 0600 "/etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem" "${SSL_DIR}/private.key"
  systemctl reload nginx >/dev/null 2>&1 || true
  systemctl restart sing-box >/dev/null 2>&1 || true
fi
HOOK
  chmod +x "$hook"
}

write_http_nginx_config() {
  mkdir -p "$(dirname "$NGINX_SITE_CONF")" "$SITE_ROOT"
  cat > "$NGINX_SITE_CONF" <<NGINX
# Managed by AGSB mask-site.sh. Existing nginx sites are not modified.
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN};

    root ${SITE_ROOT};
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${SITE_ROOT};
        default_type "text/plain";
    }

    location = /login { try_files /login.html =404; }
    location = /pricing { try_files /pricing.html =404; }
    location = /docs { try_files /docs.html =404; }
    location = /status { try_files /status.html =404; }
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
}

write_https_nginx_config() {
  local vmess_block=""
  if [[ "${VMESS_VIA_NGINX:-0}" == "1" && -n "${VMESS_WS_PATH:-}" && -n "${VMESS_PORT:-}" ]]; then
    vmess_block="
    location ${VMESS_WS_PATH} {
        proxy_pass http://127.0.0.1:${VMESS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }
"
  fi

  mkdir -p "$(dirname "$NGINX_SITE_CONF")"
  cat > "$NGINX_SITE_CONF" <<NGINX
# Managed by AGSB mask-site.sh. Existing nginx sites are not modified.
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN};

    root ${SITE_ROOT};

    location ^~ /.well-known/acme-challenge/ {
        root ${SITE_ROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${SITE_DOMAIN};

    ssl_certificate ${SSL_DIR}/fullchain.cer;
    ssl_certificate_key ${SSL_DIR}/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:AGSBSITESSSL:10m;

    root ${SITE_ROOT};
    index index.html;

    location = /login { try_files /login.html =404; }
    location = /pricing { try_files /pricing.html =404; }
    location = /docs { try_files /docs.html =404; }
    location = /status { try_files /status.html =404; }
${vmess_block}
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
}

reload_nginx() {
  nginx -t || return 1
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
}

ensure_real_certificate() {
  local le_cert="/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem"

  if cert_matches_domain "${SSL_DIR}/fullchain.cer" "$SITE_DOMAIN" && cert_is_valid "${SSL_DIR}/fullchain.cer"; then
    if cert_is_publicly_trusted "${SSL_DIR}/fullchain.cer" "$SITE_DOMAIN"; then
      green "检测到已存在 ${SITE_DOMAIN} 的公开可信证书，将直接使用。"
      return 0
    fi
    yellow "检测到 ${SSL_DIR}/fullchain.cer 匹配 ${SITE_DOMAIN}，但不是公开可信证书，将重新申请 Let's Encrypt。"
  fi

  if cert_matches_domain "$le_cert" "$SITE_DOMAIN" && cert_is_valid "$le_cert" && cert_is_publicly_trusted "$le_cert" "$SITE_DOMAIN"; then
    green "检测到 Let's Encrypt 已有 ${SITE_DOMAIN} 的有效证书，将同步到 ${SSL_DIR}。"
    copy_letsencrypt_cert
    write_cert_renew_hook
    return 0
  fi

  yellow "未检测到 ${SITE_DOMAIN} 的有效真实证书，开始申请 Let's Encrypt 证书。"
  yellow "请确认域名 A/AAAA 记录已指向本机，并且 TCP 80/443 已放行。"
  install_certbot_if_needed || return 1
  write_http_nginx_config
  reload_nginx || return 1

  certbot certonly --webroot -w "$SITE_ROOT" -d "$SITE_DOMAIN" \
    --agree-tos --register-unsafely-without-email --non-interactive || {
      red "证书申请失败。请检查 DNS 解析、80 端口、安全组和 certbot 输出。"
      return 1
    }

  copy_letsencrypt_cert || { red "证书申请成功，但同步证书到 ${SSL_DIR} 失败。"; return 1; }
  write_cert_renew_hook
}

write_edupanel_site() {
  mkdir -p "$SITE_ROOT"
  cat > "${SITE_ROOT}/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>EduPanel | 机构在线课堂平台</title>
  <style>
    :root{color-scheme:light;--ink:#172033;--muted:#657089;--line:#d9dee8;--brand:#176b87;--accent:#d47b36;--bg:#f5f7fb}
    *{box-sizing:border-box}body{margin:0;font-family:Inter,Arial,"Microsoft YaHei",sans-serif;color:var(--ink);background:#fff;line-height:1.55}
    header{border-bottom:1px solid var(--line);background:#fff;position:sticky;top:0;z-index:2}nav{max-width:1120px;margin:auto;height:64px;display:flex;align-items:center;justify-content:space-between;padding:0 22px}
    .brand{font-weight:800;font-size:20px;color:var(--brand)}.links{display:flex;gap:22px;align-items:center}.links a{color:#34405a;text-decoration:none;font-size:14px}.btn{border:1px solid var(--brand);color:#fff;background:var(--brand);padding:9px 14px;border-radius:6px;text-decoration:none}
    .hero{background:linear-gradient(180deg,#fff 0,#eef5f8 100%);border-bottom:1px solid var(--line)}.hero-inner{max-width:1120px;margin:auto;padding:64px 22px 56px;display:grid;grid-template-columns:1.15fr .85fr;gap:38px;align-items:center}
    h1{font-size:42px;line-height:1.16;margin:0 0 18px;letter-spacing:0}.lead{font-size:18px;color:var(--muted);margin:0 0 26px}.actions{display:flex;gap:12px;flex-wrap:wrap}.ghost{background:#fff;color:var(--brand)}
    .panel{border:1px solid var(--line);border-radius:8px;background:#fff;box-shadow:0 12px 30px rgba(24,38,60,.08);padding:20px}.metric{display:grid;grid-template-columns:1fr 1fr;gap:12px}.metric div{background:var(--bg);border:1px solid #e7ebf2;border-radius:6px;padding:14px}.metric strong{display:block;font-size:24px}.metric span{color:var(--muted);font-size:13px}
    section{max-width:1120px;margin:auto;padding:42px 22px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.card{border:1px solid var(--line);border-radius:8px;padding:20px;background:#fff}.card h3{margin:0 0 8px}.card p{margin:0;color:var(--muted)}
    footer{border-top:1px solid var(--line);padding:24px 22px;color:var(--muted);font-size:13px;text-align:center}
    @media(max-width:760px){.hero-inner{grid-template-columns:1fr;padding-top:38px}.links{gap:12px}.links a:not(.btn){display:none}h1{font-size:30px}.grid{grid-template-columns:1fr}}
  </style>
</head>
<body>
  <header><nav><div class="brand">EduPanel</div><div class="links"><a href="/pricing">价格</a><a href="/docs">帮助中心</a><a href="/status">服务状态</a><a class="btn" href="/login">机构登录</a></div></nav></header>
  <main>
    <div class="hero"><div class="hero-inner"><div><h1>面向机构的在线课堂与学习运营平台</h1><p class="lead">EduPanel 为培训机构和企业学习团队提供课程排期、直播课堂、作业批改、学习数据和成员权限管理。</p><div class="actions"><a class="btn" href="/login">进入控制台</a><a class="btn ghost" href="/docs">查看文档</a></div></div><div class="panel"><div class="metric"><div><strong>99.95%</strong><span>近 30 天服务可用性</span></div><div><strong>12ms</strong><span>课堂调度平均响应</span></div><div><strong>86</strong><span>已接入机构工作区</span></div><div><strong>24/7</strong><span>课程服务监控</span></div></div></div></div></div>
    <section class="grid"><article class="card"><h3>课程管理</h3><p>统一管理班级、课节、讲师、教材和学习任务。</p></article><article class="card"><h3>直播与回放</h3><p>支持课前提醒、课后回放归档和学习进度追踪。</p></article><article class="card"><h3>机构权限</h3><p>按校区、部门、角色分配访问权限，减少误操作。</p></article></section>
  </main>
  <footer>© 2026 EduPanel Learning Systems. All rights reserved.</footer>
</body>
</html>
HTML

  cat > "${SITE_ROOT}/login.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>机构登录 | EduPanel</title>
  <style>
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f7fb;font-family:Inter,Arial,"Microsoft YaHei",sans-serif;color:#172033}
    .box{width:min(420px,calc(100vw - 32px));background:#fff;border:1px solid #d9dee8;border-radius:8px;padding:26px;box-shadow:0 12px 30px rgba(24,38,60,.08)}
    h1{font-size:22px;margin:0 0 6px}.sub{color:#657089;margin:0 0 22px;font-size:14px}label{display:block;font-size:13px;margin:14px 0 6px}
    input{width:100%;height:42px;border:1px solid #cfd6e3;border-radius:6px;padding:0 12px;font-size:15px}button{width:100%;height:42px;border:0;border-radius:6px;background:#176b87;color:white;font-weight:700;margin-top:20px;cursor:pointer}
    .msg{display:none;margin-top:14px;padding:12px;border:1px solid #e7caa8;background:#fff8ef;border-radius:6px;color:#7a4b19;font-size:14px}
    a{color:#176b87;text-decoration:none}.foot{margin-top:18px;color:#657089;font-size:13px}
  </style>
</head>
<body>
  <form class="box" id="login"><h1>EduPanel 机构登录</h1><p class="sub">仅限已开通的机构工作区访问。</p><label>企业邮箱</label><input autocomplete="off" inputmode="email"><label>密码</label><input type="password" autocomplete="off"><label>机构代码</label><input autocomplete="off"><button id="btn">登录</button><div class="msg" id="msg">当前系统仅限受邀机构访问，请联系管理员开通。</div><div class="foot"><a href="/docs">帮助中心</a> · <a href="/status">服务状态</a></div></form>
  <script>
    document.getElementById('login').addEventListener('submit',function(e){e.preventDefault();var b=document.getElementById('btn');b.disabled=true;b.textContent='正在验证';setTimeout(function(){document.getElementById('msg').style.display='block';b.disabled=false;b.textContent='登录';},900);});
  </script>
</body>
</html>
HTML

  cat > "${SITE_ROOT}/pricing.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>价格 | EduPanel</title><style>body{font-family:Arial,"Microsoft YaHei",sans-serif;margin:0;color:#172033}main{max-width:960px;margin:auto;padding:42px 22px}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:18px}.card{border:1px solid #d9dee8;border-radius:8px;padding:22px}a{color:#176b87}@media(max-width:700px){.grid{grid-template-columns:1fr}}</style></head><body><main><p><a href="/">EduPanel</a></p><h1>机构版价格</h1><div class="grid"><div class="card"><h2>机构标准版</h2><p>适合中小培训机构，包含课程、学员、讲师和作业管理。</p><strong>按工作区报价</strong></div><div class="card"><h2>企业培训版</h2><p>适合多部门培训和合规学习，包含权限审计与数据报表。</p><strong>联系客户经理</strong></div></div></main></body></html>
HTML

  cat > "${SITE_ROOT}/docs.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>帮助中心 | EduPanel</title><style>body{font-family:Arial,"Microsoft YaHei",sans-serif;margin:0;color:#172033}main{max-width:860px;margin:auto;padding:42px 22px}li{margin:10px 0}a{color:#176b87}</style></head><body><main><p><a href="/">EduPanel</a></p><h1>帮助中心</h1><ul><li>如何创建课程和班级</li><li>如何邀请讲师与助教</li><li>如何查看学员学习进度</li><li>如何导出机构运营报表</li></ul></main></body></html>
HTML

  cat > "${SITE_ROOT}/status.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>服务状态 | EduPanel</title><style>body{font-family:Arial,"Microsoft YaHei",sans-serif;margin:0;color:#172033;background:#f6f8fb}main{max-width:760px;margin:auto;padding:42px 22px}.ok{border:1px solid #c9dfd0;background:white;border-radius:8px;padding:18px}a{color:#176b87}</style></head><body><main><p><a href="/">EduPanel</a></p><h1>服务状态</h1><div class="ok"><strong>所有系统运行正常</strong><p>课堂调度、账号服务、报表服务和消息通知当前无异常。</p></div></main></body></html>
HTML
}

write_placeholder_site() {
  local title="$1" desc="$2"
  mkdir -p "$SITE_ROOT"
  cat > "${SITE_ROOT}/index.html" <<HTML
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><style>body{font-family:Arial,"Microsoft YaHei",sans-serif;margin:0;color:#172033;background:#f6f8fb}main{max-width:920px;margin:auto;padding:56px 22px}.box{background:white;border:1px solid #d9dee8;border-radius:8px;padding:28px}a{color:#176b87}</style></head><body><main><div class="box"><h1>${title}</h1><p>${desc}</p><p><a href="/login">控制台登录</a> · <a href="/status">服务状态</a></p></div></main></body></html>
HTML
  cat > "${SITE_ROOT}/login.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>登录</title><style>body{font-family:Arial,"Microsoft YaHei",sans-serif;display:grid;place-items:center;min-height:100vh;background:#f6f8fb}.box{width:min(420px,calc(100vw - 32px));background:white;border:1px solid #d9dee8;border-radius:8px;padding:24px}input,button{width:100%;height:42px;margin-top:12px;box-sizing:border-box}button{background:#176b87;color:white;border:0;border-radius:6px}.msg{display:none;margin-top:12px;color:#7a4b19}</style></head><body><form class="box" id="f"><h1>工作区登录</h1><input placeholder="企业邮箱" autocomplete="off"><input placeholder="密码" type="password" autocomplete="off"><button>登录</button><div class="msg" id="m">当前系统仅限受邀机构访问，请联系管理员开通。</div></form><script>document.getElementById('f').onsubmit=function(e){e.preventDefault();setTimeout(function(){document.getElementById('m').style.display='block'},800)}</script></body></html>
HTML
  cp "${SITE_ROOT}/index.html" "${SITE_ROOT}/pricing.html"
  cp "${SITE_ROOT}/index.html" "${SITE_ROOT}/docs.html"
  cp "${SITE_ROOT}/index.html" "${SITE_ROOT}/status.html"
}

select_template() {
  local choice
  cyan "请选择伪装站模板："
  echo "  1) EduPanel 在线课堂（推荐）"
  echo "  2) WorkDesk 企业协作"
  echo "  3) HelpCenter 工单帮助台"
  echo "  4) MetricHub 数据看板"
  echo "  5) CloudDocs 企业文档"
  read -r -p "请输入序号 [默认 1]: " choice
  case "${choice:-1}" in
    1) SITE_TEMPLATE="edupanel"; SITE_ROOT="${SITE_BASE}/edupanel"; NGINX_SITE_CONF="/etc/nginx/conf.d/agsb-edupanel.conf"; write_edupanel_site ;;
    2) SITE_TEMPLATE="workdesk"; SITE_ROOT="${SITE_BASE}/workdesk"; NGINX_SITE_CONF="/etc/nginx/conf.d/agsb-workdesk.conf"; write_placeholder_site "WorkDesk" "面向团队的项目协作、任务排期和组织知识库平台。" ;;
    3) SITE_TEMPLATE="helpcenter"; SITE_ROOT="${SITE_BASE}/helpcenter"; NGINX_SITE_CONF="/etc/nginx/conf.d/agsb-helpcenter.conf"; write_placeholder_site "HelpCenter" "面向客户服务团队的工单流转、知识库和服务质量分析平台。" ;;
    4) SITE_TEMPLATE="metrichub"; SITE_ROOT="${SITE_BASE}/metrichub"; NGINX_SITE_CONF="/etc/nginx/conf.d/agsb-metrichub.conf"; write_placeholder_site "MetricHub" "面向运营团队的数据指标、报表订阅和服务状态看板。" ;;
    5) SITE_TEMPLATE="clouddocs"; SITE_ROOT="${SITE_BASE}/clouddocs"; NGINX_SITE_CONF="/etc/nginx/conf.d/agsb-clouddocs.conf"; write_placeholder_site "CloudDocs" "面向企业内部的文档协作、版本管理和权限审计平台。" ;;
    *) red "无效模板。"; return 1 ;;
  esac
}

deploy_site() {
  local input_domain
  require_root || return 1
  load_state
  install_nginx_if_needed || { red "nginx 安装失败。"; return 1; }

  read -r -p "请输入站点域名(必须是真实解析到本机的域名): " input_domain
  SITE_DOMAIN="$(printf '%s' "$input_domain" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')"
  if [[ -z "$SITE_DOMAIN" ]]; then
    red "站点必须使用真实域名，不能留空，也不会使用自签证书。"
    return 1
  fi

  select_template || return 1
  ensure_real_certificate || return 1
  write_https_nginx_config
  reload_nginx || return 1
  save_site_state

  green "伪装站部署完成。"
  echo "站点地址: https://${SITE_DOMAIN}/"
  echo "模板: ${SITE_TEMPLATE}"
  echo "站点目录: ${SITE_ROOT}"
  echo "nginx 配置: ${NGINX_SITE_CONF}"
  echo "证书目录: ${SSL_DIR}"
}

main_menu() {
  while true; do
    clear
    cyan "================================================="
    cyan "              伪装站点与 nginx 代理"
    cyan "================================================="
    echo "  1) 一键部署/重建伪装站"
    echo "  2) 仅刷新 nginx 配置"
    echo "  0) 返回/退出"
    cyan "================================================="
    read -r -p "请输入序号: " choice
    case "$choice" in
      1) deploy_site; echo "按回车键继续..."; read -r ;;
      2)
        load_state
        if [[ -z "${SITE_DOMAIN:-}" ]]; then
          red "未检测到已部署站点。"
        else
          write_https_nginx_config && reload_nginx && green "nginx 配置已刷新。"
        fi
        echo "按回车键继续..."; read -r
        ;;
      0) return 0 ;;
      *) red "无效输入。"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  deploy)
    deploy_site
    ;;
  refresh-nginx)
    load_state
    write_https_nginx_config && reload_nginx
    ;;
  *)
    main_menu
    ;;
esac
