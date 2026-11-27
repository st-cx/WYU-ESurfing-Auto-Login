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
$Config = @{ clash_config_path = '' }
function Update-CampusPreferences { $script:CampusPreferences=[pscustomobject]@{ProxyEnabled=$true;DefaultAccount=''}; return $true }
$NetworkStatePath = 'unused-test-state'
$NicBounceCooldown = 180
$script:lastBounce = Get-Date '2000-01-01'
$script:events = New-Object 'Collections.Generic.List[string]'
$script:lockAvailable = $true
function Get-AuthenticationLock { if ($script:lockAvailable) { return [pscustomobject]@{fixture=$true} }; return $null }
function Release-AuthenticationLock($Mutex) {}
function Log([string]$Message) {}
function Send-Toast([string]$Message) { $script:notices += $Message }
function Enter-AuthNetworkContext { $script:events.Add('enter') }
function Update-LoginGuard { $script:events.Add('update') }
$AutoNetworkStatePath = 'other-task-state'
function Restore-AuthNetworkContext([string]$StatePath) {
    if ($StatePath -ne $AutoNetworkStatePath) { $script:events.Add('restore') }
    return $true
}
function Set-CampusStatus {}
function Wait-AdapterUp { $script:events.Add('ready'); return $script:ready }
function Test-Internet { return $false }
function Get-PhysicalLink { return $script:link }
function Restart-Client([switch]$ForceRestart) { $script:events.Add('restart'); if ($ForceRestart) {$script:forced++}; if ($script:crash) { throw 'Client startup failed' } }
function Invoke-LoginClick { $script:events.Add('click'); $script:lastLoginRead=$script:read; return $script:submit }
function Wait-AuthSettle { $script:events.Add('settle'); return $script:online }
function Repair-NicAdapter { $script:events.Add('bounce'); return $true }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$script:ready = $true; $script:online = $true; $script:crash = $false
$script:link='Campus'; $script:submit='Submitted'; $script:read='screen'; $script:notices=@()
Assert-True (Invoke-CampusRecovery) 'A successful authentication must report recovery.'
Assert-True (($script:events -join ',') -eq 'ready,enter,restart,update,click,settle,restore') 'Proxy handling must enclose the actual login sequence.'
Write-Output 'PASS: proxy isolation covers restart, login, and authentication, followed by restoration.'

$script:events.Clear()
function Test-Internet { return $true }
Assert-True (Invoke-CampusRecovery -RepairProxy) 'A healthy campus connection must permit a proxy-only restart.'
Assert-True (-not $script:events.Contains('restart') -and -not $script:events.Contains('click') -and -not $script:events.Contains('bounce')) 'A broken proxy must not restart the campus client, submit authentication, or bounce Ethernet.'
Write-Output 'PASS: a proxy-only failure leaves a healthy campus session and its network adapter up.'
function Test-Internet { return $false }

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

$script:lockAvailable=$true; $script:lastBounce=[datetime]::MinValue
$script:read='no-glyph'; $script:submit='Timeout'; $script:readMisses=0; $script:forced=0
$script:events.Clear()
Assert-True (-not (Invoke-CampusRecovery)) 'A first unreadable login page cannot claim success.'
Assert-True (-not $script:events.Contains('bounce')) 'A single missing button must not reset the adapter.'
$script:events.Clear()
Assert-True (-not (Invoke-CampusRecovery)) 'A persistent client error cannot claim success.'
Assert-True ($script:events.Contains('bounce') -and $script:forced -gt 0) 'A persistent official error page must get a fresh client and a cooldown-limited NIC repair.'
Assert-True ($script:notices.Count -eq 1 -and $script:notices[0] -match '网卡') 'A completed adapter reset must produce one notification.'
$script:events.Clear()
[void](Invoke-CampusRecovery)
Assert-True (-not $script:events.Contains('bounce')) 'Repeated error pages may not bypass the NIC cooldown.'
foreach ($case in @(
    @{result='AccountPending';read='screen';link='Campus'},
    @{result='Timeout';read='covered';link='Campus'},
    @{result='Timeout';read='no-window';link='Campus'},
    @{result='Timeout';read='no-glyph';link='Away'},
    @{result='Timeout';read='no-glyph';link='Waiting'}
)) {
    $script:lastBounce=[datetime]::MinValue; $script:readMisses=3; $script:events.Clear()
    $script:submit=$case.result; $script:read=$case.read; $script:link=$case.link
    [void](Invoke-CampusRecovery)
    Assert-True (-not $script:events.Contains('bounce')) ('Unconfirmed recovery must leave the NIC alone: '+$case.result+'/'+$case.read+'/'+$case.link)
}
$script:events.Clear(); $script:link='Campus'; $script:submit='Submitted'
[void](Invoke-CampusRecovery -RepairProxy)
Assert-True (-not $script:events.Contains('bounce') -and -not $script:events.Contains('click')) 'A proxy-only repair cannot submit a login or reset the adapter if the direct probe changes mid-run.'
Write-Output 'PASS: repeated official-client errors can recover the NIC, while account choice, covered/missing windows, link changes and proxy-only work stay guarded.'

function Get-PhysicalLink { return 'Away' }
Assert-True (-not (Test-OnCampus)) 'Off-campus physical adapters must stay quiet.'
Write-Output 'PASS: off-campus guard checks the configured adapter, excluding TUN/VPN addresses.'
