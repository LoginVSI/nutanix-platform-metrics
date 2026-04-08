# Nutanix to Login Enterprise Platform Metrics Integration

Collect Nutanix infrastructure metrics — at the cluster, host, and VM level — and surface them alongside Login Enterprise test data in the Platform Metrics UI. Built for EUC performance engineers who want full-stack visibility during load tests, continuous tests, and migration bake-offs without switching between tools.

This integration was originally developed in partnership with Nutanix and validated with Truist Bank. It is currently a **customer preview**.

---

## What This Does

During a Login Enterprise test, you care about what the underlying infrastructure is doing. Is the host CPU saturated? Are VMs getting disk latency? Is the cluster I/O bandwidth maxed out? The Nutanix integration pulls real-time metrics from Prism Element and Prism Central and sends them to Login Enterprise Platform Metrics, where they appear on the same timeline as your EUC test results.

**Use cases:**

- **Continuous Testing** — monitor cluster and host health alongside user experience scores 24/7
- **Load Testing** — correlate infrastructure saturation with EUC performance degradation as user count scales
- **Migration / Bake-off** — compare infrastructure behavior between environments (e.g., VMware Horizon vs. AVD on Nutanix AHV)

---

## Metrics Collected

### Cluster-Level (via Prism Element v2 API)

| Metric | Unit |
|--------|------|
| Cluster CPU Usage | percent |
| Cluster Memory Usage | percent |
| Cluster Storage IOPS (Total, Read, Write) | iops |
| Cluster Storage Latency (Avg, Read, Write) | ms |
| Cluster IO Bandwidth (Total, Read, Write) | kBps |

### Host-Level (via Prism Central v4 API)

| Metric | Unit |
|--------|------|
| Host CPU Usage | percent |
| Host Memory Usage | percent |
| Host Storage IOPS (Total, Read, Write) | iops |
| Host Storage Latency (Avg, Read, Write) | ms |
| Host IO Bandwidth (Total, Read, Write) | kBps |

### VM-Level (via Prism Central v4 API)

| Metric | Unit |
|--------|------|
| VM CPU Usage | percent |
| VM CPU Ready Time | percent |
| VM Memory Usage | percent |
| VM Disk Latency (Avg) | ms |
| VM Disk Bandwidth | kBps |
| VM Network RX | bytesPerSec |
| VM Network TX | bytesPerSec |

---

## Requirements

### Nutanix

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| AOS (Prism Element) | 6.7 | Cluster-level stats via PE v2 API |
| Prism Central | 2024.3 | Required for host and VM stats |
| AHV | 10.x | VM stats tested on AHV only |

> **Tested with:** AOS 6.8.1, Prism Central 2024.3, AHV 10.x
>
> **Prism Central 7.5+:** Enables automatic API version negotiation. On older PC versions (any `pc.YYYY.x` format), the script defaults to v4.0 automatically.

Cluster-level metrics work without Prism Central. Host and VM metrics require PC.

### Login Enterprise

- Login Enterprise appliance with Platform Metrics feature enabled
- API token with **Configuration** access level
- Network access from the machine running the script to both Nutanix port 9440 and Login Enterprise port 443

### PowerShell

- Windows PowerShell 5.1 (tested and validated)
- PowerShell 7.x (compatible, not primary target)
- No admin privileges required

---

## How It Works

### Data Flow

```
Nutanix Prism Element (port 9440)
  └── Cluster stats (PE v2 API)
        └── CPU, Memory, IOPS, Latency, Bandwidth

Nutanix Prism Central (port 9440)
  ├── Host stats (PC v4 clustermgmt API)
  │     └── CPU, Memory, IOPS, Latency, Bandwidth per host
  └── VM stats (PC v4 vmm API)
        └── CPU, Memory, Disk, Network per powered-on VM

        │
        ▼

Nutanix-LE-PlatformMetrics.ps1
  ├── Pre-flight checks (PE + PC connectivity)
  ├── API version negotiation (PC 7.5+ only)
  ├── Time sync with LE appliance
  ├── Collect cluster stats
  ├── Collect host stats (if -CollectHostStats)
  ├── Collect VM stats (if -CollectVmStats, optionally filtered by -VmFilter)
  ├── Build metric payloads (with customTags, componentType, instance)
  └── Upload to Login Enterprise Platform Metrics API

        │
        ▼

Login Enterprise Platform Metrics API (port 443)
  ├── Multi-environment mode: separate env per unit type
  │     ├── Nutanix-Percent  → CPU %, Memory %
  │     ├── Nutanix-IOPS     → Storage IOPS
  │     ├── Nutanix-Latency  → Storage Latency
  │     ├── Nutanix-Bandwidth → IO Bandwidth
  │     └── Nutanix-Network  → VM Network RX/TX
  └── Single-environment mode: all metrics to one env (Power BI)

        │
        ▼

Login Enterprise Platform Metrics UI
  └── Metrics appear on test result timeline
```

### Collector Script Execution Flow

```
START
│
├── Load configuration (defaults → command-line overrides)
├── Print startup config dump
│
├── PRE-FLIGHT
│   ├── Validate params (host, URLs, env IDs)
│   ├── Test Prism Central connectivity (if host/VM stats enabled)
│   └── Test Prism Element connectivity
│       └── FAIL → exit with error
│
├── API VERSION NEGOTIATION
│   ├── PC version is 7.5+ semantic format?
│   │   ├── YES → query PC for supported v4 versions → pick highest mutual version
│   │   └── NO  → PC is calendar-versioned (pre-7.5) → default to v4.0
│   └── Set negotiated version for all subsequent PC API calls
│
├── TIME SYNC
│   └── Adjust timestamps to match LE appliance clock
│
└── POLLING LOOP (each iteration)
    │
    ├── CLUSTER STATS (PE v2)
    │   └── hypervisor_cpu_usage_ppm, memory, iops, latency, bandwidth
    │
    ├── HOST STATS (PC v4, if -CollectHostStats and PC reachable)
    │   └── For each host in cluster:
    │       └── cpu, memory, iops, latency, bandwidth
    │
    ├── VM STATS (PC v4, if -CollectVmStats and PC reachable)
    │   ├── Get powered-on VM list
    │   ├── Apply -VmFilter (if set)
    │   └── For each matching VM (500ms delay between calls):
    │       └── cpu, cpu_ready, memory, disk_latency, disk_bandwidth, net_rx, net_tx
    │
    ├── BUILD PAYLOADS
    │   ├── Attach customTags (cluster_name, cluster_uuid, host_extid, vm_extid, etc.)
    │   ├── Single mode: all metrics → one environment ID
    │   └── Multi mode: route by unit type → correct environment ID
    │       └── Skip placeholder (00000000) env IDs
    │
    ├── UPLOAD TO LE
    │   ├── POST to /publicApi/v8-preview/platform-metrics
    │   └── Retry up to 3x with exponential backoff on failure
    │
    └── SLEEP (polling interval minus elapsed time)
        └── If elapsed > interval → start next iteration immediately with WARN
```

---

## Login Enterprise Setup

Before running the collector, set up Login Enterprise:

### 1. Enable Platform Metrics

Platform Metrics is currently a preview feature. Enable it in your browser's DevTools console (F12):

```javascript
leSetFeatureFlag('platformMetrics', 1)
```

Refresh after running.

### 2. Create Environments

Create one environment per unit type in Configuration → Environments:

| Environment Name | Unit Type | Metrics |
|-----------------|-----------|---------|
| Nutanix-Percent | percent | CPU %, Memory % |
| Nutanix-IOPS | iops | Storage IOPS |
| Nutanix-Latency | ms | Storage Latency |
| Nutanix-Bandwidth | kBps | IO Bandwidth |
| Nutanix-Network | bytesPerSec | VM Network RX/TX |

Copy the UUID of each environment from the browser URL bar when viewing the environment.

**Alternatively**, create a single environment (e.g. `Nutanix-All`) and use `-LEEnvironmentId` to send all metrics there. This is the recommended setup for Power BI.

### 3. Create a Continuous Test or Load Test

Link each environment to a continuous test or a load test. The Platform Metrics tab appears on test result pages for both test types.

- **Continuous Testing** — always-on monitoring, metrics collected 24/7 alongside user experience scores
- **Load Testing** — metrics collected during active load test runs, letting you correlate infrastructure saturation with EUC performance as user count scales

### 4. Create an API Token

Configuration → System Access Tokens → create a token with **Configuration** access level.

---

## Quick Start

### Cluster stats only (no PC required)

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPassword" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -LEApplianceUrl "https://your-le-appliance.example.com" `
    -EnvironmentIdPercent "uuid-percent" `
    -EnvironmentIdIops "uuid-iops" `
    -EnvironmentIdMs "uuid-ms" `
    -EnvironmentIdKBps "uuid-kbps" `
    -RunOnce
```

### Cluster + host + VM stats (requires Prism Central)

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPassword" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -PrismCentralHost "your-prism-central.example.com" `
    -ClusterExtId "your-cluster-ext-id" `
    -LEApplianceUrl "https://your-le-appliance.example.com" `
    -EnvironmentIdPercent "uuid-percent" `
    -EnvironmentIdIops "uuid-iops" `
    -EnvironmentIdMs "uuid-ms" `
    -EnvironmentIdKBps "uuid-kbps" `
    -EnvironmentIdBytesPerSec "uuid-network" `
    -CollectHostStats `
    -CollectVmStats `
    -RunOnce
```

### Single environment (Power BI mode)

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPassword" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -PrismCentralHost "your-prism-central.example.com" `
    -ClusterExtId "your-cluster-ext-id" `
    -LEApplianceUrl "https://your-le-appliance.example.com" `
    -LEEnvironmentId "uuid-single-env" `
    -CollectHostStats `
    -CollectVmStats `
    -RunOnce
```

### Continuous polling (run until Ctrl+C)

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPassword" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -LEApplianceUrl "https://your-le-appliance.example.com" `
    -LEEnvironmentId "uuid-single-env" `
    -CollectHostStats `
    -CollectVmStats
```

### Filter to specific VMs

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPassword" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -PrismCentralHost "your-prism-central.example.com" `
    -ClusterExtId "your-cluster-ext-id" `
    -LEApplianceUrl "https://your-le-appliance.example.com" `
    -LEEnvironmentId "uuid-single-env" `
    -CollectVmStats `
    -VmFilter "MyLauncher-01,MyLauncher-02,MyTarget-01" `
    -RunOnce
```

### Dry run (verify connectivity without uploading)

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPassword" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -LEApplianceUrl "https://your-le-appliance.example.com" `
    -LEEnvironmentId "uuid-single-env" `
    -CollectHostStats `
    -CollectVmStats `
    -DryRun -RunOnce
```

---

## Collector Script Parameters

### Nutanix connection

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-NutanixPassword` | **Yes** | Prism Element admin password |
| `-NutanixHost` | **Yes** | Prism Element IP or hostname (port 9440) |
| `-NutanixUser` | No | Prism Element username (default: admin) |
| `-PrismCentralHost` | Conditional | Required for `-CollectHostStats` or `-CollectVmStats` |
| `-ClusterExtId` | Conditional | Required for host/VM stats. Get from PC API or UI. |

### Login Enterprise connection

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-LEApiToken` | **Yes** | LE API token (Configuration access level) |
| `-LEApplianceUrl` | **Yes** | Full URL of LE appliance |
| `-LEApiVersion` | No | API version segment (default: v8-preview) |

### Environment ID modes (use one)

**Multi-environment mode** — routes metrics to separate LE environments by unit type. Required for proper Y-axis scaling in the LE UI.

| Parameter | Unit | Metrics |
|-----------|------|---------|
| `-EnvironmentIdPercent` | percent | CPU, Memory usage |
| `-EnvironmentIdIops` | iops | Storage IOPS |
| `-EnvironmentIdMs` | ms | Storage Latency |
| `-EnvironmentIdKBps` | kBps | IO Bandwidth |
| `-EnvironmentIdBytesPerSec` | bytesPerSec | VM Network RX/TX |

**Single-environment mode** — sends all metrics to one environment. Recommended for Power BI.

| Parameter | Description |
|-----------|-------------|
| `-LEEnvironmentId` | Single environment UUID for all metrics |

### Collection scope

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-CollectHostStats` | off | Enable host-level metrics (requires PC) |
| `-CollectVmStats` | off | Enable VM-level metrics (requires PC) |
| `-VmFilter` | (all) | Comma-separated VM names to collect. If omitted, collects all powered-on VMs. |

### Run control

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-RunOnce` | off | Run one iteration and exit |
| `-Iterations` | 0 (unlimited) | Run N iterations and exit |
| `-PollingIntervalSec` | 30 | Seconds between polls |
| `-DryRun` | off | Collect but do not upload |
| `-SkipTimeSync` | off | Skip LE time sync |

### Output and diagnostics

| Parameter | Description |
|-----------|-------------|
| `-LogDir` | Directory for log files (default: script directory) |
| `-Verbose` | Enable detailed per-metric logging |

### Certificate handling

| Parameter | Description |
|-----------|-------------|
| `-ImportServerCert` | Import LE appliance certificate into CurrentUser\Root before connecting |
| `-KeepCert` | Keep imported cert after script exits (default: remove on exit) |

> **Note on `-ImportServerCert`:** This imports into `CurrentUser\Root` and does not require admin. Some EDR/security tools (CrowdStrike, etc.) may flag this behavior. In environments where that is a concern, manually install the LE appliance certificate in your trust store instead and omit this flag.

---

## Retrieval Script

`Get-LEPlatformMetrics.ps1` queries the Login Enterprise API and exports metrics to CSV and JSON. Use it to verify data, pull results for analysis, or feed Power BI.

### Examples

```powershell
# Last 1 hour, single environment
.\Get-LEPlatformMetrics.ps1 `
    -LEApiToken "YourToken" `
    -BaseUrl "https://your-le-appliance.example.com" `
    -EnvironmentId "uuid-single-env" `
    -LastHours 1

# Last 1 hour, all 5 environments
.\Get-LEPlatformMetrics.ps1 `
    -LEApiToken "YourToken" `
    -BaseUrl "https://your-le-appliance.example.com" `
    -EnvironmentIdPercent "uuid-percent" `
    -EnvironmentIdIops "uuid-iops" `
    -EnvironmentIdMs "uuid-ms" `
    -EnvironmentIdKBps "uuid-kbps" `
    -EnvironmentIdBytesPerSec "uuid-network" `
    -LastHours 1

# Array mode (pass any number of env IDs)
.\Get-LEPlatformMetrics.ps1 `
    -LEApiToken "YourToken" `
    -BaseUrl "https://your-le-appliance.example.com" `
    -EnvironmentIds @("uuid-1","uuid-2") `
    -LastHours 2

# Specific time range
.\Get-LEPlatformMetrics.ps1 `
    -LEApiToken "YourToken" `
    -BaseUrl "https://your-le-appliance.example.com" `
    -EnvironmentId "uuid-single-env" `
    -StartTime "2026-04-08T10:00:00.000Z" `
    -EndTime "2026-04-08T11:00:00.000Z"
```

### Output files

| File | Description |
|------|-------------|
| `Get-LEPlatformMetrics_YYYYMMDD_HHMMSS.csv` | Flat data — one row per data point, all fields |
| `Get-LEPlatformMetrics_YYYYMMDD_HHMMSS.json` | Raw API response |
| `Get-LEPlatformMetrics_Log_YYYYMMDD_HHMMSS.txt` | Run log |

CSV columns: `timestamp, value, metricId, environmentKey, displayName, unit, instance, componentType, group, customTags`

### Retrieval script parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-LEApiToken` | **Yes** | LE API token |
| `-BaseUrl` | **Yes** | LE appliance URL |
| `-EnvironmentId` | Conditional | Single environment UUID |
| `-EnvironmentIds` | Conditional | Array of environment UUIDs |
| `-EnvironmentIdPercent/Iops/Ms/KBps/BytesPerSec` | Conditional | Per-unit environment UUIDs |
| `-LastHours` | No | Hours of data to retrieve (default: 1) |
| `-StartTime` | No | ISO 8601 start time (overrides -LastHours) |
| `-EndTime` | No | ISO 8601 end time |
| `-ApiVersion` | No | LE API version (default: v8-preview) |
| `-OutputDir` | No | Output directory (default: script dir) |
| `-MetricGroups` | No | Filter by metric group name |
| `-ImportServerCert` | No | Import LE cert before connecting |
| `-KeepCert` | No | Keep imported cert after exit |

---

## Finding Your Cluster ExtId

The Cluster ExtId is required for host and VM stats. Get it from Prism Central:

```
https://your-prism-central.example.com:9440/api/clustermgmt/v4.0/config/clusters
```

Authenticate with your Prism Central credentials. Look for `extId` in the response for your cluster.

---

## How Environments Work

Login Enterprise Platform Metrics can only display one Y-axis unit at a time. To show all Nutanix metrics on the same screen, you need separate environments per unit type — each linked to its own test. The Platform Metrics tab in the test result then shows metrics from that environment's unit group.

**Multi-environment setup** (full visibility):

```
Nutanix-Percent   → CPU %, Memory %          → linked to Continuous Test A
Nutanix-IOPS      → Storage IOPS             → linked to Continuous Test B
Nutanix-Latency   → Storage Latency          → linked to Continuous Test C
Nutanix-Bandwidth → IO Bandwidth             → linked to Continuous Test D
Nutanix-Network   → VM Network RX/TX         → linked to Continuous Test E
```

**Single-environment setup** (Power BI mode):

```
Nutanix-All → all metrics → linked to any test
```

Use `-LEEnvironmentId` for the single-environment mode. All metrics land in one place, which makes Power BI integration straightforward.

---

## Caveats and Known Behaviors

**VM stats require a warm-up period.** After a VM is created or powered on, Prism Central needs 5-10 minutes before the stats endpoint returns data. The script handles this gracefully and logs a note.

**VM Memory Usage at 100% for the Prism Central VM is expected.** PC pre-allocates its full memory allocation at startup. This is normal behavior, not a problem.

**Host metric count varies by run (typically 8-11).** Some host metrics return null when there is no activity for that stat in the sampling window (e.g., no read IOPS means no read latency value). The script skips nulls and uploads only what it gets. This is correct behavior.

**Cluster stats occasionally return 0 metrics on older CE hardware.** The Prism Element v2 API can intermittently return empty stats on Nutanix Community Edition. This does not affect production clusters.

**Prism Central v4 API rate limits VM stats calls.** If you have many VMs, rapid back-to-back calls will hit a 429 rate limit. The script adds a 500ms delay between VM calls to reduce this. On very large clusters (50+ VMs), the collection loop may exceed the 30-second polling interval — the script detects this and logs a warning, then starts the next iteration immediately rather than compounding the delay.

**PS5 error buffer count.** On PowerShell 5.1, the PS error buffer may show a high number (e.g. 64 errors) at the end of a run. This is PS5 accumulating all handled exceptions in the session. The `Errors logged` line in the summary is the accurate count of real errors. The PS error buffer is informational only.

**Prism Central connectivity.** If PC is unreachable, the script detects this at pre-flight and skips all PC-dependent work (version negotiation, host stats, VM stats). Cluster stats continue normally. The script will not hang waiting for PC timeouts mid-run.

**The `bytesPerSec` environment.** VM Network RX/TX metrics use `bytesPerSec` as their unit. This requires a separate environment if using multi-environment mode. If you do not configure `-EnvironmentIdBytesPerSec`, those metrics are silently skipped — no upload attempt is made and no error is logged.

---

## Troubleshooting

**Pre-flight fails with "Nutanix PE: connection failed"**
- Verify the host is reachable on port 9440
- Check the username and password
- Confirm VPN if required

**Pre-flight warns "Prism Central: connection failed"**
- Host and VM stats will be skipped for this run
- Cluster stats still collected and uploaded
- Check PC IP/hostname and port 9440 access

**Upload timeout errors**
- Usually transient — the retry logic (3 attempts, exponential backoff) handles these
- If persistent, check LE appliance connectivity and API token validity
- Verify environment IDs are correct — uploading to a non-existent env ID causes the server to close the connection

**VM stats show 404 errors**
- PC may not have collected a stats window yet for newly created VMs — wait 5-10 minutes
- Verify the VM ExtId is valid in PC (check `/api/vmm/v4.0/ahv/config/vms/{extId}`)

**429 Too Many Requests on VM stats**
- PC is rate limiting consecutive VM stats calls
- The script logs a WARN and skips that VM for this iteration
- Reduce the number of VMs being monitored with `-VmFilter`

**VmFilter returns 0 matches**
- Names are case-sensitive and must match exactly as they appear in Prism Element
- Check the VM name in the Prism Element UI

**Certificate errors on PS5**

If you get SSL/TLS or certificate errors connecting to the Login Enterprise appliance, the appliance's certificate is not trusted on the machine running the script. Two options:

Option 1 — let the script handle it:
```powershell
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" ... -ImportServerCert -RunOnce
```
This fetches and imports the LE appliance certificate into your `CurrentUser\Root` trust store automatically. No admin required. The cert is removed when the script exits unless you add `-KeepCert`.

Option 2 — install it manually (recommended in CrowdStrike/EDR environments):
1. Open `https://your-le-appliance.example.com` in a browser
2. Click the padlock → view certificate → export/download the certificate
3. Open `certmgr.msc` → Trusted Root Certification Authorities → Certificates → right-click → Import
4. Run the script without `-ImportServerCert`

Some EDR tools (CrowdStrike, etc.) may flag the automatic import approach. Option 2 avoids that entirely.

**Enable verbose logging for more detail:**
```powershell
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" ... -Verbose -RunOnce
```

---

## Where to Run the Scripts

The scripts can run from any Windows machine that has network access to both Nutanix (port 9440) and the Login Enterprise appliance (port 443). Common setups include:

- A dedicated management or jump box
- A Login Enterprise Launcher VM on the same network as the Nutanix cluster
- A workstation with VPN access to both environments

There is no agent, no service installation, and no requirement to run on the Nutanix host itself.

---

## Running as a Windows Scheduled Task

To run the collector continuously in the background without a PowerShell window open, set it up as a Windows Scheduled Task.

### Basic setup

1. Open Task Scheduler → Create Task
2. **General tab:** Give it a name (e.g. "Nutanix LE Metrics"), select "Run whether user is logged on or not", check "Run with highest privileges"
3. **Triggers tab:** New trigger → On a schedule → Daily, repeat every 5 minutes (or whatever interval you prefer)
4. **Actions tab:** New action → Start a program
   - Program: `powershell.exe`
   - Arguments:
   ```
   -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Nutanix-LE-PlatformMetrics.ps1" -NutanixPassword "YourPassword" -LEApiToken "YourToken" -NutanixHost "your-nutanix.example.com" -LEApplianceUrl "https://your-le-appliance.example.com" -LEEnvironmentId "your-env-uuid" -CollectHostStats -CollectVmStats
   ```
5. **Settings tab:** Check "If the task is already running, do not start a new instance"

The script handles its own polling loop internally — you do not need to configure repetition in Task Scheduler unless you want the OS to restart the script if it exits unexpectedly. The simplest approach is to run the script with no `-RunOnce` or `-Iterations` flag, let it loop indefinitely, and set the scheduled task to restart on failure.

> **Note:** Store credentials securely. Do not hardcode passwords in task arguments visible to other users. Use a dedicated service account with read-only Nutanix access where possible.

---



A Power BI connector and report template for Login Enterprise Platform Metrics is available at:

**[https://github.com/LoginVSI/LE-PBI-Connector](https://github.com/LoginVSI/LE-PBI-Connector)**

Use `-LEEnvironmentId` (single-environment mode) when running the collector alongside Power BI — all metrics land in one environment, which simplifies the connector configuration.

---

## Useful Links

| Resource | URL |
|----------|-----|
| Login Enterprise docs | https://docs.loginvsi.com |
| Configuring Environments | https://docs.loginvsi.com/login-enterprise/configuring-environments-optional |
| Continuous Testing guide | https://docs.loginvsi.com/login-enterprise/configuring-continuous-testing |
| Load Testing guide | https://docs.loginvsi.com/login-enterprise/configuring-load-testing |
| Nutanix v4 API reference | https://developers.nutanix.com/api-reference |
| Nutanix PC v4 API version negotiation | https://www.nutanix.dev/2026/01/23/nutanix-v4-sdk-api-version-negotiation-in-prism-central-7-5/ |
| Power BI connector repo | https://github.com/LoginVSI/LE-PBI-Connector |
| This repo | https://github.com/LoginVSI/nutanix-platform-metrics |

---

| File | Version | Description |
|------|---------|-------------|
| `Nutanix-LE-PlatformMetrics.ps1` | 2.0.0 | Collector script |
| `Get-LEPlatformMetrics.ps1` | 2.0.0 | Retrieval and export script |
| `README.md` | — | This file |

The config JSON file (`nutanix-config.json`) from earlier versions has been removed. All configuration is passed via command-line parameters.

---

## Security

Passwords and API tokens are never stored in scripts or config files. Always pass them as command-line parameters.

Certificate import (via `-ImportServerCert`) uses `CurrentUser\Root` and does not require admin privileges. Imported certificates are automatically removed after each run unless `-KeepCert` is specified.

---

## Version History

### v2.0.0 (April 2026)
- Host-level metrics via Prism Central v4 clustermgmt API
- VM-level metrics via Prism Central v4 vmm API
- Smart API version negotiation (PC 7.5+ uses endpoint, older uses v4.0 default)
- Single environment mode (`-LEEnvironmentId`) for Power BI
- `-VmFilter` for targeted VM collection
- `-CollectHostStats` and `-CollectVmStats` scope toggles
- `-EnvironmentIdBytesPerSec` for VM network metrics
- Pre-flight PC connectivity check
- Polling interval compensation when collection exceeds poll window
- Placeholder environment ID skip (no failed uploads on unconfigured envs)
- Get script updated to match nVector patterns — log file output, PS5 fallback, UriBuilder, componentType in CSV

### v1.5.0 (January 2026)
- Enterprise certificate handling (`-ImportServerCert`, `-KeepCert`)
- Truist pilot shipped

### v1.4.0
- Enhanced error handling, verbose mode, rate limit detection, graceful Ctrl+C, exit codes

### v1.3.0
- Required command-line params for sensitive data, config file support

### v1.2.0
- Multi-environment support, time sync, retry logic

### v1.0.0
- Initial release

---

## License

MIT License — Copyright (c) 2026 Login VSI

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.

---

*This is a customer preview. For questions or feedback, contact your Login VSI account team.*
