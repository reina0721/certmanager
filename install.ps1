# CertMate Windows PowerShell 安装向导
#
# 用法:
#   交互式安装:
#     irm https://raw.githubusercontent.com/reina0721/certmanager/main/install.ps1 | iex
#   国内加速:
#     irm https://ghfast.top/https://raw.githubusercontent.com/reina0721/certmanager/main/install.ps1 | iex
#
[CmdletBinding()]
param(
    [string]$Dir = "$HOME\certmate",
    [int]$Port = 8080,
    [string]$Bind = "127.0.0.1",
    [string]$Mirror = "global",
    [string]$Admin = "admin",
    [string]$Password = "",
    [string]$Version = "latest",
    [switch]$WeakPassword,
    [switch]$NoDeploy,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Repo = "reina0721/certmanager"
$FallbackVersion = "v1.0.0"
$DownloadMirrors = @("https://ghfast.top", "https://gh-proxy.com")

function Write-Log([string]$msg) { Write-Host "==> $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "警告: $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg) { Write-Host "错误: $msg" -ForegroundColor Red }

function Get-RandomPassword() {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    $result = ""
    foreach ($b in $bytes) {
        $result += $chars[$b % $chars.Length]
    }
    return $result
}

function Get-RandomHexSecret() {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { "{0:x2}" -f $_ })
}

# 交互式向导
if (-not $Yes -and [Environment]::UserInteractive) {
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "            CertMate 部署向导 (PowerShell)" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "基于预构建产物部署，免远程 Docker Pull，免本地环境编译。"

    $inputDir = Read-Host ("请输入安装目录 [默认: {0}]" -f $Dir)
    if ($inputDir) { $Dir = $inputDir }

    $inputPort = Read-Host ("请输入 Web 访问端口 [默认: {0}]" -f $Port)
    if ($inputPort) { $Port = [int]$inputPort }

    $inputBind = Read-Host ("请输入监听地址 [默认: {0}]" -f $Bind)
    if ($inputBind) { $Bind = $inputBind }

    $inputMirror = Read-Host ("请输入加速策略 (global/cn) [默认: {0}]" -f $Mirror)
    if ($inputMirror) { $Mirror = $inputMirror }

    $inputAdmin = Read-Host ("请输入管理员用户名 [默认: {0}]" -f $Admin)
    if ($inputAdmin) { $Admin = $inputAdmin }

    $inputPass = Read-Host "请输入管理员密码 (留空将自动生成 16 位强密码)"
    if ($inputPass) { $Password = $inputPass }
}

if (-not $Password) {
    $Password = Get-RandomPassword
    Write-Log ("已生成随机管理员密码: {0}" -f $Password)
}

# 目录创建
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Set-Location $Dir

# 解析版本
function Get-ReleaseTag() {
    if ($Version -ne "latest") { return $Version }
    try {
        $url = "https://api.github.com/repos/$Repo/releases/latest"
        $release = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'certmate-installer' } -TimeoutSec 10
        if ($release.tag_name) { return $release.tag_name }
    } catch {
        Write-Warn ("无法在线查询最新 Release，使用预设版本 {0}" -f $FallbackVersion)
    }
    return $FallbackVersion
}

$tag = Get-ReleaseTag
Write-Log ("目标版本: {0}" -f $tag)

function Download-Asset($url, $dest) {
    $candidates = @()
    if ($Mirror -eq "cn") {
        foreach ($m in $DownloadMirrors) {
            $candidates += ($m + "/" + $url)
        }
        $candidates += $url
    } else {
        $candidates += $url
        foreach ($m in $DownloadMirrors) {
            $candidates += ($m + "/" + $url)
        }
    }

    foreach ($c in $candidates) {
        try {
            Write-Log ("正在下载: {0}" -f $c)
            Invoke-WebRequest -Uri $c -OutFile $dest -TimeoutSec 300 -UseBasicParsing
            return
        } catch {
            Write-Warn ("下载失败: {0}，尝试下一个镜像..." -f $c)
        }
    }
    throw ("无法从任何可用镜像下载: {0}" -f $url)
}

$baseUrl = "https://github.com/$Repo/releases/download/$tag"
$bundleAsset = "certmate-bundle-linux-amd64.tar.gz"
$imageAsset = "certmate-image-linux-amd64.tar.gz"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("certmate-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $bundleDest = Join-Path $tempDir $bundleAsset
    $imageDest = Join-Path $tempDir $imageAsset

    Download-Asset "$baseUrl/$bundleAsset" $bundleDest
    Download-Asset "$baseUrl/$imageAsset" $imageDest

    Write-Log ("解压部署产物至 {0}..." -f $Dir)
    tar -xzf $bundleDest -C $Dir

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Log "本地导入 Docker 镜像 (免远程 pull)..."
        docker load -i $imageDest
    } else {
        Write-Warn "未检测到 docker 命令，跳过自动镜像导入。"
    }
} finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

# 配置 .env
$envFile = Join-Path $Dir ".env"
$exampleFile = Join-Path $Dir ".env.example"

if (-not (Test-Path $envFile)) {
    if (Test-Path $exampleFile) {
        Copy-Item $exampleFile $envFile
    } else {
        throw "未找到 .env.example 模板文件"
    }
}

$sessionSecret = Get-RandomHexSecret
$appKey = Get-RandomHexSecret

$adminHash = ""
if (Get-Command docker -ErrorAction SilentlyContinue) {
    try {
        $adminHash = ($Password | docker run --rm -i certmate:local hash-password)
    } catch {
        Write-Warn "无法通过 Docker 生成 bcrypt 哈希，将使用明文配置。"
    }
}

$content = Get-Content $envFile -Raw
function Set-EnvVal([string]$c, [string]$k, [string]$v) {
    if ($c -match "(?m)^[ \t]*$k=.*$") {
        return $c -replace "(?m)^[ \t]*$k=.*$", "$k=$v"
    }
    return ($c + [Environment]::NewLine + "$k=$v")
}

$content = Set-EnvVal $content "APP_PORT" $Port
$content = Set-EnvVal $content "BIND_ADDRESS" $Bind
$content = Set-EnvVal $content "CERTMATE_IMAGE" "certmate:local"
$content = Set-EnvVal $content "ADMIN_USERNAME" $Admin
if ($adminHash) {
    $content = Set-EnvVal $content "ADMIN_PASSWORD_HASH" "'$adminHash'"
    $content = Set-EnvVal $content "ADMIN_PASSWORD" ""
} else {
    $content = Set-EnvVal $content "ADMIN_PASSWORD" "'$Password'"
}
$content = Set-EnvVal $content "SESSION_SECRET" $sessionSecret
$content = Set-EnvVal $content "APP_ENCRYPTION_KEY" $appKey

Set-Content -Path $envFile -Value $content -Encoding UTF8

New-Item -ItemType Directory -Force -Path (Join-Path $Dir "data") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Dir "certs") | Out-Null

Write-Log "配置生成完毕。"

if (-not $NoDeploy) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Log "启动 Docker Compose 服务..."
        docker compose --env-file .env up -d --force-recreate
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "  CertMate 安装完成！" -ForegroundColor Cyan
        Write-Host ("  访问地址: http://{0}:{1}" -f $Bind, $Port)
        Write-Host ("  管理员账户: {0}" -f $Admin)
        Write-Host ("  管理员密码: {0}" -f $Password)
        Write-Host "================================================================" -ForegroundColor Cyan
    } else {
        Write-Warn "Docker 环境未就绪，请在启动 Docker Desktop / WSL2 后运行: docker compose --env-file .env up -d"
    }
}
