# SE9 文件管理平台接口文档 / SE9 File Management Platform API Reference

## 中文

### 1. 文档范围

本文档定义 SE9 移动文件管理 Demo 及后续正式版本的接口协议，面向 Flutter App、阿里云 Go 服务和 SE9 Ubuntu C 服务开发人员。

接口按服务划分：

| 服务 | 实现语言 | 运行位置 | 主要职责 |
| --- | --- | --- | --- |
| Cloud Control API | Go | 阿里云上海 | 用户、设备、绑定、会话 |
| Cloud Relay | Go | 阿里云上海 | App 与 SE9 的远程数据转发 |
| Device File API | C | SE9 Ubuntu | 文件、目录、上传、下载和权限 |
| Device Discovery API | C | SE9 局域网 | 设备发现和绑定请求 |

除文件二进制接口外，所有接口使用 JSON。接口前缀为 `/api/v2`。

### 2. 基础地址、请求头和统一包络

云端基础地址示例：

```text
https://api.example.com
```

SE9 局域网地址示例：

```text
http://192.168.1.50:8443
```

通用请求头：

| 请求头 | 必填 | 说明 |
| --- | --- | --- |
| `Content-Type` | JSON 接口必填 | `application/json` |
| `Authorization` | 用户接口必填 | `Bearer <accessToken>` |
| `X-Request-ID` | 建议 | 客户端生成的请求追踪 ID |
| `X-Device-ID` | 设备接口必填 | SE9 设备 ID |
| `X-Session-ID` | 远程会话必填 | 云端创建的短期会话 ID |

JSON 请求包络：

```json
{
  "requestId": "0123456789abcdef0123456789abcdef",
  "timestamp": 1788768000000,
  "data": {}
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `requestId` | string | 是 | 32 位请求 ID；用于幂等和日志关联 |
| `timestamp` | int64 | 是 | Unix 毫秒时间；允许与服务端相差 5 分钟 |
| `data` | object | 按接口 | 业务参数 |

JSON 响应包络：

```json
{
  "responseId": "89abcdef0123456789abcdef01234567",
  "timestamp": 1788768000123,
  "code": "0",
  "message": "success",
  "data": {}
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `responseId` | string | 服务端追踪 ID |
| `timestamp` | int64 | 服务端 Unix 毫秒时间 |
| `code` | string | `"0"` 表示成功，其他值表示业务错误 |
| `message` | string | 成功或错误说明 |
| `data` | object/array/null | 业务结果 |

HTTP 状态码仍然表示传输层结果：`200`/`201` 成功，`400` 参数错误，`401` 未认证，`403` 无权限，`404` 不存在，`409` 状态冲突，`413` 请求过大，`429` 频率限制，`500` 服务错误。

### 3. 统一数据模型

#### 3.1 用户

```json
{
  "userId": "user-001",
  "account": "user@example.com",
  "nickname": "Alice"
}
```

#### 3.2 设备

```json
{
  "deviceId": "se9-001",
  "name": "客厅 NAS",
  "publicKey": "base64-public-key",
  "status": "online",
  "claimStatus": "claimed",
  "lastSeenAt": 1788768000
}
```

`status` 为 `online`、`offline`、`connecting` 或 `error`；`claimStatus` 为 `pending_claim`、`claiming` 或 `claimed`。

#### 3.3 文件

```json
{
  "fileId": "sha256-or-device-id",
  "name": "video.mp4",
  "path": "/videos/video.mp4",
  "directory": false,
  "size": 1048576,
  "mimeType": "video/mp4",
  "modifiedAt": 1788768000
}
```

### 4. Cloud Control API（Go）

基础地址为云端域名。以下接口均要求 `Authorization`，除登录和注册外。

#### 4.1 认证接口

##### `POST /api/v2/auth/register`

请求 `data`：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `account` | string | 是 | 邮箱或手机号 |
| `password` | string | 是 | 8～64 个字符，至少包含字母和数字 |
| `nickname` | string | 否 | 1～32 个 Unicode 字符 |

成功响应 `data`：

```json
{
  "user": {"userId": "user-001", "account": "user@example.com", "nickname": "Alice"},
  "accessToken": "access-token",
  "refreshToken": "refresh-token",
  "expiresIn": 3600
}
```

##### `POST /api/v2/auth/login`

请求 `data`：`account` string、`password` string。

成功响应与注册接口相同。

##### `POST /api/v2/auth/refresh`

请求 `data`：`refreshToken` string。

成功响应：`accessToken` string、`expiresIn` int、`refreshToken` string。

##### `POST /api/v2/auth/logout`

请求 `data`：`{}`。服务端吊销当前 access token。

##### `GET /api/v2/auth/me`

无请求体。成功响应为当前用户模型。

#### 4.2 设备接口

##### `POST /api/v2/devices/register`

由 SE9 Agent 调用。请求 `data`：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `deviceId` | string | 是 | 设备唯一 ID |
| `name` | string | 否 | 设备名称 |
| `publicKey` | string | 是 | 设备公钥，Base64 |
| `firmwareVersion` | string | 否 | Agent 版本 |
| `capabilities` | object | 否 | 能力列表 |

成功响应：`deviceId`、`claimStatus`、`heartbeatInterval`。

##### `POST /api/v2/devices/{deviceId}/heartbeat`

由 SE9 Agent 调用。请求 `data`：`agentVersion` string、`ip` string、`storageFree` int64、`storageTotal` int64、`status` string。

成功响应：`serverTime` int64、`nextHeartbeatIn` int、`commands` array。

##### `GET /api/v2/device_list`（兼容 `GET /api/v2/devices`）

当前实现。必须携带当前账号的 `Authorization: Bearer <accessToken>`；只返回该账号已绑定的设备，不接受客户端提供的账号 ID。未绑定和其他账号的设备不会返回。请求无正文。

查询参数：`status` 可选，为 `online` 或 `offline`；`page` 默认为 1；`pageSize` 默认为 20，范围 1–100。按 `deviceId` 排序。超过 90 秒没有心跳、没有心跳记录或明确标记离线的设备返回 `offline`，其他返回 `online`。无设备或超出末页时 `items` 为 `[]`。

成功响应的 `data`：

```json
{
  "items": [{"deviceId": "se9-001", "name": "Home NAS", "status": "online", "claimStatus": "claimed", "role": "owner", "lastSeen": "2026-10-20T01:30:00Z"}],
  "page": 1,
  "pageSize": 20,
  "total": 1
}
```

列表不包含设备 token、绑定字符串及其哈希。未认证返回 401；非法分页或状态参数返回 400；非 GET 请求返回 405。会话创建同样检查心跳有效期，离线设备返回 HTTP 409、错误码 `40905`。

App 登录、恢复会话和绑定成功后加载“我的设备”，支持手动刷新。通过在线设备卡片的“文件 / 下载”进入目录，或通过“上传”选择图片、视频及文件。后续文件操作携带所选设备的 `deviceId` 创建云端会话，复用现有中继。切换设备回到根目录并清空旧文件；上传完成刷新目录；文件行提供下载按钮。离线设备保留展示，禁用文件及上传操作。

##### `GET /api/v2/devices/{deviceId}`

无请求体。成功响应为设备模型和当前用户角色 `owner` 或 `member`。

##### `POST /api/v2/devices/claim/request`

请求 `data`：`deviceId` string、`localAddress` string 可选。

成功响应：`claimRequestId` string、`expiresIn` int、`status` 为 `claiming`。

##### `POST /api/v2/devices/claim/confirm`

请求 `data`：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `deviceId` | string | 是 | 设备 ID |
| `claimRequestId` | string | 是 | 绑定请求 ID |
| `claimString` | string | 是 | 通过 UDP 加密交换的一次性字符串 |

成功响应：设备模型、`role: "owner"`、`claimedAt` Unix 秒。

##### `POST /api/v2/devices/{deviceId}/claim/prepare`

设备 Agent 使用 `X-Device-Token` 调用。请求包含 `claimString`、`requestId` 和 Unix 秒 `expiresAt`；云端只保存绑定字符串哈希，确认时比对哈希并在成功后立即清除。绑定字符串有效期最多 10 分钟。

##### `DELETE /api/v2/devices/{deviceId}`

所有者调用。请求 `data`：`password` string 可选、`reason` string 可选。成功响应为 `{}`。

##### `POST /api/v2/devices/{deviceId}/reset-claim`

设备所有者调用。请求 `data`：`reason` string 可选。成功后设备进入 `pending_claim`。重置不会删除设备文件。

#### 4.3 远程会话接口

##### `POST /api/v2/sessions`

请求 `data`：`deviceId` string、`clientType` string（`ios`、`android`）、`accessMode` string（`files`）。

成功响应：

```json
{
  "sessionId": "session-001",
  "deviceId": "se9-001",
  "relayUrl": "wss://relay.example.com/api/v2/relay/app",
  "expiresAt": 1788768600
}
```

##### `GET /api/v2/sessions/{sessionId}`

成功响应：`sessionId`、`status`（`waiting_device`、`connected`、`closed`、`expired`）、`deviceId`、`expiresAt`。

##### `DELETE /api/v2/sessions/{sessionId}`

关闭远程会话。成功响应为 `{}`。

### 5. Cloud Relay API（Go）

中继使用 WebSocket，不使用 JSON HTTP 包络传输文件二进制。

#### 5.1 App 通道

```text
GET /api/v2/relay/app?sessionId=session-001
Authorization: Bearer <accessToken>
```

连接成功后，App 发送：

```json
{"type":"session_open","sessionId":"session-001","requestId":"req-001"}
```

之后每个消息包含：

```json
{
  "type": "http_request",
  "requestId": "req-002",
  "method": "GET",
  "path": "/api/v2/files?path=/videos",
  "headers": {"Authorization": "Bearer device-session-token"},
  "bodyBase64": ""
}
```

设备响应：

```json
{
  "type": "http_response",
  "requestId": "req-002",
  "status": 200,
  "headers": {"Content-Type": "application/json"},
  "bodyBase64": "eyJpdGVtcyI6W119"
}
```

文件分片可以使用二进制 WebSocket 帧，并在首帧 JSON 中声明 `uploadId`、`chunkIndex` 和 `contentLength`。

#### 5.2 Device Agent 通道

```text
GET /api/v2/relay/device?deviceId=se9-001
X-Device-Key: <device-key>
```

Agent 连接后发送：

```json
{"type":"device_auth","deviceId":"se9-001","publicKey":"...","agentVersion":"0.1.0"}
```

云端响应：

```json
{"type":"device_auth_ok","heartbeatInterval":30}
```

中继只允许同一个 `sessionId` 的 App 通道和 Device 通道互相转发。

### 6. SE9 Device File API（C）

局域网基础地址示例为 `http://192.168.1.50:8443`。远程调用时保持相同路径，由中继转发。

#### 6.1 本地认证

##### `POST /api/v2/auth/login`

请求 `data`：`username` string、`password` string。

成功响应：`accessToken` string、`username` string、`expiresIn` int。

##### `GET /api/v2/auth/me`

成功响应：`userId`、`username`、`role`、`storageRoot`。

#### 6.2 目录和文件

##### `GET /api/v2/files?path=/videos`

请求参数：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `path` | string | 否 | 相对于用户根目录的路径，默认 `/` |
| `page` | int | 否 | 默认 1 |
| `pageSize` | int | 否 | 默认 100，最大 500 |

成功响应：`path` string、`items` array<File>、`total` int。

##### `POST /api/v2/folders`

请求 `data`：`path` string、`name` string。成功响应：`file` DirectoryFile。

##### `PATCH /api/v2/files/{fileId}`

请求 `data`：`name` string 可选、`path` string 可选。至少一个字段必填。成功响应：更新后的 File。

##### `DELETE /api/v2/files/{fileId}`

请求 `data`：`permanent` bool，默认 false。成功响应：`fileId`、`deleted` bool、`recycleBinId` 可选。

##### `GET /api/v2/files/{fileId}/download`

无 JSON 请求体。成功返回二进制文件，并设置：

```text
Content-Type: 文件 MIME 类型
Content-Length: 文件大小
Content-Disposition: attachment; filename="video.mp4"
```

支持 `Range` 请求头，返回 `206 Partial Content`。

##### `GET /api/v2/files/{fileId}/preview`

请求参数：`width` int 可选、`height` int 可选、`quality` int 可选。图片返回图片数据；视频返回封面或预览地址。

##### `GET /api/v2/files/search?q=video`

请求参数：`q` string 必填、`path` string 可选、`page` int 可选、`pageSize` int 可选。成功响应：`items`、`total`、`query`。

#### 6.3 上传接口

##### `POST /api/v2/upload/sessions`

请求 `data`：

```json
{
  "path": "/videos/video.mp4",
  "size": 104857600,
  "mimeType": "video/mp4",
  "sha256": "optional-full-file-hash",
  "chunkSize": 8388608,
  "overwrite": false
}
```

成功响应：`uploadId` string、`chunkSize` int、`expiresAt` Unix 秒。

##### `GET /api/v2/upload/sessions/{uploadId}`

成功响应：`uploadId`、`path`、`size`、`chunkSize`、`receivedBytes`、`receivedChunks`、`status`（`created`、`uploading`、`completed`、`failed`、`cancelled`）。

##### `GET /api/v2/upload/sessions/{uploadId}/missing`

成功响应：`missingChunks` array<int>、`nextChunk` int。

##### `PUT /api/v2/upload/sessions/{uploadId}/chunks/{index}`

请求头：`Content-Length`、`Content-SHA256`。请求体为原始二进制分片，不使用 JSON 包络。

成功响应：`uploadId`、`chunkIndex`、`receivedBytes`、`chunkSha256`。

##### `POST /api/v2/upload/sessions/{uploadId}/complete`

请求 `data`：`sha256` string 可选。服务端校验分片完整性、合并文件并校验完整 SHA-256。

成功响应：`status: "completed"`、`file` File。

##### `DELETE /api/v2/upload/sessions/{uploadId}`

取消上传并删除临时分片。成功响应：`uploadId`、`status: "cancelled"`。

#### 6.4 分享接口

##### `POST /api/v2/shares`

请求 `data`：`fileId` string、`permission`（`read` 或 `read_write`）、`expiresAt` Unix 秒可选、`enableExternal` bool。

成功响应：`shareId`、`token`、`url`、`permission`、`expiresAt`。

##### `GET /api/v2/shares`

成功响应：`items` array<Share>、`total` int。

##### `GET /api/v2/shares/{shareId}`

成功响应：Share 模型和文件基本信息。

##### `DELETE /api/v2/shares/{shareId}`

成功响应：`deleted` bool。

##### `GET /api/v2/public/shares/{token}`

无登录要求。成功返回文件元数据；下载时使用 `GET /api/v2/public/shares/{token}/download`。

#### 6.5 回收站和存储

##### `GET /api/v2/recycle-bin`

成功响应：`items` array<File>、`total` int。

##### `POST /api/v2/recycle-bin/{fileId}/restore`

请求 `data`：`targetPath` string 可选。成功响应：恢复后的 File。

##### `DELETE /api/v2/recycle-bin/{fileId}`

永久删除文件。成功响应：`deleted` bool。

##### `DELETE /api/v2/recycle-bin`

清空当前用户回收站。成功响应：`deletedCount` int。

##### `GET /api/v2/storage`

成功响应：`totalBytes`、`usedBytes`、`freeBytes`、`userQuotaBytes`。

##### `GET /api/v2/health`

成功响应：`status`、`version`、`storageReady`、`storageRoot`。

### 7. Device Discovery and Pairing API（C）

发现推荐使用 mDNS；HTTP 接口用于确认和绑定。

##### `GET /api/v2/discovery`

无需登录。成功响应：`deviceId`、`name`、`ip`、`port`、`claimStatus`、`publicKeyFingerprint`、`apiVersion`。

##### `POST /api/v2/pairing/request`

请求 `data`：`deviceId` string、`appInstanceId` string、`userId` string、`appEphemeralPublicKey` string。成功响应：`pairingRequestId`、`status: "claiming"`、`expiresAt`。

##### `GET /api/v2/pairing/status?requestId=...`

成功响应：`requestId`、`status`（`claiming`、`claimed`、`rejected`、`expired`）、`claimString` 不通过 HTTP 返回。

##### `POST /api/v2/pairing/cancel`

请求 `data`：`requestId` string。成功响应：`status: "cancelled"`。

#### 7.1 局域网 UDP 控制协议

UDP 监听 `37020/udp`，只用于发现、握手和配对状态，不传输文件内容。数据报使用 UTF-8 JSON，最大 1200 字节。公共字段为 `version`、`type`、`requestId`、`timestamp`、`nonce` 和 `body`。

消息类型：`discover_request`、`discover_response`、`handshake_request`、`handshake_response`、`pairing_request`、`pairing_status`、`pairing_result`、`goodbye`、`error`。

设备响应必须带 `deviceId`、`serverTimestamp` 和 `signature`。签名算法为 Ed25519，签名内容是公共字段和 `body` 的规范化 JSON。App 必须校验时间偏差不超过 5 分钟、`requestId`/`nonce` 未重放、设备公钥指纹与已发现信息一致。

发现和握手流程：

```text
App -> 255.255.255.255:37020: discover_request
Device -> App 单播: discover_response
App -> Device 单播: handshake_request(appEphemeralPublicKey)
Device -> App 单播: handshake_response(deviceEphemeralPublicKey, lanSessionId)
App -> Device 单播: pairing_request(requestId)
Device -> App 单播: pairing_result(encryptedClaimString)
App -> HTTPS: /api/v2/devices/claim/confirm(claimString)
```

发现请求最多重试 3 次；设备 1 秒内响应；只有 `pending_claim` 设备才生成绑定字符串。`lanSessionId` 默认有效 10 分钟。App 和设备通过临时 X25519 密钥派生会话密钥，设备使用长期 Ed25519 密钥签名握手 transcript，`claimString` 使用 AES-256-GCM 或 ChaCha20-Poly1305 加密后通过单播 UDP 发送。云端使用原子操作保证第一个成功确认的用户成为 owner，后续请求返回设备已绑定。UDP 消息允许重复到达，配对请求和确认必须按 `requestId` 幂等。连续 3 次超时后，App 回退到云端会话。

`pairing_result` 的 `body` 至少包含：`requestId`、`keyId`、`algorithm`、`nonce`、`ciphertext`、`tag` 和 `expiresAt`。`ciphertext` 解密后的明文只包含 `claimString`、`deviceId`、`requestId` 和 `expiresAt`；App 必须校验这些字段与当前会话一致。

### 8. 错误码

| 错误码 | HTTP | 说明 |
| --- | ---: | --- |
| `0` | 200 | 成功 |
| `40001` | 400 | 请求格式错误 |
| `40002` | 400 | 缺少必填参数 |
| `40003` | 400 | 路径非法或越权 |
| `40101` | 401 | token 无效或过期 |
| `40301` | 403 | 无文件或设备权限 |
| `40401` | 404 | 文件不存在 |
| `40402` | 404 | 设备不存在 |
| `40901` | 409 | 设备已被绑定 |
| `40902` | 409 | 上传状态冲突 |
| `40903` | 409 | 文件已存在 |
| `41001` | 410 | 绑定字符串过期 |
| `41002` | 410 | 上传会话过期 |
| `41301` | 413 | 文件或分片过大 |
| `42901` | 429 | 请求频率过高 |
| `50001` | 500 | 文件系统错误 |
| `50002` | 500 | 中继服务错误 |

### 9. MVP 实现顺序

第一阶段必须实现：`auth/login`、`files`、`folders`、上传会话、分片上传、缺失分片、上传完成、下载、删除、health、设备注册、heartbeat、创建 session。

第二阶段实现：设备发现、绑定确认、WebSocket App 通道、WebSocket Device 通道、断线重连和成员权限。

第三阶段实现：分享、回收站、搜索、预览、Range 下载、配额、审计、TLS 和正式数据库。

## English

### 1. Scope

This document defines the API protocol for the SE9 mobile file-management demo and the future production version. It targets Flutter app developers, the Go services running in Alibaba Cloud, and the C services running on Ubuntu on SE9.

The APIs are grouped into Cloud Control API, Cloud Relay, Device File API, and Device Discovery API. JSON is used for all APIs except binary file transfers. The version prefix is `/api/v2`.

### 2. Base URLs, Headers, and Envelopes

Example cloud base URL:

```text
https://api.example.com
```

Example LAN device URL:

```text
http://192.168.1.50:8443
```

Common headers are `Content-Type: application/json`, `Authorization: Bearer <accessToken>`, `X-Request-ID`, `X-Device-ID`, and `X-Session-ID` as required by each endpoint.

JSON requests use `requestId`, `timestamp`, and `data`. JSON responses use `responseId`, `timestamp`, `code`, `message`, and `data`. Code `"0"` means success. HTTP status codes describe transport-level results: `200`/`201`, `400`, `401`, `403`, `404`, `409`, `413`, `429`, and `500`.

### 3. Common Models

The user model contains `userId`, `account`, and `nickname`. The device model contains `deviceId`, `name`, `publicKey`, `status`, `claimStatus`, and `lastSeenAt`. The file model contains `fileId`, `name`, `path`, `directory`, `size`, `mimeType`, and `modifiedAt`.

### 4. Cloud Control API (Go)

The Go control plane provides registration and login, token refresh, current-user lookup, device registration, heartbeat, device listing, device claiming, device unbinding, session creation, session lookup, and session closing.

The authentication endpoints are:

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| `POST` | `/api/v2/auth/register` | `account`, `password`, optional `nickname` | user, access token, refresh token, `expiresIn` |
| `POST` | `/api/v2/auth/login` | `account`, `password` | user, access token, refresh token, `expiresIn` |
| `POST` | `/api/v2/auth/refresh` | `refreshToken` | new access token and refresh token |
| `POST` | `/api/v2/auth/logout` | `{}` | `{}` |
| `GET` | `/api/v2/auth/me` | none | current user |

Device endpoints are:

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| `POST` | `/api/v2/devices/register` | `deviceId`, `publicKey`, optional name/version/capabilities | device and heartbeat interval |
| `POST` | `/api/v2/devices/{deviceId}/heartbeat` | agent version, IP, storage, status | server time, next interval, commands |
| `GET` | `/api/v2/device_list` (alias `/api/v2/devices`) | bearer access token; optional status/page/pageSize | current account’s bound devices |
| `GET` | `/api/v2/devices/{deviceId}` | none | device and user role |
| `POST` | `/api/v2/devices/claim/request` | `deviceId`, optional local address | claim request and expiry |
| `POST` | `/api/v2/devices/{deviceId}/claim/prepare` | device token, claim string, request ID, expiry | stores a one-time claim hash |
| `POST` | `/api/v2/devices/claim/confirm` | `deviceId`, request ID, one-time claim string | claimed device and owner role |
| `DELETE` | `/api/v2/devices/{deviceId}` | optional password/reason | `{}` |
| `POST` | `/api/v2/devices/{deviceId}/reset-claim` | optional reason | reset device state |

The implemented `GET /api/v2/device_list` and its alias `GET /api/v2/devices` require the current account's bearer access token. They return only owned devices, exclude unclaimed devices and other accounts, and do not accept a client-supplied account ID. There is no request body. Optional `status` accepts `online` or `offline`; `page` defaults to 1; `pageSize` defaults to 20 and is limited to 1–100. Results are sorted by `deviceId`. Missing heartbeats, heartbeats older than 90 seconds, or an explicit offline status produce `offline`; otherwise the status is `online`.

Successful envelope `data`:

```json
{
  "items": [{"deviceId": "se9-001", "name": "Home NAS", "status": "online", "claimStatus": "claimed", "role": "owner", "lastSeen": "2026-10-20T01:30:00Z"}],
  "page": 1,
  "pageSize": 20,
  "total": 1
}
```

Empty accounts and out-of-range pages return `items: []`. Device tokens, claim strings and their hashes are excluded. Unauthenticated requests return 401, invalid pagination/status returns 400, and non-GET requests return 405. Session creation uses the same heartbeat check and returns HTTP 409 with code `40905` for offline devices.

The app loads “我的设备” after login, session restoration, and binding, and supports manual refresh. Online cards offer “文件 / 下载” to browse directories and “上传” for photos, videos, and files. File operations create cloud sessions with the selected `deviceId` and reuse the existing relay. Switching devices resets the path to the root and clears old files. Uploads refresh the directory, and file rows provide a download button. Offline devices remain visible with file and upload actions disabled.

Session endpoints are:

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| `POST` | `/api/v2/sessions` | device ID, client type, access mode | session ID, relay URL, expiry |
| `GET` | `/api/v2/sessions/{sessionId}` | none | session status |
| `DELETE` | `/api/v2/sessions/{sessionId}` | none | `{}` |

### 5. Cloud Relay API (Go)

The relay uses WebSocket connections:

```text
GET /api/v2/relay/app?sessionId=...
GET /api/v2/relay/device?deviceId=...
```

The app authenticates with its bearer token. The device authenticates with its device key. JSON control frames contain `type`, `requestId`, `method`, `path`, `headers`, and `bodyBase64`; responses contain `type`, `requestId`, `status`, `headers`, and `bodyBase64`. Binary WebSocket frames may be used for upload chunks after a JSON metadata frame.

### 6. SE9 Device File API (C)

The C service runs at the local device address and uses the same paths when requests are forwarded through the relay.

Authentication endpoints are `POST /api/v2/auth/login` with `username` and `password`, and `GET /api/v2/auth/me` returning user ID, username, role, and storage root.

File and directory endpoints are:

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| `GET` | `/api/v2/files?path=` | path, page, pageSize | file list |
| `POST` | `/api/v2/folders` | parent path and name | directory file |
| `PATCH` | `/api/v2/files/{fileId}` | new name or path | updated file |
| `DELETE` | `/api/v2/files/{fileId}` | optional permanent flag | deletion result |
| `GET` | `/api/v2/files/{fileId}/download` | optional Range header | binary file |
| `GET` | `/api/v2/files/{fileId}/preview` | width, height, quality | preview data |
| `GET` | `/api/v2/files/search?q=` | query and paging | matching files |

Upload endpoints are:

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| `POST` | `/api/v2/upload/sessions` | path, size, MIME, hash, chunk size, overwrite | upload ID and expiry |
| `GET` | `/api/v2/upload/sessions/{id}` | none | upload status |
| `GET` | `/api/v2/upload/sessions/{id}/missing` | none | missing chunk indexes |
| `PUT` | `/api/v2/upload/sessions/{id}/chunks/{index}` | binary body and SHA-256 headers | received chunk result |
| `POST` | `/api/v2/upload/sessions/{id}/complete` | optional full SHA-256 | completed file |
| `DELETE` | `/api/v2/upload/sessions/{id}` | none | cancelled status |

The sharing endpoints are `POST /api/v2/shares`, `GET /api/v2/shares`, `GET /api/v2/shares/{shareId}`, `DELETE /api/v2/shares/{shareId}`, and `GET /api/v2/public/shares/{token}`. Their request fields are file ID, permission, expiry, and external-link flag; responses contain share ID, token, URL, permission, and expiry.

Recycle-bin endpoints are `GET /api/v2/recycle-bin`, `POST /api/v2/recycle-bin/{fileId}/restore`, `DELETE /api/v2/recycle-bin/{fileId}`, and `DELETE /api/v2/recycle-bin`. Storage endpoints are `GET /api/v2/storage` and `GET /api/v2/health`.

### 7. Device Discovery and Pairing API (C)

LAN discovery uses UDP control messages on `37020/udp`; file data is never sent over UDP. The HTTP endpoints are:

| Method | Path | Request | Response |
| --- | --- | --- | --- |
| `GET` | `/api/v2/discovery` | none | device ID, IP, port, claim status, public-key fingerprint |
| `POST` | `/api/v2/pairing/request` | device ID, app instance ID, user ID, app ephemeral public key | claim request and expiry |
| `GET` | `/api/v2/pairing/status?requestId=` | none | claiming/claimed/rejected/expired status; claim string is never returned over HTTP |
| `POST` | `/api/v2/pairing/cancel` | request ID | cancelled status |

#### 7.1 LAN UDP Control Protocol

UDP is used only for discovery, handshake, and pairing status. Datagrams use UTF-8 JSON and are limited to 1200 bytes. Common fields are `version`, `type`, `requestId`, `timestamp`, `nonce`, and `body`.

Message types are `discover_request`, `discover_response`, `handshake_request`, `handshake_response`, `pairing_request`, `pairing_status`, `pairing_result`, `goodbye`, and `error`.

Device responses include `deviceId`, `serverTimestamp`, and an Ed25519 `signature` over the canonical JSON of the common fields and `body`. The app verifies clock skew within five minutes, rejects replayed `requestId`/`nonce` values, and checks that the device public-key fingerprint matches the discovery result.

Discovery and handshake flow:

```text
App -> 255.255.255.255:37020: discover_request
Device -> app unicast: discover_response
App -> device unicast: handshake_request(appEphemeralPublicKey)
Device -> app unicast: handshake_response(deviceEphemeralPublicKey, lanSessionId)
App -> device unicast: pairing_request(requestId)
Device -> app unicast: pairing_result(encryptedClaimString)
App -> HTTPS: /api/v2/devices/claim/confirm(claimString)
```

The app retries discovery at most three times; the device responds within one second; only a `pending_claim` device generates a claim string; and `lanSessionId` is valid for ten minutes by default. The app and device derive a session key with ephemeral X25519 keys; the device signs the handshake transcript with its long-lived Ed25519 key; and the claim string is encrypted with AES-256-GCM or ChaCha20-Poly1305 before being sent by UDP unicast. The cloud uses an atomic first-claim operation so the first successful confirmation becomes the owner and later requests receive an already-claimed error. UDP messages may be duplicated, so pairing and confirmation requests are idempotent by `requestId`. After three consecutive timeouts, the app falls back to a cloud session.

The `pairing_result` body contains at least `requestId`, `keyId`, `algorithm`, `nonce`, `ciphertext`, `tag`, and `expiresAt`. The decrypted plaintext contains only `claimString`, `deviceId`, `requestId`, and `expiresAt`; the app must verify that these values match the current session.

### 8. Error Codes

`0` means success. `40001` and `40002` represent malformed or missing parameters. `40003` represents an invalid or unauthorized path. `40101` is an invalid or expired token. `40301` is a permission failure. `40401` and `40402` represent missing files and devices. `40901` and `40902` represent an already claimed device and an upload state conflict. `41001` and `41002` represent expired claim strings and upload sessions. `41301` is an oversized file or chunk. `42901` is rate limiting. `50001` and `50002` represent filesystem and relay errors.

### 9. MVP Delivery Order

The first phase implements login, file listing, folders, upload sessions, chunks, missing chunks, completion, download, deletion, health, device registration, heartbeat, and session creation. The second phase adds discovery, encrypted first-claim exchange, WebSocket app/device channels, reconnection, and member permissions. The third phase adds sharing, recycle bin, search, previews, range downloads, quotas, audit logs, TLS, and production persistence.
