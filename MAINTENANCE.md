# 维护文档

> 面向后续维护。所有数字都是实测值，附取证方式，不要凭印象改。
> 最后核对：2026-10-10

---

## 一、这个项目是什么

给 Windows 上的 Steam 客户端做本地解锁（俗称"假入库"）：游戏出现在库里、可以下载、内容是真的。做法是替换 Steam 会加载的两个同名 DLL + 往 `config\lua` 写一份声明，**不修改 Steam 二进制、不注入游戏进程、不碰杀软设置**。

对外只有一条命令：

```powershell
irm https://jiangqr2026.xyz/<AppID>|iex
```

与灰产工具的形态一致，区别在**载荷可审计**：二进制来自官方 Release 且逐个校验 SHA256，配置全明文，每一步都有可见输出。

### 系统边界（改动时不要破坏）

1. **服务端是可选的。** 客户端默认不调用任何 API。有服务端组件（`server/`），但客户端不依赖它——探测、超时、等待都没有。
2. **失败必须降到不写盘。** 任何一步出问题，要么继续用兜底数据，要么停下且不改动用户文件；绝不写半个配置然后宣布成功。
3. **用户可见输出只留进度。** 技术细节进日志，用户屏幕上看不到。
4. **不收集任何信息。** 没有遥测、没有上报、没有服务端记账。

---

## 二、当前资产与状态

### 本地（`D:\steam-unlock-cli\dist-package\`）

| 文件 | 字节 | 编码 | 作用 |
|---|---|---|---|
| `install.ps1` | 51676 | **UTF-8 带 BOM** | 主脚本 |
| `bootstrap.ps1` | 6137 | **纯 ASCII 无 BOM** | 引导：取回并校验 install.ps1 |
| `publish-game.ps1` | 14915 | UTF-8 带 BOM | 生成 launcher + 覆盖率诊断 + 上传 |
| `publish-update.ps1` | 4790 | UTF-8 带 BOM | 发布 bootstrap + install（含哈希自检与回读校验） |
| `sync-hashes.ps1` | 5298 | UTF-8 带 BOM | 哈希同步的唯一入口 |
| `lib\github-cred.ps1` | 2205 | UTF-8 带 BOM | 按账号精确读 GitHub 凭据（见 8.4） |
| `test-install.ps1` | 5238 | 纯 ASCII | 单元验证：解析 install.ps1 的 AST，逐个执行函数并断言 |
| `build-offline-package.ps1` | 2101 | 纯 ASCII | 打包离线组件包（校验 Release zip 哈希） |
| `update-launchers.ps1` | 1254 | 纯 ASCII | 批量重写 launcher，并把 bootstrap 哈希写进去 |
| `depotkeys.json.gz` | 7426120 | 二进制 gzip | 自托管的全局密钥表（175714 条） |
| `REPORT.md` | 37437 | UTF-8 无 BOM | 独立分析报告（原理、复现步骤） |
| `MAINTENANCE.md` | 本文件 | UTF-8 无 BOM | 维护文档 |
| `PROJECT.md` / `HANDOFF.md` / `README.md` | — | UTF-8 无 BOM | 历史文档，参考价值 |
| `g\<appid>.ps1` | 410-450 | 纯 ASCII 无 BOM | 19 个 launcher |

**改完脚本后先跑 `test-install.ps1`**：它不需要网络、不碰 Steam 目录，纯解析 + 断言，几秒出结果。有回归会当场暴露。

**关键哈希**（改完必须保持一致）：

```
install.ps1              0A13220650F1F62E60A2C83DD8F79B989AEB0291B17CAC790B3048333F02B79F
bootstrap.ps1            27932E5083380DAE784418DF18F38ADAC3E9F80CBC102F41D9D682809F604F7E
bootstrap 内置的期望哈希   = install.ps1 的实际哈希（由 sync-hashes.ps1 保证）
```

### 线上

**GitHub Pages**（`https://jiangqr2026.xyz`，仓库 `jiangqr2024/steam-unlock` public main）：

```
bootstrap.ps1   install.ps1   publish-game.ps1   depotkeys.json.gz
CNAME（jiangqr2026.xyz）  .nojekyll
14 个无扩展名 launcher + g/ 下 14 个同名 .ps1
```

**Cloudflare Worker**（`https://api.jiangqr2026.xyz`）：已部署且／v1/health 验证可用，但**客户端不调用**。保留备用。

### 已配置的游戏（19 个）

| AppID | 游戏 | 体积 | 备注 |
|---|---|---|---|
| 1086940 | 博德之门 3 + 2 DLC | 145.75 GB | 53 depot，密钥全 |
| 1091500 | 赛博朋克 2077 | — | |
| 1222140 | 底特律：化身为人 | 58.75 GB | 单 depot |
| 1237970 | 泰坦陨落 2 | 63.9 GB | **有 EA 验证限制**，见第五节 |
| 1245620 | 艾尔登法环 + 黄金树幽影 | 69.2 GB | 7/8 depot |
| 2050650 | 生化危机 4 | 62.81 GB | |
| 2407270 | AI LIMIT 无限机兵 | 22.3 GB | 2 DLC 为声明类 |
| 2778580 | 黄金树幽影（DLC） | — | 早期产物 |
| 292030 | 巫师 3 | 54.72 GB | 语言过滤前后 69→32 depot |
| 3391010 | 无限机兵豪华版升级包 | 0 | DLC 声明类 |
| 3489700 | 剑星 | — | 有 Denuvo，不可运行 |
| 367520 | 空洞骑士 | 4.87 GB | 平台过滤前后 14.7→4.9 GB |
| 374320 | 黑暗之魂 3 + 3 DLC | 24.9 GB | |
| 3813800 | 厄瑞涅的战争熔炉 | 0 | DLC 声明类 |
| 391540 | Undertale | 0.48 GB | |
| 424840 | 小小梦魇 | 9.1 GB | |
| 524220 | 尼尔：机械纪元 | 40.34 GB | |
| 814380 | 只狼 | 13.87 GB | |
| 870780 | 控制 终极合辑 | — | 主内容缺密钥，不可用 |

**线上只发布了 14 个**（`2778580`/`3391010`/`3489700`/`3813800`/`870780` 只在本地有 launcher，未上传）。

---

## 三、客户端处理流程

```
用户: irm https://jiangqr2026.xyz/<AppID>|iex
  │
  ├─[1] Pages 返回无扩展名 launcher（412 字节，纯 ASCII）
  │       $env:OST_APPID='<AppID>'; $env:OST_YES='1'
  │       iex (irm '<域名>/bootstrap.ps1')
  │
  ├─[2] bootstrap.ps1 取回 install.ps1
  │       源顺序：自有域名 → raw.github → gh-proxy → ghproxy → jsDelivr ×2
  │       每个源用 SHA256 校验，不符即视为"该源是旧版本"并跳过
  │       下载到 %TEMP%\ost-install.ps1，然后 iex (Get-Content -Raw)
  │
  └─[3] install.ps1 主流程
          定位 Steam（注册表 → 常见路径）
          关闭 Steam（轮询等待进程退出，最多 10 秒）
          校验/下载三个组件（Release zip + 逐文件 SHA256）
          写 opensteamtool.toml（UTF-8 无 BOM）
          解析 depot：appinfo → 平台过滤 → 语言过滤
          DLC 递归（appdetails.dlc，逐个查 depot 并补密钥）
          取密钥：13 个镜像并集（多文件名拼法）→ 缺则查全局密钥表
          只声明有密钥的 depot，无密钥则明确失败
          写 config\lua\<AppID>.lua（UTF-8 无 BOM）
          启动 Steam
```

`Steam 启动` → 加载 `dwmapi.dll` / `xinput1_4.dll`（代理）→ 判断进程名 == steam.exe → `LoadLibrary("OpenSteamTool.dll")` → 读 lua → hook 所有权查询。

---

## 四、几个必须理解的设计决策

### 4.1 为什么源的顺序是"自有域名优先"

实测（无代理，中国大陆线路）：

```
raw.githubusercontent.com   FAIL  超时 20s / 零字节（时通时断）
gh-proxy.com                OK    但缓存滞后，发布后短时间给旧版本
cdn.jsdelivr.net            OK    分支内容缓存约 12 小时，滞后最严重
jiangqr2026.xyz             OK    1.5 秒，发布后 1-2 分钟追平
```

早期版本把 GitHub 放在第一位，导致用户卡在 `Downloading installer ...`——**明明有一个确认可用的通道（自有域名），却不用它**。

### 4.2 哈希校验为什么不能去掉

`bootstrap.ps1` 用 `iex` 执行远端拉回的 `install.ps1`。`iex` 不受 ExecutionPolicy 约束（这是它能在锁定机器上工作的原因），也就意味着**被替换的 install.ps1 会被毫无察觉地执行**。所以期望的 SHA256 钉在 bootstrap 里。

代价是"发布不同步就自锁"。规避方式：**唯一维护入口 `sync-hashes.ps1`**，发布顺序固定（先 bootstrap 后 install）。

### 4.3 平台过滤与语言过滤

一个游戏常在 appinfo 里列出多个平台的 depot，体积各占一份：

```
空洞骑士  367521 windows 4.87 GB / 367522 macos 4.92 GB / 367523 linux 4.88 GB
          → 不过滤时"合计 14.7 GB"，而 Steam 实际只装 4.87 GB
```

语音包同理，按语言单独做 depot：

```
巫师3     69 个 depot，其中 30 个是语言包（polish/german/french/russian/japanese/...）
          → 过滤后 32 个
```

规则（在 `Get-DepotPlan` 里）：`oslist` 非空且不含 windows 就跳过；`language` 非空且不在 `$LANG_KEEP` 里就跳过。`$LANG_KEEP` 默认 `@('schinese','english')`，加语言就多下 1-2 GB。空的 `oslist`/`language` 表示跨平台或跨语言共用，**必须保留**。

### 4.4 为什么"入库"和"下载"要分开看

入库只是让游戏出现在库里，**不占任何空间**。下载是另一件事（用户在 Steam 里点安装才发生）。所以磁盘空间不足只提醒、不阻断——这一条是用户明确要求的，早期版本会弹确认框拦路。

### 4.5 编码契约（最容易出事的地方）

| 文件 | 编码 | 如果搞错 |
|---|---|---|
| `bootstrap.ps1`、`g/*.ps1` | **纯 ASCII 无 BOM** | 由 `irm\|iex` 执行，PS 5.1 按 ANSI 代码页解码非 ASCII 字节 → 乱码 → 语法崩 |
| `install.ps1`、`publish-game.ps1`、`sync-hashes.ps1` | **UTF-8 带 BOM** | 无 BOM 时 PS 5.1 按 GBK 解码中文 → 全文乱码、语法崩 |
| `config/lua/*.lua`、`opensteamtool.toml` | **UTF-8 无 BOM** | lua 解析器不识别 BOM；BOM 不是合法 TOML 起始字符 |

**两个已经踩过的坑**：

PowerShell 的 `[IO.File]::WriteAllText($path, $s, (New-Object System.Text.UTF8Encoding($true)))` 会写 BOM；而 `[Text.Encoding]::UTF8.GetString($bytes)` 会把已有 BOM 解码成 `\uFEFF` 字符保留在字符串开头。**读带 BOM 的文件时必须剥掉 BOM**（`$s = $s.TrimStart([char]0xFEFF)`）或者读取时跳过前三字节，否则写回就变双 BOM，解析器直接报错。

编辑工具（包括某些 `edit` 类工具）会抹掉 BOM。改完任何脚本**都要立刻验证编码**：

```powershell
$b = [IO.File]::ReadAllBytes($path)
'BOM={0} 非ASCII={1}' -f (($b[0] -eq 239) -and ($b[1] -eq 187) -and ($b[2] -eq 191)), (@($b | Where-Object { $_ -gt 127 }).Count)
```

---

## 五、已知问题与限制

### 5.1 硬限制（改不掉的）

**Denuvo**：需要 `setAppTicket` + `setETicket`，票据必须来自真正拥有该游戏的账号且约 30 分钟过期。无法用公开资源解决。已知名单：剑星、黑神话悟空、死亡空间、育碧全线、部分日厂。

**EA / Ubisoft / Rockstar 等第三方平台验证**：泰坦陨落 2 的商店 DRM 说明是 `EA on-line activation and Origin client software installation and background use required`。这类游戏在 Steam 上是个壳，启动时拉对方的启动器，由对方校验账号所有权。**本地解锁能让它入库、能下载，但对方那一关是另一个系统。** 已配置的 19 个游戏里，1237970 属于这一类。

**多账号无法隔离**：`config\lua` 是全局的，OpenSteamTool 的 Lua API 没有读 SteamID 的函数。大号有正版时，`setManifestid` 会强制 manifest 版本，可能与官方 build 冲突。缓解方式：登录大号前把对应 lua 移出目录（`toggle-unlock.ps1` 已存在，未接入主流程）。

**超新作 / 冷门游戏**：社区清单库滞后。DLC 尤其明显——无限机兵的厄瑞涅的战争熔炉（3813800）就是"清单库未收录"。

### 5.2 潜在风险

| 风险 | 触发条件 | 影响 | 当前缓解 |
|---|---|---|---|
| `api.steamcmd.net` 抖动 | 偶发超时（实测连测 5 次都正常，但曾超时一次导致整条失败） | 拿不到 depot 结构 → 流程停 | 已加 3 次重试 + 2/4 秒退避 |
| GitHub 密钥镜像抖动 | 无代理下时通时断 | 镜像取不到密钥 | 13 个镜像并集 + 自托管密钥表兜底 |
| 密钥表缓存过期 | 7 天后 | 需要重新下载 7 MB（实测 162-224 秒） | 用户会看到"首次较慢"提示 |
| CDN 缓存滞后 | 刚发布后 | 短暂拿到旧版本 | 哈希校验跳过旧源 + 自有域名优先 |
| 杀软拦截 | 写入代理 DLL | 组件缺失 → hook 不生效 | 写入后复校哈希可以发现；不做自动加白 |
| Steam 客户端更新 | 签名失效 | 解锁短暂失效 | 工具自动重扫，等它扫完 |
| 发布的游戏未重新生成 | 过滤逻辑改动后 | 旧 lua 里含多余平台/语言 depot | 见 7.2 |

### 5.3 未查清的问题

`-DryRun` 曾有一次总耗时 417 秒，其中密钥表只占 2 秒（走缓存），**剩下 415 秒花在哪没有定位**。可能的大头是密钥镜像扫描（13 个仓库 × 3 种文件名 + 网络抖动）。如果用户反馈"取得游戏数据"这一步特别慢，从这里查。

---

## 六、踩过的坑（完整清单）

按发现顺序，每条都记下根因，避免重犯。

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 磁盘空间不足时弹确认框拦路 | 把"入库"当成"装机前检查" | 空间只记日志、不阻断 |
| 2 | 缓存永远不命中 | `$PSScriptRoot` 在 `irm\|iex` 下是空的 → `Join-Path` 抛异常 → 被外层 `catch` 静默吞掉 | 缓存路径改到 `%LOCALAPPDATA%\ost-cache` |
| 3 | 所有下载源"秒失败" | `[System.Net.Http.HttpClient]` 类型在 PS 5.1 里没被加载，异常被静默 catch | 改用 `HttpWebRequest`（.NET 原生） |
| 4 | 密钥表请求打到错误的域名 | 混淆了 Pages 主域（静态文件）与 api 子域（服务端 API） | 密钥表用 `jiangqr2026.xyz`，注释写明区别 |
| 5 | 用户卡在 `Downloading installer` | 源列表把被墙的 GitHub 放第一位 | 自有域名提到首位 |
| 6 | 多次网络失败 | 单点、零重试 | appinfo 加 3 次重试 + 退避 |
| 7 | 安装大小虚高（14.7 GB vs 实际 4.87 GB） | 把多平台 depot 体积相加 | 平台过滤 |
| 8 | 巫师3 下了 8 种语音 | 未过滤语言 depot | 语言过滤 + `$LANG_KEEP` |
| 9 | 非交互环境直接崩 | `Read-Host` 在无交互宿主下抛异常 | 启动时探测 `$script:CANPROMPT`，不可用就走默认 |
| 10 | 假 AppID 被判定"完成" | `steamcmd.net` 对不存在的 appid 返回 `status: success` 但 depots 为空 | depot 为空时明确停止并报错 |
| 11 | 无密钥时"回退为声明全部" | 过滤后为空就回退全量，等于把已知有害那步执行到底 | 改为明确失败 + 中止 |
| 12 | 编辑后脚本语法崩 | BOM 被抹掉 / 被写重 | 见 4.5，每次改完立刻验证编码 |
| 13 | `-Compress` 上传失败 400 | `ConvertTo-Json -Compress` 让 payload 格式与平时不同 | 大文件上传不带 `-Compress` |
| 14 | launcher 中文变乱码 | launcher 必须纯 ASCII，我往里加了中文警告 | 用商店返回的英文原文，不加自造中文 |
| 15 | `publish-game.ps1` 整体崩 | 双 BOM + 写成无 BOM，两个编码错误叠加 | 从线上重新下载原件恢复 |
| 15 | `publish-game.ps1` 整体崩 | 双 BOM + 写成无 BOM，两个编码错误叠加 | 从线上重新下载原件恢复 |
| 16 | **`-DryRun` 中途崩溃 `op_Addition`** | `Get-DepotPlan` 返回 `List`，但只有 1 个元素时 PowerShell **自动展开成标量**，于是 `$depots += $d` 变成两个 PSObject 相加 | 赋值与拼接处统一用 `@()` 包住 |
| 17 | **失败时屏幕出现异常堆栈** | `Stop-WithUserMessage` 用 `throw` 中断，而 `throw` 在 `iex` 下会把原始异常和 `CategoryInfo` 打到屏幕上 | 主流程整体包一层 `try/catch`，catch 留空（友好信息已在前一步打印） |
| 18 | **上传一直 404，看不出原因** | 凭据管理器里存着两个 GitHub 账号的 token，`git credential fill` 返回的是**没有本仓库权限**的那个；即使传 `credential.username` 也无效 | 新增 `lib/github-cred.ps1` 按名字精确读，并加推送权限自检 |
| 19 | 改 `publish-update.ps1` 后文件首行丢了 `#` | 用 here-string 替换时，内容里的 C# 代码和 PowerShell 的引号规则冲突，把注释符吃掉了 | 凭据逻辑抽到独立 `lib/` 文件，避免在脚本里内联 C# |

**共同教训**（这是项目最重要的一条，来自原始交接文档，实测完全成立）：**用假设代替实测**。三次重大误判——说巫师3没入库（其实是 UI 延迟）、说剑星不可行（密钥其实在全局表里）、说黄金树幽影全库都没有（钥匙就在那 16 MB 的 json 里）——都源于扫描范围不够就下结论。

---

## 七、优化方向

### 7.1 值得做

**全局密钥表瘦身**。现在 7.08 MB gzip、解压 12.83 MB，首次下载在无代理下要 162-224 秒。如果把密钥从 64 位十六进制字符串改成 32 字节 Base64（`"a1b2…"` 44 字符 vs 64），能压到 4-5 MB，下载时间减半。代价是客户端要加一段解码逻辑。

**appinfo 自托管缓存**。`api.steamcmd.net` 是唯一还硬依赖的外部接口，抖一次就失败（虽然有重试）。可以把常用 appid 的响应预抓到自有域名上，客户端优先取本地托管版本。按 appid 存，每个几十到几百 KB。

**重新生成已发布游戏的配置**。平台/语言过滤是后加的，早期生成的 lua 里含多余 depot（比如空洞骑士那个有 37 个语言 depot）。重新跑一遍 `install.ps1 <appid>` 会刷新成干净版本。不刷新也不会坏（Steam 会忽略不匹配的），只是不干净。

### 7.2 可选

**密钥镜像双源**。现在镜像走 `raw.githubusercontent.com`，时通时断。可以给每个镜像加 jsDelivr 备选路径（`cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/...`），代价是请求数翻倍。

**服务端集成**。`server/api-worker` 已部署且 health 正常，能提供 manifest 网关（多上游故障转移）、短码、发布清单。客户端目前完全不调用它。接入方式：把 `install.ps1` 里的 `$apiInfo = $null` 改回 `$apiInfo = Get-ApiStatus`（约 40 行代码已就位）。**接入前想清楚**：这会让客户端多一次 8 秒超时风险，而当前静态路径已经能跑通。

**`toggle-unlock.ps1` 接入主流程**。账号隔离的实际需求存在（大号玩正版时），但现在要手动跑。

### 7.3 不建议

**自动加杀软白名单**。那是灰产特征，会被安全软件标记，而且违背项目"不碰杀软设置"的定位。

**遥测上报**。破坏"不收集任何信息"的定位，且引入隐私合规问题。让用户手动贴日志就够了。

---

## 八、变更流程

### 8.1 改 install.ps1 之后（必须走完）

```powershell
cd D:\steam-unlock-cli\dist-package

# 0) 先跑单元验证（几秒，不需要网络，不碰 Steam 目录）
.\test-install.ps1

# 1) 干跑验证：确认改动没破坏流程（不写盘、不关 Steam）
.\install.ps1 -AppId 1222140 -DryRun

# 2) 哈希体检：确认编码没被破坏
$b = [IO.File]::ReadAllBytes('.\install.ps1')
'BOM={0} 非ASCII={1}' -f (($b[0] -eq 239) -and ($b[1] -eq 187)), (@($b | Where-Object { $_ -gt 127 }).Count)
# 期望：BOM=True，非 ASCII 一万三千上下（少了说明中文注释被吞了）

# 3) 语法检查
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\install.ps1), [ref]$null, [ref]$err)
if ($err -and $err.Count) { $err | Select-Object -First 5 | ForEach-Object { $_.Message } } else { 'SYNTAX OK' }

# 4) 同步哈希 + 上传（顺序不能反）
.\sync-hashes.ps1
# 上传（脚本内部会做凭据自检，并按 bootstrap → install 的顺序传）
.\publish-update.ps1

# 5) 等 Pages 追平（1-2 分钟），然后真跑一次验证
```

改 `install.ps1` 时**同时更新服务端的 INSTALL_SHA**（如果还想让 L3 保持一致）：`cd server\api-worker; .\deploy.ps1`

### 8.1.1 GitHub 凭据（容易踩）

凭据管理器里存着**多个 GitHub 账号的 token**（实测两个），`git credential fill` 返回哪个不由你决定。取到没权限的那个时，上传报 404，而错误信息完全看不出是账号问题。

所以发布脚本用 `lib\github-cred.ps1` 按名字精确读：

```powershell
. .\lib\github-cred.ps1
$token = Get-GithubTokenFromStore -Owner jiangqr2024
```

它读的是凭据管理器里的 `git:https://jiangqr2024@github.com`。`publish-update.ps1` 还会拿 token 查一次仓库的 `permissions.push`，不通过就直接报错——比等到每个文件都 404 要早得多。

想确认当前凭据属于谁：

```powershell
& cmdkey /list | Select-String 'github'      # 看有哪些条目
```

---
### 8.2 发布新游戏

```powershell
.\publish-game.ps1 -AppId <appid>            # 生成 + 上传 + 诊断
.\publish-game.ps1 -AppId <appid> -NoUpload  # 只生成
```

它只上传 `g/<appid>.ps1`。**要短路径（`/<appid>` 无扩展名）还需要单独上传一次**——用 GitHub Contents API 把同一份文件 PUT 到仓库根目录同名文件。这个步骤目前是手动的，属于已知缺口。

### 8.3 改过过滤逻辑后

已发布游戏的 launcher 不受影响（launcher 只带 AppID），但**已入库游戏的 lua 是旧的**。重新跑一遍 `install.ps1 <appid>` 即可刷新。

---

## 九、故障排查

### 9.1 最快路径

```powershell
# 看最近一次运行的日志（技术细节都在里面）
Get-ChildItem "$env:LOCALAPPDATA\ost-backup\run-*.log" | Sort-Object LastWriteTime -Desc |
  Select-Object -First 1 | Get-Content
```

用户报错时，`install.ps1` 会打印**错误码 + 日志尾部**，拿到那一段基本就能定位。

### 9.2 错误码对照

| 错误码 | 含义 | 排查方向 |
|---|---|---|
| `E-STEAM-NOTFOUND` | 找不到 Steam | 注册表 `HKCU\Software\Valve\Steam\SteamPath` |
| `E-COMPONENT-DL` | 组件下载失败 | 到 GitHub Release 的网络 |
| `E-COMPONENT-SUM` | 组件哈希不符 | 下载被改坏，重试 |
| `E-COMPONENT-WRITE` | 写不进 Steam 目录 | 权限 / 杀软 |
| `E-COMPONENT-BLOCK` | 写入后被拦 | 杀软隔离 |
| `E-STEAM-BUSY` | Steam 没退出 | 手动彻底退出 |
| `E-NO-INFO` | 读不到 appid 信息 | AppID 是否有效 |
| `E-NO-KEYS` | 没有任何 depot 密钥 | 游戏未被清单库收录 |
| `E-NET` | 网络请求失败 | appinfo 或密钥源 |

### 9.3 分环节判据

| 卡在哪 | 说明 | 处理 |
|---|---|---|
| `Downloading installer ...` | install.ps1 取不到 | 检查自有域名是否可访问；看 CDN 是否追平 |
| `正在读取游戏信息...` | appinfo 失败 | 已带 3 次重试；持续失败说明该接口在你网络下不可达 |
| `正在取得游戏数据...` | 密钥扫描慢 | 正常可能 30-60 秒；超过 2 分钟查 5.3 |
| `正在准备游戏数据（首次较慢）...` | 在下密钥表 | 首次 3-4 分钟正常，之后缓存 7 天 |
| 库里没有游戏 | lua 带 BOM / Steam 未重启 | 检查 BOM；等 1-2 分钟或重启 Steam |
| 安装大小 0 B | depot 密钥缺失 | 重新诊断覆盖率 |

### 9.4 运行时状态检查

```powershell
# 组件是否加载进 steam.exe
(Get-Process steam | Select-Object -First 1).Modules | Where-Object { $_.ModuleName -match '(?i)opensteamtool' }

# hook 签名缓存（时间戳应等于 Steam 启动时间）
Get-ChildItem 'D:\steam\opensteamtool' -Recurse -File | Select-Object Name, LastWriteTime

# 游戏是否入库（Steam 会下载库封面，这是最可靠判据）
Select-String -Path 'D:\steam\logs\steamui_librarycache.txt' -Pattern '<AppID>' | Select-Object -Last 5

# lua 编码体检
Get-ChildItem 'D:\steam\config\lua' -File | ForEach-Object {
  $b = [IO.File]::ReadAllBytes($_.FullName)
  '{0,-16} BOM={1} 非ASCII={2}' -f $_.Name, (($b[0] -eq 239)), (@($b | Where-Object { $_ -gt 127 }).Count)
}
```

---

## 十、关键路径速查

| 用途 | 路径 |
|---|---|
| Steam 安装目录 | `D:\steam` |
| 游戏库 | `D:\steam\steamapps`、`E:\SteamLibrary` |
| lua 配置 | `D:\steam\config\lua\` |
| 工具配置 | `D:\steam\opensteamtool.toml` |
| hook 签名缓存 | `D:\steam\opensteamtool\{pattern,ipc}\...` |
| 组件备份 | `C:\Users\DELL\AppData\Local\ost-backup\<时间戳>\` |
| 运行日志 | `C:\Users\DELL\AppData\Local\ost-backup\run-*.log` |
| 密钥表缓存 | `C:\Users\DELL\AppData\Local\ost-cache\depotkeys.json` |
| 项目根 | `D:\steam-unlock-cli\dist-package\` |
| 服务端 | `D:\steam-unlock-cli\server\api-worker\` |

---

## 十一、文档索引

| 文档 | 内容 | 什么时候看 |
|---|---|---|
| 本文（`MAINTENANCE.md`） | 维护视角：现状、决策、坑、流程 | 改代码前 |
| [REPORT.md](REPORT.md) | 独立分析：原理、证据、复现步骤 | 想搞懂"为什么这么设计" |
| [PROJECT.md](PROJECT.md) | 历史技术文档（部分内容已过时） | 查早期资源库全景 |
| [HANDOFF.md](HANDOFF.md) | 原始交接文档（部分已过时） | 查项目起点 |
| [README.md](README.md) | 用户使用说明 | 需要给用户看时 |
| [server/部署教程.md](server/部署教程.md) | 服务端部署（手把手） | 要启用服务端时 |
| [server/README-DEPLOY.md](server/README-DEPLOY.md) | 服务端接口契约 | 改服务端时 |

**过时提醒**：`PROJECT.md` 和 `HANDOFF.md` 里关于"镜像源顺序""install.ps1 字节数""已知 BUG 清单"的部分已经不准，以本文和 `REPORT.md` 为准。
