<#
.SYNOPSIS
    JSON-driven, reversible Windows 11 debloat engine.

.DESCRIPTION
    Applies tweaks from tweak-catalog.json (built from research into ReviOS, AtlasOS, Tiny11,
    winutil, Win11Debloat and privacy tools). Only the 'safe' preset is enabled in this version.

    Every change is snapshotted BEFORE it is made (registry value or its absence, service start
    type, scheduled task state, power plan, ...). -Undo replays the snapshot in reverse, so revert
    restores what was actually there instead of guessing Windows defaults.

    Free-form 'command' strings in the catalog are never executed. A few commands are implemented
    natively with a snapshot (power plan, NTFS last-access, execution policy); the rest are skipped
    with a reason. AppX removal is skipped unless -AllowIrreversible, because it cannot be undone
    exactly.

    Modes:
      -List              show every tweak in the preset and whether it is already in effect (read-only)
      -WhatIf            show what an apply would change; writes nothing, no admin needed
      (default)          apply: restore point, snapshot, change, verify, log (admin)
      -Undo <latest|file> revert a previous run from its snapshot (admin)

.PARAMETER Preset
    Tweak preset. Only 'safe' is enabled.

.PARAMETER Only
    Apply only these tweak ids.

.PARAMETER Skip
    Skip these tweak ids.

.PARAMETER Force
    Required to apply on a device that is Entra ID joined, domain joined or MDM enrolled.

.PARAMETER NoRestorePoint
    Do not create a system restore point before applying.

.PARAMETER AllowIrreversible
    Allow steps that have no exact undo (AppX removal).

.PARAMETER ExpectedSid
    SID of the user who started the GUI. If this process runs as someone else and a per-user (HKCU)
    registry step is involved, the engine refuses before changing anything.

.PARAMETER IncludeUnverified
    Catalog entries with verification 'new-unverified' (added from fresh research, not yet tested on
    a real machine) are skipped unless this switch is passed.

.PARAMETER AsJson
    With -List or -WhatIf: write machine-readable JSON to stdout instead of tables. -List gives
    {managed:{...}, tweaks:[...]}; -WhatIf gives an array of plan steps. Nothing else is written to
    stdout; warnings go to stderr so the JSON stays parseable.

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
    [string]$Preset = 'safe',

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [string[]]$Only,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [string[]]$Skip,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Undo', Mandatory)]
    [string]$Undo,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$Force,

    # SID of the user the GUI runs as. When the elevated process runs as a DIFFERENT user (UAC with
    # another admin's credentials), per-user (HKCU) steps would land in the wrong hive, so they are refused.
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Undo')]
    [string]$ExpectedSid,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$NoRestorePoint,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$AllowIrreversible,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [switch]$IncludeUnverified,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'List')]
    [switch]$AsJson,

    [Parameter(ParameterSetName = 'List')]
    [ValidateSet('default', 'effectiveness')]
    [string]$SortBy = 'default',

    [string]$CatalogPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolved here, not as parameter defaults: Windows PowerShell 5.1 leaves $PSScriptRoot empty there.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $CatalogPath) { $CatalogPath = Join-Path $scriptDir 'tweak-catalog.json' }
if (-not $StateDir) { $StateDir = Join-Path $env:ProgramData 'DebloatKit' }

$EnabledPresets = @('safe')
# On managed devices these are skipped even with -Force: they fight org policy (updates, time sync).
$ManagedSkipCategories = @('updates')
$ManagedSkipIds = @('net-ntp-pool')
# Handled by the engine itself rather than as a catalog step.
$EngineHandledIds = @('snapshot-restore-point')

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
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8 -WhatIf:$false
}

function Get-Prop($Obj, [string]$Name, $Default = $null) {
    # StrictMode-safe optional property read (older or test catalogs lack the newer fields).
    if ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $Name) { $Obj.$Name } else { $Default }
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
    $s = if ($v -is [hashtable] -or $v -is [pscustomobject]) { $v | ConvertTo-Json -Compress -Depth 4 } else { [string]$v }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 3) + '...' }
    $s
}

function Get-ManagedState {
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
    $Cur.valueExists -and $Cur.kind -eq $Step.valueType -and ([string]$Cur.value -eq [string]$Step.value)
}

function Set-Reg($Step) {
    if (-not (Test-Path -LiteralPath $Step.path)) { New-Item -Path $Step.path -Force -WhatIf:$false | Out-Null }
    $v = if ($Step.valueType -eq 'DWord') { [int]$Step.value } else { [string]$Step.value }
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
    $created = @($Rec.createdKeys)
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

# Natively implemented 'command' tweaks: snapshot-able get/set pairs. Catalog command strings are never run.
$NativeCommands = @{
    'pwr-balanced-plan'           = @{
        Desired = '381b4222-f694-41f0-9685-ff5bb260df2e'
        Get     = { $o = & powercfg.exe /getactivescheme; if ("$o" -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $Matches[1].ToLower() } else { $null } }
        Set     = { param($v) & powercfg.exe /setactive $v | Out-Null; if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive $v failed" } }
    }
    'perf-ntfs-lastaccess'        = @{
        Desired = '1'
        Get     = { $o = & fsutil.exe behavior query disablelastaccess 2>$null; if ("$o" -match '=\s*(\d+)') { $Matches[1] } else { $null } }
        Set     = { param($v) & fsutil.exe behavior set disablelastaccess $v | Out-Null; if ($LASTEXITCODE -ne 0) { throw "fsutil set disablelastaccess $v failed" } }
    }
    'sec-powershell-remotesigned' = @{
        Desired = 'RemoteSigned'
        Get     = { [string](Get-ExecutionPolicy -Scope LocalMachine) }
        Set     = { param($v) Set-ExecutionPolicy -ExecutionPolicy $v -Scope LocalMachine -Force -WhatIf:$false }
    }
}

#endregion

#region planning -------------------------------------------------------------

function Get-Steps($Tweak) {
    $imp = $Tweak.implementation
    if ($imp -is [string]) { return @([pscustomobject]@{ type = 'unsupported'; text = $imp }) }
    if ($imp.type -eq 'multi') { return @($imp.steps) }
    @($imp)
}

# Expands a tweak into concrete step records with current state, desired state and a planned action.
function Get-Plan($Tweak, $Managed) {
    $recs = @()
    $base = @{ tweakId = $Tweak.id; category = $Tweak.category }

    if ($EngineHandledIds -contains $Tweak.id) {
        return @([pscustomobject]($base + @{ type = 'engine'; target = 'restore point'; current = $null; desired = $null; action = 'Skip'; reason = 'handled by the engine (-NoRestorePoint to disable)' }))
    }
    if (-not $IncludeUnverified -and (Get-Prop $Tweak 'verification') -eq 'new-unverified') {
        return @([pscustomobject]($base + @{ type = 'policy'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = 'unverified new tweak; use -IncludeUnverified' }))
    }
    if ($Managed -and (($ManagedSkipCategories -contains $Tweak.category) -or ($ManagedSkipIds -contains $Tweak.id))) {
        return @([pscustomobject]($base + @{ type = 'policy'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = 'managed device: conflicts with organisation policy' }))
    }

    $i = 0
    foreach ($s in (Get-Steps $Tweak)) {
        $i++
        switch ($s.type) {
            'registry' {
                $cur = Get-RegState $s.path $s.name
                $ok = Test-RegDesired $cur $s
                $recs += [pscustomobject]($base + @{ type = 'registry'; target = "$($s.path)\$($s.name)"; path = $s.path; name = $s.name; valueType = $s.valueType; value = $s.value
                        current = $(if ($cur.valueExists) { "$($cur.value) ($($cur.kind))" } else { $null }); desired = "$($s.value) ($($s.valueType))"
                        before = $cur; action = $(if ($ok) { 'InSync' } else { 'Change' }); reason = '' })
            }
            'service' {
                $cur = Get-SvcState $s.name
                if (-not $cur) { $recs += [pscustomobject]($base + @{ type = 'service'; target = $s.name; current = $null; desired = $s.startType; action = 'Skip'; reason = 'service not present' }); continue }
                $recs += [pscustomobject]($base + @{ type = 'service'; target = $s.name; name = $s.name; startType = $s.startType; current = $cur.startType; desired = $s.startType
                        before = $cur; action = $(if ($cur.startType -eq $s.startType) { 'InSync' } else { 'Change' }); reason = '' })
            }
            'task' {
                $tasks = @(Get-TaskList $s)
                if ($tasks.Count -eq 0) { $recs += [pscustomobject]($base + @{ type = 'task'; target = "$($s.path)$($s.name)"; current = $null; desired = 'Disabled'; action = 'Skip'; reason = 'task not present' }); continue }
                foreach ($t in $tasks) {
                    $state = [string]$t.State
                    $recs += [pscustomobject]($base + @{ type = 'task'; target = "$($t.TaskPath)$($t.TaskName)"; taskPath = $t.TaskPath; taskName = $t.TaskName; current = $state; desired = 'Disabled'
                            before = @{ state = $state }; action = $(if ($state -eq 'Disabled') { 'InSync' } else { 'Change' }); reason = '' })
                }
            }
            'command' {
                if ($NativeCommands.ContainsKey($Tweak.id)) {
                    $h = $NativeCommands[$Tweak.id]
                    $cur = try { & $h.Get } catch { $null }
                    $action = if ($null -eq $cur) { 'Skip' } elseif ([string]$cur -eq [string]$h.Desired) { 'InSync' } else { 'Change' }
                    $recs += [pscustomobject]($base + @{ type = 'native'; target = $Tweak.id; current = $cur; desired = $h.Desired; before = @{ value = $cur }; action = $action
                            reason = $(if ($null -eq $cur) { 'could not read current state (needs admin?)' } else { '' }) })
                } else {
                    $recs += [pscustomobject]($base + @{ type = 'command'; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = 'command not implemented natively (catalog strings are never executed)' })
                }
            }
            'appx' {
                $names = @($s.names)
                $found = @(foreach ($n in $names) { Get-AppxPackage -Name $n -ErrorAction SilentlyContinue })
                if ($found.Count -eq 0) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); current = 'not installed'; desired = 'removed'; action = 'InSync'; reason = '' }); continue }
                if (-not $AllowIrreversible) { $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); current = ($found.Name -join ','); desired = 'removed'; action = 'Skip'; reason = 'no exact undo; use -AllowIrreversible' }); continue }
                $recs += [pscustomobject]($base + @{ type = 'appx'; target = ($names -join ','); names = $names; current = ($found.Name -join ','); desired = 'removed'
                        before = @{ packages = @($found | ForEach-Object { $_.PackageFullName }) }; action = 'Change'; reason = 'irreversible: reinstall from Microsoft Store' })
            }
            default {
                $recs += [pscustomobject]($base + @{ type = [string]$s.type; target = $Tweak.id; current = $null; desired = $null; action = 'Skip'; reason = "unsupported step type '$($s.type)'" })
            }
        }
    }
    $recs
}

#endregion

#region apply / undo ---------------------------------------------------------

function Invoke-Step($Rec) {
    switch ($Rec.type) {
        'registry' {
            $Rec | Add-Member -NotePropertyName createdKeys -NotePropertyValue @(Get-MissingKeys $Rec.path) -Force
            Set-Reg $Rec
            Test-RegDesired (Get-RegState $Rec.path $Rec.name) $Rec
        }
        'service' { Set-SvcStart $Rec.name $Rec.startType; (Get-SvcState $Rec.name).startType -eq $Rec.startType }
        'task' { Disable-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName -WhatIf:$false | Out-Null; [string](Get-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName).State -eq 'Disabled' }
        'native' { $h = $NativeCommands[$Rec.tweakId]; & $h.Set $h.Desired; [string](& $h.Get) -eq [string]$h.Desired }
        'appx' {
            foreach ($n in $Rec.names) {
                Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction Continue -WhatIf:$false
                Get-AppxProvisionedPackage -Online | Where-Object DisplayName -Like $n | Remove-AppxProvisionedPackage -Online -ErrorAction Continue -WhatIf:$false | Out-Null
            }
            -not @(foreach ($n in $Rec.names) { Get-AppxPackage -Name $n -ErrorAction SilentlyContinue }).Count
        }
        default { throw "cannot apply step type $($Rec.type)" }
    }
}

function Undo-Step($Rec) {
    switch ($Rec.type) {
        'registry' { Restore-Reg $Rec }
        'service' { Set-SvcStart $Rec.name $Rec.before.startType }
        'task' { if ($Rec.before.state -ne 'Disabled') { Enable-ScheduledTask -TaskPath $Rec.taskPath -TaskName $Rec.taskName -WhatIf:$false | Out-Null } }
        'native' { & $NativeCommands[$Rec.tweakId].Set $Rec.before.value }
        'appx' { throw "AppX removal cannot be undone automatically; reinstall from Microsoft Store: $($Rec.before.packages -join ', ')" }
        default { throw "cannot undo step type $($Rec.type)" }
    }
}

function New-RestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $orig = Get-RegState $key 'SystemRestorePointCreationFrequency'
    try {
        # Windows silently skips a new point if one exists from the last 24 h; lift that for this call only.
        New-ItemProperty -LiteralPath $key -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force -WhatIf:$false | Out-Null
        $before = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue).Count
        $cmd = "Checkpoint-Computer -Description 'DebloatKit $($script:RunId)' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop"
        if ($PSVersionTable.PSEdition -eq 'Core') {
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $cmd
            if ($LASTEXITCODE -ne 0) { throw 'Checkpoint-Computer failed (is System Protection enabled on C:?)' }
        } else { Invoke-Expression $cmd }
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

function Test-SidMismatch {
    # True when -ExpectedSid was given and this process runs as another user.
    if (-not $ExpectedSid) { return $false }
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $ExpectedSid
}

# ---- Undo ----
if ($PSCmdlet.ParameterSetName -eq 'Undo') {
    if (-not $script:DryRun -and -not (Test-Elevated)) { Exit-WithError 'Undo requires an elevated (Run as administrator) PowerShell.' }
    $file = if ($Undo -eq 'latest') { Get-ChildItem -LiteralPath $StateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName } else { $Undo }
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { Exit-WithError "No snapshot found ('$Undo' in $StateDir)." }
    $state = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    $script:LogFile = Join-Path $StateDir "undo-$($script:RunId).log.jsonl"
    $todo = @($state.steps | Where-Object { $_.result -in 'Applied', 'Verified', 'Unverified' })
    [array]::Reverse($todo)
    if ((Test-SidMismatch) -and @($todo | Where-Object { $_.type -eq 'registry' -and $_.path -match '^(HKCU:|HKEY_CURRENT_USER)' }).Count) {
        Exit-WithError 'This process runs as a different user than the one who started the GUI (UAC used other credentials), so per-user (HKCU) steps would be restored in the wrong user hive. Nothing was reverted. Run the undo from an elevated prompt as the signed-in user.'
    }
    Write-Host "Reverting $($todo.Count) step(s) from $file" -ForegroundColor Cyan
    $failed = 0
    $rows = foreach ($r in $todo) {
        if ($script:DryRun) { $res = 'WouldRevert'; $err = '' }
        else {
            try { Undo-Step $r; $res = 'Reverted'; $err = '' } catch { $res = 'Failed'; $err = $_.Exception.Message; $failed++ }
            Write-RunLog @{ mode = 'undo'; tweak = $r.tweakId; target = $r.target; result = $res; error = $err }
        }
        [pscustomobject]@{ Tweak = $r.tweakId; Target = $r.target; RestoredTo = (Format-Val $r.current); Result = $res; Error = $err }
    }
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    if (-not $script:DryRun) { Move-Item -LiteralPath $file -Destination ($file -replace '\.json$', '.reverted.json') -Force -WhatIf:$false }
    if ($failed) { exit 2 }
    exit 0
}

# ---- List / Apply ----
if ($EnabledPresets -notcontains $Preset) { Exit-WithError "Preset '$Preset' is not enabled in this version. Enabled: $($EnabledPresets -join ', ')." }
if (-not (Test-Path -LiteralPath $CatalogPath)) { Exit-WithError "Catalog not found: $CatalogPath" }
$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
    Send-Warning ("Managed device detected (Entra joined: {0}, domain joined: {1}, MDM enrolled: {2}{3}). Policy keys may conflict with your organisation's settings; update and time-sync tweaks are skipped. Check with your IT admin before applying." -f `
            $managed.AzureAdJoined, $managed.DomainJoined, $managed.MdmEnrolled, $(if ($managed.Tenant) { ", tenant: $($managed.Tenant)" } else { '' }))
}

$plan = @(foreach ($t in $tweaks) { Get-Plan $t $isManaged })

if ($List) {
    $byTweak = $plan | Group-Object tweakId
    $rows = foreach ($g in $byTweak) {
        $acts = @($g.Group.action)
        $status = if ($acts -contains 'Change') { if ($acts -contains 'InSync') { 'Partial' } else { 'NotApplied' } } elseif ($acts -contains 'InSync') { 'Applied' } else { 'Skipped' }
        $t = $tweaks | Where-Object id -EQ $g.Name | Select-Object -First 1
        [pscustomobject]@{ Id = $g.Name; Category = $t.category; Status = $status; Steps = $acts.Count; Eff = [int](Get-Prop $t 'effectiveness' 0); Note = (@($g.Group.reason | Where-Object { $_ }) | Select-Object -Unique) -join '; ' }
    }
    $sorted = if ($SortBy -eq 'effectiveness') { @($rows) | Sort-Object @{ Expression = 'Eff'; Descending = $true }, Category, Id } else { @($rows) | Sort-Object Category, Id }
    if ($AsJson) {
        $out = foreach ($r in $sorted) {
            $t = $tweaks | Where-Object id -EQ $r.Id | Select-Object -First 1
            [ordered]@{ id = $r.Id; category = $r.Category; preset = $t.preset; status = $r.Status; steps = $r.Steps; note = $r.Note
                effectiveness = $r.Eff; evidenceQuality = (Get-Prop $t 'evidenceQuality' 'none'); verification = (Get-Prop $t 'verification' '') }
        }
        $doc = [ordered]@{
            managed = [ordered]@{ isManaged = [bool]$isManaged; azureAdJoined = $managed.AzureAdJoined; domainJoined = $managed.DomainJoined; mdmEnrolled = $managed.MdmEnrolled; tenant = $managed.Tenant }
            tweaks  = @($out)
        }
        Write-Output ($doc | ConvertTo-Json -Depth 6)
        exit 0
    }
    $sorted | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    $sum = $rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("{0} tweaks in preset '{1}': {2}" -f @($rows).Count, $Preset, ($sum -join ', '))
    exit 0
}

if ($AsJson -and -not $script:DryRun) { Exit-WithError '-AsJson needs -List or -WhatIf (it describes a plan; it does not apply one).' }

# Apply (or -WhatIf preview)
if (-not $script:DryRun) {
    if (-not (Test-Elevated)) { Exit-WithError 'Applying tweaks requires an elevated (Run as administrator) PowerShell. Use -List or -WhatIf to preview.' }
    if ($isManaged -and -not $Force) { Exit-WithError 'Managed device: re-run with -Force to apply anyway (see warning above).' }
}

$changes = @($plan | Where-Object action -EQ 'Change')
Write-Info ("Preset '{0}': {1} tweaks, {2} steps -> {3} to change, {4} already in effect, {5} skipped" -f $Preset, $tweaks.Count, $plan.Count, $changes.Count, @($plan | Where-Object action -EQ 'InSync').Count, @($plan | Where-Object action -EQ 'Skip').Count) Cyan

if ($script:DryRun -and $AsJson) {
    $items = @(foreach ($p in $plan) { [ordered]@{ tweakId = $p.tweakId; type = $p.type; target = $p.target; current = $(if ($null -ne $p.current) { [string]$p.current } else { $null }); desired = $(if ($null -ne $p.desired) { [string]$p.desired } else { $null }); action = $p.action; reason = $p.reason } })
    Write-Output (ConvertTo-Json -InputObject $items -Depth 4)
    exit 0
}

if ($script:DryRun) {
    $plan | Where-Object action -NE 'InSync' | Sort-Object action, tweakId |
        Select-Object @{n = 'Action'; e = { $_.action } }, @{n = 'Tweak'; e = { $_.tweakId } }, @{n = 'Target'; e = { $_.target } }, @{n = 'Current'; e = { Format-Val $_.current } }, @{n = 'Desired'; e = { Format-Val $_.desired '' } }, @{n = 'Reason'; e = { $_.reason } } |
        Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host
    Write-Host 'WhatIf: nothing was changed and nothing was written to disk.' -ForegroundColor Yellow
    exit 0
}

if ($changes.Count -eq 0) { Write-Host 'Nothing to change.'; exit 0 }

if ((Test-SidMismatch) -and @($changes | Where-Object { $_.type -eq 'registry' -and $_.path -match '^(HKCU:|HKEY_CURRENT_USER)' }).Count) {
    Exit-WithError 'This process runs as a different user than the one who started the GUI (UAC used other credentials), so per-user (HKCU) tweaks would be written to that other user''s hive and not to yours. Nothing was changed. Run from an elevated prompt as the signed-in user, or deselect the per-user tweaks.'
}

# Only now (after every refusal check) is anything written to disk.
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force -WhatIf:$false | Out-Null }
$script:LogFile = Join-Path $StateDir "run-$($script:RunId).log.jsonl"

if (-not $NoRestorePoint) {
    Write-Host 'Creating restore point...'
    try { New-RestorePoint; Write-RunLog @{ mode = 'apply'; event = 'restore-point'; result = 'ok' } }
    catch { Exit-WithError "Restore point failed: $($_.Exception.Message). Fix System Protection or use -NoRestorePoint." }
}

$statePath = Join-Path $StateDir "state-$($script:RunId).json"
$state = [ordered]@{ version = 1; runId = $script:RunId; computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; preset = $Preset; catalog = (Resolve-Path $CatalogPath).Path; steps = @() }
$failed = 0
foreach ($rec in $changes) {
    $rec | Add-Member -NotePropertyName result -NotePropertyValue 'Pending' -Force
    # Snapshot first, so a crash mid-step is still revertible.
    $state.steps += $rec
    Save-State $state $statePath
    try {
        $ok = Invoke-Step $rec
        $rec.result = if ($ok) { 'Verified' } else { 'Unverified' }
        $err = ''
    } catch { $rec.result = 'Failed'; $err = $_.Exception.Message; $failed++ }
    Save-State $state $statePath
    Write-RunLog @{ mode = 'apply'; tweak = $rec.tweakId; target = $rec.target; before = $rec.current; desired = $rec.desired; result = $rec.result; error = $err }
}

$changes | Select-Object @{n = 'Tweak'; e = { $_.tweakId } }, @{n = 'Target'; e = { $_.target } }, @{n = 'Before'; e = { Format-Val $_.current } }, @{n = 'After'; e = { Format-Val $_.desired } }, @{n = 'Result'; e = { $_.result } } |
    Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host
Write-Host "Snapshot: $statePath"
Write-Host "Undo with: .\DebloatKit.ps1 -Undo latest"
Write-Host 'Some changes (Explorer, policies, Fast Startup) take effect after sign-out or restart.'
if ($failed) { exit 2 }
exit 0

#endregion
