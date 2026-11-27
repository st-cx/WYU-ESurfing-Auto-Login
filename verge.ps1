# Shared by the resident watchdog and the optional CampusNetAuto logon task.
$script:CampusModuleDir = $PSScriptRoot

function Initialize-CampusNative {
    if ('CampusRecovery.LanProxy' -as [type]) { return }
    $sources = @('LanProxy.cs','LoginScreen.cs','StatusTray.cs') | ForEach-Object {
        Join-Path $script:CampusModuleDir ('ui\' + $_)
    }
    $refs = @('System.dll','System.Drawing.dll','System.Windows.Forms.dll')
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $refs = @((Get-ChildItem -Path (Join-Path $PSHOME 'ref\*.dll')).FullName)
        foreach ($name in @('System.Drawing.Common','System.Windows.Forms','System.Windows.Forms.Primitives',
                'Microsoft.Win32.SystemEvents','System.Private.Windows.Core','System.Windows.Extensions')) {
            $lib = Join-Path $PSHOME ($name+'.dll')
            if ([IO.File]::Exists($lib)) { $refs += $lib }
        }
    }
    Add-Type -Path $sources -ReferencedAssemblies $refs -ErrorAction Stop
}

function Write-CampusFile([string]$Path, [string]$Body) {
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, $Body, [Text.UTF8Encoding]::new($false))
        Initialize-CampusNative
        [CampusRecovery.FileCommit]::Replace($tmp,$Path)
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Set-CampusStatus([string]$Phase, [string]$Message) {
    $body = $Phase + [Environment]::NewLine + $Message
    $file = Join-Path $script:CampusModuleDir 'status.txt'
    try {
        if ([IO.File]::Exists($file) -and [IO.File]::ReadAllText($file) -ceq $body) { return }
        Write-CampusFile $file $body
        Write-NetworkLog $Message
    } catch { Write-Verbose '状态显示稍后刷新。' }
}

function Get-VergeExecutable {
    if ($script:VergeExecutable -and [IO.File]::Exists($script:VergeExecutable)) { return $script:VergeExecutable }
    $prefs = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\verge.yaml'
    if (-not [IO.File]::Exists($prefs)) { return }
    $running = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId -and $_.Path } | Select-Object -First 1
    $candidates = @($running.Path)
    foreach ($key in @('HKCU:\Software','HKLM:\Software','HKLM:\Software\WOW6432Node')) {
        $item = Get-ItemProperty -LiteralPath ($key+'\Microsoft\Windows\CurrentVersion\Uninstall\Clash Verge') -ErrorAction SilentlyContinue
        if ($item.InstallLocation) { $candidates += [IO.Path]::Combine($item.InstallLocation.Trim('"'),'clash-verge.exe') }
        if ($item.DisplayIcon) { $candidates += (($item.DisplayIcon -replace ',[-0-9]+$','').Trim('"')) }
    }
    foreach ($dir in @($env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ($dir) { $candidates += Join-Path $dir 'Clash Verge\clash-verge.exe' }
    }
    foreach ($p in $candidates) {
        if ($p -and [IO.File]::Exists($p) -and [IO.Path]::GetFileName($p) -ieq 'clash-verge.exe') {
            $script:VergeExecutable = [IO.Path]::GetFullPath($p)
            return $script:VergeExecutable
        }
    }
}

function Read-VergePreferences {
    $base = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
    $yaml = [IO.File]::ReadAllText((Join-Path $base 'verge.yaml'))
    $port = [regex]::Match($yaml,'(?m)^verge_mixed_port:\s*(\d+)\b')
    [pscustomobject]@{
        proxy = $yaml -match '(?m)^enable_system_proxy:[ \t]*true\b'
        tun = $yaml -match '(?m)^enable_tun_mode:[ \t]*true\b'
        pac = $yaml -match '(?m)^proxy_auto_config:[ \t]*true\b'
        port = if ($port.Success) { [int]$port.Groups[1].Value } else { 7897 }
        runtime = Join-Path $base 'clash-verge.yaml'
    }
}

function Get-SelectedVergeExecutable([string]$ClashConfigPath) {
    if ($ClashConfigPath) {
        $runtime = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
        if ([IO.Path]::GetFullPath($ClashConfigPath) -ine [IO.Path]::GetFullPath($runtime)) { return }
    }
    return (Get-VergeExecutable)
}

function Get-VergeGui([string]$Exe) {
    Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq [Diagnostics.Process]::GetCurrentProcess().SessionId -and $_.Path -ieq $Exe
    }
}

function Test-VergePort([int]$Port) {
    $tcp = [Net.Sockets.TcpClient]::new()
    try { return $tcp.ConnectAsync([Net.IPAddress]::Loopback,$Port).Wait(750) -and $tcp.Connected }
    catch { return $false } finally { $tcp.Dispose() }
}

function Read-LanSettings { Initialize-CampusNative; return [CampusRecovery.LanProxy]::Read() }
function Disable-LanProxy { [CampusRecovery.LanProxy]::Direct() }
function Set-LanSettings($Value) {
    $options = New-Object CampusRecovery.LanSettings
    foreach ($key in @('Flags','Server','Bypass','Pac')) { $options.$key = $Value.$key }
    [CampusRecovery.LanProxy]::Restore($options)
}
function Convert-LanSnapshot([string]$Value,[switch]$Open) {
    Add-Type -AssemblyName System.Security
    $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
    if ($Open) {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value),$null,$scope)
        return [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    }
    $bytes = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Value),$null,$scope)
    return [Convert]::ToBase64String($bytes)
}

function New-VergeRecoveryState([string]$Exe,[bool]$Repair) {
    $prefs = Read-VergePreferences
    $gui = [bool](Get-VergeGui $Exe)
    $lan = Read-LanSettings
    $core = $null
    $controller = Get-LocalClashController $prefs.runtime
    if ($controller) { try { $core = Invoke-ClashApi $controller } catch {} }
    $service = Get-Service -Name 'clash_verge_service' -ErrorAction SilentlyContinue
    $activeTun = Test-ClashTunActive
    if ($core -and $core.tun) { $activeTun = $activeTun -or [bool]$core.tun.enable }
    $usePrefs = $Repair -or -not $gui
    return [pscustomobject]@{
        version = 2; exe = $Exe; runtime = $prefs.runtime; port = $prefs.port
        restart_gui = $gui -or $prefs.proxy -or $prefs.tun -or $activeTun -or [bool]$core
        service_running = [bool]($service -and $service.Status -eq 'Running')
        tun = $activeTun -or ($usePrefs -and $prefs.tun)
        mode = [string]$core.mode
        # When the GUI died, its intended proxy may be absent from Windows. Let it rebuild that entry.
        rebuild_proxy = [bool]($usePrefs -and $prefs.proxy -and -not ($lan.Flags -band 6))
        pac_mode = $prefs.pac
        lan = Convert-LanSnapshot ($lan | ConvertTo-Json -Compress)
        restore_failures = 0; last_relaunch = 0
    }
}

function Stop-VergeForLogin($State) {
    $gui = @(Get-VergeGui $State.exe)
    if ($gui.Count) { $gui | Stop-Process -Force -ErrorAction Stop }
    $service = Get-Service -Name 'clash_verge_service' -ErrorAction SilentlyContinue
    if ($State.service_running -and $service -and $service.Status -ne 'Stopped') {
        Stop-Service -InputObject $service -ErrorAction Stop
    }
    # Stop only this installation's remaining sidecar. The old CFW service is a separate product.
    $dirs = @([IO.Path]::GetDirectoryName($State.exe), (Join-Path $env:ProgramData 'clash-verge-service\bin'))
    Get-Process -Name 'verge-mihomo','verge-mihomo-alpha' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $dirs -contains [IO.Path]::GetDirectoryName($_.Path) } |
        Stop-Process -Force -ErrorAction Stop
}

function Save-VergeLanChanges([string]$StatePath,$State,$Lan) {
    $saved = Convert-LanSnapshot $State.lan -Open
    if ($State.direct_lan) {
        $direct = Convert-LanSnapshot $State.direct_lan -Open
    } else {
        # Journals from an older release contain only the original LAN state.
        $direct = $saved.PSObject.Copy()
        $direct.Flags = 1
    }
    $changed = @('Flags','Server','Bypass','Pac' | Where-Object { [string]$Lan.$_ -cne [string]$direct.$_ })
    if (-not $changed.Count) { return }
    if (Get-VergeGui $State.exe) {
        # A late automatic Verge launch can put its own local endpoint back.
        $localProxy = '^(?:127\.0\.0\.1|localhost|\[::1\]):' + $State.port + '$'
        $vergeProxy = ($Lan.Flags -band 2) -and $Lan.Server -match $localProxy
        $vergePac = ($Lan.Flags -band 4) -and $Lan.Pac -and $Lan.Pac -ceq $saved.Pac
        if ($vergeProxy -or $vergePac) { return }
    }
    foreach ($key in $changed) { $saved.$key = $Lan.$key }
    $State.lan = Convert-LanSnapshot ($saved | ConvertTo-Json -Compress)
    $State.rebuild_proxy = $false
    Save-AuthNetworkState $StatePath $State
}

function Suspend-VergeContext($State,[string]$StatePath) {
    Set-CampusStatus 'proxy-off' '正在暂停 Clash Verge、系统代理和 TUN'
    Stop-VergeForLogin $State
    $until = [datetime]::UtcNow.AddSeconds(12)
    do {
        $lan = Read-LanSettings
        if ($lan.Flags -band 14) { Disable-LanProxy }
        $direct = Read-LanSettings
        if (-not ($direct.Flags -band 14) -and -not (Test-ClashTunActive) -and
            -not (Test-VergePort $State.port) -and -not (Get-VergeGui $State.exe)) {
            $snapshot = Convert-LanSnapshot ($direct | ConvertTo-Json -Compress)
            $State | Add-Member -Force -NotePropertyName direct_lan -NotePropertyValue $snapshot
            Save-AuthNetworkState $StatePath $State
            return
        }
        Start-Sleep -Milliseconds 400
    } while ([datetime]::UtcNow -lt $until)
    throw '系统代理、代理端口或 TUN 仍然活动。'
}

function Open-VergeGui([string]$Exe) {
    if (-not [IO.File]::Exists($Exe) -or [IO.Path]::GetFileName($Exe) -ine 'clash-verge.exe') { throw '未找到 Clash Verge。' }
    $shell = New-Object -ComObject Shell.Application
    try { $shell.ShellExecute($Exe,'',[IO.Path]::GetDirectoryName($Exe),'open',0) }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Restore-VergeContext([string]$StatePath,$State) {
    Set-CampusStatus 'restore' '正在恢复 Clash Verge，核对系统代理和 TUN'
    Save-VergeLanChanges $StatePath $State (Read-LanSettings)
    $saved = Convert-LanSnapshot $State.lan -Open
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($State.restore_failures -gt 0 -and ($now - [long]$State.last_relaunch) -ge 60) {
        $State.last_relaunch = $now
        Save-AuthNetworkState $StatePath $State
        Stop-VergeForLogin $State
    }
    if ($State.service_running) {
        $service = Get-Service -Name 'clash_verge_service' -ErrorAction Stop
        if ($service.Status -ne 'Running') { Start-Service -InputObject $service -ErrorAction Stop }
    }
    if ($State.restart_gui) {
        if (-not (Get-VergeGui $State.exe)) { Open-VergeGui $State.exe }
        $until = [datetime]::UtcNow.AddSeconds(30)
        do {
            if ((Get-VergeGui $State.exe) -and (Test-VergePort $State.port)) { break }
            Start-Sleep -Milliseconds 700
        } while ([datetime]::UtcNow -lt $until)
        if (-not (Get-VergeGui $State.exe) -or -not (Test-VergePort $State.port)) { throw '代理程序或本地端口尚未就绪。' }
        $controller = Get-LocalClashController $State.runtime
        $patch = @{}
        if ($controller) {
            $current = Invoke-ClashApi $controller
            if ($State.mode -and $current.mode -ne $State.mode) { $patch.mode = $State.mode }
            if ([bool]$current.tun.enable -ne $State.tun) { $patch.tun = @{enable=[bool]$State.tun} }
            if ($patch.Count) { Invoke-ClashApi $controller 'PATCH' $patch | Out-Null }
        } elseif ($State.mode) { throw '等待本地控制器核验原模式。' }
        $until = [datetime]::UtcNow.AddSeconds(10)
        do {
            $coreOk = $true
            if ($controller) {
                $current = Invoke-ClashApi $controller
                $coreOk = [bool]$current.tun.enable -eq $State.tun -and (-not $State.mode -or $current.mode -eq $State.mode)
            }
            if ($coreOk -and (Test-ClashTunActive) -eq $State.tun) { break }
            if ([datetime]::UtcNow -ge $until) { throw 'TUN 尚未恢复到原状态。' }
            Start-Sleep -Milliseconds 500
        } while ($true)
    }
    $lan = Read-LanSettings
    if ($State.rebuild_proxy) {
        $flag = if ($State.pac_mode) { 4 } else { 2 }
        if (-not ($lan.Flags -band $flag)) {
            if ($State.pac_mode) { throw '正在等待 Clash 恢复 PAC。' }
            $lan.Server = '127.0.0.1:' + $State.port
            $lan.Flags = ($lan.Flags -bor 3)
        }
        $saved = $lan
    }
    Set-LanSettings $saved
    $verified = Read-LanSettings
    if (($verified.Flags -band 14) -ne ($saved.Flags -band 14) -or
        (($saved.Flags -band 2) -and ($verified.Server -ne $saved.Server -or $verified.Bypass -ne $saved.Bypass)) -or
        (($saved.Flags -band 4) -and $verified.Pac -ne $saved.Pac)) { throw 'Windows 代理设置尚未恢复。' }
}

function Test-VergeHealth([object[]]$Targets,[int]$TimeoutMs,[string]$ClashConfigPath) {
    $exe = Get-SelectedVergeExecutable $ClashConfigPath
    if (-not $exe) { return $true }
    $prefs = Read-VergePreferences
    if (-not $prefs.proxy -and -not $prefs.tun) { return $true }
    if (-not (Get-VergeGui $exe) -or -not (Test-VergePort $prefs.port)) { return $false }
    if ($prefs.tun -and -not (Test-ClashTunActive)) { return $false }
    if (-not $prefs.proxy) { return $true }
    $lan = Read-LanSettings
    $flag = if ($prefs.pac) { 4 } else { 2 }
    if (-not ($lan.Flags -band $flag)) { return $false }
    if (-not $prefs.pac -and $lan.Server -notmatch ('(?i)(?:^|=)(?:127\.0\.0\.1|localhost|\[::1\]):' + $prefs.port + '(?:;|$)')) { return $false }
    $proxy = [Net.WebProxy]::new('http://127.0.0.1:'+$prefs.port)
    return (Test-InternetHttp -Targets $Targets -TimeoutMs $TimeoutMs -Proxy $proxy)
}
