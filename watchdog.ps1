# ============================================================
#  五邑大学天翼校园自动登录工具 - 看门狗主程序
#  适用于: 五邑大学天翼校园客户端 (广东电信 GDPortal / ESurfingClient)
#
#  功能:
#    - 每 check_interval_sec 秒验证外网 HTTP 响应 (避免 Clash TUN 的 TCP 假阳性)
#    - 连续 fail_threshold 次失败判定断网, 自动执行恢复梯子:
#        第1级: 等待官方客户端就绪，识别登录按钮后后台提交
#        第2级: 禁用/启用网卡 + 重启客户端 + 再点登录 (带冷却, 防反复断网)
#    - 恢复成功/断网时弹 Windows 通知
#
#  客户端界面为 miniblink 自绘网页 (窗口类 wkeWebWindow), 无 UI 自动化元素,
#  因此登录按钮采用窗口坐标点击: 优先 PostMessage 后台点击, 失败再前台真实点击。
#
#  用法:
#    正常由计划任务 CampusNetWatchdog 常驻运行 (install.ps1 安装)
#    调试: powershell -File watchdog.ps1 -Check    # 只探活一次并输出状态
#
#  命令通道: 脚本目录下放置 command.txt, 写入命令后下一轮循环执行
#    status / bounce / shot / click x y
# ============================================================

param(
    [switch]$Embedded,        # 由现有开机任务调用同一套恢复流程
    [switch]$Check,           # 仅探活, 不修改代理/客户端/网卡
    [switch]$RecoverOnce,     # 仅执行一次自动恢复 (排障/验收用)
    [switch]$RestoreNetwork   # 仅恢复上次认证临时修改的代理设置
)

$ErrorActionPreference = 'Continue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---------- 默认配置 (脚本目录下 config.json 可覆盖) ----------
$Config = [ordered]@{
    client_dir              = 'C:\Program Files (x86)\Chinatelecom_GDPortal'
    client_exe_name         = 'ESurfingClient.exe'
    client_proc_name        = 'ESurfingClient'
    adapter_name            = '以太网'
    login_btn_x             = 267
    login_btn_y             = 533
    # 校准基线: login_btn_x/y 所对应的客户端窗口尺寸 (默认对应 533x914 标准窗口)
    # 更换电脑/高DPI缩放时自动按窗口尺寸换算; 也可用 tools\calibrate.ps1 引导重新校准
    calib_win_w             = 533
    calib_win_h             = 914
    # 真实点击参考 (由"校准按钮坐标"工具记录: 用户真实点击一次登录按钮的物理位置)
    # 存在时前台真实点击优先使用它, 不再依赖换算
    phys_btn_x              = -1
    phys_btn_y              = -1
    phys_win_w              = -1
    phys_win_h              = -1
    # 客户端"断 开"按钮的基线 y 坐标 (用于校准工具的辅助断开)
    disconnect_btn_y        = 610
    # 离校静默守卫: 本机 IPv4 前缀或默认网关匹配下列特征时才执行恢复动作,
    # 否则(如带电脑回家/连热点/酒店WiFi)只记录日志并降频探活, 不折腾
    # install.ps1 会自动探测写入; 关闭设为 false
    campus_guard            = $false
    campus_ip_prefixes      = @()
    campus_gateways         = @()
    away_check_interval_sec = 300
    check_interval_sec      = 20
    fail_threshold          = 2
    probe_timeout_ms        = 2000
    nic_bounce_cooldown_sec = 180
    client_start_wait_sec   = 12
    login_ready_timeout_sec = 100
    auth_settle_wait_sec    = 75
    proxy_guard             = $true
    clash_config_path       = ''
    http_probe_targets      = @(
        @{ url = 'http://connect.rom.miui.com/generate_204'; status = 204; body = '' },
        @{ url = 'http://wifi.vivo.com.cn/generate_204'; status = 204; body = '' },
        @{ url = 'http://www.msftconnecttest.com/connecttest.txt'; status = 200; body = 'Microsoft Connect Test' }
    )
}
$configPath = Join-Path $Root 'config.json'
if ($Check -and -not (Test-Path -LiteralPath $configPath)) {
    $configPath = Join-Path $env:LOCALAPPDATA 'CampusNetWatchdog\config.json'
}
$configError = $null
if (Test-Path $configPath) {
    try {
        $userCfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($Config.Keys)) {
            if (($userCfg.PSObject.Properties.Name -contains $k) -and ($null -ne $userCfg.$k)) {
                $Config[$k] = $userCfg.$k
            }
        }
    } catch { $configError = $_.Exception.Message }
}

$ClientDir   = $Config.client_dir
$ClientExe   = Join-Path $ClientDir $Config.client_exe_name
$ClientProc  = $Config.client_proc_name
$AdapterName = $Config.adapter_name
$LogDir      = Join-Path $Root 'logs'
$LogFile     = Join-Path $LogDir 'watchdog.log'

$CheckIntervalSec   = [int]$Config.check_interval_sec
$FailThreshold      = [int]$Config.fail_threshold
$ProbeTimeoutMs     = [int]$Config.probe_timeout_ms
$NicBounceCooldown  = [int]$Config.nic_bounce_cooldown_sec
$ClientStartWaitSec = [Math]::Max(0,[int]$Config.client_start_wait_sec)
$LoginReadyTimeout = [Math]::Max(10,[int]$Config.login_ready_timeout_sec)
$AuthSettleWaitSec  = [int]$Config.auth_settle_wait_sec
$HttpProbeTargets   = $Config.http_probe_targets
. (Join-Path $Root 'network.ps1')
. (Join-Path $Root 'monitor.ps1')
$NetworkStatePath   = Join-Path $Root 'proxy-recovery.json'
$AutoNetworkStatePath = Join-Path $env:USERPROFILE 'CampusNetAuto\proxy-recovery.json'

# 离校静默守卫配置
$CampusGuard = [bool]$Config.campus_guard
$CampusIpPrefixes = @($Config.campus_ip_prefixes | Where-Object { $_ })
$CampusGateways   = @($Config.campus_gateways | Where-Object { $_ })
$AwayCheckIntervalSec = [int]$Config.away_check_interval_sec
if ($AwayCheckIntervalSec -lt 60) { $AwayCheckIntervalSec = 300 }
if ($CampusGuard -and $CampusIpPrefixes.Count -eq 0 -and $CampusGateways.Count -eq 0) {
    # 配了守卫却没有特征值, 视为无效配置, 关闭守卫以免误拦恢复
    $CampusGuard = $false
}

# 登录页"登 录"按钮中心, 相对客户端主窗口左上角 (默认值对应 533x914 标准窗口,
# 实测登录页按钮在 y=533; 注意已连接页面的"断 开"按钮在 y=610, 两者布局不同)
$LoginBtnOffsetX = [int]$Config.login_btn_x
$LoginBtnOffsetY = [int]$Config.login_btn_y
$CalibWinW       = [int]$Config.calib_win_w
$CalibWinH       = [int]$Config.calib_win_h
if ($CalibWinW -lt 100) { $CalibWinW = 533 }
if ($CalibWinH -lt 100) { $CalibWinH = 914 }

# 真实点击参考 (校准工具实测记录; -1 表示未校准过)
$PhysBtnX  = [int]$Config.phys_btn_x
$PhysBtnY  = [int]$Config.phys_btn_y
$PhysWinW  = [int]$Config.phys_win_w
$PhysWinH  = [int]$Config.phys_win_h
$HasPhysRef = ($PhysBtnX -ge 0 -and $PhysBtnY -ge 0 -and $PhysWinW -ge 200 -and $PhysWinH -ge 200)
$DisconnectBtnY = 610
if ($Config.Contains('disconnect_btn_y')) { $DisconnectBtnY = [int]$Config.disconnect_btn_y }

# ----------------------------

Add-Type -AssemblyName System.Drawing
if (-not ([System.Management.Automation.PSTypeName]'CampusWatch.Win32').Type) {
    Add-Type -Namespace CampusWatch -Name Win32 -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, System.UIntPtr dwExtraInfo);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetWindowDpiAwarenessContext(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder text, int length);
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
try { [CampusWatch.Win32]::SetProcessDPIAware() | Out-Null } catch {}

function Log {
    param([string]$msg)
    try {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 512KB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
    } catch {}
}

if ($configError) { Log ('config.json 解析失败, 已改用默认配置 (请检查文件格式): ' + $configError) }

function Test-Internet {
    return (Test-InternetHttp -Targets $HttpProbeTargets -TimeoutMs $ProbeTimeoutMs)
}

function Test-OnCampus { return ((Get-PhysicalLink) -eq 'Campus') }

function Get-CampusWindows {
    $mine = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $ids = @(Get-Process -Name $ClientProc -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $mine -and $_.Path -ieq $ClientExe
    } | ForEach-Object {$_.Id})
    if ($ids.Count) { [CampusRecovery.LoginScreen]::Windows([int[]]$ids) }
}
function Find-ClientWebWindow {
    $first = Get-CampusWindows | Select-Object -First 1
    if ($first) { return [IntPtr]$first }
    return [IntPtr]::Zero
}

function Get-WindowRectSafe {
    param([IntPtr]$h)
    $rect = New-Object CampusWatch.Win32+RECT
    [CampusWatch.Win32]::GetWindowRect($h, [ref]$rect) | Out-Null
    return $rect
}

function Restore-ClientWindow {
    param([IntPtr]$h)
    $rect = Get-WindowRectSafe $h
    if ($rect.Left -le -30000) {
        [CampusWatch.Win32]::ShowWindow($h, 9) | Out-Null     # SW_RESTORE
        Start-Sleep -Milliseconds 1500
        $rect = Get-WindowRectSafe $h
    }
    if ($rect.Left -gt -30000 -and ($rect.Right - $rect.Left) -gt 100) {
        [CampusWatch.Win32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 400
        return $rect
    }
    return $null
}

function Save-WindowShot {
    param([IntPtr]$h, [string]$tag)
    $bmp = $null
    try {
        if ($h -notin @(Get-CampusWindows)) { return }
        $bmp = [CampusRecovery.LoginScreen]::DiagnosticFrame($h)
        if (-not $bmp) { Log '天翼未返回可保存的窗口画面'; return }
        $f = Join-Path $LogDir ('shot-' + $tag + '-' + (Get-Date -Format 'MMdd-HHmmss-fff') + '.png')
        $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
        Log ('已保存截图 ' + (Split-Path $f -Leaf))
        Get-ChildItem (Join-Path $LogDir 'shot-*.png') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Log '天翼窗口截图未保存' }
    finally { if ($bmp) { $bmp.Dispose() } }
}

function Get-WindowAwareness {
    # 0=DPI不感知 1=系统感知 2=每显示器感知 -1=查询失败
    param([IntPtr]$h)
    try {
        $ctx = [CampusWatch.Win32]::GetWindowDpiAwarenessContext($h)
        if ($ctx -eq [IntPtr]::Zero) { return -1 }
        return [CampusWatch.Win32]::GetAwarenessFromDpiAwarenessContext($ctx)
    } catch { return -1 }
}

function Get-ClickPoints {
    # 把配置里的按钮坐标换算成:
    #   lpX/lpY   -> 供 PostMessage 使用的客户端坐标
    #   physX/physY -> 相对窗口左上角的物理像素偏移 (真实点击用)
    # 换算依据: 客户端窗口尺寸 + 客户端 DPI 感知方式, 使同一份配置适配
    # 不同电脑的分辨率/缩放比例(125%/150%)/窗口尺寸
    param([IntPtr]$h)
    $rect = Get-WindowRectSafe $h
    $physW = $rect.Right - $rect.Left
    $physH = $rect.Bottom - $rect.Top
    if (($rect.Left -le -30000) -or ($physW -lt 200) -or ($physH -lt 200)) {
        # 最小化状态: 页面视口不变, 直接使用配置坐标
        return @{ lpX = $LoginBtnOffsetX; lpY = $LoginBtnOffsetY;
                  physX = $LoginBtnOffsetX; physY = $LoginBtnOffsetY }
    }
    $aware = Get-WindowAwareness $h
    if ($aware -eq 0) {
        # DPI 不感知的客户端: 其自身坐标空间恒为校准基线大小
        $logicalW = $CalibWinW; $logicalH = $CalibWinH
    } else {
        # 系统/每显示器感知: 自身坐标空间 = 物理尺寸 (会随缩放变化)
        $logicalW = $physW; $logicalH = $physH
    }
    $lpX = [int][Math]::Round($LoginBtnOffsetX * $logicalW / $CalibWinW)
    $lpY = [int][Math]::Round($LoginBtnOffsetY * $logicalH / $CalibWinH)
    $physX = [int][Math]::Round($lpX * $physW / $logicalW)
    $physY = [int][Math]::Round($lpY * $physH / $logicalH)
    return @{ lpX = $lpX; lpY = $lpY; physX = $physX; physY = $physY }
}

function Get-DisconnectPoint {
    # 已连接页面上"断 开"按钮的客户端坐标 (用于辅助断开/排查)
    # y 按设计基线 914 换算 (610 是 533x914 窗口上的实测值)
    param([IntPtr]$h)
    $rect = Get-WindowRectSafe $h
    $physW = $rect.Right - $rect.Left
    $physH = $rect.Bottom - $rect.Top
    if (($rect.Left -le -30000) -or ($physW -lt 200) -or ($physH -lt 200)) {
        return @{ lpX = $LoginBtnOffsetX; lpY = $DisconnectBtnY }
    }
    $aware = Get-WindowAwareness $h
    if ($aware -eq 0) { $logicalW = $CalibWinW; $logicalH = $CalibWinH }
    else { $logicalW = $physW; $logicalH = $physH }
    $lpX = [int][Math]::Round($LoginBtnOffsetX * $logicalW / $CalibWinW)
    $lpY = [int][Math]::Round($DisconnectBtnY * $logicalH / 914)
    return @{ lpX = $lpX; lpY = $lpY }
}

function Send-ClickToWindow {
    # 后台消息点击: 不移动真实鼠标, 锁屏状态下同样有效
    param([IntPtr]$h, [int]$x, [int]$y)
    $lp = [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
    [CampusWatch.Win32]::PostMessage($h, 0x200, [IntPtr]0, $lp) | Out-Null  # WM_MOUSEMOVE
    Start-Sleep -Milliseconds 100
    [CampusWatch.Win32]::PostMessage($h, 0x201, [IntPtr]1, $lp) | Out-Null  # WM_LBUTTONDOWN
    Start-Sleep -Milliseconds 80
    [CampusWatch.Win32]::PostMessage($h, 0x202, [IntPtr]0, $lp) | Out-Null  # WM_LBUTTONUP
}

function Get-LoginSample {
    $windows = @(Get-CampusWindows)
    $script:lastLoginRead = 'no-window'
    $script:loginWindow = [IntPtr]::Zero
    foreach ($h in $windows) {
        if ($script:loginWindow -eq [IntPtr]::Zero) { $script:loginWindow=$h }
        $p = [CampusRecovery.LoginScreen]::Read($h,$script:LoginGlyph,$script:LoginX,$script:LoginY)
        $script:lastLoginRead = [CampusRecovery.LoginScreen]::LastRead
        if (-not $p.IsEmpty) { return [pscustomobject]@{Window=$h; Point=$p} }
    }
}

function Test-SameLoginSample($First,$Second) {
    return $null -ne $First -and $null -ne $Second -and $First.Window -eq $Second.Window -and
        [Math]::Abs($First.Point.X-$Second.Point.X) -le 3 -and [Math]::Abs($First.Point.Y-$Second.Point.Y) -le 3
}

function Update-LoginGuard {
    if (Test-Path -LiteralPath $NetworkStatePath) {
        Update-AuthNetworkContext -StatePath $NetworkStatePath -ClashConfigPath $Config.clash_config_path
    }
}

function Send-RecognizedLogin($Sample,[bool]$Physical) {
    $tag = if ($Physical) { 'pre-click' } else { 'pre-bgclick' }
    Save-WindowShot $Sample.Window $tag
    if ($Sample.Window -notin @(Get-CampusWindows)) { return $false }
    if ($script:CampusAccountUser -and -not [CampusRecovery.LoginScreen]::CheckAccount($Sample.Window,$script:LoginGlyph,$script:LoginX,$script:LoginY,$script:CampusAccountUser,$true)) { return $false }
    if (-not [CampusRecovery.LoginScreen]::ClickVerified($Sample.Window,$script:LoginGlyph,$script:LoginX,$script:LoginY,$Physical)) { return $false }
    $script:submittedWindow = $Sample.Window
    return $true
}

function Invoke-LoginClick([scriptblock]$BeforeLogin) {
    Set-CampusStatus 'loading' '天翼正在加载，等待识别“登录”按钮'
    $end = [datetime]::UtcNow.AddSeconds($LoginReadyTimeout)
    $nextProbe = [datetime]::MinValue
    $showAfter = [datetime]::UtcNow.AddSeconds(5)
    $announced = $null; $revealed = $false
    $previous = $null
    while ([datetime]::UtcNow -lt $end) {
        if ($script:RecoveryDeadline -and (Get-Date) -ge $script:RecoveryDeadline) { return 'Timeout' }
        if ([datetime]::UtcNow -ge $nextProbe) {
            Update-LoginGuard
            if (Test-Internet) { return 'Online' }
            $nextProbe = [datetime]::UtcNow.AddSeconds(6)
        }
        $sample = Get-LoginSample
        if (-not $sample -and [datetime]::UtcNow -ge $showAfter) {
            if ($script:lastLoginRead -ne $announced) {
                $hint = switch ($script:lastLoginRead) {
                    'no-window' {'天翼进程正在启动，等待主窗口'}
                    'covered' {'天翼窗口被遮挡，正在重新读取登录页'}
                    'hidden' {'正在显示天翼登录窗口'}
                    'desktop' {'等待可读取的天翼窗口'}
                    default {'已找到天翼窗口，等待登录表单绘制完成'}
                }
                Set-CampusStatus 'loading' $hint
                Log ('天翼识别状态：'+$script:lastLoginRead)
                $announced=$script:lastLoginRead
            }
            if (-not $revealed -and $script:loginWindow -and $script:loginWindow -ne [IntPtr]::Zero -and $script:lastLoginRead -in @('hidden','covered','no-glyph')) {
                [CampusRecovery.LoginScreen]::Reveal($script:loginWindow); $revealed=$true
            }
        }
        if (Test-SameLoginSample $previous $sample) {
            Set-CampusStatus 'ready' '已识别到登录按钮，正在提交认证'
            if ($script:CampusAccountUser) {
                if (-not (Confirm-CampusAccount $sample)) { $script:accountPending=$true; return 'AccountPending' }
            } elseif ($BeforeLogin) { & $BeforeLogin | Out-Null; $BeforeLogin = $null }
            Update-LoginGuard
            if (Test-Internet) { return 'Online' }
            if (Send-RecognizedLogin $sample $false) {
                Set-CampusStatus 'auth' '已点击登录，等待天翼认证并核验外网'
                return 'Submitted'
            }
            Set-CampusStatus 'loading' '天翼界面已变化，正在重新识别'
            $sample = $null
        }
        $previous = $sample
        Start-Sleep -Milliseconds 650
    }
    $script:loginTimedOut = $true
    Set-CampusStatus 'error' '等待天翼登录界面超时，本轮未点击'
    return 'Timeout'
}

function Wait-AuthSettle {
    $end = [datetime]::UtcNow.AddSeconds($AuthSettleWaitSec)
    $retryAt = [datetime]::UtcNow.AddSeconds(25)
    $previous = $null
    while ([datetime]::UtcNow -lt $end) {
        if ($script:RecoveryDeadline -and (Get-Date) -ge $script:RecoveryDeadline) { return $false }
        Update-LoginGuard
        if (Test-Internet) { return $true }
        if ([datetime]::UtcNow -ge $retryAt) {
            $sample = Get-LoginSample
            if (Test-SameLoginSample $previous $sample) {
                if ((Confirm-CampusAccount $sample) -and (Send-RecognizedLogin $sample $true)) {
                    Set-CampusStatus 'auth' '天翼仍显示登录按钮，已重新提交，等待认证'
                    $retryAt = [datetime]::MaxValue
                }
            }
            $previous = $sample
        }
        Start-Sleep -Seconds 2
    }
    return (Test-Internet)
}

function Restart-Client([switch]$ForceRestart) {
    Set-CampusStatus 'client' '正在启动天翼校园客户端'
    $serviceKey = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\ESurfingSvr' -ErrorAction SilentlyContinue
    if ($serviceKey -and ([string]$serviceKey.ImagePath).Trim('"') -ieq (Join-Path $ClientDir 'ESurfingSvr.exe')) {
        $service = Get-Service -Name 'ESurfingSvr' -ErrorAction Stop
        if ($service.Status -eq 'Stopped') { Start-Service -InputObject $service -ErrorAction Stop }
    }
    $mine = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $running = @(Get-Process -Name $ClientProc -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $mine -and $_.Path -ieq $ClientExe
    })
    if (-not $ForceRestart -and $running.Count -and (Find-ClientWebWindow) -ne [IntPtr]::Zero) { return }
    foreach ($proc in $running) {
        $proc | Stop-Process -Force -ErrorAction Stop
        if (-not $proc.WaitForExit(5000)) { throw '天翼进程尚未退出。' }
    }
    Start-Process -FilePath $ClientExe -WorkingDirectory $ClientDir -WindowStyle Normal -ErrorAction Stop
    $wait = $ClientStartWaitSec
    if ($script:RecoveryDeadline) { $wait = [Math]::Min($wait,[Math]::Max(0,[int][Math]::Floor(($script:RecoveryDeadline - (Get-Date)).TotalSeconds))) }
    if ($wait -gt 0) { Start-Sleep -Seconds $wait }
}

function Wait-AdapterUp([int]$TimeoutSec = 45) {
    $end = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        $link = Get-PhysicalLink
        if ($link -eq 'Campus') { return $true }
        if ($link -eq 'Away') { return $false }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $end)
    return $false
}

function Repair-NicAdapter {
    Log ('禁用并重新启用网卡: ' + $AdapterName)
    try {
        $ad = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        if ($ad.Status -eq 'Disabled') { return $false }
        Write-CampusFile (Join-Path $Root 'adapter-recovery.txt') ([string]$ad.InterfaceGuid)
        Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 4
    } catch {
        Log ('网卡操作失败: ' + $_.Exception.Message)
        return $false
    } finally { [void](Restore-OwnedAdapter) }
    $up = Wait-AdapterUp -TimeoutSec 45
    Log ('网卡恢复状态: ' + $up)
    return $up
}

function Restore-OwnedAdapter {
    $file = Join-Path $Root 'adapter-recovery.txt'
    if (-not [IO.File]::Exists($file)) { return $true }
    try {
        $guid = [guid]([IO.File]::ReadAllText($file).Trim())
        $ad = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.InterfaceGuid -and [guid]$_.InterfaceGuid -eq $guid } | Select-Object -First 1
        if (-not $ad) { return $false }
        if ($ad.Status -eq 'Disabled' -or $ad.AdminStatus -eq 'Down') {
            $ad | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
        }
        [IO.File]::Delete($file)
        return $true
    } catch {
        Set-CampusStatus 'adapter' '正在恢复先前由看门狗暂停的校园网网卡'
        return $false
    }
}

function Invoke-CampusRecovery([switch]$RepairProxy,[scriptblock]$BeforeLogin) {
    $lock = Get-AuthenticationLock
    if (-not $lock) { return $false }
    $script:loginTimedOut = $false; $script:accountPending = $false
    $script:submittedWindow = [intptr]::Zero
    try {
        if (-not (Restore-AuthNetworkContext $AutoNetworkStatePath)) { return $false }
        if (-not (Wait-AdapterUp -TimeoutSec 45)) { return $false }
        if ($Config.proxy_guard) {
            if (Test-Path -LiteralPath $NetworkStatePath) {
                Update-AuthNetworkContext $NetworkStatePath $Config.clash_config_path
            } else { Enter-AuthNetworkContext $NetworkStatePath $Config.clash_config_path -RepairProxy:$RepairProxy }
        }
        if (Test-Internet) { return $true }
        if ($RepairProxy) { return $false }
        for ($stage = 1; $stage -le 2; $stage++) {
            if ($stage -eq 2) {
                if (($script:RecoveryDeadline -and (Get-Date) -ge $script:RecoveryDeadline) -or (Get-PhysicalLink) -ne 'Campus') { return $false }
                if (Test-Internet) { return $true }
                if (((Get-Date)-$script:lastBounce).TotalSeconds -le $NicBounceCooldown) { return $false }
                $script:lastBounce = Get-Date
                Set-CampusStatus 'adapter' '认证未通过，正在重新连接校园网网卡'
                if (-not (Repair-NicAdapter)) { return $false }
                Send-Toast '已重启网卡，正在重新登录'
                if (Test-Internet) { return $true }
            }
            Restart-Client -ForceRestart:($stage -eq 2 -or $script:retryClient)
            $script:retryClient = $false
            Update-LoginGuard
            $result = Invoke-LoginClick -BeforeLogin $BeforeLogin
            if ($result -eq 'Timeout') {
                $script:retryClient = $script:lastLoginRead -in @('no-window','no-glyph')
                if ($script:lastLoginRead -eq 'no-glyph') {
                    $script:readMisses++
                    if ($stage -eq 1 -and $script:readMisses -ge 2) { continue }
                } else { $script:readMisses = 0 }
                return $false
            }
            $script:readMisses=0
            if ($result -eq 'Online') { return $true }
            if ($result -ne 'Submitted') { return $false }
            if (Wait-AuthSettle) {
                if ($script:submittedWindow -ne [intptr]::Zero -and $script:submittedWindow -in @(Get-CampusWindows)) {
                    [CampusRecovery.LoginScreen]::Minimize($script:submittedWindow)
                }
                return $true
            }
        }
        return $false
    } catch {
        Log ('恢复中断，准备恢复代理：'+$_.Exception.GetType().Name)
        return $false
    } finally {
        try { [void](Restore-AuthNetworkContext $NetworkStatePath) }
        finally { Release-AuthenticationLock $lock }
    }
}

function Invoke-ReconnectSelfTest([string]$Id, [datetime]$Deadline) {
    $report = [ordered]@{ id = $Id; deadline = $Deadline.ToString('o'); passed = $false;
        tun_stopped = $false; disconnected = $false; restored = $false }
    $reportPath = Join-Path $LogDir ('reconnect-test-' + $Id + '.json')
    $authLock = Get-AuthenticationLock
    try {
        if (-not $authLock) { throw 'Another authentication is in progress.' }
        $script:RecoveryDeadline = $Deadline
        if ((Get-Date) -ge $Deadline) { throw 'Deadline reached before test start.' }
        if (-not (Test-Internet)) { throw 'Initial network is offline.' }
        $originalProxy = (Get-SystemProxyValue 'ProxyEnable').value
        $originalMode = (Invoke-ClashApi (Get-LocalClashController -ConfigPath $Config.clash_config_path)).mode
        $originalTun = Test-ClashTunActive
        Enter-AuthNetworkContext -StatePath $NetworkStatePath -ClashConfigPath $Config.clash_config_path
        $report.tun_stopped = -not (Test-ClashTunActive)
        if (-not $report.tun_stopped) { throw 'TUN did not actually stop.' }
        Restart-Client -ForceRestart
        $h = Find-ClientWebWindow
        if ($h -eq [IntPtr]::Zero) { throw 'Client window is missing.' }
        $dp = Get-DisconnectPoint $h
        Send-ClickToWindow $h $dp.lpX $dp.lpY
        $offlineDeadline = (Get-Date).AddSeconds(12)
        while ((Get-Date) -lt $offlineDeadline) {
            if (-not (Test-Internet)) { $report.disconnected = $true; break }
            Start-Sleep -Milliseconds 300
        }
        if (-not $report.disconnected) { throw 'Client did not actually disconnect.' }
        Log '限时重测: TUN 已停止并已确认真实断网, 开始自动登录'
        if (-not (Invoke-CampusRecovery)) { throw 'Automatic authentication failed.' }
        $report.restored = Restore-AuthNetworkContext -StatePath $NetworkStatePath
        if (-not $report.restored) { throw 'Network setting restoration is pending.' }
        $mode = (Invoke-ClashApi (Get-LocalClashController -ConfigPath $Config.clash_config_path)).mode
        if ($mode -ne $originalMode -or (Test-ClashTunActive) -ne $originalTun -or
            (Get-SystemProxyValue 'ProxyEnable').value -ne $originalProxy) { throw 'Original proxy/TUN settings do not match.' }
        if (-not (Wait-InternetHttp -Targets $HttpProbeTargets -TimeoutMs $ProbeTimeoutMs -Deadline $Deadline)) {
            throw 'Internet failed after restoring proxy/TUN.'
        }
        if ((Get-Date) -ge $Deadline) { throw 'Three-minute deadline reached.' }
        $report.passed = $true
        Log '限时重测通过: 真实断网后自动登录成功, 代理与TUN已恢复'
    } catch {
        $report.error = $_.Exception.Message
        Log ('限时重测未通过: ' + $_.Exception.GetType().Name)
    } finally {
        $script:RecoveryDeadline = $null
        if ($authLock) {
            $report.restored = Restore-AuthNetworkContext -StatePath $NetworkStatePath
            Release-AuthenticationLock $authLock
        }
        $report.finished = (Get-Date).ToString('o')
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    }
}

function Send-Toast {
    param([string]$text)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $xml.GetElementsByTagName('text')
        $t.Item(0).AppendChild($xml.CreateTextNode('校园网看门狗')) | Out-Null
        $t.Item(1).AppendChild($xml.CreateTextNode($text)) | Out-Null
        $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
    } catch {}
}

function Invoke-CommandFile {
    # 命令通道: 脚本目录下 command.txt
    $f = Join-Path $Root 'command.txt'
    if (-not (Test-Path $f)) { return }
    $cmd = ''
    try { $cmd = (Get-Content $f -Raw).Trim() } catch {}
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    if (-not $cmd) { return }
    Log ('收到命令: ' + $cmd)
    switch -Regex ($cmd) {
        '^test-reconnect ([0-9a-f]{32}) ([0-9]{10})$' {
            $testId = $Matches[1]
            $deadline = [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[2]).LocalDateTime
            # Bound even a manually submitted diagnostic request to three minutes.
            if ($deadline -gt (Get-Date).AddMinutes(3)) { $deadline = (Get-Date).AddMinutes(3) }
            Invoke-ReconnectSelfTest -Id $testId -Deadline $deadline
        }
        '^restart-client$' {
            Restart-Client -ForceRestart
            Log 'restart-client: completed'
        }
        '^enable-adapter$' {
            try {
                Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
                Log 'enable-adapter: completed'
            } catch { Log 'enable-adapter: failed' }
        }
        'bounce' {
            $script:lastBounce = Get-Date
            $ok = Repair-NicAdapter
            Log ('命令bounce执行完毕, 结果: ' + $ok)
        }
        'click' {
            $h = Find-ClientWebWindow
            if ($h -ne [IntPtr]::Zero) {
                Save-WindowShot $h 'pre-manualclick'
                $p = Get-ClickPoints $h
                $cx = $p.lpX; $cy = $p.lpY
                if ($cmd -match 'click\s+(\d+)\s+(\d+)') { $cx = [int]$Matches[1]; $cy = [int]$Matches[2] }
                Send-ClickToWindow $h $cx $cy
                Log ('命令click: 已发送后台点击 (' + $cx + ',' + $cy + ')')
            } else { Log 'click: 未找到客户端窗口' }
        }
        'disconnect' {
            $h = Find-ClientWebWindow
            if ($h -ne [IntPtr]::Zero) {
                $dp = Get-DisconnectPoint $h
                Send-ClickToWindow $h $dp.lpX $dp.lpY
                Log ('命令disconnect: 已发送断开点击 (' + $dp.lpX + ',' + $dp.lpY + ')')
                Log 'disconnect: sent'
            } else { Log 'disconnect: 未找到客户端窗口' }
        }
        'shot' {
            $h = Find-ClientWebWindow
            if ($h -ne [IntPtr]::Zero) {
                Restore-ClientWindow $h | Out-Null
                Save-WindowShot $h 'manual'
                Start-Sleep -Milliseconds 300
                [CampusRecovery.LoginScreen]::Minimize($h)
            } else { Log 'shot: 未找到客户端窗口' }
        }
        'status' {
            $ad = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
            $proc = Get-Process -Name $ClientProc -ErrorAction SilentlyContinue
            Log ('status: 在线=' + (Test-Internet) + ' 网卡=' + $ad.Status + ' 客户端进程=' + ([bool]$proc))
        }
        default { Log '未知命令, 忽略' }
    }
}

Initialize-CampusNative
$script:LoginGlyph = [Drawing.Bitmap]::new((Join-Path $Root 'ui\login-glyph.png'))
$script:LoginX = $LoginBtnOffsetX / [double]$CalibWinW
$script:LoginY = $LoginBtnOffsetY / [double]$CalibWinH
if ($HasPhysRef) {
    $script:LoginX = $PhysBtnX / [double]$PhysWinW
    $script:LoginY = $PhysBtnY / [double]$PhysWinH
}
$script:lastBounce = [datetime]::MinValue
if ($Embedded) { return }

# ---------- 调试模式: 只探活一次 ----------
if ($Check) {
    $ad = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object Name -eq $AdapterName | Select-Object -First 1
    $adStatus = '未找到'
    if ($ad) { $adStatus = $ad.OperationalStatus }
    Write-Output ('直连外网: ' + (Test-Internet))
    $lan = Read-LanSettings
    Write-Output ('Windows 系统代理: ' + [bool]($lan.Flags -band 2) + '  PAC: ' + [bool]($lan.Flags -band 4) + '  TUN: ' + (Test-ClashTunActive))
    Write-Output ('校园网物理链路: ' + (Get-PhysicalLink) + '  Clash Verge: ' + (Get-VergeExecutable))
    Write-Output '探活:   HTTP 状态码 + 正文校验 (禁用请求代理/重定向/缓存)'
    Write-Output ('代理保护: ' + [bool]$Config.proxy_guard + '  待恢复设置: ' + (Test-Path -LiteralPath $NetworkStatePath))
    Write-Output ('网卡:   ' + $AdapterName + ' -> ' + $adStatus)
    Write-Output ('客户端: ' + [bool](Get-Process -Name $ClientProc -ErrorAction SilentlyContinue) +
                  '  窗口: ' + (Find-ClientWebWindow))
    Write-Output ('客户端目录: ' + $ClientDir + ' (存在=' + (Test-Path $ClientExe) + ')')
    $h = Find-ClientWebWindow
    if ($h -ne [IntPtr]::Zero) {
        $rect = Get-WindowRectSafe $h
        $p = Get-ClickPoints $h
        Write-Output ('点击坐标: 配置(' + $LoginBtnOffsetX + ',' + $LoginBtnOffsetY + ') 基线(' +
                      $CalibWinW + 'x' + $CalibWinH + ') 窗口(' + ($rect.Right - $rect.Left) + 'x' +
                      ($rect.Bottom - $rect.Top) + ') 感知=' + (Get-WindowAwareness $h) +
                      ' -> 客户端坐标(' + $p.lpX + ',' + $p.lpY + ')')
        if ($HasPhysRef) {
            Write-Output ('真实点击参考: 物理(' + $PhysBtnX + ',' + $PhysBtnY + ') @窗口' + $PhysWinW + 'x' + $PhysWinH)
        } else {
            Write-Output '真实点击参考: 无 (未做过真实点击校准, 前台点击将使用换算坐标)'
        }
    }
    if ($CampusGuard) {
        $curPrefixes = ''
        try {
            $curPrefixes = (($ad.GetIPProperties().UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address -notmatch '^(127\.|169\.254\.)'
            } | ForEach-Object { ($_.Address.ToString().Split('.')[0..1] -join '.') + '.' }) | Select-Object -Unique) -join ','
        } catch {}
        Write-Output ('离校守卫: 已启用 校园前缀=[' + ($CampusIpPrefixes -join ',') + '] 校园网关=[' +
                      ($CampusGateways -join ',') + '] 当前IP前缀=[' + $curPrefixes + '] 判定在校园网=' + (Test-OnCampus))
    } else {
        Write-Output '离校守卫: 未启用 (config.json 里 campus_guard=true 可开启)'
    }
    exit 0
}

# ---------- 单实例保护 ----------
$mutex = New-Object System.Threading.Mutex($false, 'Global\CampusNetWatchdogMutex')
try { $ownsMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
if (-not $ownsMutex) {
    $mutex.Dispose()
    if ($RecoverOnce -or $RestoreNetwork) { Write-Output '看门狗已在运行, 请先停止计划任务再执行单次调试'; exit 3 }
    exit 0
}

# ---------- 主循环 ----------
Log '===== 校园网看门狗启动 v1.6.3 ====='
$script:fails = 0
$script:nextProxyRepair = [datetime]::MinValue
$script:verifyAfterWake = $true
try {
    if ($RestoreNetwork) {
        if ((Restore-AuthNetworkContext $NetworkStatePath) -and (Restore-AuthNetworkContext $AutoNetworkStatePath)) { exit 0 }
        exit 1
    }
    if ($RecoverOnce) {
        $offCampus = $false
        if (Invoke-SingleConnection -OffCampus ([ref]$offCampus)) { exit 0 }
        if ($offCampus) { Log '不在校园网，跳过单次恢复'; exit 2 }
        exit 1
    }
    $trayReady = [CampusRecovery.StatusTray]::Start((Join-Path $Root 'status.txt'))
    Write-CampusFile (Join-Path $Root 'ready.txt') ('1.6.3|'+$PID+'|'+$trayReady+'|'+[datetime]::UtcNow.Ticks)
    try { Initialize-CampusAccountChoice } catch { Log '正在等待本次开机的账号选择。' }
    Set-CampusStatus 'check' '正在识别校园网及代理状态'
    $wake = $false
    while ($true) {
        $signalled = [CampusRecovery.StatusTray]::TakeWake()
        if ($wake -or $signalled) {
            $script:verifyAfterWake = $true; $script:fails = 0; $script:nextProxyRepair = [datetime]::MinValue
            Set-CampusStatus 'wake' '电脑刚刚唤醒，正在检查网卡、校园网和代理'
        }
        $before = [datetime]::UtcNow
        try { $delay = Invoke-MonitorPass } catch {
            Log ('监测异常，将重试：'+$_.Exception.GetType().Name)
            Set-CampusStatus 'error' '暂时无法识别网络状态，正在重试'
            $delay = 5
        }
        $gap = ([datetime]::UtcNow-$before).TotalMinutes -gt 15
        $wake = (Wait-MonitorDelay $delay) -or $gap
    }
} finally {
    try { [void](Restore-AuthNetworkContext $NetworkStatePath) }
    finally { $script:LoginGlyph.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose() }
}
