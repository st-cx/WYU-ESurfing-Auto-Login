param([string]$RepoRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'settings-store.ps1')
. (Join-Path $RepoRoot 'monitor.ps1')
$script:readCredential=(Get-Command Get-CampusCredential -CommandType Function).ScriptBlock
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'watchdog.ps1'),[ref]$null,[ref]$null)
foreach($name in 'Invoke-LoginClick','Test-SameLoginSample','Send-RecognizedLogin'){
    $def=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($def.Extent.Text))
}
Add-Type -TypeDefinition @'
using System;
namespace CampusRecovery {
    public static class LoginScreen {
        public static string Displayed="";
        public static bool FieldsReady, CanFill=true;
        public static int Clicks, Fills, LastVersion;
        public static bool CheckAccount(IntPtr h,object glyph,double x,double y,string user,bool password) {
            return h==(IntPtr)73 && FieldsReady && (String.IsNullOrEmpty(user) || user==Displayed);
        }
        public static bool FillAccount(IntPtr h,object glyph,string user,string password) {
            Fills++;
            if(!CanFill || h!=(IntPtr)73)return false;
            LastVersion=password=="fixture-A"?1:password=="fixture-B"?2:3;
            Displayed=user;FieldsReady=true;return true;
        }
        public static bool ClickVerified(IntPtr h,object glyph,double x,double y,bool physical,string user) {
            if(!CheckAccount(h,glyph,x,y,user,true))return false;
            Clicks++;return true;
        }
    }
}
'@
function Assert($ok,[string]$message){if(-not $ok){throw $message}}
function Get-CampusCredential {
    param($Root,$Account)
    $script:lookups += $Account
    & $script:readCredential -Root $Root -Account $Account
}
function Set-CampusStatus($phase,$message){$script:messages+=$message}
function Log($message){$script:messages+=$message}
function Test-Internet {return $false}
function Update-LoginGuard {}
function Get-LoginSample {return $script:sample}
function Get-CampusWindows {return [intptr]73}
function Save-WindowShot {throw 'Automatic authentication tried to write a screenshot.'}
function Start-Sleep {}
function Auth {
    $script:accountPending=$false
    return Invoke-LoginClick -BeforeLogin {$script:oldCallbacks++}
}
$Root=Join-Path ([IO.Path]::GetTempPath()) ('campus-account-auth-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Root)
$script:sample=[pscustomobject]@{Window=[intptr]73;Point=[pscustomobject]@{X=267;Y=533}}
$LoginReadyTimeout=10
$one='100001';$two='100002';$script:messages=@();$script:lookups=@();$script:oldCallbacks=0
try{
    Assert ((Auth) -eq 'AccountPending' -and [CampusRecovery.LoginScreen]::Clicks -eq 0 -and $script:lookups.Count -eq 0) 'A first-use empty form was submitted or fetched a credential.'
    $addAccount=[string][char]0x6dfb+[char]0x52a0+[char]0x8d26+[char]0x53f7
    Assert (($script:messages -join ' ').Contains($addAccount)) 'A missing saved password must point to Add Account.'
    [CampusRecovery.LoginScreen]::Displayed=$one; [CampusRecovery.LoginScreen]::FieldsReady=$true
    Assert ((Auth) -eq 'Submitted' -and [CampusRecovery.LoginScreen]::Fills -eq 0 -and $script:lookups.Count -eq 0) 'The remembered-client mode should use the verified form without retrieving any saved account.'
    Set-CampusDefaultAccount -Root $Root -Account $two
    Assert ((Auth) -eq 'AccountPending' -and [CampusRecovery.LoginScreen]::Clicks -eq 1) 'A selected unsaved account must not submit a different remembered user.'
    Set-CampusDefaultAccount -Root $Root -Account $one
    Assert ((Auth) -eq 'Submitted' -and [CampusRecovery.LoginScreen]::Fills -eq 0) 'A legacy selection matching the remembered form must remain usable.'
    Write-Output 'PASS: remembered forms, unsaved legacy selections and empty forms follow the selected account and never invoke the old callback.'

    foreach($value in 'fixture-A','fixture-B') {
        $secret=ConvertTo-SecureString $value -AsPlainText -Force
        try {Save-CampusAccount -Root $Root -Account $one -Password $secret -MakeDefault}
        finally {$secret.Dispose()}
        $before=[CampusRecovery.LoginScreen]::Fills
        Assert ((Auth) -eq 'Submitted' -and [CampusRecovery.LoginScreen]::Fills -eq $before+1) 'A managed account trusted stale masked text instead of filling the saved credential.'
        $version=if ($value -eq 'fixture-A'){1}else{2}
        Assert ([CampusRecovery.LoginScreen]::LastVersion -eq $version) 'An update of the same account and same password length was ignored.'
    }
    [CampusRecovery.LoginScreen]::CanFill=$false
    $before=[CampusRecovery.LoginScreen]::Clicks
    Assert ((Auth) -eq 'AccountPending' -and [CampusRecovery.LoginScreen]::Clicks -eq $before) 'A failed managed fill fell back to a stale remembered entry.'
    [CampusRecovery.LoginScreen]::CanFill=$true
    $script:lookups=@()
    Set-CampusDefaultAccount -Root $Root -Account $two
    Assert (-not (Send-RecognizedLogin $script:sample $false) -and [CampusRecovery.LoginScreen]::Clicks -eq $before) 'A default changed immediately before submission must cancel the stale click.'
    Assert ($script:lookups.Count -eq 0 -and $script:oldCallbacks -eq 0) 'A final account check used an unrelated secret or called the old companion.'
    [IO.File]::WriteAllText((Join-Path $Root 'campus-settings.json'),'{')
    Assert ((Auth) -eq 'AccountPending' -and -not $script:CampusPreferences -and [CampusRecovery.LoginScreen]::Clicks -eq $before) 'An unreadable selected-account policy silently fell back to the remembered form.'
    $publicText=$script:messages -join ' '
    Assert (-not $publicText.Contains($one) -and -not $publicText.Contains($two) -and -not $publicText.Contains('fixture-A')) 'A status or log line disclosed a fixture account or password.'
    Write-Output 'PASS: the latest managed password wins, equal-length replacements are used, failed fills and preference changes are guarded, and logs contain no account data.'
} finally {
    foreach($f in [IO.Directory]::GetFiles($Root)){[IO.File]::Delete($f)}
    [IO.Directory]::Delete($Root)
}
