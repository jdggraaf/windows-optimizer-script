<#
.SYNOPSIS
    Builds a slimmed Windows install image (ISO) from an official Microsoft ISO. Offline, serviceable, never downloads anything.

.DESCRIPTION
    The offline counterpart of DebloatKit.ps1, for personal and other machines (not for an Entra / Intune managed PC, which
    should be deployed with Autopilot and policies). It applies the same safe catalog to a copy of install.wim, so a fresh
    install has no bloat from the first boot, no per-user AppX leftovers and (optionally) Compact OS. It keeps Windows Update,
    Microsoft Defender, WinRE and servicing intact, and it never touches the component store with a reset.

    Steps (every one is listed by -WhatIf before anything runs):
      1. Gates: the ISO exists, its SHA-256 matches the hash you supply (-ExpectedSha256, from the Microsoft download page)
         or you accept the risk with -SkipHashCheck, the work folder is safe and empty, enough free space, elevated prompt.
      2. Mount the ISO, copy its contents to <WorkDir>\iso, dismount it.
      3. Export the chosen index (-Index) of sources\install.wim or install.esd to <WorkDir>\install.wim (/Compress:max).
      4. Mount that WIM. Read edition, build and architecture from the offline registry (not from localized DISM text).
      5. Remove provisioned AppX packages: exact names from an appx-profiles.json profile (remove list minus keep list),
         never a protected package (Store, App Installer, frameworks, shell, Windows Security).
      6. Apply the safe catalog offline: only tweaks whose steps are all registry values, in the safe preset, whose appliesTo
         matches the image. Hives are loaded under unique names and unloaded in a finally block even when a step fails.
         HKCU values go to the Default user hive and therefore only affect profiles created after the install.
      7. DISM /StartComponentCleanup (no reset of the component store, so updates stay uninstallable).
      8. Unmount with /Commit (or /Discard when anything failed), export again with /Compress:max (or /Compress:recovery to
         install.esd with -RecoveryEsd).
      9. Optional: autounattend.xml with Compact OS (-CompactOS); optional hardware-requirement bypass (-AllowUnsupportedHardware,
         with a warning, off by default).
     10. Build the ISO with oscdimg ONLY if it is already on this PC (Windows ADK Deployment Tools, or winget
         Microsoft.OSCDIMG). It is never downloaded. Without it, the prepared tree stays in <WorkDir>\iso and the script says so.
     11. Write a manifest next to the ISO: source hash, catalog and profile versions, tweaks and AppX removed, output hash.

    Not done, on purpose: no Windows Update, Defender, recovery environment, servicing stack or WinSxS changes, no Edge or
    WebView2 removal, no BitLocker or reserved-storage changes, no hardware bypass by default, no prebuilt or downloaded ISO.
    Run it in a throwaway work folder on an NTFS drive with about 30 GB free. Test the result in a VM before using it.

    Everything that changes the system goes through one dispatcher (Invoke-RealTool). -WhatIf and -SelfTest replace it with a
    recorder, so the plan you see is the list of steps a real run would execute. Works on Windows PowerShell 5.1 and
    PowerShell 7 (DISM and reg.exe are called as programs, not through the DISM module). Kept ASCII-only on purpose.

.PARAMETER IsoPath
    Path of an official Windows 11 ISO downloaded by you from microsoft.com.

.PARAMETER ExpectedSha256
    The SHA-256 Microsoft publishes for that ISO on its download page (64 hex characters). Alias: Sha256.

.PARAMETER SkipHashCheck
    Build without verifying the ISO. Prints a warning and records "unverified" in the manifest.

.PARAMETER Index
    Image index inside install.wim (1 = first edition). Use -ListEditions to see them. Required for a real run.

.PARAMETER ListEditions
    Mount the ISO, print the editions (DISM /Get-WimInfo) and dismount again. Changes nothing else.

.PARAMETER WorkDir
    Work folder (default <system drive>\DebloatKitImage). Must be empty or missing, on a local drive, and its path may
    contain only letters, digits, dot, dash, underscore and backslash (oscdimg needs that).

.PARAMETER OutputIso
    Path of the ISO to create (default <WorkDir>\out\<ISO name>-DebloatKit.iso). An existing file is never replaced.

.PARAMETER AppxProfile
    Profile name from appx-profiles.json whose remove list (minus its keep list) is removed from the image. Default
    keep-personal. Use none to leave all provisioned apps in place.

.PARAMETER CatalogPath
    Catalog to take the safe registry tweaks from (default: tweak-catalog.json next to this script).

.PARAMETER ProfilesPath
    AppX profiles file (default: appx-profiles.json next to this script).

.PARAMETER ExcludeId
    Tweak ids to leave out.

.PARAMETER IncludeManagedSensitive
    Also apply tweaks that have a managedSkip note (telemetry pipeline, Delivery Optimization). Left out by default so
    an image that is later enrolled in Intune does not fight its policies.

.PARAMETER IncludeUnverified
    Also apply tweaks the catalog marks "new-unverified" (not yet tested on a real machine). Left out by default, like the
    online engine: an image is harder to fix than a running PC. Recorded in the manifest options.

.PARAMETER CompactOS
    Write autounattend.xml with Compact OS at setup. Off by default.

.PARAMETER SkipCleanup
    Skip DISM /StartComponentCleanup.

.PARAMETER RecoveryEsd
    Export the final image as install.esd (/Compress:recovery) instead of install.wim (/Compress:max). An ESD cannot be
    serviced again or split for FAT32.

.PARAMETER AllowUnsupportedHardware
    Also set the Setup bypass values (LabConfig and MoSetup) in install.wim and boot.wim index 2. Off by default.
    Microsoft does not guarantee updates, including security updates, on unsupported hardware.

.PARAMETER OscdimgPath
    Use this oscdimg.exe instead of searching for one.

.PARAMETER EditionHint
    Plan only (-WhatIf): the edition id assumed when selecting tweaks (default Professional). A real run reads it from the image.

.PARAMETER AsJson
    Write only JSON to stdout (the plan with -WhatIf, the manifest after a build). Progress goes to stderr.

.PARAMETER SelfTest
    No system access: tests the mapping, the selection, the AppX resolution and the whole build against a recording fake
    of DISM, reg.exe and the file system, and scans this file. Prints SELFTEST PASSED or SELFTEST FAILED; exit 0 or 1.

.EXAMPLE
    .\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11_25H2_English_x64.iso -ListEditions

.EXAMPLE
    .\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11_25H2_English_x64.iso -ExpectedSha256 <hash from microsoft.com> -Index 6 -WhatIf

.EXAMPLE
    .\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11_25H2_English_x64.iso -ExpectedSha256 <hash> -Index 6 -AppxProfile keep-personal -CompactOS
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$IsoPath,
    [Alias('Sha256')][string]$ExpectedSha256,
    [switch]$SkipHashCheck,
    [int]$Index = 0,
    [switch]$ListEditions,
    [string]$WorkDir,
    [string]$OutputIso,
    [string]$AppxProfile = 'keep-personal',
    [string]$CatalogPath,
    [string]$ProfilesPath,
    [string[]]$ExcludeId = @(),
    [switch]$IncludeManagedSensitive,
    [switch]$IncludeUnverified,
    [switch]$CompactOS,
    [switch]$SkipCleanup,
    [switch]$RecoveryEsd,
    [switch]$AllowUnsupportedHardware,
    [string]$OscdimgPath,
    [string]$EditionHint = 'Professional',
    [switch]$AsJson,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -WhatIf is handled here (the plan is a recording of the real steps). Leaving it active would leak into the
# cmdlets this script calls and print a "What if:" line for each of them.
$script:DryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

$scriptDir = Split-Path -Parent $PSCommandPath
$script:ToolVersion = '1'
$script:MinFreeGB = 30
$script:Mode = 'Real'          # Real | Plan | Mock
$script:Exec = $null           # scriptblock: param($Tool, $P) -> { ExitCode; Output }
$script:Steps = $null
$script:Warnings = $null
$script:Quiet = $false
$script:StepNo = 0

# Windows packages the image builder never removes, whatever a profile says. Mirrors $ProtectedTargets.Appx in
# DebloatKit.ps1 (tests\Test-Engine.ps1 compares the two lists). Wildcards allowed.
$script:ProtectedAppx = [ordered]@{
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

# Protected registry targets, mirroring $ProtectedTargets.Services / DefenderValues / RegistryRules in DebloatKit.ps1
# (tests\Test-Engine.ps1 compares the lists). A tweak value that hits one is left out of the image with a reason.
# BEGIN-PROTECTED-LISTS
$script:ProtectedServices = [ordered]@{
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
$script:ProtectedRegistryRules = @(
    @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate(\\AU)?$'; Names = @('NoAutoUpdate', 'UseWUServer', 'WUServer', 'WUStatusServer', 'DisableWindowsUpdateAccess', 'DoNotConnectToWindowsUpdateInternetLocations'); Reason = 'Windows Update policy (switches updates off or redirects the update source)' }
    @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsFirewall(\\|$)'; Names = @(); Reason = 'Windows Defender Firewall policy' }
    @{ Path = '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Services\\SharedAccess\\Parameters\\FirewallPolicy(\\|$)'; Names = @('EnableFirewall'); Reason = 'Windows Defender Firewall profile state' }
    @{ Path = '^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System$'; Names = @('EnableLUA', 'ConsentPromptBehaviorAdmin', 'ConsentPromptBehaviorUser', 'PromptOnSecureDesktop', 'FilterAdministratorToken'); Reason = 'User Account Control' }
    @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System$'; Names = @('EnableSmartScreen', 'ShellSmartScreenLevel'); Reason = 'SmartScreen policy' }
    @{ Path = '^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer$'; Names = @('SmartScreenEnabled'); Reason = 'SmartScreen setting' }
    @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge$'; Names = @('SmartScreenEnabled', 'SmartScreenPuaEnabled'); Reason = 'Edge SmartScreen policy' }
    @{ Path = '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE(\\|$)'; Names = @(); Reason = 'BitLocker drive encryption policy' }
)
$script:ProtectedDefenderValues = @('DisableAntiSpyware', 'DisableAntiVirus', 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable', 'TamperProtection')

function Get-ProtectedRegistryReason {
    param([string]$Path, [string]$Name)
    $p = $Path.TrimEnd('\')
    if ($p -match '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Services\\([^\\]+)') {
        $svc = $Matches[2]
        foreach ($k in $script:ProtectedServices.Keys) { if ($svc -ieq $k) { return $script:ProtectedServices[$k] } }
    }
    if ($p -match '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Control\\(DeviceGuard|CI)(\\|$)') { return 'virtualization-based security, HVCI and Smart App Control settings' }
    if ($p -match '^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet001)\\Control\\Lsa$' -and $Name -in 'LsaCfgFlags', 'RunAsPPL', 'RunAsPPLBoot') { return 'Credential Guard / LSA protection' }
    if ($p -match '^HKLM:\\SOFTWARE\\(Policies\\)?Microsoft\\Windows Defender(\\|$)' -and $script:ProtectedDefenderValues -contains $Name) { return 'a setting that switches Microsoft Defender protection off' }
    foreach ($rule in $script:ProtectedRegistryRules) {
        if ($p -match $rule.Path -and (@($rule.Names).Count -eq 0 -or @($rule.Names) -contains $Name)) { return $rule.Reason }
    }
    return $null
}
# END-PROTECTED-LISTS

# Offline hive files, relative to the mounted image. The Default user's class hive is separate from NTUSER.DAT.
$script:HiveFiles = [ordered]@{
    SOFTWARE = 'Windows\System32\config\SOFTWARE'
    SYSTEM   = 'Windows\System32\config\SYSTEM'
    NTUSER   = 'Users\Default\NTUSER.DAT'
    CLASSES  = 'Users\Default\AppData\Local\Microsoft\Windows\UsrClass.dat'
}

# ---------------------------------------------------------------- pure helpers (no system access)

function Write-Diag {
    # Diagnostics go to stderr so -AsJson keeps stdout clean.
    param([string]$Message)
    [Console]::Error.WriteLine('WARNING: ' + $Message)
}

function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $Default }
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
    return $Default
}

function Add-Warning {
    param([string]$Text)
    if ($null -ne $script:Warnings) { $script:Warnings.Add($Text) }
    if (-not $script:Quiet) { Write-Diag $Text }
}

function Test-EditionMatch {
    param([string]$Edition, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Edition -like $p) { return $true } }
    return $false
}

function Get-ProtectedAppxReason {
    param([string]$Name)
    foreach ($k in $script:ProtectedAppx.Keys) { if ($Name -like $k) { return $script:ProtectedAppx[$k] } }
    return $null
}

function Format-Arg {
    param([string]$Text)
    if ($Text -match '[\s"]') { return '"' + $Text.Replace('"', '\"') + '"' }
    return $Text
}

function Format-Command {
    param([string]$Exe, [string[]]$ToolArgs)
    (@($Exe) + @($ToolArgs | ForEach-Object { Format-Arg $_ })) -join ' '
}

# HKLM:\ / HKCU:\ path of a catalog step -> { Hive; SubPath } in the offline image, or { Reason } when it cannot be mapped.
# ControlSet is the control set the loaded SYSTEM hive points to (Select\Current).
function Resolve-OfflineKey {
    param([string]$Path, [string]$ControlSet = 'ControlSet001')
    $p = $Path.TrimEnd('\')
    if ($p -match '^(?i)HKLM:\\SOFTWARE(?:\\(.*))?$') { return [pscustomobject]@{ Hive = 'SOFTWARE'; SubPath = [string]$Matches[1]; Reason = $null } }
    if ($p -match '^(?i)HKLM:\\SYSTEM\\CurrentControlSet(?:\\(.*))?$') {
        $sub = $ControlSet
        if ($Matches[1]) { $sub = $ControlSet + '\' + $Matches[1] }
        return [pscustomobject]@{ Hive = 'SYSTEM'; SubPath = $sub; Reason = $null }
    }
    if ($p -match '^(?i)HKLM:\\SYSTEM(?:\\(.*))?$') { return [pscustomobject]@{ Hive = 'SYSTEM'; SubPath = [string]$Matches[1]; Reason = $null } }
    if ($p -match '^(?i)HKCU:\\Software\\Classes(?:\\(.*))?$') { return [pscustomobject]@{ Hive = 'CLASSES'; SubPath = [string]$Matches[1]; Reason = $null } }
    if ($p -match '^(?i)HKCU:\\(.*)$') { return [pscustomobject]@{ Hive = 'NTUSER'; SubPath = [string]$Matches[1]; Reason = $null } }
    return [pscustomobject]@{ Hive = $null; SubPath = $null; Reason = "registry root of '$Path' cannot be written offline" }
}

function ConvertTo-RegType {
    param([string]$ValueType)
    switch -Regex ($ValueType) {
        '^(?i)DWord$' { return 'REG_DWORD' }
        '^(?i)QWord$' { return 'REG_QWORD' }
        '^(?i)String$' { return 'REG_SZ' }
        '^(?i)ExpandString$' { return 'REG_EXPAND_SZ' }
        '^(?i)MultiString$' { return 'REG_MULTI_SZ' }
        default { return $null }
    }
}

# 'reg add' text for one value (the plan shows exactly what the registry tool writes).
function Format-RegAdd {
    param([string]$KeyPath, [string]$Name, [string]$RegType, [string]$Value)
    $nameArg = if ($Name -eq '(Default)') { '/ve' } else { '/v ' + (Format-Arg $Name) }
    $data = if ($Value -eq '') { '""' } else { Format-Arg $Value }
    'reg add {0} {1} /t {2} /d {3} /f' -f (Format-Arg $KeyPath), $nameArg, $RegType, $data
}

# Package names (Name_Version_Arch_ResourceId_PublisherId) found in DISM /Get-ProvisionedAppxPackages output. Read by shape,
# not by label, because the labels are localized.
function ConvertFrom-ProvisionedList {
    param([string]$Text)
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($Text, '(?m)([A-Za-z0-9][A-Za-z0-9.\-]*)_(\d+(?:\.\d+)+)_([A-Za-z0-9]+)_([A-Za-z0-9.~\-]*)_([a-z0-9]{13})')) {
        $full = $m.Value
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        $out.Add([pscustomobject]@{ Name = $m.Groups[1].Value; PackageName = $full })
    }
    , @($out.ToArray())
}

# Names to remove: profile "remove" minus profile "keep", exact names only, never a protected package.
function Get-AppxRemovalSet {
    param($Profiles, [string]$ProfileName)
    $r = [pscustomobject]@{ Profile = $ProfileName; Names = @(); Kept = @(); Protected = @(); Ignored = @(); Problem = $null }
    if (-not $ProfileName -or $ProfileName -ieq 'none') { return $r }
    $all = Get-Prop $Profiles 'profiles' $null
    $prof = Get-Prop $all $ProfileName $null
    if (-not $prof) { $r.Problem = "AppX profile '$ProfileName' is not defined in the profiles file"; return $r }
    $keep = @(Get-Prop $prof 'keep' @())
    $names = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    $prot = New-Object System.Collections.Generic.List[string]
    $ign = New-Object System.Collections.Generic.List[string]
    foreach ($n in @(Get-Prop $prof 'remove' @())) {
        $n = [string]$n
        if ($n -match '[*?\[\]]') { if (-not $ign.Contains($n)) { $ign.Add($n) }; continue }
        if (@($keep | Where-Object { $_ -ieq $n }).Count) { if (-not $kept.Contains($n)) { $kept.Add($n) }; continue }
        if (Get-ProtectedAppxReason $n) { if (-not $prot.Contains($n)) { $prot.Add($n) }; continue }
        if (@($names | Where-Object { $_ -ieq $n }).Count -eq 0) { $names.Add($n) }
    }
    $r.Names = @($names.ToArray()); $r.Kept = @($kept.ToArray()); $r.Protected = @($prot.ToArray()); $r.Ignored = @($ign.ToArray())
    $r
}

# Safe-catalog tweaks that can be written into an offline image. Pure: takes the parsed catalog.
function Select-OfflineTweaks {
    param($Catalog, [string]$Edition, [int]$Build, [string[]]$ExcludeIds = @(), [bool]$IncludeManaged = $false, [string]$ControlSet = 'ControlSet001', [bool]$IncludeUnverified = $false)
    $selected = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $notSafe = 0
    foreach ($t in @(Get-Prop $Catalog 'tweaks' @())) {
        $id = [string]$t.id
        if ((Get-Prop $t 'preset' '') -ne 'safe') { $notSafe++; continue }
        $skip = { param($why) $skipped.Add([pscustomobject]@{ id = $id; reason = $why }) }
        if ($ExcludeIds -contains $id) { & $skip 'excluded with -ExcludeId'; continue }
        $risk = [string](Get-Prop $t 'risk' '')
        if ($risk -ne 'safe') { & $skip "risk is '$risk', only 'safe' tweaks go into an image"; continue }
        if (-not $IncludeUnverified -and (Get-Prop $t 'verification' '') -eq 'new-unverified') { & $skip 'unverified new tweak; use -IncludeUnverified'; continue }
        if (Get-Prop $t 'managedSkip' $null) { if (-not $IncludeManaged) { & $skip 'has a managedSkip note (managed-device conflict); use -IncludeManagedSensitive to apply it'; continue } }
        $ap = Get-Prop $t 'appliesTo' $null
        if ($ap) {
            $ed = @(Get-Prop $ap 'editions' @()); $notEd = @(Get-Prop $ap 'notEditions' @())
            $min = [int](Get-Prop $ap 'minBuild' 0); $max = [int](Get-Prop $ap 'maxBuild' 0)
            if ((Get-Prop $ap 'requiresLaptop' $false) -or (Get-Prop $ap 'requiresDesktop' $false)) { & $skip 'depends on the hardware it is installed on (laptop or desktop)'; continue }
            $bad = $false
            if ($ed.Count -gt 0 -and -not (Test-EditionMatch $Edition $ed)) { $bad = $true }
            if ($notEd.Count -gt 0 -and (Test-EditionMatch $Edition $notEd)) { $bad = $true }
            if ($min -gt 0 -and $Build -lt $min) { $bad = $true }
            if ($max -gt 0 -and $Build -gt $max) { $bad = $true }
            if ($bad) { & $skip ("not applicable to this image (edition '{0}', build {1}): {2}" -f $Edition, $Build, (Get-Prop $ap 'reason' '')); continue }
        }
        $impl = $t.implementation
        $steps = if ((Get-Prop $impl 'type' '') -eq 'multi') { @($impl.steps) } else { @($impl) }
        $nonReg = @($steps | Where-Object { $_.type -ne 'registry' })
        if ($nonReg.Count) { & $skip ('has {0} step(s) that are not registry values ({1}); they only work online' -f $nonReg.Count, ((@($nonReg | ForEach-Object { $_.type }) | Select-Object -Unique) -join ', ')); continue }
        $vals = New-Object System.Collections.Generic.List[object]
        $why = $null
        foreach ($s in $steps) {
            $rt = ConvertTo-RegType ([string](Get-Prop $s 'valueType' ''))
            if (-not $rt) { $why = "value type '{0}' is not written offline" -f (Get-Prop $s 'valueType' ''); break }
            $pr = Get-ProtectedRegistryReason ([string]$s.path) ([string]$s.name)
            if ($pr) { $why = "protected target: $pr (never written to an image)"; break }
            $m = Resolve-OfflineKey ([string]$s.path) $ControlSet
            if ($m.Reason) { $why = $m.Reason; break }
            if ($null -eq (Get-Prop $s 'value' $null)) { $why = "step '{0}' has no value" -f $s.name; break }
            $vals.Add([pscustomobject]@{ tweak = $id; hive = $m.Hive; subPath = $m.SubPath; name = [string]$s.name; regType = $rt; value = [string]$s.value; path = [string]$s.path })
        }
        if ($why) { & $skip $why; continue }
        $selected.Add([pscustomobject]@{ id = $id; values = @($vals.ToArray()) })
    }
    [pscustomobject]@{ Selected = @($selected.ToArray()); Skipped = @($skipped.ToArray()); NotInSafePreset = $notSafe }
}

function New-AutounattendXml {
    param([string]$Architecture)
    $arch = if ($Architecture -match '^(?i)arm64$') { 'arm64' } elseif ($Architecture -match '^(?i)(x86|i386)$') { 'x86' } else { 'amd64' }
    @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<unattend xmlns="urn:schemas-microsoft-com:unattend">',
        '  <settings pass="windowsPE">',
        ('    <component name="Microsoft-Windows-Setup" processorArchitecture="{0}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">' -f $arch),
        '      <ImageInstall>',
        '        <OSImage>',
        '          <Compact>true</Compact>',
        '        </OSImage>',
        '      </ImageInstall>',
        '    </component>',
        '  </settings>',
        '</unattend>',
        ''
    ) -join "`r`n"
}

# Pure checks of the arguments. Returns a list of blocker texts (empty = ready). $Probe has the live facts a real run reads.
function Get-Blockers {
    param($Cfg, [bool]$Real, $Probe)
    $b = New-Object System.Collections.Generic.List[string]
    if (-not $Cfg.IsoPath) { $b.Add('-IsoPath is required.') }
    elseif ($Cfg.IsoPath -notmatch '\.iso$') { $b.Add('-IsoPath must be a .iso file.') }
    elseif ($Real -and $Probe -and -not $Probe.IsoExists) { $b.Add("ISO not found: $($Cfg.IsoPath)") }
    if (-not $Cfg.ListEditions) {
        if ($Cfg.ExpectedSha256) {
            if ($Cfg.ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') { $b.Add('-ExpectedSha256 must be 64 hex characters.') }
        }
        elseif (-not $Cfg.SkipHashCheck) { $b.Add('No ISO hash given: pass -ExpectedSha256 <hash from the Microsoft download page>, or -SkipHashCheck to build an unverified image at your own risk.') }
        if ($Cfg.Index -lt 1) { $b.Add('-Index is required (use -ListEditions to see the indexes).') }
        $w = [string]$Cfg.WorkDir
        if (-not $w) { $b.Add('-WorkDir is empty.') }
        else {
            if ($w -notmatch '^[A-Za-z]:\\[A-Za-z0-9._\\-]*$') { $b.Add('-WorkDir must be a local absolute path of letters, digits, dot, dash, underscore and backslash only.') }
            elseif ($w -match '(\\|^)\.\.(\\|$)') { $b.Add('-WorkDir must not contain "..".') }
            if ($w -match '^(?i)[A-Za-z]:\\?$') { $b.Add('-WorkDir must be a folder, not a drive root.') }
            $win = [string]$env:SystemRoot
            if ($win -and $w.StartsWith($win, [System.StringComparison]::OrdinalIgnoreCase)) { $b.Add('-WorkDir must not be inside the Windows folder.') }
            if ($w -match '(?i)\\ProgramData\\DebloatKit(\\|$)') { $b.Add("-WorkDir must not be inside the engine's state folder.") }
            if ($Real -and $Probe -and $Probe.WorkDirNotEmpty) { $b.Add("-WorkDir is not empty: $w (use a new or empty folder; the script never deletes files it did not create).") }
        }
        $o = [string]$Cfg.OutputIso
        if ($o -and $o -notmatch '\.iso$') { $b.Add('-OutputIso must end in .iso.') }
        if ($Real -and $o -and $Probe -and $Probe.OutputExists) { $b.Add("Output ISO already exists and is never replaced: $o") }
    }
    if ($Real -and $Probe -and -not $Probe.IsAdmin) { $b.Add('Run this from an elevated prompt (DISM, mounting and loading hives need administrator rights).') }
    , @($b.ToArray())
}

# ---------------------------------------------------------------- dispatcher: the only place that changes or reads the real system

# BEGIN-REAL-TOOLS
function Invoke-Native {
    param([string]$Exe, [string[]]$ToolArgs)
    $ErrorActionPreference = 'Continue'     # Windows PowerShell 5.1 turns native stderr into a terminating error under 'Stop'
    $o = & $Exe @ToolArgs 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $o }
}

function Get-OscdimgCandidate {
    $c = New-Object System.Collections.Generic.List[string]
    $pf = ${env:ProgramFiles(x86)}
    if ($pf) { foreach ($a in 'amd64', 'arm64', 'x86') { $c.Add((Join-Path $pf "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$a\Oscdimg\oscdimg.exe")) } }
    if ($env:LOCALAPPDATA) {
        $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $pk) { foreach ($d in @(Get-ChildItem -LiteralPath $pk -Directory -Filter 'Microsoft.OSCDIMG*' -ErrorAction SilentlyContinue)) { $c.Add((Join-Path $d.FullName 'oscdimg.exe')) } }
        $c.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\oscdimg.exe'))
    }
    $c.ToArray()
}

function Invoke-RealTool {
    param([string]$Tool, [hashtable]$P)
    $ok = { param($code, $text) [pscustomobject]@{ ExitCode = $code; Output = $text } }
    switch ($Tool) {
        'dism' { return (Invoke-Native 'dism.exe' $P.Args) }
        'reg' { return (Invoke-Native 'reg.exe' $P.Args) }
        'robocopy' { return (Invoke-Native 'robocopy.exe' $P.Args) }
        'attrib' { return (Invoke-Native 'attrib.exe' $P.Args) }
        'oscdimg' { return (Invoke-Native $P.Exe $P.Args) }
        'isadmin' {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $adm = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            return (& $ok $(if ($adm) { 0 } else { 1 }) '')
        }
        'isoprobe' {
            $f = Get-Item -LiteralPath $P.Path -ErrorAction SilentlyContinue
            $outExists = $false
            if ($P.Output) { $outExists = Test-Path -LiteralPath $P.Output }
            $nonEmpty = $false
            if ($P.WorkDir -and (Test-Path -LiteralPath $P.WorkDir)) { $nonEmpty = [bool]@(Get-ChildItem -LiteralPath $P.WorkDir -Force -ErrorAction SilentlyContinue).Count }
            $info = @{ IsoExists = [bool]$f; Size = $(if ($f) { [long]$f.Length } else { 0 }); OutputExists = $outExists; WorkDirNotEmpty = $nonEmpty }
            return (& $ok 0 (ConvertTo-Json -InputObject $info -Compress))
        }
        'findoscdimg' {
            if ($P.Override) { if (Test-Path -LiteralPath $P.Override) { return (& $ok 0 ([string]$P.Override)) } else { return (& $ok 1 '') } }
            $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) { return (& $ok 0 ([string]$cmd.Source)) }
            foreach ($c in (Get-OscdimgCandidate)) { if (Test-Path -LiteralPath $c) { return (& $ok 0 $c) } }
            return (& $ok 1 '')
        }
        'freespace' {
            $root = [System.IO.Path]::GetPathRoot($P.Path)
            $di = New-Object System.IO.DriveInfo($root)
            return (& $ok 0 ([string]$di.AvailableFreeSpace))
        }
        'filehash' { return (& $ok 0 ((Get-FileHash -Algorithm SHA256 -LiteralPath $P.Path).Hash)) }
        'mountiso' {
            $img = Mount-DiskImage -ImagePath $P.Path -StorageType ISO -PassThru -ErrorAction Stop
            $vol = $img | Get-Volume
            return (& $ok 0 ([string]$vol.DriveLetter + ':'))
        }
        'dismountiso' { $null = Dismount-DiskImage -ImagePath $P.Path -ErrorAction Stop; return (& $ok 0 '') }
        'exists' { return (& $ok $(if (Test-Path -LiteralPath $P.Path) { 0 } else { 1 }) '') }
        'mkdir' { $null = New-Item -ItemType Directory -Force -Path $P.Path; return (& $ok 0 '') }
        'delete' { Remove-Item -LiteralPath $P.Path -Force -ErrorAction Stop; return (& $ok 0 '') }
        'wait' { Start-Sleep -Seconds $P.Seconds; return (& $ok 0 '') }
        'writefile' {
            $dir = [System.IO.Path]::GetDirectoryName($P.Path)
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
            [System.IO.File]::WriteAllText($P.Path, $P.Content, (New-Object System.Text.UTF8Encoding($false)))
            return (& $ok 0 '')
        }
        'regread' {
            $v = [Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\' + $P.Key, $P.Name, $null)
            if ($null -eq $v) { return (& $ok 1 '') }
            return (& $ok 0 ([string]$v))
        }
        'regset' {
            $name = if ($P.Name -eq '(Default)') { '' } else { $P.Name }
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            $val = $P.Value
            if ($P.RegType -eq 'REG_DWORD') { $kind = [Microsoft.Win32.RegistryValueKind]::DWord; $val = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$P.Value), 0) }
            elseif ($P.RegType -eq 'REG_QWORD') { $kind = [Microsoft.Win32.RegistryValueKind]::QWord; $val = [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$P.Value), 0) }
            elseif ($P.RegType -eq 'REG_EXPAND_SZ') { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
            elseif ($P.RegType -eq 'REG_MULTI_SZ') { $kind = [Microsoft.Win32.RegistryValueKind]::MultiString; $val = [string[]]@([string]$P.Value -split '\0') }
            [Microsoft.Win32.Registry]::SetValue('HKEY_LOCAL_MACHINE\' + $P.Key, $name, $val, $kind)
            return (& $ok 0 '')
        }
        default { throw "Unknown tool '$Tool'" }
    }
}
# END-REAL-TOOLS

# Plan recorder (-WhatIf): nothing runs; read-only probes of this PC are allowed, everything else returns a canned answer.
function Invoke-PlanTool {
    param([string]$Tool, [hashtable]$P)
    $ok = { param($code, $text) [pscustomobject]@{ ExitCode = $code; Output = $text } }
    switch ($Tool) {
        'findoscdimg' { return (Invoke-RealTool $Tool $P) }
        'isoprobe' { return (Invoke-RealTool $Tool $P) }
        'isadmin' { return (Invoke-RealTool $Tool $P) }
        'exists' { return (& $ok $(if ($P.Path -like '*install.esd') { 1 } else { 0 }) '') }
        'mountiso' { return (& $ok 0 'Z:') }
        'filehash' { return (& $ok 0 $script:PlanHash) }
        'freespace' { return (& $ok 0 '9999999999999') }
        'regread' {
            switch -Regex ($P.Name) {
                '^EditionID$' { return (& $ok 0 $script:PlanEdition) }
                '^CurrentBuildNumber$' { return (& $ok 0 '26100') }
                '^PROCESSOR_ARCHITECTURE$' { return (& $ok 0 'AMD64') }
                '^Current$' { return (& $ok 0 '1') }
                default { return (& $ok 1 '') }
            }
        }
        default { return (& $ok 0 '') }
    }
}

# ---------------------------------------------------------------- build pipeline

function Invoke-Step {
    # Records the step (this list is the plan under -WhatIf and the log of a real run) and runs it through the dispatcher.
    param(
        [string]$Phase, [string]$Text, [string]$Tool, [hashtable]$P = @{}, [string]$Display = '',
        [bool]$Mutates = $true, [int[]]$OkCodes = @(0), [switch]$NonFatal, [string]$Tweak = ''
    )
    $script:StepNo++
    if (-not $Display) { $Display = $Tool }
    $script:Steps.Add([pscustomobject]@{ n = $script:StepNo; phase = $Phase; description = $Text; command = $Display; mutates = $Mutates; tweak = $Tweak })
    if (-not $script:Quiet -and $script:Mode -eq 'Real' -and $Phase -ne 'registry') { Write-Host ('[{0}] {1}' -f $Phase, $Text) }
    $r = & $script:Exec $Tool $P
    if ($OkCodes -notcontains [int]$r.ExitCode) {
        $tail = (([string]$r.Output) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | '
        $msg = "step $($script:StepNo) ($Phase) failed with exit code $($r.ExitCode): $Text. $tail"
        if ($NonFatal) { Add-Warning $msg; return $r }
        throw $msg
    }
    $r
}

function Invoke-Dism {
    param([string]$Phase, [string]$Text, [string[]]$ToolArgs, [switch]$NonFatal, [bool]$Mutates = $true)
    Invoke-Step -Phase $Phase -Text $Text -Tool 'dism' -P @{ Args = $ToolArgs } -Display (Format-Command 'dism.exe' $ToolArgs) -NonFatal:$NonFatal -Mutates $Mutates
}

function Add-RegValue {
    param($State, $V)
    $key = $State.HiveNames[$V.hive] + $(if ($V.subPath) { '\' + $V.subPath } else { '' })
    $disp = Format-RegAdd ('HKLM\' + $key) $V.name $V.regType $V.value
    $null = Invoke-Step -Phase 'registry' -Text "$($V.name) in $($V.path)" -Tool 'regset' -P @{ Key = $key; Name = $V.name; RegType = $V.regType; Value = $V.value } -Display $disp -Tweak $V.tweak
}

function Mount-OfflineHive {
    param($State, [string]$Hive, [string]$MountDir)
    $name = $State.HiveNames[$Hive]
    $file = Join-Path $MountDir $script:HiveFiles[$Hive]
    $null = Invoke-Step -Phase 'hive' -Text "load the $Hive hive" -Tool 'reg' -P @{ Args = @('load', "HKLM\$name", $file) } -Display (Format-Command 'reg.exe' @('load', "HKLM\$name", $file))
    $State.Loaded.Add($Hive)
}

function Dismount-OfflineHives {
    # Called on success and in finally. Handles are released first; a hive that will not unload is reported with the manual fix.
    param($State)
    $left = @($State.Loaded.ToArray())
    [array]::Reverse($left)
    foreach ($h in $left) {
        $name = $State.HiveNames[$h]
        $done = $false
        for ($i = 1; $i -le 5 -and -not $done; $i++) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            try {
                $r = Invoke-Step -Phase 'hive' -Text "unload the $h hive" -Tool 'reg' -P @{ Args = @('unload', "HKLM\$name") } -Display (Format-Command 'reg.exe' @('unload', "HKLM\$name")) -NonFatal
                if ([int]$r.ExitCode -eq 0) { $done = $true }
            } catch { }
            if (-not $done -and $i -lt 5) { $null = & $script:Exec 'wait' @{ Seconds = 1 } }
        }
        if ($done) { $null = $State.Loaded.Remove($h) }
        else { Add-Warning "Hive HKLM\$name could not be unloaded. Close programs that read the registry, run: reg unload HKLM\$name  and then: dism /Unmount-Image /MountDir:<mount dir> /Discard" }
    }
}

function Build-Image {
    param($Cfg)
    $real = ($script:Mode -eq 'Real')
    $workDir = [string]$Cfg.WorkDir
    $isoTree = Join-Path $workDir 'iso'
    $mnt = Join-Path $workDir 'mnt'
    $bmnt = Join-Path $workDir 'bootmnt'
    $wimWork = Join-Path $workDir 'install.wim'
    $outDir = Join-Path $workDir 'out'
    $outIso = [string]$Cfg.OutputIso
    if (-not $outIso) { $outIso = Join-Path $outDir (([System.IO.Path]::GetFileNameWithoutExtension([string]$Cfg.IsoPath)) + '-DebloatKit.iso') }
    $manifestPath = $outIso + '.manifest.json'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $state = [pscustomobject]@{
        HiveNames = @{}; Loaded = (New-Object System.Collections.Generic.List[string])
        IsoMounted = $false; MainMounted = $false; BootMounted = $false
    }
    foreach ($h in $script:HiveFiles.Keys) { $state.HiveNames[$h] = "DK_${h}_$suffix" }

    $catalog = Get-Content -LiteralPath $Cfg.CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profiles = $null
    if ($Cfg.AppxProfile -and $Cfg.AppxProfile -ine 'none') {
        if (-not $Cfg.ProfilesPath -or -not (Test-Path -LiteralPath $Cfg.ProfilesPath)) { throw "AppX profiles file not found: $($Cfg.ProfilesPath)" }
        $profiles = Get-Content -LiteralPath $Cfg.ProfilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $appx = Get-AppxRemovalSet $profiles ([string]$Cfg.AppxProfile)
    if ($appx.Problem) { throw $appx.Problem }

    $m = [ordered]@{
        tool = 'DebloatKit-Image'; toolVersion = $script:ToolVersion; mode = $script:Mode.ToLower()
        startedUtc = [DateTime]::UtcNow.ToString('o')
        source = [ordered]@{ isoPath = [string]$Cfg.IsoPath; sha256Expected = [string]$Cfg.ExpectedSha256; sha256Actual = $null; verification = 'pending' }
        image = [ordered]@{ index = [int]$Cfg.Index; edition = $null; build = $null; architecture = $null; controlSet = $null }
        catalogVersion = [string](Get-Prop $catalog 'catalogVersion' ''); profilesVersion = [string](Get-Prop $profiles 'profilesVersion' '')
        options = [ordered]@{ appxProfile = [string]$Cfg.AppxProfile; compactOS = [bool]$Cfg.CompactOS; cleanup = (-not $Cfg.SkipCleanup); finalFormat = $(if ($Cfg.RecoveryEsd) { 'esd (recovery)' } else { 'wim (max)' }); unsupportedHardwareBypass = [bool]$Cfg.AllowUnsupportedHardware; includeManagedSensitive = [bool]$Cfg.IncludeManagedSensitive; includeUnverified = [bool]$Cfg.IncludeUnverified }
        tweaks = $null; appx = $null
        outputs = [ordered]@{ workDir = $workDir; installWim = $null; isoTree = $isoTree; iso = $null; isoSha256 = $null; isoBuilt = $false; oscdimg = $null; manifest = $manifestPath }
        warnings = @()
    }

    # ---- gates and probes
    $probeRaw = & $script:Exec 'isoprobe' @{ Path = [string]$Cfg.IsoPath; Output = $outIso; WorkDir = $workDir }
    $probe = $null
    try { $probe = ([string]$probeRaw.Output | ConvertFrom-Json) } catch { $probe = $null }
    if ($probe) {
        $adm = & $script:Exec 'isadmin' @{}
        $probe | Add-Member -NotePropertyName IsAdmin -NotePropertyValue ([int]$adm.ExitCode -eq 0) -Force
    }
    $blockers = Get-Blockers $Cfg $true $probe
    $m.blockers = @($blockers)
    if ($script:Mode -ne 'Plan' -and $blockers.Count) { throw ('Cannot start:' + [Environment]::NewLine + (($blockers | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine)) }
    if ($Cfg.SkipHashCheck -and -not $Cfg.ExpectedSha256) { Add-Warning 'ISO hash check skipped: the image is built from an UNVERIFIED source.' }
    if ($Cfg.AllowUnsupportedHardware) { Add-Warning 'Hardware-requirement bypass enabled: Microsoft does not guarantee updates, including security updates, on unsupported hardware.' }
    if ($Cfg.RecoveryEsd) { Add-Warning 'install.esd cannot be serviced again (no DISM edits) and cannot be split for FAT32 media.' }

    $fs = Invoke-Step -Phase 'gate' -Text "check free space on the work drive (need $($script:MinFreeGB) GB)" -Tool 'freespace' -P @{ Path = $workDir } -Display "(free space of $([System.IO.Path]::GetPathRoot($workDir)) >= $($script:MinFreeGB) GB)" -Mutates $false
    if ($real -and [long]$fs.Output -lt ([long]$script:MinFreeGB * 1GB)) { throw "Less than $($script:MinFreeGB) GB free on the work drive." }

    try {
        # ---- hash
        if ($Cfg.ExpectedSha256) {
            $h = Invoke-Step -Phase 'verify' -Text 'compute the ISO SHA-256 and compare it with -ExpectedSha256' -Tool 'filehash' -P @{ Path = [string]$Cfg.IsoPath } -Display "Get-FileHash -Algorithm SHA256 -LiteralPath $(Format-Arg ([string]$Cfg.IsoPath))" -Mutates $false
            $m.source.sha256Actual = ([string]$h.Output).Trim().ToUpperInvariant()
            if ($real -or $script:Mode -eq 'Mock') {
                if ($m.source.sha256Actual -ne $Cfg.ExpectedSha256.ToUpperInvariant()) { throw "ISO SHA-256 mismatch: expected $($Cfg.ExpectedSha256.ToUpperInvariant()), got $($m.source.sha256Actual). Refusing to build (use -SkipHashCheck only if you know why)." }
                $m.source.verification = 'verified'
            }
            else { $m.source.sha256Actual = $null; $m.source.verification = 'would be verified' }
        }
        else { $m.source.verification = 'unverified (-SkipHashCheck)' }

        # ---- mount the ISO, copy, dismount
        $mi = Invoke-Step -Phase 'iso' -Text 'mount the ISO (read-only)' -Tool 'mountiso' -P @{ Path = [string]$Cfg.IsoPath } -Display "Mount-DiskImage -ImagePath $(Format-Arg ([string]$Cfg.IsoPath)) -StorageType ISO -PassThru"
        $state.IsoMounted = $true
        $drive = ([string]$mi.Output).Trim()
        if ($drive -notmatch '^[A-Za-z]:$') { throw "Could not read the drive letter of the mounted ISO ('$drive')." }
        if ($Cfg.ListEditions) {
            $wimSrc = "$drive\sources\install.wim"
            $e = & $script:Exec 'exists' @{ Path = $wimSrc }
            if ([int]$e.ExitCode -ne 0) { $wimSrc = "$drive\sources\install.esd" }
            $li = Invoke-Dism -Phase 'iso' -Text 'list the editions in the image' -ToolArgs @('/Get-WimInfo', "/WimFile:$wimSrc") -Mutates $false
            $m.editionsText = [string]$li.Output
            return $m
        }
        foreach ($d in $workDir, $isoTree, $mnt, $outDir) { $null = Invoke-Step -Phase 'prepare' -Text "create $d" -Tool 'mkdir' -P @{ Path = $d } -Display "New-Item -ItemType Directory -Force $(Format-Arg $d)" }
        $null = Invoke-Step -Phase 'iso' -Text 'copy the ISO contents to the work folder' -Tool 'robocopy' -P @{ Args = @("$drive\", $isoTree, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') } -Display (Format-Command 'robocopy.exe' @("$drive\", $isoTree, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')) -OkCodes @(0, 1, 2, 3, 4, 5, 6, 7)
        $null = Invoke-Step -Phase 'iso' -Text 'dismount the ISO' -Tool 'dismountiso' -P @{ Path = [string]$Cfg.IsoPath } -Display "Dismount-DiskImage -ImagePath $(Format-Arg ([string]$Cfg.IsoPath))"
        $state.IsoMounted = $false
        $null = Invoke-Step -Phase 'iso' -Text 'clear the read-only attribute on the copied files' -Tool 'attrib' -P @{ Args = @('-r', "$isoTree\*", '/S', '/D') } -Display (Format-Command 'attrib.exe' @('-r', "$isoTree\*", '/S', '/D'))

        $srcWim = Join-Path $isoTree 'sources\install.wim'
        $srcEsd = Join-Path $isoTree 'sources\install.esd'
        $hasWim = [int](& $script:Exec 'exists' @{ Path = $srcWim }).ExitCode -eq 0
        $hasEsd = [int](& $script:Exec 'exists' @{ Path = $srcEsd }).ExitCode -eq 0
        if (-not $hasWim -and -not $hasEsd) { throw 'The ISO has no sources\install.wim or sources\install.esd.' }
        $srcImage = if ($hasWim) { $srcWim } else { $srcEsd }

        # ---- export the chosen index, mount
        $null = Invoke-Dism -Phase 'image' -Text "export index $($Cfg.Index) to a working WIM" -ToolArgs @('/Export-Image', "/SourceImageFile:$srcImage", "/SourceIndex:$($Cfg.Index)", "/DestinationImageFile:$wimWork", '/Compress:max', '/CheckIntegrity')
        $m.outputs.installWim = $wimWork
        $null = Invoke-Dism -Phase 'image' -Text 'mount the working WIM' -ToolArgs @('/Mount-Image', "/ImageFile:$wimWork", '/Index:1', "/MountDir:$mnt")
        $state.MainMounted = $true

        # ---- identify the image from its offline registry
        Mount-OfflineHive $state 'SOFTWARE' $mnt
        Mount-OfflineHive $state 'SYSTEM' $mnt
        $swKey = $state.HiveNames['SOFTWARE'] + '\Microsoft\Windows NT\CurrentVersion'
        $edition = ([string](& $script:Exec 'regread' @{ Key = $swKey; Name = 'EditionID' }).Output).Trim()
        $buildTxt = ([string](& $script:Exec 'regread' @{ Key = $swKey; Name = 'CurrentBuildNumber' }).Output).Trim()
        $sysKey = $state.HiveNames['SYSTEM']
        $csn = ([string](& $script:Exec 'regread' @{ Key = "$sysKey\Select"; Name = 'Current' }).Output).Trim()
        $arch = ([string](& $script:Exec 'regread' @{ Key = "$sysKey\ControlSet00$csn\Control\Session Manager\Environment"; Name = 'PROCESSOR_ARCHITECTURE' }).Output).Trim()
        if (-not $edition) { throw 'Could not read the edition id from the image.' }
        $build = 0; if (-not [int]::TryParse($buildTxt, [ref]$build)) { $build = 0 }
        if ($csn -notmatch '^\d$') { $csn = '1' }
        $controlSet = 'ControlSet00' + $csn
        $m.image.edition = $edition; $m.image.build = $build; $m.image.architecture = $arch; $m.image.controlSet = $controlSet
        if ($script:Mode -eq 'Plan') { Add-Warning "Plan only: edition '$edition' is assumed (-EditionHint); a real run reads it from the image." }

        # ---- AppX
        $removed = New-Object System.Collections.Generic.List[string]
        $notPresent = New-Object System.Collections.Generic.List[string]
        if ($appx.Names.Count) {
            if ($script:Mode -eq 'Plan') {
                foreach ($n in $appx.Names) {
                    $null = Invoke-Step -Phase 'appx' -Text "remove provisioned package $n (if present)" -Tool 'plan-note' -Display (Format-Command 'dism.exe' @("/Image:$mnt", '/Remove-ProvisionedAppxPackage', "/PackageName:<full package name of $n>"))
                    $removed.Add($n)
                }
            }
            else {
                $lst = Invoke-Dism -Phase 'appx' -Text 'list the provisioned AppX packages' -ToolArgs @("/Image:$mnt", '/Get-ProvisionedAppxPackages') -Mutates $false
                $have = ConvertFrom-ProvisionedList ([string]$lst.Output)
                foreach ($n in $appx.Names) {
                    $hits = @($have | Where-Object { $_.Name -ieq $n })
                    if (-not $hits.Count) { $notPresent.Add($n); continue }
                    foreach ($hit in $hits) {
                        $null = Invoke-Dism -Phase 'appx' -Text "remove provisioned package $($hit.PackageName)" -ToolArgs @("/Image:$mnt", '/Remove-ProvisionedAppxPackage', "/PackageName:$($hit.PackageName)")
                        $removed.Add($hit.PackageName)
                    }
                }
            }
        }
        $m.appx = [ordered]@{ profile = [string]$Cfg.AppxProfile; requested = @($appx.Names); removed = @($removed.ToArray()); notPresent = @($notPresent.ToArray()); keptByProfile = @($appx.Kept); protectedSkipped = @($appx.Protected); wildcardIgnored = @($appx.Ignored) }

        # ---- registry tweaks
        $sel = Select-OfflineTweaks -Catalog $catalog -Edition $edition -Build $build -ExcludeIds @($Cfg.ExcludeId) -IncludeManaged ([bool]$Cfg.IncludeManagedSensitive) -ControlSet $controlSet -IncludeUnverified ([bool]$Cfg.IncludeUnverified)
        $values = @($sel.Selected | ForEach-Object { $_.values })
        $needed = @($values | ForEach-Object { $_.hive } | Select-Object -Unique)
        $skippedMore = New-Object System.Collections.Generic.List[object]
        foreach ($h in 'NTUSER', 'CLASSES') {
            if ($needed -notcontains $h) { continue }
            $f = Join-Path $mnt $script:HiveFiles[$h]
            if ([int](& $script:Exec 'exists' @{ Path = $f }).ExitCode -ne 0) {
                Add-Warning "$($script:HiveFiles[$h]) is not in the image; tweaks for that hive are skipped."
                foreach ($t in $sel.Selected) { if (@($t.values | Where-Object { $_.hive -eq $h }).Count) { $skippedMore.Add([pscustomobject]@{ id = $t.id; reason = "hive file $($script:HiveFiles[$h]) is not in the image" }) } }
                continue
            }
            Mount-OfflineHive $state $h $mnt
        }
        $dropIds = @($skippedMore | ForEach-Object { $_.id })
        $applied = New-Object System.Collections.Generic.List[object]
        foreach ($t in $sel.Selected) {
            if ($dropIds -contains $t.id) { continue }
            foreach ($v in $t.values) { Add-RegValue $state $v }
            $applied.Add([pscustomobject]@{ id = $t.id; values = $t.values.Count })
        }
        if ($Cfg.AllowUnsupportedHardware) {
            foreach ($n in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck') {
                Add-RegValue $state ([pscustomobject]@{ tweak = 'hardware-bypass'; hive = 'SYSTEM'; subPath = 'Setup\LabConfig'; name = $n; regType = 'REG_DWORD'; value = '1'; path = "HKLM:\SYSTEM\Setup\LabConfig" })
            }
            Add-RegValue $state ([pscustomobject]@{ tweak = 'hardware-bypass'; hive = 'SYSTEM'; subPath = 'Setup\MoSetup'; name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; regType = 'REG_DWORD'; value = '1'; path = "HKLM:\SYSTEM\Setup\MoSetup" })
        }
        $m.tweaks = [ordered]@{ applied = @($applied.ToArray()); skipped = @(@($sel.Skipped) + @($skippedMore.ToArray())); notInSafePreset = $sel.NotInSafePreset }
        Dismount-OfflineHives $state
        if ($state.Loaded.Count) { throw 'A registry hive is still loaded; not committing the image.' }

        # ---- cleanup, commit
        if (-not $Cfg.SkipCleanup) { $null = Invoke-Dism -Phase 'image' -Text 'clean up the component store (no reset, updates stay uninstallable)' -ToolArgs @("/Image:$mnt", '/Cleanup-Image', '/StartComponentCleanup') -NonFatal }
        $null = Invoke-Dism -Phase 'image' -Text 'unmount and commit the working WIM' -ToolArgs @('/Unmount-Image', "/MountDir:$mnt", '/Commit')
        $state.MainMounted = $false

        # ---- boot.wim bypass (opt-in)
        if ($Cfg.AllowUnsupportedHardware) {
            $bootWim = Join-Path $isoTree 'sources\boot.wim'
            $null = Invoke-Step -Phase 'prepare' -Text "create $bmnt" -Tool 'mkdir' -P @{ Path = $bmnt } -Display "New-Item -ItemType Directory -Force $(Format-Arg $bmnt)"
            $null = Invoke-Dism -Phase 'bootwim' -Text 'mount boot.wim index 2 (Windows Setup)' -ToolArgs @('/Mount-Image', "/ImageFile:$bootWim", '/Index:2', "/MountDir:$bmnt")
            $state.BootMounted = $true
            $bootHive = 'DK_BOOT_' + $suffix
            $null = Invoke-Step -Phase 'hive' -Text 'load the boot.wim SYSTEM hive' -Tool 'reg' -P @{ Args = @('load', "HKLM\$bootHive", (Join-Path $bmnt $script:HiveFiles['SYSTEM'])) } -Display (Format-Command 'reg.exe' @('load', "HKLM\$bootHive", (Join-Path $bmnt $script:HiveFiles['SYSTEM'])))
            $state.HiveNames['BOOT'] = $bootHive; $state.Loaded.Add('BOOT')
            foreach ($n in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck') {
                Add-RegValue $state ([pscustomobject]@{ tweak = 'hardware-bypass'; hive = 'BOOT'; subPath = 'Setup\LabConfig'; name = $n; regType = 'REG_DWORD'; value = '1'; path = 'HKLM:\SYSTEM\Setup\LabConfig (boot.wim)' })
            }
            Dismount-OfflineHives $state
            if ($state.Loaded.Count) { throw 'The boot.wim hive is still loaded; not committing boot.wim.' }
            $null = Invoke-Dism -Phase 'bootwim' -Text 'unmount and commit boot.wim' -ToolArgs @('/Unmount-Image', "/MountDir:$bmnt", '/Commit')
            $state.BootMounted = $false
        }

        # ---- final export into the ISO tree
        foreach ($old in $srcWim, $srcEsd) {
            if ([int](& $script:Exec 'exists' @{ Path = $old }).ExitCode -eq 0) {
                if ($old.StartsWith($isoTree, [System.StringComparison]::OrdinalIgnoreCase)) { $null = Invoke-Step -Phase 'image' -Text "remove the original $(Split-Path -Leaf $old) from the work copy" -Tool 'delete' -P @{ Path = $old } -Display "Remove-Item -LiteralPath $(Format-Arg $old)" }
            }
        }
        $finalName = if ($Cfg.RecoveryEsd) { 'install.esd' } else { 'install.wim' }
        $finalImg = Join-Path $isoTree "sources\$finalName"
        $comp = if ($Cfg.RecoveryEsd) { '/Compress:recovery' } else { '/Compress:max' }
        $null = Invoke-Dism -Phase 'image' -Text "export the final image as $finalName ($comp)" -ToolArgs @('/Export-Image', "/SourceImageFile:$wimWork", '/SourceIndex:1', "/DestinationImageFile:$finalImg", $comp, '/CheckIntegrity')

        # ---- autounattend (Compact OS)
        if ($Cfg.CompactOS) {
            $xml = New-AutounattendXml $arch
            $null = Invoke-Step -Phase 'setup' -Text 'write autounattend.xml (Compact OS at setup)' -Tool 'writefile' -P @{ Path = (Join-Path $isoTree 'autounattend.xml'); Content = $xml } -Display "write $(Join-Path $isoTree 'autounattend.xml') (<Compact>true</Compact>)"
        }

        # ---- ISO
        $oc = & $script:Exec 'findoscdimg' @{ Override = [string]$Cfg.OscdimgPath }
        $ocPath = ([string]$oc.Output).Trim()
        if ([int]$oc.ExitCode -eq 0 -and $ocPath) {
            $m.outputs.oscdimg = $ocPath
            $efi = Join-Path $isoTree 'efi\microsoft\boot\efisys.bin'
            $bios = Join-Path $isoTree 'boot\etfsboot.com'
            $isArm = ($arch -match '(?i)arm64')
            $boot = if ($isArm) { "-bootdata:1#pEF,e,b$efi" } else { "-bootdata:2#p0,e,b$bios#pEF,e,b$efi" }
            if ($real) {
                if ([int](& $script:Exec 'exists' @{ Path = $efi }).ExitCode -ne 0) { throw "Boot file missing in the work copy: $efi" }
                if (-not $isArm -and [int](& $script:Exec 'exists' @{ Path = $bios }).ExitCode -ne 0) { throw "Boot file missing in the work copy: $bios" }
            }
            $ocArgs = @('-m', '-o', '-u2', '-udfver102', '-lDebloatKit', $boot, $isoTree, $outIso)
            $null = Invoke-Step -Phase 'iso' -Text 'build the ISO with the local oscdimg' -Tool 'oscdimg' -P @{ Exe = $ocPath; Args = $ocArgs } -Display (Format-Command $ocPath $ocArgs)
            $m.outputs.iso = $outIso; $m.outputs.isoBuilt = $true
            $oh = Invoke-Step -Phase 'iso' -Text 'compute the SHA-256 of the new ISO' -Tool 'filehash' -P @{ Path = $outIso } -Display "Get-FileHash -Algorithm SHA256 -LiteralPath $(Format-Arg $outIso)" -Mutates $false
            if ($real -or $script:Mode -eq 'Mock') { $m.outputs.isoSha256 = ([string]$oh.Output).Trim().ToUpperInvariant() }
        }
        else {
            $m.outputs.isoBuilt = $false
            Add-Warning "oscdimg.exe was not found on this PC, so no ISO was built (nothing is downloaded). The finished tree is in $isoTree. Install the Windows ADK Deployment Tools (or the winget package Microsoft.OSCDIMG), then run oscdimg on that folder, or pass -OscdimgPath."
        }
        $m.completedUtc = [DateTime]::UtcNow.ToString('o')
        $m.warnings = @($script:Warnings.ToArray())
        $null = Invoke-Step -Phase 'manifest' -Text 'write the manifest' -Tool 'writefile' -P @{ Path = $manifestPath; Content = (ConvertTo-Json -InputObject $m -Depth 8) } -Display "write $manifestPath"
        $m.warnings = @($script:Warnings.ToArray())
        return $m
    }
    finally {
        # Guaranteed cleanup: hives first (they pin the mounted image), then the mounts, then the ISO. Never throws.
        try { if ($state.Loaded.Count) { Dismount-OfflineHives $state } } catch { Add-Warning "hive cleanup: $($_.Exception.Message)" }
        try {
            if ($state.BootMounted) { $null = Invoke-Dism -Phase 'cleanup' -Text 'discard the boot.wim mount' -ToolArgs @('/Unmount-Image', "/MountDir:$bmnt", '/Discard') -NonFatal }
        } catch { Add-Warning "boot.wim cleanup: $($_.Exception.Message)" }
        try {
            if ($state.MainMounted) { $null = Invoke-Dism -Phase 'cleanup' -Text 'discard the install image mount' -ToolArgs @('/Unmount-Image', "/MountDir:$mnt", '/Discard') -NonFatal }
        } catch { Add-Warning "image cleanup: $($_.Exception.Message)" }
        try {
            if ($state.IsoMounted) { $null = Invoke-Step -Phase 'cleanup' -Text 'dismount the ISO' -Tool 'dismountiso' -P @{ Path = [string]$Cfg.IsoPath } -Display "Dismount-DiskImage -ImagePath $(Format-Arg ([string]$Cfg.IsoPath))" -NonFatal }
        } catch { Add-Warning "ISO cleanup: $($_.Exception.Message)" }
    }
}

function New-Config {
    param([hashtable]$Values)
    $c = [ordered]@{
        IsoPath = ''; ExpectedSha256 = ''; SkipHashCheck = $false; Index = 0; ListEditions = $false; WorkDir = ''; OutputIso = ''
        AppxProfile = 'keep-personal'; CatalogPath = ''; ProfilesPath = ''; ExcludeId = @(); IncludeManagedSensitive = $false; IncludeUnverified = $false
        CompactOS = $false; SkipCleanup = $false; RecoveryEsd = $false; AllowUnsupportedHardware = $false; OscdimgPath = ''; EditionHint = 'Professional'
    }
    foreach ($k in $Values.Keys) { $c[$k] = $Values[$k] }
    [pscustomobject]$c
}

function Start-Build {
    # Runs Build-Image in the current mode with a fresh step list. Returns { Manifest; Steps; Warnings; Error }.
    param($Cfg)
    $script:Steps = New-Object System.Collections.Generic.List[object]
    $script:Warnings = New-Object System.Collections.Generic.List[string]
    $script:StepNo = 0
    $script:PlanEdition = [string]$Cfg.EditionHint
    $script:PlanHash = if ($Cfg.ExpectedSha256) { ([string]$Cfg.ExpectedSha256).ToUpperInvariant() } else { ('0' * 64) }
    $res = [pscustomobject]@{ Manifest = $null; Steps = $null; Warnings = $null; Error = $null }
    try { $res.Manifest = Build-Image $Cfg } catch { $res.Error = $_.Exception.Message }
    $res.Steps = @($script:Steps.ToArray())
    $res.Warnings = @($script:Warnings.ToArray())
    $res
}

# ---------------------------------------------------------------- output

function Write-PlanHuman {
    param($Res, $Cfg)
    Write-Host 'DebloatKit-Image plan (-WhatIf): nothing below was run.'
    Write-Host ''
    if ($Res.Manifest -and @(Get-Prop $Res.Manifest 'blockers' @()).Count) {
        Write-Host 'A real run would stop on:' -ForegroundColor Yellow
        foreach ($b in $Res.Manifest.blockers) { Write-Host ('  - ' + $b) -ForegroundColor Yellow }
        Write-Host ''
    }
    if ($Res.Error) { Write-Host ('Plan could not be completed: ' + $Res.Error) -ForegroundColor Red }
    $reg = @($Res.Steps | Where-Object { $_.phase -eq 'registry' })
    $lastTweak = ''
    foreach ($s in $Res.Steps) {
        if ($s.phase -eq 'registry') {
            if ($s.tweak -ne $lastTweak) {
                $n = @($reg | Where-Object { $_.tweak -eq $s.tweak }).Count
                Write-Host ('{0,3}. [registry] {1}: {2} value(s)' -f $s.n, $s.tweak, $n)
                $lastTweak = $s.tweak
            }
            continue
        }
        $lastTweak = ''
        Write-Host ('{0,3}. [{1}] {2}' -f $s.n, $s.phase, $s.description)
        Write-Host ('       ' + $s.command) -ForegroundColor DarkGray
    }
    if ($Res.Manifest) {
        $mf = $Res.Manifest
        $tw = Get-Prop $mf 'tweaks' $null
        if ($tw) {
            Write-Host ''
            Write-Host ('Tweaks applied offline: {0}; left out: {1} safe tweak(s) (online-only, edition, managed-device or hive reasons); {2} tweak(s) are in other presets and never touched.' -f @($tw.applied).Count, @($tw.skipped).Count, $tw.notInSafePreset)
        }
        $ax = Get-Prop $mf 'appx' $null
        if ($ax) { Write-Host ('AppX profile {0}: {1} exact package name(s) to remove, {2} kept by the profile, {3} protected.' -f $ax.profile, @($ax.requested).Count, @($ax.keptByProfile).Count, @($ax.protectedSkipped).Count) }
    }
    foreach ($w in $Res.Warnings) { Write-Host ('WARNING: ' + $w) -ForegroundColor Yellow }
}

function Write-BuildHuman {
    param($Res)
    $mf = $Res.Manifest
    Write-Host ''
    Write-Host 'Image build finished.'
    Write-Host ('  Edition {0}, build {1}, {2}' -f $mf.image.edition, $mf.image.build, $mf.image.architecture)
    $tw = Get-Prop $mf 'tweaks' $null
    if ($tw) { Write-Host ('  Tweaks applied offline: {0} (skipped {1})' -f @($tw.applied).Count, @($tw.skipped).Count) }
    $ax = Get-Prop $mf 'appx' $null
    if ($ax) { Write-Host ('  AppX removed: {0}' -f @($ax.removed).Count) }
    if ($mf.outputs.isoBuilt) { Write-Host ('  ISO: {0}' -f $mf.outputs.iso); Write-Host ('  SHA-256: {0}' -f $mf.outputs.isoSha256) }
    else { Write-Host ('  No ISO built. Prepared tree: {0}' -f $mf.outputs.isoTree) }
    Write-Host ('  Manifest: {0}' -f $mf.outputs.manifest)
    Write-Host '  Test the result in a VM before installing it on a real machine.'
}

# ---------------------------------------------------------------- self test

# BEGIN-SELFTEST
function Invoke-SelfTest {
    $script:stFails = 0
    $check = {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('PASS  ' + $Name) } else { Write-Host ('FAIL  ' + $Name); $script:stFails++ }
    }
    $script:Quiet = $true
    $realCatalog = Join-Path $scriptDir 'tweak-catalog.json'
    $realProfiles = Join-Path $scriptDir 'appx-profiles.json'

    # key mapping
    $r = Resolve-OfflineKey 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    & $check 'map: HKLM SOFTWARE -> SOFTWARE hive' ($r.Hive -eq 'SOFTWARE' -and $r.SubPath -eq 'Policies\Microsoft\Edge')
    $r = Resolve-OfflineKey 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'ControlSet002'
    & $check 'map: CurrentControlSet follows the offline Select\Current value' ($r.Hive -eq 'SYSTEM' -and $r.SubPath -eq 'ControlSet002\Control\PriorityControl')
    $r = Resolve-OfflineKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    & $check 'map: HKCU -> Default user hive NTUSER' ($r.Hive -eq 'NTUSER' -and $r.SubPath -eq 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced')
    $r = Resolve-OfflineKey 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    & $check 'map: HKCU Software\Classes -> UsrClass.dat (not NTUSER.DAT)' ($r.Hive -eq 'CLASSES' -and $r.SubPath -eq 'CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
    $r = Resolve-OfflineKey 'HKLM:\HARDWARE\DESCRIPTION'
    & $check 'map: an unmappable root is refused with a reason' ($null -eq $r.Hive -and $r.Reason)
    & $check 'reg add text: DWord, Default value and empty string' ((Format-RegAdd 'HKLM\K' 'A' 'REG_DWORD' '0') -eq 'reg add HKLM\K /v A /t REG_DWORD /d 0 /f' -and (Format-RegAdd 'HKLM\K' '(Default)' 'REG_SZ' '') -eq 'reg add HKLM\K /ve /t REG_SZ /d "" /f')

    # provisioned list parsing (English and a translated label)
    $txt = "Pakketnaam : Microsoft.BingNews_4.55.0.0_neutral_~_8wekyb3d8bbwe`r`nPackageName : Clipchamp.Clipchamp_3.0.0.0_neutral_~_yxz26nhyzhsrt`r`nPackageName : Microsoft.WindowsStore_22409.1401.3.0_neutral_~_8wekyb3d8bbwe`r`nPackageName : Microsoft.BingNews_4.55.0.0_neutral_~_8wekyb3d8bbwe"
    $pl = ConvertFrom-ProvisionedList $txt
    & $check 'provisioned list: names read by shape (localized label), duplicates dropped' ($pl.Count -eq 3 -and $pl[0].Name -eq 'Microsoft.BingNews' -and $pl[1].PackageName -eq 'Clipchamp.Clipchamp_3.0.0.0_neutral_~_yxz26nhyzhsrt')

    # AppX removal set against the real profiles
    $profiles = Get-Content -LiteralPath $realProfiles -Raw -Encoding UTF8 | ConvertFrom-Json
    $prot = $true; $wild = $false; $overlap = $false; $count = 0
    foreach ($pn in $profiles.profiles.PSObject.Properties.Name) {
        $s = Get-AppxRemovalSet $profiles $pn
        $count += $s.Names.Count
        foreach ($n in $s.Names) { if (Get-ProtectedAppxReason $n) { $prot = $false }; if ($n -match '[*?]') { $wild = $true } }
        $keep = @($profiles.profiles.$pn.keep)
        foreach ($n in $s.Names) { if (@($keep | Where-Object { $_ -ieq $n }).Count) { $overlap = $true } }
    }
    & $check 'appx: no profile resolves to a protected package, a wildcard or a name on its own keep list' ($prot -and -not $wild -and -not $overlap -and $count -gt 0)
    $kp = Get-AppxRemovalSet $profiles 'keep-personal'
    & $check 'appx: keep-personal removes Clipchamp and BingNews, keeps Photos and Calculator, never the Store' (($kp.Names -contains 'Clipchamp.Clipchamp') -and ($kp.Names -contains 'Microsoft.BingNews') -and ($kp.Names -notcontains 'Microsoft.Windows.Photos') -and ($kp.Names -notcontains 'Microsoft.WindowsCalculator') -and ($kp.Names -notcontains 'Microsoft.WindowsStore'))
    $fake = [pscustomobject]@{ profiles = [pscustomobject]@{ t = [pscustomobject]@{ keep = @('A.Keep'); remove = @('Microsoft.WindowsStore', 'Microsoft.VCLibs.140.00', 'Some.*', 'a.keep', 'B.Remove') } } }
    $fs = Get-AppxRemovalSet $fake 't'
    & $check 'appx: protected, wildcard and kept names are filtered; only the exact name stays' ($fs.Names.Count -eq 1 -and $fs.Names[0] -eq 'B.Remove' -and $fs.Protected.Count -eq 2 -and $fs.Ignored.Count -eq 1)
    & $check 'appx: unknown profile is a problem, none is an empty set' ((Get-AppxRemovalSet $profiles 'nope').Problem -and (Get-AppxRemovalSet $profiles 'none').Names.Count -eq 0)

    # catalog selection against the real catalog
    $catalog = Get-Content -LiteralPath $realCatalog -Raw -Encoding UTF8 | ConvertFrom-Json
    $pro = Select-OfflineTweaks -Catalog $catalog -Edition 'Professional' -Build 26100
    $ent = Select-OfflineTweaks -Catalog $catalog -Edition 'Enterprise' -Build 26100
    $mgd = Select-OfflineTweaks -Catalog $catalog -Edition 'Professional' -Build 26100 -IncludeManaged $true
    $byId = @{}; foreach ($t in $catalog.tweaks) { $byId[[string]$t.id] = $t }
    & $check ('catalog: some safe tweaks are selected ({0}) and every one is in the safe preset with risk safe' -f $pro.Selected.Count) ($pro.Selected.Count -gt 20 -and -not @($pro.Selected | Where-Object { $byId[$_.id].preset -ne 'safe' -or $byId[$_.id].risk -ne 'safe' }).Count)
    $allRows = @($pro.Selected | ForEach-Object { $_.values } | ForEach-Object { $_ })
    & $check 'catalog: every selected value maps to a known hive and a registry type' (-not @($allRows | Where-Object { $script:HiveFiles.Keys -notcontains $_.hive -or -not $_.regType }).Count -and $allRows.Count -gt 50)
    $nonSafeSkipped = @($pro.Skipped | Where-Object { $byId[$_.id].preset -ne 'safe' })
    & $check 'catalog: every safe tweak is either selected or skipped with a reason (guards future catalog edits)' ((@($catalog.tweaks | Where-Object { $_.preset -eq 'safe' }).Count) -eq ($pro.Selected.Count + $pro.Skipped.Count) -and -not @($pro.Skipped | Where-Object { -not $_.reason }).Count -and $nonSafeSkipped.Count -eq 0)
    & $check 'catalog: command, service and task tweaks stay online-only (snapshot-restore-point skipped)' (@($pro.Skipped | Where-Object { $_.id -eq 'snapshot-restore-point' -and $_.reason -match 'only work online' }).Count -eq 1)
    & $check 'catalog: AllowTelemetry=0 is left out on Professional (not honoured there) and kept on Enterprise' (@($pro.Selected | Where-Object { $_.id -eq 'telemetry-allowtelemetry-policy' }).Count -eq 0 -and @($ent.Selected | Where-Object { $_.id -eq 'telemetry-allowtelemetry-policy' }).Count -eq 1)
    & $check 'catalog: managedSkip tweaks are left out by default and included with -IncludeManagedSensitive' (@($pro.Selected | Where-Object { $byId[$_.id].PSObject.Properties['managedSkip'] }).Count -eq 0 -and @($mgd.Selected | Where-Object { $byId[$_.id].PSObject.Properties['managedSkip'] }).Count -gt 0)
    & $check 'catalog: the Classes tweak goes to the UsrClass hive, HKCU values to NTUSER' (@($allRows | Where-Object { $_.tweak -eq 'ui-classic-context-menu' -and $_.hive -eq 'CLASSES' -and $_.name -eq '(Default)' }).Count -eq 1 -and @($allRows | Where-Object { $_.hive -eq 'NTUSER' }).Count -gt 5)
    & $check 'catalog: no Defender, Windows Update, recovery or servicing value is selected' (-not @($allRows | Where-Object { $_.path -match '(?i)Windows Defender|\\WindowsUpdate|WaaSMedic|\\Services\\(wuauserv|UsoSvc|WinDefend|Sense)|WinRE|Recovery' }).Count)
    $ex = Select-OfflineTweaks -Catalog $catalog -Edition 'Professional' -Build 26100 -ExcludeIds @('ai-copilot-disable')
    & $check 'catalog: -ExcludeId leaves a tweak out with a reason' (@($ex.Selected | Where-Object { $_.id -eq 'ai-copilot-disable' }).Count -eq 0 -and @($ex.Skipped | Where-Object { $_.id -eq 'ai-copilot-disable' -and $_.reason -match 'ExcludeId' }).Count -eq 1)
    $badCat = [pscustomobject]@{ tweaks = @([pscustomobject]@{ id = 'x1'; preset = 'balanced'; risk = 'moderate'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\X'; name = 'A'; valueType = 'DWord'; value = 1 } }, [pscustomobject]@{ id = 'x2'; preset = 'safe'; risk = 'reduces-security'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\X'; name = 'A'; valueType = 'DWord'; value = 1 } }) }
    $bc = Select-OfflineTweaks -Catalog $badCat -Edition 'Professional' -Build 26100
    & $check 'catalog: a non-safe preset or a risky tweak is never selected' ($bc.Selected.Count -eq 0 -and $bc.NotInSafePreset -eq 1 -and $bc.Skipped.Count -eq 1)
    $unv = Select-OfflineTweaks -Catalog $catalog -Edition 'Professional' -Build 26100 -IncludeUnverified $true
    & $check ('catalog: unverified tweaks are left out by default ({0} skipped with a reason) and selected with -IncludeUnverified ({1} more)' -f @($pro.Skipped | Where-Object { $_.reason -match 'IncludeUnverified' }).Count, ($unv.Selected.Count - $pro.Selected.Count)) (@($pro.Selected | Where-Object { $byId[$_.id].verification -eq 'new-unverified' }).Count -eq 0 -and @($pro.Skipped | Where-Object { $_.reason -match 'use -IncludeUnverified' }).Count -gt 0 -and $unv.Selected.Count -gt $pro.Selected.Count -and @($unv.Selected | Where-Object { $byId[$_.id].verification -eq 'new-unverified' }).Count -gt 0)
    $protCat = [pscustomobject]@{ tweaks = @(
            [pscustomobject]@{ id = 'p1'; preset = 'safe'; risk = 'safe'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; name = 'NoAutoUpdate'; valueType = 'DWord'; value = 1 } },
            [pscustomobject]@{ id = 'p2'; preset = 'safe'; risk = 'safe'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; name = 'EnableLUA'; valueType = 'DWord'; value = 0 } },
            [pscustomobject]@{ id = 'p3'; preset = 'safe'; risk = 'safe'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv'; name = 'Start'; valueType = 'DWord'; value = 4 } },
            [pscustomobject]@{ id = 'p4'; preset = 'safe'; risk = 'safe'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile'; name = 'EnableFirewall'; valueType = 'DWord'; value = 0 } },
            [pscustomobject]@{ id = 'p5'; preset = 'safe'; risk = 'safe'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'; name = 'UseAdvancedStartup'; valueType = 'DWord'; value = 0 } },
            [pscustomobject]@{ id = 'p6'; preset = 'safe'; risk = 'safe'; implementation = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; name = 'EnableActivityFeed'; valueType = 'DWord'; value = 0 } }) }
    $pc = Select-OfflineTweaks -Catalog $protCat -Edition 'Professional' -Build 26100
    & $check 'catalog: values on protected targets (update policy, UAC, update service, firewall, BitLocker) are skipped with a reason; an ordinary value under the same policy area is kept' ($pc.Selected.Count -eq 1 -and $pc.Selected[0].id -eq 'p6' -and @($pc.Skipped | Where-Object { $_.reason -match 'protected target' }).Count -eq 5)

    # blockers
    $base = @{ IsoPath = 'C:\Fake\Win11.iso'; ExpectedSha256 = ('AB' * 32); Index = 1; WorkDir = 'C:\DbkSelfTestWork'; CatalogPath = $realCatalog; ProfilesPath = $realProfiles }
    $mc = { param([hashtable]$o) $h = @{}; foreach ($k in $base.Keys) { $h[$k] = $base[$k] }; foreach ($k in $o.Keys) { $h[$k] = $o[$k] }; New-Config $h }
    $okProbe = [pscustomobject]@{ IsoExists = $true; Size = 5GB; OutputExists = $false; WorkDirNotEmpty = $false; IsAdmin = $true }
    & $check 'gates: a complete configuration has no blockers' ((Get-Blockers (& $mc @{}) $true $okProbe).Count -eq 0)
    & $check 'gates: no hash and no -SkipHashCheck is refused' ((@(Get-Blockers (& $mc @{ ExpectedSha256 = '' }) $true $okProbe) -match 'No ISO hash').Count -eq 1)
    & $check 'gates: -SkipHashCheck lifts the hash gate' ((Get-Blockers (& $mc @{ ExpectedSha256 = ''; SkipHashCheck = $true }) $true $okProbe).Count -eq 0)
    & $check 'gates: bad hash text, missing index, unsafe work folders and an existing output are refused' ((@(Get-Blockers (& $mc @{ ExpectedSha256 = 'xyz' }) $true $okProbe) -match '64 hex').Count -eq 1 -and (@(Get-Blockers (& $mc @{ Index = 0 }) $true $okProbe) -match 'Index').Count -eq 1 -and (@(Get-Blockers (& $mc @{ WorkDir = 'C:\Work Dir' }) $true $okProbe) -match 'WorkDir').Count -eq 1 -and (@(Get-Blockers (& $mc @{ WorkDir = 'C:\' }) $true $okProbe) -match 'drive root').Count -eq 1 -and (@(Get-Blockers (& $mc @{ WorkDir = (Join-Path $env:SystemRoot 'Work') }) $true $okProbe) -match 'Windows folder').Count -eq 1 -and (@(Get-Blockers (& $mc @{ WorkDir = 'C:\ProgramData\DebloatKit\w' }) $true $okProbe) -match 'state folder').Count -eq 1)
    $badProbe = [pscustomobject]@{ IsoExists = $false; Size = 0; OutputExists = $true; WorkDirNotEmpty = $true; IsAdmin = $false }
    $bl = Get-Blockers (& $mc @{ OutputIso = 'C:\Out\x.iso' }) $true $badProbe
    & $check 'gates: missing ISO, non-empty work folder, existing output and no elevation are refused in a real run' ((@($bl) -match 'ISO not found').Count -eq 1 -and (@($bl) -match 'not empty').Count -eq 1 -and (@($bl) -match 'never replaced').Count -eq 1 -and (@($bl) -match 'elevated').Count -eq 1)

    # mocked builds
    $script:Mode = 'Mock'
    $mk = {
        param([hashtable]$Opt)
        # Recording fake of DISM, reg.exe, the file system and the registry provider. Opt: Edition, Arch, Fail (list of tool|fragment), NoOscdimg, HashActual, NoNtUser, ProvText.
        $log = New-Object System.Collections.Generic.List[string]
        $files = @{}
        $o = @{ Edition = 'Professional'; Arch = 'AMD64'; Fail = @(); NoOscdimg = $false; HashActual = ('AB' * 32); NoNtUser = $false; ProvText = "PackageName : Microsoft.BingNews_4.55.0.0_neutral_~_8wekyb3d8bbwe`r`nPackageName : Clipchamp.Clipchamp_3.0.0.0_neutral_~_yxz26nhyzhsrt`r`nPackageName : Microsoft.WindowsStore_22409.1401.3.0_neutral_~_8wekyb3d8bbwe`r`nPackageName : Microsoft.Windows.Photos_2024.1.0.0_neutral_~_8wekyb3d8bbwe" }
        foreach ($k in $Opt.Keys) { $o[$k] = $Opt[$k] }
        $state = @{ Loaded = @{}; Mounted = $false }
        $script:Exec = {
            param($Tool, $P)
            $res = { param($c, $t) [pscustomobject]@{ ExitCode = $c; Output = $t } }
            $line = switch ($Tool) {
                'dism' { 'dism ' + ($P.Args -join ' ') }
                'reg' { 'reg ' + ($P.Args -join ' ') }
                'regset' { 'regset ' + $P.Key + '|' + $P.Name + '|' + $P.Value }
                'oscdimg' { 'oscdimg ' + ($P.Args -join ' ') }
                'writefile' { 'writefile ' + $P.Path }
                default { $Tool + $(if ($P.ContainsKey('Path')) { ' ' + $P.Path } else { '' }) }
            }
            $log.Add($line)
            foreach ($f in @($o.Fail)) { $tf = $f -split '\|', 2; if ($tf[0] -eq $Tool -and $line.Contains($tf[1])) {
                    # an unload failure only lasts for the first attempts
                    return (& $res 9 'fake failure') } }
            switch ($Tool) {
                'isoprobe' { return (& $res 0 '{"IsoExists":true,"Size":5368709120,"OutputExists":false,"WorkDirNotEmpty":false}') }
                'isadmin' { return (& $res 0 '') }
                'freespace' { return (& $res 0 '99999999999999') }
                'filehash' { if ($P.Path -eq 'C:\Fake\Win11.iso') { return (& $res 0 $o.HashActual) } else { return (& $res 0 ('CD' * 32)) } }
                'mountiso' { return (& $res 0 'E:') }
                'exists' {
                    if ($P.Path -like '*install.esd') { return (& $res 1 '') }
                    if ($P.Path -like '*UsrClass.dat' -or ($P.Path -like '*NTUSER.DAT' -and $o.NoNtUser)) { return (& $res $(if ($P.Path -like '*NTUSER.DAT' -and $o.NoNtUser) { 1 } else { 0 }) '') }
                    return (& $res 0 '')
                }
                'dism' {
                    if ($P.Args -contains '/Get-ProvisionedAppxPackages') { return (& $res 0 $o.ProvText) }
                    return (& $res 0 '')
                }
                'regread' {
                    switch ($P.Name) { 'EditionID' { return (& $res 0 $o.Edition) } 'CurrentBuildNumber' { return (& $res 0 '26100') } 'PROCESSOR_ARCHITECTURE' { return (& $res 0 $o.Arch) } 'Current' { return (& $res 0 '1') } default { return (& $res 1 '') } }
                }
                'findoscdimg' { if ($o.NoOscdimg) { return (& $res 1 '') } else { return (& $res 0 'C:\Fake\ADK\oscdimg.exe') } }
                'writefile' { $files[$P.Path] = $P.Content; return (& $res 0 '') }
                default { return (& $res 0 '') }
            }
        }.GetNewClosure()
        [pscustomobject]@{ Log = $log; Files = $files }
    }
    $names = { param($log) @($log | ForEach-Object { $_ }) }
    $idx = { param($log, $frag) $i = 0; foreach ($l in $log) { if ($l.Contains($frag)) { return $i }; $i++ }; -1 }
    $lastIdx = { param($log, $frag) $r = -1; $i = 0; foreach ($l in $log) { if ($l.Contains($frag)) { $r = $i }; $i++ }; $r }

    # default build
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{})
    $log = $fk.Log
    & $check ('build (default): succeeds ({0})' -f $res.Error) ($null -eq $res.Error -and $res.Manifest -and $res.Manifest.outputs.isoBuilt -and $res.Manifest.source.verification -eq 'verified')
    & $check 'build (default): hash is checked before the ISO is mounted' ((& $idx $log 'filehash C:\Fake\Win11.iso') -ge 0 -and (& $idx $log 'filehash C:\Fake\Win11.iso') -lt (& $idx $log 'mountiso'))
    & $check 'build (default): the order is export, mount, hive load, AppX, registry, hive unload, cleanup, commit, export, ISO' (
        (& $idx $log '/Export-Image') -lt (& $idx $log '/Mount-Image') -and (& $idx $log '/Mount-Image') -lt (& $idx $log 'reg load') -and (& $idx $log 'reg load') -lt (& $idx $log '/Remove-ProvisionedAppxPackage') -and
        (& $idx $log '/Remove-ProvisionedAppxPackage') -lt (& $idx $log 'regset') -and (& $lastIdx $log 'regset') -lt (& $idx $log 'reg unload') -and (& $lastIdx $log 'reg unload') -lt (& $idx $log '/StartComponentCleanup') -and
        (& $idx $log '/StartComponentCleanup') -lt (& $idx $log '/Commit') -and (& $idx $log '/Commit') -lt (& $lastIdx $log '/Export-Image') -and (& $lastIdx $log '/Export-Image') -lt (& $idx $log 'oscdimg '))
    $exports = @($log | Where-Object { $_.Contains('/Export-Image') })
    & $check 'build (default): both exports use /Compress:max and the final one writes install.wim' ($exports.Count -eq 2 -and -not @($exports | Where-Object { $_ -notmatch '/Compress:max' }).Count -and $exports[1] -match 'sources\\install\.wim')
    & $check 'build (default): component cleanup without a reset' (@($log | Where-Object { $_ -match 'StartComponentCleanup' }).Count -eq 1 -and -not @($log | Where-Object { $_ -match '(?i)ResetBase' }).Count)
    $removeCalls = @($log | Where-Object { $_ -match '/Remove-ProvisionedAppxPackage' })
    & $check 'build (default): removes the exact full package names of BingNews and Clipchamp, never the Store or Photos' ($removeCalls.Count -eq 2 -and ($removeCalls -match 'BingNews_4\.55\.0\.0_neutral_~_8wekyb3d8bbwe').Count -eq 1 -and ($removeCalls -match 'Clipchamp\.Clipchamp_3\.0\.0\.0').Count -eq 1)
    & $check 'build (default): no LabConfig, no autounattend, no winre, no Defender, Windows Update or servicing writes' (-not @($log | Where-Object { $_ -match '(?i)LabConfig|MoSetup|autounattend|winre|Defender|wuauserv|WaaSMedic|UsoSvc|Compact' }).Count)
    & $check 'build (default): hives loaded with unique DK_ names, all unloaded, none left' ((@($log | Where-Object { $_ -match '^reg load HKLM\\DK_[A-Z]+_[0-9a-f]{8} ' }).Count -eq @($log | Where-Object { $_ -match '^reg unload ' }).Count) -and @($log | Where-Object { $_ -match '^reg load ' }).Count -eq 4)
    & $check 'build (default): ControlSet001 is used for SYSTEM values and HKCU values go to the NTUSER hive' (@($log | Where-Object { $_ -match '^regset DK_SYSTEM_[0-9a-f]{8}\\ControlSet001\\' }).Count -gt 0 -and @($log | Where-Object { $_ -match '^regset DK_NTUSER_[0-9a-f]{8}\\Software\\' }).Count -gt 0 -and @($log | Where-Object { $_ -match '^regset DK_CLASSES_[0-9a-f]{8}\\CLSID\\' }).Count -gt 0)
    $oc = @($log | Where-Object { $_ -match '^oscdimg ' })
    & $check 'build (default): oscdimg is the local one with the UDF 1.02 boot data' ($oc.Count -eq 1 -and $oc[0] -match '-udfver102' -and $oc[0] -match 'bootdata:2#p0,e,b' -and $oc[0] -match 'efisys\.bin')
    $mfile = @($fk.Files.Keys | Where-Object { $_ -like '*.manifest.json' })
    $mj = $null; if ($mfile.Count) { try { $mj = $fk.Files[$mfile[0]] | ConvertFrom-Json } catch { } }
    & $check 'build (default): manifest has the source hash, catalog and profile versions, tweaks, AppX and the output hash' ($mj -and $mj.source.sha256Actual -eq ('AB' * 32) -and $mj.catalogVersion -and $mj.profilesVersion -and @($mj.tweaks.applied).Count -gt 20 -and @($mj.appx.removed).Count -eq 2 -and $mj.outputs.isoSha256 -eq ('CD' * 32))
    & $check 'build (default): the step list carries a command for every step and never touches the real disk (Mock mode)' ($res.Steps.Count -gt 100 -and -not @($res.Steps | Where-Object { -not $_.command }).Count)

    # hash mismatch and skip
    $fk = & $mk @{ HashActual = ('EE' * 32) }
    $res = Start-Build (& $mc @{})
    & $check 'build (hash mismatch): refused before the ISO is mounted, nothing else runs' ($res.Error -match 'SHA-256 mismatch' -and (& $idx $fk.Log 'mountiso') -eq -1 -and (& $idx $fk.Log '/Mount-Image') -eq -1)
    $fk = & $mk @{ HashActual = ('EE' * 32) }
    $res = Start-Build (& $mc @{ ExpectedSha256 = ''; SkipHashCheck = $true })
    & $check 'build (-SkipHashCheck): proceeds, warns and records the image as unverified' ($null -eq $res.Error -and $res.Manifest.source.verification -match 'unverified' -and @($res.Warnings -match 'UNVERIFIED').Count -eq 1 -and (& $idx $fk.Log 'filehash C:\Fake\Win11.iso') -eq -1)
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{ ExpectedSha256 = '' })
    & $check 'build (no hash given): refused with nothing run' ($res.Error -match 'No ISO hash' -and (& $idx $fk.Log 'mountiso') -eq -1)

    # opt-in flags
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{ CompactOS = $true })
    $ua = @($fk.Files.Keys | Where-Object { $_ -like '*autounattend.xml' })
    $xmlOk = $false; if ($ua.Count) { try { $x = [xml]$fk.Files[$ua[0]]; $xmlOk = ($x.unattend.settings.component.ImageInstall.OSImage.Compact -eq 'true' -and $x.unattend.settings.component.processorArchitecture -eq 'amd64') } catch { } }
    & $check 'build (-CompactOS): well-formed autounattend.xml with Compact=true is written into the ISO tree' ($null -eq $res.Error -and $xmlOk -and $ua[0] -match '\\iso\\autounattend\.xml$')
    $fk = & $mk @{ Arch = 'ARM64' }
    $res = Start-Build (& $mc @{ CompactOS = $true })
    $ua = @($fk.Files.Keys | Where-Object { $_ -like '*autounattend.xml' })
    $oc = @($fk.Log | Where-Object { $_ -match '^oscdimg ' })
    & $check 'build (ARM64): autounattend names arm64 and the ISO uses the EFI-only boot data' ($ua.Count -eq 1 -and $fk.Files[$ua[0]] -match 'processorArchitecture="arm64"' -and $oc[0] -match 'bootdata:1#pEF' -and $oc[0] -notmatch 'etfsboot')
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{ AllowUnsupportedHardware = $true })
    $lg = $fk.Log
    & $check 'build (-AllowUnsupportedHardware): LabConfig in install.wim and boot.wim index 2, MoSetup, with a warning' ($null -eq $res.Error -and @($lg | Where-Object { $_ -match 'LabConfig\|Bypass' }).Count -eq 10 -and @($lg | Where-Object { $_ -match 'MoSetup\|AllowUpgradesWithUnsupportedTPMOrCPU' }).Count -eq 1 -and @($lg | Where-Object { $_ -match '/Mount-Image /ImageFile:.*boot\.wim /Index:2' }).Count -eq 1 -and @($res.Warnings -match 'not guarantee').Count -eq 1)
    & $check 'build (-AllowUnsupportedHardware): boot.wim is unmounted with /Commit after its hive is unloaded' ((& $idx $lg '\bootmnt /Commit') -gt (& $lastIdx $lg 'reg unload') -and (& $idx $lg '\bootmnt /Commit') -lt (& $idx $lg 'oscdimg '))
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{ RecoveryEsd = $true })
    $ex = @($fk.Log | Where-Object { $_.Contains('/Export-Image') })
    & $check 'build (-RecoveryEsd): final export is /Compress:recovery into install.esd, warns about servicing' ($null -eq $res.Error -and $ex[1] -match '/Compress:recovery' -and $ex[1] -match 'install\.esd' -and $ex[0] -match '/Compress:max' -and @($res.Warnings -match 'cannot be serviced').Count -eq 1)
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{ SkipCleanup = $true; AppxProfile = 'none' })
    & $check 'build (-SkipCleanup, AppxProfile none): no cleanup and no AppX step' ($null -eq $res.Error -and (& $idx $fk.Log 'StartComponentCleanup') -eq -1 -and (& $idx $fk.Log 'Get-ProvisionedAppxPackages') -eq -1)
    $fk = & $mk @{ NoOscdimg = $true }
    $res = Start-Build (& $mc @{})
    & $check 'build (no oscdimg): no ISO, the tree is kept, a warning says where, nothing is downloaded' ($null -eq $res.Error -and -not $res.Manifest.outputs.isoBuilt -and @($res.Warnings -match 'oscdimg.exe was not found').Count -eq 1 -and (& $idx $fk.Log 'oscdimg ') -eq -1)
    $fk = & $mk @{ Edition = 'Enterprise' }
    $res = Start-Build (& $mc @{})
    & $check 'build (Enterprise image): AllowTelemetry is applied; the edition comes from the offline registry' ($res.Manifest.image.edition -eq 'Enterprise' -and (@($res.Manifest.tweaks.applied | Where-Object { $_.id -eq 'telemetry-allowtelemetry-policy' }).Count -eq 1))
    $fk = & $mk @{}
    $res = Start-Build (& $mc @{ ListEditions = $true; Index = 0; ExpectedSha256 = '' })
    & $check 'build (-ListEditions): mounts, lists with /Get-WimInfo, dismounts, copies and changes nothing' ($null -eq $res.Error -and (& $idx $fk.Log '/Get-WimInfo') -gt -1 -and (& $idx $fk.Log 'dismountiso') -gt -1 -and (& $idx $fk.Log 'robocopy') -eq -1 -and (& $idx $fk.Log '/Mount-Image') -eq -1)

    # failures: the finally block
    $fk = & $mk @{ Fail = @('regset|Policies') }
    $res = Start-Build (& $mc @{})
    $lg = $fk.Log
    & $check 'failure (registry write): reports the error, unloads every hive, discards the mount (no /Commit), builds no ISO' ($res.Error -match 'failed' -and (@($lg | Where-Object { $_ -match '^reg load ' }).Count -eq @($lg | Where-Object { $_ -match '^reg unload ' }).Count) -and (& $idx $lg '/Unmount-Image /MountDir:C:\DbkSelfTestWork\mnt /Discard') -gt -1 -and (& $idx $lg '/Commit') -eq -1 -and (& $idx $lg 'oscdimg ') -eq -1)
    & $check 'failure (registry write): hives are unloaded before the discard' ((& $lastIdx $lg 'reg unload') -lt (& $idx $lg '/Discard'))
    $fk = & $mk @{ Fail = @('dism|/Mount-Image') }
    $res = Start-Build (& $mc @{})
    & $check 'failure (mount): the ISO is already dismounted and nothing is loaded or committed' ($res.Error -match 'failed' -and (& $idx $fk.Log 'reg load') -eq -1 -and (& $idx $fk.Log '/Commit') -eq -1 -and (& $lastIdx $fk.Log 'dismountiso') -gt -1)
    $fk = & $mk @{ Fail = @('robocopy|') }
    $res = Start-Build (& $mc @{})
    & $check 'failure (copy): the mounted ISO is dismounted in finally' ($res.Error -match 'failed' -and (& $idx $fk.Log 'dismountiso') -gt -1 -and (& $idx $fk.Log '/Mount-Image') -eq -1)
    $fk = & $mk @{ Fail = @('reg|unload') }
    $res = Start-Build (& $mc @{})
    & $check 'failure (hive will not unload): the image is not committed and the manual fix is shown' ($res.Error -match 'hive is still loaded' -and (& $idx $fk.Log '/Commit') -eq -1 -and @($res.Warnings -match 'reg unload HKLM').Count -ge 1)
    $fk = & $mk @{ Fail = @('dism|/StartComponentCleanup') }
    $res = Start-Build (& $mc @{})
    & $check 'failure (component cleanup): only a warning; the image is still committed and exported' ($null -eq $res.Error -and (& $idx $fk.Log '/Commit') -gt -1 -and @($res.Warnings -match 'clean up the component store').Count -ge 1)
    $fk = & $mk @{ NoNtUser = $true }
    $res = Start-Build (& $mc @{})
    & $check 'build (no Default user hive in the image): HKCU tweaks are skipped with a reason, the rest is applied' ($null -eq $res.Error -and @($res.Manifest.tweaks.skipped | Where-Object { $_.reason -match 'NTUSER' }).Count -gt 0 -and @($fk.Log | Where-Object { $_ -match '^regset DK_NTUSER' }).Count -eq 0 -and @($fk.Log | Where-Object { $_ -match '^regset DK_SOFTWARE' }).Count -gt 0)

    # plan mode (-WhatIf)
    $script:Mode = 'Plan'
    $script:Exec = { param($Tool, $P) Invoke-PlanTool $Tool $P }
    $res = Start-Build (& $mc @{ CompactOS = $true; AllowUnsupportedHardware = $true; WorkDir = 'C:\DbkSelfTestPlan' })
    $plan = $res.Steps
    & $check ('plan: lists the full command plan ({0} steps) without an error' -f $plan.Count) ($null -eq $res.Error -and $plan.Count -gt 100 -and (@($plan | Where-Object { $_.command -match '^dism\.exe /Export-Image' }).Count -eq 2) -and (@($plan | Where-Object { $_.command -match 'oscdimg' -or $_.phase -eq 'iso' }).Count -ge 3))
    & $check 'plan: names the exact AppX packages to remove and shows the assumed edition' (@($plan | Where-Object { $_.phase -eq 'appx' }).Count -gt 20 -and $res.Manifest.image.edition -eq 'Professional' -and @($res.Warnings -match 'assumed').Count -eq 1)
    & $check 'plan: shows the blockers a real run would hit (the fake ISO does not exist)' (@($res.Manifest.blockers | Where-Object { $_ -match 'ISO not found' }).Count -eq 1)
    $unmountPlan = @($plan | Where-Object { $_.command -match '/Unmount-Image' })
    & $check 'plan: the same steps as a build - mount, commit, hives loaded and unloaded in pairs' (@($plan | Where-Object { $_.command -match '^reg\.exe load' }).Count -eq @($plan | Where-Object { $_.command -match '^reg\.exe unload' }).Count -and $unmountPlan.Count -eq 2)

    # static scan
    $path = $PSCommandPath
    if (-not $path) { $path = $MyInvocation.MyCommand.Path }
    $text = [System.IO.File]::ReadAllText($path)
    $noReal = [regex]::Replace($text, '(?s)# BEGIN-' + 'REAL-TOOLS.*?# END-' + 'REAL-TOOLS', '')
    $noReal = [regex]::Replace($noReal, '(?s)# BEGIN-' + 'SELFTEST.*?# END-' + 'SELFTEST', '')
    $noReal = [regex]::Replace($noReal, '(?s)# BEGIN-FORBIDDEN.*?# END-FORBIDDEN', '')
    $noReal = [regex]::Replace($noReal, '(?s)# BEGIN-' + 'PROTECTED-LISTS.*?# END-' + 'PROTECTED-LISTS', '')
    $noReal = [regex]::Replace($noReal, '(?s)<#.*?#>', '')
    $code = (($noReal -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    # BEGIN-FORBIDDEN
    $onlyInDispatcher = @('Start-Process', 'Set-ItemProperty', 'New-ItemProperty', 'WriteAllText', 'SetValue', 'Invoke-Expression', 'Copy-Item', 'Set-Content', 'Out-File', 'Add-Content', '& dism', '& reg', '& robocopy')
    $never = @('ResetBase', 'winre.wim', 'Defender', 'wuauserv', 'WaaSMedic', 'UsoSvc', 'msdl.microsoft.com', 'Invoke-WebRequest', 'Invoke-RestMethod', 'DownloadFile', 'DownloadString', 'Start-BitsTransfer', 'WebClient', 'curl.exe', 'wget', 'winget install', 'Set-Service', 'schtasks', 'sc.exe', 'Disable-WindowsOptionalFeature', 'Remove-WindowsCapability', 'Set-ReservedStorageState', 'reagentc')
    # END-FORBIDDEN
    $hits = @($onlyInDispatcher | Where-Object { $code.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    & $check ('static scan: system-changing commands appear only inside Invoke-RealTool' + $(if ($hits.Count) { ' (found: ' + ($hits -join ', ') + ')' } else { '' })) ($hits.Count -eq 0)
    $hits2 = @($never | Where-Object { $code.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $realPart = [regex]::Match($text, '(?s)# BEGIN-REAL-TOOLS.*?# END-REAL-TOOLS').Value
    $hits3 = @($never | Where-Object { $realPart.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    & $check ('static scan: no reset of the component store, no recovery / Defender / Windows Update / service changes, no download commands' + $(if ($hits2.Count + $hits3.Count) { ' (found: ' + (($hits2 + $hits3) -join ', ') + ')' } else { '' })) (($hits2.Count + $hits3.Count) -eq 0)
    & $check 'static scan: file is ASCII only' (-not [regex]::IsMatch($text, '[^\x00-\x7F]'))

    $script:Mode = 'Real'
    $script:Quiet = $false
    if ($script:stFails -eq 0) { Write-Host 'SELFTEST PASSED'; return 0 }
    Write-Host 'SELFTEST FAILED'
    return 1
}

# END-SELFTEST

# ---------------------------------------------------------------- main

try {
    if ($SelfTest) { exit (Invoke-SelfTest) }

    if (-not $CatalogPath) { $CatalogPath = Join-Path $scriptDir 'tweak-catalog.json' }
    if (-not $ProfilesPath) { $ProfilesPath = Join-Path $scriptDir 'appx-profiles.json' }
    if (-not $WorkDir) { $WorkDir = Join-Path ([string]$env:SystemDrive + '\') 'DebloatKitImage' }
    if ($IsoPath) { $IsoPath = [System.IO.Path]::GetFullPath($IsoPath) }
    if ($WorkDir) { $WorkDir = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd('\') }
    if ($OutputIso) { $OutputIso = [System.IO.Path]::GetFullPath($OutputIso) }
    foreach ($f in $CatalogPath) { if (-not (Test-Path -LiteralPath $f)) { throw "Catalog not found: $f" } }
    $ids = @($ExcludeId | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

    $cfg = New-Config @{
        IsoPath = $IsoPath; ExpectedSha256 = $ExpectedSha256; SkipHashCheck = [bool]$SkipHashCheck; Index = $Index; ListEditions = [bool]$ListEditions
        WorkDir = $WorkDir; OutputIso = $OutputIso; AppxProfile = $AppxProfile; CatalogPath = $CatalogPath; ProfilesPath = $ProfilesPath
        ExcludeId = $ids; IncludeManagedSensitive = [bool]$IncludeManagedSensitive; IncludeUnverified = [bool]$IncludeUnverified; CompactOS = [bool]$CompactOS; SkipCleanup = [bool]$SkipCleanup
        RecoveryEsd = [bool]$RecoveryEsd; AllowUnsupportedHardware = [bool]$AllowUnsupportedHardware; OscdimgPath = $OscdimgPath; EditionHint = $EditionHint
    }
    $script:Quiet = ([bool]$AsJson -or $script:DryRun)

    if ($script:DryRun) {
        $script:Mode = 'Plan'
        $script:Exec = { param($Tool, $P) Invoke-PlanTool $Tool $P }
        $res = Start-Build $cfg
        if ($AsJson) {
            $mf = $res.Manifest
            $o = [ordered]@{
                mode = 'plan'; error = $res.Error; blockers = @(Get-Prop $mf 'blockers' @()); warnings = $res.Warnings
                image = Get-Prop $mf 'image' $null; options = Get-Prop $mf 'options' $null; tweaks = Get-Prop $mf 'tweaks' $null; appx = Get-Prop $mf 'appx' $null
                outputs = Get-Prop $mf 'outputs' $null; steps = $res.Steps
            }
            Write-Output (ConvertTo-Json -InputObject $o -Depth 8)
        }
        else { Write-PlanHuman $res $cfg }
        exit $(if ($res.Error) { 1 } else { 0 })
    }

    $script:Mode = 'Real'
    $script:Exec = { param($Tool, $P) Invoke-RealTool $Tool $P }
    $res = Start-Build $cfg
    if ($res.Error) { [Console]::Error.WriteLine('DebloatKit-Image failed: ' + $res.Error); exit 1 }
    if ($AsJson) { Write-Output (ConvertTo-Json -InputObject $res.Manifest -Depth 8) }
    elseif ($ListEditions) { Write-Host $res.Manifest.editionsText }
    else { Write-BuildHuman $res }
    exit 0
}
catch {
    [Console]::Error.WriteLine('DebloatKit-Image failed: ' + $_.Exception.Message)
    exit 1
}
