# 本地联调与设备更新 / Local Validation and Device Update

## 中文

### 验证范围

`mobile/tool/verify_nas_local.dart` 启动真实 Go Cloud、C Agent 和 C File API，以临时目录隔离账号、设备身份和存储。它只访问本机，不连接实际 NAS 或阿里云。测试期间需要 UDP 37020 空闲。

覆盖：设备发现、X25519 握手、AES-GCM 解密、云端绑定、重复绑定拒绝、File API 认证、HTTP/WS 中继目录、8 MB 分片上传、缺失分片查询、完整文件 SHA-256、超过 8 MB 下载、Range 续传、重命名、删除和文件不存在响应。该脚本未覆盖 Flutter 相册选择器、iOS 实际网络、长期并发、TLS 证书链及真实 NAS 文件系统。

### 运行

在 `nas` 目录执行；Flutter/Dart 与 Go 必须可用：

```bash
cmake -S device/se9-c -B /tmp/se9-c-build
cmake --build /tmp/se9-c-build
go build -o /tmp/se9-cloud-local ./cmd/cloud
cd mobile
dart run tool/verify_nas_local.dart /tmp/se9-cloud-local /tmp/se9-c-build/se9_agent /tmp/se9-c-build/se9_file_api
```

内存检测构建：

```bash
cmake -S device/se9-c -B /tmp/se9-c-asan -DCMAKE_C_FLAGS='-fsanitize=address,undefined -g' -DCMAKE_EXE_LINKER_FLAGS='-fsanitize=address,undefined'
cmake --build /tmp/se9-c-asan
```

将脚本参数中的 C 二进制替换为 `/tmp/se9-c-asan` 下对应程序。脚本结束时停止其启动的进程，临时日志保留在系统临时目录中供排查。

### 本轮修复

- Agent 支持 HTTP IP 对应的 WS 连接，HTTPS 对应 WSS。
- Agent 中继单帧上限调整为 16 MB，可承载默认 8 MB 上传分片；超过上限会失败，不是无限制流式传输。
- 中继响应不再在 4 MB 处静默截断。
- Cloud 接受原生客户端缺少 Origin 的握手，但在 Upgrade 前验证用户或设备 token。
- 一个会话只启动一组双向转发，连接关闭后清理会话；设备连接匹配正在等待的 App。
- File API 文件路由前缀长度修正；零字节下载的 Content-Length 修正。
- Agent 启用证书链校验、验证 WebSocket Accept，修正握手输入边界及临时密钥释放。

### NAS 更新边界

本机产物是 macOS 程序，不能复制到 Linux NAS。应在 NAS 或对应 Linux 工具链重新编译。更新前保留现有二进制备份；不覆盖 `/etc/se9` 配置、设备私钥、设备 token 或用户文件。

Agent 已内置 `http://123.56.147.51:80` 和 `/se9`，正常部署无需配置服务器地址。此本机脚本会显式覆盖云端 URL 并将前缀设为空字符串，保证只访问临时本机服务。已有部署的 File API 端口是 18443 时，应保留 `FILE_API_PORT=18443`。Agent 与 File API 的代理密钥必须一致。

systemd 模板将 Agent 输出写入 `/var/log/se9/agent.log` 和 `/var/log/se9/agent.error.log`，不应只依赖 `journalctl` 查业务日志。2026-10-20 已将当前 Cloud（含账号设备列表）部署到阿里云；Go 后端端口为 18082，公网前缀为 `/se9`。完整设备部署与参数说明见 [README.md](README.md)。

## English

### Validation scope

`mobile/tool/verify_nas_local.dart` starts the real Go Cloud, C Agent, and C File API with temporary accounts, identity files, and storage. It accesses localhost only, never the actual NAS or Alibaba Cloud. UDP port 37020 must be free.

Coverage: discovery, X25519 handshake, AES-GCM decryption, cloud claiming, duplicate-claim rejection, File API authentication, HTTP/WS relay directory listing, 8 MB upload chunks, missing-chunk queries, full-file SHA-256, downloads exceeding 8 MB, Range resumption, renaming, deletion, and missing-file responses. This script does not cover the Flutter gallery picker, iOS networking, sustained concurrency, TLS certificate chains, or the real NAS filesystem.

### Running

Run from `nas` with Flutter/Dart and Go available:

```bash
cmake -S device/se9-c -B /tmp/se9-c-build
cmake --build /tmp/se9-c-build
go build -o /tmp/se9-cloud-local ./cmd/cloud
cd mobile
dart run tool/verify_nas_local.dart /tmp/se9-cloud-local /tmp/se9-c-build/se9_agent /tmp/se9-c-build/se9_file_api
```

Memory-check build:

```bash
cmake -S device/se9-c -B /tmp/se9-c-asan -DCMAKE_C_FLAGS='-fsanitize=address,undefined -g' -DCMAKE_EXE_LINKER_FLAGS='-fsanitize=address,undefined'
cmake --build /tmp/se9-c-asan
```

Replace the C binary arguments with the corresponding programs under `/tmp/se9-c-asan`. The script stops its child processes when finished and retains temporary logs for diagnosis.

### Fixes in this iteration

- Agent uses WS for HTTP IP URLs and WSS for HTTPS URLs.
- The relay frame limit is 16 MB, allowing the default 8 MB upload chunks. Larger frames fail; this is not unlimited streaming.
- Relay responses are no longer silently truncated at 4 MB.
- Cloud supports native clients without Origin while validating user or device tokens before Upgrade.
- Each session starts one bidirectional forwarding pair and is cleaned up on disconnect; device connections match waiting apps.
- File API file-route prefix lengths and zero-byte download Content-Length are corrected.
- Agent enables certificate-chain verification, verifies WebSocket Accept, bounds handshake inputs, and releases ephemeral keys.

### NAS update boundaries

Local executables target macOS and cannot be copied to Linux NAS. Rebuild on the NAS or with the appropriate Linux toolchain. Back up existing binaries before updating; preserve `/etc/se9`, device private keys, device tokens, and user files.

Agent has `http://123.56.147.51:80` and `/se9` built in; normal deployment needs no cloud settings. This local script explicitly overrides the cloud URL and sets the prefix to an empty string, ensuring it only accesses temporary localhost services. Preserve `FILE_API_PORT=18443` when that is the existing deployment’s File API port. Agent and File API proxy secrets must match.

The systemd template writes Agent output to `/var/log/se9/agent.log` and `/var/log/se9/agent.error.log`; business logs may not appear in `journalctl`. The current Cloud, including account device lists, was deployed to Alibaba Cloud on 2026-10-20. Its Go backend port is 18082 and public prefix is `/se9`. See [README.md](README.md) for complete device deployment and parameter instructions.
