[CmdletBinding()]
param([switch]$AddAccount,[string]$Root = (Join-Path $env:LOCALAPPDATA 'CampusNetWatchdog'))

$store = Join-Path (Split-Path -Parent $PSScriptRoot) 'settings-store.ps1'
. $store

function Update-CampusAccountsView($State,[string]$Select) {
    $prefs = Get-CampusPreferences -Root $State.Root
    $State.Default = [string]$prefs.DefaultAccount
    $State.Accounts = @($prefs.Accounts | Where-Object { $_ })
    $ui = $State.Controls
    $ui.AccountsList.Items.Clear()
    foreach ($id in $State.Accounts) { [void]$ui.AccountsList.Items.Add([string]$id) }
    if (-not $Select) { $Select = $State.Default }
    if ($Select -and $ui.AccountsList.Items.Contains($Select)) { $ui.AccountsList.SelectedItem = $Select }
    elseif ($ui.AccountsList.Items.Count) { $ui.AccountsList.SelectedIndex = 0 }
    $ui.EmptyLabel.Visibility = if ($State.Accounts.Count) { 'Collapsed' } else { 'Visible' }
    $ui.EmptyLabel.Text = if ($State.Default) { '本工具尚未保存账号密码，当前默认账号保持不变。' } else { '尚未保存校园账号。首个添加的账号将用于自动登录。' }
    $ui.AccountsList.Visibility = if ($State.Accounts.Count) { 'Visible' } else { 'Collapsed' }
    foreach ($name in 'EditAccount','MakeDefault','DeleteAccount') { $ui[$name].Visibility = $ui.AccountsList.Visibility }
    $ui.DefaultLabel.Text = if ($State.Default) { '默认登录账号　'+$State.Default } else { '默认登录账号　使用天翼客户端记住的账号' }
    $ui.UseClient.IsEnabled = [bool]$State.Default
    $ui.UseClient.Visibility = if ($State.Default) { 'Visible' } else { 'Collapsed' }
    Update-CampusAccountButtons $State
    return $prefs
}

function Update-CampusAccountButtons($State) {
    $ui = $State.Controls
    $id = [string]$ui.AccountsList.SelectedItem
    $ui.EditAccount.IsEnabled = [bool]$id
    $ui.DeleteAccount.IsEnabled = [bool]$id
    $ui.MakeDefault.IsEnabled = [bool]$id -and $id -cne $State.Default
}

function Close-CampusEditor($State) {
    $ui = $State.Controls
    $ui.Secret.Clear()
    $ui.AccountId.Clear()
    $ui.Editor.Visibility = 'Collapsed'
    $ui.ConfirmDelete.Visibility = 'Collapsed'
    $ui.AccountActions.Visibility = 'Visible'
    $State.Deleting = ''
}

function Open-CampusEditor($State,[bool]$Edit) {
    Close-CampusEditor $State
    $ui = $State.Controls
    $ui.Notice.Text = ''
    $ui.Sections.SelectedIndex = 0
    $ui.EditorTitle.Text = if ($Edit) { '修改已保存的密码' } else { '添加校园账号' }
    $ui.AccountId.IsReadOnly = $Edit
    $ui.AccountId.Text = if ($Edit) { [string]$ui.AccountsList.SelectedItem } else { '' }
    $first = $State.Accounts.Count -eq 0 -and -not $State.Default
    $alreadyDefault = $Edit -and $ui.AccountId.Text -ceq $State.Default
    $ui.DefaultChoice.IsChecked = $first -or $alreadyDefault
    $ui.DefaultChoice.IsEnabled = -not ($first -or $alreadyDefault)
    $ui.Editor.Visibility = 'Visible'
    $ui.AccountActions.Visibility = 'Collapsed'
    $ui.Editor.BringIntoView()
    if ($Edit) { [void]$ui.Secret.Focus() } else { [void]$ui.AccountId.Focus() }
}

function Invoke-CampusWindowAction($State,[string]$Action) {
    $ui = $State.Controls
    try {
        switch ($Action) {
            'NewAccount' { Open-CampusEditor $State $false }
            'EditAccount' { if ($ui.AccountsList.SelectedItem) { Open-CampusEditor $State $true } }
            'CancelEdit' { Close-CampusEditor $State; [void]$ui.NewAccount.Focus() }
            'SaveAccount' {
                $id = $ui.AccountId.Text.Trim()
                if ($id -cnotmatch '^[0-9]{6,16}\z') {
                    $ui.Notice.Text = '请输入 6 到 16 位数字的校园账号。'
                    [void]$ui.AccountId.Focus()
                    return
                }
                $password = $ui.Secret.SecurePassword
                try {
                    if (-not $password.Length) {
                        $ui.Notice.Text = '请输入天翼校园密码。'
                        [void]$ui.Secret.Focus()
                        return
                    }
                    $existing = $State.Accounts -ccontains $id
                    $makeDefault = $ui.DefaultChoice.IsEnabled -and $ui.DefaultChoice.IsChecked
                    [void](Save-CampusAccount -Root $State.Root -Account $id -Password $password -MakeDefault:$makeDefault)
                } finally { $password.Dispose() }
                Close-CampusEditor $State
                [void](Update-CampusAccountsView $State $id)
                $ui.Notice.Text = if ($existing) { '账号密码已更新。' } else { '账号已保存。' }
                [void]$ui.NewAccount.Focus()
            }
            'MakeDefault' {
                $id = [string]$ui.AccountsList.SelectedItem
                if (-not $id) { return }
                [void](Set-CampusDefaultAccount -Root $State.Root -Account $id)
                Close-CampusEditor $State
                [void](Update-CampusAccountsView $State $id)
                $ui.Notice.Text = '默认账号已更新，下轮认证生效。'
            }
            'UseClient' {
                [void](Set-CampusDefaultAccount -Root $State.Root -Account '')
                Close-CampusEditor $State
                [void](Update-CampusAccountsView $State)
                $ui.Notice.Text = '下轮认证使用天翼客户端记住的账号。'
            }
            'DeleteAccount' {
                $id = [string]$ui.AccountsList.SelectedItem
                if (-not $id) { return }
                Close-CampusEditor $State
                $State.Deleting = $id
                $ui.DeleteLabel.Text = '删除本机保存的账号 '+$id+' 和密码？'
                $ui.ConfirmDelete.Visibility = 'Visible'
                $ui.AccountActions.Visibility = 'Collapsed'
                $ui.ConfirmDelete.BringIntoView()
                [void]$ui.KeepAccount.Focus()
            }
            'KeepAccount' { Close-CampusEditor $State; [void]$ui.AccountsList.Focus() }
            'ConfirmRemove' {
                if (-not $State.Deleting) { return }
                [void](Remove-CampusAccount -Root $State.Root -Account $State.Deleting)
                Close-CampusEditor $State
                [void](Update-CampusAccountsView $State)
                $ui.Notice.Text = '已删除本机保存的账号和密码。'
            }
            'SaveProxy' {
                [void](Set-CampusProxyIntegration -Root $State.Root -Enabled ([bool]$ui.Proxy.IsChecked))
                $ui.Notice.Text = '代理设置已保存，下轮网络检查生效。'
            }
            'CloseSettings' { $State.Window.Close() }
        }
    } catch {
        $ui.Notice.Text = '操作未完成。请检查当前 Windows 用户是否可以读写本机设置，然后重试。'
    }
}

function New-CampusSettingsWindow([string]$DataRoot,[switch]$OpenAdd) {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="校园网设置" Width="540" Height="610"
 MinWidth="280" MinHeight="230" WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI, Segoe UI"
 FontSize="14" UseLayoutRounding="True" Background="{DynamicResource {x:Static SystemColors.WindowBrushKey}}">
 <Window.Resources>
  <SolidColorBrush x:Key="ActionBrush" Color="#106955"/>
  <SolidColorBrush x:Key="ActionTextBrush" Color="#FFFFFF"/>
  <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.WindowTextBrushKey}}"/></Style>
  <Style TargetType="Button"><Setter Property="Padding" Value="10,5"/><Setter Property="MinHeight" Value="32"/><Setter Property="Margin" Value="0,3,6,3"/></Style>
  <Style x:Key="ActionButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
   <Setter Property="Background" Value="{DynamicResource ActionBrush}"/><Setter Property="Foreground" Value="{DynamicResource ActionTextBrush}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="Frame" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding Background}" BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Frame" Property="Opacity" Value=".90"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="Frame" Property="Opacity" Value=".78"/></Trigger>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Frame" Property="BorderBrush" Value="{DynamicResource ActionTextBrush}"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TabItem"><Setter Property="Padding" Value="12,5"/></Style>
  <Style TargetType="TextBox"><Setter Property="Padding" Value="5,3"/><Setter Property="MinHeight" Value="31"/></Style>
  <Style TargetType="PasswordBox"><Setter Property="Padding" Value="5,3"/><Setter Property="MinHeight" Value="31"/></Style>
  <Style TargetType="Label"><Setter Property="Padding" Value="0,5,0,3"/></Style>
 </Window.Resources>
 <Grid Margin="14">
  <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TabControl x:Name="Sections">
   <TabItem Header="校园账号"><ScrollViewer x:Name="AccountScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10">
    <StackPanel>
     <TextBlock x:Name="DefaultLabel" FontWeight="SemiBold" FontSize="16" Margin="0,4,0,10"/>
     <TextBlock x:Name="EmptyLabel" Text="尚未保存校园账号。首个添加的账号将用于自动登录。" Margin="0,0,0,6"/>
     <TextBlock x:Name="BeforeInstall" Text="可提前保存设置，安装校园网工具后生效。" Margin="0,0,0,8" Visibility="Collapsed"/>
     <ListBox x:Name="AccountsList" AutomationProperties.Name="已保存的校园账号" MinHeight="44" MaxHeight="115" Margin="0,0,0,4"/>
     <StackPanel x:Name="AccountActions">
      <WrapPanel>
       <Button x:Name="NewAccount" Style="{StaticResource ActionButton}" Content="添加账号…"/><Button x:Name="EditAccount" Content="修改密码…"/>
       <Button x:Name="MakeDefault" Content="设为默认"/><Button x:Name="DeleteAccount" Content="删除账号…"/>
      </WrapPanel>
      <WrapPanel><Button x:Name="UseClient" Content="使用天翼记住的账号"/></WrapPanel>
     </StackPanel>
     <StackPanel x:Name="ConfirmDelete" Visibility="Collapsed" Margin="0,10,0,0">
      <TextBlock x:Name="DeleteLabel" FontWeight="SemiBold"/>
      <WrapPanel><Button x:Name="KeepAccount" Content="保留账号"/><Button x:Name="ConfirmRemove" Content="确认删除"/></WrapPanel>
     </StackPanel>
     <StackPanel x:Name="Editor" Visibility="Collapsed" Margin="0,10,0,0">
      <Separator/><TextBlock x:Name="EditorTitle" FontSize="16" FontWeight="SemiBold" Margin="0,8,0,2"/>
      <Label Content="校园账号" Target="{Binding ElementName=AccountId}"/>
      <TextBox x:Name="AccountId" AutomationProperties.Name="校园账号" MaxLength="16"/>
      <Label Content="天翼校园密码" Target="{Binding ElementName=Secret}"/>
      <PasswordBox x:Name="Secret" AutomationProperties.Name="天翼校园密码"/>
      <CheckBox x:Name="DefaultChoice" Content="设为默认登录账号" Margin="0,10,0,4"/>
      <WrapPanel><Button x:Name="SaveAccount" Style="{StaticResource ActionButton}" Content="保存账号" IsDefault="True"/><Button x:Name="CancelEdit" Content="取消"/></WrapPanel>
     </StackPanel>
    </StackPanel>
   </ScrollViewer></TabItem>
   <TabItem Header="代理联动"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10">
    <StackPanel>
     <CheckBox x:Name="Proxy" AutomationProperties.Name="启用代理联动（Clash / Verge）" Margin="0,4,0,8">
      <TextBlock Text="启用代理联动（Clash / Verge）" TextWrapping="Wrap"/>
     </CheckBox>
     <TextBlock Text="开启后，校园网认证时会暂时关闭代理，认证结束后恢复。平时直接使用校园网可保持关闭。"/>
     <TextBlock Text="保存后从下轮网络检查生效。" Margin="0,8,0,8"/>
     <WrapPanel><Button x:Name="SaveProxy" Style="{StaticResource ActionButton}" Content="保存代理设置"/></WrapPanel>
    </StackPanel>
   </ScrollViewer></TabItem>
  </TabControl>
  <TextBlock Grid.Row="1" x:Name="Notice" Margin="0,8,0,0" AutomationProperties.Name="操作结果"/>
  <Button Grid.Row="2" x:Name="CloseSettings" HorizontalAlignment="Right" Content="关闭"/>
 </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new([xml]$markup)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    if ([Windows.SystemParameters]::HighContrast) {
        $window.Resources['ActionBrush'] = [Windows.SystemColors]::HighlightBrush
        $window.Resources['ActionTextBrush'] = [Windows.SystemColors]::HighlightTextBrush
    }
    $area = [Windows.SystemParameters]::WorkArea
    $window.Width = [Math]::Min($window.Width,[Math]::Max(180,$area.Width-12))
    $window.Height = [Math]::Min($window.Height,[Math]::Max(160,$area.Height-12))
    $window.MinWidth = [Math]::Min($window.MinWidth,$window.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight,$window.Height)
    $ui = @{}
    foreach ($node in ([xml]$markup).SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name) {
            $element = $window.FindName($name)
            if ($element) { $ui[$name] = $element }
        }
    }
    $state = [pscustomobject]@{ Window=$window; Controls=$ui; Root=$DataRoot; Default=''; Accounts=@(); Deleting='' }
    $window.Tag = $state
    foreach ($control in $ui.Values) {
        if ($control -is [Windows.Controls.Button]) {
            $control.Tag = $state
            $control.Add_Click({ param($sender,$eventArgs) Invoke-CampusWindowAction $sender.Tag $sender.Name })
        }
    }
    $ui.AccountsList.Tag = $state
    $ui.AccountsList.Add_SelectionChanged({ param($sender,$eventArgs) Update-CampusAccountButtons $sender.Tag })
    $window.Add_PreviewKeyDown({
        param($sender,$eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Escape) {
            $state = $sender.Tag
            if ($state.Controls.Editor.Visibility -eq 'Visible' -or $state.Controls.ConfirmDelete.Visibility -eq 'Visible') {
                Close-CampusEditor $state
            } else { $sender.Close() }
            $eventArgs.Handled = $true
        }
    })
    $window.Add_Closed({ param($sender,$eventArgs) $sender.Tag.Controls.Secret.Clear() })
    $prefs = Update-CampusAccountsView $state
    $ui.Proxy.IsChecked = [bool]$prefs.ProxyEnabled
    if (-not [IO.File]::Exists((Join-Path $DataRoot 'watchdog.ps1'))) { $ui.BeforeInstall.Visibility = 'Visible' }
    if ($OpenAdd) {
        Open-CampusEditor $state $false
        $window.Add_ContentRendered({ param($sender,$eventArgs) [void]$sender.Tag.Controls.AccountId.Focus() })
    }
    return $window
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $window = New-CampusSettingsWindow -DataRoot $Root -OpenAdd:$AddAccount
        [void]$window.ShowDialog()
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show('校园网设置无法打开。请确认完整解压了安装包，且当前 Windows 用户可以读取本机设置。','校园网设置','OK','Error')
        exit 1
    }
}
