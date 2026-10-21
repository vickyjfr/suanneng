# SE9 云端服务 / SE9 Cloud Service

## 中文

云端使用 Go 实现账号认证、设备注册及绑定、账号设备列表、心跳、远程会话和 WebSocket 中继。文件内容保留在 NAS；设备上的 Agent 与 File API 使用 C，手机 App 使用 Flutter。

### 当前部署

2026-10-20 已部署到阿里云 ARM64 服务器 `123.56.147.51`，服务为 `se9-cloud.service`，程序 `/opt/se9-cloud/se9-cloud`，工作目录 `/opt/se9-cloud`，环境文件 `/etc/se9-cloud.env`。Go 监听 `:18082`，Nginx 将公网 `https://123.56.147.51:8443/se9/` 转发到 `http://127.0.0.1:18082/` 并剥离前缀；`http://123.56.147.51/se9/` 保留为兼容入口。8443 使用 IP SAN 证书，443 留给 PSYNC 的域名证书。Go 未开启直接 TLS。

详细的参数表、当前 unit 和 Nginx 配置、构建上传、备份、替换、验收及回滚说明见 **[NAS 部署与运维，第 8–9 节](../../device/se9-c/README.md)**。

### 已实现能力

- `/health` 健康检查。
- `/api/v2/auth/register`、`login`、`refresh`、`logout`、`me` 及 Demo 密码管理。
- `/api/v2/devices/register` 注册、设备 token 校验、每 30 秒的 Agent 心跳。
- `/api/v2/devices/{deviceId}/claim/prepare` 保存一次性绑定字符串哈希，`/api/v2/devices/claim/confirm` 验证后绑定所有者。
- `GET /api/v2/device_list`，兼容 `GET /api/v2/devices`：只返回当前登录账号绑定的设备，支持分页和在线状态筛选。
- `/api/v2/sessions` 创建所有者远程会话，`/api/v2/relay/app` 和 `/api/v2/relay/device` 配对转发。
- 超过 90 秒没有心跳的设备显示离线，拒绝创建远程会话。

接口路径为 Go 进程内路径；公网请求加 `/se9` 前缀。不带用户 access token 的设备列表返回 401 是正常认证行为。

### 状态与认证

- 账号、用户密码哈希、设备归属、设备 token 哈希和会话持久化到 `CLOUD_STATE_FILE`，当前 `/var/lib/se9-cloud/cloud-state.json`。
- 刷新凭证哈希持久化到 `AUTH_STATE_FILE`，当前 `/var/lib/se9-cloud/auth-refresh.json`。
- 当前源码 Access Token 有效期 48 小时、Refresh Token 30 天；刷新轮换使旧刷新凭证失效。Access Token 在内存中，服务重启后客户端可使用有效 Refresh Token 重新获取。
- `DEMO_ADMIN_PASSWORD` 用于初始化默认用户，加载已有用户状态后不会因修改该变量重置其密码。
- 同时配置 `TLS_CERT_FILE`、`TLS_KEY_FILE` 可由 Go 直接提供 HTTPS/WSS；当前部署通过 Nginx 的 HTTP 入口提供联调服务。

本地开发从 `nas` 根目录运行 `go run ./cmd/cloud`，默认端口 8080；它不会自动加载 `/etc/se9-cloud.env`。当前为文件状态持久化的 Demo，完整数据库、复杂成员权限和正式 TLS 运维仍需按实际环境建设。完整接口见 [SE9_API.md](../../SE9_API.md)。

## English

The Go cloud service implements account authentication, device registration/claiming, account device lists, heartbeats, remote sessions, and WebSocket relaying. Files remain on the NAS. Agent and File API are written in C, and the mobile App uses Flutter.

### Current deployment

Deployed on 2026-10-20 to Alibaba Cloud ARM64 host `123.56.147.51`. The service is `se9-cloud.service`, executable `/opt/se9-cloud/se9-cloud`, working directory `/opt/se9-cloud`, environment file `/etc/se9-cloud.env`. Go listens on `:18082`; Nginx forwards public `https://123.56.147.51:8443/se9/` to `http://127.0.0.1:18082/` and removes the prefix; `http://123.56.147.51/se9/` remains as a compatibility entry. Port 8443 uses the IP-SAN certificate; port 443 is reserved for the PSYNC domain certificate. Go direct TLS is disabled.

For complete parameter tables, current unit/Nginx settings, building/uploading, backup, replacement, verification, and rollback, see **[NAS Deployment and Operations, sections 8–9](../../device/se9-c/README.md)**.

### Implemented capabilities

- `/health` health checks.
- `/api/v2/auth/register`, `login`, `refresh`, `logout`, `me`, and Demo password management.
- `/api/v2/devices/register`, device-token authentication, and 30-second Agent heartbeats.
- `/api/v2/devices/{deviceId}/claim/prepare` stores a one-time claim hash; `/api/v2/devices/claim/confirm` verifies it and assigns ownership.
- `GET /api/v2/device_list`, alias `GET /api/v2/devices`: only the current account's bound devices, with pagination and status filtering.
- `/api/v2/sessions` creates owner-only remote sessions; `/api/v2/relay/app` and `/api/v2/relay/device` pair and forward traffic.
- Devices without heartbeats for over 90 seconds appear offline and cannot create remote sessions.

These paths are internal Go paths; prefix public requests with `/se9`. A device list requested without a user access token correctly returns 401.

### State and authentication

- Accounts, password hashes, device ownership, device-token hashes, and sessions persist in `CLOUD_STATE_FILE`, currently `/var/lib/se9-cloud/cloud-state.json`.
- Refresh-token hashes persist in `AUTH_STATE_FILE`, currently `/var/lib/se9-cloud/auth-refresh.json`.
- Current source uses 48-hour access tokens and 30-day refresh tokens. Refresh rotates the credential and invalidates its predecessor. Access tokens are in memory; after a service restart clients can obtain new access tokens with valid refresh credentials.
- `DEMO_ADMIN_PASSWORD` initializes the default user; changing it does not reset a user loaded from existing state.
- Configuring both `TLS_CERT_FILE` and `TLS_KEY_FILE` enables Go direct HTTPS/WSS. The current integration deployment uses an HTTP Nginx entry.

For local development, run `go run ./cmd/cloud` from `nas`, default port 8080. It does not automatically load `/etc/se9-cloud.env`. This is a Demo with file-based state; a full database, complex membership permissions, and production TLS operations need environment-specific implementation. See [SE9_API.md](../../SE9_API.md) for the full API.
