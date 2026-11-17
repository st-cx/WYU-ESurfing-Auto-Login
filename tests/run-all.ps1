param([string]$ShellPath = (Get-Process -Id $PID).Path)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($scriptFile in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ('PowerShell syntax error: ' + $scriptFile.Name + ': ' + ($errors | Out-String)) }
}
foreach ($test in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*-regression.ps1' -File | Sort-Object Name) {
    Write-Output ('Running ' + $test.Name)
    & $ShellPath -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw ('Regression failed: ' + $test.Name) }
}
Write-Output 'PASS: All syntax and regression checks passed.'
