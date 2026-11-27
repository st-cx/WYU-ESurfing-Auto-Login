param(
    [string]$Package=(Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Main','Accounts','Proxy')][string]$Role='Main',
    [string]$FixtureRoot
)
$ErrorActionPreference='Stop'
. (Join-Path $Package 'settings-store.ps1')
function Check($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function File-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Check-Password([string]$Dir,[string]$Id,[string]$Expected) {
    $saved = Get-CampusCredential -Root $Dir -Account $Id
    Check ($saved -is [pscredential]) 'Missing fixture credential.'
    try { Check ($saved.UserName -ceq $Id -and $saved.GetNetworkCredential().Password -ceq $Expected) 'Wrong fixture credential.' }
    finally { $saved.Password.Dispose() }
}
function Write-Sample([string]$Dir,[string]$Id,[string]$Text,[switch]$Default) {
    $secure = ConvertTo-SecureString $Text -AsPlainText -Force
    try { Save-CampusAccount -Root $Dir -Account $Id -Password $secure -MakeDefault:$Default }
    finally { $secure.Dispose() }
}
function Wait-ForFixtureFile([string]$Path) {
    $until = [datetime]::UtcNow.AddSeconds(45)
    while (-not [IO.File]::Exists($Path)) {
        if ([datetime]::UtcNow -gt $until) { throw 'Offline test worker did not reach its synchronization point.' }
        Start-Sleep -Milliseconds 35
    }
}
if ($Role -ne 'Main') {
    $env:PSModulePath = Join-Path $PSHOME 'Modules'
    Check ($FixtureRoot -and [IO.File]::Exists((Join-Path $FixtureRoot 'fixture.flag'))) 'Refusing to run a worker outside a prepared fixture.'
    Check-Password $FixtureRoot '00000111' 'cross-shell fixture'
    [IO.File]::WriteAllText((Join-Path $FixtureRoot ($Role+'.ready')),'ready')
    Wait-ForFixtureFile (Join-Path $FixtureRoot 'go')
    $start = if ($Role -eq 'Accounts') { 7310000 } else { 7320000 }
    foreach ($i in 0..7) {
        $id = ($start+$i).ToString('D8')
        Write-Sample $FixtureRoot $id ($Role+' offline fixture '+$i)
        if ($Role -eq 'Proxy') { Set-CampusProxyIntegration -Root $FixtureRoot -Enabled (($i % 2) -eq 1) }
    }
    return
}

function New-Case([string]$Name) {
    $dir=Join-Path $scratch $Name
    [void][IO.Directory]::CreateDirectory($dir)
    return $dir
}
function Write-LegacyFixture([string]$Dir) {
    [IO.File]::WriteAllText((Join-Path $Dir 'default-account.txt'),'00120001',[Text.Encoding]::Unicode)
    $pwd=ConvertTo-SecureString 'legacy offline fixture' -AsPlainText -Force
    try { [pscredential]::new('00120002',$pwd) | Export-Clixml -LiteralPath (Join-Path $Dir 'alternate-credential.xml') }
    finally { $pwd.Dispose() }
}
function Check-Rejection([scriptblock]$Action,[string]$Path) {
    $before=File-Hash $Path
    $failure=$null
    try { & $Action | Out-Null } catch { $failure=$_ }
    Check ($failure -and (File-Hash $Path) -ceq $before) 'Invalid data must raise an error and retain the original bytes.'
}
function Start-Worker([string]$Engine,[string]$Name,[string]$Dir) {
    $packageDir=(Resolve-Path -LiteralPath $Package).ProviderPath
    $argsLine='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Package "'+$packageDir+'" -Role '+$Name+' -FixtureRoot "'+$Dir+'"'
    $process=Start-Process -FilePath $Engine -ArgumentList $argsLine -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Dir ($Name+'.stderr')) -RedirectStandardOutput (Join-Path $Dir ($Name+'.stdout'))
    [void]$process.Handle
    return $process
}

$scratch=Join-Path ([IO.Path]::GetTempPath()) ('CampusSettingsTest-'+[guid]::NewGuid().ToString('N'))
$children=@()
try {
    $dir=New-Case 'current'
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'),'{"proxy_guard":true}')
    $path=Join-Path $dir 'campus-settings.json'
    $pref=Get-CampusPreferences $dir
    Check ($pref -is [pscustomobject] -and $pref.Accounts -is [string[]] -and $pref.Accounts.Count -eq 0 -and $pref.DefaultAccount -ceq '' -and $pref.ProxyEnabled -is [bool] -and -not $pref.ProxyEnabled -and -not [IO.File]::Exists($path)) 'No opt-in, no account and no writes on a new installation.'
    Write-Sample $dir '00001111' 'first offline fixture'
    Check ((Get-CampusPreferences $dir).DefaultAccount -ceq '00001111') 'First saved account did not become default.'
    Write-Sample $dir '00002222' 'second offline fixture'
    Write-Sample $dir '00002222' 'edited offline fixture' -Default
    Set-CampusProxyIntegration -Root $dir -Enabled $true
    $pref=Get-CampusPreferences $dir
    Check ($pref.Accounts.Count -eq 2 -and ($pref.Accounts -join ',') -ceq '00001111,00002222' -and $pref.DefaultAccount -ceq '00002222' -and $pref.ProxyEnabled) 'Updating an account duplicated it or lost another setting.'
    Check-Password $dir '00002222' 'edited offline fixture'
    Check (-not [IO.File]::ReadAllText($path).Contains('offline fixture')) 'A fixture password appeared in the settings file.'
    Check-Rejection { Set-CampusDefaultAccount -Root $dir -Account 'not-an-account' } $path
    Remove-CampusAccount $dir '00002222'
    $pref=Get-CampusPreferences $dir
    Check ($pref.DefaultAccount -ceq '' -and $pref.ProxyEnabled -and $pref.Accounts.Count -eq 1 -and $null -eq (Get-CampusCredential $dir '00002222')) 'Removing the default did not restore the client choice.'
    Set-CampusDefaultAccount -Root $dir -Account '00009999'
    Check ((Get-CampusPreferences $dir).DefaultAccount -ceq '00009999' -and $null -eq (Get-CampusCredential $dir '00009999')) 'The remembered client account must work without storing its password.'
    Write-Output 'PASS: explicit proxy opt-in, default account rules, multiple encrypted credentials and editing.'

    $dir=New-Case 'legacy'
    Write-LegacyFixture $dir
    $legacyXml=Join-Path $dir 'alternate-credential.xml'
    $oldDefault=Join-Path $dir 'default-account.txt'
    $xmlBytes=[IO.File]::ReadAllBytes($legacyXml)
    $path=Join-Path $dir 'campus-settings.json'
    $pref=Get-CampusPreferences $dir
    Check (-not $pref.ProxyEnabled -and $pref.DefaultAccount -ceq '00120001' -and $pref.Accounts.Count -eq 1 -and $pref.Accounts[0] -ceq '00120002' -and -not [IO.File]::Exists($path)) 'Read-only legacy access lost a credential or wrote new settings.'
    Check-Password $dir '00120002' 'legacy offline fixture'
    Set-CampusProxyIntegration -Root $dir -Enabled $true
    Check-Password $dir '00120002' 'legacy offline fixture'
    $pref=Get-CampusPreferences $dir
    Check ($pref.DefaultAccount -ceq '00120001' -and $pref.ProxyEnabled) 'The first write lost a legacy preference.'
    Set-CampusDefaultAccount -Root $dir -Account ''
    Remove-CampusAccount $dir '00120002'
    [IO.File]::WriteAllBytes($legacyXml,$xmlBytes)
    [IO.File]::WriteAllText($oldDefault,'00120001')
    $pref=Get-CampusPreferences $dir
    Check ($pref.DefaultAccount -ceq '' -and $pref.Accounts.Count -eq 0 -and $null -eq (Get-CampusCredential $dir '00120002')) 'A stale legacy file resurrected a cleared account.'
    Write-Output 'PASS: legacy default/CLIXML migration, DPAPI password recovery and persistent clearing.'

    $dir=New-Case 'damaged'
    $path=Join-Path $dir 'campus-settings.json'
    foreach ($bad in @('', '{bad', '{"version":2,"defaultAccount":"","proxyEnabled":false,"accounts":[]}',
        '{"version":1,"defaultAccount":"","proxyEnabled":"false","accounts":[]}',
        '{"version":1,"defaultAccount":"","proxyEnabled":true,"proxyEnabled":false,"accounts":[]}',
        '{"version":1,"defaultAccount":"","proxyEnabled":true,"accounts":[{"account":"00001111","passwordDpapi":"invalid"}]}')) {
        [IO.File]::WriteAllText($path,$bad)
        Check-Rejection { Get-CampusPreferences $dir } $path
        Check-Rejection { Set-CampusProxyIntegration -Root $dir -Enabled $true } $path
    }
    [IO.File]::Delete($path)
    [IO.File]::WriteAllText((Join-Path $dir 'alternate-credential.xml'),'<different-format/>')
    Check-Rejection { Write-Sample $dir '00001111' 'offline' } (Join-Path $dir 'alternate-credential.xml')
    Check (-not [IO.File]::Exists($path)) 'Malformed legacy data was covered by a new settings file.'
    [IO.File]::Delete((Join-Path $dir 'alternate-credential.xml'))
    Write-Sample $dir '00001111' 'opaque fixture'
    Write-Sample $dir '00002222' 'valid fixture'
    $json=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    $opaque=$json.accounts[0].passwordDpapi
    $json.accounts[0].passwordDpapi=$opaque.Substring(0,$opaque.Length-2)+$(if($opaque.EndsWith('00')){'01'}else{'00'})
    [IO.File]::WriteAllText($path,($json|ConvertTo-Json -Depth 5))
    Check ((Get-CampusPreferences $dir).Accounts.Count -eq 2) 'Listing preferences attempted to decrypt unselected accounts.'
    Check-Password $dir '00002222' 'valid fixture'
    Check-Rejection { Get-CampusCredential $dir '00001111' } $path
    Write-Output 'PASS: invalid schema, duplicates, damaged data and decryption of only the selected account.'

    $dir=New-Case 'parallel'
    [IO.File]::WriteAllText((Join-Path $dir 'fixture.flag'),'offline fixture')
    Write-Sample $dir '00000111' 'cross-shell fixture'
    $win=(Get-Command powershell.exe -ErrorAction Stop).Source
    $core=Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $other=if ($core) { $core.Source } else { $win }
    $children+=Start-Worker $win 'Accounts' $dir
    $children+=Start-Worker $other 'Proxy' $dir
    $roles=@('Accounts','Proxy')
    for ($i=0; $i -lt $children.Count; $i++) {
        $ready=Join-Path $dir ($roles[$i]+'.ready')
        $deadline=[datetime]::UtcNow.AddSeconds(45)
        while (-not [IO.File]::Exists($ready)) {
            if ($children[$i].HasExited) { throw ('Offline '+$roles[$i]+' failed before synchronization. '+([IO.File]::ReadAllText((Join-Path $dir ($roles[$i]+'.stderr'))) -split '\r?\n')[0]) }
            Check ([datetime]::UtcNow -lt $deadline) 'Timed out starting offline worker.'
            Start-Sleep -Milliseconds 35
        }
    }
    [IO.File]::WriteAllText((Join-Path $dir 'go'),'go')
    for ($i=0; $i -lt $children.Count; $i++) {
        $child=$children[$i]
        Check ($child.WaitForExit(45000)) 'Concurrent offline write timed out.'
        $child.Refresh()
        if ($child.ExitCode -ne 0) { throw ('Offline '+$roles[$i]+' failed. '+([IO.File]::ReadAllText((Join-Path $dir ($roles[$i]+'.stderr'))) -split '\r?\n')[0]) }
    }
    $pref=Get-CampusPreferences $dir
    Check ($pref.Accounts.Count -eq 17 -and $pref.ProxyEnabled -and $pref.DefaultAccount -ceq '00000111') 'Concurrent writers lost accounts, proxy settings or the default.'
    foreach ($i in 0..7) {
        Check-Password $dir ((7310000+$i).ToString('D8')) ('Accounts offline fixture '+$i)
        Check-Password $dir ((7320000+$i).ToString('D8')) ('Proxy offline fixture '+$i)
    }
    $engines=if ($core) {'Windows PowerShell and PowerShell 7'} else {'two Windows PowerShell processes'}
    Write-Output ('PASS: same-user DPAPI and concurrent read/modify/write with '+$engines+'.')
} finally {
    foreach ($child in $children) {
        if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
        $child.Dispose()
    }
    $exact=[IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($exact).TrimEnd('\') -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($exact) -notmatch '^CampusSettingsTest-[a-f0-9]{32}$') { throw 'Unexpected fixture path.' }
    if ([IO.Directory]::Exists($exact)) { Remove-Item -LiteralPath $exact -Recurse -Force }
}
