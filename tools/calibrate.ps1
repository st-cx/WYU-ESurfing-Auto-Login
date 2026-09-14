# ============================================================
#  天翼校园自动登录工具 - 引导式按钮坐标校准
#
#  作用: 记录"登 录"按钮在客户端窗口中的位置并写入 config.json,
#        适配不同电脑的窗口尺寸 / DPI 缩放(125%、150%) 等情况。
#        校准后可选立即验证(自动发一次点击, 看网络是否恢复)。
#
#  用法: 双击安装包/安装目录里的 "校准按钮坐标.bat"
#        (脚本会自动请求管理员权限)
#
#  高级用法(调试/远程): -TestX <屏幕x> -TestY <屏幕y>
#        跳过"移动鼠标+回车"步骤, 直接用给定屏幕坐标作为按钮位置
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
    if ($TestX -ge 0 -and $TestY -ge 0) { $argList += @('-TestX', $TestX, '-TestY', $TestY) }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

Add-Type -AssemblyName System.Drawing
if (-not ([System.Management.Automation.PSTypeName]'Calib.Win32').Type) {
    Add-Type -Namespace Calib -Name Win32 -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
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
    client_dir  = 'C:\Program Files (x86)\Chinatelecom_GDPortal'
    login_btn_x = 267
    login_btn_y = 533
    calib_win_w = 533
    calib_win_h = 914
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

Write-Host ''
Write-Host '========== 登录按钮坐标校准 ==========' -ForegroundColor Cyan

$testMode = ($TestX -ge 0 -and $TestY -ge 0)
function Pause-Exit([int]$code) {
    if (-not $testMode) { Read-Host '按回车退出' }
    exit $code
}

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

# 显示窗口
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

$online = Test-Internet
$pt = New-Object Calib.Win32+POINT
if ($testMode) {
    Info ('测试模式: 直接使用屏幕坐标 (' + $TestX + ',' + $TestY + ')')
    $pt.X = $TestX; $pt.Y = $TestY
} else {
    Write-Host ''
    Write-Host '请按下面三步操作:' -ForegroundColor Yellow
    Write-Host '  1) 让客户端显示【登 录】界面 —— 如果现在显示"已连接"，'
    Write-Host '     请先在客户端上点一下【断 开】按钮'
    Write-Host '  2) 把鼠标移到【登 录】按钮的正中心（只移动，不要点击）'
    Write-Host '  3) 然后回到本窗口，按回车键记录坐标'
    if ($online) {
        Write-Host '  (提示: 当前网络在线, 校准后无法自动验证; 断开后再校准可验证)' -ForegroundColor DarkYellow
    }
    Write-Host ''
    Read-Host '把鼠标停在【登 录】按钮中心, 然后在这里按回车'
    [Calib.Win32]::GetCursorPos([ref]$pt) | Out-Null
}
$ox = $pt.X - $rect.Left
$oy = $pt.Y - $rect.Top

if ($ox -lt 0 -or $oy -lt 0 -or $ox -gt $physW -or $oy -gt $physH) {
    Err ('鼠标不在客户端窗口内 (相对窗口位置 ' + $ox + ',' + $oy + '), 请重试')
    Pause-Exit 1
}

# 换算到客户端自身坐标空间(供后台点击使用)
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
Ok ('记录成功: 相对窗口 物理(' + $ox + ',' + $oy + ')  ->  客户端坐标(' + $lx + ',' + $ly + ')')
Info ('当前窗口逻辑尺寸 ' + $logicalW + 'x' + $logicalH + ', 将作为校准基线写入配置')
if (-not $testMode) {
    $ans = Read-Host '确认写入配置并重启看门狗? (Y/n)'
    if ($ans -and ($ans -notmatch '^[Yy]')) {
        Warn '已取消, 未做任何修改'
        Pause-Exit 0
    }
}

# ---------- 可选: 立即验证 ----------
if (-not $online) {
    $ans2 = 'n'
    if (-not $testMode) {
        $ans2 = Read-Host '是否立即验证(会发送一次后台点击并等待最多45秒)? (Y/n)'
    }
    if (-not $ans2 -or ($ans2 -match '^[Yy]')) {
        Info '发送后台点击...'
        Send-Click $h $lx $ly
        $deadline = (Get-Date).AddSeconds(45)
        $got = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-Internet) { $got = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($got) { Ok '验证通过: 网络已恢复, 坐标正确!' }
        else { Warn '验证未通过: 45秒内网络未恢复。请确认(1)客户端处于登录界面 (2)鼠标停在按钮正中心, 可重新运行本工具校准' }
    }
} else {
    Info '当前在线, 跳过验证 (验证需要客户端停在登录界面)'
}

# ---------- 写入配置并重启看门狗 ----------
$Config['login_btn_x'] = $lx
$Config['login_btn_y'] = $ly
$Config['calib_win_w'] = $logicalW
$Config['calib_win_h'] = $logicalH
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
Ok '校准完成!'
if (-not $testMode) { Read-Host '按回车退出' }
