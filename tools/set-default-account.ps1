[CmdletBinding(DefaultParameterSetName='Set')]
param(
    [Parameter(ParameterSetName='Set')][string]$Account,
    [Parameter(Mandatory,ParameterSetName='Clear')][switch]$Clear
)
$ErrorActionPreference = 'Stop'
$install = Join-Path $env:LOCALAPPDATA 'CampusNetWatchdog'
if (-not [IO.File]::Exists((Join-Path $install 'watchdog.ps1'))) {
    throw '请先通过完整安装包安装校园网工具。'
}
$policy = Join-Path $install 'default-account.txt'
if (-not $Clear -and -not $PSBoundParameters.ContainsKey('Account')) {
    Write-Host '输入自己的校园网账号后，每次登录 Windows 将有十秒钟可以选择备用账号。'
    $Account = Read-Host '默认账号（6 到 16 位数字），输入 0 恢复使用天翼记住的账号，直接回车保留原设置'
    if ([string]::IsNullOrWhiteSpace($Account)) { return }
    if ($Account.Trim() -eq '0') { $Clear = $true }
}
if ($Clear) {
    [IO.File]::Delete($policy)
    Write-Output '已取消指定默认账号。下次启动校园网工具时将沿用天翼客户端记住的账号。'
    return
}
$idText = $Account.Trim()
if ($idText -cnotmatch '^[0-9]{6,16}\z') { throw '校园账号应为 6 到 16 位数字。' }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'verge.ps1')
Write-CampusFile $policy $idText
Write-Output '默认校园账号已保存在本机，下次启动校园网工具时生效。'
