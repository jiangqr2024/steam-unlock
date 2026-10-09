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
    [switch]$Yes,
    [switch]$DryRun
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

# depot 密钥清单库镜像。
# 只收录密钥为明文标准格式（恰好 64 个十六进制字符）的仓库。标为 "Encrypted"
# 的仓库（sean-who / Fairyvmos/BlankTMing）其 Key.vdf 内是 128/192 字符的哈希或
# 加密格式，而 lua_addappid 有硬编码校验 "if (strlen(key) == 64)"（见
# src/Utils/Config/LuaConfig.cpp），不满足者被静默丢弃。
#
# Fairyvmos/bruh-hub 是当前最优来源：40461 个 AppID 分支，抽样密钥全部有效，
# 且额外提供 .lua / .json / .manifest。其文件名是【小写】key.vdf，与其余仓库的
# 【大写】Key.vdf 不同，下面会同时尝试两种拼法（以及 config.vdf）。
$MIRRORS = @(
    'Fairyvmos/bruh-hub',
    'nekoaday/ManifestAutoUpdate',
    'TOP-01/ManifestAutoUpdate',
    'Auiowu/ManifestAutoUpdate',
    'tymolu233/ManifestAutoUpdate',
    'hansaes/ManifestAutoUpdate',
    '1271620983/ManifestAutoUpdate',
    'MineRPG/ManifestAutoUpdate',
    'bingyu50/ManifestAutoUpdate',
    'ManifestHub/ManifestHub',
    'Scropiouos/ManifestAutoUpdate_backup',
    'luomojim/ManifestAutoUpdate',
    'crazzzzzysnail/ManifestAutoUpdate_fork'
)

# 上游 manifest request code 服务（实测 steamrun 可用，另两家分别返回 403 / 503）
$MANIFEST_MIRROR = 'steamrun'

$BACKUP_ROOT = Join-Path $env:LOCALAPPDATA 'ost-backup'

# 实测过的真实体积。单位 GB。
# 为什么需要它：appinfo 的 depot 体积求和与真实下载量无关——Steam 会按语言/
# 平台筛选，例如博德之门 3 的 53 个 depot 合计 449.4 GB，实际只需 145.75 GB。
# 拿求和值去比对剩余空间只会制造假警报，所以已实测的游戏用真实值，未知的用宽松阈值。
$KNOWN_SIZE = @{
    1086940 = 145.75   # 博德之门 3 + 2 DLC
    1245620 = 69.2     # 艾尔登法环 + 黄金树幽影
    2050650 = 62.81    # 生化危机 4
    292030  = 54.72    # 巫师 3
    524220  = 40.34    # 尼尔：机械纪元
    814380  = 13.87    # 只狼
}

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
    # 进程退出用轮询而不是固定 6 秒：多数机器 2 秒内就退干净了，
    # 固定等待只是白白拖慢每次"一条命令"的体感。
    for ($w = 0; $w -lt 20; $w++) {
        if (-not (Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
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

# 预检失败时的统一询问出口。
# 注意：-DryRun 不询问，直接继续（它不会改动任何东西）。
function Ask-Continue([string]$reason) {
    if ($Yes -or $DryRun) { Warn "继续（未确认）: $reason"; return $true }
    $ans = Read-Host "仍要继续? (y/N)"
    return ($ans -eq 'y' -or $ans -eq 'Y')
}

# 估算游戏体积，并推断 Steam 会把它装到哪一块盘，再比对剩余空间。
# 这一步存在的理由很直接：本机 D: 只剩 60 余 GB 时，145 GB 的博德之门 3
# 连下载都进不去，脚本却会一路宣告"完成"。
function Get-DiskPrecheck([string]$root, [int64]$needBytes) {
    if ($needBytes -le 0) { return $null }
    $lv = Join-Path $root 'steamapps\libraryfolders.vdf'
    $cands = New-Object System.Collections.Generic.List[object]
    if (Test-Path $lv) {
        try {
            $txt = Get-Content $lv -Raw
            foreach ($mm in [regex]::Matches($txt, '"path"\s*"([^"]+)"')) {
                $p = $mm.Groups[1].Value -replace '\\\\', '\'
                $d = $p
                if ($d -match '^([A-Za-z]):') { $d = $Matches[1] + ':' }
                if ($d -match '^[A-Za-z]:$') { $cands.Add([pscustomobject]@{ Root = $p; Drive = $d }) }
            }
        } catch { }
    }
    if ($cands.Count -eq 0) {
        $d = (Split-Path $root -Qualifier)
        $cands.Add([pscustomobject]@{ Root = $root; Drive = $d })
    }
    $head = $cands[0]
    $free = $null
    try { $free = (Get-PSDrive -Name $head.Drive.TrimEnd(':') -ErrorAction Stop).Free } catch { }
    if ($null -eq $free) { return $null }
    return [pscustomobject]@{
        Need      = $needBytes
        Free      = [int64]$free
        Drive     = $head.Drive
        Roots     = @($cands | ForEach-Object { $_.Root })
        Ok        = ($free -ge ($needBytes * 1.15))
        AnyRootOk = (@($cands | Where-Object {
                        try { (Get-PSDrive -Name $_.Drive.TrimEnd(':') -ErrorAction Stop).Free -ge ($needBytes * 1.15) } catch { $false }
                    }).Count -gt 0)
    }
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
    if ($DryRun) {
        Say "[DryRun] 跳过组件下载与写入（目标 $root）"
        return $true
    }
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
        try {
            Copy-Item (Join-Path $tmp $f) $dst -Force -ErrorAction Stop
        } catch {
            Fail "写入 $f 失败：$($_.Exception.Message)"
            if (-not (Ask-Continue "组件未写入，配置将生成但不会生效")) { return $false }
            return $true
        }
        # 写入后复校：杀软隔离、磁盘写入错误都会在这里暴露，而不是等到启动 Steam 才失败
        if ((Get-FileHash $dst -Algorithm SHA256).Hash -ne $DLL_SHA[$f]) {
            Warn "$f 写入后哈希不符（可能被安全软件拦截或篡改）"
            if (-not (Ask-Continue '该组件哈希校验失败')) { return $false }
        }
    }

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Ok "三个组件已写入 $root"
    return $true
}

function Write-Config([string]$root, [string]$stamp) {
    $toml = Join-Path $root 'opensteamtool.toml'

    if ($DryRun) {
        Say "[DryRun] 不写、不备份 opensteamtool.toml（目标 $toml）"
        return $true
    }

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
    # 同样必须无 BOM：BOM 不是合法 TOML 起始字符
    [System.IO.File]::WriteAllText($toml, $body, (New-Object System.Text.UTF8Encoding($false)))
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
        $dd = $app.depots.$k
        $gid = $dd.manifests.public.gid
        if (-not $gid) { continue }
        $sz = 0
        try { $sz = [int64]$dd.manifests.public.size } catch { }
        # appinfo 的 size 是 manifest 记录的大小，通常等于内容体积，
        # 但压缩/分片过的 depot 可能偏小，所以它只作参考值。
        $list.Add([pscustomobject]@{ Id = $k; Gid = [string]$gid; Size = $sz })
    }
    return $list
}

function Get-DepotKeys([int]$id, $needDepots) {
    # 遍历多个镜像取并集：各仓库收录的 depot 并不一致，单个仓库常缺关键密钥。
    # 一旦 appinfo 里列出的 depot 全部有密钥就提前停止，避免无谓请求。
    $all = @{}
    $srcs = New-Object System.Collections.Generic.List[string]
    foreach ($m in $MIRRORS) {
        # 各仓库文件名大小写不一致（bruh-hub 用小写 key.vdf），逐个尝试
        $resp = $null
        foreach ($fn in @('key.vdf', 'Key.vdf', 'config.vdf')) {
            try {
                $resp = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$m/$id/$fn" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                break
            } catch { }
        }
        if ($null -eq $resp) { continue }

        try {
            $added = 0
            $skipped = 0
            # 正则放宽到任意长度再按长度过滤：哈希格式的仓库必须被识别并报告，而不是静默丢弃
            foreach ($mm in [regex]::Matches($resp.Content, '"(\d+)"\s*\{\s*"DecryptionKey"\s*"([0-9a-fA-F]+)"')) {
                $k = $mm.Groups[1].Value
                $v = $mm.Groups[2].Value
                if ($v.Length -ne 64) { $skipped++; continue }
                if (-not $all.ContainsKey($k)) {
                    $all[$k] = $v
                    $added++
                }
            }
            if ($added -gt 0) { [void]$srcs.Add("$m (+$added)") }
            elseif ($skipped -gt 0) { [void]$srcs.Add("$m (哈希格式 $skipped 个，已跳过)") }

            if ($needDepots -and @($needDepots).Count -gt 0) {
                $missing = @($needDepots | Where-Object { -not $all.ContainsKey([string]$_.Id) })
                if ($missing.Count -eq 0) { break }
            }
        } catch { }
    }
    # 兜底：SteamAutoCracks/ManifestHub 的 depotkeys.json 是 depotId -> key 的
    # 全局映射表（实测 288381 条），覆盖面远超任何单仓库。代价是 16 MB，
    # 所以只在前面所有镜像仍未能凑齐时下载一次。
    if ($needDepots -and @($needDepots).Count -gt 0) {
        $stillMissing = @($needDepots | Where-Object { -not $all.ContainsKey([string]$_.Id) })
        if ($stillMissing.Count -gt 0) {
            Write-Host ("[*]   仍有 {0} 个 depot 缺密钥，尝试全局密钥表 ..." -f $stillMissing.Count)
            try {
                $globalUrl = 'https://raw.githubusercontent.com/SteamAutoCracks/ManifestHub/main/depotkeys.json'
                # 缓存路径不能建立在 $PSScriptRoot 上：install.ps1 在 irm|iex 场景里没有
                # 脚本文件上下文，这个变量是空的。整个 try 块又没有 catch，异常会沿着
                # 外层 catch 被吞掉 —— 结果就是"看起来有缓存，实际永远不命中"。
                $cacheDir = Join-Path $env:LOCALAPPDATA 'ost-cache'
                $cache = Join-Path $cacheDir 'depotkeys.json'
                $gj = $null
                if ((Test-Path $cache) -and (((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -lt 7)) {
                    try {
                        $gj = Get-Content $cache -Raw | ConvertFrom-Json
                        Say '    使用本地缓存的全局密钥表（7 天内有效）'
                    } catch { $gj = $null; Warn '    本地缓存损坏，改为重新下载' }
                }
                if (-not $gj) {
                    # 先落原始文件再解析：避免 PS 的 ConvertTo-Json/ConvertFrom-Json
                    # 往返在这张 28 万条目的表上引入任何差异。
                    $rawTmp = Join-Path $env:TEMP ('ost-depotkeys-' + (Get-Random) + '.json')
                    Invoke-WebRequest -Uri $globalUrl -OutFile $rawTmp -UseBasicParsing -TimeoutSec 180
                    try {
                        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
                        Copy-Item $rawTmp $cache -Force
                        Say "    已缓存全局密钥表 -> $cache"
                    } catch { Warn "    缓存写入失败（不影响本次运行）: $($_.Exception.Message)" }
                    $gj = Get-Content $rawTmp -Raw | ConvertFrom-Json
                    Remove-Item $rawTmp -Force -ErrorAction SilentlyContinue
                }
                $gained = 0
                foreach ($d in $stillMissing) {
                    $prop = $gj.PSObject.Properties | Where-Object { $_.Name -eq [string]$d.Id }
                    if ($prop) {
                        $v = [string]$prop.Value
                        # 全局表里有空值条目，必须校验格式
                        if ($v -match '^[0-9a-fA-F]{64}$') {
                            $all[[string]$d.Id] = $v.ToLower()
                            $gained++
                        }
                    }
                }
                if ($gained -gt 0) { [void]$srcs.Add("SteamAutoCracks/ManifestHub/depotkeys.json (+$gained)") }
            } catch { }
        }
    }

    if ($all.Count -eq 0) { return $null }
    return [pscustomobject]@{ Keys = $all; Sources = $srcs }
}

function Write-Lua([string]$root, [int]$id, $depots, $keyInfo, [string]$stamp, $extraApps) {
    $luaDir = Join-Path $root 'config\lua'
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $luaDir | Out-Null }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('-- OpenSteamTool unlock script — 由自建安装脚本生成')
    [void]$sb.AppendLine("-- appid: $id")
    [void]$sb.AppendLine("-- 生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine('-- 语法: addappid(参数1=depotId, 参数2=被实现忽略, 参数3=64位解密密钥)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- 本体')
    [void]$sb.AppendLine("addappid($id)")

    # DLC 的 appid 必须显式声明。否则 Steam 不认为你拥有该 DLC——
    # 即使其 depot 密钥已在下方列出，对应内容也不会被下载。
    if ($extraApps -and @($extraApps).Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("-- DLC（共 $(@($extraApps).Count) 个）")
        foreach ($ea in $extraApps) {
            [void]$sb.AppendLine("addappid($ea)")
        }
    }

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
    if ($DryRun) {
        Say "[DryRun] 不写盘。将生成的内容如下："
        Write-Host '---------- lua 预览 ----------'
        Write-Host $sb.ToString()
        Write-Host '------------------------------'
        Say "  depot 数: $($depots.Count)（带密钥 $withKey，无密钥 $noKey）"
        Say '  预览结束（未落盘）。去掉 -DryRun 即为真正写入。'
        return $true
    }
    if (Test-Path $target) {
        $bk = Join-Path $BACKUP_ROOT $stamp
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Copy-Item $target (Join-Path $bk "$id.lua") -Force
    }
    # 必须无 BOM 写入：Lua 解析器不识别 BOM，带 BOM 会让首行变成
    # "\uFEFFaddappid(...)" 从而导致整个脚本解析失败。
    # 注意 PS 5.1 的 Set-Content -Encoding UTF8 会写入 BOM，不能用于此处。
    [System.IO.File]::WriteAllText($target, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

    Ok "已写入 $target"
    Say "  depot 数: $($depots.Count)（带密钥 $withKey，无密钥 $noKey）"
    return $true
}

# 卸载时要处理的组件。优先还原"上一个工具留下的同名文件"，
# 没有可还原的备份时直接删除——删掉之后 Steam 会回落到 system32 的系统库。
# 顺序很重要：先备份 -> 再删除，避免把代理 DLL 当成原件拷来拷去。
function Restore-SteamComponents([string]$root, [string]$stamp, [switch]$Yes) {
    $bkRoot = Join-Path $BACKUP_ROOT $stamp
    foreach ($f in $DLL_SHA.Keys) {
        $dst = Join-Path $root $f
        if (-not (Test-Path $dst)) { continue }

        $cur = (Get-FileHash $dst -Algorithm SHA256).Hash
        if ($cur -ne $DLL_SHA[$f]) {
            Say "  $f 当前内容不是本项目的组件（哈希不符），保持原样不删除"
            continue
        }

        # 找最近一次备份里这个文件
        $cand = $null
        if (Test-Path $bkRoot) {
            $p = Join-Path $bkRoot $f
            if (Test-Path $p) { $cand = $p }
        }
        if (-not $cand) {
            # 同样的原因：iex 场景下 $PSScriptRoot 为空，只能用固定候选路径。
            # 这里找不到也不会出错，只是少一个还原来源。
            foreach ($base in @('D:\steam-unlock-cli')) {
                $p = Join-Path $base "backup\original-steam-dlls\$f"
                if (Test-Path $p) { $cand = $p; break }
            }
        }
        if (-not $cand) {
            $dirs = @(Get-ChildItem $BACKUP_ROOT -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            foreach ($d in $dirs) {
                $p = Join-Path $d.FullName $f
                if (Test-Path $p) { $cand = $p; break }
            }
        }

        if ($cand) {
            $bh = (Get-FileHash $cand -Algorithm SHA256).Hash
            if ($bh -eq $DLL_SHA[$f]) {
                Warn "备份里的 $f 仍是本项目的组件（哈希相同），不可还原，将直接删除"
                $cand = $null
            }
        }

        if ($cand) {
            try {
                Copy-Item $cand $dst -Force -ErrorAction Stop
                if ((Get-FileHash $dst -Algorithm SHA256).Hash -eq (Get-FileHash $cand -Algorithm SHA256).Hash) {
                    Ok "  已还原原有 $f  <- $cand"
                } else {
                    Warn "  还原 $f 后哈希不符，请手工核对 $dst"
                }
            } catch {
                Warn "  还原 $f 失败：$($_.Exception.Message)"
            }
        } else {
            # 删除时要考虑 KnownDLLs：dwmapi.dll 属于 KnownDLLs，
            # 覆盖成同名文件通常可行，但删除动作本身可能被系统拒绝（通常表现为"文件正在使用"）。
            try {
                # 认不出来的同名文件先归档再删：删除动作通常是安全的（Steam 会回落到
                # system32 的系统库），但"备份"是这里唯一不可逆的一步，所以先落盘。
                $keep = Join-Path $BACKUP_ROOT "removed-$stamp"
                New-Item -ItemType Directory -Force -Path $keep | Out-Null
                Copy-Item $dst (Join-Path $keep $f) -Force -ErrorAction SilentlyContinue
                Remove-Item $dst -Force -ErrorAction Stop
                Say "  已删除 $f（原件已归档到 $keep；Steam 将回落到 system32 的系统库）"
            } catch {
                Warn "  删除 $f 失败：$($_.Exception.Message)"
                Warn "  请手动删除，或重启后重试：$dst"
            }
        }
    }
}

function Do-Uninstall([string]$root) {
    Say '开始卸载 ...'
    if ($DryRun) {
        Warn '[DryRun] 仅列出将删除的内容，不做任何改动'
    }
    if (-not $DryRun) { Stop-SteamProcesses $root | Out-Null }

    # 取最近一次安装留下的备份目录，作为组件还原的优先来源
    $latest = ''
    $dirs = @(Get-ChildItem $BACKUP_ROOT -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending)
    if ($dirs.Count -gt 0) { $latest = $dirs[0].Name }

    $removed = 0
    if ($DryRun) {
        foreach ($f in $DLL_SHA.Keys) {
            if (Test-Path (Join-Path $root $f)) { Say "  [DryRun] 将处理 $f" }
        }
    } else {
        # 组件的备份、还原、删除统一在这一处完成（含哈希判定），不做循环调用
        Restore-SteamComponents $root $latest | Out-Null
        $removed += $DLL_SHA.Keys.Count
    }
    foreach ($d in @('opensteamtool', 'config\lua')) {
        $p = Join-Path $root $d
        if (Test-Path $p) {
            if ($DryRun) { Say "  [DryRun] 将删除 $d\" }
            else { Remove-Item $p -Recurse -Force; Say "  已删除 $d\"; $removed++ }
        }
    }
    $toml = Join-Path $root 'opensteamtool.toml'
    if (Test-Path $toml) {
        if ($DryRun) { Say '  [DryRun] 将删除 opensteamtool.toml' }
        else { Remove-Item $toml -Force; Say '  已删除 opensteamtool.toml'; $removed++ }
    }

    # 清理各账号的库缓存，避免库里继续显示解锁游戏
    $ud = Join-Path $root 'userdata'
    if (Test-Path $ud) {
        Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8,}$' } | ForEach-Object {
            $lc = Join-Path $_.FullName 'config\librarycache'
            if (Test-Path $lc) {
                Get-ChildItem $lc -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object {
                    $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                    if (-not $c) { return $false }
                    # 只清掉"仅含单个 appid 的解锁占位文件"。本工具确实会写入
                    # 这种小文件，但这个判据同样是启发式的：体积阈值 4 KB 既可能
                    # 漏掉更大的占位文件，理论上也可能误伤正常的小缓存。
                    # 需要确定性清理时请手工核对 $lc 下的 json。
                    return ($c.Length -lt 4096 -and
                            $c -match '"appid"\s*:\s*"?\d+' -and
                            $c -notmatch '"apps"\s*:\s*\[')
                } | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Ok "卸载完成，共处理 $removed 项（组件、lua、toml、库缓存）"
    Say "备份保留在: $BACKUP_ROOT"
    Say '以下内容没有被自动清理，确认无用后可手工删除：'
    Say "  · $root\appcache\librarycache\<appid>  （Steam 下载的库封面）"
    Say "  · $root\depotcache                     （已下载的 manifest 缓存）"
    Say '  · userdata 下各账号的 librarycache json 可能有残留'
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

# 预检：管理员权限 / 剩余空间 / 安全软件排除项
$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $isAdmin) {
    Warn '当前不是管理员权限：写入 Steam 目录可能失败；被安全软件拦截时也无法自动处理。'
    Warn '若下一步出现"拒绝访问"，请重开一个管理员 PowerShell 再跑本命令。'
}

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

# 预置启动脚本（g\<appid>.ps1）通过环境变量跳过确认，实现「一条命令跑完」
if ($env:OST_YES -eq '1') { $Yes = $true }

if (-not $Yes) {
    $ans = Read-Host '确认继续? (y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') { Say '已取消'; return }
}

Write-Host ''
Say '正在关闭 Steam ...'
if ($DryRun) {
    Warn '[DryRun] 跳过关闭 Steam'
} else {
    if (-not (Stop-SteamProcesses $steam)) { Warn '部分文件仍被占用，继续尝试写入' }
    Ok 'Steam 已停止'
}

Write-Host ''
Say '准备组件 ...'
if (-not (Install-Components $steam $stamp)) { Fail '组件准备失败，已中止（原有文件未改动）'; return }

Write-Config $steam $stamp | Out-Null

Write-Host ''
Say '解析 depot 结构 ...'
$depots = Get-DepotPlan $AppId

# appinfo 返回的是"当前 public 分支"的 depots，通常覆盖主体内容。
# 体积用于磁盘预检，同时给覆盖率判断一个参考。
$sizeMap = @{}
foreach ($d in $depots) { $sizeMap["$($d.Id)"] = [int64]$d.Size }
$totalBytes = ($depots | Measure-Object -Property Size -Sum).Sum
if ($totalBytes -gt 0) {
    Say ("  本体 depot 合计 {0:N1} GB（{1} 个）——这是各平台/语言 depot 的总和，不是真实下载量" -f ($totalBytes/1GB), $depots.Count)
    if ($KNOWN_SIZE[[int]$AppId]) { Say ("  该 AppID 实测下载量 {0:N1} GB（见 `$KNOWN_SIZE 表）" -f $KNOWN_SIZE[[int]$AppId]) }
}

# 磁盘预检：只提示、不阻断。装到哪块盘由用户在 Steam 里决定，
# 这里负责把"装不下"提前说清楚，避免下到一半失败。
if ($totalBytes -gt 0) {
    $known = $KNOWN_SIZE[[int]$AppId]
    if ($known) {
        $need = [int64]($known * 1GB)
        $srcTxt = "该游戏实测下载量 {0:N1} GB" -f $known
    } else {
        # 未知游戏：depot 求和通常远大于真实下载量，取 1/4 作下限粗判
        $need = [int64]($totalBytes * 0.25)
        $srcTxt = "depot 合计 {0:N1} GB（按 1/4 粗估）" -f ($totalBytes/1GB)
    }
    $dp = Get-DiskPrecheck $steam $need
    if ($dp) {
        if ($dp.Ok) {
            Ok ("磁盘预检: $($dp.Drive)\ 剩余 {0:N1} GB，{1}，空间充裕" -f ($dp.Free/1GB), $srcTxt)
        } elseif ($dp.AnyRootOk) {
            Warn ("默认库 $($dp.Drive)\ 剩余 {0:N1} GB 偏紧（{1}）。" -f ($dp.Free/1GB), $srcTxt)
            Warn '其他库位置空间更充裕，可在 Steam 里选择装到别的盘。'
        } else {
            Warn ("磁盘空间不足：$($dp.Drive)\ 剩余 {0:N1} GB，{1}。" -f ($dp.Free/1GB), $srcTxt)
            Warn '现在开始下载很可能中途失败。库位置：' + ($dp.Roots -join ' | ')
            if (-not (Ask-Continue '磁盘空间不足')) { Say '已取消（配置未改动）'; return }
        }
    }
}

# 收集 DLC。DLC 的 appid 必须显式 addappid，否则 Steam 不认为你拥有它；
# 而其 depot 有时挂在本体下、有时独立，两种都要覆盖。
$dlcIds = @()
try {
    $sd = Invoke-RestMethod -Uri "https://store.steampowered.com/api/appdetails?appids=$AppId&l=schinese" -TimeoutSec 30 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    $sdApp = $sd."$AppId"
    if ($sdApp -and $sdApp.success -and $sdApp.data.dlc) { $dlcIds = @($sdApp.data.dlc) }
} catch { }
if ($dlcIds.Count -gt 0) {
    Say "检测到 $($dlcIds.Count) 个 DLC，纳入其 app 声明与独立 depot ..."
    # 每个 DLC 查一次 appinfo，下面取密钥时复用，避免同一接口请求两遍
    $dlcPlans = @{}
    foreach ($dlcId in $dlcIds) {
        $dlcDepots = Get-DepotPlan ([int]$dlcId)
        $dlcPlans["$dlcId"] = $dlcDepots
        $added = 0
        foreach ($d in $dlcDepots) {
            if (-not ($depots | Where-Object { "$($_.Id)" -eq "$($d.Id)" })) {
                $depots += $d
                $sizeMap["$($d.Id)"] = [int64]$d.Size
                $totalBytes += [int64]$d.Size
                $added++
            }
        }
        Say "    DLC $dlcId : 独立 depot $($dlcDepots.Count) 个（新增 $added）"
    }
}

if ($depots.Count -eq 0) {
    Warn '未能解析出 depot 列表，将只写入 addappid(本体)，由工具自行向上游索取清单'
}

Write-Host ''
Say '获取 depot 解密密钥 ...'
$keyInfo = Get-DepotKeys $AppId $depots

# DLC 若带独立 depot，其密钥可能在 DLC 自己的分支下，逐个补取
if ($dlcIds.Count -gt 0) {
    foreach ($dlcId in $dlcIds) {
        $dlcDepots2 = $dlcPlans["$dlcId"]
        if (-not $dlcDepots2 -or $dlcDepots2.Count -eq 0) { continue }
        $dk = Get-DepotKeys ([int]$dlcId) $dlcDepots2
        if (-not $dk) { continue }
        if (-not $keyInfo) {
            $keyInfo = [pscustomobject]@{ Keys = @{}; Sources = (New-Object System.Collections.Generic.List[string]) }
        }
        $gained = 0
        foreach ($kk in $dk.Keys.Keys) {
            if (-not $keyInfo.Keys.ContainsKey($kk)) { $keyInfo.Keys[$kk] = $dk.Keys[$kk]; $gained++ }
        }
        if ($gained -gt 0) { [void]$keyInfo.Sources.Add("DLC $dlcId (+$gained)") }
    }
}
if ($keyInfo) {
    Ok "共取到 $($keyInfo.Keys.Count) 个 depot 密钥，来源："
    foreach ($s in $keyInfo.Sources) { Say "    $s" }
} else {
    Warn '所有镜像均无该 appid 的 Key.vdf，将不写密钥（下载可能失败，属该游戏未被收录）'
}

# 有密钥源时只声明有密钥的 depot。
# 无密钥的 depot 强行写进配置会让 Steam 尝试挂载却拿不到解密密钥，进而导致整个 app 安装失败。
$plan = $depots
if ($keyInfo -and $depots.Count -gt 0) {
    $plan = @($depots | Where-Object { $keyInfo.Keys.ContainsKey("$($_.Id)") })
    if ($plan.Count -eq 0) {
        # 一个密钥都没有时，"回退为声明全部"只会让 Steam 挂载一堆无法解密的
        # depot，表现是安装大小 0 B / 直接失败，比什么都不写更糟。
        Fail '本体与 DLC 的所有 depot 都没有拿到解密密钥，本 AppID 未被任何公开库收录。'
        Warn '继续下去只会写入一个无效配置。若要强行尝试（仅用于实验），请加 -Yes 重跑。'
        if (-not ($Yes -or $DryRun)) { Say '已中止（配置未改动）'; return }
        $plan = $depots
    }
    elseif ($plan.Count -lt $depots.Count) {
        Say "  已过滤 $($depots.Count - $plan.Count) 个无密钥 depot（清单库未收录）"
    }
}

Write-Host ''
Write-Lua $steam $AppId $plan $keyInfo $stamp $dlcIds | Out-Null

Write-Host ''
if ($DryRun) {
    Warn '[DryRun] 到此为止：未下载组件、未写任何文件、未启动 Steam'
    return
}
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
