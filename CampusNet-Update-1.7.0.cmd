@echo off
setlocal DisableDelayedExpansion
set "CNW_SHA="
set "CNW_EXPECTED=%CNW_SHA%"
set "CNW_CHECK=0"
if not "%~2"=="" goto usage
if /i "%~1"=="--check" set "CNW_CHECK=1"
if not "%~1"=="" if "%CNW_CHECK%"=="0" goto usage
set "CNW_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "CNW_EXE=%~dp0CampusNet-Update-1.7.0.exe"
set "CNW_CACHE=%LOCALAPPDATA%\CampusNetUpdateCache\v1.7.0\CampusNet-Update-1.7.0.exe"
if exist "%CNW_EXE%" goto launch
if defined CNW_SHA if exist "%CNW_CACHE%" goto cache
set "CNW_SRC=%~dp0"
if exist "%CNW_SRC%tools\build-update.ps1" goto build
set "CNW_SRC=%~dp0WYU-ESurfing-Auto-Login-v1.7.0\"
if exist "%CNW_SRC%tools\build-update.ps1" goto build
set "CNW_SRC=%~dp0CampusNet-Repair\"
if not exist "%CNW_SRC%tools\build-update.ps1" goto nosource
"%CNW_PS%" -NoLogo -NoProfile -NonInteractive -Command "$file=Join-Path $env:CNW_SRC 'tools\UpdateLauncher.cs'; if([IO.File]::Exists($file) -and [IO.File]::ReadAllText($file).Contains('AssemblyFileVersion('+[char]34+'1.7.0.0'+[char]34+')')){exit 0}; exit 1"
if not errorlevel 1 goto build
:nosource
if defined CNW_SHA goto cache
goto missing

:build
if defined CNW_SHA set "CNW_EXE=%CNW_SRC%CampusNet-Update-1.7.0.local.exe"
"%CNW_PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; & (Join-Path $env:CNW_SRC 'tools\build-update.ps1') -OutputPath $env:CNW_EXE"
if errorlevel 1 goto result
set "CNW_EXPECTED="
goto launch

:cache
set "CNW_EXE=%CNW_CACHE%"
"%CNW_PS%" -NoLogo -NoProfile -NonInteractive -Command ^
  "$ErrorActionPreference='Stop'; Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1');" ^
  "$file=$env:CNW_CACHE; if([IO.File]::Exists($file) -and (Get-FileHash -LiteralPath $file).Hash -ieq $env:CNW_SHA){exit 0};" ^
  "$dir=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); $tmp=Join-Path $dir.FullName ([guid]::NewGuid().ToString('N')+'.tmp');" ^
  "try{ Write-Host 'Downloading v1.7.0 from the official GitHub release...'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;" ^
  "Invoke-WebRequest -UseBasicParsing -TimeoutSec 35 -Uri 'https://github.com/st-cx/WYU-ESurfing-Auto-Login/releases/download/v1.7.0/CampusNet-Update-1.7.0.exe' -OutFile $tmp;" ^
  "if((Get-FileHash -LiteralPath $tmp).Hash -ine $env:CNW_SHA){throw 'Downloaded EXE checksum mismatch.'};" ^
  "try{if([IO.File]::Exists($file)){[IO.File]::Replace($tmp,$file,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$file)}}" ^
  "catch [IO.IOException]{if(-not [IO.File]::Exists($file) -or (Get-FileHash -LiteralPath $file).Hash -ine $env:CNW_SHA){throw}}} finally{[IO.File]::Delete($tmp)}"
if errorlevel 1 goto result

:launch
"%CNW_PS%" -NoLogo -NoProfile -NonInteractive -Command ^
  "$ErrorActionPreference='Stop'; Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1');" ^
  "$file=$env:CNW_EXE; $lock=[IO.File]::Open($file,'Open','Read','Read');" ^
  "try{if($env:CNW_EXPECTED -and (Get-FileHash -InputStream $lock).Hash -ine $env:CNW_EXPECTED){throw 'EXE checksum mismatch. Download the original v1.7.0 EXE again.'};" ^
  "if([Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion -ne '1.7.0.0'){throw 'A matching v1.7.0 EXE is required.'};" ^
  "$start=[Diagnostics.ProcessStartInfo]::new($file); $start.UseShellExecute=$false; if($env:CNW_CHECK -eq '1'){$start.Arguments='--check'};" ^
  "$process=[Diagnostics.Process]::Start($start); try{$process.WaitForExit(); $code=$process.ExitCode}finally{$process.Dispose()}} finally{$lock.Dispose()}; exit $code"
:result
set "CNW_RESULT=%errorlevel%"
if "%CNW_RESULT%"=="0" if "%CNW_CHECK%"=="1" echo CampusNet v1.7.0 update package check passed.
if "%CNW_RESULT%"=="0" exit /b 0
echo CampusNet update returned exit code %CNW_RESULT%. For offline use, place the official EXE beside this CMD.
if "%CNW_CHECK%"=="0" pause
exit /b %CNW_RESULT%
:missing
echo Extract the complete source, place the v1.7.0 EXE beside this template, or download the CMD from Releases.
if "%CNW_CHECK%"=="0" pause
exit /b 2
:usage
echo Usage: CampusNet-Update-1.7.0.cmd [--check]
exit /b 64
