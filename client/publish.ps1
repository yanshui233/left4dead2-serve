<#
.SYNOPSIS
  用 GitHub REST API 把本仓库文件发布/更新到 GitHub。

.DESCRIPTION
  为什么需要它：国内直连 github.com:443 常被重置（git push 直接失败），
  但 api.github.com / raw.githubusercontent.com 通常还能用。
  本脚本只走 api.github.com，不碰 git 协议。

  所需权限：classic token 勾选 repo；fine-grained token 给 Contents: Read and write。
  （token 若没有任何 scope，会看到 404 —— 那是权限不足，不是路径错误）

.EXAMPLE
  $env:GITHUB_TOKEN = 'ghp_xxxx'
  powershell -ExecutionPolicy Bypass -File .\publish.ps1
#>
[CmdletBinding()]
param(
    [string]$Token  = $env:GITHUB_TOKEN,
    [string]$Repo   = 'yanshui233/left4dead2-serve',
    [string]$Branch = 'main',
    [string]$Root
)

$ErrorActionPreference = 'Stop'
# 兜底解析仓库根目录：某些调用方式下 $PSScriptRoot 在 param 默认值里为空
if (-not $Root) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $Root = Split-Path -Parent $here
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Token) {
    Write-Host "[x] 没有 token。用法: `$env:GITHUB_TOKEN='ghp_xxx'; .\publish.ps1" -ForegroundColor Red
    exit 1
}

$headers = @{
    Authorization = "token $Token"
    'User-Agent'  = 'l4d2-serve-publisher'
    Accept        = 'application/vnd.github+json'
}

# 待发布文件（不含 client/config.ps1 —— 那里有你的私有密码）
$files = @(
    '.gitattributes',
    '.gitignore',
    'README.md',
    'server/deploy.sh',
    'server/uninstall.sh',
    'client/up.ps1',
    'client/down.ps1',
    'client/publish.ps1',
    'client/config.example.ps1'
)

function Invoke-Gh {
    param($Method, $Uri, $Body)
    $p = @{ Uri = $Uri; Headers = $headers; Method = $Method; UseBasicParsing = $true }
    if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
    Invoke-WebRequest @p
}

$me = (Invoke-Gh GET 'https://api.github.com/user' $null).Content | ConvertFrom-Json
$info = Invoke-Gh GET "https://api.github.com/repos/$Repo" $null
$scopes = if ($info.Headers['X-OAuth-Scopes']) { $info.Headers['X-OAuth-Scopes'] } else { '' }
Write-Host "[*] 账号: $($me.login)   仓库: $Repo   分支: $Branch" -ForegroundColor Cyan
Write-Host "[*] token scopes: '$scopes'" -ForegroundColor Cyan
if (-not ($scopes -match 'repo')) {
    Write-Host "[!] token 看起来没有 repo 写权限，PUT 会返回 404。请重新生成 classic token 并勾选 repo。" -ForegroundColor Yellow
}

$fail = 0
foreach ($rel in $files) {
    $local = Join-Path $Root ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $local)) { Write-Host "[skip] $rel （本地不存在）" -ForegroundColor DarkGray; continue }

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($local))
    $uri = "https://api.github.com/repos/$Repo/contents/$rel"
    $body = @{ message = "chore: sync $rel"; content = $b64; branch = $Branch } | ConvertTo-Json -Compress
    try {
        Invoke-Gh PUT $uri $body | Out-Null
        Write-Host "[ok]   $rel" -ForegroundColor Green
    }
    catch {
        try {
            $cur = (Invoke-Gh GET $uri $null).Content | ConvertFrom-Json
            $body = @{ message = "chore: sync $rel"; content = $b64; sha = $cur.sha; branch = $Branch } | ConvertTo-Json -Compress
            Invoke-Gh PUT $uri $body | Out-Null
            Write-Host "[ok*]  $rel (更新)" -ForegroundColor Green
        }
        catch {
            $fail++
            Write-Host "[fail] $rel -> $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "[+] 全部发布成功: https://github.com/$Repo" -ForegroundColor Green
    Write-Host "    raw 直链（服务器 curl 用这个）:" -ForegroundColor Cyan
    Write-Host "    https://raw.githubusercontent.com/$Repo/$Branch/server/deploy.sh" -ForegroundColor Gray
} else {
    Write-Host "[x] $fail 个文件失败，看上面报错" -ForegroundColor Red
    exit 1
}
