# cf-tunnel.sh

独立的 **Cloudflare Tunnel 管理工具**。只负责隧道的新建、列表（连通性）与删除，不生成 sing-box 节点配置。可与本仓库主脚本共用状态目录，但**不会被 `node.sh` 自动调用**，需单独运行。

---

## 功能概览

| 功能 | 说明 |
|------|------|
| 新建临时隧道 | 不填 API Token，启动 Quick Tunnel，得到 `*.trycloudflare.com` 域名 |
| 新建固定隧道 | 填写 API Token，创建/复用 Named Tunnel，配置 Public Hostname 与 DNS CNAME |
| 查看隧道 | 列出账号下所有未删除隧道，并显示状态 / 连接数 |
| 删除隧道 | 按序号（可多选）删除 Named Tunnel |
| 依赖处理 | 自动检查并安装 `curl`、`jq`；缺失时安装 `cloudflared` |

---

## 环境要求

- Linux，**root** 权限（脚本启动时会检查）
- 网络可访问 Cloudflare / GitHub（下载 `cloudflared`）
- Named Tunnel 相关操作需要有效的 **Cloudflare API Token**（需具备 Tunnel、DNS、Zone 等权限）
- 域名必须已在 Cloudflare 托管（Named Tunnel 会按域名自动匹配 Zone）

默认路径：

| 项 | 默认值 |
|----|--------|
| `cloudflared` | `/usr/local/bin/cloudflared` |
| 状态目录 | `/etc/sing-box/state` |
| API | `https://api.cloudflare.com/client/v4` |

---

## 快速使用

```bash
# 交互菜单
sudo bash cf-tunnel.sh

# 或直接指定子命令
sudo bash cf-tunnel.sh create   # 新建（也可 new / 1）
sudo bash cf-tunnel.sh list     # 列表（也可 ls / 2）
sudo bash cf-tunnel.sh delete   # 删除（也可 del / rm / 3）
```

远程一键（若已推送到本仓库）：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/wuyou18075/node/refs/heads/main/cf-tunnel.sh")
```

---

## 菜单说明

```text
1) 新建隧道
   - 输入 Token → 创建 Named Tunnel（固定域名）
   - 留空 Token → 快速随机隧道 (trycloudflare)
2) 查看所有隧道 (带连通性检测)
3) 删除隧道
0) 退出
```

### 1. 新建隧道

#### A. 临时隧道（Quick Tunnel）

1. 选择「新建」后，**API Token 直接回车留空**
2. 输入本地 HTTP 服务端口；留空则在 `50000–60000` 随机选空闲端口
3. 脚本后台启动：

   ```text
   cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:<端口>
   ```

4. 从日志中解析 `https://xxxx.trycloudflare.com`，打印域名、本地端口、PID、日志路径
5. 停止方式：对打印的 PID 执行 `kill <pid>`

特点：无需 Cloudflare 账号配置，适合临时暴露本机端口；域名与进程非持久，机器重启后失效。

#### B. 固定隧道（Named Tunnel）

1. 输入 **Cloudflare API Token**
2. 输入隧道域名，例如 `tunnel.example.com`（会去掉 `http(s)://` 与路径）
3. 输入本地服务端口（可留空自动分配）
4. 脚本依次完成：
   - 校验 Token，按域名查找 Zone / Account
   - 按域名派生隧道名，**查询或创建** Named Tunnel
   - 拉取 Tunnel Token
   - 配置 Public Hostname：`域名 → http://localhost:<端口>`
   - 配置 DNS：将域名 **CNAME** 到 `<tunnel-id>.cfargotunnel.com`（清理冲突的非 CNAME 记录）
5. 完成后打印域名、Tunnel ID、本地端口、Zone，以及在目标机上运行 connector 的命令，例如：

   ```bash
   /usr/local/bin/cloudflared tunnel --no-autoupdate run --token <TOKEN>
   ```

说明：Named Tunnel 的 API 侧配置在本机完成；**真正转发流量**需要你在「提供本地服务的那台机器」上用上面的 token 持续运行 `cloudflared`（可用 systemd 自行托管）。

### 2. 查看所有隧道

1. 输入 API Token（输入时不回显）
2. 拉取当前 Account 下 `is_deleted=false` 的隧道（最多 100 条）
3. 表格字段大致包括：序号、名称、状态、创建时间、连接信息

状态含义（展示用）：

| 状态 | 含义（简要） |
|------|----------------|
| healthy | 健康 |
| degraded | 降级 |
| down | 离线 |
| inactive | 未激活 |
| 连接数 > 0 | 显示在线连接数 |

### 3. 删除隧道

1. 输入 API Token 并列出隧道（含 Tunnel ID）
2. 输入要删除的**序号**，多个用逗号分隔，如 `1,2,3`
3. 确认后调用 API `DELETE .../cfd_tunnel/<id>`
4. 输出成功/失败数量

注意：删除的是 Cloudflare 侧 Named Tunnel 资源；本机若仍有 `cloudflared` 进程，需自行停止。临时 Quick Tunnel 不在此列表中（它们没有 Named Tunnel 记录）。

---

## 与 node.sh 的关系

| | `cf-tunnel.sh` | `node.sh` 内置 Argo |
|--|----------------|---------------------|
| 定位 | 纯 Tunnel 增删查 | 节点一键里的 Argo-VLESS 等 |
| 协议/节点 | 不生成 | 生成 URI / 订阅等 |
| 调用关系 | 独立脚本 | 不调用 `cf-tunnel.sh` |
| 状态目录 | 默认 `/etc/sing-box/state` | 同目录体系 |

需要「只开一个公网入口指到本机端口」时用本脚本；需要完整节点方案时用 `node.sh`。

---

## 常见问题

**Q: 提示请使用 root？**  
A: 使用 `sudo bash cf-tunnel.sh`。

**Q: 临时隧道 30 秒内没打出域名？**  
A: 按提示 `tail -f` 日志文件；检查本机出网、是否被墙、`cloudflared` 是否正常。

**Q: Named Tunnel 报 Zone / Token 失败？**  
A: 确认域名在 CF 的 DNS 已接入，Token 权限包含 Account Tunnel、Zone DNS 等；Token 对应账号能管理该域名。

**Q: 配置完成但访问不通？**  
A: 确认本机 `localhost:<端口>` 已有 HTTP 服务，且已执行 `cloudflared tunnel run --token ...`；检查 DNS 是否已生效。

**Q: 能否开机自启 Named Tunnel？**  
A: 本工具不安装 systemd unit；Named Tunnel 的常驻运行需自行写 service 或用 screen/tmux 保活。

---

## 许可证

与本仓库相同，见根目录 [LICENSE](./LICENSE)（Apache License 2.0）。
