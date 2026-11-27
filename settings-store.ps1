# Per-user campus settings. Windows PowerShell 5.1 and PowerShell 7 on Windows.
# Dot-sourcing this file only defines functions. No UI/compiler or network module is required.
function Test-CampusAccountId($Value) {
    return ($Value -is [string] -and $Value -cmatch '^[0-9]{6,16}\z')
}

function Assert-CampusAccountId($Value) {
    if (-not (Test-CampusAccountId $Value)) { throw '校园账号应为 6 到 16 位数字。' }
}

function Get-CampusSecurityCommand([string]$Name) {
    # Windows PowerShell started by pwsh can inherit a PSModulePath containing incompatible Core modules.
    $manifest = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
    $module = Import-Module -Name $manifest -Scope Local -PassThru -ErrorAction Stop
    return $module.ExportedCommands[$Name]
}

function Test-CampusPasswordBlob([string]$Blob) {
    # Windows ConvertFrom-SecureString and Export-Clixml use the DPAPI provider's hex blob.
    return ($Blob.Length -ge 128 -and $Blob.Length % 2 -eq 0 -and
        $Blob.StartsWith('01000000d08c9ddf0115d1118c7a00c04fc297eb',[StringComparison]::OrdinalIgnoreCase) -and
        $Blob -cmatch '^[0-9A-Fa-f]+\z')
}

function Read-CampusOptionalBytes([string]$Path) {
    try { return ,([IO.File]::ReadAllBytes($Path)) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch { throw ('无法读取 '+[IO.Path]::GetFileName($Path)+'，请检查当前 Windows 用户的文件权限。') }
}

function ConvertFrom-CampusTextBytes([byte[]]$Bytes) {
    $stream = [IO.MemoryStream]::new($Bytes,$false)
    $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-CampusJsonFields([Xml.XmlElement]$Node,[string[]]$Names) {
    if ($Node.GetAttribute('type') -cne 'object' -or $Node.ChildNodes.Count -ne $Names.Count) { throw 'Invalid JSON object.' }
    $fields = @{}
    foreach ($child in $Node.ChildNodes) {
        if ($Names -cnotcontains $child.LocalName -or $fields.ContainsKey($child.LocalName)) { throw 'Unknown or duplicate field.' }
        $fields.Add($child.LocalName,$child)
    }
    return $fields
}

function Read-CampusJsonSettings([byte[]]$Bytes,$State) {
    if (-not ('System.Runtime.Serialization.Json.JsonReaderWriterFactory' -as [type])) {
        Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction Stop
    }
    try {
        # This built-in reader preserves repeated JSON members, including on Windows PowerShell 5.1.
        $text = ConvertFrom-CampusTextBytes $Bytes
        $reader = [Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader(
            [Text.Encoding]::UTF8.GetBytes($text),[Xml.XmlDictionaryReaderQuotas]::Max)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        try { $document.Load($reader) } finally { $reader.Dispose() }
        $fields = Read-CampusJsonFields $document.DocumentElement @('version','defaultAccount','proxyEnabled','accounts')
        if ($fields.version.GetAttribute('type') -cne 'number' -or $fields.version.InnerText -cne '1') { throw 'Unsupported settings version.' }
        if ($fields.defaultAccount.GetAttribute('type') -cne 'string' -or
            ($fields.defaultAccount.InnerText -ne '' -and -not (Test-CampusAccountId $fields.defaultAccount.InnerText))) { throw 'Invalid default account.' }
        if ($fields.proxyEnabled.GetAttribute('type') -cne 'boolean' -or @('true','false') -cnotcontains $fields.proxyEnabled.InnerText) { throw 'Invalid proxy preference.' }
        if ($fields.accounts.GetAttribute('type') -cne 'array') { throw 'Invalid accounts array.' }
        foreach ($item in $fields.accounts.ChildNodes) {
            $entry = Read-CampusJsonFields $item @('account','passwordDpapi')
            $account = $entry.account.InnerText
            $blob = $entry.passwordDpapi.InnerText
            if ($entry.account.GetAttribute('type') -cne 'string' -or -not (Test-CampusAccountId $account) -or
                $State.Credentials.Contains($account) -or $entry.passwordDpapi.GetAttribute('type') -cne 'string' -or
                -not (Test-CampusPasswordBlob $blob)) { throw 'Invalid or repeated saved account.' }
            $State.Credentials.Add($account,$blob)
        }
        $State.DefaultAccount = [string]$fields.defaultAccount.InnerText
        $State.ProxyEnabled = $fields.proxyEnabled.InnerText -ceq 'true'
    } catch { throw 'campus-settings.json 格式不受支持或已损坏。请恢复有效的设置文件，原文件已保留。' }
}

function Read-CampusLegacyCredential([byte[]]$Bytes,$State) {
    try {
        $stream = [IO.MemoryStream]::new($Bytes,$false)
        $options = [Xml.XmlReaderSettings]::new()
        $options.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $options.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($stream,$options)
        $doc = [Xml.XmlDocument]::new()
        $doc.XmlResolver=$null
        try { $doc.Load($reader) } finally { $reader.Dispose(); $stream.Dispose() }
        $ns = [Xml.XmlNamespaceManager]::new($doc.NameTable)
        $ns.AddNamespace('p','http://schemas.microsoft.com/powershell/2004/04')
        $entries = $doc.SelectNodes('/p:Objs/p:Obj',$ns)
        if ($entries.Count -ne 1 -or $doc.DocumentElement.ChildNodes.Count -ne 1) { throw 'Invalid credential object.' }
        $entry = $entries[0]
        $sections = @{}
        foreach ($child in $entry.ChildNodes) {
            if (@('TN','Props','ToString') -cnotcontains $child.LocalName -or $sections.ContainsKey($child.LocalName)) { throw 'Unknown credential field.' }
            $sections.Add($child.LocalName,$true)
        }
        $type = $entry.SelectSingleNode('p:TN/p:T[1]',$ns)
        $user = $entry.SelectNodes('p:Props/p:S[@N="UserName"]',$ns)
        $password = $entry.SelectNodes('p:Props/p:SS[@N="Password"]',$ns)
        if (-not $type -or $type.InnerText -cne 'System.Management.Automation.PSCredential' -or $entry.SelectNodes('p:Props/*',$ns).Count -ne 2 -or $user.Count -ne 1 -or $password.Count -ne 1 -or
            -not (Test-CampusAccountId $user[0].InnerText) -or -not (Test-CampusPasswordBlob $password[0].InnerText)) { throw 'Invalid saved credential.' }
        # Migrate the protected bytes directly. Only Get-CampusCredential decrypts a selected account.
        $State.Credentials.Add($user[0].InnerText,$password[0].InnerText)
    } catch { throw '旧备用账号 alternate-credential.xml 格式不受支持或已损坏。请恢复有效的凭据文件，原文件已保留。' }
}

function Read-CampusSettingsState([string]$Root) {
    $state = [pscustomobject]@{
        DefaultAccount=''
        ProxyEnabled=$false
        Credentials=[Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        LegacyBytes=@{}
    }
    $bytes = Read-CampusOptionalBytes (Join-Path $Root 'campus-settings.json')
    if ($null -ne $bytes) { Read-CampusJsonSettings $bytes $state; return $state }
    $default = Read-CampusOptionalBytes (Join-Path $Root 'default-account.txt')
    if ($null -ne $default) {
        try {
            $id = (ConvertFrom-CampusTextBytes $default).Trim()
            Assert-CampusAccountId $id
        } catch { throw '旧默认账号 default-account.txt 格式不正确。请修复该文件，原文件已保留。' }
        $state.DefaultAccount = $id
        $state.LegacyBytes['default-account.txt'] = $default
    }
    $alternate = Read-CampusOptionalBytes (Join-Path $Root 'alternate-credential.xml')
    if ($null -ne $alternate) {
        Read-CampusLegacyCredential $alternate $state
        $state.LegacyBytes['alternate-credential.xml'] = $alternate
    }
    return $state
}

function Write-CampusSettingsState([string]$Root,$State) {
    $entries = @(foreach ($id in $State.Credentials.Keys) { [ordered]@{account=$id;passwordDpapi=$State.Credentials[$id]} })
    $body = [ordered]@{version=1;defaultAccount=$State.DefaultAccount;proxyEnabled=$State.ProxyEnabled;accounts=$entries} | ConvertTo-Json -Depth 4
    [void][IO.Directory]::CreateDirectory($Root)
    $file = Join-Path $Root 'campus-settings.json'
    $temp = $file+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,$body,[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($file)) { [IO.File]::Replace($temp,$file,[Management.Automation.Language.NullString]::Value,$true) }
        else { [IO.File]::Move($temp,$file) }
    } finally { [IO.File]::Delete($temp) }
    # Only retire snapshots that have been committed. Never remove a concurrently edited legacy file.
    foreach ($name in $State.LegacyBytes.Keys) {
        try {
            $old = Join-Path $Root $name
            $current = Read-CampusOptionalBytes $old
            if ($null -eq $current) { continue }
            if ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($current,$State.LegacyBytes[$name])) {
                [IO.File]::Delete($old)
            } else { Write-Warning ('旧文件 '+$name+' 在迁移期间发生变化，已保留。新版使用 campus-settings.json。') }
        } catch { Write-Warning ('设置已保存，旧文件 '+$name+' 暂未清理。新版使用 campus-settings.json。') }
    }
}

function Invoke-CampusSettingsAction([string]$Root,[scriptblock]$Action,[switch]$Write) {
    $ErrorActionPreference = 'Stop'
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $key = $user.User.Value+'|'+[IO.Path]::GetFullPath($path).TrimEnd('\','/').ToUpperInvariant() } finally { $user.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','') } finally { $sha.Dispose() }
    $mutex = [Threading.Mutex]::new($false,('Global\CampusNetSettings-'+$hash))
    $held = $false
    try {
        try { $held = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw '校园网设置正在被其他窗口保存，请稍后重试。' }
        $state = Read-CampusSettingsState $path
        & $Action $state
        if ($Write) { Write-CampusSettingsState $path $state }
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-CampusPreferences {
    param([Parameter(Mandatory)][string]$Root)
    Invoke-CampusSettingsAction $Root {
        param($state)
        [pscustomobject]@{DefaultAccount=$state.DefaultAccount;ProxyEnabled=$state.ProxyEnabled;Accounts=[string[]]@($state.Credentials.Keys)}
    }
}

function Get-CampusCredential {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Account)
    Assert-CampusAccountId $Account
    Invoke-CampusSettingsAction $Root {
        param($state)
        if ($state.Credentials.Contains($Account)) {
            $unprotect = Get-CampusSecurityCommand 'ConvertTo-SecureString'
            try { $secure = & $unprotect -String $state.Credentials[$Account] -ErrorAction Stop }
            catch { throw '当前 Windows 用户无法解密此校园账号的已存密码。请在账号管理中重新保存密码。' }
            [pscredential]::new($Account,$secure)
        }
    }
}

function Save-CampusAccount {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][Security.SecureString]$Password,[switch]$MakeDefault)
    Assert-CampusAccountId $Account
    if ($Password.Length -eq 0) { throw '请输入校园账号密码。' }
    Invoke-CampusSettingsAction $Root -Write -Action {
        param($state)
        $protect = Get-CampusSecurityCommand 'ConvertFrom-SecureString'
        $blob = & $protect -SecureString $Password -ErrorAction Stop
        if (-not (Test-CampusPasswordBlob $blob)) { throw 'Windows 未能使用当前用户的 DPAPI 加密密码。' }
        if ($MakeDefault -or ($state.Credentials.Count -eq 0 -and $state.DefaultAccount -eq '')) { $state.DefaultAccount=$Account }
        $state.Credentials[$Account]=$blob
    }
}

function Set-CampusDefaultAccount {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][AllowEmptyString()][string]$Account)
    if ($Account -cne '') { Assert-CampusAccountId $Account }
    Invoke-CampusSettingsAction $Root -Write -Action { param($state) $state.DefaultAccount=$Account }
}

function Remove-CampusAccount {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Account)
    Assert-CampusAccountId $Account
    Invoke-CampusSettingsAction $Root -Write -Action {
        param($state)
        $state.Credentials.Remove($Account)
        if ($state.DefaultAccount -ceq $Account) { $state.DefaultAccount='' }
    }
}

function Set-CampusProxyIntegration {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][bool]$Enabled)
    Invoke-CampusSettingsAction $Root -Write -Action { param($state) $state.ProxyEnabled=$Enabled }
}
