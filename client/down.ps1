<#
.SYNOPSIS
  停止 ECS 上的 L4D2 服务；可选 -Purge 彻底卸载文件。
  真正"不花钱"的最后一步是：在阿里云控制台【释放实例】。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\down.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\down.ps1 -Purge
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Purge,
    [string]$UninstallUrl = 'https://raw.githubusercontent.com/yanshui233/left4dead2-serve/main/server/uninstall.sh'
)

$ErrorActionPreference = 'Stop'
# 兜底解析脚本目录：某些调用方式下 $PSScriptRoot 在 param 默认值里为空
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.ps1' }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[x] 找不到 $ConfigPath" -ForegroundColor Red; exit 1
}
. $ConfigPath

$suser   = if ($Config.SshUser) { $Config.SshUser } else { 'root' }
$sshPort = if ($Config.SshPort) { $Config.SshPort } else { 22 }
$target  = "$suser@$($Config.ServerIP)"

if ($Purge) {
    Write-Host "[!] Purge 模式：将删除服务端文件、SteamCMD、运行用户" -ForegroundColor Yellow
    $remote = "set -e; curl -fsSL '$UninstallUrl' -o /root/u.sh; bash /root/u.sh"
} else {
    $remote = "systemctl stop l4d2ds 2>/dev/null; systemctl is-active l4d2ds || echo 'l4d2ds 已停止'; df -h / | tail -n1"
}

if ($Config.KeyPath) {
    & ssh -i $Config.KeyPath -p "$sshPort" -o StrictHostKeyChecking=accept-new `
        -o ServerAliveInterval=30 $target $remote
}
elseif ($Config.Password) {
    if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
        Write-Host "[x] 需要 plink 或密钥。手动执行:" -ForegroundColor Red
        Write-Host "    ssh $target  然后 systemctl stop l4d2ds" -ForegroundColor Gray
        exit 1
    }
    & plink -ssh -P "$sshPort" -pw $Config.Password $target $remote
}
else {
    Write-Host "[x] KeyPath / Password 都为空" -ForegroundColor Red; exit 1
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " 下一步（否则会继续扣费）:" -ForegroundColor Yellow
Write-Host "   1. 阿里云控制台 → 实例 → 停止实例" -ForegroundColor White
Write-Host "   2. 实例 → 更多 → 实例状态 → 释放实例（选"立即释放"）" -ForegroundColor White
Write-Host "   3. 若用了独立弹性公网 IP(EIP)，到 EIP 页面一并释放" -ForegroundColor White
Write-Host "   4. 快照/自定义镜像不释放，会按 GB·月 持续计费，确认是否保留" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Cyan
