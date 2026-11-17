param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'watchdog.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Invoke-CampusRecovery', 'Test-OnCampus', 'Wait-AdapterUp')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$Config = @{ proxy_guard = $true; clash_config_path = '' }
$NetworkStatePath = 'unused-test-state'
$NicBounceCooldown = 180
$script:lastBounce = Get-Date '2000-01-01'
$script:events = New-Object 'Collections.Generic.List[string]'
$script:lockAvailable = $true
function Get-AuthenticationLock { if ($script:lockAvailable) { return [pscustomobject]@{fixture=$true} }; return $null }
function Release-AuthenticationLock($Mutex) {}
function Log([string]$Message) {}
function Send-Toast([string]$Message) {}
function Enter-AuthNetworkContext { $script:events.Add('enter') }
function Update-AuthNetworkContext { $script:events.Add('update') }
function Restore-AuthNetworkContext { $script:events.Add('restore'); return $true }
function Wait-AdapterUp { $script:events.Add('ready'); return $script:ready }
function Test-Internet { return $false }
function Restart-Client { $script:events.Add('restart'); if ($script:crash) { throw 'Client startup failed' } }
function Invoke-LoginClick { $script:events.Add('click'); return $true }
function Wait-AuthSettle { $script:events.Add('settle'); return $script:online }
function Repair-NicAdapter { $script:events.Add('bounce'); return $true }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$script:ready = $true; $script:online = $true; $script:crash = $false
Assert-True (Invoke-CampusRecovery) 'A successful authentication must report recovery.'
Assert-True (($script:events -join ',') -eq 'ready,enter,restart,update,click,settle,restore') 'Proxy handling must enclose the actual login sequence.'
Write-Output 'PASS: proxy isolation covers restart, login, and authentication, followed by restoration.'

$script:events.Clear(); $script:ready = $false
Assert-True (-not (Invoke-CampusRecovery)) 'An unready adapter cannot report recovery.'
Assert-True (-not $script:events.Contains('restart') -and -not $script:events.Contains('bounce')) 'DHCP startup must not restart the client or bounce the adapter.'
Write-Output 'PASS: DHCP startup is allowed to finish before touching the client or adapter.'

$script:events.Clear(); $script:ready = $true; $script:crash = $true
Assert-True (-not (Invoke-CampusRecovery)) 'A startup error must not report recovery.'
Assert-True ($script:events[$script:events.Count - 1] -eq 'restore') 'Exceptions must still restore proxies.'
Write-Output 'PASS: a client startup exception still restores the network context.'

$script:events.Clear(); $script:crash = $false; $script:online = $false
$script:lastBounce = Get-Date
Assert-True (-not (Invoke-CampusRecovery)) 'Failed authentication cannot report success.'
Assert-True (-not $script:events.Contains('bounce')) 'Adapter cooldown must survive the proxy recovery change.'
Assert-True ($script:events[$script:events.Count - 1] -eq 'restore') 'Failed authentication must restore proxies.'
Write-Output 'PASS: authentication failure preserves the adapter cooldown and restores proxies.'

$script:events.Clear(); $script:lockAvailable = $false
Assert-True (-not (Invoke-CampusRecovery)) 'A competing authentication must defer recovery.'
Assert-True ($script:events.Count -eq 0) 'A competing authentication must not restore proxies, restart, click, or bounce.'
Write-Output 'PASS: a competing authentication cannot be interrupted by recovery.'

$CampusGuard = $true; $CampusIpPrefixes = @('100.2.'); $CampusGateways = @('100.2.0.1'); $AdapterName = 'Ethernet'
function Get-NetIPAddress([string]$InterfaceAlias) {
    if (-not $InterfaceAlias) { throw 'Campus guard must only inspect the configured physical adapter.' }
    return [pscustomobject]@{ IPAddress = '192.168.1.3' }
}
function Get-NetRoute([string]$InterfaceAlias) {
    if (-not $InterfaceAlias) { throw 'Campus guard must not accept a virtual default route.' }
    return [pscustomobject]@{ NextHop = '192.168.1.1' }
}
Assert-True (-not (Test-OnCampus)) 'Off-campus physical adapters must stay quiet.'
Write-Output 'PASS: off-campus guard checks the configured adapter, excluding TUN/VPN addresses.'
