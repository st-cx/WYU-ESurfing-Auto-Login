function Get-ConsoleUser {
    # 当前登录(控制台)用户, 防止提权到其他管理员账号时把任务装错用户
    $u = $null
    try { $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName } catch {}
    if (-not $u) { $u = "$env:USERDOMAIN\$env:USERNAME" }
    return $u
}

function Get-InstallDir([string]$consoleUser) {
    $name = $consoleUser.Split('\')[-1]
    $profileDir = $null
    try {
        $profileDir = (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -and ($_.LocalPath.Split('\')[-1] -ieq $name) } |
            Select-Object -First 1).LocalPath
    } catch {}
    if (-not $profileDir -and $consoleUser -ieq ("$env:USERDOMAIN\$env:USERNAME") -and $env:USERPROFILE) {
        $profileDir = $env:USERPROFILE
    }
    if (-not $profileDir) { $profileDir = Join-Path 'C:\Users' $name }
    return (Join-Path $profileDir 'AppData\Local\CampusNetWatchdog')
}

function Get-CampusTask([string]$Name,[string]$Watch) {
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($task -and -not ($task.Actions | Where-Object { $_.Arguments -and $_.Arguments.IndexOf($Watch,[StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
        throw '已有同名计划任务指向其他安装目录。请核对当前登录用户。'
    }
    return $task
}

function Get-CompanionPath([string]$InstallDir) {
    $profileDir = [IO.Directory]::GetParent($InstallDir).Parent.Parent.FullName
    return (Join-Path $profileDir 'CampusNetAuto\campus-auth.ps1')
}

function Get-CampusProgramFiles {
    # Only program files belong to the public update. Accounts, calibration and settings are user data.
    return @('ui\LoginScreen.cs','ui\LanProxy.cs','ui\StatusTray.cs','ui\login-glyph.png',
        'verge.ps1','network.ps1','monitor.ps1','watchdog.ps1','设置默认账号.cmd','tools\set-default-account.ps1',
        '校准按钮坐标.bat','tools\calibrate.ps1','tools\uia-probe.ps1')
}

function Get-CompanionLoginBridge([string]$Script) {
    if ($Script.Contains('# CampusNet shared login v1.6')) { return $Script }
    $anchor = [regex]::new('(?m)^\. \$networkModule[ \t]*(?=\r?$)')
    if ($anchor.Matches($Script).Count -ne 1 -or -not $Script.Contains('function Ensure-DefaultAccount')) {
        throw '现有 CampusNetAuto 入口版本不同，未覆盖其自定义代码。'
    }
    $bridge = @'
# CampusNet shared login v1.6
if ($ClientMode -in @('Auto','Connect')) {
    try {
        $ok = & {
            . (Join-Path (Split-Path -Parent $networkModule) 'watchdog.ps1') -Embedded
            try {
                Invoke-SingleConnection -BeforeLogin {
                    $win = Find-ClientWindow
                    if ($win) { Ensure-DefaultAccount $win }
                }
            } finally { $script:LoginGlyph.Dispose() }
        }
        if ($ok) { Write-Result $true '在线'; exit 0 }
        Write-Result $false '校园网或代理尚未就绪，看门狗将继续重试'
    } catch { Write-Result $false '启动认证未完成，看门狗将继续重试' }
    exit 1
}
# End CampusNet shared login
'@
    $newline = if ($Script.Contains("`r`n")) { "`r`n" } else { "`n" }
    $bridge = $bridge -replace '\r?\n', $newline
    return $anchor.Replace($Script,[Text.RegularExpressions.MatchEvaluator]{param($match) $match.Value+$newline+$bridge})
}

function Get-CompanionUpdate([string]$Script) {
    $updated = Get-CompanionLoginBridge $Script
    if ($updated.Contains('# CampusNet verified account v1.6.2') -or -not $updated.Contains('function Load-Accounts') -or -not $updated.Contains('function Unprotect-Text')) { return $updated }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$errors)
    $slot=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and $_.Left.VariablePath.UserPath -eq 'req' })
    if ($slot.Count -ne 1) { throw '无法定位现有账号工具的请求入口。' }
    $handler=@'
# CampusNet verified account v1.6.2
$campusInput = Get-Variable -Name CampusAccountInvocation -ValueOnly -ErrorAction SilentlyContinue
if ($campusInput -and $campusInput.User -match '^[0-9]{6,16}$' -and $campusInput.Window -ne [IntPtr]::Zero) {
    try {
        $cfg = Load-Accounts
        $acct = @($cfg.accounts | Where-Object { [string]$_.user -ceq [string]$campusInput.User }) | Select-Object -First 1
        if (-not $acct -or -not $acct.pass_enc) { return 'CampusAccountMissing' }
        $plain = Unprotect-Text $acct.pass_enc
        if (-not $plain) { return 'CampusAccountMissing' }
        $applied = [CampusRecovery.LoginScreen]::FillAccount($campusInput.Window,$campusInput.Glyph,$campusInput.User,$plain)
        if ($applied) { return 'CampusAccountReady' }
    } catch { } finally { $plain=$null }
    return 'CampusAccountUnverified'
}
# End CampusNet verified account
'@
    $newline = if ($updated.Contains("`r`n")) { "`r`n" } else { "`n" }
    return $updated.Insert($slot[0].Extent.StartOffset,($handler -replace '\r?\n', $newline)+$newline)
}

function Assert-PowerShellSource([string]$Text,[string]$Name) {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw ('脚本语法检查失败：'+$Name) }
}
function Write-BytesAtomically([string]$Path,[byte[]]$Bytes) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($tmp,$Bytes)
        [CampusRecovery.FileCommit]::Replace($tmp,$Path)
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Read-CompanionScript([string]$Path) {
    # Detect a BOM and refuse to rewrite unrecognised bytes as replacement characters.
    return [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
}

function Get-CompanionEdit([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $original = Read-CompanionScript $Path
        $updated = Get-CompanionUpdate $original
        if ($updated -cne $original) {
            Assert-PowerShellSource $updated 'CampusNetAuto'
            return [pscustomobject]@{ Original=$original; Updated=$updated; Warning='' }
        }
    } catch {
        return [pscustomobject]@{ Original=$null; Updated=$null; Warning=('已保留自定义 CampusNetAuto 入口：'+$_.Exception.Message) }
    }
}

function Remove-CompanionHooks([string]$Script,[switch]$KeepLogin,[switch]$KeepAccount) {
    if (-not $KeepLogin) {
        $Script = [regex]::Replace($Script,'(?ms)\r?\n^# CampusNet shared login v1\.6[ \t]*\r?\n.*?^# End CampusNet shared login[ \t]*(?=\r?$)','')
    }
    if (-not $KeepAccount) {
        $Script = [regex]::Replace($Script,'(?ms)^# CampusNet verified account v1\.6\.2[ \t]*\r?\n.*?^# End CampusNet verified account[ \t]*(?:\r?\n|\z)','')
    }
    return $Script
}

function Write-CompanionScript([string]$Path,[string]$Text) {
    $encoding = [Text.UTF8Encoding]::new($true)
    Write-BytesAtomically $Path ([byte[]]($encoding.GetPreamble()+$encoding.GetBytes($Text)))
}

function Add-WakeTrigger($Task) {
    $query = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[(Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1) or (Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=107)]]</Select></Query></QueryList>"
    $previous = @($Task.Triggers)
    $changed=$false
    $triggers = @(
        foreach ($trigger in $previous) {
            if ($trigger.CimSystemProperties.ClassName -eq 'MSFT_TaskLogonTrigger' -and $trigger.Delay -and $trigger.Delay -ne 'PT0S') {
                $trigger = [Microsoft.Management.Infrastructure.CimInstance]::new($trigger)
                $trigger.Delay = 'PT0S'
                $changed = $true
            }
            $trigger
        }
    )
    if (-not ($previous | Where-Object { $_.Subscription -eq $query })) {
        $wake = New-CimInstance -ClientOnly -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler' -Property @{
            Enabled = $true; Subscription = $query
        }
        $triggers=@($triggers + $wake); $changed=$true
    }
    if (-not $changed) { return $false }
    # The provider declares event and logon triggers as subclasses of MSFT_TaskTrigger.
    # Windows PowerShell's Set-ScheduledTask also checks this *PowerShell* type name.
    # A client-only CIM instance, and some deserialized existing triggers, omit it.
    $baseType = 'Microsoft.Management.Infrastructure.CimInstance#MSFT_TaskTrigger'
    foreach ($trigger in $triggers) {
        if ($trigger.PSObject.TypeNames -notcontains $baseType) { $trigger.PSObject.TypeNames.Add($baseType) }
    }
    Set-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Trigger $triggers -ErrorAction Stop | Out-Null
    return $true
}
