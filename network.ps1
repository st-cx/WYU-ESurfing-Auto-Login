# Shared network checks. Compatible with Windows PowerShell 5.1; no external modules.
. (Join-Path $PSScriptRoot 'verge.ps1')
$script:CampusAuthMutexName = 'Global\CampusNetAuthenticationMutex'
function Test-InternetHttp {
    param(
        [object[]]$Targets = @(
            @{ url = 'http://connect.rom.miui.com/generate_204'; status = 204; body = '' },
            @{ url = 'http://wifi.vivo.com.cn/generate_204'; status = 204; body = '' },
            @{ url = 'http://www.msftconnecttest.com/connecttest.txt'; status = 200; body = 'Microsoft Connect Test' }
        ),
        [int]$TimeoutMs = 3000,
        [Net.IWebProxy]$Proxy = $null
    )
    foreach ($target in $Targets) {
        $request = $null; $response = $null; $reader = $null
        try {
            $request = [Net.HttpWebRequest]::Create([string]$target.url)
            # A local proxy / TUN can accept TCP before its upstream is available.
            # Require the actual HTTP response, never follow a captive-portal redirect.
            $request.Proxy = $Proxy
            $request.AllowAutoRedirect = $false
            $request.KeepAlive = $false
            $request.Timeout = $TimeoutMs
            $request.ReadWriteTimeout = $TimeoutMs
            $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::BypassCache)
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -ne [int]$target.status) { continue }
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $buffer = New-Object char[] 512
            $body = New-Object Text.StringBuilder
            while ($body.Length -lt 512) {
                $count = $reader.Read($buffer, 0, 512 - $body.Length)
                if ($count -eq 0) { break }
                [void]$body.Append($buffer, 0, $count)
            }
            if ($body.ToString() -ceq [string]$target.body) { return $true }
        } catch {
            # Try another independent probe; do not log URLs or response bodies.
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($response) { $response.Dispose() }
            if ($request) { $request.Abort() }
        }
    }
    return $false
}

function Write-NetworkLog([string]$Message) {
    if (Get-Command Log -CommandType Function -ErrorAction SilentlyContinue) { Log $Message }
    else { Write-Verbose $Message }
}

function Wait-InternetHttp {
    param([object[]]$Targets, [int]$TimeoutMs = 2000, [int]$TimeoutSec = 30, [datetime]$Deadline = [datetime]::MaxValue)
    $limit = (Get-Date).AddSeconds($TimeoutSec)
    if ($Deadline -lt $limit) { $limit = $Deadline }
    $successes = 0
    while ((Get-Date) -lt $limit) {
        $online = if ($Targets) { Test-InternetHttp -Targets $Targets -TimeoutMs $TimeoutMs }
                  else { Test-InternetHttp -TimeoutMs $TimeoutMs }
        if ($online) { $successes++ } else { $successes = 0 }
        if ($successes -ge 2) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-SystemProxyValue([string]$Name) {
    $key = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return [pscustomobject]@{ exists = ($key.PSObject.Properties.Name -contains $Name); value = $key.$Name }
}

function Set-SystemProxyValue([string]$Name, $Value, [bool]$Exists = $true) {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not $Exists) {
        Remove-ItemProperty -LiteralPath $path -Name $Name -ErrorAction SilentlyContinue
    } else {
        $type = 'String'
        if ($Name -eq 'ProxyEnable') { $type = 'DWord' }
        New-ItemProperty -LiteralPath $path -Name $Name -Value $Value -PropertyType $type -Force -ErrorAction Stop | Out-Null
    }
}

function Notify-SystemProxyChanged {
    if (-not ([Management.Automation.PSTypeName]'CampusNetwork.WinInet').Type) {
        Add-Type -Namespace CampusNetwork -Name WinInet -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(System.IntPtr hInternet, int option, System.IntPtr buffer, int length);
'@
    }
    [void][CampusNetwork.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][CampusNetwork.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Get-LocalClashController([string]$ConfigPath = '') {
    $candidates = @($ConfigPath)
    if (-not $ConfigPath) {
        $candidates = @(
            (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'),
            (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash.yaml'),
            (Join-Path $env:USERPROFILE '.config\clash\config.yaml')
        )
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $yaml = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 -ErrorAction Stop
            $secret = [regex]::Match($yaml, '(?m)^secret:[ \t]*([^\r\n]*)').Groups[1].Value.Trim()
            if ($secret.StartsWith('"')) { $secret = $secret | ConvertFrom-Json }
            elseif ($secret.StartsWith("'")) { $secret = $secret.Trim("'").Replace("''", "'") }
            else { $secret = ($secret -replace '\s+#.*$', '').Trim() }
            if ($secret -match '[\r\n]') { continue }
            $endpoints = @()
            $pipe = [regex]::Match($yaml, '(?m)^external-controller-pipe:[ \t]*([^\r\n]+)').Groups[1].Value.Trim().Trim('"').Trim("'")
            # Verge service mode replaces the sidecar name at launch. Match only
            # the same local pipe identity; never open an arbitrary remote pipe.
            if ($pipe -match '^\\\\\.\\pipe\\(verge-mihomo-[A-Za-z0-9_-]+)$') {
                $configuredName = $Matches[1]
                $names = @($configuredName.Replace('verge-mihomo-sidecar-release-', 'verge-mihomo-production-'), $configuredName) | Select-Object -Unique
                $available = @([IO.Directory]::GetFiles('\\.\pipe\'))
                foreach ($name in $names) {
                    if ($available -contains ('\\.\pipe\' + $name)) {
                        $endpoints += [pscustomobject]@{ config_path = [IO.Path]::GetFullPath($candidate); pipe_name = $name; secret = $secret }
                    }
                }
            }
            $address = [regex]::Match($yaml, '(?m)^external-controller:[ \t]*([^\r\n#]*)').Groups[1].Value.Trim().Trim('"').Trim("'")
            # Never send a controller credential to a nonlocal address.
            if ($address -match '^(127\.0\.0\.1|localhost|0\.0\.0\.0):([0-9]{1,5})$') {
                $port = [int]$Matches[2]
                if ($port -ge 1 -and $port -le 65535) {
                    $endpoints += [pscustomobject]@{ config_path = [IO.Path]::GetFullPath($candidate); base_uri = ('http://127.0.0.1:' + $port); secret = $secret }
                }
            }
            foreach ($endpoint in $endpoints) {
                try {
                    $status = Invoke-ClashApi -Controller $endpoint
                    if ($status.mode) { return $endpoint }
                } catch { }
            }
        } catch { }
    }
    return $null
}

function Invoke-ClashPipeApi($Controller, [string]$Method, $Payload) {
    $pipe = $null; $reader = $null
    try {
        if ($Controller.pipe_name -notmatch '^verge-mihomo-[A-Za-z0-9_-]+$' -or
            $Method -notin @('GET', 'PATCH') -or $Controller.secret -match '[\r\n]') {
            throw 'Invalid local Clash request.'
        }
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $Controller.pipe_name,
            [IO.Pipes.PipeAccessRights]::ReadWrite, [IO.Pipes.PipeOptions]::Asynchronous,
            [Security.Principal.TokenImpersonationLevel]::Identification, [IO.HandleInheritability]::None)
        $pipe.Connect(2000)
        $body = ''
        if ($null -ne $Payload) { $body = $Payload | ConvertTo-Json -Depth 5 -Compress }
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
        # HTTP/1.0 and Connection: close give a bounded, non-chunked response on
        # both the bundled Mihomo service and its sidecar, on PowerShell 5.1.
        $header = "$Method /configs HTTP/1.0`r`nHost: localhost`r`nConnection: close`r`n"
        if ($Controller.secret) { $header += ('Authorization: Bearer ' + $Controller.secret + "`r`n") }
        $header += "Content-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`n`r`n"
        $headerBytes = [Text.Encoding]::UTF8.GetBytes($header)
        $write = $pipe.WriteAsync($headerBytes, 0, $headerBytes.Length)
        if (-not $write.Wait(3000)) { throw 'Local Clash write timed out.' }
        if ($bodyBytes.Length) {
            $write = $pipe.WriteAsync($bodyBytes, 0, $bodyBytes.Length)
            if (-not $write.Wait(3000)) { throw 'Local Clash write timed out.' }
        }
        $reader = [IO.StreamReader]::new($pipe, [Text.Encoding]::UTF8)
        $read = $reader.ReadToEndAsync()
        if (-not $read.Wait(3000)) { throw 'Local Clash read timed out.' }
        $parts = $read.Result -split "`r`n`r`n", 2
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^HTTP/1\.[01] 2[0-9]{2}\b' -or
            $parts[0] -match '(?i)Transfer-Encoding:\s*chunked') { throw 'Local Clash request failed.' }
        if ($parts[1]) { return ($parts[1] | ConvertFrom-Json) }
    } finally {
        if ($pipe) { $pipe.Dispose() }
        if ($reader) { $reader.Dispose() }
    }
}

function Invoke-ClashApi($Controller, [string]$Method = 'GET', $Payload) {
    if ($Controller.pipe_name) { return (Invoke-ClashPipeApi -Controller $Controller -Method $Method -Payload $Payload) }
    $request = $null; $response = $null; $reader = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Controller.base_uri + '/configs')
        $request.Proxy = $null
        $request.Timeout = 3000; $request.ReadWriteTimeout = 3000
        $request.Method = $Method
        if ($Controller.secret) { $request.Headers['Authorization'] = 'Bearer ' + $Controller.secret }
        if ($null -ne $Payload) {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 5 -Compress))
            $request.ContentType = 'application/json'; $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        $body = $reader.ReadToEnd()
        if ($body) { return ($body | ConvertFrom-Json) }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Abort() }
    }
}

function Save-AuthNetworkState([string]$StatePath, $State) {
    # Write intentions BEFORE changing settings so even a killed process can recover.
    Write-CampusFile $StatePath ($State | ConvertTo-Json -Depth 8)
}

function Test-ClashTunActive {
    param([object[]]$Interfaces = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()))
    return [bool]@($Interfaces | Where-Object {
        $_.Description -match '^(Clash|Meta) Tunnel$|^Mihomo' -and $_.OperationalStatus -eq 'Up'
    }).Count
}

function Wait-ClashTunInactive {
    $deadline = (Get-Date).AddSeconds(8)
    while (Test-ClashTunActive) {
        if ((Get-Date) -ge $deadline) { throw 'Clash TUN is still active; authentication was not started.' }
        Start-Sleep -Milliseconds 200
    }
}

function Get-AuthenticationLock([int]$TimeoutMs = 0) {
    $mutex = New-Object Threading.Mutex($false, $script:CampusAuthMutexName)
    try {
        try { $owned = $mutex.WaitOne($TimeoutMs) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { return $mutex }
    } catch { $mutex.Dispose(); throw }
    $mutex.Dispose()
    return $null
}

function Release-AuthenticationLock($Mutex) {
    if ($Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
}

function Get-LegacyCfwState($Controller) {
    if (-not (Test-ClashTunActive)) { return $null }
    $app = Get-Process -Name 'Clash for Windows' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } | Select-Object -First 1
    if (-not $app) { throw 'Active TUN cannot be paused through this core API.' }
    $corePath = Join-Path (Split-Path -Parent $app.Path) 'resources\static\files\win\x64\clash-win64.exe'
    if (-not (Test-Path -LiteralPath $corePath)) { throw 'Legacy CFW core path could not be verified.' }
    $service = Get-Service -Name 'Clash Core Service' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        app_path = $app.Path
        core_path = $corePath
        service_running = [bool]($service -and $service.Status -eq 'Running')
        tun_active = $true
    }
}

function Stop-LegacyCfw($State) {
    # This CFW core predates the TUN PATCH API. Merely changing mode to DIRECT
    # leaves its virtual adapter active and the official client on error 101.
    Get-Process -Name 'Clash for Windows' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $State.app_path } | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($State.service_running) {
        Stop-Service -Name 'Clash Core Service' -Force -ErrorAction Stop
    }
    Get-Process -Name 'clash-win64' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $State.core_path } | Stop-Process -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(10)
    while (Test-ClashTunActive) {
        if ((Get-Date) -ge $deadline) { throw 'Legacy Clash TUN did not stop.' }
        Start-Sleep -Milliseconds 200
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-NetworkLog 'Authentication: legacy CFW core stopped; TUN is confirmed inactive.'
}

function Start-LegacyCfw($State) {
    if ($State.service_running) { Start-Service -Name 'Clash Core Service' -ErrorAction Stop }
    $app = Get-Process -Name 'Clash for Windows' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $State.app_path }
    if (-not $app) {
        # Launch through Explorer so an elevated watchdog does not unnecessarily
        # raise the privilege level of the user's normal desktop application.
        $shell = New-Object -ComObject Shell.Application
        try { $shell.ShellExecute([string]$State.app_path, '', (Split-Path -Parent $State.app_path), 'open', 0) }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-ClashTunActive)) {
        if ((Get-Date) -ge $deadline) { throw 'Legacy CFW TUN has not restarted yet.' }
        Start-Sleep -Milliseconds 500
    }
    Write-NetworkLog 'Authentication: legacy CFW restarted; original TUN is active again.'
}

function Enter-AuthNetworkContext([string]$StatePath, [string]$ClashConfigPath = '', [switch]$RepairProxy) {
    if (Test-Path -LiteralPath $StatePath) { throw 'Previous network settings still need restoration.' }
    $exe = Get-SelectedVergeExecutable $ClashConfigPath
    if ($exe) {
        $prefs = Read-VergePreferences
        if ((Get-VergeGui $exe) -or $prefs.proxy -or $prefs.tun) {
            $saved = New-VergeRecoveryState $exe $RepairProxy.IsPresent
            Save-AuthNetworkState $StatePath $saved
            Suspend-VergeContext $saved $StatePath
            return
        }
    }
    $state = [pscustomobject]@{ version = 1; proxy_enable = $null; pac = $null; clash = $null; legacy_cfw = $null }
    Save-AuthNetworkState $StatePath $state
    Update-AuthNetworkContext -StatePath $StatePath -ClashConfigPath $ClashConfigPath
}

function Update-AuthNetworkContext([string]$StatePath, [string]$ClashConfigPath = '') {
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.version -eq 2) {
        $lan = Read-LanSettings
        if (($lan.Flags -band 14) -or (Test-ClashTunActive) -or
            (Get-VergeGui $state.exe) -or (Test-VergePort $state.port)) {
            Save-VergeLanChanges $StatePath $state $lan
            Suspend-VergeContext $state $StatePath
        }
        return
    }
    $proxy = Get-SystemProxyValue 'ProxyEnable'
    if ($proxy.exists -and [int]$proxy.value -ne 0) {
        if (-not $state.proxy_enable) { $state.proxy_enable = $proxy; Save-AuthNetworkState $StatePath $state }
        Set-SystemProxyValue 'ProxyEnable' 0
        Notify-SystemProxyChanged
        Write-NetworkLog 'Authentication: temporarily paused the Windows system proxy.'
    }
    $pac = Get-SystemProxyValue 'AutoConfigURL'
    if ($pac.exists -and $pac.value) {
        if (-not $state.pac) { $state.pac = $pac; Save-AuthNetworkState $StatePath $state }
        Set-SystemProxyValue 'AutoConfigURL' ''
        Notify-SystemProxyChanged
        Write-NetworkLog 'Authentication: temporarily paused PAC.'
    }
    if ($state.legacy_cfw) {
        if (Test-ClashTunActive) { Stop-LegacyCfw $state.legacy_cfw }
        return
    }
    if ($state.clash) { $ClashConfigPath = $state.clash.config_path }
    $controller = Get-LocalClashController -ConfigPath $ClashConfigPath
    if (-not $controller) {
        if (Test-ClashTunActive) { throw 'Active Clash TUN has no reachable local controller; authentication was not started.' }
        return
    }
    try { $current = Invoke-ClashApi -Controller $controller }
    catch {
        if (Test-ClashTunActive) { throw 'Active Clash TUN could not be paused; authentication was not started.' }
        Write-NetworkLog 'Authentication: Clash controller is unavailable; will retry during authentication.'
        return
    }
    if (-not $current.mode) { throw 'Clash controller did not report its state.' }
    if (-not $current.tun) {
        $legacy = Get-LegacyCfwState -Controller $controller
        if ($legacy) {
            $state.legacy_cfw = $legacy
            $state.clash = [pscustomobject]@{ config_path = $controller.config_path; mode = [string]$current.mode;
                restore_mode = $true; restore_tun = $false }
            Save-AuthNetworkState $StatePath $state
            Stop-LegacyCfw $legacy
            return
        }
    }
    $patch = @{}
    if ($current.mode -ne 'direct') { $patch['mode'] = 'direct' }
    if ($current.tun -and $current.tun.enable -eq $true) { $patch['tun'] = @{ enable = $false } }
    if ($patch.Count -eq 0) { Wait-ClashTunInactive; return }
    if (-not $state.clash) {
        $state.clash = [pscustomobject]@{
            config_path = $controller.config_path
            mode = [string]$current.mode
            restore_mode = $false
            restore_tun = $false
        }
    }
    if ($patch.ContainsKey('mode')) {
        if (-not $state.clash.restore_mode) { $state.clash.mode = [string]$current.mode }
        $state.clash.restore_mode = $true
    }
    if ($patch.ContainsKey('tun')) { $state.clash.restore_tun = $true }
    Save-AuthNetworkState $StatePath $state
    Invoke-ClashApi -Controller $controller -Method 'PATCH' -Payload $patch | Out-Null
    $verified = Invoke-ClashApi -Controller $controller
    if ($verified.mode -ne 'direct' -or ($verified.tun -and $verified.tun.enable -eq $true)) {
        throw 'Clash did not apply the temporary direct settings.'
    }
    Wait-ClashTunInactive
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-NetworkLog 'Authentication: Clash is temporarily DIRECT; TUN is confirmed inactive.'
}

function Restore-AuthNetworkContext([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $true }
    $authLock = Get-AuthenticationLock
    if (-not $authLock) { return $false }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($state.version -eq 2) {
            try {
                Restore-VergeContext $StatePath $state
                Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
                return $true
            } catch {
                $state.restore_failures++
                Save-AuthNetworkState $StatePath $state
                Set-CampusStatus 'error' '代理恢复等待重试，已保存原设置'
                return $false
            }
        }
        if ($state.version -ne 1) { throw 'Unsupported network recovery journal.' }
        if ($state.legacy_cfw) {
            Start-LegacyCfw $state.legacy_cfw
        }
        foreach ($entry in @(@{ field = 'proxy_enable'; name = 'ProxyEnable'; temporary = 0 },
                             @{ field = 'pac'; name = 'AutoConfigURL'; temporary = '' })) {
            $original = $state.($entry.field)
            if (-not $original) { continue }
            $current = Get-SystemProxyValue $entry.name
            if ($current.exists -and [string]$current.value -ceq [string]$entry.temporary) {
                Set-SystemProxyValue -Name $entry.name -Value $original.value -Exists ([bool]$original.exists)
                Notify-SystemProxyChanged
            }
            # If the user changed it during authentication, keep their newer setting.
            $state.($entry.field) = $null
            Save-AuthNetworkState $StatePath $state
        }
        if ($state.clash) {
            $controller = Get-LocalClashController -ConfigPath $state.clash.config_path
            if (-not $controller) { throw 'Clash controller is not ready for restoration.' }
            $current = Invoke-ClashApi -Controller $controller
            $patch = @{}
            if ($state.clash.restore_mode -and ($current.mode -eq 'direct' -or $state.legacy_cfw) -and
                $current.mode -ne $state.clash.mode) { $patch['mode'] = $state.clash.mode }
            if ($state.clash.restore_tun -and $current.tun -and $current.tun.enable -eq $false) { $patch['tun'] = @{ enable = $true } }
            if ($patch.Count) {
                Invoke-ClashApi -Controller $controller -Method 'PATCH' -Payload $patch | Out-Null
                $verified = Invoke-ClashApi -Controller $controller
                if (($patch.ContainsKey('mode') -and $verified.mode -ne $patch.mode) -or
                    ($patch.ContainsKey('tun') -and $verified.tun.enable -ne $true)) { throw 'Clash restoration did not apply.' }
            }
        }
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
        Write-NetworkLog 'Authentication: original proxy and Clash settings restored.'
        return $true
    } catch {
        # Keep the journal and retry before the next recovery / after process restart.
        # Do not log exceptions containing PAC addresses or controller credentials.
        Write-NetworkLog 'Proxy restoration is pending; the saved settings will be retried.'
        return $false
    } finally {
        Release-AuthenticationLock $authLock
    }
}
