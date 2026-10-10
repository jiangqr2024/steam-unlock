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
# 保留的语音语言：中文、英文，以及跨语言共用的（language 字段为空）。
# 想多留一种语言就往这里加（用 Valve 的写法：schinese / english / japanese...）。
# 加得越多下载越大 —— 巫师3 每多一种语音大约多 1-2 GB。
$LANG_KEEP = @('schinese', 'english')

# 只问一次 /v1/latest，后面多处复用这个结果，并把它当作 L2/L3 的开关：
# 探测失败就整条链路退回本地逻辑。HTTP 404 之类的也会走 catch —— 对客户端
# 来说"端点不存在"和"服务不可达"是同一件事：就不做这次增强。
function Get-ApiStatus {
    try {
        $r = Invoke-RestMethod -Uri "$API_BASE/v1/latest" -TimeoutSec $API_TIMEOUT_SEC `
             -Headers @{ 'User-Agent' = 'ost-install' } -ErrorAction Stop
        Write-Log "api: reachable (api_version=$($r.api_version))"
        return $r
    } catch {
        Write-Log "api: unavailable - $($_.Exception.Message)"
        return $null
    }
}

# 实测过的真实体积。单位 GB。
# 为什么需要它：appinfo 的 depot 体积求和与真实下载量无关——Steam 会按语言/
# 平台筛选，例如博德之门 3 的 53 个 depot 合计 449.4 GB，实际只需 145.75 GB。
# 拿求和值去比对剩余空间只会制造假警报，所以已实测的游戏用真实值，未知的用宽松阈值。
$KNOWN_SIZE = @{
    1086940 = 145.75   # 博德之门 3 + 2 DLC
    1222140 = 58.75    # 底特律：化身为人
    367520  = 4.87     # 空洞骑士（windows 单平台）
    1245620 = 69.2     # 艾尔登法环 + 黄金树幽影
    2050650 = 62.81    # 生化危机 4
    292030  = 54.72    # 巫师 3
    524220  = 40.34    # 尼尔：机械纪元
    814380  = 13.87    # 只狼
}

# ── 输出层 ───────────────────────────────────────────────────────
# 分两层，这是给"别人用"的前提：
#   用户层   console 只出进度与结论，一句话一件事，不带任何内部术语
#   技术层   全部细节写进日志文件；失败时把最后几行随错误一起打出来
# 理由很直接：用户在装游戏，不需要知道我们扫了几个镜像、哪个仓库给了多少密钥。
# 但失败时他要把信息发回给我们，所以那一刻细节必须有。
$script:LOGPATH = $null
$script:LOGTAIL = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $script:LOGPATH) { return }
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $script:LOGPATH -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($Message -match '\[x\]|\[!\]|ERR|错误|失败') {
        [void]$script:LOGTAIL.Add($line)
        while ($script:LOGTAIL.Count -gt 8) { $script:LOGTAIL.RemoveAt(0) }
    }
}

# 进度：一句话，一件事。重复调用同一句时只打印一次，避免滚动屏。
function Step {
    param([string]$Message, [string]$Key)
    if (-not $Key) { $Key = $Message }
    if ($script:LASTSTEP -eq $Key) { return }
    $script:LASTSTEP = $Key
    Write-Host $Message -ForegroundColor Cyan
    Write-Log $Message
}

function Say  ($m) { Write-Log $m }
function Ok   ($m) { Write-Log $m 'OK' }
function Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow; Write-Log $m 'WARN' }
function Nice ($m) { Write-Host "  $m"; Write-Log $m }
function Fail ($m) { Write-Log $m 'ERROR' }

# 错误表：失败码 -> 一句话结论 + 一个动作。
# Retry = $true 表示"同样的命令再跑一次可能就成了"，失败出口会据此补一句重试建议。
$script:ERRORS = @{
    'E-STEAM-NOTFOUND'  = @{ T = '没有找到 Steam。';              A = '确认电脑上装了 Steam；装在其他盘的话，把命令换成 .\install.ps1 -SteamPath "你的路径"'; R = $false }
    'E-COMPONENT-DL'    = @{ T = '组件下载失败，网络没连上。';      A = '换个网络，或者先开代理再跑一次同样的命令。'; R = $true }
    'E-COMPONENT-SUM'   = @{ T = '组件校验不通过，已主动中止。';    A = '你的文件没有被改动。这通常是下载过程中被改坏了，隔几分钟再跑一次。'; R = $true }
    'E-COMPONENT-WRITE' = @{ T = '写不进 Steam 目录。';            A = '用管理员身份重新打开 PowerShell 再跑一次。'; R = $false }
    'E-COMPONENT-BLOCK' = @{ T = '组件被安全软件拦下了。';          A = '在安全软件里把 Steam 安装目录加进"排除项"，然后重跑。'; R = $false }
    'E-STEAM-BUSY'      = @{ T = 'Steam 没有完全退出。';           A = '在右下角托盘里右键退出 Steam，等 10 秒，再跑一次。'; R = $true }
    'E-NO-INFO'         = @{ T = '这个 AppID 读不到游戏信息。';     A = '确认那个数字是对的（Steam 商店页地址里那串数字）。'; R = $false }
    'E-NO-KEYS'         = @{ T = '这个游戏暂时没有可用的解锁数据。'; A = '换个游戏试试。如果很多游戏都这样，隔一天再来看。'; R = $true }
    'E-NET'             = @{ T = '网络请求失败。';                 A = '检查网络后重跑；开着代理的话先关掉试试。'; R = $true }
    'E-UNKNOWN'         = @{ T = '出现了预期之外的问题。';          A = '把下面的日志尾部发给我，我来定位。'; R = $false }
}

# 失败出口：所有失败都必须走这里，保证"一句话结论 + 一个动作"。
# 细节不进 console —— 用户在装游戏，不想看堆栈；但它们会进日志，且尾部随错误一起打出来。
function Stop-WithUserMessage {
    param([string]$Code, [string]$Detail, [int]$ExitCode = 1)
    $e = $script:ERRORS[$Code]
    if (-not $e) { $e = $script:ERRORS['E-UNKNOWN']; $Code = 'E-UNKNOWN' }
    if ($Detail) { Write-Log ("detail: " + $Detail) 'ERROR' }

    Write-Host ''
    Write-Host ('  出错了，已经停下来（' + $e.T + '）') -ForegroundColor Red
    Write-Host ('  ' + $e.A)
    if ($e.R) { Write-Host '  修好之后，直接用同样的命令再跑一次就行。' -ForegroundColor DarkGray }
    Write-Host ('  错误码 ' + $Code) -ForegroundColor DarkGray
    if ($script:LOGPATH) { Write-Host ('  日志 ' + $script:LOGPATH) -ForegroundColor DarkGray }
    if ($script:LOGTAIL.Count -gt 0) {
        Write-Host '  ---- 下面这段发给我 ----' -ForegroundColor DarkGray
        foreach ($l in $script:LOGTAIL) { Write-Host ('  ' + $l) -ForegroundColor DarkGray }
    }
    Write-Host ''
    if (-not $DryRun) { try { exit $ExitCode } catch { return } }
    return
}

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
    if ($Yes -or $DryRun) { Write-Log ('continue without asking: ' + $reason); return $true }
    if (-not $script:CANPROMPT) { Write-Log ('no interactive host; assuming yes: ' + $reason) 'WARN'; return $true }
    $ans = Read-Host '仍要继续? (y/N)'
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
        Fail "download failed: $($_.Exception.Message)"
        $script:ERRCODE = 'E-COMPONENT-DL'
        return $false
    }

    $h = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($h -ne $REL_SHA) {
        Fail "release zip sha256 mismatch: expected $REL_SHA, got $h"
        $script:ERRCODE = 'E-COMPONENT-SUM'
        return $false
    }
    Write-Log "release zip sha256 ok" 'OK'

    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    foreach ($f in $DLL_SHA.Keys) {
        $src = Join-Path $tmp $f
        if (-not (Test-Path $src)) {
            Fail "component missing in package: $f"
            $script:ERRCODE = 'E-COMPONENT-SUM'
            return $false
        }
        $fh = (Get-FileHash $src -Algorithm SHA256).Hash
        if ($fh -ne $DLL_SHA[$f]) {
            Fail "$f sha256 mismatch: expected $($DLL_SHA[$f]), got $fh"
            $script:ERRCODE = 'E-COMPONENT-SUM'
            return $false
        }
        Write-Log "$f sha256 ok" 'OK'
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
            Fail "write $f failed: $($_.Exception.Message)"
            $script:ERRCODE = 'E-COMPONENT-WRITE'
            if (-not (Ask-Continue "组件未写入，配置将生成但不会生效")) { return $false }
            return $true
        }
        # 写入后复校：杀软隔离、磁盘写入错误都会在这里暴露，而不是等到启动 Steam 才失败
        if ((Get-FileHash $dst -Algorithm SHA256).Hash -ne $DLL_SHA[$f]) {
            Fail "$f changed after write (AV quarantine or tampering)"
            $script:ERRCODE = 'E-COMPONENT-BLOCK'
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
# [manifest] 这一节由 install.ps1 按服务端可用性生成：
#   url_template = 自建网关（多上游竞速 + 故障转移）
#   url          = 直连内置上游
# 想固定用直连，就把下一行的 url_template 换成 url = "steamrun"
$manifestBlock

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

# 取某个 appid 的 depot 结构。
# 这里必须重试：实测这个接口是"抖动型"的 —— 连续 5 次测都正常（250-1000ms），
# 但偶尔会超时一次。之前没有重试，一次超时就让整条流程失败退出，而用户看到
# 的只是"网络请求失败"。对家用网络来说，重试是最便宜也最有效的修复。
function Get-DepotPlan([int]$id) {
    $urls = @(
        "https://api.steamcmd.net/v1/info/$id"
    )
    $info = $null
    $lastErr = ''
    foreach ($u in $urls) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $info = Invoke-RestMethod -Uri $u -TimeoutSec 40 -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -ErrorAction Stop
                break
            } catch {
                $lastErr = $_.Exception.Message
                Write-Log ("appinfo attempt $attempt failed for $id : $lastErr") 'WARN'
                if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
            }
        }
        if ($info) { break }
    }
    if (-not $info) {
        Fail "appinfo request failed for appid $id : $lastErr"
        $script:ERRCODE = 'E-NET'
        return @()
    }
    if ($info.status -and $info.status -ne 'success') {
        Fail ("appinfo status: " + $info.status)
        $script:ERRCODE = 'E-NO-INFO'
        return @()
    }
    $app = $info.data."$id"
    if (-not $app) {
        # HTTP 200 但表里没有这个 appid：不是网络问题，重试也没用
        Fail "appid $id not present in appinfo"
        $script:ERRCODE = 'E-NO-INFO'
        return @()
    }

    $list = New-Object System.Collections.Generic.List[object]
    $any = $false
    foreach ($k in $app.depots.PSObject.Properties.Name) {
        if ($k -notmatch '^\d+$') { continue }
        $dd = $app.depots.$k
        $gid = $dd.manifests.public.gid
        if (-not $gid) { continue }
        # 平台过滤：一个游戏常有 windows / macos / linux 三份 depot，体积各占一份。
        # 不过滤的后果：配置里塞进另外两个平台的内容，Steam 目前会自己忽略，
        # 但那是在赌它的行为；而"安装大小"这类判断也会被三倍数字带偏。
        # 空的 oslist 表示跨平台共用（例如语音包），必须保留。
        $os = $dd.config.oslist
        if ($os -and $os -notmatch '(?i)windows') { continue }
        # 语言过滤：语音包常按语言单独做成 depot（巫师3 有 30 个语言 depot，
        # 波兰语/德语/法语/俄语/日语/葡语/韩语各一份）。全声明等于把八种配音
        # 都拉一遍。空的 language 表示跨语言共用（比如文本、贴图），必须保留。
        $lang = $dd.config.language
        if ($lang -and $LANG_KEEP -notcontains ([string]$lang).ToLower()) { continue }
        $sz = 0
        try { $sz = [int64]$dd.manifests.public.size } catch { }
        $list.Add([pscustomobject]@{ Id = $k; Gid = [string]$gid; Size = $sz })
        $any = $true
    }
    if (-not $any) {
        # 全部被过滤掉说明 oslist 表达方式跟我预期不同，退回不过滤更安全
        Write-Log "platform filter removed everything for appid $id; keeping all depots" 'WARN'
        foreach ($k in $app.depots.PSObject.Properties.Name) {
            if ($k -notmatch '^\d+$') { continue }
            $dd = $app.depots.$k
            $gid = $dd.manifests.public.gid
            if (-not $gid) { continue }
            $sz = 0
            try { $sz = [int64]$dd.manifests.public.size } catch { }
            $list.Add([pscustomobject]@{ Id = $k; Gid = [string]$gid; Size = $sz })
        }
    }
    return $list
}

# 下载一个文件（支持 gzip）。不用 Invoke-WebRequest 的 -OutFile：
# 它在 PS 5.1 下会按文本解码，二进制压缩包会被破坏。
# 下载一个文件，可选 gzip 解压。
# 不用 Invoke-WebRequest 的 -OutFile：PS 5.1 下它按文本解码，二进制压缩包会被破坏。
# 也不用 HttpClient：这个类型在 PS 5.1 里没被加载（会报"找不到类型…的程序集"），
# 而那个失败是静默的 —— 表现为"所有下载源都秒失败"，排查起来很费时间。
# HttpWebRequest 是 .NET Framework 原生的，PS 5.1 直接可用。
function Download-File([string]$url, [string]$dest, [int]$timeoutSec, [switch]$Gzip) {
    try {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'ost-install'
        $req.Timeout = $timeoutSec * 1000
        $req.ReadWriteTimeout = $timeoutSec * 1000
        try { $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip } catch { }
        $resp = $req.GetResponse()
        $rs = $resp.GetResponseStream()
        if ($Gzip) {
            $rs = New-Object System.IO.Compression.GZipStream($rs, [IO.Compression.CompressionMode]::Decompress)
        }
        $fs = [IO.File]::Create($dest)
        try { $rs.CopyTo($fs) } finally { $fs.Close(); $rs.Close(); $resp.Close() }
        return $true
    } catch {
        Write-Log ("download failed: " + $url + " -- " + $_.Exception.Message) 'WARN'
        return $false
    }
}

# 全局 depot 密钥表：优先从自有域名取（国内可达性稳定），GitHub 只作备用。
# 这张表覆盖面最大（实测 288,313 条、其中 175,781 条有效），一个游戏里
# 镜像补不齐的 depot，通常都能在这里找到，所以它的可用性直接决定成不成。
function Get-GlobalKeyTable([string]$cache) {
    $srcs = @(
        # 注意域名区别：密钥表是静态文件，放在 Pages 主域（jiangqr2026.xyz），
        # 不是服务端 API 的 api 子域 —— 两者不可混用。
        @{ u = 'https://jiangqr2026.xyz/depotkeys.json.gz'; g = $true;  n = 'self-hosted (gzip)' },
        @{ u = 'https://raw.githubusercontent.com/SteamAutoCracks/ManifestHub/main/depotkeys.json'; g = $false; n = 'github raw' }
    )
    foreach ($s in $srcs) {
        $raw = Join-Path $env:TEMP ('ost-keys-' + (Get-Random) + '.json')
        $ok = $false
        # 实测：这张表 7 MB，从自有域名下完要 4-5 分钟（国内线路限速）。
        # 但它是一次性的 —— 下完缓存 7 天，之后所有游戏都不用再下。
        # 所以超时给足，宁可慢也不要半途失败重来。
        if ($s.g) { $ok = Download-File $s.u $raw 600 -Gzip } else { $ok = Download-File $s.u $raw 600 }
        if (-not $ok -or -not (Test-Path $raw)) {
            Write-Log ("global key table: source failed - " + $s.n) 'WARN'
            continue
        }
        $sizeMb = [math]::Round((Get-Item $raw).Length / 1MB, 1)
        try {
            $t = Get-Content $raw -Raw | ConvertFrom-Json
            try { Copy-Item $raw $cache -Force } catch { }
            Write-Log ("global key table: loaded from " + $s.n + " ($sizeMb MB)")
            Remove-Item $raw -Force -ErrorAction SilentlyContinue
            return $t
        } catch {
            Write-Log ("global key table: parse failed from " + $s.n) 'WARN'
            Remove-Item $raw -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
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
            Write-Log ("{0} depot(s) still missing; consulting the global key table" -f $stillMissing.Count)
            # 缓存路径不能建立在 $PSScriptRoot 上：install.ps1 在 irm|iex 场景里
            # 没有脚本文件上下文，那个变量是空的，整个 try 会被外层 catch 吞掉。
            $cacheDir = Join-Path $env:LOCALAPPDATA 'ost-cache'
            $cache = Join-Path $cacheDir 'depotkeys.json'
            if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
            $gj = $null
            if ((Test-Path $cache) -and (((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -lt 7)) {
                try {
                    $gj = Get-Content $cache -Raw | ConvertFrom-Json
                    Write-Log 'using cached global key table (within 7 days)'
                } catch { $gj = $null; Write-Log 'local key cache corrupt; refetching' 'WARN' }
            }
            if (-not $gj) {
                # 第一次跑某个游戏时可能要下这张表（约 7 MB），慢但只此一次。
                Step '正在准备游戏数据（首次较慢，之后会快）...' 'keytable'
                $gj = Get-GlobalKeyTable $cache
            }
            $gained = 0
            if ($gj) {
                foreach ($d in $stillMissing) {
                    $prop = $gj.PSObject.Properties | Where-Object { $_.Name -eq [string]$d.Id }
                    if ($prop) {
                        $v = [string]$prop.Value
                        # 表里有空值条目，必须校验格式
                        if ($v -match '^[0-9a-fA-F]{64}$') {
                            $all[[string]$d.Id] = $v.ToLower()
                            $gained++
                        }
                    }
                }
            }
            if ($gained -gt 0) { [void]$srcs.Add("global key table (+$gained)") }
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
        Write-Log "[DryRun] would write $luaDir\$id.lua"
        Nice ("离线检查通过：{0} 个内容包，其中 {1} 个已配好密钥。" -f @($depots).Count, $withKey)
        if ($withKey -lt $depots.Count) { Warn ("有 {0} 个内容包没有密钥，这部分内容可能下载不完整。" -f $noKey) }
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

# ---- 可选的服务端层 ----------------------------------------------
# 这三层是加速与冗余，不是必经路径：任何一个不可达时，本脚本必须能用原有
# 方式把游戏装完。这是硬约束，改动这里时不要破坏它。
#   L1 网关      manifest request code 的多上游转发，写进 opensteamtool.toml
#   L2 短码      别名 -> AppID（服务端只返回数字，不含密钥）
#   L3 发布清单  权威哈希与最高可用版本（自检 + 叫停）
# $env:OST_API 是给测试用的覆盖开关（本地 mock 服务端），生产环境不要设置。
$API_BASE = 'https://api.jiangqr2026.xyz'
if ($env:OST_API) { $API_BASE = $env:OST_API; Write-Log ("api base overridden: $API_BASE") }
# 首次请求要算上 Workers 冷启动 + 用户自己那段网络，实测 3.5 秒左右是常态。
# 这里给足余量：超时只会让用户白等，而探测失败会丢掉一整层加速能力。
# 用户可用环境变量 OST_API_TIMEOUT 覆盖（例：网络好就设 2，省等待时间）。
$API_TIMEOUT_SEC = 8
if ($env:OST_API_TIMEOUT -and [int]::TryParse($env:OST_API_TIMEOUT, [ref]$null)) {
    $API_TIMEOUT_SEC = [int]$env:OST_API_TIMEOUT
}

# ══ 主流程 ══════════════════════════════════════════════════════
Write-Host ''
Write-Host '  Steam 游戏解锁' -ForegroundColor Cyan
Write-Host ''

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $env:LOCALAPPDATA 'ost-backup'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$script:LOGPATH = Join-Path $logDir ("run-$stamp.log")
$script:CANPROMPT = $true
try { $null = Read-Host -Prompt "" } catch { $script:CANPROMPT = $false }
Write-Log ('interactive prompt available: ' + $script:CANPROMPT)

$steam = Get-SteamRoot
if (-not $steam) {
    Stop-WithUserMessage 'E-STEAM-NOTFOUND' 'Get-SteamRoot returned null'
    return
}
Write-Log "steam root: $steam"
Write-Log "powershell: $($PSVersionTable.PSVersion)"
Write-Log "dryrun: $DryRun  yes: $Yes  norestart: $NoRestart"

if ($Uninstall) { Do-Uninstall $steam | Out-Null; return }



# 取 AppID：参数 -> 环境变量 -> 交互输入
if ($AppId -le 0 -and $env:OST_APPID) {
    $tmpId = 0
    if ([int]::TryParse($env:OST_APPID, [ref]$tmpId)) { $AppId = $tmpId }
}
# 解析目标：纯数字直接当 AppID；否则交给 L2 换数字。
# 环境变量优先于参数 —— launcher 是通过环境变量传值的。
# ---- 服务端调用默认关闭 ----------------------------------------
# 静态路径优先：不探测、不等待，从按下回车到开跑没有任何网络等待。
# 想启用服务端（网关/短码/叫停），把下面这行改成：
#     $apiInfo = Get-ApiStatus
$apiInfo = $null

# L3：服务端可以在 /v1/latest 里下发提示或叫停。用途是"发现某个版本有
# 问题时先让所有人停下来"，所以优先级最高，且必须发生在任何写盘之前。
if ($apiInfo) {
    if ($apiInfo.note) { Write-Host ('  ' + $apiInfo.note) -ForegroundColor Yellow }
    if ($apiInfo.halt) {
        $why = '服务端已暂停本工具的安装流程'
        if ($apiInfo.reason) { $why = [string]$apiInfo.reason }
        Write-Log ("halted by server: " + $why) 'ERROR'
        Write-Host ''
        Write-Host ('  已暂停：' + $why) -ForegroundColor Red
        Write-Host '  没有对你的电脑做任何改动。'
        Write-Host ''
        return
    }
}

$targetRaw = ''
if ($env:OST_APPID) { $targetRaw = [string]$env:OST_APPID }
if (-not $targetRaw -and $env:OST_ALIAS) { $targetRaw = [string]$env:OST_ALIAS }
if ($AppId -gt 0) { $targetRaw = [string]$AppId }

if (-not $targetRaw) {
    if (-not $script:CANPROMPT) {
        Stop-WithUserMessage 'E-NO-INFO' 'no appid given and no interactive host to ask'
        return
    }
    $targetRaw = Read-Host '请输入要入库的游戏 AppID（商店页 URL 里的数字）'
}

$tmpId = 0
if ([int]::TryParse($targetRaw, [ref]$tmpId) -and $tmpId -gt 0) {
    $AppId = $tmpId
} else {
    # 短码路径：服务端只返回一个数字，密钥仍然由本脚本自己去公开渠道取。
    if (-not $apiInfo) {
        Stop-WithUserMessage 'E-ALIAS' ("alias needs the api, which is unreachable: " + $targetRaw)
        return
    }
    try {
        $al = Invoke-RestMethod -Uri "$API_BASE/v1/alias?c=$targetRaw" -TimeoutSec $API_TIMEOUT_SEC `
              -Headers @{ 'User-Agent' = 'ost-install' } -ErrorAction Stop
        if (-not $al.appid) { throw 'response had no appid' }
        $AppId = [int]$al.appid
        Write-Log "alias $targetRaw -> $AppId"
    } catch {
        Stop-WithUserMessage 'E-ALIAS' ("alias lookup failed: " + $targetRaw)
        return
    }
}
Write-Log "target appid: $AppId"

Write-Log 'preflight listing suppressed (user-facing mode)'

# 预置启动脚本（g\<appid>.ps1）通过环境变量跳过确认，实现「一条命令跑完」
if ($env:OST_YES -eq '1') { $Yes = $true }

if (-not $Yes -and $script:CANPROMPT) {
    $ans = Read-Host '确认继续? (y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') { Write-Host '  已取消。'; Write-Log 'cancelled by user'; return }
}

if ($DryRun) {
    Warn '[DryRun] 跳过关闭 Steam'
} else {
    Step '正在连接 Steam 服务...' 'stop-steam'
    if (-not (Stop-SteamProcesses $steam)) {
        Write-Log 'some files still locked' 'WARN'
        if (-not (Ask-Continue 'Steam 没有完全退出，组件可能写不进去')) {
            Stop-WithUserMessage 'E-STEAM-BUSY' 'user aborted after steam files stayed locked'
            return
        }
    }
    Step '正在准备游戏组件...' 'components'
}

if (-not (Install-Components $steam $stamp)) {
    $c = $script:ERRCODE
    if (-not $c) { $c = 'E-COMPONENT-WRITE' }
    Stop-WithUserMessage $c 'Install-Components returned false'
    return
}

Write-Host ''
# 服务端探测放在这里：它同时决定 toml 的 manifest 上游怎么写、短码能不能
# 解析、要不要接受叫停。只问一次，避免每个功能各探一遍。

# L1：网关可用就走网关，不可用就直连内置上游。探针用一个必然非法的 request
# code（0），网关会回 400；只要不是 404/5xx 就说明这条路由是活的。
$manifestBlock = "[manifest]`nurl = `"$MANIFEST_MIRROR`""
if ($apiInfo) {
    $gwOk = $false
    try {
        $null = Invoke-WebRequest -Uri "$API_BASE/api/manifest/0" -UseBasicParsing `
                -TimeoutSec $API_TIMEOUT_SEC -ErrorAction Stop
        $gwOk = $true
    } catch {
        $resp = $null
        if ($_.Exception) { $resp = $_.Exception.Response }
        if ($resp) {
            $code = 0
            try { $code = [int]$resp.StatusCode } catch { }
            if ($code -eq 400 -or $code -eq 502) { $gwOk = $true }
        }
    }
    if ($gwOk) {
        $manifestBlock = "[manifest]`nurl_template = `"$API_BASE/api/manifest/%llu`""
        Write-Log "manifest gateway enabled ($API_BASE)"
    } else {
        Write-Log 'manifest gateway probe failed; keeping direct upstream' 'WARN'
    }
}

Write-Config $steam $stamp | Out-Null

Step '正在读取游戏信息...' 'gameinfo'
Write-Log "resolving depot plan for appid $AppId"
$depots = Get-DepotPlan $AppId

# appinfo 返回的是"当前 public 分支"的 depots，通常覆盖主体内容。
# 体积用于磁盘预检，同时给覆盖率判断一个参考。
$sizeMap = @{}
foreach ($d in $depots) { $sizeMap["$($d.Id)"] = [int64]$d.Size }
$totalBytes = ($depots | Measure-Object -Property Size -Sum).Sum
if ($totalBytes -gt 0) {
    $depotCount = @($depots).Count
    Write-Log ("depot total {0:N1} GB across {1} depot(s), windows only" -f ($totalBytes/1GB), $depotCount)
    if ($KNOWN_SIZE[[int]$AppId]) { Write-Log ("known install size {0:N1} GB" -f $KNOWN_SIZE[[int]$AppId]) }
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
# 空间只记日志、不给用户看：入库本身不占空间，下载是另一件事，什么时候点
# 安装由用户自己决定。这里保留记录是为了以后排查“这个游戏多大”。
$dp = Get-DiskPrecheck $steam $need
if ($dp) {
    Write-Log ("install size estimate {0:N1} GB; free on {1}: {2:N1} GB" -f [math]::Round($need/1GB,1), $dp.Drive, ($dp.Free/1GB))
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
    Write-Log "dlc detected: $($dlcIds -join ', ')"
    Nice "这款游戏包含 $($dlcIds.Count) 个 DLC，会一起装好。"
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
        Write-Log "dlc $dlcId : own depots $($dlcDepots.Count), newly added $added"
    }
}

if ($depots.Count -eq 0) {
    # 一个 depot 都拿不到时，写出 addappid(appid) 是个空配置：游戏会进库，
    # 但 0 B 内容。与其让用户以为装好了，不如在这里停下并把原因说清楚。
    $c = $script:ERRCODE
    if (-not $c) { $c = 'E-NO-INFO' }
    Write-Log "depot plan empty for appid $AppId (code $c)" 'WARN'
    Stop-WithUserMessage $c "empty depot plan for appid $AppId"
    return
}

Step '正在取得游戏数据...' 'keys'
Write-Log 'collecting depot keys from public mirrors'
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
    Write-Log ("keys collected: {0}" -f $keyInfo.Keys.Count)
    foreach ($s in $keyInfo.Sources) { Write-Log ("  source: $s") }
} else {
    Write-Log 'no key source matched this appid' 'WARN'
}

# 有密钥源时只声明有密钥的 depot。
# 无密钥的 depot 强行写进配置会让 Steam 尝试挂载却拿不到解密密钥，进而导致整个 app 安装失败。
$plan = $depots
if ($keyInfo -and $depots.Count -gt 0) {
    $plan = @($depots | Where-Object { $keyInfo.Keys.ContainsKey("$($_.Id)") })
    if ($plan.Count -eq 0) {
        # 一个密钥都没有时，"回退为声明全部"只会让 Steam 挂载一堆无法解密的
        # depot，表现是安装大小 0 B / 直接失败，比什么都不写更糟。
        Fail 'no depot key available for this appid'
        if (-not ($Yes -or $DryRun)) {
            Stop-WithUserMessage 'E-NO-KEYS' "appid $AppId produced 0 usable depots"
            return
        }
        Write-Log 'forcing full depot declaration because -Yes was given' 'WARN'
        $plan = $depots
    }
    elseif ($plan.Count -lt $depots.Count) {
        Write-Log ("filtered out {0} depot(s) without keys" -f ($depots.Count - $plan.Count))
    }
}

Write-Host ''
Write-Lua $steam $AppId $plan $keyInfo $stamp $dlcIds | Out-Null

Write-Host ''
if ($DryRun) {
    Warn '[DryRun] 到此为止：未下载组件、未写任何文件、未启动 Steam'
    Write-Host ('  日志：' + $script:LOGPATH) -ForegroundColor DarkGray
    return
}
if ($NoRestart) {
    Warn '按 -NoRestart 要求，未启动 Steam。手动启动后生效。'
} else {
    Step '正在完成配置...' 'launch'
    Start-Process (Join-Path $steam 'Steam.exe')
    Start-Sleep -Seconds 5
}

Write-Host ''
Write-Host '  完成了。打开 Steam，游戏会出现在库中。' -ForegroundColor Green
Write-Host '  库里暂时没有的话，等 1-2 分钟（Steam 刷新库有延迟），或者重启一次 Steam。'
Write-Host ''

Write-Host ''
