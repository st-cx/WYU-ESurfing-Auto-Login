param([switch]$Preview,[switch]$WriteResult)
$ErrorActionPreference = 'Stop'
$package = $PSScriptRoot
. (Join-Path $package 'tools\setup.ps1')
$target = Get-InstallDir (Get-ConsoleUser)
$auto = Get-CompanionPath $target
$taskName = 'CampusNetWatchdog'
$version = '1.6.3'
$files = Get-CampusProgramFiles
$report = [pscustomobject]@{Stage='检查更新包'; LogFile=$null; Warning=''; Rollback=''; Backup=''}

function Write-UpdateLog($Report,[string]$Text) {
    if (-not $Report.LogFile) { return }
    try {
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')+' ['+$PID+'] '+$Text+[Environment]::NewLine
        [IO.File]::AppendAllText($Report.LogFile,$line,[Text.UTF8Encoding]::new($false))
    } catch { Write-Verbose '更新日志当前不可写。' }
}
function Set-UpdateStage($Report,[string]$Step) {
    $Report.Stage = $Step
    Write-UpdateLog $Report $Step
}
function Save-UpdateResult([string]$State,[string]$Message) {
    if ($WriteResult) {
        [IO.File]::WriteAllText((Join-Path $package 'update-result.txt'),$State+[Environment]::NewLine+$Message,[Text.UTF8Encoding]::new($false))
    } else { Write-Output $Message }
}
function Wait-InstalledWatchdog($Task,[string]$Target,[string]$Version,[long]$LaunchTicks) {
    $file = Join-Path $Target 'ready.txt'
    $until = [datetime]::UtcNow.AddSeconds(50)
    $retried = $false
    $pattern = '^'+[regex]::Escape($Version)+'\|(\d+)\|True\|(\d+)$'
    do {
        Start-Sleep -Milliseconds 450
        $current = Get-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
        $marker = ''
        if ([IO.File]::Exists($file)) {
            try { $marker = [IO.File]::ReadAllText($file) } catch [IO.IOException] {}
        }
        if ($current.State -eq 'Running' -and $marker -match $pattern -and [long]$Matches[2] -ge $LaunchTicks) {
            if (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) { return }
        }
        if (-not $retried -and $current.State -eq 'Ready' -and ([datetime]::UtcNow.Ticks-$LaunchTicks) -gt [TimeSpan]::FromSeconds(6).Ticks) {
            Start-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
            $retried = $true
        }
    } while ([datetime]::UtcNow -lt $until)
    $info = Get-ScheduledTaskInfo -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction SilentlyContinue
    throw ('未收到新版进程和托盘的就绪回执。计划任务状态 '+$current.State+'，运行结果 '+$info.LastTaskResult+'。')
}
function Invoke-CampusUpdate($Task,[string]$Package,[string]$Target,[string]$Auto,[string[]]$Files,[string]$Version,$Report) {
    $watch = Join-Path $Target 'watchdog.ps1'
    Set-UpdateStage $Report '等待正在进行的校园网认证结束'
    $lock = Get-AuthenticationLock -TimeoutMs 180000
    if (-not $lock) { throw '天翼仍在认证，升级尚未开始。' }
    $backup = Join-Path $Target ('backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$PID)
    $journal = Join-Path $Target 'proxy-recovery.json'
    $otherJournal = Join-Path (Split-Path -Parent $Auto) 'proxy-recovery.json'
    $stopped = $false; $replaced = [Collections.Generic.List[string]]::new()
    $changedTask = $false; $changedAuto = $false
    $missingDirs = @('ui','tools' | ForEach-Object { Join-Path $Target $_ } | Where-Object { -not [IO.Directory]::Exists($_) })
    try {
        $Task = Get-CampusTask $Task.TaskName $watch
        if (-not $Task -or -not [IO.File]::Exists($watch)) { throw '没有找到现有安装。请解压完整 ZIP 并运行一键安装。' }
        Set-UpdateStage $Report '备份现有脚本及计划任务'
        $edit = Get-CompanionEdit $Auto
        if ($edit.Warning) {
            $Report.Warning = $edit.Warning
            Write-UpdateLog $Report $edit.Warning
        }
        [void][IO.Directory]::CreateDirectory($backup)
        $Report.Backup = $backup
        $oldXml = Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
        [IO.File]::WriteAllText((Join-Path $backup 'task.xml'),$oldXml,[Text.Encoding]::Unicode)
        foreach ($name in $Files) {
            $old = Join-Path $Target $name
            if ([IO.File]::Exists($old)) {
                $backupFile = Join-Path $backup $name
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backupFile))
                [IO.File]::Copy($old,$backupFile)
            }
        }
        if ($edit.Updated) { [IO.File]::Copy($Auto,(Join-Path $backup 'campus-auth.ps1')) }
        Set-UpdateStage $Report '停止旧版看门狗'
        Stop-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
        $stopped = $true
        $stopUntil = [datetime]::UtcNow.AddSeconds(12)
        while ((Get-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop).State -eq 'Running') {
            if ([datetime]::UtcNow -ge $stopUntil) { throw '原看门狗仍在退出。' }
            Start-Sleep -Milliseconds 350
        }
        if (-not (Restore-AuthNetworkContext $journal) -or -not (Restore-AuthNetworkContext $otherJournal)) { throw '代理设置仍在恢复。' }
        Set-UpdateStage $Report '安装新版文件及开机认证入口'
        foreach ($name in $Files) {
            Write-BytesAtomically (Join-Path $Target $name) ([IO.File]::ReadAllBytes((Join-Path $Package $name)))
            $replaced.Add($name)
        }
        if ($edit.Updated) {
            if ((Read-CompanionScript $Auto) -cne $edit.Original) { throw '开机认证入口在更新过程中被修改。请重试。' }
            Write-CompanionScript $Auto $edit.Updated
            $changedAuto = $true
        }
        Set-UpdateStage $Report '设置附加唤醒触发器'
        try { $changedTask = Add-WakeTrigger $Task }
        catch {
            $warning = 'Windows 暂未接受登录触发时间或附加唤醒设置，常驻程序仍会检查网络。'
            $Report.Warning = (@($Report.Warning,$warning) | Where-Object { $_ }) -join [Environment]::NewLine
            Write-UpdateLog $Report ($warning+' Windows：'+$_.Exception.Message+' ['+$_.FullyQualifiedErrorId+']')
        }
        Set-UpdateStage $Report '启动新版看门狗'
        $launchTime = [datetime]::UtcNow.Ticks
        Start-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
        Set-UpdateStage $Report '验证新版进程及右下角托盘'
        Wait-InstalledWatchdog $Task $Target $Version $launchTime
    } catch {
        $failure = $_
        Write-UpdateLog $Report ('失败步骤：'+$Report.Stage+'。'+$failure.Exception.Message+' ['+$failure.FullyQualifiedErrorId+']')
        if ($stopped) {
            $issues = [Collections.Generic.List[string]]::new()
            try { Stop-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop }
            catch { $issues.Add('停止更新实例：'+$_.Exception.Message) }
            if ($changedAuto) {
                try {
                    if ([IO.File]::Exists($Auto)) {
                        $now = Read-CompanionScript $Auto
                        if ($now -ceq $edit.Updated) {
                            Write-BytesAtomically $Auto ([IO.File]::ReadAllBytes((Join-Path $backup 'campus-auth.ps1')))
                        } else {
                            $restored = Remove-CompanionHooks $now -KeepLogin:($edit.Original.Contains('# CampusNet shared login v1.6')) -KeepAccount:($edit.Original.Contains('# CampusNet verified account v1.6.2'))
                            if ($restored -cne $now) { Write-CompanionScript $Auto $restored }
                        }
                    }
                }
                catch { $issues.Add('还原开机认证入口：'+$_.Exception.Message) }
            }
            foreach ($name in $replaced) {
                try {
                    $bak = Join-Path $backup $name; $dst = Join-Path $Target $name
                    if ([IO.File]::Exists($bak)) { Write-BytesAtomically $dst ([IO.File]::ReadAllBytes($bak)) }
                    elseif ([IO.File]::Exists($dst)) { [IO.File]::Delete($dst) }
                } catch { $issues.Add('还原 '+$name+'：'+$_.Exception.Message) }
            }
            foreach ($dir in $missingDirs) {
                try {
                    if ([IO.Directory]::Exists($dir) -and [IO.Directory]::GetFileSystemEntries($dir).Length -eq 0) {
                        [IO.Directory]::Delete($dir)
                    }
                } catch { $issues.Add('清理新增目录：'+$_.Exception.Message) }
            }
            if ($changedTask) {
                try { Register-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Xml $oldXml -Force -ErrorAction Stop | Out-Null }
                catch { $issues.Add('还原原计划任务：'+$_.Exception.Message) }
            }
            try { Start-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop }
            catch { $issues.Add('启动原任务：'+$_.Exception.Message) }
            if ($issues.Count) { $Report.Rollback = '回滚仍有问题。'+($issues -join '。')+'。备份位于 '+$backup }
            else { $Report.Rollback = '已还原原版本并请求启动原计划任务。' }
            Write-UpdateLog $Report $Report.Rollback
        }
        throw $failure
    } finally { Release-AuthenticationLock $lock }
}

try {
    if (-not $Preview) {
        $logs = Join-Path $target 'logs'
        if ([IO.Directory]::Exists($target)) {
            [void][IO.Directory]::CreateDirectory($logs)
            $report.LogFile = Join-Path $logs 'update.log'
            Write-UpdateLog $report ('开始更新 v'+$version)
        }
    }
    . (Join-Path $package 'network.ps1')
    foreach ($name in $files) {
        $file = Join-Path $package $name
        if (-not [IO.File]::Exists($file)) { throw ('缺少文件 '+$name) }
        if ($name.EndsWith('.ps1')) { Assert-PowerShellSource ([IO.File]::ReadAllText($file)) $name }
    }
    Initialize-CampusNative
    if ($Preview) {
        $edit = Get-CompanionEdit $auto
        $msg = '更新预检通过。安装目录：'+$target
        if ($edit.Warning) { Save-UpdateResult 'WARN' ($msg+[Environment]::NewLine+$edit.Warning) }
        else { Save-UpdateResult 'OK' $msg }
        return
    }
    Set-UpdateStage $report '读取已安装的 Windows 计划任务'
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '更新现有计划任务需要 Windows 管理员权限。' }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Invoke-CampusUpdate $task $package $target $auto $files $version $report
    $msg = '校园网自动登录 v'+$version+' 已启动，右下角托盘已就绪。'
    $state = 'OK'
    if ($report.Warning) { $state='WARN'; $msg += [Environment]::NewLine+$report.Warning }
    Write-UpdateLog $report $msg
    Save-UpdateResult $state $msg
} catch {
    $reason = $_.Exception.Message
    $msg = '更新未完成。失败步骤：'+$report.Stage+[Environment]::NewLine+$reason
    if ($report.Rollback) { $msg += [Environment]::NewLine+$report.Rollback }
    if ($report.LogFile) { $msg += [Environment]::NewLine+'日志：'+$report.LogFile }
    Write-UpdateLog $report ('更新结束。'+$report.Stage+'：'+$reason+' ['+$_.FullyQualifiedErrorId+']')
    if ($WriteResult) { Save-UpdateResult 'ERROR' $msg; exit 1 }
    throw $msg
}
