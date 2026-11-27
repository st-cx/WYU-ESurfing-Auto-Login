param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'network.ps1')
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('campus-proxy-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$statePath = Join-Path $testDir 'proxy-recovery.json'
$script:CampusAuthMutexName = 'Local\'+[IO.Path]::GetFileName($testDir)

# Only OS / Clash I/O is simulated. The journal and recovery lifecycle are real.
function Get-VergeExecutable { return $null } # These cases exercise legacy/v1 journals.
$script:proxy = @{ ProxyEnable = @{ exists = $true; value = 1 }; AutoConfigURL = @{ exists = $true; value = 'http://127.0.0.1/proxy.pac' } }
$script:clash = [pscustomobject]@{ mode = 'rule'; tun = [pscustomobject]@{ enable = $true } }
$script:controllerAvailable = $true
$script:legacyTun = $false
$script:legacyActive = $false
function Get-LegacyCfwState($Controller) {
    if (-not $script:legacyTun) { return $null }
    return [pscustomobject]@{ app_path = 'fixture-cfw.exe'; core_path = 'fixture-core.exe'; service_running = $true; tun_active = $true; mode = $script:clash.mode }
}
function Stop-LegacyCfw($State) { $script:legacyActive = $false }
function Start-LegacyCfw($State) { $script:legacyActive = $true }
function Get-SystemProxyValue([string]$Name) { return [pscustomobject]$script:proxy[$Name] }
function Set-SystemProxyValue([string]$Name, $Value, [bool]$Exists = $true) {
    $script:proxy[$Name] = @{ exists = $Exists; value = $Value }
}
function Notify-SystemProxyChanged {}
function Clear-DnsClientCache {}
function Test-ClashTunActive { return ($script:legacyActive -or [bool]($script:clash.tun -and $script:clash.tun.enable)) }
function Get-LocalClashController([string]$ConfigPath) {
    if (-not $script:controllerAvailable) { return $null }
    if (-not $ConfigPath) { $ConfigPath='fixture.yaml' }
    $script:lastController=$ConfigPath
    return [pscustomobject]@{ config_path = $ConfigPath; base_uri = 'http://127.0.0.1:1'; secret = 'private-do-not-persist' }
}
function Invoke-ClashApi($Controller, [string]$Method = 'GET', $Payload) {
    if (-not $script:controllerAvailable) { throw 'Controller temporarily unavailable' }
    if ($Method -eq 'PATCH') {
        if ($Payload.Contains('mode')) { $script:clash.mode = $Payload.mode }
        if ($Payload.Contains('tun')) { $script:clash.tun.enable = $Payload.tun.enable }
    }
    return $script:clash
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    Enter-AuthNetworkContext -StatePath $statePath
    Assert-True ($script:proxy.ProxyEnable.value -eq 0) 'System proxy must be paused for authentication.'
    Assert-True ($script:proxy.AutoConfigURL.value -eq '') 'PAC must be paused for authentication.'
    Assert-True ($script:clash.mode -eq 'direct' -and -not $script:clash.tun.enable) 'Clash must allow authentication directly.'
    Assert-True (-not (Get-Content -LiteralPath $statePath -Raw).Contains('private-do-not-persist')) 'The journal must not contain the controller secret.'
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'Restoration must succeed.'
    Assert-True ($script:proxy.ProxyEnable.value -eq 1) 'System proxy was not restored.'
    Assert-True ($script:proxy.AutoConfigURL.value -eq 'http://127.0.0.1/proxy.pac') 'PAC was not restored.'
    Assert-True ($script:clash.mode -eq 'rule' -and $script:clash.tun.enable) 'Clash was not restored.'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'Completed restoration must remove its journal.'
    Write-Output 'PASS: authentication pauses proxies and restores all original settings without persisting secrets.'

    # The user has an old CFW core: /configs does not expose a tun field.
    $script:clash = [pscustomobject]@{ mode = 'global' }
    Enter-AuthNetworkContext -StatePath $statePath
    Assert-True ($script:clash.mode -eq 'direct') 'Old CFW must still enter direct mode.'
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'Old CFW restoration failed.'
    Assert-True ($script:clash.mode -eq 'global') 'Old CFW mode was not preserved.'
    Write-Output 'PASS: old CFW cores without a tun API use temporary direct mode.'

    Enter-AuthNetworkContext -StatePath $statePath
    $script:controllerAvailable = $false
    Assert-True (-not (Restore-AuthNetworkContext -StatePath $statePath)) 'A failed restoration cannot report success.'
    Assert-True (Test-Path -LiteralPath $statePath) 'An interrupted restoration must retain its journal.'
    $script:controllerAvailable = $true
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'The next watchdog start must finish interrupted restoration.'
    Assert-True ($script:clash.mode -eq 'global') 'Interrupted restoration lost the original mode.'
    Write-Output 'PASS: interrupted restoration is retried from the saved journal.'

    Enter-AuthNetworkContext -StatePath $statePath
    $script:clash.mode = 'rule'
    $script:proxy.AutoConfigURL.value = 'http://127.0.0.1/new-user-choice.pac'
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'Restoration after a user change failed.'
    Assert-True ($script:clash.mode -eq 'rule') 'Restoration must preserve a newer user mode.'
    Assert-True ($script:proxy.AutoConfigURL.value -eq 'http://127.0.0.1/new-user-choice.pac') 'Restoration must preserve a newer PAC.'
    Write-Output 'PASS: newer user settings are preserved.'

    # Clash starts after the watchdog has already begun recovering the network.
    $script:controllerAvailable = $false
    $script:proxy.ProxyEnable = @{ exists = $true; value = 0 }
    $script:proxy.AutoConfigURL = @{ exists = $false; value = $null }
    Enter-AuthNetworkContext -StatePath $statePath
    $script:controllerAvailable = $true
    $script:proxy.ProxyEnable.value = 1
    Update-AuthNetworkContext -StatePath $statePath
    Assert-True ($script:proxy.ProxyEnable.value -eq 0 -and $script:clash.mode -eq 'direct') 'Late Clash startup must be handled before login.'
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'Restoration after late startup failed.'
    Assert-True ($script:proxy.ProxyEnable.value -eq 1 -and $script:clash.mode -eq 'rule') 'Late-starting Clash settings were not restored.'
    Write-Output 'PASS: Clash starting during recovery is also isolated and restored.'

    $script:legacyTun = $true; $script:legacyActive = $true
    $script:clash = [pscustomobject]@{ mode = 'rule' }
    Enter-AuthNetworkContext -StatePath $statePath
    Assert-True (-not $script:legacyActive) 'A legacy TUN must actually stop; DIRECT alone still leaves error 101.'
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'Legacy CFW restoration failed.'
    Assert-True $script:legacyActive 'Legacy CFW and its TUN must be restored after authentication.'
    Write-Output 'PASS: legacy CFW really stops TUN before login and restores it afterwards.'

    $script:legacyActive = $true; $script:controllerAvailable = $false
    $blocked = $false
    try { Enter-AuthNetworkContext -StatePath $statePath }
    catch { $blocked = $_.Exception.Message -match 'no reachable local controller' }
    Assert-True $blocked 'An active TUN without a controller must abort authentication.'
    Assert-True (Restore-AuthNetworkContext -StatePath $statePath) 'A blocked attempt must restore its proxy/PAC changes.'
    Assert-True ($script:proxy.ProxyEnable.value -eq 1) 'A blocked attempt left the system proxy disabled.'
    Write-Output 'PASS: an uncontrollable active TUN aborts authentication and preserves restoration.'

    . (Join-Path $RepoRoot 'monitor.ps1')
    $Config=@{clash_config_path=(Join-Path $testDir 'portable.yaml')}
    $script:CampusPreferences=[pscustomobject]@{ProxyEnabled=$true;DefaultAccount=''}
    function Get-VergeExecutable { return 'fixture\clash-verge.exe' }
    function Get-VergeGui { return $null }
    function Read-VergePreferences { return [pscustomobject]@{runtime=(Join-Path $testDir 'default.yaml');port=7897;proxy=$true;tun=$true} }
    function Wait-InternetHttp { return $true }
    $script:legacyTun=$false; $script:legacyActive=$false; $script:controllerAvailable=$true
    $script:clash=[pscustomobject]@{mode='rule';tun=[pscustomobject]@{enable=$true}}
    Enter-AuthNetworkContext $statePath $Config.clash_config_path
    Assert-True ((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).version -eq 1 -and $script:lastController -eq $Config.clash_config_path) 'A custom controller must be isolated instead of the default Verge instance.'
    Assert-True (Restore-AuthNetworkContext $statePath) 'A custom controller must be restored.'
    Assert-True ($script:clash.mode -eq 'rule' -and $script:clash.tun.enable -and (Test-CompleteConnection)) 'A restored custom controller and healthy campus connection cannot be failed by an unrelated closed Verge installation.'
    Write-Output 'PASS: a custom controller completes isolation, restoration and final verification with a separate stale Verge installation.'
} finally {
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testDir -Force -ErrorAction SilentlyContinue
}
