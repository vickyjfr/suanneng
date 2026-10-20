# SE9 部署入口 / SE9 Deployment Entry Point

## 中文

设备端的完整部署流程统一维护在 **[NAS 部署与运维](../device/se9-c/README.md)**，按顺序执行首次部署，已有设备使用其中的升级流程。该文档包含 Linux 依赖与编译、用户与目录权限、全部环境参数、配置生成、systemd、阿里云与 Nginx 当前配置、App 绑定及上传下载、验收、日志、备份、回滚和停止步骤。

### 本目录文件

| 文件 | 用途与注意事项 |
| --- | --- |
| `se9-file-api.service` | NAS 文件服务 unit，工作目录 `/opt/se9`，读取 `/etc/se9/se9-file-api.env` |
| `se9-agent.service` | NAS Agent unit，依赖文件服务，读取 `/etc/se9/se9-agent.env` |
| `se9-file-api.env.example` | File API 旧参数示例；不能保留示例密码或代理密钥用于部署 |
| `se9-agent.env.example` | Agent 旧参数示例；其中 `SE9_FILE_API_URL` 当前未被源码读取，实际使用 `FILE_API_PORT` |
| `se9-cloud.env.example` | 云端直接 TLS 场景的示例；不代表当前阿里云的环境文件内容 |
| `se9-logrotate` | NAS 文件日志轮转，目标 `/var/log/se9` |

### 关键配置约定

- 本文关联的完整指南使用 NAS File API 端口 `18443`；源码和部分旧模板默认 `8443`。两个 NAS 环境文件里的 `FILE_API_PORT` 必须相同，已有部署保留原端口。
- `SE9_AGENT_PROXY_TOKEN` 必须在 Agent 与 File API 两边一致。首次部署按完整指南安全生成，已有设备保留原配置。
- 当前阿里云地址为 `http://123.56.147.51/se9`。Agent 已内置 `http://123.56.147.51:80` 和 `/se9`，无需在环境文件中配置服务器地址；App 用完整的 `SE9_CLOUD_API`。已有服务器环境变量仍可覆盖内置值，仅用于调试和迁移。
- 当前云端为 `se9-cloud.service`，Go 监听 `18082`，通过 Nginx `/se9/` 入口提供 HTTP/WS。`se9-cloud.env.example` 的 `8443` 和证书路径只是另一种部署示例，不能直接覆盖现有 `/etc/se9-cloud.env`。
- 不覆盖设备长期私钥、设备 token、云端状态文件或用户存储卷；升级时先备份。修改 `STORAGE_ROOT` 同时检查 File API unit 的 `ReadWritePaths`。

本次只维护部署文档，不执行安装、重启或配置覆盖。源码联调流程见 [LOCAL_VALIDATION.md](../device/se9-c/LOCAL_VALIDATION.md)，云端概览见 [云端服务说明](../cmd/cloud/README.md)。

## English

The complete device deployment procedure is maintained in **[NAS Deployment and Operations](../device/se9-c/README.md)**. Follow it in order for a fresh installation and use its upgrade procedure for existing devices. It covers Linux dependencies/builds, user and directory permissions, every environment variable, configuration generation, systemd, current Alibaba Cloud/Nginx settings, App claiming and transfers, acceptance, logs, backups, rollback, and stopping.

### Files in this directory

| File | Purpose and notes |
| --- | --- |
| `se9-file-api.service` | NAS File API unit, working directory `/opt/se9`, environment `/etc/se9/se9-file-api.env` |
| `se9-agent.service` | NAS Agent unit requiring File API, environment `/etc/se9/se9-agent.env` |
| `se9-file-api.env.example` | Older File API example; replace sample password and proxy secret before deployment |
| `se9-agent.env.example` | Older Agent example; `SE9_FILE_API_URL` is currently ignored, use `FILE_API_PORT` |
| `se9-cloud.env.example` | Example for direct cloud TLS, not the current Alibaba Cloud environment file |
| `se9-logrotate` | NAS file-log rotation under `/var/log/se9` |

### Key configuration conventions

- The full guide uses NAS File API port `18443`; source and some older templates default to `8443`. Both NAS environment files must set the same `FILE_API_PORT`. Preserve existing ports during upgrades.
- Both Agent and File API must use the same `SE9_AGENT_PROXY_TOKEN`. Generate it securely using the full guide on new installs; preserve existing configuration otherwise.
- The current cloud base is `http://123.56.147.51/se9`. Agent has `http://123.56.147.51:80` and `/se9` built in, so cloud environment settings are unnecessary; App uses the complete `SE9_CLOUD_API`. Existing environment overrides remain for debugging and migration.
- The current cloud runs `se9-cloud.service`, with Go on `18082` and Nginx `/se9/` serving HTTP/WS. The cloud example's `8443` and certificate paths describe a different setup; do not overwrite existing `/etc/se9-cloud.env` with them.
- Preserve the long-lived device key, device token, cloud state, and user volume. Back up before upgrades. Changes to `STORAGE_ROOT` also require checking File API `ReadWritePaths`.

This update changes documentation only, without installation, restarts, or configuration replacement. See [LOCAL_VALIDATION.md](../device/se9-c/LOCAL_VALIDATION.md) for source integration checks and [cloud service](../cmd/cloud/README.md) for an overview.
