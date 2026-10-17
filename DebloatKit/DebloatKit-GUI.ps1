<#
.SYNOPSIS
    WPF front end for DebloatKit.ps1 (the engine is the only thing that changes the system).

.DESCRIPTION
    Lists every tweak in tweak-catalog.json with its effectiveness, evidence quality, risk and
    current status, explains it in plain language, and lets you preview / apply / undo through the
    engine. This GUI never writes the registry or services itself: every change goes through
    DebloatKit.ps1 in a separate (elevated, when applying) process.

    Works on Windows PowerShell 5.1 and PowerShell 7 on Windows. Relaunches itself with -STA when
    needed. This file is kept ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI).

.PARAMETER SelfTest
    Load the XAML, load the data via the engine, fill the grid, exercise filter / sort /
    select-recommended, print counts and the top 10 by effectiveness, and exit 0 without showing
    the window. Exits non-zero on any failure.

.PARAMETER EnginePath
    Path to DebloatKit.ps1 (default: next to this script).

.PARAMETER CatalogPath
    Path to tweak-catalog.json (default: next to this script).
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$EnginePath,
    [string]$CatalogPath
)

$ErrorActionPreference = 'Stop'
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }
$script:ScriptDir = Split-Path -Parent $script:ScriptPath
if (-not $EnginePath) { $EnginePath = Join-Path $script:ScriptDir 'DebloatKit.ps1' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $script:ScriptDir 'tweak-catalog.json' }
$script:DefaultCatalogPath = Join-Path $script:ScriptDir 'tweak-catalog.json'
$script:HostExe = (Get-Process -Id $PID).Path

# ---- STA relaunch (WPF needs a single-threaded apartment) ----
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $script:ScriptPath)
    if ($SelfTest) { $relaunch += '-SelfTest' }
    if ($PSBoundParameters.ContainsKey('EnginePath')) { $relaunch += @('-EnginePath', $EnginePath) }
    if ($PSBoundParameters.ContainsKey('CatalogPath')) { $relaunch += @('-CatalogPath', $CatalogPath) }
    & $script:HostExe @relaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

if (-not ('DebloatKitGui.TweakRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
namespace DebloatKitGui {
    public class TweakRow : INotifyPropertyChanged {
        public static Action SelectionChanged;
        public event PropertyChangedEventHandler PropertyChanged;
        private bool _checked;
        public bool Checked {
            get { return _checked; }
            set {
                if (_checked != value) {
                    _checked = value;
                    if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs("Checked"));
                    if (SelectionChanged != null) SelectionChanged();
                }
            }
        }
        public bool CanCheck { get; set; }
        public string CheckTip { get; set; }
        public string Id { get; set; }
        public string Description { get; set; }
        public string Category { get; set; }
        public string Preset { get; set; }
        public string Risk { get; set; }
        public int Eff { get; set; }
        public string Stars { get; set; }
        public string EvidenceQuality { get; set; }
        public string Status { get; set; }
        public string Note { get; set; }
        public bool IsUnverified { get; set; }
        public string Verification { get; set; }
        public string RiskColor { get; set; }
        public string PresetColor { get; set; }
        public string EvColor { get; set; }
        public string StatusColor { get; set; }
        public string GroupLabel { get; set; }
        public object Data { get; set; }
    }
}
'@
}

#region engine access ---------------------------------------------------------

function Test-Elevated {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-JsonArray([string]$Json) {
    # Windows PowerShell 5.1 returns a JSON array as ONE object; piping it enumerates the items on both editions.
    $o = $Json | ConvertFrom-Json
    @($o | ForEach-Object { $_ })
}

function Test-InAdminGroup {
    # True when the signed-in user is in the local Administrators group (also with a filtered, non-elevated token).
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    [bool]($id.Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' })
}

function Test-TweakId([string]$Id) { $Id -match '^[A-Za-z0-9._-]+$' }

function ConvertTo-EncodedCommand([string]$Text) {
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function New-EngineCommandText {
    # $EngineArgs: tokens such as '-List','-AsJson'. $Ids becomes -Only @('a','b').
    param([string[]]$EngineArgs, [string[]]$Ids, [string]$LogPath, [switch]$PassSid)
    $enginePathQ = $EnginePath.Replace("'", "''")
    $line = "& '$enginePathQ'"
    if ($EngineArgs) { $line += ' ' + ($EngineArgs -join ' ') }
    # The engine must read the same catalog the grid shows.
    if ([IO.Path]::GetFullPath($CatalogPath) -ne [IO.Path]::GetFullPath($script:DefaultCatalogPath)) {
        $line += " -CatalogPath '" + ([IO.Path]::GetFullPath($CatalogPath).Replace("'", "''")) + "'"
    }
    if ($PassSid) { $line += " -ExpectedSid '" + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + "'" }
    if ($Ids) {
        foreach ($i in $Ids) { if (-not (Test-TweakId $i)) { throw "Refusing suspicious tweak id: $i" } }
        $line += ' -Only @(' + (($Ids | ForEach-Object { "'$_'" }) -join ',') + ')'
    }
    if ($LogPath) {
        $logQ = $LogPath.Replace("'", "''")
        $line = "$line *>&1 | Tee-Object -FilePath '$logQ'"
    }
    $line + '; exit $LASTEXITCODE'
}

function Start-EngineProcess {
    # Starts the engine in a child process of the same PowerShell flavour as this script.
    # Non-elevated: output captured to temp files. Elevated: UAC prompt, output teed to a log file.
    param([string[]]$EngineArgs, [string[]]$Ids, [switch]$Elevated)
    $tag = [guid]::NewGuid().ToString('N')
    $h = [pscustomobject]@{ Process = $null; Out = $null; Err = $null; Log = $null; Elevated = [bool]$Elevated }
    if ($Elevated) { $h.Log = Join-Path $env:TEMP "DebloatKit-gui-$tag.log" }
    $cmd = New-EngineCommandText -EngineArgs $EngineArgs -Ids $Ids -LogPath $h.Log -PassSid:$Elevated
    $argLine = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + (ConvertTo-EncodedCommand $cmd)
    if ($Elevated) {
        $h.Process = Start-Process -FilePath $script:HostExe -ArgumentList $argLine -Verb RunAs -PassThru
    } else {
        $h.Out = Join-Path $env:TEMP "DebloatKit-gui-$tag.out"
        $h.Err = Join-Path $env:TEMP "DebloatKit-gui-$tag.err"
        $h.Process = Start-Process -FilePath $script:HostExe -ArgumentList ('-NonInteractive ' + $argLine) -WindowStyle Hidden -PassThru -RedirectStandardOutput $h.Out -RedirectStandardError $h.Err
    }
    $null = $h.Process.Handle   # keep the handle so ExitCode is readable on Windows PowerShell 5.1
    $h
}

function Read-EngineResult($h) {
    $stdout = ''; $stderr = ''
    if ($h.Out -and (Test-Path -LiteralPath $h.Out)) { $stdout = [IO.File]::ReadAllText($h.Out); Remove-Item -LiteralPath $h.Out -Force -ErrorAction SilentlyContinue }
    if ($h.Err -and (Test-Path -LiteralPath $h.Err)) { $stderr = [IO.File]::ReadAllText($h.Err); Remove-Item -LiteralPath $h.Err -Force -ErrorAction SilentlyContinue }
    $log = ''
    if ($h.Log -and (Test-Path -LiteralPath $h.Log)) { $log = (Get-Content -LiteralPath $h.Log -Raw -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $h.Log -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ ExitCode = $h.Process.ExitCode; Stdout = $stdout; Stderr = $stderr; Log = $log }
}

function Invoke-EngineSync {
    param([string[]]$EngineArgs, [string[]]$Ids)
    $h = Start-EngineProcess -EngineArgs $EngineArgs -Ids $Ids
    $h.Process.WaitForExit()
    Read-EngineResult $h
}

function Get-EngineList {
    # Returns @{ Managed; Tweaks } from: engine -List -AsJson -IncludeUnverified
    param($Result)
    if ($Result.ExitCode -ne 0) { throw "Engine -List failed (exit $($Result.ExitCode)): $($Result.Stderr) $($Result.Stdout)" }
    $doc = $Result.Stdout | ConvertFrom-Json
    if (-not $doc -or -not $doc.PSObject.Properties['tweaks']) { throw 'Engine -List returned no tweaks array.' }
    [pscustomobject]@{ Managed = $doc.managed; Tweaks = @($doc.tweaks); Warnings = $Result.Stderr }
}

#endregion

#region data model ------------------------------------------------------------

function Get-Prop($Obj, [string]$Name, $Default = $null) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
    $Default
}

$script:RiskColors   = @{ 'safe' = '#2E7D32'; 'moderate' = '#B26A00'; 'breaks-features' = '#E65100'; 'reduces-security' = '#C62828' }
$script:PresetColors = @{ 'safe' = '#2E7D32'; 'balanced' = '#B26A00'; 'aggressive' = '#E65100'; 'never-default' = '#C62828' }
$script:EvColors     = @{ 'strong' = '#2E7D32'; 'mixed' = '#1565C0'; 'weak' = '#757575'; 'none' = '#9E9E9E' }
$script:StatusColors = @{ 'Applied' = '#2E7D32'; 'NotApplied' = '#1565C0'; 'Partial' = '#B26A00'; 'Skipped' = '#757575' }
$script:RiskOrder    = @{ 'safe' = 0; 'moderate' = 1; 'breaks-features' = 2; 'reduces-security' = 3 }
$script:EvOrder      = @{ 'strong' = 3; 'mixed' = 2; 'weak' = 1; 'none' = 0 }
$script:StatusOrder  = @{ 'NotApplied' = 0; 'Partial' = 1; 'Applied' = 2; 'Skipped' = 3 }

function Get-Stars([int]$n) {
    if ($n -lt 0) { $n = 0 }; if ($n -gt 5) { $n = 5 }
    ([string][char]0x2605) * $n + ([string][char]0x2606) * (5 - $n)
}

function New-TweakRows {
    param($Catalog, $EngineTweaks)
    $byId = @{}
    foreach ($e in $EngineTweaks) { $byId[[string]$e.id] = $e }
    $rows = New-Object System.Collections.Generic.List[DebloatKitGui.TweakRow]
    foreach ($t in $Catalog) {
        $r = New-Object DebloatKitGui.TweakRow
        $r.Id = [string]$t.id
        $r.Description = [string](Get-Prop $t 'description' $t.id)
        $r.Category = [string](Get-Prop $t 'category' 'other')
        $r.Preset = [string](Get-Prop $t 'preset' 'safe')
        $r.Risk = [string](Get-Prop $t 'risk' 'safe')
        $r.Eff = [int](Get-Prop $t 'effectiveness' 0)
        $r.Stars = Get-Stars $r.Eff
        $r.EvidenceQuality = [string](Get-Prop $t 'evidenceQuality' 'none')
        $r.Verification = [string](Get-Prop $t 'verification' '')
        $r.IsUnverified = ($r.Verification -eq 'new-unverified')
        $eng = $byId[$r.Id]
        if ($eng) {
            $r.Status = [string]$eng.status
            $r.Note = [string](Get-Prop $eng 'note' '')
        } else {
            $r.Status = 'Skipped'
            $r.Note = 'Preset not enabled in this version'
        }
        $r.CanCheck = ($r.Preset -eq 'safe' -and $r.Status -ne 'Skipped')
        if ($r.Preset -ne 'safe') { $r.CheckTip = 'Preset not enabled in this version' }
        elseif ($r.Status -eq 'Skipped') { $r.CheckTip = 'The engine would skip this tweak: ' + $r.Note }
        elseif ($r.IsUnverified) { $r.CheckTip = 'Unverified: not tested on a real machine. Unchecked by default.' }
        else { $r.CheckTip = '' }
        $r.RiskColor = $script:RiskColors[$r.Risk]; if (-not $r.RiskColor) { $r.RiskColor = '#757575' }
        $r.PresetColor = $script:PresetColors[$r.Preset]; if (-not $r.PresetColor) { $r.PresetColor = '#757575' }
        $r.EvColor = $script:EvColors[$r.EvidenceQuality]; if (-not $r.EvColor) { $r.EvColor = '#9E9E9E' }
        $r.StatusColor = $script:StatusColors[$r.Status]; if (-not $r.StatusColor) { $r.StatusColor = '#757575' }
        $r.Data = $t
        $rows.Add($r)
    }
    ,$rows
}

function Select-TweakRows {
    # Filter + group + sort. Pure function over the row list (used by the UI and by -SelfTest).
    param(
        $Rows,
        [string]$Search = '', [string]$Category = 'All', [string]$Preset = 'All', [string]$Risk = 'All',
        [string]$Status = 'All', [bool]$OnlyProven = $false,
        [ValidateSet('Effectiveness', 'Category', 'Risk', 'Status', 'None')][string]$GroupBy = 'Effectiveness',
        [ValidateSet('Effectiveness', 'Name', 'Category', 'Risk', 'Status')][string]$SortBy = 'Effectiveness'
    )
    $q = $Search.Trim().ToLowerInvariant()
    $sel = @($Rows | Where-Object {
        $r = $_
        if ($Category -ne 'All' -and $r.Category -ne $Category) { return $false }
        if ($Preset -ne 'All' -and $r.Preset -ne $Preset) { return $false }
        if ($Risk -ne 'All' -and $r.Risk -ne $Risk) { return $false }
        if ($Status -ne 'All' -and $r.Status -ne $Status) { return $false }
        if ($OnlyProven -and $r.EvidenceQuality -notin 'strong', 'mixed') { return $false }
        if ($q) {
            $d = $r.Data
            $hay = ($r.Id + ' ' + $r.Description + ' ' + $r.Category + ' ' + (Get-Prop $d 'explanation' '') + ' ' + (Get-Prop $d 'whoBenefits' '')).ToLowerInvariant()
            if (-not $hay.Contains($q)) { return $false }
        }
        $true
    })
    $keys = New-Object System.Collections.ArrayList
    switch ($GroupBy) {
        'Effectiveness' { [void]$keys.Add(@{ Expression = { $_.Eff }; Descending = $true }) }
        'Category'      { [void]$keys.Add(@{ Expression = { $_.Category }; Descending = $false }) }
        'Risk'          { [void]$keys.Add(@{ Expression = { [int]$script:RiskOrder[$_.Risk] }; Descending = $false }) }
        'Status'        { [void]$keys.Add(@{ Expression = { [int]$script:StatusOrder[$_.Status] }; Descending = $false }) }
    }
    switch ($SortBy) {
        'Effectiveness' { [void]$keys.Add(@{ Expression = { $_.Eff }; Descending = $true }); [void]$keys.Add(@{ Expression = { [int]$script:EvOrder[$_.EvidenceQuality] }; Descending = $true }) }
        'Name'          { [void]$keys.Add(@{ Expression = { $_.Description }; Descending = $false }) }
        'Category'      { [void]$keys.Add(@{ Expression = { $_.Category }; Descending = $false }) }
        'Risk'          { [void]$keys.Add(@{ Expression = { [int]$script:RiskOrder[$_.Risk] }; Descending = $false }) }
        'Status'        { [void]$keys.Add(@{ Expression = { [int]$script:StatusOrder[$_.Status] }; Descending = $false }) }
    }
    [void]$keys.Add(@{ Expression = { $_.Id }; Descending = $false })
    $sorted = @($sel | Sort-Object -Property $keys.ToArray())
    foreach ($r in $sorted) {
        $r.GroupLabel = switch ($GroupBy) {
            'Effectiveness' { 'Effectiveness {0} of 5   {1}' -f $r.Eff, (Get-Stars $r.Eff) }
            'Category'      { $r.Category }
            'Risk'          { 'Risk: ' + $r.Risk }
            'Status'        { 'Status: ' + $r.Status }
            default         { 'All tweaks' }
        }
    }
    ,$sorted
}

function Test-Recommended($r) {
    $r.Preset -eq 'safe' -and $r.Eff -ge 2 -and $r.EvidenceQuality -ne 'none' -and -not $r.IsUnverified -and $r.Status -ne 'Applied' -and $r.CanCheck
}

function Set-RecommendedSelection($Rows) {
    foreach ($r in $Rows) { $r.Checked = ($r.CanCheck -and (Test-Recommended $r)) }
}

function Clear-Selection($Rows) { foreach ($r in $Rows) { $r.Checked = $false } }

# ---- text helpers for the detail pane ----
function Format-Value($v) {
    if ($null -eq $v) { return '<none>' }
    if ($v -is [string]) { return $v }
    ($v | ConvertTo-Json -Compress -Depth 4)
}

function Format-ImplStep($s) {
    if ($s -is [string]) { return @("Command (reference only): $s") }
    $type = [string](Get-Prop $s 'type' '')
    switch ($type) {
        'registry' {
            $n = Get-Prop $s 'name' $null
            $target = if ($n) { "$(Get-Prop $s 'path')  value '$n'" } else { "key $(Get-Prop $s 'path')" }
            @("Registry: $target = $(Format-Value (Get-Prop $s 'value')) ($(Get-Prop $s 'valueType' 'n/a'))")
        }
        'service' { @("Service '$(Get-Prop $s 'name')': startup type set to $(Get-Prop $s 'startType')" + $(if (Get-Prop $s 'stockDefaultHint') { "  (Windows default: $(Get-Prop $s 'stockDefaultHint'))" } else { '' })) }
        'task'    { @("Scheduled task $(Get-Prop $s 'path')$(Get-Prop $s 'name'): set to $(Get-Prop $s 'state')") }
        'appx'    { @("Remove AppX packages: $((@(Get-Prop $s 'names' @())) -join ', ')  [engine skips this unless -AllowIrreversible; this GUI never passes it]") }
        'command' { @("Command: $(Get-Prop $s 'run')  [only 3 commands are implemented natively by the engine; the rest are skipped, never executed]") }
        'external' { @("External tool: $(Get-Prop $s 'tool') - $(Get-Prop $s 'note')  [not run by the engine]") }
        'multi'   { $out = @(); foreach ($x in @(Get-Prop $s 'steps' @())) { $out += Format-ImplStep $x }; $out }
        default   { @(Format-Value $s) }
    }
}

function Get-ImplLeafSteps($Impl) {
    if ($null -eq $Impl -or $Impl -is [string]) { return @($Impl) }
    if ((Get-Prop $Impl 'type' '') -eq 'multi') { $o = @(); foreach ($x in @(Get-Prop $Impl 'steps' @())) { $o += @(Get-ImplLeafSteps $x) }; return $o }
    @($Impl)
}

function Format-RevertText($rev) {
    if ($null -eq $rev) { return 'Use "Undo last run": the engine restores the exact values saved in its snapshot.' }
    if ($rev -is [string]) { return "Reference command (not run by the engine): $rev" }
    $type = [string](Get-Prop $rev 'type' '')
    $act = [string](Get-Prop $rev 'action' '')
    if ($type -eq 'multi') {
        $lines = @()
        if (Get-Prop $rev 'note') { $lines += [string](Get-Prop $rev 'note') }
        foreach ($x in @(Get-Prop $rev 'steps' @())) { $lines += (Format-RevertText $x) }
        return ($lines -join "`n")
    }
    switch ($act) {
        'restoreSnapshot' {
            $t = 'Undo last run restores what was there before (the snapshot value)'
            if ((Get-Prop $rev 'ifAbsentBefore') -eq 'deleteValue') { $t += ', or deletes the value if it did not exist before' }
            return $t + '.'
        }
        'deleteKey' { return 'Undo last run deletes the key the run created.' }
        'reinstall' { return "No exact undo: reinstall via $(Get-Prop $rev 'how' 'winget/Store')." }
    }
    if ($type -eq 'service' -or $type -eq 'task') { return 'Undo last run restores the saved previous state from the snapshot.' }
    Format-Value $rev
}

#endregion

#region XAML ------------------------------------------------------------------

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DebloatKit" Width="1480" Height="880" MinWidth="1000" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F4F6F8" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="MinHeight" Value="30"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,10,0,3"/>
      <Setter Property="Foreground" Value="#37474F"/>
    </Style>
    <Style x:Key="SectionHead" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#455A64"/>
      <Setter Property="Margin" Value="0,14,0,3"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Banner -->
    <Border x:Name="bannerManaged" Grid.Row="0" Background="#E8F5E9" BorderBrush="#C8E6C9" BorderThickness="0,0,0,1" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="txtManaged" Grid.Column="0" TextWrapping="Wrap" Text="Loading device information..."/>
        <TextBlock x:Name="txtElevation" Grid.Column="1" Margin="20,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- Main area -->
    <Grid Grid.Row="1" Margin="10,10,10,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="230" MinWidth="170"/>
        <ColumnDefinition Width="6"/>
        <ColumnDefinition Width="*" MinWidth="400"/>
        <ColumnDefinition Width="6"/>
        <ColumnDefinition Width="430" MinWidth="260"/>
      </Grid.ColumnDefinitions>

      <!-- Filters -->
      <Border Grid.Column="0" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4" Padding="12,6,12,12">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="FILTERS" Style="{StaticResource SectionHead}" Margin="0,6,0,0"/>
            <TextBlock Text="Search" Style="{StaticResource Label}"/>
            <TextBox x:Name="txtSearch" Padding="4" ToolTip="Matches id, description, explanation and category"/>
            <TextBlock Text="Category" Style="{StaticResource Label}"/>
            <ComboBox x:Name="cmbCategory"/>
            <TextBlock Text="Preset" Style="{StaticResource Label}"/>
            <ComboBox x:Name="cmbPreset"/>
            <TextBlock Text="Risk" Style="{StaticResource Label}"/>
            <ComboBox x:Name="cmbRisk"/>
            <TextBlock Text="Status" Style="{StaticResource Label}"/>
            <ComboBox x:Name="cmbStatus"/>
            <CheckBox x:Name="chkProven" Content="Only proven (evidence strong/mixed)" Margin="0,14,0,0">
              <CheckBox.ContentTemplate><DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap"/></DataTemplate></CheckBox.ContentTemplate>
            </CheckBox>
            <TextBlock Text="VIEW" Style="{StaticResource SectionHead}"/>
            <TextBlock Text="Group by" Style="{StaticResource Label}" Margin="0,2,0,3"/>
            <ComboBox x:Name="cmbGroup"/>
            <TextBlock Text="Sort by" Style="{StaticResource Label}"/>
            <ComboBox x:Name="cmbSort"/>
            <Button x:Name="btnResetFilters" Content="Reset filters" Margin="0,16,0,0" HorizontalAlignment="Left"/>
            <TextBlock x:Name="txtLegend" TextWrapping="Wrap" Foreground="#607D8B" FontSize="11.5" Margin="0,16,0,0"
                       Text="Effectiveness (0-5) is a score from the catalog, based on measured evidence only. 0 means no measurable speed gain was found, not that the tweak is useless (many are privacy or comfort tweaks)."/>
          </StackPanel>
        </ScrollViewer>
      </Border>

      <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="Transparent" ResizeBehavior="PreviousAndNext"/>

      <!-- Tweak list -->
      <Border Grid.Column="2" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4">
        <Grid>
          <DataGrid x:Name="grid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserSortColumns="False"
                    IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow" HeadersVisibility="Column"
                    GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECEFF1" BorderThickness="0"
                    RowBackground="White" AlternatingRowBackground="#FAFBFC" CanUserResizeRows="False"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" EnableRowVirtualization="True">
            <DataGrid.GroupStyle>
              <GroupStyle>
                <GroupStyle.ContainerStyle>
                  <Style TargetType="GroupItem">
                    <Setter Property="Template">
                      <Setter.Value>
                        <ControlTemplate TargetType="GroupItem">
                          <Expander IsExpanded="True" Background="#ECEFF1" BorderBrush="#CFD8DC" BorderThickness="0,0,0,1">
                            <Expander.Header>
                              <StackPanel Orientation="Horizontal" Margin="4,3">
                                <TextBlock Text="{Binding Name}" FontWeight="Bold" Foreground="#263238"/>
                                <TextBlock Text="   " />
                                <TextBlock Text="{Binding ItemCount}" Foreground="#607D8B"/>
                                <TextBlock Text=" tweak(s)" Foreground="#607D8B"/>
                              </StackPanel>
                            </Expander.Header>
                            <ItemsPresenter/>
                          </Expander>
                        </ControlTemplate>
                      </Setter.Value>
                    </Setter>
                  </Style>
                </GroupStyle.ContainerStyle>
              </GroupStyle>
            </DataGrid.GroupStyle>
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="34">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding Checked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanCheck}"
                              ToolTip="{Binding CheckTip}" ToolTipService.ShowOnDisabled="True" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Tweak" Width="*" MinWidth="200">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <StackPanel Margin="2,5">
                      <TextBlock Text="{Binding Description}" TextWrapping="Wrap" FontWeight="SemiBold"/>
                      <TextBlock Text="{Binding Id}" Foreground="#78909C" FontSize="11" TextWrapping="Wrap"/>
                    </StackPanel>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="110">
                <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Foreground" Value="#455A64"/></Style></DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTemplateColumn Header="Effectiveness" Width="100">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="{Binding Stars}" Foreground="#F9A825" FontSize="15" FontFamily="Segoe UI Symbol"/>
                      <TextBlock Text="{Binding Eff, StringFormat='{}{0} / 5'}" Foreground="#78909C" FontSize="11"/>
                    </StackPanel>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Evidence" Width="76">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Border Background="{Binding EvColor}" CornerRadius="3" Padding="6,1" HorizontalAlignment="Left" VerticalAlignment="Center">
                      <TextBlock Text="{Binding EvidenceQuality}" Foreground="White" FontSize="11"/>
                    </Border>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Preset / risk" Width="112">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <StackPanel VerticalAlignment="Center">
                      <Border Background="{Binding PresetColor}" CornerRadius="3" Padding="6,1" HorizontalAlignment="Left">
                        <TextBlock Text="{Binding Preset}" Foreground="White" FontSize="11"/>
                      </Border>
                      <TextBlock Text="{Binding Risk}" Foreground="{Binding RiskColor}" FontSize="11" Margin="0,2,0,0" FontWeight="SemiBold"/>
                    </StackPanel>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Status" Width="92">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="" Width="86">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Border Background="#7B1FA2" CornerRadius="3" Padding="6,1" HorizontalAlignment="Left" VerticalAlignment="Center"
                            ToolTip="Not yet tested on a real machine. Use a VM first.">
                      <Border.Style>
                        <Style TargetType="Border">
                          <Setter Property="Visibility" Value="Collapsed"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding IsUnverified}" Value="True"><Setter Property="Visibility" Value="Visible"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Border.Style>
                      <TextBlock Text="unverified" Foreground="White" FontSize="11"/>
                    </Border>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>
          <!-- Loading overlay -->
          <Border x:Name="loadingOverlay" Background="#E6FFFFFF" Visibility="Collapsed">
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <TextBlock x:Name="txtLoading" Text="Loading..." FontSize="18" FontWeight="SemiBold" Foreground="#37474F" HorizontalAlignment="Center"/>
              <ProgressBar IsIndeterminate="True" Width="260" Height="8" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>

      <GridSplitter Grid.Column="3" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="Transparent" ResizeBehavior="PreviousAndNext"/>

      <!-- Detail pane -->
      <Border Grid.Column="4" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,12,16,16">
          <StackPanel x:Name="detailPanel">
            <TextBlock Text="Select a tweak to see what it does." Foreground="#78909C" TextWrapping="Wrap"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <!-- Action bar -->
    <Border Grid.Row="2" Margin="10,10,10,0" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4" Padding="12,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal">
          <Button x:Name="btnRecommended" Content="Select recommended" ToolTip="safe preset, effectiveness 2 or more, some evidence, verified, not already applied"/>
          <Button x:Name="btnClear" Content="Clear"/>
          <Button x:Name="btnPreview" Content="Preview changes" ToolTip="Runs the engine with -WhatIf. Writes nothing."/>
          <Button x:Name="btnApply" Content="Apply selected" FontWeight="SemiBold" Background="#2E7D32" Foreground="White"/>
          <Button x:Name="btnUndo" Content="Undo last run"/>
          <Button x:Name="btnRefresh" Content="Refresh"/>
          <Button x:Name="btnLogs" Content="Open log folder"/>
        </StackPanel>
        <CheckBox x:Name="chkManaged" Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"
                  Content="I understand this is a managed device (adds -Force; policy keys may conflict with my organisation's settings)"/>
        <TextBlock x:Name="txtSelected" Grid.Column="2" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="#37474F"/>
      </Grid>
    </Border>

    <!-- Status bar -->
    <Border Grid.Row="3" Padding="14,6" Margin="0,4,0,0">
      <TextBlock x:Name="txtStatus" Foreground="#546E7A" TextWrapping="Wrap"/>
    </Border>
  </Grid>
</Window>
'@

$script:PlanXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Preview" Width="1100" Height="620" WindowStartupLocation="CenterOwner" Background="#F4F6F8" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="txtSummary" TextWrapping="Wrap" Margin="0,0,0,10" FontWeight="SemiBold"/>
    <DataGrid x:Name="planGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column"
              GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECEFF1" Background="White">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Action" Binding="{Binding action}" Width="80"/>
        <DataGridTextColumn Header="Tweak" Binding="{Binding tweakId}" Width="200"/>
        <DataGridTextColumn Header="Type" Binding="{Binding type}" Width="70"/>
        <DataGridTextColumn Header="Target" Binding="{Binding target}" Width="260"/>
        <DataGridTextColumn Header="Current" Binding="{Binding current}" Width="90"/>
        <DataGridTextColumn Header="Desired" Binding="{Binding desired}" Width="90"/>
        <DataGridTextColumn Header="Reason" Binding="{Binding reason}" Width="*"/>
      </DataGrid.Columns>
      <DataGrid.CellStyle>
        <Style TargetType="DataGridCell"><Setter Property="TextBlock.TextWrapping" Value="Wrap"/></Style>
      </DataGrid.CellStyle>
    </DataGrid>
    <Button x:Name="btnClose" Grid.Row="2" Content="Close" Width="90" Padding="10,6" HorizontalAlignment="Right" Margin="0,10,0,0" IsDefault="True"/>
  </Grid>
</Window>
'@

$script:TextXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Result" Width="900" Height="560" WindowStartupLocation="CenterOwner" Background="#F4F6F8" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="txtHead" TextWrapping="Wrap" FontWeight="SemiBold" Margin="0,0,0,10"/>
    <TextBox x:Name="txtBody" Grid.Row="1" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    <Button x:Name="btnClose" Grid.Row="2" Content="Close" Width="90" Padding="10,6" HorizontalAlignment="Right" Margin="0,10,0,0" IsDefault="True"/>
  </Grid>
</Window>
'@

function Read-Xaml([string]$Xaml) {
    $sr = New-Object System.IO.StringReader($Xaml)
    $xr = [System.Xml.XmlReader]::Create($sr)
    try { [System.Windows.Markup.XamlReader]::Load($xr) } finally { $xr.Close() }
}

#endregion

#region self test (no window) -------------------------------------------------

function Invoke-SelfTest {
    $fail = New-Object System.Collections.Generic.List[string]
    function Assert-That([bool]$Cond, [string]$Msg) {
        if ($Cond) { Write-Output "  ok   $Msg" } else { Write-Output "  FAIL $Msg"; $fail.Add($Msg) }
    }
    Write-Output "DebloatKit-GUI self-test (host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion), apartment: $([Threading.Thread]::CurrentThread.GetApartmentState()))"

    # 1. XAML
    $win = Read-Xaml $script:MainXaml
    $script:Window = $win   # Get-Ctl / Show-Detail work against this instance
    Assert-That ($null -ne $win) 'main XAML loads'
    foreach ($n in 'grid', 'txtSearch', 'cmbCategory', 'cmbPreset', 'cmbRisk', 'cmbStatus', 'chkProven', 'detailPanel', 'btnApply', 'btnUndo', 'btnPreview', 'txtManaged') {
        Assert-That ($null -ne $win.FindName($n)) "XAML element '$n' present"
    }
    Assert-That ($null -ne (Read-Xaml $script:PlanXaml)) 'plan dialog XAML loads'
    Assert-That ($null -ne (Read-Xaml $script:TextXaml)) 'result dialog XAML loads'

    # 2. Data via engine (child process, no admin)
    Assert-That (Test-Path -LiteralPath $EnginePath) "engine found: $EnginePath"
    Assert-That (Test-Path -LiteralPath $CatalogPath) "catalog found: $CatalogPath"
    $res = Invoke-EngineSync -EngineArgs @('-List', '-AsJson', '-IncludeUnverified')
    Assert-That ($res.ExitCode -eq 0) "engine -List -AsJson exit code 0 (got $($res.ExitCode))"
    $eng = Get-EngineList $res
    $catalog = (Read-JsonArray (Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8))
    Assert-That ($catalog.Count -gt 0) "catalog loaded: $($catalog.Count) entries"
    Assert-That ($eng.Tweaks.Count -gt 0) "engine returned $($eng.Tweaks.Count) tweaks"
    $m = $eng.Managed
    Write-Output ("  managed: isManaged={0} entra={1} domain={2} mdm={3} tenant='{4}' elevated={5}" -f $m.isManaged, $m.azureAdJoined, $m.domainJoined, $m.mdmEnrolled, $m.tenant, (Test-Elevated))

    # 3. Rows
    $rows = New-TweakRows -Catalog $catalog -EngineTweaks $eng.Tweaks
    Assert-That ($rows.Count -eq $catalog.Count) "grid rows = catalog entries ($($rows.Count))"
    $win.FindName('grid').ItemsSource = $rows
    Assert-That ($win.FindName('grid').Items.Count -eq $rows.Count) 'DataGrid accepts the rows'
    $badSafe = @($rows | Where-Object { $_.Preset -eq 'safe' -and $_.Status -eq 'Skipped' -and $_.Note -eq 'Preset not enabled in this version' })
    Assert-That ($badSafe.Count -eq 0) 'every safe tweak has an engine status'
    Assert-That (@($rows | Where-Object { $_.Checked }).Count -eq 0) 'nothing is checked by default'
    Assert-That (@($rows | Where-Object { $_.Preset -ne 'safe' -and $_.CanCheck }).Count -eq 0) 'non-safe presets have disabled checkboxes'
    Assert-That (@($rows | Where-Object { $_.IsUnverified -and $_.Checked }).Count -eq 0) 'unverified tweaks are unchecked'

    Write-Output ''
    Write-Output 'Counts:'
    Write-Output ('  total={0}  unverified={1}  checkable={2}' -f $rows.Count, @($rows | Where-Object IsUnverified).Count, @($rows | Where-Object CanCheck).Count)
    Write-Output ('  by preset:   ' + ((@($rows | Group-Object Preset | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ', '))
    Write-Output ('  by status:   ' + ((@($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ', '))
    Write-Output ('  by evidence: ' + ((@($rows | Group-Object EvidenceQuality | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ', '))
    Write-Output ('  by effect:   ' + ((@($rows | Group-Object Eff | Sort-Object Name -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ', '))

    # 4. Filter / sort / select-recommended
    $all = Select-TweakRows -Rows $rows
    Assert-That ($all.Count -eq $rows.Count) 'no filter returns every row'
    $effs = @($all | ForEach-Object { $_.Eff })
    $sortedOk = $true; for ($i = 1; $i -lt $effs.Count; $i++) { if ($effs[$i] -gt $effs[$i - 1]) { $sortedOk = $false } }
    Assert-That $sortedOk 'default sort is effectiveness descending'
    $win.FindName('grid').ItemsSource = $null
    $lcv = New-GridView $all   # same builder Update-Grid uses (ArrayList-backed view)
    $win.FindName('grid').ItemsSource = $lcv
    Assert-That ($lcv.Count -eq $all.Count) 'New-GridView keeps every item'
    Assert-That ($lcv.Groups.Count -gt 0) "grouping works ($($lcv.Groups.Count) groups)"

    $proven = Select-TweakRows -Rows $rows -OnlyProven $true
    Assert-That ($proven.Count -gt 0 -and $proven.Count -lt $rows.Count -and (@($proven | Where-Object { $_.EvidenceQuality -notin 'strong', 'mixed' }).Count -eq 0)) "only-proven filter ($($proven.Count) rows)"
    $safeOnly = Select-TweakRows -Rows $rows -Preset 'safe'
    Assert-That ($safeOnly.Count -gt 0 -and @($safeOnly | Where-Object Preset -NE 'safe').Count -eq 0) "preset filter safe ($($safeOnly.Count) rows)"
    $cat = ($rows | Select-Object -First 1).Category
    $byCat = Select-TweakRows -Rows $rows -Category $cat
    Assert-That ($byCat.Count -gt 0 -and @($byCat | Where-Object Category -NE $cat).Count -eq 0) "category filter '$cat' ($($byCat.Count) rows)"
    $search = Select-TweakRows -Rows $rows -Search 'telemetry'
    Assert-That ($search.Count -gt 0) "search 'telemetry' ($($search.Count) rows)"
    $notApplied = Select-TweakRows -Rows $rows -Status 'NotApplied'
    Assert-That (@($notApplied | Where-Object Status -NE 'NotApplied').Count -eq 0) "status filter NotApplied ($($notApplied.Count) rows)"
    $byName = Select-TweakRows -Rows $rows -SortBy Name -GroupBy None
    Assert-That ($byName.Count -eq $rows.Count) 'sort by name / no grouping'

    Set-RecommendedSelection $rows
    $rec = @($rows | Where-Object Checked)
    Write-Output ''
    Write-Output ("Select recommended: {0} tweaks checked" -f $rec.Count)
    $recBad = @($rec | Where-Object { $_.Preset -ne 'safe' -or $_.Eff -lt 2 -or $_.EvidenceQuality -eq 'none' -or $_.IsUnverified -or $_.Status -eq 'Applied' })
    Assert-That ($recBad.Count -eq 0) 'recommended set respects every rule'
    foreach ($r in $rec) { Write-Output ("  - {0} (eff {1}, {2}, {3})" -f $r.Id, $r.Eff, $r.EvidenceQuality, $r.Status) }
    Clear-Selection $rows
    Assert-That (@($rows | Where-Object Checked).Count -eq 0) 'Clear unchecks everything'

    # 5. Detail text for every row (exercises the catalog join)
    $detailOk = $true
    foreach ($r in $rows) {
        try {
            $impl = Format-ImplStep $r.Data.implementation
            $rev = Format-RevertText (Get-Prop $r.Data 'revert' $null)
            if (-not $impl -or -not $rev) { $detailOk = $false }
        } catch { $detailOk = $false; Write-Output "    detail failed for $($r.Id): $($_.Exception.Message)" }
    }
    Assert-That $detailOk 'implementation / revert text builds for every tweak'

    # 5b. Code paths the happy-path checks above do not reach
    $detailUiOk = $true
    foreach ($r in $rows) { try { Show-Detail $r } catch { $detailUiOk = $false; Write-Output "    Show-Detail failed for $($r.Id): $($_.Exception.Message)" } }
    try { Show-Detail $null } catch { $detailUiOk = $false }
    Assert-That ($detailUiOk) 'Show-Detail builds the detail pane for every row'
    Assert-That ($null -ne (Get-Command Show-PlanDialog -ErrorAction SilentlyContinue)) 'Show-PlanDialog is defined (modal dialog itself not opened in a self-test)'

    $threw = $false; try { $null = New-EngineCommandText -EngineArgs @('-WhatIf') -Ids @("a';calc") } catch { $threw = $true }
    Assert-That $threw 'New-EngineCommandText refuses a suspicious tweak id'
    $cmdText = New-EngineCommandText -EngineArgs @('-WhatIf') -Ids @('x-y') -PassSid
    Assert-That ($cmdText -match '-ExpectedSid ''S-1-') 'elevated command passes -ExpectedSid'
    $cmdText = New-EngineCommandText -EngineArgs @('-WhatIf')
    Assert-That (($cmdText -match '-CatalogPath') -eq ([IO.Path]::GetFullPath($CatalogPath) -ne [IO.Path]::GetFullPath($script:DefaultCatalogPath))) '-CatalogPath is forwarded to the engine only when it is not the default'

    $first = $rows | Where-Object { $_.CanCheck } | Select-Object -First 1
    if ($first) {
        $p = Invoke-EngineSync -EngineArgs @('-WhatIf', '-AsJson', '-IncludeUnverified') -Ids @($first.Id)
        Assert-That ($p.ExitCode -eq 0) "preview path: engine -WhatIf -AsJson -Only $($first.Id) exit 0 (got $($p.ExitCode))"
        $plan = @(Read-JsonArray $p.Stdout)
        Assert-That ($plan.Count -gt 0) "preview path: Read-JsonArray returns $($plan.Count) plan step(s) (single-tweak plan)"
        Assert-That ($p.Stdout -notmatch 'WARNING') 'preview path: stdout is pure JSON (warnings go to stderr)'
        Assert-That (@($plan | Where-Object { $_.tweakId -ne $first.Id }).Count -eq 0) 'preview path: plan only contains the requested tweak'
    }
    $nonSafe = $rows | Where-Object { $_.Preset -ne 'safe' } | Select-Object -First 1
    if ($nonSafe) {
        $p = Invoke-EngineSync -EngineArgs @('-WhatIf', '-AsJson') -Ids @($nonSafe.Id)
        Assert-That ($p.ExitCode -eq 1) "engine refuses -Only with a non-safe id (exit 1, got $($p.ExitCode))"
    }

    # 5c. Catalog rules (what the GUI promises: 'safe' is reversible, scores match the evidence)
    $ruleBad = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rows) {
        $d = $r.Data
        if ($r.Preset -eq 'safe') {
            $steps = @(Get-ImplLeafSteps (Get-Prop $d 'implementation' $null))
            if (@($steps | Where-Object { (Get-Prop $_ 'type' '') -eq 'appx' }).Count) { $ruleBad.Add("$($r.Id): safe tweak has an appx step") }
            $rv = Get-Prop $d 'revert' $null
            if ($rv -is [string] -and $rv -match 'not reversible') { $ruleBad.Add("$($r.Id): safe tweak is not reversible") }
        }
        $me = [string](Get-Prop $d 'measuredEffect' '')
        if ($me -match '^\s*not measured' -and $r.Eff -gt 1 -and $me -notmatch '\d') { $ruleBad.Add("$($r.Id): effectiveness $($r.Eff) but 'not measured'") }
    }
    foreach ($b in $ruleBad) { Write-Output "    rule: $b" }
    Assert-That ($ruleBad.Count -eq 0) 'catalog rules: no irreversible safe tweaks; unmeasured tweaks score at most 1'

    # 6. Top 10
    Write-Output ''
    Write-Output 'Top 10 by effectiveness:'
    $i = 0
    foreach ($r in (Select-TweakRows -Rows $rows -GroupBy None)) {
        $i++; if ($i -gt 10) { break }
        Write-Output ('  {0,2}. [{1}/5] {2,-42} {3,-6} {4,-10} {5}' -f $i, $r.Eff, $r.Id, $r.EvidenceQuality, $r.Status, $r.Preset)
    }

    Write-Output ''
    if ($fail.Count -gt 0) { Write-Output "SELFTEST FAILED: $($fail.Count) check(s) failed"; $script:SelfTestCode = 1; return }
    Write-Output 'SELFTEST PASSED'
    $script:SelfTestCode = 0
}

#endregion

#region GUI -------------------------------------------------------------------

$script:Window = Read-Xaml $script:MainXaml
function Get-Ctl([string]$Name) { $script:Window.FindName($Name) }
$script:Rows = $null
$script:Managed = $null
$script:Busy = $false
$script:Loading = $false
$script:Job = $null
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)

function New-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Set-Status([string]$Text) { (Get-Ctl 'txtStatus').Text = $Text }

function Set-Busy([bool]$Busy, [string]$Text = 'Loading...') {
    $script:Busy = $Busy
    (Get-Ctl 'loadingOverlay').Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
    (Get-Ctl 'txtLoading').Text = $Text
    foreach ($b in 'btnRecommended', 'btnClear', 'btnPreview', 'btnApply', 'btnUndo', 'btnRefresh') { (Get-Ctl $b).IsEnabled = -not $Busy }
}

function Update-Counts {
    if (-not $script:Rows) { return }
    $checked = @($script:Rows | Where-Object Checked)
    $unv = @($checked | Where-Object IsUnverified).Count
    $txt = "$($checked.Count) selected"
    if ($unv) { $txt += " ($unv unverified)" }
    (Get-Ctl 'txtSelected').Text = $txt
}

function Get-FilterValue([string]$Name) {
    $v = (Get-Ctl $Name).SelectedItem
    if ($null -eq $v) { 'All' } else { [string]$v }
}

function New-GridView($Items) {
    $list = New-Object System.Collections.ArrayList
    foreach ($i in $Items) { [void]$list.Add($i) }
    $view = New-Object System.Windows.Data.ListCollectionView -ArgumentList (,$list)
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('GroupLabel')))
    ,$view
}

function Update-Grid {
    if ($script:Loading -or -not $script:Rows) { return }
    $grp = [string](Get-Ctl 'cmbGroup').SelectedItem; if (-not $grp) { $grp = 'Effectiveness' }
    $srt = [string](Get-Ctl 'cmbSort').SelectedItem; if (-not $srt) { $srt = 'Effectiveness' }
    $items = Select-TweakRows -Rows $script:Rows -Search (Get-Ctl 'txtSearch').Text -Category (Get-FilterValue 'cmbCategory') `
        -Preset (Get-FilterValue 'cmbPreset') -Risk (Get-FilterValue 'cmbRisk') -Status (Get-FilterValue 'cmbStatus') `
        -OnlyProven ([bool](Get-Ctl 'chkProven').IsChecked) -GroupBy $grp -SortBy $srt
    (Get-Ctl 'grid').ItemsSource = New-GridView $items
    $hiddenChecked = @($script:Rows | Where-Object { $_.Checked -and $items -notcontains $_ }).Count
    $msg = "Showing $($items.Count) of $($script:Rows.Count) tweaks."
    if ($hiddenChecked) { $msg += " $hiddenChecked selected tweak(s) are hidden by the filters." }
    Set-Status $msg
    Update-Counts
}

function Add-Combo([string]$Name, [string[]]$Values, [string]$Selected) {
    $c = Get-Ctl $Name
    $c.Items.Clear()
    foreach ($v in $Values) { [void]$c.Items.Add($v) }
    $c.SelectedItem = $Selected
    if ($null -eq $c.SelectedItem -and $c.Items.Count) { $c.SelectedIndex = 0 }
}

function Update-Banner {
    $m = $script:Managed
    $banner = Get-Ctl 'bannerManaged'; $txt = Get-Ctl 'txtManaged'
    if ($m -and $m.isManaged) {
        $parts = @()
        if ($m.azureAdJoined) { $parts += 'Entra ID joined' }
        if ($m.domainJoined) { $parts += 'domain joined' }
        if ($m.mdmEnrolled) { $parts += 'MDM enrolled' }
        $t = 'MANAGED DEVICE: ' + ($parts -join ', ')
        if ($m.tenant) { $t += ' (tenant: ' + $m.tenant + ')' }
        $t += '. Policy keys may conflict with your organisation''s settings; update and time-sync tweaks are always skipped. Check with your IT admin before applying.'
        $txt.Text = $t
        $banner.Background = New-Brush '#FFF3E0'; $banner.BorderBrush = New-Brush '#FFB74D'
        (Get-Ctl 'chkManaged').Visibility = 'Visible'
    } elseif ($m) {
        $txt.Text = 'This device does not look managed (not Entra ID joined, domain joined or MDM enrolled).'
        $banner.Background = New-Brush '#E8F5E9'; $banner.BorderBrush = New-Brush '#C8E6C9'
        (Get-Ctl 'chkManaged').Visibility = 'Collapsed'
    }
    $el = Get-Ctl 'txtElevation'
    if (Test-Elevated) { $el.Text = 'Elevated: yes'; $el.Foreground = New-Brush '#2E7D32' }
    else { $el.Text = 'Elevated: no (UAC prompt when applying or undoing)'; $el.Foreground = New-Brush '#B26A00' }
}

function Load-Data {
    if ($script:Busy) { return }
    $script:Loading = $true
    Set-Busy $true 'Loading tweaks from the engine...'
    Set-Status 'Running the engine (-List -AsJson -IncludeUnverified)...'
    try {
        $h = Start-EngineProcess -EngineArgs @('-List', '-AsJson', '-IncludeUnverified')
    } catch {
        Set-Busy $false; $script:Loading = $false
        Set-Status "Could not start the engine: $($_.Exception.Message)"
        return
    }
    $script:Job = @{ Handle = $h; OnDone = {
        param($res)
        try {
            $eng = Get-EngineList $res
            $catalog = (Read-JsonArray (Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8))
            $script:Managed = $eng.Managed
            $oldChecked = @{}
            if ($script:Rows) { foreach ($r in $script:Rows) { if ($r.Checked) { $oldChecked[$r.Id] = $true } } }
            $script:Rows = New-TweakRows -Catalog $catalog -EngineTweaks $eng.Tweaks
            foreach ($r in $script:Rows) { if ($oldChecked.ContainsKey($r.Id) -and $r.CanCheck -and $r.Status -ne 'Applied') { $r.Checked = $true } }
            $cats = @('All') + @($script:Rows | ForEach-Object { $_.Category } | Sort-Object -Unique)
            $presets = @('All') + @($script:Rows | ForEach-Object { $_.Preset } | Sort-Object -Unique)
            $risks = @('All') + @($script:Rows | ForEach-Object { $_.Risk } | Sort-Object -Unique)
            Add-Combo 'cmbCategory' $cats (Get-FilterValue 'cmbCategory')
            Add-Combo 'cmbPreset' $presets (Get-FilterValue 'cmbPreset')
            Add-Combo 'cmbRisk' $risks (Get-FilterValue 'cmbRisk')
            Update-Banner
            $script:Loading = $false
            Update-Grid
        } catch {
            $script:Loading = $false
            Set-Status "Loading failed: $($_.Exception.Message)"
            [void][System.Windows.MessageBox]::Show($script:Window, "Could not load the tweak list.`n`n$($_.Exception.Message)", 'DebloatKit', 'OK', 'Error')
        } finally {
            $script:Loading = $false
            Set-Busy $false
        }
    } }
    $script:Timer.Start()
}

$script:Timer.Add_Tick({
    if (-not $script:Job) { $script:Timer.Stop(); return }
    $p = $script:Job.Handle.Process
    if (-not $p.HasExited) { return }
    $script:Timer.Stop()
    $job = $script:Job; $script:Job = $null
    $res = Read-EngineResult $job.Handle
    try { & $job.OnDone $res }
    catch { Set-Busy $false; Set-Status "Error: $($_.Exception.Message)" }
})

function Start-Job-Async($Handle, [scriptblock]$OnDone) {
    $script:Job = @{ Handle = $Handle; OnDone = $OnDone }
    $script:Timer.Start()
}

# ---- detail pane ----
function Add-DetailText($Panel, [string]$Title, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Title.ToUpperInvariant(); $h.FontWeight = 'Bold'; $h.FontSize = 11.5
    $h.Foreground = New-Brush '#546E7A'; $h.Margin = '0,14,0,3'
    [void]$Panel.Children.Add($h)
    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = $Text; $b.TextWrapping = 'Wrap'; $b.Foreground = New-Brush '#263238'
    [void]$Panel.Children.Add($b)
}

function Add-Badge($Panel, [string]$Text, [string]$Color) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.Background = New-Brush $Color; $bd.CornerRadius = 3; $bd.Padding = '7,2'; $bd.Margin = '0,0,6,4'
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.Foreground = [System.Windows.Media.Brushes]::White; $tb.FontSize = 11.5
    $bd.Child = $tb
    [void]$Panel.Children.Add($bd)
}

function Show-Detail($Row) {
    $panel = Get-Ctl 'detailPanel'
    $panel.Children.Clear()
    if (-not $Row) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = 'Select a tweak to see what it does.'; $t.Foreground = New-Brush '#78909C'
        [void]$panel.Children.Add($t); return
    }
    $d = $Row.Data
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $Row.Description; $title.FontSize = 16; $title.FontWeight = 'Bold'; $title.TextWrapping = 'Wrap'
    [void]$panel.Children.Add($title)
    $idt = New-Object System.Windows.Controls.TextBlock
    $idt.Text = $Row.Id + '   |   ' + $Row.Category; $idt.Foreground = New-Brush '#78909C'; $idt.FontSize = 11.5; $idt.Margin = '0,2,0,8'; $idt.TextWrapping = 'Wrap'
    [void]$panel.Children.Add($idt)

    $badges = New-Object System.Windows.Controls.WrapPanel
    Add-Badge $badges ("effectiveness {0}/5 {1}" -f $Row.Eff, $Row.Stars) '#F9A825'
    Add-Badge $badges ("evidence: " + $Row.EvidenceQuality) $Row.EvColor
    Add-Badge $badges ("preset: " + $Row.Preset) $Row.PresetColor
    Add-Badge $badges ("risk: " + $Row.Risk) $Row.RiskColor
    Add-Badge $badges ("status: " + $Row.Status) $Row.StatusColor
    if ($Row.IsUnverified) { Add-Badge $badges 'unverified' '#7B1FA2' }
    [void]$panel.Children.Add($badges)

    if ($Row.IsUnverified) {
        Add-DetailText $panel 'Warning' 'This tweak was added from fresh research and has not been tested on a real machine. Try it in a VM first. It is unchecked by default; the engine only runs it because the GUI passes -IncludeUnverified when you select one.'
    } elseif ($Row.Verification -and $Row.Verification -ne 'from-notes') {
        Add-DetailText $panel 'Verification note' ("Catalog verification: " + $Row.Verification + ' (some values or paths were inferred rather than checked against a source project).')
    }
    if ($Row.Preset -ne 'safe') { Add-DetailText $panel 'Availability' 'Preset not enabled in this version. The engine refuses to run it; shown for information only.' }
    if ($Row.Note -and $Row.Preset -eq 'safe') { Add-DetailText $panel 'Engine note' $Row.Note }

    Add-DetailText $panel 'What it does' ([string](Get-Prop $d 'explanation' ''))
    Add-DetailText $panel 'Measured effect' ([string](Get-Prop $d 'measuredEffect' 'Not measured.'))
    Add-DetailText $panel 'Who benefits' ([string](Get-Prop $d 'whoBenefits' ''))
    Add-DetailText $panel 'Trade-off' ([string](Get-Prop $d 'tradeoff' ''))
    $breaks = Get-Prop $d 'breaks' $null
    Add-DetailText $panel 'What it can break' $(if ($breaks) { [string]$breaks } else { 'Nothing documented.' })
    $mdi = Get-Prop $d 'managedDeviceImpact' $null
    if ($mdi) { Add-DetailText $panel 'On a managed (Intune / Entra) device' ([string]$mdi) }
    $red = Get-Prop $d 'redundantWith' $null
    if ($red) { Add-DetailText $panel 'Redundant with' ("Not needed if '$red' is applied.") }
    if ((Get-Prop $d 'policyDocumented' $false) -eq $true) { Add-DetailText $panel 'Documentation' 'The policy or setting is documented by Microsoft. That says it exists, not that it has a measurable effect.' }
    $nt = Get-Prop $d 'notes' $null
    if ($nt) { Add-DetailText $panel 'Catalog note' ([string]$nt) }
    $ram = Get-Prop $d 'ram_or_perf_effect' $null
    if ($ram) { Add-DetailText $panel 'Catalog note on performance / RAM' ([string]$ram) }

    $steps = @(Format-ImplStep (Get-Prop $d 'implementation' $null))
    Add-DetailText $panel 'Exact changes (implementation steps)' (($steps | ForEach-Object { '- ' + $_ }) -join "`n")
    Add-DetailText $panel 'How it is reverted' ((Format-RevertText (Get-Prop $d 'revert' $null)) + "`nThe engine saves a snapshot before every step; 'Undo last run' replays it in reverse.")

    $links = @(Get-Prop $d 'evidence' @())
    if ($links.Count) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = 'EVIDENCE LINKS'; $h.FontWeight = 'Bold'; $h.FontSize = 11.5; $h.Foreground = New-Brush '#546E7A'; $h.Margin = '0,14,0,3'
        [void]$panel.Children.Add($h)
        foreach ($u in $links) {
            $uri = $null
            if (-not [Uri]::TryCreate([string]$u, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https') { continue }
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,0,0,3'
            $hl = New-Object System.Windows.Documents.Hyperlink
            $hl.NavigateUri = $uri
            [void]$hl.Inlines.Add($uri.Host + $uri.AbsolutePath)
            $hl.ToolTip = $uri.AbsoluteUri
            $hl.Add_RequestNavigate({ param($s, $e) try { Start-Process -FilePath $e.Uri.AbsoluteUri } catch { } ; $e.Handled = $true })
            [void]$tb.Inlines.Add($hl)
            [void]$panel.Children.Add($tb)
        }
    }
}

# ---- dialogs ----
function Show-TextDialog([string]$Title, [string]$Head, [string]$Body) {
    $w = Read-Xaml $script:TextXaml
    $w.Title = $Title; $w.Owner = $script:Window
    $w.FindName('txtHead').Text = $Head
    $w.FindName('txtBody').Text = $Body
    $w.FindName('btnClose').Add_Click({ $w.Close() }.GetNewClosure())
    [void]$w.ShowDialog()
}

function Show-PlanDialog($Plan) {
    $w = Read-Xaml $script:PlanXaml
    $w.Owner = $script:Window
    $items = @($Plan | Where-Object { $_.action -ne 'InSync' })
    $change = @($Plan | Where-Object action -EQ 'Change').Count
    $sync = @($Plan | Where-Object action -EQ 'InSync').Count
    $skip = @($Plan | Where-Object action -EQ 'Skip').Count
    $w.FindName('txtSummary').Text = "Preview (nothing was changed): $change step(s) would change, $sync already in effect, $skip skipped. Steps already in effect are hidden."
    $w.FindName('planGrid').ItemsSource = $items
    $w.FindName('btnClose').Add_Click({ $w.Close() }.GetNewClosure())
    [void]$w.ShowDialog()
}

function Get-CheckedRows { @($script:Rows | Where-Object Checked) }

function Confirm-Action([string]$Text, [string]$Title) {
    $r = [System.Windows.MessageBox]::Show($script:Window, $Text, $Title, 'YesNo', 'Warning', 'No')
    $r -eq 'Yes'
}

# ---- buttons ----
function Invoke-Preview {
    $sel = Get-CheckedRows
    if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($script:Window, 'Tick at least one tweak first.', 'Preview', 'OK', 'Information'); return }
    $ids = @($sel | ForEach-Object { $_.Id })
    $args2 = @('-WhatIf', '-AsJson')
    if (@($sel | Where-Object IsUnverified).Count) { $args2 += '-IncludeUnverified' }
    Set-Busy $true 'Building preview (engine -WhatIf)...'
    try { $h = Start-EngineProcess -EngineArgs $args2 -Ids $ids } catch { Set-Busy $false; Set-Status "Preview failed: $($_.Exception.Message)"; return }
    Start-Job-Async $h {
        param($res)
        Set-Busy $false
        try {
            if ($res.ExitCode -ne 0) { throw "Engine exit code $($res.ExitCode). $($res.Stderr) $($res.Stdout)" }
            $plan = (Read-JsonArray $res.Stdout)
            Show-PlanDialog $plan
        } catch { [void][System.Windows.MessageBox]::Show($script:Window, "Preview failed.`n`n$($_.Exception.Message)", 'Preview', 'OK', 'Error') }
    }
}

function Show-RunResult([string]$Title, $Proc, $Log) {
    $code = $Proc.ExitCode
    $meaning = switch ($code) { 0 { 'success' } 1 { 'engine refused or failed before changing anything' } 2 { 'finished, but at least one step failed' } default { 'unexpected' } }
    $head = "$Title finished. Exit code: $code ($meaning). Log folder: $env:ProgramData\DebloatKit"
    $body = if ($Log) { $Log }
    elseif ($code -eq 1) { "(the engine exited with code 1 without writing any output.`nCommon causes: System Protection is off so the restore point could not be created; there is no snapshot to undo; the device is managed and the confirmation box was not ticked; the UAC prompt ran as a different user.`nCheck $env:ProgramData\DebloatKit for run-*.log.jsonl, or run DebloatKit.ps1 -WhatIf in an elevated PowerShell to see the reason.)" }
    else { '(no output captured; the elevated window may have been closed early)' }
    Show-TextDialog $Title $head $body
}

function Invoke-ElevatedRun([string]$Title, [string[]]$EngineArgs, [string[]]$Ids) {
    Set-Busy $true "$Title running in an elevated window..."
    Set-Status "${Title}: waiting for the elevated engine process (accept the UAC prompt)..."
    try { $h = Start-EngineProcess -EngineArgs $EngineArgs -Ids $Ids -Elevated }
    catch {
        Set-Busy $false
        Set-Status "$Title cancelled or failed to start: $($_.Exception.Message)"
        [void][System.Windows.MessageBox]::Show($script:Window, "Could not start the elevated engine (UAC declined?).`n`n$($_.Exception.Message)", $Title, 'OK', 'Warning')
        return
    }
    $t = $Title
    Start-Job-Async $h ({
        param($res)
        Set-Busy $false
        $fake = [pscustomobject]@{ ExitCode = $res.ExitCode }
        Show-RunResult $t $fake $res.Log
        Set-Status "$t finished with exit code $($res.ExitCode). Refreshing..."
        Load-Data
    }.GetNewClosure())
}

function Invoke-Apply {
    $sel = Get-CheckedRows
    if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($script:Window, 'Tick at least one tweak first.', 'Apply', 'OK', 'Information'); return }
    $isManaged = ($script:Managed -and $script:Managed.isManaged)
    $ack = [bool](Get-Ctl 'chkManaged').IsChecked
    if ($isManaged -and -not $ack) {
        [void][System.Windows.MessageBox]::Show($script:Window, "This is a managed device. Tick 'I understand this is a managed device' before applying (the engine otherwise refuses).", 'Apply', 'OK', 'Warning')
        return
    }
    $unv = @($sel | Where-Object IsUnverified)
    $ids = @($sel | ForEach-Object { $_.Id })
    $lines = ($ids | Select-Object -First 30 | ForEach-Object { '  - ' + $_ }) -join "`n"
    if ($ids.Count -gt 30) { $lines += "`n  ... and $($ids.Count - 30) more" }
    $msg = "Apply $($ids.Count) tweak(s) with the DebloatKit engine?`n`n$lines`n`n"
    $msg += "A system restore point is created first (the run aborts if that fails), and a snapshot is saved to $env:ProgramData\DebloatKit so 'Undo last run' can restore the exact previous values.`n"
    if ($unv.Count) { $msg += "`nWARNING: $($unv.Count) selected tweak(s) are UNVERIFIED (never tested on a real machine): $(($unv | ForEach-Object { $_.Id }) -join ', ')`n" }
    if ($isManaged) { $msg += "`nWARNING: managed device. This run passes -Force and may conflict with your organisation's policy.`n" }
    if (-not (Test-Elevated) -and -not (Test-InAdminGroup)) { $msg += "`nWARNING: you are not a local administrator, so the UAC prompt will ask for another admin's credentials. Per-user (HKCU) tweaks would then be written to that admin's profile. The engine detects this and refuses to apply them, but the rest of the run is unaffected.`n" }
    $msg += "`nA UAC prompt follows. Continue?"
    if (-not (Confirm-Action $msg 'Confirm apply')) { Set-Status 'Apply cancelled.'; return }
    $a = @()
    if ($isManaged -and $ack) { $a += '-Force' }
    (Get-Ctl 'chkManaged').IsChecked = $false   # the opt-in is per run
    if ($unv.Count) { $a += '-IncludeUnverified' }
    Invoke-ElevatedRun 'Apply' $a $ids
}

function Invoke-Undo {
    $msg = "Undo the last DebloatKit run?`n`nThe engine restores the values saved in the newest snapshot in $env:ProgramData\DebloatKit (it does not reset to Windows defaults). A UAC prompt follows."
    if (-not (Confirm-Action $msg 'Confirm undo')) { Set-Status 'Undo cancelled.'; return }
    Invoke-ElevatedRun 'Undo' @('-Undo', 'latest') $null
}

if ($SelfTest) {
    $script:SelfTestCode = 1
    try { Invoke-SelfTest } catch { Write-Output "SELFTEST FAILED: $($_.Exception.Message)"; Write-Output $_.ScriptStackTrace; $script:SelfTestCode = 1 }
    exit $script:SelfTestCode
}

(Get-Ctl 'btnRecommended').Add_Click({ if (-not $script:Rows) { return }; Set-RecommendedSelection $script:Rows; Update-Grid; Update-Counts })
(Get-Ctl 'btnClear').Add_Click({ if (-not $script:Rows) { return }; Clear-Selection $script:Rows; Update-Grid; Update-Counts })
(Get-Ctl 'btnPreview').Add_Click({ Invoke-Preview })
(Get-Ctl 'btnApply').Add_Click({ Invoke-Apply })
(Get-Ctl 'btnUndo').Add_Click({ Invoke-Undo })
(Get-Ctl 'btnRefresh').Add_Click({ Load-Data })
(Get-Ctl 'btnLogs').Add_Click({
    $dir = Join-Path $env:ProgramData 'DebloatKit'
    if (Test-Path -LiteralPath $dir) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"') }
    else { [void][System.Windows.MessageBox]::Show($script:Window, "No log folder yet ($dir). It is created by the first apply.", 'DebloatKit', 'OK', 'Information') }
})
(Get-Ctl 'btnResetFilters').Add_Click({
    $script:Loading = $true
    (Get-Ctl 'txtSearch').Text = ''
    foreach ($c in 'cmbCategory', 'cmbPreset', 'cmbRisk', 'cmbStatus') { (Get-Ctl $c).SelectedIndex = 0 }
    (Get-Ctl 'chkProven').IsChecked = $false
    (Get-Ctl 'cmbGroup').SelectedItem = 'Effectiveness'; (Get-Ctl 'cmbSort').SelectedItem = 'Effectiveness'
    $script:Loading = $false
    Update-Grid
})

(Get-Ctl 'txtSearch').Add_TextChanged({ Update-Grid })
foreach ($c in 'cmbCategory', 'cmbPreset', 'cmbRisk', 'cmbStatus', 'cmbGroup', 'cmbSort') { (Get-Ctl $c).Add_SelectionChanged({ Update-Grid }) }
(Get-Ctl 'chkProven').Add_Click({ Update-Grid })
(Get-Ctl 'grid').Add_SelectionChanged({ Show-Detail ((Get-Ctl 'grid').SelectedItem) })

$script:Loading = $true
Add-Combo 'cmbStatus' @('All', 'Applied', 'NotApplied', 'Partial', 'Skipped') 'All'
Add-Combo 'cmbCategory' @('All') 'All'
Add-Combo 'cmbPreset' @('All') 'All'
Add-Combo 'cmbRisk' @('All') 'All'
Add-Combo 'cmbGroup' @('Effectiveness', 'Category', 'Risk', 'Status', 'None') 'Effectiveness'
Add-Combo 'cmbSort' @('Effectiveness', 'Name', 'Category', 'Risk', 'Status') 'Effectiveness'
$script:Loading = $false
Update-Banner

[DebloatKitGui.TweakRow]::SelectionChanged = [Action]{ Update-Counts }

$script:Window.Add_ContentRendered({
    if (-not $script:Rows -and -not $script:Busy) { Load-Data }
})
[void]$script:Window.ShowDialog()

#endregion
