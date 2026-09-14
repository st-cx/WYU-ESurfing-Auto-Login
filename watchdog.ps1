# ============================================================
#  五邑大学天翼校园自动登录工具 - 看门狗主程序
#  适用于: 五邑大学天翼校园客户端 (广东电信 GDPortal / ESurfingClient)
#
#  功能:
#    - 每 check_interval_sec 秒探测外网连通性
#    - 连续 fail_threshold 次失败判定断网, 自动执行恢复梯子:
#        第1级: 重启客户端 + 后台点击"登 录"按钮 (不抢鼠标, 锁屏也有效)
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
    [switch]$Check   # 仅执行一次探活并输出状态后退出 (调试用)
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
    check_interval_sec      = 20
    fail_threshold          = 2
    probe_timeout_ms        = 2000
    nic_bounce_cooldown_sec = 180
    client_start_wait_sec   = 12
    auth_settle_wait_sec    = 75
    probe_targets           = @(
        @{ ip = '223.5.5.5';       port = 443 },
        @{ ip = '119.29.29.29';    port = 53 },
        @{ ip = '114.114.114.114'; port = 53 }
    )
}
$configPath = Join-Path $Root 'config.json'
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
$ClientStartWaitSec = [int]$Config.client_start_wait_sec
$AuthSettleWaitSec  = [int]$Config.auth_settle_wait_sec
$ProbeTargets       = $Config.probe_targets

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
    foreach ($t in $ProbeTargets) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $c.BeginConnect($t.ip, $t.port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($ProbeTimeoutMs) -and $c.Connected) {
                $c.Close(); return $true
            }
        } catch {} finally { try { $c.Close() } catch {} }
    }
    return $false
}

function Find-ClientWebWindow {
    # 返回客户端 miniblink 主窗口 (class=wkeWebWindow) 的句柄
    $script:foundHwnd = [IntPtr]::Zero
    $procs = Get-Process -Name $ClientProc -ErrorAction SilentlyContinue
    if (-not $procs) { return $script:foundHwnd }
    $pids = @($procs | ForEach-Object { $_.Id })
    $cb = [CampusWatch.Win32+EnumProc]{
        param($h, $l)
        $procId = 0
        [CampusWatch.Win32]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        if ($pids -contains [int]$procId) {
            $sb = New-Object System.Text.StringBuilder 256
            [CampusWatch.Win32]::GetClassName($h, $sb, 256) | Out-Null
            if ($sb.ToString() -eq 'wkeWebWindow') { $script:foundHwnd = $h; return $false }
        }
        return $true
    }
    [CampusWatch.Win32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $script:foundHwnd
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
    try {
        $rect = Get-WindowRectSafe $h
        if ($rect.Left -le -30000) { return }
        $wd = $rect.Right - $rect.Left; $ht = $rect.Bottom - $rect.Top
        if ($wd -le 50 -or $ht -le 50 -or $wd -gt 4000) { return }
        $bmp = New-Object System.Drawing.Bitmap($wd, $ht)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
        $g.Dispose()
        $f = Join-Path $LogDir ('shot-' + $tag + '-' + (Get-Date -Format 'MMdd-HHmmss') + '.png')
        $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Log ('已保存截图 ' + (Split-Path $f -Leaf))
        Get-ChildItem (Join-Path $LogDir 'shot-*.png') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
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

function Send-RealClick {
    param([IntPtr]$h)
    $rect = Restore-ClientWindow $h
    if (-not $rect) { Log '客户端窗口无法恢复到前台'; return $false }
    Save-WindowShot $h 'pre-click'
    $physW = $rect.Right - $rect.Left; $physH = $rect.Bottom - $rect.Top
    $src = '换算'
    if ($HasPhysRef) {
        # 校准工具记录的真实点击位置(已实测生效), 按窗口尺寸等比换算
        $px = [int][Math]::Round($PhysBtnX * $physW / $PhysWinW)
        $py = [int][Math]::Round($PhysBtnY * $physH / $PhysWinH)
        $src = '真实点击参考'
    } else {
        $p = Get-ClickPoints $h
        $px = $p.physX; $py = $p.physY
    }
    $sx = $rect.Left + $px; $sy = $rect.Top + $py
    [CampusWatch.Win32]::SetCursorPos($sx, $sy) | Out-Null
    Start-Sleep -Milliseconds 200
    [CampusWatch.Win32]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)   # LEFTDOWN
    [CampusWatch.Win32]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)   # LEFTUP
    Log ('已前台点击 (' + $sx + ',' + $sy + ') [' + $src + ']')
    Start-Sleep -Seconds 3
    [CampusWatch.Win32]::ShowWindow($h, 6) | Out-Null               # SW_MINIMIZE 收回托盘
    return $true
}

function Invoke-LoginClick {
    $h = Find-ClientWebWindow
    if ($h -eq [IntPtr]::Zero) { Log '未找到客户端主窗口(wkeWebWindow)'; return $false }

    # 1) 后台点击 (不打扰用户)
    Save-WindowShot $h 'pre-bgclick'
    $p = Get-ClickPoints $h
    Send-ClickToWindow $h $p.lpX $p.lpY
    Log ('已发送后台点击 (客户端坐标 ' + $p.lpX + ',' + $p.lpY + ')')
    Start-Sleep -Seconds 6
    if (Test-Internet) {
        Log '后台点击已生效, 网络恢复'
        [CampusWatch.Win32]::ShowWindow($h, 6) | Out-Null   # 收回最小化
        return $true
    }

    # 2) 前台真实点击
    Log '后台点击未生效, 改用前台真实点击'
    return (Send-RealClick $h)
}

function Wait-AuthSettle {
    # 点击/重启后耐心等客户端完成认证, 避免过早重启打断它的登录流程
    $deadline = (Get-Date).AddSeconds($AuthSettleWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Internet) { return $true }
        Start-Sleep -Seconds 8
    }
    return (Test-Internet)
}

function Restart-Client {
    Log '重启天翼校园客户端'
    try {
        Get-Process -Name $ClientProc -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    } catch {}
    try {
        Start-Process -FilePath $ClientExe -WorkingDirectory $ClientDir
    } catch {
        Log ('客户端启动失败: ' + $_.Exception.Message)
    }
    Start-Sleep -Seconds $ClientStartWaitSec
}

function Wait-AdapterUp {
    param([int]$TimeoutSec = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $ad = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
            if ($ad.Status -eq 'Up') {
                $ip = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($ip) { return $true }
            }
        } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

function Repair-NicAdapter {
    Log ('禁用并重新启用网卡: ' + $AdapterName)
    try {
        Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 4
        Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
    } catch {
        Log ('网卡操作失败: ' + $_.Exception.Message)
        return $false
    }
    $up = Wait-AdapterUp -TimeoutSec 45
    Log ('网卡恢复状态: ' + $up)
    return $up
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
            } else { Log 'disconnect: 未找到客户端窗口' }
        }
        'shot' {
            $h = Find-ClientWebWindow
            if ($h -ne [IntPtr]::Zero) {
                Restore-ClientWindow $h | Out-Null
                Save-WindowShot $h 'manual'
                Start-Sleep -Milliseconds 300
                [CampusWatch.Win32]::ShowWindow($h, 6) | Out-Null
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

# ---------- 调试模式: 只探活一次 ----------
if ($Check) {
    $ad = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    $adStatus = '未找到'
    if ($ad) { $adStatus = $ad.Status }
    Write-Output ('在线:   ' + (Test-Internet))
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
    exit 0
}

# ---------- 单实例保护 ----------
$mutex = New-Object System.Threading.Mutex($false, 'Global\CampusNetWatchdogMutex')
if (-not $mutex.WaitOne(0)) { exit 0 }

# ---------- 主循环 ----------
Log '===== 校园网看门狗启动 ====='
$fails = 0
$lastBounce = Get-Date '2000-01-01'

while ($true) {
    Invoke-CommandFile

    if (Test-Internet) {
        if ($fails -ge $FailThreshold) { Log '网络已恢复, 回到正常监测' }
        $fails = 0
        Start-Sleep -Seconds $CheckIntervalSec
        continue
    }

    $fails++
    if ($fails -lt $FailThreshold) {
        Start-Sleep -Seconds $CheckIntervalSec
        continue
    }

    Log '连续探测失败, 判定断网, 开始自动恢复'
    Send-Toast '检测到断网, 正在自动登录...'

    # ---- 第 1 级: 重启客户端 + 自动点击登录 ----
    Restart-Client
    Invoke-LoginClick | Out-Null
    if (Wait-AuthSettle) {
        Log '恢复成功 (重启客户端/点击登录)'
        Send-Toast '校园网已自动恢复上网'
        $fails = 0
        Start-Sleep -Seconds $CheckIntervalSec
        continue
    }
    Log '第1级恢复未成功'

    # ---- 第 2 级: 网卡禁用/启用 (带冷却) ----
    $cooldownOk = ((Get-Date) - $lastBounce).TotalSeconds -gt $NicBounceCooldown
    if ($cooldownOk) {
        $lastBounce = Get-Date
        Repair-NicAdapter | Out-Null
        Send-Toast '已重启网卡, 正在重新登录...'
        Restart-Client
        Invoke-LoginClick | Out-Null
        if (Wait-AuthSettle) {
            Log '恢复成功 (网卡重启后登录)'
            Send-Toast '校园网已自动恢复上网'
            $fails = 0
            Start-Sleep -Seconds $CheckIntervalSec
            continue
        }
        Log '第2级恢复未成功, 稍后继续重试'
    } else {
        Log '网卡重启冷却中, 本轮跳过'
    }

    $fails = 1   # 让梯子约40秒后重走
    Start-Sleep -Seconds $CheckIntervalSec
}
