# Steam 自助解锁项目 — 工作文档

> 最后更新：2026-10-08
> 仓库：https://github.com/jiangqr2024/steam-unlock
> 本地：`D:\steam-unlock-cli\dist-package\`

---

## 一、项目定位

一个**全透明、可审计**的 Steam 本地解锁方案，形态上对齐灰产工具（一条命令搞定），但实现路径完全公开：

| 维度 | 灰产工具 | 本项目 |
|---|---|---|
| 分发方式 | `irm 短域名\|iex` | `irm 短域名\|iex`（形态一致） |
| 载荷 | 加壳 DLL、内存加载、劫持系统 DLL | OpenSteamTool 官方 Release，SHA256 校验 |
| 落盘文件 | 加密的 `localData.vdf` | 明文 lua + 明文 toml |
| 杀软处理 | 自动加白名单 | **不做任何杀软设置** |
| 密钥来源 | 私有库 + 账号池 | 公开 GitHub 镜像并集 |
| 用户可否审计 | 否 | **是**，所有文件明文可核对 |

**不覆盖的场景**：Denuvo 加密的游戏、社区清单库尚未收录的新作。

---

## 二、整体架构

```
用户粘贴的一条命令
        │
        ▼
┌───────────────────────────────────────────┐
│ 1. launcher   g/<appid>.ps1   (448-450 B) │  内嵌 AppID，纯 ASCII 无 BOM
│    $env:OST_APPID = '292030'              │
│    $env:OST_YES   = '1'                   │
│    iex (irm bootstrap.ps1)                │
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│ 2. bootstrap.ps1              (3908 B)    │  5 镜像 fallback，纯 ASCII 无 BOM
│    下载 install.ps1 → %TEMP%              │
│    iex (Get-Content $DST -Raw)            │  规避 ExecutionPolicy
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│ 3. install.ps1               (18118 B)    │  UTF-8 BOM（含中文）
│    ① 注册表定位 Steam 目录                 │
│    ② 关闭 Steam                           │
│    ③ 下载 OpenSteamTool Release + 校验     │
│    ④ 写入 3 个 DLL + toml                 │
│    ⑤ 查 appinfo 得 depot 结构              │
│    ⑥ 多镜像并集取 depot 密钥               │
│    ⑦ 生成 config/lua/<appid>.lua          │
│    ⑧ 启动 Steam                           │
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│ 4. config/lua/<appid>.lua                  │  无 BOM，Lua 解析器要求
│    addappid(depotId, 0, "<64位hex>")       │
│    setManifestid(depotId, "<gid>")         │
└───────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────┐
│ 5. Steam 启动，加载代理 DLL                │
│    dwmapi.dll / xinput1_4.dll              │
│      → 检测进程名 == steam.exe             │
│      → LoadLibraryA("OpenSteamTool.dll")   │
│    OpenSteamTool hook license 判断         │
└───────────────────────────────────────────┘
        │
        ▼
   库中出现游戏，可下载 / 可运行
```

---

## 三、每一步的实现原理

### 3.1 launcher（`g/<appid>.ps1`）

**作用**：把"用户输入 AppID"这一步消掉，实现一游戏一命令。

```powershell
$env:OST_APPID = '292030'
$env:OST_YES   = '1'
iex (Invoke-RestMethod 'https://.../bootstrap.ps1')
```

**为什么用环境变量而不是命令行参数**：`irm|iex` 上下文里无法给脚本传参数，而环境变量会跨进程边界传递（bootstrap → install 都在同一个 PowerShell 进程内）。

**为什么必须纯 ASCII 无 BOM**：这个文件由 PowerShell 5.1 通过 `Invoke-RestMethod` 拉取后直接 `iex`。PS 5.1 对无 BOM 的文件按 **ANSI 代码页（GBK）** 解码，中文会被解成乱码字节，破坏语法。实测报错：`无法将"﻿Write-Host"项识别为 cmdlet`。

**为什么用 `iex (irm ...)` 而不是 `irm ... | iex`**：两者都可行，前者在出错时能保留更完整的异常上下文。

### 3.2 bootstrap.ps1

**作用**：多镜像容错地把 `install.ps1` 落到本地。

**镜像链**（依次尝试，每个重试 2 次）：

| 顺序 | 镜像 | 形式 |
|---|---|---|
| 1 | `raw.githubusercontent.com` | 直连 |
| 2 | `gh-proxy.com/` + URL | 代理前缀 |
| 3 | `ghproxy.net/` + URL | 代理前缀 |
| 4 | `cdn.jsdelivr.net/gh/USER/REPO@main/` | CDN |
| 5 | `fastly.jsdelivr.net/gh/...` | CDN |

**关键实现**：`iex (Get-Content $DST -Raw)` 而非 `& $DST`

```
实测（Restricted 策略下）：
  & script.ps1          -> 运行脚本已被禁用（失败）
  iex (Get-Content)     -> SCRIPT_RAN（成功）
```

调用运算符 `&` **受 ExecutionPolicy 约束**。新装 Windows 客户端默认是 `Restricted`；即便 `RemoteSigned`，从网络下载的脚本带 Mark-of-the-Web 也会被拦。`iex` 执行的是字符串，不受策略限制。

**`$MIN = 2000`**：小于 2KB 的响应被判定为错误页而非真脚本。

### 3.3 install.ps1

**Steam 路径定位**

```
注册表 HKCU:\Software\Valve\Steam\SteamPath  →  d:/steam
规范化：-replace '/','\'  然后大写盘符  →  D:\steam
```

**组件校验**

| 文件 | 用途 | SHA256 前缀 |
|---|---|---|
| `dwmapi.dll` | 代理 DLL（桌面窗口管理器） | `CC086189...` |
| `xinput1_4.dll` | 代理 DLL（手柄输入） | `730D6E3C...` |
| `OpenSteamTool.dll` | 真正的载荷 | `B2ED24E0...` |

Release 包整体校验：`96665460...`（tag `1.4.8`）

**为什么选这两个代理 DLL**：Steam 会从**自己的安装目录**加载 `dwmapi.dll` 和 `xinput1_4.dll`（Windows 的 DLL 搜索顺序中，程序目录优先于 system32）。代理 DLL 被加载后检查当前进程名，只有 `steam.exe` 才继续加载真正的载荷，避免污染其他程序。

**depot 结构查询**

```
GET https://api.steamcmd.net/v1/info/<appid>
  → data.<appid>.depots.<depotId>.manifests.public.gid
```

public appinfo **不含密钥**，只有 manifest 的 gid。

**密钥获取（多镜像并集）**

```powershell
foreach ($m in $MIRRORS) {
    # 各仓库文件名大小写不一致：bruh-hub 用 key.vdf，其余多为 Key.vdf
    foreach ($fn in @('key.vdf', 'Key.vdf', 'config.vdf')) { 尝试拉取 }
    正则匹配 '"(\d+)"\s*\{\s*"DecryptionKey"\s*"([0-9a-fA-F]+)"'
    长度必须 == 64，否则跳过（哈希/加密格式）
    取并集，已覆盖全部 depot 则提前 break
}
```

**为什么必须并集而非命中即停**（实测数据）：

| 游戏 | 单库覆盖 | 并集覆盖 |
|---|---|---|
| 巫师 3 | Auiowu 35 / TOP-01 18 | **53 / 53** |
| 赛博朋克 2077 | TOP-01 12 / Auiowu 12 | **24 / 24** |
| 生化危机 4 | 旧列表 2 / 31（不可行） | **31 / 31**（bruh-hub 一个源补齐） |

### 3.3.1 关于 64 字符限制（源码级确认）

`src/Utils/Config/LuaConfig.cpp` 的 `lua_addappid` 实现：

```cpp
    std::string Key = "";
    if (argc > 2) {
        if (!lua_isstring(L, 3)) return luaL_error(L, "");
        const char* key = lua_tostring(L, 3);
        // Keep only keys with exactly 64 characters.
        if (strlen(key) == 64) {
            Key = std::string(key);
        }
    }
    if (!Key.empty() || !DepotKeySet.count(DepotId)) {
        DepotKeySet[DepotId] = Key;
    }
```

**恰好 64，不是 64 就静默丢弃**——注意这里**没有 `luaL_error`**，所以 DLL 里也没有 `addappid` 的校验消息串（对比 `setETicket` / `setStat` 都有成套提示），排查时容易误以为"没有校验"。

### 3.3.2 资源库全景（按内容实测，不信任分类标签）

**教训**：SDO 的 `Encrypted` / `Decrypted` / `Branch` 标签**与实际可用性严重不符**，必须逐个实测。全量验证 26 个仓库的结果：

| 实测结果 | 数量 | 说明 |
|---|---|---|
| 实际可用 | 13 | 密钥为 64 字符标准格式 |
| 标 Decrypted 但取不到数据 | 6 | `ManifestHub/ManifestHub`、`ikun0014/ManifestHub`、`ltsj/*`、`bingyu50/SteamManifestCache`、`TOP-01/SteamManifestCache`、`Scropiouos/SteamManifestCache_backup` |
| 标 Encrypted 但实际可用 | 1 | **`nekoaday/ManifestAutoUpdate`**（16562 分支，文件名 `config.vdf`） |
| 标 Branch 但实际可用 | 1 | **`Fairyvmos/bruh-hub`**（40461 分支，文件名 `key.vdf`） |
| 确认哈希/无效 | 3 | `sean-who`、`Fairyvmos/BlankTMing`、`Scropiouos/..._PrivateBackUp` |
| 仓库已删除 | 5 | `japapalarox/*`、`ltsj/*`、`ikun0014/*`、`Fallonma/*`、`nekoaday/*_again` |

**文件名的三种拼法**（这是取不到数据的主因）：

| 文件名 | 使用的仓库 |
|---|---|
| `key.vdf`（小写） | `Fairyvmos/bruh-hub` |
| `Key.vdf`（大写） | `Auiowu`、`TOP-01`、`tymolu233`、`sean-who` |
| **`config.vdf`** | `nekoaday`、`hansaes`、`MineRPG`、`luomojim`、`1271620983`、`bingyu50`、`crazzzzzysnail`、`Scropiouos_backup` |

**大多数仓库用的是 `config.vdf`，而不是 `key.vdf`——只试前者会漏掉近一半可用源。** 脚本现已三种都试。

### 3.3.3 全局密钥表（覆盖面最大的一环）

`SteamAutoCracks/ManifestHub` 的 **`depotkeys.json`** 是一个 **depotId → key 的全局映射表**：

```
文件大小   : 16,044,970 字节
总条目     : 288,381
有效条目   : 175,781（其余为空值，必须逐条校验格式后才能采用）
```

**这个表的覆盖面超过所有按 AppID 分目录的仓库之和**，因为它是扁平的 depot 级映射，不受"某个仓库收不收这个游戏"的限制。

**接入策略**（兼顾速度与覆盖率）：先走 12 个镜像（快，秒级），**只有当仍有 depot 缺密钥时**才下载这 16 MB 全局表兜底。

**实测效果——艾尔登法环「全 DLC」从不可能变为可行**：

```
接入前: 4 / 8  depot，缺 黄金树幽影(2778580, 15.02GB) + 典藏包(2855520, 1.01GB) + 2 个小 depot
接入后: 7 / 8  depot，有密钥 69.20 GB

[有] depot 1245621   51.26 GB
[缺] depot 1245622    0.91 GB     ← 全局表里这条是空值，唯一的缺口
[有] depot 2778580   15.02 GB     ★ 黄金树幽影
[有] depot 2855520    1.01 GB     ★ 典藏包
```

生成的 lua 实测包含：

```lua
addappid(2778580, 0, "9f1556645ea8ef43529f920cf02a2682a6da5756b29e630ba376a0cde24e3908")
setManifestid(2778580, "1674424364022381183")
addappid(2855520, 0, "476eca9191866d6743aa7ad82d4d7ce1fcd5e0f0613f2f4b6559635d68f8c0e3")
setManifestid(2855520, "2785904640065824767")
```

**这把钥匙在此之前扫遍全部 26 个公开仓库都找不到。**

### 3.3.4 另两个资源维度

**`appaccesstokens.json`**（`SteamAutoCracks/ManifestHub`，182295 字节）——`appId → accessToken` 映射。OpenSteamTool 支持 `addtoken(appid, token)`，可用于部分需要访问令牌的场景。**本项目暂未接入**（尚未验证其必要性与有效性）。

**`SteamManifestCache` 系列**（3 个仓库，各 2.4-2.6 万分支）——提供 `.manifest` 数据 + `appinfo.vdf` + `config.json`，但**不含密钥**（实测 `appinfo.vdf` 里 `decryptionkey` 字样出现 0 次）。而 OpenSteamTool 从上游按 request code 拉取 manifest、不读本地文件，**故对该工具无用**。

### 3.3.5 三类仓库的本质区别

SDO 的 README 给出了权威定义：

| 类型 | 密钥 | manifest | 说明 |
|---|---|---|---|
| **Decrypted** | 64 字符有效 ✓ | 可能旧 | 传统主力来源 |
| **Encrypted** | **128/192 字符，hashed/partial/invalid ✗** | 最新 ✓ | 密钥不可用 |
| **Branch** | **64 字符有效 ✓** | **实际 .manifest 数据 ✓** | **最优，此前被误判跳过** |

SDO 原文对 Encrypted 的说明：
> decryption keys within their `key.vdf`/`config.vdf` might be **hashed, partial, or invalid**... Games downloaded solely from here **likely won't work directly** ("Content is still encrypted" error).

**关键教训**：`Branch` 只是 SDO 对「下载打包 zip」这种分发方式的分类，**不代表资源不可用**。`Fairyvmos/bruh-hub` 被归为 Branch，但它实际提供：

```
<appid>/key.vdf      标准 64 字符密钥（实测 5/5 与已知明文一致）
<appid>/<appid>.lua  现成的 lua 配置
<appid>/<appid>.json 含 decryptionkey + gid + size 的完整元数据
<appid>/<depot>_<gid>.manifest  实际 manifest 数据
```

**规模对比（实测）**：

| 仓库 | 分支数 | 密钥有效性 |
|---|---|---|
| `SteamAutoCracks/ManifestHub` 的 depotkeys.json | **175781 个有效 depot** | **✓ 全局覆盖** |
| **Fairyvmos/bruh-hub** | **40461** | **✓ 抽样 5/5 有效** |
| sean-who/ManifestAutoUpdate | 27795 | ✗ 128 字符哈希 |
| Fairyvmos/BlankTMing | 29470 | ✗ 192 字符哈希 |
| 11 个 Decrypted 仓库并集 | 8323 | ✓ 有效 |

**为何最初会漏掉**：分支名是纯数字 AppID，但按字母序 `10`/`20`/`1000000` 这些短数字排在前面，`814380` 这类 6 位 AppID 要翻很多页才出现，第一眼容易被误判为"分支名是随机串"。

**lua 生成**

```lua
addappid(292030)                          -- 注册 app 本身
addappid(292031, 0, "57538aae...")        -- 注册 depot + 密钥
setManifestid(292031, "8401480366474980007")
```

- `addappid(id, arg2, key)`：**arg2 被实现忽略**；arg3 必须恰好 64 字符
- 只写**有密钥的** depot —— 无密钥的写入会让 Steam 尝试挂载一个无法解密的 depot

### 3.4 OpenSteamTool 的 hook 机制

| 保护类型 | 是否需要额外数据 | 说明 |
|---|---|---|
| 无 DRM | 否 | 直接可用 |
| **SteamStub** | **否** | 复用本地 ConfigStore 票据 + 利用 SteamDRMP 的 off-by-four 解析漏洞伪造 AppId，不注入游戏进程 |
| **Denuvo** | **是** | 需要 `setAppTicket` + `setETicket`，票据**必须从真正拥有该游戏的账号提取**，有效期 **30 分钟**，过期报错 `88500005` |

**运行时产物**（证明 hook 生效）：

```
D:\steam\opensteamtool\pattern\steamclient\<sha256>.toml   3000 B
D:\steam\opensteamtool\pattern\steamui\<sha256>.toml       1307 B
D:\steam\opensteamtool\ipc\steamclient\<sha256>.toml        934 B
```

文件名是 **Steam 客户端二进制的 sha256**，内容是匹配到的函数签名偏移。Steam 每次更新客户端，这个 hash 会变，工具需要重新扫描——**存在一个短暂的窗口期**。

---

## 四、编码契约（最容易踩的坑）

项目里有三种文件，编码要求**各不相同且互相冲突**：

| 文件 | 编码 | 原因 |
|---|---|---|
| `bootstrap.ps1` | **纯 ASCII，无 BOM** | 由 PS5.1 直接 `iex`，非 ASCII 会按 GBK 误解码 |
| `g/<appid>.ps1` | **纯 ASCII，无 BOM** | 同上 |
| `install.ps1` | **UTF-8 带 BOM** | 含中文，PS5.1 读无 BOM 的 UTF-8 会按 GBK 解码导致语法错误 |
| `config/lua/*.lua` | **UTF-8 无 BOM** | Lua 解析器不识别 BOM |
| `opensteamtool.toml` | **UTF-8 无 BOM** | BOM 不是合法 TOML 起始字符 |

**PowerShell 5.1 的两个陷阱**：

1. `Set-Content -Encoding UTF8` 会**写入 BOM** —— 不能用于 lua/toml
2. `edit` 类工具会**抹掉已有 BOM** —— 每次改完 `install.ps1` 都要重新补

**验证命令**：

```powershell
$b = [IO.File]::ReadAllBytes($path)
'BOM=' + (($b[0] -eq 239) -and ($b[1] -eq 187) -and ($b[2] -eq 191))
'非ASCII=' + (@($b | Where-Object { $_ -gt 127 }).Count)
```

---

## 五、已知 BUG 与隐患清单

### 5.1 已修复（含根因）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `The term 'if' is not recognized` | PS5.1 不支持 `if` 作表达式 | 改用 `$(if ...)` |
| 2 | 路径解析失败 | 注册表返回 `d:/steam` | `-replace '/','\'` + 大写盘符 |
| 3 | `1 = 4` 之类诡异结果 | 单元素数组退化为标量 | `@()` 强制数组 |
| 4 | 脚本整体中断 | `& $exe -shutdown` 抛"不是有效应用程序" | `Start-Process -PassThru` + try/catch |
| 5 | 安装后 `0 mounted depots` | depot 过度声明（6 个 vs 实际需要 4 个） | 只保留有密钥的 depot |
| 6 | 上传 GitHub 返回 422 | Contents API 更新已存在文件必须带 `sha` | 先 GET 取 sha 再 PUT |
| 7 | **小白环境直接失败** | `& $DST` 受 ExecutionPolicy 限制 | 改 `iex (Get-Content $DST -Raw)` |
| 8 | **lua 不生效** | `Set-Content -Encoding UTF8` 写入 BOM | 改 `WriteAllText(UTF8Encoding($false))` |
| 9 | **密钥数虚高但不可用** | 镜像列表含 `Encrypted` 仓库，密钥是 76 字符格式 | 只收明文仓库 + 长度校验 + 明确报告跳过 |

**#9 的教训值得单独记**：当时只统计了 `DecryptionKey` 出现的**次数**就断定 `sean-who` "7/7 最全"，实际它的密钥 OpenSteamTool 根本不接受。**计数不等于可用**——必须校验格式。

### 5.2 潜在风险（未爆发）

| 风险 | 触发条件 | 影响 | 缓解 |
|---|---|---|---|
| GitHub API 限流 | 无 token 时 60 次/小时 | 发布失败 | 已用 Windows 凭据管理器的 token |
| Pages 构建延迟 | 新发布 launcher 后立即访问 | 短暂 404 | 等待 20-30 秒 |
| 镜像全挂 | 11 个镜像同时不可用 | 密钥取不到 | 脚本会明确报告，不会静默降级 |
| hook 签名失效 | Steam 客户端更新 | 解锁短暂失效 | 工具自动重扫，等待即可 |
| **多账号无法隔离** | 大号登录 | 伪造 license 对**所有账号**生效 | 见第七章 |
| 磁盘空间不足 | 安装大游戏前 | 下载中断 | **install.ps1 当前无检查** |
| 杀软误报 | 首次写入代理 DLL | 文件被隔离 | 未验证，建议手动加排除 |
| 网络中断 | 下载组件中途 | 组件损坏 | SHA256 校验会拦住 |

---

## 六、覆盖边界（实测数据）

### 6.1 公开密钥库规模

去重统计（仅明文格式仓库，11 个镜像）：

```
Scropiouos_backup   累计唯一  5342
TOP-01              +1868  = 7210
tymolu233           +610   = 7820
Auiowu              +53    = 7873
hansaes             +450   = 8323
其余                +0
───────────────────────────────
唯一 AppID 总数      8323
```

**增长曲线说明这些镜像高度重叠**——本质是同一份数据的多份拷贝，价值主要在冗余而非互补。

对比 Steam 约 10 万个 app，覆盖率约 **8%**。抽样显示以中小型/独立游戏为主，但主流 3A 覆盖良好。

### 6.2 实测覆盖结果

| 游戏 | AppID | depot 覆盖 | 结论 |
|---|---|---|---|
| 巫师 3 | 292030 | **53 / 53** | 完整 |
| 赛博朋克 2077 | 1091500 | **24 / 24** | 完整 |
| 尼尔：机械纪元 | 524220 | **9 / 9** | 完整 |
| 生化危机 4 | 2050650 | **31 / 31** | 完整（bruh-hub 补齐，旧方案仅 2/31） |
| **艾尔登法环** | 1245620 | **7 / 8，69.20 GB** | **含黄金树幽影 + 典藏包**，仅缺 0.91GB 空值条目 |
| 剑星 | 3489700 | **3 / 3** | 密钥齐全，但 **Denuvo** 拦在运行环节 |
| 只狼 | 814380 | 5 / 6 | 缺 512B 空占位，已实测可玩 |
| 控制 终极合辑 | 870780 | 4 / 5 | 最大的 42.73GB depot 仍缺 |
| 黑神话悟空 | 2358720 | 1 / 1 | **Denuvo**，不可行 |

**已实测入库成功的游戏**：只狼、赛博朋克 2077、巫师 3、艾尔登法环、尼尔：机械纪元。

**主流 3A 筛查结论**（25 款抽样）：仅「死亡空间」有 Denuvo；加入 bruh-hub 与全局密钥表后，「生化危机 4」由不可行转为完整、「艾尔登法环」由缺 DLC 转为含 DLC；仅「控制 终极合辑」仍缺主内容。

**覆盖率演进**（以艾尔登法环为例）：

```
初始（仅 Decrypted 仓库、只试 Key.vdf） : 4 / 8   缺黄金树幽影
+ Fairyvmos/bruh-hub                    : 4 / 8   该库无此游戏
+ 三种文件名兼容（config.vdf）            : 4 / 8
+ 全局密钥表 depotkeys.json              : 7 / 8   ★ 黄金树幽影到手
+ 接入 nekoaday/ManifestAutoUpdate       : 7 / 8
```

**主流 3A 筛查结论**（25 款抽样）：仅「死亡空间」有 Denuvo；「生化危机 4 / 控制」在加入 bruh-hub 后前者转为完整、后者仍缺主内容；其余 22 款均为「完整」或「主内容可用」。

### 6.3 不可行的两类

**Denuvo 游戏**：需要 `AppTicket` / `ETicket`，票据必须来自真正拥有该游戏的账号且 30 分钟过期，**无法通过公开资源解决**。

**超新作**：社区清单库滞后数周到数月。剑星（2025-06 发售）在全部 26 个公开仓库中都没有 `Key.vdf`。

---

## 七、账号冲突分析（重要）

### 7.1 核心事实

**`config/lua/*.lua` 是全局的，不区分登录账号。** OpenSteamTool 的 Lua API 只有 8 个函数（`addappid` / `addtoken` / `setmanifestid` / `http_get` / `http_post` / `setappticket` / `seteticket` / `setstat`），**没有任何可以读取 SteamID 的接口**，因此无法在 lua 层面写"仅对某账号生效"的条件。

### 7.2 实际场景

| 场景 | 大号（有正版） | 小号（无） |
|---|---|---|
| 大号登录 | 真实 license + lua 伪造声明**叠加** | — |
| 小号登录 | — | 仅 lua 伪造声明 |

### 7.3 风险点

**`setManifestid` 会强制指定 manifest 版本（gid）。**

- 如果 lua 里的 gid **落后于**官方最新 build，Steam 可能尝试使用旧清单 → **更新异常**或触发重新下载
- 正版文件与伪造 manifest 若不匹配 → **文件校验失败**
- 存档通常不受影响（存档不绑定 license）

**实测证据**：
- 只狼：用户切大号时只狼也被解锁，未报异常 —— 但**大号没有只狼**，不构成"正版 + 伪造"混合
- 艾尔登法环：**本项目的首次混合场景**（大号有正版本体、无 DLC）

### 7.4 处置建议

**推荐做法**：登录大号玩正版艾尔登法环前，把 `1245620.lua` 移出 `config/lua`。

```powershell
# 登录大号前
Move-Item 'D:\steam\config\lua\1245620.lua' 'D:\steam-unlock-cli\park\1245620.lua' -Force
# 切回小号
Move-Item 'D:\steam-unlock-cli\park\1245620.lua' 'D:\steam\config\lua\1245620.lua' -Force
```

**更好的做法**：用 `toggle-unlock.ps1`（已有）——它读取 `HKCU:\Software\Valve\Steam\ActiveProcess\ActiveUser` 判断当前账号，非目标账号时自动清空 `config/lua`。

> 注：该项目早期实现过按账号隔离，实测每 2 秒轮询约 2.19 ms、单核约 0.99% CPU、86.4 MB 内存。当时因"能入库就行"的取舍被搁置，**现在因大号有正版而重新变得相关**。

---

## 八、优化方向

### 8.1 功能性

1. **账号自动隔离** —— 恢复 `toggle-unlock.ps1` 的守护模式，或做成 `install.ps1` 的一个开关
2. **DLC 自动递归** —— 读 `appdetails.dlc` 数组，对每个 DLC 重复 depot/密钥流程（本次手工做了赛博朋克 2077 + 往日之影）
3. **本地密钥缓存** —— 同一 appid 24 小时内不重复请求 11 个镜像（当前每次全量遍历，约 10-15 秒）
4. **磁盘空间检查** —— 安装前比对本体的 `BytesToDownload` 与剩余空间
5. **证书就绪后统一切换短域名** —— `jiangqr2026.xyz` 已配好 DNS，等 GitHub 签发证书

### 8.2 稳健性

6. **镜像健康度记录** —— 记录各镜像历史命中率，动态排序（当前是硬编码顺序）
7. **失败可视化** —— 幂等性验证：重复执行不产生副作用（当前基本满足）
8. **回滚完整性** —— `restore-clean.ps1` 已有，但未覆盖 `depotcache` 的变更

### 8.3 体验

9. **进度反馈** —— 拉取 11 个镜像期间显示进度而非静默等待
10. **错误信息本地化** —— 部分异常仍是英文原始信息

---

## 九、操作手册

### 9.1 用户侧（一条命令）

```powershell
# 自有域名（证书已于 2026-10-08 21:00 前后签发，到期 2027-01-06）
irm https://jiangqr2026.xyz/814380|iex

# 回退到 GitHub Pages 默认域名（证书异常时可用）
irm https://jiangqr2024.github.io/steam-unlock/814380|iex
```

**命令长度对比**：

| 形态 | 长度 | 备注 |
|---|---|---|
| 灰产参考 | 28 | `irm steam-install.xxxxxx\|iex` |
| **本方案（最短）** | **38** | `irm https://jiangqr2026.xyz/814380\|iex` |
| 本方案（publish 默认输出） | 46 | 带 `/g/` 与 `.ps1` |
| 旧（github.io） | 57 | —— |

**不要省略 `https://`**：`irm` 对无 scheme 的地址会自动补 `http://`，走明文。启动脚本是要被**执行**的代码，明文传输给了中间人注入的机会。

**已发布的游戏**（全部为短域名版，launcher 内指向 `https://jiangqr2026.xyz/bootstrap.ps1`）：

| 游戏 | AppID | 短地址 | 覆盖率 |
|---|---|---|---|
| 只狼 | 814380 | `/814380` | 100% |
| 赛博朋克 2077 | 1091500 | `/1091500` | 100% |
| 巫师 3 | 292030 | `/292030` | 100% |
| 艾尔登法环 | 1245620 | `/1245620` | 7/8（含黄金树幽影） |
| 尼尔：机械纪元 | 524220 | `/524220` | 100% |
| 生化危机 4 | 2050650 | `/2050650` | 100% |

### 9.1.1 域名与证书

| 项 | 值 |
|---|---|
| 自有域名 | `jiangqr2026.xyz` |
| DNS 托管 | Cloudflare（apex CNAME → `jiangqr2024.github.io`，**DNS only 灰云**） |
| 解析结果 | Cloudflare flatten 为 GitHub 官方四 IP `185.199.108-111.153` |
| 证书 | Let's Encrypt `CN=jiangqr2026.xyz`，签发 2026-10-08，到期 2027-01-06 |
| 续期 | GitHub Pages 自动 |

**配置要点**：Cloudflare 必须用**灰云（DNS only）**。开橙色云代理会隐藏源站 IP，GitHub 无法验证域名所有权、Let's Encrypt 也签不下证书。

**注意**：设置自定义域名后，`jiangqr2024.github.io/steam-unlock/*` 会被 301 重定向到自有域名。DNS 未配好期间该地址会返回 502——配置自定义域名前应先确认 DNS 记录已就位。

### 9.2 发布新游戏

```powershell
cd D:\steam-unlock-cli\dist-package
.\publish-game.ps1 -AppId <appid>          # 生成 + 上传 + 诊断 + 打印命令
.\publish-game.ps1 -AppId <appid> -NoUpload # 只生成
```

脚本会输出**密钥覆盖率诊断**，判据是「**最大的那个 depot 有没有密钥**」——本体主内容总在最大的 depot 里。三种结论：缺失项是空占位/DLC → 可直接用；主内容有密钥、次要缺失 → 本体能玩；最大的 depot 就缺密钥 → 建议放弃。

### 9.3 新增游戏（手工，等效于命令流程）

把 lua 放进 `D:\steam\config\lua\<appid>.lua`，重启 Steam 或等待热重载。

---

## 十、故障排查

### 10.1 标准诊断序列

```powershell
# ① lua 是否生成、编码是否正确
Get-ChildItem 'D:\steam\config\lua' -File | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    '{0,-16} BOM={1} 非ASCII={2}' -f $_.Name, (($b[0] -eq 239)), (@($b | Where-Object { $_ -gt 127 }).Count)
}

# ② 组件是否加载进 steam.exe
$sp = Get-Process steam | Select-Object -First 1
$sp.Modules | Where-Object { $_.ModuleName -match '(?i)opensteamtool' }

# ③ hook 是否生效（时间戳应等于 Steam 启动时间）
Get-ChildItem 'D:\steam\opensteamtool' -Recurse -File | Select-Object Name, LastWriteTime

# ④ 游戏是否入库（Steam 会下载库封面，这是最可靠的判据）
Select-String -Path 'D:\steam\logs\steamui_librarycache.txt' -Pattern '292030' | Select-Object -Last 5

# ⑤ depot 挂载情况
Get-Content 'D:\steam\logs\content_log.txt' -Tail 40
```

### 10.2 常见症状对照

| 症状 | 最可能原因 | 处理 |
|---|---|---|
| 库里没有游戏 | lua 带 BOM / Steam 未重启 | 检查 BOM，重启 Steam |
| 库里没有游戏（lua 正常） | 需要等 Steam 刷新库 UI | 等 1-2 分钟，看 `steamui_librarycache.txt` |
| 安装大小是 0 B | depot 密钥缺失或过度声明 | 跑 `publish-game.ps1` 看覆盖率诊断 |
| `N mounted depots` 为 0 | 上游 request code 服务不可用 | 检查 `opensteamtool.toml` 的 `url` |
| 命令报执行策略错误 | 用了 `& $DST` | 确认 bootstrap 是 `iex (Get-Content)` |
| 中文乱码 | 文件编码与读取方不匹配 | 对照第四章编码契约 |

### 10.3 完全卸载

```powershell
cd D:\steam-unlock-cli\dist-package
.\install.ps1 -Uninstall
# 彻底清理
D:\steam-unlock-cli\restore-clean.ps1 -Apply -Purge
```

---

## 十一、关键路径速查

| 用途 | 路径 |
|---|---|
| Steam 安装目录 | `D:\steam` |
| 游戏库 | `E:\SteamLibrary` |
| depot 缓存 | `D:\steam\depotcache` |
| **lua 配置** | `D:\steam\config\lua\` |
| 工具配置 | `D:\steam\opensteamtool.toml` |
| hook 签名缓存 | `D:\steam\opensteamtool\` |
| 组件备份 | `D:\steam-unlock-cli\backup\original-steam-dlls\` |
| 安装备份 | `C:\Users\DELL\AppData\Local\ost-backup\<时间戳>\` |
| 项目根目录 | `D:\steam-unlock-cli\dist-package\` |

**上游 request code 服务**（`opensteamtool.toml` 的 `[manifest] url`）：

| 值 | 实测 |
|---|---|
| `opensteamtool` | 403 |
| `wudrm` | 503 |
| **`steamrun`** | **200 ✓ 当前使用** |
