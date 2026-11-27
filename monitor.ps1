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
    if ($script:CampusPreferences.ProxyEnabled) { return (Test-VergeHealth $HttpProbeTargets $ProbeTimeoutMs $Config.clash_config_path) }
    return $true
}


function Update-CampusPreferences([switch]$Quiet) {
    try {
        $prefs = Get-CampusPreferences -Root $Root -ErrorAction Stop
        if ($null -eq $prefs -or -not $prefs.PSObject.Properties['DefaultAccount'] -or
            $prefs.ProxyEnabled -isnot [bool] -or ($prefs.DefaultAccount -and $prefs.DefaultAccount -notmatch '^[0-9]{6,16}$')) {
            throw 'Invalid settings.'
        }
        if (-not $script:CampusPreferences -or $script:CampusPreferences.ProxyEnabled -ne $prefs.ProxyEnabled) {
            $script:verifyAfterWake = $true; $script:nextProxyRepair = [datetime]::MinValue
        }
        if ($script:CampusPreferences -and $script:CampusPreferences.DefaultAccount -cne $prefs.DefaultAccount) {
            $script:readMisses = 0; $script:retryClient = $false; $script:accountPending = $false
        }
        $script:CampusPreferences = $prefs
        return $true
    } catch {
        $script:CampusPreferences = $null
        if (-not $Quiet) { Set-CampusStatus 'account' '暂时无法读取校园网设置，请右键托盘打开设置后重试' }
        return $false
    }
}

function Confirm-CampusAccount($Sample) {
    if (-not $script:CampusPreferences) { return $false }
    $id = [string]$script:CampusPreferences.DefaultAccount
    if ($id) {
        try {
            $saved = Get-CampusCredential -Root $Root -Account $id -ErrorAction Stop
            if ($null -ne $saved) {
                if ($saved -is [pscredential] -and $saved.UserName -ceq $id -and
                    [CampusRecovery.LoginScreen]::FillAccount($Sample.Window,$script:LoginGlyph,$id,$saved.GetNetworkCredential().Password)) { return $true }
                Set-CampusStatus 'account' '正在等待天翼显示可填写的账号和密码框'
                return $false
            }
        } catch {
            Set-CampusStatus 'account' '无法读取所选账号的本机凭据，请右键托盘 → 添加账号后重试'
            return $false
        }
    }
    if ([CampusRecovery.LoginScreen]::CheckAccount($Sample.Window,$script:LoginGlyph,$script:LoginX,$script:LoginY,$id,$true)) { return $true }
    Set-CampusStatus 'account' '请右键托盘 → 添加账号，或在天翼中填好账号和密码后重试'
    return $false
}

function Invoke-SingleConnection([scriptblock]$BeforeLogin,[ref]$OffCampus) {
    # Older logon tasks pass a callback that rewrites the official client's account.
    # Keep the parameter for installed callers. The current tray setting owns account selection.
    $lock = Get-AuthenticationLock -TimeoutMs 90000
    if (-not $lock) { return $false }
    try {
        if (-not (Restore-OwnedAdapter)) { return $false }
        if (-not (Restore-AuthNetworkContext $NetworkStatePath) -or -not (Restore-AuthNetworkContext $AutoNetworkStatePath)) { return $false }
        if ($null -ne $OffCampus) {
            $OffCampus.Value = (Get-PhysicalLink) -ne 'Campus'
            if ($OffCampus.Value) { return $false }
        }
        if (-not (Update-CampusPreferences)) { return $false }
        $online = Test-Internet
        if ($online -and (-not $script:CampusPreferences.ProxyEnabled -or (Test-VergeHealth $HttpProbeTargets $ProbeTimeoutMs $Config.clash_config_path))) { return $true }
        if ((Get-PhysicalLink) -ne 'Campus') { return $false }
        if (-not (Invoke-CampusRecovery -RepairProxy:$online)) { return $false }
        if (Test-Path -LiteralPath $NetworkStatePath) { return $false }
        $ok = Test-CompleteConnection
        if ($ok) { Set-CampusStatus 'online' '校园网已联网，外网验证通过' }
        return $ok
    } finally { Release-AuthenticationLock $lock }
}

function Invoke-MonitorPass {
    $lock = Get-AuthenticationLock
    if (-not $lock) { return 3 }
    try {
        if (-not (Restore-OwnedAdapter)) { return 3 }
        if (-not (Restore-AuthNetworkContext $NetworkStatePath) -or -not (Restore-AuthNetworkContext $AutoNetworkStatePath)) { return 10 }
        if (-not (Update-CampusPreferences)) { return 5 }
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
        if ($direct -and $script:CampusPreferences.ProxyEnabled) {
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
            Set-CampusStatus 'online' '校园网已恢复，外网验证通过'
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
