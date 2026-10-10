# Steam 本地解锁工具链 —— 独立分析报告

> 报告范围：`D:\steam-unlock-cli\`（分发侧 `dist-package\` + 辅助脚本 + 资源缓存）
> 分析方法：不看结论看证据。所有判断都重新跑过：读字节、读进程模块、发 HTTP 请求、解析 Steam 日志。
> 与前几版文档的关系：`PROJECT.md` / `HANDOFF.md` 里的结论只作为线索，不作为依据；本报告中的每个数字与哈希都是本次实测所得。
> 生成时间：2026-10-09

---

## 一、这到底是什么东西（一句话）

一套把「Steam 客户端本地认为自己拥有某个游戏」这件事自动化的工具链，对外只暴露一条命令：

```powershell
irm https://jiangqr2026.xyz/1086940|iex
```

它不破解游戏本体，不做内存注入到游戏进程，不修改 Steam 客户端二进制。它做的是三件事：**换掉 Steam 会加载的两个同名 DLL**、**在 Steam 的配置目录里放一份 Lua 声明**、**让 Steam 用公开渠道泄露的 depot 密钥去下载真实内容**。

理解这套东西的关键，是把「拥有某款游戏」拆成 Steam 内部四个互相独立的判断：

| Steam 的判断 | 由什么决定 | 本方案怎么骗过它 |
|---|---|---|
| 这个账号拥有这个 AppID 吗 | license / 所有权记录（服务端下发） | OpenSteamTool 在进程内 hook 所有权查询 |
| 这个 depot 能解密吗 | depot 密钥（AES-256，服务端才知道） | 把公开泄露的密钥塞进 Lua |
| 这个 depot 挂哪个版本 | manifest gid | `setManifestid` 指定 |
| 这个 manifest 从哪拿 | manifest request code | 换一个可用的上游服务 |

四件事各有各的失败模式，**任何一件没成，游戏都不会出现在库里**。这解释了为什么历史上三次重大误判都发生在「以为某件不成、其实是别处断了」。

---

## 二、代码清单与角色（`dist-package\`，全部实测字节）

| 文件 | 字节 | 编码（实测） | 角色 |
|---|---|---|---|
| `bootstrap.ps1` | 3908 | 纯 ASCII、无 BOM | 5 镜像取回 `install.ps1` 并执行 |
| `install.ps1` | 已改 → 37291 | UTF-8 **带 BOM**、794+ 行 | 全流程主体 |
| `publish-game.ps1` | 14206 | UTF-8 带 BOM | 生成 launcher + 覆盖率诊断 + 上传 |
| `g\<appid>.ps1` | 410-450 | 纯 ASCII、无 BOM | 每游戏一条命令的入口 |
| `README.md` / `PROJECT.md` / `HANDOFF.md` | — | UTF-8 无 BOM | 文档 |
| `sync-hashes.ps1`（本次新增） | — | UTF-8 带 BOM | 防「发布不同步导致自锁」 |

仓库侧（`jiangqr2024/steam-unlock`，本次实测拉取文件树）：22 个 blob，其中 7 个无扩展名 launcher（`1086940` / `1091500` / `1245620` / `2050650` / `292030` / `524220` / `814380`）、`g\` 下 7 个同名 `.ps1`、`bootstrap.ps1`、`install.ps1`、`CNAME`（`jiangqr2026.xyz`）、`.nojekyll`。

**本地与仓库的差异（实测）**：本地 `g\` 有 10 个（多出 `2778580` 黄金树幽影、`3489700` 剑星、`870780` 控制），仓库只有 7 个；仓库里也不存在 `2778580` / `3489700` / `870780` 三个无扩展名文件。也就是说这三个游戏**从未对外发布**，只在本地生成过。

---

## 三、全流程与每一步的原理

### 3.0 端到端链路

```
用户粘贴: irm https://jiangqr2026.xyz/1086940|iex
   │
   ├─[1] 域名 → GitHub Pages（Cloudflare DNS only，灰云）
   │      /1086940 是无扩展名文件，Content-Type: application/octet-stream
   │
   ├─[2] launcher（410-412 B，纯 ASCII 无 BOM）
   │      $env:OST_APPID='1086940'; $env:OST_YES='1'
   │      iex (Invoke-RestMethod 'https://jiangqr2026.xyz/bootstrap.ps1')
   │
   ├─[3] bootstrap.ps1（3908 B）
   │      5 个镜像依次尝试 × 每个 2 次 → %TEMP%\ost-install.ps1
   │      iex (Get-Content $DST -Raw)
   │
   ├─[4] install.ps1（本次已加固）
   │      预检 → 关 Steam → 组件 SHA256 → opensteamtool.toml
   │      → appinfo 解析 depot → DLC 递归 → 密钥并集(+全局表) → 磁盘预检
   │      → config\lua\<appid>.lua（UTF-8 无 BOM）→ 启动 Steam
   │
   └─[5] Steam 启动
          dwmapi.dll / xinput1_4.dll 从 Steam 目录被加载（代理）
            → 判断进程名 == steam.exe
            → LoadLibrary("OpenSteamTool.dll")
          → 读 config\lua → hook 所有权查询 → 库里出现游戏
          → 上游取 manifest → 用 Lua 里的密钥解密 → 下载
```

下面逐个环节说清「为什么这么做」，以及**验证手段**。

### 3.1 为什么用无扩展名的短路径

GitHub Pages 对无扩展名文件返回 `application/octet-stream`，`Invoke-RestMethod` 只关心内容，不关心扩展名。于是 `<域名>/1086940` 可以直接当脚本喂给 `iex`。实测三条：

| URL | 状态 | 长度 | Content-Type |
|---|---|---|---|
| `https://jiangqr2026.xyz/1086940` | 200 | 412 | `application/octet-stream` |
| `https://jiangqr2026.xyz/g/1086940.ps1` | 200 | 412 | `application/octet-stream` |
| `https://jiangqr2026.xyz/install.ps1` | 200 | 22592 | `application/octet-stream` |

代价是路径里不能带参数，所以 AppID 只能靠**环境变量**传递：`$env:OST_APPID` / `$env:OST_YES` 会跨同一进程内的 `iex` 边界继续存在（bootstrap 与 install 共享一个 PowerShell 进程）。

**顺带一个观察**：首次请求 `bootstrap.ps1` 曾返回 **503**，2 秒后重试三次全部 200（本地与远端 SHA256 完全一致：`D63642B5...`）。这是 Pages CDN 边缘的冷启动抖动。而 `bootstrap.ps1` 是全链路**唯一的必经关口**——它挂了，所有游戏的所有命令全挂（`g\<appid>.ps1` 也只能死在这）。这是当前架构里单点性最强的一环。

### 3.2 bootstrap 的两处关键设计

**镜像链（5 个，顺序即优先级）**：

```
1) raw.githubusercontent.com/.../install.ps1          直连
2) gh-proxy.com/<RAW>                                 代理前缀
3) ghproxy.net/<RAW>                                  代理前缀
4) cdn.jsdelivr.net/gh/USER/REPO@main/install.ps1     CDN
5) fastly.jsdelivr.net/gh/.../install.ps1             CDN
```

每个源重试 2 次、超时 45 秒、`$MIN = 2000` 字节下限（挡错误页）。

**为什么是 `iex (Get-Content $DST -Raw)` 而不是 `& $DST`**：调用运算符 `&` 受 ExecutionPolicy 约束。新装 Windows 客户端默认 `Restricted`；即使 `RemoteSigned`，从网络下载的脚本带 Mark-of-the-Web 也会被拦。`iex` 执行的是字符串，不受策略限制。

**这一条的隐患**（下面第七章详述）：`iex` 绕过的同时也就绕过了「文件来源可信」这一层判断，所以 bootstrap 里对 `install.ps1` 的完整性校验不是可选项。

### 3.3 install.ps1 逐段原理

**① Steam 定位**：先读 `HKCU:\Software\Valve\Steam\SteamPath`（实测返回 `d:/steam`，正斜杠），做 `-replace '/','\'` + 盘符大写，再验证 `Steam.exe` 存在；失败则退到四个常见路径。**为什么不能只信注册表**：注册表值可能是残留（Steam 卸载/迁移后仍在），必须用 `Steam.exe` 存在性做二次确认。

**② 关闭 Steam**：先 `Steam.exe -shutdown`（`Start-Process -PassThru` 包在 try/catch 里——Steam 缺失或损坏时会抛「不是有效应用程序」，老版本就死在这），然后用**轮询**等方式等进程退出（本次改为最多 10 秒、每 500 ms 检查一次），最后强杀四个相关进程，再逐个尝试以 `ReadWrite + None` 独占打开目标 DLL，确认文件锁已释放。

**为什么必须独占打开**：DLL 被加载时文件被锁，直接 `Copy-Item` 会失败或写入半截文件。这一步是「写组件」的前置条件，不是保险动作。

**③ 组件下载与校验**：

| 文件 | 目标 | SHA256（实测与官方 Release 一致） | 大小 |
|---|---|---|---|
| Release 包 | `%TEMP%` | `966654604D258D5D...C882C710` | 1.16 MB |
| `dwmapi.dll` | `D:\steam` | `CC086189E9AE5F6F...813DF44F8` | 109568 B |
| `xinput1_4.dll` | `D:\steam` | `730D6E3C12162283...CA6F38A27` | 122880 B |
| `OpenSteamTool.dll` | `D:\steam` | `B2ED24E0B4E2D0DA...36EA22581` | 1446400 B |

**为什么先下 zip 再逐文件校**：zip 级别校验保证「包没被换」，文件级别校验保证「包解出来是我要的那三个」。任何一个不符就中止，且**此时还没有覆盖任何文件**。

**④ opensteamtool.toml**：写了上游服务名与超时参数。这份文件的实际作用是告诉 DLL 从哪儿取 manifest request code。

**⑤ depot 结构**：`GET https://api.steamcmd.net/v1/info/<appid>`，取 `data.<appid>.depots.<depotId>.manifests.public.gid`。

**实测发现的一个语义坑**：同一接口的 `manifests.public.size` 是**该 depot 的完整大小**，把所有 depot 加起来得到的是「所有平台 × 所有语言」的总和，不是下载量。以博德之门 3 为例：

```
53 个 depot 合计   449.4 GB     ← 求和值
Steam 实际下载量   145.75 GB    ← appmanifest 实测
```

拿 449.4 GB 去比对剩余空间，只会得到假警报（本次改造前的预检逻辑就会这么干）。所以本次新增了 `$KNOWN_SIZE` 表并明确标注求和值的语义。

**⑥ DLC 递归**：`store.steampowered.com/api/appdetails?appids=<id>` 拿 `data.dlc` 数组，对每个 DLC 再查一次 appinfo，把独立 depot 合并进计划，并且**每个 DLC 的 appid 都要单独 `addappid` 声明**。

**为什么必须声明 DLC 的 appid**：Steam 的「你拥有什么」和「你能解密什么」是两套判断。DLC 的 depot 密钥给了，但没声明拥有该 DLC，Steam 会认为你不该看到这部分内容，于是**不下载**。这是历史 BUG #10 的根因（「安装大小比预期小」）。

**⑦ 密钥获取（本项目最有价值的部分）**：

文件名三种拼法都要试——实测三个仓库各用一种：

| 仓库 | 文件名 | 实测 |
|---|---|---|
| `Fairyvmos/bruh-hub` | `key.vdf`（小写） | 200, 593 B |
| `Auiowu/ManifestAutoUpdate` | `Key.vdf`（大写） | 200, 417 B |
| `nekoaday/ManifestAutoUpdate` | `config.vdf` | 200, 421 B |

取到后按正则抽 `"<depotId>" { "DecryptionKey" "<hex>" }`，**只接受恰好 64 个十六进制字符**的值，其余计入「哈希格式，已跳过」。

**为什么 64 是硬门槛**：DLL 里 `lua_addappid` 有 `if (strlen(key) == 64)`，不满足者静默丢弃——注意是**静默**（没有 `luaL_error`，所以 DLL 字符串里连一句报错都没有）。这意味着「表面看起来配好了、实际什么都没生效」是这个项目最容易踩的坑。本次在 DLL 中检索 `64 characters` / `strlen` / `lua_addappid` 均为 **0 次命中**，与「静默丢弃」一致。

多镜像取**并集**而非命中即停：各仓库收录的 depot 互不覆盖。本次 DryRun 实测博德之门 3 的来源分布：

```
Fairyvmos/bruh-hub                +36
luomojim/ManifestAutoUpdate      +127
SteamAutoCracks/depotkeys.json    +17
合计取到 180 个密钥（最终只用其中 53 个）
```

注意 `luomojim` 那个仓库的 `config.vdf` 混进了大量其他游戏的密钥（+127），所以「取到 180 个」这个数字**不代表这个游戏需要 180 个**，容易误导。功能正确，提示可以更清楚。

**⑧ 全局密钥表兜底**：`SteamAutoCracks/ManifestHub/main/depotkeys.json` 是扁平的 `depotId → key` 映射，覆盖面远超任何按 AppID 分目录的仓库。本次实测：

```
远端大小      16044970 B
本地缓存大小  14891450 B（ConvertTo-Json 重写后的体积）
有效条目      175781（其余是空值，必须逐条正则校验）
```

只有当前面所有镜像仍缺 depot 时才下载它。本次改造加了 7 天本地缓存——此前每跑一次游戏都要重下 16 MB，纯浪费。

**这里踩到一个非常隐蔽的坑，值得单独记下来**：

第一版缓存实现把路径写成 `Join-Path $PSScriptRoot 'depotkeys-cache.json'`。在本地直接执行 `.\install.ps1` 时 `$PSScriptRoot` 有值，干跑测试一切正常；但**真实入口是 `irm|iex`，此时没有脚本文件上下文，`$PSScriptRoot` 是空字符串**，`Join-Path` 直接抛参数异常。而这段代码被一个「只做容错、不区分原因」的 `try { } catch { }` 包着 ——

- 缓存**读**失败被吞 → 每次都重新下载 16 MB（慢，但结果正确）
- 缓存**写**失败被吞 → 缓存文件永远不生成
- 最要命的是：第一次真实运行时那 17 个 depot 的全局表密钥因此没拿到，实际写入的 lua **只有 36 个 depot**，而干跑（本地执行）显示 53 个

也就是说，**同一个脚本在「本地执行」和「远程 iex 执行」两种上下文下会给出不同的结果**，而失败被静默吞掉、不留任何痕迹。这类 bug 靠看代码几乎发现不了，只有把两个上下文都真跑一遍、并逐字比对产出（lua 里到底有多少个 `addappid`）才会暴露。

修复：缓存路径改到 `%LOCALAPPDATA%\ost-cache\depotkeys.json`，并改成**原文件缓存**（先下载到临时文件、直接拷贝为缓存，读取时再解析）——顺手也避开了 PS 的 `ConvertTo-Json`/`ConvertFrom-Json` 往返在这张 28 万条目表上引入差异的可能。卸载路径里同源的一处 `$PSScriptRoot` 也一并改掉。

**⑨ 磁盘预检（本次新增）**：读 `steamapps\libraryfolders.vdf` 得到所有库位置，取默认库所在盘比对剩余空间。实测本机：`D:\` 剩 66.6 GB、`E:\` 剩 43.1 GB，而博德之门 3 需要 145.75 GB —— 这个检查直接命中真实处境。

**⑩ 写 Lua**：`config\lua\<appid>.lua`，UTF-8 **无 BOM**，内容形如：

```lua
addappid(1086940)                                       -- 本体
addappid(2378500)                                       -- DLC 声明
addappid(2378500, 0, "77dfde8ac009c5a5...25d9cb")        -- depot + 密钥
setManifestid(2378500, "6453229909780803137")            -- 指定版本
```

**为什么必须无 BOM**：Lua 解析器不识别 BOM，带 BOM 会让首行变成 `\uFEFFaddappid(...)` 而整个文件解析失败。而 PS 5.1 的 `Set-Content -Encoding UTF8` **会写 BOM**，所以只能用 `[IO.File]::WriteAllText(..., UTF8Encoding($false))`。本次实测 6 个本地 lua 全部 `BOM=False`，且中文注释是合法 UTF-8 三字节序列（首行 `-- OpenSteamTool unlock script`）。

**⑪ 只声明有密钥的 depot（原逻辑）**：无密钥的 depot 强行写进 lua 会让 Steam 尝试挂载一个无法解密的内容，表现为「安装大小 0 B」甚至整个 app 安装失败。

本次把这条逻辑修正了：原来在**过滤后为空**时会「回退为声明全部」，那等于把已知有害的那一步执行到底。现在改为**明确失败并中止**（除非显式 `-Yes` 强行尝试）。

### 3.4 DLL 劫持这一段（有证据的部分）

Windows 的 DLL 搜索顺序里，**程序所在目录优先于 system32**。Steam 会从自己目录加载 `dwmapi.dll` 与 `xinput1_4.dll`，于是这两个文件被替换成「代理 DLL」：它们转发真正的系统调用，同时在自己被加载时检查宿主进程名，只有 `steam.exe` 才继续 `LoadLibraryA("OpenSteamTool.dll")`。

**本次实测的运行时证据**（这是判断「hook 到底有没有生效」最硬的一条）：

```
steam.exe (PID 66400, 启动于 22:42:26) 已加载模块：
  OpenSteamTool.dll   D:\steam\OpenSteamTool.dll          1446400 B
  XInput1_4.dll       D:\steam\XInput1_4.dll              122880 B   ← 注意大小写
  xinput1_4.dll       C:\WINDOWS\system32\xinput1_4.dll
  dwmapi.dll          D:\steam\dwmapi.dll                 109568 B
```

注意**同一个进程里同时存在** Steam 目录的代理 `XInput1_4.dll` 和 system32 的系统 `xinput1_4.dll`。这说明代理确实被加载了、且没有挤掉系统库的正常使用。

**签名缓存**：`D:\steam\opensteamtool\` 下三类 toml，文件名是 Steam 客户端二进制的 SHA256：

```
pattern\steamclient\caba4826aa350103...9fee.toml   3000 B   写入于 22:42:30
ipc\steamclient\caba4826aa350103...9fee.toml        934 B   写入于 22:42:30
pattern\steamui\cb387adefbbac64a...9278.toml       1307 B   写入于 22:42:30
```

Steam 启动于 22:42:26，三个文件写入于 22:42:30 —— **时间戳与启动时间吻合，证明 hook 在本次启动中完成了签名扫描并落盘**。内容是对应版本的函数偏移签名；Steam 每次更新客户端，这个 hash 就变，工具需要重新扫描（存在一个短暂的失效窗口，扫描失败时 DLL 会打印 `OpenSteamTool - Missing Signatures` / `Unsupported Steam Version`）。

### 3.5 上游 manifest request code 服务（本次修正了一处长期误读）

DLL 里内嵌了完整的三个候选端点。在 `OpenSteamTool.dll` 偏移 1004888 处抽出的字符串序列是：

```
https://manifest.opensteamtool.com/%llu      ← "opensteamtool"
http://gmrc.wudrm.com/manifest/%llu          ← "wudrm"
https://manifest.steam.run/api/manifest/%llu ← "steamrun"
```

所以 `opensteamtool.toml` 里那行 `url = "steamrun"` 不是「某家叫 steamrun 的服务」，而是**选择第三组端点**（`https://manifest.steam.run/api/manifest/<code>`）。此前文档只把它记作「实测 200 的那个字符串」，现在映射关系是确定的。

### 3.6 编码契约（这是本项目真正的「地基」）

同一套流程里五种文件、三种编码要求，互相冲突：

| 文件 | 编码 | 如果搞错会怎样 |
|---|---|---|
| `bootstrap.ps1` | 纯 ASCII，无 BOM | PS 5.1 按 ANSI 代码页解码，中文变乱码字节 → `The term '...' is not recognized` |
| `g\<appid>.ps1` | 纯 ASCII，无 BOM | 同上 |
| `install.ps1` | UTF-8 **带 BOM** | 无 BOM 时 PS 5.1 按 GBK 解码中文注释 → 语法错误 |
| `config\lua\*.lua` | UTF-8 **无 BOM** | 带 BOM → 首行 `\uFEFFaddappid(...)`，Lua 解析失败 |
| `opensteamtool.toml` | UTF-8 **无 BOM** | BOM 不是合法 TOML 起始字符 |

**两个已知的「工具陷阱」**（本次亲手踩到）：

1. `Set-Content -Encoding UTF8` 会写 BOM，不能用于 lua / toml；必须 `WriteAllText(..., UTF8Encoding($false))`。
2. **编辑类工具会抹掉已有 BOM**。本次用脚本化编辑时就复现了：第一次改完 `install.ps1`，BOM 掉了，随后直接用 `& script.ps1` 执行立即出现中文乱码性语法错误（`表达式或语句中包含意外的标记`）。规避办法是**不用 edit 工具改带 BOM 的文件**，或者改完立即补 BOM 并复验。

**验证片段**（建议固化成流程的一部分）：

```powershell
$b = [IO.File]::ReadAllBytes($path)
'BOM=' + (($b[0] -eq 239) -and ($b[1] -eq 187) -and ($b[2] -eq 191))
'非ASCII字节数=' + (@($b | Where-Object { $_ -gt 127 }).Count)
```

**一个容易误判的现象**：用 PS 5.1 的 `Get-Content` 读这些 UTF-8 无 BOM 的 lua，中文注释会显示成 `瀵嗛挜` 之类的乱码。那是**读的一方**用 GBK 解码造成的显示问题，文件本身是好的（本次用字节级校验确认过）。不要因为控制台乱码就去「修编码」。

---

## 四、Steam 侧的运行日志：怎么判断「到底成没成」

四个判据，按可靠度排序（本次都实际跑过）：

| 判据 | 命令 | 本次实测结果 |
|---|---|---|
| **库里有封面**（最可靠） | `Select-String steamui_librarycache.txt -Pattern <appid>` | 博德之门 3 **9 处命中**，含 `Saved downloaded file: ...1086940/library_600x900.jpg` |
| 进程加载了载荷 | 见 3.4 | `OpenSteamTool.dll` + 两个代理 DLL 均在 steam.exe 模块列表 |
| 缓存时间戳 == 启动时间 | `Get-ChildItem D:\steam\opensteamtool -Recurse` | 22:42:30 vs 启动 22:42:26 ✓ |
| depot 挂载 | `content_log.txt` | 本次日志未见 mounted depot 行 |

**博德之门 3 的现状（本次实测结论）**：`librarycache` 显示 22:32:29 已下载库封面（9 条），说明**游戏已经成功入库**；但 `appmanifest_1086940.acf` 不存在（库内 6 个 manifest：`1862520`/`228980`/`3590`/`431960`/`814380`/`501300`），即**尚未开始下载**。而磁盘剩余（D 64 GB / E 43 GB）都远小于 145.75 GB —— 这就是为什么必须先把磁盘预检做出来。

**另一个值得记录的日志噪声**：`content_log.txt` 里反复出现

```
AppID 7 failed to update ownership ticket (Access Denied)
```

这是 Steam 客户端自身的常规失败（AppID 7 是 Steam 客户端本体），与解锁无关。看到它不用紧张。

---

## 五、覆盖率与可行性边界（实测汇总）

| AppID | 游戏 | depot 覆盖 | 体积 | 备注 |
|---|---|---|---|---|
| 814380 | 只狼 | 5/6 | 13.87 GB | 缺 512 B 空占位；**已入库**（appmanifest 实测 14.96 GB） |
| 1091500 | 赛博朋克 2077 + 往日之影 | 完整 | — | 已入库 |
| 292030 | 巫师 3 | 53/53 | 54.72 GB | 已入库 |
| 1245620 | 艾尔登法环 + 黄金树幽影 | 7/8 | 69.2 GB | 缺 0.91 GB（全局表里是空值） |
| 524220 | 尼尔：机械纪元 | 9/9 | 40.34 GB | 已入库 |
| 2050650 | 生化危机 4 | 31/31 | 62.81 GB | 已入库 |
| 1086940 | 博德之门 3 + 2 DLC | **53/53（含密钥）** | 145.75 GB | **已入库，未安装**（磁盘不足） |

**两类硬边界**：

1. **Denuvo**。它不靠密钥解决，需要 `setAppTicket` + `setETicket`，而票据必须来自**真正拥有该游戏的账号**且有效期约 30 分钟（过期报错 `88500005`）。这意味着 Denuvo 游戏在技术上等价于「需要养一个正版账号池做实时签发」——这正是「离线版」商业模式的本质。已知名单（剑星、黑神话悟空、死亡空间、育碧全线、部分日厂大作）无法通过公开资源绕过。
2. **超新作**。社区清单库滞后数周到数月。注意剑星（2025-06 发售）的**密钥其实已经在全局表里（3/3）**，真正卡住它的只有 Denuvo —— 也就是说「不可行」的原因常常被归错。

---

## 六、Bug 与隐患清单（按严重度）

### 6.1 本次已修复

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 1 | **无密钥时「回退为声明全部」** | 过滤后为空就 `$plan = $depots`，等于强行挂载无法解密的 depot | 改为明确失败 + 中止，除非显式 `-Yes` 强行实验 |
| 2 | **卸载不还原组件** | `Do-Uninstall` 只删 DLL，Steam 目录留下被换过的同名 DLL；且库缓存清理判据（`Length < 4096`）基本不会命中 | 组件改为「备份→还原/删除 + 哈希判定」，认不出的原件先归档；清理判据收紧并如实说明它是启发式的 |
| 3 | **磁盘空间完全不检查** | 无 | 新增 `Get-DiskPrecheck` + `$KNOWN_SIZE` 实测表（见 3.3⑨） |
| 4 | **全局密钥表每次重下 16 MB** | 无缓存 | 新增 7 天本地缓存 `dist-package\depotkeys-cache.json` |
| 5 | **体积语义错误** | 把 depot 求和（449.4 GB）当成下载量 | 输出明确标注「不是真实下载量」，实际值走 `$KNOWN_SIZE` |
| 6 | **DLC 的 appinfo 被请求两次** | 取 depot 与取密钥各调一次 | 用 `$dlcPlans` 复用 |
| 7 | **组件写入无异常处理** | 杀软拦截 / 写入失败会直接抛错中断 | try/catch + 写入后复校哈希 + 询问出口 |
| 8 | **固定等 6 秒等 Steam 退出** | 无谓延迟 | 改轮询（最多 10 秒） |
| 9 | **缺管理员权限时无提示** | 后续「拒绝访问」不可解释 | 预检阶段明确告知 |
| 10 | **无干跑能力** | 想验证只能真跑 | 新增 `-DryRun`：不下载、不写盘、不启动，只打印将要生成的内容 |
| 11 | **缓存与备份路径依赖 `$PSScriptRoot`** | `irm\|iex` 场景下该变量为空 → `Join-Path` 抛异常 → 被外层 `catch` 静默吞掉 | 缓存改到 `%LOCALAPPDATA%\ost-cache\`，改为原文件缓存；备份目录改固定候选路径（详见 3.3⑧） |
| 12 | **远端拉取的 `install.ps1` 无任何完整性校验** | `iex` 不受策略约束，替换了也不知道 | bootstrap 内钉住期望 SHA256，唯一维护入口 `sync-hashes.ps1`（见 6.3） |

**`-DryRun` 的价值当场兑现**：第一次跑就抓出两个真实缺陷——「`-DryRun` 仍然写了 `opensteamtool.toml`」和「`Get-DepotPlan` 返回的对象没有 `Size` 属性，导致 `Measure-Object -Property Size` 抛错」。这两个在真跑时都会造成误导性结果（前者悄悄改了用户的配置，后者让脚本中途崩在体积统计上）。

### 6.2 仍未解决（按风险分级）

| 风险 | 触发条件 | 影响 | 现状 |
|---|---|---|---|
| **`install.ps1` 曾无完整性校验** | 域名/仓库被劫持，或代理注入 | 被喂一段任意 PowerShell 并执行（`iex` 天然无策略约束） | **本次已修复**：bootstrap 内钉住期望 SHA256，唯一维护入口 `sync-hashes.ps1`；配合换源重试（详见 6.3） |
| **CDN 缓存滞后** | 刚发布后 CDN 仍在发旧副本 | 校验拦住旧副本 → 命令报错 | 已缓解：换源重试（实测 raw / gh-proxy / ghproxy 三家同时是旧副本，第 4 个源 jsDelivr 命中） |
| **单点：`bootstrap.ps1`** | Pages CDN 抖动（本次实测过一次 503）或 CNAME/证书异常 | 所有游戏的命令同时失效 | 未解决；建议 `install.ps1` 也提供 launcher 直连兜底 |
| **多账号无法隔离** | 大号登录 | 伪造声明对所有账号生效；`setManifestid` 会强制 manifest 版本，可能与官方 build 冲突 | `toggle-unlock.ps1` 已存在且可用（读注册表 `ActiveProcess\ActiveUser`，实测值 700388284），但**未接入主流程** |
| **杀软拦截** | 写入两个同名系统 DLL | 文件被隔离 → 组件缺失 → hook 不生效，表现为「什么都没发生」 | 仅在写入后复校哈希时能发现；仍建议用户自行加排除项 |
| **`dwmapi.dll` 属 KnownDLLs** | 覆盖 + 后续删除 | 删除动作可能被系统拒绝（表现为「文件正在使用」） | 已改为容错并给出提示，但无法自动解决 |
| **Steam 客户端更新** | 客户端二进制变化 | 签名缓存失效，需要重扫；扫描失败期解锁无效 | 工具自带重扫；建议在命令输出里提示「若立刻无效，重启一次 Steam 等它扫完」 |
| **Pages 构建延迟** | 发布新 launcher 后立刻访问 | 短暂 404 | 未解决（等待 20-30 秒即好） |
| **`gh-proxy.com` / `ghproxy.net` 属第三方** | 上游被投毒 | bootstrap 取到被篡改的 `install.ps1` | 与「install.ps1 无校验」是同一个洞；校验补上后即缓解 |

### 6.3 关于完整性校验的两难（含一次真实教训）

**诱惑**：bootstrap 用 `iex` 执行远端拉下来的 `install.ps1`。`iex` 不受 ExecutionPolicy 约束 —— 这既是它能在一台 `Restricted` 策略的新机器上跑起来的原因，也意味着**一个被换掉的 `install.ps1` 会被毫无察觉地执行**。补法看起来很简单：在 bootstrap 里钉住 `install.ps1` 的 SHA256。

**代价**：只要改了 `install.ps1` 而忘了同步 bootstrap 里的哈希，**所有用户当场装不上**。这个风险比它防住的威胁更可能发生。

**第一次上线时的真实结果**（比任何推演都有说服力）：哈希同步了、两个文件都上传了，但**第一次真跑仍然被拦住**——

```
attempt 1/2 : raw.githubusercontent.com/.../install.ps1
              stale copy (5C7FC1E4E77E...), trying next source
attempt 1/2 : gh-proxy.com/...
              stale copy (0B7C8E724C23...), trying next source
attempt 1/2 : ghproxy.net/...
              stale copy (000102659032...), trying next source
[+] Mirror used : https://cdn.jsdelivr.net/gh/jiangqr2024/steam-unlock@main/install.ps1
[+] SHA256      : ED45C291370F...
[+] Integrity   : matches the hash pinned in this file
```

原因是 **`raw.githubusercontent.com` 在推送后仍有约 5 分钟的缓存**，两个代理前缀也各自带着旧副本。如果校验写成「不匹配就中止」，这一条命令就会被自家校验锁死——用户看到 `expected/got` 两串哈希，完全无从下手。

最终采用的策略由三件事组成：

1. **校验放在下载循环内部**：哈希不匹配的含义是「这个源是旧的」，不是「有人在攻击」。换下一个源继续试，并把 `stale copy` 明明白白打印出来。
2. **只有当所有源都不可用或都给不出验证副本时才拒绝执行**，同时区分三种失败原因（全是旧副本 / 响应过小 / 全无响应），并给出「等 5-10 分钟再跑」的具体建议 —— 而不是甩两串哈希给用户。
3. **发布顺序固定**：先 `sync-hashes.ps1`，再依次上传 bootstrap、install。`sync-hashes.ps1` 每次都会回读校验，写错会立刻报错。

顺带一句：这套机制防的是**传输与托管环节被篡改**。要防「你自己发的就是坏的」，靠的是 Authenticode 代码签名，而这需要证书——目前没有，也不该假装有。

---

## 七、针对实际应用的改善建议

### P0（不做会直接卡住真实使用）

1. **磁盘空间引导**（已实现检测）。博德之门 3 需要 145.75 GB，本机 D 64 GB / E 43 GB 都不够。建议在命令输出末尾直接给出「建议装到哪块盘 / 至少释放多少空间」。
2. **把 `toggle-unlock.ps1` 接进主流程**。至少提供一个 `-Profile` 开关，或者安装完成后提示一句「检测到多个账号，是否启用账号隔离」。理由很实在：大号有正版艾尔登法环时，lua 的 `setManifestid` 会与官方 manifest 叠加。
3. **发布流程脚本化**。当前「生成 `g\<appid>.ps1`」与「上传无扩展名 `<appid>`」是两件事（后者要手工做），这是发布不一致的温床。应该让 `publish-game.ps1` 一次把两份都生成并上传。

### P1（显著提升可用性）

4. **launcher 直连兜底**：`g\<appid>.ps1` 里在 `bootstrap` 失败时，退化为直接 `iex (irm install.ps1)`，绕开单点。
5. **密钥结果本地缓存**：同一 appid 24 小时内不重扫 13 个镜像（当前每次约 10-15 秒）。
6. **镜像健康度记录**：把命中率写进本地文件，动态调整 `$MIRRORS` 顺序（现在是硬编码）。
7. **接入 `appaccesstokens.json`**（182295 B，`appId → accessToken`）：DLL 支持 `addtoken`，对部分需要访问令牌的场景可能有意义 —— 前提是先验证「哪些游戏真的需要它」，不要凭猜测加进去。
8. **输出可读性**：把「共取到 180 个密钥」这种噪声改成「需要 53 个，已获取 53 个（来源 3 处）」。

### P2（长期）

9. **把配置从「全局 lua 目录」升级为「账号感知」**：唯一可靠的做法仍是外部守护进程切换文件（Lua API 没有读 SteamID 的能力，这条路走不通）。
10. **文档化「失败说明书」**：把 6.1/6.2 里的每一项写成「症状 → 三秒排查命令」。用户真正需要的不是原理，是「现在该按哪个键」。
11. **`-DryRun` 纳入发布前自检**：`publish-game.ps1` 生成后自动跑一次 `install.ps1 -AppId X -DryRun`，确保目标 AppID 的 lua 能生成、覆盖率诊断与 lua 内容一致。

---

## 八、本次做的验证（可复现清单）

| 验证项 | 手段 | 结果 |
|---|---|---|
| 组件哈希 | `Get-FileHash` vs Release 常量 | 三个 DLL 全部一致 |
| hook 是否真加载 | `(Get-Process steam).Modules` | `OpenSteamTool.dll` + 代理双 DLL 均在 |
| 签名缓存时效 | 文件时间戳 vs 进程启动时间 | 22:42:30 vs 22:42:26 |
| lua 编码 | 逐字节读 | 6 个文件全部 BOM=False；中文为合法 UTF-8 |
| 入库判据 | `steamui_librarycache.txt` | 博德之门 3 封面已下载（22:32:29） |
| 安装状态 | `appmanifest_*.acf` | 无 1086940 → 未安装 |
| 远端文件与本地一致 | SHA256 比对 | bootstrap 一致（`D63642B5...`） |
| 三文件名拼法 | 三个仓库 live 请求 | 三种全部 200 |
| DLL 内嵌上游 | 二进制字符串 | 三个端点映射，含 `manifest.steam.run` |
| 密钥覆盖率 | DryRun + 13 镜像 + 全局表 | BG3 53/53 有密钥 |
| 全流程安全 | `-DryRun` | 零副作用（toml 哈希未变、lua 未改、无备份目录新增、Steam 未被关） |
| **哈希校验正例** | 沙箱里把 bootstrap 的 URL 换成假文件，内容与哈希一致 | 校验放行，一路执行到 install 主体 |
| **哈希校验反例** | 同上，但给假文件追加一个字节 | 明确拦截，打印 expected/got，**未执行 install** |
| **换源重试** | 真实入口连跑 | raw / gh-proxy / ghproxy 三家旧副本被自动跳过，jsDelivr 命中 |
| **缓存命中（远程 iex 上下文）** | 真实入口连跑 | 提示「使用本地缓存的全局密钥表」，53/53 有密钥 |
| **两种执行上下文结果一致** | 本地 `.\install.ps1` 与远程 `irm\|iex` 产出逐字比对 | 均为 53 个 depot；此前不一致的 bug 已修 |

### 8.1 端到端真实运行的最后状态（本次收尾）

```
入口      : irm https://jiangqr2026.xyz/1086940|iex   （真实用户命令，非本地执行）
组件      : 三个 DLL 已存在且哈希与官方 Release 一致 → 跳过下载
磁盘预检  : D:\ 剩余 63.8 GB < 实测下载量 145.8 GB → 明确警告
密钥      : 53/53（bruh-hub +36、luomojim +127、全局表缓存 +17）
生成的 lua: 7564 字节、BOM=False、56 个 addappid、53 个 setManifestid
Steam     : 已启动
```

`1086940.lua` 回到 7564 字节、与最初配置完全同尺寸，说明本次加固**没有改变输出语义**——改的都是路径解析、失败处理、缓存与预检这些外围环节。

---

## 九、结论

这套工具链的设计意图是清晰的：**在「形态与灰产对齐」和「载荷可审计」之间取一个明确的点**。本次重新分析确认了它在这两点上确实成立——二进制来自官方 Release 且逐个校验哈希、落盘配置全明文、不碰杀软、不注入游戏进程。

真正的风险不在「它做了什么」，而在两处：

一是**完整性链条中间有一环是空的**（远端拉下来的 `install.ps1` 在 bootstrap 里没有校验，而 `iex` 天然不设防）。这一环已补上机制，代价是发布必须走 `sync-hashes.ps1`。

二是**用户侧的账号与磁盘现实**（大号有正版、D 盘装不下 145 GB）。这类问题不是代码 bug，但决定用户第二天会不会用——所以账号隔离接入与磁盘引导应当排在功能扩展之前。

至于那份「已修复 BUG 清单」里最重要的一条，本次分析完全支持它：**三次重大误判都源于用假设代替实测**。所以本报告里所有数字都附了获取方式，任何一条都能被推翻——**被推翻比被相信更有价值**。

---

## 附录 A：关键路径速查

| 用途 | 路径 |
|---|---|
| Steam 安装目录 | `D:\steam` |
| 游戏库 | `E:\SteamLibrary`（另有 `D:\steam\steamapps`） |
| lua 配置 | `D:\steam\config\lua\` |
| 工具配置 | `D:\steam\opensteamtool.toml` |
| 签名缓存 | `D:\steam\opensteamtool\{pattern,ipc}\{steamclient,steamui}\<sha256>.toml` |
| 安装备份 | `C:\Users\DELL\AppData\Local\ost-backup\<yyyyMMdd-HHmmss>\` |
| 原始 DLL 备份 | `D:\steam-unlock-cli\backup\original-steam-dlls\` |
| 全局密钥表缓存 | `C:\Users\DELL\AppData\Local\ost-cache\depotkeys.json` |
| 项目根 | `D:\steam-unlock-cli\dist-package\` |

## 附录 B：常用命令

```powershell
# 干跑（不下载、不写盘、不启动 Steam）—— 发布前的必做一步
.\install.ps1 -AppId 1086940 -DryRun

# 发布一个新游戏（生成 + 上传 + 诊断）
.\publish-game.ps1 -AppId <appid>

# 改完 install.ps1 后：先同步哈希，再上传 bootstrap 与 install（顺序不能反，反了会短暂自锁）
.\sync-hashes.ps1
.\sync-hashes.ps1 -Verify    # 发布后回读确认

# 卸载（还原组件 + 清 lua/toml + 清库缓存）
.\install.ps1 -Uninstall

# 账号隔离（已有，未接入主流程）
..\toggle-unlock.ps1 -Action Status
..\toggle-unlock.ps1 -Action Watch

# 编码体检（改了任何脚本之后都跑一次）
Get-ChildItem . -File | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    '{0,-20} BOM={1,-5} 非ASCII={2}' -f $_.Name, (($b[0] -eq 239) -and ($b[1] -eq 187)), (@($b | Where-Object { $_ -gt 127 }).Count)
}
```

## 附录 C：故障速查

| 症状 | 最可能原因 | 先看什么 |
|---|---|---|
| 库里没有游戏 | lua 带 BOM / Steam 未重启 | lua 字节头 + `steamui_librarycache.txt` |
| 库里没有游戏（lua 正常） | 库 UI 刷新延迟（1-2 分钟） | 等一会儿再看 librarycache |
| 安装大小 0 B | depot 密钥缺失或过度声明 | `.\publish-game.ps1 -AppId X -NoUpload` 看诊断 |
| 安装大小偏小 | DLC 未声明 | lua 里有没有 `addappid(<dlcId>)` |
| 命令报执行策略错误 | 用了 `& $DST` | bootstrap 是否为 `iex (Get-Content ... -Raw)` |
| 中文乱码 | 文件编码与读取方不匹配 | 对照第三章编码契约（注意：可能只是 `Get-Content` 的显示问题） |
| hook 无反应 | 组件被杀软隔离 | `Get-Process steam).Modules` 里有没有 OpenSteamTool.dll |
| 上游拉不到 manifest | toml 的 `url` 值失效 | 换 `steamrun` / `opensteamtool` / `wudrm` 试 |
