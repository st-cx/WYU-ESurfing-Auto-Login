# ============================================================
#  天翼校园客户端 窗口探测 / 坐标测量工具 (调试用)
#
#  作用:
#    1. 列出客户端所有窗口 (类名/标题/大小)
#    2. 把客户端主窗口(wkeWebWindow)显示出来并截图保存, 便于测量
#       "登 录"按钮在窗口内的坐标 (登录页按钮一般在窗口水平中心)
#    3. 查询 UI 自动化元素 (客户端为 miniblink 自绘界面, 通常为空, 仅供确认)
#
#  用法 (需要管理员权限, 因为客户端本身以管理员运行):
#    powershell -ExecutionPolicy Bypass -File uia-probe.ps1
#
#  输出: 同目录下 uia-probe.log 和 client-window.png
# ============================================================
$ErrorActionPreference = 'Continue'
$Dir    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutLog = Join-Path $Dir 'uia-probe.log'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
if (-not ([System.Management.Automation.PSTypeName]'CampusWatch.Win32').Type) {
    Add-Type -Namespace CampusWatch -Name Win32 -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr hWndParent, EnumProc lpEnumFunc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@
}

function P([string]$s) { Add-Content -LiteralPath $OutLog -Value $s -Encoding UTF8 }

Set-Content -LiteralPath $OutLog -Value ('UIA probe start ' + (Get-Date)) -Encoding UTF8
try { [CampusWatch.Win32]::SetProcessDPIAware() | Out-Null } catch {}

$procs = Get-Process -Name ESurfingClient -ErrorAction SilentlyContinue
if (-not $procs) { P 'ESurfingClient 未运行, 请先启动天翼校园客户端'; Write-Host 'ESurfingClient 未运行'; exit }
$pids = @($procs | ForEach-Object { $_.Id })

# ---- 枚举进程的所有顶层窗口 ----
$topWindows = New-Object System.Collections.ArrayList
$cbTop = [CampusWatch.Win32+EnumProc]{
    param($h, $l)
    $procId = 0
    [CampusWatch.Win32]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
    if ($pids -contains [int]$procId) {
        $sb = New-Object System.Text.StringBuilder 256
        [CampusWatch.Win32]::GetClassName($h, $sb, 256) | Out-Null
        $cls = $sb.ToString()
        $sb2 = New-Object System.Text.StringBuilder 512
        [CampusWatch.Win32]::GetWindowText($h, $sb2, 512) | Out-Null
        [void]$topWindows.Add(@{ H = $h; Class = $cls; Title = $sb2.ToString(); Visible = [CampusWatch.Win32]::IsWindowVisible($h) })
    }
    return $true
}
[CampusWatch.Win32]::EnumWindows($cbTop, [IntPtr]::Zero) | Out-Null

foreach ($w in $topWindows) {
    $rect = New-Object CampusWatch.Win32+RECT
    [CampusWatch.Win32]::GetWindowRect($w.H, [ref]$rect) | Out-Null
    P ('TOP hwnd=' + $w.H + ' class=[' + $w.Class + '] title=[' + $w.Title + '] visible=' + $w.Visible +
       ' rect=' + $rect.Left + ',' + $rect.Top + ',' + ($rect.Right - $rect.Left) + 'x' + ($rect.Bottom - $rect.Top))
}
Write-Host ('窗口信息已写入 ' + $OutLog)

# ---- 显示主窗口(wkeWebWindow)并截图 ----
$main = ($topWindows | Where-Object { $_.Class -eq 'wkeWebWindow' } | Select-Object -First 1)
if (-not $main) {
    P '未找到 wkeWebWindow 主窗口'
    Write-Host '未找到客户端主窗口 (wkeWebWindow), 请确认客户端已启动'
    exit
}
P ('截图窗口: class=[' + $main.Class + '] title=[' + $main.Title + ']')
[CampusWatch.Win32]::ShowWindow($main.H, 9) | Out-Null   # SW_RESTORE
[CampusWatch.Win32]::SetForegroundWindow($main.H) | Out-Null
Start-Sleep -Seconds 2

$rect = New-Object CampusWatch.Win32+RECT
[CampusWatch.Win32]::GetWindowRect($main.H, [ref]$rect) | Out-Null
$wd = $rect.Right - $rect.Left; $ht = $rect.Bottom - $rect.Top
P ('窗口矩形: ' + $rect.Left + ',' + $rect.Top + ' ' + $wd + 'x' + $ht)
if ($wd -gt 50 -and $ht -gt 50 -and $wd -lt 4000) {
    try {
        $bmp = New-Object System.Drawing.Bitmap($wd, $ht)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
        $g.Dispose()
        $bmp.Save((Join-Path $Dir 'client-window.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        P ('已保存截图, 分辨率 ' + $wd + 'x' + $ht)
        Write-Host ('已保存截图 client-window.png (' + $wd + 'x' + $ht + ')')
        Write-Host '坐标换算: 假设截图里"登 录"按钮中心为 (px,py), 则 config.json 里'
        Write-Host ('  login_btn_x = px, login_btn_y = py  (窗口尺寸 ' + $wd + 'x' + $ht + ', 标准为 533x914)')
    } catch { P ('截图失败: ' + $_.Exception.Message) }
} else {
    P '窗口矩形异常, 跳过截图'
}

# ---- UIA 元素查询 (miniblink 无元素属正常) ----
try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($proc in $procs) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
        $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
        foreach ($w in $wins) {
            $els = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                              [System.Windows.Automation.Condition]::TrueCondition)
            P ('UIA 窗口 [' + $w.Current.Name + '] 元素数: ' + $els.Count)
        }
    }
} catch { P ('UIA 查询异常: ' + $_.Exception.Message) }

# ---- 恢复托盘状态 ----
Start-Sleep -Milliseconds 500
[CampusWatch.Win32]::ShowWindow($main.H, 6) | Out-Null   # SW_MINIMIZE
P '窗口已最小化还原'
P 'UIA probe done'
Write-Host '探测完成'
