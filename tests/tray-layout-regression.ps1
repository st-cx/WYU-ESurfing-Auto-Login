param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'network.ps1')
Initialize-CampusNative
$assembly = [CampusRecovery.StatusTray].Assembly
$dpiScope = $assembly.GetType('CampusRecovery.LoginScreen+DpiScope', $true)
$scope = [Activator]::CreateInstance($dpiScope, $true)
try {
    $make = [CampusRecovery.StatusTray].GetMethod('MakeStatus',[Reflection.BindingFlags]'Static,NonPublic')
    $message = ('校园网正在等待天翼客户端完成认证。' + [Environment]::NewLine + '连接恢复后将继续检查代理。' + [Environment]::NewLine) * 12
    foreach ($dpi in 96,120,144,192) {
        $area = [Drawing.Rectangle]::new(-1200,0,[int](300*$dpi/96),[int](235*$dpi/96))
        $card = $make.Invoke($null,[object[]]@('loading',[string]$message,$area,$dpi))
        try {
            $viewport = @($card.Controls | Where-Object { $_ -is [Windows.Forms.Panel] })[0]
            $label = $viewport.Controls[0].Controls[0]
            $preferred = $label.GetPreferredSize([Drawing.Size]::new($label.Width,0))
            if ($label.Text -cne $message -or $label.Height -lt $preferred.Height -or $label.Width -lt $preferred.Width) {
                throw "Status text is clipped or incomplete at $dpi DPI."
            }
            if (-not $area.Contains($card.Bounds) -or $viewport.AutoScrollMinSize.Height -le $viewport.Height) {
                throw "Long content cannot fit or scroll within the working area at $dpi DPI."
            }
        } finally { $card.Dispose() }
    }
    Write-Output 'PASS: complete multiline status and accessible overflow at 100%, 125%, 150%, and 200%.'
    $calls = [Collections.Generic.List[bool]]::new()
    $handler = [Action[bool]]{ param($add) $calls.Add($add) }
    $menuFactory = [CampusRecovery.StatusTray].GetMethod('MakeSettingsMenu',[Reflection.BindingFlags]'Static,NonPublic')
    $menu = $menuFactory.Invoke($null,[object[]]@($handler))
    try {
        if ($menu.Items.Count -ne 2 -or $menu.Items[0].Text -cne '添加账号…' -or $menu.Items[1].Text -cne '账号与设置…') { throw 'Tray account commands are missing.' }
        $menu.Items[0].PerformClick()
        $menu.Items[1].PerformClick()
        if ($calls.Count -ne 2 -or -not $calls[0] -or $calls[1]) { throw 'Tray commands selected the wrong settings mode.' }
    } finally { $menu.Dispose() }
    $makeCommand = [CampusRecovery.StatusTray].GetMethod('SettingsStartInfo',[Reflection.BindingFlags]'Static,NonPublic')
    $path = Join-Path ([IO.Path]::GetTempPath()) '校园网 & tray (test)!\status.txt'
    $script = Join-Path (Split-Path -Parent $path) 'tools\settings.ps1'
    foreach ($add in $false,$true) {
        $command = $makeCommand.Invoke($null,[object[]]@([string]$path,[bool]$add))
        $end = '-File "'+$script+'"' + $(if ($add) { ' -AddAccount' } else { '' })
        if ($command.UseShellExecute -or -not $command.CreateNoWindow -or -not $command.Arguments.EndsWith($end,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Tray does not start the intended settings script directly.'
        }
    }
    Write-Output 'PASS: right-click settings commands and fixed-script arguments.'
} finally { $scope.Dispose() }
