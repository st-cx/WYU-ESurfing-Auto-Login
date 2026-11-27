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
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'settings-store.ps1')
if (-not $Clear -and -not $PSBoundParameters.ContainsKey('Account')) {
    Write-Host '输入校园账号后，天翼客户端下次需要认证时会使用所选账号。'
    $Account = Read-Host '默认账号（6 到 16 位数字），输入 0 恢复使用天翼记住的账号，直接回车保留原设置'
    if ([string]::IsNullOrWhiteSpace($Account)) { return }
    if ($Account.Trim() -eq '0') { $Clear = $true }
}
if ($Clear) {
    Set-CampusDefaultAccount -Root $install -Account ''
    Write-Output '已取消指定默认账号。下次需要认证时将沿用天翼客户端记住的账号。'
    return
}
Set-CampusDefaultAccount -Root $install -Account $Account.Trim()
Write-Output '默认校园账号已保存在本机，下次需要认证时生效。'
