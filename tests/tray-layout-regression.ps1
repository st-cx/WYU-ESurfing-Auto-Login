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
} finally { $scope.Dispose() }
