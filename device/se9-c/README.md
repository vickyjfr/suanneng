# SE9 NAS 部署与运维 / SE9 NAS Deployment and Operations

## 中文

### 1. 组件与部署范围

本说明适用于本目录的 C 设备程序，目标环境为安装了 systemd 的 Linux NAS（项目目标为 Ubuntu 22.04）。所有源码命令从 `nas` 项目根目录执行；`/path/to/nas`、`<device-id>`、`/path/to/ssh-private-key` 等必须替换为实际值。先按章节顺序完成首次部署；已有设备使用第 10 节升级流程。

- `se9_file_api`：独立文件服务，读写 `STORAGE_ROOT`，处理目录、分片上传、下载、Range 下载、重命名及删除。
- `se9_agent`：UDP 发现与加密绑定、云端注册/心跳，以及云端 WebSocket 到本机 File API 的转发。
- `cmd/cloud`：运行在阿里云的 Go 控制面和中继；不在 NAS 上重复部署。
- `mobile`：Flutter App，登录后通过 `device_list` 展示账号绑定的设备，再按设备上传和下载。

实际文件保存在 NAS，阿里云不保存上传文件。本项目使用独立存储目录，不自动继承 VOS 用户或权限。File API 当前提供 HTTP；端口名为 `8443` 或 `18443` 不表示已启用 HTTPS。云端 HTTP 对应 WS，HTTPS 对应 WSS。

### 2. 当前服务器信息与网络路径

以下阿里云信息于 **2026-10-20** 通过服务器只读查询核对；设备侧是本文的建议部署值，不能视为已在实体 NAS 上安装。当前 Mac 本地测试程序已停止。

| 项目 | 当前值 |
| --- | --- |
| 阿里云公网 IP / 架构 | `123.56.147.51` / `aarch64`（Linux ARM64） |
| App 云端基地址 | `http://123.56.147.51/se9` |
| Agent 内置云端地址 / 前缀 | `http://123.56.147.51:80` / `/se9`；无需配置服务器环境变量 |
| 公网入口 | Nginx，HTTP TCP `80`，URL 前缀 `/se9/` |
| Go 后端监听 | TCP `18082`；进程实际监听 `:18082`，Nginx 访问 `127.0.0.1:18082` |
| 云端服务 / 用户 | `se9-cloud.service` / `se9-cloud` |
| 云端程序 / 工作目录 | `/opt/se9-cloud/se9-cloud` / `/opt/se9-cloud` |
| 云端环境文件 / unit | `/etc/se9-cloud.env` / `/etc/systemd/system/se9-cloud.service` |
| 账号、设备归属、设备凭证哈希、会话状态 | `/var/lib/se9-cloud/cloud-state.json` |
| 刷新凭证状态 | `/var/lib/se9-cloud/auth-refresh.json` |
| 最近一次已部署版本的备份 | `/opt/se9-cloud/backups/20261020T014607Z-device-list` |
| 公网健康检查 | `http://123.56.147.51/se9/health` |
| 账号设备接口 | `GET /se9/api/v2/device_list`，兼容 `/se9/api/v2/devices`；需用户 Bearer Token |

当前公网基地址为 HTTP，Go 服务未配置直接 TLS；这是现有联调配置。改为正式 HTTPS/WSS 时，先在 Nginx 或 Go 配置可验证的证书，再同步更新 Agent 和 App 的云端地址。

```text
手机 App --HTTP/WS--> 123.56.147.51:80/se9/
                          |
                      Nginx 去掉 /se9/ 前缀
                          |
                      Go :18082
                          |
                 NAS Agent 主动向云端建立 WS
                          |
                 127.0.0.1:18443 File API
                          |
                 /vos/workspace/demo

首次发现和绑定：手机 <---局域网 UDP 37020---> NAS Agent
```

| 位置 | 端口 / 方向 | 用途 |
| --- | --- | --- |
| NAS | UDP `37020`，局域网入站 | 手机发现、握手和绑定；固定端口，不能通过环境变量修改 |
| NAS | TCP `18443`，仅本机 | 本文的 File API 端口；源码默认 `8443` |
| NAS | 出站 TCP `80` | 当前云端注册、心跳、绑定准备和 WS；使用 HTTPS 时改为目标端口，默认 `443` |
| 云端 | 入站 TCP `80` | 当前 App 和 Agent 的公网入口 |
| 云端 | TCP `18082` | Go 后端；安全组/主机防火墙应限制公网直接访问，仅通过 Nginx 入口使用 |

手机首次绑定需与 NAS 位于允许 UDP 通信的同一局域网；访客 Wi-Fi、AP 隔离和 VPN 可能阻断发现。绑定后通过账号设备列表进行远程文件操作，不依赖局域网发现。NAS 不需要公网 IP 或路由器入站端口映射。若启用防火墙，只对实际手机局域网网段放行 UDP `37020`，不要直接套用一个未知网段的规则。

### 3. 编译与运行依赖

在目标 NAS 上编译最直接。确认系统时钟已同步、存储卷已挂载、能访问阿里云；OpenSSL 动态库必须可用。

```bash
cd /path/to/nas
uname -m
sudo apt-get update
sudo apt-get install -y build-essential cmake libssl-dev ca-certificates curl openssl
cmake -S device/se9-c -B build/se9-c -DCMAKE_BUILD_TYPE=Release
cmake --build build/se9-c --parallel 2
file build/se9-c/se9_agent build/se9-c/se9_file_api
ldd build/se9-c/se9_agent
ldd build/se9-c/se9_file_api
```

`file` 的架构应与 NAS 的 `uname -m` 对应，`ldd` 不应出现 `not found`。Mac 上生成的 Mach-O 程序不能复制到 Linux NAS 使用。交叉编译还需匹配目标 Linux 架构、sysroot 和 OpenSSL 库，不能只改文件名。

### 4. 目录、用户与权限

先确认 `/vos/workspace` 是预期的数据卷；若不是，在执行以下创建存储目录的命令前换成实际挂载点。这里仅对专用子目录授权，不对整个 VOS 数据卷递归修改权限。

```bash
getent passwd se9 >/dev/null || sudo useradd --system --user-group --home-dir /var/lib/se9 --shell /usr/sbin/nologin se9
sudo install -d -o root -g root -m 0755 /opt/se9
sudo install -d -o root -g se9 -m 0750 /etc/se9
sudo install -d -o se9 -g se9 -m 0750 /var/lib/se9 /var/log/se9
findmnt -T /vos/workspace
sudo install -d -o se9 -g se9 -m 0750 /vos/workspace/demo
sudo install -o root -g root -m 0755 build/se9-c/se9_file_api /opt/se9/se9_file_api
sudo install -o root -g root -m 0755 build/se9-c/se9_agent /opt/se9/se9_agent
```

| 路径 | 所有者 / 权限 | 用途 |
| --- | --- | --- |
| `/opt/se9` | `root:root`，目录 0755、程序 0755 | 两个可执行文件 |
| `/etc/se9` | `root:se9`，目录 0750、环境文件 0640 | 配置及本机代理密钥 |
| `/var/lib/se9` | `se9:se9`，目录 0750 | 设备长期私钥、云端设备 token |
| `/var/log/se9` | `se9:se9`，目录 0750 | stdout/stderr 日志 |
| `/vos/workspace/demo` | `se9:se9`，目录 0750 | 专用文件存储及 `.uploading` 临时目录 |

### 5. 全部设备参数与配置文件

程序不接受命令行参数，也不自动读取 `.env`；它们通过环境变量获取配置。systemd 的 `EnvironmentFile` 负责注入参数；前台调试时需自行加载或导出。以下默认值来自当前 C 源码，不代表旧示例文件里的值。

#### 5.1 File API 参数

| 参数 | 源码默认值 | 本文值 / 含义 |
| --- | --- | --- |
| `STORAGE_ROOT` | `/vos/workspace/demo` | 所有文件和上传临时目录的根；必须可写，并与 systemd 的 `ReadWritePaths` 一致 |
| `FILE_API_PORT` | `8443` | 本文使用 `18443`；有效 TCP 端口，必须与 Agent 完全一致 |
| `FILE_API_BIND_ADDR` | `127.0.0.1` | 远程中继模式保留回环；局域网直连可用 `0.0.0.0` 并限制防火墙来源；当前只支持 IPv4 |
| `DEMO_ADMIN_PASSWORD` | `change-me` | 本地 `admin` 登录密码；与云端 App 账号密码相互独立，首次部署生成随机值 |
| `SE9_AGENT_PROXY_TOKEN` | 空 | Agent 与 File API 共用的代理密钥；两边必须相同，建议 `openssl rand -hex 32` |

#### 5.2 Agent 参数

| 参数 | 源码默认值 | 本文值 / 含义 |
| --- | --- | --- |
| `SE9_DEVICE_NAME` | `SE9 NAS` | App 中的设备名称；保持简短，避免引号、反斜杠等当前简易 JSON 编码无法处理的字符 |
| `SE9_KEY_FILE` | `/var/lib/se9/device-ed25519.pem` | Ed25519 长期设备私钥；首次启动自动生成，文件 0600；更换私钥会改变设备 ID |
| `SE9_TOKEN_FILE` | `/var/lib/se9/device-token` | 云端注册成功后保存的设备 token，文件 0600；升级保留 |
| `SE9_CLOUD_URL` | `http://123.56.147.51:80` | 阿里云 IP 和公网端口已内置；一般不配置。仅调试或迁移时可覆盖为协议、主机和端口，不包含 `/se9` 或 `/api/v2` |
| `SE9_CLOUD_BASE_PATH` | `/se9` | 阿里云反向代理前缀已内置；一般不配置。直连 Go 后端测试可显式设为空字符串 |
| `FILE_API_PORT` | `8443` | Agent 固定连接 `127.0.0.1:<此端口>`；本文为 `18443` |
| `SE9_AGENT_PROXY_TOKEN` | 空 | 必须与 File API 配置一致；为空时远程转发不可用 |
| `SE9_CA_FILE` | `/etc/ssl/certs/ca-certificates.crt` | 使用 HTTPS/WSS 时读取的 CA bundle；需存在且服务用户可读 |
| `SE9_TLS_INSECURE` | 关闭 | 只有精确设置为 `1` 才跳过证书校验；本文为 `0`；正式环境保留校验 |

**`SE9_FILE_API_URL` 当前不生效。** 旧 `deploy/se9-agent.env.example` 虽含该项，但源码没有读取；改变本机服务端口必须在两个环境文件中都设置 `FILE_API_PORT`。不要把 App 的 `SE9_CLOUD_API` 当成 Agent 参数。`deviceId` 自动由长期公钥派生，没有手工指定的环境变量。

内置地址为 `http://123.56.147.51:80`，内置前缀为 `/se9`；有效公网基地址为 `http://123.56.147.51:80/se9`，使用 Nginx 公网端口 80，不直接连接 Go 内部端口 18082。环境变量仅保留用于调试和迁移；未设置时完全使用程序内置值。HTTP 未指定端口时使用 `80`，HTTPS 使用 `443`。应使用含端口修复的当前源码编译 Agent，旧程序可能仍错误地将无端口的 HTTP 地址连到 `8080`。

#### 5.3 首次部署时生成配置

服务器地址已内置，下面生成的 Agent 配置不需要云端地址字段；已有环境文件中的服务器地址仍会覆盖内置值，若希望使用内置值，请移除原 `SE9_CLOUD_URL` 和 `SE9_CLOUD_BASE_PATH` 配置行后重启 Agent。下列脚本仅用于两个环境文件均不存在的首次部署。它先检查文件不存在，再生成随机本地密码和同一份代理密钥，不输出密钥内容；已有部署直接保留并按需编辑原文件。随机本地密码保存在 File API 环境文件中，通过授权管理方式读取；App 远程模式使用云端账号，不需要该本地密码。

```bash
sudo bash <<'SH'
set -euo pipefail
test ! -e /etc/se9/se9-file-api.env
test ! -e /etc/se9/se9-agent.env
umask 0077
proxy_secret=$(openssl rand -hex 32)
local_password=$(openssl rand -hex 24)
cat > /etc/se9/se9-file-api.env <<EOF
STORAGE_ROOT=/vos/workspace/demo
FILE_API_PORT=18443
FILE_API_BIND_ADDR=127.0.0.1
DEMO_ADMIN_PASSWORD=$local_password
SE9_AGENT_PROXY_TOKEN=$proxy_secret
EOF
cat > /etc/se9/se9-agent.env <<EOF
SE9_DEVICE_NAME="SE9 NAS"
SE9_KEY_FILE=/var/lib/se9/device-ed25519.pem
SE9_TOKEN_FILE=/var/lib/se9/device-token
FILE_API_PORT=18443
SE9_AGENT_PROXY_TOKEN=$proxy_secret
SE9_CA_FILE=/etc/ssl/certs/ca-certificates.crt
SE9_TLS_INSECURE=0
EOF
chown root:se9 /etc/se9/se9-file-api.env /etc/se9/se9-agent.env
chmod 0640 /etc/se9/se9-file-api.env /etc/se9/se9-agent.env
SH
```

私钥与设备 token 由 Agent 生成，不能把另一台 NAS 的这两个文件复制来充当新设备。已有设备必须保留原私钥和 token，不能为了“重新绑定”删除它们。

### 6. 安装 systemd 服务并启动

从项目根目录执行：

```bash
sudo install -o root -g root -m 0644 deploy/se9-file-api.service /etc/systemd/system/se9-file-api.service
sudo install -o root -g root -m 0644 deploy/se9-agent.service /etc/systemd/system/se9-agent.service
sudo install -o root -g root -m 0644 deploy/se9-logrotate /etc/logrotate.d/se9
sudo systemctl daemon-reload
sudo systemctl enable --now se9-file-api.service
sudo systemctl enable --now se9-agent.service
systemctl is-active se9-file-api.service se9-agent.service
sudo ss -lntp 'sport = :18443'
sudo ss -lunp 'sport = :37020'
curl -fsS http://127.0.0.1:18443/api/v2/health
```

正常结果为两个服务均 `active`；TCP `18443` 绑定 `127.0.0.1`，UDP `37020` 绑定 `0.0.0.0`；健康接口返回 `code: "0"`、`data.status: "ok"`。Agent unit 已依赖 File API；显式先启动 File API 便于排错。unit 的 `EnvironmentFile=-...` 允许缺失配置仍启动，因此务必先确认第 5 节两个文件存在，否则程序会使用源码默认值。

如果使用 `/mnt/nas/se9-data` 等自定义存储路径，先创建并授权专用目录，在 File API 环境文件中修改 `STORAGE_ROOT`，再执行 `sudo systemctl edit se9-file-api.service` 写入以下 drop-in；路径仅为示例，必须替换：

```ini
[Service]
ReadWritePaths=
ReadWritePaths=/mnt/nas/se9-data /var/lib/se9 /var/log/se9
```

然后运行 `sudo systemctl daemon-reload` 和 `sudo systemctl restart se9-file-api.service se9-agent.service`。只修改环境变量而不调整 `ProtectSystem=strict` 下的可写目录，会出现写入失败。外部数据卷需在服务启动前挂载；可在 File API unit 的 `[Unit]` drop-in 中添加 `RequiresMountsFor=/实际/存储路径`。程序和环境文件不要放在 `/home`，因为模板启用了 `ProtectHome=true`。

### 7. 启动验收、绑定和 App 上传下载

```bash
curl -fsS http://123.56.147.51/se9/health
sudo tail -n 80 /var/log/se9/agent.error.log
sudo tail -n 80 /var/log/se9/file-api.error.log
sudo journalctl -u se9-agent.service -u se9-file-api.service -n 80 --no-pager
sudo timedatectl status
sudo -u se9 test -w /vos/workspace/demo
sudo -u se9 test -w /var/lib/se9
```

Agent 的 `[CLOUD] .../devices/register status=201` 表示注册成功；首次可观察 `/var/lib/se9/device-token` 文件生成。心跳每 30 秒发送一次，设备列表超过 90 秒没有心跳会显示离线。注册只在进程启动时尝试；初次网络故障导致注册失败且没有 token 时，恢复网络后重启 Agent。

日志实际写入 `/var/log/se9/agent.log`、`agent.error.log`、`file-api.log`、`file-api.error.log`；systemd 启停失败看 `journalctl`，业务问题优先看文件日志。stdout 重定向时可能缓冲，stderr 的 `[CLOUD]`、`[UDP]` 日志更及时。没有 App 会话时，Agent 的中继连接可能周期性关闭并重试；不能只凭一条 WS 连接关闭记录断言注册失败。

App 的云端地址与 NAS 的设置不同：

```bash
cd mobile
flutter pub get
flutter run -d "<device-id>" --dart-define=SE9_CLOUD_API=http://123.56.147.51/se9
```

1. 手机使用云端账号注册或登录。首次绑定时与 NAS 位于同一局域网，点击“发现并绑定设备”，选择设备绑定。
2. 日志应先出现握手，再出现 `/claim/prepare status=200`，App 随后向云端确认绑定。不要再次绑定已经属于当前账号的设备。
3. “我的设备”加载当前账号已绑定的设备；已有绑定无需再次发现。离线时先启动 NAS，再点“刷新设备列表”。
4. 在线设备点击“上传”，选择相册图片、视频或文件。目录路径留空表示存储根目录；成功后刷新文件列表。
5. 点击“文件 / 下载”进入所选设备目录，文件行点击下载图标并选择保存位置；图片可通过右侧菜单预览。切换设备回到根目录。
6. 在 NAS 的 `STORAGE_ROOT` 下核对文件和大小，再下载核对内容；不要仅以进度条达到 100% 作为上传成功依据，服务还需合并文件。

局域网 HTTP 直连是可选模式：File API 必须仍可通过 `127.0.0.1` 被 Agent 访问，建议设为 `0.0.0.0` 并仅允许可信 LAN；App 可另传 `--dart-define=SE9_API=http://<nas-lan-ip>:18443`。不要把云端账号凭证等同于本地 `admin` 凭证。当前主流程使用账号设备列表和云端中继。

### 8. 阿里云服务参数与 Nginx 配置

现有服务器已经部署，日常只做检查和升级，不应重新创建用户或覆盖配置。以下是实际参数及 unit；未展示真实密码或设备 token。

`/etc/se9-cloud.env` 已核对的非敏感配置：

```dotenv
PORT=18082
AUTH_STATE_FILE=/var/lib/se9-cloud/auth-refresh.json
CLOUD_STATE_FILE=/var/lib/se9-cloud/cloud-state.json
```

| 云端参数 | 源码默认值 | 配置说明 |
| --- | --- | --- |
| `PORT` | `8080` | 当前 `18082`；程序监听 `:<PORT>`，不是自动绑定回环 |
| `AUTH_STATE_FILE` | `./data/auth-refresh.json` | 刷新凭证哈希持久化文件 |
| `CLOUD_STATE_FILE` | `./data/cloud-state.json` | 用户、账号映射、设备归属和会话状态 |
| `DEMO_ADMIN_PASSWORD` | `change-me` | 初始化默认 `admin` 用户的密码；已有用户状态加载后优先保留，改环境变量不会重置已有密码 |
| `DEMO_PASSWORD_RESET_CODE` | `change-me-reset` | Demo 找回密码校验码；真实值不写入文档，正式配置需替换默认值 |
| `TLS_CERT_FILE` | 空 | Go 直接提供 HTTPS/WSS 时的证书文件；须与私钥同时配置 |
| `TLS_KEY_FILE` | 空 | 与证书配套的私钥；当前服务未配置 Go 直接 TLS |

`/etc/systemd/system/se9-cloud.service`：

```ini
[Unit]
Description=SE9 Cloud Demo API and WebSocket Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=se9-cloud
Group=se9-cloud
WorkingDirectory=/opt/se9-cloud
EnvironmentFile=/etc/se9-cloud.env
ExecStart=/opt/se9-cloud/se9-cloud
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/se9-cloud

[Install]
WantedBy=multi-user.target
```

云端用户应能写 `/var/lib/se9-cloud`，读环境文件；程序由 root 管理。服务持久化目录应保留原所有者，备份含账号和凭证信息应限制权限。当前不需要在云端部署 NAS 的 File API 或开放 UDP `37020`。

Nginx 已有的 `/se9/` 位置规则如下，位于现有 `server` 块内，不是完整的 `nginx.conf`；更新时不要替换其他业务的 `location /`。本次核对的配置文件为 `/etc/nginx/conf.d/psync-ip.conf` 与 `/etc/nginx/conf.d/psync.conf`；可用 `sudo nginx -T` 确认当前生效配置。

```nginx
location ^~ /se9/ {
    proxy_pass http://127.0.0.1:18082/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 1200s;
    proxy_send_timeout 1200s;
    client_max_body_size 128m;
}
```

`proxy_pass` 末尾 `/` 会去掉 `/se9/`：公网 `/se9/api/v2/device_list` 对应 Go 的 `/api/v2/device_list`。直接访问 `127.0.0.1:18082` 时不能再加 `/se9`。WebSocket 的 `Upgrade`、`Connection` 和 HTTP/1.1 必须保留。修改后先 `sudo nginx -t`，通过后 `sudo systemctl reload nginx`。

```bash
sudo systemctl is-active se9-cloud.service nginx
curl -fsS http://127.0.0.1:18082/health
curl -fsS http://123.56.147.51/se9/health
curl -i http://123.56.147.51/se9/api/v2/device_list
sudo journalctl -u se9-cloud.service -n 80 --no-pager
sudo nginx -t
```

公网健康检查应返回 200；不带 Token 的设备列表应返回 **401**，这表示认证拦截正常。检查实际账号列表时使用 App 登录返回的短期 access token，不用 NAS 的设备 token 或刷新 token：

```bash
read -r -s -p 'Access token: ' SE9_ACCESS_TOKEN
printf '\n'
curl -fsS -H "Authorization: Bearer $SE9_ACCESS_TOKEN" \
  'http://123.56.147.51/se9/api/v2/device_list?page=1&pageSize=100'
unset SE9_ACCESS_TOKEN
```

账号设备接口的分页、字段和错误码见 [SE9_API.md](../../SE9_API.md)。空列表表示当前账号没有绑定设备，需与“设备离线但仍在列表中”区分。

### 9. 云端程序升级

源码最低 Go 版本见根目录 `go.mod`，当前声明 `go 1.25.0`。在开发机编译匹配当前 ARM64 服务器的程序并上传；Mac 可使用 `shasum`，Linux 使用 `sha256sum`。服务器上操作要有读取配置、停止服务和写 `/opt/se9-cloud` 的权限。

```bash
cd /path/to/nas
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/se9-cloud-linux-arm64 ./cmd/cloud
shasum -a 256 dist/se9-cloud-linux-arm64
scp -i /path/to/ssh-private-key dist/se9-cloud-linux-arm64 root@123.56.147.51:/tmp/se9-cloud.new
```

在服务器上核对上传文件 SHA-256 与开发机一致，再执行以下维护步骤；这会短暂停止 SE9 云端服务。每对 `sha256sum` 的结果必须相同，不同则不要继续替换：

```bash
SE9_CLOUD_UPDATE_ID=$(date -u +%Y%m%dT%H%M%SZ)
sudo install -d -o root -g root -m 0700 "/opt/se9-cloud/backups/$SE9_CLOUD_UPDATE_ID"
sudo systemctl stop se9-cloud.service
sudo cp -a /opt/se9-cloud/se9-cloud /etc/se9-cloud.env /var/lib/se9-cloud "/opt/se9-cloud/backups/$SE9_CLOUD_UPDATE_ID/"
sudo install -o root -g root -m 0755 /tmp/se9-cloud.new /opt/se9-cloud/se9-cloud.new
sha256sum /tmp/se9-cloud.new /opt/se9-cloud/se9-cloud.new
sudo mv /opt/se9-cloud/se9-cloud.new /opt/se9-cloud/se9-cloud
sudo systemctl start se9-cloud.service
curl -fsS http://127.0.0.1:18082/health
```

升级不覆盖原环境文件和两个 JSON 状态文件。完成后再验证公网 `/se9/health` 为 200、未认证 `/se9/api/v2/device_list` 为 401，并用 App 原账号刷新列表。失败时停止服务，从本次备份目录恢复旧 `se9-cloud` 二进制并启动；除非明确需要数据恢复，不回写旧状态文件，以免丢失升级后的有效操作。

### 10. NAS 升级、回滚与停止

升级前等待上传任务结束并备份重要文件；当前分片会话索引在内存中，File API 重启不会恢复原 upload ID，未完成任务需要重建上传会话。以下备份只包含配置、身份和程序，不包含整个用户存储卷，存储备份需另行安排。

```bash
cmake --build build/se9-c --parallel 2
SE9_UPDATE_ID=$(date -u +%Y%m%dT%H%M%SZ)
sudo install -d -o root -g root -m 0700 "/var/backups/se9/$SE9_UPDATE_ID"
sudo systemctl stop se9-agent.service se9-file-api.service
sudo cp -a /opt/se9/se9_agent /opt/se9/se9_file_api "/var/backups/se9/$SE9_UPDATE_ID/"
sudo cp -a /etc/se9 /var/lib/se9 "/var/backups/se9/$SE9_UPDATE_ID/"
sudo install -o root -g root -m 0755 build/se9-c/se9_agent /opt/se9/se9_agent.new
sudo install -o root -g root -m 0755 build/se9-c/se9_file_api /opt/se9/se9_file_api.new
sha256sum build/se9-c/se9_agent /opt/se9/se9_agent.new
sha256sum build/se9-c/se9_file_api /opt/se9/se9_file_api.new
sudo mv /opt/se9/se9_agent.new /opt/se9/se9_agent
sudo mv /opt/se9/se9_file_api.new /opt/se9/se9_file_api
sudo systemctl start se9-file-api.service se9-agent.service
curl -fsS http://127.0.0.1:18443/api/v2/health
```

执行替换前确认每对 SHA-256 相同；已有端口不是 `18443` 时，健康检查 URL 使用原端口。更换配置后只需 restart；更改 unit/drop-in 后还需 daemon-reload。失败时恢复旧程序：

```bash
SE9_BACKUP="/var/backups/se9/<update-id>"
sudo systemctl stop se9-agent.service se9-file-api.service
sudo install -o root -g root -m 0755 "$SE9_BACKUP/se9_file_api" /opt/se9/se9_file_api
sudo install -o root -g root -m 0755 "$SE9_BACKUP/se9_agent" /opt/se9/se9_agent
sudo systemctl start se9-file-api.service se9-agent.service
```

默认不恢复旧私钥、token 或用户文件，防止覆盖当前身份与有效数据。只有确认身份文件损坏且备份属于同一设备时才做专门恢复。

停止服务；第二条命令仅在还希望取消开机启动时执行：

```bash
sudo systemctl stop se9-agent.service se9-file-api.service
sudo systemctl disable se9-agent.service se9-file-api.service
```

停止不删除上传文件、配置、私钥或 token。若只需临时暂停，使用第一条；稍后用 `sudo systemctl start se9-file-api.service se9-agent.service` 恢复。

### 11. 常见故障

| 现象 | 检查与处理 |
| --- | --- |
| App “绑定交换失败”，日志 `status=0 bytes=0` | NAS 上先访问公网 `/se9/health`；检查出站网络、云端主机/前缀、HTTP 端口；旧 Agent 的默认 HTTP 端口错误需重新编译升级 |
| 发现成功但没有握手响应 | 检查 UDP 37020、Wi-Fi/AP 隔离、手机权限和时间；请求时间允许偏差 5 分钟；仅发现成功不代表云端可达 |
| `/claim/prepare` 返回 409 | 设备已绑定；同一账号直接使用“我的设备”，不同账号需按设备归属管理流程处理，不能通过删设备私钥绕过 |
| 注册失败后一直离线 | 检查云端可达、token 文件和日志；首次注册失败且没有 token 时恢复网络后重启 Agent |
| 设备存在但显示离线 | 检查 30 秒心跳、Agent 服务及日志；超过 90 秒判离线；恢复后刷新设备列表 |
| 列表 401 / 404 / 502 | 401 重新获取有效用户 access token；404 检查 `/se9` 是否漏写/重复；502 检查 Nginx 到 18082、后端服务及反代配置 |
| 列表正常但文件上传下载失败 | 核对两个 `FILE_API_PORT`、两个代理密钥、回环健康检查和 WebSocket Upgrade；不要依赖无效的 `SE9_FILE_API_URL` |
| `bind/listen` / Address already in use | 用 `ss` 找占用者；避免同时运行前台副本和 systemd；端口修改两份 env 后重启两个服务 |
| Permission denied / Read-only file system | 检查 se9 用户、实际挂载、存储目录所有权和 `ReadWritePaths`；不要修改整个 VOS 数据卷权限来绕过 |
| HTTPS 证书校验失败 | 检查系统时间、CA 文件、完整证书链、域名与证书匹配；保留 `SE9_TLS_INSECURE=0` 并修复证书配置 |
| 重启后设备 ID 变化或注册冲突 | 检查是否换了私钥或使用了不同 `SE9_KEY_FILE`；保留同一设备原始身份；不要重置云端状态 |
| 看不到程序日志 | 业务日志在 `/var/log/se9`，stdout 可能缓冲；journal 主要用于 systemd 级故障 |

### 12. 验证边界与相关文档

本机联调已覆盖账号设备列表、账号隔离、加密绑定、WS 中继、8 MB 分片上传、超过 8 MB 下载、SHA-256、Range 续传、重命名和删除，步骤见 [LOCAL_VALIDATION.md](LOCAL_VALIDATION.md)。阿里云部署和公网接口已经核对，实体 NAS 的存储挂载、长期运行和目标系统构建仍需在设备上验收。

当前 Agent 单帧上限为 16 MiB（包含 HTTP 报文），不是无限制流式中继；App 默认 8 MiB 分片。大于单帧上限的整文件远程下载不能视为已支持，Range 只是底层能力，当前 App 的普通下载不会自动拆成多个 Range。完整 JSON 解析、多用户文件权限隔离、局域网 File API TLS，以及跨进程重启的上传状态恢复仍是后续工作。

相关入口：[部署目录说明](../../deploy/README.md)、[云端说明](../../cmd/cloud/README.md)、[接口文档](../../SE9_API.md)、[整体设计](../../PROJECT_DESIGN.md)。

## English

### 1. Components and deployment scope

This guide covers the C device programs in this directory on a Linux NAS with systemd; the project targets Ubuntu 22.04. Run source commands from the `nas` project root and replace `/path/to/nas`, `<device-id>`, `/path/to/ssh-private-key`, and similar placeholders. Follow the sections in order for a fresh installation; use section 10 for existing devices.

- `se9_file_api`: independent file service using `STORAGE_ROOT`, with directories, chunked uploads, downloads, Range downloads, renaming, and deletion.
- `se9_agent`: UDP discovery and encrypted claiming, cloud registration/heartbeats, and WebSocket forwarding from the cloud to the local File API.
- `cmd/cloud`: Go control plane and relay deployed on Alibaba Cloud, not an additional NAS service.
- `mobile`: Flutter app that lists the account's bound devices through `device_list`, then uploads and downloads through the selected device.

File contents stay on the NAS, not in cloud storage. The dedicated storage directory does not automatically inherit VOS users or permissions. The current File API speaks HTTP; a port named `8443` or `18443` does not enable HTTPS. Cloud HTTP uses WS; HTTPS uses WSS.

### 2. Current server information and network paths

The Alibaba Cloud values below were checked through read-only server queries on **2026-10-20**. Device values are this guide's proposed configuration, not evidence that a physical NAS has been installed. The Mac's local test programs remain stopped.

| Item | Current value |
| --- | --- |
| Cloud public IP / architecture | `123.56.147.51` / `aarch64` (Linux ARM64) |
| App cloud base URL | `http://123.56.147.51/se9` |
| Agent built-in cloud URL / prefix | `http://123.56.147.51:80` / `/se9`; no cloud environment variables required |
| Public entry | Nginx, HTTP TCP `80`, URL prefix `/se9/` |
| Go listener | TCP `18082`; process listens on `:18082`, Nginx connects to `127.0.0.1:18082` |
| Cloud service / user | `se9-cloud.service` / `se9-cloud` |
| Executable / working directory | `/opt/se9-cloud/se9-cloud` / `/opt/se9-cloud` |
| Environment file / unit | `/etc/se9-cloud.env` / `/etc/systemd/system/se9-cloud.service` |
| Users, device ownership, credential hashes, sessions | `/var/lib/se9-cloud/cloud-state.json` |
| Refresh credential state | `/var/lib/se9-cloud/auth-refresh.json` |
| Backup from the latest deployment | `/opt/se9-cloud/backups/20261020T014607Z-device-list` |
| Public health endpoint | `http://123.56.147.51/se9/health` |
| Account device endpoint | `GET /se9/api/v2/device_list`, alias `/se9/api/v2/devices`; user bearer token required |

The public base URL currently uses HTTP, and Go direct TLS is not configured. This is the existing integration setup. To move to HTTPS/WSS, configure a verifiable certificate in Nginx or Go first, then update both Agent and App cloud URLs.

```text
Mobile App --HTTP/WS--> 123.56.147.51:80/se9/
                            |
                       Nginx strips /se9/
                            |
                         Go :18082
                            |
               NAS Agent initiates outbound WS
                            |
                  127.0.0.1:18443 File API
                            |
                  /vos/workspace/demo

Initial discovery/claiming: phone <---LAN UDP 37020---> NAS Agent
```

| Location | Port / direction | Purpose |
| --- | --- | --- |
| NAS | UDP `37020`, LAN inbound | Discovery, handshake, claiming; fixed in code, not configurable through environment variables |
| NAS | TCP `18443`, loopback only | This guide's File API port; source default is `8443` |
| NAS | Outbound TCP `80` | Current registration, heartbeats, claim preparation, WS; HTTPS uses its target port, normally `443` |
| Cloud | Inbound TCP `80` | Current public App and Agent entry |
| Cloud | TCP `18082` | Go backend; restrict direct public access with security group/host firewall and use Nginx |

Initial claiming requires the phone and NAS to share a LAN that permits UDP. Guest Wi-Fi, AP isolation, and VPNs can block discovery. Once bound, remote file operations use the account device list without LAN discovery. The NAS needs neither a public IP nor router inbound port forwarding. If a firewall is enabled, permit UDP `37020` only from the actual phone LAN subnet; do not copy a rule for an unknown subnet.

### 3. Build and runtime dependencies

Building on the target NAS is the most direct option. Verify clock synchronization, storage mounts, and cloud connectivity. The OpenSSL runtime libraries must be available.

```bash
cd /path/to/nas
uname -m
sudo apt-get update
sudo apt-get install -y build-essential cmake libssl-dev ca-certificates curl openssl
cmake -S device/se9-c -B build/se9-c -DCMAKE_BUILD_TYPE=Release
cmake --build build/se9-c --parallel 2
file build/se9-c/se9_agent build/se9-c/se9_file_api
ldd build/se9-c/se9_agent
ldd build/se9-c/se9_file_api
```

The `file` architecture must match `uname -m`; `ldd` must not report `not found`. A macOS Mach-O executable cannot run on a Linux NAS. Cross-compilation requires the correct Linux target architecture, sysroot, and OpenSSL libraries; renaming a file is insufficient.

### 4. Directories, user, and permissions

Check that `/vos/workspace` is the intended data volume before creating the storage subdirectory below. Replace it with the real mount if necessary. Grant access only to the dedicated directory, not recursively to the entire VOS volume.

```bash
getent passwd se9 >/dev/null || sudo useradd --system --user-group --home-dir /var/lib/se9 --shell /usr/sbin/nologin se9
sudo install -d -o root -g root -m 0755 /opt/se9
sudo install -d -o root -g se9 -m 0750 /etc/se9
sudo install -d -o se9 -g se9 -m 0750 /var/lib/se9 /var/log/se9
findmnt -T /vos/workspace
sudo install -d -o se9 -g se9 -m 0750 /vos/workspace/demo
sudo install -o root -g root -m 0755 build/se9-c/se9_file_api /opt/se9/se9_file_api
sudo install -o root -g root -m 0755 build/se9-c/se9_agent /opt/se9/se9_agent
```

| Path | Owner / permissions | Purpose |
| --- | --- | --- |
| `/opt/se9` | `root:root`, directory 0755, executables 0755 | Two executables |
| `/etc/se9` | `root:se9`, directory 0750, environment files 0640 | Configuration and shared proxy secret |
| `/var/lib/se9` | `se9:se9`, directory 0750 | Long-lived device key and cloud device token |
| `/var/log/se9` | `se9:se9`, directory 0750 | stdout/stderr logs |
| `/vos/workspace/demo` | `se9:se9`, directory 0750 | Dedicated file storage and `.uploading` temporary directory |

### 5. Complete device parameters and configuration

The programs do not accept command-line options or load `.env` files themselves; they read environment variables. systemd injects them using `EnvironmentFile`; foreground debugging requires loading/exporting them manually. Defaults below come from current C source, not older example files.

#### 5.1 File API parameters

| Parameter | Source default | Guide value / meaning |
| --- | --- | --- |
| `STORAGE_ROOT` | `/vos/workspace/demo` | Root for files and upload staging; must be writable and match systemd `ReadWritePaths` |
| `FILE_API_PORT` | `8443` | This guide uses `18443`; valid TCP port, identical to Agent configuration |
| `FILE_API_BIND_ADDR` | `127.0.0.1` | Keep loopback for relay access; optional LAN direct access can use `0.0.0.0` with firewall restrictions; currently IPv4 only |
| `DEMO_ADMIN_PASSWORD` | `change-me` | Local `admin` password, independent of cloud App credentials; generated randomly for a new install |
| `SE9_AGENT_PROXY_TOKEN` | Empty | Shared Agent/File API secret; both values must match, preferably generated with `openssl rand -hex 32` |

#### 5.2 Agent parameters

| Parameter | Source default | Guide value / meaning |
| --- | --- | --- |
| `SE9_DEVICE_NAME` | `SE9 NAS` | App device name; keep it short and avoid quotes/backslashes unsupported by current simple JSON encoding |
| `SE9_KEY_FILE` | `/var/lib/se9/device-ed25519.pem` | Long-lived Ed25519 key, generated on first start with mode 0600; changing it changes device ID |
| `SE9_TOKEN_FILE` | `/var/lib/se9/device-token` | Cloud registration token persisted with mode 0600; preserve during upgrades |
| `SE9_CLOUD_URL` | `http://123.56.147.51:80` | Cloud IP and public port are built in; normally leave unset. Override only for debugging/migration with scheme, host and port, without `/se9` or `/api/v2` |
| `SE9_CLOUD_BASE_PATH` | `/se9` | Built-in proxy prefix; normally leave unset. Explicitly set an empty string when testing against Go directly |
| `FILE_API_PORT` | `8443` | Agent always connects to `127.0.0.1:<port>`; this guide uses `18443` |
| `SE9_AGENT_PROXY_TOKEN` | Empty | Identical to File API value; remote forwarding is unavailable when empty |
| `SE9_CA_FILE` | `/etc/ssl/certs/ca-certificates.crt` | CA bundle for HTTPS/WSS; must exist and be readable by the service user |
| `SE9_TLS_INSECURE` | Disabled | Only the exact value `1` bypasses certificate verification; this guide uses `0`; keep verification enabled in production |

**`SE9_FILE_API_URL` is currently ignored.** The older `deploy/se9-agent.env.example` includes it, but source code never reads it. Set `FILE_API_PORT` in both environment files to change the local port. The App's `SE9_CLOUD_API` is not an Agent parameter. `deviceId` is derived from the long-lived public key, with no environment override.

The built-in URL is `http://123.56.147.51:80`, with prefix `/se9`, yielding `http://123.56.147.51:80/se9`. It uses Nginx public port 80 rather than Go internal port 18082. Environment overrides remain for debugging/migration; unset variables use the built-in values. HTTP without an explicit port uses `80`, HTTPS uses `443`. Compile current source containing the port fix; older Agent executables may incorrectly connect portless HTTP URLs to `8080`.

#### 5.3 Generate configuration on a fresh installation

Cloud settings are built in, so the generated Agent configuration omits them. Existing cloud environment values still override the built-in settings; remove the old `SE9_CLOUD_URL` and `SE9_CLOUD_BASE_PATH` lines and restart Agent to use the built-ins. Use the following script only when both environment files are absent. It checks that first, generates a random local password and one shared proxy secret, and does not print secrets. Preserve and edit existing configuration instead of rerunning it. The generated local password is stored in the File API environment file and can be read through authorized administration. Remote App access uses cloud credentials and does not require this local password.

```bash
sudo bash <<'SH'
set -euo pipefail
test ! -e /etc/se9/se9-file-api.env
test ! -e /etc/se9/se9-agent.env
umask 0077
proxy_secret=$(openssl rand -hex 32)
local_password=$(openssl rand -hex 24)
cat > /etc/se9/se9-file-api.env <<EOF
STORAGE_ROOT=/vos/workspace/demo
FILE_API_PORT=18443
FILE_API_BIND_ADDR=127.0.0.1
DEMO_ADMIN_PASSWORD=$local_password
SE9_AGENT_PROXY_TOKEN=$proxy_secret
EOF
cat > /etc/se9/se9-agent.env <<EOF
SE9_DEVICE_NAME="SE9 NAS"
SE9_KEY_FILE=/var/lib/se9/device-ed25519.pem
SE9_TOKEN_FILE=/var/lib/se9/device-token
FILE_API_PORT=18443
SE9_AGENT_PROXY_TOKEN=$proxy_secret
SE9_CA_FILE=/etc/ssl/certs/ca-certificates.crt
SE9_TLS_INSECURE=0
EOF
chown root:se9 /etc/se9/se9-file-api.env /etc/se9/se9-agent.env
chmod 0640 /etc/se9/se9-file-api.env /etc/se9/se9-agent.env
SH
```

The Agent generates the private key and device token. Do not copy another NAS's identity files to create a new device. Existing devices must retain their original key and token; deleting them is not a rebinding procedure.

### 6. Install and start systemd services

Run from the project root:

```bash
sudo install -o root -g root -m 0644 deploy/se9-file-api.service /etc/systemd/system/se9-file-api.service
sudo install -o root -g root -m 0644 deploy/se9-agent.service /etc/systemd/system/se9-agent.service
sudo install -o root -g root -m 0644 deploy/se9-logrotate /etc/logrotate.d/se9
sudo systemctl daemon-reload
sudo systemctl enable --now se9-file-api.service
sudo systemctl enable --now se9-agent.service
systemctl is-active se9-file-api.service se9-agent.service
sudo ss -lntp 'sport = :18443'
sudo ss -lunp 'sport = :37020'
curl -fsS http://127.0.0.1:18443/api/v2/health
```

Both services should be `active`, TCP `18443` should bind `127.0.0.1`, UDP `37020` should bind `0.0.0.0`, and health should return `code: "0"`, `data.status: "ok"`. The Agent unit already requires File API; starting File API first makes diagnosis easier. The units use optional `EnvironmentFile=-...`, so missing files do not prevent startup; ensure both configuration files exist before starting, or source defaults will apply.

For custom storage such as `/mnt/nas/se9-data`, create and authorize the directory, update `STORAGE_ROOT`, and run `sudo systemctl edit se9-file-api.service` to add the following drop-in. Replace the example path:

```ini
[Service]
ReadWritePaths=
ReadWritePaths=/mnt/nas/se9-data /var/lib/se9 /var/log/se9
```

Then run `sudo systemctl daemon-reload` and `sudo systemctl restart se9-file-api.service se9-agent.service`. Changing only the environment variable without adjusting writable paths under `ProtectSystem=strict` causes write failures. Mount external storage before service start; a File API `[Unit]` drop-in may use `RequiresMountsFor=/actual/storage/path`. Do not keep executables or environment files under `/home`; the templates enable `ProtectHome=true`.

### 7. Acceptance checks, claiming, and App transfers

```bash
curl -fsS http://123.56.147.51/se9/health
sudo tail -n 80 /var/log/se9/agent.error.log
sudo tail -n 80 /var/log/se9/file-api.error.log
sudo journalctl -u se9-agent.service -u se9-file-api.service -n 80 --no-pager
sudo timedatectl status
sudo -u se9 test -w /vos/workspace/demo
sudo -u se9 test -w /var/lib/se9
```

Agent `[CLOUD] .../devices/register status=201` means registration succeeded; on a fresh device, check that `/var/lib/se9/device-token` was created. Heartbeats run every 30 seconds; the device list reports offline after 90 seconds without a heartbeat. Registration is attempted at process startup only. If the initial attempt failed and no token exists, restore connectivity and restart the Agent.

Logs are written to `/var/log/se9/agent.log`, `agent.error.log`, `file-api.log`, and `file-api.error.log`. Use `journalctl` for systemd/start failures and file logs for application events. Redirected stdout may buffer; stderr `[CLOUD]` and `[UDP]` messages are more immediate. With no App session, relay connections may close and retry periodically; one WS closure alone does not prove registration failed.

The App cloud URL differs from the NAS settings:

```bash
cd mobile
flutter pub get
flutter run -d "<device-id>" --dart-define=SE9_CLOUD_API=http://123.56.147.51/se9
```

1. Register/login with cloud credentials. For initial claiming, use the same LAN as the NAS, select “发现并绑定设备”, and bind the device.
2. Expect a handshake followed by `/claim/prepare status=200`; the App then confirms the claim with the cloud. Do not rebind a device already owned by this account.
3. “我的设备” lists the current account's bound devices without discovery. For offline devices, start the NAS and refresh the device list.
4. Choose “上传” on an online card to select photos, videos, or files. An empty directory path means the storage root; successful uploads refresh the file list.
5. Choose “文件 / 下载” to browse the selected device. Use a file's download icon to choose a save location, or its menu to preview supported images. Switching devices resets the path to the root.
6. Check the file and size under NAS `STORAGE_ROOT`, then download and verify contents. A 100% chunk progress bar alone does not prove completion; the server still must merge the upload.

LAN direct HTTP is optional: File API must remain reachable at `127.0.0.1` by the Agent, so use `0.0.0.0` with trusted-LAN firewall restrictions. The App can additionally use `--dart-define=SE9_API=http://<nas-lan-ip>:18443`. Cloud account credentials and local `admin` credentials are independent. The primary flow uses account devices and the cloud relay.

### 8. Alibaba Cloud parameters and Nginx configuration

The existing server is deployed already; routine work should inspect and upgrade it, not recreate users or overwrite configuration. The actual parameters and unit follow, with no real passwords or device tokens included.

Verified non-secret configuration in `/etc/se9-cloud.env`:

```dotenv
PORT=18082
AUTH_STATE_FILE=/var/lib/se9-cloud/auth-refresh.json
CLOUD_STATE_FILE=/var/lib/se9-cloud/cloud-state.json
```

| Cloud parameter | Source default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Currently `18082`; Go listens on `:<PORT>`, not automatically on loopback |
| `AUTH_STATE_FILE` | `./data/auth-refresh.json` | Refresh credential hash persistence |
| `CLOUD_STATE_FILE` | `./data/cloud-state.json` | Users, account mapping, device ownership, sessions |
| `DEMO_ADMIN_PASSWORD` | `change-me` | Initializes default `admin`; loaded users take precedence, so changing this variable does not reset an existing password |
| `DEMO_PASSWORD_RESET_CODE` | `change-me-reset` | Demo password-reset code; do not publish the real value, replace default for a production configuration |
| `TLS_CERT_FILE` | Empty | Certificate for Go direct HTTPS/WSS; must be configured together with its key |
| `TLS_KEY_FILE` | Empty | Matching private key; Go direct TLS is currently not configured |

`/etc/systemd/system/se9-cloud.service`:

```ini
[Unit]
Description=SE9 Cloud Demo API and WebSocket Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=se9-cloud
Group=se9-cloud
WorkingDirectory=/opt/se9-cloud
EnvironmentFile=/etc/se9-cloud.env
ExecStart=/opt/se9-cloud/se9-cloud
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/se9-cloud

[Install]
WantedBy=multi-user.target
```

The cloud user needs write access to `/var/lib/se9-cloud` and read access to the environment file. Root manages the executable. Preserve persistent-directory ownership and restrict backups containing account/credential data. Do not deploy NAS File API on the cloud or open UDP `37020` there.

The existing Nginx location below belongs inside a current `server` block, not a complete `nginx.conf`. Preserve other services' `location /`. The checked files are `/etc/nginx/conf.d/psync-ip.conf` and `/etc/nginx/conf.d/psync.conf`; confirm active configuration with `sudo nginx -T`.

```nginx
location ^~ /se9/ {
    proxy_pass http://127.0.0.1:18082/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 1200s;
    proxy_send_timeout 1200s;
    client_max_body_size 128m;
}
```

The trailing slash in `proxy_pass` strips `/se9/`: public `/se9/api/v2/device_list` becomes Go `/api/v2/device_list`. Direct `127.0.0.1:18082` URLs must not include `/se9`. Preserve HTTP/1.1, `Upgrade`, and `Connection` for WebSocket. After changes, run `sudo nginx -t`, then `sudo systemctl reload nginx` only if validation succeeds.

```bash
sudo systemctl is-active se9-cloud.service nginx
curl -fsS http://127.0.0.1:18082/health
curl -fsS http://123.56.147.51/se9/health
curl -i http://123.56.147.51/se9/api/v2/device_list
sudo journalctl -u se9-cloud.service -n 80 --no-pager
sudo nginx -t
```

Public health should return 200. An unauthenticated device-list request should return **401**, confirming the authentication guard. To inspect an account's actual devices, use the short-lived access token returned by App login, not the NAS device token or a refresh token:

```bash
read -r -s -p 'Access token: ' SE9_ACCESS_TOKEN
printf '\n'
curl -fsS -H "Authorization: Bearer $SE9_ACCESS_TOKEN" \
  'http://123.56.147.51/se9/api/v2/device_list?page=1&pageSize=100'
unset SE9_ACCESS_TOKEN
```

See [SE9_API.md](../../SE9_API.md) for pagination, fields, and errors. An empty account list differs from an offline device that remains listed.

### 9. Cloud executable upgrades

See root `go.mod` for the minimum source Go version, currently `go 1.25.0`. Build for the current ARM64 cloud host and upload from the development machine. macOS can use `shasum`; Linux uses `sha256sum`. Remote operations need configuration-read, service-control, and executable-write permissions.

```bash
cd /path/to/nas
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o dist/se9-cloud-linux-arm64 ./cmd/cloud
shasum -a 256 dist/se9-cloud-linux-arm64
scp -i /path/to/ssh-private-key dist/se9-cloud-linux-arm64 root@123.56.147.51:/tmp/se9-cloud.new
```

On the server, compare the uploaded SHA-256 with the development build, then perform the maintenance steps below. They briefly stop the SE9 cloud service. Each pair of printed SHA-256 values must match; do not replace the executable if they differ:

```bash
SE9_CLOUD_UPDATE_ID=$(date -u +%Y%m%dT%H%M%SZ)
sudo install -d -o root -g root -m 0700 "/opt/se9-cloud/backups/$SE9_CLOUD_UPDATE_ID"
sudo systemctl stop se9-cloud.service
sudo cp -a /opt/se9-cloud/se9-cloud /etc/se9-cloud.env /var/lib/se9-cloud "/opt/se9-cloud/backups/$SE9_CLOUD_UPDATE_ID/"
sudo install -o root -g root -m 0755 /tmp/se9-cloud.new /opt/se9-cloud/se9-cloud.new
sha256sum /tmp/se9-cloud.new /opt/se9-cloud/se9-cloud.new
sudo mv /opt/se9-cloud/se9-cloud.new /opt/se9-cloud/se9-cloud
sudo systemctl start se9-cloud.service
curl -fsS http://127.0.0.1:18082/health
```

Keep the original environment and both JSON state files. Afterwards check public `/se9/health` returns 200, unauthenticated `/se9/api/v2/device_list` returns 401, and refresh devices in the App using the existing account. On failure stop the service, restore the prior `se9-cloud` executable from this backup, and restart. Do not restore older state unless explicitly recovering data, because that could discard valid post-upgrade actions.

### 10. NAS upgrades, rollback, and stopping

Let uploads finish and back up important files before upgrading. Upload-session indexes are in memory; a File API restart does not restore previous upload IDs, so unfinished tasks must create new sessions. This backup covers programs, configuration, and identity, not the whole user storage volume; plan data-volume backups separately.

```bash
cmake --build build/se9-c --parallel 2
SE9_UPDATE_ID=$(date -u +%Y%m%dT%H%M%SZ)
sudo install -d -o root -g root -m 0700 "/var/backups/se9/$SE9_UPDATE_ID"
sudo systemctl stop se9-agent.service se9-file-api.service
sudo cp -a /opt/se9/se9_agent /opt/se9/se9_file_api "/var/backups/se9/$SE9_UPDATE_ID/"
sudo cp -a /etc/se9 /var/lib/se9 "/var/backups/se9/$SE9_UPDATE_ID/"
sudo install -o root -g root -m 0755 build/se9-c/se9_agent /opt/se9/se9_agent.new
sudo install -o root -g root -m 0755 build/se9-c/se9_file_api /opt/se9/se9_file_api.new
sha256sum build/se9-c/se9_agent /opt/se9/se9_agent.new
sha256sum build/se9-c/se9_file_api /opt/se9/se9_file_api.new
sudo mv /opt/se9/se9_agent.new /opt/se9/se9_agent
sudo mv /opt/se9/se9_file_api.new /opt/se9/se9_file_api
sudo systemctl start se9-file-api.service se9-agent.service
curl -fsS http://127.0.0.1:18443/api/v2/health
```

Compare each SHA-256 pair before replacing executables. If the existing port is not `18443`, keep it in the health URL. Configuration changes require restart; unit/drop-in changes also require daemon-reload. Restore old executables on failure:

```bash
SE9_BACKUP="/var/backups/se9/<update-id>"
sudo systemctl stop se9-agent.service se9-file-api.service
sudo install -o root -g root -m 0755 "$SE9_BACKUP/se9_file_api" /opt/se9/se9_file_api
sudo install -o root -g root -m 0755 "$SE9_BACKUP/se9_agent" /opt/se9/se9_agent
sudo systemctl start se9-file-api.service se9-agent.service
```

Do not restore older keys, tokens, or user files by default. Perform identity recovery only after confirming corruption and that the backup belongs to this same device.

Stop services; execute the second command only when also disabling boot startup:

```bash
sudo systemctl stop se9-agent.service se9-file-api.service
sudo systemctl disable se9-agent.service se9-file-api.service
```

Stopping keeps uploaded files, configuration, keys, and tokens. For a temporary pause, use only the first command; resume with `sudo systemctl start se9-file-api.service se9-agent.service`.

### 11. Troubleshooting

| Symptom | Checks and action |
| --- | --- |
| App claim exchange fails; `status=0 bytes=0` | Test public `/se9/health` from NAS, outbound network, cloud host/prefix, HTTP port; rebuild older Agents containing the default HTTP port bug |
| Discovery works, handshake does not | Check UDP 37020, Wi-Fi/AP isolation, phone permissions, clocks; requests allow five minutes of skew; discovery alone does not prove cloud reachability |
| `/claim/prepare` returns 409 | Device is already claimed; owners use “我的设备”; other-account ownership requires proper ownership administration, not deleting keys |
| Failed registration stays offline | Inspect cloud reachability, token file, logs; restart Agent once network is restored if first registration failed without a token |
| Listed device is offline | Inspect 30-second heartbeats, Agent unit and logs; absence over 90 seconds means offline; refresh after recovery |
| Device list 401 / 404 / 502 | 401: obtain a valid user access token; 404: missing/duplicate `/se9`; 502: Nginx-to-18082 access, backend service and proxy configuration |
| Devices list but transfers fail | Compare both `FILE_API_PORT` values, shared proxy secrets, loopback health, and WS Upgrade; ignore unsupported `SE9_FILE_API_URL` |
| `bind/listen` / Address already in use | Inspect `ss`; avoid running foreground and systemd copies simultaneously; update both env files and restart both services when changing port |
| Permission denied / read-only filesystem | Check service user, mount, directory ownership, `ReadWritePaths`; do not change permissions of the entire VOS volume to bypass the issue |
| HTTPS certificate verification fails | Check clock, CA bundle, full chain, certificate hostname; retain `SE9_TLS_INSECURE=0` and fix the certificate configuration |
| Changed device ID or registration conflict after restart | Check key replacement or a different `SE9_KEY_FILE`; preserve original identity and do not reset cloud state |
| Missing program logs | Application logs are under `/var/log/se9`; stdout may buffer; journal primarily diagnoses systemd failures |

### 12. Validation limits and related documents

Local integration covered account device lists, account isolation, encrypted claiming, WS relay, 8 MB upload chunks, downloads exceeding 8 MB, SHA-256, Range resume, renaming, and deletion. See [LOCAL_VALIDATION.md](LOCAL_VALIDATION.md). Cloud deployment and public endpoints were checked; the physical NAS's storage mount, sustained operation, and target-system build still require device acceptance.

Agent frames are limited to 16 MiB including HTTP messages; this is not unlimited streaming. App upload chunks default to 8 MiB. Do not assume whole-file remote downloads exceeding the frame limit are supported. Range exists at the lower layer, but the current App's ordinary download does not automatically split files into Range requests. Complete JSON parsing, multiuser file isolation, LAN File API TLS, and upload-session recovery across process restarts remain future work.

Related: [deployment directory](../../deploy/README.md), [cloud service](../../cmd/cloud/README.md), [API reference](../../SE9_API.md), [project design](../../PROJECT_DESIGN.md).
