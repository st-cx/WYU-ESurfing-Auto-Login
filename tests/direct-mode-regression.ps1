param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot),[string]$CheckRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'network.ps1')
. (Join-Path $RepoRoot 'settings-store.ps1')
. (Join-Path $RepoRoot 'monitor.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'watchdog.ps1'),[ref]$null,[ref]$null)
foreach($name in 'Invoke-CampusRecovery','Invoke-ReconnectSelfTest','Update-LoginGuard') {
    $def=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($def.Extent.Text))
}
function Assert($ok,[string]$message) {if(-not $ok){throw $message}}
function Log {}
function Set-CampusStatus {}
function Send-Toast {}
function Get-AuthenticationLock {return $true}
function Release-AuthenticationLock {}
function Restore-OwnedAdapter {return $true}
function Invoke-CommandFile {}
function Get-PhysicalLink {return 'Campus'}
function Wait-AdapterUp {return $true}
function Restart-Client {}
function Test-Internet {return $script:online}
function Wait-InternetHttp {return $script:online}
function Invoke-LoginClick {$script:submissions++; $script:online=$true; return 'Online'}
function Find-ClientWebWindow {return [intptr]73}
function Get-DisconnectPoint {return @{lpX=4;lpY=8}}
function Send-ClickToWindow {$script:online=$false}
$script:proxyCalls=0
foreach($name in 'Read-LanSettings','Get-SystemProxyValue','Test-ClashTunActive','Get-VergeExecutable',
    'Get-VergeGui','Get-LocalClashController','Invoke-ClashApi','Enter-AuthNetworkContext','Update-AuthNetworkContext') {
    Set-Item -Path ('Function:'+$name) -Value { $script:proxyCalls++; throw ('Unexpected proxy call: '+$MyInvocation.MyCommand.Name) }
}
function Get-SelectedVergeExecutable { $script:proxyCalls++;return 'fixture' }
function Test-VergeHealth { $script:proxyCalls++;return $true }
$Config=@{proxy_guard=$true;clash_config_path=''}
$Root=if($CheckRoot){$CheckRoot}else{Join-Path ([IO.Path]::GetTempPath()) ('campus-runtime-'+[guid]::NewGuid().ToString('N'))}
$LogDir=$Root
$NetworkStatePath=Join-Path $Root 'proxy-recovery.json'
$AutoNetworkStatePath=Join-Path $Root 'other-fixture-journal.json'
$AdapterName='nonexistent-fixture-adapter';$ClientProc='nonexistent-fixture-client';$ClientDir=$Root;$ClientExe=Join-Path $Root 'fixture.exe'
$CheckIntervalSec=20;$FailThreshold=1;$script:online=$true
if($CheckRoot){
    function Find-ClientWebWindow {return [intptr]::Zero}
    $Check=$true
    $branch=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$Check'},$true)
    . ([scriptblock]::Create($branch.Extent.Text))
    throw 'The diagnostic did not exit.'
}
[void][IO.Directory]::CreateDirectory($Root)
try{
    $configFile=Join-Path $Root 'config.json'
    [IO.File]::WriteAllText($configFile,'{"proxy_guard":true}')
    Assert ((Invoke-MonitorPass) -eq 20 -and $script:proxyCalls -eq 0) 'An old configured installation queried the proxy.'
    $script:verifyAfterWake=$true
    [void](Invoke-MonitorPass)
    Assert ((Invoke-SingleConnection) -and $script:proxyCalls -eq 0) 'The default wake or embedded path queried the proxy.'
    $script:online=$false
    Assert ((Invoke-SingleConnection -BeforeLogin {throw 'The old task attempted to overwrite the account.'}) -and $script:submissions -eq 1 -and $script:proxyCalls -eq 0) 'A direct recovery touched the proxy.'
    $shell=(Get-Process -Id $PID).Path
    $diagnostic=@(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -CheckRoot $Root)
    Assert ($LASTEXITCODE -eq 0 -and ($diagnostic -join ' ') -notmatch 'Clash Verge:|TUN:') 'Standalone -Check queried or displayed proxy state by default.'
    $id=[guid]::NewGuid().ToString('N')
    Invoke-ReconnectSelfTest $id ((Get-Date).AddMinutes(2))
    $report=[IO.File]::ReadAllText((Join-Path $Root ('reconnect-test-'+$id+'.json'))) | ConvertFrom-Json
    Assert ($report.passed -and $report.disconnected -and -not $report.proxy_managed -and $null -eq $report.tun_stopped -and $script:proxyCalls -eq 0) 'Direct reconnect diagnostics touched or claimed to inspect TUN.'
    Write-Output 'PASS: the old flag alone never contacts proxy software or Windows proxy settings on monitor, wake, embedded, recovery, -Check or reconnect diagnostics.'

    Set-CampusProxyIntegration -Root $Root -Enabled $true
    [void](Invoke-MonitorPass)
    Assert ($script:proxyCalls -ge 2) 'Explicit opt-in was ignored.'
    $before=$script:proxyCalls
    Set-CampusProxyIntegration -Root $Root -Enabled $false
    [void](Invoke-MonitorPass)
    Assert ($script:proxyCalls -eq $before) 'Turning off integration did not take effect on the next pass.'

    function Get-SystemProxyValue { $script:restoredReads++; return [pscustomobject]@{exists=$true;value=0} }
    function Set-SystemProxyValue { $script:restoredWrites++ }
    function Notify-SystemProxyChanged {}
    function Save-AuthNetworkState {}
    [IO.File]::WriteAllText($NetworkStatePath,'{"version":1,"proxy_enable":{"exists":true,"value":1},"pac":null,"clash":null,"legacy_cfw":null}')
    [void](Invoke-MonitorPass); [void](Invoke-MonitorPass)
    Assert ($script:restoredReads -eq 1 -and $script:restoredWrites -eq 1 -and -not [IO.File]::Exists($NetworkStatePath)) 'An existing owned journal must be restored once even with integration disabled.'
    Write-Output 'PASS: opt-in and opt-out apply without restart, and a pending restoration finishes once.'
}finally{
    foreach($f in [IO.Directory]::GetFiles($Root)){[IO.File]::Delete($f)}
    [IO.Directory]::Delete($Root)
}
