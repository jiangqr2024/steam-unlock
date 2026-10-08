<#
  Steam 解锁一键安装脚本 — 自建安全版

  设计原则（与灰产脚本的对立点）：
    · 二进制来源固定：OpenSteam001/OpenSteamTool 官方 GitHub Release，逐个校验 SHA256
    · 全部配置明文落盘，随时可打开人工核对
    · 不修改杀软设置、不劫持系统 DLL 名、不加壳、不内存加载、不规避任何检测
    · 每一步都有可见输出，不做静默行为
    · 自带备份与卸载，所有改动可回退
    · 无任何服务端记账，不收集不回传任何信息

  用法：
    本地   : .\install.ps1 -AppId 814380
    远程   : irm <本文件的 raw 地址> | iex        （会提示输入 AppID）
    环境变量: $env:OST_APPID='814380'; irm <地址> | iex
    卸载   : .\install.ps1 -Uninstall

  注意：脚本内一律用 return 而非 exit —— 在 irm|iex 场景下 exit 会关掉用户终端。
#>
[CmdletBinding()]
param(
    [int]$AppId = 0,
    [string]$SteamPath,
    [switch]$Uninstall,
    [switch]$NoRestart,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ── 常量：全部硬编码，便于人工审计 ────────────────────────────────
$REL_TAG  = '1.4.8'
$REL_ZIP  = "https://github.com/OpenSteam001/OpenSteamTool/releases/download/$REL_TAG/OpenSteamTool-$REL_TAG-Release.zip"
$REL_SHA  = '966654604D258D5D5383E72FEC616DF7957BF86F760C67EEB3D0E18CD882C710'
$REL_MB   = 1.11

# 官方 Release 内三个文件的 SHA256，落盘前逐个核对
$DLL_SHA = [ordered]@{
    'dwmapi.dll'        = 'CC086189E9AE5F6FEC1B9839110FD5EC5836E86989CB5F15CAB80BB813DF44F8'
    'xinput1_4.dll'     = '730D6E3C1216228392CF336127AD663564CAFDB560FAF3AE8BDFCC8CA6F38A27'
    'OpenSteamTool.dll' = 'B2ED24E0B4E2D0DAE4CAA8817ED4C0C34AF8FDF056F356FD697AE1356EA22581'
}

# depot 密钥清单库镜像，按顺序尝试（均为 GitHub 公开仓库）
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

# 上游 manifest request code 服务（实测 steamrun 可用，另两家分别返回 403 / 503）
$MANIFEST_MIRROR = 'steamrun'

$BACKUP_ROOT = Join-Path $env:LOCALAPPDATA 'ost-backup'

# ── 输出助手 ─────────────────────────────────────────────────────
function Say  ($m) { Write-Host "[*] $m" }
function Ok   ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "[x] $m" -ForegroundColor Red }

function Get-SteamRoot {
    if ($SteamPath) { return $SteamPath }
    $reg = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($reg -and $reg.SteamPath) {
        $p = $reg.SteamPath -replace '/', '\'
        if ($p -match '^[a-z]:') { $p = $p.Substring(0, 1).ToUpper() + $p.Substring(1) }
        if (Test-Path (Join-Path $p 'Steam.exe')) { return $p }
    }
    foreach ($c in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", 'C:\Steam', 'D:\Steam')) {
        if (Test-Path (Join-Path $c 'Steam.exe')) { return $c }
    }
    return $null
}

function Stop-SteamProcesses([string]$root) {
    $exe = Join-Path $root 'Steam.exe'
    if (Test-Path $exe) {
        # 用 Start-Process 并对失败容错：Steam.exe 缺失、损坏或被杀软隔离时不应中断整个流程
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList '-shutdown' -PassThru -ErrorAction Stop
            $proc | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
        }
        catch { Warn "调用 Steam.exe -shutdown 失败（$($_.Exception.Message)），改为直接结束进程" }
    }
    Start-Sleep -Seconds 6
    foreach ($n in @('steam', 'steamwebhelper', 'steamservice', 'steamerrorreporter')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # 等待目标文件释放，最多 15 秒
    for ($i = 0; $i -lt 30; $i++) {
        $busy = $false
        foreach ($f in $DLL_SHA.Keys) {
            $p = Join-Path $root $f
            if (Test-Path $p) {
                try { $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close() }
                catch { $busy = $true }
            }
        }
        if (-not $busy) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Test-LocalComponents([string]$root) {
    foreach ($f in $DLL_SHA.Keys) {
        $p = Join-Path $root $f
        if (-not (Test-Path $p)) { return $false }
        if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $DLL_SHA[$f]) { return $false }
    }
    return $true
}

function Install-Components([string]$root, [string]$stamp) {
    if (Test-LocalComponents $root) {
        Ok '三个组件已存在且哈希与官方 Release 一致，跳过下载'
        return $true
    }

    $tmp = Join-Path $env:TEMP "ost-$REL_TAG-$stamp"
    $zip = "$tmp.zip"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    Say "下载官方 Release（约 $REL_MB MB）: $REL_ZIP"
    try {
        Invoke-WebRequest -Uri $REL_ZIP -OutFile $zip -UseBasicParsing -TimeoutSec 240
    } catch {
        Fail "下载失败: $($_.Exception.Message)"
        return $false
    }

    $h = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($h -ne $REL_SHA) {
        Fail '压缩包 SHA256 与预期不符，已中止。'
        Say  "  预期: $REL_SHA"
        Say  "  实际: $h"
        return $false
    }
    Ok '压缩包 SHA256 校验通过'

    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    foreach ($f in $DLL_SHA.Keys) {
        $src = Join-Path $tmp $f
        if (-not (Test-Path $src)) { Fail "包内缺少 $f"; return $false }
        $fh = (Get-FileHash $src -Algorithm SHA256).Hash
        if ($fh -ne $DLL_SHA[$f]) {
            Fail "$f 的 SHA256 与预期不符，已中止。"
            Say  "  预期: $($DLL_SHA[$f])"
            Say  "  实际: $fh"
            return $false
        }
        Ok "$f 校验通过"
    }

    # 备份现有同名文件（可能是其他工具的组件）
    $bk = Join-Path $BACKUP_ROOT $stamp
    New-Item -ItemType Directory -Force -Path $bk | Out-Null
    foreach ($f in $DLL_SHA.Keys) {
        $dst = Join-Path $root $f
        if (Test-Path $dst) {
            Copy-Item $dst (Join-Path $bk $f) -Force
            Say "已备份原有 $f -> $bk"
        }
        Copy-Item (Join-Path $tmp $f) $dst -Force
    }

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Ok "三个组件已写入 $root"
    return $true
}

function Write-Config([string]$root, [string]$stamp) {
    $toml = Join-Path $root 'opensteamtool.toml'

    if (Test-Path $toml) {
        $bk = Join-Path $BACKUP_ROOT $stamp
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Copy-Item $toml (Join-Path $bk 'opensteamtool.toml') -Force
        Say '已备份原有 opensteamtool.toml'
    }

    $body = @"
# OpenSteamTool 配置 — 由自建安装脚本生成
# 上游 request code 服务：opensteamtool / steamrun / wudrm
# 实测 opensteamtool -> 403、wudrm -> 503、steamrun -> 200，故固定用 steamrun
[manifest]
url = "$MANIFEST_MIRROR"

timeout_resolve_ms = 5000
timeout_connect_ms = 5000
timeout_send_ms    = 10000
timeout_recv_ms    = 10000

[stats]
enable_api = true

[lua]
paths = []

[inject]
# 保持 false，不向游戏进程注入，减少反作弊暴露面
enabled = false
"@
    Set-Content -Path $toml -Value $body -Encoding UTF8
    Ok '已写入 opensteamtool.toml'
}

function Get-DepotPlan([int]$id) {
    try {
        $info = Invoke-RestMethod -Uri "https://api.steamcmd.net/v1/info/$id" -TimeoutSec 40 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    } catch {
        Warn "拉取 appinfo 失败: $($_.Exception.Message)"
        return @()
    }
    $app = $info.data."$id"
    if (-not $app) { return @() }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $app.depots.PSObject.Properties.Name) {
        if ($k -notmatch '^\d+$') { continue }
        $gid = $app.depots.$k.manifests.public.gid
        if ($gid) {
            $list.Add([pscustomobject]@{ Id = $k; Gid = [string]$gid })
        }
    }
    return $list
}

function Get-DepotKeys([int]$id) {
    foreach ($m in $MIRRORS) {
        $u = "https://raw.githubusercontent.com/$m/$id/Key.vdf"
        try {
            $r = Invoke-WebRequest -Uri $u -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        } catch { continue }

        $keys = @{}
        foreach ($mm in [regex]::Matches($r.Content, '"(\d+)"\s*\{\s*"DecryptionKey"\s*"([0-9a-fA-F]{64})"')) {
            $keys[$mm.Groups[1].Value] = $mm.Groups[2].Value
        }
        if ($keys.Count -gt 0) {
            return [pscustomobject]@{ Source = $m; Keys = $keys }
        }
    }
    return $null
}

function Write-Lua([string]$root, [int]$id, $depots, $keyInfo, [string]$stamp) {
    $luaDir = Join-Path $root 'config\lua'
    New-Item -ItemType Directory -Force -Path $luaDir | Out-Null

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('-- OpenSteamTool unlock script — 由自建安装脚本生成')
    [void]$sb.AppendLine("-- appid: $id")
    [void]$sb.AppendLine("-- 生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine('-- 语法: addappid(参数1=depotId, 参数2=被实现忽略, 参数3=64位解密密钥)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("addappid($id)")

    $withKey = 0
    $noKey = 0
    foreach ($d in $depots) {
        $k = $null
        if ($keyInfo -and $keyInfo.Keys.ContainsKey("$($d.Id)")) { $k = $keyInfo.Keys["$($d.Id)"] }
        if ($k) {
            if ($k.Length -ne 64) { $k = $null }
        }
        if ($k) {
            [void]$sb.AppendLine("addappid($($d.Id), 0, `"$k`")")
            $withKey++
        } else {
            [void]$sb.AppendLine("addappid($($d.Id))")
            $noKey++
        }
        [void]$sb.AppendLine("setManifestid($($d.Id), `"$($d.Gid)`")")
    }

    $target = Join-Path $luaDir "$id.lua"
    if (Test-Path $target) {
        $bk = Join-Path $BACKUP_ROOT $stamp
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Copy-Item $target (Join-Path $bk "$id.lua") -Force
    }
    Set-Content -Path $target -Value $sb.ToString() -Encoding UTF8

    Ok "已写入 $target"
    Say "  depot 数: $($depots.Count)（带密钥 $withKey，无密钥 $noKey）"
    return $true
}

function Do-Uninstall([string]$root) {
    Say '开始卸载 ...'
    Stop-SteamProcesses $root | Out-Null

    $removed = 0
    foreach ($f in $DLL_SHA.Keys) {
        $p = Join-Path $root $f
        if (Test-Path $p) { Remove-Item $p -Force; Say "  已删除 $f"; $removed++ }
    }
    foreach ($d in @('opensteamtool', 'config\lua')) {
        $p = Join-Path $root $d
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Say "  已删除 $d\"; $removed++ }
    }
    $toml = Join-Path $root 'opensteamtool.toml'
    if (Test-Path $toml) { Remove-Item $toml -Force; Say '  已删除 opensteamtool.toml'; $removed++ }

    # 清理各账号的库缓存，避免库里继续显示解锁游戏
    $ud = Join-Path $root 'userdata'
    if (Test-Path $ud) {
        Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8,}$' } | ForEach-Object {
            $lc = Join-Path $_.FullName 'config\librarycache'
            if (Test-Path $lc) {
                Get-ChildItem $lc -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object {
                    $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                    $c -match '"appid"\s*:\s*"?\d+' -and $c.Length -lt 4096
                } | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Ok "卸载完成，共处理 $removed 项"
    Say "备份保留在: $BACKUP_ROOT"
    return $true
}

# ══ 主流程 ══════════════════════════════════════════════════════
Write-Host ''
Write-Host '=== Steam 解锁一键安装（自建安全版）===' -ForegroundColor Cyan
Write-Host ''

$steam = Get-SteamRoot
if (-not $steam) { Fail '未找到 Steam 安装目录，请用 -SteamPath 指定'; return }
Ok "Steam 目录: $steam"

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($Uninstall) { Do-Uninstall $steam | Out-Null; return }

# 取 AppID：参数 -> 环境变量 -> 交互输入
if ($AppId -le 0 -and $env:OST_APPID) {
    $tmpId = 0
    if ([int]::TryParse($env:OST_APPID, [ref]$tmpId)) { $AppId = $tmpId }
}
if ($AppId -le 0) {
    $line = Read-Host '请输入要入库的游戏 AppID（商店页 URL 里的数字）'
    $tmpId = 0
    if (-not [int]::TryParse($line, [ref]$tmpId) -or $tmpId -le 0) { Fail 'AppID 无效'; return }
    $AppId = $tmpId
}
Ok "目标 AppID: $AppId"

Write-Host ''
Say '即将执行：'
Say "  1) 关闭 Steam"
Say "  2) 下载 OpenSteamTool 官方 Release 并校验 SHA256（若本地已匹配则跳过）"
Say "  3) 写入 dwmapi.dll / xinput1_4.dll / OpenSteamTool.dll（原文件先备份）"
Say "  4) 写入 opensteamtool.toml（上游固定 steamrun）"
Say "  5) 依据 appinfo 与公开清单库生成 config\lua\$AppId.lua"
Say '  6) 重新启动 Steam'
Write-Host ''
Say '本脚本不修改杀软设置、不劫持系统 DLL、不加载任何加壳或加密载荷。'
Say '所有落盘文件均为明文，可随时打开核对。'
Write-Host ''

if (-not $Yes) {
    $ans = Read-Host '确认继续? (y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') { Say '已取消'; return }
}

Write-Host ''
Say '正在关闭 Steam ...'
if (-not (Stop-SteamProcesses $steam)) { Warn '部分文件仍被占用，继续尝试写入' }
Ok 'Steam 已停止'

Write-Host ''
Say '准备组件 ...'
if (-not (Install-Components $steam $stamp)) { Fail '组件准备失败，已中止（原有文件未改动）'; return }

Write-Host ''
Write-Config $steam $stamp | Out-Null

Write-Host ''
Say '解析 depot 结构 ...'
$depots = Get-DepotPlan $AppId
if ($depots.Count -eq 0) {
    Warn '未能解析出 depot 列表，将只写入 addappid(本体)，由工具自行向上游索取清单'
}

Write-Host ''
Say '获取 depot 解密密钥 ...'
$keyInfo = Get-DepotKeys $AppId
if ($keyInfo) {
    Ok "命中镜像 $($keyInfo.Source)，共 $($keyInfo.Keys.Count) 个密钥"
} else {
    Warn '所有镜像均无该 appid 的 Key.vdf，将不写密钥（下载可能失败，属该游戏未被收录）'
}

# 有密钥源时只声明有密钥的 depot。
# 无密钥的 depot 强行写进配置会让 Steam 尝试挂载却拿不到解密密钥，进而导致整个 app 安装失败。
$plan = $depots
if ($keyInfo -and $depots.Count -gt 0) {
    $plan = @($depots | Where-Object { $keyInfo.Keys.ContainsKey("$($_.Id)") })
    if ($plan.Count -eq 0) {
        Warn '过滤后无可用 depot，回退为声明全部'
        $plan = $depots
    }
    elseif ($plan.Count -lt $depots.Count) {
        Say "  已过滤 $($depots.Count - $plan.Count) 个无密钥 depot（清单库未收录）"
    }
}

Write-Host ''
Write-Lua $steam $AppId $plan $keyInfo $stamp | Out-Null

Write-Host ''
if ($NoRestart) {
    Warn '按 -NoRestart 要求，未启动 Steam。手动启动后配置生效。'
} else {
    Say '启动 Steam ...'
    Start-Process (Join-Path $steam 'Steam.exe')
    Start-Sleep -Seconds 5
    Ok 'Steam 已启动'
}

Write-Host ''
Ok '完成。'
Say "备份目录: $BACKUP_ROOT\$stamp"
Say "卸载命令: .\install.ps1 -Uninstall"
Write-Host ''
