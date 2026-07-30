# node

基于 **sing-box** 的 Linux 节点一键部署与运维工具集。提供交互式中文面板，可安装核心、批量生成多协议节点、对接 Cloudflare（DNS / 边缘证书 / Argo Tunnel / CDN）、部署伪装站点与受保护的订阅入口，并附带内核网络调优与浏览器测速页。

> 面向自用 VPS 场景；多数操作需 **root**。请遵守当地法律法规与云厂商条款。

---

## 主要功能

- **一键安装 sing-box**：自动检测架构、下载官方 release，并生成 systemd 服务
- **多协议节点生成**：VLESS Reality、Hysteria2、AnyTLS、Shadowsocks-2022、VMess-WS、TUIC v5、Argo-VLESS、CDN+VMess+WS 等
- **两种部署路径**
  - **基础协议（无 CF）**：不依赖 Cloudflare 的直连节点
  - **全协议（灰云 + 橙云 + Argo + CDN）**：结合 Cloudflare DNS、边缘证书、临时/固定隧道与 CDN 回源
- **Cloudflare 自动化**：Zone 识别、DNS 记录、橙云代理、Origin Rules、边缘证书等
- **伪装站 + Nginx**：静态业务风模板站，并反代 WebSocket / 订阅路径
- **智能订阅**：本地合并订阅文件；可选 Nginx Basic Auth + 限速的公开订阅入口
- **系统网络加速**：BBR / fq / cake 等单用户高 RTT 场景调优，支持回滚与状态报告
- **浏览器测速页**：systemd 托管的简易 HTTP 测速服务，便于对比代理链路与直连
- **状态可复用**：关键配置写入 `node.config` / `node-state.env`，支持配置文件管理与卸载清理

---

## 快速开始

若提示 `curl: command not found`，先安装 curl（Debian / Ubuntu）：

```bash
apt update && apt install -y curl
```

其他发行版示例：

```bash
# CentOS / RHEL / Fedora
dnf install -y curl   # 或: yum install -y curl

# Alpine
apk add --no-cache curl
```

一键运行：

```bash
bash <(curl -fsSL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/wuyou18075/node/refs/heads/main/node.sh?t=$RANDOM")
```

没有 curl、只有 wget 时：

```bash
bash <(wget -qO- --header="Cache-Control: no-cache" "https://raw.githubusercontent.com/wuyou18075/node/refs/heads/main/node.sh")
```

或克隆后本地运行：

```bash
git clone https://github.com/wuyou18075/node.git
cd node
sudo bash node.sh
```

主面板常用项：

| 选项 | 作用 |
|------|------|
| `1` | 安装 sing-box 核心 |
| `2` | 基础协议一键部署（无 Cloudflare） |
| `4` | 全协议：CF 灰云 + 橙云 + Argo + CDN |
| `5` | Cloudflare 橙云 DNS + 边缘证书 |
| `6` | 应用系统网络加速 |
| `7` | 查看所有节点 / 分享链接 |
| `8` | 配置节点订阅链接（Nginx 保护入口） |
| `90` | 配置文件管理（`node.config` 等） |
| `97` | 安装伪装站并由 Nginx 代理 |
| `98` | 更新 sing-box 版本 |
| `99` | 卸载本脚本产出的服务、配置与相关文件 |
| `0` | 退出 |

---

## 仓库结构与文件说明

```text
.
├── node.sh                 # 主控：安装、协议、CF、订阅、面板
├── mask-site.sh            # 伪装站 + Nginx 反代
├── cf-tunnel.sh            # Cloudflare Tunnel 独立管理
├── cf-tunnel.md            # cf-tunnel.sh 功能与使用说明
├── subscription-link.sh    # 订阅链接 Nginx 入口
├── net-deep-tune.sh        # 系统网络深度调优
├── web-speedtest.sh        # 浏览器测速网页服务
├── LICENSE                 # Apache License 2.0
└── README.md               # 本说明
```

### `node.sh`（核心，约 6k+ 行）

节点配置与订阅管理主脚本，可独立运行（内置 polyfill，不依赖外部主控框架）。

主要能力：

- 安装 / 升级 **sing-box**，生成 `config.json` 与 systemd 单元
- 交互式一键：基础协议、全协议 CF 方案
- Cloudflare API：DNS、CDN VMess 回源端口 / Origin Rules、橙云边缘证书等
- Argo / cloudflared 相关：隧道、可达性校验（HTTP/1.1 WebSocket）、订阅刷新钩子
- 生成多客户端分享内容：URI、Clash / mihomo YAML、本地合并订阅
- 状态目录：`/etc/sing-box/`、`/etc/agsb/node.config` 等
- 菜单内可调用伪装站、订阅链接、网络加速、卸载等子流程
- CLI 辅助入口示例：`--wait-tcp`、`--refresh-argo-subscription`

典型远程安装地址由脚本内 `NODE_SCRIPT_URL` 指向本仓库 `main/node.sh`。

### `mask-site.sh`

独立的 **伪装业务站 + Nginx 反向代理** 管理器。

- 一键部署 / 重建站点，或仅刷新 Nginx 配置
- 内置多套模板（如 EduPanel 在线课堂、WorkDesk、HelpCenter、MetricHub、CloudDocs）
- 与主脚本状态联动：可代理 VMess / CDN-VMess WebSocket、订阅路径等
- 站点根目录、证书、Nginx conf 路径可配置；状态写入 `/etc/sing-box/state`

命令示例：

```bash
sudo bash mask-site.sh              # 交互菜单
sudo bash mask-site.sh deploy       # 部署/重建
sudo bash mask-site.sh refresh-nginx
```

### `cf-tunnel.sh`

**Cloudflare Tunnel** 独立管理工具（不依赖完整 node 面板）。

- 新建隧道：临时 `trycloudflare.com` 域名，或绑定自有域名（API + DNS）
- 列出隧道并检查连通性
- 删除隧道与相关资源
- 自动安装 `cloudflared`，选择空闲本地端口

```bash
sudo bash cf-tunnel.sh          # 菜单
sudo bash cf-tunnel.sh create   # 新建
sudo bash cf-tunnel.sh list     # 列表
sudo bash cf-tunnel.sh delete   # 删除
```

完整功能说明与排错见 **[cf-tunnel.md](./cf-tunnel.md)**。

### `subscription-link.sh`

为节点订阅配置 **经 Nginx 保护的公开入口**。

- 读取 `node-state.env` / `node.config`
- 为订阅子路径启用 Basic Auth 与访问限速
- 页面可展示原始订阅 URL，降低明文路径被暴力扫中的风险
- 可与 `mask-site.sh` 配合使用

```bash
sudo bash subscription-link.sh configure
```

### `net-deep-tune.sh`

面向 **单用户、高 RTT 代理链路** 的系统网络调优。

- 交互看板或 CLI：`status` / `apply` / `rollback` / `reports`
- 配置档：`safe`、`aggressive`、`throughput`、`bbr-fq`、`cake` 等
- 写入 sysctl drop-in、可选 sing-box 服务资源限制、RPS/XPS
- Argo edge 池导入、排序与状态（`edge-import` / `edge-status` / `edge-rank`）
- 支持按 `RTT_MS`、`BANDWIDTH_MBPS` 等环境变量定制；可回滚并保留备份与报告

说明：脚本只能启用内核已有的 BBR 等能力，不能把普通内核“升级成 BBR3”。

### `web-speedtest.sh`

在 VPS 上起一个 **浏览器测速页**（Python + systemd），用于实验代理效果。

```bash
sudo bash web-speedtest.sh start|stop|restart|status|doctor|run|uninstall
```

- 默认监听 `0.0.0.0:6080`（可用 `WEBTEST_PORT` / `WEBTEST_BIND` 覆盖）
- 浏览器走代理时测的是代理链路；不走代理时测本机到 VPS 的直连
- `doctor` 用于排查页面打不开的原因

### `LICENSE`

Apache License 2.0。

---

## 运行环境建议

- Linux（systemd 发行版体验最佳；包管理支持 apt / dnf / yum 等）
- root 权限
- 拉脚本前本机需有 `curl` 或 `wget`（例如：`apt update && apt install -y curl`）
- 常用依赖：`curl`、`jq`、`nginx`（伪装站/订阅）、`python3`（测速页）、`cloudflared`（Argo/隧道，可由脚本安装）
- 使用 Cloudflare 相关功能时需有效 API Token 与对应 Zone 权限

---

## 常见路径（默认）

| 路径 | 含义 |
|------|------|
| `/usr/local/bin/sing-box` | sing-box 二进制 |
| `/etc/sing-box/config.json` | 核心配置 |
| `/etc/sing-box/state/` | 运行状态、隧道与站点相关 state |
| `/etc/agsb/node.config` | 可复用的节点/域名/端口等配置 |
| `/var/www/edupanel` 等 | 伪装站站点根 |
| `/etc/nginx/conf.d/agsb-edupanel.conf` | 站点 Nginx 配置 |
| `/usr/local/bin/agsb-node.sh` | 自安装后的稳定脚本路径（供 systemd 引用） |

---

## 免责声明

本仓库脚本用于服务器网络组件与配置的自动化管理。使用者需自行确保用途合法合规，并承担由此产生的全部风险与责任。作者不对滥用、误配置或服务中断导致的损失负责。
