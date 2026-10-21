# SE9 NAS 部署与运维 / SE9 NAS Deployment and Operations

## 中文

### 当前默认配置

当前源码已内置云端地址 `https://123.56.147.51:8443`、前缀 `/se9`，构建时将 `deploy/cloud-grant-public.pem` 中的 Ed25519 公钥编入程序。WebRTC 编译开启时，运行默认启用，不再需要手工填写地址、公钥或 `SE9_RTC_ENABLED=1`。HTTPS/WSS 对公网 IP 按证书的 IP SAN 校验，保留 CA 信任链校验。注意：`443` 使用 `*.hualaikeji.com` 域名证书，不适用于 IP 直连；SE9 客户端必须使用 `8443`。

NAS 上运行两个进程：`se9_file_api` 管理实际文件与持久化传输任务；`se9_agent` 负责发现绑定、云端注册/心跳、WebRTC 和服务器转发。Go 云服务已运行在阿里云，不要在 NAS 重复部署。

| 配置/文件 | 默认行为 |
|---|---|
| 云地址 | `https://123.56.147.51:8443` |
| 云前缀 | `/se9` |
| 云授权公钥 | 编译时内置，内容来自 `deploy/cloud-grant-public.pem` |
| WebRTC | 编译支持时默认启用；`SE9_RTC_ENABLED=0` 可明确关闭 |
| 本机代理密钥 | 首次启动生成 32 字节随机密钥，保存为 `/var/lib/se9/agent-proxy-token`，文件 0600；两个进程自动复用 |
| 设备长期私钥 | `/var/lib/se9/device-ed25519.pem`，首次启动生成，升级保留 |
| 云端设备凭证 | `/var/lib/se9/device-token`，注册后保存，升级保留 |
| 文件服务 | `127.0.0.1:8443`，只供本机 Agent 使用 |
| 文件目录 | 默认 `/vos/workspace/demo`，可由安装参数指定 |

公网服务器与证书续期状态见 [IP_DEPLOYMENT.md](../../IP_DEPLOYMENT.md)。公网 TURN 端口仍需要安全组/上游网络核查；本次未将公网中继标记为已验收。设备代码配置完成不等于已在实体 NAS 安装。

### 在 Linux NAS 编译

支持具有 POSIX 接口的 Linux；安装脚本要求 systemd。实际程序必须与 NAS 的 CPU 架构和运行库一致，不能把 macOS 二进制复制到 Linux。默认 WebRTC 后端使用 libnice，支持 TURN UDP/TCP/TLS；C 应用通过 C API 调用 C++17 的 libdatachannel。

`device` 目录是完整的 NAS 交付包（源码、三方依赖、公钥、安装脚本和 unit），可整体复制到目标机。在该目录执行，例如 Ubuntu / Debian：

```sh
cd device
uname -m
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libssl-dev libnice-dev ca-certificates python3 curl openssl
cmake -S se9-c -B build/se9-c -DCMAKE_BUILD_TYPE=Release
cmake --build build/se9-c --parallel 2
ctest --test-dir build/se9-c --output-on-failure
file build/se9-c/se9_agent build/se9-c/se9_file_api
ldd build/se9-c/se9_agent
build/se9-c/se9_agent --config-info
```

构建默认使用 `se9-c/third_party` 内的 cJSON 和 libdatachannel（含子模块），目录缺失时才按固定提交联网拉取；也可显式指定 `-DFETCHCONTENT_SOURCE_DIR_CJSON=/absolute/path/cJSON` 和 `-DFETCHCONTENT_SOURCE_DIR_DATACHANNEL=/absolute/path/libdatachannel`。公钥取自 `deploy/cloud-grant-public.pem`，也可用 `-DSE9_CLOUD_GRANT_PUBLIC_KEY_FILE=/absolute/path/public.pem` 指定构建信任的其他公钥。

`-DSE9_WEBRTC=OFF` 可构建仅兼容旧传输的程序。`-DSE9_USE_LIBNICE=OFF` 使用 libjuice，该构建不可视为支持 TURN TCP/TLS。

### 安装并启动

先确认 NAS 数据卷已经挂载，再选择专用文件目录。下面安装脚本是运行在目标 Linux NAS 上的操作；本机 Mac 不会执行它。

```sh
sudo python3 deploy/install_nas.py --storage-root /vos/workspace/demo
```

默认读取 `build/se9-c`（相对 `device` 目录）；如构建目录不同，增加 `--build-dir /absolute/path/build`；仅安装配置而不启动，增加 `--no-start`。

安装脚本会：

- 检查两个 Linux ELF 程序的架构、运行库、默认云地址、公钥指纹和 WebRTC 编译状态；拒绝旧构建或错误配置的程序。
- 创建 `se9` 服务账号和专用目录，将两个程序安装至 `/opt/se9`。
- 配置 HTTPS 地址、启用 WebRTC、移除旧公钥文件覆盖，使用编译内置的公钥。
- 保留已配置的设备私钥和 device-token；无配置时识别常见历史私钥路径，存在多个候选则停止，避免更换设备身份。
- 保留匹配的旧代理密钥；新安装移除占位符，两个进程自动创建同一个随机密钥文件。旧配置密钥或端口不一致时停止。
- 为缺失或占位的本地 admin 密码生成随机值，保存到受限环境文件，不在终端输出。
- 备份已有程序、环境文件、公钥和 unit 到 `/var/backups/se9-nas/<时间戳>`，不覆盖存储文件或重建设备私钥。
- 更新 systemd 的可写存储路径，先启动并检查 File API，再启动 Agent，设置开机自启。

安装脚本会将 NAS 云配置迁移为当前阿里云 HTTPS 地址，并启用 WebRTC。如需使用自定义云地址或关闭 RTC，应在安装后修改环境文件再启动。安装后若启动失败，检查日志，不要删除设备私钥来“重试”。

### 配置覆盖与权限

旧的 `SE9_FILE_API_URL` 不被读取，修改本机端口应使用 `FILE_API_PORT`。程序通过环境变量读取参数，不自行解析 `.env`；systemd 的 EnvironmentFile 负责加载。前台运行时需显式导出变量。

| 参数 | 作用 |
|---|---|
| `SE9_CLOUD_URL` | 覆盖内置 origin，包含协议、主机、端口，不含 `/se9` |
| `SE9_CLOUD_BASE_PATH` | 覆盖 `/se9`，本地直连 Go 测试可明确设为空 |
| `SE9_CLOUD_GRANT_PUBLIC_KEY` | 明确指定外部公钥 PEM；路径无效时启动失败，不回退到其他密钥 |
| `SE9_RTC_ENABLED` | 未设置或 `1` 启用；`0` 关闭；其他值拒绝 |
| `SE9_RTC_ALLOW_INSECURE_LOCAL` | 仅隔离回环测试可设 `1`，生产为 `0` |
| `SE9_TLS_INSECURE` | 旧 HTTP/WS 兼容路径的跳过证书测试选项，生产保持 `0` |
| `SE9_CA_FILE` | Linux 默认 `/etc/ssl/certs/ca-certificates.crt`；macOS 测试可设 `/etc/ssl/cert.pem` |
| `SE9_KEY_FILE` / `SE9_TOKEN_FILE` | 设备身份私钥与云端凭证路径，升级不能重建 |
| `SE9_DEVICE_NAME` | 设备名称，避免引号和反斜杠 |
| `SE9_AGENT_PROXY_TOKEN_FILE` | 两个进程的共同密钥文件，默认 `/var/lib/se9/agent-proxy-token` |
| `SE9_AGENT_PROXY_TOKEN` | 兼容显式旧密钥，两端必须相同；拒绝 `replace-` 占位值 |
| `FILE_API_PORT` | 两端一致，默认 `8443` |
| `FILE_API_BIND_ADDR` | File API 默认 `127.0.0.1`；LAN 直连需自行限制访问来源 |
| `STORAGE_ROOT` | File API 数据根目录，必须与 unit 的可写路径一致 |
| `DEMO_ADMIN_PASSWORD` | File API 本地 admin 密码，独立于云账号，安装脚本自动生成 |

新生成的代理密钥要求普通文件、当前服务账号所有、0600 权限；拒绝符号链接和宽松权限。其父目录必须已创建且服务账号可写，安装脚本负责准备 `/var/lib/se9`。并发启动使用原子发布，两个进程不会各自产生不同的代理密钥。

环境文件位于 `/etc/se9/se9-agent.env` 和 `/etc/se9/se9-file-api.env`，权限 0640，root:se9。设备私钥、device-token、代理密钥和 `.se9-transfers/store.key` 属于本机私有状态，不要提交到代码仓库。只把公钥分发给 NAS；云端签名私钥和 TURN 共享密钥只留在云端。

### 日志、绑定与升级

```sh
systemctl status se9-file-api se9-agent
journalctl -u se9-file-api -u se9-agent --since today
tail -n 80 /var/log/se9/agent.error.log
curl -fsS http://127.0.0.1:8443/api/v2/health
curl -fsS https://123.56.147.51:8443/se9/health
```

Agent 首次无法注册到云端时退出，由 systemd 稍后重试；公钥配置无效或代理密钥无法加载时也会明确失败。成功注册后应出现 RTC 信令已连接的日志。

首次绑定要求手机和 NAS 同一局域网，放行该局域网入站 UDP 37020。绑定后 App 登录同一云账号，通过设备列表操作文件。NAS 不需要公网 IP 或路由器入站映射，但需出站 TCP 8443（HTTPS/WSS），并允许 ICE/TURN 使用所需的网络端口。App 默认 HTTPS 地址已修改，手机需运行更新后的版本。

升级时重新编译后再次执行安装命令；脚本保留已有身份和文件。回滚只恢复对应备份的程序及配置，不用旧快照覆盖新写入文件。代理密钥损坏应先检查权限和备份，不要随意重置设备身份。

### 已验证与待验证

配置测试覆盖内置公钥、显式无效公钥、并发生成共享密钥、重启复用、权限和符号链接保护；持久化传输测试覆盖重启续传、旧 epoch、校验失败、快照和原子提交。安装脚本检查覆盖环境值保留、错误二进制架构、缺失运行库、旧程序拒绝和内置公钥不一致；IP TLS 测试确认正确 IP SAN 可用、仅 DNS SAN 的 IP 证书被拒绝。HTTPS/WSS 下自动代理密钥、WebRTC 上传下载和跨传输续传已通过隔离联调。

实体 NAS 的 CPU、系统、存储挂载与 systemd 安装仍需在目标设备执行确认；本次不宣称实体设备已安装或公网 TURN 已畅通。

## English

### Current defaults

The source embeds `https://123.56.147.51:8443` with prefix `/se9`. The build embeds the Ed25519 public key from `deploy/cloud-grant-public.pem`. When RTC support is compiled, runtime RTC is enabled by default; no manual cloud address, public-key file, or `SE9_RTC_ENABLED=1` is required. HTTPS/WSS validates an IP origin against the certificate IP SAN while retaining CA trust verification.

Two processes run on the NAS: `se9_file_api` owns files and durable transfer state, while `se9_agent` handles discovery/binding, cloud registration/heartbeats, WebRTC, and server forwarding. The Go cloud service runs on Aliyun and must not be duplicated on the NAS.

| Setting/file | Default behavior |
|---|---|
| Cloud origin | `https://123.56.147.51:8443` |
| Cloud prefix | `/se9` |
| Cloud authorization public key | Embedded at build time from `deploy/cloud-grant-public.pem` |
| WebRTC | Enabled when compiled; explicitly disable with `SE9_RTC_ENABLED=0` |
| Local proxy key | First startup creates a random 32-byte key at `/var/lib/se9/agent-proxy-token`, mode 0600; both processes reuse it |
| Device private key | `/var/lib/se9/device-ed25519.pem`, generated on first startup and retained during upgrades |
| Cloud device credential | `/var/lib/se9/device-token`, persisted after registration and retained |
| File service | `127.0.0.1:8443`, accessed by the local Agent |
| Storage | `/vos/workspace/demo` by default, configurable during installation |

See [IP_DEPLOYMENT.md](../../IP_DEPLOYMENT.md) for the public server and certificate renewal. Public TURN ports still require security-group/upstream-network verification; public relay is not marked accepted. Configured source code does not mean installation on a physical NAS has occurred.

### Build on Linux NAS

The code targets POSIX Linux; the installer requires systemd. Binaries must match the NAS architecture and runtime libraries. macOS binaries cannot be copied to Linux. The default libnice backend supports TURN UDP/TCP/TLS; the C application uses the C API of the C++17 libdatachannel implementation.

The `device` directory is a complete NAS delivery bundle (source, third-party dependencies, public key, installer, and units) and can be copied wholesale to the target machine. Run there, for example on Ubuntu / Debian:

```sh
cd device
uname -m
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libssl-dev libnice-dev ca-certificates python3 curl openssl
cmake -S se9-c -B build/se9-c -DCMAKE_BUILD_TYPE=Release
cmake --build build/se9-c --parallel 2
ctest --test-dir build/se9-c --output-on-failure
file build/se9-c/se9_agent build/se9-c/se9_file_api
ldd build/se9-c/se9_agent
build/se9-c/se9_agent --config-info
```

The build uses the pinned cJSON and libdatachannel sources (with submodules) under `se9-c/third_party` by default and only fetches them when those directories are absent. Explicit overrides remain available with `-DFETCHCONTENT_SOURCE_DIR_CJSON=/absolute/path/cJSON` and `-DFETCHCONTENT_SOURCE_DIR_DATACHANNEL=/absolute/path/libdatachannel`. The trusted public key comes from `deploy/cloud-grant-public.pem`; select a different one with `-DSE9_CLOUD_GRANT_PUBLIC_KEY_FILE=/absolute/path/public.pem`.

`-DSE9_WEBRTC=OFF` builds legacy-only transport. `-DSE9_USE_LIBNICE=OFF` selects libjuice and must not be advertised as supporting TURN TCP/TLS.

### Install and start

Confirm that the NAS data volume is mounted and choose a dedicated storage directory. Run this on the target Linux NAS; it is not executed on the local Mac.

```sh
sudo python3 deploy/install_nas.py --storage-root /vos/workspace/demo
```

The default build directory is `build/se9-c` relative to `device`. For another build directory add `--build-dir /absolute/path/build`; add `--no-start` to install without starting services.

The installer:

- Checks ELF architecture, runtime libraries, embedded cloud origin/key fingerprint, and compiled RTC support; rejects old or mismatched builds.
- Creates the `se9` service account and directories and installs binaries under `/opt/se9`.
- Configures HTTPS, enables RTC, removes the old public-key file override, and uses the embedded public key.
- Preserves configured device identity and device-token. Without configuration, it recognizes common historical key paths and stops on multiple candidates rather than replacing identity.
- Retains matching old proxy keys. Fresh installs remove placeholders and both processes generate one shared key file. Conflicting old keys or ports abort installation.
- Generates a random local admin password when missing or a placeholder, stores it in a restricted environment file, and does not print it.
- Backs up existing binaries, environment files, public key, and units to `/var/backups/se9-nas/<timestamp>` without overwriting stored data or regenerating device keys.
- Updates systemd writable storage paths, starts/checks File API before Agent, and enables startup at boot.

Installation migrates cloud configuration to the current Aliyun HTTPS origin and enables RTC. For a custom origin or disabled RTC, edit the environment after installation and before startup. Inspect startup failures through logs; do not delete the device identity to retry.

### Overrides and permissions

The obsolete `SE9_FILE_API_URL` is not read; use `FILE_API_PORT` for local port changes. Programs read environment variables, not `.env` files directly. systemd loads EnvironmentFile; foreground runs need explicitly exported variables.

| Variable | Purpose |
|---|---|
| `SE9_CLOUD_URL` | Override the origin, including scheme/host/port but excluding `/se9` |
| `SE9_CLOUD_BASE_PATH` | Override `/se9`; local direct-Go tests can explicitly set empty |
| `SE9_CLOUD_GRANT_PUBLIC_KEY` | Explicit external public-key PEM; an invalid path fails rather than falling back |
| `SE9_RTC_ENABLED` | Unset or `1` enables, `0` disables, other values fail |
| `SE9_RTC_ALLOW_INSECURE_LOCAL` | `1` only for isolated loopback tests; keep `0` in production |
| `SE9_TLS_INSECURE` | Legacy transport certificate-bypass test option; keep `0` in production |
| `SE9_CA_FILE` | Linux `/etc/ssl/certs/ca-certificates.crt`; macOS tests can use `/etc/ssl/cert.pem` |
| `SE9_KEY_FILE` / `SE9_TOKEN_FILE` | Persistent device private key and cloud credential; do not regenerate during upgrades |
| `SE9_DEVICE_NAME` | Device name; avoid quotes and backslashes |
| `SE9_AGENT_PROXY_TOKEN_FILE` | Shared local proxy key path, default `/var/lib/se9/agent-proxy-token` |
| `SE9_AGENT_PROXY_TOKEN` | Compatible explicit key, identical in both processes; `replace-` placeholders fail |
| `FILE_API_PORT` | Identical in both processes, default `8443` |
| `FILE_API_BIND_ADDR` | File API defaults to `127.0.0.1`; restrict clients if enabling LAN access |
| `STORAGE_ROOT` | File API storage root, matching systemd writable paths |
| `DEMO_ADMIN_PASSWORD` | Local File API admin password, independent of cloud accounts; generated by the installer |

Generated proxy keys must be regular files owned by the current service account, mode 0600. Symlinks and permissive modes are rejected. The writable parent directory must already exist; the installer prepares `/var/lib/se9`. Atomic publication prevents concurrent processes from generating different active keys.

Environment files are `/etc/se9/se9-agent.env` and `/etc/se9/se9-file-api.env`, mode 0640, root:se9. Device private keys, device-token, proxy keys, and `.se9-transfers/store.key` are local secrets and must not enter source control. Distribute public keys only; cloud signing private keys and TURN shared secrets remain on the cloud server.

### Logs, binding, and upgrades

```sh
systemctl status se9-file-api se9-agent
journalctl -u se9-file-api -u se9-agent --since today
tail -n 80 /var/log/se9/agent.error.log
curl -fsS http://127.0.0.1:8443/api/v2/health
curl -fsS https://123.56.147.51:8443/se9/health
```

If initial cloud registration fails, Agent exits so systemd can retry. Invalid key configuration or an unreadable proxy key also fails explicitly. A successful startup should report that RTC signaling connected.

Initial binding requires phone and NAS on the same LAN with inbound LAN UDP 37020 permitted. Then the App uses the same cloud account and device list for remote file operations. NAS needs no public IP or router inbound mapping, but must allow outbound TCP 8443 (HTTPS/WSS) and ICE/TURN traffic. The App default HTTPS origin has been updated; the phone must run the updated build.

Rebuild and rerun installation for upgrades; identity and stored files are preserved. Roll back matching binaries/configuration without replacing newly written files with old snapshots. Inspect proxy-key permissions/backups before resetting anything; do not casually replace device identity.

### Verified and pending

Configuration checks cover the embedded public key, invalid explicit keys, concurrent shared-key creation, restart reuse, permissions, and symlink protection. Durable transfer checks cover restart resume, stale epochs, checksum failure, snapshots, and atomic publication. Installer checks cover preserved environment values, wrong architectures, missing libraries, old-build rejection, and mismatched pinned keys. IP TLS tests accept correct IP SANs and reject DNS-only SANs for IP origins. Isolated HTTPS/WSS tests passed automatic proxy keys, WebRTC upload/download, and cross-transport resume.

CPU, OS, mounted storage, and full systemd installation still require checks on the target physical NAS. This change does not claim the physical NAS is installed or public TURN is reachable.
