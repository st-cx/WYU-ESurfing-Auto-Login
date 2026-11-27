param([string]$Package=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$helper = Join-Path $Package 'tools\set-default-account.ps1'
$original = $env:LOCALAPPDATA
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('CampusAccountTest-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $scratch 'CampusNetWatchdog'
$watchdog = Join-Path $install 'watchdog.ps1'
$policy = Join-Path $install 'default-account.txt'
try {
    $env:LOCALAPPDATA = $scratch
    [void][IO.Directory]::CreateDirectory($install)
    [IO.File]::WriteAllText($watchdog,'# test installation')
    $sample = '00123456'
    $message = & $helper -Account $sample
    if ([IO.File]::ReadAllText($policy) -cne $sample -or "$message".Contains($sample)) {
        throw 'A saved account must retain its leading zeros and stay out of console output.'
    }
    foreach ($invalid in @('12345','12abc345','12345678901234567')) {
        $rejected = $false
        try { & $helper -Account $invalid | Out-Null } catch { $rejected = $true }
        if (-not $rejected -or [IO.File]::ReadAllText($policy) -cne $sample) { throw 'An invalid account replaced the original policy.' }
    }
    & $helper -Clear | Out-Null
    & $helper -Clear | Out-Null
    if ([IO.File]::Exists($policy) -or @(Get-ChildItem -LiteralPath $install -Force).Count -ne 1) {
        throw 'Clearing the policy should leave only the starting installation.'
    }
    Write-Output 'PASS: local default account, leading zeros, invalid input, clearing and original client mode.'
} finally {
    $env:LOCALAPPDATA = $original
    [IO.File]::Delete($policy)
    [IO.File]::Delete($watchdog)
    if ([IO.Directory]::Exists($install)) { [IO.Directory]::Delete($install) }
    if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch) }
}
