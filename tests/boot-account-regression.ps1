param(
    [string]$Package=(Split-Path -Parent $PSScriptRoot),
    [string]$LoginScreenshot,
    [string]$ExpectedUser,
    [string]$ErrorScreenshot
)
$ErrorActionPreference='Stop'
if ([bool]$LoginScreenshot -ne [bool]$ExpectedUser) { throw 'Supply both a login screenshot and its expected account for the optional recognition check.' }
. (Join-Path $Package 'network.ps1')
Initialize-CampusNative
function Assert-Check([bool]$Pass,[string]$Message) { if (-not $Pass) { throw $Message }; Write-Output ('PASS '+$Message) }
$glyph=[Drawing.Bitmap]::new((Join-Path $Package 'ui\login-glyph.png'))
$blank=[Drawing.Bitmap]::new(533,914)
try {
    $g=[Drawing.Graphics]::FromImage($blank);$g.Clear([Drawing.Color]::White);$g.Dispose()
    Assert-Check ([CampusRecovery.LoginScreen]::Match($blank,$glyph,.5,.58).IsEmpty) 'blank or loading screen is never clicked'
    $ink=[Drawing.Color]::FromArgb(0,125,0)
    for($y=0;$y -lt $glyph.Height;$y++){for($x=0;$x -lt $glyph.Width;$x++){if($glyph.GetPixel($x,$y).R -gt 127){$blank.SetPixel(210+$x,607+$y,$ink)}}}
    $match=[CampusRecovery.LoginScreen]::Match($blank,$glyph,.5,.58)
    Assert-Check (-not $match.IsEmpty -and [Math]::Abs($match.Y-618) -lt 4) 'login can be found below the old calibration area'
    $digits = '0123456789'
    $font = [Drawing.Font]::new('Segoe UI',23,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $graphics = [Drawing.Graphics]::FromImage($blank)
    try {
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        for ($i=0; $i -lt $digits.Length; $i++) {
            $graphics.DrawString([string]$digits[$i],$font,[Drawing.Brushes]::Black,
                [single]($match.X-150+19*$i),[single]($match.Y-230),[Drawing.StringFormat]::GenericTypographic)
        }
    } finally { $graphics.Dispose(); $font.Dispose() }
    Assert-Check ([CampusRecovery.LoginScreen]::MatchesNumber($blank,$match,$digits)) 'all ten digits are recognized in the account field'
    Assert-Check (-not [CampusRecovery.LoginScreen]::MatchesNumber($blank,$match,'0123456780')) 'a one-digit account mismatch is rejected'
    if($LoginScreenshot) {
        $pic=[Drawing.Bitmap]::new($LoginScreenshot)
        try {
            $center=[CampusRecovery.LoginScreen]::Match($pic,$glyph,.5,.58)
            Assert-Check (-not $center.IsEmpty) 'the actual Tianyi login screenshot matches'
            Assert-Check ([CampusRecovery.LoginScreen]::MatchesNumber($pic,$center,$ExpectedUser)) 'the actual account field matches the requested primary'
            $wrong=if($ExpectedUser[0] -eq '0'){'1'+$ExpectedUser.Substring(1)}else{'0'+$ExpectedUser.Substring(1)}
            Assert-Check (-not [CampusRecovery.LoginScreen]::MatchesNumber($pic,$center,$wrong)) 'a different account is rejected on the same screenshot'
            foreach ($scale in @(1.25,1.5)) {
                $large=[Drawing.Bitmap]::new([int]($pic.Width*$scale),[int]($pic.Height*$scale))
                try {
                    $g=[Drawing.Graphics]::FromImage($large)
                    try {$g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear;$g.DrawImage($pic,0,0,$large.Width,$large.Height)}finally{$g.Dispose()}
                    $p=[CampusRecovery.LoginScreen]::Match($large,$glyph,.5,.58)
                    Assert-Check (-not $p.IsEmpty) ("login recognition at scale "+$scale)
                    $norm=[Drawing.Bitmap]::new(533,914)
                    try {
                        $g=[Drawing.Graphics]::FromImage($norm)
                        try {$g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear;$g.DrawImage($large,0,0,533,914)}finally{$g.Dispose()}
                        $button=[Drawing.Point]::new([int]($p.X*533/$large.Width),[int]($p.Y*914/$large.Height))
                        Assert-Check ([CampusRecovery.LoginScreen]::MatchesNumber($norm,$button,$ExpectedUser)) ("account verification at scale "+$scale)
                    }finally{$norm.Dispose()}
                } finally {$large.Dispose()}
            }
        } finally { $pic.Dispose() }
    }
    if($ErrorScreenshot) {
        $pic=[Drawing.Bitmap]::new($ErrorScreenshot)
        try {Assert-Check ([CampusRecovery.LoginScreen]::Match($pic,$glyph,.5,.58).IsEmpty) 'Tianyi error 108 is never clicked'}finally{$pic.Dispose()}
    }
} finally {$glyph.Dispose();$blank.Dispose()}
