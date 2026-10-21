# SE9 部署入口 / SE9 Deployment Entry Point

## 中文

设备端的完整部署流程统一维护在 **[NAS 部署与运维](../device/se9-c/README.md)**，按顺序执行首次部署，已有设备使用其中的升级流程。该文档包含 Linux 依赖与编译、用户与目录权限、全部环境参数、配置生成、systemd、阿里云与 Nginx 当前配置、App 绑定及上传下载、验收、日志、备份、回滚和停止步骤。

### 本目录文件

本目录只保留云端/证书相关文件。**设备端的源码、三方依赖、公钥、安装脚本、systemd unit 和环境示例已全部移至 [`device/deploy`](../device/deploy) 与 [`device/se9-c`](../device/se9-c)**，`device` 目录可整体复制到目标 NAS。

| 文件 | 用途与注意事项 |
| --- | --- |
| `se9-cloud.env.example` | 云端直接 TLS 场景的示例；不代表当前阿里云的环境文件内容 |
| `se9-ip-https.conf` | 公网 `443` 站点（PSYNC 域名证书 + `/se9/` 反代） |
| `se9-ip-8443.conf` | SE9 专用 `8443` 站点（IP SAN 证书），`/se9/` → `127.0.0.1:18082` |
| `se9-ip-cert-renew.service` / `.timer` | IP 证书续期定时器 |
| `se9-ip-certificate-hook` | 续期后更新 TURN 证书副本并重载 Nginx |
| `se9-turn.service` | TURN 服务 unit |
| `coturn.conf.example` | TURN 配置示例，占位值上线前必须替换 |

### 关键配置约定

- 本文关联的完整指南使用 NAS File API 端口 `18443`；源码和部分旧模板默认 `8443`。两个 NAS 环境文件里的 `FILE_API_PORT` 必须相同，已有部署保留原端口。
- `SE9_AGENT_PROXY_TOKEN` 必须在 Agent 与 File API 两边一致。首次部署按完整指南安全生成，已有设备保留原配置。
- 当前阿里云 HTTPS 地址为 `https://123.56.147.51:8443/se9`（IP SAN 证书）；Agent 已内置该地址和 `/se9`，无需在环境文件中配置服务器地址；App 用完整的 `SE9_CLOUD_API`。`http://123.56.147.51/se9`（80 端口）仅作兼容入口。443 端口使用 `*.hualaikeji.com` 域名证书，仅服务 PSYNC，SE9 不要连 443。已有服务器环境变量仍可覆盖内置值，仅用于调试和迁移。
- 当前云端为 `se9-cloud.service`，Go 监听 `18082`，通过 Nginx `/se9/` 入口提供 HTTP/WS。`se9-cloud.env.example` 的 `8443` 和证书路径只是另一种部署示例，不能直接覆盖现有 `/etc/se9-cloud.env`。
- 不覆盖设备长期私钥、设备 token、云端状态文件或用户存储卷；升级时先备份。修改 `STORAGE_ROOT` 同时检查 File API unit 的 `ReadWritePaths`。

本次只维护部署文档，不执行安装、重启或配置覆盖。源码联调流程见 [LOCAL_VALIDATION.md](../device/se9-c/LOCAL_VALIDATION.md)，云端概览见 [云端服务说明](../cmd/cloud/README.md)。

## English

The complete device deployment procedure is maintained in **[NAS Deployment and Operations](../device/se9-c/README.md)**. Follow it in order for a fresh installation and use its upgrade procedure for existing devices. It covers Linux dependencies/builds, user and directory permissions, every environment variable, configuration generation, systemd, current Alibaba Cloud/Nginx settings, App claiming and transfers, acceptance, logs, backups, rollback, and stopping.

### Files in this directory

This directory now holds only cloud/certificate files. **Device source, third-party dependencies, the public key, installer, systemd units, and environment examples all live in [`device/deploy`](../device/deploy) and [`device/se9-c`](../device/se9-c)**; the `device` directory can be copied wholesale to the target NAS.

| File | Purpose and notes |
| --- | --- |
| `se9-cloud.env.example` | Example for direct cloud TLS, not the current Alibaba Cloud environment file |
| `se9-ip-https.conf` | Public `443` vhost (PSYNC domain certificate plus `/se9/` proxy) |
| `se9-ip-8443.conf` | SE9-only `8443` vhost (IP-SAN certificate), `/se9/` → `127.0.0.1:18082` |
| `se9-ip-cert-renew.service` / `.timer` | IP certificate renewal timer |
| `se9-ip-certificate-hook` | Refreshes the TURN certificate copy and reloads Nginx after renewal |
| `se9-turn.service` | TURN service unit |
| `coturn.conf.example` | TURN configuration example; replace placeholders before deployment |

### Key configuration conventions

- The full guide uses NAS File API port `18443`; source and some older templates default to `8443`. Both NAS environment files must set the same `FILE_API_PORT`. Preserve existing ports during upgrades.
- Both Agent and File API must use the same `SE9_AGENT_PROXY_TOKEN`. Generate it securely using the full guide on new installs; preserve existing configuration otherwise.
- The current cloud HTTPS base is `https://123.56.147.51:8443/se9` (IP-SAN certificate). Agent has this origin and `/se9` built in, so cloud environment settings are unnecessary; App uses the complete `SE9_CLOUD_API`. `http://123.56.147.51/se9` on port 80 remains a compatibility entry. Port 443 uses the `*.hualaikeji.com` certificate and serves PSYNC only; SE9 must not use 443. Existing environment overrides remain for debugging and migration.
- The current cloud runs `se9-cloud.service`, with Go on `18082` and Nginx `/se9/` serving HTTP/WS. The cloud example's `8443` and certificate paths describe a different setup; do not overwrite existing `/etc/se9-cloud.env` with them.
- Preserve the long-lived device key, device token, cloud state, and user volume. Back up before upgrades. Changes to `STORAGE_ROOT` also require checking File API `ReadWritePaths`.

This update changes documentation only, without installation, restarts, or configuration replacement. See [LOCAL_VALIDATION.md](../device/se9-c/LOCAL_VALIDATION.md) for source integration checks and [cloud service](../cmd/cloud/README.md) for an overview.
