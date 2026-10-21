# 公网 IP 部署记录 / Public IP Deployment Record

## 中文

### 当前部署

部署日期：2026-10-20。ECS：`i-2zeeufkzkmtkorqf7tif`，地域 `cn-beijing`，公网 IP `123.56.147.51`，私网 IP `10.1.1.223`，Ubuntu 26.04 ARM64。

- App 云地址：`https://123.56.147.51:8443/se9`。
- 健康检查：`https://123.56.147.51:8443/se9/health`。
- 信令：`wss://123.56.147.51:8443/se9/api/v2/rtc/signaling/app` 和 `/device`，仍需正常身份凭证及会话参数。
- Go 服务：`se9-cloud.service`，二进制 `/opt/se9-cloud/se9-cloud`，仅监听 `127.0.0.1:18082`。已有账号、设备和刷新凭证数据保留。
- SE9 HTTPS/WSS 虚拟主机：`/etc/nginx/conf.d/se9-ip-8443.conf`，监听 `8443`，使用短期 Let's Encrypt IP 证书（含 IP SAN），标准 CA + 主机名校验可用；`/se9/` 转发到 `127.0.0.1:18082`。
- `123.56.147.51:443` 是共享默认站点（`se9-ip-https.conf`），使用稳定的 `*.hualaikeji.com` 证书，供 PSYNC Flutter pinned-IP 客户端使用，并包含 `/v1/`、`/healthz` 路由；禁止改回短期 IP 证书。原有域名虚拟主机及 HTTP `/se9/` 兼容入口保留。原 HTTP 入口不提供加密，新客户端应使用 HTTPS。
- TURN：`se9-turn.service`，配置 `/etc/se9-turn/turnserver.conf`；UDP/TCP 3478、TLS TCP 5349、UDP relay 49160–49260。使用临时凭证授权，禁止匿名 relay 和访问内网目标。

**SE9 的 HTTPS/WSS 已迁移到 `8443`，使用 IP SAN 证书，标准 CA 校验可用；服务器本机已验证 `/se9/health` 返回 200。公网访问 8443 需要先在阿里云安全组放行（当前从公网探测仍不可达）。`443` 现由 PSYNC 的 `*.hualaikeji.com` 稳定证书占用，SE9 客户端不要连 443。TURN 在服务器内网通过 STUN 响应、TLS 证书和认证分配测试；公网 TURN 尚未验证通过，外部端口探测没有到达服务器网卡。安全组或上游网络需要核查，不能据此宣称公网文件中继已经可用。**

### IP 证书与续期

两个端口使用不同证书，互不影响：

- `123.56.147.51:443`（共享默认站点，`se9-ip-https.conf`）：使用部署 SE9 之前的稳定域名证书 `/etc/nginx/ssl/hualaikeji.com/{fullchain,privkey}.pem`（CN=`*.hualaikeji.com`，2027-01-05 到期）。2026-10-21 起不再把 Let's Encrypt 短期 IP 证书用于该 vhost：IP 证书只有约 6 天有效期且会自动轮换，轮换后固定证书 SHA-256 的客户端（PSYNC Flutter `pinned-ip-https`）会在 TLS 握手阶段报 `SocketException`，且该 vhost 曾把 `/v1/` 路由挡成 404。
- `123.56.147.51:8443`（SE9 专用，`se9-ip-8443.conf`）：使用 Let's Encrypt 签发的 `IP Address:123.56.147.51` 证书，标准 CA + IP SAN 主机名校验；续期轮换对该校验透明，SE9 客户端无需 pin。

Let's Encrypt IP 证书同时继续用于 TURN TLS（5349）的证书副本。本次 IP 证书有效期从 `2026-10-20 04:51:38 UTC` 至 `2026-10-26 20:51:37 UTC`，轮换后应以实时查询为准。

- 独立 Certbot 5.4：`/opt/se9-certbot/bin/certbot`，不替换原域名使用的系统 Certbot。
- IP 证书：`/etc/se9-certbot/live/123.56.147.51/fullchain.pem`（8443 与 TURN 使用）。
- IP 私钥：`/etc/se9-certbot/live/123.56.147.51/privkey.pem`（8443 与 TURN 使用）。
- ACME webroot：`/var/lib/se9-acme`。HTTP 80 的 `/.well-known/acme-challenge/` 必须保持公网可达。
- 自动续期：`se9-ip-cert-renew.timer` 每小时检查，最多随机延迟 5 分钟；对应 `se9-ip-cert-renew.service`。
- 更新钩子：`/usr/local/sbin/se9-ip-certificate-hook`。更新 TURN 专用证书副本，验证并重载 Nginx（443 的域名证书不变；8443 使用的 IP 证书在重载后生效），重启运行中的 TURN。TURN 重启会中断当时的中继连接，客户端需恢复任务。
- 已通过 `renew --dry-run --run-deploy-hooks`；真实证书未被测试证书替换。未配置证书通知邮箱，需监控定时任务和有效期。

**注意：** `443` 的 wildcard 证书不含 IP SAN，SE9 移动端和 NAS Agent 必须使用 `https://123.56.147.51:8443/se9`；连 `443` 会因主机名不匹配失败。`80` 端口的 HTTP `/se9/` 仅作为兼容入口保留。

```sh
systemctl list-timers se9-ip-cert-renew.timer
journalctl -u se9-ip-cert-renew.service --since today
openssl x509 -in /etc/se9-certbot/live/123.56.147.51/fullchain.pem -noout -dates -ext subjectAltName
/opt/se9-certbot/bin/certbot renew --dry-run --run-deploy-hooks --no-random-sleep-on-renew --config-dir /etc/se9-certbot --work-dir /var/lib/se9-certbot --logs-dir /var/log/se9-certbot --deploy-hook /usr/local/sbin/se9-ip-certificate-hook
```

### 授权密钥

- 云端授权私钥：`/var/lib/se9-cloud/rtc-grant.pem`，权限 0600，仅服务账号持有。
- 云端公钥：`/etc/se9-cloud/cloud-grant-public.pem`，项目副本为 `device/deploy/cloud-grant-public.pem`。公钥可以分发给 NAS。其 DER SHA-256 指纹为 `5991d966e23a94d418bff4d1a8bb35f25554e5b0fa392bb5b05bc4db310a8370`。
- TURN 共享密钥：`/etc/se9-cloud/turn-shared-secret`，由服务器随机生成，与 TURN 配置一致。不会下发给 App。
- 私钥、共享密钥和完整云环境文件均没有复制到项目仓库。

当前 NAS 源码已内置 HTTPS 地址及云端公钥，WebRTC 编译支持时默认启用；地址和公钥不再要求人工填写。目标设备的构建和自动安装步骤见 [NAS 部署说明](device/se9-c/README.md)。以下变量仅用于需要覆盖默认值的情况：

```dotenv
SE9_CLOUD_URL=https://123.56.147.51:8443
SE9_CLOUD_BASE_PATH=/se9
SE9_RTC_ENABLED=1
SE9_RTC_ALLOW_INSECURE_LOCAL=0
SE9_CA_FILE=/etc/ssl/certs/ca-certificates.crt
```

自动安装脚本保留设备私钥、device-token、存储目录和匹配的旧代理密钥；首次安装时由两个进程自动生成并复用本机代理密钥。仅在需要外部公钥覆盖时设置 `SE9_CLOUD_GRANT_PUBLIC_KEY` 并安装相应 PEM 文件。macOS 的系统 CA 文件通常为 `/etc/ssl/cert.pem`。本次没有启动长期运行的本地 NAS，也没有重新安装手机 App。

App 下次构建使用：

```sh
flutter run --dart-define=SE9_CLOUD_API=https://123.56.147.51:8443/se9
```

### 待核查的安全组规则

进入阿里云 ECS 控制台 → 北京地域 → 上述实例 → 安全组 → 入方向规则。按业务需要对公网客户端放行：

| 协议 | 端口 | 来源 | 用途 |
|---|---|---|---|
| TCP | 80 | 0.0.0.0/0 | IP 证书 HTTP 验证与续期、HTTP 兼容入口 |
| TCP | 443 | 0.0.0.0/0 | PSYNC HTTPS（稳定域名证书） |
| TCP | 8443 | 0.0.0.0/0 | SE9 HTTPS/WSS |
| TCP | 3478 | 0.0.0.0/0 | TURN TCP |
| TCP | 5349 | 0.0.0.0/0 | TURN TLS |
| UDP | 3478 | 0.0.0.0/0 | STUN/TURN UDP |
| UDP | 49160–49260 | 0.0.0.0/0 | TURN relay 数据 |

本次 SSH 环境没有阿里云 CLI 凭证或 ECS RAM 角色，无法直接修改安全组。主机 UFW 未启用，TURN 在私网接口正常监听；不能将新增 SSH 防火墙规则等同于已放行阿里云安全组。安全组修改后需再次从公网完成 TURN 认证分配及真实中继文件校验。

### 备份与运维

本次备份在 `/var/backups/se9-ip-20261020-134744`；最新备份位置记录在 `/var/backups/se9-ip-current`。含旧云二进制、Nginx 配置、服务配置、云环境和原有状态数据，位于服务器且仅 root 可读。

```sh
systemctl status se9-cloud se9-turn nginx
journalctl -u se9-cloud -u se9-turn --since today
ss -lntup
curl -fsS https://123.56.147.51:8443/se9/health
```

回滚程序时只恢复旧二进制及本次修改的配置；不要直接用旧状态覆盖新增账号或设备数据。保留新私钥和 TURN 密钥，避免后续 NAS 公钥配置失效。

## English

### Deployed services

Deployment date: 2026-10-20. ECS instance `i-2zeeufkzkmtkorqf7tif`, region `cn-beijing`, public IP `123.56.147.51`, private IP `10.1.1.223`, Ubuntu 26.04 ARM64.

- App cloud URL: `https://123.56.147.51:8443/se9`.
- Health endpoint: `https://123.56.147.51:8443/se9/health`.
- Signaling: `wss://123.56.147.51:8443/se9/api/v2/rtc/signaling/app` and `/device`, with normal authentication and session parameters.
- Go service: `se9-cloud.service`, binary `/opt/se9-cloud/se9-cloud`, listening only on `127.0.0.1:18082`. Existing account, device, and refresh-token state is retained.
- SE9 HTTPS/WSS virtual host: `/etc/nginx/conf.d/se9-ip-8443.conf`, listening on `8443` with the short-lived Let's Encrypt IP certificate (IP SAN), so standard CA + hostname verification works; `/se9/` is forwarded to `127.0.0.1:18082`.
- `123.56.147.51:443` is the shared default vhost (`se9-ip-https.conf`) using the stable `*.hualaikeji.com` certificate for the PSYNC Flutter pinned-IP client, with `/v1/` and `/healthz` routes. Do not switch it back to the short-lived IP certificate. Existing domain virtual hosts and the legacy HTTP `/se9/` entry remain. HTTP is unencrypted; new clients should use HTTPS.
- TURN: `se9-turn.service`, configuration `/etc/se9-turn/turnserver.conf`; UDP/TCP 3478, TLS TCP 5349, and UDP relay 49160–49260. Temporary credentials authorize relay access; anonymous relay and private-network destinations are denied.

**SE9 HTTPS/WSS has moved to `8443` with the IP-SAN certificate, so standard CA verification works; `/se9/health` returned 200 on the server. Public access to 8443 requires an Aliyun security-group rule (public probes are still blocked). Port `443` now carries the PSYNC `*.hualaikeji.com` certificate, so SE9 clients must not use 443. TURN passed private-interface STUN, TLS certificate, and authenticated allocation checks. Public TURN verification has not passed: external probes did not reach the server interface. Security groups or upstream networking require investigation; public file relay must not yet be considered operational.**

### IP certificate and renewal

The two ports use different certificates and are independent:

- `123.56.147.51:443` (shared default vhost, `se9-ip-https.conf`) keeps the stable domain certificate used before the SE9 deployment: `/etc/nginx/ssl/hualaikeji.com/{fullchain,privkey}.pem` (CN `*.hualaikeji.com`, expires 2027-01-05). Since 2026-10-21 the short-lived Let's Encrypt IP certificate is no longer used by that vhost: it is valid for about six days and rotates automatically, so clients that pin its SHA-256 (PSYNC Flutter `pinned-ip-https`) fail during the TLS handshake with `SocketException`; the same vhost also used to return 404 for `/v1/` routes.
- `123.56.147.51:8443` (SE9-only, `se9-ip-8443.conf`) uses the Let's Encrypt `IP Address:123.56.147.51` certificate with standard CA + IP-SAN hostname verification. Rotation is transparent to that verification, so SE9 clients need no pin.

The Let's Encrypt IP certificate is also still used for the TURN TLS (5349) copy. Its initial validity is `2026-10-20 04:51:38 UTC` through `2026-10-26 20:51:37 UTC`. Query the active certificate after rotation.

- Dedicated Certbot 5.4: `/opt/se9-certbot/bin/certbot`, separate from the existing domain Certbot installation.
- IP certificate: `/etc/se9-certbot/live/123.56.147.51/fullchain.pem` (used by 8443 and TURN).
- IP private key: `/etc/se9-certbot/live/123.56.147.51/privkey.pem` (used by 8443 and TURN).
- ACME webroot: `/var/lib/se9-acme`. Public HTTP 80 access to `/.well-known/acme-challenge/` must remain available.
- Renewal: `se9-ip-cert-renew.timer` checks hourly with up to five minutes of randomized delay, invoking `se9-ip-cert-renew.service`.
- Deploy hook: `/usr/local/sbin/se9-ip-certificate-hook`. It refreshes the TURN-only certificate copy, validates/reloads Nginx (the 443 domain certificate is unchanged; 8443 picks up the renewed IP certificate after reload), and restarts active TURN. This restart interrupts current relay connections; clients must resume tasks.
- `renew --dry-run --run-deploy-hooks` passed without replacing the production certificate with a test certificate. No notification email was configured; monitor timer results and expiration.

**Note:** the 443 wildcard certificate has no IP SAN. SE9 mobile and NAS Agent clients must use `https://123.56.147.51:8443/se9`; connecting to 443 fails hostname verification. The port-80 HTTP `/se9/` entry is retained for compatibility only.

```sh
systemctl list-timers se9-ip-cert-renew.timer
journalctl -u se9-ip-cert-renew.service --since today
openssl x509 -in /etc/se9-certbot/live/123.56.147.51/fullchain.pem -noout -dates -ext subjectAltName
/opt/se9-certbot/bin/certbot renew --dry-run --run-deploy-hooks --no-random-sleep-on-renew --config-dir /etc/se9-certbot --work-dir /var/lib/se9-certbot --logs-dir /var/log/se9-certbot --deploy-hook /usr/local/sbin/se9-ip-certificate-hook
```

### Authorization keys

- Cloud signing private key: `/var/lib/se9-cloud/rtc-grant.pem`, mode 0600, owned by the service account.
- Public key: `/etc/se9-cloud/cloud-grant-public.pem`, with a project copy at `device/deploy/cloud-grant-public.pem` for NAS provisioning. Its DER SHA-256 fingerprint is `5991d966e23a94d418bff4d1a8bb35f25554e5b0fa392bb5b05bc4db310a8370`.
- TURN shared secret: `/etc/se9-cloud/turn-shared-secret`, randomly generated on the server and matched to TURN configuration. It is not delivered to the App.
- Private keys, shared secrets, and the complete cloud environment file were not copied into the repository.

The current NAS source embeds the HTTPS origin and cloud public key and enables RTC when compiled. No manual address/key entry is required. See [NAS deployment](device/se9-c/README.md) for building and automatic installation. The variables below are overrides only:

```dotenv
SE9_CLOUD_URL=https://123.56.147.51:8443
SE9_CLOUD_BASE_PATH=/se9
SE9_RTC_ENABLED=1
SE9_RTC_ALLOW_INSECURE_LOCAL=0
SE9_CA_FILE=/etc/ssl/certs/ca-certificates.crt
```

The installer preserves existing device keys, device-token, storage, and matching old proxy keys. Fresh processes generate and reuse one local proxy key. Only set `SE9_CLOUD_GRANT_PUBLIC_KEY` and install a PEM when overriding the embedded key. macOS typically uses `/etc/ssl/cert.pem`. This deployment did not start a permanent local NAS or reinstall the phone App.

For the next App build:

```sh
flutter run --dart-define=SE9_CLOUD_API=https://123.56.147.51:8443/se9
```

### Security-group rules to check

In the Aliyun ECS console, select Beijing, the instance above, its security group, and inbound rules. Allow public clients as appropriate:

| Protocol | Port | Source | Purpose |
|---|---|---|---|
| TCP | 80 | 0.0.0.0/0 | IP certificate HTTP validation and renewal, HTTP compatibility |
| TCP | 443 | 0.0.0.0/0 | PSYNC HTTPS (stable domain certificate) |
| TCP | 8443 | 0.0.0.0/0 | SE9 HTTPS/WSS |
| TCP | 3478 | 0.0.0.0/0 | TURN TCP |
| TCP | 5349 | 0.0.0.0/0 | TURN TLS |
| UDP | 3478 | 0.0.0.0/0 | STUN/TURN UDP |
| UDP | 49160–49260 | 0.0.0.0/0 | TURN relay data |

The SSH environment has no Aliyun CLI credentials or ECS RAM role, so it cannot modify security groups. Host UFW is inactive and TURN listens normally on its private interface. Adding host firewall rules does not open Aliyun security-group rules. After changes, repeat public authenticated allocation and actual relayed file integrity checks.

### Backup and operations

Backup: `/var/backups/se9-ip-20261020-134744`; `/var/backups/se9-ip-current` records the latest location. It contains the old cloud binary, Nginx/service configuration, cloud environment, and prior state, retained on the server with root-only access.

```sh
systemctl status se9-cloud se9-turn nginx
journalctl -u se9-cloud -u se9-turn --since today
ss -lntup
curl -fsS https://123.56.147.51:8443/se9/health
```

For rollback, restore the old binary and affected configuration only. Do not overwrite newly created account/device data with an old state backup. Preserve the new signing key and TURN secret so NAS public-key configuration remains valid.
