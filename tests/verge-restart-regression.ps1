param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'network.ps1')
Initialize-CampusNative
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('campus-verge-life-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$journal=Join-Path $scratch 'recovery.json'
$script:CampusAuthMutexName='Local\'+[IO.Path]::GetFileName($scratch)
function Assert($Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
function Set-CampusStatus {}
function Get-VergeExecutable { return 'fixture\clash-verge.exe' }
function Read-VergePreferences { return [pscustomobject]@{runtime='fixture.yaml';port=7897;proxy=$true;tun=$true;pac=$false} }
function Get-VergeGui { return $script:gui }
function Test-VergePort { return $script:listener }
function Test-ClashTunActive { return $script:tun }
function Read-LanSettings { return $script:lan }
function Disable-LanProxy { $script:lan.Flags=1 }
function Set-LanSettings($Value) { $script:lan=$Value }
function Get-LocalClashController { if ($script:gui) {return [pscustomobject]@{config_path='fixture.yaml'}} }
function Invoke-ClashApi($Controller,[string]$Method='GET',$Payload) {
    if ($Method -eq 'PATCH' -and $Payload.ContainsKey('tun')) { $script:tun=$Payload.tun.enable }
    return [pscustomobject]@{mode='rule';tun=[pscustomobject]@{enable=$script:tun}}
}
function Get-Service { return [pscustomobject]@{Status=$script:service} }
function Start-Service { $script:service='Running' }
function Stop-VergeForLogin {
    Assert ([IO.File]::Exists($journal)) 'The first change occurred before the recovery journal existed.'
    $script:gui=$false; $script:listener=$false; $script:tun=$false; $script:service='Stopped'
}
function Open-VergeGui {
    if ($script:badStart) { throw 'Simulated startup error' }
    $script:gui=$true; $script:listener=$true; $script:tun=$true
}
try {
    foreach ($flags in @(3,5,1)) {
        $script:gui=$true; $script:listener=$true; $script:tun=($flags -ne 1); $script:service='Running'
        $script:lan=[pscustomobject]@{Flags=$flags;Server='127.0.0.1:7897';Bypass='localhost';Pac='http://127.0.0.1:7897/fixture-private.pac'}
        $script:badStart=$false
        Enter-AuthNetworkContext $journal
        Assert (-not $script:gui -and -not $script:tun -and -not $script:listener -and $script:lan.Flags -eq 1) 'Clash, TUN or the effective system proxy remained active.'
        Assert (-not [IO.File]::ReadAllText($journal).Contains('fixture-private')) 'PAC data leaked into the recovery journal.'
        $script:lan.Flags=3; $script:gui=$true # Simulate a late autostart.
        Update-AuthNetworkContext $journal
        Assert (-not $script:gui -and $script:lan.Flags -eq 1) 'A late proxy restart was ignored.'
        $script:badStart=$true
        Assert (-not (Restore-AuthNetworkContext $journal) -and [IO.File]::Exists($journal)) 'A failed restart lost its journal.'
        $script:badStart=$false
        Assert (Restore-AuthNetworkContext $journal) 'A retry failed to restore the proxy.'
        Assert ($script:gui -and $script:listener -and $script:service -eq 'Running' -and $script:tun -eq ($flags -ne 1)) 'The original runtime was not restored.'
        Assert ($script:lan.Flags -eq $flags -and -not [IO.File]::Exists($journal)) 'Original LAN flags were not restored.'
    }
    Write-Output 'PASS: system proxy, PAC, TUN and initially disabled states survive late autostart and interrupted restoration.'
    $script:gui=$false; $script:listener=$false; $script:tun=$false
    $script:lan.Flags=1
    Enter-AuthNetworkContext $journal -RepairProxy
    Assert (Restore-AuthNetworkContext $journal) 'Clash, missing after resume, was not restarted.'
    Assert ($script:gui -and $script:tun -and ($script:lan.Flags -band 2)) 'Requested system proxy/TUN were not rebuilt on resume.'
    Write-Output 'PASS: a missing proxy application and its disabled OS proxy are recovered from the saved Verge preferences.'
    foreach ($checkDuringLogin in @($true,$false)) {
        $script:lan=[pscustomobject]@{Flags=3;Server='127.0.0.1:7897';Bypass='localhost';Pac=''}
        Enter-AuthNetworkContext $journal
        $script:lan=[pscustomobject]@{Flags=5;Server='127.0.0.1:1888';Bypass='new-bypass';Pac='http://127.0.0.1/new-user-choice.pac'}
        if ($checkDuringLogin) {
            Update-AuthNetworkContext $journal
            Assert ($script:lan.Flags -eq 1) 'The new PAC should remain suspended only while authentication is in progress.'
        }
        Assert (Restore-AuthNetworkContext $journal) 'Restoration with an updated LAN preference failed.'
        Assert ($script:lan.Flags -eq 5 -and $script:lan.Pac -like '*new-user-choice*' -and $script:lan.Bypass -eq 'new-bypass') 'A PAC changed by the user during login was overwritten by the older snapshot.'
    }
    Write-Output 'PASS: user-edited PAC, bypass and flags survive a guard check and final Verge restoration.'
} finally {
    if ([IO.File]::Exists($journal)) { [IO.File]::Delete($journal) }
    [IO.Directory]::Delete($scratch)
}
