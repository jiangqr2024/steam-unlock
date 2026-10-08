<#
  publish-game.ps1 — 为单个游戏生成专用的一键解锁命令

  流程：
    1) Steam 官方接口查游戏名
    2) 解析 appinfo 的 depot 结构与各 depot 体积
    3) 检查公开清单库的密钥覆盖，逐个诊断缺失项是否为关键内容
    4) 生成 g\<appid>.ps1（内嵌 AppID，用户无需输入任何东西）
    5) 上传到 GitHub 仓库
    6) 打印可直接分发的命令

  用法：
    .\publish-game.ps1 -AppId 814380
    .\publish-game.ps1 -AppId 814380 -NoUpload      # 只生成不传

  注意：g\<appid>.ps1 走 irm|iex，必须纯 ASCII 且无 BOM（本脚本已保证）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$AppId,
    [string]$Owner = 'jiangqr2024',
    [string]$Repo = 'steam-unlock',
    [string]$OutDir,
    [switch]$NoUpload
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$MIRRORS = @(
    'Auiowu/ManifestAutoUpdate',
    'tymolu233/ManifestAutoUpdate',
    'MineRPG/ManifestAutoUpdate',
    'bingyu50/ManifestAutoUpdate',
    'TOP-01/ManifestAutoUpdate',
    '1271620983/ManifestAutoUpdate',
    'hansaes/ManifestAutoUpdate',
    'luomojim/ManifestAutoUpdate',
    'crazzzzzysnail/ManifestAutoUpdate_fork'
)

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'g' }
$PAGES = "https://$Owner.github.io/$Repo"

function Say  ($m) { Write-Host "[*] $m" }
function Ok   ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

function Format-Size([int64]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return "$b B"
}

Write-Host ''
Write-Host "=== 发布 AppID $AppId ===" -ForegroundColor Cyan
Write-Host ''

# ── 1. 游戏信息 ───────────────────────────────────────────────
Say '查询商店信息 ...'
$appName = '(unknown)'
try {
    $j = Invoke-RestMethod -Uri "https://store.steampowered.com/api/appdetails?appids=$AppId&l=schinese" -TimeoutSec 30 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    $d = $j."$AppId"
    if ($d -and $d.success) { $appName = $d.data.name }
}
catch { Warn "商店接口失败: $($_.Exception.Message)" }
Ok "游戏名: $appName"

# ── 2. depot 结构 ─────────────────────────────────────────────
Say '解析 depot 结构 ...'
$depots = @()
try {
    $info = Invoke-RestMethod -Uri "https://api.steamcmd.net/v1/info/$AppId" -TimeoutSec 40 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    $app = $info.data."$AppId"
    foreach ($k in $app.depots.PSObject.Properties.Name) {
        if ($k -notmatch '^\d+$') { continue }
        $dd = $app.depots.$k
        $gid = $dd.manifests.public.gid
        if (-not $gid) { continue }
        $sz = 0
        try { $sz = [int64]$dd.manifests.public.size } catch { }
        $isDlc = $false
        if ($dd.dlcappid) { $isDlc = $true }
        $depots += [pscustomobject]@{ Id = $k; Gid = [string]$gid; Size = $sz; IsDlc = $isDlc }
    }
}
catch { Warn "appinfo 失败: $($_.Exception.Message)" }
Ok "带 public manifest 的 depot: $($depots.Count) 个"

# ── 3. 密钥覆盖 ───────────────────────────────────────────────
Say '检查清单库密钥覆盖 ...'
$keyInfo = $null
foreach ($m in $MIRRORS) {
    try {
        $r = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$m/$AppId/Key.vdf" -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        $keys = @{}
        foreach ($mm in [regex]::Matches($r.Content, '"(\d+)"\s*\{\s*"DecryptionKey"\s*"([0-9a-fA-F]{64})"')) {
            $keys[$mm.Groups[1].Value] = $mm.Groups[2].Value
        }
        if ($keys.Count -gt 0) {
            $keyInfo = [pscustomobject]@{ Source = $m; Keys = $keys }
            break
        }
    }
    catch { }
}

# ── 4. 覆盖率诊断 ─────────────────────────────────────────────
$have = @()
$miss = @()
if ($keyInfo) {
    foreach ($x in $depots) {
        if ($keyInfo.Keys.ContainsKey($x.Id)) { $have += $x } else { $miss += $x }
    }
}

Write-Host ''
Write-Host '--- 覆盖率诊断 ---' -ForegroundColor Cyan

if (-not $keyInfo) {
    Warn '所有镜像都没有该 AppID 的 Key.vdf'
    Warn '脚本将只声明本体 addappid(appid)，能否下载取决于工具上游是否收录该游戏'
    $verdict = '清单库未收录'
}
else {
    Ok "密钥来源: $($keyInfo.Source)"
    '   appinfo depot : ' + $depots.Count
    '   有密钥        : ' + $have.Count
    '   缺密钥        : ' + $miss.Count

    # 先列出有密钥的（按体积降序），这是判断本体是否完整的关键依据
    if ($have.Count -gt 0) {
        Write-Host ''
        Ok '有密钥的 depot（按体积降序）:'
        foreach ($x in ($have | Sort-Object Size -Descending)) {
            '     depot {0,-10} {1,-12}' -f $x.Id, (Format-Size $x.Size)
        }
    }

    if ($miss.Count -eq 0) {
        Write-Host ''
        Ok '覆盖率 100%，可完整下载'
        $verdict = '完整'
    }
    else {
        Write-Host ''
        Warn '缺密钥的 depot:'
        $critical = 0
        foreach ($x in ($miss | Sort-Object Size -Descending)) {
            $tag = ''
            if ($x.IsDlc) { $tag = 'DLC / 附加内容，本体通常不需要' }
            elseif ($x.Size -lt 1MB) { $tag = '空占位（<1MB），可忽略' }
            else { $tag = '内容 depot'; $critical++ }
            '     depot {0,-10} {1,-12} {2}' -f $x.Id, (Format-Size $x.Size), $tag
        }
        Write-Host ''

        # 核心判据：最大的那个 depot 有没有密钥。本体主内容通常在最大的 depot 里。
        $bigHave = $have | Sort-Object Size -Descending | Select-Object -First 1
        $bigMiss = $miss | Sort-Object Size -Descending | Select-Object -First 1
        $haveTotal = ($have | Measure-Object -Property Size -Sum).Sum
        $missTotal = ($miss | Measure-Object -Property Size -Sum).Sum

        '   有密钥合计: ' + (Format-Size $haveTotal) + '    缺密钥合计: ' + (Format-Size $missTotal)
        Write-Host ''

        if ($bigMiss -and (-not $bigHave -or $bigMiss.Size -gt $bigHave.Size)) {
            Warn "最大的 depot ($($bigMiss.Id), $(Format-Size $bigMiss.Size)) 缺密钥"
            Warn '本体主内容很可能在其中，该游戏下载风险高'
            $verdict = '主内容缺密钥'
        }
        elseif ($critical -gt 0) {
            Ok "主内容有密钥：最大 depot $($bigHave.Id) = $(Format-Size $bigHave.Size)"
            Warn "另有 $critical 个较小的内容 depot 缺密钥，可能缺少部分资源"
            $verdict = '主内容可用，次要内容缺失'
        }
        else {
            Ok "主内容有密钥：最大 depot $($bigHave.Id) = $(Format-Size $bigHave.Size)"
            Ok '缺失项均为空占位或附加内容，不影响本体下载'
            $verdict = '缺失项不影响'
        }
    }
}

# ── 5. 生成 g\<appid>.ps1（纯 ASCII 无 BOM）──────────────────
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$launcher = @"
# Steam unlock launcher  (AppID $AppId)
# Generated by publish-game.ps1
#
# This runs the auditable installer hosted in the public repo below.
# To read the installer before running it:
#   `$u='$PAGES/install.ps1'; `$f="`$env:TEMP\ost-install.ps1"
#   irm `$u -OutFile `$f; notepad `$f
#
`$env:OST_APPID = '$AppId'
`$env:OST_YES   = '1'
iex (Invoke-RestMethod '$PAGES/bootstrap.ps1')
"@
$lp = Join-Path $OutDir "$AppId.ps1"
[System.IO.File]::WriteAllText($lp, $launcher, (New-Object System.Text.UTF8Encoding($false)))
$lb = [System.IO.File]::ReadAllBytes($lp)
$nonAscii = 0
foreach ($x in $lb) { if ($x -gt 127) { $nonAscii++ } }
Ok "已生成 $lp  ($($lb.Length) 字节, 非ASCII=$nonAscii, BOM=False)"

# ── 6. 上传 ───────────────────────────────────────────────────
if ($NoUpload) {
    Warn '按 -NoUpload 跳过上传'
}
else {
    $cred = "protocol=https`nhost=github.com`n`n" | & git credential fill 2>$null
    $token = ($cred | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
    if (-not $token) {
        Warn '未取到 GitHub 凭据，跳过上传（文件已生成在本地）'
    }
    else {
        $H = @{ Authorization = "token $token"; 'User-Agent' = 'ost-publish' }
        $API = "https://api.github.com/repos/$Owner/$Repo"
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lp))

        $sha = $null
        try {
            $cur = Invoke-RestMethod -Uri "$API/contents/g/$AppId.ps1" -Headers $H -TimeoutSec 30
            $sha = $cur.sha
        }
        catch { }

        $body = @{ message = "Publish launcher for AppID $AppId"; content = $b64 }
        if ($sha) { $body.sha = $sha }

        try {
            $null = Invoke-RestMethod -Uri "$API/contents/g/$AppId.ps1" -Method Put -Headers $H `
                -Body ($body | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 90
            Ok "已上传 g/$AppId.ps1"
        }
        catch { Warn "上传失败: $($_.Exception.Message)" }
    }
}

# ── 7. 结果 ───────────────────────────────────────────────────
Write-Host ''
Write-Host '=== 分发命令 ===' -ForegroundColor Cyan
Write-Host ''
Write-Host "irm $PAGES/g/$AppId.ps1 | iex" -ForegroundColor White
Write-Host ''
'   游戏   : ' + $appName
'   诊断   : ' + $verdict
'   命令长 : ' + ("irm $PAGES/g/$AppId.ps1 | iex").Length + ' 字符'
Write-Host ''
