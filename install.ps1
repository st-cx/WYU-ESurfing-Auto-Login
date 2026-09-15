# ============================================================
#  五邑大学天翼校园自动登录工具 - 安装 / 卸载脚本
#
#  安装: 由 "一键安装.bat" 调用 (自动请求管理员权限)
#        会做三件事:
#          1. 自动探测天翼校园客户端安装目录和上网网卡
#          2. 把看门狗复制到 当前用户\AppData\Local\CampusNetWatchdog 并生成 config.json
#          3. 注册计划任务 CampusNetWatchdog (登录时自启, 最高权限) 并启动
#
#  卸载: 一键安装.bat 同目录的 "卸载.bat", 或: install.ps1 -Uninstall
#  调试: powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun   (只探测不安装)
# ============================================================

param(
    [switch]$DryRun,      # 只探测并打印结果, 不安装
    [switch]$Uninstall,   # 卸载
    [switch]$NoCalibrate  # 安装后不提示校准 (无人值守场景)
)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TaskName = 'CampusNetWatchdog'

function Info($m) { Write-Host ('[*] ' + $m) }
function Ok($m)   { Write-Host ('[+] ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('[!] ' + $m) -ForegroundColor Yellow }
function Err($m)  { Write-Host ('[x] ' + $m) -ForegroundColor Red }

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        Err '需要管理员权限, 请双击 "一键安装.bat" 运行 (会自动请求提权)'
        exit 1
    }
}

function Get-ConsoleUser {
    # 当前登录(控制台)用户, 防止提权到其他管理员账号时把任务装错用户
    $u = $null
    try { $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName } catch {}
    if (-not $u) { $u = "$env:USERDOMAIN\$env:USERNAME" }
    return $u
}

function Get-InstallDir([string]$consoleUser) {
    $name = $consoleUser.Split('\')[-1]
    $profileDir = $null
    try {
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -and ($_.LocalPath.Split('\')[-1] -ieq $name) } |
            Select-Object -First 1).LocalPath
    } catch {}
    if (-not $profileDir) { $profileDir = Join-Path 'C:\Users' $name }
    return (Join-Path $profileDir 'AppData\Local\CampusNetWatchdog')
}

function Find-ClientDir {
    # 1) 注册表卸载项 (最可靠, 含自定义安装路径)
    $keys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $hits = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and ($_.DisplayName -match '天翼校园|ESurfing|Chinatelecom|电信') }
    foreach ($h in $hits) {
        foreach ($field in @($h.DisplayIcon, $h.InstallLocation, $h.UninstallString)) {
            if (-not $field) { continue }
            $p = ($field -replace '"', '').Split(',')[0].Trim()
            $d = $null
            if (Test-Path -LiteralPath $p -PathType Container) { $d = $p }
            elseif (Test-Path -LiteralPath $p) { $d = Split-Path -Parent $p }
            if ($d -and (Test-Path (Join-Path $d 'ESurfingClient.exe'))) { return $d }
        }
    }
    # 2) 常见路径扫描
    $cands = @()
    foreach ($root in @('C:', 'D:', 'E:', 'F:', 'G:')) {
        $cands += "$root\software\Chinatelecom_GDPortal"
        $cands += "$root\Program Files\Chinatelecom_GDPortal"
        $cands += "$root\Program Files (x86)\Chinatelecom_GDPortal"
        $cands += "$root\Chinatelecom_GDPortal"
    }
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c 'ESurfingClient.exe')) { return $c }
    }
    return $null
}

function Find-Adapter {
    $skip = 'Hyper-V|VMware|Virtual|Loopback|TAP|VPN|Bluetooth|WAN Miniport|Kernel Debug'
    $cands = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch $skip })
    if ($cands.Count -eq 0) { return $null }
    $wired = @($cands | Where-Object { $_.MediaType -eq '802.3' })
    $pool = $cands
    if ($wired.Count -gt 0) { $pool = $wired }
    foreach ($a in $pool) {
        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' }
        if ($ip) { return $a.Name }
    }
    return $pool[0].Name
}

# ==================== 卸载 ====================
if ($Uninstall) {
    Assert-Admin
    $consoleUser = Get-ConsoleUser
    $installDir = Get-InstallDir $consoleUser
    Info ('结束并删除计划任务: ' + $TaskName)
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $installDir) {
        Info ('删除安装目录: ' + $installDir)
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Ok '卸载完成'
    exit 0
}

# ==================== 探测 ====================
Info '检测天翼校园客户端安装位置...'
$clientDir = Find-ClientDir
if (-not $clientDir) {
    Warn '未能自动找到客户端 (需要 ESurfingClient.exe 所在目录)'
    Warn '请先安装并登录一次 "天翼校园客户端", 然后重新运行本安装程序'
    $clientDir = Read-Host '也可手动输入客户端安装目录 (直接回车取消)'
    if (-not $clientDir) { exit 1 }
    $clientDir = $clientDir.Trim().Trim('"')
    if (-not (Test-Path (Join-Path $clientDir 'ESurfingClient.exe'))) {
        Err ('该目录下没有 ESurfingClient.exe: ' + $clientDir)
        exit 1
    }
}
Ok ('客户端目录: ' + $clientDir)

Info '检测上网网卡...'
$adapterName = Find-Adapter
if (-not $adapterName) {
    Warn '未找到正在连接的网卡, 请确认有线网线已插好'
    $adapterName = Read-Host '可手动输入网卡名称 (网络连接里看到的名称, 直接回车取消)'
    if (-not $adapterName) { exit 1 }
    $adapterName = $adapterName.Trim()
}
$upAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
if ($upAdapters.Count -gt 1) {
    Write-Host '检测到多个在用网卡:'
    for ($i = 0; $i -lt $upAdapters.Count; $i++) {
        Write-Host ('    [{0}] {1}  ({2})' -f ($i + 1), $upAdapters[$i].Name, $upAdapters[$i].InterfaceDescription)
    }
    $sel = Read-Host ('默认使用 [' + $adapterName + '], 回车确认, 或输入序号更换')
    if ($sel) {
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $upAdapters.Count) {
            $adapterName = $upAdapters[$n - 1].Name
        }
    }
}
Ok ('上网网卡: ' + $adapterName)

# ---------- 探测校园网特征 (供"离校静默"守卫: 不在校园网时不折腾) ----------
Info '探测校园网特征 (离校静默守卫)...'
$ipPrefixes = @()
try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
    foreach ($ip in $ips) {
        $parts = $ip.IPAddress.Split('.')
        if ($parts.Count -eq 4) { $ipPrefixes += ($parts[0] + '.' + $parts[1] + '.') }
    }
    $ipPrefixes = @($ipPrefixes | Select-Object -Unique)
} catch {}
$gateways = @()
try {
    $gateways = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
        Select-Object -ExpandProperty NextHop | Select-Object -Unique)
} catch {}

$campusGuard = $true
$privatePrefixes = @($ipPrefixes | Where-Object { $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)$' })
if ($ipPrefixes.Count -eq 0) {
    $campusGuard = $false
    Warn '未能获取本机 IP, 已关闭"离校静默"守卫 (稍后可在 config.json 手动配置)'
} elseif ($privatePrefixes.Count -eq $ipPrefixes.Count) {
    # 全是家用/普通私网地址, 判定当前可能不在校园网 → 关闭守卫(避免回校后无法自动恢复)
    $campusGuard = $false
    Warn ('当前网络看起来不是校园网 (IP前缀: ' + ($ipPrefixes -join ',') + '), 已关闭"离校静默"守卫;')
    Warn '  如果你现在就在校园网, 可重新运行安装, 或稍后在 config.json 设置 campus_guard=true'
}

$consoleUser = Get-ConsoleUser
$installDir = Get-InstallDir $consoleUser

if ($DryRun) {
    Info '===== DryRun 结果 (未做任何改动) ====='
    Info ('管理员权限: ' + (Test-Admin))
    Info ('安装用户:   ' + $consoleUser)
    Info ('安装目录:   ' + $installDir)
    Info ('客户端目录: ' + $clientDir)
    Info ('上网网卡:   ' + $adapterName)
    Info ('离校守卫:   启用=' + $campusGuard + ' 前缀=[' + ($ipPrefixes -join ',') + '] 网关=[' + ($gateways -join ',') + ']')
    exit 0
}

# ==================== 安装 ====================
Assert-Admin

Info ('安装到: ' + $installDir)
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $installDir 'tools') -Force | Out-Null

Copy-Item (Join-Path $Here 'watchdog.ps1') $installDir -Force
$probe = Join-Path $Here 'tools\uia-probe.ps1'
if (Test-Path $probe) { Copy-Item $probe (Join-Path $installDir 'tools') -Force }
$calib = Join-Path $Here 'tools\calibrate.ps1'
if (Test-Path $calib) { Copy-Item $calib (Join-Path $installDir 'tools') -Force }

# 生成"校准按钮坐标.bat"到安装目录 (方便日后重新校准, 不依赖安装包)
# 注意: bat 内容必须为纯 ASCII —— cmd 在部分代码页下解析含非 ASCII 的批处理
# 会错位(乱码/执行残片), 中文提示一律由 calibrate.ps1 输出
$calibBat = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\calibrate.ps1"
if errorlevel 1 (
  echo.
  pause
)
"@
$calibBat = $calibBat -replace "`r?`n", "`r`n"   # 批处理统一用 CRLF 换行
[IO.File]::WriteAllText((Join-Path $installDir '校准按钮坐标.bat'), $calibBat, (New-Object Text.UTF8Encoding($false)))

# 生成 config.json (保留用户已调过的其它项)
$cfgPath = Join-Path $installDir 'config.json'
$cfg = [ordered]@{}
if (Test-Path $cfgPath) {
    try {
        $old = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch {}
}
$cfg['client_dir'] = $clientDir
$cfg['adapter_name'] = $adapterName

# 离校静默守卫: 已有有效配置则保留(避免覆盖用户手工调整), 否则写入本次探测结果
$keepCampus = $false
if ($cfg.Contains('campus_guard') -and $cfg['campus_guard'] -eq $true -and
    (($cfg['campus_ip_prefixes'] | Where-Object { $_ }) -or ($cfg['campus_gateways'] | Where-Object { $_ }))) {
    $keepCampus = $true
}
if ($keepCampus) {
    Ok ('保留已有校园网特征: 前缀=[' + (@($cfg['campus_ip_prefixes']) -join ',') + '] 网关=[' +
        (@($cfg['campus_gateways']) -join ',') + ']')
} elseif ($campusGuard) {
    $cfg['campus_guard'] = $true
    $cfg['campus_ip_prefixes'] = $ipPrefixes
    $cfg['campus_gateways'] = $gateways
    Ok ('离校守卫已启用: 校园IP前缀=[' + ($ipPrefixes -join ',') + '] 网关=[' + ($gateways -join ',') + ']')
    Info '  (带电脑去其他地方/连热点时, 探测失败也不会重启客户端或动网卡)'
} else {
    $cfg['campus_guard'] = $false
}

$json = $cfg | ConvertTo-Json
[IO.File]::WriteAllText($cfgPath, $json, (New-Object Text.UTF8Encoding($false)))
Ok ('配置已写入: ' + $cfgPath)

Info '注册计划任务 (登录时自启, 最高权限)...'
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue   # 若旧实例在运行先结束
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
               (Join-Path $installDir 'watchdog.ps1') + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $consoleUser
$trigger.Delay = 'PT20S'
$principal = New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) { Ok ('计划任务状态: ' + $t.State) } else { Warn '计划任务创建异常, 请截图反馈' }

$log = Join-Path $installDir 'logs\watchdog.log'
if (Test-Path $log) {
    Ok '看门狗已开始工作, 最近日志:'
    Get-Content $log -Tail 3 | ForEach-Object { Write-Host ('    ' + $_) }
}

Write-Host ''
Ok '安装完成! 现在起会自动监测断网并自动登录, 无需再手动点登录。'

# ---------- 首次使用引导: 真实点击校准 ----------
if (-not $NoCalibrate) {
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ' 是否现在做一次"登录按钮校准"? (推荐, 约 1 分钟)' -ForegroundColor Yellow
    Write-Host ' 校准过程: 工具帮你断开网络 -> 你手动点击一次客户端上的【登 录】'
    Write-Host '           -> 工具自动记录这次真实点击的位置并验证'
    Write-Host ' 作用: 适配你这台电脑的窗口尺寸/缩放, 保证断网后能自动点中按钮。'
    Write-Host ' 跳过也没关系: 以后随时双击安装目录里的 校准按钮坐标.bat 重做。' -ForegroundColor DarkGray
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    $ans = Read-Host '现在校准? [Y/n]'
    if (-not $ans -or ($ans -match '^[Yy]')) {
        $calibScript = Join-Path $installDir 'tools\calibrate.ps1'
        if (Test-Path $calibScript) {
            & $calibScript
        } else {
            Warn '未找到校准脚本, 可稍后双击 校准按钮坐标.bat'
        }
    } else {
        Info '已跳过校准, 之后可随时双击 校准按钮坐标.bat 校准'
    }
}

Write-Host ''
Info ('日志目录: ' + (Join-Path $installDir 'logs'))
Info '常用命令: 在本目录放 command.txt 写 status / bounce / disconnect / shot / click x y'
Info ('重新校准: 双击 ' + (Join-Path $installDir '校准按钮坐标.bat'))
Info '卸载: 双击同目录 "卸载.bat"'
