# Functions run inside the watchdog process, or inside the existing logon task for a single connection.
function Get-PhysicalLink([object[]]$Interfaces = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    $nic = $Interfaces |
        Where-Object Name -eq $AdapterName | Select-Object -First 1
    if (-not $nic -or $nic.OperationalStatus -ne 'Up') { return 'Waiting' }
    $props = $nic.GetIPProperties()
    $addresses = @($props.UnicastAddresses | Where-Object {
        $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address -notmatch '^(0\.|127\.|169\.254\.)' -and
        $_.DuplicateAddressDetectionState -notin @('Tentative','Duplicate','Invalid')
    } | ForEach-Object {$_.Address.ToString()})
    if ($addresses.Count -eq 0) { return 'Waiting' }
    if (-not $CampusGuard) { return 'Campus' }
    foreach ($address in $addresses) {
        foreach ($prefix in $CampusIpPrefixes) { if ($address.StartsWith($prefix)) { return 'Campus' } }
    }
    $gws = @($props.GatewayAddresses | ForEach-Object {$_.Address.ToString()})
    foreach ($gw in $CampusGateways) { if ($gws -contains $gw) { return 'Campus' } }
    if (-not $gws.Count) { return 'Waiting' }
    return 'Away'
}

function Wait-MonitorDelay([int]$Seconds) {
    $end = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $before = [datetime]::UtcNow
        $ms = [int][Math]::Min(2000,[Math]::Max(1,($end-$before).TotalMilliseconds))
        if ([CampusRecovery.StatusTray]::Wait($ms)) { return $true }
        if ([CampusRecovery.StatusTray]::IsSleepGap($before,[datetime]::UtcNow)) { return $true }
    } while ([datetime]::UtcNow -lt $end)
    return $false
}

function Test-CompleteConnection {
    if (-not (Wait-InternetHttp -Targets $HttpProbeTargets -TimeoutMs $ProbeTimeoutMs)) { return $false }
    if ($Config.proxy_guard) { return (Test-VergeHealth $HttpProbeTargets $ProbeTimeoutMs $Config.clash_config_path) }
    return $true
}


function Initialize-CampusAccountChoice {
    if ($script:CampusAccountUser) { return }
    $policy = Join-Path $Root 'default-account.txt'
    if (-not [IO.File]::Exists($policy)) { return }
    $primary = [IO.File]::ReadAllText($policy).Trim()
    if ($primary -notmatch '^[0-9]{6,16}$') { throw '默认账号文件格式不正确。' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $logon = @($identity.Groups | ForEach-Object {$_.Value} | Where-Object {$_ -like 'S-1-5-5-*'}) | Select-Object -First 1
    $boot = $null
    try { $boot = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name BootId -ErrorAction Stop).BootId } catch {}
    if ($null -eq $boot) {
        try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks } catch { $boot = '' }
    }
    $key = ([string]$boot)+'/'+$logon+'/'+[Diagnostics.Process]::GetCurrentProcess().SessionId+'/'+$primary
    $file = Join-Path $Root 'account-session.txt'
    $open = Join-Path $Root 'account-prompt-open.txt'
    $localProfile = Join-Path $Root 'alternate-credential.xml'
    $gate = New-Object Threading.Mutex($false,('Local\CampusNetAccountChoice-'+$identity.User.Value))
    $held = $false
    try {
        try { $held = $gate.WaitOne(16000) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw '账号选择窗口仍在启动，请稍候。' }
        $script:CampusAccountUser = $primary
        if ([IO.File]::Exists($file)) {
            $parts = ([IO.File]::ReadAllText($file).Trim() -split '\|',2)
            if ($parts.Count -eq 2 -and $parts[0] -ceq $key -and $parts[1] -match '^[0-9]{6,16}$') {
                $script:CampusAccountUser=$parts[1]; return
            }
        }
        $accounts = Join-Path $env:USERPROFILE 'CampusNetAuto\accounts.json'
        $others = @()
        if ([IO.File]::Exists($accounts)) {
            try {
                $conf = [IO.File]::ReadAllText($accounts) | ConvertFrom-Json -ErrorAction Stop
                $others = @($conf.accounts | ForEach-Object {[string]$_.user} | Where-Object {$_ -match '^[0-9]{6,16}$' -and $_ -ne $primary} | Select-Object -Unique)
            } catch { Log '备用账号列表暂不可读，将使用指定默认账号。' }
        }
        if ([IO.File]::Exists($localProfile)) {
            try {
                $stored=Import-Clixml -LiteralPath $localProfile -ErrorAction Stop
                if ($stored -is [pscredential] -and $stored.UserName -match '^[0-9]{6,16}$' -and $stored.UserName -ne $primary) {
                    $others=@(@($others)+$stored.UserName | Select-Object -Unique)
                }
            } catch {}
        }
        try {
            Write-CampusFile $open $key
            $choice = [CampusRecovery.StatusTray]::ChooseAccount($primary,[string[]]$others)
            if ($choice -eq '@add') {
                $inputAccount=[CampusRecovery.StatusTray]::EnterAlternate($primary)
                if ($inputAccount) {
                    $credential=[pscredential]::new($inputAccount.User,$inputAccount.Password)
                    Write-CampusFile $localProfile ([Management.Automation.PSSerializer]::Serialize($credential))
                    $choice=$credential.UserName; $others=@(@($others)+$choice)
                } else { $choice=$primary }
            }
            if ($choice -ceq $primary -or $others -contains $choice) { $script:CampusAccountUser=$choice }
            Write-CampusFile $file ($key+'|'+$script:CampusAccountUser)
        } finally { if ([IO.File]::Exists($open)) { [IO.File]::Delete($open) } }
        if ($script:CampusAccountUser -ceq $primary) { Log '本次 Windows 登录使用默认校园网账号。' }
        else { Log '用户已为本次 Windows 登录选择备用校园网账号。' }
    } catch {
        if (-not $held){$script:CampusAccountUser=$null;throw}
        Log ('选择账号时遇到问题，将沿用默认账号：'+$_.Exception.GetType().Name)
    } finally { if ($held) { $gate.ReleaseMutex() }; $gate.Dispose() }
}

function Confirm-CampusAccount($Sample) {
    if (-not $script:CampusAccountUser) { return $true }
    $id = $script:CampusAccountUser
    if ([CampusRecovery.LoginScreen]::CheckAccount($Sample.Window,$script:LoginGlyph,$script:LoginX,$script:LoginY,$id,$true)) { return $true }
    $localProfile = Join-Path $Root 'alternate-credential.xml'
    if ([IO.File]::Exists($localProfile)) {
        try {
            $saved=Import-Clixml -LiteralPath $localProfile -ErrorAction Stop
            if ($saved -is [pscredential] -and $saved.UserName -ceq $id) {
                return [CampusRecovery.LoginScreen]::FillAccount($Sample.Window,$script:LoginGlyph,$id,$saved.GetNetworkCredential().Password)
            }
        } catch { Set-CampusStatus 'account' '正在等待天翼确认备用账号'; return $false }
    }
    $entry = Join-Path $env:USERPROFILE 'CampusNetAuto\campus-auth.ps1'
    if (-not [IO.File]::Exists($entry) -or -not [IO.File]::ReadAllText($entry).Contains('# CampusNet verified account v1.6.2')) {
        Set-CampusStatus 'account' '天翼显示的账号与所选账号不符，等待已保存的账号资料'
        return $false
    }
    $CampusAccountInvocation = [pscustomobject]@{User=$id; Window=$Sample.Window; Glyph=$script:LoginGlyph}
    $result = @(& $entry -ClientMode Auto)
    $reason = [string]($result | Select-Object -Last 1)
    if ($reason -eq 'CampusAccountReady') {
        return [CampusRecovery.LoginScreen]::CheckAccount($Sample.Window,$script:LoginGlyph,$script:LoginX,$script:LoginY,$id,$true)
    }
    if ($reason -eq 'CampusAccountMissing') { Set-CampusStatus 'account' ('天翼尚未记住所选账号 '+$id+' 的密码，请在本机保存一次') }
    else { Set-CampusStatus 'account' ('等待确认天翼登录框显示账号 '+$id) }
    return $false
}

function Invoke-SingleConnection([scriptblock]$BeforeLogin,[ref]$OffCampus) {
    if ($null -eq $OffCampus) { Initialize-CampusAccountChoice }
    $lock = Get-AuthenticationLock -TimeoutMs 90000
    if (-not $lock) { return $false }
    try {
        if (-not (Restore-OwnedAdapter)) { return $false }
        if (-not (Restore-AuthNetworkContext $NetworkStatePath) -or -not (Restore-AuthNetworkContext $AutoNetworkStatePath)) { return $false }
        if ($null -ne $OffCampus) {
            $OffCampus.Value = (Get-PhysicalLink) -ne 'Campus'
            if ($OffCampus.Value) { return $false }
            Initialize-CampusAccountChoice
        }
        $online = Test-Internet
        if ($online -and (-not $Config.proxy_guard -or (Test-VergeHealth $HttpProbeTargets $ProbeTimeoutMs $Config.clash_config_path))) { return $true }
        if ((Get-PhysicalLink) -ne 'Campus') { return $false }
        if (-not (Invoke-CampusRecovery -RepairProxy:$online -BeforeLogin $BeforeLogin)) { return $false }
        if (Test-Path -LiteralPath $NetworkStatePath) { return $false }
        $ok = Test-CompleteConnection
        if ($ok) { Set-CampusStatus 'online' '校园网已联网，代理状态已核验' }
        return $ok
    } finally { Release-AuthenticationLock $lock }
}

function Invoke-MonitorPass {
    Initialize-CampusAccountChoice
    $lock = Get-AuthenticationLock
    if (-not $lock) { return 3 }
    try {
        if (-not (Restore-OwnedAdapter)) { return 3 }
        if (-not (Restore-AuthNetworkContext $NetworkStatePath) -or -not (Restore-AuthNetworkContext $AutoNetworkStatePath)) { return 10 }
        Invoke-CommandFile
        $link = Get-PhysicalLink
        if ($link -eq 'Waiting') {
            $script:fails = 0; $script:readMisses = 0; $script:retryClient = $false
            Set-CampusStatus 'adapter' ('等待 '+$AdapterName+' 就绪并取得 IPv4 地址')
            return 3
        }
        if ($link -eq 'Away') {
            $script:fails = 0; $script:readMisses = 0; $script:retryClient = $false; $script:outageAnnounced = $false
            Set-CampusStatus 'away' '当前处于其他网络，等待接入校园网'
            return $AwayCheckIntervalSec
        }
        $direct = Test-Internet
        $proxyFault = $false
        if ($direct -and $Config.proxy_guard) {
            $exe = Get-SelectedVergeExecutable $Config.clash_config_path
            if ($exe -and ($script:verifyAfterWake -or (Get-VergeGui $exe))) {
                $proxyFault = -not (Test-VergeHealth $HttpProbeTargets $ProbeTimeoutMs $Config.clash_config_path)
            }
        }
        if ($direct -and -not $proxyFault) {
            $script:fails = 0; $script:verifyAfterWake = $false
            $script:readMisses = 0; $script:retryClient = $false
            if ($script:outageAnnounced) { Send-Toast '校园网已恢复上网'; $script:outageAnnounced = $false }
            Set-CampusStatus 'online' '校园网已联网，正在监测'
            return $CheckIntervalSec
        }
        $script:fails++
        if ($script:fails -lt $FailThreshold) {
            if ($proxyFault) { Set-CampusStatus 'check' '校园网可用，正在复查 Clash 代理' }
            else { Set-CampusStatus 'check' '校园网探测失败，正在复查连接' }
            return 3
        }
        if ($proxyFault -and [datetime]::UtcNow -lt $script:nextProxyRepair) { return 10 }
        if ($proxyFault) { $script:nextProxyRepair = [datetime]::UtcNow.AddMinutes(2) }
        if (-not $direct -and -not $script:outageAnnounced) {
            Send-Toast '检测到校园网断网，正在自动登录'
            $script:outageAnnounced = $true
        }
        $script:verifyAfterWake = $true
        $recovered = Invoke-CampusRecovery -RepairProxy:$proxyFault
        if ($recovered -and -not (Test-Path -LiteralPath $NetworkStatePath) -and (Test-CompleteConnection)) {
            $script:fails = 0; $script:verifyAfterWake = $false
            $script:readMisses = 0; $script:retryClient = $false
            if ($script:outageAnnounced) { Send-Toast '校园网已恢复上网'; $script:outageAnnounced = $false }
            Set-CampusStatus 'online' '校园网已恢复，代理状态已核验'
            return $CheckIntervalSec
        }
        if (-not (Test-Path -LiteralPath $NetworkStatePath)) {
            if ($script:accountPending) { return 5 }
            $msg = if ($script:loginTimedOut) { '尚未识别到可点击的登录按钮，稍后重试' }
                   elseif ($proxyFault) { '校园网可用，代理链路待恢复，稍后重试' }
                   else { '校园网认证尚未通过，稍后重试' }
            Set-CampusStatus 'error' $msg
        }
        return $CheckIntervalSec
    } finally { Release-AuthenticationLock $lock }
}
