# =====================================================================
#  pc-tuner-gui.ps1 — WPF front end for pc-tuner
#
#  Same trust model as the engine: one plain-text PowerShell script,
#  no compiled binaries. The GUI never changes your system itself -
#  every apply/revert shells out to pc-tuner.ps1, so the engine stays
#  the single audited path for modifications.
#
#  Launch:  right-click > Run with PowerShell, or:
#           powershell -ExecutionPolicy Bypass -File .\pc-tuner-gui.ps1
#
#  -SelfTest builds the window without showing it (used for testing).
# =====================================================================

[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$EnginePath = Join-Path $PSScriptRoot 'pc-tuner.ps1'
Add-Type -AssemblyName PresentationFramework

# ------------------------------------------------------------ engine I/O

function Get-TunerStatus {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $EnginePath -StatusJson
    @(($raw -join "`n") | ConvertFrom-Json)
}

function Invoke-Engine($mode, $id, $acceptTradeoffs) {
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$EnginePath`"","-$mode",$id,'-NoPause')
    if ($acceptTradeoffs) { $argList += '-AcceptTradeoffs' }
    Start-Process powershell -ArgumentList $argList -Wait -WindowStyle Hidden
}

# ------------------------------------------------------------------ XAML

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="pc-tuner" Width="760" Height="640" WindowStartupLocation="CenterScreen"
        Background="#1E1E24">
    <DockPanel Margin="14">
        <TextBlock DockPanel.Dock="Top" Text="pc-tuner" FontSize="22" FontWeight="Bold" Foreground="White"/>
        <TextBlock DockPanel.Dock="Top" Margin="0,2,0,10" FontSize="12" Foreground="#9E9EA8"
                   Text="Evidence-based tweaks. Modules are pure data; only the audited engine touches your system."/>
        <Border DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <DockPanel>
                <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="Refresh" Width="90" Margin="8,0,0,0" Padding="0,6"/>
                <Button x:Name="BtnRevertAll" DockPanel.Dock="Right" Content="Revert all" Width="90" Margin="8,0,0,0" Padding="0,6"/>
                <Button x:Name="BtnApplySafe" DockPanel.Dock="Right" Content="Apply all safe" Width="110" Margin="8,0,0,0" Padding="0,6"/>
                <TextBlock x:Name="StatusBar" Foreground="#9E9EA8" VerticalAlignment="Center" Text="Ready."/>
            </DockPanel>
        </Border>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="TweakList"/>
        </ScrollViewer>
    </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$TweakList   = $window.FindName('TweakList')
$StatusBar   = $window.FindName('StatusBar')
$BtnRefresh  = $window.FindName('BtnRefresh')
$BtnApplySafe = $window.FindName('BtnApplySafe')
$BtnRevertAll = $window.FindName('BtnRevertAll')

# ------------------------------------------------------------ UI builders

function New-Brush($hex) {
    (New-Object Windows.Media.BrushConverter).ConvertFromString($hex)
}

$script:RebootPending = $false

function Add-TweakRow($tweak) {
    $row = New-Object Windows.Controls.Border
    $row.Background = New-Brush '#2A2A33'
    $row.CornerRadius = '6'
    $row.Margin = '0,3,4,3'
    $row.Padding = '10,8'

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in '18','*','90') {
        $col = New-Object Windows.Controls.ColumnDefinition
        $col.Width = $w
        $grid.ColumnDefinitions.Add($col)
    }

    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10
    $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,5,0,0'
    $dot.Fill = if ($tweak.applied) { New-Brush '#4CAF50' } else { New-Brush '#6E6E78' }
    [Windows.Controls.Grid]::SetColumn($dot, 0)
    $grid.Children.Add($dot) | Out-Null

    $textPanel = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($textPanel, 1)

    $titlePanel = New-Object Windows.Controls.StackPanel
    $titlePanel.Orientation = 'Horizontal'
    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $tweak.name
    $title.Foreground = New-Brush 'White'
    $title.FontWeight = 'SemiBold'
    $titlePanel.Children.Add($title) | Out-Null
    if ($tweak.risk -eq 'tradeoff') {
        $badge = New-Object Windows.Controls.TextBlock
        $badge.Text = ' TRADEOFF '
        $badge.Margin = '8,0,0,0'
        $badge.FontSize = 10
        $badge.VerticalAlignment = 'Center'
        $badge.Foreground = New-Brush '#1E1E24'
        $badge.Background = New-Brush '#FFB74D'
        $titlePanel.Children.Add($badge) | Out-Null
    }
    if ($tweak.needsReboot) {
        $rb = New-Object Windows.Controls.TextBlock
        $rb.Text = ' reboot '
        $rb.Margin = '6,0,0,0'
        $rb.FontSize = 10
        $rb.VerticalAlignment = 'Center'
        $rb.Foreground = New-Brush '#9E9EA8'
        $titlePanel.Children.Add($rb) | Out-Null
    }
    $textPanel.Children.Add($titlePanel) | Out-Null

    $why = New-Object Windows.Controls.TextBlock
    $why.Text = $tweak.why
    $why.TextWrapping = 'Wrap'
    $why.FontSize = 11
    $why.Foreground = New-Brush '#9E9EA8'
    $why.Margin = '0,2,0,2'
    $textPanel.Children.Add($why) | Out-Null

    $detail = New-Object Windows.Controls.TextBlock
    $detail.Text = $tweak.detail
    $detail.FontSize = 10
    $detail.FontFamily = 'Consolas'
    $detail.Foreground = New-Brush '#6E6E78'
    $detail.TextWrapping = 'Wrap'
    $textPanel.Children.Add($detail) | Out-Null
    $grid.Children.Add($textPanel) | Out-Null

    $btn = New-Object Windows.Controls.Button
    $btn.Width = 80
    $btn.Height = 26
    $btn.VerticalAlignment = 'Top'
    $btn.Content = if ($tweak.applied) { 'Revert' } else { 'Apply' }
    $btn.Tag = @{ id = $tweak.id; applied = $tweak.applied; risk = $tweak.risk; why = $tweak.why; needsReboot = $tweak.needsReboot }
    $btn.Add_Click({
        param($s, $e)
        $info = $s.Tag
        $accept = $false
        if (-not $info.applied -and $info.risk -eq 'tradeoff') {
            $answer = [Windows.MessageBox]::Show(
                "This tweak is a real tradeoff:`n`n$($info.why)`n`nApply it anyway?",
                'pc-tuner - tradeoff', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            $accept = $true
        }
        $mode = if ($info.applied) { 'Revert' } else { 'Apply' }
        $StatusBar.Text = "$mode`: $($info.id)... (accept the UAC prompt if one appears)"
        $window.Cursor = 'Wait'
        try { Invoke-Engine $mode $info.id $accept } finally { $window.Cursor = $null }
        if ($info.needsReboot) { $script:RebootPending = $true }
        Refresh-List
    })
    [Windows.Controls.Grid]::SetColumn($btn, 2)
    $grid.Children.Add($btn) | Out-Null

    $row.Child = $grid
    $TweakList.Children.Add($row) | Out-Null
}

function Refresh-List {
    $TweakList.Children.Clear()
    $modules = Get-TunerStatus
    foreach ($m in $modules) {
        $hdr = New-Object Windows.Controls.TextBlock
        $hdr.Text = "$($m.module)  -  $($m.file)"
        $hdr.Foreground = New-Brush '#7FB4FF'
        $hdr.FontSize = 13
        $hdr.FontWeight = 'Bold'
        $hdr.Margin = '0,10,0,4'
        $TweakList.Children.Add($hdr) | Out-Null
        foreach ($t in $m.tweaks) { Add-TweakRow $t }
    }
    $onCount = @($modules.tweaks | Where-Object applied).Count
    $total = @($modules.tweaks).Count
    $msg = "$onCount of $total tweaks applied."
    if ($script:RebootPending) { $msg += '  REBOOT REQUIRED for some changes.' }
    $StatusBar.Text = $msg
}

$BtnRefresh.Add_Click({ Refresh-List })
$BtnApplySafe.Add_Click({
    $StatusBar.Text = 'Applying all safe tweaks... (accept the UAC prompt)'
    $window.Cursor = 'Wait'
    try { Invoke-Engine 'Apply' 'safe' $false } finally { $window.Cursor = $null }
    $script:RebootPending = $true
    Refresh-List
})
$BtnRevertAll.Add_Click({
    $answer = [Windows.MessageBox]::Show(
        'Restore every tweak to its original backed-up value?',
        'pc-tuner - revert all', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $window.Cursor = 'Wait'
    try { Invoke-Engine 'Revert' 'all' $false } finally { $window.Cursor = $null }
    $script:RebootPending = $true
    Refresh-List
})

Refresh-List

if ($SelfTest) {
    $n = $TweakList.Children.Count
    Write-Output "SELFTEST OK: window built, $n elements in tweak list, status: $($StatusBar.Text)"
    exit 0
}

$window.ShowDialog() | Out-Null
