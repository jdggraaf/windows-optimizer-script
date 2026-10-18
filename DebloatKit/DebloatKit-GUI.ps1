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

.PARAMETER StateDir
    For tests only. Passed to every engine call (-StateDir) so snapshots are read from, and written to, this folder.

.PARAMETER TestEnvironment
    For tests only. Passed to every engine call (-TestEnvironment). Together with -SelfTest it runs the sandbox
    self-test instead of the normal one: revert, drift and re-apply command paths against the fake state in that file.

.PARAMETER ProfilesPath
    For tests only. Passed to every engine call (-ProfilesPath), the AppX profiles file.

.PARAMETER SetupProfilesPath
    Path to profiles.json, the setup profiles and questions of the Profiles tab (default: next to this script).

.PARAMETER FootprintScriptPath
    Path to Get-FootprintReport.ps1 (default: next to this script).

.PARAMETER FootprintDir
    Folder for the footprint report files (default: %LOCALAPPDATA%\DebloatKit). Created only when something is saved: by
    the Save as baseline button, and by an elevated Apply / Revert / Undo / Re-apply, which first saves "before the last
    run". Never under %ProgramData%.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$EnginePath,
    [string]$CatalogPath,
    [string]$StateDir,
    [string]$TestEnvironment,
    [string]$ProfilesPath,
    [string]$SetupProfilesPath,
    [string]$FootprintScriptPath,
    [string]$FootprintDir
)

$ErrorActionPreference = 'Stop'
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }
$script:ScriptDir = Split-Path -Parent $script:ScriptPath
if (-not $EnginePath) { $EnginePath = Join-Path $script:ScriptDir 'DebloatKit.ps1' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $script:ScriptDir 'tweak-catalog.json' }
if (-not $SetupProfilesPath) { $SetupProfilesPath = Join-Path $script:ScriptDir 'profiles.json' }
if (-not $FootprintScriptPath) { $FootprintScriptPath = Join-Path $script:ScriptDir 'Get-FootprintReport.ps1' }
if (-not $FootprintDir) { $FootprintDir = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }) 'DebloatKit' }
$script:DefaultCatalogPath = Join-Path $script:ScriptDir 'tweak-catalog.json'
$script:HostExe = (Get-Process -Id $PID).Path

# ---- STA relaunch (WPF needs a single-threaded apartment) ----
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $script:ScriptPath)
    if ($SelfTest) { $relaunch += '-SelfTest' }
    foreach ($pn in 'EnginePath', 'CatalogPath', 'StateDir', 'TestEnvironment', 'ProfilesPath', 'SetupProfilesPath', 'FootprintScriptPath', 'FootprintDir') {
        if ($PSBoundParameters.ContainsKey($pn)) { $relaunch += @("-$pn", [string](Get-Variable -Name $pn -ValueOnly)) }
    }
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
        public bool Tracked { get; set; }
        public string ToggleLabel { get; set; }
        public bool CanToggle { get; set; }
        public bool HasToggle { get; set; }
        public string ToggleTip { get; set; }
        public string StatusDetail { get; set; }
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

function Read-CatalogFile([string]$Path) {
    # Catalog v1 is a bare JSON array of tweaks; v2 is { schemaVersion, migrations, tweaks }. Both give the tweak list.
    $items = @((Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
    if ($items.Count -eq 1 -and $items[0].PSObject.Properties.Name -contains 'tweaks') { return @($items[0].tweaks | ForEach-Object { $_ }) }
    $items
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
    # $EngineArgs: tokens such as '-List','-AsJson'. $Ids becomes -Only @('a','b'), or -Revert @('a','b') with -IdSwitch '-Revert'.
    # -Tool builds the command for another script (-ScriptPath, e.g. Get-FootprintReport.ps1): none of the engine-only
    # parameters (-CatalogPath, -StateDir, -ExpectedSid ...) are added then.
    param([string[]]$EngineArgs, [string[]]$Ids, [ValidateSet('-Only', '-Revert')][string]$IdSwitch = '-Only', [string]$LogPath, [switch]$PassSid, [switch]$Tool, [string]$ScriptPath)
    $targetPath = if ($Tool) { $ScriptPath } else { $EnginePath }
    $line = "& '" + $targetPath.Replace("'", "''") + "'"
    if ($EngineArgs) { $line += ' ' + ($EngineArgs -join ' ') }
    if (-not $Tool) {
        # The engine must read the same catalog the grid shows.
        if ([IO.Path]::GetFullPath($CatalogPath) -ne [IO.Path]::GetFullPath($script:DefaultCatalogPath)) {
            $line += " -CatalogPath '" + ([IO.Path]::GetFullPath($CatalogPath).Replace("'", "''")) + "'"
        }
        # Test-only pass-through so the self-test can run the engine against a throwaway state folder and a fake environment.
        foreach ($pair in @(@('StateDir', $StateDir), @('TestEnvironment', $TestEnvironment), @('ProfilesPath', $ProfilesPath))) {
            if ($pair[1]) { $line += " -$($pair[0]) '" + ([IO.Path]::GetFullPath($pair[1]).Replace("'", "''")) + "'" }
        }
        if ($PassSid) { $line += " -ExpectedSid '" + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + "'" }
    }
    if ($Ids) {
        foreach ($i in $Ids) { if (-not (Test-TweakId $i)) { throw "Refusing suspicious tweak id: $i" } }
        $line += " $IdSwitch @(" + (($Ids | ForEach-Object { "'$_'" }) -join ',') + ')'
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
    param([string[]]$EngineArgs, [string[]]$Ids, [switch]$Elevated, [string]$IdSwitch = '-Only', [string]$ScriptPath)
    $tag = [guid]::NewGuid().ToString('N')
    $h = [pscustomobject]@{ Process = $null; Out = $null; Err = $null; Log = $null; Elevated = [bool]$Elevated }
    if ($Elevated) { $h.Log = Join-Path $env:TEMP "DebloatKit-gui-$tag.log" }
    # -ScriptPath runs another tool (the footprint report) instead of the engine; engine-only parameters are then left out.
    if ($ScriptPath) { $cmd = New-EngineCommandText -EngineArgs $EngineArgs -LogPath $h.Log -Tool -ScriptPath $ScriptPath }
    else { $cmd = New-EngineCommandText -EngineArgs $EngineArgs -Ids $Ids -IdSwitch $IdSwitch -LogPath $h.Log -PassSid:$Elevated }
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
    param([string[]]$EngineArgs, [string[]]$Ids, [string]$IdSwitch = '-Only', [string]$ScriptPath)
    $h = Start-EngineProcess -EngineArgs $EngineArgs -Ids $Ids -IdSwitch $IdSwitch -ScriptPath $ScriptPath
    $h.Process.WaitForExit()
    Read-EngineResult $h
}

function Get-EngineList {
    # Returns @{ Managed; Tweaks } from: engine -List -AsJson -IncludeUnverified
    param($Result)
    if ($Result.ExitCode -ne 0) { throw "Engine -List failed (exit $($Result.ExitCode)): $($Result.Stderr) $($Result.Stdout)" }
    $doc = $Result.Stdout | ConvertFrom-Json
    if (-not $doc -or -not $doc.PSObject.Properties['tweaks']) { throw 'Engine -List returned no tweaks array.' }
    [pscustomobject]@{ Managed = $doc.managed; Tweaks = @($doc.tweaks); Warnings = $Result.Stderr; Os = (Get-Prop $doc 'os' $null); Preflight = (Get-Prop $doc 'preflight' $null) }
}

function Format-PreflightText($Pf, $Os) {
    # One banner line: Windows build plus the preflight verdict. Pure function (used by the self-test).
    $parts = @()
    if ($Os -and (Get-Prop $Os 'buildFull' '')) { $parts += ('Windows build {0} ({1}, {2})' -f $Os.buildFull, (Get-Prop $Os 'editionId' '?'), ([string](Get-Prop $Os 'chassis' 'Unknown')).ToLower()) }
    if ($Pf) {
        $bad = @(@(Get-Prop $Pf 'checks' @()) | Where-Object { $_.blocking })
        if ($bad.Count) { $parts += ('Preflight: an apply would be refused. ' + (($bad | ForEach-Object { $_.title + ': ' + $_.detail }) -join ' | ')) }
        else { $parts += 'Preflight: ready to apply.' }
    }
    $parts -join '. '
}

function Measure-PlanWeight($Plan) {
    # Total progress weight of the steps a plan would change (the engine reports a weight per step).
    $sum = 0
    foreach ($p in @($Plan)) { if ((Get-Prop $p 'action' '') -eq 'Change') { $sum += [int](Get-Prop $p 'weight' 0) } }
    $sum
}

function Get-ProgressPercent([string]$LogText) {
    # Last "[progress] NN% - ..." line the engine wrote, or $null.
    $m = [regex]::Matches($LogText, '\[progress\]\s+(\d+)%')
    if ($m.Count -eq 0) { return $null }
    [int]$m[$m.Count - 1].Groups[1].Value
}

function Format-PreflightChecks($Pf) {
    # One line per preflight gate ("[ok] On AC power: ..."), for tooltips and the profile / drift views. Pure function.
    $lines = @()
    foreach ($c in @(Get-Prop $Pf 'checks' @())) {
        $tag = if ($c.blocking) { 'BLOCKED' } else { [string](Get-Prop $c 'status' 'ok') }
        $lines += ('[{0}] {1}: {2}' -f $tag, $c.title, $c.detail)
    }
    $lines -join "`n"
}

function Read-JsonObject([string]$Json, [string]$What) {
    # Parses stdout that must be one JSON object (engine -Drift / -Revert, footprint report). Throws a readable error otherwise.
    if ([string]::IsNullOrWhiteSpace($Json)) { throw "$What returned no output." }
    try { $o = $Json | ConvertFrom-Json } catch { throw "$What did not return JSON: $($_.Exception.Message)" }
    if ($null -eq $o) { throw "$What returned an empty document." }
    $o
}

function ConvertTo-DriftRows($Doc) {
    # Drift document (engine -Drift -AsJson) -> one grid row per tweak. Pure function.
    $rows = @()
    foreach ($t in @(Get-Prop $Doc 'tweaks' @())) {
        $notes = @()
        if (-not (Get-Prop $t 'inCatalog' $true)) { $notes += 'no longer in the catalog' }
        if (Get-Prop $t 'notApplicable' $false) { $notes += 'no longer applicable on this build' }
        if (Get-Prop $t 'buildChanged' $false) { $notes += 'Windows build changed since it was applied' }
        $rows += [pscustomobject]@{
            Id = [string]$t.id; Status = [string]$t.status; DriftedSteps = [int](Get-Prop $t 'driftedSteps' 0)
            Builds = (@(Get-Prop $t 'appliedBuilds' @()) -join ', '); Note = ($notes -join '; '); Steps = @(Get-Prop $t 'steps' @())
            StatusColor = $(switch ([string]$t.status) { 'Drifted' { '#E57373' } 'InSync' { '#81C784' } default { '#9AA0A6' } })
        }
    }
    ,$rows
}

function ConvertTo-DriftStepRows($TweakRow) {
    # The steps of one drift row, with display text for the applied and the current value. Pure function.
    $out = @()
    foreach ($s in @(Get-Prop $TweakRow 'Steps' @())) {
        $txt = { param($v) if ($null -eq $v) { '' } elseif ($v -is [string]) { $v } else { ($v | ConvertTo-Json -Compress -Depth 3) } }
        $out += [pscustomobject]@{ state = [string]$s.state; type = [string]$s.type; target = [string]$s.target
            desiredText = (& $txt (Get-Prop $s 'desired' $null)); currentText = (& $txt (Get-Prop $s 'current' $null)); note = [string](Get-Prop $s 'note' '') }
    }
    ,$out
}

function Format-DriftSummary($Doc) {
    $s = Get-Prop $Doc 'summary' $null
    if (-not $s) { return '' }
    if ([int]$s.tweaks -eq 0) { return ('No tweak has been applied yet (snapshots read: {0}). Drift compares the live state with what DebloatKit applied, so there is nothing to compare.' -f (Get-Prop $Doc 'snapshots' 0)) }
    ('{0} applied tweak(s) in {1} snapshot(s): {2} in effect, {3} drifted ({4} step(s)), {5} could not be compared.' -f $s.tweaks, (Get-Prop $Doc 'snapshots' 0), $s.inSync, $s.drifted, $s.driftedSteps, $s.unknown)
}

function Format-FpBytes($v, [switch]$Signed) {
    if ($null -eq $v) { return 'n/a' }
    $d = [double]$v; $a = [Math]::Abs($d)
    $sign = if ($Signed) { if ($d -gt 0) { '+' } elseif ($d -lt 0) { '-' } else { '' } } elseif ($d -lt 0) { '-' } else { '' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($a -ge 1GB) { return $sign + ($a / 1GB).ToString('0.0', $inv) + ' GB' }
    if ($a -ge 1MB) { return $sign + ($a / 1MB).ToString('0.0', $inv) + ' MB' }
    if ($a -ge 1KB) { return $sign + ($a / 1KB).ToString('0', $inv) + ' KB' }
    $sign + $a.ToString('0', $inv) + ' B'
}

function ConvertTo-FootprintRows($Cmp) {
    # Footprint comparison (Get-FootprintReport.ps1 -Compare -AsJson) -> grid rows with display strings. Pure function.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $rows = @()
    foreach ($m in @(Get-Prop $Cmp 'metrics' @())) {
        $isBytes = ([string]$m.kind -eq 'bytes')
        $fmt = { param($v) if ($null -eq $v) { 'n/a' } elseif ($isBytes) { Format-FpBytes $v } else { ([double]$v).ToString('0', $inv) } }.GetNewClosure()
        $chg = if ($null -eq $m.delta) { '' } elseif ($isBytes) { Format-FpBytes $m.delta -Signed } else { ([double]$m.delta).ToString('+0;-0;0', $inv) }
        $rows += [pscustomobject]@{
            Metric = [string]$m.label; Before = (& $fmt $m.before); Now = (& $fmt $m.after); Change = $chg; Verdict = [string]$m.verdict
            VerdictColor = $(switch ([string]$m.verdict) { 'better' { '#81C784' } 'worse' { '#E57373' } default { '#9AA0A6' } })
        }
    }
    foreach ($s in @(Get-Prop $Cmp 'states' @())) {
        $rows += [pscustomobject]@{ Metric = [string]$s.label; Before = [string]$s.before; Now = [string]$s.after; Change = $(if ($s.changed) { 'changed' } else { '' }); Verdict = $(if ($s.changed) { 'changed' } else { 'same' }); VerdictColor = $(if ($s.changed) { '#FFB74D' } else { '#9AA0A6' }) }
    }
    ,$rows
}

function ConvertTo-FootprintNowRows($Fp) {
    # A single footprint report -> the same grid rows, with no "before" column. Pure function.
    $rows = @()
    $disk = Get-Prop $Fp 'disk' $null
    if ($disk) { $rows += [pscustomobject]@{ Metric = ("System drive {0} free / total" -f (Get-Prop $disk 'drive' '')); Before = ''; Now = ((Format-FpBytes (Get-Prop $disk 'freeBytes' $null)) + ' / ' + (Format-FpBytes (Get-Prop $disk 'totalBytes' $null))); Change = ''; Verdict = ''; VerdictColor = '#9AA0A6' } }
    $sf = Get-Prop $Fp 'systemFiles' $null
    if ($sf) {
        foreach ($p in @(@('hiberfilBytes', 'hiberfil.sys'), @('pagefileBytes', 'pagefile.sys'), @('swapfileBytes', 'swapfile.sys'))) {
            $rows += [pscustomobject]@{ Metric = $p[1]; Before = ''; Now = (Format-FpBytes (Get-Prop $sf $p[0] $null)); Change = ''; Verdict = ''; VerdictColor = '#9AA0A6' }
        }
    }
    foreach ($p in @(@('appx', 'userCount', 'AppX packages (current user)'), @('appx', 'provisionedCount', 'AppX packages (provisioned)'), @('processes', 'count', 'Running processes'),
            @('services', 'total', 'Services (total)'), @('services', 'running', 'Services (running)'), @('services', 'automatic', 'Services (automatic start)'), @('startupItems', 'count', 'Startup entries'))) {
        $grp = Get-Prop $Fp $p[0] $null
        $v = if ($grp) { Get-Prop $grp $p[1] $null } else { $null }
        $rows += [pscustomobject]@{ Metric = $p[2]; Before = ''; Now = $(if ($null -eq $v) { 'n/a' } else { [string]$v }); Change = ''; Verdict = ''; VerdictColor = '#9AA0A6' }
    }
    $mem = Get-Prop $Fp 'memory' $null
    if ($mem) {
        $rows += [pscustomobject]@{ Metric = 'RAM in use'; Before = ''; Now = (Format-FpBytes (Get-Prop $mem 'usedBytes' $null)); Change = ''; Verdict = ''; VerdictColor = '#9AA0A6' }
        $rows += [pscustomobject]@{ Metric = 'Commit charge'; Before = ''; Now = (Format-FpBytes (Get-Prop $mem 'commitBytes' $null)); Change = ''; Verdict = ''; VerdictColor = '#9AA0A6' }
    }
    ,$rows
}

function Format-FootprintHeader($Fp, $Cmp) {
    # Banner line: process / service / AppX counts and disk now, plus the change since the saved "before last run" report.
    if (-not $Fp) { return '' }
    $proc = Get-Prop (Get-Prop $Fp 'processes' $null) 'count' $null
    $svc = Get-Prop $Fp 'services' $null
    $appx = Get-Prop $Fp 'appx' $null
    $disk = Get-Prop $Fp 'disk' $null
    $parts = @()
    if ($null -ne $proc) { $parts += "$proc processes" }
    if ($svc) { $parts += ('{0} of {1} services running' -f (Get-Prop $svc 'running' '?'), (Get-Prop $svc 'total' '?')) }
    if ($appx) { $parts += ('{0} AppX packages ({1} provisioned)' -f (Get-Prop $appx 'userCount' '?'), (Get-Prop $appx 'provisionedCount' '?')) }
    if ($disk) { $parts += ('{0} {1} free of {2}' -f (Get-Prop $disk 'drive' ''), (Format-FpBytes (Get-Prop $disk 'freeBytes' $null)), (Format-FpBytes (Get-Prop $disk 'totalBytes' $null))) }
    $t = 'Footprint now: ' + ($parts -join ', ') + '.'
    if ($Cmp) {
        $byKey = @{}
        foreach ($m in @(Get-Prop $Cmp 'metrics' @())) { $byKey[[string]$m.key] = $m }
        $ch = @()
        foreach ($p in @(@('processes.count', 'processes', 'count'), @('services.running', 'services running', 'count'), @('appx.userCount', 'AppX', 'count'), @('disk.freeBytes', 'free disk', 'bytes'))) {
            $m = $byKey[$p[0]]
            if ($m -and $null -ne $m.delta) {
                $d = if ($p[2] -eq 'bytes') { Format-FpBytes $m.delta -Signed } else { ([double]$m.delta).ToString('+0;-0;0', [Globalization.CultureInfo]::InvariantCulture) }
                $ch += "$($p[1]) $d"
            }
        }
        if ($ch.Count) { $t += ' Since before the last run: ' + ($ch -join ', ') + '.' }
    }
    $t
}

#endregion

#region data model ------------------------------------------------------------

function Get-Prop($Obj, [string]$Name, $Default = $null) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
    $Default
}

# Dark theme. Risk and status colours are used as text on a dark panel, so they are light tints;
# preset and evidence colours are badge backgrounds behind white text, so they stay saturated.
$script:TextGreen = '#81C784'; $script:TextAmber = '#FFB74D'; $script:TextRed = '#E57373'; $script:TextMuted = '#9AA0A6'
$script:RiskColors   = @{ 'safe' = $script:TextGreen; 'moderate' = $script:TextAmber; 'breaks-features' = '#FF8A65'; 'reduces-security' = $script:TextRed }
$script:PresetColors = @{ 'safe' = '#2E7D32'; 'balanced' = '#B26A00'; 'aggressive' = '#E65100'; 'never-default' = '#C62828' }
$script:EvColors     = @{ 'strong' = '#2E7D32'; 'mixed' = '#1565C0'; 'weak' = '#757575'; 'none' = '#9E9E9E' }
$script:StatusColors = @{ 'Applied' = $script:TextGreen; 'NotApplied' = '#64B5F6'; 'Partial' = $script:TextAmber; 'Skipped' = $script:TextMuted }
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
        $r.RiskColor = $script:RiskColors[$r.Risk]; if (-not $r.RiskColor) { $r.RiskColor = $script:TextMuted }
        $r.PresetColor = $script:PresetColors[$r.Preset]; if (-not $r.PresetColor) { $r.PresetColor = '#757575' }
        $r.EvColor = $script:EvColors[$r.EvidenceQuality]; if (-not $r.EvColor) { $r.EvColor = '#9E9E9E' }
        $r.StatusColor = $script:StatusColors[$r.Status]; if (-not $r.StatusColor) { $r.StatusColor = $script:TextMuted }
        $r.Data = $t
        Set-RowToggle $r
        $rows.Add($r)
    }
    ,$rows
}

function Set-RowToggle($r, [bool]$TrackKnown = $false) {
    # The per-row Apply / Revert button. Pure function over one row (used by the grid, by -SelfTest and after the drift data arrives).
    # Revert needs a DebloatKit snapshot record; "Applied" in -List only means the live value matches, which is also true for a
    # Windows default DebloatKit never touched. $TrackKnown says the drift document was read, so $r.Tracked can be trusted.
    $note = [string]$r.Note
    $r.StatusDetail = $(if ($note -and $note.Length -gt 140) { $note.Substring(0, 137) + '...' } else { $note })
    if ($r.Preset -ne 'safe') { $r.HasToggle = $false; $r.CanToggle = $false; $r.ToggleLabel = ''; $r.ToggleTip = 'Preset not enabled in this version'; $r.StatusDetail = 'Preset not enabled in this version'; return }
    $r.HasToggle = $true
    if ($r.Status -eq 'Skipped') { $r.ToggleLabel = 'Skipped'; $r.CanToggle = $false; $r.ToggleTip = 'The engine would skip this tweak: ' + $note; return }
    if ($r.Status -eq 'Applied') {
        $r.ToggleLabel = 'Revert'
        if ($TrackKnown -and -not $r.Tracked) { $r.CanToggle = $false; $r.ToggleTip = 'In effect already, but DebloatKit did not apply it (no snapshot), so there is nothing to restore.' }
        else { $r.CanToggle = $true; $r.ToggleTip = 'Restore the value saved before DebloatKit changed it (engine -Revert, elevated).' }
        return
    }
    $r.ToggleLabel = 'Apply'; $r.CanToggle = $true
    $r.ToggleTip = $(if ($r.Status -eq 'Partial') { 'Applies the missing steps (engine -Only, elevated). Revert is in the detail pane.' } else { 'Apply only this tweak (engine -Only, elevated).' })
}

function Update-RowTracking($Rows, $DriftDoc) {
    # Marks the rows DebloatKit has a snapshot record for (the ids in the drift document) and refreshes their toggles.
    $ids = @{}
    foreach ($t in @(Get-Prop $DriftDoc 'tweaks' @())) { $ids[[string]$t.id] = $true }
    foreach ($r in $Rows) { $r.Tracked = $ids.ContainsKey($r.Id); Set-RowToggle $r ($null -ne $DriftDoc) }
}

function Get-RowAction($Row) {
    # What a click on a row's toggle runs: Kind Apply (engine -Only) or Revert (engine -Revert). $null when the row has no action.
    if (-not $Row -or -not $Row.HasToggle -or -not $Row.CanToggle) { return $null }
    if ($Row.ToggleLabel -eq 'Revert') { return [pscustomobject]@{ Kind = 'Revert'; Ids = @($Row.Id) } }
    if ($Row.ToggleLabel -eq 'Apply') { return [pscustomobject]@{ Kind = 'Apply'; Ids = @($Row.Id) } }
    $null
}

function Get-RevertEngineArgs([bool]$WhatIf = $false) {
    # The Revert parameter set accepts only -Revert, -ExpectedSid and -AsJson (plus the common and path parameters). It does NOT
    # accept -Force, -SkipPreflight or -IncludeUnverified, and it is never gated by the preflight or the managed-device check.
    if ($WhatIf) { return @('-WhatIf', '-AsJson') }
    @()
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

# ---- setup profiles (Profiles tab): profiles.json questions + appx-profiles.json optionProfiles -> tweak ids ----
function Read-SetupData {
    # { Setup (profiles.json); Option (optionProfiles of appx-profiles.json) }. The tweak lists per profile live in appx-profiles.json.
    param([string]$SetupPath, [string]$AppxProfilesPath)
    $setup = Get-Content -LiteralPath $SetupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $opt = $null
    if (Test-Path -LiteralPath $AppxProfilesPath) { $opt = (Get-Content -LiteralPath $AppxProfilesPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $optMap = if ($opt -and $opt.PSObject.Properties['optionProfiles']) { $opt.optionProfiles } else { $null }
    [pscustomobject]@{ Setup = $setup; Option = $optMap }
}

function Get-DefaultProfileName([bool]$Managed, [string]$Chassis) {
    # A managed device always starts on work-managed (it never plans app removal); otherwise laptop or desktop.
    if ($Managed) { return 'work-managed' }
    if ($Chassis -eq 'Laptop') { return 'personal-laptop' }
    'personal-desktop'
}

function Get-ProfileAnswers($Setup, [string]$ProfileName, [bool]$Managed, [string]$Chassis) {
    # Default answers of a profile. A null answer in profiles.json is detected from the device ("auto": managed / laptop).
    $prof = Get-Prop $Setup.profiles $ProfileName $null
    if (-not $prof) { throw "Unknown profile '$ProfileName'." }
    $ans = @{}
    foreach ($q in @($Setup.questions)) {
        $v = Get-Prop $prof.answers ([string]$q.id) $null
        if ($null -eq $v) {
            $v = switch ([string](Get-Prop $q 'auto' '')) { 'managed' { $Managed } 'laptop' { ($Chassis -eq 'Laptop') } default { $false } }
        }
        $ans[[string]$q.id] = [bool]$v
    }
    $ans
}

function Resolve-SetupProfile {
    # Pure function. Profile + answers + grid rows -> which tweaks to tick and why the others are not ticked.
    param($Setup, $Option, [string]$ProfileName, [hashtable]$Answers, $Rows)
    $prof = Get-Prop $Setup.profiles $ProfileName $null
    if (-not $prof) { throw "Unknown profile '$ProfileName'." }
    $byId = @{}
    foreach ($r in $Rows) { $byId[$r.Id] = $r }
    $ans = @{}
    foreach ($k in $Answers.Keys) { $ans[$k] = [bool]$Answers[$k] }
    $effects = @()
    foreach ($q in @($Setup.questions)) {
        $eff = if ($ans[[string]$q.id]) { $q.yes } else { $q.no }
        if ($eff) { $effects += , $eff }
        $force = Get-Prop $eff 'force' $null
        if ($force) { foreach ($pn in $force.PSObject.Properties.Name) { $ans[$pn] = [bool]$force.$pn } }
    }
    $want = New-Object System.Collections.Generic.List[string]
    $minEff = [int](Get-Prop $prof 'minEffectiveness' 2)
    foreach ($r in $Rows) { if ($r.Preset -eq 'safe' -and $r.Eff -ge $minEff -and $r.EvidenceQuality -ne 'none') { $want.Add($r.Id) } }
    $op = if ($Option) { Get-Prop $Option ([string]$prof.optionProfile) $null } else { $null }
    foreach ($id in @(Get-Prop $op 'tweakIds' @())) { if ([string]$id -notlike 'appx-profile-*') { $want.Add([string]$id) } }
    $remove = New-Object System.Collections.Generic.List[string]
    foreach ($eff in $effects) {
        if (-not ((Get-Prop $eff 'requiresAppx' $false) -and -not $ans['appx'])) { foreach ($id in @(Get-Prop $eff 'addIds' @())) { $want.Add([string]$id) } }
        foreach ($id in @(Get-Prop $eff 'removeIds' @())) { $remove.Add([string]$id) }
    }
    $appxProfile = $null
    if ($ans['appx']) {
        $appxProfile = if ($ans['work']) { 'keep-work' } else { [string](Get-Prop $op 'appxProfile' 'keep-personal') }
        if (-not $appxProfile) { $appxProfile = 'keep-personal' }
        $want.Add("appx-profile-$appxProfile")
    }
    $res = [pscustomobject]@{
        Profile = $ProfileName; Answers = $ans; AppxProfile = $appxProfile; MinEffectiveness = $minEff
        Selected = @(); AlreadyApplied = @(); Unverified = @(); Skipped = @(); NotEnabled = @(); Excluded = @(); Unknown = @()
        NeedsAck = [bool]$ans['appx']; AckText = ''
    }
    foreach ($q in @($Setup.questions)) { if ([string]$q.id -eq 'appx') { $res.AckText = [string](Get-Prop $q.yes 'requiresAck' '') } }
    $seen = @{}
    foreach ($id in $want) {
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        if ($remove -contains $id) { $res.Excluded += $id; continue }
        $r = $byId[$id]
        if (-not $r) { $res.Unknown += $id; continue }
        if ($r.Preset -ne 'safe') { $res.NotEnabled += [pscustomobject]@{ Id = $id; Preset = $r.Preset; Description = $r.Description }; continue }
        if ($r.Status -eq 'Skipped') { $res.Skipped += [pscustomobject]@{ Id = $id; Note = $r.Note }; continue }
        if ($r.Status -eq 'Applied') { $res.AlreadyApplied += $id; continue }
        if ($r.IsUnverified) { $res.Unverified += $id; continue }
        if ($r.CanCheck) { $res.Selected += $id }
    }
    $res
}

function Format-ProfilePlan($Res) {
    # Plain-text sections for the Profiles tab: [pscustomobject]@{ Title; Text }. Pure function.
    $out = @()
    $out += [pscustomobject]@{ Title = ('Selected for you ({0})' -f @($Res.Selected).Count); Text = $(if (@($Res.Selected).Count) { (@($Res.Selected) | ForEach-Object { '- ' + $_ }) -join "`n" } else { 'Nothing to tick: everything in this profile is already in effect, skipped or not available.' }) }
    if (@($Res.AlreadyApplied).Count) { $out += [pscustomobject]@{ Title = ('Already in effect ({0})' -f @($Res.AlreadyApplied).Count); Text = (@($Res.AlreadyApplied) -join ', ') } }
    if (@($Res.Skipped).Count) { $out += [pscustomobject]@{ Title = ('Skipped by the engine on this device ({0})' -f @($Res.Skipped).Count); Text = ((@($Res.Skipped) | ForEach-Object { '- ' + $_.Id + ': ' + $_.Note }) -join "`n") } }
    if (@($Res.Unverified).Count) { $out += [pscustomobject]@{ Title = ('Unverified, not ticked ({0})' -f @($Res.Unverified).Count); Text = ((@($Res.Unverified) -join ', ') + "`nNot tested on a real machine. Tick them yourself in the Tweaks tab after trying a VM.") } }
    if (@($Res.NotEnabled).Count) {
        $out += [pscustomobject]@{ Title = ('In a preset that is not enabled in this version ({0})' -f @($Res.NotEnabled).Count)
            Text = (((@($Res.NotEnabled) | ForEach-Object { '- ' + $_.Id + ' (' + $_.Preset + ')' }) -join "`n") + "`nThe engine refuses these, so the profile cannot tick them. They show what the profile will do once the preset is enabled.") }
    }
    if (@($Res.Excluded).Count) { $out += [pscustomobject]@{ Title = ('Left out because of your answers ({0})' -f @($Res.Excluded).Count); Text = (@($Res.Excluded) -join ', ') } }
    if (@($Res.Unknown).Count) { $out += [pscustomobject]@{ Title = 'Not in the catalog'; Text = (@($Res.Unknown) -join ', ') } }
    if ($Res.AppxProfile) { $out += [pscustomobject]@{ Title = 'AppX keep profile'; Text = ("Profile '" + $Res.AppxProfile + "' from appx-profiles.json would be used (its remove list minus its keep list). Plan only: app removal needs -AllowIrreversible, which this GUI never passes, and the preset is not enabled in this version. " + $Res.AckText) } }
    $out
}

function Set-ProfileSelection($Rows, $Res) {
    # Ticks exactly the resolved tweaks (and unticks all the others). Only rows the engine can run are ever ticked.
    $sel = @{}
    foreach ($id in @($Res.Selected)) { $sel[$id] = $true }
    foreach ($r in $Rows) { $r.Checked = ($r.CanCheck -and $sel.ContainsKey($r.Id)) }
}

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
        'appx'    { $pfn = [string](Get-Prop $s 'profile' ''); @("Remove AppX packages: $(if ($pfn) { "profile '$pfn' (appx-profiles.json: its remove list minus its keep list)" } else { (@(Get-Prop $s 'names' @())) -join ', ' })  [a reinstall manifest is saved in the snapshot; the engine skips this unless -AllowIrreversible, which this GUI never passes. Protected packages are never removed; Teams and Outlook are kept on managed devices]") }
        'capability' { @("Windows capability '$(Get-Prop $s 'name')': removed (Remove-WindowsCapability); undo re-adds it and needs Windows Update or Features on Demand access. Skipped when not present on this edition") }
        'optionalfeature' { @("Optional feature '$(Get-Prop $s 'name')': disabled without removing the payload (Disable-WindowsOptionalFeature); undo enables it again offline. Skipped when not present on this edition") }
        'command' { @("Command: $(Get-Prop $s 'run')  [only an allowlist of commands is implemented natively by the engine (with a snapshot and exact undo); the rest are skipped, never executed. Irreversible ones, such as the component store cleanup, need -AllowIrreversible, which this GUI never passes]") }
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
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock x:Name="txtManaged" Grid.Column="0" TextWrapping="Wrap" Text="Loading device information..."/>
        <TextBlock x:Name="txtElevation" Grid.Column="1" Margin="20,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="txtPreflight" Grid.Row="1" Grid.ColumnSpan="2" Margin="0,4,0,0" TextWrapping="Wrap" Foreground="#37474F" ToolTipService.ShowDuration="30000"/>
        <TextBlock x:Name="txtFootprint" Grid.Row="2" Grid.ColumnSpan="2" Margin="0,2,0,0" TextWrapping="Wrap" Foreground="#546E7A"/>
      </Grid>
    </Border>

    <!-- Main area -->
    <TabControl x:Name="tabs" Grid.Row="1" Margin="10,10,10,0">
      <TabItem Header="Tweaks (advanced)" x:Name="tabTweaks">
    <Grid Margin="0,8,0,0">
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
              <DataGridTemplateColumn Header="Status" Width="150">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <StackPanel VerticalAlignment="Center" Margin="0,3">
                      <TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold"/>
                      <TextBlock Text="{Binding StatusDetail}" Foreground="#78909C" FontSize="10.5" TextWrapping="Wrap" MaxHeight="52"/>
                    </StackPanel>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Toggle" Width="96">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Button Content="{Binding ToggleLabel}" IsEnabled="{Binding CanToggle}" ToolTip="{Binding ToggleTip}" ToolTipService.ShowOnDisabled="True"
                            Tag="rowtoggle" Padding="8,2" Margin="0" MinHeight="24" MinWidth="76" VerticalAlignment="Center" HorizontalAlignment="Left">
                      <Button.Style>
                        <Style TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
                          <Setter Property="Visibility" Value="Collapsed"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding HasToggle}" Value="True"><Setter Property="Visibility" Value="Visible"/></DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Button.Style>
                    </Button>
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
              <ProgressBar x:Name="pbLoading" IsIndeterminate="True" Minimum="0" Maximum="100" Width="260" Height="8" Margin="0,12,0,0"/>
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
      </TabItem>

      <!-- Profiles -->
      <TabItem Header="Profiles" x:Name="tabProfiles">
        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="400" MinWidth="300"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4" Padding="14,8,14,14">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <TextBlock Text="SETUP" Style="{StaticResource SectionHead}" Margin="0,6,0,0"/>
                <TextBlock Text="Start from" Style="{StaticResource Label}"/>
                <ComboBox x:Name="cmbProfile"/>
                <TextBlock x:Name="txtProfileDesc" TextWrapping="Wrap" Foreground="#607D8B" FontSize="11.5" Margin="0,6,0,0"/>
                <TextBlock Text="QUESTIONS" Style="{StaticResource SectionHead}"/>
                <StackPanel x:Name="profileQuestions"/>
                <CheckBox x:Name="chkProfileAck" Visibility="Collapsed" Margin="0,12,0,0">
                  <CheckBox.ContentTemplate><DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap" FontWeight="SemiBold"/></DataTemplate></CheckBox.ContentTemplate>
                </CheckBox>
                <Button x:Name="btnProfileSelect" Content="Tick these tweaks in the Tweaks tab" Margin="0,18,0,0" HorizontalAlignment="Left" FontWeight="SemiBold" Background="#2E7D32" Foreground="White"
                        ToolTip="Only selects. Nothing is applied until you press Apply selected."/>
                <TextBlock x:Name="txtProfileNote" TextWrapping="Wrap" Foreground="#607D8B" FontSize="11.5" Margin="0,12,0,0"
                           Text="A profile only ticks tweaks in the grid. You still review them, preview with -WhatIf and confirm the apply. The engine's preset gate stays authoritative: tweaks in a preset that is not enabled are listed, never forced."/>
              </StackPanel>
            </ScrollViewer>
          </Border>
          <Border Grid.Column="2" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,12,16,16">
              <StackPanel x:Name="profilePanel">
                <TextBlock Text="Loading the tweak list..." Foreground="#78909C" TextWrapping="Wrap"/>
              </StackPanel>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <!-- Drift -->
      <TabItem Header="Drift" x:Name="tabDrift">
        <Grid Margin="0,8,0,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Grid.Row="0" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4" Padding="12,8">
            <StackPanel>
              <TextBlock x:Name="txtDriftSummary" TextWrapping="Wrap" FontWeight="SemiBold" Text="Drift has not been read yet."/>
              <TextBlock x:Name="txtDriftBanner" TextWrapping="Wrap" Foreground="#B26A00" Margin="0,4,0,0"/>
              <TextBlock TextWrapping="Wrap" Foreground="#607D8B" FontSize="11.5" Margin="0,4,0,0"
                         Text="Compares the live state of every tweak DebloatKit applied with what it applied (read-only, engine -Drift). A feature update can quietly put values back. Re-apply runs only the drifted tweaks through the normal apply path."/>
            </StackPanel>
          </Border>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8,0,8">
            <Button x:Name="btnDriftRefresh" Content="Check drift now"/>
            <Button x:Name="btnDriftPreview" Content="Preview re-apply" ToolTip="Runs the engine with -Drift -Reapply -WhatIf. Writes nothing."/>
            <Button x:Name="btnDriftReapply" Content="Re-apply drifted" FontWeight="SemiBold" Background="#2E7D32" Foreground="White" ToolTip="Elevated engine run: -Drift -Reapply (preflight, restore point, snapshot)."/>
            <Button x:Name="btnDriftRevert" Content="Revert selected tweak" ToolTip="Elevated engine run: -Revert for the tweak selected below."/>
          </StackPanel>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*" MinWidth="300"/><ColumnDefinition Width="6"/><ColumnDefinition Width="1.4*" MinWidth="300"/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4">
              <DataGrid x:Name="driftGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" SelectionMode="Single" HeadersVisibility="Column"
                        GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECEFF1" BorderThickness="0" Background="White">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Tweak" Binding="{Binding Id}" Width="*"/>
                  <DataGridTemplateColumn Header="State" Width="80">
                    <DataGridTemplateColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusColor}" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="Drifted steps" Binding="{Binding DriftedSteps}" Width="90"/>
                  <DataGridTextColumn Header="Applied on build" Binding="{Binding Builds}" Width="120"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
            <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="Transparent" ResizeBehavior="PreviousAndNext"/>
            <Border Grid.Column="2" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                <TextBlock x:Name="txtDriftNote" Grid.Row="0" TextWrapping="Wrap" Margin="10,8" Foreground="#37474F" Text="Select a tweak to see its steps."/>
                <DataGrid x:Name="driftStepGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column"
                          GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECEFF1" BorderThickness="0" Background="White">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="State" Binding="{Binding state}" Width="70"/>
                    <DataGridTextColumn Header="Type" Binding="{Binding type}" Width="70"/>
                    <DataGridTextColumn Header="Target" Binding="{Binding target}" Width="*"/>
                    <DataGridTextColumn Header="Applied" Binding="{Binding desiredText}" Width="110"/>
                    <DataGridTextColumn Header="Now" Binding="{Binding currentText}" Width="110"/>
                    <DataGridTextColumn Header="Note" Binding="{Binding note}" Width="150"/>
                  </DataGrid.Columns>
                  <DataGrid.CellStyle>
                    <Style TargetType="DataGridCell" BasedOn="{StaticResource {x:Type DataGridCell}}"><Setter Property="TextBlock.TextWrapping" Value="Wrap"/></Style>
                  </DataGrid.CellStyle>
                </DataGrid>
              </Grid>
            </Border>
          </Grid>
        </Grid>
      </TabItem>

      <!-- Footprint -->
      <TabItem Header="Footprint" x:Name="tabFootprint">
        <Grid Margin="0,8,0,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal">
            <Button x:Name="btnFpMeasure" Content="Measure now"/>
            <Button x:Name="btnFpSave" Content="Save as baseline" ToolTip="Saves the current measurement as the baseline file (Get-FootprintReport.ps1 -Baseline)."/>
            <TextBlock Text="Compare with" VerticalAlignment="Center" Margin="12,0,6,0" Foreground="#37474F"/>
            <ComboBox x:Name="cmbFpBase" MinWidth="230" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <Button x:Name="btnFpCompare" Content="Compare"/>
          </StackPanel>
          <Border Grid.Row="1" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4" Padding="12,8" Margin="0,8,0,8">
            <StackPanel>
              <TextBlock x:Name="txtFpHeader" TextWrapping="Wrap" FontWeight="SemiBold" Text="Not measured yet."/>
              <TextBlock x:Name="txtFpNote" TextWrapping="Wrap" Foreground="#607D8B" FontSize="11.5" Margin="0,4,0,0"/>
            </StackPanel>
          </Border>
          <Border Grid.Row="2" Background="White" BorderBrush="#CFD8DC" BorderThickness="1" CornerRadius="4">
            <DataGrid x:Name="fpGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" HeadersVisibility="Column"
                      GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECEFF1" BorderThickness="0" Background="White">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Metric" Binding="{Binding Metric}" Width="*" MinWidth="200"/>
                <DataGridTextColumn Header="Before" Binding="{Binding Before}" Width="120"/>
                <DataGridTextColumn Header="Now" Binding="{Binding Now}" Width="130"/>
                <DataGridTextColumn Header="Change" Binding="{Binding Change}" Width="110"/>
                <DataGridTemplateColumn Header="Verdict" Width="90">
                  <DataGridTemplateColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Verdict}" Foreground="{Binding VerdictColor}" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>
          </Border>
          <TextBlock Grid.Row="3" TextWrapping="Wrap" Foreground="#607D8B" FontSize="11.5" Margin="0,8,0,0"
                     Text="Read-only (Get-FootprintReport.ps1). The GUI runs it without elevation, so provisioned AppX and the WinSxS analysis are not measured here. Take the baseline and the comparison the same way. Process and memory numbers move by themselves; treat small differences as noise. Run the script with -Deep from an elevated prompt for the full report."/>
        </Grid>
      </TabItem>
    </TabControl>

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
        <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
          <CheckBox x:Name="chkManaged" Visibility="Collapsed"
                    Content="I understand this is a managed device (adds -Force; policy keys may conflict with my organisation's settings)"/>
          <CheckBox x:Name="chkSkipPreflight" Visibility="Collapsed" Margin="0,3,0,0"
                    Content="Apply anyway although the preflight check fails (adds -SkipPreflight)"/>
        </StackPanel>
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
        <Style TargetType="DataGridCell" BasedOn="{StaticResource {x:Type DataGridCell}}"><Setter Property="TextBlock.TextWrapping" Value="Wrap"/></Style>
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

# Dark theme ------------------------------------------------------------------
# The window XAML above keeps its original light colour literals; Read-Xaml swaps them through this
# map and injects the control styles below, so all three windows share one palette. New-Brush uses
# the same map for colours set from code. Badge colours (white text on saturated fills) are not mapped.
$script:DarkMap = @{
    '#F4F6F8'   = '#1B1C1F'     # window background
    '#FAFBFC'   = '#2A2C31'     # alternating row
    '#E6FFFFFF' = '#E625272B'   # loading overlay
    '#ECEFF1'   = '#33363C'     # grid lines, group header
    '#CFD8DC'   = '#3A3D44'     # panel borders
    '#E8F5E9'   = '#1E3324'; '#C8E6C9' = '#2E5236'   # unmanaged banner (background, border)
    '#FFF3E0'   = '#3A2C17'     # managed banner background (its border is set directly in Update-Banner)
    '#263238'   = '#E4E6EA'; '#37474F' = '#D3D7DC'; '#455A64' = '#C2C7CE'   # text, strongest to weakest
    '#546E7A'   = '#A9B0B8'; '#607D8B' = '#9AA3AD'; '#78909C' = '#8B949E'
}

$script:DarkStyles = @'
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#25272B"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#2E3035"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E4E6EA"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#E4E6EA"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.GrayTextBrushKey}" Color="#8B949E"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#264F78"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>

    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="MinHeight" Value="30"/>
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="Background" Value="#34373D"/>
      <Setter Property="BorderBrush" Value="#4A4E56"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid SnapsToDevicePixels="True">
              <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4"/>
              <Border x:Name="hl" Background="#FFFFFF" CornerRadius="4" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hl" Property="Opacity" Value="0.08"/><Setter TargetName="bd" Property="BorderBrush" Value="#6B717B"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="hl" Property="Opacity" Value="0.16"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#5B9BD5"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1E1F23"/>
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="BorderBrush" Value="#4A4E56"/>
      <Setter Property="CaretBrush" Value="#E4E6EA"/>
      <Setter Property="SelectionBrush" Value="#3D7BC4"/>
    </Style>

    <ControlTemplate x:Key="DkComboToggle" TargetType="ToggleButton">
      <Border x:Name="bd" Background="#1E1F23" BorderBrush="#4A4E56" BorderThickness="1" CornerRadius="3">
        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0" Data="M 0 0 L 4 4 L 8 0 Z" Fill="#B5BAC1"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#6B717B"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#5B9BD5"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="MinHeight" Value="27"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Template="{StaticResource DkComboToggle}" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter IsHitTestVisible="False" Margin="8,3,26,3" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="#25272B" BorderBrush="#4A4E56" BorderThickness="1" CornerRadius="3" Margin="0,2,0,0"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer SnapsToDevicePixels="True"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#264F78"/></Trigger>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="#34373D"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="box" Width="16" Height="16" CornerRadius="3" Background="#1E1F23" BorderBrush="#6B717B" BorderThickness="1" VerticalAlignment="Top" Margin="0,1,0,0">
                <Path x:Name="mark" Data="M 2.5 7.5 L 6 11 L 12.5 3.5" Stroke="White" StrokeThickness="2" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="7,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#9AA3AD"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="mark" Property="Visibility" Value="Visible"/><Setter TargetName="box" Property="Background" Value="#3D7BC4"/><Setter TargetName="box" Property="BorderBrush" Value="#3D7BC4"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#25272B"/>
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="RowBackground" Value="#25272B"/>
      <Setter Property="AlternatingRowBackground" Value="#2A2C31"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#33363C"/>
      <Setter Property="VerticalGridLinesBrush" Value="#33363C"/>
      <Setter Property="BorderBrush" Value="#3A3D44"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#2E3035"/>
      <Setter Property="Foreground" Value="#B5BAC1"/>
      <Setter Property="BorderBrush" Value="#3A3D44"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="6,6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridColumnHeader">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
                <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
              </Border>
              <Thumb x:Name="PART_LeftHeaderGripper" HorizontalAlignment="Left" Width="6" Opacity="0" Cursor="SizeWE"/>
              <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="6" Opacity="0" Cursor="SizeWE"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#264F78"/>
          <Setter Property="BorderBrush" Value="#264F78"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#3A3D44"/>
      <Setter Property="BorderThickness" Value="0,1,0,0"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#B5BAC1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,2" Padding="14,7" Margin="0,0,2,0" CornerRadius="3,3,0,0">
              <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2C31"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#25272B"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#5B9BD5"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DkThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" Background="#4A4E56" CornerRadius="4"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#6B717B"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#80868F"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DkPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="#1F2024"/>
      <Setter Property="Width" Value="11"/>
      <Setter Property="MinWidth" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Border Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource DkPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource DkThumb}" Margin="2"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource DkPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="11"/>
          <Setter Property="MinHeight" Value="11"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Border Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource DkPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb Style="{StaticResource DkThumb}" Margin="2"/></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource DkPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                  </Track>
                </Border>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#2E3035"/>
      <Setter Property="Foreground" Value="#E4E6EA"/>
      <Setter Property="BorderBrush" Value="#4A4E56"/>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Background" Value="#33363C"/>
      <Setter Property="Foreground" Value="#5B9BD5"/>
      <Setter Property="BorderBrush" Value="#3A3D44"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="#E4E6EA"/>
    </Style>
    <Style TargetType="Hyperlink">
      <Setter Property="Foreground" Value="#64B5F6"/>
    </Style>
'@

function ConvertTo-DarkXaml([string]$Xaml) {
    foreach ($k in $script:DarkMap.Keys) { $Xaml = $Xaml.Replace('"' + $k + '"', '"' + $script:DarkMap[$k] + '"') }
    $Xaml = $Xaml.Replace('Background="White"', 'Background="#25272B"')
    $Xaml = $Xaml.Replace('Foreground="#B26A00"', 'Foreground="#FFB74D"')   # warning text; #B26A00 stays a badge fill elsewhere
    # Default text colour for every TextBlock that does not set its own.
    $Xaml = [regex]::Replace($Xaml, '(<Window\b[^>]*?)FontFamily="Segoe UI"', '$1Foreground="#E4E6EA" FontFamily="Segoe UI"')
    if ($Xaml.Contains('<Window.Resources>')) { return $Xaml.Replace('<Window.Resources>', "<Window.Resources>`n" + $script:DarkStyles) }
    $end = $Xaml.IndexOf('>', $Xaml.IndexOf('<Window')) + 1
    $Xaml.Insert($end, "`n  <Window.Resources>`n" + $script:DarkStyles + "  </Window.Resources>")
}

function Set-DarkTitleBar($Window) {
    try {
        if (-not ('DebloatKit.Dwm' -as [type])) {
            Add-Type -Namespace DebloatKit -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
        }
        $Window.Add_SourceInitialized({
                param($s, $e)
                try {
                    $h = (New-Object System.Windows.Interop.WindowInteropHelper($s)).Handle
                    $on = 1
                    [void][DebloatKit.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)   # DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 2004+, Windows 11)
                } catch { }
            })
    } catch { }   # cosmetic only
}

function Read-Xaml([string]$Xaml) {
    $sr = New-Object System.IO.StringReader((ConvertTo-DarkXaml $Xaml))
    $xr = [System.Xml.XmlReader]::Create($sr)
    try { $w = [System.Windows.Markup.XamlReader]::Load($xr) } finally { $xr.Close() }
    if ($w -is [System.Windows.Window]) { Set-DarkTitleBar $w }
    $w
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
    foreach ($n in 'grid', 'txtSearch', 'cmbCategory', 'cmbPreset', 'cmbRisk', 'cmbStatus', 'chkProven', 'detailPanel', 'btnApply', 'btnUndo', 'btnPreview', 'txtManaged', 'txtPreflight', 'chkSkipPreflight', 'pbLoading') {
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
    $catalog = Read-CatalogFile $CatalogPath
    Assert-That ($catalog.Count -gt 0) "catalog loaded: $($catalog.Count) entries"
    Assert-That (@($catalog | Where-Object { $null -eq (Get-Prop $_ 'id' $null) }).Count -eq 0) 'catalog loader returns tweak entries only (no schemaVersion / migrations rows)'
    $legacy = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitGuiLegacy-" + [guid]::NewGuid().ToString('N') + '.json')
    $v2 = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitGuiV2-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Set-Content -LiteralPath $legacy -Value '[{"id":"a"},{"id":"b"}]' -Encoding UTF8
        Set-Content -LiteralPath $v2 -Value '{"schemaVersion":2,"migrations":[],"tweaks":[{"id":"a"},{"id":"b"}]}' -Encoding UTF8
        Assert-That ((@(Read-CatalogFile $legacy)).Count -eq 2) 'Read-CatalogFile reads a version 1 catalog (bare array)'
        Assert-That ((@(Read-CatalogFile $v2)).Count -eq 2) 'Read-CatalogFile reads a version 2 catalog (object with tweaks)'
    } finally { Remove-Item -LiteralPath $legacy, $v2 -Force -ErrorAction SilentlyContinue }
    Assert-That ($eng.Tweaks.Count -gt 0) "engine returned $($eng.Tweaks.Count) tweaks"
    Assert-That ($null -ne $eng.Preflight -and @($eng.Preflight.checks).Count -eq 4) 'engine -List returns a preflight block with 4 checks'
    Assert-That ($null -ne $eng.Os -and $eng.Os.build -gt 0 -and $eng.Os.buildFull) "engine -List returns the OS build ($($eng.Os.buildFull), $($eng.Os.chassis))"
    Assert-That (@($eng.Tweaks | Where-Object { $null -eq $_.PSObject.Properties['weight'] }).Count -eq 0) 'every listed tweak carries a progress weight'
    $okPf = [pscustomobject]@{ blocked = $false; checks = @() }
    $badPf = [pscustomobject]@{ blocked = $true; checks = @([pscustomobject]@{ blocking = $true; title = 'No pending reboot'; detail = 'a restart is pending' }) }
    $osFake = [pscustomobject]@{ buildFull = '26200.1'; editionId = 'Professional'; chassis = 'Laptop' }
    Assert-That ((Format-PreflightText $okPf $osFake) -eq 'Windows build 26200.1 (Professional, laptop). Preflight: ready to apply.') 'Format-PreflightText: clear state'
    Assert-That ((Format-PreflightText $badPf $osFake) -match 'refused.*No pending reboot: a restart is pending') 'Format-PreflightText: blocked state names the failing gate'
    Assert-That ((Format-PreflightText $null $null) -eq '') 'Format-PreflightText: no data gives an empty line'
    $planFake = @([pscustomobject]@{ action = 'Change'; weight = 3 }, [pscustomobject]@{ action = 'Change'; weight = 20 }, [pscustomobject]@{ action = 'Skip'; weight = 20 }, [pscustomobject]@{ action = 'InSync'; weight = 1 })
    Assert-That ((Measure-PlanWeight $planFake) -eq 23) 'Measure-PlanWeight sums only the steps that change'
    Assert-That ((Measure-PlanWeight @()) -eq 0) 'Measure-PlanWeight of an empty plan is 0'
    Assert-That ((Get-ProgressPercent "x`n[progress] 10% - a`n[progress] 55% - b`n") -eq 55) 'Get-ProgressPercent reads the last progress line'
    Assert-That ($null -eq (Get-ProgressPercent 'no progress here')) 'Get-ProgressPercent: no line, no value'
    $cmdSkip = New-EngineCommandText -EngineArgs @('-SkipPreflight') -Ids @('x-y')
    Assert-That ($cmdSkip -match '-SkipPreflight' -and $cmdSkip -match "-Only @\('x-y'\)") 'engine command carries -SkipPreflight and the tweak ids' 
    $m = $eng.Managed
    Write-Output ("  managed: isManaged={0} entra={1} domain={2} mdm={3} tenant='{4}' elevated={5}" -f $m.isManaged, $m.azureAdJoined, $m.domainJoined, $m.mdmEnrolled, $m.tenant, (Test-Elevated))

    # 3. Rows
    $rows = New-TweakRows -Catalog $catalog -EngineTweaks $eng.Tweaks
    Assert-That ($rows.Count -eq $catalog.Count) "grid rows = catalog entries ($($rows.Count))"
    $win.FindName('grid').ItemsSource = $rows
    Assert-That ($win.FindName('grid').Items.Count -eq $rows.Count) 'DataGrid accepts the rows'
    $msk = @($rows | Where-Object { Get-Prop $_.Data 'managedSkip' $null })
    Assert-That ($msk.Count -gt 0) "catalog has managedSkip entries ($($msk.Count))"
    if ($m.isManaged) { Assert-That (@($msk | Where-Object { $_.Status -ne 'Skipped' }).Count -eq 0) 'managed device: every managedSkip tweak is Skipped by the engine' }
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
        Assert-That (@($plan | Where-Object { $null -eq $_.PSObject.Properties['weight'] -or $null -eq $_.PSObject.Properties['order'] }).Count -eq 0) 'preview path: every plan step has order and weight'
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
            if (@($steps | Where-Object { (Get-Prop $_ 'type' '') -in 'appx', 'capability', 'optionalfeature' }).Count) { $ruleBad.Add("$($r.Id): safe tweak has an appx, capability or optionalfeature step") }
            $rv = Get-Prop $d 'revert' $null
            if ($rv -is [string] -and $rv -match 'not reversible') { $ruleBad.Add("$($r.Id): safe tweak is not reversible") }
        }
        $me = [string](Get-Prop $d 'measuredEffect' '')
        if ($me -match '^\s*not measured' -and $r.Eff -gt 1 -and $me -notmatch '\d') { $ruleBad.Add("$($r.Id): effectiveness $($r.Eff) but 'not measured'") }
    }
    foreach ($b in $ruleBad) { Write-Output "    rule: $b" }
    Assert-That ($ruleBad.Count -eq 0) 'catalog rules: no irreversible safe tweaks; unmeasured tweaks score at most 1'

    # 5d. WP7: per-row toggle, profiles, drift, footprint (nothing here changes the system: reads, -WhatIf, fixtures and temp files)
    Write-Output ''
    Write-Output 'WP7 checks:'
    $pdExisted = Test-Path -LiteralPath (Join-Path $env:ProgramData 'DebloatKit')
    foreach ($n in 'tabs', 'tabTweaks', 'tabProfiles', 'tabDrift', 'tabFootprint', 'cmbProfile', 'profileQuestions', 'profilePanel', 'chkProfileAck', 'btnProfileSelect', 'txtProfileDesc',
        'driftGrid', 'driftStepGrid', 'btnDriftRefresh', 'btnDriftPreview', 'btnDriftReapply', 'btnDriftRevert', 'txtDriftSummary', 'txtDriftBanner',
        'fpGrid', 'btnFpMeasure', 'btnFpSave', 'btnFpCompare', 'cmbFpBase', 'txtFpHeader', 'txtFootprint') {
        Assert-That ($null -ne $win.FindName($n)) "XAML element '$n' present"
    }
    Assert-That ($win.FindName('tabs').Items.Count -eq 4) 'tab control has the four tabs (Tweaks, Profiles, Drift, Footprint)'
    foreach ($bn in $script:BusyButtons) { Assert-That ($null -ne $win.FindName($bn)) "busy-state button '$bn' exists" }

    # command construction: revert, tool, drift
    $cmdRev = New-EngineCommandText -EngineArgs (Get-RevertEngineArgs) -Ids @('x-y', 'a.b') -IdSwitch '-Revert' -PassSid
    Assert-That ($cmdRev -match "-Revert @\('x-y','a\.b'\)" -and $cmdRev -match '-ExpectedSid ''S-1-') 'revert command: -Revert @(ids) with -ExpectedSid'
    Assert-That ($cmdRev -notmatch '-Only' -and $cmdRev -notmatch '-Force' -and $cmdRev -notmatch '-SkipPreflight' -and $cmdRev -notmatch '-IncludeUnverified') 'revert command: none of -Only / -Force / -SkipPreflight / -IncludeUnverified (the Revert parameter set rejects them)'
    $cmdRevW = New-EngineCommandText -EngineArgs (Get-RevertEngineArgs $true) -Ids @('x-y') -IdSwitch '-Revert'
    Assert-That ($cmdRevW -match '-WhatIf -AsJson -Revert @\(''x-y''\)') 'revert preview command: -WhatIf -AsJson -Revert @(id)'
    $threw = $false; try { $null = New-EngineCommandText -EngineArgs @() -Ids @('a b') -IdSwitch '-Revert' } catch { $threw = $true }
    Assert-That $threw 'revert command refuses a suspicious id'
    $cmdTool = New-EngineCommandText -EngineArgs @('-AsJson') -Tool -ScriptPath $FootprintScriptPath
    Assert-That ($cmdTool -match 'Get-FootprintReport\.ps1' -and $cmdTool -notmatch '-CatalogPath|-ExpectedSid|-StateDir|-Only|-Revert') 'tool command: runs Get-FootprintReport.ps1 with none of the engine-only parameters'
    $cmdDrift = New-EngineCommandText -EngineArgs (@('-Drift', '-Reapply', '-IncludeUnverified') + @('-Force', '-SkipPreflight')) -PassSid
    Assert-That ($cmdDrift -match '-Drift -Reapply -IncludeUnverified -Force -SkipPreflight' -and $cmdDrift -match '-ExpectedSid' -and $cmdDrift -notmatch '-Only') 're-apply command: -Drift -Reapply with -Force / -SkipPreflight / -ExpectedSid and no -Only'
    $cmdSb = ''
    $sbSave = @{ S = $StateDir; T = $TestEnvironment; P = $ProfilesPath }
    $StateDir = Join-Path ([IO.Path]::GetTempPath()) 'dk-gui-selftest-state'; $TestEnvironment = Join-Path ([IO.Path]::GetTempPath()) 'dk-gui-selftest-env.json'; $ProfilesPath = $null
    try { $cmdSb = New-EngineCommandText -EngineArgs @('-Drift', '-AsJson') } finally { $StateDir = $sbSave.S; $TestEnvironment = $sbSave.T; $ProfilesPath = $sbSave.P }
    Assert-That ($cmdSb -match '-StateDir ''[^'']*dk-gui-selftest-state''' -and $cmdSb -match '-TestEnvironment ''[^'']*dk-gui-selftest-env\.json''') '-StateDir / -TestEnvironment are forwarded to the engine when the GUI is given them'

    # per-row Apply / Revert toggle
    $badToggle = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rows) {
        if ($r.Preset -ne 'safe') { if ($r.HasToggle -or $r.CanToggle) { $badToggle.Add("$($r.Id): non-safe row has a toggle") }; continue }
        if (-not $r.HasToggle) { $badToggle.Add("$($r.Id): safe row without a toggle"); continue }
        if ($r.Status -eq 'Skipped' -and ($r.CanToggle -or $r.ToggleLabel -ne 'Skipped' -or $r.ToggleTip -notlike "*$($r.Note)*")) { $badToggle.Add("$($r.Id): skipped row must show the reason and not be actionable") }
        if ($r.Status -eq 'Applied' -and $r.ToggleLabel -ne 'Revert') { $badToggle.Add("$($r.Id): applied row should offer Revert") }
        if ($r.Status -in 'NotApplied', 'Partial' -and $r.ToggleLabel -ne 'Apply') { $badToggle.Add("$($r.Id): not-applied row should offer Apply") }
    }
    foreach ($b in $badToggle) { Write-Output "    toggle: $b" }
    Assert-That ($badToggle.Count -eq 0) 'per-row toggle: Apply / Revert / Skipped (with the engine reason) / hidden for presets that are not enabled'
    $sk = $rows | Where-Object { $_.Preset -eq 'safe' -and $_.Status -eq 'Skipped' } | Select-Object -First 1
    if ($sk) { Assert-That ($null -eq (Get-RowAction $sk)) "skipped row ($($sk.Id)) has no action; the reason is its tooltip" }
    $appliedRows = @($rows | Where-Object { $_.Preset -eq 'safe' -and $_.Status -eq 'Applied' })
    $fakeDrift = [pscustomobject]@{ tweaks = @() }
    if ($appliedRows.Count) { $fakeDrift = [pscustomobject]@{ tweaks = @([pscustomobject]@{ id = $appliedRows[0].Id; status = 'InSync' }) } }
    Update-RowTracking $rows $fakeDrift
    if ($appliedRows.Count) {
        $a0 = Get-RowAction $appliedRows[0]
        Assert-That ($a0 -and $a0.Kind -eq 'Revert' -and $a0.Ids[0] -eq $appliedRows[0].Id) 'tracked applied row: the toggle reverts exactly that tweak'
        if ($appliedRows.Count -gt 1) { Assert-That ($null -eq (Get-RowAction $appliedRows[1]) -and $appliedRows[1].ToggleTip -match 'did not apply it') 'applied but untracked row: Revert disabled (nothing to restore)' }
    }
    $na = $rows | Where-Object { $_.Preset -eq 'safe' -and $_.Status -eq 'NotApplied' } | Select-Object -First 1
    if ($na) { $aN = Get-RowAction $na; Assert-That ($aN -and $aN.Kind -eq 'Apply' -and $aN.Ids.Count -eq 1) 'not-applied row: the toggle applies exactly that tweak' }
    Update-RowTracking $rows $null
    Assert-That (@($rows | Where-Object { $_.Preset -eq 'safe' -and $_.Status -eq 'Applied' -and -not $_.CanToggle }).Count -eq 0) 'without drift data every applied row stays revertible (the engine decides)'

    # profiles
    $sd = Read-SetupData $SetupProfilesPath (Get-AppxProfilesPath)
    $setup = $sd.Setup
    Assert-That ($setup.schemaVersion -eq 1 -and @($setup.questions).Count -ge 5 -and @($setup.profiles.PSObject.Properties).Count -ge 4) 'profiles.json: version 1, at least 5 questions, at least 4 profiles'
    $byIdRow = @{}; foreach ($r in $rows) { $byIdRow[$r.Id] = $r }
    $profIds = New-Object System.Collections.Generic.List[string]
    foreach ($pn in $setup.profiles.PSObject.Properties.Name) {
        $p = $setup.profiles.$pn
        Assert-That ($null -ne $sd.Option -and $null -ne $sd.Option.PSObject.Properties[[string]$p.optionProfile]) "profile $pn maps to optionProfiles.$($p.optionProfile) in appx-profiles.json"
        foreach ($id in @(Get-Prop $sd.Option.$($p.optionProfile) 'tweakIds' @())) { $profIds.Add([string]$id) }
    }
    foreach ($q in @($setup.questions)) {
        foreach ($side in 'yes', 'no') { foreach ($k in 'addIds', 'removeIds') { foreach ($id in @(Get-Prop (Get-Prop $q $side $null) $k @())) { $profIds.Add([string]$id) } } }
    }
    $missing = @($profIds | Select-Object -Unique | Where-Object { -not $byIdRow.ContainsKey($_) })
    Assert-That ($missing.Count -eq 0) "every id used by a profile or question exists in the catalog$(if ($missing.Count) { ': ' + ($missing -join ', ') })"
    $forbidden = @($profIds | Select-Object -Unique | Where-Object { $byIdRow.ContainsKey($_) -and ($byIdRow[$_].Preset -eq 'never-default' -or $byIdRow[$_].Risk -eq 'reduces-security') })
    Assert-That ($forbidden.Count -eq 0) "no profile contains a never-default or reduces-security tweak$(if ($forbidden.Count) { ': ' + ($forbidden -join ', ') })"
    Assert-That ((Get-DefaultProfileName $true 'Laptop') -eq 'work-managed' -and (Get-DefaultProfileName $false 'Laptop') -eq 'personal-laptop' -and (Get-DefaultProfileName $false 'Desktop') -eq 'personal-desktop') 'default profile: managed -> work-managed, then laptop / desktop'
    $ansWm = Get-ProfileAnswers $setup 'work-managed' $true 'Laptop'
    Assert-That ($ansWm['work'] -eq $true -and $ansWm['laptop'] -eq $true -and $ansWm['gaming'] -eq $false) 'work-managed answers: work and laptop are detected from the device'
    $ansPd = Get-ProfileAnswers $setup 'personal-desktop' $false 'Laptop'
    Assert-That ($ansPd['work'] -eq $false -and $ansPd['laptop'] -eq $false) 'personal-desktop answers are fixed by the profile, not by the device'

    $profBad = New-Object System.Collections.Generic.List[string]
    foreach ($pn in $setup.profiles.PSObject.Properties.Name) {
        foreach ($variant in 0..3) {
            $a = Get-ProfileAnswers $setup $pn ([bool]$m.isManaged) ([string]$eng.Os.chassis)
            if ($variant -band 1) { $a['appx'] = $true; $a['keepxbox'] = $false; $a['keepphone'] = $false }
            if ($variant -band 2) { $a['gaming'] = (-not $a['gaming']); $a['laptop'] = (-not $a['laptop']) }
            $res = Resolve-SetupProfile -Setup $setup -Option $sd.Option -ProfileName $pn -Answers $a -Rows $rows
            foreach ($id in @($res.Selected)) {
                $r = $byIdRow[$id]
                if (-not $r.CanCheck -or $r.IsUnverified -or $r.Status -eq 'Applied' -or $r.Status -eq 'Skipped' -or $r.Preset -ne 'safe') { $profBad.Add("${pn}/${variant}: $id selected although it cannot or should not be ticked") }
            }
            if (@($res.Unknown).Count) { $profBad.Add("${pn}/${variant}: unknown ids " + (@($res.Unknown) -join ',')) }
            $classified = @($res.Selected).Count + @($res.AlreadyApplied).Count + @($res.Unverified).Count + @($res.Skipped).Count + @($res.NotEnabled).Count + @($res.Excluded).Count
            if ($classified -lt @($res.Selected).Count) { $profBad.Add("$pn/${variant}: classification lost ids") }
            if ($pn -eq 'work-managed' -and ($res.AppxProfile -or @($res.NotEnabled | Where-Object { $_.Id -like 'appx-*' }).Count)) { $profBad.Add("$pn/${variant}: work-managed must never plan app removal") }
            if ($pn -eq 'work-managed' -and @($res.NotEnabled).Count) { $profBad.Add("$pn/${variant}: work-managed must stay inside the safe set (" + (($res.NotEnabled | ForEach-Object { $_.Id }) -join ',') + ')') }
        }
    }
    foreach ($b in $profBad) { Write-Output "    profile: $b" }
    Assert-That ($profBad.Count -eq 0) 'every profile x answer variant resolves to ticks the engine can run; work-managed never plans app removal'
    $ansP = Get-ProfileAnswers $setup 'personal-desktop' $false 'Desktop'; $ansP['appx'] = $true; $ansP['keepxbox'] = $false; $ansP['keepphone'] = $false
    $resP = Resolve-SetupProfile -Setup $setup -Option $sd.Option -ProfileName 'personal-desktop' -Answers $ansP -Rows $rows
    $np = @($resP.NotEnabled | ForEach-Object { $_.Id })
    Assert-That ($resP.AppxProfile -eq 'keep-personal' -and $resP.NeedsAck -and $resP.AckText -match 'reinstalled from the Store' -and $np -contains 'appx-profile-keep-personal' -and $np -contains 'appx-xbox-gaming' -and $np -contains 'appx-crossdevice-yourphone') 'AppX answers: keep-personal profile planned, Xbox / Phone Link removal planned when not kept, acknowledgement required, all listed as not enabled'
    $ansP2 = Get-ProfileAnswers $setup 'personal-desktop' $false 'Desktop'
    $resP2 = Resolve-SetupProfile -Setup $setup -Option $sd.Option -ProfileName 'personal-desktop' -Answers $ansP2 -Rows $rows
    Assert-That ($null -eq $resP2.AppxProfile -and -not $resP2.NeedsAck -and (@($resP2.NotEnabled | Where-Object { $_.Id -like 'appx-*' }).Count -eq 0)) 'without the AppX answer no app removal is planned and no acknowledgement is needed'
    $ansL = Get-ProfileAnswers $setup 'personal-desktop' $false 'Desktop'; $ansL['laptop'] = $true
    $resL = Resolve-SetupProfile -Setup $setup -Option $sd.Option -ProfileName 'personal-desktop' -Answers $ansL -Rows $rows
    Assert-That (@($resL.Excluded) -contains 'pwr-hibernate-off' -and (@($resL.NotEnabled | ForEach-Object { $_.Id }) -contains 'pwr-hiberfile-reduced') -and @($resL.Selected) -notcontains 'pwr-fast-startup-off') 'laptop answer: hibernate off is left out, the reduced hibernation file is planned, Fast Startup stays'
    $ansG = Get-ProfileAnswers $setup 'gaming-desktop' $false 'Desktop'
    $resG = Resolve-SetupProfile -Setup $setup -Option $sd.Option -ProfileName 'gaming-desktop' -Answers $ansG -Rows $rows
    Assert-That ((@($resG.NotEnabled | ForEach-Object { $_.Id }) -contains 'pwr-ultra-performance-plan') -and (@($resG.Unverified) + @($resG.AlreadyApplied) + @($resG.Skipped | ForEach-Object { $_.Id }) -contains 'gaming-gamedvr-appcapture-user-off')) 'gaming answer: performance power plan planned (not enabled), the unverified Game DVR tweak is listed but not ticked'
    Assert-That (@(Format-ProfilePlan $resP).Count -ge 3) 'Format-ProfilePlan builds the plan sections'

    # profiles tab against the window (what Load-Data does after the engine answered)
    $script:Rows = $rows; $script:Managed = $m; $script:OsInfo = $eng.Os; $script:Preflight = $eng.Preflight
    $script:SetupData = $null; $script:ProfileInit = $false
    Initialize-ProfilesTab
    $expectProfile = Get-DefaultProfileName ([bool]$m.isManaged) ([string]$eng.Os.chassis)
    Assert-That ([string]$win.FindName('cmbProfile').SelectedItem -eq $expectProfile) "Profiles tab preselects '$expectProfile' for this device (managed=$($m.isManaged), chassis=$($eng.Os.chassis))"
    Assert-That ($win.FindName('profileQuestions').Children.Count -eq (2 * @($setup.questions).Count) -and $script:QuestionBoxes.Count -eq @($setup.questions).Count) 'Profiles tab shows one check box and one hint per question'
    Assert-That ($win.FindName('profilePanel').Children.Count -ge 3) 'Profiles tab shows the plan'
    $script:QuestionBoxes['appx'].IsChecked = $true; Update-ProfilePlan
    Assert-That (($win.FindName('chkProfileAck').Visibility -eq 'Visible') -eq [bool]$script:ProfileResult.NeedsAck) 'acknowledgement box follows the AppX answer (hidden on a work PC, where app removal is forced off)'
    $script:QuestionBoxes['appx'].IsChecked = $false; Update-ProfilePlan
    $win.FindName('chkProfileAck').IsChecked = $false
    Select-ProfileInGrid
    Assert-That ((@($rows | Where-Object Checked).Count) -eq @($script:ProfileResult.Selected).Count -and @($rows | Where-Object { $_.Checked -and -not $_.CanCheck }).Count -eq 0) 'selecting a profile ticks exactly its resolved tweaks (only ones the engine can run)'
    Clear-Selection $rows
    $script:Rows = $null; $script:SetupData = $null; $script:ProfileInit = $false

    # drift: real, read-only
    $dr = Invoke-EngineSync -EngineArgs @('-Drift', '-AsJson', '-IncludeUnverified')
    Assert-That ($dr.ExitCode -eq 0) "engine -Drift -AsJson exit 0 (got $($dr.ExitCode))"
    $driftReal = Read-JsonObject $dr.Stdout 'Engine -Drift'
    Assert-That ($driftReal.mode -eq 'drift' -and $null -ne $driftReal.summary -and $null -ne $driftReal.os) 'engine -Drift -AsJson: mode drift, summary and os present'
    $realRows = ConvertTo-DriftRows $driftReal
    Assert-That (@($realRows).Count -eq @($driftReal.tweaks).Count) "drift rows = drift tweaks ($(@($realRows).Count); an empty list is valid when nothing was applied)"
    Show-DriftDoc $driftReal
    Assert-That ($win.FindName('txtDriftSummary').Text.Length -gt 10) 'Drift tab summary is filled for the real state'
    $rv = Invoke-EngineSync -EngineArgs (Get-RevertEngineArgs $true) -Ids @('ui-explorer-show-extensions') -IdSwitch '-Revert'
    $rvOk = ($rv.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($rv.Stdout) -and $rv.Stderr -match 'Nothing to revert') -or ($rv.ExitCode -eq 0 -and ($rv.Stdout | ConvertFrom-Json).mode -eq 'revert' -and ($rv.Stdout | ConvertFrom-Json).dryRun -eq $true)
    Assert-That $rvOk "engine -Revert <id> -WhatIf -AsJson: nothing to revert (exit 1, stderr only) or a pure JSON preview (exit $($rv.ExitCode))"
    $rp = Invoke-EngineSync -EngineArgs @('-Drift', '-Reapply', '-WhatIf', '-AsJson', '-IncludeUnverified')
    $rpDoc = Read-JsonObject $rp.Stdout 'Engine -Drift -Reapply -WhatIf'
    Assert-That ($rp.ExitCode -eq 0 -and $rpDoc.mode -eq 'drift' -and $null -ne $rpDoc.reapply) 'engine -Drift -Reapply -WhatIf -AsJson: pure JSON with a reapply object, exit 0'
    # drift through the tab fill code with a fake document
    $fakeDoc = [pscustomobject]@{
        mode = 'drift'; snapshots = 2; banner = 'Windows reverted 1 tweak(s) since build 26100.1; this system is on build 26200.1'
        summary = [pscustomobject]@{ tweaks = 2; inSync = 1; drifted = 1; unknown = 0; driftedSteps = 1 }
        tweaks = @(
            [pscustomobject]@{ id = 'a-one'; status = 'Drifted'; driftedSteps = 1; appliedBuilds = @('26100.1'); buildChanged = $true; inCatalog = $true; notApplicable = $false
                steps = @([pscustomobject]@{ type = 'registry'; target = 'HKCU:\Software\X\A'; desired = 1; current = 5; state = 'Drifted'; note = ''; run = 'r1'; appliedBuild = '26100.1' }) },
            [pscustomobject]@{ id = 'b-two'; status = 'InSync'; driftedSteps = 0; appliedBuilds = @('26100.1'); buildChanged = $true; inCatalog = $false; notApplicable = $true
                steps = @([pscustomobject]@{ type = 'service'; target = 'Svc'; desired = 'Disabled'; current = 'Disabled'; state = 'InSync'; note = ''; run = 'r1'; appliedBuild = '26100.1' }) })
    }
    $fr = ConvertTo-DriftRows $fakeDoc
    Assert-That (@($fr).Count -eq 2 -and $fr[0].Status -eq 'Drifted' -and $fr[0].StatusColor -eq '#E57373' -and $fr[1].Note -match 'no longer in the catalog' -and $fr[1].Note -match 'no longer applicable') 'ConvertTo-DriftRows: status colour and the catalog / applicability notes'
    Assert-That ((Format-DriftSummary $fakeDoc) -match '2 applied tweak\(s\) in 2 snapshot\(s\): 1 in effect, 1 drifted \(1 step') 'Format-DriftSummary reads the summary'
    Assert-That ((Format-DriftSummary ([pscustomobject]@{ snapshots = 0; summary = [pscustomobject]@{ tweaks = 0 } })) -match 'nothing to compare') 'Format-DriftSummary: no snapshots is explained, not an error'
    $steps = ConvertTo-DriftStepRows $fr[0]
    Assert-That (@($steps).Count -eq 1 -and $steps[0].desiredText -eq '1' -and $steps[0].currentText -eq '5' -and $steps[0].state -eq 'Drifted') 'ConvertTo-DriftStepRows: applied and current values as text'
    $script:DriftDoc = $fakeDoc
    Show-DriftDoc $fakeDoc
    Assert-That (@($win.FindName('driftGrid').ItemsSource).Count -eq 2 -and $win.FindName('txtDriftBanner').Text -match 'Windows reverted') 'Drift tab shows the rows and the Windows-reverted banner'
    Assert-That ($win.FindName('btnDriftReapply').IsEnabled -and $win.FindName('btnDriftPreview').IsEnabled) 'Re-apply buttons are enabled when something drifted'
    $win.FindName('driftGrid').SelectedIndex = 0
    Show-DriftSteps ($win.FindName('driftGrid').SelectedItem)
    Assert-That (@($win.FindName('driftStepGrid').ItemsSource).Count -eq 1 -and $win.FindName('btnDriftRevert').IsEnabled) 'selecting a drift row shows its steps and enables Revert'
    $script:DriftDoc = [pscustomobject]@{ summary = [pscustomobject]@{ tweaks = 1; inSync = 1; drifted = 0; unknown = 0; driftedSteps = 0 }; tweaks = @(); snapshots = 1 }
    Update-ActionStates
    Assert-That (-not $win.FindName('btnDriftReapply').IsEnabled) 'Re-apply buttons are disabled when nothing drifted'
    $script:DriftDoc = $null; Show-DriftDoc ([pscustomobject]@{ summary = [pscustomobject]@{ tweaks = 0 }; tweaks = @(); snapshots = 0 })

    # footprint: real, read-only (no admin), then the comparison code with two temp reports
    Assert-That (Test-Path -LiteralPath $FootprintScriptPath) "footprint tool found: $FootprintScriptPath"
    Assert-That ((Get-FpPath 'baseline') -notlike "$env:ProgramData*" -and (Get-FpPath 'beforeRun') -notlike "$env:SystemRoot*") 'footprint files are never under ProgramData or the Windows folder'
    $fa = Get-FootprintSaveArgs 'beforeRun'
    Assert-That ($fa[0] -eq '-Baseline' -and $fa[1] -match "^'.*footprint-before-last-run\.json'$" -and $fa -contains '-Force' -and $fa -contains '-AsJson') 'pre-run footprint arguments: -Baseline <path> -Force -AsJson'
    $fp = Invoke-EngineSync -EngineArgs @('-AsJson') -ScriptPath $FootprintScriptPath
    Assert-That ($fp.ExitCode -eq 0) "Get-FootprintReport.ps1 -AsJson exit 0 (got $($fp.ExitCode))"
    $fpDoc = Read-JsonObject $fp.Stdout 'Get-FootprintReport.ps1'
    Assert-That ($fpDoc.schemaVersion -eq 1 -and $fpDoc.processes.count -gt 0 -and $fpDoc.services.total -gt 0 -and $fpDoc.disk.totalBytes -gt 0) 'footprint report: schema 1 with process, service and disk numbers'
    $nowRows = ConvertTo-FootprintNowRows $fpDoc
    Assert-That (@($nowRows | Where-Object { $_.Metric -eq 'Running processes' }).Count -eq 1 -and @($nowRows).Count -ge 10) 'ConvertTo-FootprintNowRows: process, service, AppX and disk rows'
    $hdr = Format-FootprintHeader $fpDoc $null
    Assert-That ($hdr -match "^Footprint now: $($fpDoc.processes.count) processes, \d+ of \d+ services running" -and $hdr -match 'AppX packages') 'Format-FootprintHeader: counts in the banner line'
    Assert-That ((Format-FpBytes 1536MB) -eq '1.5 GB' -and (Format-FpBytes (-2MB) -Signed) -eq '-2.0 MB' -and (Format-FpBytes 0 -Signed) -eq '0 B') 'Format-FpBytes: GB / MB / signed'
    $fdir = Join-Path ([IO.Path]::GetTempPath()) ("dk-gui-fp-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $fdir | Out-Null
        $fBefore = Join-Path $fdir 'before.json'; $fAfter = Join-Path $fdir 'after.json'
        $b = $fp.Stdout | ConvertFrom-Json; $b.processes.count = 480; $b.services.running = 150; $b.appx.userCount = 117; $b.disk.freeBytes = 50GB
        $a = $fp.Stdout | ConvertFrom-Json; $a.processes.count = 470; $a.services.running = 140; $a.appx.userCount = 100; $a.disk.freeBytes = 52GB
        Set-Content -LiteralPath $fBefore -Value ($b | ConvertTo-Json -Depth 8) -Encoding UTF8
        Set-Content -LiteralPath $fAfter -Value ($a | ConvertTo-Json -Depth 8) -Encoding UTF8
        $cm = Invoke-EngineSync -EngineArgs ((Get-FootprintCompareArgs $fBefore) + @('-With', ("'" + $fAfter + "'"))) -ScriptPath $FootprintScriptPath
        Assert-That ($cm.ExitCode -eq 0) "Get-FootprintReport.ps1 -Compare -With exit 0 (got $($cm.ExitCode))"
        $cmp = Read-JsonObject $cm.Stdout 'Get-FootprintReport.ps1 -Compare'
        $cmpRows = ConvertTo-FootprintRows $cmp
        $pr = @($cmpRows | Where-Object { $_.Metric -eq 'Running processes' })[0]
        Assert-That ($pr -and $pr.Before -eq '480' -and $pr.Now -eq '470' -and $pr.Change -eq '-10' -and $pr.Verdict -eq 'better' -and $pr.VerdictColor -eq '#81C784') 'ConvertTo-FootprintRows: 480 -> 470 processes is -10 and better'
        $fr2 = @($cmpRows | Where-Object { $_.Metric -eq 'System drive free' })[0]
        Assert-That ($fr2 -and $fr2.Before -eq '50.0 GB' -and $fr2.Now -eq '52.0 GB' -and $fr2.Change -eq '+2.0 GB') 'ConvertTo-FootprintRows: bytes are shown as GB with a sign'
        $hdr2 = Format-FootprintHeader $a $cmp
        Assert-That ($hdr2 -match 'Since before the last run: processes -10, services running -10, AppX -17, free disk \+2\.0 GB') 'Format-FootprintHeader: "since before the last run" line from the comparison'
        $win.FindName('fpGrid').ItemsSource = $cmpRows
        Assert-That (@($win.FindName('fpGrid').ItemsSource).Count -eq @($cmpRows).Count) 'Footprint tab grid accepts the comparison rows'
        Show-FootprintCompare $cmp 'baseline' 'Saved baseline (test)'
        Assert-That ($win.FindName('txtFpHeader').Text -match 'Compared with: Saved baseline \(test\)\. \d+ better, \d+ worse\.') 'Footprint tab header names the report and counts better / worse'
        $script:FpBeforeRun = $null
    } finally { Remove-Item -LiteralPath $fdir -Recurse -Force -ErrorAction SilentlyContinue }
    Assert-That ((Test-Path -LiteralPath (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdExisted) 'the WP7 checks did not create or remove the DebloatKit state folder in ProgramData'

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

function Invoke-SandboxSelfTest {
    # -SelfTest with -TestEnvironment (used by tests\Test-Engine.ps1): the revert / drift / re-apply command paths of the GUI against a
    # throwaway state folder (-StateDir), the fake environment file and a test catalog (-CatalogPath), which Test-Engine prepared.
    # Expects w5-a (in effect) and w5-b (changed by hand after the apply, so drifted) to be applied in that state folder.
    $fail = New-Object System.Collections.Generic.List[string]
    function Assert-That([bool]$Cond, [string]$Msg) {
        if ($Cond) { Write-Output "  ok   $Msg" } else { Write-Output "  FAIL $Msg"; $fail.Add($Msg) }
    }
    Write-Output "DebloatKit-GUI sandbox self-test (host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
    $script:Window = Read-Xaml $script:MainXaml
    Assert-That ([bool]$StateDir -and (Test-Path -LiteralPath $StateDir)) 'sandbox state folder given and present'
    $lst = Invoke-EngineSync -EngineArgs @('-List', '-AsJson', '-IncludeUnverified')
    $eng = Get-EngineList $lst
    $rows = New-TweakRows -Catalog (Read-CatalogFile $CatalogPath) -EngineTweaks $eng.Tweaks
    Assert-That ($rows.Count -gt 0) "rows built from the test catalog through the engine ($($rows.Count))"

    $dr = Invoke-EngineSync -EngineArgs @('-Drift', '-AsJson', '-IncludeUnverified')
    Assert-That ($dr.ExitCode -eq 0) "engine -Drift -AsJson through the GUI command path: exit 0 (got $($dr.ExitCode))"
    $doc = Read-JsonObject $dr.Stdout 'Engine -Drift'
    $drows = ConvertTo-DriftRows $doc
    $dA = @($drows | Where-Object Id -EQ 'w5-a')[0]; $dB = @($drows | Where-Object Id -EQ 'w5-b')[0]
    Assert-That ($dA -and $dA.Status -eq 'InSync') 'drift: w5-a is in sync'
    Assert-That ($dB -and $dB.Status -eq 'Drifted' -and $dB.DriftedSteps -ge 1) 'drift: w5-b (changed by hand) is drifted'
    Assert-That ((Format-DriftSummary $doc) -match 'drifted') 'drift summary text is built'
    $stepsB = ConvertTo-DriftStepRows $dB
    Assert-That (@($stepsB).Count -ge 1 -and $stepsB[0].state -eq 'Drifted' -and $stepsB[0].currentText -ne '') 'drift steps of w5-b show the current value'

    Update-RowTracking $rows $doc
    $rA = $rows | Where-Object Id -EQ 'w5-a'
    $actA = Get-RowAction $rA
    Assert-That ($rA.Status -eq 'Applied' -and $actA -and $actA.Kind -eq 'Revert') 'row w5-a is applied and tracked: the toggle is Revert'
    $rowsPlain = $rows | Where-Object { $_.Status -eq 'Applied' -and -not $_.Tracked }
    Assert-That (@($rowsPlain | Where-Object { $_.CanToggle }).Count -eq 0) 'applied rows without a snapshot record cannot be reverted'

    $rv = Invoke-EngineSync -EngineArgs (Get-RevertEngineArgs $true) -Ids @('w5-a') -IdSwitch '-Revert'
    $rvDoc = Read-JsonObject $rv.Stdout 'Engine -Revert -WhatIf'
    Assert-That ($rv.ExitCode -eq 0 -and $rvDoc.mode -eq 'revert' -and $rvDoc.dryRun -eq $true -and $rvDoc.results[0].result -eq 'WouldRevert') 'GUI revert preview command: pure JSON, WouldRevert for w5-a'

    $rp = Invoke-EngineSync -EngineArgs @('-Drift', '-Reapply', '-WhatIf', '-AsJson', '-IncludeUnverified')
    $rpDoc = Read-JsonObject $rp.Stdout 'Engine -Drift -Reapply -WhatIf'
    $plan = @(Get-Prop (Get-Prop $rpDoc 'reapply' $null) 'plan' @())
    Assert-That ($rp.ExitCode -eq 0 -and @($plan | Where-Object { $_.tweakId -eq 'w5-b' -and $_.action -eq 'Change' }).Count -ge 1 -and @($plan | Where-Object { $_.tweakId -eq 'w5-a' -and $_.action -eq 'Change' }).Count -eq 0) 'GUI re-apply preview command: plans only the drifted tweak (w5-b)'

    # The engine accepts -TestEnvironment for a real run only when the test runner set DEBLOATKIT_TESTENV=1 (tests\Test-Engine.ps1 does).
    if ((Test-Elevated) -and $env:DEBLOATKIT_TESTENV -eq '1') {
        $rr = Invoke-EngineSync -EngineArgs (Get-RevertEngineArgs) -Ids @('w5-a') -IdSwitch '-Revert'
        Assert-That ($rr.ExitCode -eq 0) "GUI revert command (real, against the sandbox): exit 0 (got $($rr.ExitCode))"
        $after = Invoke-EngineSync -EngineArgs @('-Drift', '-AsJson', '-IncludeUnverified')
        $afterDoc = Read-JsonObject $after.Stdout 'Engine -Drift'
        Assert-That (@($afterDoc.tweaks | Where-Object { $_.id -eq 'w5-a' }).Count -eq 0 -and @($afterDoc.tweaks | Where-Object { $_.id -eq 'w5-b' }).Count -eq 1) 'after the revert the tweak is gone from the drift list and the other one is untouched'
    } else { Write-Output '  skip real revert (not elevated, or DEBLOATKIT_TESTENV is not 1); the preview paths above ran' }

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

function New-Brush([string]$Hex) {
    $mapped = $script:DarkMap[$Hex.ToUpperInvariant()]
    if ($mapped) { $Hex = $mapped }
    (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Set-Status([string]$Text) { (Get-Ctl 'txtStatus').Text = $Text }

$script:BusyButtons = @('btnRecommended', 'btnClear', 'btnPreview', 'btnApply', 'btnUndo', 'btnRefresh',
    'btnProfileSelect', 'btnDriftRefresh', 'btnDriftPreview', 'btnDriftReapply', 'btnDriftRevert', 'btnFpMeasure', 'btnFpSave', 'btnFpCompare')

function Set-Busy([bool]$Busy, [string]$Text = 'Loading...', [switch]$Quiet) {
    # -Quiet: a background read (drift, footprint): the buttons are disabled, but the grid overlay stays hidden.
    $script:Busy = $Busy
    (Get-Ctl 'loadingOverlay').Visibility = $(if ($Busy -and -not $Quiet) { 'Visible' } else { 'Collapsed' })
    (Get-Ctl 'txtLoading').Text = $Text
    if ($Busy) { $pb = Get-Ctl 'pbLoading'; $pb.IsIndeterminate = $true; $pb.Value = 0 }
    foreach ($b in $script:BusyButtons) { (Get-Ctl $b).IsEnabled = -not $Busy }
    # the per-row toggles are buttons inside the grid; keep them out of reach while a run is going
    (Get-Ctl 'grid').IsEnabled = (-not $Busy) -or [bool]$Quiet
    if (-not $Busy) { Update-ActionStates }
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
        $banner.Background = New-Brush '#FFF3E0'; $banner.BorderBrush = New-Brush '#8A6224'
        (Get-Ctl 'chkManaged').Visibility = 'Visible'
    } elseif ($m) {
        $txt.Text = 'This device does not look managed (not Entra ID joined, domain joined or MDM enrolled).'
        $banner.Background = New-Brush '#E8F5E9'; $banner.BorderBrush = New-Brush '#C8E6C9'
        (Get-Ctl 'chkManaged').Visibility = 'Collapsed'
    }
    $pfTxt = Get-Ctl 'txtPreflight'
    $pfTxt.Text = Format-PreflightText $script:Preflight $script:OsInfo
    $pfTxt.ToolTip = $(if ($script:Preflight) { Format-PreflightChecks $script:Preflight } else { $null })   # every gate with its detail
    (Get-Ctl 'txtFootprint').Text = Format-FootprintHeader $script:FpNow $script:FpBeforeRun
    $blocked = [bool]($script:Preflight -and (Get-Prop $script:Preflight 'blocked' $false))
    $pfTxt.Foreground = New-Brush $(if ($blocked) { $script:TextAmber } else { $script:TextGreen })
    (Get-Ctl 'chkSkipPreflight').Visibility = $(if ($blocked) { 'Visible' } else { 'Collapsed' })
    $el = Get-Ctl 'txtElevation'
    if (Test-Elevated) { $el.Text = 'Elevated: yes'; $el.Foreground = New-Brush $script:TextGreen }
    else { $el.Text = 'Elevated: no (UAC prompt when applying or undoing)'; $el.Foreground = New-Brush $script:TextAmber }
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
            $catalog = Read-CatalogFile $CatalogPath
            $script:Managed = $eng.Managed
            $script:Preflight = $eng.Preflight
            $script:OsInfo = $eng.Os
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
            Initialize-ProfilesTab
            # drift tells which tweaks have a snapshot record (enables Revert); the footprint feeds the banner line
            Add-Followup 'drift' { Load-Drift }
            Add-Followup 'footprint' { Load-Footprint }
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

function Update-RunProgress($Handle) {
    # Elevated runs tee the engine output to a log file; show the weighted progress the engine prints.
    if (-not $Handle.Elevated -or -not $Handle.Log) { return }
    try {
        if (-not (Test-Path -LiteralPath $Handle.Log)) { return }
        $fs = [IO.File]::Open($Handle.Log, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        $pct = Get-ProgressPercent $text
        if ($null -ne $pct) {
            $pb = Get-Ctl 'pbLoading'; $pb.IsIndeterminate = $false; $pb.Value = $pct
            (Get-Ctl 'txtLoading').Text = "Running in the elevated window... $pct%"
        }
    } catch { }
}

$script:Timer.Add_Tick({
    if (-not $script:Job) { $script:Timer.Stop(); return }
    Update-RunProgress $script:Job.Handle
    $p = $script:Job.Handle.Process
    if (-not $p.HasExited) { return }
    $script:Timer.Stop()
    $job = $script:Job; $script:Job = $null
    $res = Read-EngineResult $job.Handle
    try { & $job.OnDone $res }
    catch { Set-Busy $false; Set-Status "Error: $($_.Exception.Message)" }
    Start-NextFollowup   # drift / footprint reads that were waiting for this process
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
    $bg = New-Brush $Color
    $bd.Background = $bg; $bd.CornerRadius = 3; $bd.Padding = '7,2'; $bd.Margin = '0,0,6,4'
    $tb = New-Object System.Windows.Controls.TextBlock
    # Risk/status colours are light text tints in the dark theme; put dark text on those badges.
    $c = $bg.Color
    $light = (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) -gt 150
    $tb.Text = $Text; $tb.Foreground = $(if ($light) { New-Brush '#1B1C1F' } else { [System.Windows.Media.Brushes]::White }); $tb.FontSize = 11.5
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
    if ($Row.Note -and $Row.Preset -eq 'safe') { Add-DetailText $panel $(if ($Row.Status -eq 'Skipped') { 'Why the engine skips it here (managed device / applicability / not present)' } else { 'Engine note' }) $Row.Note }
    if ($Row.HasToggle) {
        # Apply / Revert for just this tweak (the same actions as the toggle in the grid)
        $bp = New-Object System.Windows.Controls.WrapPanel
        $bp.Margin = '0,6,0,0'
        $b1 = New-Object System.Windows.Controls.Button
        $b1.Content = $(if ($Row.Status -eq 'Applied') { 'Revert this tweak' } else { 'Apply this tweak' }); $b1.IsEnabled = $Row.CanToggle; $b1.ToolTip = $Row.ToggleTip
        $b1.Add_Click({ Invoke-RowAction $Row }.GetNewClosure())
        [void]$bp.Children.Add($b1)
        if ($Row.Status -eq 'Partial') {
            $b2 = New-Object System.Windows.Controls.Button
            $b2.Content = 'Revert this tweak'; $b2.IsEnabled = [bool]$Row.Tracked
            $b2.ToolTip = $(if ($Row.Tracked) { 'Restore the values saved before DebloatKit changed this tweak.' } else { 'DebloatKit has no snapshot record for this tweak, so there is nothing to restore.' })
            $b2.Add_Click({ Invoke-RowAction $Row 'Revert' }.GetNewClosure())
            [void]$bp.Children.Add($b2)
        }
        [void]$panel.Children.Add($bp)
    }

    Add-DetailText $panel 'What it does' ([string](Get-Prop $d 'explanation' ''))
    Add-DetailText $panel 'Measured effect' ([string](Get-Prop $d 'measuredEffect' 'Not measured.'))
    Add-DetailText $panel 'Who benefits' ([string](Get-Prop $d 'whoBenefits' ''))
    Add-DetailText $panel 'Trade-off' ([string](Get-Prop $d 'tradeoff' ''))
    $breaks = Get-Prop $d 'breaks' $null
    Add-DetailText $panel 'What it can break' $(if ($breaks) { [string]$breaks } else { 'Nothing documented.' })
    $mdi = Get-Prop $d 'managedDeviceImpact' $null
    if ($mdi) { Add-DetailText $panel 'On a managed (Intune / Entra) device' ([string]$mdi) }
    $msk = Get-Prop $d 'managedSkip' $null
    if ($msk) { Add-DetailText $panel 'Skipped on managed devices' ("The engine skips this tweak on an Entra joined, domain joined or MDM enrolled device, even with -Force: " + [string]$msk) }
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
    $w.FindName('txtSummary').Text = "Preview (nothing was changed): $change step(s) would change (work: $(Measure-PlanWeight $Plan) weight unit(s)), $sync already in effect, $skip skipped. Steps already in effect are hidden. Steps run in the order shown by the Order hints, then catalog order."
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
    elseif ($code -eq 1 -and $Title -like 'Revert*') { "(the engine exited with code 1 without writing any output.`nCommon causes: there is no unreverted DebloatKit snapshot record for the tweak (it was already in effect before DebloatKit, or it was reverted before); the elevated process ran as a different user than this window (UAC with other credentials; per-user HKCU steps would land in the wrong profile); the UAC prompt was declined.`nRevert is never blocked by the preflight check or the managed-device check. Run DebloatKit.ps1 -Revert <id> -WhatIf in a PowerShell to see the reason.)" }
    elseif ($code -eq 1) { "(the engine exited with code 1 without writing any output.`nCommon causes: the preflight check failed (pending reboot, Windows servicing running, on battery, low disk space; tick the preflight box to override); System Protection is off so the restore point could not be created; there is no snapshot to undo; the device is managed and the confirmation box was not ticked; the UAC prompt ran as a different user.`nCheck $env:ProgramData\DebloatKit for run-*.log.jsonl, or run DebloatKit.ps1 -WhatIf in an elevated PowerShell to see the reason.)" }
    else { '(no output captured; the elevated window may have been closed early)' }
    Show-TextDialog $Title $head $body
}

# ---- footprint files (written only by Get-FootprintReport.ps1 -Baseline, under the user's profile, never ProgramData) ----
function Get-FpPath([string]$Which) {
    Join-Path $FootprintDir $(if ($Which -eq 'baseline') { 'footprint-baseline.json' } else { 'footprint-before-last-run.json' })
}

function Get-FootprintSaveArgs([string]$Which) {
    # Tokens for: Get-FootprintReport.ps1 -Baseline '<path>' -Force -AsJson (the tool refuses the Windows folder and ProgramData\DebloatKit).
    @('-Baseline', ("'" + (Get-FpPath $Which).Replace("'", "''") + "'"), '-Force', '-AsJson')
}

function Get-FootprintCompareArgs([string]$Path) {
    @('-Compare', ("'" + $Path.Replace("'", "''") + "'"), '-AsJson')
}

function Start-PreRunFootprint {
    # Before an elevated run: save the current footprint as "before the last run" (read-only measurement, ~2 s). $null when it cannot start.
    try { Start-EngineProcess -EngineArgs (Get-FootprintSaveArgs 'beforeRun') -ScriptPath $FootprintScriptPath } catch { $null }
}

# ---- queue of follow-up reads (drift, footprint) that wait for the current process ----
$script:Followups = New-Object System.Collections.ArrayList
function Add-Followup([string]$Key, [scriptblock]$Fn) {
    foreach ($f in $script:Followups) { if ($f.Key -eq $Key) { return } }
    [void]$script:Followups.Add([pscustomobject]@{ Key = $Key; Fn = $Fn })
    Start-NextFollowup
}
function Start-NextFollowup {
    if ($script:Job -or $script:Busy -or $script:Followups.Count -eq 0) { return }
    $f = $script:Followups[0]; $script:Followups.RemoveAt(0)
    & $f.Fn
}

function Start-ElevatedEngine([string]$Title, [string[]]$EngineArgs, [string[]]$Ids, [string]$IdSwitch) {
    Set-Busy $true "$Title running in an elevated window..."
    Set-Status "${Title}: waiting for the elevated engine process (accept the UAC prompt)..."
    try { $h = Start-EngineProcess -EngineArgs $EngineArgs -Ids $Ids -IdSwitch $IdSwitch -Elevated }
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

function Invoke-ElevatedRun {
    # Saves the footprint first (so the header can show "since before the last run"), then starts the elevated engine process.
    param([string]$Title, [string[]]$EngineArgs, [string[]]$Ids, [string]$IdSwitch = '-Only')
    $pre = Start-PreRunFootprint
    if (-not $pre) { Start-ElevatedEngine $Title $EngineArgs $Ids $IdSwitch; return }
    Set-Busy $true "Recording the footprint before $Title..."
    Set-Status "${Title}: recording the footprint first (read-only)..."
    $t = $Title; $ea = $EngineArgs; $ii = $Ids; $sw = $IdSwitch
    Start-Job-Async $pre ({ param($res) Start-ElevatedEngine $t $ea $ii $sw }.GetNewClosure())
}

function Get-ApplyGate {
    # The checks every apply-like run shares (Apply selected, a single row, Re-apply drifted): managed-device opt-in, preflight, local admin.
    # Returns $null after telling the user why not, else { Args; Warn }.
    $isManaged = [bool]($script:Managed -and $script:Managed.isManaged)
    $ack = [bool](Get-Ctl 'chkManaged').IsChecked
    if ($isManaged -and -not $ack) {
        [void][System.Windows.MessageBox]::Show($script:Window, "This is a managed device. Tick 'I understand this is a managed device' before applying (the engine otherwise refuses).", 'Apply', 'OK', 'Warning')
        return $null
    }
    $pfBlocked = [bool]($script:Preflight -and (Get-Prop $script:Preflight 'blocked' $false))
    $skipPf = [bool](Get-Ctl 'chkSkipPreflight').IsChecked
    if ($pfBlocked -and -not $skipPf) {
        [void][System.Windows.MessageBox]::Show($script:Window, ((Format-PreflightText $script:Preflight $script:OsInfo) + "`n`n" + (Format-PreflightChecks $script:Preflight) + "`n`nThe engine refuses to apply while this is true (a half-applied run during servicing or on battery is hard to recover from). Fix it and press Refresh, or tick 'Apply anyway' to override."), 'Apply', 'OK', 'Warning')
        return $null
    }
    $warn = ''
    if ($isManaged) { $warn += "`nWARNING: managed device. This run passes -Force and may conflict with your organisation's policy.`n" }
    if ($pfBlocked -and $skipPf) { $warn += "`nWARNING: the preflight check fails and you chose to apply anyway (-SkipPreflight).`n" }
    if (-not (Test-Elevated) -and -not (Test-InAdminGroup)) { $warn += "`nWARNING: you are not a local administrator, so the UAC prompt will ask for another admin's credentials. Per-user (HKCU) tweaks would then be written to that admin's profile. The engine detects this and refuses to apply them, but the rest of the run is unaffected.`n" }
    $a = @()
    if ($isManaged -and $ack) { $a += '-Force' }
    if ($pfBlocked -and $skipPf) { $a += '-SkipPreflight' }
    [pscustomobject]@{ Args = $a; Warn = $warn }
}

function Clear-ApplyAcks {
    (Get-Ctl 'chkSkipPreflight').IsChecked = $false   # per run, like the managed opt-in
    (Get-Ctl 'chkManaged').IsChecked = $false
}

function Invoke-Apply {
    # No argument: the ticked rows. -Rows: exactly these rows (the per-row toggle and the detail pane button).
    param([object[]]$Rows)
    $sel = if ($Rows) { @($Rows) } else { Get-CheckedRows }
    if (-not $sel.Count) { [void][System.Windows.MessageBox]::Show($script:Window, 'Tick at least one tweak first.', 'Apply', 'OK', 'Information'); return }
    $gate = Get-ApplyGate
    if (-not $gate) { return }
    $unv = @($sel | Where-Object IsUnverified)
    $ids = @($sel | ForEach-Object { $_.Id })
    $lines = ($ids | Select-Object -First 30 | ForEach-Object { '  - ' + $_ }) -join "`n"
    if ($ids.Count -gt 30) { $lines += "`n  ... and $($ids.Count - 30) more" }
    $msg = "Apply $($ids.Count) tweak(s) with the DebloatKit engine?`n`n$lines`n`n"
    $msg += "A system restore point is created first (the run aborts if that fails), and a snapshot is saved to $env:ProgramData\DebloatKit so 'Undo last run' and the per-tweak Revert can restore the exact previous values.`n"
    if ($unv.Count) { $msg += "`nWARNING: $($unv.Count) selected tweak(s) are UNVERIFIED (never tested on a real machine): $(($unv | ForEach-Object { $_.Id }) -join ', ')`n" }
    $msg += $gate.Warn
    $msg += "`nA UAC prompt follows. Continue?"
    if (-not (Confirm-Action $msg 'Confirm apply')) { Set-Status 'Apply cancelled.'; return }
    $a = @($gate.Args)
    Clear-ApplyAcks
    if ($unv.Count) { $a += '-IncludeUnverified' }
    Invoke-ElevatedRun 'Apply' $a $ids
}

function Invoke-RevertTweaks {
    # Per-tweak revert: engine -Revert <ids>, elevated. Restores the oldest saved before-state of those tweaks only.
    param([string[]]$Ids)
    if (-not $Ids -or -not $Ids.Count) { return }
    $lines = ($Ids | Select-Object -First 30 | ForEach-Object { '  - ' + $_ }) -join "`n"
    $msg = "Revert $($Ids.Count) tweak(s)?`n`n$lines`n`nThe engine restores the values saved in DebloatKit's snapshots in $env:ProgramData\DebloatKit for these tweaks only (when several runs changed the same target, the oldest saved value comes back) and marks the steps reverted there. Other tweaks stay as they are. Reverting is not blocked by the preflight check or the managed-device check.`n`nA UAC prompt follows. Continue?"
    if (-not (Test-Elevated) -and -not (Test-InAdminGroup)) { $msg = $msg.Replace('A UAC prompt follows.', "WARNING: you are not a local administrator, so the UAC prompt will ask for another admin's credentials; the engine refuses per-user (HKCU) steps then.`n`nA UAC prompt follows.") }
    if (-not (Confirm-Action $msg 'Confirm revert')) { Set-Status 'Revert cancelled.'; return }
    Invoke-ElevatedRun 'Revert' (Get-RevertEngineArgs) $Ids '-Revert'
}

function Invoke-RowAction {
    # A click on a row's toggle (or the detail pane button). -Kind forces Apply / Revert (the detail pane offers Revert for partial rows).
    param($Row, [string]$Kind = '')
    if ($script:Busy -or -not $Row) { return }
    $act = Get-RowAction $Row
    if ($Kind -and $Row.HasToggle) { $act = [pscustomobject]@{ Kind = $Kind; Ids = @($Row.Id) } }
    if (-not $act) { return }
    if ($act.Kind -eq 'Revert') { Invoke-RevertTweaks $act.Ids } else { Invoke-Apply -Rows @($Row) }
}

function Invoke-Undo {
    $msg = "Undo the last DebloatKit run?`n`nThe engine restores the values saved in the newest snapshot in $env:ProgramData\DebloatKit (it does not reset to Windows defaults). A UAC prompt follows."
    if (-not (Confirm-Action $msg 'Confirm undo')) { Set-Status 'Undo cancelled.'; return }
    Invoke-ElevatedRun 'Undo' @('-Undo', 'latest') $null
}

# ---- drift tab ----
$script:DriftDoc = $null

function Update-ActionStates {
    # Enable / disable the drift buttons from the data (Set-Busy turns every button on when a job ends).
    $n = if ($script:DriftDoc) { [int](Get-Prop (Get-Prop $script:DriftDoc 'summary' $null) 'drifted' 0) } else { 0 }
    (Get-Ctl 'btnDriftReapply').IsEnabled = ($n -gt 0 -and -not $script:Busy)
    (Get-Ctl 'btnDriftPreview').IsEnabled = ($n -gt 0 -and -not $script:Busy)
    (Get-Ctl 'btnDriftRevert').IsEnabled = ($null -ne (Get-Ctl 'driftGrid').SelectedItem -and -not $script:Busy)
}

function Show-DriftDoc($Doc) {
    $rows = ConvertTo-DriftRows $Doc
    (Get-Ctl 'driftGrid').ItemsSource = $rows
    (Get-Ctl 'driftStepGrid').ItemsSource = $null
    (Get-Ctl 'txtDriftNote').Text = $(if (@($rows).Count) { 'Select a tweak to see its steps.' } else { 'Nothing to show.' })
    (Get-Ctl 'txtDriftSummary').Text = Format-DriftSummary $Doc
    $banner = [string](Get-Prop $Doc 'banner' '')
    (Get-Ctl 'txtDriftBanner').Text = $banner
    Update-ActionStates
}

function Show-DriftSteps($Row) {
    if (-not $Row) { (Get-Ctl 'driftStepGrid').ItemsSource = $null; Update-ActionStates; return }
    (Get-Ctl 'driftStepGrid').ItemsSource = ConvertTo-DriftStepRows $Row
    $txt = "$($Row.Id): $($Row.Status)."
    if ($Row.Note) { $txt += ' ' + $Row.Note + '.' }
    (Get-Ctl 'txtDriftNote').Text = $txt
    Update-ActionStates
}

function Load-Drift {
    if ($script:Busy -or $script:Job) { Add-Followup 'drift' { Load-Drift }; return }
    Set-Busy $true 'Reading drift...' -Quiet
    Set-Status 'Reading drift (engine -Drift -AsJson, read-only)...'
    try { $h = Start-EngineProcess -EngineArgs @('-Drift', '-AsJson', '-IncludeUnverified') }
    catch { Set-Busy $false; Set-Status "Could not start the engine: $($_.Exception.Message)"; return }
    Start-Job-Async $h {
        param($res)
        Set-Busy $false
        try {
            if ($res.ExitCode -ne 0) { throw "engine -Drift failed (exit $($res.ExitCode)): $($res.Stderr) $($res.Stdout)" }
            $doc = Read-JsonObject $res.Stdout 'Engine -Drift'
            $script:DriftDoc = $doc
            Show-DriftDoc $doc
            if ($script:Rows) { Update-RowTracking $script:Rows $doc; Update-Grid }
            Set-Status ((Format-DriftSummary $doc))
        } catch {
            $script:DriftDoc = $null
            (Get-Ctl 'txtDriftSummary').Text = "Could not read drift: $($_.Exception.Message)"
            Set-Status "Drift read failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-DriftPreview {
    Set-Busy $true 'Previewing the re-apply (engine -Drift -Reapply -WhatIf)...' -Quiet
    try { $h = Start-EngineProcess -EngineArgs @('-Drift', '-Reapply', '-WhatIf', '-AsJson', '-IncludeUnverified') }
    catch { Set-Busy $false; Set-Status "Preview failed: $($_.Exception.Message)"; return }
    Start-Job-Async $h {
        param($res)
        Set-Busy $false
        try {
            if ($res.ExitCode -ne 0) { throw "Engine exit code $($res.ExitCode). $($res.Stderr) $($res.Stdout)" }
            $doc = Read-JsonObject $res.Stdout 'Engine -Drift -Reapply -WhatIf'
            $plan = @(Get-Prop (Get-Prop $doc 'reapply' $null) 'plan' @())
            if ($plan.Count) { Show-PlanDialog $plan }
            else {
                $skipped = @(Get-Prop (Get-Prop $doc 'reapply' $null) 'skipped' @())
                $why = if ($skipped.Count) { "`n`nNot eligible:`n" + (($skipped | ForEach-Object { '  - ' + (Format-Value $_) }) -join "`n") } else { '' }
                [void][System.Windows.MessageBox]::Show($script:Window, "Nothing would be re-applied.$why", 'Preview re-apply', 'OK', 'Information')
            }
        } catch { [void][System.Windows.MessageBox]::Show($script:Window, "Preview failed.`n`n$($_.Exception.Message)", 'Preview re-apply', 'OK', 'Error') }
    }
}

function Invoke-DriftReapply {
    $allRows = ConvertTo-DriftRows $script:DriftDoc
    $drifted = @($allRows | Where-Object { $_.Status -eq 'Drifted' })
    if (-not $drifted.Count) { [void][System.Windows.MessageBox]::Show($script:Window, 'Nothing has drifted; nothing to re-apply.', 'Re-apply', 'OK', 'Information'); return }
    $gate = Get-ApplyGate
    if (-not $gate) { return }
    $lines = ($drifted | Select-Object -First 30 | ForEach-Object { '  - ' + $_.Id + ' (' + $_.DriftedSteps + ' step(s))' }) -join "`n"
    $msg = "Re-apply $($drifted.Count) drifted tweak(s) with the DebloatKit engine?`n`n$lines`n`nOnly the drifted tweaks that are still in the catalog, in the enabled preset and applicable to this build are re-applied, through the normal apply path (preflight, restore point, snapshot, verify). The engine says which ones it skipped.`n"
    $msg += $gate.Warn
    $msg += "`nA UAC prompt follows. Continue?"
    if (-not (Confirm-Action $msg 'Confirm re-apply')) { Set-Status 'Re-apply cancelled.'; return }
    $a = @('-Drift', '-Reapply', '-IncludeUnverified') + @($gate.Args)
    Clear-ApplyAcks
    Invoke-ElevatedRun 'Re-apply' $a $null
}

# ---- footprint tab ----
$script:FpNow = $null
$script:FpBeforeRun = $null
$script:FpChoices = @()

function Update-FpChoices {
    $choices = @()
    foreach ($w in 'beforeRun', 'baseline') {
        $p = Get-FpPath $w
        if (Test-Path -LiteralPath $p) {
            $label = $(if ($w -eq 'baseline') { 'Saved baseline' } else { 'Before the last run' }) + ' (' + (Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ')'
            $choices += [pscustomobject]@{ Which = $w; Path = $p; Label = $label }
        }
    }
    $script:FpChoices = $choices
    Add-Combo 'cmbFpBase' @($choices | ForEach-Object { $_.Label }) $(if ($choices.Count) { $choices[0].Label } else { '' })
}

function Show-FootprintNow($Fp) {
    (Get-Ctl 'fpGrid').ItemsSource = ConvertTo-FootprintNowRows $Fp
    (Get-Ctl 'txtFpHeader').Text = Format-FootprintHeader $Fp $null
    $notes = @(Get-Prop (Get-Prop $Fp 'appx' $null) 'notes' @()) + @(if ((Get-Prop $Fp 'componentStore' $null)) { [string](Get-Prop $Fp.componentStore 'note' '') })
    (Get-Ctl 'txtFpNote').Text = ((@($notes | Where-Object { $_ })) -join ' ')
    (Get-Ctl 'txtFootprint').Text = Format-FootprintHeader $Fp $script:FpBeforeRun
}

function Load-Footprint {
    if ($script:Busy -or $script:Job) { Add-Followup 'footprint' { Load-Footprint }; return }
    Set-Busy $true 'Measuring the footprint...' -Quiet
    Set-Status 'Measuring the footprint (Get-FootprintReport.ps1 -AsJson, read-only)...'
    try { $h = Start-EngineProcess -EngineArgs @('-AsJson') -ScriptPath $FootprintScriptPath }
    catch { Set-Busy $false; Set-Status "Could not start the footprint tool: $($_.Exception.Message)"; return }
    Start-Job-Async $h {
        param($res)
        Set-Busy $false
        try {
            if ($res.ExitCode -ne 0) { throw "Get-FootprintReport.ps1 failed (exit $($res.ExitCode)): $($res.Stderr) $($res.Stdout)" }
            $script:FpNow = Read-JsonObject $res.Stdout 'Get-FootprintReport.ps1'
            Update-FpChoices
            Show-FootprintNow $script:FpNow
            Set-Status 'Footprint measured.'
            if (@($script:FpChoices | Where-Object { $_.Which -eq 'beforeRun' }).Count) { Add-Followup 'fpcmp' { Load-FootprintCompare 'beforeRun' } }
        } catch {
            (Get-Ctl 'txtFpHeader').Text = "Could not measure the footprint: $($_.Exception.Message)"
            Set-Status "Footprint failed: $($_.Exception.Message)"
        }
    }
}

function Load-FootprintCompare([string]$Which) {
    $choice = @($script:FpChoices | Where-Object { $_.Which -eq $Which }) | Select-Object -First 1
    if (-not $choice) { Set-Status 'That report does not exist yet. Save a baseline first.'; return }
    if ($script:Busy -or $script:Job) { return }
    Set-Busy $true 'Comparing the footprint...' -Quiet
    Set-Status "Comparing the footprint with: $($choice.Label)..."
    try { $h = Start-EngineProcess -EngineArgs (Get-FootprintCompareArgs $choice.Path) -ScriptPath $FootprintScriptPath }
    catch { Set-Busy $false; Set-Status "Could not start the footprint tool: $($_.Exception.Message)"; return }
    $w = $Which; $lbl = $choice.Label
    Start-Job-Async $h ({
        param($res)
        Set-Busy $false
        try {
            if ($res.ExitCode -ne 0) { throw "Get-FootprintReport.ps1 -Compare failed (exit $($res.ExitCode)): $($res.Stderr) $($res.Stdout)" }
            $cmp = Read-JsonObject $res.Stdout 'Get-FootprintReport.ps1 -Compare'
            Show-FootprintCompare $cmp $w $lbl
            Set-Status "Footprint compared with: $lbl."
        } catch {
            (Get-Ctl 'txtFpHeader').Text = "Could not compare the footprint: $($_.Exception.Message)"
            Set-Status "Footprint compare failed: $($_.Exception.Message)"
        }
    }.GetNewClosure())
}

function Show-FootprintCompare($Cmp, [string]$Which, [string]$Label) {
    (Get-Ctl 'fpGrid').ItemsSource = ConvertTo-FootprintRows $Cmp
    $better = @(Get-Prop $Cmp 'metrics' @() | Where-Object { $_.verdict -eq 'better' }).Count
    $worse = @(Get-Prop $Cmp 'metrics' @() | Where-Object { $_.verdict -eq 'worse' }).Count
    (Get-Ctl 'txtFpHeader').Text = "Compared with: $Label. $better better, $worse worse."
    (Get-Ctl 'txtFpNote').Text = ((@(Get-Prop $Cmp 'notes' @()) | ForEach-Object { [string]$_ }) -join ' ')
    if ($Which -eq 'beforeRun') { $script:FpBeforeRun = $Cmp }
    (Get-Ctl 'txtFootprint').Text = Format-FootprintHeader $script:FpNow $script:FpBeforeRun
}

function Save-FootprintBaseline {
    $p = Get-FpPath 'baseline'
    if ((Test-Path -LiteralPath $p) -and -not (Confirm-Action "Replace the saved baseline ($p)?" 'Save baseline')) { return }
    Set-Busy $true 'Saving the footprint baseline...' -Quiet
    try { $h = Start-EngineProcess -EngineArgs (Get-FootprintSaveArgs 'baseline') -ScriptPath $FootprintScriptPath }
    catch { Set-Busy $false; Set-Status "Could not start the footprint tool: $($_.Exception.Message)"; return }
    Start-Job-Async $h {
        param($res)
        Set-Busy $false
        if ($res.ExitCode -eq 0) { Update-FpChoices; Set-Status "Baseline saved to $(Get-FpPath 'baseline'). Compare with it after a run." }
        else { Set-Status "Saving the baseline failed (exit $($res.ExitCode)): $($res.Stderr) $($res.Stdout)" }
    }
}

# ---- profiles tab ----
$script:SetupData = $null
$script:ProfileInit = $false
$script:ProfileLoading = $false
$script:ProfileResult = $null
$script:QuestionBoxes = @{}

function Get-AppxProfilesPath { if ($ProfilesPath) { $ProfilesPath } else { Join-Path $script:ScriptDir 'appx-profiles.json' } }

function Get-ProfileUiAnswers {
    $a = @{}
    foreach ($k in $script:QuestionBoxes.Keys) { $a[$k] = [bool]$script:QuestionBoxes[$k].IsChecked }
    $a
}

function Set-ProfileUiAnswers([hashtable]$Answers) {
    $script:ProfileLoading = $true
    foreach ($k in $Answers.Keys) { if ($script:QuestionBoxes.ContainsKey($k)) { $script:QuestionBoxes[$k].IsChecked = [bool]$Answers[$k] } }
    $script:ProfileLoading = $false
}

function Build-ProfileQuestions {
    $panel = Get-Ctl 'profileQuestions'
    $panel.Children.Clear()
    $script:QuestionBoxes = @{}
    foreach ($q in @($script:SetupData.Setup.questions)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = [string]$q.text; $cb.FontWeight = 'SemiBold'; $cb.Margin = '0,12,0,0'; $cb.Tag = [string]$q.id
        $cb.Add_Click({ if (-not $script:ProfileLoading) { Update-ProfilePlan } })
        [void]$panel.Children.Add($cb)
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = [string](Get-Prop $q 'hint' ''); $hint.TextWrapping = 'Wrap'; $hint.Foreground = New-Brush '#607D8B'; $hint.FontSize = 11.5; $hint.Margin = '22,2,0,0'
        [void]$panel.Children.Add($hint)
        $script:QuestionBoxes[[string]$q.id] = $cb
    }
}

function Initialize-ProfilesTab {
    # Called after every data load. Builds the questions once and preselects the profile that fits this device; later calls only refresh the plan.
    if (-not $script:SetupData) {
        try { $script:SetupData = Read-SetupData $SetupProfilesPath (Get-AppxProfilesPath) }
        catch {
            $p = Get-Ctl 'profilePanel'; $p.Children.Clear()
            Add-DetailText $p 'Profiles unavailable' ("Could not read $SetupProfilesPath : " + $_.Exception.Message)
            return
        }
    }
    if (-not $script:ProfileInit) {
        Build-ProfileQuestions
        $names = @($script:SetupData.Setup.profiles.PSObject.Properties.Name)
        $managed = [bool]($script:Managed -and $script:Managed.isManaged)
        $chassis = [string](Get-Prop $script:OsInfo 'chassis' 'Unknown')
        $default = Get-DefaultProfileName $managed $chassis
        $script:ProfileLoading = $true
        Add-Combo 'cmbProfile' $names $default
        $script:ProfileLoading = $false
        Set-ProfileUiAnswers (Get-ProfileAnswers $script:SetupData.Setup $default $managed $chassis)
        $script:ProfileInit = $true
    }
    Update-ProfilePlan
}

function Update-ProfilePlan {
    $panel = Get-Ctl 'profilePanel'
    if (-not $script:Rows -or -not $script:SetupData) { return }
    $name = [string](Get-Ctl 'cmbProfile').SelectedItem
    if (-not $name) { return }
    $setup = $script:SetupData.Setup
    $prof = Get-Prop $setup.profiles $name $null
    (Get-Ctl 'txtProfileDesc').Text = $(if ($prof) { [string]$prof.title + ': ' + [string](Get-Prop $script:SetupData.Option.$name 'description' '') } else { '' })
    $res = Resolve-SetupProfile -Setup $setup -Option $script:SetupData.Option -ProfileName $name -Answers (Get-ProfileUiAnswers) -Rows $script:Rows
    $script:ProfileResult = $res
    $ack = Get-Ctl 'chkProfileAck'
    $ack.Visibility = $(if ($res.NeedsAck) { 'Visible' } else { 'Collapsed' })
    $ack.Content = $res.AckText
    $panel.Children.Clear()
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = 'Plan for: ' + $name; $t.FontSize = 16; $t.FontWeight = 'Bold'; $t.TextWrapping = 'Wrap'
    [void]$panel.Children.Add($t)
    $sum = '{0} tweak(s) can be ticked now; {1} wait for a preset that is not enabled in this version; {2} already in effect; {3} skipped on this device.' -f @($res.Selected).Count, @($res.NotEnabled).Count, @($res.AlreadyApplied).Count, @($res.Skipped).Count
    $s = New-Object System.Windows.Controls.TextBlock
    $s.Text = $sum; $s.TextWrapping = 'Wrap'; $s.Foreground = New-Brush '#37474F'; $s.Margin = '0,4,0,4'
    [void]$panel.Children.Add($s)
    if ($script:Managed -and $script:Managed.isManaged -and $name -ne 'work-managed') {
        Add-DetailText $panel 'Managed device' 'This device is managed. work-managed is the profile made for it; other profiles still stay inside what the engine allows, and applying still needs the managed-device tick.'
    }
    foreach ($sec in (Format-ProfilePlan $res)) { Add-DetailText $panel $sec.Title $sec.Text }
    $pf = Format-PreflightChecks $script:Preflight
    if ($pf) { Add-DetailText $panel 'Preflight (checked before any apply)' $pf }
}

function Select-ProfileInGrid {
    if (-not $script:Rows -or -not $script:ProfileResult) { return }
    $ack = Get-Ctl 'chkProfileAck'
    if ($script:ProfileResult.NeedsAck -and -not [bool]$ack.IsChecked) {
        [void][System.Windows.MessageBox]::Show($script:Window, "Tick the acknowledgement first:`n`n$($script:ProfileResult.AckText)", 'Profile', 'OK', 'Information')
        return
    }
    Set-ProfileSelection $script:Rows $script:ProfileResult
    (Get-Ctl 'tabs').SelectedItem = (Get-Ctl 'tabTweaks')
    Update-Grid
    Set-Status ("Profile '{0}': {1} tweak(s) ticked. Review them, then use Preview changes and Apply selected." -f $script:ProfileResult.Profile, @($script:ProfileResult.Selected).Count)
}

if ($SelfTest) {
    $script:SelfTestCode = 1
    try { if ($TestEnvironment) { Invoke-SandboxSelfTest } else { Invoke-SelfTest } } catch { Write-Output "SELFTEST FAILED: $($_.Exception.Message)"; Write-Output $_.ScriptStackTrace; $script:SelfTestCode = 1 }
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

# per-row Apply / Revert toggle: one handler on the grid (the buttons are created by the cell template)
(Get-Ctl 'grid').AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $src = $e.OriginalSource
    if ($src -is [System.Windows.Controls.Button] -and $src.Tag -eq 'rowtoggle') { $e.Handled = $true; Invoke-RowAction $src.DataContext }
})

# profiles tab
(Get-Ctl 'cmbProfile').Add_SelectionChanged({
    if ($script:ProfileLoading -or -not $script:SetupData) { return }
    $name = [string](Get-Ctl 'cmbProfile').SelectedItem
    if (-not $name) { return }
    $managed = [bool]($script:Managed -and $script:Managed.isManaged)
    Set-ProfileUiAnswers (Get-ProfileAnswers $script:SetupData.Setup $name $managed ([string](Get-Prop $script:OsInfo 'chassis' 'Unknown')))
    Update-ProfilePlan
})
(Get-Ctl 'btnProfileSelect').Add_Click({ Select-ProfileInGrid })

# drift tab
(Get-Ctl 'btnDriftRefresh').Add_Click({ Load-Drift })
(Get-Ctl 'btnDriftPreview').Add_Click({ Invoke-DriftPreview })
(Get-Ctl 'btnDriftReapply').Add_Click({ Invoke-DriftReapply })
(Get-Ctl 'btnDriftRevert').Add_Click({
    $row = (Get-Ctl 'driftGrid').SelectedItem
    if ($row) { Invoke-RevertTweaks @([string]$row.Id) }
})
(Get-Ctl 'driftGrid').Add_SelectionChanged({ Show-DriftSteps ((Get-Ctl 'driftGrid').SelectedItem) })

# footprint tab
(Get-Ctl 'btnFpMeasure').Add_Click({ Load-Footprint })
(Get-Ctl 'btnFpSave').Add_Click({ Save-FootprintBaseline })
(Get-Ctl 'btnFpCompare').Add_Click({
    $label = [string](Get-Ctl 'cmbFpBase').SelectedItem
    $c = @($script:FpChoices | Where-Object { $_.Label -eq $label }) | Select-Object -First 1
    if ($c) { Load-FootprintCompare $c.Which } else { Set-Status 'No saved report to compare with yet. Use Save as baseline first.' }
})

# the Drift and Footprint tabs read their data the first time they are opened
(Get-Ctl 'tabs').Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne (Get-Ctl 'tabs')) { return }   # SelectionChanged of the combo boxes inside the tabs bubbles up
    $t = (Get-Ctl 'tabs').SelectedItem
    if ($t -eq (Get-Ctl 'tabDrift') -and -not $script:DriftDoc) { Load-Drift }
    elseif ($t -eq (Get-Ctl 'tabFootprint') -and -not $script:FpNow) { Load-Footprint }
})

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
