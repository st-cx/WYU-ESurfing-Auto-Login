param([string]$Package=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$helper = Join-Path $Package 'tools\set-default-account.ps1'
. (Join-Path $Package 'settings-store.ps1')
$original = $env:LOCALAPPDATA
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('CampusAccountTest-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $scratch 'CampusNetWatchdog'
$watchdog = Join-Path $install 'watchdog.ps1'
$policy = Join-Path $install 'campus-settings.json'
try {
    $env:LOCALAPPDATA = $scratch
    [void][IO.Directory]::CreateDirectory($install)
    [IO.File]::WriteAllText($watchdog,'# test installation')
    $sample = '00123456'
    $message = & $helper -Account $sample
    if ((Get-CampusPreferences -Root $install).DefaultAccount -cne $sample -or "$message".Contains($sample) -or
        "$message" -notlike '*下次需要认证*') {
        throw 'A saved account must retain its leading zeros and stay out of console output.'
    }
    foreach ($invalid in @('12345','12abc345','12345678901234567')) {
        $rejected = $false
        try { & $helper -Account $invalid | Out-Null } catch { $rejected = $true }
        if (-not $rejected -or (Get-CampusPreferences -Root $install).DefaultAccount -cne $sample) { throw 'An invalid account replaced the original policy.' }
    }
    & $helper -Clear | Out-Null
    & $helper -Clear | Out-Null
    if ((Get-CampusPreferences -Root $install).DefaultAccount -cne '' -or @(Get-ChildItem -LiteralPath $install -Force).Count -ne 2) {
        throw 'Clearing must persist the client choice in the single settings file.'
    }
    Write-Output 'PASS: local default account, leading zeros, invalid input, clearing and original client mode.'
} finally {
    $env:LOCALAPPDATA = $original
    [IO.File]::Delete($policy)
    [IO.File]::Delete($watchdog)
    if ([IO.Directory]::Exists($install)) { [IO.Directory]::Delete($install) }
    if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch) }
}
