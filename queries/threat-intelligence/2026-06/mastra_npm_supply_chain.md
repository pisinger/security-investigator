# Sapphire Sleet — Mastra npm Supply Chain Compromise (easy-day-js) — Threat Hunts

**Created:** 2026-06-24  
**Platform:** Microsoft Defender XDR  
**Tables:** DeviceProcessEvents, DeviceNetworkEvents, DeviceFileEvents, DeviceRegistryEvents  
**Keywords:** Sapphire Sleet, npm, supply chain, postinstall, easy-day-js, dayjs, typosquat, mastra, setup.cjs, protocal.cjs, NvmProtocal, NodePackages, dropper, second-stage payload, detached node process, NODE_TLS_REJECT_UNAUTHORIZED, reflective .NET, PowerShell backdoor, onweblive, maskasd, Defender exclusion, scdev, svchost, service persistence, RunOnce, Registry Run key, anti-forensic, PSReadLine, North Korea, BlueNoroff, UNC1069, crypto wallet theft  
**MITRE:** T1195.002, T1546.016, T1059.007, T1059.001, T1027, T1140, T1071.001, T1105, T1547.001, T1543.003, T1620, T1562.001, T1070.003, T1217, T1082, T1555.003, T1539, T1041  
**Domains:** endpoint  
**Timeframe:** Last 30 days (configurable)  
**Source:** [From package to postinstall payload: Inside the Mastra npm supply chain compromise by Sapphire Sleet (2026-06-17)](https://www.microsoft.com/en-us/security/blog/2026/06/17/postinstall-payload-inside-mastra-npm-supply-chain-compromise/)

---

## Threat Overview

Microsoft Threat Intelligence attributes (high confidence) a large-scale npm supply chain attack — affecting **140+ packages** across the `mastra` and `@mastra` scopes — to **Sapphire Sleet**, a North Korean state actor focused on the financial/cryptocurrency sector (overlaps: BlueNoroff, UNC1069, STARDUST CHOLLIMA, CryptoCore). The compromise originated from takeover of the `ehindero` npm maintainer account, which was used to inject `easy-day-js@^1.11.21` — a malicious typosquat of the popular `dayjs` library — as a new dependency into every poisoned package.

`easy-day-js@1.11.22` carried a `postinstall` hook that executed an obfuscated dropper (`setup.cjs`), disabled TLS certificate verification, beaconed to attacker C2, downloaded a ~41 KB cross-platform Node.js tasking implant, and spawned it as a **detached, window-hidden** process. Because the payload runs during `npm install`, any developer workstation or CI/CD pipeline that ran `npm install`/`npm update` after the compromised versions were published was exposed. On high-value Windows hosts the actor escalated to a PowerShell backdoor (separate infrastructure), reflective .NET assembly injection into `cmd.exe`, Registry Run-key persistence, Microsoft Defender exclusions, and a SYSTEM-context service implant (`scdev`).

### TTP Summary
| Capability | TTP |
|---|---|
| Compromised npm dependency auto-runs on install | Supply Chain Compromise (T1195.002) + npm `postinstall` hook (T1546.016) |
| Obfuscated `setup.cjs` dropper executed by `node` | JavaScript execution (T1059.007), Obfuscated/Encoded payload (T1027, T1140) |
| TLS verification disabled, C2 beacon, second-stage download | App-layer C2 (T1071.001), Ingress tool transfer (T1105) |
| Detached, hidden Node.js implant (`protocal.cjs`) | Masquerading as NVM/Node; hidden window execution (T1027) |
| Registry Run-key + RunOnce persistence (`NvmProtocal`, `MicrosoftUpdate`) | Registry Run Keys (T1547.001) |
| Cross-platform login persistence (LaunchAgent / systemd / Run key) | Boot/Logon Autostart (T1547.001) |
| PowerShell backdoor download cradle (`iwr … | iex`, hidden window) | PowerShell (T1059.001) |
| Reflective .NET assembly loaded in-memory, injected into `cmd.exe` | Reflective Code Loading (T1620) |
| Microsoft Defender exclusion added for `System32` | Impair Defenses: Disable/Modify Tools (T1562.001) |
| Service-level SYSTEM implant (`scdev` shared `svchost.exe -k`) | Create/Modify System Process: Windows Service (T1543.003) |
| PSReadLine history file deleted + history disabled | Clear Command History (T1070.003) |
| Crypto-wallet extension + browser credential/cookie theft | Credentials from Web Browsers (T1555.003), Steal Web Session Cookie (T1539) |

### ⚠️ Hunt Pitfalls
| Pitfall | Mitigation |
|---|---|
| `node`/`node.exe` and `npm install` are ubiquitous on developer & CI hosts | Anchor on the campaign artifact strings (`setup.cjs`, `easy-day-js`, `protocal.cjs`) or pair with a C2/persistence hit; scope to non-developer assets where node activity is itself anomalous |
| Published IOCs (hashes, C2 IPs, domains) rot quickly after disclosure | Treat IOC sweeps as point-in-time; refresh from current Microsoft TI / VirusTotal and re-run in Sentinel Data Lake (>30d) for retrospective coverage |
| `setup.cjs` runs only during install — short-lived process, easy to miss | Hunt continuously (NRT/hourly) and corroborate with the dropped marker files (`.pkg_history`, `.pkg_logs`) and the detached implant |
| Second-stage payload is a randomly named `.js` in home/temp | The filename is not a stable IOC — pivot on the parent `node` install context and outbound C2 instead |
| Reflective .NET stage is fileless | Disk/file IOC sweeps will miss it — rely on the network C2 and PowerShell cradle signals |
| Generic `iwr … | iex -w h` is noisy in admin-heavy estates | For alerting, anchor on the actor C2 domains (`onweblive.org`, `maskasd.com`); keep the generic branch for hunting only |

---

## Quick Reference — Query Index

| # | Query | Use Case | Key Table |
|---|-------|----------|-----------|
| 1 | [Malicious npm postinstall dropper / implant execution by node](#query-1-malicious-npm-postinstall-dropper--implant-execution-by-node) | Investigation | `DeviceProcessEvents` |
| 2 | [Outbound connections to Mastra-compromise C2 IPs](#query-2-outbound-connections-to-mastra-compromise-c2-ips) | Investigation | `DeviceNetworkEvents` |
| 3 | [Post-compromise backdoor domain/URL beacons](#query-3-post-compromise-backdoor-domainurl-beacons) | Investigation | `DeviceNetworkEvents` |
| 4 | [File-hash IOC sweep (dropper, tarballs, implant, scripts)](#query-4-file-hash-ioc-sweep-dropper-tarballs-implant-scripts) | Investigation | `DeviceFileEvents` |
| 5 | [Registry Run-key / RunOnce persistence (NvmProtocal / MicrosoftUpdate)](#query-5-registry-run-key--runonce-persistence-nvmprotocal--microsoftupdate) | Investigation | `DeviceRegistryEvents` |
| 6 | [NVM/Node masquerade persistence artifacts on disk](#query-6-nvmnode-masquerade-persistence-artifacts-on-disk) | Investigation | `DeviceFileEvents` |
| 7 | [Post-compromise PowerShell backdoor download cradle](#query-7-post-compromise-powershell-backdoor-download-cradle) | Investigation | `DeviceProcessEvents` |
| 8 | [Defender exclusion for System32 + SYSTEM service implant](#query-8-defender-exclusion-for-system32--system-service-implant) | Investigation | `DeviceProcessEvents` |
| 9 | [Anti-forensic PowerShell history tampering](#query-9-anti-forensic-powershell-history-tampering) | Investigation | `DeviceProcessEvents` |


## IOC Reference

> All indicators below are transcribed verbatim from the article's *Indicators of compromise* section. **IOCs rot** — operators rotate infrastructure after disclosure. Refresh from current Microsoft TI before relying on direct-match hunts, and run IOC sweeps in Sentinel Data Lake (>30d) for retrospective coverage beyond the 30-day Advanced Hunting window.

**Network indicators**

| Indicator | Type | Description |
|---|---|---|
| `23.254.164.92` | IP | Primary C2 server |
| `23.254.164.123` | IP | Secondary C2 (from deobfuscated strings) |
| `https://23.254.164.92:8000/update/49890878` | URL | Payload download endpoint |
| `teams.onweblive.org` | Domain | Post-compromise PowerShell backdoor delivery |
| `https://teams.onweblive.org/api/update/8555575039/4` | URL | PowerShell backdoor download endpoint |
| `maskasd.com` | Domain | Post-compromise C2 beacon domain |
| `https://maskasd.com/8555575039` | URL | Post-compromise C2 beacon endpoint |

**File indicators (SHA-256)**

| Indicator | Description |
|---|---|
| `B122A9873BEDF145AE2A7FD024B5F309007DBB025149F4DC4AC3F7E4F32A36A4` | `setup.cjs` (malicious postinstall dropper) |
| `AE70DD4F6BC0D1C8C2848E4E6B51934626C4818DCB5AF99D080DDBD7DC337185` | `easy-day-js-1.11.22.tgz` (weaponized tarball) |
| `4A8860240E4231C3A74C81949BE655A28E096A7D72F38FBE84E5B37636B98417` | `easy-day-js-1.11.21.tgz` (clean bait tarball) |
| `B73DE25C053C3225A077738A1FCBD9CA6966D7B3CD6F5494A30F0AA0EAE55C7E` | `mastra-1.13.1.tgz` (compromised CLI tarball) |
| `221c45a790dec2a296af57969e1165a16f8f49733aeab64c0bbd768d9943badf` | `protocol.cjs` (detached implant) |
| `50eae63d3e24be9ca8803f4b5a0408aef97ee3fab7af018d8c2dde7c359edd65` | Downloader and backdoor PowerShell script |
| `1d1bf5e8c1539d2f05b1429235b8f4990f87036774be95157b315a7803dd5526` | Second-stage PowerShell script |

**Host / package indicators**

| Indicator | Type | Description |
|---|---|---|
| `$TMPDIR/.pkg_history` | File artifact | Install path of the compromised package |
| `$TMPDIR/.pkg_logs` | File artifact | XOR 0x80–encoded string `easy-day-js` |
| `protocal.cjs` (deliberate misspelling) | File artifact | Persisted implant (Windows: `C:\ProgramData\NodePackages\`) |
| `NvmProtocal` / `MicrosoftUpdate` | Registry value | Run-key persistence value names |
| `C:\ProgramData\system.bat` | File artifact | Backdoor persistence loader |
| `scdev` / `scdev.dll` | Service / DLL | SYSTEM-context service implant |
| `easy-day-js` | npm package | Malicious typosquat of `dayjs` |
| `ehindero` / `sergey2016` | npm accounts | Compromised publisher / typosquat publisher |

---

## Query 1: Malicious npm postinstall dropper / implant execution by node

**Purpose:** Detects `node` executing the campaign's dropper or persisted implant by command-line artifact (`setup.cjs`, `easy-day-js`, `protocal.cjs`). A clean estate returns 0; any hit on a non-build host is high-confidence.  
**Severity:** High  
**MITRE:** T1546.016, T1059.007, T1195.002
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "Execution"
title: "Malicious npm postinstall payload executed by node on {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
  - type: user
    identifier: accountName
recommendedActions: "A node process referenced a Sapphire Sleet Mastra-compromise artifact (setup.cjs / easy-day-js / protocal.cjs). Isolate the host, capture $TMPDIR/.pkg_history and .pkg_logs and any randomly named .js in the user home/temp, review npm install history for easy-day-js / compromised @mastra versions, and rotate credentials/tokens present on the device."
adaptation_notes: "Already row-level. Add DeviceId + ReportId for CD. High fidelity — artifact strings are campaign-specific."
-->

```kql
DeviceProcessEvents
| where Timestamp > ago(30d)
| where FileName in~ ("node", "node.exe")
| where ProcessCommandLine has_any ("setup.cjs", "easy-day-js", "protocal.cjs", "protocol.cjs")
| project Timestamp, DeviceName, AccountName, FileName, ProcessCommandLine,
    FolderPath, InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 in an unaffected environment. The artifact strings are campaign-specific, so any match warrants immediate triage.

---

## Query 2: Outbound connections to Mastra-compromise C2 IPs

**Purpose:** Direct network IOC sweep for the primary/secondary C2 addresses. Mirrors the article's published hunt.  
**Severity:** High  
**MITRE:** T1071.001, T1105
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "CommandAndControl"
title: "Connection to Mastra-compromise C2 IP from {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "Device contacted a published Sapphire Sleet C2 IP. Isolate, identify the initiating process, and hunt for the npm postinstall chain (Query 1) and persistence (Queries 5-6). IOCs rot — confirm against current Microsoft TI."
adaptation_notes: "Row-level network IOC match. Add DeviceId + ReportId. Refresh IP list periodically."
-->

```kql
DeviceNetworkEvents
| where Timestamp > ago(30d)
| where RemoteIP in ("23.254.164.92", "23.254.164.123")
| project Timestamp, DeviceName, RemoteIP, RemotePort, RemoteUrl,
    InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 expected (post-disclosure infrastructure). A hit is a high-confidence compromise indicator.

---

## Query 3: Post-compromise backdoor domain/URL beacons

**Purpose:** Network IOC sweep for the post-compromise PowerShell backdoor and beacon domains/URLs.  
**Severity:** High  
**MITRE:** T1071.001, T1105
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "CommandAndControl"
title: "Connection to Sapphire Sleet backdoor domain from {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "Device resolved/contacted a published post-compromise backdoor domain (onweblive.org / maskasd.com). Treat as hands-on-keyboard escalation: isolate, hunt for the PowerShell cradle (Query 7) and service persistence (Query 8)."
adaptation_notes: "Row-level URL IOC match. Add DeviceId + ReportId. Domains rot — refresh from current TI."
-->

```kql
DeviceNetworkEvents
| where Timestamp > ago(30d)
| where RemoteUrl has_any ("onweblive.org", "maskasd.com")
    or RemoteUrl has "23.254.164.92" or RemoteUrl has "23.254.164.123"
| project Timestamp, DeviceName, RemoteUrl, RemoteIP, RemotePort,
    InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 expected. Any hit indicates post-compromise C2 and should be escalated.

---

## Query 4: File-hash IOC sweep (dropper, tarballs, implant, scripts)

**Purpose:** Direct SHA-256 sweep for the published file indicators across file events. Note the reflective .NET stage is fileless and will not appear here.  
**Severity:** High  
**MITRE:** T1195.002, T1105
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "Execution"
title: "Mastra-compromise file IOC observed on {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "A published Sapphire Sleet file hash was written/observed on the device. Isolate and triage. Hashes rot as samples are rebuilt — refresh from current Microsoft TI / VirusTotal."
adaptation_notes: "Row-level hash match. Add ReportId. For full coverage also sweep DeviceProcessEvents.SHA256 and DeviceImageLoadEvents.SHA256 with the same list."
-->

```kql
DeviceFileEvents
| where Timestamp > ago(30d)
| where SHA256 in (
    "b122a9873bedf145ae2a7fd024b5f309007dbb025149f4dc4ac3f7e4f32a36a4",
    "ae70dd4f6bc0d1c8c2848e4e6b51934626c4818dcb5af99d080ddbd7dc337185",
    "4a8860240e4231c3a74c81949be655a28e096a7d72f38fbe84e5b37636b98417",
    "b73de25c053c3225a077738a1fcbd9ca6966d7b3cd6f5494a30f0aa0eae55c7e",
    "221c45a790dec2a296af57969e1165a16f8f49733aeab64c0bbd768d9943badf",
    "50eae63d3e24be9ca8803f4b5a0408aef97ee3fab7af018d8c2dde7c359edd65",
    "1d1bf5e8c1539d2f05b1429235b8f4990f87036774be95157b315a7803dd5526")
| project Timestamp, DeviceName, FileName, FolderPath, SHA256,
    InitiatingProcessFileName, InitiatingProcessAccountName, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 in an unaffected environment. A match is a direct compromise indicator. Pair with `DeviceProcessEvents` / `DeviceImageLoadEvents` SHA-256 sweeps for execution/load coverage.

---

## Query 5: Registry Run-key / RunOnce persistence (NvmProtocal / MicrosoftUpdate)

**Purpose:** Detects the campaign's autostart persistence — Run-key values pointing at the Node implant or `system.bat` loader.  
**Severity:** High  
**MITRE:** T1547.001
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "Persistence"
title: "Sapphire Sleet Run-key persistence on {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "A Run/RunOnce value matching the Mastra-compromise persistence was created (NvmProtocal / MicrosoftUpdate / NodePackages / system.bat / protocal.cjs). Inspect the value data, remove persistence after triage, and hunt for the implant and C2."
adaptation_notes: "Row-level registry event. Add DeviceId + ReportId. Value names/data are campaign-specific — high fidelity."
-->

```kql
DeviceRegistryEvents
| where Timestamp > ago(30d)
| where RegistryKey has @"CurrentVersion\Run"
| where RegistryValueName has_any ("NvmProtocal", "MicrosoftUpdate")
    or RegistryValueData has_any ("protocal.cjs", "system.bat", "NodePackages")
| project Timestamp, DeviceName, ActionType, RegistryKey, RegistryValueName,
    RegistryValueData, InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 expected. The `NvmProtocal`/`MicrosoftUpdate` value names and `system.bat`/`NodePackages` data are campaign-specific.

---

## Query 6: NVM/Node masquerade persistence artifacts on disk

**Purpose:** Detects the dropped implant files that masquerade as legitimate Node/NVM installs across Windows/macOS/Linux drop locations.  
**Severity:** High  
**MITRE:** T1547.001, T1027
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "Persistence"
title: "Node/NVM masquerade implant file on {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "An implant file mimicking Node/NVM (protocal.cjs / NodePackages / nvmconf / com.nvm.protocal.plist) was written. Triage the path, capture the file, and correlate with Run-key persistence (Query 5) and C2 (Queries 2-3)."
adaptation_notes: "Row-level file event. Add DeviceId + ReportId. NodePackages/nvmconf are non-standard directory names — low FP."
-->

```kql
DeviceFileEvents
| where Timestamp > ago(30d)
| where FileName in~ ("protocal.cjs", "protocol.cjs", "nvmconf.service", "com.nvm.protocal.plist")
    or FolderPath has_any (@"\NodePackages", "nvmconf", "NodePackages/")
| project Timestamp, DeviceName, ActionType, FileName, FolderPath,
    InitiatingProcessFileName, InitiatingProcessAccountName, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 expected. `protocal.cjs` is a deliberate misspelling and the `NodePackages`/`nvmconf` directories are not standard Node paths.

---

## Query 7: Post-compromise PowerShell backdoor download cradle

**Purpose:** Hunts the hidden PowerShell download-and-execute cradle delivering the Sapphire Sleet backdoor. The actor-domain branch is high fidelity; the generic `iwr … | iex` hidden-window branch is hunt-only and noisier.  
**Severity:** High  
**MITRE:** T1059.001, T1105
<!-- cd-metadata
cd_ready: false
adaptation_notes: "Hunt-only as written. The generic iwr/iex hidden-window branch is noisy in admin-heavy estates. For custom detection, keep only the actor-domain branch (onweblive.org / maskasd.com) as a high-fidelity row-level rule, or pair the generic branch with a C2 hit."
-->

```kql
DeviceProcessEvents
| where Timestamp > ago(30d)
| where FileName in~ ("powershell.exe", "pwsh.exe")
| where ProcessCommandLine has_any ("onweblive.org", "maskasd.com")
    or (ProcessCommandLine has_any ("iwr", "invoke-webrequest", "iex", "invoke-expression")
        and ProcessCommandLine has_any ("-w h", "-windowstyle hidden", "-w hidden"))
| project Timestamp, DeviceName, AccountName, ProcessCommandLine,
    InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** Actor-domain matches are 0 in a clean estate. The generic branch may surface benign admin tooling — review and allowlist known-good automation before alerting.

---

## Query 8: Defender exclusion for System32 + SYSTEM service implant

**Purpose:** Detects the post-compromise defense-evasion and service-level persistence: adding a Defender exclusion for `System32` and creating the `scdev` shared-`svchost` service.  
**Severity:** High  
**MITRE:** T1562.001, T1543.003
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "DefenseEvasion"
title: "Defender exclusion / scdev service persistence on {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "A Defender System32 exclusion or the scdev svchost service was created — both are late-stage Sapphire Sleet actions implying SYSTEM-context compromise. Isolate immediately, review the service DLL (scdev.dll), and engage IR."
adaptation_notes: "Row-level process event. Add DeviceId + ReportId. scdev is campaign-specific; the Defender-exclusion-of-System32 branch is rare and high fidelity."
-->

```kql
DeviceProcessEvents
| where Timestamp > ago(30d)
| where (ProcessCommandLine has_any ("Add-MpPreference", "Set-MpPreference")
        and ProcessCommandLine has "ExclusionPath" and ProcessCommandLine has "System32")
    or ProcessCommandLine has "scdev"
    or (ProcessCommandLine has "sc " and ProcessCommandLine has "create"
        and ProcessCommandLine has "svchost.exe -k")
| project Timestamp, DeviceName, AccountName, FileName, ProcessCommandLine,
    InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** 0 expected. Adding a Defender exclusion for `System32` or creating an `scdev` service is highly anomalous outside this campaign.

---

## Query 9: Anti-forensic PowerShell history tampering

**Purpose:** Detects the backdoor's anti-forensic cleanup — deleting the PSReadLine history file and disabling future history recording.  
**Severity:** Medium  
**MITRE:** T1070.003
<!-- cd-metadata
cd_ready: true
schedule: "1H"
category: "DefenseEvasion"
title: "PowerShell history tampering on {{DeviceName}}"
impactedAssets:
  - type: device
    identifier: deviceName
recommendedActions: "PowerShell command-history deletion or HistorySaveStyle=SaveNothing observed — consistent with Sapphire Sleet anti-forensics. Correlate with the backdoor cradle (Query 7) and C2 before closing; some hardening tooling legitimately disables history."
adaptation_notes: "Row-level process event. Add DeviceId + ReportId. Rare-but-not-unique — allowlist sanctioned hardening/EDR tooling that sets SaveNothing."
-->

```kql
DeviceProcessEvents
| where Timestamp > ago(30d)
| where ProcessCommandLine has "HistorySavePath"
    or (ProcessCommandLine has "Set-PSReadLineOption" and ProcessCommandLine has "SaveNothing")
| project Timestamp, DeviceName, AccountName, FileName, ProcessCommandLine,
    InitiatingProcessFileName, InitiatingProcessCommandLine, DeviceId, ReportId
| sort by Timestamp desc
```

**Expected results:** Typically 0–low. Investigate any hit; allowlist sanctioned hardening/EDR scripts that legitimately disable PowerShell history.

---

## General Tuning Notes

1. **IOC refresh.** Every hash/IP/domain here is point-in-time from the 2026-06-17 disclosure. Sapphire Sleet rotates infrastructure quickly — refresh IOC lists from current Microsoft Threat Intelligence / VirusTotal and re-run Queries 2–4 periodically. For retrospective coverage beyond the 30-day Advanced Hunting window, run the IOC sweeps in **Sentinel Data Lake** (`mcp_sentinel-data_query_lake`), changing `Timestamp` → `TimeGenerated` for the Device* tables as applicable.
2. **Developer / CI noise.** `node`, `npm install`, and PowerShell automation are normal on developer workstations and build agents. The artifact-anchored queries (1, 5, 6, 8) are campaign-specific and low-FP; the broader behavioral branch in Query 7 is hunt-only. Where possible, scope behavioral detections to non-developer assets or maintain a developer/CI allowlist.
3. **Telemetry gaps.** The second-stage reflective `.NET` injection is fileless and the second-stage `.js` payload is randomly named — neither yields a stable disk IOC. Rely on the network C2 (Queries 2–3) and the PowerShell cradle (Query 7) for those stages. Host marker files (`$TMPDIR/.pkg_history`, `$TMPDIR/.pkg_logs`) are useful corroboration on Unix-like dev hosts.
4. **Prevention corroboration.** Mastra `1.13.0` / `@mastra/core` `1.42.0` and earlier are unaffected; `npm install --ignore-scripts` blocks postinstall execution. Auditing lockfiles for `easy-day-js` is a strong complementary control to these runtime hunts.
5. **CD-readiness summary.** Queries 1–6, 8, 9 are row-level and suitable for custom detections (add `DeviceId` + `ReportId`, then apply the detection-authoring Query Adaptation Checklist). Query 7 is `cd_ready: false` as written — restrict it to the actor-domain branch for production alerting.

---

## References
- Microsoft Threat Intelligence — [From package to postinstall payload: Inside the Mastra npm supply chain compromise by Sapphire Sleet](https://www.microsoft.com/en-us/security/blog/2026/06/17/postinstall-payload-inside-mastra-npm-supply-chain-compromise/)
- Microsoft Threat Intelligence — [Mitigating the Axios npm supply chain compromise (Sapphire Sleet, April 2026)](https://www.microsoft.com/en-us/security/blog/2026/04/01/mitigating-the-axios-npm-supply-chain-compromise/)
- MITRE ATT&CK — [T1195.002 Compromise Software Supply Chain](https://attack.mitre.org/techniques/T1195/002/), [T1546.016 Installer Packages](https://attack.mitre.org/techniques/T1546/016/), [T1620 Reflective Code Loading](https://attack.mitre.org/techniques/T1620/), [T1543.003 Windows Service](https://attack.mitre.org/techniques/T1543/003/)
- Companion files: [`queries/threat-intelligence/2026-05/npm_dependency_confusion.md`](../2026-05/npm_dependency_confusion.md), [`queries/threat-intelligence/2026-03/npm_supply_chain_attack.md`](../2026-03/npm_supply_chain_attack.md), [`queries/threat-intelligence/2026-04/sapphire_sleet_macos_intrusion.md`](../2026-04/sapphire_sleet_macos_intrusion.md)
