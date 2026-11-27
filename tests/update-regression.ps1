param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'network.ps1')
. (Join-Path $RepoRoot 'tools\setup.ps1')
Initialize-CampusNative
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'upgrade.ps1'),[ref]$null,[ref]$null)
foreach ($fn in $ast.FindAll({param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
$paramType=(Get-Command 'ScheduledTasks\Set-ScheduledTask').Parameters['Trigger'].Attributes |
    Where-Object {$_ -is [Management.Automation.PSTypeNameAttribute]} | Select-Object -ExpandProperty PSTypeName
Assert ($paramType -eq 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger') 'The fixture must enforce the installed Windows cmdlet contract.'
function Set-ScheduledTask {
    [CmdletBinding()]param($TaskName,$TaskPath,[PSTypeName('Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger')][Microsoft.Management.Infrastructure.CimInstance[]]$Trigger)
    if($script:rejectWake){throw 'fixture: Windows rejected the additional wake trigger'}
    $script:fixture.Triggers=@($Trigger); $script:setCount++
}
function Get-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) $script:fixture }
function Export-ScheduledTask {
    [CmdletBinding()]param($TaskName,$TaskPath)
    '<Task><Triggers><LogonTrigger><Delay>'+$script:fixture.Triggers[0].Delay+'</Delay></LogonTrigger></Triggers></Task>'
}
function Stop-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) $script:fixture.State='Ready' }
function Register-ScheduledTask {
    [CmdletBinding()]param($TaskName,$TaskPath,$Xml,[switch]$Force)
    $originalDelay = ([xml]$Xml).Task.Triggers.LogonTrigger.Delay
    $script:fixture.Triggers = @(New-CimInstance -ClientOnly -ClassName MSFT_TaskLogonTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler' -Property @{Delay=$originalDelay;Enabled=$true})
}
function Start-ScheduledTask {
    [CmdletBinding()]param($TaskName,$TaskPath)
    $script:fixture.State='Running'
    $installed=[IO.File]::ReadAllText((Join-Path $script:destination 'watchdog.ps1'))
    if($installed -eq 'old watchdog'){return}
    if ($script:rejectStartup){
        if ($script:editDuringStartup) {
            [IO.File]::AppendAllText($auto,[Environment]::NewLine+'# user edit during update')
        }
        throw 'fixture: could not start the updated task'
    }
    # Only the OS scheduler is simulated. Verify a fresh receipt for an actually live PID.
    Write-CampusFile (Join-Path $script:destination 'ready.txt') ($script:packageVersion+'|'+$PID+'|True|'+[datetime]::UtcNow.Ticks)
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('campus-update-test-'+[guid]::NewGuid().ToString('N'))
$script:CampusAuthMutexName='Local\'+[IO.Path]::GetFileName($root)
$script:packageVersion='1.7.0'
$files=Get-CampusProgramFiles
Assert ($files -notcontains 'default-account.txt') 'A release may not supply a personal default account.'
Assert ($files -notcontains 'campus-settings.json' -and $files -contains 'tools\settings.ps1' -and $files -contains 'settings-store.ps1') 'The updater must ship the account settings UI and preserve local preferences.'
try {
    $untyped=New-CimInstance -ClientOnly -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
    $rejected=$false
    try { Set-ScheduledTask -TaskName 'fixture' -TaskPath '\' -Trigger @($untyped) } catch {
        $rejected=$_.FullyQualifiedErrorId -like 'MismatchedPSTypeName,*'
    }
    Assert $rejected 'The previous installer failure was not reproduced.'
    foreach($case in @('success','wake-denied','custom-companion','startup-failed','rollback-with-user-edit')){
        $dir=Join-Path $root $case
        $script:destination=Join-Path $dir 'CampusNetWatchdog'
        $auto=Join-Path $dir 'CampusNetAuto\campus-auth.ps1'
        [void][IO.Directory]::CreateDirectory($script:destination)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($auto))
        $watch=Join-Path $script:destination 'watchdog.ps1'
        $oldAuto="function Ensure-DefaultAccount { }"+[Environment]::NewLine+'. $networkModule'
        if ($case -eq 'custom-companion') { $oldAuto='Write-Output "custom entry"' }
        [IO.File]::WriteAllText($auto,$oldAuto)
        [IO.File]::WriteAllText((Join-Path $script:destination 'default-account.txt'),'1000000001')
        $accounts=Join-Path ([IO.Path]::GetDirectoryName($auto)) 'accounts.json'
        [IO.File]::WriteAllText($accounts,'{"fixture":"existing accounts"}')
        [IO.File]::WriteAllText($watch,'old watchdog')
        [IO.File]::WriteAllText((Join-Path $script:destination 'network.ps1'),'old network')
        [IO.File]::WriteAllText((Join-Path $script:destination 'config.json'),'{"fixture":"preserved"}')
        $script:logon=New-CimInstance -ClientOnly -ClassName MSFT_TaskLogonTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler' -Property @{Delay='PT20S';Enabled=$true}
        $script:fixture=[pscustomobject]@{TaskName='fixture';TaskPath='\';State='Running';Actions=@([pscustomobject]@{Arguments=('-File "'+$watch+'"')});Triggers=@($script:logon)}
        $script:setCount=0; $script:rejectWake=$case -eq 'wake-denied'; $script:editDuringStartup=$case -eq 'rollback-with-user-edit'; $script:rejectStartup=($case -eq 'startup-failed' -or $script:editDuringStartup)
        $report=[pscustomobject]@{Stage='';LogFile=(Join-Path $dir 'update.log');Warning='';Rollback='';Backup=''}
        $failure=$null
        try {Invoke-CampusUpdate $script:fixture $RepoRoot $script:destination $auto $files $script:packageVersion $report}
        catch {$failure=$_}
        Assert ([IO.File]::ReadAllText((Join-Path $script:destination 'config.json')) -eq '{"fixture":"preserved"}') 'User configuration changed.'
        Assert ([IO.File]::ReadAllText((Join-Path $script:destination 'default-account.txt')) -ceq '1000000001' -and [IO.File]::ReadAllText($accounts) -ceq '{"fixture":"existing accounts"}') 'A local account file changed.'
        Assert ([IO.File]::ReadAllText((Join-Path $report.Backup 'watchdog.ps1')) -eq 'old watchdog') 'The backup does not match the original.'
        if($script:rejectStartup){
            Assert ($failure -and $failure.Exception.Message -like '*could not start*') 'The true startup failure was hidden.'
            Assert ([IO.File]::ReadAllText($watch) -eq 'old watchdog' -and [IO.File]::ReadAllText($auto) -ceq $(if ($script:editDuringStartup) { $oldAuto+[Environment]::NewLine+'# user edit during update' } else { $oldAuto })) 'Rollback lost old entry points.'
            Assert (-not [IO.File]::Exists((Join-Path $script:destination 'monitor.ps1')) -and $script:fixture.Triggers.Count -eq 1) 'Rollback left new files or an extra trigger.'
            Assert ($script:fixture.Triggers[0].Delay -eq 'PT20S' -and -not [IO.Directory]::Exists((Join-Path $script:destination 'ui')) -and -not [IO.Directory]::Exists((Join-Path $script:destination 'tools'))) 'Rollback left a changed trigger delay or a created directory.'
            Assert ($script:fixture.State -eq 'Running' -and [IO.File]::ReadAllText($report.LogFile).Contains('fixture: could not start')) 'Rollback did not restart the old task or log the primary cause.'
        } else {
            if($failure){throw $failure}
            Assert ((Get-FileHash $watch).Hash -eq (Get-FileHash (Join-Path $RepoRoot 'watchdog.ps1')).Hash) 'The installed worker is not the package version.'
            Assert ([IO.File]::ReadAllText($auto) -ceq $oldAuto) 'The public updater changed a separate login tool.'
            foreach ($name in $files) {
                Assert ((Get-FileHash -LiteralPath (Join-Path $script:destination $name)).Hash -eq (Get-FileHash -LiteralPath (Join-Path $RepoRoot $name)).Hash) ('Package file differs after update: '+$name)
            }
            Assert ($script:fixture.State -eq 'Running' -and [IO.File]::Exists((Join-Path $script:destination 'ready.txt'))) 'Missing startup receipt.'
            if($script:rejectWake){
                Assert ($report.Warning -and $script:fixture.Triggers.Count -eq 1 -and $script:fixture.Triggers[0].Delay -eq 'PT20S') 'Optional trigger failure interrupted the required update.'
            } else {
                Assert ($script:fixture.Triggers.Count -eq 2 -and $script:fixture.Triggers[0].Delay -eq 'PT0S') 'The existing logon trigger did not become immediate.'
                Assert ($script:fixture.Triggers[1].CimSystemProperties.ClassName -eq 'MSFT_TaskEventTrigger') 'The event trigger lost its native CIM class.'
                Assert (-not (Add-WakeTrigger $script:fixture) -and $script:setCount -eq 1) 'A repeated update duplicated the wake trigger.'
            }
        }
        Write-Output ('PASS: installer transaction '+$case)
    }
} finally {
    $exact=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($exact).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($exact) -notmatch '^campus-update-test-[0-9a-f]{32}$') {throw 'Unexpected fixture directory.'}
    if ([IO.Directory]::Exists($exact)) {Remove-Item -LiteralPath $exact -Recurse -Force}
}
