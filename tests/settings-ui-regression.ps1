param([string]$Package = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    & (Get-Process -Id $PID).Path -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Package $Package
    if ($LASTEXITCODE) { throw 'The native settings UI tests failed in STA.' }
    return
}
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $tempRoot ('CampusSettingsUI-'+[guid]::NewGuid().ToString('N'))
$window = $null
function Assert-Settings([bool]$Passed,[string]$Reason) { if (-not $Passed) { throw $Reason } }
function Click-SettingsButton($Button) {
    Assert-Settings $Button.IsEnabled ('Unexpected disabled button: '+$Button.Name)
    $event = [Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent,$Button)
    $Button.RaiseEvent($event)
}
try {
    . (Join-Path $Package 'tools\settings.ps1') -Root $scratch
    $window = New-CampusSettingsWindow -DataRoot $scratch -OpenAdd
    $ui = $window.Tag.Controls
    Assert-Settings (-not $window.IsVisible -and $ui.Editor.Visibility -eq 'Visible') 'Direct Add mode did not open the account editor.'
    Assert-Settings ($ui.Secret -is [Windows.Controls.PasswordBox]) 'The password field must be masked and expose SecurePassword.'
    Assert-Settings ($ui.BeforeInstall.Visibility -eq 'Visible') 'The portable settings entry does not explain preinstall use.'
    Assert-Settings (-not $ui.Proxy.IsChecked -and -not (Get-CampusPreferences -Root $scratch).ProxyEnabled) 'A fresh profile must have proxy integration disabled.'
    foreach ($dpi in 96,120,144,192) {
        # WPF uses device-independent pixels. Exercise the physical budget of a small display at each scale.
        $area = [Windows.Size]::new(760*96.0/$dpi,560*96.0/$dpi)
        $grid = $window.Content
        $grid.Measure($area)
        $grid.Arrange([Windows.Rect]::new(0,0,$area.Width,$area.Height))
        $grid.UpdateLayout()
        $width = $ui.AccountScroll.ViewportWidth
        Assert-Settings ($width -gt 100 -and $ui.Secret.ActualWidth -ge 100 -and $ui.Secret.ActualWidth -le $width+1) "Password input is clipped at $dpi DPI."
        Assert-Settings ($ui.SaveAccount.ActualHeight -ge 30 -and $ui.SaveAccount.ActualWidth -gt 50) "Account actions are unusable at $dpi DPI."
        Assert-Settings ($ui.AccountScroll.ComputedHorizontalScrollBarVisibility -ne 'Visible') "Horizontal clipping at $dpi DPI."
        if ($dpi -eq 192) {
            Assert-Settings ($ui.AccountScroll.ExtentHeight -gt $ui.AccountScroll.ViewportHeight) 'The editor cannot scroll on a small 200% display.'
        }
    }
    $first = '000001'; $second = '000002'
    $ui.AccountId.Text = 'abc'
    Click-SettingsButton $ui.SaveAccount
    Assert-Settings ($ui.Notice.Text -like '*6 到 16*' -and -not (Get-CampusPreferences -Root $scratch).Accounts.Count) 'An invalid ID changed persisted accounts.'
    $ui.AccountId.Text = $first
    Click-SettingsButton $ui.SaveAccount
    Assert-Settings ($ui.Notice.Text -like '*密码*' -and -not (Get-CampusPreferences -Root $scratch).Accounts.Count) 'An empty password was accepted.'
    $ui.Secret.Password = [guid]::NewGuid().ToString('N').Substring(0,12)
    Click-SettingsButton $ui.SaveAccount
    $prefs = Get-CampusPreferences -Root $scratch
    Assert-Settings ($prefs.DefaultAccount -ceq $first -and $prefs.Accounts.Count -eq 1) 'First saved account was not the default.'
    Click-SettingsButton $ui.NewAccount
    $ui.AccountId.Text = $second
    $ui.Secret.Password = [guid]::NewGuid().ToString('N')
    Click-SettingsButton $ui.SaveAccount
    $prefs = Get-CampusPreferences -Root $scratch
    Assert-Settings ($prefs.DefaultAccount -ceq $first -and $prefs.Accounts.Count -eq 2) 'Adding another account lost the previous default.'
    $ui.AccountsList.SelectedItem = $first
    Click-SettingsButton $ui.EditAccount
    $empty = $ui.Secret.SecurePassword
    try { Assert-Settings ($ui.AccountId.IsReadOnly -and $empty.Length -eq 0) 'Editing exposed an existing password or allowed the ID to change.' }
    finally { $empty.Dispose() }
    $ui.Secret.Password = [guid]::NewGuid().ToString('N').Substring(0,17)
    Click-SettingsButton $ui.SaveAccount
    $saved = Get-CampusCredential -Root $scratch -Account $first
    try { Assert-Settings ($saved.Password.Length -eq 17 -and (Get-CampusPreferences -Root $scratch).Accounts.Count -eq 2) 'Same-ID password replacement failed.' }
    finally { if ($saved) { $saved.Password.Dispose() } }
    $ui.AccountsList.SelectedItem = $second
    Click-SettingsButton $ui.MakeDefault
    Assert-Settings ((Get-CampusPreferences -Root $scratch).DefaultAccount -ceq $second) 'The user-selected default was not persisted.'
    Click-SettingsButton $ui.UseClient
    Assert-Settings ((Get-CampusPreferences -Root $scratch).DefaultAccount -ceq '') 'Restoring the Tianyi remembered account failed.'
    $ui.AccountsList.SelectedItem = $first
    Click-SettingsButton $ui.DeleteAccount
    Click-SettingsButton $ui.KeepAccount
    Assert-Settings ((Get-CampusPreferences -Root $scratch).Accounts.Count -eq 2) 'Canceling deletion removed an account.'
    Click-SettingsButton $ui.DeleteAccount
    Click-SettingsButton $ui.ConfirmRemove
    Assert-Settings ((Get-CampusPreferences -Root $scratch).Accounts -cnotcontains $first) 'Confirmed deletion did not remove the account.'
    $ui.Sections.SelectedIndex = 1
    $ui.Proxy.IsChecked = $true
    Assert-Settings (-not (Get-CampusPreferences -Root $scratch).ProxyEnabled) 'Checking the proxy option took effect before saving.'
    Click-SettingsButton $ui.SaveProxy
    Assert-Settings ((Get-CampusPreferences -Root $scratch).ProxyEnabled) 'Proxy opt-in did not persist.'
    $window.Close()
    $window = New-CampusSettingsWindow -DataRoot $scratch
    $ui = $window.Tag.Controls
    Assert-Settings ($ui.Proxy.IsChecked -and $ui.AccountsList.Items.Count -eq 1 -and $ui.Editor.Visibility -eq 'Collapsed') 'A new settings window did not load stored choices.'
    $ui.Proxy.IsChecked = $false
    Click-SettingsButton $ui.SaveProxy
    Assert-Settings (-not (Get-CampusPreferences -Root $scratch).ProxyEnabled) 'Proxy opt-out did not persist.'
    $window.Close()
    $legacy = Join-Path $scratch 'older-profile'
    [void][IO.Directory]::CreateDirectory($legacy)
    [IO.File]::WriteAllText((Join-Path $legacy 'default-account.txt'),'000003')
    $window = New-CampusSettingsWindow -DataRoot $legacy -OpenAdd
    $ui = $window.Tag.Controls
    Assert-Settings ($ui.DefaultChoice.IsEnabled -and -not $ui.DefaultChoice.IsChecked) 'Adding the first credential would override the existing legacy default.'
    $ui.AccountId.Text = $first
    $ui.Secret.Password = [guid]::NewGuid().ToString('N')
    Click-SettingsButton $ui.SaveAccount
    Assert-Settings ((Get-CampusPreferences -Root $legacy).DefaultAccount -ceq '000003') 'Saving the first managed account replaced an older default.'
    Click-SettingsButton $ui.NewAccount
    $ui.AccountId.Text = $first
    $ui.Secret.Password = [guid]::NewGuid().ToString('N').Substring(0,19)
    $ui.DefaultChoice.IsChecked = $true
    Click-SettingsButton $ui.SaveAccount
    $prefs = Get-CampusPreferences -Root $legacy
    Assert-Settings ($prefs.Accounts.Count -eq 1 -and $prefs.DefaultAccount -ceq $first) 'Re-adding an existing account created a duplicate or missed the explicit default choice.'
    Write-Output 'PASS: native settings controls, 100–200% layout, account CRUD and explicit proxy opt-in in an isolated profile.'
} finally {
    if ($window) { $window.Close() }
    if ([IO.Directory]::Exists($scratch) -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($scratch)) -eq $tempRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($scratch) -match '^CampusSettingsUI-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
