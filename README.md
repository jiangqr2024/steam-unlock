# Steam 解锁一键安装包（自建版）

自己维护的一条命令安装方案。形式和市面上那类「CDK 激活」脚本一致，但把灰产脚本里所有危险设计全部拆掉了。

---

## 一、和灰产脚本的技术差异

| 项目 | 灰产脚本（`irm steam.work\|iex`） | 本方案 |
|---|---|---|
| 分发 | 一条指向短域名的远程执行，内容不可预知 | 脚本明文托管在公开仓库，可先读再跑 |
| 二进制来源 | 自有打包，加壳 + 内存加载，不可审计 | OpenSteam001/OpenSteamTool **官方 Release** |
| 完整性校验 | 无 | 压缩包 + 三个 DLL 逐个 **SHA256 硬校验** |
| 配置 | 服务端下发、加密 | 本地明文 lua / toml，可随时打开 |
| 系统 DLL 劫持 | 劫持 `hid.dll` + `simulator.dll` 中转规避检测 | 用官方设计的 `dwmapi.dll` / `xinput1_4.dll` 代理 |
| 杀软 | **主动把 Steam 路径加入 Defender 白名单** | 不碰任何杀软设置 |
| 行为可见性 | 静默 | 每一步打印，写入前列出全部动作并确认 |
| 回退 | 无 | 自动备份原文件，内置 `-Uninstall` |
| 数据回传 | 服务端记录你的 SteamID 与购买 | 无服务端，不收集任何信息 |

**保留的只有「一条命令」这个形式**，内核换成了可审计的开源组件。

---

## 二、文件

```
dist-package/
├── install.ps1      主脚本：安装 / 卸载（UTF-8 BOM，支持 PS 5.1 与 7）
├── bootstrap.ps1    引导脚本：给 irm|iex 用（纯 ASCII、无 BOM，可一眼读完）
└── README.md        本文件
```

`install.ps1` 独立可用，不依赖 `bootstrap.ps1`。

---

## 三、部署（GitHub 公开仓库）

1. 建一个**公开**仓库，把 `install.ps1` 和 `bootstrap.ps1` 传到根目录。
2. 编辑 `bootstrap.ps1`，把开头的 `<USER>` 和 `<REPO>` 换成你的：

```powershell
$BASE = 'https://raw.githubusercontent.com/<你的用户名>/<你的仓库>/main'
```

3. 记下两个 raw 地址：

```
https://raw.githubusercontent.com/<USER>/<REPO>/main/install.ps1
https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap.ps1
```

打包发布时记得同步更新 `install.ps1` 里的 `$REL_TAG` / `$REL_SHA` / `$DLL_SHA`（见第七节）。

**不想用 GitHub**：局域网起个 HTTP 服务即可，把上面 URL 换成 `http://<内网IP>:<端口>/...`。

---

## 四、分发命令

**方式 A：`irm | iex`（推荐 —— 操作方式与市面商品一致）**

```powershell
irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap.ps1 | iex
```

`Win+X` 打开终端 → 粘贴 → 回车，一条命令完成。和那类「CDK 激活」商品的操作方式相同。

bootstrap 内部会：在 5 个镜像间轮询，把完整的 `install.ps1` 下载到磁盘，打印实际使用的镜像、路径、大小与 SHA256，然后再执行它。你随时可以 `notepad` 打开那个文件核对内容。

**方式 B：先落盘再执行（不依赖 bootstrap.ps1，少一层网络）**

```powershell
$u='https://raw.githubusercontent.com/<USER>/<REPO>/main/install.ps1'; $f="$env:TEMP\ost-install.ps1"; irm $u -OutFile $f; & $f
```

**方式 C：带参数，免交互**

```powershell
$u='https://raw.githubusercontent.com/<USER>/<REPO>/main/install.ps1'; $f="$env:TEMP\ost-install.ps1"; irm $u -OutFile $f; & $f -AppId 814380 -Yes
```

### 稳定性：多镜像 fallback

`raw.githubusercontent.com` 在部分网络下不可达。bootstrap 按顺序尝试下列镜像，每个重试 2 次，任一成功即停止：

| 顺序 | 源 | 本机实测耗时 |
|---|---|---|
| 1 | `raw.githubusercontent.com` | 1311 ms |
| 2 | `gh-proxy.com` | 6443 ms |
| 3 | `ghproxy.net` | 7215 ms |
| 4 | `cdn.jsdelivr.net` | 6660 ms |
| 5 | `fastly.jsdelivr.net` | 7209 ms |

五个源实测返回内容一致（14933 字节）。`raw.githack.com` 返回 429 限流，已剔除。

**注意**：jsDelivr 对分支内容的缓存约 12 小时，刚更新仓库后它可能仍返回旧版 `install.ps1`。它排在最后顺位，实际影响很小。

> 为什么不直接 `irm install.ps1 | iex`：主脚本是 UTF-8 BOM，`iex` 会把 BOM 粘到首条命令上导致解析失败（实测报错 `无法将"﻿Write-Host"项识别为 cmdlet`）。而 BOM 是 PS 5.1 正确读取中文的必要条件。所以主脚本必须先落盘——bootstrap 用二进制方式下载，BOM 与文件哈希都完整保留（已验证：下载后前 3 字节仍为 239,187,191，哈希与源文件一致）。

---

## 五、使用

运行后脚本会：

1. 定位 Steam 目录（注册表优先，失败则探测常见路径）
2. 询问 AppID（或从 `$env:OST_APPID` 读取）
3. **列出全部将要执行的动作并要求确认**（`-Yes` 可跳过）
4. 关闭 Steam，下载官方 Release 并校验 SHA256
5. 备份并写入三个组件
6. 写入 `opensteamtool.toml`（上游固定为实测可用的 `steamrun`）
7. 从 `api.steamcmd.net` 解析 depot 结构，从公开清单库取解密密钥，生成 `config\lua\<appid>.lua`
8. 重新启动 Steam

AppID 就是商店页 URL 里的数字：

```
https://store.steampowered.com/app/814380/   ->  814380
```

**参数**

| 参数 | 说明 |
|---|---|
| `-AppId <int>` | 目标游戏 AppID，省略则交互输入 |
| `-SteamPath <path>` | 手动指定 Steam 目录 |
| `-Uninstall` | 卸载：删除组件、配置、lua，并清理各账号库缓存 |
| `-NoRestart` | 不自动启动 Steam |
| `-Yes` | 跳过确认提示 |

### 5.1 一游戏一命令（用户无需输入 AppID）

用 `publish-game.ps1` 为单个游戏生成专用启动脚本，内嵌 AppID，放进仓库的 `g/` 目录：

```powershell
.\publish-game.ps1 -AppId 814380
```

它会输出一份**密钥覆盖率诊断**（见 5.2），并打印可直接分发的命令：

```
irm https://jiangqr2024.github.io/steam-unlock/g/814380.ps1 | iex
```

生成的 `g\<appid>.ps1` 只有十几行，内容完全可读：

```powershell
$env:OST_APPID = '814380'
$env:OST_YES   = '1'
iex (Invoke-RestMethod 'https://jiangqr2024.github.io/steam-unlock/bootstrap.ps1')
```

它只设置两个环境变量，然后调用同一套 bootstrap/install 流程——**没有任何预置的密钥或二进制**，全部在运行期从公开源拉取。再加游戏就再跑一次，多份启动脚本互不影响。

### 5.2 密钥不全怎么办

解锁一个游戏需要两样东西，性质完全不同：

| 需要的东西 | 是否公开 |
|---|---|
| depot 列表 + manifest gid | 公开，`api.steamcmd.net` 直接可查 |
| **每个 depot 的 AES 解密密钥** | **不公开**，只能来自真正拥有该游戏的账号 |

密钥是稀缺资源，社区在 GitHub 上以「每个 appid 一个分支」的仓库形式共享。`publish-game.ps1` 每次都报告真实覆盖率：

```
[+] 密钥来源（多镜像并集）:
       TOP-01/ManifestAutoUpdate (+5)

     appinfo depot : 6
     有密钥        : 5
     缺密钥        : 1

[+] 有密钥的 depot（按体积降序）:
       depot 814382     13.87 GB
       depot 814381     64.9 MB

[!] 缺密钥的 depot:
       depot 814384     512 B        空占位（<1MB），可忽略

[+] 主内容有密钥：最大 depot 814382 = 13.87 GB
```

**判据是「最大的那个 depot 有没有密钥」**——本体主内容总在最大的 depot 里。三种结论：

**① 缺失项是空占位或 DLC** —— 不影响本体，直接可用。
只狼就是这种：缺 `814384`（512 字节占位），实测能完整安装运行。

**② 主内容有密钥，次要内容缺失** —— 本体能玩，可能少部分资源。
艾尔登法环：`1245621 = 51.26 GB`（本体）有密钥，缺 2 个较小的内容 depot 与 4 个 DLC。

**③ 最大的 depot 就缺密钥** —— 下载风险高，建议放弃。

**补救途径**（按可行性排序）：

**多镜像并集** —— 已内置。脚本遍历 8 个明文格式仓库取并集去重（不同仓库收录的 depot 并不一致）。只狼就是靠这个从 4 个补到 5 个，多出的 `1039230` 是 967.9 MB 的附加内容。

**警惕加密格式仓库** —— `repositories.json` 里标为 `Encrypted` 的仓库（`sean-who`、`Fairyvmos` 等）虽然 `DecryptionKey` 条目数更多，但值是 **76+ 字符的加密格式**，而 OpenSteamTool 要求恰好 64 字符、否则直接丢弃。早期版本曾把它们排在最前，导致正则一条都匹配不上却毫无提示。现在脚本放宽正则、再按长度过滤，遇到这类仓库会明确报告「加密格式 N 个，已跳过」。

**自行提取（最可靠）** —— 若账号**确实拥有**该游戏，密钥可从本地读取：用 Steam 装过该游戏后，`<Steam>\config\config.vdf` 对应 depot 段会写入 `DecryptionKey`。项目里的 `steam-unlock-cli.ps1 -Mode Keys` 就是做这个的。

**等待社区更新** —— 新发售游戏通常滞后几天到几周。

**手动补进 lua** —— 拿到密钥后直接改 `<Steam>\config\lua\<appid>.lua`：

```lua
addappid(1245622, 0, "在此填入 64 位十六进制密钥")
```

改完热重载生效，无需重启 Steam。

---

## 六、卸载

```powershell
& "$env:TEMP\ost-install.ps1" -Uninstall
```

或本地运行 `.\install.ps1 -Uninstall`。

会删除三个 DLL、`opensteamtool.toml`、`config\lua\`、`opensteamtool\`，并清理各账号 `librarycache` 里的解锁残留，使游戏从库中消失。原文件备份保留在 `%LOCALAPPDATA%\ost-backup\<时间戳>\`。

---

## 七、依赖的外部服务

全部为公开服务，无自有后端：

| 用途 | 地址 |
|---|---|
| 组件下载 | `github.com/OpenSteam001/OpenSteamTool/releases` |
| depot 结构 | `api.steamcmd.net/v1/info/<appid>` |
| depot 密钥 | GitHub 公开清单库（9 个镜像，逐个尝试） |
| manifest request code | `manifest.steam.run`（实测 `opensteamtool` 返 403、`wudrm` 返 503） |

**升级组件版本时**，改动 `install.ps1` 顶部的常量：

```powershell
$REL_TAG  = '1.4.8'
$REL_SHA  = '966654604D258D5D5383E72FEC616DF7957BF86F760C67EEB3D0E18CD882C710'   # Release zip 的 SHA256
$DLL_SHA  = @{ 'dwmapi.dll' = '...'; 'xinput1_4.dll' = '...'; 'OpenSteamTool.dll' = '...' }
```

三个 DLL 的期望哈希取自 Release 包内实际文件，脚本会在落盘前逐个比对，任何一个不匹配就中止且不改动任何文件。

---

## 八、已知限制

**无密钥 depot 会被过滤。** 清单库未收录密钥的 depot 不写进 lua——强行声明会让 Steam 尝试挂载却拿不到解密密钥，导致整个 app 安装失败。实测只狼在 appinfo 里有 6 个 depot，清单库只提供 4 个密钥，脚本最终写 4 个，与手动验证成功的配置一致。

**清单库覆盖率有限。** 冷门游戏、新发售游戏可能查不到 `Key.vdf`，此时脚本会提示并只写 `addappid(本体)`，能否下载取决于工具上游是否收录。

**Denuvo 游戏无效。** 授权 token 由服务端签发，本地伪造拿不到，需要额外的 `setAppTicket` / `setETicket`（票据必须有正版来源）。

**联机游戏有封号风险。** 本方案不做任何检测规避，解锁的游戏只应离线或单机游玩。不要用它启动受 VAC / EAC / BattlEye 保护的游戏。

**Steam 更新后需重新拉取 hook 签名。** 工具每次启动会计算 `steamclient64.dll` / `steamui.dll` 的 SHA256 并向上游取匹配的签名，上游未发布对应版本时会弹窗提示并只禁用相关 hook。

---

## 九、编辑注意事项

`install.ps1` 必须是 **UTF-8 with BOM**。PowerShell 5.1 按系统 ANSI 代码页读取无 BOM 文件，中文注释会被解错并破坏语法。很多编辑器（含部分自动化编辑工具）保存时会丢掉 BOM，改动后请确认：

```powershell
$b = [System.IO.File]::ReadAllBytes('D:\steam-unlock-cli\dist-package\install.ps1')
"$($b[0]),$($b[1]),$($b[2])"   # 应为 239,187,191
```

需要补写时：

```powershell
$p = 'D:\steam-unlock-cli\dist-package\install.ps1'
$c = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($true)))
```

`bootstrap.ps1` 相反——必须**无 BOM 且纯 ASCII**，否则 `irm | iex` 会因 BOM 解析失败。
