param([string]$ShellPath = (Get-Process -Id $PID).Path)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($scriptFile in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ('PowerShell syntax error: ' + $scriptFile.Name + ': ' + ($errors | Out-String)) }
}
$originalModules = $env:PSModulePath
$shellExecutable = (Get-Command -Name $ShellPath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$shellModules = Join-Path (Split-Path -Parent $shellExecutable) 'Modules'
try {
    # WinPS started from pwsh can otherwise resolve its built-in Security module to the Core edition.
    $env:PSModulePath = $shellModules + [IO.Path]::PathSeparator + $originalModules
    foreach ($test in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*-regression.ps1' -File | Sort-Object Name) {
        Write-Output ('Running ' + $test.Name)
        & $shellExecutable -NoProfile -ExecutionPolicy Bypass -File $test.FullName
        if ($LASTEXITCODE -ne 0) { throw ('Regression failed: ' + $test.Name) }
    }
} finally {
    $env:PSModulePath = $originalModules
}
Write-Output 'PASS: All syntax and regression checks passed.'
