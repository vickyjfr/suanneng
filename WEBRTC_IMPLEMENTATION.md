# WebRTC 文件传输实现与部署 / WebRTC File Transfer Implementation and Deployment

## 中文

### 实现范围

本次实现基于 `WEBRTC_FILE_TRANSFER_DESIGN.md`，修改了 Go 云服务、NAS C Agent / File API 和 Flutter App。云端由 `RTC_ENABLED` 控制；当前 NAS 在编译支持 WebRTC 时默认启用，并内置 HTTPS 地址和云端公钥。升级后二进制兼容原有 HTTP/WebSocket 上传下载。

- 云端新增 `/api/v2/rtc/ice`、`/api/v2/rtc/sessions`、会话查询/续期/关闭，以及 App / NAS WebSocket 信令。设备列表在 NAS 信令连接后返回 `capabilities.fileTransferTransports`。
- 云端签发短期 Ed25519 授权，绑定账号、设备、协商 ID、App SDP 哈希和 DTLS 指纹。NAS 使用固定公钥验签并签署 Answer，App 验证设备签名后设置远端描述。DTLS 证书指纹由 WebRTC 库验证。
- 两条可靠有序 DataChannel：`se9.control.v1` 和 `se9.file.v1`。二进制帧上限 16 KiB，固定 48 字节头，文件偏移为 64 位；持久化逻辑块为 1 MiB。上传有发送缓冲限制；下载通过 `READ_BLOCK` 按块拉取。
- File API 新增 `/api/v2/transfers`，统一处理 WebRTC 和服务器转发请求。Agent 注入账号/设备身份，客户端不能直接伪造可信请求头。
- 分块和任务清单同步落盘后确认；断点恢复递增 epoch，旧写入请求被拒绝。下载使用不可变快照；上传全文件 SHA-256 校验后原子发布，默认禁止覆盖已有文件。内部文件保存在存储根目录的 `.se9-transfers`，禁止从普通文件接口访问。
- App 从支持 WebRTC 的设备卡片进入上传/下载；缓存源文件，逐块读写，记录进度和任务，恢复凭证使用系统安全存储。工具栏“传输任务”支持暂停、继续、取消和重新保存已完成下载。iOS 使用文档导出选择器，Android 使用系统创建文档接口，避免整份大文件进入 Dart 内存。
- 失败后在同一任务上重新建立 PeerConnection 并递增 epoch；会话允许回退时，使用云端签名 `relay.attach` 身份上下文继续同一 File API 任务。旧版 NAS 保留既有上传下载流程。

### 协议补充与边界

- `GET /api/v2/rtc/ice?deviceId=<id>` 在生成 Offer 前提供短期 ICE 凭证，解决创建会话前必须配置 ICE 的先后依赖。
- 下载 `READ_BLOCK` → DATA → `COMMIT_BLOCK` → `BLOCK_ACK`；App 写盘、保存本地块校验值后确认，NAS 持久化下载确认记录。
- 所有控制请求有 `version`、`requestId`、`rtcSessionId`；已开始的任务还包括 `transferId` 和 `epoch`。JSON 中的文件大小、偏移、块索引采用十进制字符串。
- 当前按单 App 一个活动文件、NAS 最多两个未完成任务执行；文件大小参数上限 20 GiB，任务保留期 24 小时，在创建任务时清理过期任务。此上限是参数保护，并非已完成 20 GiB 性能验收。
- 当前目录浏览、重命名和删除继续使用原 HTTP/WS 元数据接口，文件内容走新传输模块。图片预览限制 16 MiB；视频按文件下载保存，本次不实现视频播放器。
- 连接恢复使用新 PeerConnection，尚未实现同一 PeerConnection 内的 ICE restart。任务数据继续复用；App 进入后台时请求暂停，回到前台由任务列表继续。
- 旧版传输路径仍可能整文件读入内存；新的大文件保障适用于已启用 WebRTC 能力的 NAS。
- 必须使用证书校验通过的 HTTPS/WSS。仅在显式开启测试开关且地址为回环时允许 HTTP。当前嵌入的阿里云地址为 `https://123.56.147.51:8443`、前缀 `/se9`，按 IP SAN 校验证书；`443` 使用 PSYNC 的 `*.hualaikeji.com` 域名证书，SE9 不得使用。

### 编译 NAS 与云端

Linux 安装构建依赖，例如 Ubuntu / Debian：

```sh
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libssl-dev libnice-dev
cmake -S device/se9-c -B build/se9-c -DCMAKE_BUILD_TYPE=Release
cmake --build build/se9-c -j
ctest --test-dir build/se9-c --output-on-failure
go build -o build/se9-cloud ./cmd/cloud
```

构建会下载固定版本 cJSON 和 libdatachannel。NAS 主程序保持 C；libdatachannel 使用 C++17，实现通过 C API 调用。默认使用 libnice 提供 TURN UDP/TCP/TLS 后端。受限设备可加 `-DSE9_USE_LIBNICE=OFF` 使用 libjuice，但不能据此宣称支持 TURN TCP/TLS。`-DSE9_WEBRTC=OFF` 可关闭 RTC 传输编译，File API 的持久化传输接口仍保留。

离线构建先准备完整含子模块的 libdatachannel 源码，然后传入 `-DFETCHCONTENT_SOURCE_DIR_DATACHANNEL=/absolute/path/libdatachannel`，cJSON 同样可用 `-DFETCHCONTENT_SOURCE_DIR_CJSON=/absolute/path/cJSON` 指定。

macOS 可安装 `cmake openssl libnice pkgconf coturn`，命令行测试使用本机可用的 OpenSSL 和动态库。NAS 实际部署应在目标架构构建并一同安装 libnice / OpenSSL 运行库。

### 阿里云配置

当前已知 ECS 公网地址为 `123.56.147.51`，已有 HTTP 入口 `/se9/`，Nginx 转发到云端 `18082`。下列为通用配置步骤；本次公网 IP 的实际部署与验证结果见 [IP_DEPLOYMENT.md](IP_DEPLOYMENT.md)。

1. 为实际使用的云端域名或 IP 配置有效证书，在 Nginx 开放 HTTPS 443，保留 `/se9/` 到 `127.0.0.1:18082` 的路径映射。信令路由必须转发 WebSocket Upgrade / Connection 头，并设置至少 90 秒的代理读超时。
2. Nginx 覆盖 `X-Forwarded-Proto` 为实际请求协议；Go 端口仅供本机代理访问，不应通过 ECS 安全组向公网暴露。设置 `RTC_TRUST_PROXY=1` 仅适用于代理从回环连接的部署。
3. 独立生成持久化签名私钥。保持 `/var/lib/se9-cloud/rtc-grant.pem` 稳定，权限 0600，运行服务账号可读。备份时保密，不复制到 App 或 NAS。
4. 在同一 ECS 或专门 TURN 主机部署 coturn；参考 `deploy/coturn.conf.example`。填写 ECS 实际网卡私网地址及公网映射，不能把示例中的占位值原样上线。云服务和 coturn 使用同一随机共享密钥，密钥文件限制权限。
5. ECS 安全组和主机防火墙允许 HTTPS TCP 443、TURN UDP/TCP 3478、TURN TLS TCP 5349 和 relay UDP 49160–49260。默认使用 UDP relay；TCP 3478 / TLS 5349 指客户端到 TURN 服务的连接方式。
6. 修改现有 `/etc/se9-cloud.env`，保留账号数据库、原端口和密码设置，增加下列配置。根据实际 HTTPS 终止方式保留 Nginx 或 Go 自身 TLS，不能同时错误配置。

```dotenv
PORT=18082
RTC_ENABLED=1
RTC_TRUST_PROXY=1
RTC_ALLOW_INSECURE_LOCAL=0
RTC_GRANT_KEY_FILE=/var/lib/se9-cloud/rtc-grant.pem
TURN_URLS=turn:123.56.147.51:3478?transport=udp,turn:123.56.147.51:3478?transport=tcp
TURN_SHARED_SECRET_FILE=/etc/se9-cloud/turn-shared-secret
```

TLS TURN 可在有证书的实际主机上额外配置 `turns:<certificate-host>:5349?transport=tls`。共享密钥至少 32 字节，切勿写入 App。云端根据账号设备授权返回临时 TURN 用户名和密码。

签名密钥可通过以下方式生成并导出公钥；已有密钥时不得覆盖：

```sh
umask 077
openssl genpkey -algorithm ED25519 -out /var/lib/se9-cloud/rtc-grant.pem
openssl pkey -in /var/lib/se9-cloud/rtc-grant.pem -pubout -out /tmp/cloud-grant-public.pem
```

将新云端二进制替换到现有 `/opt/se9-cloud/se9-cloud`，按现有备份/回滚流程重启 `se9-cloud.service`。启动时 `RTC_ENABLED=1` 且密钥不存在，也会创建私钥；先启动完成再导出公钥。生产服务上线前应单独验收域名证书、跨网 ICE、TURN 流量和带宽。

### NAS 与手机配置

复制 `device/deploy/se9-agent.env.example` 并填写实际 HTTPS origin；URL 不包含 `/se9`，前缀单独设置：

```dotenv
SE9_CLOUD_URL=https://your-verified-cloud-host
SE9_CLOUD_BASE_PATH=/se9
SE9_RTC_ENABLED=1
SE9_RTC_ALLOW_INSECURE_LOCAL=0
SE9_CLOUD_GRANT_PUBLIC_KEY=/etc/se9/cloud-grant-public.pem
SE9_KEY_FILE=/var/lib/se9/device.key
SE9_TOKEN_FILE=/var/lib/se9/device-token
SE9_AGENT_PROXY_TOKEN=<same-random-secret-as-file-api>
FILE_API_PORT=8443
SE9_CA_FILE=/etc/ssl/certs/ca-certificates.crt
```

当前 NAS 已在构建时内置 `device/deploy/cloud-grant-public.pem`，无需额外安装公钥文件；仅设置 `SE9_CLOUD_GRANT_PUBLIC_KEY` 时才需要安装覆盖文件。自动安装步骤见 [NAS 部署说明](device/se9-c/README.md)。File API 的 `SE9_AGENT_PROXY_TOKEN` 必须与 Agent 一致，监听 `127.0.0.1:8443`，`STORAGE_ROOT` 指向 NAS 数据目录。保留设备私钥、device-token 和 `.se9-transfers/store.key`，否则会破坏设备身份或恢复凭证。

先启动 File API，再启动 Agent。刷新 App 设备列表后，NAS 的 WebRTC 控制连接应已就绪。设备离线或 RTC 未开启时不会宣告新能力。不要同时启动两个占用 UDP 37020 的 Agent。

```sh
cd mobile
flutter pub get
flutter run --dart-define=SE9_CLOUD_API=https://your-verified-cloud-host/se9
```

可通过 `--dart-define=SE9_RTC_FORCE_RELAY=true` 强制 App 使用中继策略，通过 `--dart-define=SE9_RTC_ALLOW_LEGACY_RELAY=false` 禁止服务器回退。

本次已生成 iOS `mobile/build/ios/iphoneos/Runner.app` 和 Android `mobile/build/app/outputs/flutter-apk/app-debug.apk`。构建成功不等于已安装到手机；iOS 无签名构建需要正式签名后安装。

### 验证命令与状态

```sh
go test -race ./cmd/cloud
go vet ./...
python3 device/se9-c/tests/transfer_store_check.py "$PWD/build/se9-c/se9_file_api"
cd mobile
flutter analyze
flutter test
dart run tool/verify_webrtc_local.dart ../build/se9-cloud ../build/se9-c/se9_agent ../build/se9-c/se9_file_api ../build/se9-c/se9_rtc_probe
```

本地脚本只在临时目录启动服务，使用回环 HTTP 例外和独立账号/设备密钥；结束后关闭测试 NAS，不恢复长期运行的本地 NAS。它验证 UDP 绑定、云端设备列表、签名 SDP、WebRTC 上传下载、暂停续传、跨传输回退以及旧接口兼容性。使用前确保 UDP 37020 空闲。

已通过：Go race 测试、C 帧测试、NAS 持久化存储测试、Flutter 静态检查及 17 项测试、iOS/Android 调试构建、真实 WebRTC 直连、TURN UDP/TCP 中继及同任务服务器转发续传。存储测试包含进程重启、重复块、坏哈希、旧 epoch、提交中断恢复、空文件、快照、账号隔离、路径穿越、符号链接和禁止覆盖。

TURN 验证必须检查选中的 candidate pair 至少有一个 `typ relay`，不能仅凭设置 relay policy 判定成功。跨公网、生产证书、真机大视频、低存储空间和长时间传输仍需在部署环境验收。云端实际部署状态见 [IP_DEPLOYMENT.md](IP_DEPLOYMENT.md)；手机安装版本未自动更新。

## English

### Implementation scope

This implementation follows `WEBRTC_FILE_TRANSFER_DESIGN.md` and changes the Go cloud service, NAS C Agent / File API, and Flutter App. The cloud is controlled by `RTC_ENABLED`; current NAS builds enable RTC when compiled and embed the HTTPS origin and cloud public key. Updated binaries retain the existing HTTP/WebSocket upload and download paths.

- The cloud adds `/api/v2/rtc/ice`, `/api/v2/rtc/sessions`, session inspection/renewal/closure, and App / NAS WebSocket signaling. Device lists expose `capabilities.fileTransferTransports` once NAS signaling connects.
- Short-lived Ed25519 grants bind account, device, negotiation ID, App SDP hash, and DTLS fingerprint. The NAS verifies a pinned cloud public key and signs its Answer. The App verifies the device signature before setting the remote description. The WebRTC library verifies the DTLS certificate fingerprint.
- Two reliable ordered DataChannels are used: `se9.control.v1` and `se9.file.v1`. Binary frames are limited to 16 KiB with a fixed 48-byte header and 64-bit file offsets. Durable logical blocks are 1 MiB. Uploads apply buffered-send limits; downloads pull blocks through `READ_BLOCK`.
- File API `/api/v2/transfers` owns task storage for both WebRTC and server forwarding. The Agent injects trusted account/device identity and strips client-supplied identity headers.
- Blocks and manifests are synced before acknowledgement. Resume increments the epoch and rejects stale writers. Downloads use immutable snapshots. Uploads verify the full SHA-256 before atomic publication and reject existing destinations. Internal state lives under `.se9-transfers`, inaccessible through ordinary file routes.
- The App uses the new path from capable device cards, caches upload sources, reads/writes blocks, and persists tasks/progress. Recovery tokens use system secure storage. The transfer task toolbar supports pause, resume, cancel, and re-export of completed downloads. iOS document export and Android document creation avoid loading an entire large file into Dart memory.
- Recovery creates a new PeerConnection and advances the epoch. When the session permits fallback, a cloud-signed `relay.attach` identity context continues the same File API task through server forwarding. Older NAS versions retain the original transfer flow.

### Protocol additions and limits

- `GET /api/v2/rtc/ice?deviceId=<id>` supplies temporary ICE credentials before Offer generation, resolving the setup dependency.
- Downloads follow `READ_BLOCK` → DATA → `COMMIT_BLOCK` → `BLOCK_ACK`. The App flushes data and persists local block hashes before acknowledgement; the NAS persists download acknowledgement records.
- Control requests include `version`, `requestId`, and `rtcSessionId`; started tasks also include `transferId` and `epoch`. JSON sizes, offsets, and block indexes use decimal strings.
- The App runs one active file at a time; the NAS permits two unfinished tasks. The parameter limit is 20 GiB. Tasks are retained for 24 hours, with expiration cleanup during task creation. This limit is validation, not a completed 20 GiB performance qualification.
- Directory browsing, rename, and delete retain existing HTTP/WS metadata routes. File content uses the new transport. Image preview is limited to 16 MiB. Videos can be downloaded and saved; this change does not add a video player.
- Recovery replaces the PeerConnection rather than implementing ICE restart within the same connection. Durable task data is reused. Backgrounding requests pause; users resume through the task list.
- Legacy transfer paths may still buffer whole files. The new large-file handling applies to NAS devices with RTC enabled.
- Verified HTTPS/WSS is required. HTTP is allowed only with an explicit test flag and a loopback address. The embedded Aliyun origin is `https://123.56.147.51:8443` with prefix `/se9`, verified against the certificate IP SAN; port `443` carries PSYNC's `*.hualaikeji.com` certificate and must not be used by SE9.

### Build NAS and cloud

Install Linux build dependencies, for example on Ubuntu / Debian:

```sh
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libssl-dev libnice-dev
cmake -S device/se9-c -B build/se9-c -DCMAKE_BUILD_TYPE=Release
cmake --build build/se9-c -j
ctest --test-dir build/se9-c --output-on-failure
go build -o build/se9-cloud ./cmd/cloud
```

The build downloads pinned cJSON and libdatachannel sources. NAS application code remains C; the C++17 libdatachannel implementation is accessed through its C API. The default libnice backend supports TURN UDP/TCP/TLS. Constrained targets can select libjuice using `-DSE9_USE_LIBNICE=OFF`; that build must not be advertised as supporting TURN TCP/TLS. `-DSE9_WEBRTC=OFF` disables the RTC transport build while retaining durable File API transfer routes.

For offline builds, prepare libdatachannel including its submodules and pass `-DFETCHCONTENT_SOURCE_DIR_DATACHANNEL=/absolute/path/libdatachannel`. Similarly use `-DFETCHCONTENT_SOURCE_DIR_CJSON=/absolute/path/cJSON` for cJSON.

On macOS, install `cmake openssl libnice pkgconf coturn`. Local tests use installed OpenSSL and dynamic libraries. Build on the deployment architecture and install required libnice / OpenSSL runtime libraries on the NAS.

### Aliyun configuration

The known ECS public IP is `123.56.147.51`. The existing HTTP `/se9/` entry is proxied by Nginx to cloud port `18082`. The following describes generic setup. See [IP_DEPLOYMENT.md](IP_DEPLOYMENT.md) for the actual public-IP deployment and verification results.

1. Provision a valid certificate for the actual cloud hostname or IP. Enable Nginx HTTPS 443 and preserve `/se9/` mapping to `127.0.0.1:18082`. Forward WebSocket Upgrade / Connection headers and set a proxy read timeout of at least 90 seconds.
2. Nginx must overwrite `X-Forwarded-Proto` with the actual incoming scheme. Keep the Go listener accessible only to the local proxy and block public ECS access. `RTC_TRUST_PROXY=1` applies only when the proxy connects over loopback.
3. Generate a persistent signing private key. Keep `/var/lib/se9-cloud/rtc-grant.pem` stable, mode 0600, readable by the service account. Protect backups; never copy this private key to the NAS or App.
4. Deploy coturn on this ECS or a separate TURN host using `deploy/coturn.conf.example`. Substitute the actual private interface address and public mapping; never deploy the placeholders. Use the same random shared secret in coturn and the cloud secret file, with restricted permissions.
5. Allow HTTPS TCP 443, TURN UDP/TCP 3478, TURN TLS TCP 5349, and relay UDP 49160–49260 in ECS security groups and host firewalls. Relay allocation uses UDP; TCP 3478 / TLS 5349 describe the client-to-TURN connection.
6. Update the existing `/etc/se9-cloud.env`, retaining its account state, listener, and password configuration, and add the following settings. Choose Nginx termination or Go-native TLS consistently.

```dotenv
PORT=18082
RTC_ENABLED=1
RTC_TRUST_PROXY=1
RTC_ALLOW_INSECURE_LOCAL=0
RTC_GRANT_KEY_FILE=/var/lib/se9-cloud/rtc-grant.pem
TURN_URLS=turn:123.56.147.51:3478?transport=udp,turn:123.56.147.51:3478?transport=tcp
TURN_SHARED_SECRET_FILE=/etc/se9-cloud/turn-shared-secret
```

For TLS TURN, add `turns:<certificate-host>:5349?transport=tls` on the actual certificate-backed host. Use a shared secret of at least 32 bytes and never embed it in the App. The cloud returns temporary TURN credentials after device/account authorization.

Generate a signing key and export its public key as follows; do not overwrite an existing key:

```sh
umask 077
openssl genpkey -algorithm ED25519 -out /var/lib/se9-cloud/rtc-grant.pem
openssl pkey -in /var/lib/se9-cloud/rtc-grant.pem -pubout -out /tmp/cloud-grant-public.pem
```

Replace `/opt/se9-cloud/se9-cloud` using the existing backup/rollback procedure and restart `se9-cloud.service`. With `RTC_ENABLED=1`, startup also creates the key if absent; export the public key after that startup. Production acceptance must separately verify certificates, cross-network ICE, TURN traffic, and bandwidth.

### NAS and phone configuration

Copy `device/deploy/se9-agent.env.example` and set the real HTTPS origin. Keep `/se9` in the separate prefix setting:

```dotenv
SE9_CLOUD_URL=https://your-verified-cloud-host
SE9_CLOUD_BASE_PATH=/se9
SE9_RTC_ENABLED=1
SE9_RTC_ALLOW_INSECURE_LOCAL=0
SE9_CLOUD_GRANT_PUBLIC_KEY=/etc/se9/cloud-grant-public.pem
SE9_KEY_FILE=/var/lib/se9/device.key
SE9_TOKEN_FILE=/var/lib/se9/device-token
SE9_AGENT_PROXY_TOKEN=<same-random-secret-as-file-api>
FILE_API_PORT=8443
SE9_CA_FILE=/etc/ssl/certs/ca-certificates.crt
```

Current NAS builds embed `device/deploy/cloud-grant-public.pem`; no separate key file is needed unless `SE9_CLOUD_GRANT_PUBLIC_KEY` explicitly overrides it. See [NAS deployment](device/se9-c/README.md) for automatic installation. File API must use the same proxy token, listen on `127.0.0.1:8443`, and point `STORAGE_ROOT` to the NAS data directory. Preserve the device private key, device-token, and `.se9-transfers/store.key`; losing them breaks device identity or recovery credentials.

Start File API before Agent. Refresh the App device list after the NAS RTC control connection is ready. Offline devices or disabled RTC do not advertise the capability. Do not run two Agents on UDP 37020 simultaneously.

```sh
cd mobile
flutter pub get
flutter run --dart-define=SE9_CLOUD_API=https://your-verified-cloud-host/se9
```

Use `--dart-define=SE9_RTC_FORCE_RELAY=true` to request App relay policy, or `--dart-define=SE9_RTC_ALLOW_LEGACY_RELAY=false` to disable server fallback.

Build artifacts are `mobile/build/ios/iphoneos/Runner.app` and `mobile/build/app/outputs/flutter-apk/app-debug.apk`. A successful build does not mean the App is installed; the unsigned iOS build needs signing before installation.

### Verification commands and status

```sh
go test -race ./cmd/cloud
go vet ./...
python3 device/se9-c/tests/transfer_store_check.py "$PWD/build/se9-c/se9_file_api"
cd mobile
flutter analyze
flutter test
dart run tool/verify_webrtc_local.dart ../build/se9-cloud ../build/se9-c/se9_agent ../build/se9-c/se9_file_api ../build/se9-c/se9_rtc_probe
```

The local script uses temporary state, separate account/device keys, and the explicit loopback HTTP exception. It closes test services afterward and does not restart the long-running local NAS. It validates UDP binding, cloud device lists, signed SDP, WebRTC upload/download, pause/resume, transport fallback, and legacy compatibility. UDP 37020 must be free.

Passed: Go race tests, C frame tests, NAS durable-store tests, Flutter analysis and 17 tests, iOS/Android debug builds, real direct WebRTC transfer, TURN UDP/TCP relay, and same-task server-forwarding resume. Store checks cover process restart, duplicate blocks, bad hashes, stale epochs, interrupted publication recovery, empty files, immutable snapshots, account isolation, traversal, symlinks, and no-overwrite behavior.

TURN validation must inspect the selected candidate pair for at least one `typ relay`; selecting a relay policy alone is insufficient evidence. Cross-public-network transfer, production certificates, large videos on phones, low-disk conditions, and long-running transfers still require deployment acceptance. See [IP_DEPLOYMENT.md](IP_DEPLOYMENT.md) for cloud deployment status. The installed phone App was not automatically updated.
