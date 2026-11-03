# CertMate Docker 部署手册

本文是 CertMate Docker 部署与升级的权威说明。推荐方式是基于 GitHub Release 预构建产物的交互式安装向导与 Docker Compose 部署；业务使用说明请回到 [README.md](../README.md)。

## 1. 部署前提与核心架构

部署主机需要：

- Linux（或支持 WSL2/Docker Desktop 的 Windows）；
- Bash（Windows 下使用 PowerShell 5.1+）；
- Docker Engine 20.10+；
- Docker Compose v2，即 `docker compose` 命令。

### 为什么选择预构建产物部署？
在生产环境或配置受限的服务器上现场全量构建（前端 Vite + npm ci + Go 编译）极易因网络超时、内网隔离或内存不足（OOM）导致失败；同时在中国大陆服务器直接 `docker pull` 海外 Registry 也经常受限。

CertMate 采用与 `dsh-docker` 一致的现代化发布架构：
1. **CI 负责重活**：GitHub Actions 在云端完成前端 Vite 静态产物构建与 Go 单静态二进制交叉编译，并直接制作离线 Docker 镜像包 `certmate-image-${arch}.tar.gz`；
2. **直链加速下载**：用户利用 Git / GitHub Release 资产下载预打包文件，提供中国大陆镜像节点（如 `ghfast.top` 等）加速下载；
3. **100% 免远程 Docker Pull**：安装脚本直接执行 `docker load -i certmate-image-${arch}.tar.gz` 载入本地镜像 `certmate:local`，全程不连接任何 Docker Registry；
4. **100% 免本地依赖编译**：宿主机不需要安装 Node.js、npm、Go、OpenSSL 或任何开发依赖，启动时间仅需几秒钟。

---

## 2. 推荐：一键向导部署

### 2.1 Linux / macOS 在线安装

官方源直接安装：
```bash
curl -fsSL https://raw.githubusercontent.com/reina0721/certmanager/main/install.sh | bash
```

中国大陆服务器加速安装（脚本与 Release 产物均优先通过加速通道下载）：
```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/reina0721/certmanager/main/install.sh | bash -s -- --mirror cn
```

### 2.2 Windows 原生 PowerShell 安装

```powershell
irm https://raw.githubusercontent.com/reina0721/certmanager/main/install.ps1 | iex
```

### 2.3 交互式向导说明

运行安装脚本后，终端将引导您完成关键选项配置：
1. **安装根目录**：默认 `~/certmate`。所有编排文件、配置（`.env`）、持久化数据（`data/`）及证书（`certs/`）完全存放在该目录下，不向系统散落文件；
2. **Web 端口**：默认 `8080`。脚本会自动检查端口占用，发现冲突时提示更换；
3. **监听绑定地址**：默认 `127.0.0.1`（适合宿主机通过 Nginx/Caddy 等前端反代终止 TLS）；若设为 `0.0.0.0` 则允许局域网或公网直接访问；
4. **网络镜像策略**：可选 `global`（官方）或 `cn`（国内加速镜像）；
5. **管理员账户与密码**：可输入自定义密码（默认要求 >=12 位，加 `--weak-password` 允许 >=6 位），或直接回车由脚本自动生成 16 位高强度安全密码。

---

## 3. 非交互自动化静默部署（CI / 脚本运维）

如果要在云主机初始化、Ansible、Terraform 或自动化 Shell 中一键部署，可传递参数跳过交互：

```bash
curl -fsSL https://raw.githubusercontent.com/reina0721/certmanager/main/install.sh | bash -s -- \
  --dir /opt/certmate \
  --port 8080 \
  --bind 127.0.0.1 \
  --admin admin \
  --password 'MySuperSecretP@ss123' \
  --mirror cn \
  --yes
```

### 常用参数说明

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--dir <PATH>` | `~/certmate` | 项目安装根目录 |
| `--port <PORT>` | `8080` | 宿主机 Web 访问端口 |
| `--bind <IP>` | `127.0.0.1` | 绑定监听 IP（`127.0.0.1` 本机反代 或 `0.0.0.0` 全网访问） |
| `--admin <USER>` | `admin` | 管理员用户名 |
| `--password <PASS>`| 自动生成 | 管理员登录密码（留空自动生成 16 位安全密码） |
| `--weak-password` | 强密码模式 | 允许使用简短测试密码（>=6位） |
| `--mirror <global\|cn>`| `global` | 网络加速策略，`cn` 会使用国内加速节点 |
| `--version <VER>` | `latest` | 指定 Release 版本标签（如 `v1.0.0`） |
| `--no-deploy` | 立即启动 | 仅完成产物下载、解压与 `.env` 生成，不立即执行 Docker 启动 |
| `--yes`, `-y` | 交互向导 | 非交互静默确认，未指定项自动采用默认值 |
| `--from-source` | 否 | 从当前环境源码重新构建 |

---

## 4. 手动部署与两阶段配置模式

如果因内网隔离手工拷贝了 Release 部署包（`certmate-bundle-*.tar.gz` 与 `certmate-image-*.tar.gz`）：

### 4.1 解压与导入镜像

```bash
mkdir -p ~/certmate && cd ~/certmate
tar -xzf certmate-bundle-linux-amd64.tar.gz
docker load -i certmate-image-linux-amd64.tar.gz
```

### 4.2 第一步：生成 `.env`

```bash
bash scripts/deploy.sh init
```

当 `.env` 不存在时，脚本只复制 `.env.example` 为 `.env` 并将其设为 `0600`，提示人工确认后退出。

### 4.3 配置管理员账户

```bash
bash scripts/deploy.sh configure-admin
```

脚本会隐藏输入两次密码，并通过已导入的 Docker 镜像安全计算 bcrypt 哈希后写入 `.env`：

```env
ADMIN_PASSWORD_HASH='$2y$12$...'
ADMIN_PASSWORD=
```

### 4.4 第二步：生成 Secret 并启动

再次运行：

```bash
bash scripts/deploy.sh init
```

脚本会自动生成 32 字节高强度 `SESSION_SECRET` 与 `APP_ENCRYPTION_KEY`，校验目录权限后启动容器并等待健康检查就绪。

---

## 5. 源码本地自构建模式（高级开发者）

如果需要修改前端或后端源码并在本地重新全量编译：

```bash
# 结合 compose.build.yaml 使用本地 Dockerfile.source 编译
docker compose -f compose.yaml -f compose.build.yaml build

# 或通过脚本指定源码模式
bash scripts/deploy.sh init --from-source
```

源码构建会启动多阶段 Docker 编译：下载 Node 镜像、运行 `npm ci` 和 `npm run build`、下载 Go 编译器构建二进制、以及下载校验 `acme.sh`。这需要主机具备充足的内存与顺畅的互联网连接。

---

## 6. 配置项详解（`.env`）

| 配置 | 填写方式 | 说明 |
| --- | --- | --- |
| `ADMIN_USERNAME` | 用户指定 | 单管理员登录名 |
| `ADMIN_PASSWORD_HASH` | 脚本生成/单引号 | 管理员 bcrypt 哈希，含 `$` 时必须使用单引号包围 |
| `SESSION_SECRET` | 脚本自动生成 | 32 字节十六进制会话加密密钥 |
| `APP_ENCRYPTION_KEY` | 脚本自动生成 | 32 字节十六进制 DNS 凭据加密密钥 |
| `APP_PORT` | 用户指定 | 宿主机 Web 映射端口（容器内固定为 8080） |
| `BIND_ADDRESS` | 用户指定 | 宿主机监听地址（`127.0.0.1` 或 `0.0.0.0`） |
| `DATA_HOST_DIR` | 用户指定 | 宿主机数据持久化目录（存放 SQLite 与 ACME 状态） |
| `CERTS_HOST_DIR` | 用户指定 | 宿主机生产证书输出目录 |
| `APP_UID` / `APP_GID` | 用户指定 | 容器进程与文件所有者（默认 `10001:10001`） |
| `CERTMATE_IMAGE` | 产物预设 | Docker 镜像标签，产物部署默认为 `certmate:local` |
| `SESSION_COOKIE_SECURE` | 用户确认 | 生产环境必须保持 `true`（要求 HTTPS） |

修改 `.env` 后重新执行 `bash scripts/deploy.sh init` 即可使配置生效。

---

## 7. 更新与升级维护

### 7.1 升级前备份

在执行升级前，请妥善备份以下内容：
1. `.env` 配置文件；
2. `DATA_HOST_DIR`（默认 `./data`，包含 SQLite 数据库与 ACME 账号状态）；
3. `CERTS_HOST_DIR`（默认 `./certs`，生产证书目录）。

### 7.2 执行平滑更新

如果在 Git 工作目录下部署：
```bash
bash scripts/deploy.sh update
```
脚本会执行 `git pull --ff-only` 并平滑重启服务。

如果使用预构建产物部署：
重新执行 `install.sh` 脚本并指定新版本标签，脚本会自动下载新版产物并重新导入镜像平滑替换容器。应用启动时会自动执行 SQLite 向前数据库迁移。

---

## 8. 常见问题排查

1. **宿主机端口已被占用 (`port is already allocated`)**：
   修改 `.env` 中的 `APP_PORT`（例如改为 `8081`），然后重新运行 `bash scripts/deploy.sh init`。不要修改容器内部的 `LISTEN_ADDR`。
2. **目录权限错误 (`permission denied`)**：
   宿主机挂载目录（`./data` 和 `./certs`）的所有者必须与 `APP_UID:APP_GID`（默认 `10001:10001`）匹配。部署脚本在检测到权限不匹配时会给出具体的 `sudo chown -R 10001:10001 ...` 修复命令。
3. **登录后立即回到登录页**：
   在生产模式下 `SESSION_COOKIE_SECURE=true`，浏览器要求必须通过 HTTPS 协议传输 Cookie。如果是本机测试，请通过 `http://localhost:8080` 或 `http://127.0.0.1:8080` 访问。
4. **下载 Release 产物速度缓慢**：
   在中国大陆网络环境下，请在安装时添加 `--mirror cn` 参数，脚本将自动选择高速代理节点下载产物包。
