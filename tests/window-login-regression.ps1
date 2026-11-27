param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'network.ps1')
. (Join-Path $RepoRoot 'settings-store.ps1')
. (Join-Path $RepoRoot 'monitor.ps1')
Initialize-CampusNative
$refs=@('System.dll','System.Drawing.dll')
if($PSVersionTable.PSEdition -eq 'Core'){
    $refs=@((Get-ChildItem -Path (Join-Path $PSHOME 'ref/*.dll')).FullName)
    foreach($lib in 'System.Drawing.Common.dll','System.Private.Windows.Core.dll','Microsoft.Win32.SystemEvents.dll'){
        $path=Join-Path $PSHOME $lib
        if([IO.File]::Exists($path)){$refs+=$path}
    }
}
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures/TianyiLoginWindow.cs') -ReferencedAssemblies $refs
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'watchdog.ps1'),[ref]$null,[ref]$null)
foreach($name in 'Get-LoginSample','Test-SameLoginSample','Update-LoginGuard','Invoke-LoginClick','Send-RecognizedLogin','Wait-AuthSettle','Invoke-CampusRecovery') {
    $def=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($def.Extent.Text))
}
function Get-AuthenticationLock {return $true}
function Release-AuthenticationLock {}
function Restore-OwnedAdapter {return $true}
function Set-CampusStatus {}
function Send-Toast {}
function Log {}
function Get-PhysicalLink {return 'Campus'}
function Restart-Client {}
function Wait-AdapterUp {return $true}
function Repair-NicAdapter {throw 'The fixture must not reach adapter repair.'}
function Test-Internet {return $script:form.Accepted}
function Wait-InternetHttp {return $script:form.Accepted}
function Get-CampusWindows {return [CampusRecovery.LoginScreen]::Windows([int[]]@($PID))}
function Save-WindowShot {throw 'Automatic login tried to write a screenshot.'}
$Root=Join-Path ([IO.Path]::GetTempPath()) ('campus-window-login-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Root)
$NetworkStatePath=Join-Path $Root 'proxy-recovery.json';$AutoNetworkStatePath=Join-Path $Root 'other-journal.json'
$LoginReadyTimeout=8;$AuthSettleWaitSec=4;$NicBounceCooldown=180;$script:lastBounce=Get-Date
$script:LoginX=.5;$script:LoginY=.58
$glyphFile=Join-Path $RepoRoot 'ui/login-glyph.png'
$script:LoginGlyph=[Drawing.Bitmap]::new($glyphFile)
$account='100001';$newValue='fixture-B';$oldValue='fixture-A'
try{
    $secret=ConvertTo-SecureString $newValue -AsPlainText -Force
    try {Save-CampusAccount -Root $Root -Account $account -Password $secret -MakeDefault}
    finally {$secret.Dispose()}
    $script:form=[TianyiLoginWindow]::new($glyphFile,$account,$oldValue,$account,$newValue)
    if(-not (Invoke-SingleConnection -BeforeLogin {throw 'The old callback attempted to rewrite the form.'}) -or
        -not $script:form.Accepted -or $script:form.Clicks -ne 1 -or $script:form.PasswordCharacters -lt $newValue.Length) {
        throw 'The official-window fixture did not receive the selected stored credential and exactly one background login click.'
    }
    Write-Output 'PASS: an offscreen native Tianyi-form fixture receives the real DPAPI-backed form fill, password replacement, pixel verification and one background button submission.'
} finally {
    if($script:form){$script:form.Dispose()}
    $script:LoginGlyph.Dispose()
    foreach($f in [IO.Directory]::GetFiles($Root)){[IO.File]::Delete($f)}
    [IO.Directory]::Delete($Root)
}
