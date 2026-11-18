<#
.SYNOPSIS
  一键把 L4D2 专用服务器部署到阿里云 ECS（幂等，可反复执行）。

.DESCRIPTION
  默认从 GitHub raw 取 deploy.sh；-Local 则直接上传本机 server\deploy.sh，
  完全不依赖 GitHub（github.com 被墙时更稳）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\up.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\up.ps1 -Local
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ScriptUrl  = 'https://raw.githubusercontent.com/yanshui233/left4dead2-serve/main/server/deploy.sh',
    [switch]$Local
)

$ErrorActionPreference = 'Stop'

# 兜底解析脚本目录：某些调用方式下 $PSScriptRoot 在 param 默认值里为空
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.ps1' }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[x] 找不到配置文件: $ConfigPath" -ForegroundColor Red
    Write-Host "    先执行: Copy-Item .\config.example.ps1 .\config.ps1  然后填写 IP / 密码" -ForegroundColor Yellow
    exit 1
}
. $ConfigPath

$suser   = if ($Config.SshUser) { $Config.SshUser } else { 'root' }
$sshPort = if ($Config.SshPort) { $Config.SshPort } else { 22 }
$port    = if ($Config.Port)    { $Config.Port }    else { 27015 }
$target  = "$suser@$($Config.ServerIP)"

# ---- 远端 deploy.sh 的来源 ----
$localDeploy = Join-Path (Split-Path $here -Parent) 'server\deploy.sh'
if ($Local) {
    if (-not (Test-Path -LiteralPath $localDeploy)) {
        Write-Host "[x] 找不到本地脚本: $localDeploy" -ForegroundColor Red; exit 1
    }
    # 传上去之前强制转 LF，避免 Windows 编辑后带回 CRLF 把脚本跑炸
    $text = [IO.File]::ReadAllText($localDeploy, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $stage = Join-Path $env:TEMP 'l4d2-deploy.sh'
    [IO.File]::WriteAllText($stage, $text, (New-Object Text.UTF8Encoding($false)))
    Write-Host "[*] 使用本地脚本上传: $localDeploy" -ForegroundColor Cyan
}
else {
    $stage = $null
    Write-Host "[*] 从 GitHub 拉取: $ScriptUrl" -ForegroundColor Cyan
}

# ---- 环境变量参数 ----
$envs = "SERVER_NAME='$($Config.ServerName)' SRCDS_PORT=$port"
if ($Config.MaxPlayers) { $envs += " MAXPLAYERS=$($Config.MaxPlayers)" }
if ($Config.StartMap)   { $envs += " START_MAP=$($Config.StartMap)" }
if ($Config.Difficulty) { $envs += " DIFFICULTY='$($Config.Difficulty)'" }
if ($Config.SvPassword) { $envs += " SV_PASSWORD='$($Config.SvPassword)'" }
if ($Config.WorkshopCollection) { $envs += " WORKSHOP_COLLECTION=$($Config.WorkshopCollection)" }

if ($Local) { $remote = "$envs bash /root/l4d2-deploy.sh" }
else        { $remote = "set -e; curl -fsSL '$ScriptUrl' -o /root/l4d2-deploy.sh; $envs bash /root/l4d2-deploy.sh" }

Write-Host "[*] 目标: $target   游戏端口: $port" -ForegroundColor Cyan
Write-Host "[*] 首次部署要下载约 12 GB（10-20 分钟），窗口别关" -ForegroundColor Cyan

# ---- 上传本地脚本（仅 -Local）----
if ($Local) {
    if ($Config.KeyPath) {
        & scp -i $Config.KeyPath -P "$sshPort" -o StrictHostKeyChecking=accept-new $stage "${target}:/root/l4d2-deploy.sh"
    }
    elseif ($Config.Password) {
        if (-not (Get-Command pscp -ErrorAction SilentlyContinue)) {
            Write-Host "[x] -Local + 密码模式需要 pscp: winget install PuTTY.PuTTY" -ForegroundColor Red
            Write-Host "    或者改用 -i 密钥：" -ForegroundColor Yellow
            exit 1
        }
        & pscp -P "$sshPort" -pw $Config.Password $stage "${target}:/root/l4d2-deploy.sh"
    }
    else { Write-Host "[x] KeyPath / Password 都为空" -ForegroundColor Red; exit 1 }
    if ($LASTEXITCODE -ne 0) { Write-Host "[x] 上传失败（退出码 $LASTEXITCODE）" -ForegroundColor Red; exit 1 }
    Write-Host "[+] 上传完成" -ForegroundColor Green
}

# ---- 远端执行 ----
if ($Config.KeyPath) {
    if (-not (Test-Path -LiteralPath $Config.KeyPath)) {
        Write-Host "[x] 私钥不存在: $($Config.KeyPath)" -ForegroundColor Red; exit 1
    }
    Write-Host "[*] 认证: 密钥" -ForegroundColor Green
    & ssh -i $Config.KeyPath -p "$sshPort" `
        -o StrictHostKeyChecking=accept-new `
        -o ServerAliveInterval=30 -o ServerAliveCountMax=20 `
        $target $remote
}
elseif ($Config.Password) {
    if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
        Write-Host "[x] 密码免交互登录需要 plink: winget install PuTTY.PuTTY" -ForegroundColor Red
        Write-Host ""
        Write-Host "    手动两步也行:" -ForegroundColor Cyan
        Write-Host "      ssh $target" -ForegroundColor Gray
        Write-Host "      curl -fsSL $ScriptUrl -o /root/d.sh && $envs bash /root/d.sh" -ForegroundColor Gray
        exit 1
    }
    Write-Host "[*] 认证: 密码（plink，首次会问主机指纹，输 y）" -ForegroundColor Green
    & plink -ssh -P "$sshPort" -pw $Config.Password $target $remote
}
else { Write-Host "[x] KeyPath / Password 都为空" -ForegroundColor Red; exit 1 }

Write-Host ""
if ($LASTEXITCODE -eq 0) {
    Write-Host "[+] 部署完成。进游戏按 ~ 执行:" -ForegroundColor Green
    Write-Host "    connect $($Config.ServerIP):$port" -ForegroundColor White
    Write-Host "    连不上先查阿里云安全组是否放行 $port TCP+UDP" -ForegroundColor Yellow
} else {
    Write-Host "[x] 远端执行失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
}
