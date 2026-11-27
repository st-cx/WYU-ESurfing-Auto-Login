# 五邑大学天翼校园自动登录工具

> Windows 开机或从休眠唤醒后，自动检查校园网和代理，右下角显示天翼登录进度。

![Platform](https://img.shields.io/badge/平台-Windows%2010%2F11-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![License](https://img.shields.io/badge/License-MIT-green)
![学校](https://img.shields.io/badge/五邑大学-天翼校园-red)

工具在登录 Windows 后监测宿舍有线校园网，通过广东电信天翼校园客户端（GDPortal / ESurfingClient）完成认证。断线、唤醒或代理恢复时，可从右下角查看正在进行的操作。

**当前正式版为 v1.6.3。** 首次安装下载完整 ZIP。已经安装看门狗的用户可单独下载更新 EXE。[下载正式版及 SHA-256 校验文件](https://github.com/st-cx/WYU-ESurfing-Auto-Login/releases/tag/v1.6.3) · [与 v1.5.0 的功能对照及验证范围](docs/compatibility-v1.6.3.md)

---

## ✨ 功能特性

- **开机和唤醒**　等待校园网网卡取得有效地址，再探测直连和代理。
- **断网自动恢复**：每 20 秒探测一次外网，断网自动重启客户端并点击登录，一直重试到连上为止
- **兼容 Clash / Verge 开机自启**：使用 HTTP 状态码和正文校验，避免 TUN 接住 TCP 连接就误判为在线；认证时同时暂停系统代理/PAC 和 TUN，成功或失败后恢复原设置。Verge Rev 支持服务模式和普通模式的本地管道，无需开启外部控制端口；旧版 Clash for Windows 会临时退出客户端和内核、登录后自动重启。认证过程中才启动 Clash 也会重新检查
- **锁屏后的认证**　天翼能在后台提供登录画面时可发送窗口消息。画面不可识别时继续等待，解锁后重新检查。
- **远程使用**　如果宿舍电脑已经登录 Windows，网络恢复后，随系统启动的远程桌面软件可以继续使用。
- **离校静默**　网卡地址和网关均不匹配校园网特征时，定期复查物理链路。
- **登录按钮卡死也能救**：点击无效时自动"禁用→启用水网卡"（对应手动操作），再重试登录，带 3 分钟冷却防止反复断网
- **Windows 通知**　断线、联网恢复和网卡修复时发送系统通知，显示方式取决于 Windows 通知设置。
- **高 DPI 自适应**　根据天翼窗口尺寸换算点击位置。托盘面板已检查 100%、125%、150%、200% 四档缩放。
- **真人点击校准**：安装时会提示做一次校准——你在客户端上**真实点击一次【登 录】按钮**，工具捕获这次点击的位置并等到网络真的连上（证明点得中）才记录，不靠换算猜；日后界面改版或换电脑，双击 `校准按钮坐标.bat` 再走一遍即可
- **账号选择**　默认使用天翼客户端记住的账号。指定本机默认账号后，每次登录 Windows 有十秒钟选择备用账号，超时使用默认账号。主动保存的备用密码由当前 Windows 用户的 DPAPI 加密。
- **托盘面板**　显示当前阶段和完整提示。长句会换行，内容超过屏幕工作区时可以滚动。点击托盘图标可让面板保持打开，看完再关闭。

![右下角托盘显示校园网已连接](docs/tray-status.png)

## 📋 适用环境

- 五邑大学 校园网（广东电信天翼校园客户端，客户端界面为 533×914 标准窗口）
- Windows 10 / 11，有线连接（宿舍网口）
- 需要管理员权限安装（注册开机自启的计划任务、控制网卡）

> 也适用于其他使用同款"天翼校园客户端（广东电信 GDPortal）"的高校，只要客户端界面一致即可，按钮坐标可在配置里微调。
> **macOS / Linux / 路由器用户**请看下方 [macOS / Linux 用户怎么用](#-macos--linux-用户怎么用) 一节。

## 🚀 快速开始

1. **首次安装**　下载并完整解压 [WYU-ESurfing-Auto-Login-v1.6.3.zip](https://github.com/st-cx/WYU-ESurfing-Auto-Login/releases/download/v1.6.3/WYU-ESurfing-Auto-Login-v1.6.3.zip)。先在天翼客户端完成一次登录并记住账号，然后双击 **`一键安装.bat`**。确认 Windows 管理员提示，按需校准登录按钮。
2. **升级旧版**　完全离线时，用原 Windows 账号双击 [独立更新 EXE](https://github.com/st-cx/WYU-ESurfing-Auto-Login/releases/download/v1.6.3/CampusNet-Update-1.6.3.exe)。也可使用 [更新 CMD](https://github.com/st-cx/WYU-ESurfing-Auto-Login/releases/download/v1.6.3/CampusNet-Update-1.6.3.cmd)。它优先读取同目录 EXE，再查本机缓存，单独下载 CMD 且没有缓存时会从本次 GitHub Release 获取 EXE 并校验 SHA-256。完整 ZIP 内附带两个入口，可以离线使用。升级保留账号、网卡、校准和校园网配置。若计划任务已被删除，请用完整包的 `一键安装.bat` 修复。
3. **可选的账号切换**　双击 `设置默认账号.cmd`，输入自己的校园账号。天翼应当已记住该账号的密码。下次启动时可选择其他账号，选择在本次 Windows 登录内有效。再次运行设置入口并输入 `0` 可恢复使用天翼记住的账号。

升级后会核验新版进程及托盘。更新弹窗会显示结果，详细记录写在 `%LOCALAPPDATA%\CampusNetWatchdog\logs\update.log`。

要预检下载的更新包，在解压目录运行 `CampusNet-Update-1.6.3.cmd --check`。返回码 0 表示更新内容和运行组件可加载。正式安装完成后可点击右下角的托盘图标查看联网状态。

## 🔧 工作原理

天翼校园的主窗口使用 miniblink。自动恢复依次检查以下状态。

1. 读取物理网卡及 IPv4 地址，确认已接入校园网。直连可用时另外核验 Clash。
2. 认证前保存当前网络设置，暂停 Clash Verge，确认系统代理、PAC、TUN 和本地代理端口已经关闭。
3. 在客户端窗口内匹配“登录”字形。连续两帧位置稳定，且提交前仍处于登录页，才会点击。天翼自行认证成功时直接进入连通性检查。
4. 认证结束后重新启动原有代理，核验 Windows 代理状态和 TUN。只有外网探测通过才显示已恢复。若仅代理故障，会跳过重启天翼和网卡。
5. 右下角短提示显示阶段，托盘图标可随时查看当前状态。恢复记录在程序中断后用于继续还原。

## ⚙️ 配置说明

安装后配置在 `%LOCALAPPDATA%\CampusNetWatchdog\config.json`，修改后重启看门狗生效：

```powershell
Stop-ScheduledTask -TaskName CampusNetWatchdog; Start-ScheduledTask -TaskName CampusNetWatchdog
```

| 配置项 | 默认 | 说明 |
|---|---|---|
| `client_dir` | 自动探测 | 天翼校园客户端安装目录 |
| `adapter_name` | 自动探测 | 上网用的网卡名称（"网络连接"里看到的名称） |
| `login_btn_x` / `login_btn_y` | 267 / 533 | "登 录"按钮的后台点击坐标（无需手改，用 `校准按钮坐标.bat` 真实点击一遍即可） |
| `calib_win_w` / `calib_win_h` | 533 / 914 | 上述坐标对应的客户端窗口逻辑尺寸（校准基线，换电脑/缩放时自动按比例换算） |
| `phys_btn_x` / `phys_btn_y` | 校准记录 | 真人点击校准捕获到的按钮物理位置（前台点击直接使用，已实测生效） |
| `phys_win_w` / `phys_win_h` | 校准记录 | 校准时客户端窗口的物理尺寸 |
| `disconnect_btn_y` | 610 | 已连接页面"断 开"按钮的 y 坐标（校准工具辅助断开用） |
| `campus_guard` | 安装时自动 | "离校静默"守卫开关：不在校园网环境时不执行恢复动作、不折腾 |
| `campus_ip_prefixes` | 安装时自动 | 校园网 IPv4 前缀（如 `100.2.`），任一匹配即视为在校园网 |
| `campus_gateways` | 安装时自动 | 校园网默认网关（如 `100.2.0.1`） |
| `away_check_interval_sec` | 300 | 离校静默模式下的探活间隔（秒） |
| `check_interval_sec` | 20 | 探活间隔（秒） |
| `fail_threshold` | 2 | 连续失败几次判定断网 |
| `nic_bounce_cooldown_sec` | 180 | 两次网卡重启最小间隔（秒） |
| `client_start_wait_sec` | 12 | 启动新的天翼进程后，等待它加载界面的秒数 |
| `login_ready_timeout_sec` | 100 | 单轮等待天翼登录按钮出现的时限（秒） |
| `auth_settle_wait_sec` | 75 | 点击登录后最长等待认证时间（秒） |
| `proxy_guard` | true | 认证期间临时处理系统代理/PAC/TUN，结束后还原；旧版 CFW 会临时退出并重新启动 |
| `clash_config_path` | 自动发现 | Clash 控制接口的运行配置文件；支持当前用户默认 CFW / Clash Verge Rev 目录，也可填写自定义运行配置文件绝对路径。仅连接本机 IPv4 HTTP 或 Verge 本地管道 |
| `http_probe_targets` | 小米 / vivo / 微软 | 每项包含 `url`、`status`、`body`；必须匹配 HTTP 状态码和正文，任一检测页通过即在线 |

旧配置不需要手动补字段，新字段自动采用默认值；旧版 `probe_targets`（TCP 探活）不再用于判断在线。

## 🕹 命令通道（进阶）

在 `%LOCALAPPDATA%\CampusNetWatchdog\` 下新建 `command.txt`，写入命令并保存。看门狗在下一轮监测时读取并删除该文件。

| 命令 | 作用 |
|---|---|
| `status` | 把当前在线状态 / 网卡 / 客户端进程写进日志 |
| `restart-client` | 仅重启官方客户端，用于排查客户端报错 |
| `enable-adapter` | 启用配置中的上网网卡，用于恢复诊断时被中断的网卡操作 |
| `bounce` | 立即重启一次网卡 |
| `disconnect` | 在客户端上点一次【断 开】(排查/测试用) |
| `shot` | 弹出客户端窗口截图存档后自动收回托盘 |
| `click x y` | 向客户端窗口发送一次后台点击（如 `click 267 610` 点"断开"） |
| `test-reconnect <id> <截止时间>` | 主动断开并测试重连。ID 为 32 位小写十六进制，截止时间为 10 位 Unix 秒，最长三分钟。结果写入日志目录的 JSON。 |

调试探活：`powershell -File watchdog.ps1 -Check`（只探一次并输出状态）。

单轮排障：停止 `CampusNetWatchdog` 任务后运行 `powershell -File watchdog.ps1 -RecoverOnce`；只执行一次恢复并返回结果。`-RestoreNetwork` 只恢复未完成的代理保护记录。日常使用继续由计划任务常驻监测。

## ❓ 常见问题

**Q: 开着代理时客户端显示异常错误码 101，也不能点“断开”，但实际能上网？**
这与“校园网已断开”需要分别判断。已知在这类代理冲突下，客户端操作可能报 101，而实际网络仍可用；先暂停代理后才能进行客户端断开操作。新版依据独立 HTTP 检测判断在线，网络可用时保持监测，不会因为客户端显示 101 就重启客户端或网卡。真正断网需要重新认证时，才临时处理代理并在结束后还原。

**Q: Clash 开机自启后天翼校园报错，工具却显示“网络恢复”？**
旧版只检查 TCP 能不能建立连接，TUN 可以提前接住连接，导致校园认证未完成就误判在线、不再重试。另外，仅切换 DIRECT 并不等于关闭 TUN，天翼仍可能停在 101 错误页，那里没有登录按钮。v1.5.0 按“关闭代理与 TUN → 确认虚拟网卡停止 → 重启天翼 → 点击登录 → 确认联网 → 恢复代理与 TUN”的顺序处理，并适配 Verge Rev 的服务管道和 Meta 网卡。重新运行新版 `一键安装.bat` 即可升级，原有按钮校准会保留；Clash / Verge 仍可保持开机自启。最终日志 `代理/TUN恢复后HTTP验证通过` 表示恢复代理后也已验证联网。

如果 Clash 使用非默认或便携配置目录，在 `config.json` 中把 `clash_config_path` 设置为实际运行配置文件的绝对路径（Verge Rev 通常是 `clash-verge.yaml`）。默认目录按当前 Windows 用户发现，无需照抄作者的用户名、软件盘符或管道标识。活动 TUN 的控制接口不可用时，工具会恢复本轮修改并等待下次重试；请确认 Clash / Verge 正常运行并检查该路径。认证期间的直连可能短暂影响需要代理的软件，认证结束后恢复原设置。

**Q: 同时装过另一套校园网自动登录脚本怎么办？**
已识别的 `CampusNetAuto` 开机和手动入口可以共用新版登录流程及认证互斥锁。升级会备份需要调整的入口，并保留账号库。遇到无法识别的自定义脚本时会保留原文件并提示。如果两套脚本各自独立操作天翼，请只启用一个开机认证入口。

**Q: 怎么验证兼容性？**
运行 `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1`；PowerShell 7 用户可将开头的 `powershell` 换成 `pwsh`。自动检查使用临时用户目录、随机本地管道及模拟内核，覆盖旧 CFW 配置残留、Verge 服务/普通模式、GET/PATCH 控制、Meta 识别、异常恢复、并发和 HTTP 探活，不修改真实代理设置。本版已在 Windows PowerShell 5.1 和 PowerShell 7 下分别通过检查。

现场已验证一台 Windows / Verge Rev 服务模式电脑上的 TUN 真实暂停、校园网直连和原设置恢复；完整重启登录和其他电脑上的实际登录仍需要各自确认，按钮布局不同时请重新校准。

**Q: 电脑锁屏 / 睡眠时能用吗？**
休眠期间监测暂停。唤醒后，系统事件和时间间隔检测会触发网卡、校园认证及代理检查。锁屏下如果客户端无法提供可识别的画面，程序会等到画面可用再点击。

**Q: 带电脑去教室 / 回家 / 连手机热点，看门狗会不会疯狂重启客户端？**
不会。有网络的地方探活正常通过，它完全安静。连上没有互联网的网络时（酒店网页认证 WiFi、纯局域网、网线插了但网不通），"离校静默"守卫会发现本机 IP 前缀/默认网关都不符合校园网特征，于是**只记录日志并降频探活（每 5 分钟一次），不重启客户端、不动网卡**；回到校园网后自动恢复正常监测。校园网特征在安装时自动探测写入 `config.json`（`campus_guard` / `campus_ip_prefixes` / `campus_gateways`），校园网 IP 段特殊的学校可手动修改。

**Q: 双击 `一键安装.bat` 时一堆 cmd 窗口报错、关了又弹（死循环）？**
这是 v1.2.0 及更早版本的问题，**v1.2.1 已修复**：旧版批处理文件里含有中文，在部分系统代码页下 cmd.exe 解析批处理会错位（乱码、把行残片当命令执行），导致"是否管理员"的判断失效、反复重新提权。
处理办法：在任务管理器里结束所有"命令提示符（cmd.exe）"进程（或直接重启电脑），然后到 [Releases](../../releases) 下载**最新版**重新安装即可。新版所有 `.bat` 均为纯英文内容（中文提示由 PowerShell 脚本输出），不会再出现该问题。

**Q: 客户端升级后界面变了、点不中按钮怎么办？**
双击 `校准按钮坐标.bat`（安装包里或 `%LOCALAPPDATA%\CampusNetWatchdog\` 里都有）：工具会帮你断开网络 → 你**手动真实点击一次**【登 录】按钮 → 工具捕获这次点击的位置、等网络真的连上作为验证 → 自动写入配置并重启看门狗。整个过程约 1 分钟，安装时也会提示做一次。

**Q: 室友电脑上会不会点不中？**
工具已按"窗口尺寸 + DPI 缩放"自动换算坐标，标准情况下开箱即用；安装时的真人点击校准会进一步用实测位置兜底。个别情况（界面改版、手动拉伸过窗口）随时双击 `校准按钮坐标.bat` 一分钟重做。

**Q: 会不会和手动操作冲突？**
不会。工具只在"探测到断网"时才动作；你手动连上后它就安静监测。

**Q: 杀毒软件报毒？**
脚本是明文的 PowerShell（可直接用记事本查看），未加壳未混淆，行为包括：HTTP 探活、窗口消息点击、禁用/启用网卡，以及认证期间临时调整并恢复代理设置。若被拦截请放行，或把 `%LOCALAPPDATA%\CampusNetWatchdog` 加入信任目录。

**Q: 为什么不用 HTTP 直接模拟登录？**
本工具通过官方客户端完成认证。登录页面由天翼显示和提交，因此可沿用天翼已保存的账号和密码。

## 🔍 与同类工具的对比

GitHub 上围绕"广东电信天翼校园网"已经有不少开源项目，按思路分两条路线：

| 路线 | 代表项目 | 平台 | 要交出账号密码? | 锁屏自动连 | 原理 |
|---|---|---|---|---|---|
| **自动化官方客户端（本工具）** | **WYU-ESurfing-Auto-Login** | Windows | 可沿用天翼记住的账号 | 需客户端能提供画面 | 检测断网，识别并点击登录按钮，必要时修复网卡 |
| 自动化官方客户端 | `MarkussLugia/ESurfingKeepAlive`（9★，AutoHotkey） | Windows | ❌ 不用 | ❌ | 定时检测断网 → kill 客户端重新拨号 |
| 协议复刻 | `BadGhost520/ESurfingClient-CVersion`（117★） | 多架构（可跑路由器） | ✅ 需要 | ❌ | 直接模拟认证协议，不依赖官方客户端 |
| 协议复刻 | `6DDUU6/ESurfingDialer-onekey`（67★，Windows 一键包） | Windows | ✅ 需要 | ❌ | 同上（基于 ESurfingDialer 系列） |
| 协议复刻 | `Pandaft/ESurfingPy-CLI`（53★）/ `xxmod/EsurfingGo`（18★） | 跨平台 | ✅ 需要 | ❌ | 同上 |
| 网页 Portal 脚本 | `Z446C/ESC-Z`（31★，shell） | Win/Linux/Mac/路由器 | ✅ 需要 | ❌ | 自动填网页认证表单 |
| 同校前辈 | `6DDUU6/SchoolAuthentication`（65★，五邑大学，Android） | Android | ✅ 需要 | ❌ | 协议复刻；**已停止维护**（旧接口失效） |

**本工具的差异化（也是它的取舍）**：

- **账号资料**　默认沿用官方客户端记住的密码。启用备用账号并保存密码时，工具使用当前 Windows 用户的加密凭据，在天翼登录框内填写。
- ✅ **后台认证**　天翼可以提供后台画面时，通过窗口消息提交登录。
- ✅ **登录按钮卡死自愈**：点击无效自动"禁用→启用网卡"再重试（对应手动排障操作）
- ✅ **真人点击校准 + DPI/窗口尺寸自适应**：不同电脑开箱即用，点不中可一分钟重新校准
- ⚠️ **仅 Windows**：协议类工具能跑在 Linux/macOS/路由器/ESP32 上，本工具做不到（它自动化的是 Windows 官方客户端）
- ⚠️ **依赖官方客户端**：客户端被卸载或大幅改版时需要重新校准/重装客户端
- ⚠️ 如果你要的是"宿舍软路由全屋覆盖"，建议直接用上表的协议类工具（见下一节）

## 🍎🐧 macOS / Linux 用户怎么用

本工具自动化的是 **Windows 官方客户端**，所以 macOS / Linux 上用不了（想在 Mac 上用官方客户端只能开 Windows 虚拟机，那就绕回 Windows 方案了）。

Mac / Linux / 路由器用户请用**协议复刻类**开源工具（需要把宽带账号密码填进程序自己的配置里，请自行评估风险；电信调整接口时可能失效，留意对应仓库的动态）：

| 你的场景 | 推荐 | 说明 |
|---|---|---|
| Linux / macOS 桌面 | [`xxmod/EsurfingGo`](https://github.com/xxmod/EsurfingGo) | Go 单文件，Windows/Linux/macOS 通用，自动检测强制门户、心跳保活、断线重连 |
| 路由器 / OpenWrt / NAS | 同上（单文件免依赖），或 `Z446C/ESC-Z`（shell，兼容广） | 部署成开机自启即可全屋覆盖 |
| Linux 上想快速登录/登出 | [`Pandaft/ESurfingPy-CLI`](https://github.com/Pandaft/ESurfingPy-CLI) | Python 命令行工具，也支持图形界面 |
| 有 Web 界面管理多网卡 | `EchoPing07/Esurfing-go-webui` | 带网页管理面板（该项目已停止维护，仅供 fork 参考） |
| Android 手机 | 参考 `6DDUU6/ESurfingDialer-onekey` 作者的其他项目 | 手机端方案变化较快，以各仓库最新说明为准 |

> 注意：以上协议类工具**都需要你提供账号密码**（通常保存在本地配置文件），并且认证失败时可能需要自己改源码里的认证地址/NAS IP；本工具（官方客户端自动化路线）没有这些问题，但仅限 Windows。

## 📁 目录结构

```
.
├── 一键安装.bat          # 首次安装或修复缺失的计划任务
├── CampusNet-Update-1.6.3.cmd  # 更新现有安装，支持 --check
├── 设置默认账号.cmd      # 设置或清除本机默认账号
├── 卸载.bat              # 双击卸载
├── 校准按钮坐标.bat      # 真人点击校准: 你点一次登录按钮, 工具记录并验证位置
├── install.ps1           # 安装/卸载逻辑 (自动探测 + 写配置 + 注册计划任务)
├── watchdog.ps1          # 看门狗主程序 (常驻循环)
├── network.ps1           # HTTP 检测、认证期间代理保护与恢复
├── monitor.ps1           # 唤醒与物理网卡检测
├── verge.ps1             # 系统代理及 Verge 的暂停、重启和验证
├── ui/                   # 登录字形识别与右下角提示
├── config.example.json   # 配置示例
├── tools/
│   ├── calibrate.ps1     # 坐标校准核心脚本
│   └── uia-probe.ps1     # 窗口探测工具 (高级调试用)
└── LICENSE
```

安装后实际运行在 `%LOCALAPPDATA%\CampusNetWatchdog\`（含 `config.json`、`logs\`、`校准按钮坐标.bat`），计划任务名 `CampusNetWatchdog`（登录时自启、最高权限、无运行时限）。

在 Windows PowerShell 5.1 或 PowerShell 7 下，从完整包的根目录可运行全部回归检查。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
pwsh -NoProfile -File tests\run-all.ps1
```

这些测试使用本地 HTTP 服务和模拟的系统/Clash 接口，不断开真实网络。开机、锁屏和真实校园认证仍需对应环境验收。

v1.4.0 已于 2026-10-21 在五邑大学有线校园网、旧版 CFW Premium 2022.03.21 环境完成一次真实重连验收：13:04:02 确认 TUN 停止，13:04:16 确认断网，13:04:38 后台点击登录后恢复校园网络，13:04:44 恢复 Clash/TUN，13:05:12 连续两次 HTTP 验证通过，早于 13:05:30 截止时间。该记录验证了运行中的断网恢复流程；冷启动和锁屏场景仍需分别观察。

## 🗑 卸载

在完整安装包中双击 `卸载.bat`，或在管理员 PowerShell 中运行 `.\install.ps1 -Uninstall`。卸载会清理看门狗的任务、程序目录及本工具在可选启动脚本中加入的调用。安装目录内保存的配置和备用账号会一起移除。

## ⚠️ 免责声明

- 本工具用于本人账号，通过天翼官方客户端登录。使用备用账号时，凭据只保存在本机。
- 请遵守学校的网络管理规定。

## 📄 License

[MIT](LICENSE) © st-cx
