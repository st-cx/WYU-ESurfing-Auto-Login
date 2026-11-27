param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'network.ps1')
. (Join-Path $RepoRoot 'monitor.ps1')
Initialize-CampusNative
function Assert($Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
$now = [datetime]::UtcNow
Assert ([CampusRecovery.StatusTray]::IsSleepGap($now,$now.AddMinutes(75))) 'Long standby was ignored.'
Assert (-not [CampusRecovery.StatusTray]::IsSleepGap($now,$now.AddSeconds(2))) 'Ordinary monitoring delay was treated as a wake.'
$AdapterName='Ethernet'; $CampusGuard=$true; $CampusIpPrefixes=@('100.2.'); $CampusGateways=@('100.2.0.1')
$nic=[pscustomobject]@{Name=$AdapterName;OperationalStatus='Up'}
$nic | Add-Member ScriptMethod GetIPProperties {return $script:ipProps}
$script:ipProps=[pscustomobject]@{UnicastAddresses=@();GatewayAddresses=@()}
Assert ((Get-PhysicalLink @($nic)) -eq 'Waiting') 'An empty DHCP lease must be checked again soon.'
$addr=[pscustomobject]@{Address=[ipaddress]'169.254.2.1';DuplicateAddressDetectionState='Preferred'}
$script:ipProps.UnicastAddresses=@($addr)
Assert ((Get-PhysicalLink @($nic)) -eq 'Waiting') 'A link-local lease cannot authorize a login.'
$addr.Address=[ipaddress]'100.2.4.5'
Assert ((Get-PhysicalLink @($nic)) -eq 'Campus') 'The physical campus lease was missed.'
$addr.Address=[ipaddress]'192.168.4.5'; $script:ipProps.GatewayAddresses=@([pscustomobject]@{Address=[ipaddress]'192.168.4.1'})
Assert ((Get-PhysicalLink @($nic)) -eq 'Away') 'An off-campus link must remain quiet.'
Write-Output 'PASS: 75-minute resume, delayed DHCP, valid campus lease and off-campus link are distinct.'

$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'watchdog.ps1'),[ref]$null,[ref]$null)
foreach ($name in 'Invoke-LoginClick','Test-SameLoginSample') {
    $def=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($def.Extent.Text))
}
function Set-CampusStatus {}
function Update-LoginGuard {}
function Start-Sleep {}
function Test-Internet {return $script:online}
function Get-LoginSample {
    $script:frames++
    if ($script:frames -in @(3,5,6)) { return [pscustomobject]@{Window=[intptr]42;Point=[Drawing.Point]::new(266,531)} }
    if ($script:frames -gt 6) { throw 'The stable login was missed.' }
}
function Send-RecognizedLogin($Sample,$Physical) { $script:clicks++; return $true }
$script:frames=0; $script:clicks=0; $script:online=$false; $LoginReadyTimeout=100
Assert ((Invoke-LoginClick) -eq 'Submitted' -and $script:frames -eq 6 -and $script:clicks -eq 1) 'An unstable screen was clicked.'
$script:online=$true
Assert ((Invoke-LoginClick) -eq 'Online' -and $script:clicks -eq 1) 'An auto-authenticated session was clicked.'
$LoginReadyTimeout=0
Assert ((Invoke-LoginClick) -eq 'Timeout' -and $script:clicks -eq 1) 'A recognition timeout generated a click.'
Write-Output 'PASS: loading, a one-frame login, a stable button, automatic login and timeout produce the correct click counts.'

$glyph=[Drawing.Bitmap]::new((Join-Path $RepoRoot 'ui\login-glyph.png'))
$frame=[Drawing.Bitmap]::new(533,914); $g=[Drawing.Graphics]::FromImage($frame)
try {
    $g.Clear([Drawing.Color]::WhiteSmoke)
    Assert ([CampusRecovery.LoginScreen]::Match($frame,$glyph,0.5,0.583).IsEmpty) 'Blank screen matched.'
    $g.DrawString('网络状态检测中',[Drawing.SystemFonts]::MessageBoxFont,[Drawing.Brushes]::Green,226,525)
    Assert ([CampusRecovery.LoginScreen]::Match($frame,$glyph,0.5,0.583).IsEmpty) 'Loading text matched.'
    $g.Clear([Drawing.Color]::WhiteSmoke)
    for ($y=0;$y -lt $glyph.Height;$y++) {for ($x=0;$x -lt $glyph.Width;$x++) {
        if ($glyph.GetPixel($x,$y).R -gt 127) { $frame.SetPixel(240+$x,520+$y,[Drawing.Color]::Green) }
    }}
    foreach ($scale in @(1,1.25,1.5)) {
        $scaled=[Drawing.Bitmap]::new($frame,[int]($frame.Width*$scale),[int]($frame.Height*$scale))
        try { Assert (-not [CampusRecovery.LoginScreen]::Match($scaled,$glyph,0.5,0.583).IsEmpty) ('Login not recognized at scale '+$scale) }
        finally {$scaled.Dispose()}
    }
} finally {$g.Dispose();$frame.Dispose();$glyph.Dispose()}
Write-Output 'PASS: the glyph matcher rejects blank/loading frames and accepts the login at 100%, 125%, and 150%.'
