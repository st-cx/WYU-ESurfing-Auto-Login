# ============================================================
#  天翼校园自动登录工具 - 引导式按钮坐标校准 (真实点击版)
#
#  原理: 让用户在客户端上真实点击一次【登 录】按钮, 工具捕获这次点击的
#        屏幕位置, 并等到网络真的恢复(点击确实生效)才记录 —— 不靠换算猜。
#        记录两份坐标:
#          - 物理参考 phys_*  : 真实点击位置(前台点击路径直接使用, 已实测生效)
#          - 逻辑坐标 login_* : 供后台消息点击(锁屏也可用)使用
#        两份坐标 + 当时的窗口尺寸一起写入 config.json, 看门狗按窗口尺寸
#        自动换算, 适配不同电脑/DPI 缩放。
#
#  用法: 双击安装包/安装目录里的 "校准按钮坐标.bat"
#        (脚本会自动请求管理员权限; 安装时会提示做一次)
#
#  高级用法(调试/远程): -TestX <屏幕x> -TestY <屏幕y>
#        跳过真实点击捕获, 直接用给定屏幕坐标作为按钮位置(不等待验证)
# ============================================================
param(
    [int]$TestX = -1,
    [int]$TestY = -1
)

$ErrorActionPreference = 'Continue'
$testMode = ($TestX -ge 0 -and $TestY -ge 0)

function Info($m) { Write-Host ('[*] ' + $m) }
function Ok($m)   { Write-Host ('[+] ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('[!] ' + $m) -ForegroundColor Yellow }
function Err($m)  { Write-Host ('[x] ' + $m) -ForegroundColor Red }

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 自动提权 ----------
if (-not (Test-Admin)) {
    Info '请求管理员权限 (客户端以管理员运行, 需要同级权限才能操作其窗口)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($testMode) { $argList += @('-TestX', $TestX, '-TestY', $TestY) }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

Add-Type -AssemblyName System.Drawing
if (-not ([System.Management.Automation.PSTypeName]'Calib.Win32').Type) {
    Add-Type -Namespace Calib -Name Win32 -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetWindowDpiAwarenessContext(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(System.IntPtr value);
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public struct POINT { public int X; public int Y; }
"@
}
try { [Calib.Win32]::SetProcessDPIAware() | Out-Null } catch {}

# ---------- 定位安装目录与配置 ----------
$TaskName = 'CampusNetWatchdog'
$InstallDir = $null
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task -and $task.Actions.Count -gt 0) {
    $args0 = $task.Actions[0].Arguments
    if ($args0 -match '-File\s+"([^"]+)"') {
        $InstallDir = Split-Path -Parent $Matches[1]
    }
}
if (-not $InstallDir -and $PSScriptRoot) {
    $parent = Split-Path -Parent $PSScriptRoot
    if (Test-Path (Join-Path $parent 'watchdog.ps1')) { $InstallDir = $parent }
}
if (-not $InstallDir) {
    Err '未找到安装目录 (计划任务 CampusNetWatchdog 不存在, 请先运行 一键安装.bat)'
    if (-not $testMode) { Read-Host '按回车退出' }
    exit 1
}
$ConfigPath = Join-Path $InstallDir 'config.json'
Info ('配置位置: ' + $ConfigPath)

$Config = [ordered]@{
    client_dir       = 'C:\Program Files (x86)\Chinatelecom_GDPortal'
    login_btn_x      = 267
    login_btn_y      = 533
    calib_win_w      = 533
    calib_win_h      = 914
    disconnect_btn_y = 610
}
if (Test-Path $ConfigPath) {
    try {
        $old = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $old.PSObject.Properties) { $Config[$p.Name] = $p.Value }
    } catch { Warn 'config.json 解析失败, 使用默认值' }
}

function Find-ClientWebWindow {
    $script:foundHwnd = [IntPtr]::Zero
    $procs = Get-Process -Name 'ESurfingClient' -ErrorAction SilentlyContinue
    if (-not $procs) { return $script:foundHwnd }
    $pids = @($procs | ForEach-Object { $_.Id })
    $cb = [Calib.Win32+EnumProc]{
        param($h, $l)
        $procId = 0
        [Calib.Win32]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        if ($pids -contains [int]$procId) {
            $sb = New-Object System.Text.StringBuilder 128
            [Calib.Win32]::GetClassName($h, $sb, 128) | Out-Null
            if ($sb.ToString() -eq 'wkeWebWindow') { $script:foundHwnd = $h; return $false }
        }
        return $true
    }
    [Calib.Win32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $script:foundHwnd
}

function Test-Internet {
    foreach ($t in @(@{ip='223.5.5.5';port=443}, @{ip='119.29.29.29';port=53}, @{ip='114.114.114.114';port=53})) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $c.BeginConnect($t.ip, $t.port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000) -and $c.Connected) { $c.Close(); return $true }
        } catch {} finally { try { $c.Close() } catch {} }
    }
    return $false
}

function Get-WindowAwareness([IntPtr]$h) {
    try {
        $ctx = [Calib.Win32]::GetWindowDpiAwarenessContext($h)
        if ($ctx -eq [IntPtr]::Zero) { return -1 }
        return [Calib.Win32]::GetAwarenessFromDpiAwarenessContext($ctx)
    } catch { return -1 }
}

function Send-Click([IntPtr]$h, [int]$x, [int]$y) {
    $lp = [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
    [Calib.Win32]::PostMessage($h, 0x200, [IntPtr]0, $lp) | Out-Null
    Start-Sleep -Milliseconds 100
    [Calib.Win32]::PostMessage($h, 0x201, [IntPtr]1, $lp) | Out-Null
    Start-Sleep -Milliseconds 80
    [Calib.Win32]::PostMessage($h, 0x202, [IntPtr]0, $lp) | Out-Null
}

function Get-ClickPointFor([IntPtr]$h, [int]$baseX, [int]$baseY) {
    # 把 533x914 基线坐标换算成当前窗口的客户端坐标(供 PostMessage 使用)
    $r = New-Object Calib.Win32+RECT
    [Calib.Win32]::GetWindowRect($h, [ref]$r) | Out-Null
    $pw = $r.Right - $r.Left; $ph = $r.Bottom - $r.Top
    $aw = Get-WindowAwareness $h
    if ($aw -eq 0) { $lw = 533; $lh = 914 } else { $lw = $pw; $lh = $ph }
    return @([int][Math]::Round($baseX * $lw / 533), [int][Math]::Round($baseY * $lh / 914))
}

function Wait-Offline([int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Internet)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-Online([int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Internet) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Pause-Exit([int]$code) {
    if (-not $testMode) { Read-Host '按回车退出' }
    exit $code
}

Write-Host ''
Write-Host '========== 登录按钮坐标校准 (真实点击版) ==========' -ForegroundColor Cyan

# ---------- 找到并显示客户端 ----------
$h = Find-ClientWebWindow
if ($h -eq [IntPtr]::Zero) {
    Warn '客户端未运行, 尝试启动...'
    $exe = Join-Path $Config.client_dir 'ESurfingClient.exe'
    if (Test-Path $exe) {
        Start-Process -FilePath $exe -WorkingDirectory $Config.client_dir
        Start-Sleep -Seconds 12
        $h = Find-ClientWebWindow
    }
}
if ($h -eq [IntPtr]::Zero) {
    Err '仍未找到客户端主窗口, 请先启动天翼校园客户端再运行本工具'
    Pause-Exit 1
}

$rect = New-Object Calib.Win32+RECT
[Calib.Win32]::GetWindowRect($h, [ref]$rect) | Out-Null
if ($rect.Left -le -30000) {
    [Calib.Win32]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
    Start-Sleep -Milliseconds 1500
    [Calib.Win32]::GetWindowRect($h, [ref]$rect) | Out-Null
}
[Calib.Win32]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500

$physW = $rect.Right - $rect.Left
$physH = $rect.Bottom - $rect.Top
$aware = Get-WindowAwareness $h
Info ('客户端窗口: ' + $physW + 'x' + $physH + '  DPI感知=' + $aware + ' (0=不感知,1=系统,2=每显示器)')

# ---------- 确保客户端停在登录界面 ----------
$online = Test-Internet
if ($online -and -not $testMode) {
    Write-Host ''
    Write-Host '当前电脑已联网。校准需要客户端停在【登 录】界面。' -ForegroundColor Yellow
    $ans = Read-Host '是否让工具帮你点一下客户端的【断 开】按钮? (会短暂断网) [Y/n]'
    if (-not $ans -or ($ans -match '^[Yy]')) {
        $dp = Get-ClickPointFor $h 267 ([int]$Config.disconnect_btn_y)
        Send-Click $h $dp[0] $dp[1]
        Info '已发送断开点击, 等待断网...'
        if (-not (Wait-Offline 30)) {
            Warn '自动断开未生效 (不同版本界面按钮位置可能不同)'
            Info '请手动在客户端上点击【断 开】按钮, 工具会继续等待...'
            if (-not (Wait-Offline 150)) {
                Err '一直未检测到断网, 无法校准。请断网后重新运行本工具'
                Pause-Exit 1
            }
        }
        Ok '已断开, 客户端现在应显示登录界面'
    } else {
        Info '请手动在客户端上点击【断 开】按钮, 工具会等待...'
        if (-not (Wait-Offline 150)) {
            Err '一直未检测到断网, 无法校准。请断网后重新运行本工具'
            Pause-Exit 1
        }
        Ok '已断开'
    }
} elseif ($online -and $testMode) {
    Info '当前在线 (测试模式跳过断开步骤)'
}

# ---------- 用户真实点击一次, 捕获点击位置 ----------
if ($testMode) {
    Info ('测试模式: 直接使用屏幕坐标 (' + $TestX + ',' + $TestY + ')')
    $clickPt = @{ X = $TestX; Y = $TestY }
    $verified = $false
} else {
    Write-Host ''
    Write-Host '请用鼠标点击客户端上的【登 录】按钮 (点完即可, 不用移动鼠标)。' -ForegroundColor Yellow
    Write-Host '工具会自动捕获这次点击的位置, 并等待网络恢复以验证。'
    Write-Host '(若 3 分钟内未检测到点击, 可把鼠标停在按钮中心后按回车, 用悬停方式记录)'
    Write-Host ''
    $clickPt = $null
    $wasDown = $false
    $enterUsed = $false
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $state = [int][Calib.Win32]::GetAsyncKeyState(0x01)   # VK_LBUTTON
        $down = (($state -band 0x8000) -ne 0)
        if ($down) { $wasDown = $true }
        elseif ($wasDown) {
            $wasDown = $false
            $pt0 = New-Object Calib.Win32+POINT
            [Calib.Win32]::GetCursorPos([ref]$pt0) | Out-Null
            $ox0 = $pt0.X - $rect.Left
            $oy0 = $pt0.Y - $rect.Top
            if ($ox0 -ge 0 -and $oy0 -ge 0 -and $ox0 -le $physW -and $oy0 -le $physH) {
                $clickPt = @{ X = $pt0.X; Y = $pt0.Y }
                Ok ('检测到点击: 相对窗口 (' + $ox0 + ',' + $oy0 + ')')
                break
            } else {
                Warn '检测到点击, 但不在客户端窗口内 (可能点到了本窗口), 请点击客户端上的【登 录】按钮'
            }
        }
        $enter = [int][Calib.Win32]::GetAsyncKeyState(0x0D)   # VK_RETURN
        if (($enter -band 0x8000) -ne 0) {
            $pt0 = New-Object Calib.Win32+POINT
            [Calib.Win32]::GetCursorPos([ref]$pt0) | Out-Null
            $clickPt = @{ X = $pt0.X; Y = $pt0.Y }
            $enterUsed = $true
            Ok '使用当前鼠标位置 (悬停方式)'
            break
        }
        Start-Sleep -Milliseconds 40
    }
    if (-not $clickPt) {
        Err '未检测到点击, 已超时'
        Pause-Exit 1
    }

    # ---------- 验证: 等网络真的恢复 ----------
    if (-not $enterUsed) {
        Info '等待网络恢复以验证点击确实生效 (最多 75 秒)...'
        $verified = Wait-Online 75
        if ($verified) { Ok '验证通过: 网络已恢复, 这次点击的位置确认为登录按钮!' }
        else {
            Warn '点击后 75 秒内网络未恢复'
            $choice = Read-Host '可能没点中按钮。 [r] 重新点一次 / [s] 仍然保存 / [c] 取消 (默认 s)'
            if ($choice -match '^[Rr]') {
                Info '请重新运行本工具, 再点一次'
                Pause-Exit 0
            } elseif ($choice -match '^[Cc]') {
                Warn '已取消, 未做任何修改'
                Pause-Exit 0
            }
        }
    } else {
        Info '悬停方式记录, 不再自动验证'
        $verified = $false
    }
}

$ox = $clickPt.X - $rect.Left
$oy = $clickPt.Y - $rect.Top
if ($aware -eq 0) {
    $logicalW = 533; $logicalH = 914     # 不感知的客户端坐标空间恒定
    $scale = $physW / [double]533
    $lx = [int][Math]::Round($ox / $scale)
    $ly = [int][Math]::Round($oy / $scale)
} else {
    $logicalW = $physW; $logicalH = $physH
    $lx = $ox; $ly = $oy
}

Write-Host ''
Ok ('记录结果: 真实点击位置 相对窗口 物理(' + $ox + ',' + $oy + ')  ->  后台点击坐标(逻辑)(' + $lx + ',' + $ly + ')')
Info ('窗口尺寸: 物理 ' + $physW + 'x' + $physH + ', 逻辑基线 ' + $logicalW + 'x' + $logicalH)
if ($verified) { Ok '该坐标已通过"网络真实恢复"验证' } else { Info '该坐标未经过网络恢复验证 (下次断网时看门狗会实测)' }

if (-not $testMode) {
    $ans = Read-Host '确认写入配置并重启看门狗? (Y/n)'
    if ($ans -and ($ans -notmatch '^[Yy]')) {
        Warn '已取消, 未做任何修改'
        Pause-Exit 0
    }
}

# ---------- 写入配置并重启看门狗 ----------
$Config['login_btn_x'] = $lx
$Config['login_btn_y'] = $ly
$Config['calib_win_w'] = $logicalW
$Config['calib_win_h'] = $logicalH
$Config['phys_btn_x'] = $ox
$Config['phys_btn_y'] = $oy
$Config['phys_win_w'] = $physW
$Config['phys_win_h'] = $physH
$Config['calib_verified'] = [bool]$verified
if (-not $Config.Contains('disconnect_btn_y')) { $Config['disconnect_btn_y'] = 610 }
$json = $Config | ConvertTo-Json
[IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
Ok ('配置已更新: ' + $ConfigPath)

if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $t2 = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t2) { Ok ('看门狗已重启, 状态: ' + $t2.State) }
}
Write-Host ''
Ok '校准完成! 以后想重新校准, 再双击一次 校准按钮坐标.bat 即可。'
if (-not $testMode) { Read-Host '按回车退出' }
