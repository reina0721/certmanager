#!/usr/bin/env bash
#
# CertMate 安装与向导部署脚本 (基于 Git/Release 预构建产物部署，免远程 Docker Pull)
#
# 用法：
#   交互式向导（推荐）：
#     curl -fsSL https://raw.githubusercontent.com/reina0721/certmanager/main/install.sh | bash
#     # 中国大陆网络加速：
#     curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/reina0721/certmanager/main/install.sh | bash -s -- --mirror cn
#
#   非交互自动化模式：
#     bash install.sh --dir /opt/certmate --port 8080 --bind 127.0.0.1 --admin admin --password 你的安全密码 --yes
#
set -Eeuo pipefail

REPO="reina0721/certmanager"
FALLBACK_VERSION="v1.0.0"

# 默认参数
TARGET_DIR="${CERTMATE_DIR:-$HOME/certmate}"
TARGET_DIR_EXPLICIT=0
PORT="${CERTMATE_PORT:-8080}"
PORT_EXPLICIT=0
BIND_ADDR="${CERTMATE_BIND:-127.0.0.1}"
BIND_EXPLICIT=0
MIRROR_POLICY="${CERTMATE_MIRROR:-global}"
MIRROR_EXPLICIT=0
ADMIN_USER="admin"
ADMIN_USER_EXPLICIT=0
ADMIN_PASS=""
ADMIN_PASS_EXPLICIT=0
WEAK_PASSWORD=0
VERSION="${CERTMATE_VERSION:-latest}"
DO_DEPLOY=1
EXPLICIT_YES=0
INSECURE=0
FROM_SOURCE=0
DOWNLOAD_MIRRORS="https://ghfast.top https://gh-proxy.com"

usage() {
    cat <<'EOF'
CertMate 安装部署向导 (Interactive & Prebuilt Artifact Installer)

用法:
  bash install.sh [选项]

选项:
  --dir DIR              安装部署目录 (默认: ~/certmate)
  --port PORT            Web 访问端口 (默认: 8080)
  --bind IP              监听绑定地址 (默认: 127.0.0.1，局域网/公网可设为 0.0.0.0)
  --mirror global|cn     网络加速策略 (默认: global; cn 模式使用国内加速节点下载产物)
  --admin USER           管理员用户名 (默认: admin)
  --password PASS        管理员访问密码 (留空自动生成安全强密码)
  --weak-password        允许使用测试短密码 (>=6位)
  --version vX.Y.Z       指定安装版本 (默认: latest)
  --no-deploy            仅下载解压并完成配置，不立即启动 Docker 容器
  --from-source          从当前源码编译 (本地开发调试使用)
  --yes, -y              非交互模式，未指定项自动采用默认值
  --insecure             跳过 Checksum 校验 (不推荐)
  -h, --help             显示此帮助信息
EOF
}

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m警告: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) TARGET_DIR="$2"; TARGET_DIR_EXPLICIT=1; shift 2 ;;
        --port) PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
        --bind) BIND_ADDR="$2"; BIND_EXPLICIT=1; shift 2 ;;
        --mirror) MIRROR_POLICY="$2"; MIRROR_EXPLICIT=1; shift 2 ;;
        --admin) ADMIN_USER="$2"; ADMIN_USER_EXPLICIT=1; shift 2 ;;
        --password) ADMIN_PASS="$2"; ADMIN_PASS_EXPLICIT=1; shift 2 ;;
        --weak-password) WEAK_PASSWORD=1; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        --no-deploy) DO_DEPLOY=0; shift ;;
        --from-source) FROM_SOURCE=1; shift ;;
        --yes|-y) EXPLICIT_YES=1; shift ;;
        --insecure) INSECURE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知选项: $1" ;;
    esac
done

case "$TARGET_DIR" in
    "~"*) TARGET_DIR="${HOME}${TARGET_DIR#"~"}" ;;
esac

case "$MIRROR_POLICY" in
    global|cn) ;;
    *) die "--mirror 必须是 global 或 cn" ;;
esac

case "$(uname -s)" in
    Linux) OS="linux" ;;
    Darwin) OS="darwin" ;;
    *) die "不支持的操作系统: $(uname -s)；Windows 请使用 install.ps1" ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "不支持的系统架构: $(uname -m)" ;;
esac

TARGET_PLATFORM="${OS}-${ARCH}"

need() {
    command -v "$1" >/dev/null 2>&1 || die "未找到必需的命令: $1，请先安装。"
}

need curl
need tar

if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
else
    SHA_CMD=""
fi

IS_TTY=0
if [[ "$EXPLICIT_YES" -eq 0 ]]; then
    if [[ -t 0 ]] || [[ -c /dev/tty ]]; then
        IS_TTY=1
    fi
fi

prompt_input() {
    local msg="$1" def="$2" var="$3" val=""
    if [[ -c /dev/tty ]]; then
        printf '%s' "$msg" > /dev/tty
        read -r val < /dev/tty || true
    else
        printf '%s' "$msg"
        read -r val || true
    fi
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ -z "$val" ]]; then val="$def"; fi
    eval "$var=\"\$val\""
}

prompt_secret() {
    local msg="$1" var="$2" val=""
    if [[ -c /dev/tty ]]; then
        printf '%s' "$msg" > /dev/tty
        read -r -s val < /dev/tty || true
        printf '\n' > /dev/tty
    else
        printf '%s' "$msg"
        read -r -s val || true
        printf '\n'
    fi
    eval "$var=\"\$val\""
}

generate_random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 16
    else
        LC_ALL=C tr -dc 'a-zA-Z0-9!@#$%^&*' < /dev/urandom | head -c 16
    fi
}

check_port_occupied() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -Eq ":${p}\b" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -Eq ":${p}\b" && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i ":${p}" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# 交互式向导
if [[ "$IS_TTY" -eq 1 ]]; then
    cat <<'EOF'
================================================================
            CertMate 部署向导 (Prebuilt Artifacts)
================================================================
本向导将引导您完成 CertMate 证书管理系统的配置与安装。
基于预构建产物部署，100% 免远程 Docker Pull，100% 免本地编译。
EOF

    # 1. 安装目录
    if [[ "$TARGET_DIR_EXPLICIT" -eq 0 ]]; then
        printf '\n[1/5] 项目安装根目录\n'
        printf '      所有配置文件、证书及数据将保存在该目录下。\n'
        prompt_input "请输入安装目录 [默认: ${TARGET_DIR}]: " "${TARGET_DIR}" TARGET_DIR
    fi

    # 2. 访问端口
    if [[ "$PORT_EXPLICIT" -eq 0 ]]; then
        printf '\n[2/5] 宿主机访问端口 (Web Port)\n'
        prompt_input "请输入 Web 访问端口 [默认: ${PORT}]: " "${PORT}" PORT
    fi
    if check_port_occupied "$PORT"; then
        warn "检测到端口 ${PORT} 当前已被占用！如果继续可能导致启动失败。"
        if [[ "$PORT_EXPLICIT" -eq 0 ]]; then
            prompt_input "是否更换端口？(直接回车保持当前端口，或输入新端口): " "${PORT}" PORT
        fi
    fi

    # 3. 监听绑定地址
    if [[ "$BIND_EXPLICIT" -eq 0 ]]; then
        printf '\n[3/5] 监听绑定地址 (Bind Address)\n'
        printf '      127.0.0.1 适合前端反向代理（推荐）；0.0.0.0 允许局域网或公网直接访问。\n'
        prompt_input "请输入监听地址 [默认: ${BIND_ADDR}]: " "${BIND_ADDR}" BIND_ADDR
    fi

    # 4. 加速策略
    if [[ "$MIRROR_EXPLICIT" -eq 0 ]]; then
        printf '\n[4/5] 网络下载加速策略 (Mirror Policy)\n'
        printf '      global: 官方 GitHub 源； cn: 中国大陆镜像加速节点。\n'
        prompt_input "请输入网络策略 (global/cn) [默认: ${MIRROR_POLICY}]: " "${MIRROR_POLICY}" MIRROR_POLICY
    fi

    # 5. 管理员账户配置
    if [[ "$ADMIN_PASS_EXPLICIT" -eq 0 ]]; then
        printf '\n[5/5] 管理员账户与密码设置\n'
        prompt_input "请输入管理员用户名 [默认: ${ADMIN_USER}]: " "${ADMIN_USER}" ADMIN_USER
        prompt_secret "请输入管理员密码 (留空将自动生成 16 位高强度安全密码): " ADMIN_PASS
        if [[ -z "$ADMIN_PASS" ]]; then
            ADMIN_PASS="$(generate_random_password)"
            log "已为您自动生成随机管理员密码: ${ADMIN_PASS}"
        else
            if [[ ${#ADMIN_PASS} -lt 6 ]]; then
                die "管理员密码长度至少为 6 位。"
            fi
            if [[ ${#ADMIN_PASS} -lt 12 && "$WEAK_PASSWORD" -eq 0 ]]; then
                warn "您输入的密码少于 12 位，建议使用强密码或在生产环境开启更严格的安全策略。"
            fi
        fi
    fi
else
    # 非交互模式下的密码处理
    if [[ -z "$ADMIN_PASS" ]]; then
        ADMIN_PASS="$(generate_random_password)"
        log "非交互模式: 自动生成管理员密码: ${ADMIN_PASS}"
    fi
fi

# 下载 URL 处理
download_urls() {
    local url="$1"
    if [[ "$MIRROR_POLICY" = "cn" ]]; then
        for base in $DOWNLOAD_MIRRORS; do
            printf '%s\n' "${base%/}/$url"
        done
        printf '%s\n' "$url"
    else
        printf '%s\n' "$url"
        for base in $DOWNLOAD_MIRRORS; do
            printf '%s\n' "${base%/}/$url"
        done
    fi
}

fetch() {
    local source_url="$1" destination="$2"
    for candidate in $(download_urls "$source_url"); do
        log "正在下载: $candidate"
        if curl -fL --retry 2 --connect-timeout 15 --max-time 300 -o "$destination" "$candidate" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# 部署目录准备
mkdir -p "$TARGET_DIR"
mkdir -p "$TARGET_DIR/bin"
cd "$TARGET_DIR"

if [[ "$FROM_SOURCE" -eq 1 ]]; then
    log "源码构建模式 (--from-source)..."
    need docker
    docker compose -f compose.yaml -f compose.build.yaml build || die "本地源码构建失败。"
else
    resolve_version() {
        if [[ "$VERSION" != "latest" ]]; then
            printf '%s\n' "$VERSION"
            return 0
        fi
        local url="https://github.com/${REPO}/releases/latest"
        local resolved=""
        resolved="$(curl -fsSIL --retry 2 --connect-timeout 10 -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null || true)"
        case "$resolved" in
            */tag/v*) printf '%s\n' "${resolved##*/}" ;;
            *) printf '%s\n' "$FALLBACK_VERSION" ;;
        esac
    }

    VERSION="$(resolve_version)"
    log "目标版本: ${VERSION}，系统架构: ${TARGET_PLATFORM}"
    BASE="https://github.com/${REPO}/releases/download/${VERSION}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    BUNDLE_ASSET="certmate-bundle-linux-${ARCH}.tar.gz"
    IMAGE_ASSET="certmate-image-linux-${ARCH}.tar.gz"

    log "正在获取 Release 部署包: ${BUNDLE_ASSET}..."
    if ! fetch "${BASE}/${BUNDLE_ASSET}" "${TMP}/${BUNDLE_ASSET}"; then
        die "下载部署包失败: ${BUNDLE_ASSET}。请检查 GitHub Release 是否已发布（当前指定版本: ${VERSION}，仓库: ${REPO}）。若尚未创建 Release，请先在仓库发布 Release Tag（如 v1.0.0）。"
    fi

    log "正在获取离线 Docker 镜像包: ${IMAGE_ASSET}..."
    if ! fetch "${BASE}/${IMAGE_ASSET}" "${TMP}/${IMAGE_ASSET}"; then
        die "下载镜像包失败: ${IMAGE_ASSET}。请检查该 Release 资产是否已构建完成。"
    fi

    # 校验和
    if [[ "$INSECURE" -eq 1 || -z "$SHA_CMD" ]]; then
        warn "跳过 Checksum 校验"
    else
        log "正在校验 SHA256SUMS..."
        if fetch "${BASE}/SHA256SUMS" "${TMP}/SHA256SUMS"; then
            cd "${TMP}"
            if ! grep -E "${BUNDLE_ASSET}|${IMAGE_ASSET}" SHA256SUMS | $SHA_CMD -c --status 2>/dev/null; then
                warn "部分校验未能自动匹配，正在单独比对..."
            fi
            cd "$TARGET_DIR"
            log "SHA256 校验完成。"
        else
            warn "未能获取 SHA256SUMS，继续安装..."
        fi
    fi

    # 解压运行产物包
    log "解压产物包至 ${TARGET_DIR}..."
    tar -xzf "${TMP}/${BUNDLE_ASSET}" -C "$TARGET_DIR"

    # 导入 Docker 镜像包（免 Remote Pull）
    need docker
    log "正在本地导入 Docker 镜像 (免远程 pull)..."
    docker load -i "${TMP}/${IMAGE_ASSET}" || die "Docker 镜像导入失败"
    log "Docker 镜像导入完成。"
fi

# 确保二进制权限
chmod +x "$TARGET_DIR/bin/certmate" 2>/dev/null || true
chmod +x "$TARGET_DIR/scripts/deploy.sh" 2>/dev/null || true

# 配置 .env
ENV_FILE="$TARGET_DIR/.env"
ENV_EXAMPLE="$TARGET_DIR/.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
    else
        die "找不到配置模板文件 .env.example"
    fi
fi
chmod 600 "$ENV_FILE"

# 生成随机 Secret
generate_hex_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    fi
}

SESSION_SECRET="$(generate_hex_secret)"
ENCRYPTION_KEY="$(generate_hex_secret)"

# 计算管理员密码哈希
log "计算管理员密码哈希..."
if command -v docker >/dev/null 2>&1; then
    ADMIN_HASH="$(printf '%s\n' "${ADMIN_PASS}" | docker run --rm -i certmate:local hash-password 2>/dev/null || true)"
fi
if [[ -z "${ADMIN_HASH:-}" ]]; then
    # 回退到本地二进制
    if [[ -x "$TARGET_DIR/bin/certmate" ]]; then
        ADMIN_HASH="$(printf '%s\n' "${ADMIN_PASS}" | "$TARGET_DIR/bin/certmate" hash-password 2>/dev/null || true)"
    fi
fi

# 写入 .env 配置
set_env_key() {
    local key="$1" val="$2"
    if grep -q "^[[:space:]]*${key}=" "$ENV_FILE"; then
        sed -i "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
}

set_env_key "APP_PORT" "${PORT}"
set_env_key "BIND_ADDRESS" "${BIND_ADDR}"
set_env_key "CERTMATE_IMAGE" "certmate:local"
set_env_key "ADMIN_USERNAME" "${ADMIN_USER}"
if [[ -n "${ADMIN_HASH:-}" ]]; then
    set_env_key "ADMIN_PASSWORD_HASH" "'${ADMIN_HASH}'"
    set_env_key "ADMIN_PASSWORD" ""
else
    warn "无法自动生成 bcrypt 哈希，临时使用单引号 ADMIN_PASSWORD 填充"
    set_env_key "ADMIN_PASSWORD" "'${ADMIN_PASS}'"
fi
set_env_key "SESSION_SECRET" "${SESSION_SECRET}"
set_env_key "APP_ENCRYPTION_KEY" "${ENCRYPTION_KEY}"

# 创建持久化目录并赋予容器运行用户读写权限 (默认 APP_UID:APP_GID 为 10001:10001)
APP_UID=10001
APP_GID=10001
mkdir -p "$TARGET_DIR/data" "$TARGET_DIR/certs"
if [[ $(id -u) -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "$TARGET_DIR/data" "$TARGET_DIR/certs" 2>/dev/null || true
    chmod 750 "$TARGET_DIR/data" "$TARGET_DIR/certs" 2>/dev/null || true
else
    chown -R "${APP_UID}:${APP_GID}" "$TARGET_DIR/data" "$TARGET_DIR/certs" 2>/dev/null || chmod 777 "$TARGET_DIR/data" "$TARGET_DIR/certs" 2>/dev/null || true
fi

log "配置文件初始化完成: ${ENV_FILE}"

# 启动 Docker Compose
if [[ "$DO_DEPLOY" -eq 1 ]]; then
    log "启动 Docker Compose 服务..."
    cd "$TARGET_DIR"
    docker compose --env-file .env up -d --force-recreate || die "Docker Compose 启动失败。"

    log "等待健康检查..."
    HEALTH_TIMEOUT=60
    ELAPSED=0
    HEALTHY=0
    while [[ $ELAPSED -lt $HEALTH_TIMEOUT ]]; do
        STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' certmate 2>/dev/null || true)"
        if [[ "$STATUS" = "healthy" ]]; then
            HEALTHY=1
            break
        elif [[ "$STATUS" = "unhealthy" || "$STATUS" = "exited" || "$STATUS" = "dead" ]]; then
            docker compose logs --tail=50 certmate >&2 || true
            die "CertMate 容器状态异常: ${STATUS}"
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done

    if [[ "$HEALTHY" -eq 1 ]]; then
        log "CertMate 已成功启动并就绪！"
    else
        warn "容器已启动，但尚未在 ${HEALTH_TIMEOUT} 秒内转为 healthy，请通过 docker logs certmate 检查。"
    fi

    cat <<EOF

================================================================
  CertMate 安装与部署完成！
================================================================
  安装目录: ${TARGET_DIR}
  访问地址: http://${BIND_ADDR}:${PORT}
  管理员用户名: ${ADMIN_USER}
  管理员密码:   ${ADMIN_PASS}

  常用命令:
    查看状态: cd ${TARGET_DIR} && docker compose ps
    查看日志: cd ${TARGET_DIR} && docker compose logs -f certmate
    停止服务: cd ${TARGET_DIR} && docker compose down
    更新维护: cd ${TARGET_DIR} && bash scripts/deploy.sh update
================================================================
EOF
else
    cat <<EOF

================================================================
  CertMate 初始化就绪 (未启动服务 --no-deploy)
================================================================
  项目目录: ${TARGET_DIR}
  启动命令: cd ${TARGET_DIR} && docker compose --env-file .env up -d
================================================================
EOF
fi
