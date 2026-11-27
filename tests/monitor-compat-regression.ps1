param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$CliLink,
    [int]$Connectivity = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'monitor.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'watchdog.ps1'),[ref]$null,[ref]$null)
function Definition([string]$Name) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if (-not $node) { throw ('Missing watchdog function '+$Name) }
    return [scriptblock]::Create($node.Extent.Text)
}
function Assert($Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
function Get-CampusPreferences {return [pscustomobject]@{DefaultAccount=''; ProxyEnabled=$false; Accounts=@()}}
function Get-AuthenticationLock { return $true }
function Release-AuthenticationLock {}
function Restore-OwnedAdapter { return $true }
function Restore-AuthNetworkContext { return $true }
function Invoke-CommandFile {}
function Get-PhysicalLink { return $script:link }
function Test-Internet { $script:probes++; return $script:online }
function Wait-InternetHttp { return $script:online }
function Invoke-CampusRecovery {
    $script:recoveries++
    if ($script:repairSucceeds) { $script:online=$true }
    return $script:repairSucceeds
}
function Set-CampusStatus {}
function Send-Toast($Message) { $script:notices += $Message }
function Log {}
$Config=@{proxy_guard=$false}
$NetworkStatePath=Join-Path ([IO.Path]::GetTempPath()) ('campus-fixture-'+[guid]::NewGuid().ToString('N')+'.json')
if ($CliLink) {
    $script:link=$CliLink; $script:online=[bool]$Connectivity
    $RecoverOnce=$true
    $branch=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$RecoverOnce'},$true)
    if (-not $branch) { throw 'Missing CLI entry point.' }
    . ([scriptblock]::Create($branch.Extent.Text))
    throw 'The one-shot CLI did not exit.'
}
$shell=(Get-Process -Id $PID).Path
foreach ($case in @(
    @{link='Away';online=0;code=2}, @{link='Away';online=1;code=2},
    @{link='Waiting';online=0;code=2}, @{link='Campus';online=1;code=0}, @{link='Campus';online=0;code=1}
)) {
    & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -RepoRoot $RepoRoot -CliLink $case.link -Connectivity $case.online
    Assert ($LASTEXITCODE -eq $case.code) ('Wrong -RecoverOnce exit code for '+$case.link+'/'+$case.online+': '+$LASTEXITCODE)
}
Write-Output 'PASS: the actual -RecoverOnce CLI returns 0/1/2 for online, failed and skipped checks.'

$AwayCheckIntervalSec=900; $CheckIntervalSec=20; $FailThreshold=2
$script:link='Away'; $script:probes=0; $script:notices=@(); $script:recoveries=0
Assert ((Invoke-MonitorPass) -eq 900 -and $script:probes -eq 0) 'Off-campus monitoring ignored the configured interval or attempted authentication.'
$script:link='Waiting'
Assert ((Invoke-MonitorPass) -eq 3 -and $script:probes -eq 0) 'DHCP must keep its short retry interval.'
$script:link='Campus'; $script:online=$false
[void](Invoke-MonitorPass)
Assert ($script:notices.Count -eq 0 -and $script:recoveries -eq 0) 'A single failed probe notified or started recovery.'
[void](Invoke-MonitorPass); [void](Invoke-MonitorPass)
Assert ($script:notices.Count -eq 1 -and $script:recoveries -eq 2) 'A confirmed outage must be announced only once.'
$script:repairSucceeds=$true
[void](Invoke-MonitorPass); [void](Invoke-MonitorPass)
Assert ($script:notices.Count -eq 2 -and $script:notices[0] -ne $script:notices[1]) 'A verified recovery must generate exactly one recovery notification.'
Write-Output 'PASS: away cadence, rapid DHCP checks and one notification per outage/recovery transition.'

& {
    . (Definition 'Restart-Client')
    . (Definition 'Invoke-CommandFile')
    $Root=Join-Path ([IO.Path]::GetTempPath()) ('campus-command-fixture-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($Root)
    $file=Join-Path $Root 'command.txt'
    $ClientDir='C:\fixture'; $ClientExe=Join-Path $ClientDir 'ESurfingClient.exe'
    $ClientProc='ESurfingClient'; $ClientStartWaitSec=7
    $script:proc=[pscustomobject]@{Path=$ClientExe;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId}
    $script:proc | Add-Member ScriptMethod WaitForExit {return $true}
    $script:events=@()
    function Get-ItemProperty { return $null }
    function Get-Process { return $script:proc }
    function Find-ClientWebWindow { return [intptr]42 }
    function Stop-Process { $script:events+='stop' }
    function Start-Process { $script:events+='start' }
    function Start-Sleep([int]$Seconds) { $script:events+=('wait'+$Seconds) }
    try {
        Restart-Client
        Assert (-not $script:events.Count) 'Routine recovery restarted an already usable client.'
        [IO.File]::WriteAllText($file,'restart-client')
        Invoke-CommandFile
        Assert (($script:events -join ',') -eq 'stop,start,wait7' -and -not [IO.File]::Exists($file)) 'The manual command did not restart the client and apply the configured startup grace.'
    } finally {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
        [IO.Directory]::Delete($Root)
    }
}
Write-Output 'PASS: restart-client forces a restart and honors client_start_wait_sec; routine checks reuse a ready client.'
