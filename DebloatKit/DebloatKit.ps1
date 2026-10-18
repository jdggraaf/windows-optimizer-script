<#
.SYNOPSIS
    JSON-driven, reversible Windows 11 debloat engine.

.DESCRIPTION
    Applies tweaks from tweak-catalog.json (built from research into ReviOS, AtlasOS, Tiny11,
    winutil, Win11Debloat and privacy tools). Only the 'safe' preset is enabled in this version.

    Every change is snapshotted BEFORE it is made (registry value or its absence, service start
    type, scheduled task state, power plan, ...). -Undo replays the snapshot in reverse, so revert
    restores what was actually there instead of guessing Windows defaults.

    Free-form 'command' strings in the catalog are never executed. An allowlisted set of commands is
    implemented natively with a snapshot and an exact undo (power plans, NTFS last-access and 8.3 names,
    execution policy, Compact OS, hibernation file type, reserved storage, memory compression, Sleep Study
    event channels, boot menu policy); the rest are skipped with a reason. AppX removal and the component
    store cleanup are skipped unless -AllowIrreversible, because they cannot be undone exactly.

    Modes:
      -List              show every tweak in the preset and whether it is already in effect (read-only)
      -WhatIf            show what an apply would change; writes nothing, no admin needed
      (default)          apply: preflight, restore point, snapshot, change, verify, log (admin)
      -Undo <latest|file> revert a previous run from its snapshot (admin)
      -Revert <id[,id]>  undo only these tweaks, across all snapshots; marks their steps reverted (admin)
      -Drift             compare the live state of every applied tweak with what was applied (read-only)
      -Drift -Reapply    re-apply only the drifted tweaks, with preflight (admin)
      -Migrate           reset values an older catalog version set and no longer recommends (snapshotted, admin)
      -Lint              check the catalog and the engine's own handlers (read-only, no admin)

.PARAMETER Preset
    Tweak preset. Only 'safe' is enabled.

.PARAMETER Only
    Apply only these tweak ids.

.PARAMETER Skip
    Skip these tweak ids.

.PARAMETER Force
    Required to apply on a device that is Entra ID joined, domain joined or MDM enrolled.

.PARAMETER SkipPreflight
    An apply first checks that the machine is in a state where changes are safe: no pending reboot,
    no Windows servicing (TrustedInstaller / TiWorker) running, not on battery power, enough free disk
    space. When a check fails the engine refuses before writing anything. -SkipPreflight applies anyway
    (a warning lists what was ignored). -List and -WhatIf only report the preflight result. -Undo is
    never gated.

.PARAMETER NoRestorePoint
    Do not create a system restore point before applying.

.PARAMETER AllowIrreversible
    Allow steps that have no exact undo (AppX removal, component store cleanup).

.PARAMETER ExpectedSid
    SID of the user who started the GUI. If this process runs as someone else and a per-user (HKCU)
    registry step is involved, the engine refuses before changing anything.

.PARAMETER IncludeUnverified
    Catalog entries with verification 'new-unverified' (added from fresh research, not yet tested on
    a real machine) are skipped unless this switch is passed.

.PARAMETER AsJson
    With -List or -WhatIf: write machine-readable JSON to stdout instead of tables. -List gives
    {managed:{...}, tweaks:[...]}; -WhatIf gives an array of plan steps. Also valid with -Revert and -Drift. Nothing else is written to
    stdout; warnings go to stderr so the JSON stays parseable.

.PARAMETER Revert
    Tweak ids to undo. Searches every snapshot that still has applied steps, newest first, restores the
    latest applied record per target (the oldest unreverted before-state when several runs touched it) and
    marks those records "reverted" inside the snapshot; the file is renamed *.reverted.json only when
    nothing is left. Steps that were interrupted (Pending) or failed part-way (Failed) are restored too.
    -WhatIf never calls an undo. AppX records stay non-revertible. Needs admin (not for -WhatIf), honours -ExpectedSid,
    is never blocked by the preflight or the managed-device check. With -AsJson: { mode, dryRun, requested,
    notFound, summary, results }.

.PARAMETER Drift
    Read-only. Takes the newest unreverted record of every target a previous run changed and compares the
    live state with what was applied (registry, service, task, native handlers, capabilities, optional
    features, AppX packages back again). Reports the Windows build the tweaks were applied on versus the
    current build and flags tweaks whose appliesTo no longer matches. With -AsJson: { mode, os, snapshots,
    appliedBuilds, buildChanged, banner, summary, tweaks }.

.PARAMETER Reapply
    With -Drift: re-apply only the drifted tweaks that are still in the catalog, in the enabled preset and
    applicable to this build, through the normal apply path (preflight, restore point, snapshot, verify;
    -Force on a managed device; -WhatIf previews; irreversible steps still need -AllowIrreversible). With
    -AsJson the output is the drift report plus a "reapply" object (plan or results). Never runs by itself.

.PARAMETER Migrate
    Apply the catalog's 'migrations' instead of the tweaks: values that an older DebloatKit version set
    and that are no longer recommended are reset (restore-default) or rewritten. -List shows how many
    are pending. Each one goes through the normal snapshot / verify / -Undo path. Never applied silently.

.PARAMETER Lint
    Check the catalog (ids, step types, registry paths and value types, presets, evidence rules,
    managedSkip / appliesTo / migrations) and the engine (every step type has a handler, every native
    handler reads back what it writes and undoes back to the exact starting state). Read-only: native
    handlers run against an in-memory fake, never against the system. Exit code 1 when there are errors. With -AsJson the findings are JSON on stdout.

.PARAMETER TestEnvironment
    For tests only. Path of a JSON file {managed, os:{editionId,build,ubr,chassis}, tools:{...},
    preflight:{rebootPending,pendingFileRename,servicingBusy,onBattery,freeDiskMB}, protectedServiceKeys:[...],
    failSteps:[...]}. Replaces the managed-device detection, the OS edition/build/chassis and the
    preflight reads, and replaces every tool the native handlers use (fsutil, powercfg, compact, dism, wevtutil,
    bcdedit, MMAgent, the hibernation / commit / BitLocker / volume reads, the execution policy) with a fake whose
    state lives in that file, so native handlers can be applied and undone without touching the system. Keys of
    "tools" not listed fall back to the engine's built-in defaults ($FakeToolDefaults). failSteps
    ("tweakId|target", wildcards allowed) makes those steps fail when applied, to test the error policy.
    Without a preflight section every preflight check passes. Because that lifts the managed-device and
    preflight gates while registry, service and task steps still hit the real system, a real (non-preview)
    run is refused unless the environment variable DEBLOATKIT_TESTENV is 1 (the test runner sets it);
    -WhatIf, -List, -Lint and read-only -Drift always accept the file.

.PARAMETER SortBy
    With -List: 'default' (category, id) or 'effectiveness' (highest score first).

.EXAMPLE
    .\DebloatKit.ps1 -List

.EXAMPLE
    .\DebloatKit.ps1 -WhatIf

.EXAMPLE
    .\DebloatKit.ps1 -Only priv-advertising-id,ui-explorer-show-extensions

.EXAMPLE
    .\DebloatKit.ps1 -Undo latest
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Drift')]
    [string]$Preset = 'safe',

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Drift')]
    [string[]]$Only,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Drift')]
    [string[]]$Skip,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Undo', Mandatory)]
    [string]$Undo,

    [Parameter(ParameterSetName = 'Revert', Mandatory)]
    [string[]]$Revert,

    [Parameter(ParameterSetName = 'Drift', Mandatory)]
    [switch]$Drift,

    [Parameter(ParameterSetName = 'Drift')]
    [switch]$Reapply,

    [Parameter(ParameterSetName = 'Lint', Mandatory)]
    [switch]$Lint,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$Migrate,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Undo')]
    [Parameter(ParameterSetName = 'Revert')]
    [Parameter(ParameterSetName = 'Drift')]
    [string]$TestEnvironment,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Drift')]
    [switch]$Force,

    # SID of the user the GUI runs as. When the elevated process runs as a DIFFERENT user (UAC with
    # another admin's credentials), per-user (HKCU) steps would land in the wrong hive, so they are refused.
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Undo')]
    [Parameter(ParameterSetName = 'Revert')]
    [Parameter(ParameterSetName = 'Drift')]
    [string]$ExpectedSid,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Drift')]
    [switch]$SkipPreflight,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Drift')]
    [switch]$NoRestorePoint,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Drift')]
    [switch]$AllowIrreversible,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Drift')]
    [switch]$IncludeUnverified,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [Parameter(ParameterSetName = 'Lint')]
    [Parameter(ParameterSetName = 'Revert')]
    [Parameter(ParameterSetName = 'Drift')]
    [switch]$AsJson,

    [Parameter(ParameterSetName = 'List')]
    [ValidateSet('default', 'effectiveness')]
    [string]$SortBy = 'default',

    [string]$CatalogPath,
    [string]$StateDir,
    # AppX keep profiles, framework list and reinstall data (default: appx-profiles.json next to this script).
    [string]$ProfilesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# powershell.exe -File passes "-Only a,b" as ONE string; split it so both ways of calling work.
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
if ($Skip) { $Skip = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
if ($Revert) { $Revert = @($Revert | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | Select-Object -Unique) }

# Resolved here, not as parameter defaults: Windows PowerShell 5.1 leaves $PSScriptRoot empty there.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CatalogPath) { $CatalogPath = Join-Path $scriptDir 'tweak-catalog.json' }
if (-not $ProfilesPath) { $ProfilesPath = Join-Path $scriptDir 'appx-profiles.json' }
if (-not $StateDir) { $StateDir = Join-Path $env:ProgramData 'DebloatKit' }

$EnginePath = $MyInvocation.MyCommand.Path
$EnabledPresets = @('safe')
# Catalog file format this engine reads. An older catalog (a bare JSON array is version 1) is migrated
# in memory by ConvertTo-CurrentCatalog; a newer one is refused.
$CurrentSchemaVersion = 2
# Managed-device skips are catalog metadata ("managedSkip": "reason" on a tweak), not ids in this file.
# Handled by the engine itself rather than as a catalog step.
$EngineHandledIds = @('snapshot-restore-point')
# Catalog step types that are documentation only: the engine reports them as skipped.
$InfoOnlyStepTypes = @('external')
# Plan record types that change the system: each needs a branch in Invoke-Step and in Undo-Step.
$MutatingStepTypes = @('registry', 'service', 'task', 'native', 'appx', 'capability', 'optionalfeature', 'appxcheck')
$RegistryValueTypes = @('DWord', 'String')
$ValidPresets = @('safe', 'balanced', 'aggressive', 'never-default')
# Step policy. A catalog step may carry "onError": continue (default) | stop-tweak | abort-run,
# "order": integer (lower runs first, default 100; ties keep catalog order) and "weight": integer cost
# units for progress display. Default weights per step type below; a restore point counts as one step.
$ErrorPolicies = @('continue', 'stop-tweak', 'abort-run')
$DefaultStepOrder = 100
$StepWeights = @{ registry = 1; service = 2; task = 2; native = 3; appx = 20; capability = 12; optionalfeature = 10; appxcheck = 2 }
$RestorePointWeight = 10
# Preflight: free space needed on the system drive (restore point storage and servicing need headroom).
$MinFreeDiskMB = 2048
$MinFreeDiskNoRestoreMB = 512

# Targets the engine never changes, whatever the catalog says: they are owned by Windows servicing or
# security, and changing them breaks updates, the Store, app deployment or protection. Enforced in the
# plan (a Skip with the reason) and again right before a step runs. Kept in the engine, not the catalog,
# so a catalog edit cannot lift it.
$ProtectedTargets = @{
    Services       = [ordered]@{
        AppXSvc               = 'AppX Deployment Service: installs, updates and removes Store and system apps'
        ClipSVC               = 'Client License Service: licensing for Store apps and Windows features'
        WaaSMedicSvc          = 'Windows Update Medic Service: repairs Windows Update and is protected by Windows itself'
        TrustedInstaller      = 'Windows Modules Installer: all servicing and updates go through it'
        WinDefend             = 'Microsoft Defender Antivirus service'
        WdNisSvc              = 'Microsoft Defender network inspection service'
        WdNisDrv              = 'Microsoft Defender network inspection driver'
        WdFilter              = 'Microsoft Defender file system filter driver'
        WdBoot                = 'Microsoft Defender early-launch driver'
        Sense                 = 'Microsoft Defender for Endpoint sensor'
        MDCoreSvc             = 'Microsoft Defender Core service'
        SecurityHealthService = 'Windows Security Health service'
        wscsvc                = 'Security Center service (reports antivirus and firewall state)'
        mpssvc                = 'Windows Defender Firewall service'
        BFE                   = 'Base Filtering Engine (firewall and IPsec policy)'
        wuauserv              = 'Windows Update service'
        UsoSvc                = 'Update Orchestrator service (schedules and installs updates)'
        BITS                  = 'Background Intelligent Transfer Service (Windows Update and Intune content downloads)'
        DoSvc                 = 'Delivery Optimization service (Windows Update and Intune content downloads)'
    }
    Appx           = [ordered]@{
        'Microsoft.WindowsStore'                    = 'Microsoft Store'
        'Microsoft.StorePurchaseApp'                = 'Microsoft Store purchase component'
        'Microsoft.DesktopAppInstaller'             = 'App Installer (winget and .appinstaller support)'
        'Microsoft.VCLibs*'                         = 'Visual C++ runtime framework packages other apps depend on'
        'Microsoft.NET.Native*'                     = '.NET Native framework packages other apps depend on'
        'Microsoft.UI.Xaml*'                        = 'WinUI framework packages other apps depend on'
        'Microsoft.WindowsAppRuntime*'              = 'Windows App SDK runtime other apps depend on'
        'Microsoft.WebView2*'                       = 'WebView2 runtime (used by Outlook, Teams, Widgets and many third-party apps)'
        'Microsoft.Win32WebViewHost'                = 'WebView2 host component'
        'Microsoft.SecHealthUI'                     = 'Windows Security app'
        'Microsoft.AAD.BrokerPlugin'                = 'Entra ID sign-in broker'
        'Microsoft.AccountsControl'                 = 'account sign-in UI'
        'Microsoft.LockApp'                         = 'lock screen'
        'Microsoft.Windows.CloudExperienceHost'     = 'sign-in and setup experience host'
        'Microsoft.Windows.ShellExperienceHost'     = 'Windows shell (taskbar flyouts)'
        'Microsoft.Windows.StartMenuExperienceHost' = 'Start menu'
        'MicrosoftWindows.Client.CBS'               = 'Windows shell feature pack'
        'MicrosoftWindows.Client.Core'              = 'Windows shell feature pack'
        'windows.immersivecontrolpanel'             = 'Settings app'
    }
    # Windows capabilities (Features on Demand), matched on the name before '~~~~'. Wildcards allowed.
    Capabilities   = [ordered]@{
        'Language.*'                    = 'language features (basic typing, handwriting, OCR, speech, text-to-speech): removing them breaks input and accessibility'
        'Windows.Client.ShellComponents' = 'Windows shell components'
        'Windows.Desktop.EMS-SAC.Tools' = 'emergency management tools'
    }
    # Optional features, wildcards allowed.
    OptionalFeatures = [ordered]@{
        'Windows-Defender*'      = 'Microsoft Defender components'
        'Microsoft-Hyper-V*'     = 'Hyper-V: prerequisite of virtualization-based security and the Windows Subsystem for Linux 2'
        'VirtualMachinePlatform' = 'Virtual Machine Platform: prerequisite of virtualization-based security and WSL2'
        'HypervisorPlatform'     = 'Windows Hypervisor Platform'
        'NetFx4*'                = '.NET Framework 4.x (many applications and Windows tools need it)'
        'SearchEngine-Client-Package' = 'Windows Search'
    }
    # Scheduled task full names (path + name), wildcards allowed.
    Tasks          = [ordered]@{
        '\Microsoft\Windows\WindowsUpdate\*'      = 'Windows Update scheduled scans'
        '\Microsoft\Windows\UpdateOrchestrator\*' = 'Update Orchestrator (schedules and installs updates)'
        '\Microsoft\Windows\WaaSMedic\*'          = 'Windows Update Medic'
        '\Microsoft\Windows\Servicing\*'          = 'component servicing'
        '\Microsoft\Windows\Windows Defender\*'   = 'Microsoft Defender scheduled scans and cleanup'
        '\Microsoft\Windows\SystemRestore\*'      = 'System Restore point creation'
    }
    # Registry values that switch update, firewall, UAC, SmartScreen or BitLocker policy off or redirect it. Path is a regex on the key
    # (no trailing backslash); Names limits the rule to those value names (empty = every value under the key).
    RegistryRules  = @(
        @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate(\\AU)?$'; Names = @('NoAutoUpdate', 'UseWUServer', 'WUServer', 'WUStatusServer', 'DisableWindowsUpdateAccess', 'DoNotConnectToWindowsUpdateInternetLocations'); Reason = 'Windows Update policy (switches updates off or redirects the update source)' }
        @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsFirewall(\\|$)'; Names = @(); Reason = 'Windows Defender Firewall policy' }
        @{ Path = '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Services\\SharedAccess\\Parameters\\FirewallPolicy(\\|$)'; Names = @('EnableFirewall'); Reason = 'Windows Defender Firewall profile state' }
        @{ Path = '^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System$'; Names = @('EnableLUA', 'ConsentPromptBehaviorAdmin', 'ConsentPromptBehaviorUser', 'PromptOnSecureDesktop', 'FilterAdministratorToken'); Reason = 'User Account Control' }
        @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System$'; Names = @('EnableSmartScreen', 'ShellSmartScreenLevel'); Reason = 'SmartScreen policy' }
        @{ Path = '^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer$'; Names = @('SmartScreenEnabled'); Reason = 'SmartScreen setting' }
        @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge$'; Names = @('SmartScreenEnabled', 'SmartScreenPuaEnabled'); Reason = 'Edge SmartScreen policy' }
        @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE(\\|$)'; Names = @(); Reason = 'BitLocker drive encryption policy' }
    )
    # Value names under the Defender policy / settings keys that switch protection off.
    DefenderValues = @('DisableAntiSpyware', 'DisableAntiVirus', 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable', 'TamperProtection')
}

$script:TestEnv = $null
$script:Os = $null
$script:DryRun = [bool]$WhatIfPreference
# The engine checks $script:DryRun itself. Leaving -WhatIf active would leak into module auto-import
# (CIM, AppX, ScheduledTasks) and print dozens of "Set Alias" lines.
$WhatIfPreference = $false
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = $null

#region helpers --------------------------------------------------------------

function Test-Elevated {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-RunLog([hashtable]$Entry) {
    if ($script:DryRun -or -not $script:LogFile) { return }
    $Entry['time'] = (Get-Date).ToString('o')
    Add-Content -LiteralPath $script:LogFile -Value ($Entry | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8 -WhatIf:$false
}

function Save-State($State, [string]$Path) {
    if ($script:DryRun) { return }
    # Written to a temp file first, then swapped in, so a crash or power loss never leaves a truncated snapshot (the only undo record).
    $tmp = "$Path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8 -WhatIf:$false
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($tmp), $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path), [NullString]::Value) }
    else { Move-Item -LiteralPath $tmp -Destination $Path -Force -WhatIf:$false }
}

function Get-Prop($Obj, [string]$Name, $Default = $null) {
    # StrictMode-safe optional property read (older or test catalogs lack the newer fields).
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name]) { $Obj.$Name } else { $Default }
}

function Send-Warning([string]$Message) {
    # With -AsJson stdout must stay clean JSON, so the warning goes to stderr instead.
    if ($AsJson) { [Console]::Error.WriteLine("WARNING: $Message") } else { Write-Warning $Message }
}

function Write-Info([string]$Message, $Color = $null) {
    if ($AsJson) { return }
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
}

function Format-Val($v, [string]$IfNull = '<absent>', [int]$Max = 60) {
    if ($null -eq $v) { return $IfNull }
    $s = if ($v -is [System.Collections.IDictionary] -or $v -is [pscustomobject]) { $v | ConvertTo-Json -Compress -Depth 4 } else { [string]$v }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 3) + '...' }
    $s
}

function Get-ManagedState {
    if ($script:TestEnv -and $null -ne (Get-Prop $script:TestEnv 'managed' $null)) {
        $mg = [bool]$script:TestEnv.managed
        return [pscustomobject]@{ AzureAdJoined = $false; DomainJoined = $false; MdmEnrolled = $mg; Tenant = '' }
    }
    $r = [ordered]@{ AzureAdJoined = $false; DomainJoined = $false; MdmEnrolled = $false; Tenant = '' }
    try {
        $out = & dsregcmd.exe /status 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*AzureAdJoined\s*:\s*YES') { $r.AzureAdJoined = $true }
            if ($line -match '^\s*DomainJoined\s*:\s*YES') { $r.DomainJoined = $true }
            if ($line -match '^\s*TenantName\s*:\s*(.+)$') { $r.Tenant = $Matches[1].Trim() }
            if ($line -match '^\s*MdmUrl\s*:\s*\S+') { $r.MdmEnrolled = $true }
        }
    } catch { }
    try {
        foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and ($p.PSObject.Properties.Name -contains 'ProviderID') -and $p.ProviderID -eq 'MS DM Server') { $r.MdmEnrolled = $true }
        }
    } catch { }
    [pscustomobject]$r
}

function Get-OsInfo {
    # Read-only. Edition and build decide whether a policy is honoured (for example AllowTelemetry=0).
    $r = [ordered]@{ EditionId = ''; Build = 0; Ubr = 0; BuildFull = ''; DisplayVersion = ''; Chassis = 'Unknown'; IsLtsc = $false }
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($p) {
        $r.EditionId = [string](Get-Prop $p 'EditionID' '')
        $b = 0; if ([int]::TryParse([string](Get-Prop $p 'CurrentBuildNumber' (Get-Prop $p 'CurrentBuild' '')), [ref]$b)) { $r.Build = $b }
        $u = 0; if ([int]::TryParse([string](Get-Prop $p 'UBR' ''), [ref]$u)) { $r.Ubr = $u }
        $r.DisplayVersion = [string](Get-Prop $p 'DisplayVersion' '')
    }
    $ov = if ($script:TestEnv) { Get-Prop $script:TestEnv 'os' $null } else { $null }
    if ($ov) {
        $r.EditionId = [string](Get-Prop $ov 'editionId' $r.EditionId)
        $r.Build = [int](Get-Prop $ov 'build' $r.Build)
        $r.Ubr = [int](Get-Prop $ov 'ubr' $r.Ubr)
        $r.Chassis = [string](Get-Prop $ov 'chassis' 'Unknown')
    } else {
        $r.Chassis = Get-ChassisType
    }
    # "26200.1234": tied to a feature update or cumulative update, so a later run can tell which build a snapshot came from.
    # LTSC / IoT Enterprise LTSC: no Store, a smaller inbox app set and different optional components.
    $r.IsLtsc = ($r.EditionId -match '^(IoT)?Enterprise(S|SN|SK)$')
    $r.BuildFull = if ($r.Build -gt 0) { '{0}.{1}' -f $r.Build, $r.Ubr } else { '' }
    [pscustomobject]$r
}

function Get-ChassisType {
    # Read-only. 'Laptop' | 'Desktop' | 'Unknown' from the SMBIOS enclosure type; a battery is only a fallback
    # (desktops with a UPS report one). Used by appliesTo requiresLaptop / requiresDesktop.
    try {
        $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes | ForEach-Object { [int]$_ })
        if ($types | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }) { return 'Laptop' }
        if ($types | Where-Object { $_ -in 3, 4, 5, 6, 7, 13, 15, 16, 23, 24, 34, 35, 36 }) { return 'Desktop' }
        if (@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0) { return 'Laptop' }
    } catch { }
    'Unknown'
}

function Test-EditionMatch([string]$Edition, $Patterns) {
    foreach ($pat in @($Patterns)) { if ($Edition -like [string]$pat) { return $true } }
    $false
}

function Get-AppliesToResult($Tweak, $Os) {
    # $null when the tweak applies here. Otherwise { Mode = 'skip'|'note'; Reason }. A tweak may declare
    #   "appliesTo": { "editions": [...], "notEditions": [...], "minBuild": n, "maxBuild": n,
    #                  "requiresLaptop": true, "requiresDesktop": true,
    #                  "onMismatch": "skip" (default) | "note", "reason": "text" }
    # 'skip' leaves the tweak out; 'note' keeps it and shows the reason next to every step. A chassis that
    # cannot be told ('Unknown') never fails requiresLaptop / requiresDesktop.
    $ap = Get-Prop $Tweak 'appliesTo' $null
    if (-not $ap) { return $null }
    $why = [string](Get-Prop $ap 'reason' '')
    $ed = @(Get-Prop $ap 'editions' @())
    $notEd = @(Get-Prop $ap 'notEditions' @())
    $min = [int](Get-Prop $ap 'minBuild' 0)
    $max = [int](Get-Prop $ap 'maxBuild' 0)
    $needLaptop = [bool](Get-Prop $ap 'requiresLaptop' $false)
    $needDesktop = [bool](Get-Prop $ap 'requiresDesktop' $false)
    $bad = $false
    if ($ed.Count -gt 0 -and -not (Test-EditionMatch $Os.EditionId $ed)) { $bad = $true }
    if ($notEd.Count -gt 0 -and (Test-EditionMatch $Os.EditionId $notEd)) { $bad = $true }
    if ($min -gt 0 -and $Os.Build -lt $min) { $bad = $true }
    if ($max -gt 0 -and $Os.Build -gt $max) { $bad = $true }
    if ($needLaptop -and $Os.Chassis -eq 'Desktop') { $bad = $true }
    if ($needDesktop -and $Os.Chassis -eq 'Laptop') { $bad = $true }
    if (-not $bad) { return $null }
    $here = "this system: edition '{0}', build {1}" -f $Os.EditionId, $Os.Build
    if ($needLaptop -or $needDesktop) { $here += ', {0}' -f $Os.Chassis.ToLower() }
    if (-not $why) { $why = 'not applicable to this edition or build' }
    [pscustomobject]@{ Mode = [string](Get-Prop $ap 'onMismatch' 'skip'); Reason = "$why ($here)" }
}

# ---- protected targets --------------------------------------------------------
# Each returns the reason a target is off limits, or $null. The plan turns it into a Skip; Invoke-Step
# throws on it as a second line of defence.

function Test-ServiceKeyLocked([string]$Name) {
    # Read-only. True when no ACE lets administrators write to the service's registry key (for example
    # TrkWks, WdiServiceHost, UCPD on some builds: Windows protects them, usually via TrustedInstaller).
    # Changing it would fail with "Access denied", which is by design and not an engine bug.
    # Unknown (key missing, ACL unreadable) counts as not locked.
    if ($script:TestEnv) { return (@(Get-Prop $script:TestEnv 'protectedServiceKeys' @()) -contains $Name) }
    try {
        $acl = Get-Acl -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name) -ErrorAction Stop
        $setValue = [int][System.Security.AccessControl.RegistryRights]::SetValue
        $canWrite = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -match '(Administrators|\\Users|Everyone)$' -and (([int]$_.RegistryRights -band $setValue) -ne 0) })
        return ($canWrite.Count -eq 0)
    } catch { return $false }
}

function Get-ProtectedServiceReason([string]$Name, [switch]$CheckAcl) {
    foreach ($k in $ProtectedTargets.Services.Keys) { if ($Name -ieq $k) { return $ProtectedTargets.Services[$k] } }
    if ($CheckAcl -and (Test-ServiceKeyLocked $Name)) { return 'Windows protects this service key (usually TrustedInstaller); administrators cannot change it' }
    $null
}

function Get-ProtectedAppxReason([string]$Name) {
    foreach ($k in $ProtectedTargets.Appx.Keys) { if ($Name -like $k) { return $ProtectedTargets.Appx[$k] } }
    $null
}

function Get-ProtectedCapabilityReason([string]$Name) {
    $n = ($Name -split '~~~~')[0]
    foreach ($k in $ProtectedTargets.Capabilities.Keys) { if ($n -like $k) { return $ProtectedTargets.Capabilities[$k] } }
    $null
}

function Get-ProtectedFeatureReason([string]$Name) {
    foreach ($k in $ProtectedTargets.OptionalFeatures.Keys) { if ($Name -like $k) { return $ProtectedTargets.OptionalFeatures[$k] } }
    $null
}

function Get-ProtectedTaskReason([string]$Path, [string]$Name) {
    $full = $Path + $Name
    foreach ($k in $ProtectedTargets.Tasks.Keys) { if ($full -like $k) { return $ProtectedTargets.Tasks[$k] } }
    $null
}

function Get-ProtectedRegistryReason([string]$Path, [string]$Name) {
    $p = $Path.TrimEnd('\')
    if ($p -match '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Services\\([^\\]+)') {
        $r = Get-ProtectedServiceReason $Matches[2]
        if ($r) { return $r }
    }
    if ($p -match '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Control\\(DeviceGuard|CI)(\\|$)') { return 'virtualization-based security, HVCI and Smart App Control settings' }
    if ($p -match '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Control\\Lsa$' -and $Name -in 'LsaCfgFlags', 'RunAsPPL', 'RunAsPPLBoot') { return 'Credential Guard / LSA protection' }
    if ($p -match '^HKLM:\\SOFTWARE\\(Policies\\)?Microsoft\\Windows Defender(\\|$)' -and $ProtectedTargets.DefenderValues -contains $Name) { return 'a setting that switches Microsoft Defender protection off' }
    foreach ($rule in $ProtectedTargets.RegistryRules) {
        if ($p -match $rule.Path -and (@($rule.Names).Count -eq 0 -or @($rule.Names) -contains $Name)) { return $rule.Reason }
    }
    $null
}

function Get-RecProtection($Rec) {
    # Reason for a plan record that is about to run, or $null.
    $type = [string](Get-Prop $Rec 'type' '')
    if ($type -eq 'service') { return (Get-ProtectedServiceReason ([string](Get-Prop $Rec 'name' '')) -CheckAcl) }
    if ($type -eq 'registry') { return (Get-ProtectedRegistryReason ([string](Get-Prop $Rec 'path' '')) ([string](Get-Prop $Rec 'name' ''))) }
    if ($type -eq 'task') { return (Get-ProtectedTaskReason ([string](Get-Prop $Rec 'taskPath' '')) ([string](Get-Prop $Rec 'taskName' ''))) }
    if ($type -eq 'appx') {
        foreach ($n in @(Get-Prop $Rec 'names' @())) { $r = Get-ProtectedAppxReason ([string]$n); if ($r) { return $r } }
    }
    if ($type -eq 'capability') { return (Get-ProtectedCapabilityReason ([string](Get-Prop $Rec 'name' ''))) }
    if ($type -eq 'optionalfeature') { return (Get-ProtectedFeatureReason ([string](Get-Prop $Rec 'name' ''))) }
    $null
}

function Format-Protected([string]$Reason) { "protected target: $Reason (not supported by design)" }

# ---- preflight ----------------------------------------------------------------
# Read-only state readers, kept apart from the check logic so tests can replace them. With -TestEnvironment
# they read the file's "preflight" section instead of the system (absent section = everything clear).

function Get-PreflightFake { if ($script:TestEnv) { Get-Prop $script:TestEnv 'preflight' ([pscustomobject]@{}) } else { $null } }

function Get-PendingRebootSigns {
    # Names of the pending-reboot markers that are set. CBS and Windows Update markers are reliable.
    $fake = Get-PreflightFake
    if ($script:TestEnv) { return @(Get-Prop $fake 'rebootPending' @()) }
    $signs = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $signs += 'Component Based Servicing: RebootPending' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $signs += 'Windows Update: RebootRequired' }
    $signs
}

function Test-PendingFileRename {
    # PendingFileRenameOperations is set by many installers and often stays set; a hint, not a gate.
    $fake = Get-PreflightFake
    if ($script:TestEnv) { return [bool](Get-Prop $fake 'pendingFileRename' $false) }
    $v = (Get-RegState 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations')
    $v.valueExists -and @($v.value | Where-Object { $_ }).Count -gt 0
}

function Get-ServicingBusy {
    # Description of the servicing activity in progress, or $null.
    $fake = Get-PreflightFake
    if ($script:TestEnv) {
        $b = Get-Prop $fake 'servicingBusy' $false
        if ($b -is [string] -and $b) { return $b }
        if ($b -eq $true) { return 'TrustedInstaller is running' }
        return $null
    }
    $svc = Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { return 'the Windows Modules Installer (TrustedInstaller) service is running' }
    if (Get-Process -Name TiWorker -ErrorAction SilentlyContinue) { return 'TiWorker.exe (Windows servicing) is running' }
    $null
}

function Get-PowerInfo {
    # { HasBattery; OnBattery }. BatteryStatus 1 = discharging, 4 = low, 5 = critical.
    $fake = Get-PreflightFake
    if ($script:TestEnv) { $on = [bool](Get-Prop $fake 'onBattery' $false); return [pscustomobject]@{ HasBattery = $on; OnBattery = $on } }
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    [pscustomobject]@{ HasBattery = ($bat.Count -gt 0); OnBattery = (@($bat | Where-Object { $_.BatteryStatus -in 1, 4, 5 }).Count -gt 0) }
}

function Get-SystemDriveFreeMB {
    $fake = Get-PreflightFake
    if ($script:TestEnv) { return [int64](Get-Prop $fake 'freeDiskMB' 1000000) }
    try { [int64]([IO.DriveInfo]::new($env:SystemDrive).AvailableFreeSpace / 1MB) } catch { -1 }
}

function Get-PreflightState([bool]$RestorePoint) {
    # Checks whether this is a good moment to change the system. Returns { Checks; Blocked } where each check is
    # { id; title; status ok|blocked|warning|unknown; blocking; detail }. 'blocked' stops an apply (unless
    # -SkipPreflight). Nothing here changes anything.
    $checks = New-Object System.Collections.Generic.List[object]
    $add = { param($id, $title, $status, $detail) $checks.Add([pscustomobject]@{ id = $id; title = $title; status = $status; blocking = ($status -eq 'blocked'); detail = $detail }) }

    try {
        $signs = @(Get-PendingRebootSigns)
        if ($signs.Count) { & $add 'pending-reboot' 'No pending reboot' 'blocked' ('a restart is pending (' + ($signs -join '; ') + '); restart Windows first') }
        elseif (Test-PendingFileRename) { & $add 'pending-reboot' 'No pending reboot' 'warning' 'PendingFileRenameOperations is set (often left by installers); not blocking' }
        else { & $add 'pending-reboot' 'No pending reboot' 'ok' 'no restart pending' }
    } catch { & $add 'pending-reboot' 'No pending reboot' 'unknown' "could not check: $($_.Exception.Message)" }

    try {
        $busy = Get-ServicingBusy
        if ($busy) { & $add 'servicing-idle' 'Windows servicing idle' 'blocked' ("$busy; wait for updates or servicing to finish") }
        else { & $add 'servicing-idle' 'Windows servicing idle' 'ok' 'no servicing in progress' }
    } catch { & $add 'servicing-idle' 'Windows servicing idle' 'unknown' "could not check: $($_.Exception.Message)" }

    try {
        $pw = Get-PowerInfo
        if ($pw.OnBattery) { & $add 'ac-power' 'On AC power' 'blocked' 'running on battery; plug in the charger (a power loss mid-run leaves a half-applied state)' }
        elseif ($pw.HasBattery) { & $add 'ac-power' 'On AC power' 'ok' 'on AC power' }
        else { & $add 'ac-power' 'On AC power' 'ok' 'no battery (desktop)' }
    } catch { & $add 'ac-power' 'On AC power' 'unknown' "could not check: $($_.Exception.Message)" }

    try {
        $need = if ($RestorePoint) { $MinFreeDiskMB } else { $MinFreeDiskNoRestoreMB }
        $free = Get-SystemDriveFreeMB
        if ($free -lt 0) { & $add 'free-disk' 'Free disk space' 'unknown' 'could not read the free space of the system drive' }
        elseif ($free -lt $need) { & $add 'free-disk' 'Free disk space' 'blocked' ("only {0} MB free on the system drive, {1} MB needed{2}" -f $free, $need, $(if ($RestorePoint) { ' for the restore point' } else { '' })) }
        else { & $add 'free-disk' 'Free disk space' 'ok' ("{0} MB free (needs {1} MB)" -f $free, $need) }
    } catch { & $add 'free-disk' 'Free disk space' 'unknown' "could not check: $($_.Exception.Message)" }

    [pscustomobject]@{ Checks = @($checks.ToArray()); Blocked = (@($checks | Where-Object blocking).Count -gt 0) }
}

function Format-PreflightLines($Pf) {
    foreach ($c in $Pf.Checks) { '  [{0}] {1}: {2}' -f $c.status.ToUpper(), $c.title, $c.detail }
}

# ---- external tools -----------------------------------------------------------
# Every external tool the native handlers use (fsutil, powercfg, compact, dism, wevtutil, bcdedit) and the
# few PowerShell-only reads and writes (execution policy, MMAgent, hibernation state, commit charge, BitLocker
# state, volume list) are only reached through Invoke-Tool. $script:ToolHost = $null means the real system;
# -Lint and -TestEnvironment put a fake in its place, so a handler can be applied, read back and undone
# without changing anything. Output text of the real tools is parsed in English (the same fragility as the
# fsutil handler: another UI language reads as "could not read", which the plan reports as a Skip).
$script:ToolHost = $null

function New-ToolResult([int]$Code, $Lines) { [pscustomobject]@{ ExitCode = $Code; Output = @($Lines) } }

function Invoke-Tool([string]$Tool, [string[]]$Arguments) {
    if ($script:ToolHost) { return (& $script:ToolHost $Tool $Arguments) }
    if ($Tool -eq 'executionpolicy') {
        # Pinned to Windows PowerShell 5.1: its machine policy is a registry value, while pwsh 7 keeps its own in powershell.config.json.
        # Read and written the same way from either host, so apply under 5.1 and undo under 7 (or the reverse) touch the same setting.
        if ($PSVersionTable.PSEdition -ne 'Core') {
            if ($Arguments[0] -eq 'get') { return (New-ToolResult 0 ([string](Get-ExecutionPolicy -Scope LocalMachine))) }
            Set-ExecutionPolicy -ExecutionPolicy $Arguments[1] -Scope LocalMachine -Force -WhatIf:$false
            return (New-ToolResult 0 @())
        }
        $ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        if ($Arguments[0] -eq 'get') {
            $o = @(& $ps51 -NoProfile -NonInteractive -Command 'Get-ExecutionPolicy -Scope LocalMachine' 2>$null)
            return (New-ToolResult $LASTEXITCODE $o)
        }
        if ([string]$Arguments[1] -notin 'Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass', 'Undefined', 'Default') { return (New-ToolResult 1 @("unsupported execution policy '$($Arguments[1])'")) }
        $o = @(& $ps51 -NoProfile -NonInteractive -Command "Set-ExecutionPolicy -ExecutionPolicy $($Arguments[1]) -Scope LocalMachine -Force" 2>&1)
        return (New-ToolResult $LASTEXITCODE $o)
    }
    if ($Tool -eq 'hiberstate') {
        # 'off' | 'reduced' | 'full' from the power key (HiberFileType 1 = reduced, 2 = full).
        $p = Get-RegState 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
        if (-not $p.valueExists) { return (New-ToolResult 1 @()) }
        if ([int]$p.value -eq 0) { return (New-ToolResult 0 'off') }
        $t = Get-RegState 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HiberFileType'
        return (New-ToolResult 0 $(if ($t.valueExists -and [int]$t.value -eq 1) { 'reduced' } else { 'full' }))
    }
    if ($Tool -eq 'mmagent') {
        if ($Arguments[0] -eq 'get') { return (New-ToolResult 0 ([string](Get-MMAgent).MemoryCompression)) }
        if ($Arguments[1] -eq 'true') { Enable-MMAgent -MemoryCompression | Out-Null } else { Disable-MMAgent -MemoryCompression | Out-Null }
        return (New-ToolResult 0 @())
    }
    if ($Tool -eq 'commit') {
        # Commit charge in percent (committed bytes of the commit limit).
        $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return (New-ToolResult 0 ([string][math]::Round(100 * ($o.TotalVirtualMemorySize - $o.FreeVirtualMemory) / $o.TotalVirtualMemorySize)))
    }
    if ($Tool -eq 'bitlocker') {
        # 'on' | 'off' | 'unknown' for a drive letter (ProtectionStatus 1 = protection on).
        $v = Get-CimInstance -Namespace root/CIMV2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $Arguments[1]) -ErrorAction SilentlyContinue
        if (-not $v) { return (New-ToolResult 0 'unknown') }
        return (New-ToolResult 0 $(switch ([int]$v.ProtectionStatus) { 0 { 'off' } 1 { 'on' } default { 'unknown' } }))
    }
    if ($Tool -eq 'volumes') {
        return (New-ToolResult 0 @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.DriveFormat -eq 'NTFS' } | ForEach-Object { $_.Name.TrimEnd('\') }))
    }
    if ($Tool -eq 'regvalue') {
        $v = Get-RegState $Arguments[0] $Arguments[1]
        if (-not $v.valueExists) { return (New-ToolResult 1 @()) }
        return (New-ToolResult 0 ([string]$v.value))
    }
    if ($Tool -in 'capability', 'optionalfeature', 'appx', 'wusource') {
        try { return (Invoke-ServicingTool $Tool $Arguments) } catch { return (New-ToolResult 1 ([string]$_.Exception.Message)) }
    }
    $out = & $Tool @Arguments 2>$null
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
}

function Invoke-ServicingTool([string]$Tool, [string[]]$A) {
    # The real capability / optional feature / AppX / update-source tools. Reads only list or look up; the
    # remove / disable / add / enable / deprov / register verbs are reached only through a plan record, and the
    # tests never get here (they use the fake tool host). Output lines are 'a|b|c' so the fake can mirror them.
    switch ($Tool) {
        'capability' {
            if ($A[0] -eq 'list') { return (New-ToolResult 0 @(Get-WindowsCapability -Online -ErrorAction Stop | ForEach-Object { '{0}|{1}' -f $_.Name, [string]$_.State })) }
            if ($A[0] -eq 'remove') { $null = Remove-WindowsCapability -Online -Name $A[1] -ErrorAction Stop -WhatIf:$false; return (New-ToolResult 0 @()) }
            if ($A[0] -eq 'add') { $null = Add-WindowsCapability -Online -Name $A[1] -ErrorAction Stop -WhatIf:$false; return (New-ToolResult 0 @()) }
        }
        'optionalfeature' {
            if ($A[0] -eq 'list') { return (New-ToolResult 0 @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | ForEach-Object { '{0}|{1}' -f $_.FeatureName, [string]$_.State })) }
            if ($A[0] -eq 'disable') { $r = Disable-WindowsOptionalFeature -Online -FeatureName $A[1] -NoRestart -ErrorAction Stop -WhatIf:$false; return (New-ToolResult 0 @("restart=$($r.RestartNeeded)")) }
            if ($A[0] -eq 'enable') { $r = Enable-WindowsOptionalFeature -Online -FeatureName $A[1] -NoRestart -ErrorAction Stop -WhatIf:$false; return (New-ToolResult 0 @("restart=$($r.RestartNeeded)")) }
        }
        'appx' {
            if ($A[0] -in 'list', 'listall') {
                $pk = if ($A[0] -eq 'listall') { Get-AppxPackage -AllUsers -ErrorAction Stop } else { Get-AppxPackage -ErrorAction Stop }
                return (New-ToolResult 0 @($pk | Sort-Object PackageFullName -Unique | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.Name, $_.PackageFullName, $_.PackageFamilyName, $_.Version, $(if ($_.IsFramework) { 'F' } else { '-' }) }))
            }
            if ($A[0] -eq 'provlist') { return (New-ToolResult 0 @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { '{0}|{1}' -f $_.DisplayName, $_.PackageName })) }
            if ($A[0] -eq 'remove') {
                if ($A[2] -eq 'allusers') { Remove-AppxPackage -Package $A[1] -AllUsers -ErrorAction Stop -WhatIf:$false } else { Remove-AppxPackage -Package $A[1] -ErrorAction Stop -WhatIf:$false }
                return (New-ToolResult 0 @())
            }
            if ($A[0] -eq 'deprov') { $null = Remove-AppxProvisionedPackage -Online -PackageName $A[1] -ErrorAction Stop -WhatIf:$false; return (New-ToolResult 0 @()) }
            if ($A[0] -eq 'register') {
                $p = Get-AppxPackage -AllUsers -Name $A[1] -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
                if (-not $p -or -not $p.InstallLocation) { return (New-ToolResult 1 "no installed copy of $($A[1]) to register") }
                Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $p.InstallLocation 'AppxManifest.xml') -ErrorAction Stop
                return (New-ToolResult 0 @())
            }
        }
        'wusource' {
            # 'wsus=<0|1>;repair=<n|absent>;local=<path|absent>': where optional components would come from.
            $wu = Get-RegState 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer'
            $sv = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'
            $rp = Get-RegState $sv 'RepairContentServerSource'
            $lp = Get-RegState $sv 'LocalSourcePath'
            $fmt = { param($x) if ($x.valueExists) { [string]$x.value } else { 'absent' } }
            return (New-ToolResult 0 @(('wsus={0};repair={1};local={2}' -f $(if ($wu.valueExists -and [int]$wu.value -eq 1) { '1' } else { '0' }), (& $fmt $rp), (& $fmt $lp))))
        }
    }
    New-ToolResult 99 "unsupported $Tool call: $($A -join ' ')"
}

# State the fake tools start from (-Lint seeds with it; -TestEnvironment files may override any key). A key
# missing from the fake's state reads as its value here; a key with no default here reads as absent (bcdedit
# bootmenupolicy). Every default differs from the Desired value of the handler that uses it.
$FakeToolDefaults = @{
    'fsutil:disablelastaccess'                                     = '2'
    'fsutil:disable8dot3'                                          = '0'
    'fsutil:8dot3name:c:'                                          = '0'
    'powercfg:activescheme'                                        = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    'powercfg:schemes'                                             = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c,381b4222-f694-41f0-9685-ff5bb260df2e'
    'powercfg:hibernate'                                           = 'full'
    'executionpolicy'                                              = 'Restricted'
    'compactos:state'                                              = 'not-compact'
    'dism:reservedstorage'                                         = 'enabled'
    'dism:componentstore:recommended'                              = 'Yes'
    'dism:componentstore:size'                                     = '7.00 GB'
    'mmagent:memorycompression'                                    = 'True'
    'commit:percent'                                               = '40'
    'bitlocker:protection'                                         = 'off'
    'wevtutil:microsoft-windows-sleepstudy/diagnostic'             = 'true'
    'wevtutil:microsoft-windows-kernel-processor-power/diagnostic' = 'true'
    'wevtutil:microsoft-windows-usermodepowerservice/diagnostic'   = 'true'
    # Windows capabilities / optional features: 'capability:<lowercase name>' = 'Name|State'
    'capability:microsoft.windows.wordpad~~~~0.0.1.0'              = 'Microsoft.Windows.WordPad~~~~0.0.1.0|Installed'
    'capability:app.stepsrecorder~~~~0.0.1.0'                      = 'App.StepsRecorder~~~~0.0.1.0|Installed'
    'capability:mathrecognizer~~~~0.0.1.0'                         = 'MathRecognizer~~~~0.0.1.0|Installed'
    'capability:media.windowsmediaplayer~~~~0.0.12.0'              = 'Media.WindowsMediaPlayer~~~~0.0.12.0|NotPresent'
    'capability:language.basic~~~en-us~~~0.0.1.0'                  = 'Language.Basic~~~en-US~~~0.0.1.0|Installed'
    'feature:internet-explorer-optional-amd64'                     = 'Internet-Explorer-Optional-amd64|Enabled'
    'feature:windowsmediaplayer'                                   = 'WindowsMediaPlayer|Enabled'
    'feature:microsoft-hyper-v-all'                                = 'Microsoft-Hyper-V-All|Disabled'
    # update source policy (wusource): WSUS in use; 'wusource:repair' / 'wusource:local' when a repair or FoD source is set
    'wusource:wsus'                                                = '0'
    # AppX inventory: 'appx:<lowercase name>' = 'Name;Version;PublisherId;Flags' (U registered for the current user,
    # P provisioned, F framework, O registered for another user only)
    'appx:microsoft.windowsstore'                                  = 'Microsoft.WindowsStore;22409.1401.3.0;8wekyb3d8bbwe;UP'
    'appx:microsoft.desktopappinstaller'                           = 'Microsoft.DesktopAppInstaller;1.24.0.0;8wekyb3d8bbwe;UP'
    'appx:microsoft.vclibs.140.00'                                 = 'Microsoft.VCLibs.140.00;14.0.33519.0;8wekyb3d8bbwe;UF'
    'appx:microsoft.vclibs.140.00.uwpdesktop'                      = 'Microsoft.VCLibs.140.00.UWPDesktop;14.0.33728.0;8wekyb3d8bbwe;UF'
    'appx:microsoft.ui.xaml.2.8'                                   = 'Microsoft.UI.Xaml.2.8;8.2310.30001.0;8wekyb3d8bbwe;UF'
    'appx:microsoft.bingnews'                                      = 'Microsoft.BingNews;4.55.0.0;8wekyb3d8bbwe;UP'
    'appx:microsoft.zunemusic'                                     = 'Microsoft.ZuneMusic;11.2401.0.0;8wekyb3d8bbwe;UP'
    'appx:clipchamp.clipchamp'                                     = 'Clipchamp.Clipchamp;3.0.0.0;yxz26nhyzhsrt;UP'
    'appx:msteams'                                                 = 'MSTeams;24004.1307.2669.7070;8wekyb3d8bbwe;UP'
    'appx:microsoft.outlookforwindows'                             = 'Microsoft.OutlookForWindows;1.2024.0.0;8wekyb3d8bbwe;UP'
    'appx:microsoft.windowsterminal'                               = 'Microsoft.WindowsTerminal;1.19.0.0;8wekyb3d8bbwe;UP'
    'appx:microsoft.paint'                                         = 'Microsoft.Paint;11.2401.0.0;8wekyb3d8bbwe;UP'
    'appx:microsoft.windowscalculator'                             = 'Microsoft.WindowsCalculator;11.2401.0.0;8wekyb3d8bbwe;UP'
}

function New-FakeToolHost([hashtable]$State, [scriptblock]$OnChange) {
    # Models only what the native handlers use. $State holds the settings ('fsutil:<setting>', 'powercfg:...',
    # 'compactos:state', ...; see $FakeToolDefaults). A call it does not model fails (exit 99), so a new handler
    # must teach it first.
    $defaults = $FakeToolDefaults
    $h = {
        param([string]$Tool, [string[]]$Arguments)
        $t = ($Tool -replace '\.exe$', '').ToLower()
        $a = @($Arguments)
        $l = @($a | ForEach-Object { ([string]$_).ToLower() })
        $res = { param($code, $text) [pscustomobject]@{ ExitCode = $code; Output = @($text) } }
        $get = { param($k) if ($State.ContainsKey($k)) { [string]$State[$k] } elseif ($defaults.ContainsKey($k)) { [string]$defaults[$k] } else { $null } }
        $put = { param($k, $v) $State[$k] = [string]$v; if ($OnChange) { & $OnChange } }
        $del = { param($k) $State.Remove($k); if ($OnChange) { & $OnChange } }
        if ($t -eq 'fsutil' -and $a.Count -ge 3 -and $a[0] -eq 'behavior') {
            $k = 'fsutil:' + $l[2]
            if ($a[1] -eq 'query') {
                $v = & $get $k
                if ($null -ne $v) { return (& $res 0 ("{0} = {1}  (fake)" -f $a[2], $v)) }
                return (& $res 1 'unknown setting')
            }
            if ($a[1] -eq 'set' -and $a.Count -ge 4) { & $put $k $a[3]; return (& $res 0 '') }
        }
        if ($t -eq 'fsutil' -and $a.Count -ge 3 -and $a[0] -eq '8dot3name') {
            $k = 'fsutil:8dot3name:' + $l[2]
            if ($a[1] -eq 'query') {
                $v = & $get $k
                if ($null -ne $v) { return (& $res 0 @(("The volume state is: {0} (fake)" -f $v), ("The registry state is: {0} (fake)" -f (& $get 'fsutil:disable8dot3')))) }
                return (& $res 1 'volume not found')
            }
            if ($a[1] -eq 'set' -and $a.Count -ge 4) { & $put $k $a[3]; return (& $res 0 '') }
        }
        if ($t -eq 'powercfg' -and $a.Count -ge 1) {
            $schemes = @((& $get 'powercfg:schemes') -split ',' | Where-Object { $_ })
            if ($l[0] -eq '/getactivescheme') { return (& $res 0 ("Power Scheme GUID: {0}  (fake)" -f (& $get 'powercfg:activescheme'))) }
            if ($l[0] -eq '/setactive' -and $a.Count -ge 2) {
                if ($schemes -notcontains $l[1]) { return (& $res 1 'The power scheme does not exist') }
                & $put 'powercfg:activescheme' $l[1]; return (& $res 0 '')
            }
            if ($l[0] -eq '/l') { return (& $res 0 (@('Existing Power Schemes (* Active)') + @($schemes | ForEach-Object { 'Power Scheme GUID: {0}  (fake){1}' -f $_, $(if ($_ -eq (& $get 'powercfg:activescheme')) { ' *' } else { '' }) }))) }
            if ($l[0] -eq '/duplicatescheme' -and $a.Count -ge 3) { & $put 'powercfg:schemes' ((@($schemes) + $l[2]) -join ','); return (& $res 0 ("Power Scheme GUID: {0}  (fake)" -f $l[2])) }
            if ($l[0] -eq '/changename' -and $a.Count -ge 3) { if ($schemes -contains $l[1]) { return (& $res 0 '') } else { return (& $res 1 'The power scheme does not exist') } }
            if ($l[0] -eq '/delete' -and $a.Count -ge 2) {
                if ($schemes -notcontains $l[1] -or $l[1] -eq (& $get 'powercfg:activescheme')) { return (& $res 1 'cannot delete this scheme') }
                & $put 'powercfg:schemes' ((@($schemes | Where-Object { $_ -ne $l[1] })) -join ','); return (& $res 0 '')
            }
            if ($l[0] -eq '/hibernate' -and $a.Count -ge 2) {
                $cur = & $get 'powercfg:hibernate'
                if ($l[1] -eq 'off') { & $put 'powercfg:hibernate' 'off'; return (& $res 0 '') }
                if ($l[1] -eq 'on') { if ($cur -eq 'off') { & $put 'powercfg:hibernate' 'full' }; return (& $res 0 '') }
                if ($l[1] -eq '/type' -and $a.Count -ge 3 -and $l[2] -in 'reduced', 'full') {
                    if ($cur -eq 'off') { return (& $res 1 'hibernation is not enabled') }
                    & $put 'powercfg:hibernate' $l[2]; return (& $res 0 '')
                }
            }
        }
        if ($t -eq 'hiberstate' -and $l[0] -eq 'get') { return (& $res 0 (& $get 'powercfg:hibernate')) }
        if ($t -eq 'executionpolicy' -and $a.Count -ge 1) {
            if ($a[0] -eq 'get') { return (& $res 0 (& $get 'executionpolicy')) }
            if ($a[0] -eq 'set' -and $a.Count -ge 2) { & $put 'executionpolicy' $a[1]; return (& $res 0 '') }
        }
        if ($t -eq 'compact' -and $a.Count -ge 1) {
            if ($l[0] -eq '/compactos:query') {
                if ((& $get 'compactos:state') -eq 'compact') { return (& $res 0 'The system is in the Compact state (fake).') }
                return (& $res 102 'The system is not in the Compact state because Windows has determined that, it is not beneficial for this system (fake).')
            }
            if ($l[0] -eq '/compactos:always') { & $put 'compactos:state' 'compact'; return (& $res 0 '') }
            if ($l[0] -eq '/compactos:never') { & $put 'compactos:state' 'not-compact'; return (& $res 0 '') }
        }
        if ($t -eq 'dism' -and $a.Count -ge 2 -and $l[0] -eq '/online') {
            if ($l[1] -eq '/get-reservedstoragestate') { return (& $res 0 ("Reserved storage is {0}." -f (& $get 'dism:reservedstorage'))) }
            if ($l[1] -eq '/set-reservedstoragestate' -and $a.Count -ge 3 -and $l[2] -in '/state:disabled', '/state:enabled') { & $put 'dism:reservedstorage' ($l[2] -replace '^/state:', ''); return (& $res 0 '') }
            if ($l[1] -eq '/cleanup-image' -and $a.Count -eq 3 -and $l[2] -eq '/analyzecomponentstore') {
                return (& $res 0 @(('Actual Size of Component Store : {0}' -f (& $get 'dism:componentstore:size')), 'Backups and Disabled Features : 1.50 GB', ('Component Store Cleanup Recommended : {0}' -f (& $get 'dism:componentstore:recommended'))))
            }
            if ($l[1] -eq '/cleanup-image' -and $a.Count -eq 3 -and $l[2] -eq '/startcomponentcleanup') {
                & $put 'dism:lastcleanup' ($l -join ' ')
                if ((& $get 'dism:cleanupfails') -eq 'servicing') { return (& $res (-2146498554) 'Error: 0x800f0806 (fake) servicing is pending') }
                & $put 'dism:componentstore:size' '5.50 GB'; & $put 'dism:componentstore:recommended' 'No'
                return (& $res 0 '')
            }
        }
        if ($t -eq 'mmagent' -and $a.Count -ge 1) {
            if ($l[0] -eq 'get') { return (& $res 0 (& $get 'mmagent:memorycompression')) }
            if ($l[0] -eq 'set' -and $a.Count -ge 2) { & $put 'mmagent:memorycompression' $(if ($l[1] -eq 'true') { 'True' } else { 'False' }); return (& $res 0 '') }
        }
        if ($t -eq 'commit' -and $l[0] -eq 'get') { return (& $res 0 (& $get 'commit:percent')) }
        if ($t -eq 'bitlocker' -and $l[0] -eq 'status') { return (& $res 0 (& $get 'bitlocker:protection')) }
        if ($t -eq 'volumes' -and $l[0] -eq 'list') {
            $names = @(@($defaults.Keys) + @($State.Keys) | Where-Object { $_ -like 'fsutil:8dot3name:*' } | ForEach-Object { ($_ -replace '^fsutil:8dot3name:', '').ToUpper() } | Select-Object -Unique)
            return (& $res 0 $names)
        }
        if ($t -eq 'wevtutil' -and $a.Count -ge 2) {
            $k = 'wevtutil:' + $l[1]
            if ($l[0] -eq 'gl') {
                $v = & $get $k
                if ($null -ne $v) { return (& $res 0 @(('name: {0}' -f $a[1]), ('enabled: {0}' -f $v), 'type: Analytic')) }
                return (& $res 15007 'The specified channel could not be found.')
            }
            if ($l[0] -eq 'sl' -and $a.Count -ge 3 -and $l[2] -match '^/e:(true|false)$' -and $null -ne (& $get $k)) { & $put $k $Matches[1]; return (& $res 0 '') }
        }
        if ($t -eq 'bcdedit' -and $a.Count -ge 2) {
            $k = 'bcdedit:bootmenupolicy'
            if ($l[0] -eq '/enum' -and $l[1] -eq '{current}') {
                $v = & $get $k
                return (& $res 0 (@('Windows Boot Loader', '-------------------', 'identifier              {current}') + $(if ($v) { @("bootmenupolicy          $v") } else { @() })))
            }
            if ($l[0] -eq '/set' -and $a.Count -ge 4 -and $l[1] -eq '{current}' -and $l[2] -eq 'bootmenupolicy' -and $l[3] -in 'legacy', 'standard') { & $put $k $l[3]; return (& $res 0 '') }
            if ($l[0] -eq '/deletevalue' -and $a.Count -ge 3 -and $l[1] -eq '{current}' -and $l[2] -eq 'bootmenupolicy') { & $del $k; return (& $res 0 '') }
        }
        if ($t -in 'capability', 'optionalfeature' -and $a.Count -ge 1) {
            # State 'Name|State' under 'capability:<lowercase name>' / 'feature:<lowercase name>'.
            $pfx = $(if ($t -eq 'capability') { 'capability:' } else { 'feature:' })
            $keys = @(@($defaults.Keys) + @($State.Keys) | Where-Object { $_ -like "$pfx*" } | Select-Object -Unique | Sort-Object)
            if ($l[0] -eq 'list') { return (& $res 0 @($keys | ForEach-Object { & $get $_ } | Where-Object { $_ })) }
            if ($a.Count -ge 2 -and $l[0] -in 'remove', 'add', 'disable', 'enable') {
                $k = $pfx + $l[1]
                $cur = & $get $k
                if (-not $cur) { return (& $res 1 "the name $($a[1]) was not found (fake)") }
                if ($l[0] -eq 'add' -and (& $get 'source:blocked') -eq 'true') { return (& $res 1 '0x800f0954 (fake): the source files could not be downloaded') }
                $nm = ($cur -split '\|')[0]
                $new = switch ($l[0]) { 'remove' { 'NotPresent' } 'add' { 'Installed' } 'disable' { 'Disabled' } 'enable' { 'Enabled' } }
                & $put $k "$nm|$new"
                return (& $res 0 $(if ($t -eq 'optionalfeature') { 'restart=False' } else { '' }))
            }
        }
        if ($t -eq 'wusource' -and $l[0] -eq 'get') {
            return (& $res 0 ('wsus={0};repair={1};local={2}' -f (& $get 'wusource:wsus'), $(if ($null -ne (& $get 'wusource:repair')) { & $get 'wusource:repair' } else { 'absent' }), $(if ($null -ne (& $get 'wusource:local')) { & $get 'wusource:local' } else { 'absent' })))
        }
        if ($t -eq 'appx' -and $a.Count -ge 1) {
            # 'Name;Version;PublisherId;Flags'; the full name is Name_Version_x64__PublisherId.
            $keys = @(@($defaults.Keys) + @($State.Keys) | Where-Object { $_ -like 'appx:*' -and $_ -notlike 'appx:fail*' -and $_ -notlike 'appx:breaks:*' } | Select-Object -Unique | Sort-Object)
            $items = @(foreach ($k in $keys) { $v = & $get $k; if ($v) { $f = $v -split ';'; [pscustomobject]@{ Key = $k; Name = $f[0]; Ver = $f[1]; Pub = $f[2]; Flags = $f[3]; Full = ('{0}_{1}_x64__{2}' -f $f[0], $f[1], $f[2]) } } })
            $line = { param($i) '{0}|{1}|{2}_{3}|{4}|{5}' -f $i.Name, $i.Full, $i.Name, $i.Pub, $i.Ver, $(if ($i.Flags -match 'F') { 'F' } else { '-' }) }
            $store = { param($i, $flags) if ($flags) { & $put $i.Key ('{0};{1};{2};{3}' -f $i.Name, $i.Ver, $i.Pub, $flags) } else { $State[$i.Key] = ''; if ($OnChange) { & $OnChange } } }
            if ($l[0] -eq 'list') { return (& $res 0 @($items | Where-Object { $_.Flags -match 'U' } | ForEach-Object { & $line $_ })) }
            if ($l[0] -eq 'listall') { return (& $res 0 @($items | Where-Object { $_.Flags -match '[UO]' } | ForEach-Object { & $line $_ })) }
            if ($l[0] -eq 'provlist') { return (& $res 0 @($items | Where-Object { $_.Flags -match 'P' } | ForEach-Object { '{0}|{1}_{2}_neutral_~_{3}' -f $_.Name, $_.Name, $_.Ver, $_.Pub })) }
            if ($l[0] -eq 'remove' -and $a.Count -ge 3) {
                $i = $items | Where-Object { $_.Full -ieq $a[1] } | Select-Object -First 1
                if (-not $i) { return (& $res 1 'package not found (fake)') }
                if ($l[2] -eq 'allusers' -and (& $get 'appx:failallusers') -eq 'true') { return (& $res 1 '0x80073CFA (fake): removal for all users failed') }
                if ((& $get ('appx:failremove:' + $i.Name.ToLower())) -eq 'true') { return (& $res 1 '0x80073CFA (fake): removal failed') }
                & $store $i ($i.Flags -replace '[UO]', '')
                # 'appx:breaks:<name>' = 'Framework.Name|O' (left registered for other users only) or 'Framework.Name|gone': a removal that damages a framework.
                $br = & $get ('appx:breaks:' + $i.Name.ToLower())
                if ($br) {
                    $bp = $br -split '\|'
                    $fw = $items | Where-Object { $_.Name -ieq $bp[0] } | Select-Object -First 1
                    if ($fw) { & $store $fw $(if ($bp[1] -eq 'O') { ($fw.Flags -replace 'U', '') + 'O' } else { '' }) }
                }
                return (& $res 0 '')
            }
            if ($l[0] -eq 'deprov' -and $a.Count -ge 2) {
                $i = $items | Where-Object { $a[1] -like ($_.Name + '_*') } | Select-Object -First 1
                if (-not $i) { return (& $res 1 'provisioned package not found (fake)') }
                & $store $i ($i.Flags -replace 'P', '')
                return (& $res 0 '')
            }
            if ($l[0] -eq 'register' -and $a.Count -ge 2) {
                $i = $items | Where-Object { $_.Name -ieq $a[1] -and $_.Flags -match 'O' } | Select-Object -First 1
                if (-not $i) { return (& $res 1 'no installed copy to register (fake)') }
                & $store $i (($i.Flags -replace 'O', '') + 'U')
                return (& $res 0 '')
            }
        }
        & $res 99 ("unmodelled tool call: $Tool $($a -join ' ')")
    }
    $h.GetNewClosure()
}

function Initialize-TestEnvironment([string]$Path) {
    # -TestEnvironment: managed flag, OS edition/build and the fake tools come from a JSON file, and
    # the fake tools' state is written back to it, so a later -Undo process sees what -apply did.
    if (-not (Test-Path -LiteralPath $Path)) { throw "Test environment file not found: $Path" }
    $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tools = @{}
    $tp = Get-Prop $o 'tools' $null
    if ($tp) { foreach ($p in $tp.PSObject.Properties) { $tools[$p.Name] = [string]$p.Value } }
    $save = {
        $doc = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { if ($p.Name -ne 'tools') { $doc[$p.Name] = $p.Value } }
        $doc['tools'] = $tools
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8 -WhatIf:$false
    }.GetNewClosure()
    $script:TestEnv = $o
    $script:ToolHost = New-FakeToolHost $tools $save
}

function ConvertTo-DWordInt($v) {
    # Registry DWords are read back as signed Int32, catalogs write them unsigned (0xFFFFFFFF = 4294967295).
    $n = [int64]$v
    if ($n -gt [int]::MaxValue) { $n -= 4294967296 }
    [int]$n
}

function Test-ValueEqual($A, $B, [string]$ValueType) {
    try {
        if ($ValueType -eq 'DWord') { return ((ConvertTo-DWordInt $A) -eq (ConvertTo-DWordInt $B)) }
        [string]$A -eq [string]$B
    } catch { $false }
}

#endregion

#region catalog format -------------------------------------------------------
# Catalog file: { "schemaVersion": 2, "migrations": [...], "tweaks": [...] }.
# Version 1 was a bare array of tweaks. Each entry in $CatalogSchemaSteps upgrades version N to N+1 in memory.

$CatalogSchemaSteps = @{
    1 = {
        param($doc)
        # v1 engines hard-coded which tweaks to skip on managed devices (the updates category and the NTP
        # pool). v2 reads "managedSkip" from the tweak, so carry that rule into old catalogs.
        foreach ($t in @($doc.tweaks)) {
            if (Get-Prop $t 'managedSkip' $null) { continue }
            $reason = $null
            if ((Get-Prop $t 'category' '') -eq 'updates') { $reason = 'Windows Update settings are owned by the organisation (update rings, Autopatch).' }
            elseif ((Get-Prop $t 'id' '') -eq 'net-ntp-pool') { $reason = 'Time sync is owned by the organisation (domain / Entra time source).' }
            if ($reason) { $t | Add-Member -NotePropertyName managedSkip -NotePropertyValue $reason -Force }
        }
        $doc
    }
}

function ConvertTo-CurrentCatalog($Raw) {
    # $Raw: the parsed JSON (bare array = schema 1, or an object with schemaVersion). Returns
    # { SchemaVersion (as found); Tweaks; Migrations; Migrated; CatalogVersion }. Throws on a newer schema.
    $items = @($Raw | ForEach-Object { $_ })
    $isDoc = ($items.Count -eq 1 -and $items[0].PSObject.Properties.Name -contains 'tweaks')
    if ($isDoc) {
        $found = [int](Get-Prop $items[0] 'schemaVersion' 0)
        if ($found -lt 1) { throw "Catalog object has no valid 'schemaVersion'." }
        $doc = [pscustomobject]@{ schemaVersion = $found; catalogVersion = [string](Get-Prop $items[0] 'catalogVersion' ''); migrations = @(Get-Prop $items[0] 'migrations' @()); tweaks = @($items[0].tweaks | ForEach-Object { $_ }) }
    } else {
        $found = 1
        $doc = [pscustomobject]@{ schemaVersion = 1; catalogVersion = ''; migrations = @(); tweaks = $items }
    }
    if ($found -gt $CurrentSchemaVersion) { throw "Catalog schemaVersion $found is newer than this engine supports ($CurrentSchemaVersion). Update DebloatKit." }
    $v = $found
    while ($v -lt $CurrentSchemaVersion) {
        if (-not $CatalogSchemaSteps.ContainsKey($v)) { throw "No migration from catalog schemaVersion $v." }
        $doc = & $CatalogSchemaSteps[$v] $doc
        $v++
        $doc.schemaVersion = $v
    }
    [pscustomobject]@{ SchemaVersion = $found; Tweaks = @($doc.tweaks); Migrations = @($doc.migrations); Migrated = ($found -ne $CurrentSchemaVersion); CatalogVersion = $doc.catalogVersion }
}

function Read-Catalog([string]$Path) {
    ConvertTo-CurrentCatalog (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

#endregion

#region step handlers --------------------------------------------------------
# Each step type has: Get (current state), Test (current matches desired), Set (apply), Restore (from snapshot).

function Get-RegState([string]$Path, [string]$Name) {
    $s = @{ keyExists = (Test-Path -LiteralPath $Path); valueExists = $false; kind = $null; value = $null }
    if ($s.keyExists) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $s.valueExists = $true
            $s.kind = [string]$key.GetValueKind($Name)
            $s.value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    }
    $s
}

function Get-MissingKeys([string]$Path) {
    # Keys that do not exist yet, deepest last, so revert can remove exactly what apply created.
    $missing = @()
    $p = $Path
    while ($p -and -not (Test-Path -LiteralPath $p)) {
        $missing = @($p) + $missing
        $parent = Split-Path -Path $p -Parent
        if ($parent -eq $p) { break }
        $p = $parent
    }
    $missing
}

function Test-RegDesired($Cur, $Step) {
    # A step with "absent": true (used by catalog migrations) wants the value gone.
    if (Get-Prop $Step 'absent' $false) { return -not $Cur.valueExists }
    $Cur.valueExists -and $Cur.kind -eq $Step.valueType -and (Test-ValueEqual $Cur.value $Step.value $Step.valueType)
}

function Set-Reg($Step) {
    if (Get-Prop $Step 'absent' $false) {
        if (Test-Path -LiteralPath $Step.path) { Remove-ItemProperty -LiteralPath $Step.path -Name $Step.name -ErrorAction SilentlyContinue -WhatIf:$false }
        return
    }
    if (-not (Test-Path -LiteralPath $Step.path)) { New-Item -Path $Step.path -Force -WhatIf:$false | Out-Null }
    $v = if ($Step.valueType -eq 'DWord') { ConvertTo-DWordInt $Step.value } else { [string]$Step.value }
    New-ItemProperty -LiteralPath $Step.path -Name $Step.name -PropertyType $Step.valueType -Value $v -Force -WhatIf:$false | Out-Null
}

function Restore-Reg($Rec) {
    $b = $Rec.before
    if ($b.valueExists) {
        if (-not (Test-Path -LiteralPath $Rec.path)) { New-Item -Path $Rec.path -Force -WhatIf:$false | Out-Null }
        New-ItemProperty -LiteralPath $Rec.path -Name $Rec.name -PropertyType $b.kind -Value $b.value -Force -WhatIf:$false | Out-Null
    } elseif (Test-Path -LiteralPath $Rec.path) {
        Remove-ItemProperty -LiteralPath $Rec.path -Name $Rec.name -ErrorAction SilentlyContinue -WhatIf:$false
    }
    # Remove keys this run created, deepest first, only when empty.
    $created = @(Get-Prop $Rec 'createdKeys' @())   # a Pending record (interrupted before createdKeys was recorded) has none
    [array]::Reverse($created)
    foreach ($k in $created) {
        if (-not $k -or -not (Test-Path -LiteralPath $k)) { continue }
        $item = Get-Item -LiteralPath $k
        if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) { Remove-Item -LiteralPath $k -WhatIf:$false }
    }
}

function Get-SvcState([string]$Name) {
    $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $delayed = $false
    $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DelayedAutostart -ErrorAction SilentlyContinue
    if ($p -and $p.DelayedAutostart -eq 1) { $delayed = $true }
    $mode = switch ($svc.StartMode) { 'Auto' { if ($delayed) { 'AutomaticDelayedStart' } else { 'Automatic' } } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { [string]$svc.StartMode } }
    @{ startType = $mode }
}

function Set-SvcStart([string]$Name, [string]$StartType) {
    $sc = switch ($StartType) { 'Automatic' { 'auto' } 'AutomaticDelayedStart' { 'delayed-auto' } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { throw "Unsupported start type '$StartType'" } }
    $out = & sc.exe config $Name start= $sc 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config $Name start= $sc failed: $out" }
}

function Get-TaskList($Step) {
    $tasks = Get-ScheduledTask -TaskPath $Step.path -ErrorAction SilentlyContinue
    if ($Step.name -ne '*') { $tasks = $tasks | Where-Object TaskName -EQ $Step.name }
    @($tasks)
}

# ---- native handler helpers (read functions are kept apart from set functions) -------------------
# Get-* functions only read. Set-* functions change the system and are only ever reached through a handler's
# Set, which the tests drive through the fake tools.

function Assert-ToolOk($Result, [string]$What) {
    if ($Result.ExitCode -ne 0) { throw ("{0} failed (exit {1}): {2}" -f $What, $Result.ExitCode, (@($Result.Output | Where-Object { $_ } | Select-Object -First 2) -join ' ')) }
}

function Get-FirstLine($Result) { [string]($Result.Output | Select-Object -First 1) }

function Get-BusyReason {
    # Reason a servicing-type change should not run now, or $null (same readers as the preflight).
    $busy = Get-ServicingBusy
    if ($busy) { return "$busy; wait for servicing to finish" }
    $signs = @(Get-PendingRebootSigns)
    if ($signs.Count) { return ('a restart is pending (' + ($signs -join '; ') + '); restart Windows first') }
    $null
}

# -- hibernation: 'off' | 'reduced' | 'full' (the file type lives in HiberFileType; off removes hiberfil.sys)
function Get-HibernateState { $s = Get-FirstLine (Invoke-Tool 'hiberstate' @('get')); if ($s -in 'off', 'reduced', 'full') { $s } else { $null } }
function Set-HibernateState([string]$State) {
    if ($State -eq 'off') { Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/hibernate', 'off')) 'powercfg /hibernate off'; return }
    if ((Get-HibernateState) -eq 'off') { Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/hibernate', 'on')) 'powercfg /hibernate on' }
    Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/hibernate', '/type', $State)) "powercfg /hibernate /type $State"
}

# -- power plan: a DebloatKit-owned plan duplicated from the Ultimate Performance base scheme
$DebloatKitPlanGuid = 'deb10a7c-17a1-4e2d-9c3f-5a6b7c8d9e01'
$UltimatePlanBase = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$BalancedPlanGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
function Get-ActiveSchemeGuid { $r = Invoke-Tool 'powercfg.exe' @('/getactivescheme'); if ("$($r.Output)" -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $Matches[1].ToLower() } else { $null } }
function Get-PowerSchemeList { $r = Invoke-Tool 'powercfg.exe' @('/l'); @([regex]::Matches("$($r.Output -join "`n")", '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') | ForEach-Object { $_.Groups[1].Value.ToLower() }) }
function Set-PowerScheme([string]$Guid) {
    $Guid = $Guid.ToLower()
    if ($Guid -eq $DebloatKitPlanGuid -and (Get-PowerSchemeList) -notcontains $Guid) {
        Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/duplicatescheme', $UltimatePlanBase, $Guid)) 'powercfg /duplicatescheme (the Ultimate Performance scheme may not exist on this system)'
        Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/changename', $Guid, 'DebloatKit Performance', 'Created by DebloatKit; removed again by -Undo')) 'powercfg /changename'
    }
    Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/setactive', $Guid)) "powercfg /setactive $Guid"
}
function Undo-PowerScheme($Rec) {
    # Back to the scheme that was active, then delete the plan this run created (the active scheme cannot be deleted).
    $b = $Rec.before
    $prior = [string](Get-Prop $b 'value' '')
    $list = @(Get-PowerSchemeList)
    Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/setactive', $(if ($prior -and $list -contains $prior.ToLower()) { $prior } else { $BalancedPlanGuid }))) 'powercfg /setactive (prior scheme)'
    if (-not [bool](Get-Prop $b 'planExisted' $true) -and (Get-PowerSchemeList) -contains $DebloatKitPlanGuid) {
        Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/delete', $DebloatKitPlanGuid)) 'powercfg /delete'
    }
}

# -- Compact OS: 'compact' | 'not-compact'. The exit code of the query is not usable (102 means "not compact").
function Get-CompactOsState {
    $r = Invoke-Tool 'compact.exe' @('/CompactOS:query')
    $t = "$($r.Output)"
    if ($t -match 'is not in the Compact state') { return 'not-compact' }
    if ($t -match 'is in the Compact state') { return 'compact' }
    $null
}
function Set-CompactOsState([string]$State) {
    Assert-ToolOk (Invoke-Tool 'compact.exe' @($(if ($State -eq 'compact') { '/CompactOS:always' } else { '/CompactOS:never' }))) 'compact /CompactOS'
}

# -- reserved storage: 'enabled' | 'disabled' (DISM text first, the ShippedWithReserves value as fallback)
function Get-ReservedStorageState {
    $t = "$((Invoke-Tool 'dism.exe' @('/Online', '/Get-ReservedStorageState')).Output)"
    if ($t -match '\bdisabled\b') { return 'disabled' }
    if ($t -match '\benabled\b') { return 'enabled' }
    $r = Invoke-Tool 'regvalue' @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager', 'ShippedWithReserves')
    if ($r.ExitCode -eq 0) { return $(if ((Get-FirstLine $r) -eq '1') { 'enabled' } else { 'disabled' }) }
    $null
}
function Set-ReservedStorageState([string]$State) {
    $arg = if ($State -eq 'enabled') { '/State:Enabled' } else { '/State:Disabled' }
    Assert-ToolOk (Invoke-Tool 'dism.exe' @('/Online', '/Set-ReservedStorageState', $arg)) 'DISM /Set-ReservedStorageState (fails while reserved storage is in use by a pending update)'
}

# -- component store: analysis is read-only but takes about a minute, so it only runs around the cleanup
function Get-ComponentStoreInfo {
    $r = Invoke-Tool 'dism.exe' @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore')
    if ($r.ExitCode -ne 0) { return $null }
    $t = $r.Output -join "`n"
    $info = [ordered]@{ actualSize = $null; reclaimable = $null; cleanupRecommended = $null }
    if ($t -match '(?m)Actual Size of Component Store\s*:\s*(.+?)\s*$') { $info.actualSize = $Matches[1] }
    if ($t -match '(?m)Backups and Disabled Features\s*:\s*(.+?)\s*$') { $info.reclaimable = $Matches[1] }
    if ($t -match '(?m)Component Store Cleanup Recommended\s*:\s*(\w+)') { $info.cleanupRecommended = $Matches[1] }
    $info
}
function Get-ComponentCleanupMetric {
    $m = [ordered]@{ freeDiskMB = (Get-SystemDriveFreeMB) }
    $i = Get-ComponentStoreInfo
    if ($i) { foreach ($k in $i.Keys) { $m[$k] = $i[$k] } }
    $m
}
function Invoke-ComponentCleanup {
    # /StartComponentCleanup WITHOUT /ResetBase: superseded components are removed, installed updates stay removable.
    $r = Invoke-Tool 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($r.ExitCode -eq 0) { return }
    if ($r.ExitCode -eq -2146498554 -or "$($r.Output)" -match '0x800f0806') { throw 'DISM /StartComponentCleanup failed with 0x800F0806: servicing is pending. Restart Windows and try again.' }
    Assert-ToolOk $r 'DISM /StartComponentCleanup'
}

# -- memory compression: 'enabled' | 'disabled'
function Get-MemoryCompressionState { $s = Get-FirstLine (Invoke-Tool 'mmagent' @('get')); if ($s -eq 'True') { 'enabled' } elseif ($s -eq 'False') { 'disabled' } else { $null } }
function Set-MemoryCompressionState([string]$State) { Assert-ToolOk (Invoke-Tool 'mmagent' @('set', $(if ($State -eq 'enabled') { 'true' } else { 'false' }))) 'Enable/Disable-MMAgent -MemoryCompression' }
function Get-CommitPercent { $n = 0; if ([int]::TryParse((Get-FirstLine (Invoke-Tool 'commit' @('get'))), [ref]$n)) { $n } else { -1 } }

# -- 8.3 short names: '0'..'3' system-wide (registry), '0'/'1' per volume
function Get-Dot3SystemState { $r = Invoke-Tool 'fsutil.exe' @('behavior', 'query', 'disable8dot3'); if ("$($r.Output)" -match '(?:=|:)\s*(\d+)') { $Matches[1] } else { $null } }
function Get-Dot3VolumeState([string]$Volume) { $r = Invoke-Tool 'fsutil.exe' @('8dot3name', 'query', $Volume); if ($r.ExitCode -eq 0 -and "$($r.Output)" -match ':\s*(\d)\s*\(') { $Matches[1] } else { $null } }

# -- event log channels (Sleep Study): 'true' | 'false'
function Get-EventChannelState([string]$Channel) { $r = Invoke-Tool 'wevtutil.exe' @('gl', $Channel); if ($r.ExitCode -eq 0 -and ($r.Output -join "`n") -match '(?im)^\s*enabled:\s*(true|false)') { $Matches[1].ToLower() } else { $null } }
function Set-EventChannelState([string]$Channel, [string]$State) { Assert-ToolOk (Invoke-Tool 'wevtutil.exe' @('sl', $Channel, "/e:$State")) "wevtutil sl $Channel" }

# -- boot menu policy: 'legacy' | 'standard' | 'absent' (no bootmenupolicy element in the boot entry)
function Get-BootMenuPolicy {
    $r = Invoke-Tool 'bcdedit.exe' @('/enum', '{current}')
    $t = $r.Output -join "`n"
    if ($r.ExitCode -ne 0 -or $t -notmatch '(?i)identifier') { return $null }
    if ($t -match '(?im)^\s*bootmenupolicy\s+(\S+)') { $Matches[1].ToLower() } else { 'absent' }
}
function Set-BootMenuPolicy([string]$Policy) {
    if ($Policy -eq 'absent') { Assert-ToolOk (Invoke-Tool 'bcdedit.exe' @('/deletevalue', '{current}', 'bootmenupolicy')) 'bcdedit /deletevalue' }
    else { Assert-ToolOk (Invoke-Tool 'bcdedit.exe' @('/set', '{current}', 'bootmenupolicy', $Policy)) 'bcdedit /set bootmenupolicy' }
}

# Natively implemented 'command' tweaks: snapshot-able get/set pairs. Catalog command strings are never run.
# Handler keys (the key is the tweak id):
#   Desired       the state the tweak wants (string compared with Get)
#   Get           { param($target) } current state, or $null when it cannot be read
#   Set           { param($value, $target) } writes the state
#   Before        optional { param($target) } extra facts to snapshot (@{...}), for example whether a plan existed
#   Undo          optional { param($rec) } replaces "Set(before.value)" when undo needs more than one call
#   Check         optional { param($target, $current) } $null, or @{ Mode = 'skip'|'note'; Reason }; run only when a change is planned
#   Verify        optional { param($target) } replaces "Get equals Desired" as the after-check
#   Metric        optional { param($target) } measurements stored before and after the change (run log + snapshot)
#   Targeted      the catalog step must name a "target" (volume, event channel); Allowed (exact list) or
#                 AllowedPattern (regex) limits it, Expand turns "*" into the real targets, LintTarget is used by -Lint
#   SharedState   optional key; handlers with the same key write one setting (hibernation), so only the first of them is planned in a run
#   Irreversible  text; the change has no exact undo: the plan skips it without -AllowIrreversible and -Undo refuses it
# Rules (checked by -Lint): Desired, Get and Set are all present; Get reads exactly the setting Set writes
# (so a verify-after-write cannot pass on the wrong value); after Undo the fake tools are back to their seed state;
# the tools are called through Invoke-Tool.
$NativeCommands = @{
    'pwr-balanced-plan'           = @{
        Desired = '381b4222-f694-41f0-9685-ff5bb260df2e'
        Get     = { $r = Invoke-Tool 'powercfg.exe' @('/getactivescheme'); if ("$($r.Output)" -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $Matches[1].ToLower() } else { $null } }
        Set     = { param($v) $r = Invoke-Tool 'powercfg.exe' @('/setactive', [string]$v); if ($r.ExitCode -ne 0) { throw "powercfg /setactive $v failed" } }
    }
    'perf-ntfs-lastaccess'        = @{
        Desired = '1'
        Get     = { $r = Invoke-Tool 'fsutil.exe' @('behavior', 'query', 'disablelastaccess'); if ("$($r.Output)" -match '=\s*(\d+)') { $Matches[1] } else { $null } }
        Set     = { param($v) $r = Invoke-Tool 'fsutil.exe' @('behavior', 'set', 'disablelastaccess', [string]$v); if ($r.ExitCode -ne 0) { throw "fsutil set disablelastaccess $v failed" } }
    }
    'sec-powershell-remotesigned' = @{
        Desired = 'RemoteSigned'
        Get     = { $r = Invoke-Tool 'executionpolicy' @('get'); [string]($r.Output | Select-Object -First 1) }
        Set     = { param($v) $r = Invoke-Tool 'executionpolicy' @('set', [string]$v); if ($r.ExitCode -ne 0) { throw "Set-ExecutionPolicy $v failed" } }
        Before  = { @{ host = 'Windows PowerShell 5.1 (LocalMachine scope)' } }
    }
    # disk: Compact OS (undo returns to the observed state; a state Windows chose itself is restored as an explicit "never")
    'disk-compactos-on'           = @{
        Desired = 'compact'
        Get     = { Get-CompactOsState }
        Set     = { param($v) Set-CompactOsState $v }
        Metric  = { @{ freeDiskMB = (Get-SystemDriveFreeMB) } }
        Check   = { param($t, $cur) $b = Get-BusyReason; if ($b) { @{ Mode = 'skip'; Reason = $b } } }
    }
    # disk: hibernation file
    'pwr-hibernate-off'           = @{
        Desired = 'off'
        SharedState = 'hibernate'
        Get     = { Get-HibernateState }
        Set     = { param($v) Set-HibernateState $v }
        Metric  = { @{ freeDiskMB = (Get-SystemDriveFreeMB) } }
    }
    'pwr-hiberfile-reduced'       = @{
        Desired = 'reduced'
        SharedState = 'hibernate'
        Get     = { Get-HibernateState }
        Set     = { param($v) Set-HibernateState $v }
        Metric  = { @{ freeDiskMB = (Get-SystemDriveFreeMB) } }
        Check   = { param($t, $cur) if ($cur -eq 'off') { @{ Mode = 'skip'; Reason = 'hibernation is off, so there is no hibernation file to reduce (turning it on would use disk space)' } } }
    }
    # disk: reserved storage (DISM refuses while it is in use by a pending update)
    'perf-reserved-storage-off'   = @{
        Desired = 'disabled'
        Get     = { Get-ReservedStorageState }
        Set     = { param($v) Set-ReservedStorageState $v }
        Metric  = { @{ freeDiskMB = (Get-SystemDriveFreeMB) } }
        Check   = { param($t, $cur) $b = Get-BusyReason; if ($b) { @{ Mode = 'skip'; Reason = "reserved storage is in use while servicing is pending: $b" } } }
    }
    # disk: component store cleanup, one-shot and irreversible. Get is a constant (the analysis takes about a minute and
    # runs around the cleanup instead, see Metric), so the cleanup is always offered.
    'disk-component-cleanup'      = @{
        Desired      = 'done'
        Get          = { 'pending' }
        Set          = { param($v) Invoke-ComponentCleanup }
        Verify       = { param($t) $true }
        Metric       = { Get-ComponentCleanupMetric }
        Check        = { param($t, $cur) $b = Get-BusyReason; if ($b) { @{ Mode = 'skip'; Reason = "0x800F0806 would follow: $b" } } }
        Irreversible = 'superseded components are deleted from the component store; reinstalling Windows components is the only way back'
    }
    # power: DebloatKit-owned plan; undo re-activates the previous scheme and deletes the plan only if this run created it
    'pwr-ultra-performance-plan'  = @{
        Desired = 'deb10a7c-17a1-4e2d-9c3f-5a6b7c8d9e01'
        Get     = { Get-ActiveSchemeGuid }
        Set     = { param($v) Set-PowerScheme $v }
        Before  = { @{ planExisted = ((Get-PowerSchemeList) -contains $DebloatKitPlanGuid) } }
        Undo    = { param($rec) Undo-PowerScheme $rec }
    }
    # performance
    'perf-memory-compression-off' = @{
        Desired = 'disabled'
        Get     = { Get-MemoryCompressionState }
        Set     = { param($v) Set-MemoryCompressionState $v }
        Check   = { param($t, $cur) $c = Get-CommitPercent; if ($c -ge 80) { @{ Mode = 'note'; Reason = "commit charge is $c %: with compression off, pages that were compressed in RAM go to the pagefile, which raises pagefile writes on a PC this close to its commit limit" } } }
    }
    'perf-ntfs-8dot3-off'         = @{
        Desired = '1'
        Get     = { Get-Dot3SystemState }
        Set     = { param($v) $r = Invoke-Tool 'fsutil.exe' @('behavior', 'set', 'disable8dot3', [string]$v); Assert-ToolOk $r "fsutil behavior set disable8dot3 $v" }
    }
    'perf-ntfs-8dot3-volume-off'  = @{
        Desired      = '1'
        Targeted     = $true
        AllowedPattern = '^[A-Za-z]:$'
        LintTarget   = 'C:'
        Expand       = { @((Invoke-Tool 'volumes' @('list')).Output | Where-Object { $_ }) }
        Get          = { param($t) Get-Dot3VolumeState $t }
        Set          = { param($v, $t) Assert-ToolOk (Invoke-Tool 'fsutil.exe' @('8dot3name', 'set', $t, [string]$v)) "fsutil 8dot3name set $t $v" }
        Check        = { param($t, $cur) $s = Get-Dot3SystemState; if ($s -and $s -ne '2') { @{ Mode = 'skip'; Reason = "the system-wide setting is $s; per-volume flags only apply when it is 2 (perf-ntfs-8dot3-off sets the system-wide value)" } } }
    }
    'perf-sleepstudy-off'         = @{
        Desired        = 'false'
        Targeted       = $true
        Allowed        = @('Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic')
        LintTarget     = 'Microsoft-Windows-SleepStudy/Diagnostic'
        Get            = { param($t) Get-EventChannelState $t }
        Set            = { param($v, $t) Set-EventChannelState $t $v }
    }
    'perf-bootmenu-legacy'        = @{
        Desired = 'legacy'
        Get     = { Get-BootMenuPolicy }
        Set     = { param($v) Set-BootMenuPolicy $v }
        Check   = { param($t, $cur)
            $bl = Get-FirstLine (Invoke-Tool 'bitlocker' @('status', $env:SystemDrive))
            if ($bl -ne 'off') { @{ Mode = 'skip'; Reason = $(if ($bl -eq 'on') { 'BitLocker protection is on; a boot configuration change can trigger the recovery key prompt (suspend BitLocker for one restart first)' } else { 'could not tell whether BitLocker protection is on; a boot configuration change can trigger the recovery key prompt' }) } }
        }
    }
}

# ---- native handler plumbing (used by the plan, the apply, the undo and -Lint) ------------------

function Invoke-NativeGet($Handler, $Target) { & $Handler.Get $Target }

function Test-NativeTargetAllowed($Handler, [string]$Target) {
    if ($Handler.ContainsKey('Allowed')) { return (@($Handler.Allowed) -contains $Target) }
    if ($Handler.ContainsKey('AllowedPattern')) { return ($Target -match $Handler.AllowedPattern) }
    $false
}

function Get-NativeTargets($Handler, $StepTarget) {
    # Targets a catalog step expands to: @($null) for an untargeted handler, otherwise the step's target ("*" expands
    # to every real target the handler knows). Returns { Targets; Problem }. An unlisted target is a Problem, not run.
    if (-not $Handler.ContainsKey('Targeted')) { return [pscustomobject]@{ Targets = @($null); Problem = $null } }
    $t = [string]$StepTarget
    if (-not $t) { return [pscustomobject]@{ Targets = @(); Problem = 'the catalog step has no target' } }
    if ($t -eq '*') {
        if (-not $Handler.ContainsKey('Expand')) { return [pscustomobject]@{ Targets = @(); Problem = "'*' is not supported by this handler" } }
        $all = @(& $Handler.Expand | Where-Object { $_ -and (Test-NativeTargetAllowed $Handler ([string]$_)) })
        if ($all.Count -eq 0) { return [pscustomobject]@{ Targets = @(); Problem = 'no target found on this system' } }
        return [pscustomobject]@{ Targets = $all; Problem = $null }
    }
    if (-not (Test-NativeTargetAllowed $Handler $t)) { return [pscustomobject]@{ Targets = @(); Problem = "target '$t' is not on this handler's allowlist" } }
    [pscustomobject]@{ Targets = @($t); Problem = $null }
}

function Get-NativeBefore($Handler, $Target, $Current) {
    $b = @{ value = $Current }
    if ($Handler.ContainsKey('Before')) { $extra = & $Handler.Before $Target; if ($extra) { foreach ($k in $extra.Keys) { $b[$k] = $extra[$k] } } }
    $b
}

function Invoke-NativeUndo($Handler, $Rec) {
    if ($Handler.ContainsKey('Undo')) { & $Handler.Undo $Rec; return }
    & $Handler.Set $Rec.before.value (Get-Prop $Rec 'nativeTarget' $null)
}

#endregion

#region capabilities, optional features and AppX ------------------------------
# Read functions (Get-*) only read; the set verbs live behind Invoke-Tool and are reached from Invoke-Step / Undo-Step.

# Kept by default on managed devices: Teams and Outlook are normally deployed and updated by the organisation.
$AppxManagedKeep = @('MSTeams', 'MicrosoftTeams', 'Microsoft.OutlookForWindows')
# Framework / runtime packages the post-removal check watches (the ones that were present before the run must still be).
$FrameworkPatterns = @('Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.Native*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsStore')
$script:AppxProfiles = $null
$script:AppxProfilesLoaded = $false
$script:AppxProfilesError = ''
$script:Inventory = @{}

function Read-AppxProfiles {
    # The profiles file (keep/remove lists, framework hints, Store product ids), or $null when missing or unreadable.
    if ($script:AppxProfilesLoaded) { return $script:AppxProfiles }
    $script:AppxProfilesLoaded = $true
    if (-not $ProfilesPath -or -not (Test-Path -LiteralPath $ProfilesPath)) { $script:AppxProfilesError = "file not found: $ProfilesPath"; return $null }
    try { $script:AppxProfiles = Get-Content -LiteralPath $ProfilesPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $script:AppxProfilesError = $_.Exception.Message }
    $script:AppxProfiles
}

function Reset-Inventory { $script:Inventory = @{} }

function Get-DismInventory([string]$Kind) {
    # { Ok; Items = @{Name; State} } for 'capability' or 'optionalfeature'. Ok is $false when the list cannot be read (needs admin).
    if (-not $script:Inventory.ContainsKey($Kind)) {
        $r = Invoke-Tool $Kind @('list')
        $items = @(if ($r.ExitCode -eq 0) { $r.Output | Where-Object { "$_" -match '\|' } | ForEach-Object { $p = ([string]$_) -split '\|', 2; [pscustomobject]@{ Name = $p[0]; State = $p[1] } } })
        $script:Inventory[$Kind] = [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Items = $items }
    }
    $script:Inventory[$Kind]
}

function Get-AppxInventory([string]$Scope) {
    # { Ok; Items = @{Name; Full; Family; Version; Framework} } for 'list' (current user), 'listall' (all users) or 'provlist' (provisioned: Name = DisplayName, Full = PackageName).
    $key = "appx-$Scope"
    if (-not $script:Inventory.ContainsKey($key)) {
        $r = Invoke-Tool 'appx' @($Scope)
        $items = @(if ($r.ExitCode -eq 0) {
                foreach ($l in $r.Output) {
                    $f = ([string]$l) -split '\|'
                    if ($f.Count -lt 2) { continue }
                    [pscustomobject]@{ Name = $f[0]; Full = $f[1]; Family = $(if ($f.Count -gt 2) { $f[2] } else { '' }); Version = $(if ($f.Count -gt 3) { $f[3] } else { '' }); Framework = ($f.Count -gt 4 -and $f[4] -eq 'F') }
                }
            })
        $script:Inventory[$key] = [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Items = $items }
    }
    $script:Inventory[$key]
}

function Test-AppxNameMatch($Item, [string]$Pattern) {
    # Exact Name, or a PackageFamilyName that starts with "<name>_" (never a greedy substring); wildcards only when the pattern has them.
    if ($Pattern -match '[*?\[]') { return ($Item.Name -like $Pattern) }
    ($Item.Name -ieq $Pattern) -or ($Item.Family -like ($Pattern + '_*'))
}

function Test-CapabilityNameMatch([string]$Full, [string]$Name) {
    # A catalog capability name is the part before '~~~~' (the version suffix differs per build); a full name is matched exactly.
    if ($Name -match '~~~~') { return ($Full -ieq $Name) }
    ($Full -split '~~~~')[0] -ieq $Name
}

function Get-UpdateSourceInfo {
    # Where Add-WindowsCapability / Enable-WindowsOptionalFeature would get payload from. Blocked = WSUS is in use and no
    # repair content source (RepairContentServerSource = 2, or LocalSourcePath) is configured, so an undo may fail.
    $r = Invoke-Tool 'wusource' @('get')
    $t = "$($r.Output)"
    $info = [pscustomobject]@{ Known = ($r.ExitCode -eq 0); Wsus = $false; Repair = 'absent'; Local = 'absent'; Blocked = $false }
    if ($info.Known) {
        $info.Wsus = ($t -match 'wsus=1')
        if ($t -match 'repair=([^;]+)') { $info.Repair = $Matches[1] }
        if ($t -match 'local=(.*)$') { $info.Local = $Matches[1].Trim() }
        $info.Blocked = ($info.Wsus -and $info.Repair -ne '2' -and $info.Local -eq 'absent')
    }
    $info
}

function Get-NotPresentReason([string]$What) {
    $r = "$What is not present on this edition or build"
    if ($script:Os -and $script:Os.IsLtsc) { $r += ' (LTSC edition: the inbox app and optional component set differs)' }
    $r
}

function Resolve-AppxStep($Step, [bool]$Managed) {
    # Names an appx catalog step would remove: "names" plus the profile's "remove" list, minus the profile's "keep" list,
    # minus (on a managed device) Teams and Outlook. Returns { Names; KeptByProfile; ManagedKept; Profile; Problem }.
    $names = @(Get-Prop $Step 'names' @())
    $out = [pscustomobject]@{ Names = @(); KeptByProfile = @(); ManagedKept = @(); Profile = ''; Problem = $null }
    $pn = [string](Get-Prop $Step 'profile' '')
    if ($pn) {
        $out.Profile = $pn
        $pf = Read-AppxProfiles
        $all = if ($pf) { Get-Prop $pf 'profiles' $null } else { $null }
        $prof = if ($all) { Get-Prop $all $pn $null } else { $null }
        if (-not $pf) { $out.Problem = "AppX profiles file is missing or unreadable ($script:AppxProfilesError)"; return $out }
        if (-not $prof) { $out.Problem = "AppX profile '$pn' is not defined in the profiles file"; return $out }
        $names = @($names) + @(Get-Prop $prof 'remove' @())
        $keep = @(Get-Prop $prof 'keep' @())
        $isKept = { param($n) [bool](@($keep | Where-Object { $_ -ieq $n -or ($n -match '[*?]' -and $_ -like $n) }).Count) }
        $out.KeptByProfile = @($names | Where-Object { & $isKept $_ } | Select-Object -Unique)
        $names = @($names | Where-Object { -not (& $isKept $_) })
    }
    if ($Managed) {
        # The profiles file decides; the built-in list is only the fallback for a file without a "managedKeep" array.
        $pfm = Read-AppxProfiles
        $mkFile = if ($pfm) { Get-Prop $pfm 'managedKeep' $null } else { $null }
        $mkeep = if ($null -ne $mkFile) { @($mkFile | ForEach-Object { [string]$_ }) } else { $AppxManagedKeep }
        $out.ManagedKept = @($names | Where-Object { $mkeep -contains $_ } | Select-Object -Unique)
        $names = @($names | Where-Object { $mkeep -notcontains $_ })
    }
    $out.Names = @($names | Select-Object -Unique)
    $out
}

function New-ReinstallEntry($Item, [bool]$Provisioned) {
    # One line of the reinstall manifest saved in the snapshot. Store ids come only from the profiles file ("packages"); where none is
    # known the entry says so and names a search instead of guessing. Nothing here downloads or runs anything.
    $pf = Read-AppxProfiles
    $pk = if ($pf) { Get-Prop (Get-Prop $pf 'packages' $null) $Item.Name $null } else { $null }
    $display = [string](Get-Prop $pk 'display' $Item.Name)
    $sid = Get-Prop $pk 'storeId' $null
    $wid = Get-Prop $pk 'wingetId' $null
    $noStore = [bool]($script:Os -and $script:Os.IsLtsc)
    $cmd = if ($noStore) { "no Microsoft Store on this edition (LTSC): sideload the package $($Item.Name) (family $($Item.Family)) from an offline source" }
    elseif ($sid) { "winget install --id $sid -s msstore --accept-package-agreements" }
    elseif ($wid) { "winget install --id $wid -e" }
    else { "winget search `"$display`" -s msstore   (no Store product id recorded for $($Item.Name))" }
    [ordered]@{ name = $Item.Name; display = $display; packageFullName = $Item.Full; packageFamilyName = $Item.Family; version = $Item.Version; provisioned = $Provisioned; storeProductId = $sid; wingetId = $wid; command = $cmd }
}

function New-AppxCheckRecord($Plan) {
    # One engine-owned record after all AppX work: it checks that every framework package that was registered before the run still is.
    if (@($Plan | Where-Object { $_.type -eq 'appx' -and $_.action -eq 'Change' }).Count -eq 0) { return $null }
    $inv = Get-AppxInventory 'list'
    if (-not $inv.Ok) { return $null }
    $present = @($inv.Items | Where-Object { $n = $_.Name; @($FrameworkPatterns | Where-Object { $n -like $_ }).Count } | ForEach-Object { $_.Name } | Select-Object -Unique)
    $rec = [pscustomobject]@{ tweakId = 'engine-appx-framework-check'; category = 'engine'; type = 'appxcheck'; target = 'AppX framework packages'; current = "$($present.Count) registered"; desired = 'still registered'
        before = @{ present = $present }; action = 'Change'; reason = 'engine: checks VCLibs, UI.Xaml, WindowsAppRuntime, NET.Native, App Installer and Store are still registered after the removals (re-registers a copy that is only missing for this user)' }
    Add-PlanPolicy $rec ([pscustomobject]@{ order = 900; weight = $StepWeights.appxcheck })
}

function Invoke-FrameworkCheck($Rec) {
    Reset-Inventory
    $present = @($Rec.before.present)
    $user = Get-AppxInventory 'list'
    if (-not $user.Ok) { throw 'could not read the AppX inventory to check the frameworks' }
    $missing = New-Object System.Collections.Generic.List[string]
    $registered = New-Object System.Collections.Generic.List[string]
    foreach ($n in $present) {
        if (@($user.Items | Where-Object { $_.Name -ieq $n }).Count) { continue }
        $all = Get-AppxInventory 'listall'
        $fixed = $false
        if ($all.Ok -and @($all.Items | Where-Object { $_.Name -ieq $n }).Count) {
            $r = Invoke-Tool 'appx' @('register', $n)
            Reset-Inventory
            if ($r.ExitCode -eq 0 -and @((Get-AppxInventory 'list').Items | Where-Object { $_.Name -ieq $n }).Count) { $fixed = $true; $registered.Add($n) }
        }
        if (-not $fixed) { $missing.Add($n) }
        $user = Get-AppxInventory 'list'
    }
    $Rec | Add-Member -NotePropertyName repair -NotePropertyValue ([ordered]@{ checked = $present.Count; reRegistered = @($registered); missing = @($missing) }) -Force
    if ($missing.Count) {
        $pf = Read-AppxProfiles
        $hints = foreach ($m in $missing) {
            $fw = if ($pf) { @(Get-Prop $pf 'frameworks' @()) | Where-Object { $m -like (Get-Prop $_ 'pattern' '') } | Select-Object -First 1 } else { $null }
            $ids = @(Get-Prop $fw 'storeIds' @())
            if ($ids.Count) { "$m (winget install --id $($ids -join ' / ') -s msstore)" } else { "$m (reinstall from the Microsoft Store or winget)" }
        }
        throw ("AppX framework package(s) no longer registered for this user: " + ($hints -join '; '))
    }
    $true
}

#endregion

#region planning -------------------------------------------------------------

function Get-Steps($Tweak) {
    $imp = $Tweak.implementation
    if ($imp -is [string]) { return @([pscustomobject]@{ type = 'unsupported'; text = $imp }) }
    if ($imp.type -eq 'multi') { return @($imp.steps) }
    @($imp)
}

$script:PlanSeq = 0
$script:SharedClaims = @{}   # SharedState key of a native handler -> id of the tweak that planned a change of it in this run

function Add-PlanPolicy($Rec, $Step = $null) {
    # Stamps a plan record with its step policy: order (execution order hint), seq (position in the plan, the
    # tie-break that keeps the order deterministic), weight (progress cost) and onError. Returns the record.
    $script:PlanSeq++
    $type = [string](Get-Prop $Rec 'type' '')
    $w = Get-Prop $Step 'weight' $null
    if ($null -eq $w) { $w = $(if ($StepWeights.ContainsKey($type)) { $StepWeights[$type] } else { 0 }) }
    $Rec | Add-Member -NotePropertyName order -NotePropertyValue ([int](Get-Prop $Step 'order' $DefaultStepOrder)) -Force
    $Rec | Add-Member -NotePropertyName seq -NotePropertyValue $script:PlanSeq -Force
    $Rec | Add-Member -NotePropertyName weight -NotePropertyValue ([int]$w) -Force
    $Rec | Add-Member -NotePropertyName onError -NotePropertyValue ([string](Get-Prop $Step 'onError' 'continue')) -Force
    $Rec
}

function Sort-PlanSteps($Plan) {
    # Execution order: the step's "order" hint, then plan position (catalog order of the tweaks, then of their steps).
    @($Plan | Sort-Object -Property @{ Expression = { [int](Get-Prop $_ 'order' $DefaultStepOrder) } }, @{ Expression = { [int](Get-Prop $_ 'seq' 0) } })
}

# Expands a tweak into concrete step records with current state, desired state and a planned action.
function Get-Plan($Tweak, $Managed) {
    $recs = @()
    $base = @{ tweakId = $Tweak.id; category = $Tweak.category }

    if ($EngineHandledIds -contains $Tweak.id) {
        return @(Add-PlanPolicy ([pscustomobject]($base + @{ type = 'engine'; target = 'restore point'; current = $null; desired = $null; action = 'Skip'; reason = 'handled by the engine (-NoRestorePoint to disable)' })))
    }
    if (-not $IncludeUnverified -and (Get-Prop $Tweak 'verification') -eq 'new-unverified') {
        return @(Add-PlanPolicy ([pscustomobject]($base + @{ type = 'policy'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = 'unverified new tweak; use -IncludeUnverified' })))
    }
    $managedSkip = Get-Prop $Tweak 'managedSkip' $null
    if ($Managed -and $managedSkip) {
        return @(Add-PlanPolicy ([pscustomobject]($base + @{ type = 'policy'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = "managed device: $managedSkip" })))
    }
    $applies = Get-AppliesToResult $Tweak $script:Os
    if ($applies -and $applies.Mode -ne 'note') {
        return @(Add-PlanPolicy ([pscustomobject]($base + @{ type = 'policy'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = "not applicable: $($applies.Reason)" })))
    }

    $i = 0
    foreach ($s in (Get-Steps $Tweak)) {
        $i++
        $firstRec = $recs.Count
        switch ($s.type) {
            'registry' {
                $prot = Get-ProtectedRegistryReason $s.path $s.name
                if ($prot) { $recs += [pscustomobject]($base + @{ type = 'registry'; target = "$($s.path)\$($s.name)"; current = $null; desired = $null; action = 'Skip'; reason = (Format-Protected $prot) }); continue }
                $cur = Get-RegState $s.path $s.name
                $ok = Test-RegDesired $cur $s
                $recs += [pscustomobject]($base + @{ type = 'registry'; target = "$($s.path)\$($s.name)"; path = $s.path; name = $s.name; valueType = $s.valueType; value = $s.value; absent = [bool](Get-Prop $s 'absent' $false)
                        current = $(if ($cur.valueExists) { "$($cur.value) ($($cur.kind))" } else { $null }); desired = $(if (Get-Prop $s 'absent' $false) { '<absent>' } else { "$($s.value) ($($s.valueType))" })
                        before = $cur; action = $(if ($ok) { 'InSync' } else { 'Change' }); reason = '' })
            }
            'service' {
                $prot = Get-ProtectedServiceReason $s.name
                if ($prot) { $recs += [pscustomobject]($base + @{ type = 'service'; target = $s.name; current = $null; desired = $s.startType; action = 'Skip'; reason = (Format-Protected $prot) }); continue }
                $cur = Get-SvcState $s.name
                if (-not $cur) { $recs += [pscustomobject]($base + @{ type = 'service'; target = $s.name; current = $null; desired = $s.startType; action = 'Skip'; reason = 'service not present' }); continue }
                $prot = Get-ProtectedServiceReason $s.name -CheckAcl
                if ($prot) { $recs += [pscustomobject]($base + @{ type = 'service'; target = $s.name; current = $cur.startType; desired = $s.startType; action = 'Skip'; reason = (Format-Protected $prot) }); continue }
                $recs += [pscustomobject]($base + @{ type = 'service'; target = $s.name; name = $s.name; startType = $s.startType; current = $cur.startType; desired = $s.startType
                        before = $cur; action = $(if ($cur.startType -eq $s.startType) { 'InSync' } else { 'Change' }); reason = '' })
            }
            'task' {
                $tasks = @(Get-TaskList $s)
                if ($tasks.Count -eq 0) { $recs += [pscustomobject]($base + @{ type = 'task'; target = "$($s.path)$($s.name)"; current = $null; desired = 'Disabled'; action = 'Skip'; reason = 'task not present' }); continue }
                foreach ($t in @($tasks | Sort-Object TaskPath, TaskName)) {
                    $state = [string]$t.State
                    $prot = Get-ProtectedTaskReason $t.TaskPath $t.TaskName
                    if ($prot) { $recs += [pscustomobject]($base + @{ type = 'task'; target = "$($t.TaskPath)$($t.TaskName)"; current = $state; desired = 'Disabled'; action = 'Skip'; reason = (Format-Protected $prot) }); continue }
                    $recs += [pscustomobject]($base + @{ type = 'task'; target = "$($t.TaskPath)$($t.TaskName)"; taskPath = $t.TaskPath; taskName = $t.TaskName; current = $state; desired = 'Disabled'
                            before = @{ state = $state }; action = $(if ($state -eq 'Disabled') { 'InSync' } else { 'Change' }); reason = '' })
                }
            }
            'command' {
                if ($NativeCommands.ContainsKey($Tweak.id)) {
                    $h = $NativeCommands[$Tweak.id]
                    $expanded = Get-NativeTargets $h (Get-Prop $s 'target' $null)
                    if ($expanded.Problem) { $recs += [pscustomobject]($base + @{ type = 'native'; target = $Tweak.id; current = $null; desired = $h.Desired; action = 'Skip'; reason = $expanded.Problem }); continue }
                    foreach ($nt in $expanded.Targets) {
                        $label = if ($null -ne $nt) { [string]$nt } else { $Tweak.id }
                        $irrev = if ($h.ContainsKey('Irreversible')) { [string]$h.Irreversible } else { '' }
                        $rec = @{ type = 'native'; target = $label; nativeTarget = $nt; irreversible = $irrev; current = $null; desired = $h.Desired }
                        # An irreversible change is gated before anything is read (reading may be slow).
                        if ($irrev -and -not $AllowIrreversible) { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = 'no exact undo; use -AllowIrreversible' }); continue }
                        $cur = try { Invoke-NativeGet $h $nt } catch { $null }
                        if ($null -eq $cur) { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = 'could not read current state (needs admin, or not present on this system)' }); continue }
                        $rec.current = $cur
                        # Two tweaks that write the same setting would be planned from the same "before" and the second would silently undo the first.
                        if ($h.ContainsKey('SharedState') -and $script:SharedClaims.ContainsKey([string]$h.SharedState)) { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = "conflicts with $($script:SharedClaims[[string]$h.SharedState]): both change the same setting" }); continue }
                        if ([string]$cur -eq [string]$h.Desired) { $recs += [pscustomobject]($base + $rec + @{ before = @{ value = $cur }; action = 'InSync'; reason = '' }); continue }
                        # Check runs only when a change is planned: 'skip' leaves the step out with the reason, 'note' keeps it and shows the reason.
                        $chk = if ($h.ContainsKey('Check')) { & $h.Check $nt $cur } else { $null }
                        if ($chk -and $chk.Mode -ne 'note') { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = [string]$chk.Reason }); continue }
                        $why = $(if ($chk) { "note: $($chk.Reason)" } elseif ($irrev) { "irreversible: $irrev" } else { '' })
                        if ($h.ContainsKey('SharedState')) { $script:SharedClaims[[string]$h.SharedState] = $Tweak.id }
                        $recs += [pscustomobject]($base + $rec + @{ before = (Get-NativeBefore $h $nt $cur); action = 'Change'; reason = $why })
                    }
                } else {
                    $recs += [pscustomobject]($base + @{ type = 'command'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = 'command not implemented natively (catalog strings are never executed)' })
                }
            }
            'appx' {
                # Names come from the step and/or a keep profile; Teams and Outlook are kept on managed devices. Protected packages are
                # dropped twice: by name (no wildcard) and from what a pattern resolves to.
                $rs = Resolve-AppxStep $s $Managed
                if ($rs.Problem) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = [string]$rs.Profile; current = $null; desired = 'removed'; action = 'Skip'; reason = $rs.Problem }); continue }
                if ($rs.ManagedKept.Count) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($rs.ManagedKept -join ','); current = ($rs.ManagedKept -join ','); desired = 'removed'; action = 'Skip'; reason = 'managed device: kept by default (Teams, Outlook, Quick Assist and the Microsoft 365 app are normally deployed or used by the organisation)' }) }
                $names = @($rs.Names)
                $protNames = @($names | Where-Object { $_ -notmatch '[*?\[]' -and (Get-ProtectedAppxReason $_) })
                $names = @($names | Where-Object { $protNames -notcontains $_ })
                $inv = Get-AppxInventory 'list'
                if (-not $inv.Ok) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); current = $null; desired = 'removed'; action = 'Skip'; reason = 'could not read the installed AppX packages' }); continue }
                $found = @($inv.Items | Where-Object { $it = $_; @($names | Where-Object { Test-AppxNameMatch $it $_ }).Count })
                $protFound = @($found | Where-Object { Get-ProtectedAppxReason $_.Name })
                $found = @($found | Where-Object { -not (Get-ProtectedAppxReason $_.Name) })
                # Provisioned copies with no registration for this user (a later sign-in would install them again).
                $prov = Get-AppxInventory 'provlist'
                $provOnly = @(if ($prov.Ok) { $prov.Items | Where-Object { $it = $_; -not (Get-ProtectedAppxReason $it.Name) -and @($names | Where-Object { Test-AppxNameMatch $it $_ }).Count -and @($found | Where-Object { $_.Name -ieq $it.Name }).Count -eq 0 } })
                $protAll = @(@($protNames) + @($protFound | ForEach-Object { $_.Name }) | Select-Object -Unique)
                if ($protAll.Count) {
                    $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($protAll -join ','); current = ($protAll -join ','); desired = 'removed'; action = 'Skip'; reason = (Format-Protected (Get-ProtectedAppxReason $protAll[0])) })
                    if ($names.Count -eq 0) { continue }
                }
                if ($names.Count -eq 0) { if (-not $recs.Count -or $recs.Count -eq $firstRec) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = [string]$rs.Profile; current = $null; desired = 'removed'; action = 'Skip'; reason = 'nothing to remove: every package is kept by the profile' }) }; continue }
                if ($found.Count -eq 0 -and $provOnly.Count -eq 0) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); current = 'not installed'; desired = 'removed'; action = 'InSync'; reason = $(if ($script:Os.IsLtsc) { 'LTSC edition: packages that are not part of it are skipped' } else { '' }) }); continue }
                if (-not $AllowIrreversible) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); current = (@(@($found | ForEach-Object { $_.Name }) + @($provOnly | ForEach-Object { $_.Name })) -join ','); desired = 'removed'; action = 'Skip'; reason = 'no exact undo; use -AllowIrreversible' }); continue }
                $manifest = @(@($found | ForEach-Object { New-ReinstallEntry $_ $false }) + @($provOnly | ForEach-Object { New-ReinstallEntry $_ $true }))
                $allNames = @(@($found | ForEach-Object { $_.Name }) + @($provOnly | ForEach-Object { $_.Name }) | Select-Object -Unique)
                $why = 'irreversible: reinstall from Microsoft Store (reinstall manifest saved in the snapshot)'
                if ($rs.Profile) { $why += "; profile $($rs.Profile) keeps $($rs.KeptByProfile.Count) app(s)" }
                if ($script:Os.IsLtsc) { $why += '; LTSC: no Store, packages that are not installed are skipped' }
                $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); names = $allNames; current = ($allNames -join ','); desired = 'removed'
                        before = @{ packages = @($manifest | ForEach-Object { $_.packageFullName }); manifest = $manifest; storeAvailable = (-not $script:Os.IsLtsc); profile = [string]$rs.Profile }; action = 'Change'; reason = $why })
            }
            'capability' {
                $nm = [string](Get-Prop $s 'name' '')
                $prot = Get-ProtectedCapabilityReason $nm
                if ($prot) { $recs += [pscustomobject]($base + @{ type = 'capability'; target = $nm; current = $null; desired = 'NotPresent'; action = 'Skip'; reason = (Format-Protected $prot) }); continue }
                $inv = Get-DismInventory 'capability'
                if (-not $inv.Ok) { $recs += [pscustomobject]($base + @{ type = 'capability'; target = $nm; current = $null; desired = 'NotPresent'; action = 'Skip'; reason = 'could not read current state (needs admin, or not present on this system)' }); continue }
                $hit = @($inv.Items | Where-Object { Test-CapabilityNameMatch $_.Name $nm })
                if ($hit.Count -eq 0) { $recs += [pscustomobject]($base + @{ type = 'capability'; target = $nm; current = $null; desired = 'NotPresent'; action = 'Skip'; reason = (Get-NotPresentReason "capability $nm") }); continue }
                foreach ($h in $hit) {
                    $cs = [string]$h.State
                    $rec = @{ type = 'capability'; target = $h.Name; name = $h.Name; current = $cs; desired = 'NotPresent' }
                    $prot2 = Get-ProtectedCapabilityReason $h.Name
                    if ($prot2) { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = (Format-Protected $prot2) }); continue }
                    if ($cs -eq 'NotPresent') { $recs += [pscustomobject]($base + $rec + @{ before = @{ state = $cs }; action = 'InSync'; reason = '' }); continue }
                    if ($cs -ne 'Installed') { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = "state is $cs (a restart or servicing is pending)" }); continue }
                    # Undo downloads the capability again. Without a reachable source that cannot be promised, so it needs -AllowIrreversible.
                    $src = Get-UpdateSourceInfo
                    if ($src.Blocked) {
                        $irrev = 'WSUS is configured without a repair content source, so Add-WindowsCapability for the undo may not find the files'
                        $rec.irreversible = $irrev
                        if (-not $AllowIrreversible) { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = "no reliable undo: $irrev; use -AllowIrreversible" }); continue }
                        $why = "irreversible: $irrev"
                    } else { $why = 'undo re-adds it from Windows Update or Features on Demand (needs access to one of them)' }
                    $recs += [pscustomobject]($base + $rec + @{ before = @{ state = $cs; name = $h.Name }; action = 'Change'; reason = $why })
                }
            }
            'optionalfeature' {
                $nm = [string](Get-Prop $s 'name' '')
                $prot = Get-ProtectedFeatureReason $nm
                if ($prot) { $recs += [pscustomobject]($base + @{ type = 'optionalfeature'; target = $nm; current = $null; desired = 'Disabled'; action = 'Skip'; reason = (Format-Protected $prot) }); continue }
                $inv = Get-DismInventory 'optionalfeature'
                if (-not $inv.Ok) { $recs += [pscustomobject]($base + @{ type = 'optionalfeature'; target = $nm; current = $null; desired = 'Disabled'; action = 'Skip'; reason = 'could not read current state (needs admin, or not present on this system)' }); continue }
                $hit = @($inv.Items | Where-Object { $_.Name -ieq $nm })
                if ($hit.Count -eq 0) { $recs += [pscustomobject]($base + @{ type = 'optionalfeature'; target = $nm; current = $null; desired = 'Disabled'; action = 'Skip'; reason = (Get-NotPresentReason "optional feature $nm") }); continue }
                $cs = [string]$hit[0].State
                $rec = @{ type = 'optionalfeature'; target = $nm; name = $hit[0].Name; current = $cs; desired = 'Disabled' }
                if ($cs -in 'Disabled', 'DisabledWithPayloadRemoved') { $recs += [pscustomobject]($base + $rec + @{ before = @{ state = $cs }; action = 'InSync'; reason = '' }); continue }
                if ($cs -ne 'Enabled') { $recs += [pscustomobject]($base + $rec + @{ action = 'Skip'; reason = "state is $cs (a restart or servicing is pending)" }); continue }
                $recs += [pscustomobject]($base + $rec + @{ before = @{ state = $cs; name = $hit[0].Name }; action = 'Change'; reason = 'the payload stays on disk (no -Remove), so undo enables it again without a download' })
            }
            default {
                $recs += [pscustomobject]($base + @{ type = [string]$s.type; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = "unsupported step type '$($s.type)'" })
            }
        }
        for ($j = $firstRec; $j -lt $recs.Count; $j++) { $null = Add-PlanPolicy $recs[$j] $s }
    }
    if ($applies) {
        # appliesTo with onMismatch 'note': keep the steps, but say why the label may overstate the effect.
        foreach ($r in $recs) { if ($r.action -ne 'Skip') { $r.reason = $(if ($r.reason) { "$($r.reason); $($applies.Reason)" } else { $applies.Reason }) } }
    }
    $recs
}

# Migrations: values an older catalog version set and that are no longer recommended. One plan record per
# migration whose current value still equals oldValue; applied only with -Migrate, through the normal path.
function Get-MigrationPlan($Migrations) {
    foreach ($m in @($Migrations)) {
        $cur = Get-RegState $m.path $m.name
        $vt = [string](Get-Prop $m 'valueType' 'DWord')
        if (-not ($cur.valueExists -and (Test-ValueEqual $cur.value $m.oldValue $vt))) { continue }
        $absent = ($m.action -eq 'restore-default')
        $newValue = Get-Prop $m 'newValue' $null
        [pscustomobject]@{ tweakId = "migration:$($m.id)"; category = 'migration'; type = 'registry'; target = "$($m.path)\$($m.name)"; path = $m.path; name = $m.name; valueType = $vt
            value = $newValue; absent = $absent; current = "$($cur.value) ($($cur.kind))"; desired = $(if ($absent) { '<absent>' } else { "$newValue ($vt)" })
            before = $cur; action = 'Change'; reason = [string](Get-Prop $m 'reason' 'set by an older DebloatKit version; no longer recommended') }
    }
}

#endregion

#region lint -----------------------------------------------------------------

function Get-SwitchLabels([string]$FunctionName) {
    # Labels of the first switch in one of this script's functions, read from the script's own source.
    $errs = $null; $toks = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$toks, [ref]$errs)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true)
    if (-not $fn) { return @() }
    $sw = $fn.Find({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
    if (-not $sw) { return @() }
    @($sw.Clauses | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
}

function Get-LeafSteps($Tweak) {
    $imp = Get-Prop $Tweak 'implementation' $null
    if ($null -eq $imp -or $imp -is [string]) { return @() }
    if ((Get-Prop $imp 'type' '') -eq 'multi') { return @(Get-Prop $imp 'steps' @()) }
    @($imp)
}

function Invoke-CatalogLint($Cat) {
    # $Cat: result of ConvertTo-CurrentCatalog. Returns findings { severity: error|warning|info; tweakId; rule; message }.
    $f = New-Object System.Collections.Generic.List[object]
    $add = { param($sev, $id, $rule, $msg) $f.Add([pscustomobject]@{ severity = $sev; tweakId = $id; rule = $rule; message = $msg }) }

    if ($Cat.Migrated) { & $add 'warning' '' 'schema' "catalog uses schemaVersion $($Cat.SchemaVersion); it is migrated in memory to $CurrentSchemaVersion. Rewrite the file as schemaVersion $CurrentSchemaVersion." }

    # --- engine side: every step type has a handler -------------------------------------------
    $planLabels = @(Get-SwitchLabels 'Get-Plan')
    $invokeLabels = @(Get-SwitchLabels 'Invoke-Step')
    $undoLabels = @(Get-SwitchLabels 'Undo-Step')
    foreach ($t in $MutatingStepTypes) {
        if ($invokeLabels -notcontains $t) { & $add 'error' '' 'handler' "plan record type '$t' has no branch in Invoke-Step" }
        if ($undoLabels -notcontains $t) { & $add 'error' '' 'handler' "plan record type '$t' has no branch in Undo-Step" }
    }
    foreach ($t in @('registry', 'service', 'task', 'command', 'appx', 'capability', 'optionalfeature')) {
        if ($planLabels -notcontains $t) { & $add 'error' '' 'handler' "catalog step type '$t' has no branch in Get-Plan" }
    }

    # --- engine side: each native handler reads back what it writes ----------------------------
    $saved = $script:ToolHost
    foreach ($id in ($NativeCommands.Keys | Sort-Object)) {
        $h = $NativeCommands[$id]
        if (-not ($h.ContainsKey('Desired') -and $h.ContainsKey('Get') -and $h.ContainsKey('Set')) -or $null -eq $h.Desired -or "$($h.Desired)" -eq '') {
            & $add 'error' $id 'native-handler' 'needs Desired, Get and Set'
            continue
        }
        if ($h.ContainsKey('Targeted') -and -not (($h.ContainsKey('Allowed') -or $h.ContainsKey('AllowedPattern')) -and $h.ContainsKey('LintTarget') -and (Test-NativeTargetAllowed $h ([string]$h.LintTarget)))) {
            & $add 'error' $id 'native-handler' 'a Targeted handler needs Allowed or AllowedPattern, and a LintTarget that is allowed'
            continue
        }
        if ($h.ContainsKey('Irreversible')) {
            # A one-shot with no readable "done" state: no round trip is possible, so require what the engine relies on instead.
            if (-not ([string]$h.Irreversible).Trim()) { & $add 'error' $id 'native-handler' 'Irreversible needs the reason text shown to the user' }
            continue
        }
        $seed = @{}; foreach ($k in $FakeToolDefaults.Keys) { $seed[$k] = $FakeToolDefaults[$k] }
        $state = @{}; foreach ($k in $seed.Keys) { $state[$k] = $seed[$k] }
        $script:ToolHost = New-FakeToolHost $state $null
        $tg = if ($h.ContainsKey('Targeted')) { [string]$h.LintTarget } else { $null }
        try {
            $orig = Invoke-NativeGet $h $tg
            if ($null -eq $orig) { & $add 'error' $id 'native-roundtrip' 'Get returned nothing against the fake tools; teach New-FakeToolHost the tool the handler uses'; continue }
            if ([string]$orig -eq [string]$h.Desired) { & $add 'error' $id 'native-roundtrip' 'the lint seed already equals Desired, so the round trip proves nothing; change the seed'; continue }
            $rec = [pscustomobject]@{ nativeTarget = $tg; before = [pscustomobject](Get-NativeBefore $h $tg $orig) }
            & $h.Set $h.Desired $tg | Out-Null
            $changed = @($state.Keys | Where-Object { $state[$_] -ne $seed[$_] })
            if ($changed.Count -eq 0) { & $add 'error' $id 'native-roundtrip' 'Set(Desired) changed nothing in the fake tools'; continue }
            $got = Invoke-NativeGet $h $tg
            if ([string]$got -ne [string]$h.Desired) { & $add 'error' $id 'native-roundtrip' "Get read '$got' after Set wrote '$($h.Desired)': Get and Set use different settings"; continue }
            Invoke-NativeUndo $h $rec | Out-Null
            $back = Invoke-NativeGet $h $tg
            if ([string]$back -ne [string]$orig) { & $add 'error' $id 'native-roundtrip' "undo did not restore the original value (read '$back', expected '$orig')"; continue }
            $left = @(@($state.Keys) + @($seed.Keys) | Select-Object -Unique | Where-Object { [string]$state[$_] -ne [string]$seed[$_] })
            if ($left.Count) { & $add 'error' $id 'native-roundtrip' ("after undo these fake settings differ from where they started: " + ($left -join ', ')) }
        } catch { & $add 'error' $id 'native-roundtrip' "handler failed against the fake tools: $($_.Exception.Message)" }
        finally { $script:ToolHost = $saved }
    }


    # --- catalog side ----------------------------------------------------------------------------
    $tweaks = @($Cat.Tweaks)
    $seen = @{}
    foreach ($t in $tweaks) {
        $id = [string](Get-Prop $t 'id' '')
        if (-not $id) { & $add 'error' '' 'id' 'a tweak has no id'; continue }
        if ($id -notmatch '^[A-Za-z0-9._-]+$') { & $add 'error' $id 'id' 'id may only contain letters, digits, dot, underscore and dash' }
        if ($seen.ContainsKey($id)) { & $add 'error' $id 'id' 'duplicate id' }
        $seen[$id] = $true
        foreach ($req in 'category', 'preset', 'risk', 'implementation', 'revert') {
            if ($null -eq (Get-Prop $t $req $null)) { & $add 'error' $id 'fields' "missing '$req'" }
        }
        $preset = [string](Get-Prop $t 'preset' '')
        if ($preset -and $ValidPresets -notcontains $preset) { & $add 'error' $id 'preset' "unknown preset '$preset'" }
        $risk = [string](Get-Prop $t 'risk' '')
        $eff = [int](Get-Prop $t 'effectiveness' 0)
        if ($eff -lt 0 -or $eff -gt 5) { & $add 'error' $id 'effectiveness' "effectiveness $eff is outside 0-5" }
        $me = [string](Get-Prop $t 'measuredEffect' '')
        if ($eff -gt 1 -and ($me -match '^\s*not measured' -or $me -notmatch '\d')) { & $add 'error' $id 'effectiveness' "effectiveness $eff needs a measured figure in measuredEffect" }

        $imp = Get-Prop $t 'implementation' $null
        if ($imp -is [string]) { & $add 'warning' $id 'step' 'implementation is a free-form string; the engine skips it' }
        $steps = @(Get-LeafSteps $t)
        $isSafe = ($preset -eq 'safe')
        if ($isSafe) {
            if ($risk -ne 'safe') { & $add 'error' $id 'safe-preset' "risk is '$risk' but the preset is safe" }
            $rv = Get-Prop $t 'revert' $null
            if ($rv -is [string] -and $rv -match 'not reversible') { & $add 'error' $id 'safe-preset' 'safe tweak is not reversible' }
        }
        foreach ($s in $steps) {
            $type = [string](Get-Prop $s 'type' '')
            if ($planLabels -notcontains $type -and $InfoOnlyStepTypes -notcontains $type) { & $add 'error' $id 'step' "step type '$type' has no handler in the engine"; continue }
            switch ($type) {
                'registry' {
                    $path = [string](Get-Prop $s 'path' ''); $name = [string](Get-Prop $s 'name' ''); $vt = [string](Get-Prop $s 'valueType' '')
                    if ($path -notmatch '^(HKLM|HKCU):\\') { & $add 'error' $id 'registry' "path '$path' must start with HKLM:\ or HKCU:\" }
                    if ($path -match '\\\.DEFAULT(\\|$)') { & $add 'error' $id 'registry' "path '$path' uses the .DEFAULT hive, which is not the new-user template" }
                    if (-not $name) { & $add 'error' $id 'registry' "step on '$path' has no value name" }
                    if ($path -match 'Image File Execution Options' -and $name -ieq 'Debugger') { & $add 'error' $id 'registry' 'IFEO Debugger redirection is a hijack technique and is not allowed' }
                    if ($RegistryValueTypes -notcontains $vt) { & $add 'error' $id 'registry' "valueType '$vt' is not supported (use $($RegistryValueTypes -join ' or '))" }
                    elseif ($vt -eq 'DWord') {
                        $n = 0L
                        if (-not [int64]::TryParse([string](Get-Prop $s 'value' ''), [ref]$n) -or $n -lt -2147483648 -or $n -gt 4294967295) { & $add 'error' $id 'registry' "DWord value '$(Get-Prop $s 'value' '')' is not an integer in the 32-bit range" }
                    }
                }
                'service' {
                    if ((Get-Prop $s 'startType' '') -notin 'Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled') { & $add 'error' $id 'service' "startType '$(Get-Prop $s 'startType' '')' is not supported" }
                    if (-not (Get-Prop $s 'name' '')) { & $add 'error' $id 'service' 'service step has no name' }
                }
                'task' {
                    if ((Get-Prop $s 'state' '') -notin 'Disabled', 'restoreSnapshot') { & $add 'error' $id 'task' "task state '$(Get-Prop $s 'state' '')' is not supported (the engine only disables)" }
                    if ((Get-Prop $s 'path' '') -notmatch '\\$') { & $add 'error' $id 'task' 'task path must end with a backslash' }
                }
                'command' {
                    if ($isSafe -and $EngineHandledIds -notcontains $id -and $null -eq (Get-Prop $s 'undo' $null)) { & $add 'error' $id 'safe-preset' 'safe tweak has a command step with no undo' }
                    if (-not $NativeCommands.ContainsKey($id) -and $EngineHandledIds -notcontains $id) { & $add 'info' $id 'command' 'command step has no native handler; the engine always skips it' }
                    if ($NativeCommands.ContainsKey($id)) {
                        $nh = $NativeCommands[$id]
                        $stg = Get-Prop $s 'target' $null
                        if ($nh.ContainsKey('Targeted')) {
                            if (-not $stg) { & $add 'error' $id 'native-target' 'this handler needs a "target" on each command step' }
                            elseif ($stg -eq '*') { if (-not $nh.ContainsKey('Expand')) { & $add 'error' $id 'native-target' "'*' is not supported by this handler" } }
                            elseif (-not (Test-NativeTargetAllowed $nh ([string]$stg))) { & $add 'error' $id 'native-target' "target '$stg' is not on the handler's allowlist" }
                        } elseif ($null -ne $stg) { & $add 'error' $id 'native-target' 'this handler takes no target' }
                        if ($nh.ContainsKey('Irreversible')) {
                            if ($isSafe) { & $add 'error' $id 'safe-preset' 'safe tweak uses an irreversible native handler' }
                            $rvt = Get-Prop $t 'revert' $null
                            if (-not ($rvt -is [string] -and $rvt -match 'not reversible')) { & $add 'error' $id 'native-handler' 'the handler is irreversible, so the catalog revert must say "not reversible"' }
                        }
                    }
                }
                'appx' {
                    if ($isSafe) { & $add 'error' $id 'safe-preset' 'safe tweak has an appx step (no exact undo)' }
                    $pnm = [string](Get-Prop $s 'profile' '')
                    if (-not $pnm -and @(Get-Prop $s 'names' @()).Count -eq 0) { & $add 'error' $id 'appx' 'appx step needs "names" or a "profile"' }
                    if ($pnm) {
                        $lpf = Read-AppxProfiles
                        if (-not $lpf) { & $add 'error' $id 'appx' "profile '$pnm' is used but the profiles file is missing or unreadable ($script:AppxProfilesError)" }
                        elseif ($null -eq (Get-Prop (Get-Prop $lpf 'profiles' $null) $pnm $null)) { & $add 'error' $id 'appx' "profile '$pnm' is not defined in the profiles file" }
                    }
                }
                'capability' {
                    if ($isSafe) { & $add 'error' $id 'safe-preset' 'safe tweak removes a Windows capability (undo needs Windows Update or FoD access)' }
                    $cn = [string](Get-Prop $s 'name' '')
                    if (-not $cn) { & $add 'error' $id 'capability' 'capability step has no name' }
                    elseif ($cn -match '[*?\[\]]') { & $add 'error' $id 'capability' "capability name '$cn' must not contain wildcards (use the name before '~~~~')" }
                }
                'optionalfeature' {
                    if ($isSafe) { & $add 'error' $id 'safe-preset' 'safe tweak disables an optional feature' }
                    $fnm = [string](Get-Prop $s 'name' '')
                    if (-not $fnm) { & $add 'error' $id 'optionalfeature' 'optionalfeature step has no name' }
                    elseif ($fnm -match '[*?\[\]]') { & $add 'error' $id 'optionalfeature' "feature name '$fnm' must not contain wildcards" }
                }
            }
            # step policy: onError / order / weight
            $oe = Get-Prop $s 'onError' $null
            if ($null -ne $oe -and $ErrorPolicies -notcontains [string]$oe) { & $add 'error' $id 'step-policy' "onError '$oe' must be one of: $($ErrorPolicies -join ', ')" }
            foreach ($numKey in 'order', 'weight') {
                $nv = Get-Prop $s $numKey $null
                $n = 0
                if ($null -ne $nv -and (($nv -is [string]) -or -not [int]::TryParse([string]$nv, [ref]$n) -or ($numKey -eq 'weight' -and $n -lt 0))) { & $add 'error' $id 'step-policy' "$numKey '$nv' must be an integer$(if ($numKey -eq 'weight') { ' of 0 or more' })" }
            }
            # protected targets: the engine skips these whatever the catalog says; in the safe preset that is a catalog bug
            $pr = $null
            if ($type -eq 'service') { $pr = Get-ProtectedServiceReason ([string](Get-Prop $s 'name' '')) }
            elseif ($type -eq 'registry') { $pr = Get-ProtectedRegistryReason ([string](Get-Prop $s 'path' '')) ([string](Get-Prop $s 'name' '')) }
            elseif ($type -eq 'task') { $pr = Get-ProtectedTaskReason ([string](Get-Prop $s 'path' '')) ([string](Get-Prop $s 'name' '')) }
            elseif ($type -eq 'appx') { foreach ($an in @(Get-Prop $s 'names' @())) { if ([string]$an -notmatch '[*?\[]' -and -not $pr) { $pr = Get-ProtectedAppxReason ([string]$an) } } }
            elseif ($type -eq 'capability') { $pr = Get-ProtectedCapabilityReason ([string](Get-Prop $s 'name' '')) }
            elseif ($type -eq 'optionalfeature') { $pr = Get-ProtectedFeatureReason ([string](Get-Prop $s 'name' '')) }
            if ($pr) { & $add $(if ($isSafe) { 'error' } else { 'info' }) $id 'protected-target' "step targets a protected item ($pr); the engine always skips it" }
            # safe must not weaken serviceability or the visibility of security state
            if ($isSafe -and $type -eq 'task' -and (([string](Get-Prop $s 'path' '')) + ([string](Get-Prop $s 'name' ''))) -like '*\Application Experience\Microsoft Compatibility Appraiser') { & $add 'error' $id 'safe-preset' 'safe tweak disables the Compatibility Appraiser (feature-update gating and Autopatch readiness depend on it)' }
            if ($isSafe -and $type -eq 'registry' -and [string](Get-Prop $s 'path' '') -match 'SystemToast\.SecurityAndMaintenance') { & $add 'error' $id 'safe-preset' 'safe tweak hides the Security and Maintenance notifications (lowers visibility of security state)' }
        }
        $ms = Get-Prop $t 'managedSkip' $null
        if ($null -ne $ms -and ($ms -isnot [string] -or -not $ms.Trim())) { & $add 'error' $id 'managedSkip' 'managedSkip must be a non-empty string (the reason shown to the user)' }
        $ap = Get-Prop $t 'appliesTo' $null
        if ($null -ne $ap) {
            $known = 'editions', 'notEditions', 'minBuild', 'maxBuild', 'requiresLaptop', 'requiresDesktop', 'onMismatch', 'reason'
            foreach ($pn in $ap.PSObject.Properties.Name) { if ($known -notcontains $pn) { & $add 'error' $id 'appliesTo' "unknown key '$pn'" } }
            foreach ($bk in 'requiresLaptop', 'requiresDesktop') {
                $bv = Get-Prop $ap $bk $null
                if ($null -ne $bv -and $bv -isnot [bool]) { & $add 'error' $id 'appliesTo' "$bk must be true or false" }
            }
            if ((Get-Prop $ap 'requiresLaptop' $false) -eq $true -and (Get-Prop $ap 'requiresDesktop' $false) -eq $true) { & $add 'error' $id 'appliesTo' 'requiresLaptop and requiresDesktop together can never be satisfied' }
            $bmin = 0; $bmax = 0
            foreach ($bk in 'minBuild', 'maxBuild') {
                $bv = Get-Prop $ap $bk $null
                $bn = 0
                if ($null -ne $bv -and (($bv -is [string]) -or -not [int]::TryParse([string]$bv, [ref]$bn) -or $bn -lt 0)) { & $add 'error' $id 'appliesTo' "$bk '$bv' must be a positive integer build number" }
                elseif ($null -ne $bv) { if ($bk -eq 'minBuild') { $bmin = $bn } else { $bmax = $bn } }
            }
            if ($bmin -gt 0 -and $bmax -gt 0 -and $bmin -gt $bmax) { & $add 'error' $id 'appliesTo' "minBuild $bmin is above maxBuild $bmax, so the tweak can never apply" }
            foreach ($lk in 'editions', 'notEditions') {
                $lv = Get-Prop $ap $lk $null
                if ($null -ne $lv -and @($lv | Where-Object { $_ -isnot [string] -or -not $_ }).Count) { & $add 'error' $id 'appliesTo' "$lk must be a list of non-empty edition patterns" }
            }
            if (-not [string](Get-Prop $ap 'reason' '')) { & $add 'error' $id 'appliesTo' 'appliesTo needs a reason' }
            if ((Get-Prop $ap 'onMismatch' 'skip') -notin 'skip', 'note') { & $add 'error' $id 'appliesTo' "onMismatch must be 'skip' or 'note'" }
        }
    }
    foreach ($id in ($NativeCommands.Keys | Sort-Object)) {
        $t = $tweaks | Where-Object { (Get-Prop $_ 'id' '') -eq $id } | Select-Object -First 1
        if (-not $t) { & $add 'warning' $id 'native-handler' 'handler has no catalog entry in this catalog' }
        elseif (@(Get-LeafSteps $t | Where-Object { (Get-Prop $_ 'type' '') -eq 'command' }).Count -eq 0) { & $add 'error' $id 'native-handler' 'the catalog entry has no command step, so the handler never runs' }
    }

    # --- AppX profiles file -------------------------------------------------------------------------
    $pfl = Read-AppxProfiles
    if (-not $pfl) { & $add 'info' '' 'profiles' "no usable AppX profiles file ($script:AppxProfilesError); appx steps with a profile are skipped" }
    else {
        if ([int](Get-Prop $pfl 'schemaVersion' 0) -ne 1) { & $add 'error' '' 'profiles' 'profiles file schemaVersion must be 1' }
        $profs = Get-Prop $pfl 'profiles' $null
        if (-not $profs) { & $add 'error' '' 'profiles' 'profiles file has no "profiles" object' }
        else {
            foreach ($pp in $profs.PSObject.Properties) {
                $pnm = $pp.Name; $pv = $pp.Value
                if (-not [string](Get-Prop $pv 'description' '')) { & $add 'error' "profile:$pnm" 'profiles' 'a profile needs a description' }
                $pk = @(Get-Prop $pv 'keep' @()); $pr2 = @(Get-Prop $pv 'remove' @())
                if ($pr2.Count -eq 0) { & $add 'error' "profile:$pnm" 'profiles' 'a profile needs a non-empty "remove" list' }
                foreach ($k in $pk) { if ([string]$k -match '[*?\[]') { & $add 'error' "profile:$pnm" 'profiles' "keep entry '$k' must be an exact package name" } }
                foreach ($n in $pr2) {
                    if ([string]$n -notmatch '[*?\[]' -and (Get-ProtectedAppxReason ([string]$n))) { & $add 'error' "profile:$pnm" 'protected-target' "remove list names a protected package (${n}: $(Get-ProtectedAppxReason ([string]$n)))" }
                    if ([string]$n -notmatch '^[A-Za-z0-9._*-]+$') { & $add 'error' "profile:$pnm" 'profiles' "package name '$n' has unexpected characters" }
                }
                foreach ($k in $pk) { if ($pr2 -notcontains $k -and [string]$k) { & $add 'info' "profile:$pnm" 'profiles' "keep entry '$k' is not in the remove list, so it has no effect" } }
            }
        }
        $pkgs = Get-Prop $pfl 'packages' $null
        if ($pkgs) {
            foreach ($pp in $pkgs.PSObject.Properties) {
                $sid = Get-Prop $pp.Value 'storeId' $null
                if ($null -ne $sid -and [string]$sid -notmatch '^[A-Z0-9]{12}$') { & $add 'error' "package:$($pp.Name)" 'profiles' "storeId '$sid' is not a 12-character Store product id" }
            }
        }
        foreach ($mk in @(Get-Prop $pfl 'managedKeep' @())) {
            if ([string]$mk -match '[*?\[]') { & $add 'error' '' 'profiles' "managedKeep entry '$mk' must be exact" }
            elseif ($profs -and @($profs.PSObject.Properties | Where-Object { @(Get-Prop $_.Value 'remove' @()) -contains [string]$mk }).Count -eq 0) { & $add 'warning' '' 'profiles' "managedKeep entry '$mk' is in no profile's remove list, so it has no effect" }
        }
        $opts = Get-Prop $pfl 'optionProfiles' $null
        if ($opts) {
            foreach ($op in $opts.PSObject.Properties) {
                $ov = $op.Value; $onm = "option-profile:$($op.Name)"
                $ap2 = Get-Prop $ov 'appxProfile' $null
                if ($null -ne $ap2 -and $null -eq (Get-Prop $profs $ap2 $null)) { & $add 'error' $onm 'profiles' "appxProfile '$ap2' is not defined" }
                foreach ($tid in @(Get-Prop $ov 'tweakIds' @())) {
                    $ct = $tweaks | Where-Object { (Get-Prop $_ 'id' '') -eq $tid } | Select-Object -First 1
                    if (-not $ct) { & $add 'warning' $onm 'profiles' "tweak id '$tid' is not in this catalog" }
                    elseif ((Get-Prop $ct 'preset' '') -eq 'never-default') { & $add 'error' $onm 'profiles' "tweak '$tid' is never-default and cannot be part of a profile" }
                    elseif ($op.Name -eq 'work-managed' -and (Get-Prop $ct 'preset' '') -ne 'safe') { & $add 'error' $onm 'profiles' "work-managed may only contain safe tweaks ('$tid' is $(Get-Prop $ct 'preset' ''))" }
                }
            }
        }
    }

    # --- migrations ---------------------------------------------------------------------------------
    $mseen = @{}
    foreach ($m in @($Cat.Migrations)) {
        $mid = [string](Get-Prop $m 'id' '')
        if (-not $mid) { & $add 'error' '' 'migration' 'a migration has no id'; continue }
        if ($mseen.ContainsKey($mid)) { & $add 'error' $mid 'migration' 'duplicate migration id' }
        $mseen[$mid] = $true
        $mpath = [string](Get-Prop $m 'path' '')
        if ($mpath -notmatch '^(HKLM|HKCU):\\' -or $mpath -match '\\\.DEFAULT(\\|$)') { & $add 'error' $mid 'migration' "path '$mpath' must start with HKLM:\ or HKCU:\ and not use .DEFAULT" }
        if (-not (Get-Prop $m 'name' '')) { & $add 'error' $mid 'migration' 'no value name' }
        if ((Get-Prop $m 'valueType' 'DWord') -notin $RegistryValueTypes) { & $add 'error' $mid 'migration' 'valueType must be DWord or String' }
        if ($null -eq (Get-Prop $m 'oldValue' $null)) { & $add 'error' $mid 'migration' 'oldValue is required' }
        $act = [string](Get-Prop $m 'action' '')
        if ($act -notin 'restore-default', 'rewrite') { & $add 'error' $mid 'migration' "action '$act' must be restore-default or rewrite" }
        if ($act -eq 'rewrite' -and $null -eq (Get-Prop $m 'newValue' $null)) { & $add 'error' $mid 'migration' 'rewrite needs newValue' }
        if (-not [string](Get-Prop $m 'reason' '')) { & $add 'error' $mid 'migration' 'a migration needs a reason' }
        if ($mpath -match 'Image File Execution Options' -and [string](Get-Prop $m 'name' '') -ieq 'Debugger') { & $add 'error' $mid 'migration' 'IFEO Debugger is not allowed' }
    }
    , @($f.ToArray())
}

#endregion

#region apply / undo ---------------------------------------------------------

function Test-InjectedFailure($Rec) {
    # -TestEnvironment only: "failSteps": ["tweakId|target", ...] (wildcards allowed) makes those steps fail
    # before they touch anything, so the error policy can be tested without a real failure.
    if (-not $script:TestEnv) { return $false }
    $key = '{0}|{1}' -f $Rec.tweakId, $Rec.target
    foreach ($pat in @(Get-Prop $script:TestEnv 'failSteps' @())) { if ($key -like [string]$pat) { return $true } }
    $false
}

function Invoke-Step($Rec) {
    $prot = Get-RecProtection $Rec
    if ($prot) { throw (Format-Protected $prot) }
    if (Test-InjectedFailure $Rec) { throw 'injected failure (test environment)' }
    switch ($Rec.type) {
        'registry' {
            $Rec | Add-Member -NotePropertyName createdKeys -NotePropertyValue @(Get-MissingKeys $Rec.path) -Force
            Set-Reg $Rec
            Test-RegDesired (Get-RegState $Rec.path $Rec.name) $Rec
        }
        'service' { Set-SvcStart $Rec.name $Rec.startType; (Get-SvcState $Rec.name).startType -eq $Rec.startType }
        'task' { Disable-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName -WhatIf:$false | Out-Null; [string](Get-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName).State -eq 'Disabled' }
        'native' {
            $h = $NativeCommands[$Rec.tweakId]
            $nt = Get-Prop $Rec 'nativeTarget' $null
            $m0 = if ($h.ContainsKey('Metric')) { & $h.Metric $nt } else { $null }
            & $h.Set $h.Desired $nt | Out-Null
            # Measurements (free disk space, component store size) are kept next to the step so the effect is visible.
            if ($h.ContainsKey('Metric')) { $Rec | Add-Member -NotePropertyName metric -NotePropertyValue ([ordered]@{ before = $m0; after = (& $h.Metric $nt) }) -Force }
            if ($h.ContainsKey('Verify')) { [bool](& $h.Verify $nt) } else { [string](& $h.Get $nt) -eq [string]$h.Desired }
        }
        'appx' {
            # Removal ladder per package: (1) all users; (2) on failure the current user only; (3) the provisioned copy by exact name;
            # (4) failures are collected and reported (no RunOnce, no scheduled work left behind).
            Reset-Inventory
            $failures = New-Object System.Collections.Generic.List[string]
            $all = Get-AppxInventory 'listall'
            if (-not $all.Ok) { $all = Get-AppxInventory 'list' }
            foreach ($n in $Rec.names) {
                foreach ($pk in @($all.Items | Where-Object { $_.Name -ieq $n })) {
                    $r = Invoke-Tool 'appx' @('remove', $pk.Full, 'allusers')
                    if ($r.ExitCode -ne 0) {
                        $r2 = Invoke-Tool 'appx' @('remove', $pk.Full, 'user')
                        if ($r2.ExitCode -ne 0) { $failures.Add("$($pk.Full): $(Get-FirstLine $r2)") }
                    }
                }
                $prov = Get-AppxInventory 'provlist'
                foreach ($pp in @($prov.Items | Where-Object { $_.Name -ieq $n })) {
                    $r = Invoke-Tool 'appx' @('deprov', $pp.Full)
                    if ($r.ExitCode -ne 0) { $failures.Add("provisioned $($pp.Name): $(Get-FirstLine $r)") }
                }
            }
            Reset-Inventory
            $left = @(foreach ($n in $Rec.names) { @((Get-AppxInventory 'list').Items | Where-Object { $_.Name -ieq $n }); @((Get-AppxInventory 'provlist').Items | Where-Object { $_.Name -ieq $n }) })
            $Rec | Add-Member -NotePropertyName failures -NotePropertyValue @($failures) -Force
            if ($failures.Count) { throw ("could not remove: " + ($failures -join '; ')) }
            $left.Count -eq 0
        }
        'capability' {
            Assert-ToolOk (Invoke-Tool 'capability' @('remove', $Rec.name)) "Remove-WindowsCapability $($Rec.name)"
            Reset-Inventory
            $st = [string](@((Get-DismInventory 'capability').Items | Where-Object { $_.Name -ieq $Rec.name })[0].State)
            if ($st -eq 'UninstallPending') { $Rec | Add-Member -NotePropertyName restartNeeded -NotePropertyValue $true -Force }
            $st -in 'NotPresent', 'UninstallPending'
        }
        'optionalfeature' {
            $r = Invoke-Tool 'optionalfeature' @('disable', $Rec.name)
            Assert-ToolOk $r "Disable-WindowsOptionalFeature $($Rec.name)"
            $Rec | Add-Member -NotePropertyName restartNeeded -NotePropertyValue ("$($r.Output)" -match 'restart=True') -Force
            Reset-Inventory
            [string](@((Get-DismInventory 'optionalfeature').Items | Where-Object { $_.Name -ieq $Rec.name })[0].State) -in 'Disabled', 'DisablePending', 'DisabledWithPayloadRemoved'
        }
        'appxcheck' { Invoke-FrameworkCheck $Rec }
        default { throw "cannot apply step type $($Rec.type)" }
    }
}

function Get-NotRevertibleReason($Rec) {
    # Text for a step the engine can never undo by itself (AppX removal, one-shot native changes), or '' for every other step.
    # A capability record may also carry an 'irreversible' note, but its undo is a real Add-WindowsCapability, so it is not listed here.
    $type = [string](Get-Prop $Rec 'type' '')
    if ($type -eq 'appx') {
        # The reinstall manifest says how to get each package back.
        $cmds = @(Get-Prop (Get-Prop $Rec 'before' $null) 'manifest' @() | ForEach-Object { "$($_.name): $($_.command)" })
        if (-not $cmds.Count) { $cmds = @(Get-Prop (Get-Prop $Rec 'before' $null) 'packages' @()) }
        return ("AppX removal cannot be undone automatically; reinstall these packages: " + ($cmds -join ' | '))
    }
    if ($type -eq 'native') {
        $why = [string](Get-Prop $Rec 'irreversible' '')
        if ($why) { return "This change cannot be undone automatically: $why" }
    }
    ''
}

function Undo-Step($Rec) {
    switch ($Rec.type) {
        'registry' { Restore-Reg $Rec }
        'service' { Set-SvcStart $Rec.name $Rec.before.startType }
        'task' { if ($Rec.before.state -ne 'Disabled') { Enable-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName -WhatIf:$false | Out-Null } }
        'native' {
            $why = Get-NotRevertibleReason $Rec
            if ($why) { throw $why }
            Invoke-NativeUndo $NativeCommands[$Rec.tweakId] $Rec
        }
        'appx' { throw (Get-NotRevertibleReason $Rec) }   # the engine never downloads or installs anything
        'capability' {
            if ($Rec.before.state -eq 'Installed') {
                # A removal that was interrupted or failed may have changed nothing: only add it back (a download) when it is really gone.
                Reset-Inventory
                $curCap = @((Get-DismInventory 'capability').Items | Where-Object { $_.Name -ieq $Rec.name })
                if (-not ($curCap.Count -and [string]$curCap[0].State -eq 'Installed')) {
                    Assert-ToolOk (Invoke-Tool 'capability' @('add', $Rec.name)) "Add-WindowsCapability $($Rec.name) (needs Windows Update or Features on Demand media; check the update source policy)"
                }
            }
        }
        'optionalfeature' {
            if ($Rec.before.state -eq 'Enabled') {
                Reset-Inventory
                $curFeat = @((Get-DismInventory 'optionalfeature').Items | Where-Object { $_.Name -ieq $Rec.name })
                if (-not ($curFeat.Count -and [string]$curFeat[0].State -eq 'Enabled')) { Assert-ToolOk (Invoke-Tool 'optionalfeature' @('enable', $Rec.name)) "Enable-WindowsOptionalFeature $($Rec.name)" }
            }
        }
        'appxcheck' { }   # a check, and at most a re-registration of a framework that must stay registered: nothing to put back
        default { throw "cannot undo step type $($Rec.type)" }
    }
}

#endregion

#region per-tweak revert and drift detection ---------------------------------
# Snapshots (state-<runId>.json) are the record of what was applied. -Revert undoes chosen tweaks and marks their
# step records "reverted" inside the snapshot; -Drift reads the current state of every applied, not reverted step.
# Everything here that is named Get-* / Read-* only reads.

$RevertibleResults = @('Applied', 'Verified', 'Unverified')
# A step that was started and did not finish: 'Pending' (the run was interrupted: Ctrl-C, power loss) or 'Failed' (it threw, possibly
# after a partial change). Restoring the "before" state is idempotent, so -Undo and -Revert put these back too. -Drift does not compare them.
$InterruptedResults = @('Pending', 'Failed')

function Test-RecNonRevertible($Rec) { [bool](Get-NotRevertibleReason $Rec) }

function Test-RecRestorable($Rec) {
    # True when -Undo / -Revert should put this step record back: applied and not yet reverted, or interrupted (not for AppX, one-shot
    # native changes, or a step the engine refused as a protected target, where there is nothing to put back).
    if ([string](Get-Prop $Rec 'type' '') -eq 'appxcheck') { return $false }
    if (Get-Prop $Rec 'reverted' $false) { return $false }
    $res = [string](Get-Prop $Rec 'result' '')
    if ($res -in $RevertibleResults) { return $true }
    if ($res -in $InterruptedResults) { return (-not (Test-RecNonRevertible $Rec)) -and (-not (Get-RecProtection $Rec)) }
    $false
}

function Get-RestoreNote($Rec) { if ([string](Get-Prop $Rec 'result' '') -in $InterruptedResults) { 'restore of an interrupted step' } else { '' } }
$DriftOkFeatureStates = @('Disabled', 'DisablePending', 'DisabledWithPayloadRemoved')

function Read-Snapshots {
    # Snapshots that still hold applied steps (a file renamed *.reverted.json is fully undone), oldest first.
    $list = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $StateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name)
    foreach ($f in $files) {
        try { $st = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Send-Warning "Snapshot $($f.Name) cannot be read and is ignored: $($_.Exception.Message)"; continue }
        if ($null -eq $st -or $null -eq $st.PSObject.Properties['steps']) { Send-Warning "Snapshot $($f.Name) has no steps and is ignored."; continue }
        $list.Add([pscustomobject]@{ File = $f.FullName; Name = $f.Name; State = $st })
    }
    $list.ToArray()
}

function Get-AppliedRecords($Snapshots, [switch]$IncludeInterrupted) {
    # Applied step records that are not reverted yet, oldest snapshot first. Pos is the position inside the snapshot.
    # A not-run step changed nothing, and the framework check is a check. A failed or pending (interrupted) step may have changed
    # something: it is only listed with -IncludeInterrupted (revert), never for the drift comparison.
    foreach ($sn in @($Snapshots)) {
        $i = 0
        foreach ($r in @(Get-Prop $sn.State 'steps' @())) {
            $i++
            if (-not (Test-RecRestorable $r)) { continue }
            if (-not $IncludeInterrupted -and [string](Get-Prop $r 'result' '') -notin $RevertibleResults) { continue }
            [pscustomobject]@{ Snapshot = $sn; Pos = $i; Rec = $r; Key = ('{0}|{1}|{2}' -f $r.tweakId, $r.type, $r.target) }
        }
    }
}

function Get-RecShareKey($Rec) {
    # What a step record writes: type|target, or for a native handler with a SharedState the shared setting.
    $type = [string](Get-Prop $Rec 'type' '')
    if ($type -eq 'native') {
        $h = $NativeCommands[[string](Get-Prop $Rec 'tweakId' '')]
        if ($h -and $h.ContainsKey('SharedState')) { return "native|$($h.SharedState)" }
    }
    '{0}|{1}' -f $type, (Get-Prop $Rec 'target' '')
}

function Get-RevertGroups($Applied, [string[]]$Ids) {
    # One group per (tweak, step type, target) of the requested tweaks: every unreverted applied record of it across all
    # snapshots. When a target was changed by several runs (a re-apply after drift) the OLDEST record holds the state from
    # before DebloatKit touched it, so that one is restored and all of them are marked reverted. Newest group first, which
    # is the reverse of the order things were applied in.
    $mine = @($Applied | Where-Object { $Ids -contains $_.Rec.tweakId })
    $groups = foreach ($g in ($mine | Group-Object Key)) {
        $items = @($g.Group | Sort-Object @{ Expression = { $_.Snapshot.Name } }, @{ Expression = { $_.Pos } })
        $oldest = $items[0]; $newest = $items[-1]
        # Native targets are labelled with the tweak id, so handlers that write one setting (SharedState) are matched on that key instead.
        $myShare = Get-RecShareKey $oldest.Rec
        $others = @($Applied | Where-Object { (Get-RecShareKey $_.Rec) -eq $myShare -and $Ids -notcontains $_.Rec.tweakId } | ForEach-Object { $_.Rec.tweakId } | Select-Object -Unique)
        $note = if ($others.Count) { "also changed by $($others -join ', '); restoring the value from before the first run overwrites their change" } else { '' }
        [pscustomobject]@{ TweakId = $oldest.Rec.tweakId; Type = $oldest.Rec.type; Target = $oldest.Rec.target; Items = $items; Oldest = $oldest; Newest = $newest; Note = $note }
    }
    @($groups | Sort-Object @{ Expression = { $_.Newest.Snapshot.Name }; Descending = $true }, @{ Expression = { $_.Newest.Pos }; Descending = $true })
}

function Set-RecordsReverted($Items, [string]$By) {
    $ts = (Get-Date).ToString('o')
    foreach ($it in @($Items)) {
        $it.Rec | Add-Member -NotePropertyName reverted -NotePropertyValue $true -Force
        $it.Rec | Add-Member -NotePropertyName revertedAt -NotePropertyValue $ts -Force
        $it.Rec | Add-Member -NotePropertyName revertedBy -NotePropertyValue $By -Force
    }
}

function Save-SnapshotReverted($Snapshot) {
    # Writes the snapshot back. When nothing in it is left to revert the file is renamed *.reverted.json, like a full -Undo does.
    Save-State $Snapshot.State $Snapshot.File
    $left = @(@(Get-Prop $Snapshot.State 'steps' @()) | Where-Object { Test-RecRestorable $_ })
    if ($left.Count -eq 0 -and -not $script:DryRun) {
        $new = $Snapshot.File -replace '\.json$', '.reverted.json'
        Move-Item -LiteralPath $Snapshot.File -Destination $new -Force -WhatIf:$false
        $Snapshot.File = $new
    }
}

function Get-DriftState($Rec) {
    # Read-only. { State = InSync | Drifted | Unknown | NotTracked; Current; Note } for one applied step record:
    # is the target still at the value the run set? Unknown: it cannot be read now (needs admin, gone from this system).
    $r = { param($s, $c, $n) @{ State = $s; Current = $c; Note = $n } }
    try {
        switch ([string]$Rec.type) {
            'registry' {
                $cur = Get-RegState $Rec.path $Rec.name
                $txt = if ($cur.valueExists) { "$($cur.value) ($($cur.kind))" } else { '<absent>' }
                return (& $r $(if (Test-RegDesired $cur $Rec) { 'InSync' } else { 'Drifted' }) $txt '')
            }
            'service' {
                $s = Get-SvcState $Rec.name
                if (-not $s) { return (& $r 'Unknown' $null 'service not present') }
                return (& $r $(if ($s.startType -eq $Rec.startType) { 'InSync' } else { 'Drifted' }) $s.startType '')
            }
            'task' {
                $t = @(Get-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName -ErrorAction SilentlyContinue)
                if ($t.Count -eq 0) { return (& $r 'Unknown' $null 'task not present') }
                return (& $r $(if ([string]$t[0].State -eq 'Disabled') { 'InSync' } else { 'Drifted' }) ([string]$t[0].State) '')
            }
            'native' {
                $h = $NativeCommands[[string]$Rec.tweakId]
                if (-not $h) { return (& $r 'Unknown' $null 'this engine has no handler for the tweak any more') }
                if ($h.ContainsKey('Irreversible')) { return (& $r 'NotTracked' $null 'one-shot change: there is no state to compare') }
                $cur = Invoke-NativeGet $h (Get-Prop $Rec 'nativeTarget' $null)
                if ($null -eq $cur) { return (& $r 'Unknown' $null 'could not read current state (needs admin, or not present on this system)') }
                return (& $r $(if ([string]$cur -eq [string]$Rec.desired) { 'InSync' } else { 'Drifted' }) ([string]$cur) '')
            }
            'capability' {
                $inv = Get-DismInventory 'capability'
                if (-not $inv.Ok) { return (& $r 'Unknown' $null 'could not read the capability list (needs admin)') }
                $it = @($inv.Items | Where-Object { $_.Name -ieq $Rec.name })
                $st = if ($it.Count) { [string]$it[0].State } else { 'NotPresent' }
                return (& $r $(if ($st -in 'NotPresent', 'UninstallPending') { 'InSync' } else { 'Drifted' }) $st '')
            }
            'optionalfeature' {
                $inv = Get-DismInventory 'optionalfeature'
                if (-not $inv.Ok) { return (& $r 'Unknown' $null 'could not read the optional feature list (needs admin)') }
                $it = @($inv.Items | Where-Object { $_.Name -ieq $Rec.name })
                if (-not $it.Count) { return (& $r 'Unknown' $null 'optional feature not present') }
                return (& $r $(if ([string]$it[0].State -in $DriftOkFeatureStates) { 'InSync' } else { 'Drifted' }) ([string]$it[0].State) '')
            }
            'appx' {
                # Feature updates re-provision inbox apps: the removed packages are listed again.
                $inst = Get-AppxInventory 'list'
                if (-not $inst.Ok) { return (& $r 'Unknown' $null 'could not read the installed AppX packages') }
                $prov = Get-AppxInventory 'provlist'
                $back = @(foreach ($n in @(Get-Prop $Rec 'names' @())) {
                        if (@($inst.Items | Where-Object { $_.Name -ieq $n }).Count -or ($prov.Ok -and @($prov.Items | Where-Object { $_.Name -ieq $n }).Count)) { $n }
                    })
                return (& $r $(if ($back.Count) { 'Drifted' } else { 'InSync' }) $(if ($back.Count) { "back: $($back -join ',')" } else { 'not installed' }) '')
            }
            default { return (& $r 'NotTracked' $null "step type '$($Rec.type)' is not compared") }
        }
    } catch { return (& $r 'Unknown' $null $_.Exception.Message) }
}

function Get-DriftReport($Applied, $Catalog) {
    # Newest unreverted record per target of every applied tweak (a later re-apply replaces an older record), compared with the
    # live state. Returns one object per tweak with its steps. Migration records are not tweaks and are left out.
    Reset-Inventory
    $latest = @(foreach ($g in (@($Applied | Where-Object { $_.Rec.tweakId -notlike 'migration:*' }) | Group-Object Key)) {
            @($g.Group | Sort-Object @{ Expression = { $_.Snapshot.Name } }, @{ Expression = { $_.Pos } })[-1]
        })
    if ($latest.Count -eq 0) { return }
    $byTweak = $latest | Group-Object { $_.Rec.tweakId }
    $nowBuild = [string]$script:Os.BuildFull
    foreach ($tg in ($byTweak | Sort-Object Name)) {
        $steps = foreach ($it in ($tg.Group | Sort-Object @{ Expression = { $_.Snapshot.Name } }, @{ Expression = { $_.Pos } })) {
            $ds = Get-DriftState $it.Rec
            $sOs = Get-Prop $it.Snapshot.State 'os' $null
            [pscustomobject]@{ Type = [string]$it.Rec.type; Target = [string]$it.Rec.target; Desired = [string](Get-Prop $it.Rec 'desired' ''); Current = $ds.Current; State = $ds.State; Note = $ds.Note
                Run = [string](Get-Prop $it.Snapshot.State 'runId' ''); Snapshot = $it.Snapshot.Name; AppliedBuild = [string](Get-Prop $sOs 'BuildFull' '') }
        }
        $steps = @($steps)
        $drifted = @($steps | Where-Object State -EQ 'Drifted')
        $cmp = @($steps | Where-Object State -In 'InSync', 'Drifted')
        $status = if ($drifted.Count) { 'Drifted' } elseif ($cmp.Count) { 'InSync' } else { 'Unknown' }
        $tw = @(if ($Catalog) { $Catalog.Tweaks | Where-Object id -EQ $tg.Name | Select-Object -First 1 })
        $inCat = ($tw.Count -gt 0)
        $ap = if ($inCat) { Get-AppliesToResult $tw[0] $script:Os } else { $null }
        $na = if ($ap -and $ap.Mode -ne 'note') { [string]$ap.Reason } else { '' }
        $builds = @($steps | ForEach-Object { $_.AppliedBuild } | Where-Object { $_ } | Select-Object -Unique)
        [pscustomobject]@{ TweakId = $tg.Name; Status = $status; Steps = $steps; DriftedSteps = $drifted.Count; AppliedBuilds = $builds
            BuildChanged = [bool](@($builds | Where-Object { $_ -ne $nowBuild }).Count); InCatalog = $inCat; NotApplicable = $na }
    }
}

function New-DriftDocument($Report, [int]$SnapshotCount) {
    $rep = @($Report)
    $driftedT = @($rep | Where-Object Status -EQ 'Drifted')
    $nowBuild = [string]$script:Os.BuildFull
    $builds = @($rep | ForEach-Object { $_.AppliedBuilds } | Select-Object -Unique)
    $older = @($builds | Where-Object { $_ -ne $nowBuild })
    $banner = if ($driftedT.Count -eq 0) { '' }
    elseif ($older.Count) { "Windows reverted $($driftedT.Count) tweak(s) since build $($older -join ', '); this system is on build $nowBuild" }
    else { "$($driftedT.Count) applied tweak(s) are no longer in effect (Windows build $nowBuild, unchanged since they were applied)" }
    [ordered]@{
        mode = 'drift'
        os = [ordered]@{ editionId = $script:Os.EditionId; build = $script:Os.Build; ubr = $script:Os.Ubr; buildFull = $nowBuild; displayVersion = $script:Os.DisplayVersion }
        snapshots = $SnapshotCount
        appliedBuilds = @($builds)
        buildChanged = [bool]$older.Count
        banner = $banner
        summary = [ordered]@{ tweaks = $rep.Count; inSync = @($rep | Where-Object Status -EQ 'InSync').Count; drifted = $driftedT.Count; unknown = @($rep | Where-Object Status -EQ 'Unknown').Count
            driftedSteps = [int](@($rep | ForEach-Object { $_.DriftedSteps }) | Measure-Object -Sum).Sum }
        tweaks = @(foreach ($t in $rep) {
                [ordered]@{ id = $t.TweakId; status = $t.Status; driftedSteps = $t.DriftedSteps; appliedBuilds = @($t.AppliedBuilds); buildChanged = $t.BuildChanged; inCatalog = $t.InCatalog; notApplicable = $t.NotApplicable
                    steps = @(foreach ($s in $t.Steps) { [ordered]@{ type = $s.Type; target = $s.Target; desired = $s.Desired; current = $s.Current; state = $s.State; note = $s.Note; run = $s.Run; appliedBuild = $s.AppliedBuild } }) }
            })
    }
}

#endregion

#region apply / undo (continued) ---------------------------------------------

function New-RestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $orig = Get-RegState $key 'SystemRestorePointCreationFrequency'
    try {
        # Windows silently skips a new point if one exists from the last 24 h; lift that for this call only.
        New-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force -WhatIf:$false | Out-Null
        $before = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue).Count
        $cmd = "Checkpoint-Computer -Description 'DebloatKit $($script:RunId)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop"
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Output is discarded: anything the child writes to stdout would land before the JSON document of -AsJson runs.
            $null = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $cmd
            if ($LASTEXITCODE -ne 0) { throw 'Checkpoint-Computer failed (is System Protection enabled on C:?)' }
        } else { $null = Invoke-Expression $cmd }
        $after = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue).Count
        if ($after -le $before) { throw 'no new restore point was created (is System Protection enabled on C:?)' }
    } finally {
        if ($orig.valueExists) { New-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -PropertyType $orig.kind -Value $orig.value -Force -WhatIf:$false | Out-Null }
        else { Remove-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}

#endregion

#region main -----------------------------------------------------------------

function Exit-WithError([string]$Message, [int]$Code = 1) {
    # Without -AsJson the message goes to the host stream so a caller using '*>&1 | Tee-Object' (the GUI's
    # elevated run) captures it. [Console]::Error is not a PowerShell stream and would be lost there.
    # With -AsJson stdout must stay clean, so it goes to stderr only.
    if ($AsJson) { [Console]::Error.WriteLine("ERROR: $Message") }
    else { Write-Host "ERROR: $Message" -ForegroundColor Red }
    exit $Code
}

function Write-ReapplyDoc($Reapply, [int]$Code) {
    # -Drift -Reapply -AsJson: the drift report plus what the re-apply planned or did, as one JSON document, then exit.
    $script:DriftDoc['reapply'] = $Reapply
    Write-Output ($script:DriftDoc | ConvertTo-Json -Depth 8)
    exit $Code
}

function Test-SidMismatch {
    # True when -ExpectedSid was given and this process runs as another user.
    if (-not $ExpectedSid) { return $false }
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $ExpectedSid
}

if ($TestEnvironment) {
    # The fake managed flag / preflight / edition would lift the managed-device and preflight guards while registry, service and task
    # steps still hit the real system. So a test environment may only drive changes when the test runner says so; previews and reads are always fine.
    $teReadOnly = $script:DryRun -or $List -or $Lint -or ($PSCmdlet.ParameterSetName -eq 'Drift' -and -not $Reapply)
    if (-not $teReadOnly -and $env:DEBLOATKIT_TESTENV -ne '1') { Exit-WithError '-TestEnvironment is for tests: it fakes the managed-device and preflight state, so it is only accepted with -WhatIf, -List, -Lint or -Drift (read-only), or when DEBLOATKIT_TESTENV=1 is set by the test runner.' }
    try { Initialize-TestEnvironment $TestEnvironment } catch { Exit-WithError $_.Exception.Message }
    Send-Warning 'TEST ENVIRONMENT: managed state, OS edition/build and fsutil/powercfg/execution policy are fakes read from the test file.'
}

# ---- Lint ----
if ($Lint) {
    if (-not (Test-Path -LiteralPath $CatalogPath)) { Exit-WithError "Catalog not found: $CatalogPath" }
    try { $lintCat = Read-Catalog $CatalogPath } catch { Exit-WithError "Cannot read catalog: $($_.Exception.Message)" }
    $findings = Invoke-CatalogLint $lintCat   # the function returns the array as one object (comma operator)
    $nErr = @($findings | Where-Object severity -EQ 'error').Count
    $nWarn = @($findings | Where-Object severity -EQ 'warning').Count
    $nInfo = @($findings | Where-Object severity -EQ 'info').Count
    if ($AsJson) {
        $doc = [ordered]@{ schemaVersion = $lintCat.SchemaVersion; currentSchemaVersion = $CurrentSchemaVersion; tweaks = @($lintCat.Tweaks).Count; migrations = @($lintCat.Migrations).Count; errors = $nErr; warnings = $nWarn; info = $nInfo; findings = $findings }
        Write-Output (ConvertTo-Json -InputObject $doc -Depth 5)
    } else {
        $shown = @($findings | Where-Object severity -NE 'info')
        if ($shown.Count) { $shown | Select-Object severity, tweakId, rule, message | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
        Write-Host ("Lint: {0} tweak(s), {1} migration(s), schemaVersion {2}: {3} error(s), {4} warning(s), {5} info" -f @($lintCat.Tweaks).Count, @($lintCat.Migrations).Count, $lintCat.SchemaVersion, $nErr, $nWarn, $nInfo) -ForegroundColor $(if ($nErr) { 'Red' } else { 'Green' })
    }
    exit $(if ($nErr) { 1 } else { 0 })
}

# ---- Undo ----
if ($PSCmdlet.ParameterSetName -eq 'Undo') {
    if (-not $script:DryRun -and -not (Test-Elevated)) { Exit-WithError 'Undo requires an elevated (Run as administrator) PowerShell.' }
    $file = if ($Undo -eq 'latest') { Get-ChildItem -LiteralPath $StateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName } else { $Undo }
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { Exit-WithError "No snapshot found ('$Undo' in $StateDir)." }
    $state = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    # Undo is never gated by the preflight (reverting must stay possible), but say when Windows has been updated since.
    $snapOs = Get-Prop $state 'os' $null
    $snapBuild = [string](Get-Prop $snapOs 'BuildFull' '')
    $nowBuild = (Get-OsInfo).BuildFull
    if ($snapBuild -and $nowBuild -and $snapBuild -ne $nowBuild) {
        Write-Host ("Note: this snapshot was taken on Windows build {0}; this system is now on build {1}. Values Windows changed in between are put back to the snapshot state." -f $snapBuild, $nowBuild) -ForegroundColor Yellow
    }
    $script:LogFile = Join-Path $StateDir "undo-$($script:RunId).log.jsonl"
    $todo = @($state.steps | Where-Object { Test-RecRestorable $_ })
    [array]::Reverse($todo)
    if ((Test-SidMismatch) -and @($todo | Where-Object { $_.type -eq 'registry' -and $_.path -match '^(HKCU:|HKEY_CURRENT_USER)' }).Count) {
        Exit-WithError 'This process runs as a different user than the one who started the GUI (UAC used other credentials), so per-user (HKCU) steps would be restored in the wrong user hive. Nothing was reverted. Run the undo from an elevated prompt as the signed-in user.'
    }
    Write-Host "Reverting $($todo.Count) step(s) from $file" -ForegroundColor Cyan
    $failed = 0     # steps whose undo threw: they can be retried, so the snapshot is kept
    $terminal = 0   # AppX removals and one-shot changes: never undoable, they do not keep the snapshot alive
    $undoTs = (Get-Date).ToString('o')
    $rows = foreach ($r in $todo) {
        $err = ''
        if ($script:DryRun) { $res = 'WouldRevert' }
        elseif (Test-RecNonRevertible $r) { $res = 'NotRevertible'; $err = Get-NotRevertibleReason $r; $terminal++ }
        else {
            try {
                Undo-Step $r; $res = 'Reverted'
                $r | Add-Member -NotePropertyName reverted -NotePropertyValue $true -Force
                $r | Add-Member -NotePropertyName revertedAt -NotePropertyValue $undoTs -Force
                $r | Add-Member -NotePropertyName revertedBy -NotePropertyValue $script:RunId -Force
            } catch { $res = 'Failed'; $err = $_.Exception.Message; $failed++ }
        }
        if (-not $script:DryRun) { Write-RunLog @{ mode = 'undo'; tweak = $r.tweakId; target = $r.target; result = $res; error = $err } }
        [pscustomobject]@{ Tweak = $r.tweakId; Target = $r.target; RestoredTo = (Format-Val $r.current); Result = $res; Error = $err; Note = (Get-RestoreNote $r) }
    }
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    if (-not $script:DryRun) {
        # Only a fully undone snapshot is retired. After a failure (a capability that needs Windows Update, a locked key) the steps that did
        # revert are marked in place and the file stays, so -Undo / -Revert / -Drift can still see it and the failed steps can be retried.
        Save-State $state $file
        if ($failed -eq 0) { Move-Item -LiteralPath $file -Destination ($file -replace '\.json$', '.reverted.json') -Force -WhatIf:$false }
        else { Write-Host ("{0} step(s) could not be reverted. The snapshot was kept ({1}); run -Undo again after fixing the cause." -f $failed, $file) -ForegroundColor Yellow }
    }
    if ($failed -or $terminal) { exit 2 }
    exit 0
}

# ---- Revert (per tweak) ----
if ($PSCmdlet.ParameterSetName -eq 'Revert') {
    if (-not $script:DryRun -and -not (Test-Elevated)) { Exit-WithError 'Revert requires an elevated (Run as administrator) PowerShell.' }
    $script:Os = Get-OsInfo
    $snaps = @(Read-Snapshots)
    $applied = @(Get-AppliedRecords $snaps -IncludeInterrupted)
    $groups = @(Get-RevertGroups $applied $Revert)
    $found = @($groups | ForEach-Object { $_.TweakId } | Select-Object -Unique)
    $notFound = @($Revert | Where-Object { $found -notcontains $_ })
    if ($groups.Count -eq 0) { Exit-WithError "Nothing to revert: no applied step of $($Revert -join ', ') that is not already reverted in the snapshots in $StateDir." }
    if ($notFound.Count) { Send-Warning "No applied step found in the snapshots for: $($notFound -join ', ')" }
    if ((Test-SidMismatch) -and @($groups | Where-Object { $_.Type -eq 'registry' -and $_.Oldest.Rec.path -match '^(HKCU:|HKEY_CURRENT_USER)' }).Count) {
        Exit-WithError 'This process runs as a different user than the one who started the GUI (UAC used other credentials), so per-user (HKCU) steps would be restored in the wrong user hive. Nothing was reverted. Run the revert from an elevated prompt as the signed-in user.'
    }
    $nowBuild = [string]$script:Os.BuildFull
    $oldBuilds = @($groups | ForEach-Object { [string](Get-Prop (Get-Prop $_.Oldest.Snapshot.State 'os' $null) 'BuildFull' '') } | Where-Object { $_ -and $_ -ne $nowBuild } | Select-Object -Unique)
    if ($oldBuilds.Count) { Write-Info ("Note: the steps were applied on Windows build {0}; this system is now on build {1}. Values Windows changed in between are put back to the state from before DebloatKit changed them." -f ($oldBuilds -join ', '), $nowBuild) Yellow }
    $script:LogFile = Join-Path $StateDir "revert-$($script:RunId).log.jsonl"
    Write-Info "Reverting $($groups.Count) target(s) of $($found.Count) tweak(s): $($found -join ', ')" Cyan
    $failed = 0
    $rows = foreach ($g in $groups) {
        $rec = $g.Oldest.Rec
        # AppX removal and one-shot native changes have no automatic undo. A capability record may carry an 'irreversible' note too
        # (WSUS without a repair source), but its undo is a real Add-WindowsCapability. Undo-Step is never called in a dry run.
        $nonRev = Test-RecNonRevertible $rec
        $res = ''; $err = ''
        if ($nonRev) { $res = 'NotRevertible'; $err = Get-NotRevertibleReason $rec; $failed++ }
        elseif ($script:DryRun) { $res = 'WouldRevert' }
        else {
            try { $null = Undo-Step $rec; $res = 'Reverted' }
            catch { $res = 'Failed'; $err = $_.Exception.Message; $failed++ }
        }
        if ($res -eq 'Reverted') {
            Set-RecordsReverted $g.Items $script:RunId
            foreach ($sn in @($g.Items | ForEach-Object { $_.Snapshot } | Sort-Object Name -Unique)) { Save-SnapshotReverted $sn }
        }
        Write-RunLog @{ mode = 'revert'; tweak = $g.TweakId; target = $g.Target; result = $res; error = $err; snapshot = $g.Oldest.Snapshot.Name; runs = @($g.Items).Count }
        [pscustomobject]@{ Tweak = $g.TweakId; Type = $g.Type; Target = $g.Target; RestoredTo = (Format-Val $rec.current '<absent>' 200); Result = $res; Error = $err; Snapshot = $g.Oldest.Snapshot.Name; Runs = @($g.Items).Count; Note = (@($g.Note, (Get-RestoreNote $rec)) | Where-Object { $_ }) -join '; ' }
    }
    $rows = @($rows)
    $nRev = @($rows | Where-Object Result -EQ 'Reverted').Count
    $nWould = @($rows | Where-Object Result -EQ 'WouldRevert').Count
    if ($AsJson) {
        $doc = [ordered]@{
            mode = 'revert'; dryRun = [bool]$script:DryRun; requested = @($Revert); notFound = @($notFound)
            os = [ordered]@{ buildFull = $nowBuild; build = $script:Os.Build; ubr = $script:Os.Ubr }
            summary = [ordered]@{ targets = $rows.Count; reverted = $nRev; wouldRevert = $nWould; failed = @($rows | Where-Object Result -EQ 'Failed').Count; notRevertible = @($rows | Where-Object Result -EQ 'NotRevertible').Count }
            results = @(foreach ($x in $rows) { [ordered]@{ tweakId = $x.Tweak; type = $x.Type; target = $x.Target; restoredTo = $x.RestoredTo; result = $x.Result; error = $x.Error; snapshot = $x.Snapshot; runs = $x.Runs; note = $x.Note } })
        }
        Write-Output ($doc | ConvertTo-Json -Depth 6)
    } else {
        $rows | Select-Object Tweak, Target, RestoredTo, Result, Error, Note | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
        foreach ($x in @($rows | Where-Object Result -EQ 'NotRevertible')) { Write-Host ("NOT REVERTIBLE {0} {1}: {2}" -f $x.Tweak, $x.Target, $x.Error) -ForegroundColor Yellow }
        if ($script:DryRun) { Write-Host 'WhatIf: nothing was changed and nothing was written to disk.' -ForegroundColor Yellow }
        else { Write-Host ("Reverted {0} of {1} target(s). The steps are marked reverted in their snapshots; a later -Undo skips them." -f $nRev, $rows.Count) }
    }
    if ($failed) { exit 2 }
    exit 0
}

# ---- Drift (and -Reapply) ----
$script:DriftDoc = $null
$script:ReapplySkipped = @()
if ($PSCmdlet.ParameterSetName -eq 'Drift') {
    if ($EnabledPresets -notcontains $Preset) { Exit-WithError "Preset '$Preset' is not enabled in this version. Enabled: $($EnabledPresets -join ', ')." }
    if (-not (Test-Path -LiteralPath $CatalogPath)) { Exit-WithError "Catalog not found: $CatalogPath" }
    try { $cat = Read-Catalog $CatalogPath } catch { Exit-WithError "Cannot read catalog: $($_.Exception.Message)" }
    $script:Os = Get-OsInfo
    $snaps = @(Read-Snapshots)
    $applied = @(Get-AppliedRecords $snaps)
    $report = @(Get-DriftReport $applied $cat)
    if ($Only) { $report = @($report | Where-Object { $Only -contains $_.TweakId }) }
    if ($Skip) { $report = @($report | Where-Object { $Skip -notcontains $_.TweakId }) }
    $script:DriftDoc = New-DriftDocument $report $snaps.Count
    $driftedT = @($report | Where-Object Status -EQ 'Drifted')
    # Tweaks a re-apply can act on: still in the catalog, in the enabled preset and applicable to this build.
    $eligible = @(); $notEligible = @()
    foreach ($t in $driftedT) {
        $ct = @($cat.Tweaks | Where-Object { $_.id -eq $t.TweakId } | Select-Object -First 1)
        if (-not $t.InCatalog -or $ct.Count -eq 0) { $notEligible += [ordered]@{ id = $t.TweakId; reason = 'not in the catalog any more' } }
        elseif ($ct[0].preset -ne $Preset) { $notEligible += [ordered]@{ id = $t.TweakId; reason = "preset '$($ct[0].preset)' is not '$Preset'" } }
        elseif ($t.NotApplicable) { $notEligible += [ordered]@{ id = $t.TweakId; reason = "not applicable: $($t.NotApplicable)" } }
        else { $eligible += $t.TweakId }
    }
    if (-not $Reapply) {
        if ($AsJson) { Write-Output ($script:DriftDoc | ConvertTo-Json -Depth 8); exit 0 }
        $sum = $script:DriftDoc.summary
        Write-Host ("Drift check: {0} snapshot(s), {1} applied tweak(s): {2} in effect, {3} drifted, {4} could not be compared." -f $snaps.Count, $sum.tweaks, $sum.inSync, $sum.drifted, $sum.unknown) -ForegroundColor Cyan
        Write-Host ("Windows build now {0}; applied on {1}." -f $script:Os.BuildFull, $(if (@($script:DriftDoc.appliedBuilds).Count) { @($script:DriftDoc.appliedBuilds) -join ', ' } else { '(nothing applied)' }))
        $rowsD = @(foreach ($t in $report) { foreach ($s in $t.Steps) { if ($s.State -in 'Drifted', 'Unknown') { [pscustomobject]@{ Tweak = $t.TweakId; Target = $s.Target; Wanted = (Format-Val $s.Desired '' ); Now = (Format-Val $s.Current); State = $s.State; AppliedOn = $s.AppliedBuild; Note = $s.Note } } } })
        if ($rowsD.Count) { $rowsD | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
        if ($script:DriftDoc.banner) { Write-Host $script:DriftDoc.banner -ForegroundColor Yellow }
        foreach ($n in $notEligible) { Write-Host ("  not re-applicable: {0}: {1}" -f $n.id, $n.reason) }
        if ($driftedT.Count) { Write-Host 'Nothing was changed. Preview the fix with: .\DebloatKit.ps1 -Drift -Reapply -WhatIf   apply it with: .\DebloatKit.ps1 -Drift -Reapply' } else { Write-Host 'Nothing has drifted.' -ForegroundColor Green }
        exit 0
    }
    if ($eligible.Count -eq 0) {
        if ($AsJson) { $script:DriftDoc['reapply'] = [ordered]@{ dryRun = [bool]$script:DryRun; ids = @(); skipped = @($notEligible); plan = @(); results = @() }; Write-Output ($script:DriftDoc | ConvertTo-Json -Depth 8); exit 0 }
        Write-Host $(if ($driftedT.Count) { 'None of the drifted tweaks can be re-applied here (see -Drift for the reasons).' } else { 'Nothing has drifted; nothing to re-apply.' })
        foreach ($n in $notEligible) { Write-Host ("  not re-applicable: {0}: {1}" -f $n.id, $n.reason) }
        exit 0
    }
    # Re-apply goes through the normal apply path below (preflight, restore point, snapshot, verify), for the drifted tweaks only.
    # They were applied by the user before, so unverified ones are included.
    if ($script:DriftDoc.banner) { Write-Info $script:DriftDoc.banner Yellow }
    Write-Info ("Re-applying {0} drifted tweak(s): {1}" -f $eligible.Count, ($eligible -join ', ')) Cyan
    $Only = @($eligible)
    $IncludeUnverified = [switch]$true
    $script:ReapplySkipped = @($notEligible)
}

# ---- List / Apply ----
if ($EnabledPresets -notcontains $Preset) { Exit-WithError "Preset '$Preset' is not enabled in this version. Enabled: $($EnabledPresets -join ', ')." }
if (-not (Test-Path -LiteralPath $CatalogPath)) { Exit-WithError "Catalog not found: $CatalogPath" }
try { $cat = Read-Catalog $CatalogPath } catch { Exit-WithError "Cannot read catalog: $($_.Exception.Message)" }
$catalog = $cat.Tweaks
$tweaks = @($catalog | Where-Object { $_.preset -eq $Preset })
if ($Only) {
    $unknown = @($Only | Where-Object { $tweaks.id -notcontains $_ })
    if ($unknown) { Exit-WithError "Unknown or non-$Preset tweak id(s): $($unknown -join ', ')" }
    $tweaks = @($tweaks | Where-Object { $Only -contains $_.id })
}
if ($Skip) { $tweaks = @($tweaks | Where-Object { $Skip -notcontains $_.id }) }

$managed = Get-ManagedState
$isManaged = $managed.AzureAdJoined -or $managed.DomainJoined -or $managed.MdmEnrolled
if ($isManaged) {
    Send-Warning ("Managed device detected (Entra joined: {0}, domain joined: {1}, MDM enrolled: {2}{3}). Policy keys may conflict with your organisation's settings; tweaks that fight managed-device policy (managedSkip in the catalog) are skipped. Check with your IT admin before applying." -f `
            $managed.AzureAdJoined, $managed.DomainJoined, $managed.MdmEnrolled, $(if ($managed.Tenant) { ", tenant: $($managed.Tenant)" } else { '' }))
}

$script:Os = Get-OsInfo
$pendingMigrations = @(Get-MigrationPlan $cat.Migrations)
foreach ($m in $pendingMigrations) { $null = Add-PlanPolicy $m }
if ($Migrate) {
    $tweaks = @()
    $plan = $pendingMigrations
} else {
    # Execution order: step "order" hints first, then catalog order. Skip records keep their place.
    $script:SharedClaims = @{}
    $plan = @(Sort-PlanSteps @(foreach ($t in $tweaks) { Get-Plan $t $isManaged }))
    # After any AppX removal the engine checks that the framework packages are still registered (applies and -WhatIf, not -List).
    if (-not $List) { $chk = New-AppxCheckRecord $plan; if ($chk) { $plan = @(Sort-PlanSteps @($plan + $chk)) } }
}
$planWeight = [int](@($plan | Where-Object action -EQ 'Change' | ForEach-Object { [int](Get-Prop $_ 'weight' 0) }) | Measure-Object -Sum).Sum
$preflight = Get-PreflightState (-not $NoRestorePoint)

if ($List) {
    $byTweak = $plan | Group-Object tweakId
    $rows = foreach ($g in $byTweak) {
        $acts = @($g.Group.action)
        $status = if ($acts -contains 'Change') { if ($acts -contains 'InSync') { 'Partial' } else { 'NotApplied' } } elseif ($acts -contains 'InSync') { 'Applied' } else { 'Skipped' }
        $t = $tweaks | Where-Object id -EQ $g.Name | Select-Object -First 1
        $wt = [int](@($g.Group | Where-Object action -EQ 'Change' | ForEach-Object { [int](Get-Prop $_ 'weight' 0) }) | Measure-Object -Sum).Sum
        [pscustomobject]@{ Id = $g.Name; Category = $t.category; Status = $status; Steps = $acts.Count; Eff = [int](Get-Prop $t 'effectiveness' 0); Weight = $wt; Note = (@($g.Group.reason | Where-Object { $_ }) | Select-Object -Unique) -join '; ' }
    }
    $sorted = if ($SortBy -eq 'effectiveness') { @($rows) | Sort-Object @{ Expression = 'Eff'; Descending = $true }, Category, Id } else { @($rows) | Sort-Object Category, Id }
    if ($AsJson) {
        $out = foreach ($r in $sorted) {
            $t = $tweaks | Where-Object id -EQ $r.Id | Select-Object -First 1
            [ordered]@{ id = $r.Id; category = $r.Category; preset = $t.preset; status = $r.Status; steps = $r.Steps; note = $r.Note
                effectiveness = $r.Eff; evidenceQuality = (Get-Prop $t 'evidenceQuality' 'none'); verification = (Get-Prop $t 'verification' ''); managedSkip = (Get-Prop $t 'managedSkip' $null); weight = $r.Weight }
        }
        $doc = [ordered]@{
            managed = [ordered]@{ isManaged = [bool]$isManaged; azureAdJoined = $managed.AzureAdJoined; domainJoined = $managed.DomainJoined; mdmEnrolled = $managed.MdmEnrolled; tenant = $managed.Tenant }
            os = [ordered]@{ editionId = $script:Os.EditionId; build = $script:Os.Build; ubr = $script:Os.Ubr; buildFull = $script:Os.BuildFull; displayVersion = $script:Os.DisplayVersion; chassis = $script:Os.Chassis; isLtsc = [bool]$script:Os.IsLtsc }
            preflight = [ordered]@{ blocked = [bool]$preflight.Blocked; checks = @($preflight.Checks | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title; status = $_.status; blocking = [bool]$_.blocking; detail = $_.detail } }) }
            catalog = [ordered]@{ schemaVersion = $cat.SchemaVersion; currentSchemaVersion = $CurrentSchemaVersion; catalogVersion = $cat.CatalogVersion }
            migrations = @(foreach ($m in $pendingMigrations) { [ordered]@{ id = ($m.tweakId -replace '^migration:', ''); target = $m.target; current = [string]$m.current; desired = [string]$m.desired; reason = $m.reason } })
            tweaks  = @($out)
        }
        Write-Output ($doc | ConvertTo-Json -Depth 6)
        exit 0
    }
    $sorted | Select-Object Id, Category, Status, Steps, Eff, Note | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    $sum = $rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("{0} tweaks in preset '{1}': {2}" -f @($rows).Count, $Preset, ($sum -join ', '))
    Write-Host ("Windows build {0} ({1}, {2})" -f $script:Os.BuildFull, $script:Os.EditionId, $script:Os.Chassis.ToLower())
    Write-Host $(if ($preflight.Blocked) { 'Preflight: an apply would be refused right now.' } else { 'Preflight: ready to apply.' }) -ForegroundColor $(if ($preflight.Blocked) { 'Yellow' } else { 'Green' })
    Format-PreflightLines $preflight | ForEach-Object { Write-Host $_ }
    if ($pendingMigrations.Count) { Write-Host ("{0} value(s) set by an older DebloatKit version are no longer recommended; review with -Migrate -WhatIf, apply with -Migrate." -f $pendingMigrations.Count) -ForegroundColor Yellow }
    exit 0
}

if ($AsJson -and -not $script:DryRun -and -not $script:DriftDoc) { Exit-WithError '-AsJson needs -List or -WhatIf (it describes a plan; it does not apply one).' }

# Apply (or -WhatIf preview)
if (-not $script:DryRun) {
    if (-not (Test-Elevated)) { Exit-WithError 'Applying tweaks requires an elevated (Run as administrator) PowerShell. Use -List or -WhatIf to preview.' }
    if ($isManaged -and -not $Force) { Exit-WithError 'Managed device: re-run with -Force to apply anyway (see warning above).' }
}

$changes = @($plan | Where-Object action -EQ 'Change')
Write-Info ("Preset '{0}'{6}: {1} tweaks, {2} steps -> {3} to change, {4} already in effect, {5} skipped" -f $Preset, $tweaks.Count, $plan.Count, $changes.Count, @($plan | Where-Object action -EQ 'InSync').Count, @($plan | Where-Object action -EQ 'Skip').Count, $(if ($Migrate) { ' (migrations)' } else { '' })) Cyan

if ($script:DryRun -and $AsJson) {
    $items = @(foreach ($p in $plan) { [ordered]@{ tweakId = $p.tweakId; type = $p.type; target = $p.target; current = $(if ($null -ne $p.current) { [string]$p.current } else { $null }); desired = $(if ($null -ne $p.desired) { [string]$p.desired } else { $null }); action = $p.action; reason = $p.reason
                order = [int](Get-Prop $p 'order' $DefaultStepOrder); weight = [int](Get-Prop $p 'weight' 0); onError = [string](Get-Prop $p 'onError' 'continue') } })
    if ($script:DriftDoc) {
        $pfDoc = [ordered]@{ blocked = [bool]$preflight.Blocked; checks = @($preflight.Checks | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title; status = $_.status; blocking = [bool]$_.blocking; detail = $_.detail } }) }
        Write-ReapplyDoc ([ordered]@{ dryRun = $true; ids = @($Only); skipped = @($script:ReapplySkipped); preflight = $pfDoc; plan = $items; results = @() }) 0
    }
    Write-Output (ConvertTo-Json -InputObject $items -Depth 4)
    exit 0
}

if ($script:DryRun) {
    $plan | Where-Object action -NE 'InSync' | Sort-Object action, @{ Expression = { [int](Get-Prop $_ 'order' $DefaultStepOrder) } }, @{ Expression = { [int](Get-Prop $_ 'seq' 0) } } |
        Select-Object @{n = 'Action'; e = { $_.action } }, @{n = 'Tweak'; e = { $_.tweakId } }, @{n = 'Target'; e = { $_.target } }, @{n = 'Current'; e = { Format-Val $_.current } }, @{n = 'Desired'; e = { Format-Val $_.desired '' } }, @{n = 'Reason'; e = { $_.reason } } |
        Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host
    Write-Host ("Windows build {0} ({1}, {2}). Work to do: {3} weight unit(s) in {4} step(s)." -f $script:Os.BuildFull, $script:Os.EditionId, $script:Os.Chassis.ToLower(), $planWeight, $changes.Count)
    if ($changes.Count) {
        Write-Host $(if ($preflight.Blocked) { 'Preflight: an apply would be refused right now (-SkipPreflight overrides).' } else { 'Preflight: ready to apply.' }) -ForegroundColor $(if ($preflight.Blocked) { 'Yellow' } else { 'Green' })
        Format-PreflightLines $preflight | ForEach-Object { Write-Host $_ }
    }
    Write-Host 'WhatIf: nothing was changed and nothing was written to disk.' -ForegroundColor Yellow
    exit 0
}

if ($changes.Count -eq 0) {
    if ($script:DriftDoc) { Write-ReapplyDoc ([ordered]@{ dryRun = $false; ids = @($Only); skipped = @($script:ReapplySkipped); plan = @(); results = @() }) 0 }
    Write-Host 'Nothing to change.'; exit 0
}

if ((Test-SidMismatch) -and @($changes | Where-Object { $_.type -eq 'registry' -and $_.path -match '^(HKCU:|HKEY_CURRENT_USER)' }).Count) {
    Exit-WithError 'This process runs as a different user than the one who started the GUI (UAC used other credentials), so per-user (HKCU) tweaks would be written to that other user''s hive and not to yours. Nothing was changed. Run from an elevated prompt as the signed-in user, or deselect the per-user tweaks.'
}

# Preflight: refuse while the machine is mid-servicing, waiting for a reboot, on battery or short of disk.
# Runs before anything is written (state folder, restore point). -Undo is never gated.
if ($preflight.Blocked) {
    $bl = @($preflight.Checks | Where-Object blocking | ForEach-Object { "  - $($_.title): $($_.detail)" }) -join "`n"
    if (-not $SkipPreflight) {
        Exit-WithError "Preflight check failed; nothing was changed.`n$bl`nFix the above and run again, or re-run with -SkipPreflight to apply anyway."
    }
    Send-Warning "Preflight skipped (-SkipPreflight) although these checks fail:`n$bl"
}

# Only now (after every refusal check) is anything written to disk.
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force -WhatIf:$false | Out-Null }
$script:LogFile = Join-Path $StateDir "run-$($script:RunId).log.jsonl"

# Progress is weighted: a restore point and an AppX removal cost more than a registry value.
$totalWeight = [math]::Max(1, $planWeight + $(if ($NoRestorePoint) { 0 } else { $RestorePointWeight }))
$doneWeight = 0
function Write-ProgressLine([string]$What) {
    if ($AsJson) { return }
    Write-Host ("[progress] {0}% - {1}" -f [int][math]::Min(100, [math]::Floor(100 * $doneWeight / $totalWeight)), $What)
}

if (-not $NoRestorePoint) {
    Write-Info 'Creating restore point...'
    try { New-RestorePoint; Write-RunLog @{ mode = 'apply'; event = 'restore-point'; result = 'ok' } }
    catch { Exit-WithError "Restore point failed: $($_.Exception.Message). Fix System Protection or use -NoRestorePoint." }
    $doneWeight += $RestorePointWeight
    Write-ProgressLine 'restore point created'
}

$statePath = Join-Path $StateDir "state-$($script:RunId).json"
$pfSummary = [ordered]@{ skipped = [bool]$SkipPreflight; blocked = [bool]$preflight.Blocked; checks = @($preflight.Checks | ForEach-Object { [ordered]@{ id = $_.id; status = $_.status; detail = $_.detail } }) }
$state = [ordered]@{ version = 1; catalogSchemaVersion = $cat.SchemaVersion; catalogVersion = $cat.CatalogVersion; migrate = [bool]$Migrate; os = $script:Os; preflight = $pfSummary; runId = $script:RunId; computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; preset = $Preset; reapply = [bool]$Reapply; catalog = (Resolve-Path $CatalogPath).Path; steps = @() }
$failed = 0
$aborted = $null
$stoppedTweaks = @{}
foreach ($rec in $changes) {
    $rec | Add-Member -NotePropertyName result -NotePropertyValue 'Pending' -Force
    # Snapshot first, so a crash mid-step is still revertible.
    $state.steps += $rec
    # Error policy of an earlier failed step: stop-tweak skips the rest of that tweak, abort-run skips everything left.
    if ($aborted -or $stoppedTweaks.ContainsKey($rec.tweakId)) {
        $rec.result = $(if ($aborted) { 'Aborted' } else { 'NotRun' })
        Write-RunLog @{ mode = 'apply'; tweak = $rec.tweakId; target = $rec.target; result = $rec.result; error = $(if ($aborted) { "run aborted by onError=abort-run at $aborted" } else { 'an earlier step of this tweak failed (onError=stop-tweak)' }) }
        continue
    }
    Save-State $state $statePath
    try {
        $ok = Invoke-Step $rec
        $rec.result = if ($ok) { 'Verified' } else { 'Unverified' }
        $err = ''
    } catch {
        $rec.result = 'Failed'; $err = $_.Exception.Message; $failed++
        $rec | Add-Member -NotePropertyName error -NotePropertyValue $err -Force
        $pol = [string](Get-Prop $rec 'onError' 'continue')
        if ($pol -eq 'stop-tweak') { $stoppedTweaks[$rec.tweakId] = $true }
        elseif ($pol -eq 'abort-run') { $aborted = "$($rec.tweakId) ($($rec.target))" }
    }
    Save-State $state $statePath
    $doneWeight += [int](Get-Prop $rec 'weight' 0)
    $metric = Get-Prop $rec 'metric' $null
    Write-RunLog @{ mode = 'apply'; tweak = $rec.tweakId; target = $rec.target; before = $rec.current; desired = $rec.desired; result = $rec.result; error = $err; weight = [int](Get-Prop $rec 'weight' 0); onError = [string](Get-Prop $rec 'onError' 'continue'); metric = $metric }
    Write-ProgressLine ("{0} {1}: {2}" -f $rec.tweakId, $rec.target, $rec.result)
    if ($metric -and -not $AsJson) { Write-Host ("  measured: before {0} | after {1}" -f (Format-Val $metric.before -Max 200), (Format-Val $metric.after -Max 200)) }
}
Save-State $state $statePath

if ($AsJson) {
    $resItems = @(foreach ($c in $changes) { [ordered]@{ tweakId = $c.tweakId; type = $c.type; target = $c.target; before = $(if ($null -ne $c.current) { [string]$c.current } else { $null }); desired = $(if ($null -ne $c.desired) { [string]$c.desired } else { $null }); result = $c.result; error = [string](Get-Prop $c 'error' '') } })
    Write-ReapplyDoc ([ordered]@{ dryRun = $false; ids = @($Only); skipped = @($script:ReapplySkipped); snapshot = $statePath; plan = @(); results = $resItems }) $(if ($failed) { 2 } else { 0 })
}

$changes | Select-Object @{n = 'Tweak'; e = { $_.tweakId } }, @{n = 'Target'; e = { $_.target } }, @{n = 'Before'; e = { Format-Val $_.current } }, @{n = 'After'; e = { Format-Val $_.desired } }, @{n = 'Result'; e = { $_.result } } |
    Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host
foreach ($f in @($changes | Where-Object { $_.result -eq 'Failed' })) { Write-Host ("FAILED {0} {1}: {2}" -f $f.tweakId, $f.target, (Get-Prop $f 'error' '')) -ForegroundColor Red }
$notRun = @($changes | Where-Object { $_.result -in 'NotRun', 'Aborted' }).Count
if ($aborted) { Write-Host "Run aborted at $aborted (onError=abort-run); $notRun step(s) were not run. Steps that did run are in the snapshot and can be undone." -ForegroundColor Red }
elseif ($notRun) { Write-Host "$notRun step(s) were not run because an earlier step of the same tweak failed (onError=stop-tweak)." -ForegroundColor Yellow }
Write-Host "Snapshot: $statePath"
Write-Host "Undo with: .\DebloatKit.ps1 -Undo latest"
Write-Host 'Some changes (Explorer, policies, Fast Startup) take effect after sign-out or restart.'
if ($failed) { exit 2 }
exit 0

#endregion
