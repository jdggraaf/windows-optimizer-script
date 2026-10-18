# DebloatKit

A reversible Windows 11 debloat engine driven by `tweak-catalog.json`. The catalog was built from research into ReviOS, AtlasOS, Tiny11, Chris Titus winutil, Win11Debloat and privacy tools (O&O ShutUp10++, privacy.sexy, Sophia Script). See [RESEARCH.md](RESEARCH.md) for the findings and sources.

Only the **`safe`** preset (64 tweaks) is enabled. The catalog also holds `balanced`, `aggressive` and `never-default` tweaks, but the engine refuses to run them in this version.

## Quick start

```powershell
.\DebloatKit.ps1 -List      # what is already in effect (read-only)
.\DebloatKit.ps1 -WhatIf    # what would change; writes nothing, no admin needed
.\DebloatKit.ps1            # apply (elevated PowerShell)
.\DebloatKit.ps1 -Undo latest
.\DebloatKit.ps1 -Revert id1,id2   # undo just those tweaks (admin)
.\DebloatKit.ps1 -Drift            # what did Windows change back? (read-only)
.\DebloatKit.ps1 -Drift -Reapply   # re-apply only the drifted tweaks (admin)
```

Apply only some tweaks with `-Only id1,id2`, or leave some out with `-Skip id1,id2`. Tweak ids are shown by `-List`.

Before an apply the engine runs a [preflight check](#preflight-checks) (pending reboot, Windows servicing, battery, disk space) and refuses with a clear reason when the machine is not in a good state. `-SkipPreflight` overrides it. `-List` and `-WhatIf` show the result without refusing.

## How it stays reversible

0. **Preflight** first: nothing is written (no state folder, no restore point) when a gate fails. See [Preflight checks](#preflight-checks).
1. **Restore point** before anything changes. The 24-hour limit is lifted for that one call, and the run aborts if no new point appears. Turn this off with `-NoRestorePoint`.
2. **Snapshot before every step** to `%ProgramData%\DebloatKit\state-<time>.json`. It records the registry value, or the fact that the value or key was absent, the service start type, the scheduled task state, the power plan, and so on. It also records the OS (`os`: edition, build, UBR, `BuildFull` such as `26200.1234`, display version, chassis) and the preflight result, so a later change can be tied to a Windows update. The file is saved before each change, so even a run that crashes partway can be undone.
3. **Verify after every step.** The new state is read back and the step is marked `Verified`, `Unverified` or `Failed`.
4. **`-Undo latest`** (never blocked by the preflight) restores the snapshot in reverse order. When Windows has been updated since the snapshot, it says which build the snapshot came from. It brings back the exact previous values, deletes values and keys the run created, and re-enables tasks it disabled. It does not reset to Windows defaults. A step that was interrupted (Ctrl-C, power loss: result `Pending`) or that failed part-way (`Failed`) is restored to its before-state too, because that restore is idempotent; the row is marked "restore of an interrupted step". The snapshot is renamed `*.reverted.json` only when no step failed to revert; after a failure (for example a capability that needs Windows Update or Features on Demand) the steps that did revert are marked in the snapshot, the file stays, and a second `-Undo latest` retries only the failed ones. AppX removals and one-shot native changes cannot be undone: they are reported as `NotRevertible` (exit 2) and do not keep the snapshot alive. Steps that `-Revert` already undid are skipped. Snapshots are written to a temp file and swapped in, so a crash never leaves a truncated undo record. To undo single tweaks instead of a whole run, see [Revert one tweak and drift detection](#revert-one-tweak-and-drift-detection).
5. **Log** of every step as JSON lines in `run-<time>.log.jsonl` (and `undo-<time>.log.jsonl` for undo runs).

## Safety rules in the engine

- **Catalog command strings are never executed.** Only an allowlist of command tweaks is implemented natively, each with a snapshot and an exact undo: see [Native disk and system handlers](#native-disk-and-system-handlers). They reach their tools through `Invoke-Tool`, so tests and `-Lint` can swap in a fake. The others are skipped with a reason.
- **AppX removal and the component store cleanup are skipped** unless you pass `-AllowIrreversible`, because they have no exact undo (you reinstall apps from the Store; removed component versions are gone). AppX removal is at least recoverable: a reinstall manifest is saved in the snapshot, see [Capabilities, optional features and AppX profiles](#capabilities-optional-features-and-appx-profiles).
- **Managed devices** (Entra ID joined, domain joined or MDM enrolled) show a warning, and applying needs `-Force`. Tweaks that carry a `managedSkip` reason in the catalog (updates, time sync, DiagTrack and its autologgers, Delivery Optimization, reserved storage, Office telemetry tasks, dmwappushservice, diagnostic log limits) are skipped on these devices even with `-Force`. See [Managed-device skip list](#managed-device-skip-list).
- **Browser policies** (Chrome and Edge memory tweaks) are written to HKLM policy keys under `Software\Policies`. On managed devices they may conflict with Intune or Group Policy, which can overwrite them or lock the setting; the managed-device guard above applies to them as well.
- **Protected targets are never changed.** The engine has its own denylist (see [Protected targets](#protected-targets)); a catalog step that touches one is skipped with `protected target: <reason> (not supported by design)`, whatever the preset.
- **A failing step follows its error policy** (`continue`, `stop-tweak` or `abort-run`); see [Step policy](#step-policy-order-error-handling-weight).
- Applying needs an elevated PowerShell. `-List` and `-WhatIf` don't.
- Steps that are already at the desired value are left alone, so it is safe to run again.

## GUI

```powershell
.\DebloatKit-GUI.ps1            # opens the window (Windows PowerShell 5.1 or PowerShell 7)
.\DebloatKit-GUI.ps1 -SelfTest  # no window: loads XAML + data, tests filter/sort/select, the per-row toggle, profiles, drift and footprint tabs, prints counts and the top 10, exit 0 = pass
```

The GUI is a front end only. It never writes the registry or services; every change goes through `DebloatKit.ps1` in a separate process. If the thread is not STA it relaunches itself with `-STA`. Besides the tweak grid it has a per-row Apply / Revert toggle, a Profiles tab (setup questions), a Drift tab and a Footprint tab, described after this list.

- **Data**: runs `DebloatKit.ps1 -List -AsJson -IncludeUnverified` in a child process (no admin needed, off the UI thread, "Loading..." overlay) and joins it with `tweak-catalog.json` for the explanations. All 156 catalog entries are shown.
- **Layout**: filters on the left (search, category, preset, risk, status, "Only proven (evidence strong/mixed)", group and sort), the tweak grid in the middle (checkbox, name/id, category, 0-5 stars, evidence badge, preset/risk badge, status, "unverified" badge), and a detail pane on the right. The default view is grouped and sorted **most effective first**. The panes are resizable.
- **Detail pane**: plain explanation, measured effect, who benefits, trade-off, what it can break, the exact changes (implementation steps), how it is reverted, and evidence links that open in your default browser.
- **Banner**: managed-device warning from the engine (Entra / domain / MDM, tenant), whether the GUI is elevated, and a second line with the Windows build (`26200.1234`, edition, laptop or desktop) and the preflight verdict. When a gate fails, a checkbox "Apply anyway although the preflight check fails (adds `-SkipPreflight`)" appears next to the managed-device one; without it **Apply selected** explains the failing gate instead of starting.
- **Presets other than safe** are listed, but their checkboxes are disabled ("Preset not enabled in this version"). Unverified tweaks are never checked by default and carry a purple badge. Tweaks the engine would skip (status Skipped) cannot be ticked either.
- **Select recommended** ticks tweaks that are safe preset, effectiveness 2 or higher, evidence not "none", not unverified, and not already applied. **Clear** unticks everything.
- **Preview changes** runs the engine with `-WhatIf -AsJson -Only <ids>` and shows the plan in a table. It writes nothing.
- **Apply selected** always asks for confirmation first (lists the ids and the restore-point note), then starts an elevated engine process (UAC) with `-Only <ids>`. `-Force` is added only when the device is managed **and** you ticked "I understand this is a managed device"; `-IncludeUnverified` is added only when you selected an unverified tweak. The exit code and engine output are shown afterwards and the list refreshes. While the elevated run is going, the loading overlay shows a determinate progress bar driven by the engine's weighted `[progress] NN%` lines. The preview shows the total weight of the steps that would change.
- **Undo last run** asks for confirmation, then runs the elevated engine with `-Undo latest`. **Refresh** reloads the status. **Open log folder** opens `%ProgramData%\DebloatKit`.

The detail pane also shows "Skipped on managed devices" with the catalog's reason, and the grid shows the engine's note (for example the AllowTelemetry edition note). The GUI reads both catalog formats (see below).

The effectiveness score (0-5) comes from the catalog and is based on measured evidence only. A 0 means no measurable speed gain was found, not that the tweak is harmful or useless (many are privacy tweaks).

The window has four tabs. **Tweaks (advanced)** is the grid described above; **Profiles**, **Drift** and **Footprint** are described below. The action bar (select / preview / apply / undo, the managed-device and preflight ticks) stays visible on every tab.

### Per-row Apply / Revert toggle

Every row of the grid has a **Toggle** button, and the detail pane has the same action ("Apply this tweak" / "Revert this tweak"). It runs the engine for exactly that tweak, so you can change one thing at a time and measure it (`Get-BootReport.ps1`, `Get-MemoryPressure.ps1`, the Footprint tab).

- **Apply** (not applied or partly applied): the same path as **Apply selected** with one id: confirmation dialog, managed-device tick, preflight gate (the failing gates are listed), `-IncludeUnverified` only for an unverified tweak, elevated engine process with `-Only <id>`.
- **Revert** (applied): confirmation dialog, then the elevated engine runs `-Revert <id>`. It restores what DebloatKit saved before it changed the tweak and marks those steps reverted in the snapshot; other tweaks stay as they are. The revert command carries only `-Revert`, `-ExpectedSid` and the path parameters, because the Revert parameter set accepts nothing else; it is never blocked by the preflight check or the managed-device check, so no tick is needed.
- **Revert is only offered when there is something to restore.** `-List` shows `Applied` when the live value equals the desired one, which is also true for a Windows default DebloatKit never touched. The GUI reads `-Drift -AsJson` after every load; the tweaks in that document are the ones with a snapshot record, and only those get an enabled Revert. An applied tweak without a record shows a disabled button with the reason ("DebloatKit did not apply it (no snapshot)"). While the drift data is not loaded yet, Revert stays enabled and the engine decides.
- **Skipped** tweaks show a disabled button whose tooltip is the engine's reason, and the status column shows the reason under the status (managed-device skip, "task not present", edition or build not applicable, handled by the engine). The detail pane repeats it under "Why the engine skips it here". Presets that are not enabled have no button.
- Partly applied tweaks get **Apply** in the grid and both **Apply this tweak** and **Revert this tweak** in the detail pane.

The preflight line in the banner has a tooltip with every gate and its detail (`[ok]` / `[BLOCKED]`), and the same list is shown at the bottom of the Profiles plan.

### Profiles tab

A short setup instead of 156 rows. Choose a starting profile (a managed device starts on `work-managed`, a laptop on `personal-laptop`, everything else on `personal-desktop`), answer a few questions, and the tab shows what that means. **Tick these tweaks in the Tweaks tab** selects exactly the resolved tweaks in the grid; nothing is applied until you press **Apply selected**, and you can preview with `-WhatIf` first.

| Question | Effect |
|---|---|
| Work or managed PC? | `work-managed`: only safe tweaks with effectiveness 2 or more, no app removal (forced off), no hibernation, power plan or component-cleanup changes. Detected from the device when the profile leaves it open. |
| Gaming PC? | Adds the per-user Game DVR / app capture switch and the performance power plan. |
| Laptop? | Keeps Fast Startup, hibernate and the power plan; plans the reduced hibernation file instead of removing it. Detected from the chassis. |
| Keep Xbox and the gaming overlay apps? / Keep Phone Link? | Only matter with app removal: "no" plans the Xbox or Phone Link AppX removal tweak. |
| Also remove preinstalled consumer apps (AppX)? | Plans the `keep-personal` AppX profile (`keep-work` on a work PC) from `appx-profiles.json`. Needs a tick "I understand these apps must be reinstalled from the Store (no exact undo)" before the profile can be selected. |

How it resolves: the safe tweaks at or above the profile's minimum effectiveness (2 for `work-managed`, 1 for the personal profiles), plus the profile's own tweak list (`optionProfiles` in `appx-profiles.json`), plus the answers, minus the answers' removals. The result is sorted into: **selected** (ticked), already in effect, skipped by the engine on this device (with the reason), unverified (listed, never ticked), in a **preset that is not enabled in this version** (listed with a note, never ticked: today the balanced and aggressive entries such as the hibernation, power plan, component cleanup and AppX tweaks), and left out because of your answers. The engine's preset gate stays authoritative, so a profile cannot enable anything the engine refuses. Because only `safe` runs in this version, a profile effectively ticks safe tweaks only; the AppX keep profile is a plan that the GUI shows but never runs (app removal needs `-AllowIrreversible`, which this GUI never passes).

`profiles.json` holds the four profiles (their defaults and minimum effectiveness) and the questions with their effects as data (`addIds`, `removeIds`, `force`, `requiresAppx`, `requiresAck`), so nothing is hard-coded in the handlers. The tweak lists per profile are the `optionProfiles` of `appx-profiles.json`. `-SelfTest` and `tests\Test-Engine.ps1` check that every id exists in the catalog, that no profile contains a `never-default` or `reduces-security` tweak, and that `work-managed` never plans app removal or anything outside the safe set.

### Drift tab

Runs `DebloatKit.ps1 -Drift -AsJson -IncludeUnverified` (read-only, no admin) and shows one row per tweak DebloatKit applied: in effect, drifted (Windows or something else changed it back) or not comparable, with the Windows build it was applied on, notes ("no longer in the catalog", "no longer applicable on this build") and, for the selected tweak, each step with the applied and the current value. A banner says when Windows changed the build since the tweaks were applied. With nothing applied yet the tab says so instead of showing an error.

- **Check drift now** reads it again. The tab loads the first time it is opened.
- **Preview re-apply** runs `-Drift -Reapply -WhatIf -AsJson` and shows the plan (or why nothing is eligible). It writes nothing.
- **Re-apply drifted** (enabled only when something drifted) asks for confirmation, then runs the elevated engine with `-Drift -Reapply -IncludeUnverified`, plus `-Force` and `-SkipPreflight` under the same ticks as Apply. The engine re-applies only the drifted tweaks that are still in the catalog, in the enabled preset and applicable to this build, through the normal apply path (preflight, restore point, snapshot, verify).
- **Revert selected tweak** runs the per-tweak revert for the selected row.

### Footprint tab

Uses `Get-FootprintReport.ps1` (read-only, no admin; the GUI runs it unelevated, so provisioned AppX and the WinSxS analysis are not measured there).

- The banner shows **process, service, AppX and disk numbers** ("Footprint now: 467 processes, 139 of 299 services running, 117 AppX packages (45 provisioned), C: 48.8 GB free of 293.3 GB") and, when a report from before the last run exists, "Since before the last run: processes -12, services running -3, AppX -9, free disk +1.2 GB".
- Before every elevated Apply, Revert, Undo or Re-apply the GUI saves a report as `footprint-before-last-run.json` (about two seconds, read-only measurement) so the banner and the tab can show what the run changed. After the run the footprint is measured again.
- **Measure now** shows the current numbers. **Save as baseline** stores a report as `footprint-baseline.json` (asks before replacing). **Compare** measures now and compares with the chosen report (the baseline or "before the last run"): each metric with before, now, change and a better / worse / same verdict, plus changes of Compact OS, reserved storage, OS build and edition and the tool's warnings.
- Both files live in `%LOCALAPPDATA%\DebloatKit` (never in `%ProgramData%\DebloatKit` or the Windows folder, which the tool refuses) and are only written when you apply something or press **Save as baseline**. Process and memory numbers move by themselves; treat small differences as noise, and compare after a restart for anything that matters.

### Test-only parameters

`-StateDir`, `-TestEnvironment` and `-ProfilesPath` are passed on to every engine call; with `-SelfTest -TestEnvironment <file>` the GUI runs a sandbox self-test (GUI-built `-Revert`, `-Drift`, `-Drift -Reapply -WhatIf` against a throwaway state folder). `-SetupProfilesPath`, `-FootprintScriptPath` and `-FootprintDir` point at `profiles.json`, `Get-FootprintReport.ps1` and the folder for the baseline files.

## Catalog format, managed-device skips, edition notes and migrations

`tweak-catalog.json` is a versioned document:

```json
{ "schemaVersion": 2, "catalogVersion": "2026.10.17.1", "migrations": [ ... ], "tweaks": [ ... ] }
```

- **`schemaVersion`** is the file format. Version 1 was a bare JSON array. The engine reads both: an older catalog is migrated in memory (`ConvertTo-CurrentCatalog`, one step per version), a newer one is refused with a clear message. The v1 to v2 step adds the managed-device skips that v1 engines hard-coded (the `updates` category and `net-ntp-pool`), so a custom v1 catalog keeps behaving the same. Every snapshot records `catalogSchemaVersion`, `catalogVersion`, the OS (`os.EditionId`, `Build`, `Ubr`, `BuildFull`, `DisplayVersion`, `Chassis`) and the preflight result (`preflight.skipped`, `blocked` and each check).
- **`catalogVersion`** is the content version (date and counter). Quote it in bug reports.

### Managed-device skip list

A tweak with `"managedSkip": "reason"` is skipped on an Entra joined, domain joined or MDM enrolled device, even with `-Force`. The reason is shown in the plan, in `-List` (`note`, plus `managedSkip` in `-List -AsJson`) and in the GUI detail pane. The engine has no id list of its own. Currently skipped there:

| Tweak | Why |
|---|---|
| `svc-diagtrack-disable`, `priv-firewall-block-diagtrack`, `priv-autologgers-off` | DiagTrack and its autologgers feed Intune Endpoint analytics, Windows Update reports and Autopatch |
| `net-delivery-optimization-off`, `net-do-monthly-upload-cap`, `net-do-background-bandwidth-pct` | Intune configures Delivery Optimization (peering, Connected Cache) |
| `perf-reserved-storage-off` | Reserved storage keeps feature updates from failing on a full disk |
| `task-office-telemetry-off` | Microsoft 365 Apps are managed by IT |
| `svc-dmwappushservice-disable` (aggressive) | dmwappushservice routes MDM push messages; disabling it breaks Intune sync |
| `telemetry-limit-collection` (balanced) | Limits the diagnostic logs and dumps IT can collect |
| every `updates` tweak, `net-ntp-pool` | Update rings and time sync belong to the organisation |

### Edition, build and chassis rules (`appliesTo`)

```json
"appliesTo": { "editions": ["Enterprise*", "Education*"], "notEditions": [], "minBuild": 0, "maxBuild": 0,
               "requiresLaptop": false, "requiresDesktop": false,
               "onMismatch": "skip", "reason": "text shown to the user" }
```

`editions` and `notEditions` are `-like` patterns on `EditionID`; `minBuild` and `maxBuild` compare `CurrentBuildNumber` (inclusive). `requiresLaptop` / `requiresDesktop` use the SMBIOS enclosure type (a battery is only a fallback; desktops with a UPS report one). A system whose chassis cannot be told (`Unknown`, for example some VMs) never fails them. The rules are evaluated in the plan, so `-List`, `-WhatIf` and the GUI all show `not applicable: ...`. With `onMismatch: "skip"` (the default) the tweak is skipped with `not applicable: <reason> (this system: edition ..., build ...)`. With `"note"` the tweak still runs and the reason is attached to every step, so the plan does not overstate the effect. `telemetry-allowtelemetry-policy` and `telemetry-datacollection-cv-policy` use `note`: `AllowTelemetry=0` is only honoured on Enterprise, Education and Server, while Pro and Business treat it as 1 (Required data). That is still a real reduction from the default, so the value is written but labelled.

### Migrations

`migrations` lists values an older catalog version set that are no longer recommended (the model of ReviOS's `revert.yml`). Each is `{ id, tweakId, path, name, valueType, oldValue, action: "restore-default" | "rewrite", newValue, reason }`.

```powershell
.\DebloatKit.ps1 -List               # prints "N value(s) set by an older DebloatKit version ..."; -AsJson has a migrations array
.\DebloatKit.ps1 -Migrate -WhatIf    # what would be reset or rewritten
.\DebloatKit.ps1 -Migrate            # apply (admin; -Force on a managed device); snapshot, verify and -Undo latest work as usual
```

A migration is only offered when the current value still equals `oldValue`, and a normal run never applies one. Shipped migration: `svchost-split-forced` (the removed `SvcHostSplitThresholdInKB=0xFFFFFFFF` entry; ReviOS itself ships the Windows default, so the migration deletes the value).

## Preflight checks

An apply refuses, before writing anything, when one of these is true. The result is reported by `-List` (text, and `preflight` plus `os` in `-List -AsJson`) and by `-WhatIf` (text); `-WhatIf -AsJson` stays a bare array of plan steps.

| Gate | Blocks when | Notes |
|---|---|---|
| `pending-reboot` | `Component Based Servicing\RebootPending` or `WindowsUpdate\Auto Update\RebootRequired` exists | `PendingFileRenameOperations` alone is only a warning: installers often leave it set |
| `servicing-idle` | the `TrustedInstaller` service or `TiWorker.exe` is running | Windows servicing (updates, features) is in progress |
| `ac-power` | a battery reports discharging, low or critical | a power loss mid-run leaves a half-applied state; desktops pass |
| `free-disk` | free space on the system drive is below 2048 MB (512 MB with `-NoRestorePoint`) | restore point storage and servicing need headroom |

`-SkipPreflight` applies anyway and prints a warning naming every failing gate; the snapshot records `preflight.skipped`. `-Undo` is never gated, so a revert is always possible. The checks read state only; they never change anything. Under `-TestEnvironment` they come from the file's `preflight` section (see [Tests](#tests)).

## Protected targets

The engine itself, not the catalog, keeps a denylist of things it never changes. They are skipped in the plan (`Skip`, reason `protected target: ... (not supported by design)`) and refused again right before a step would run:

- **Services**: `AppXSvc`, `ClipSVC`, `WaaSMedicSvc`, `TrustedInstaller`, the Defender services and drivers (`WinDefend`, `WdNisSvc`, `WdNisDrv`, `WdFilter`, `WdBoot`, `Sense`, `MDCoreSvc`), `SecurityHealthService`, `wscsvc`, `mpssvc`, `BFE`, and the update plumbing `wuauserv`, `UsoSvc`, `BITS`, `DoSvc`. A registry step under `...\Services\<one of these>` counts too.
- **Services Windows write-protects**: at plan time the service's registry key ACL is read. When no entry lets administrators write to it (for example `TrkWks`, `WdiServiceHost`, `RpcSs`), the step is skipped as protected instead of failing later with a generic "Access denied". The engine never takes ownership or runs as TrustedInstaller.
- **AppX packages**: Store (`Microsoft.WindowsStore`, `StorePurchaseApp`, `DesktopAppInstaller`), the framework packages other apps depend on (`VCLibs*`, `NET.Native*`, `UI.Xaml*`, `WindowsAppRuntime*`), WebView2, the Windows Security app and the shell and sign-in components (Start, shell experience host, lock screen, Settings). A wildcard step is expanded first; protected matches are dropped from what would be removed.
- **Scheduled tasks**: `WindowsUpdate`, `UpdateOrchestrator`, `WaaSMedic`, `Servicing`, `Windows Defender` and `SystemRestore` task folders.
- **Registry**: `DeviceGuard` and `CI` (VBS, HVCI, Smart App Control), `Lsa\LsaCfgFlags` / `RunAsPPL`, the Defender switches `DisableAntiSpyware`, `DisableAntiVirus`, `DisableRealtimeMonitoring`, `DisableBehaviorMonitoring`, `DisableIOAVProtection`, `DisableOnAccessProtection`, `TamperProtection`, the Windows Update policy values (`NoAutoUpdate`, `UseWUServer`, `WUServer`, `WUStatusServer`, `DisableWindowsUpdateAccess`, `DoNotConnectToWindowsUpdateInternetLocations`), the Windows Firewall policy and `EnableFirewall`, the UAC values (`EnableLUA`, `ConsentPromptBehaviorAdmin`/`User`, `PromptOnSecureDesktop`, `FilterAdministratorToken`), the SmartScreen switches and the BitLocker (`FVE`) policy. The image builder carries the same list and leaves such a value out of the image (`tests\Test-Engine.ps1` compares the two).

`-Lint` reports a catalog step on this list as an `error` in the `safe` preset and as `info` elsewhere (the never-default entries for Defender, VBS and Windows Update are therefore inert even if that preset is ever enabled).

## Step policy: order, error handling, weight

Any catalog step (the `implementation` object, or an entry of `steps` in a `multi`) may carry:

| Field | Values | Meaning |
|---|---|---|
| `onError` | `continue` (default), `stop-tweak`, `abort-run` | What a failed step does. `stop-tweak`: the remaining steps of the same tweak are not run (`NotRun`); steps that already ran stay applied and are in the snapshot. `abort-run`: nothing else runs (`Aborted`), exit code 2. |
| `order` | integer, default 100 | Execution order hint: lower runs first. Ties keep catalog order (tweak order, then step order), so a plan is always the same for the same catalog. The plan (`-WhatIf -AsJson`) is listed in execution order and reports `order`. |
| `weight` | integer >= 0 | Cost for progress display. Defaults: registry 1, service 2, task 2, native handler 3, AppX 20; a restore point counts 10. |

During an apply the engine prints `[progress] NN% - <tweak> <target>: <result>` lines weighted by these costs (also in the elevated window and in the log the GUI reads). `-WhatIf` reports the total ("Work to do: N weight unit(s) in M step(s)"), `-WhatIf -AsJson` adds `order`, `weight` and `onError` to every step, and `-List -AsJson` adds `weight` (what is still to do) to every tweak. Only `Verified`, `Applied` and `Unverified` steps are reverted by `-Undo`; `Failed`, `NotRun` and `Aborted` are left alone.

## Catalog lint

```powershell
.\DebloatKit.ps1 -Lint                  # read-only, no admin; exit 1 on errors
.\DebloatKit.ps1 -Lint -AsJson          # {errors, warnings, info, findings:[{severity,tweakId,rule,message}]}
.\tests\Lint-Catalog.ps1 [-CatalogPath x.json] [-ShowInfo]
```

It checks the engine and the catalog:

- **Every step type has a handler.** The engine's own source is parsed: each catalog step type must have a branch in `Get-Plan`, and each mutating plan type (`registry`, `service`, `task`, `native`, `appx`, `capability`, `optionalfeature`, `appxcheck`) must have one in `Invoke-Step` and in `Undo-Step`. `external` is documentation only.
- **Every native handler reads back what it writes.** Each handler in `$NativeCommands` runs against an in-memory fake of fsutil, powercfg, compact, dism, wevtutil, bcdedit, MMAgent and the execution policy: `Set(desired)` must change something, `Get` must then return the desired value, and the handler's undo must bring `Get` and **every** fake setting back to where it started (so an undo that leaves a created power plan behind fails). This catches a handler that verifies a different value than it writes. It never touches the system. Handlers reach external tools only through `Invoke-Tool`; a handler that makes a new kind of tool call must first teach `New-FakeToolHost` that call, or lint fails. Targeted handlers are linted with their `LintTarget`; irreversible handlers have no round trip, so lint requires a reason text, a non-`safe` preset and a catalog `revert` of `not reversible`.
- **Catalog rules:** unique valid ids, required fields, preset names, registry paths only `HKLM:` or `HKCU:` (no `.DEFAULT` hive, no IFEO `Debugger`), value types `DWord` or `String`, DWord values within 32 bits, task and service step fields, nothing in `safe` that is `reduces-security`, an `appx` step, `not reversible` or a command without undo, effectiveness above 1 only with a measured figure, and well-formed `managedSkip`, `appliesTo` (including `requiresLaptop` / `requiresDesktop` as booleans that are not both true, and `minBuild` not above `maxBuild`), step policy (`onError` one of the three values, `order` and `weight` integers) and `migrations`.
- **Protected targets** (rule `protected-target`): an error in `safe`, info elsewhere.
- **Native targets** (rule `native-target`): a command step for a targeted handler must name a `target` on the handler's allowlist (or `*` where the handler can expand it); a step for an untargeted handler must not have one.

## Native disk and system handlers

These catalog commands run natively, never as free-form strings. Each handler has separate read functions (safe to run at any time, tested live and read-only) and set functions (tested only against the fake tools). The snapshot records the exact state before the change, so `-Undo` puts that state back instead of a fixed default. They are all `balanced` or stricter: none is in `safe`, and the engine only enables `safe` for now, so today they are exercised by the tests and by a future preset switch.

| Catalog id | Preset | Reads | Changes | Undo | Skipped when |
|---|---|---|---|---|---|
| `disk-compactos-on` | balanced | `compact /CompactOS:query` (text, never the exit code: 102 means "not compact") | `compact /CompactOS:always` (10-30 min) | back to the observed state; a state Windows chose itself comes back as an explicit `never` | restart or servicing pending |
| `pwr-hibernate-off` | balanced | hibernation state `off` / `reduced` / `full` (power key `HibernateEnabled`, `HiberFileType`) | `powercfg /hibernate off` | the exact previous type (`/hibernate on`, then `/type`) | not a desktop (`appliesTo.requiresDesktop`): laptops keep hibernate |
| `pwr-hiberfile-reduced` | balanced | same | `powercfg /hibernate /type reduced` (about 40 % of RAM becomes about 20 %, Fast Startup stays) | previous type | hibernation is already off |
| `perf-reserved-storage-off` | balanced | `DISM /Online /Get-ReservedStorageState` (`ShippedWithReserves` as fallback) | `DISM /Online /Set-ReservedStorageState /State:Disabled` | recorded state | managed device (`managedSkip`); restart or servicing pending |
| `disk-component-cleanup` | balanced | nothing (constant; the ~1 minute `/AnalyzeComponentStore` runs around the cleanup instead) | `DISM /Online /Cleanup-Image /StartComponentCleanup` **without** `/ResetBase` | none: irreversible, needs `-AllowIrreversible`; `-Undo` reports it cannot be undone | restart or servicing pending (`0x800F0806`) |
| `perf-dism-cleanup-resetbase` | aggressive | none | not implemented natively; the engine never runs `/ResetBase` | none | always skipped |
| `pwr-ultra-performance-plan` | balanced | active scheme GUID, whether the DebloatKit plan exists | duplicates the Ultimate Performance scheme into the DebloatKit-owned GUID `deb10a7c-...-5a6b7c8d9e01` if missing, then `/setactive` | re-activates the prior scheme, deletes the plan only if this run created it | not a desktop |
| `perf-memory-compression-off` | balanced | `Get-MMAgent` | `Disable-MMAgent -MemoryCompression` | `Enable-MMAgent` if it was on | never skipped; the plan row carries a warning when the commit charge is 80 % or more |
| `perf-ntfs-8dot3-off` | balanced | `fsutil behavior query disable8dot3` | `fsutil behavior set disable8dot3 1` | the exact previous value (0, 1, 2 or 3) | none |
| `perf-ntfs-8dot3-volume-off` | balanced | `fsutil 8dot3name query <volume>` per fixed NTFS volume | `fsutil 8dot3name set <volume> 1` | previous value per volume | system-wide setting is not 2 (per-volume flags are ignored then) |
| `perf-sleepstudy-off` | balanced | `wevtutil gl <channel>` for the 3 Sleep Study channels | `wevtutil sl <channel> /e:false` | each channel's own previous state | none |
| `perf-bootmenu-legacy` | balanced | `bcdedit /enum {current}` (`bootmenupolicy`, or "absent") | `bcdedit /set {current} bootmenupolicy legacy` | the previous value, or `/deletevalue` when the element did not exist | BitLocker protection is on, or its state cannot be read (a boot configuration change can trigger the recovery key prompt) |

How a handler is described in `$NativeCommands` (the key is the tweak id): `Desired`, `Get`, `Set` (all required) and optional `Before` (extra facts to snapshot, such as "plan existed"), `Undo`, `Check` (returns `skip` or `note` with a reason; it runs only when a change is planned), `Verify`, `Metric` (measurements stored before and after), `Targeted` with `Allowed` / `AllowedPattern` / `Expand` / `LintTarget`, and `Irreversible` (the reason text). A catalog command step passes a target to a targeted handler as `"target": "<channel or volume or *>"`; an entry that is not on the allowlist is skipped, never run, so the catalog cannot smuggle an arbitrary argument into a command line.

Free disk space (and, for the component store cleanup, the `AnalyzeComponentStore` sizes) is measured before and after each disk step. It is printed as `measured: before ... | after ...`, written to the run log and saved in the snapshot, so the real gain is visible (Compact OS: Microsoft documents about 3.7-4.75 GB; the hibernation file: 40 % of RAM becomes about 20 %). Heavy steps carry a high `order` (reserved storage 200, Compact OS 300, component cleanup 310) so they run last, and a `weight` for the progress display.

Limits: the output of `compact`, `dism`, `fsutil`, `wevtutil` and `bcdedit` is parsed in English, like the existing fsutil handler; on another UI language a value reads as "could not read current state" and the step is skipped, not guessed. The 8.3 handlers do not strip short names that already exist. Compact OS cannot restore "Windows decided it is not beneficial" exactly (there is no such setting to write), so undo sets `never`.

## Capabilities, optional features and AppX profiles

Three catalog step types remove Windows components. Like the native handlers they read state first, snapshot it, change it through `Invoke-Tool` (so tests and `-Lint` can swap in a fake) and verify afterwards. None of them is in the `safe` preset (`-Lint` makes that an error), and today only `safe` is enabled, so they are exercised by the tests and by a future preset switch.

| Step type | Catalog fields | Reads | Changes | Undo |
|---|---|---|---|---|
| `capability` | `name`: the capability name before `~~~~` (for example `Microsoft.Windows.WordPad`; the version suffix differs per build, so it is never part of the catalog) | `Get-WindowsCapability -Online` (once per run, needs admin) | `Remove-WindowsCapability -Online -Name <full name>` | `Add-WindowsCapability` if it was `Installed`. **Conditional**: it needs Windows Update or Features on Demand media |
| `optionalfeature` | `name`: the feature name | `Get-WindowsOptionalFeature -Online` | `Disable-WindowsOptionalFeature -NoRestart`, never `-Remove`: the payload stays on disk | `Enable-WindowsOptionalFeature -NoRestart` if it was `Enabled`; works offline |
| `appx` | `names` and/or `profile` | `Get-AppxPackage`, `Get-AppxProvisionedPackage` | removal ladder, see below | none (see the reinstall manifest) |

Plan rules for capabilities and features: a name that does not exist in the inventory is a `Skip` ("not present on this edition or build", with an LTSC note on LTSC), an already removed or disabled one is `InSync`, a state with a pending restart is a `Skip`, and an unreadable inventory (not elevated) is the usual "could not read current state" `Skip`. Verification accepts `NotPresent` / `UninstallPending` and `Disabled` / `DisablePending`; a pending restart is recorded as `restartNeeded` on the step. Protected targets (kept in the engine, not the catalog): capabilities `Language.*` (typing, handwriting, OCR, speech) and the shell components; features `Windows-Defender*`, `Microsoft-Hyper-V*`, `VirtualMachinePlatform`, `HypervisorPlatform` (VBS and WSL2 prerequisites), `NetFx4*` and Windows Search.

**Update-source check (irreversible flag where a source is needed).** Before a capability removal the plan reads whether WSUS is in use (`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\UseWUServer = 1`) and whether a repair content source is set (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing`: `RepairContentServerSource = 2`, the "contact Windows Update directly" choice of the *Specify settings for optional component installation and component repair* policy, or a `LocalSourcePath`). WSUS without either means `Add-WindowsCapability` for the undo may not find the files, so the removal is flagged irreversible and skipped without `-AllowIrreversible`. This is a registry pre-check, not a guarantee in either direction. Optional features are never gated: their payload stays.

`comp-optional-features-legacy` is now explicit steps: capabilities WordPad, Steps Recorder, Math Recognizer and legacy Media Player, optional features Internet Explorer and the legacy Media Player feature. Language features and Defender are not in it. The tweak starts as `new-unverified`.

### AppX keep profiles (`appx-profiles.json`)

A catalog step `{ "type": "appx", "profile": "keep-work" }` removes the profile's `remove` list minus its `keep` list. Names are matched exactly (`Name`, or a `PackageFamilyName` starting with `<name>_`), never as greedy substrings; a `*` is allowed only in a `remove` entry. The file (`-ProfilesPath` overrides it) has:

- `profiles`: `keep-work` (keeps Teams, Outlook, Terminal, Paint, Snipping Tool, Camera, Calculator, Notepad, Photos), `keep-personal` (everyday tools, Phone Link, Media Player; removes promotional apps, Teams and Outlook) and `minimal` (Calculator, Notepad, Photos, Snipping Tool, Terminal). They are exposed as the balanced tweaks `appx-profile-keep-work`, `appx-profile-keep-personal` and `appx-profile-minimal`.
- `managedKeep`: `MSTeams`, `MicrosoftTeams`, `Microsoft.OutlookForWindows`, `MicrosoftCorporationII.QuickAssist` (the helpdesk remote-support tool), `Microsoft.MicrosoftOfficeHub` (the Microsoft 365 app). On a managed device these are kept whatever the profile says (a `Skip` row says so), also for the older `appx-consumer-bloat`. The list is read from this file (the built-in Teams/Outlook list is only the fallback when the file has no `managedKeep`), and `-Lint` warns about an entry that is in no profile's remove list. `keep-work` keeps Quick Assist and the Microsoft 365 app on every PC.
- `packages`: display name, Store product id and winget id **where known**; the ids are from public listings and were not verified with winget here (`winget show --id <id> -s msstore` confirms one). `frameworks`: Store ids for the framework hints (VCLibs: `9NBLGGH3FRZM`, `9NBLGGH4RV3K`).
- `optionProfiles` (ReviOS V6 profile data): `work-managed` (safe only, no AppX), `personal-desktop`, `personal-laptop` (reduced hibernation file instead of hibernate off, no power plan) and `gaming-desktop`, each a set of tweak ids plus the AppX profile. `-Lint` checks the ids exist, none is `never-default`, and `work-managed` holds only `safe` tweaks. The engine does not read this section; it is the data for a GUI option page.

Protected packages (Store, StorePurchaseApp, App Installer, VCLibs, UI.Xaml, NET.Native, WindowsAppRuntime, WebView2, Win32WebViewHost, SecHealthUI, shell and sign-in components) are never matched, by name or through a wildcard, and `-Lint` rejects a profile whose `remove` list names one.

### AppX removal ladder, reinstall manifest and framework check

1. **Plan** (needs `-AllowIrreversible`): the matching packages for the current user, plus provisioned copies with no registration for this user. The snapshot entry's `before.manifest` lists, per package, name, full name, family name, version, whether it was provisioned, `storeProductId`, `wingetId` and a ready `command`: `winget install --id <id> -s msstore --accept-package-agreements`, or `winget search "<name>" -s msstore` when no id is known (no id is ever guessed). The manifest is part of the snapshot saved before the step runs, so even a crashed or failed step has it. On **LTSC** there is no Store: `before.storeAvailable` is `false` and the command says to sideload.
2. **Apply**, per package: (1) remove for all users; (2) on failure remove for the current user; (3) remove the provisioned copy by its exact name; (4) failures are collected and the step ends `Failed` with the list (printed as `FAILED <tweak> <target>: ...`). No RunOnce key and no scheduled task is ever created.
3. **Framework check**: when the plan contains an AppX change, the engine appends one record, `engine-appx-framework-check` (order 900, runs last, listed in `-WhatIf`). At plan time it notes which of VCLibs, UI.Xaml, NET.Native, WindowsAppRuntime, App Installer and the Store are registered for you. Afterwards each must still be. One that is only registered for other users is re-registered from its install location (`Add-AppxPackage -Register`, no download). One that is gone makes the record `Failed` (exit 2) with the Store product ids to restore it (`9NBLGGH3FRZM` / `9NBLGGH4RV3K` for VCLibs). It is not offered for undo.
4. **Undo** never installs anything: for an AppX step it reports `Failed` ("cannot be undone automatically") and prints the manifest's commands for you to run.

### LTSC

`Get-OsInfo` reports `IsLtsc` for EditionID `EnterpriseS`, `EnterpriseSN`, `IoTEnterpriseS` and `IoTEnterpriseSK` (also in `-List -AsJson` as `os.isLtsc`, and in every snapshot). On those editions steps for components the edition does not ship are skipped with an LTSC note instead of failing, AppX rows say so, and the reinstall manifest does not offer the Store. **Not implemented:** the tiny11 report's `removablepackage` step (`DISM /Online /Disable-Feature ... /PackageName`) for the LTSC-only Removable Packages. Its exact syntax could not be verified on a non-LTSC machine, it has no undo, and it saves only tens of MB per package.

## Revert one tweak and drift detection

The snapshots in `%ProgramData%\DebloatKit` are the record of what was applied. Two modes use them. Both support `-AsJson` (stdout stays pure JSON, warnings go to stderr).

### `-Revert <id[,id]>`: undo specific tweaks

```powershell
.\DebloatKit.ps1 -Revert perf-ntfs-lastaccess -WhatIf   # preview, writes nothing, no admin needed
.\DebloatKit.ps1 -Revert ui-explorer-show-extensions,priv-advertising-id   # admin
```

This is for trying one change at a time (for example to compare `Get-BootReport` or `Get-MemoryPressure` with and without it) without undoing the whole run.

- The engine reads **all** snapshots that still hold applied steps (a file named `*.reverted.json` is finished), collects every applied, not yet reverted step of the requested tweaks, and restores them newest first.
- **Later re-applies are respected.** A step that was reverted earlier is marked in its snapshot and ignored. A tweak that was applied again after a revert has a fresh record, and only that record counts.
- **Two runs touched the same target** (for example a re-apply after Windows changed the value back): the **oldest** unreverted record holds the state from before DebloatKit first touched it, so that state is restored and every record of the target is marked reverted. The value Windows left in between is not what you get back. If another tweak that you did not name also changed the same target, the result row carries a note, because the restore overwrites its change.
- The steps are marked `reverted` (with `revertedAt` and `revertedBy`, the run id) **inside the snapshot**, after each successful target. The file is renamed `*.reverted.json` only when nothing in it is left to undo. A later `-Undo latest` skips marked steps. `-Revert -WhatIf` never calls an undo, whatever the step type: it only reports `WouldRevert` (or `NotRevertible`). Interrupted (`Pending`) and `Failed` steps of a tweak are offered too, marked "restore of an interrupted step"; `-Drift` does not compare them.
- A target that was already reverted, or an id that was never applied, is reported (`notFound` in JSON); when nothing at all can be reverted the engine exits with 1.
- **AppX records stay non-revertible** (and so do irreversible native changes): the result is `NotRevertible`, the reinstall manifest is printed, the record is not marked, and the exit code is 2. The engine never downloads anything.
- Safety: needs an elevated PowerShell (except `-WhatIf`), refuses when the process runs as another user than the GUI user and a per-user (HKCU) step is involved (`-ExpectedSid`), and logs to `revert-<time>.log.jsonl`. Like `-Undo`, a revert is **not** blocked on a managed device or by the preflight: putting things back must always stay possible.
- `-AsJson`: `{ mode: "revert", dryRun, requested, notFound, os, summary: { targets, reverted, wouldRevert, failed, notRevertible }, results: [ { tweakId, type, target, restoredTo, result, error, snapshot, runs, note } ] }`.

### `-Drift`: what did Windows change back?

```powershell
.\DebloatKit.ps1 -Drift            # read-only report, no admin needed for most steps
.\DebloatKit.ps1 -Drift -AsJson
.\DebloatKit.ps1 -Drift -Only ui-explorer-show-extensions
```

Feature updates and cumulative updates re-provision apps and reset policies, services and tasks. `-Drift` takes the **newest unreverted record of every target** that DebloatKit changed (so a later re-apply replaces an older record), reads the live state with the same read functions the plan uses, and compares it with what the run set:

| Step type | Drifted when |
|---|---|
| registry | the value is not the applied value, kind or presence any more |
| service, task | the start type is different, or the task is not Disabled |
| native | the handler's `Get` no longer returns the applied state (one-shot, irreversible changes such as the component store cleanup have no state and are not compared) |
| capability | the capability is `Installed` again |
| optional feature | the feature is `Enabled` again |
| AppX | a removed package is installed or provisioned again |

A step that cannot be read now (needs admin, gone from this system, the engine has no handler for it) is `Unknown`, never `Drifted`. Each snapshot records the Windows build (`os.BuildFull`), so the report says which build the tweaks were applied on and which build this is, with a one-line `banner` for the GUI ("Windows reverted 12 tweaks since build 26100.1234; this system is on build 26200.5678"). It also checks `appliesTo` against the current build and flags a tweak that no longer applies here (`notApplicable`). Migrations are not tweaks and are not tracked.

JSON: `{ mode: "drift", os, snapshots, appliedBuilds, buildChanged, banner, summary: { tweaks, inSync, drifted, unknown, driftedSteps }, tweaks: [ { id, status: InSync|Drifted|Unknown, driftedSteps, appliedBuilds, buildChanged, inCatalog, notApplicable, steps: [ { type, target, desired, current, state, note, run, appliedBuild } ] } ] }`.

Limit: the snapshot only holds steps the engine **changed**. A step that was already in effect when the tweak was applied is not tracked, and a tweak whose steps were all already in effect is not tracked at all.

### `-Drift -Reapply`: re-apply only what drifted

`-Reapply` takes the drifted tweaks that are still in the catalog, in the enabled preset and applicable to this build, and sends **only those** through the normal apply path: [preflight](#preflight-checks), restore point, snapshot, verify. Everything else works as for an apply: `-WhatIf` previews (with `-AsJson` you get the drift report plus `reapply: { dryRun, ids, skipped, preflight, plan }` as one document), `-Force` is needed on a managed device, `-SkipPreflight`, `-NoRestorePoint` and `-ExpectedSid` behave the same, `-Skip` and `-Only` narrow the set, and tweaks with `verification: new-unverified` are included because you applied them before. AppX and other irreversible steps are planned but skipped until you add `-AllowIrreversible`. Drifted tweaks that cannot be re-applied (removed from the catalog, no longer applicable, not in the enabled preset) are listed under `skipped` with the reason.

The new snapshot records the current build and `reapply: true`. Nothing re-applies automatically or on a schedule: drift is only reported until you ask for `-Reapply`.

## Memory pressure monitor

`Get-MemoryPressure.ps1` is a separate, read-only tool. It tells you whether the system is really short of memory, so you can decide on the one fix that matters (a larger pagefile minimum) with numbers instead of guesses. It also gives before/after figures when you change browser settings.

```powershell
.\Get-MemoryPressure.ps1                                   # one report: commit, paging, verdict, top 10 processes, pagefile advice
.\Get-MemoryPressure.ps1 -AsJson                           # JSON only on stdout (warnings go to stderr)
.\Get-MemoryPressure.ps1 -Watch -IntervalSeconds 60        # one line per minute until Ctrl+C
.\Get-MemoryPressure.ps1 -Watch -Count 60 -LogPath $env:TEMP\mp.csv -Toast
.\Get-MemoryPressure.ps1 -SelfTest                         # no system access; tests the logic and scans its own source
```

**Watch commit %, not "RAM in use".** Windows uses free RAM as cache on purpose, so a full RAM bar is normal. Commit charge (what programs have promised to use, against RAM + pagefile) is the number that runs out. The report shows it in GB and as a percentage, next to Pages Output/sec, which says whether Windows is really writing memory to disk.

| Condition | Status |
|---|---|
| commit >= 90 % | Critical (the system-managed pagefile grows here; allocations fail at 100 %) |
| commit >= 80 % and Pages Output/sec >= 100 | Critical |
| commit >= 80 % and Pages Output/sec < 100 | Warning (high commit, little paging yet) |
| Available < 500 MB or < 1 % of RAM | Critical |
| Available < 10 % of RAM | Warning |
| Event 2004 (Resource-Exhaustion-Detector) in the last `-EventDays` days | at least Warning |
| Any pagefile more than 90 % used | Warning |

The thresholds and their Microsoft sources are in [docs/PERFORMANCE-RESEARCH.md](../docs/PERFORMANCE-RESEARCH.md). The pagefile advice suggests `ceil(peak commit x 1.25 - RAM)` GB as a minimum (capped at 3 x RAM) and says "no change needed" when the current pagefile is already that large. It is a manual change in System Properties > Advanced > Performance > Virtual memory; on a managed device ask IT first.

**The tool never purges memory and never changes the pagefile.** It does not empty working sets or the standby list, and it does not write the registry, services, scheduled tasks, power settings or the event log. The only file it can write is the CSV from `-LogPath`. There is no install option. If you want it to run periodically, you can create a scheduled task yourself, for example an action of `powershell.exe -NoProfile -File "C:\path\to\Get-MemoryPressure.ps1" -Watch -IntervalSeconds 300 -LogPath "C:\path\to\mp.csv"` started at logon.

**Crash dump and pagefile.** The report also reads `CrashControl` (`CrashDumpEnabled`, `FilterPages`, `AutoReboot`, a dedicated dump file) and sets it next to the pagefile on the boot drive, in a `Crash dump:` section and in `crashDump` in `-AsJson`:

| Finding | Status |
|---|---|
| Dump type needs a pagefile on the boot drive (complete, kernel, automatic) and there is no pagefile | Warning |
| The only pagefile is on another drive | Warning |
| Boot-drive pagefile smaller than the dump type needs (complete = RAM + 257 MB; kernel and automatic follow Microsoft's RAM-size table: 800 MB under 4 GB, 2 GB to 16 GB, 4 GB to 64 GB, 8 GB to 128 GB, 32 GB above; an approximation; RAM is rounded to the nearest GB first, so a 16 GB PC that reports 15.9 uses the 16 GB row) | Warning on a fixed pagefile; OK with an info note on a system-managed pagefile for kernel and automatic dumps, because Windows sizes it for the dump (a complete dump still warns) |
| A dedicated dump file is set | OK (the pagefile requirement is waived) |
| Small dump (`CrashDumpEnabled=3`, what ReviOS sets) | OK, with a note: on a system-managed pagefile it can let Windows shrink the pagefile and so lower the commit limit. Do not copy it onto a PC that runs near its commit limit |
| Automatic dump (7) on a system-managed pagefile | OK, note that this is the safe setting for commit headroom |

The crash-dump status is reported on its own and does not change the memory verdict. The tool still never changes the pagefile or the dump settings.

Exit code: 0 on success (also for Warning or Critical status), 1 on a script error. `-Toast` uses the Windows toast API on Windows PowerShell; on PowerShell 7 it falls back to a console warning and a beep.

## Boot and startup baseline

`Get-BootReport.ps1` is a separate, read-only tool that gives you a before/after baseline for startup changes. Disabling startup apps is the only boot change with a measured gain (about 7 s on an SSD and 19 s on an HDD in published tests), and Task Manager's "Startup impact" column often reads "Not measured", so this report uses the objective boot timings Windows already records.

```powershell
.\Get-BootReport.ps1                  # boot history, degradations, startup items, logon tasks, Fast Startup, findings
.\Get-BootReport.ps1 -Boots 5 -Days 14
.\Get-BootReport.ps1 -AsJson          # JSON only on stdout
.\Get-BootReport.ps1 -SelfTest        # no system reads; tests the parsers and scans its own source
```

It shows the last `-Boots` boots from Event 100 (Diagnostics-Performance/Operational) with the median, the apps, drivers and services that slowed boot (events 101/102/103 in the last `-Days` days), every Run / RunOnce / Startup-folder item with its enabled state from `Explorer\StartupApproved`, enabled non-Microsoft logon tasks with their delay, and the Fast Startup setting. Microsoft's goal is fewer than 10 Run-key processes; the report says so when you go over.

Reading the Diagnostics-Performance log may require an elevated prompt or Event Log Readers membership. Without it the boot and degradation sections are skipped (reported as `needsElevation`) and the rest of the report still runs.

To measure a change: run the report, change **one** thing in Settings > Apps > Startup or Task Manager > Startup apps, restart (not Shut down, because Fast Startup makes a normal shutdown boot differently), and compare Event 100 before and after. The tool writes nothing and changes no setting, service, scheduled task or boot option.

## Footprint report

`Get-FootprintReport.ps1` is a separate, read-only tool that measures what a debloat run actually changed. Most size and "feels lighter" claims are headline numbers that nobody measured on the machine they were made for, so save a report before, run DebloatKit, and compare. State readings that depend on the Windows display language are best effort: Compact OS comes from the exit code of `compact /CompactOS:query` (0 compact, 102 not compact; the English text is only a fallback), reserved storage comes from the live DISM answer (elevated only) and is `unknown` when that is not recognised or the report is not elevated (never guessed from the `ShippedWithReserves` factory value), and `cleanupRecommended` is read from the English DISM label only. An `unknown` state is never reported as a change in a comparison.

```powershell
.\Get-FootprintReport.ps1 -Deep                                  # one report (-Deep adds the WinSxS analysis; needs an elevated prompt)
.\Get-FootprintReport.ps1 -Deep -Baseline D:\Notes\before.json   # the same, and save it as JSON at a path you choose
.\Get-FootprintReport.ps1 -Deep -Compare D:\Notes\before.json    # measure now and show the differences against the saved report
.\Get-FootprintReport.ps1 -Compare D:\Notes\before.json -With D:\Notes\after.json   # compare two saved reports (no system reads)
.\Get-FootprintReport.ps1 -SettleSeconds 120 -AsJson             # wait 2 minutes for idle memory figures, JSON only on stdout
.\Get-FootprintReport.ps1 -SelfTest                              # no system reads; tests the parsers and the comparison
```

It reports the system drive (total, used, free), the component store (WinSxS) with Explorer's number, the actual size and the backups and disabled features that a cleanup could reclaim, `hiberfil.sys`, `pagefile.sys` and `swapfile.sys` sizes, reserved storage and Compact OS state, AppX packages (current user and provisioned), running processes, services (total, running, automatic), startup entries (Run / RunOnce values and Startup-folder files; use `Get-BootReport.ps1` for their enabled state), and RAM in use and commit charge.

**WinSxS needs `-Deep` and an elevated prompt.** The only honest figure is the one from `DISM /Online /Cleanup-Image /AnalyzeComponentStore`, which is read-only but takes about a minute. Walking the `WinSxS` folder would count hard-linked files twice, so the tool never does that: without `-Deep`, or without elevation, the section says why it was skipped. Provisioned AppX packages also need elevation; in PowerShell 7 they are counted through Windows PowerShell because the DISM-backed cmdlet does not work there. The DISM labels are localized, so the sizes are read by position.

**Comparing.** `-Compare` shows each number before and after with the difference and whether it is better, worse or the same (less used space, fewer processes and a smaller `hiberfil.sys` are better; more free space is better). It also lists changes of Compact OS, reserved storage, OS build and edition, and warns when the OS build changed between the two reports (size differences may then come from the update) or when one report was elevated and the other was not (provisioned AppX and WinSxS figures exist only in the elevated one). Take both reports in the same way (same elevation, `-Deep` on both) and, for memory, after the same settle time; process and memory numbers move by themselves from minute to minute, so treat small differences there as noise.

**What it writes.** Nothing, except the baseline JSON at the path you give with `-Baseline`. It refuses paths under the Windows folder and under `%ProgramData%\DebloatKit`, creates a missing parent folder, and replaces an existing file only with `-Force`. It changes no setting, service, task, package or file. `-AsJson` writes only JSON to stdout (the report, or the comparison with `-Compare`); warnings go to stderr. Exit code: 0 on success, 1 on a script error or a bad argument.

## Offline image builder

`DebloatKit-Image.ps1` is a separate tool for **building** a slimmed install ISO from an official Microsoft ISO. It is the offline counterpart of the engine, meant for personal and other unmanaged machines (an Entra or Intune PC should be deployed with Autopilot and policies instead). It reproduces the useful part of tiny11-style images (no bloat from the first boot, no per-user AppX leftovers, optional Compact OS) while keeping Windows Update, Microsoft Defender, WinRE and servicing intact.

```powershell
.\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11.iso -ListEditions                      # mounts the ISO, prints the editions, dismounts
.\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11.iso -ExpectedSha256 <hash> -Index 6 -WhatIf   # the full command plan; nothing runs
.\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11.iso -ExpectedSha256 <hash> -Index 6 -WorkDir D:\ImgWork   # build (elevated)
.\DebloatKit-Image.ps1 -IsoPath D:\ISO\Win11.iso -ExpectedSha256 <hash> -Index 6 -AppxProfile keep-work -CompactOS
.\DebloatKit-Image.ps1 -SelfTest                                                  # no system access; plan and mocked-DISM checks
```

**Source and hash.** The input is an ISO you downloaded yourself from microsoft.com; the script never downloads an ISO, and prebuilt "tiny11" images are not an input. Pass the SHA-256 that Microsoft publishes on the download page with `-ExpectedSha256`. A mismatch, a malformed hash or no hash at all stops the build before the ISO is mounted. `-SkipHashCheck` builds anyway, prints a warning and records the source as unverified in the manifest. No hash values are checked in: a table of hashes that nobody here can verify would be worse than none.

**What a build does** (every step is listed by `-WhatIf`; the plan is a recording of the same steps a real run executes):

1. Gates: ISO found, hash, a new or empty work folder (default `<system drive>\DebloatKitImage`; plain path of letters, digits, dot, dash, underscore, no spaces, not inside the Windows folder), 30 GB free, elevated prompt. An existing output ISO is never replaced, and the script never deletes files it did not create.
2. Mount the ISO, copy it to `<WorkDir>\iso`, dismount it. Export the chosen `-Index` of `install.wim` or `install.esd` to `<WorkDir>\install.wim` with `/Compress:max`, and mount that copy.
3. Read the edition, build and architecture from the image's offline registry (not from DISM text, which is localized).
4. **AppX:** remove provisioned packages from an `appx-profiles.json` profile (`-AppxProfile`, default `keep-personal`; `none` skips): the profile's remove list minus its keep list, matched by **exact name**, and never a protected package (Store, App Installer, VC++/XAML/.NET Native/Windows App SDK frameworks, WebView2, Windows Security, shell and sign-in components; the list mirrors the engine's and a test keeps them equal). Names are matched against the image's real package list and each removal uses the full package name.
5. **Registry:** apply the `safe` catalog offline. Only a tweak whose steps are **all** registry values is used (services, scheduled tasks and commands only work on a running system and are listed as skipped with that reason). A tweak is also left out when its `appliesTo` does not match the image (for example `AllowTelemetry=0` on Professional, where Windows ignores it), when it depends on laptop or desktop hardware, or when it has a `managedSkip` note (add `-IncludeManagedSensitive` to apply those), or when the catalog marks it `new-unverified` (not yet tested on a real machine; add `-IncludeUnverified` to apply those, recorded as `options.includeUnverified` in the manifest), or when a value sits on a protected target (update policy, firewall, UAC, SmartScreen, BitLocker, Defender; see [Protected targets](#protected-targets)). `-ExcludeId` drops tweaks by id. Hives are loaded under unique names (`HKLM\DK_<hive>_<random>`) and unloaded in a `finally` block, with the handles released first and a retry; if one cannot be unloaded the script says which command to run and does not commit the image. `HKLM\SYSTEM\CurrentControlSet` is mapped to the control set the image itself names (`Select\Current`). `HKCU` values go to the **Default user** hive (`NTUSER.DAT`), so they only affect accounts created after the install; `HKCU\Software\Classes` values go to the Default user's `UsrClass.dat` (they are not stored in `NTUSER.DAT`) and are skipped when that file is missing.
6. `DISM /StartComponentCleanup` **without** `/ResetBase`, so installed updates stay uninstallable. A failed cleanup is a warning (`-SkipCleanup` omits it).
7. Unmount with `/Commit`. On any failure the image is unmounted with `/Discard`, every hive is unloaded and the ISO is dismounted; nothing is committed half-done.
8. Export the result into the ISO tree with `/Compress:max` as `install.wim`, or with `-RecoveryEsd` as `install.esd` with `/Compress:recovery` (smaller, but it cannot be serviced again or split for FAT32).
9. Build the ISO with `oscdimg` **only if it is already on this PC**: `-OscdimgPath`, `oscdimg.exe` on the PATH, the Windows ADK (Deployment Tools), or the winget package `Microsoft.OSCDIMG`. It is never downloaded. If it is not found, the prepared tree stays in `<WorkDir>\iso`, a warning says so, and the manifest records `isoBuilt: false`.
10. Write `<output>.iso.manifest.json`: source path and hash, verification state, image index, edition, build, architecture, catalog and profile versions, every option, the tweaks applied and skipped (with reasons), the AppX packages removed and not present, the output ISO hash and the warnings.

**Off by default, opt-in only:**

| Switch | Effect | Warning |
|---|---|---|
| `-CompactOS` | writes `autounattend.xml` with `<Compact>true</Compact>` into the ISO, so Setup installs Compact OS | small CPU cost; NTFS only; the unattend file is the minimal one and was not run through a Setup in this repo, so test it in a VM |
| `-AllowUnsupportedHardware` | sets the Setup bypass values (`LabConfig` in `install.wim` and in `boot.wim` index 2, and `MoSetup`) | Microsoft does not guarantee updates, including security updates, on unsupported hardware |
| `-RecoveryEsd` | final image as `install.esd` | cannot be serviced again or split for FAT32 |
| `-SkipHashCheck` | build without verifying the ISO | an unverified source can contain anything |

**Never done:** removing or disabling Defender, Windows Update, the Update Medic or Orchestrator services, WinRE, the servicing stack or WinSxS content; `/ResetBase`; deleting Edge or WebView2; turning off BitLocker or reserved storage; `BypassNRO`; downloading an ISO, oscdimg or anything else. A test scans the script for these and for any system-changing command outside the one dispatcher function (`Invoke-RealTool`) that `-WhatIf` and `-SelfTest` replace with a recorder.

**Testing.** `-SelfTest` needs no admin and touches no disk: it checks the key mapping, the selection against the real catalog (every safe tweak is either selected or skipped with a reason, so a future catalog edit cannot slip through), the AppX resolution, whole builds against a recording fake of DISM, `reg.exe` and the file system (order of steps, hash refusal, each flag, ARM64, no oscdimg, failures at several points and the cleanup after them), the plan mode and the static scans. Before using an image on a real PC, build it, install it in a VM, and check that Setup reaches the desktop, `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth` pass and Windows Update installs a cumulative update. The first real build on your hardware is the real test of the DISM steps, which this repo's tests deliberately never run.

## Repo root launchers (legacy `clear_ram_loop.bat` retired)

The repository root used to hold a batch loop that disabled Windows Update, UsoSvc and BITS, then every 10 seconds purged temp files, trimmed working sets, killed apps and emptied the standby list with RAMMap. It was the most harmful code in the project (no security patches, Intune, Defender signature and Delivery Optimization traffic broken, cache thrown away) and has been replaced:

- `clear_ram_loop.bat` explains why it was retired, points to this kit and opens `DebloatKit-GUI.ps1`. It changes nothing. `clear_ram_loop.bat /noop` prints the text and the launch command only.
- `run_invisible.vbs` and `setup.ps1` open the GUI (the VBS hidden, without a console window) instead of the loop. Neither elevates or changes the execution policy; the GUI asks for UAC only when you apply or undo. `run_invisible.vbs /check` (run with `cscript //nologo`) and `setup.ps1 -WhatIf` print what they would do.
- `revert.bat` stays for anyone who ran the old script. Run it as Administrator: `wuauserv` goes back to manual, `UsoSvc` to automatic (delayed) and `BITS` to manual (the Windows defaults), the three services are started, the `NoAutoUpdate`, `AUOptions` and `ToastEnabled` values are removed and the three `WindowsUpdate` scheduled tasks are re-enabled. `revert.bat /noop` prints every command without running it or needing admin.
- To see whether you really need to free memory, run `Get-MemoryPressure.ps1`; see [Memory pressure monitor](#memory-pressure-monitor).
- The RAMMap binaries in the repository root are no longer used by anything; they are only documented in the root README.

## Tests

```powershell
.\tests\Test-Engine.ps1
```

This runs apply, re-apply and undo against a throwaway key (`HKCU:\Software\DebloatKitTest`) using `tests\test-catalog.json` (a version 1 array, which also tests the legacy path) and `tests\test-catalog-v2.json`, then deletes the key. It covers changing an existing value, creating values and nested keys, idempotency, exact undo, skipping command strings, the preset gate, the catalog schema (v1 migration, newer schema refused), `managedSkip`, `appliesTo` (skip and note), migrations (`-List`, `-Migrate -WhatIf`, apply, undo), DWord values above Int32.MaxValue, and `-Lint` on the real catalog, on a catalog with deliberate defects and on copies of the engine with deliberate handler defects. It also runs the `-SelfTest` of `Get-FootprintReport.ps1` and `Get-MemoryPressure.ps1` (including the crash-dump checks) and tests the footprint comparison, the baseline path rules, the argument and schema checks on saved report files, plus one live read-only `-Baseline` run that writes a report into a temporary folder. It passes on Windows PowerShell 5.1 and PowerShell 7.

It also covers the engine's preflight, applicability, step policy and protected targets with `tests\test-catalog-wp2.json`: each preflight gate refusing before anything is written, `-SkipPreflight`, `-Undo` while a gate fails, requiresLaptop / requiresDesktop and build ranges per fake chassis and build, deterministic order, `continue` / `stop-tweak` / `abort-run` with the exact snapshot results and what undo reverts, protected services, AppX packages (including a live wildcard), registry values and tasks, and the new lint rules. The real preflight is only read (`-List -AsJson` must report its four gates); the tests that apply on the real system pass `-SkipPreflight` because the machine may legitimately have a reboot pending.

The native disk and system handlers are covered with `tests\test-catalog-wp3.json` (all eleven ids, preset `safe` in the test copy only so the engine considers them): their read functions run against the real system with `-WhatIf` (read-only, every Get must return a value, and the real state of Compact OS, hibernation, reserved storage, power plans, memory compression, 8.3 names, Sleep Study channels and boot menu policy is compared before and after the whole run); every plan, apply, re-apply and undo runs against the fake tools. It checks the exact undo (an existing power plan is kept, an existing boot policy comes back, 8.3 comes back as 3 and not a fixed 2, hibernation comes back as reduced), the `Check` rules (laptop, commit 90 % warning, BitLocker on or unreadable, hibernation off, restart or servicing pending, managed device), allowlisted targets, the irreversible component cleanup (skipped without `-AllowIrreversible`, no `/ResetBase`, undo refused, `0x800F0806` reported, sizes in the run log), the new lint rules and four deliberately broken copies of the engine.

The capability, optional feature and AppX work is covered with `tests\test-catalog-wp4.json` and `tests\test-appx-profiles.json` (preset `safe` in the test copy only): the real plan is read with `-WhatIf` (every row must be a state, "not present", protected, profile or admin note), the real capability, feature, AppX and provisioned inventories are compared before and after the whole run, and everything that changes runs against the fake `capability`, `optionalfeature`, `appx` and `wusource` tools (state keys `capability:<name>`, `feature:<name>`, `appx:<name>` and `wusource:*`, plus `source:blocked`, `appx:failallusers`, `appx:failremove:<name>` and `appx:breaks:<name>` to inject failures). It covers plan, apply, re-apply and undo for both step types, the update-source gate, profile keep and remove, managed-device keeps, the manifest in the snapshot, the removal ladder, the framework check (re-registered, missing with and without a known Store id), LTSC, the lint rules and a deliberately broken copy of the engine.

The revert and drift work is covered with `tests\test-catalog-wp5.json` (registry steps in `HKCU:\Software\DebloatKitTest\WP5`, a native, a capability, an optional feature and an AppX step on the fake tools): apply several tweaks, `-Revert` one (preview, JSON, the reverted marker inside the snapshot, other tweaks untouched, the file kept until nothing is left, a created key removed again), revert across runs (oldest before-state wins, a reverted-then-re-applied tweak, `-Undo latest` skipping reverted steps), AppX `NotRevertible`, the SID check, a managed device, then a fake feature update (build 26100 to 26200) with manual changes to every step type, `-Drift` (text and JSON, read-only: the state folder is unchanged afterwards), `-Drift -Reapply` (preview, pending-reboot refusal, managed device, only the drifted tweaks, the newer snapshot superseding the old record, `-AllowIrreversible` for AppX, a no-longer-applicable tweak skipped) and `-Drift` against the real system with an empty state folder.

The GUI work is covered in two ways. `DebloatKit-GUI.ps1 -SelfTest` (no window) checks the new XAML elements, the Apply / Revert / Skipped toggle for every row (the reason of a skipped row, Revert only with a snapshot record), the command text (`-Revert @(ids)` without `-Only`, `-Force`, `-SkipPreflight` or `-IncludeUnverified`; the footprint tool without engine-only parameters; `-Drift -Reapply` with `-Force` / `-SkipPreflight` / `-ExpectedSid`), every profile with several answer variants (only runnable, verified, not-yet-applied tweaks are ticked; `work-managed` never plans app removal; ids exist; no `never-default` or `reduces-security`), the Profiles tab against the real device state, the Drift tab with the real `-Drift -AsJson` (empty is valid), `-Drift -Reapply -WhatIf -AsJson` and a fake drifted document, a real `-Revert <id> -WhatIf -AsJson` (nothing to revert, or a pure JSON preview), the live footprint report, and the comparison code with two temporary reports compared through `-Compare -With` (no second system read). `tests\Test-Engine.ps1` additionally checks `profiles.json` against the real catalog, runs the GUI self-test, and runs a sandbox self-test (`-SelfTest -StateDir ... -TestEnvironment ... -CatalogPath tests\test-catalog-wp5.json`) in which the GUI-built `-Revert w5-a` restores the throwaway key, the hand-changed value is reported as drifted and the re-apply preview plans only that tweak.

The repo root launchers are covered in the same file (WP8): static scans of `clear_ram_loop.bat`, `run_invisible.vbs` and `setup.ps1` (no `sc config` / `sc stop`, no registry or task change, no loop, `taskkill`, temp purge, RAMMap or working-set trim, no `Set-ExecutionPolicy`, no elevation), `clear_ram_loop.bat /noop`, `revert.bat /noop` (the exact start types, the service starts, the three value deletes and the three task enables, nothing run), `cscript run_invisible.vbs /check`, `setup.ps1 -WhatIf` on the host being tested, and the root `README.md` (no Defender-pause advice, the GUI, monitors, safety model, research docs and legacy table present, relative links resolve). Every one of them runs in its no-change mode.

The review fixes are covered in the same file (WP10): `-Revert -WhatIf` on a capability record with an irreversible note leaves the fake capability untouched, a failed `-Undo` keeps the snapshot and a second `-Undo` retries only the failed step, `Pending` and `Failed` steps are restored by `-Undo` and `-Revert`, snapshot writes leave no temp file, `-TestEnvironment` is refused for a real run without `DEBLOATKIT_TESTENV`, the extra protected targets (engine and image builder lists compared), the safe-preset rules (Appraiser, Security and Maintenance toast, firewall block) with their lint rules, the `managedKeep` list read from the profiles file, and the execution-policy handler pinned to Windows PowerShell. The offline image builder is covered in the same file (WP9): `DebloatKit-Image.ps1 -SelfTest` (key mapping including the `CurrentControlSet` and `Software\Classes` cases, the selection against the real catalog, AppX resolution with protected, wildcard and kept names, whole builds against a recording fake of DISM / `reg.exe` / the file system with the exact step order, hash mismatch and `-SkipHashCheck`, each opt-in flag, ARM64, no oscdimg, failures during the registry writes, the mount, the copy, the hive unload and the component cleanup, and static scans), a comparison of the builder's protected AppX list with the engine's, and the real script in `-WhatIf -AsJson` (pure JSON plan, nothing created) and in refusal mode (no hash, missing ISO, malformed hash, unsafe or spaced work folder, missing index, unknown profile). DISM, `reg.exe`, `Mount-DiskImage` and oscdimg are never run by any test.

Nothing in it changes the system outside the throwaway key. The managed-device flag, OS edition, build and chassis, the preflight readings, and every tool the native handlers use (fsutil, powercfg, compact, dism, wevtutil, bcdedit, MMAgent, the execution policy) come from a fake `-TestEnvironment <file.json>` (`{ "managed": true, "os": { "editionId": "Professional", "build": 26200, "ubr": 1, "chassis": "Laptop" }, "preflight": { "rebootPending": ["..."], "pendingFileRename": false, "servicingBusy": false, "onBattery": false, "freeDiskMB": 50000 }, "protectedServiceKeys": ["Spooler"], "failSteps": ["tweakId|target*"], "tools": { "fsutil:disablelastaccess": "2", "compactos:state": "not-compact", "powercfg:hibernate": "full", "commit:percent": "90", "bitlocker:protection": "off", ... } }`; a key not listed falls back to the engine's built-in default, so a test only names what it cares about). Without a `preflight` section every gate passes; `protectedServiceKeys` fakes write-protected service keys; `failSteps` makes matching steps fail when applied (before they touch anything), which is how the error policy is tested. The fake tool state is written back to that file, so a later `-Undo` process sees it. Because the fake managed flag and preflight would lift the engine's safety gates, the engine accepts `-TestEnvironment` for a real run only when the test runner sets `DEBLOATKIT_TESTENV=1` (`tests\Test-Engine.ps1` does); `-WhatIf`, `-List`, `-Lint` and read-only `-Drift` always accept it. Use the same mechanism to test a new native handler: put its id in a test catalog as a `command` step and run apply and undo with `-TestEnvironment`.

## Caveats

- Profiles are safe-only in practice while the engine enables only the `safe` preset: the balanced and aggressive tweaks and the AppX keep profiles a profile names are listed as "not enabled in this version", never ticked. The GUI never passes `-AllowIrreversible`.
- The per-row Revert needs the snapshots in `%ProgramData%\DebloatKit`; a tweak that was already in effect before DebloatKit has nothing to restore. Two runs that changed the same value restore the oldest saved value.
- 32 catalog entries (18 of them in `safe`) are marked as not verified against the source projects (see the `verification` field). Test on a Windows 11 VM before applying them to a real machine.
- HKCU tweaks apply to the account running the elevated PowerShell. Run it from the account you want to change.
- Some changes, such as Explorer settings, policies and Fast Startup, take effect after you sign out or restart.
