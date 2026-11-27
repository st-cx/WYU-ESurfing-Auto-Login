param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MarkerRoot = '',
    [switch]$Hold
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'network.ps1')
if ($Hold) {
    $script:CampusAuthMutexName = 'Local\'+[IO.Path]::GetFileName($MarkerRoot)
    $lock = Get-AuthenticationLock
    if (-not $lock) { exit 2 }
    try {
        [IO.File]::WriteAllText((Join-Path $MarkerRoot 'ready'), 'ready')
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath (Join-Path $MarkerRoot 'release')) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    } finally { Release-AuthenticationLock $lock }
    exit 0
}
$marker = Join-Path ([IO.Path]::GetTempPath()) ('campus-lock-test-' + [guid]::NewGuid().ToString('N'))
$script:CampusAuthMutexName = 'Local\'+[IO.Path]::GetFileName($marker)
New-Item -Path $marker -ItemType Directory | Out-Null
$child = $null; $lock = $null
try {
    $child = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-RepoRoot', ('"' + $RepoRoot + '"'), '-MarkerRoot', ('"' + $marker + '"'), '-Hold')
    $deadline = (Get-Date).AddSeconds(8)
    while (-not (Test-Path -LiteralPath (Join-Path $marker 'ready'))) {
        if ((Get-Date) -gt $deadline -or $child.HasExited) { throw 'The independent process did not acquire its lock.' }
        Start-Sleep -Milliseconds 100
    }
    $lock = Get-AuthenticationLock
    if ($lock) { throw 'Two authentication processes can operate at the same time.' }
    [IO.File]::WriteAllText((Join-Path $marker 'release'), 'release')
    if (-not $child.WaitForExit(5000) -or $child.ExitCode -ne 0) { throw 'The independent process did not release its lock.' }
    $lock = Get-AuthenticationLock
    if (-not $lock) { throw 'The authentication lock remains blocked after release.' }
    Write-Output 'PASS: Independent authentication processes are serialized and the lock is released.'
} finally {
    Release-AuthenticationLock $lock
    [IO.File]::WriteAllText((Join-Path $marker 'release'), 'release')
    if ($child -and -not $child.HasExited) { [void]$child.WaitForExit(5000) }
    Get-ChildItem -LiteralPath $marker -File | Remove-Item -Force
    Remove-Item -LiteralPath $marker -Force
}
