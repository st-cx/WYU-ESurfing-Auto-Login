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
        'verge.ps1','network.ps1','monitor.ps1','watchdog.ps1','settings-store.ps1',
        '校园网设置.cmd','tools\settings.ps1','设置默认账号.cmd','tools\set-default-account.ps1',
        '校准按钮坐标.bat','tools\calibrate.ps1','tools\uia-probe.ps1')
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

function Remove-CompanionHooks([string]$Script) {
    # v1.6.x added these marked sections. Only uninstall needs to remove them.
    $Script = [regex]::Replace($Script,'(?ms)\r?\n^# CampusNet shared login v1\.6[ \t]*\r?\n.*?^# End CampusNet shared login[ \t]*(?=\r?$)','')
    $Script = [regex]::Replace($Script,'(?ms)^# CampusNet verified account v1\.6\.2[ \t]*\r?\n.*?^# End CampusNet verified account[ \t]*(?:\r?\n|\z)','')
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
