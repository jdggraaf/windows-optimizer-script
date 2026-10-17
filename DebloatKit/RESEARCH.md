> For the 2026-10 performance and RAM review, see [../docs/PERFORMANCE-RESEARCH.md](../docs/PERFORMANCE-RESEARCH.md).

# Windows 11 debloat research: reproducing ReviOS / AtlasOS / Tiny11 results post-install

Inputs: 7 per-project catalogs (178 source pages summarised by a small model). Output: `tweak-catalog.json` (122 deduplicated, machine-usable tweaks). Registry paths marked `verification` other than `from-notes` must be checked on a 26100/26200 VM before shipping.

## TL;DR

- Most of what these projects do on a live system is **policy/registry/service/task/AppX changes**, all reproducible and revertible by a script. The deep wins (WinSxS, Defender component, Edge file removal) are image-time only and not reproducible safely.
- **Measured gains are small and anecdotal.** Independent tests (Yahoo/PCMag) found debloaters barely change idle RAM (about 1.9 GB fresh boot). Reported ReviOS/Atlas RAM and process-count wins mostly come from image-time removal plus disabled security features and services.
- Real, defensible effects: fewer background processes/services, less telemetry I/O, no ads/suggestions, slightly snappier foreground (priority separation), Game DVR off, faster shutdown timeouts, fewer metadata writes. HVCI off helps some older gaming PCs (7-15% reported, secondhand) but is a real security trade.
- Revert must be **snapshot-driven** (record prior value or absence), not hard-coded defaults; several projects' own undo is partial (winutil Widgets/hosts/AppX, Atlas relies on a services .reg backup).
- Security-reducing items (Defender, SmartScreen, Smart App Control, VBS/HVCI, mitigations, UAC secure desktop, updates, BitLocker auto-encryption) stay opt-in behind an explicit switch; Smart App Control off is one-way.

## What each project does differently

| Project | Method | Scope | Revert story | Security posture |
|---|---|---|---|---|
| ReviOS | AME Wizard playbook (YAML) + custom CBS packages for WinSxS/Defender removal; revitool for post-install toggles | Fresh install only; ~77 files; services, power plan, BCD, policy, AppX, deep component removal | Reinstall; revitool toggles for some; package uninstall for components | Defender removed by default, updates paused, SmartScreen/SAC/VBS off; UAC kept |
| AtlasOS | AME Wizard playbook, ~450 YAML + cmd/ps1 scripts, option tags | Fresh install (24H2/25H2); services, privacy, perf, AppX, optional Edge removal | '(default).cmd' pairs and services .reg backup; SAC irreversible | Defender/UAC/mitigations on by default; mitigations, VBS, Defender, MSA block opt-in |
| Tiny11 / Core | Offline DISM on install.wim: remove AppX, delete Edge/OneDrive files, prune WinSxS (Core), registry in image | Image build, not installed systems | None (rebuild image); Core is not serviceable | Core disables Defender/WU; regular keeps them |
| Winutil | PowerShell/JSON tweak catalog with Original/RemoveEntry undo | Live system, per-tweak toggles, presets | Per-tweak undo, partial; no persisted state across sessions | Mostly keeps security; update modes and BitLocker off optional |
| Win11Debloat | PowerShell script + Regfiles with Undo/ counterparts, Apps.json | Live system; current, other or Default user hive; WhatIf and registry backup | Undo .reg files; apps need reinstall | Prefers policy keys; keeps Defender/WU; some update deferral |
| Privacy guides (RTLFB, O&O, Sophia, privacy.sexy) | Group-policy/registry per Microsoft's connection-endpoints article; tiered recommendations | Live system | Delete policy values; Sophia has -Default functions | Tiered Recommended/Limited/Not recommended; warns against blocking WU/root certs |

## Where the measurable gains come from

| Metric | Evidence | Verdict |
|---|---|---|
| Idle RAM | Yahoo/PCMag: debloat tools 'barely change' idle RAM; ReviOS ~1.5 GB vs Atlas ~1.3 GB and Atlas ~12-13% vs stock 17% are single-run anecdotes | Mostly image-time removal and disabled services; do not promise numbers post-install |
| Process count | PCGH: 128 vs 72 processes for whole Atlas build | Real, but whole-build; svchost-split, service disables and AppX removal each contribute a few |
| Boot time | Fast Startup off makes cold boots slower on HDD, cleaner on SSD | Not an improvement by itself |
| Latency/responsiveness | Win32PrioritySeparation 38, shutdown/hang timeouts, MenuShowDelay | Small but real and cheap |
| Gaming FPS | PCGH 2-8% for Atlas; HVCI off about 8% on a 5800X3D (secondhand) | Largest single lever is HVCI/VBS, which is a security cost; Game DVR off is free |
| Disk | Reserved storage ~7 GB; hiberfil; AppX | Real and measurable |
**Placebo / unproven:** BBRv2 command, svchost-group tuning beyond the threshold key, memory-compression off (can raise paging), pagefile/CPU idle claims, 'tweaks stop working after 1-3 months' (anecdotal; mitigated by drift check + re-apply after feature updates).

## Catalog stats

Total: **122** tweaks; 42 done by 3+ projects. Per project (entries touching it): atlas 55, revios 54, winutil 46, privacy 34, win11debloat 30, perf-evidence 29, tiny11 24.

| Category | safe | balanced | aggressive | never-default | total |
|---|---|---|---|---|---|
| appx | 0 | 5 | 1 | 0 | 6 |
| components | 3 | 3 | 2 | 0 | 8 |
| edge-browser | 1 | 1 | 2 | 1 | 5 |
| network | 5 | 4 | 1 | 0 | 10 |
| other | 1 | 3 | 0 | 0 | 4 |
| performance | 6 | 10 | 0 | 0 | 16 |
| power | 2 | 2 | 0 | 0 | 4 |
| scheduled-tasks | 3 | 0 | 0 | 0 | 3 |
| security | 2 | 2 | 1 | 10 | 15 |
| services | 2 | 6 | 3 | 1 | 12 |
| telemetry-privacy | 17 | 6 | 1 | 0 | 24 |
| ui-shell | 9 | 0 | 0 | 0 | 9 |
| updates | 1 | 3 | 0 | 2 | 6 |
| **all** | 52 | 45 | 11 | 14 | 122 |

Preset rule: safe = risk 'safe'; balanced = moderate; aggressive = breaks-features; never-default = reduces-security (opt-in with typed confirmation).

## Image-only changes (excluded from JSON) and closest post-install alternative

| Change | Source | Closest post-install alternative |
|---|---|---|
| Defender WinSxS components removal (Service, UI, Offline-Amcore, ETW; AMSI kept) | ReviOS | Policy DisableAntiSpyware + wscsvc; blocked by Tamper Protection; not a removal |
| WinSxS component removal (Flash, CEIP, SQM, UsbCeip, RetailDemo, screensavers, Unified Telemetry Client...) | ReviOS | Equivalent service/policy tweaks (CEIP, autologgers, tasks); optional features via Disable-WindowsOptionalFeature |
| Edge/EdgeUpdate/WebView file deletion | Tiny11 | Edge debloat policies; unsupported external removers only (opt-in) |
| WinSxS whitelist prune and winre.wim delete (Core) | Tiny11 Core | DISM /StartComponentCleanup /ResetBase (different, shrinks repair source) |
| Offline DISM /Remove-ProvisionedAppxPackage on media | Tiny11 / NTLite | Remove-AppxProvisionedPackage -Online plus Remove-AppxPackage -AllUsers |
| OOBE BypassNRO (local account at setup) | Tiny11 | None after first sign-in |
| LabConfig TPM/SecureBoot/RAM checks bypass | Tiny11 | Setup-only; MoSetup AllowUpgradesWithUnsupportedTPMOrCPU for in-place upgrade (not shipped) |

**Pending research (not in JSON, implementation not verified):** Win11Debloat Disable_Telemetry/Windows_Suggestions/Edge ads/AI regfiles contents, DisableDeviceAutoAppDownload, Disable_Widgets_Service (failed import #544), ReviOS pending WU service RegisterWithAU path, BCD TSX/lastknowngood, winutil unsigned-RDP warning values, per-app mitigation exceptions, start2.bin replacement, Store search ACL hack, Windows Update reset routine (repair, not tweak).

## Recommended tool architecture

- **JSON-driven PowerShell module** (`DebloatKit`): one engine interprets `tweak-catalog.json`; step types registry, service, task, appx, command, multi, external. No tweak logic hard-coded. This mirrors AME playbooks: ordered YAML actions with tags/options and a root file sequencing phases, plus Atlas's per-option '(default)' pair.
- **Presets**: safe (default), balanced, aggressive, never-default. `-IncludeSecurityRisk` plus typed confirmation for never-default; `-Only/-Skip id`; named lists like winutil presets.
- **State snapshot + exact revert**: before each step record prior value or absence (registry), StartMode (service), task state, AppX name + InstallLocation; write `state-<timestamp>.json`; `Undo-Run <id|latest>` replays in reverse. Delete values that were absent; never rely on remembered defaults (hints only).
- **Restore point** (bypass 24h limit) + optional `reg export` of touched keys; `Revert-All` command.
- **-WhatIf / audit mode**: print current vs desired per tweak, no writes (Win11Debloat WhatIf, winutil style diff). `Test-` drift check after feature updates to re-apply.
- **Logging**: transcript + structured JSONL per step (id, before, after, result).
- **Pre-flight**: admin; PowerShell 5.1 or MSI PS7 (MSIX breaks DISM cmdlets); Constrained Language Mode; Windows build gate (26100/26200 supported); edition (warn AllowTelemetry=0 not honoured on Pro); laptop/battery detection (skip hibernate off, ultra plan); **detect Entra-joined, hybrid, domain-joined or Intune/MDM-managed devices (warn; policy keys may conflict, NTP and update tweaks skipped by default)**; Tamper Protection state; BitLocker state.
- **Per-tweak verification**: after apply, read back and compare; report Applied / Verified / Failed / Skipped(reason).
- **Idempotent**: skip when already at target; re-run safe.
- **Guard rails**: denylist (ClipSVC, AppXSvc, InstallService, LicenseManager, WaaSMedicSvc, UsoSvc, TokenBroker, WpnService, StateRepository, Store, App Installer, Windows Security); never delete service keys (disable instead).
- **Default-user hive** (`reg load HKU\AME_UserHive_Default`) for HKCU tweaks so new accounts inherit; unload afterwards.
- **Measurement harness**: record idle committed RAM, process count, service count, boot time over N repeats before/after, since sourced numbers are unreliable.
- Licensing: ReviOS playbook CC-BY-SA-4.0, revitool and Atlas GPL-3.0: reimplement from behaviour, do not copy files.

## Top 20 tweaks to implement first

| # | id | preset | note |
|---|---|---|---|
| 1 | `snapshot-restore-point` | safe | 5 projects, other |
| 2 | `telemetry-allowtelemetry-policy` | safe | 6 projects, telemetry-privacy |
| 3 | `priv-contentdelivery-off` | safe | 5 projects, telemetry-privacy |
| 4 | `priv-consumer-features-off` | safe | 4 projects, telemetry-privacy |
| 5 | `priv-advertising-id` | safe | 5 projects, telemetry-privacy |
| 6 | `priv-activity-history` | safe | 5 projects, telemetry-privacy |
| 7 | `ai-recall-disable` | safe | 6 projects, components |
| 8 | `ai-copilot-disable` | safe | 5 projects, components |
| 9 | `net-delivery-optimization-off` | safe | 6 projects, network |
| 10 | `perf-ntfs-lastaccess` | safe | 2 projects, performance |
| 11 | `perf-win32priority-separation` | safe | 2 projects, performance |
| 12 | `pwr-fast-startup-off` | safe | 3 projects, power |
| 13 | `perf-gamedvr-off` | safe | 3 projects, performance |
| 14 | `task-telemetry-set` | safe | 2 projects, scheduled-tasks |
| 15 | `priv-autologgers-off` | safe | 2 projects, telemetry-privacy |
| 16 | `priv-ceip-disable` | safe | 2 projects, telemetry-privacy |
| 17 | `edge-debloat-policies` | safe | 4 projects, edge-browser |
| 18 | `appx-consumer-bloat` | balanced | 7 projects, appx |
| 19 | `svc-diagtrack-disable` | balanced | 4 projects, services |
| 20 | `ui-classic-context-menu` | safe | 3 projects, ui-shell |

Ordering logic: reversible policy/HKCU keys done by many projects first, then scheduled tasks, then AppX allowlist, then services.

## Never include by default

- Defender disable/removal, cloud-reporting off (`sec-defender-disable-policy`, `priv-defender-cloud-reporting-off`): malware exposure; Tamper Protection blocks it by design and the tool must not circumvent it.
- SmartScreen, Edge SmartScreen off; **Smart App Control off** (one-way without reinstall).
- VBS/HVCI/Credential Guard off, CPU mitigations off, UAC secure desktop off: real security cost; HVCI may be re-enabled by Windows in Oct 2026.
- Windows Update disable / NoAutoUpdate / wuauserv off, root-cert auto-update off, time sync off: no patches, broken TLS/Kerberos; never disable WaaSMedicSvc.
- BitLocker auto-encryption block and decrypt: data-at-rest loss.
- Edge force removal, WinSxS pruning, Store removal, MSA sign-in block, wlidsvc/LicenseManager off: break WebView2, Store, Xbox, sign-in.
- Hosts blocklists with unknown content (ReviOS) and unverified BBRv2/BCD tweaks.
- Hibernate off and Ultimate-style plan on laptops (overheating reports); OneDrive uninstall without Known Folder Move undo.

## Sources (deduped, 36)

- https://docs.atlasos.net/faq/install-faq/removed-features/
- https://github.com/Raphire/Win11Debloat
- https://github.com/meetrevision/packages/blob/main/defender-removal-amd64.yaml
- https://github.com/meetrevision/playbook/blob/c6c6e7572c19de403f6acef80717c35fa344f366/src/Configuration/Tasks/start.yml
- https://github.com/meetrevision/playbook/releases/tag/23.04
- https://github.com/ntdevlabs/tiny11builder/blob/main/tiny11Coremaker.ps1
- https://github.com/ntdevlabs/tiny11builder/blob/main/tiny11maker.ps1
- https://github.com/orgs/Atlas-OS/discussions/1699
- https://github.com/raphire/Win11Debloat/wiki/App-Removal
- https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services
- https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity
- https://mintlify.wiki/Atlas-OS/Atlas/features/security
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/atlas/appx.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/atlas/services.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/custom.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/misc/config-time.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/performance/system/win32-priority-separation.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/privacy/telemetry/disallow-data-collection.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/qol/explorer/remove-context-menus/paint-3D.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/scripts/script-core-isolation.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/scripts/script-mitigations.yml
- https://raw.githubusercontent.com/Atlas-OS/Atlas/main/src/playbook/Configuration/tweaks/scripts/script-power.yml
- https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/config/feature.json
- https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/config/tweaks.json
- https://raw.githubusercontent.com/Raphire/Win11Debloat/master/README.md
- https://raw.githubusercontent.com/Raphire/Win11Debloat/master/Regfiles/Disable_AI_Recall.reg
- https://raw.githubusercontent.com/Raphire/Win11Debloat/master/Regfiles/Disable_Bing_Cortana_In_Search.reg
- https://raw.githubusercontent.com/Raphire/Win11Debloat/master/Regfiles/Disable_Copilot.reg
- https://raw.githubusercontent.com/farag2/Sophia-Script-for-Windows/master/README.md
- https://raw.githubusercontent.com/meetrevision/playbook/main/src/Configuration/Tasks/final.yml
- https://raw.githubusercontent.com/meetrevision/playbook/main/src/Configuration/Tasks/services.yml
- https://revi.cc/docs/faq/troubleshoot/overheating
- https://revi.cc/docs/features
- https://tech.yahoo.com/computing/articles/tested-4-windows-debloating-tools-100000336.html
- https://thefilibusterblog.com/my-experience-debloating-windows-11-3-unexpected-drawbacks-revealed/
