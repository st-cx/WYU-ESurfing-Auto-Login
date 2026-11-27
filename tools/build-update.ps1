param([Parameter(Mandatory)][string]$OutputPath,[string]$CommandPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'setup.ps1')
$compiler = @('Framework64','Framework') | ForEach-Object {
    Join-Path $env:WINDIR ('Microsoft.NET\' + $_ + '\v4.0.30319\csc.exe')
} | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
if (-not $compiler) { throw '未找到 Windows 自带的 .NET Framework C# 编译器。' }

$out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$directory = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out))
$id = [guid]::NewGuid().ToString('N')
$staged = Join-Path $directory.FullName ('.CampusNetBuild-' + $id + '.exe')
$stagedCmd = $null
$payload = Join-Path ([IO.Path]::GetTempPath()) ('CampusNetPayload-' + $id + '.zip')
$files = @(Get-CampusProgramFiles) + @('upgrade.ps1','tools/setup.ps1','LICENSE')
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
try {
    $zip = [IO.Compression.ZipFile]::Open($payload,'Create')
    try {
        foreach ($name in $files) {
            $entry = $name.Replace('\','/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $root $name),$entry)
        }
    } finally { $zip.Dispose() }
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ /utf8output /codepage:65001 ('/out:' + $staged) ('/resource:' + $payload + ',CampusNet.Payload') /r:System.Windows.Forms.dll /r:System.IO.Compression.dll (Join-Path $PSScriptRoot 'UpdateLauncher.cs')
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($staged)) { throw '更新程序编译失败。' }
    if ($CommandPath) {
        $templatePath = Join-Path $root 'CampusNet-Update-1.6.3.cmd'
        $cmd = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CommandPath)
        if ($cmd -ieq $templatePath -or $cmd -ieq $out) { throw '请为独立 CMD 指定单独的输出路径。' }
        $cmdDir = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cmd))
        $stagedCmd = Join-Path $cmdDir.FullName ('.CampusNetBuild-' + $id + '.cmd')
        $template = [IO.File]::ReadAllText($templatePath,[Text.Encoding]::ASCII)
        $slot = [regex]'(?m)^set "CNW_SHA=(?:[0-9a-f]{64})?"(?=\r?$)'
        if ($slot.Matches($template).Count -ne 1) { throw '未找到 CMD 模板中唯一的更新校验值。' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $sum = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($staged))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $content = $slot.Replace($template,('set "CNW_SHA=' + $sum + '"')) -replace '\r?\n', "`r`n"
        [IO.File]::WriteAllText($stagedCmd,$content,[Text.Encoding]::ASCII)
    }
    if ([IO.File]::Exists($out)) {
        [IO.File]::Replace($staged,$out,[Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($staged,$out)
    }
    if ($stagedCmd) {
        if ([IO.File]::Exists($cmd)) {
            [IO.File]::Replace($stagedCmd,$cmd,[Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($stagedCmd,$cmd)
        }
    }
} finally {
    if ($stagedCmd) { [IO.File]::Delete($stagedCmd) }
    [IO.File]::Delete($payload)
    [IO.File]::Delete($staged)
}
