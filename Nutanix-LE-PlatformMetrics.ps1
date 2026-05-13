<#
.SYNOPSIS
    Nutanix to Login Enterprise Platform Metrics Collector

.DESCRIPTION
    Polls Nutanix cluster, host, and VM statistics from Prism Central v4 API
    and uploads them to Login Enterprise Platform Metrics API.

    Cluster-Level Metrics (PC v4 preferred, PE v2 fallback):
    - CPU Usage (%), Memory Usage (%)
    - Storage IOPS (total, read, write)
    - Storage Latency (avg, read, write) in ms
    - IO Bandwidth (total, read, write) in kBps

    Host-Level Metrics (via PC v4):
    - CPU Usage (%), Memory Usage (%)
    - Storage IOPS, Latency, Bandwidth per host

    VM-Level Metrics (via PC v4):
    - CPU Usage (%), CPU Ready Time (%)
    - Memory Usage (%)
    - Disk Latency (ms), Disk Bandwidth (kBps)
    - Network RX/TX (bytes/s)

    Environment Modes:
    - Single:  all metrics -> one environment ID (Power BI connector friendly)
    - Multi:   metrics split by unit type (percent/iops/ms/kBps) -> separate env IDs (LE web UI friendly)

.PARAMETER NutanixPassword
    REQUIRED. Nutanix admin password for both PE and PC.

.PARAMETER LEApiToken
    REQUIRED. Login Enterprise API token with Configuration access.

.PARAMETER NutanixHost
    Prism Element IP or FQDN. Default: value in script config.

.PARAMETER PrismCentralHost
    Prism Central IP or FQDN. Required for host/VM metrics.

.PARAMETER NutanixUser
    Nutanix admin username. Default: admin.

.PARAMETER ClusterExtId
    Nutanix cluster ExtId (UUID) for PC v4 API calls.

.PARAMETER LEApplianceUrl
    Login Enterprise appliance base URL. Default: value in script config.

.PARAMETER LEApiVersion
    Login Enterprise API version string. Default: v8-preview.

.PARAMETER LEEnvironmentId
    Single environment ID - all metrics go here (Power BI mode).
    Mutually exclusive with per-unit environment ID params below.

.PARAMETER EnvironmentIdPercent
    Environment ID for percent-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdIops
    Environment ID for iops-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdMs
    Environment ID for ms-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdKBps
    Environment ID for kBps-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdBytesPerSec
    Environment ID for bytes/s-unit metrics (network, multi-environment mode).

.PARAMETER CollectClusterStats
    Collect cluster-level metrics. Default: true.

.PARAMETER CollectHostStats
    Collect host-level metrics via PC v4. Requires PrismCentralHost + ClusterExtId.

.PARAMETER CollectVmStats
    Collect VM-level metrics via PC v4. Requires PrismCentralHost + ClusterExtId.

.PARAMETER StatsWindowMinutes
    How far back to query for stats time window. Default: 5 minutes.

.PARAMETER StatsSamplingIntervalSec
    Sampling interval in seconds for PC v4 stats queries. Default: 30.

.PARAMETER PollingIntervalSec
    How often to poll Nutanix. Default: 30 seconds.

.PARAMETER ApiTimeoutSec
    HTTP request timeout in seconds. Default: 30.

.PARAMETER MaxRetries
    Max upload retry attempts with exponential backoff. Default: 3.

.PARAMETER LogDir
    Directory for log and transcript files. Default: script directory.

.PARAMETER DryRun
    Collect metrics but do not upload to LE. Useful for testing.

.PARAMETER RunOnce
    Run a single collection pass and exit.

.PARAMETER Iterations
    Run exactly N iterations then exit. 0 = run indefinitely.

.PARAMETER SkipTimeSync
    Skip LE appliance time synchronization.

.PARAMETER SaveRawResponse
    Save raw Nutanix API responses to JSON files in LogDir.

.PARAMETER IgnoreCertificateErrors
    Bypass TLS certificate validation for Login Enterprise appliance connections.
    Use this if the LE appliance is using its default self-signed certificate and
    the machine running this script does not have that certificate in its trust store.
    This bypasses certificate validation entirely. Review your organization's security
    policies before using this in your environment.

.EXAMPLE
    # Cluster stats only
    .\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -RunOnce

.EXAMPLE
    # Cluster + host + VM stats, multi-environment mode
    .\Nutanix-LE-PlatformMetrics.ps1 `
        -NutanixPassword "pass" `
        -LEApiToken "token" `
        -PrismCentralHost "10.30.15.203" `
        -ClusterExtId "00064ed1-aeae-074e-4209-00505696e0b5" `
        -CollectHostStats `
        -CollectVmStats `
        -RunOnce

.EXAMPLE
    # Single environment mode (Power BI connector)
    .\Nutanix-LE-PlatformMetrics.ps1 `
        -NutanixPassword "pass" `
        -LEApiToken "token" `
        -PrismCentralHost "10.30.15.203" `
        -ClusterExtId "00064ed1-aeae-074e-4209-00505696e0b5" `
        -LEEnvironmentId "1ceef39e-aa91-4d87-abbc-21d6eec7306b" `
        -CollectHostStats -CollectVmStats -RunOnce

.NOTES
    Version: 2.1.0 | Author: Login VSI | May 2026
    PowerShell 5.1+ compatible. No admin required.
    PC v4 API version negotiation: automatic. PC < 7.5 defaults to v4.0.
    Cluster stats: PC v4 preferred, PE v2 fallback.
#>

[CmdletBinding()]
param(
    # Required credentials - never default these
    [Parameter(Mandatory = $false)][string]$NutanixPassword,
    [Parameter(Mandatory = $false)][string]$LEApiToken,

    # Connection targets
    [Parameter(Mandatory = $false)][string]$NutanixHost,
    [Parameter(Mandatory = $false)][string]$PrismCentralHost,
    [Parameter(Mandatory = $false)][string]$NutanixUser,
    [Parameter(Mandatory = $false)][string]$ClusterExtId,
    [Parameter(Mandatory = $false)][string]$LEApplianceUrl,
    [Parameter(Mandatory = $false)][string]$LEApiVersion,

    # Environment mode - single OR multi (mutually exclusive)
    [Parameter(Mandatory = $false)][string]$LEEnvironmentId,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdPercent,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdIops,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdMs,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdKBps,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdBytesPerSec,

    # Collection scope
    [Parameter(Mandatory = $false)][switch]$CollectClusterStats,
    [Parameter(Mandatory = $false)][switch]$CollectHostStats,
    [Parameter(Mandatory = $false)][switch]$CollectVmStats,

    # Timing and reliability
    [Parameter(Mandatory = $false)][int]$StatsWindowMinutes,
    [Parameter(Mandatory = $false)][int]$StatsSamplingIntervalSec,
    [Parameter(Mandatory = $false)][int]$PollingIntervalSec,
    [Parameter(Mandatory = $false)][int]$ApiTimeoutSec,
    [Parameter(Mandatory = $false)][int]$MaxRetries,

    # Run control
    [Parameter(Mandatory = $false)][switch]$DryRun,
    [Parameter(Mandatory = $false)][switch]$RunOnce,
    [Parameter(Mandatory = $false)][int]$Iterations = 0,
    [Parameter(Mandatory = $false)][switch]$SkipTimeSync,

    # VM filtering — comma-separated list of VM names to collect stats for.
    # If not set, all powered-on VMs are collected.
    # Example: -VmFilter "MyVM-01,MyVM-02"
    [Parameter(Mandatory = $false)][string]$VmFilter,

    # Output and cert
    [Parameter(Mandatory = $false)][string]$LogDir,
    [Parameter(Mandatory = $false)][switch]$SaveRawResponse,
    [Parameter(Mandatory = $false)][switch]$IgnoreCertificateErrors
)

$ErrorActionPreference = "Continue"

function ConvertFrom-SecureStringToPlainText {
    param([System.Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

if (-not $LEApiToken) {
    $secureLEApiToken = Read-Host "Paste or type Login Enterprise API token" -AsSecureString
    $LEApiToken = ConvertFrom-SecureStringToPlainText $secureLEApiToken
    Remove-Variable secureLEApiToken -ErrorAction SilentlyContinue
}

if (-not $NutanixPassword) {
    $secureNutanixPassword = Read-Host "Enter Nutanix password" -AsSecureString
    $NutanixPassword = ConvertFrom-SecureStringToPlainText $secureNutanixPassword
    Remove-Variable secureNutanixPassword -ErrorAction SilentlyContinue
}

# ============================================================
#  DEFAULTS - override any of these via command-line params
# ============================================================
$script:Config = @{
    NutanixHost              = "your-prism-element.example.com"
    PrismCentralHost         = ""                          # set for PC host/VM stats
    NutanixUser              = "admin"
    ClusterExtId             = ""                          # required for PC v4 calls
    LEApplianceUrl           = "https://your-le-appliance.example.com"
    LEApiVersion             = "v8-preview"

    # Environment mode: "single" or "multi"
    # Single: all metrics -> LEEnvironmentId
    # Multi: metrics split by unit -> per-unit IDs below
    EnvironmentMode          = "multi"
    LEEnvironmentId          = "00000000-0000-0000-0000-000000000000"  # single mode
    EnvironmentIds           = @{
        "percent"    = "00000000-0000-0000-0000-000000000001"
        "iops"       = "00000000-0000-0000-0000-000000000002"
        "ms"         = "00000000-0000-0000-0000-000000000003"
        "kBps"       = "00000000-0000-0000-0000-000000000004"
        "bytesPerSec"= "00000000-0000-0000-0000-000000000005"
    }

    # Collection scope defaults - cluster always on; host/VM need PC
    CollectClusterStats      = $true
    CollectHostStats         = $false
    CollectVmStats           = $false
    VmFilter                 = @()          # empty = collect all VMs; set to array of VM names to filter

    # Timing
    StatsWindowMinutes       = 5
    StatsSamplingIntervalSec = 30
    PollingIntervalSec       = 30
    ApiTimeoutSec            = 30
    MaxRetries               = 3
    RetryBaseDelaySec        = 2
    SanityMaxHours           = 168

    # Output
    LogDir                   = $PSScriptRoot
    SaveRawResponse          = $false
    SkipTimeSync             = $false
}

# ============================================================
#  APPLY COMMAND-LINE OVERRIDES
# ============================================================
if ($NutanixHost)             { $script:Config.NutanixHost             = $NutanixHost }
if ($PrismCentralHost)        { $script:Config.PrismCentralHost        = $PrismCentralHost }
if ($NutanixUser)             { $script:Config.NutanixUser             = $NutanixUser }
if ($ClusterExtId)            { $script:Config.ClusterExtId            = $ClusterExtId }
if ($LEApplianceUrl)          { $script:Config.LEApplianceUrl          = $LEApplianceUrl }
if ($LEApiVersion)            { $script:Config.LEApiVersion            = $LEApiVersion }
if ($LogDir)                  { $script:Config.LogDir                  = $LogDir }
if ($SaveRawResponse)         { $script:Config.SaveRawResponse         = $true }
if ($SkipTimeSync)            { $script:Config.SkipTimeSync            = $true }
if ($StatsWindowMinutes -gt 0)       { $script:Config.StatsWindowMinutes       = $StatsWindowMinutes }
if ($StatsSamplingIntervalSec -gt 0) { $script:Config.StatsSamplingIntervalSec = $StatsSamplingIntervalSec }
if ($PollingIntervalSec -gt 0)       { $script:Config.PollingIntervalSec       = $PollingIntervalSec }
if ($ApiTimeoutSec -gt 0)            { $script:Config.ApiTimeoutSec            = $ApiTimeoutSec }
if ($MaxRetries -gt 0)               { $script:Config.MaxRetries               = $MaxRetries }
if ($CollectClusterStats)     { $script:Config.CollectClusterStats     = $true }
if ($CollectHostStats)        { $script:Config.CollectHostStats        = $true }
if ($CollectVmStats)          { $script:Config.CollectVmStats          = $true }
if ($VmFilter)                { $script:Config.VmFilter = @($VmFilter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# Environment mode resolution
if ($LEEnvironmentId) {
    $script:Config.EnvironmentMode  = "single"
    $script:Config.LEEnvironmentId  = $LEEnvironmentId
} elseif ($EnvironmentIdPercent -or $EnvironmentIdIops -or $EnvironmentIdMs -or $EnvironmentIdKBps) {
    $script:Config.EnvironmentMode  = "multi"
    if ($EnvironmentIdPercent)    { $script:Config.EnvironmentIds["percent"]     = $EnvironmentIdPercent }
    if ($EnvironmentIdIops)       { $script:Config.EnvironmentIds["iops"]        = $EnvironmentIdIops }
    if ($EnvironmentIdMs)         { $script:Config.EnvironmentIds["ms"]          = $EnvironmentIdMs }
    if ($EnvironmentIdKBps)       { $script:Config.EnvironmentIds["kBps"]        = $EnvironmentIdKBps }
    if ($EnvironmentIdBytesPerSec){ $script:Config.EnvironmentIds["bytesPerSec"] = $EnvironmentIdBytesPerSec }
}

# Store credentials in config (never in defaults above)
$script:Config.NutanixPassword = $NutanixPassword
$script:Config.LEApiToken      = $LEApiToken

# ============================================================
#  METRIC DEFINITIONS
# ============================================================

# Cluster metrics - PE v2 field names (fallback path)
$script:ClusterMetricsPEv2 = @(
    @{ NutanixStat="hypervisor_cpu_usage_ppm";            MetricId="nutanix.cluster.cpu.usage";              DisplayName="Cluster CPU Usage";               Unit="percent";    ComponentType="cluster"; Conversion="ppm_to_percent" },
    @{ NutanixStat="hypervisor_memory_usage_ppm";         MetricId="nutanix.cluster.memory.usage";           DisplayName="Cluster Memory Usage";            Unit="percent";    ComponentType="cluster"; Conversion="ppm_to_percent" },
    @{ NutanixStat="controller_num_iops";                 MetricId="nutanix.cluster.storage.iops.total";     DisplayName="Cluster Storage IOPS (Total)";    Unit="iops";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controller_num_read_iops";            MetricId="nutanix.cluster.storage.iops.read";      DisplayName="Cluster Storage IOPS (Read)";     Unit="iops";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controller_num_write_iops";           MetricId="nutanix.cluster.storage.iops.write";     DisplayName="Cluster Storage IOPS (Write)";    Unit="iops";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controller_avg_io_latency_usecs";     MetricId="nutanix.cluster.storage.latency.avg";    DisplayName="Cluster Storage Latency (Avg)";   Unit="ms";         ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ NutanixStat="controller_avg_read_io_latency_usecs";MetricId="nutanix.cluster.storage.latency.read";   DisplayName="Cluster Storage Latency (Read)";  Unit="ms";         ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ NutanixStat="controller_avg_write_io_latency_usecs";MetricId="nutanix.cluster.storage.latency.write"; DisplayName="Cluster Storage Latency (Write)"; Unit="ms";         ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ NutanixStat="controller_io_bandwidth_kBps";        MetricId="nutanix.cluster.storage.bandwidth.total";DisplayName="Cluster IO Bandwidth (Total)";    Unit="kBps";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controller_read_io_bandwidth_kBps";   MetricId="nutanix.cluster.storage.bandwidth.read"; DisplayName="Cluster IO Bandwidth (Read)";     Unit="kBps";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controller_write_io_bandwidth_kBps";  MetricId="nutanix.cluster.storage.bandwidth.write";DisplayName="Cluster IO Bandwidth (Write)";    Unit="kBps";       ComponentType="cluster"; Conversion="none" }
)

# Cluster metrics - PC v4 field names (preferred path)
# Same MetricIds as PE v2 so data is directly comparable regardless of which path fired.
$script:ClusterMetricsPCv4 = @(
    @{ NutanixStat="hypervisorCpuUsagePpm";               MetricId="nutanix.cluster.cpu.usage";              DisplayName="Cluster CPU Usage";               Unit="percent";    ComponentType="cluster"; Conversion="ppm_to_percent" },
    @{ NutanixStat="aggregateHypervisorMemoryUsagePpm";   MetricId="nutanix.cluster.memory.usage";           DisplayName="Cluster Memory Usage";            Unit="percent";    ComponentType="cluster"; Conversion="ppm_to_percent" },
    @{ NutanixStat="controllerNumIops";                   MetricId="nutanix.cluster.storage.iops.total";     DisplayName="Cluster Storage IOPS (Total)";    Unit="iops";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controllerNumReadIops";               MetricId="nutanix.cluster.storage.iops.read";      DisplayName="Cluster Storage IOPS (Read)";     Unit="iops";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controllerNumWriteIops";              MetricId="nutanix.cluster.storage.iops.write";     DisplayName="Cluster Storage IOPS (Write)";    Unit="iops";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controllerAvgIoLatencyUsecs";         MetricId="nutanix.cluster.storage.latency.avg";    DisplayName="Cluster Storage Latency (Avg)";   Unit="ms";         ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ NutanixStat="controllerAvgReadIoLatencyUsecs";     MetricId="nutanix.cluster.storage.latency.read";   DisplayName="Cluster Storage Latency (Read)";  Unit="ms";         ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ NutanixStat="controllerAvgWriteIoLatencyUsecs";    MetricId="nutanix.cluster.storage.latency.write";  DisplayName="Cluster Storage Latency (Write)"; Unit="ms";         ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ NutanixStat="ioBandwidthKbps";                     MetricId="nutanix.cluster.storage.bandwidth.total";DisplayName="Cluster IO Bandwidth (Total)";    Unit="kBps";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controllerReadIoBandwidthKbps";       MetricId="nutanix.cluster.storage.bandwidth.read"; DisplayName="Cluster IO Bandwidth (Read)";     Unit="kBps";       ComponentType="cluster"; Conversion="none" },
    @{ NutanixStat="controllerWriteIoBandwidthKbps";      MetricId="nutanix.cluster.storage.bandwidth.write";DisplayName="Cluster IO Bandwidth (Write)";    Unit="kBps";       ComponentType="cluster"; Conversion="none" }
)

# Keep $script:ClusterMetrics pointing at PE v2 for any code that hasn't been updated yet
$script:ClusterMetrics = $script:ClusterMetricsPEv2

# Host metrics - sourced from PC v4 clustermgmt API
# select keys match clustermgmt v4 API spec (no stats/ prefix)
$script:HostMetricSelect = "hypervisorCpuUsagePpm,aggregateHypervisorMemoryUsagePpm," +
                           "controllerNumIops,controllerNumReadIops,controllerNumWriteIops," +
                           "controllerAvgIoLatencyUsecs,controllerAvgReadIoLatencyUsecs,controllerAvgWriteIoLatencyUsecs," +
                           "ioBandwidthKbps,controllerReadIoBandwidthKbps,controllerWriteIoBandwidthKbps"

$script:HostMetricMap = @(
    @{ StatKey="hypervisorCpuUsagePpm";             MetricId="nutanix.host.cpu.usage";              DisplayName="Host CPU Usage";               Unit="percent"; Conversion="ppm_to_percent" },
    @{ StatKey="aggregateHypervisorMemoryUsagePpm"; MetricId="nutanix.host.memory.usage";           DisplayName="Host Memory Usage";            Unit="percent"; Conversion="ppm_to_percent" },
    @{ StatKey="controllerNumIops";                 MetricId="nutanix.host.storage.iops.total";     DisplayName="Host Storage IOPS (Total)";    Unit="iops";    Conversion="none" },
    @{ StatKey="controllerNumReadIops";             MetricId="nutanix.host.storage.iops.read";      DisplayName="Host Storage IOPS (Read)";     Unit="iops";    Conversion="none" },
    @{ StatKey="controllerNumWriteIops";            MetricId="nutanix.host.storage.iops.write";     DisplayName="Host Storage IOPS (Write)";    Unit="iops";    Conversion="none" },
    @{ StatKey="controllerAvgIoLatencyUsecs";       MetricId="nutanix.host.storage.latency.avg";    DisplayName="Host Storage Latency (Avg)";   Unit="ms";      Conversion="usecs_to_ms" },
    @{ StatKey="controllerAvgReadIoLatencyUsecs";   MetricId="nutanix.host.storage.latency.read";   DisplayName="Host Storage Latency (Read)";  Unit="ms";      Conversion="usecs_to_ms" },
    @{ StatKey="controllerAvgWriteIoLatencyUsecs";  MetricId="nutanix.host.storage.latency.write";  DisplayName="Host Storage Latency (Write)"; Unit="ms";      Conversion="usecs_to_ms" },
    @{ StatKey="ioBandwidthKbps";                   MetricId="nutanix.host.storage.bandwidth.total";DisplayName="Host IO Bandwidth (Total)";    Unit="kBps";    Conversion="none" },
    @{ StatKey="controllerReadIoBandwidthKbps";     MetricId="nutanix.host.storage.bandwidth.read"; DisplayName="Host IO Bandwidth (Read)";     Unit="kBps";    Conversion="none" },
    @{ StatKey="controllerWriteIoBandwidthKbps";    MetricId="nutanix.host.storage.bandwidth.write";DisplayName="Host IO Bandwidth (Write)";    Unit="kBps";    Conversion="none" }
)

# VM metrics - sourced from PC v4 vmm API
# select keys use stats/ prefix as required by vmm v4 API spec
$script:VmMetricSelect = "stats/hypervisorCpuUsagePpm," +
                         "stats/hypervisorCpuReadyTimePpm," +
                         "stats/hypervisorMemoryUsagePpm," +
                         "stats/controllerAvgIoLatencyMicros," +
                         "stats/controllerIoBandwidthKbps," +
                         "stats/hypervisorNumReceivedBytes," +
                         "stats/hypervisorNumTransmittedBytes"

$script:VmMetricMap = @(
    @{ StatKey="hypervisorCpuUsagePpm";       MetricId="nutanix.vm.cpu.usage";            DisplayName="VM CPU Usage";             Unit="percent";     Conversion="ppm_to_percent" },
    @{ StatKey="hypervisorCpuReadyTimePpm";   MetricId="nutanix.vm.cpu.ready";            DisplayName="VM CPU Ready Time";        Unit="percent";     Conversion="ppm_to_percent" },
    @{ StatKey="hypervisorMemoryUsagePpm";    MetricId="nutanix.vm.memory.usage";         DisplayName="VM Memory Usage";          Unit="percent";     Conversion="ppm_to_percent" },
    @{ StatKey="controllerAvgIoLatencyMicros";MetricId="nutanix.vm.storage.latency.avg";  DisplayName="VM Disk Latency (Avg)";    Unit="ms";          Conversion="usecs_to_ms" },
    @{ StatKey="controllerIoBandwidthKbps";   MetricId="nutanix.vm.storage.bandwidth";    DisplayName="VM Disk Bandwidth";        Unit="kBps";        Conversion="none" },
    @{ StatKey="hypervisorNumReceivedBytes";  MetricId="nutanix.vm.network.rx";           DisplayName="VM Network RX";            Unit="bytesPerSec"; Conversion="none" },
    @{ StatKey="hypervisorNumTransmittedBytes";MetricId="nutanix.vm.network.tx";          DisplayName="VM Network TX";            Unit="bytesPerSec"; Conversion="none" }
)

# ============================================================
#  SCRIPT STATE
# ============================================================
$script:Version             = "2.1.0"
$script:StartTime           = Get-Date
$script:Timestamp           = $script:StartTime.ToString('yyyyMMdd_HHmmss')
$script:LogFile             = Join-Path $script:Config.LogDir "Nutanix-LE-Metrics_$($script:Timestamp).log"
$script:TranscriptFile      = Join-Path $script:Config.LogDir "Nutanix-LE-Metrics_$($script:Timestamp)_transcript.log"
$script:TimeAdjustment      = [TimeSpan]::Zero
$script:ErrorCount          = 0
$script:SuccessCount        = 0
$script:FailedIterations    = @()
$script:VerboseLogging      = ($VerbosePreference -eq 'Continue')
$script:NegotiatedApiVersion= "v4.0"
$script:ExitCode            = 0
$script:Interrupted         = $false
$script:PcReachable         = $false
$script:ClusterStatsSource  = "PE_v2"   # set to "PC_v4" during preflight if PC cluster stats succeed

# ============================================================
#  HELPERS
# ============================================================
function Ensure-Directory { param([string]$Path)
    if ($Path -and -not (Test-Path $Path)) {
        try { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        catch { Write-Host "[WARN] Could not create directory: $Path" -ForegroundColor Yellow }
    }
}

function Write-Log { param([string]$Message, [ValidateSet("INFO","WARN","ERROR","DEBUG","SUCCESS","VERBOSE")][string]$Level="INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    if ($Level -eq "VERBOSE" -and -not $script:VerboseLogging) { return }
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red;     $script:ErrorCount++ }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "DEBUG"   { Write-Host $entry -ForegroundColor Gray }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green;   $script:SuccessCount++ }
        "VERBOSE" { Write-Host $entry -ForegroundColor DarkGray }
        default   { Write-Host $entry }
    }
    try { Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue } catch {}
}

function Write-ErrorDetails { param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    Write-Log "  Exception: $($ErrorRecord.Exception.Message)" -Level ERROR
    Write-Log "  Type: $($ErrorRecord.Exception.GetType().FullName)" -Level ERROR
    if ($ErrorRecord.ScriptStackTrace) { Write-Log "  Stack: $($ErrorRecord.ScriptStackTrace)" -Level ERROR }
}

function Convert-MetricValue { param([object]$RawValue, [string]$ConversionType)
    if ($null -eq $RawValue -or $RawValue -eq "" -or "$RawValue" -eq "-1") { return $null }
    $v = [double]$RawValue
    switch ($ConversionType) {
        "ppm_to_percent" { return [math]::Round($v / 10000, 2) }
        "usecs_to_ms"    { return [math]::Round($v / 1000, 2) }
        "micros_to_ms"   { return [math]::Round($v / 1000, 2) }
        "none"           { return [math]::Round($v, 2) }
        default          { return $v }
    }
}

function Get-EnvironmentId { param([string]$Unit)
    if ($script:Config.EnvironmentMode -eq "single") { return $script:Config.LEEnvironmentId }
    $envId = $script:Config.EnvironmentIds[$Unit]
    if (-not $envId) { Write-Log "No environment ID configured for unit: $Unit" -Level WARN }
    return $envId
}

function Get-VmStatLatestValue { param($StatsArray, [string]$StatKey)
    # VM stats response format: [{hypervisorCpuUsagePpm: X}, {hypervisorCpuUsagePpm: Y}, ...]
    # Most recent value is first element
    if (-not $StatsArray -or $StatsArray.Count -eq 0) { return $null }
    $first = $StatsArray[0]
    $key = $StatKey -replace '^stats/', ''
    $val = $first.$key
    if ($null -eq $val) { return $null }
    return $val
}

function Get-LatestSeriesValue { param($Series)
    if ($Series -and $Series.Count -gt 0) { return $Series[0].value }
    return $null
}

# ============================================================
#  TLS / CERT HELPERS
# ============================================================

# Nutanix (Prism Element and Prism Central) always uses self-signed certificates.
# Certificate validation is bypassed unconditionally for all Nutanix API calls.
# This is expected behavior - Nutanix does not require customers to replace the
# default Prism certificate for API access.
#
# Login Enterprise appliance connections use normal certificate validation by default.
# If the LE appliance is using a certificate trusted by this machine (via your
# organization's CA, GPO-pushed root, or manual install), connections will work
# without any additional flags.
#
# If you receive an SSL/TLS error connecting to the LE appliance, see the
# Certificate Handling section in the documentation:
# https://docs.loginvsi.com/login-enterprise/6.6/nutanix-platform-metrics-integration
#
# To install a trusted certificate manually on this machine:
# https://learn.microsoft.com/windows-hardware/drivers/install/trusted-root-certification-authorities-certificate-store

function Initialize-TlsSettings {
    # TLS 1.2 baseline for all connections
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        # PS5: install a process-wide cert policy that bypasses validation for
        # Nutanix calls. LE calls are handled per-request via callback below.
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class NutanixTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        // Only bypass for Nutanix hosts (port 9440). All other hosts (including LE) use normal validation.
        return (req != null && req.RequestUri != null && req.RequestUri.Port == 9440) || problem == 0;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object NutanixTrustAllCerts
        Write-Log "TLS configured: Nutanix cert bypass active (PS5 mode)" -Level VERBOSE
    }
}

function Write-LeCertGuidance {
    # Called when an SSL/TLS error is detected on an LE appliance connection.
    Write-Log "  If the LE appliance is using a certificate issued by your organization's CA:" -Level WARN
    Write-Log "    Export the root CA certificate from the appliance and install it to" -Level WARN
    Write-Log "    Trusted Root Certification Authorities on this machine." -Level WARN
    Write-Log "    See: https://learn.microsoft.com/windows-hardware/drivers/install/trusted-root-certification-authorities-certificate-store" -Level WARN
    Write-Log "  If the LE appliance is using its default self-signed certificate:" -Level WARN
    Write-Log "    Re-run with -IgnoreCertificateErrors to bypass certificate validation." -Level WARN
    Write-Log "    See the Certificate Handling section in the documentation for details." -Level WARN
    Write-Log "    https://docs.loginvsi.com/login-enterprise/6.6/nutanix-platform-metrics-integration" -Level WARN
}

# ============================================================
#  API HELPERS
# ============================================================
function Build-NutanixHeaders { param([string]$User, [string]$Password)
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${User}:${Password}"))
    return @{ "Authorization" = "Basic $b64"; "Accept" = "application/json"; "Content-Type" = "application/json" }
}

function Build-PcSession {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Cookies = New-Object System.Net.CookieContainer
    return $session
}

function Invoke-NutanixApi { param([string]$Uri, [hashtable]$Headers, $Session, [int]$TimeoutSec = 30)
    # Nutanix API calls always skip cert validation - Prism uses self-signed certs by design.
    $params = @{ Uri = $Uri; Method = "GET"; Headers = $Headers; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
    if ($Session) { $params.WebSession = $Session }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipCertificateCheck = $true }
    $raw = Invoke-WebRequest @params
    return $raw.Content | ConvertFrom-Json
}

function Invoke-LEApi {
    param([hashtable]$Params)
    # LE API calls respect certificate validation unless -IgnoreCertificateErrors is set.
    if ($IgnoreCertificateErrors -and $PSVersionTable.PSVersion.Major -ge 7) {
        $Params.SkipCertificateCheck = $true
    }
    # PS5: the NutanixTrustAllCerts policy only bypasses port 9440.
    # With -IgnoreCertificateErrors on PS5, swap to a full bypass policy for this call.
    if ($IgnoreCertificateErrors -and $PSVersionTable.PSVersion.Major -lt 7) {
        $saved = [System.Net.ServicePointManager]::CertificatePolicy
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllForLE : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@ -ErrorAction SilentlyContinue
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllForLE
        try { return Invoke-RestMethod @Params }
        finally { [System.Net.ServicePointManager]::CertificatePolicy = $saved }
    }
    return Invoke-RestMethod @Params
}

# ============================================================
#  VERSION NEGOTIATION
# ============================================================
function Invoke-ApiVersionNegotiation { param([hashtable]$Headers, $Session)
    Write-Log "Starting API version negotiation..." -Level INFO
    $scriptSupported = @("v4.1", "v4.0")
    $default         = "v4.0"

    # Step 1: detect PC build version
    $pcBuild = $null
    try {
        $resp    = Invoke-NutanixApi -Uri "https://$($script:Config.PrismCentralHost):9440/api/clustermgmt/v4.0/config/clusters" -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
        $pcEntry = $resp.data | Where-Object { $_.name -eq "Unnamed" } | Select-Object -First 1
        if (-not $pcEntry) { $pcEntry = $resp.data | Select-Object -First 1 }
        $pcBuild = $pcEntry.config.buildInfo.version
        Write-Log "  PC build version: $pcBuild" -Level INFO
    } catch { Write-Log "  Could not detect PC version - defaulting to $default" -Level WARN }

    # Step 2: skip negotiation if PC is pre-7.5 (calendar versioned = pc.YYYY.x)
    $attempt = $true
    if ($pcBuild -match "^\d{4}\.") {
        Write-Log "  PC $pcBuild uses calendar versioning (pre-7.5) - API version negotiation requires PC 7.5+, defaulting to $default" -Level INFO
        $attempt = $false
    } elseif ($pcBuild -match "^(\d+)\.(\d+)") {
        if ([int]$Matches[1] -lt 7 -or ([int]$Matches[1] -eq 7 -and [int]$Matches[2] -lt 5)) {
            Write-Log "  PC $pcBuild is below 7.5 - using $default" -Level INFO
            $attempt = $false
        }
    }

    if ($attempt) {
        try {
            $resp    = Invoke-NutanixApi -Uri "https://$($script:Config.PrismCentralHost):9440/api/prism/v4.0/config/cluster-version-info" -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
            $pcVers  = @($resp.data | ForEach-Object { $_.version })
            Write-Log "  PC supported versions: $($pcVers -join ', ')" -Level INFO
            foreach ($v in $scriptSupported) {
                if ($pcVers -contains $v) {
                    Write-Log "  Negotiated version: $v" -Level SUCCESS
                    return $v
                }
            }
        } catch { Write-Log "  Negotiation endpoint failed - using $default" -Level WARN }
    }

    Write-Log "  Using API version: $default" -Level INFO
    return $default
}

# ============================================================
#  TIME SYNC
# ============================================================
function Get-ServerTimeAdjustment { param([string]$BaseUrl, [string]$Token)
    try {
        $localBefore = [DateTimeOffset]::UtcNow
        $params = @{ Uri = "$($BaseUrl.TrimEnd('/'))/publicApi/$($script:Config.LEApiVersion)/tests"; Method = "GET"; Headers = @{ "Authorization" = "Bearer $Token"; "Accept" = "application/json" }; TimeoutSec = 10; UseBasicParsing = $true }
        $response    = Invoke-LEApi -Params $params
        $localAfter  = [DateTimeOffset]::UtcNow
        $dateHeader  = $response.Headers['Date']; if ($dateHeader -is [array]) { $dateHeader = $dateHeader[0] }
        if (-not $dateHeader) { return [TimeSpan]::Zero }
        $serverTime  = [DateTimeOffset]::Parse($dateHeader)
        $localMid    = $localBefore.AddTicks(($localAfter - $localBefore).Ticks / 2)
        $adj         = $serverTime - $localMid
        if ([Math]::Abs($adj.TotalHours) -gt $script:Config.SanityMaxHours) { return [TimeSpan]::Zero }
        return $adj
    } catch { Write-Log "Time sync failed: $($_.Exception.Message)" -Level WARN; return [TimeSpan]::Zero }
}

function Get-AdjustedTimestamp { return ([DateTimeOffset]::UtcNow.Add($script:TimeAdjustment)).ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

# ============================================================
#  NUTANIX DATA COLLECTION
# ============================================================
function Get-ClusterStatsFromPE { param([hashtable]$Headers)
    try {
        $uri    = "https://$($script:Config.NutanixHost):9440/PrismGateway/services/rest/v2.0/cluster/"
        $params = @{ Uri = $uri; Method = "GET"; Headers = $Headers; ContentType = "application/json"; TimeoutSec = $script:Config.ApiTimeoutSec }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipCertificateCheck = $true }
        $resp   = Invoke-RestMethod @params
        if ($resp -and $resp.stats) {
            return @{ ClusterName = $resp.name; ClusterUuid = $resp.uuid; Stats = $resp.stats; Source = "PE_v2" }
        }
        Write-Log "No stats in PE v2 response" -Level WARN
        return $null
    } catch { Write-Log "PE v2 cluster stats failed: $($_.Exception.Message)" -Level ERROR; return $null }
}

function Get-ClusterStatsFromPC { param([hashtable]$Headers, $Session, [string]$ApiVer)
    # Collects cluster-level stats via Prism Central v4 clustermgmt API.
    # Returns the same hashtable shape as Get-ClusterStatsFromPE for drop-in compatibility.
    try {
        $now       = [DateTimeOffset]::UtcNow
        $startTime = $now.AddSeconds(-60).AddSeconds(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")  # -30s clock skew offset
        $endTime   = $now.AddSeconds(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $select    = "hypervisorCpuUsagePpm,aggregateHypervisorMemoryUsagePpm," +
                     "controllerNumIops,controllerNumReadIops,controllerNumWriteIops," +
                     "controllerAvgIoLatencyUsecs,controllerAvgReadIoLatencyUsecs,controllerAvgWriteIoLatencyUsecs," +
                     "ioBandwidthKbps,controllerReadIoBandwidthKbps,controllerWriteIoBandwidthKbps"
        $uri       = "https://$($script:Config.PrismCentralHost):9440/api/clustermgmt/${ApiVer}/stats/clusters/$($script:Config.ClusterExtId)" +
                     "?`$startTime=$startTime&`$endTime=$endTime&`$samplingInterval=$($script:Config.StatsSamplingIntervalSec)&`$statType=AVG&`$select=$select"
        $resp      = Invoke-NutanixApi -Uri $uri -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
        if (-not ($resp -and $resp.data)) { Write-Log "PC v4 cluster stats: empty response" -Level WARN; return $null }
        $d         = $resp.data
        $name      = if ($d.name)  { $d.name }  else { $script:Config.ClusterExtId }
        $uuid      = if ($d.extId) { $d.extId } else { $script:Config.ClusterExtId }
        $stats     = $d.stats
        if (-not $stats) { Write-Log "PC v4 cluster stats: no stats block in response" -Level WARN; return $null }
        # Flatten series arrays to their latest value so Convert-ClusterStatsToMetrics works unchanged
        $flat = @{}
        foreach ($key in ($stats | Get-Member -MemberType NoteProperty).Name) {
            $series = $stats.$key
            if ($series -is [array] -and $series.Count -gt 0) { $flat[$key] = $series[0].value }
            elseif ($null -ne $series)                         { $flat[$key] = $series }
        }
        return @{ ClusterName = $name; ClusterUuid = $uuid; Stats = $flat; Source = "PC_v4" }
    } catch {
        Write-Log "PC v4 cluster stats failed: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Get-HostList { param([hashtable]$Headers, $Session, [string]$ApiVer)
    try {
        $uri   = "https://$($script:Config.PrismCentralHost):9440/api/clustermgmt/${ApiVer}/config/hosts"
        $resp  = Invoke-NutanixApi -Uri $uri -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
        return $resp.data
    } catch { Write-Log "Host list unavailable: $($_.Exception.Message)" -Level WARN; return @() }
}

function Get-HostStats { param([hashtable]$Headers, $Session, [string]$ApiVer, [string]$HostExtId)
    try {
        $startTime = (Get-Date).ToUniversalTime().AddMinutes(-$script:Config.StatsWindowMinutes).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $uri = "https://$($script:Config.PrismCentralHost):9440/api/clustermgmt/${ApiVer}/stats/clusters/$($script:Config.ClusterExtId)/hosts/${HostExtId}" +
               "?`$startTime=$startTime&`$endTime=$endTime&`$samplingInterval=$($script:Config.StatsSamplingIntervalSec)&`$statType=AVG&`$select=$($script:HostMetricSelect)"
        $resp = Invoke-NutanixApi -Uri $uri -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
        return $resp.data
    } catch { Write-Log "  Host stats failed ($HostExtId): $($_.Exception.Message) (400 may indicate no data in time window)" -Level WARN; return $null }
}

function Get-VmList { param([hashtable]$Headers, $Session, [string]$ApiVer)
    try {
        $uri  = "https://$($script:Config.PrismCentralHost):9440/api/vmm/${ApiVer}/ahv/config/vms"
        $resp = Invoke-NutanixApi -Uri $uri -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
        return $resp.data
    } catch { Write-Log "VM list unavailable: $($_.Exception.Message)" -Level WARN; return @() }
}

function Get-VmStats { param([hashtable]$Headers, $Session, [string]$ApiVer, [string]$VmExtId)
    try {
        $startTime = (Get-Date).ToUniversalTime().AddMinutes(-$script:Config.StatsWindowMinutes).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $uri = "https://$($script:Config.PrismCentralHost):9440/api/vmm/${ApiVer}/ahv/stats/vms/${VmExtId}" +
               "?`$startTime=$startTime&`$endTime=$endTime&`$samplingInterval=$($script:Config.StatsSamplingIntervalSec)&`$statType=AVG&`$select=$($script:VmMetricSelect)"
        $resp = Invoke-NutanixApi -Uri $uri -Headers $Headers -Session $Session -TimeoutSec $script:Config.ApiTimeoutSec
        return $resp.data.stats
    } catch { Write-Log "  VM stats failed ($VmExtId): $($_.Exception.Message)" -Level WARN; return $null }
}

# ============================================================
#  METRIC BUILDING
# ============================================================
function Build-MetricPayload {
    param([string]$MetricId, [string]$DisplayName, [string]$Unit, [double]$Value,
          [string]$Instance, [string]$ComponentType, [hashtable]$CustomTags)
    $envId = Get-EnvironmentId -Unit $Unit
    if (-not $envId) { return $null }
    return @{
        metricId      = $MetricId
        environmentKey= $envId
        timestamp     = Get-AdjustedTimestamp
        displayName   = $DisplayName
        unit          = $Unit
        instance      = $Instance
        value         = $Value
        group         = "Nutanix"
        componentType = $ComponentType
        customTags    = $CustomTags
    }
}

function Convert-ClusterStatsToMetrics { param([hashtable]$ClusterData)
    $metrics = @()
    $tags    = @{ cluster_uuid = $ClusterData.ClusterUuid; cluster_name = $ClusterData.ClusterName; source = $ClusterData.Source }
    $map     = if ($ClusterData.Source -eq "PC_v4") { $script:ClusterMetricsPCv4 } else { $script:ClusterMetricsPEv2 }
    foreach ($m in $map) {
        $raw = $ClusterData.Stats.($m.NutanixStat)
        $val = Convert-MetricValue -RawValue $raw -ConversionType $m.Conversion
        if ($null -ne $val) {
            $payload = Build-MetricPayload -MetricId $m.MetricId -DisplayName $m.DisplayName -Unit $m.Unit -Value $val -Instance $ClusterData.ClusterName -ComponentType $m.ComponentType -CustomTags $tags
            if ($payload) { $metrics += $payload; Write-Log "    $($m.DisplayName): $val $($m.Unit)" -Level VERBOSE }
        }
    }
    return $metrics
}

function Convert-HostStatsToMetrics { param($HostData, [string]$HostName, [string]$HostExtId, [string]$ClusterName, [string]$ClusterUuid)
    $metrics = @()
    $tags    = @{ host_extid = $HostExtId; host_name = $HostName; cluster_name = $ClusterName; cluster_uuid = $ClusterUuid }
    foreach ($m in $script:HostMetricMap) {
        $series = $HostData.($m.StatKey)
        $raw    = Get-LatestSeriesValue -Series $series
        $val    = Convert-MetricValue -RawValue $raw -ConversionType $m.Conversion
        if ($null -ne $val) {
            $payload = Build-MetricPayload -MetricId $m.MetricId -DisplayName $m.DisplayName -Unit $m.Unit -Value $val -Instance $HostName -ComponentType "host" -CustomTags $tags
            if ($payload) { $metrics += $payload; Write-Log "      $($m.DisplayName): $val $($m.Unit)" -Level VERBOSE }
        }
    }
    return $metrics
}

function Convert-VmStatsToMetrics { param($VmStats, [string]$VmName, [string]$VmExtId, [string]$ClusterName, [string]$ClusterUuid)
    $metrics = @()
    $tags    = @{ vm_extid = $VmExtId; vm_name = $VmName; cluster_name = $ClusterName; cluster_uuid = $ClusterUuid }
    foreach ($m in $script:VmMetricMap) {
        $raw    = Get-VmStatLatestValue -StatsArray $VmStats -StatKey $m.StatKey
        $val    = Convert-MetricValue -RawValue $raw -ConversionType $m.Conversion
        if ($null -ne $val) {
            $payload = Build-MetricPayload -MetricId $m.MetricId -DisplayName $m.DisplayName -Unit $m.Unit -Value $val -Instance $VmName -ComponentType "vm" -CustomTags $tags
            if ($payload) { $metrics += $payload; Write-Log "      $($m.DisplayName): $val $($m.Unit)" -Level VERBOSE }
        }
    }
    return $metrics
}

# ============================================================
#  LE UPLOAD
# ============================================================
function Send-ToLEPlatformMetrics { param([array]$Metrics)
    if (-not $Metrics -or $Metrics.Count -eq 0) { return $true }

    # Group by environment ID for batching
    $byEnv = @{}
    foreach ($m in $Metrics) {
        $key = $m.environmentKey
        if (-not $byEnv.ContainsKey($key)) { $byEnv[$key] = @() }
        $byEnv[$key] += $m
    }

    $allSuccess = $true
    $uri        = "$($script:Config.LEApplianceUrl.TrimEnd('/'))/publicApi/$($script:Config.LEApiVersion)/platform-metrics"
    $headers    = @{ "Authorization" = "Bearer $($script:Config.LEApiToken)"; "Content-Type" = "application/json" }

    foreach ($envId in $byEnv.Keys) {
        # Skip placeholder env IDs
        if ($envId -match "^0{8}-") {
            Write-Log "  Skipping $($byEnv[$envId].Count) metrics for unconfigured env $($envId.Substring(0,8))..." -Level WARN
            continue
        }
        $batch    = $byEnv[$envId]
        $bodyJson = $batch | ConvertTo-Json -Depth 10
        if (-not $bodyJson.TrimStart().StartsWith("[")) { $bodyJson = "[$bodyJson]" }

        Write-Log "  Uploading $($batch.Count) metrics to env $($envId.Substring(0,8))..." -Level INFO
        Write-Log "  Payload size: $($bodyJson.Length) bytes" -Level VERBOSE
        Write-Log "  Payload: $($bodyJson.Substring(0, [Math]::Min(500, $bodyJson.Length)))..." -Level VERBOSE

        $attempt = 0; $success = $false
        while ($attempt -lt $script:Config.MaxRetries -and -not $success) {
            $attempt++
            try {
                $params = @{ Uri = $uri; Method = "POST"; Headers = $headers; Body = $bodyJson; ContentType = "application/json"; TimeoutSec = $script:Config.ApiTimeoutSec }
                $resp   = Invoke-LEApi -Params $params
                Write-Log "  Uploaded $($batch.Count) metrics to env $($envId.Substring(0,8))... ($($resp.successfullyAddedCount) accepted)" -Level SUCCESS
                $success = $true
            } catch {
                $msg    = $_.Exception.Message
                $status = $_.Exception.Response.StatusCode.value__
                # Detect SSL/TLS trust errors and surface actionable guidance
                if ($msg -match "SSL|TLS|trust|certificate|secure channel") {
                    Write-Log "  SSL/TLS error connecting to LE appliance: $msg" -Level ERROR
                    Write-LeCertGuidance
                    $allSuccess = $false
                    break
                }
                $delay  = $script:Config.RetryBaseDelaySec * [Math]::Pow(2, $attempt - 1)
                if ($status -eq 429) {
                    $ra = $_.Exception.Response.Headers["Retry-After"]
                    if ($ra) { $delay = [int]$ra }
                    Write-Log "  Rate limited - waiting ${delay}s" -Level WARN
                }
                if ($attempt -lt $script:Config.MaxRetries) {
                    Write-Log "  Upload attempt $attempt/$($script:Config.MaxRetries) failed - retrying in ${delay}s" -Level WARN
                    Start-Sleep -Seconds $delay
                } else {
                    Write-Log "  Upload failed after $($script:Config.MaxRetries) attempts" -Level ERROR
                    Write-Log "  Failed env: $envId" -Level ERROR
                    Write-Log "  Failed payload size: $($bodyJson.Length) bytes" -Level ERROR
                    Write-ErrorDetails -ErrorRecord $_
                    $allSuccess = $false
                }
            }
        }
    }
    return $allSuccess
}

# ============================================================
#  PREFLIGHT
# ============================================================
function Test-Preflight { param([hashtable]$PeHeaders, [hashtable]$PcHeaders, $PcSession)
    Write-Log "Running pre-flight checks..." -Level INFO
    $ok = $true

    # Validate URLs
    foreach ($urlKey in @("NutanixHost","LEApplianceUrl")) {
        $val = $script:Config[$urlKey]
        if (-not $val -or $val -like "*example.com*") { Write-Log "  [$urlKey] not configured" -Level ERROR; $ok = $false }
    }

    # Validate environment IDs
    if ($script:Config.EnvironmentMode -eq "single") {
        $eid = $script:Config.LEEnvironmentId
        if (-not $eid -or $eid -match "^0{8}-") { Write-Log "  LEEnvironmentId not configured" -Level ERROR; $ok = $false }
    } else {
        foreach ($u in @("percent","iops","ms","kBps")) {
            $eid = $script:Config.EnvironmentIds[$u]
            if (-not $eid -or $eid -match "^0{8}-") { Write-Log "  EnvironmentId for [$u] not configured" -Level WARN }
        }
    }

    # Validate PC config if host/VM collection enabled
    if ($script:Config.CollectHostStats -or $script:Config.CollectVmStats) {
        if (-not $script:Config.PrismCentralHost) { Write-Log "  PrismCentralHost required for host/VM stats" -Level ERROR; $ok = $false }
        if (-not $script:Config.ClusterExtId)     { Write-Log "  ClusterExtId required for host/VM stats" -Level ERROR; $ok = $false }
    }

    # Test PC connectivity (always try if PrismCentralHost is set)
    if ($script:Config.PrismCentralHost -and $ok) {
        try {
            $pcTest = Invoke-NutanixApi -Uri "https://$($script:Config.PrismCentralHost):9440/api/clustermgmt/v4.0/config/clusters" -Headers $PcHeaders -Session $PcSession -TimeoutSec $script:Config.ApiTimeoutSec
            if ($pcTest.data) { Write-Log "  Prism Central: connected at $($script:Config.PrismCentralHost)" -Level SUCCESS; $script:PcReachable = $true }
            else              { Write-Log "  Prism Central: connected but returned no cluster data" -Level WARN; $script:PcReachable = $true }
        } catch {
            Write-Log "  Prism Central: connection failed at $($script:Config.PrismCentralHost) - host/VM stats will be skipped" -Level WARN
        }
    }

    if (-not $ok) { return $false }

    # Cluster stats preflight: try PC v4 first, fall back to PE v2
    if ($script:Config.CollectClusterStats) {
        $pcClusterOk = $false

        # Try PC v4 cluster stats if PC is configured and reachable and ClusterExtId is set
        if ($script:Config.PrismCentralHost -and $script:PcReachable -and $script:Config.ClusterExtId) {
            Write-Log "  Cluster stats: trying Prism Central v4..." -Level INFO
            $pcData = Get-ClusterStatsFromPC -Headers $PcHeaders -Session $PcSession -ApiVer $script:NegotiatedApiVersion
            if ($pcData) {
                Write-Log "  Cluster stats: Prism Central v4 OK - cluster '$($pcData.ClusterName)'" -Level SUCCESS
                $script:ClusterStatsSource = "PC_v4"
                $pcClusterOk = $true
            } else {
                Write-Log "  Cluster stats: Prism Central v4 returned no data - falling back to Prism Element v2" -Level WARN
            }
        } else {
            Write-Log "  Cluster stats: Prism Central not configured or unreachable - using Prism Element v2" -Level INFO
        }

        # Fall back to PE v2 if PC v4 didn't work
        if (-not $pcClusterOk) {
            Write-Log "  Cluster stats: trying Prism Element v2..." -Level INFO
            $peData = Get-ClusterStatsFromPE -Headers $PeHeaders
            if ($peData) {
                Write-Log "  Cluster stats: Prism Element v2 OK - cluster '$($peData.ClusterName)'" -Level SUCCESS
                $script:ClusterStatsSource = "PE_v2"
            } else {
                Write-Log "  Cluster stats: Prism Element v2 connection failed" -Level ERROR
                $ok = $false
            }
        }
    }

    return $ok
}

# ============================================================
#  MAIN
# ============================================================
[Console]::TreatControlCAsInput = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { $script:Interrupted = $true }

try {
    Ensure-Directory -Path $script:Config.LogDir
    try { Start-Transcript -Path $script:TranscriptFile -Append | Out-Null } catch { Write-Log "Transcript unavailable: $($_.Exception.Message)" -Level WARN }

    Initialize-TlsSettings

    if ($IgnoreCertificateErrors) {
        Write-Host ""
        Write-Host "  [WARN] -IgnoreCertificateErrors is active." -ForegroundColor Yellow
        Write-Host "  Certificate validation for the Login Enterprise appliance is bypassed." -ForegroundColor Yellow
        Write-Host "  Review your organization's security policies before using this in your environment." -ForegroundColor Yellow
        Write-Host "  See: https://docs.loginvsi.com/login-enterprise/6.6/nutanix-platform-metrics-integration" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "  Nutanix to Login Enterprise Platform Metrics Collector v$($script:Version)" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host ""

    # Startup config dump
    Write-Log "Configuration:"
    Write-Log "  Nutanix PE Host:       $($script:Config.NutanixHost)"
    Write-Log "  Nutanix User:          $($script:Config.NutanixUser)"
    Write-Log "  Prism Central Host:    $(if ($script:Config.PrismCentralHost) { $script:Config.PrismCentralHost } else { '(not set)' })"
    Write-Log "  Cluster ExtId:         $(if ($script:Config.ClusterExtId) { $script:Config.ClusterExtId } else { '(not set)' })"
    Write-Log "  LE Appliance:          $($script:Config.LEApplianceUrl)"
    Write-Log "  LE API Version:        $($script:Config.LEApiVersion)"
    Write-Log "  Environment Mode:      $($script:Config.EnvironmentMode)"
    if ($script:Config.EnvironmentMode -eq "single") {
        Write-Log "  Environment ID:        $($script:Config.LEEnvironmentId)"
    } else {
        foreach ($u in $script:Config.EnvironmentIds.Keys) { Write-Log "  Env [$u]:          $($script:Config.EnvironmentIds[$u])" }
    }
    Write-Log "  Collect Cluster Stats: $($script:Config.CollectClusterStats)"
    Write-Log "  Cluster Stats Source:  $($script:ClusterStatsSource) (determined at preflight)"
    Write-Log "  Collect Host Stats:    $($script:Config.CollectHostStats)"
    Write-Log "  Collect VM Stats:      $($script:Config.CollectVmStats)"
    if ($script:Config.VmFilter.Count -gt 0) {
        Write-Log "  VM Filter:             $($script:Config.VmFilter -join ', ')"
    } else {
        Write-Log "  VM Filter:             (all powered-on VMs)"
    }
    Write-Log "  Polling Interval:      $($script:Config.PollingIntervalSec)s"
    Write-Log "  Stats Window:          $($script:Config.StatsWindowMinutes) minutes"
    Write-Log "  Stats Sampling:        $($script:Config.StatsSamplingIntervalSec)s"
    Write-Log "  API Timeout:           $($script:Config.ApiTimeoutSec)s"
    Write-Log "  Max Retries:           $($script:Config.MaxRetries)"
    Write-Log "  Dry Run:               $DryRun"
    Write-Log "  Run Once:              $RunOnce"
    if ($DryRun) { Write-Host "" ; Write-Host "  *** DRY RUN MODE - no data will be uploaded ***" -ForegroundColor Yellow }
    Write-Host ""

    # Auth headers
    $peHeaders = Build-NutanixHeaders -User $script:Config.NutanixUser -Password $script:Config.NutanixPassword
    $pcHeaders = Build-NutanixHeaders -User $script:Config.NutanixUser -Password $script:Config.NutanixPassword
    $pcSession = Build-PcSession

    # Pre-flight
    if (-not (Test-Preflight -PeHeaders $peHeaders -PcHeaders $pcHeaders -PcSession $pcSession)) {
        Write-Log "Pre-flight failed - exiting" -Level ERROR
        $script:ExitCode = 1
        throw "Pre-flight validation failed"
    }
    Write-Host ""

    # Version negotiation (only if PC is configured and reachable)
    if ($script:Config.PrismCentralHost -and $script:PcReachable) {
        $script:NegotiatedApiVersion = Invoke-ApiVersionNegotiation -Headers $pcHeaders -Session $pcSession
    } elseif ($script:Config.PrismCentralHost -and -not $script:PcReachable) {
        Write-Log "Skipping version negotiation - PC not reachable" -Level WARN
    }
    Write-Host ""

    # Time sync
    if (-not $SkipTimeSync -and -not $script:Config.SkipTimeSync) {
        Write-Log "Synchronizing time with LE appliance..."
        $script:TimeAdjustment = Get-ServerTimeAdjustment -BaseUrl $script:Config.LEApplianceUrl -Token $script:Config.LEApiToken
        if ($script:TimeAdjustment -ne [TimeSpan]::Zero) {
            Write-Log "  Time adjustment: $([math]::Round($script:TimeAdjustment.TotalMilliseconds))ms" -Level VERBOSE
        } else {
            Write-Log "  Time adjustment: none needed" -Level VERBOSE
        }
    } else {
        Write-Log "Time sync: skipped"
    }
    Write-Host ""

    $iteration = 0; $totalMetricsSent = 0

    while ($true) {
        if ($script:Interrupted) { Write-Log "Interrupt detected - finishing current iteration" -Level WARN; break }

        $iteration++
        $iterStart = Get-Date
        Write-Log "--- Iteration $iteration ---"

        $allMetrics = @()

        try {
            # CLUSTER STATS (PC v4 preferred, PE v2 fallback)
            if ($script:Config.CollectClusterStats) {
                $clusterData = $null
                if ($script:ClusterStatsSource -eq "PC_v4") {
                    Write-Log "  Collecting cluster stats (PC v4)..." -Level VERBOSE
                    $clusterData = Get-ClusterStatsFromPC -Headers $pcHeaders -Session $pcSession -ApiVer $script:NegotiatedApiVersion
                    if (-not $clusterData) {
                        Write-Log "  PC v4 cluster stats returned no data - falling back to PE v2 this iteration" -Level WARN
                        $clusterData = Get-ClusterStatsFromPE -Headers $peHeaders
                    }
                } else {
                    Write-Log "  Collecting cluster stats (PE v2)..." -Level VERBOSE
                    $clusterData = Get-ClusterStatsFromPE -Headers $peHeaders
                }
                if ($clusterData) {
                    Write-Log "  Cluster source: $($clusterData.Source)" -Level VERBOSE
                    if ($script:Config.SaveRawResponse) {
                        $rawFile = Join-Path $script:Config.LogDir "NutanixCluster_$($script:Timestamp)_$($iteration.ToString('D4')).json"
                        $clusterData.Stats | ConvertTo-Json -Depth 10 | Out-File $rawFile -Encoding UTF8
                    }
                    $clusterMetrics = Convert-ClusterStatsToMetrics -ClusterData $clusterData
                    $allMetrics += $clusterMetrics
                    Write-Log "  Cluster: $($clusterMetrics.Count) metrics" -Level DEBUG
                } else {
                    Write-Log "  Cluster stats unavailable from both PC v4 and PE v2" -Level WARN
                }
            }

            # HOST STATS (PC v4)
            if ($script:Config.CollectHostStats -and $script:Config.PrismCentralHost -and $script:PcReachable) {
                Write-Log "  Collecting host stats (PC v4 $($script:NegotiatedApiVersion))..." -Level VERBOSE
                $clusterName = if ($clusterData) { $clusterData.ClusterName } else { $script:Config.ClusterExtId }
                $clusterUuid = if ($clusterData) { $clusterData.ClusterUuid } else { $script:Config.ClusterExtId }
                $hosts = Get-HostList -Headers $pcHeaders -Session $pcSession -ApiVer $script:NegotiatedApiVersion
                if (-not $hosts -or $hosts.Count -eq 0) {
                    Write-Log "  No hosts found in cluster - skipping host stats" -Level INFO
                } else {
                    foreach ($h in $hosts) {
                        Write-Log "    Host: $($h.hostName) ($($h.extId))" -Level VERBOSE
                        $hStats = Get-HostStats -Headers $pcHeaders -Session $pcSession -ApiVer $script:NegotiatedApiVersion -HostExtId $h.extId
                        if ($hStats) {
                            $hMetrics = Convert-HostStatsToMetrics -HostData $hStats -HostName $h.hostName -HostExtId $h.extId -ClusterName $clusterName -ClusterUuid $clusterUuid
                            $allMetrics += $hMetrics
                            Write-Log "    Host $($h.hostName): $($hMetrics.Count) metrics" -Level DEBUG
                        }
                    }
                }
            }

            # VM STATS (PC v4)
            if ($script:Config.CollectVmStats -and $script:Config.PrismCentralHost -and $script:PcReachable) {
                Write-Log "  Collecting VM stats (PC v4 $($script:NegotiatedApiVersion))..." -Level VERBOSE
                $clusterName = if ($clusterData) { $clusterData.ClusterName } else { $script:Config.ClusterExtId }
                $clusterUuid = if ($clusterData) { $clusterData.ClusterUuid } else { $script:Config.ClusterExtId }
                $vms = Get-VmList -Headers $pcHeaders -Session $pcSession -ApiVer $script:NegotiatedApiVersion
                if (-not $vms -or $vms.Count -eq 0) {
                    Write-Log "  No VMs found in cluster - skipping VM stats" -Level INFO
                } else {
                    $poweredOnVms = @($vms | Where-Object { $_.powerState -eq "ON" })
                    if ($poweredOnVms.Count -eq 0) {
                        Write-Log "  No powered-on VMs found - skipping VM stats" -Level INFO
                    } else {
                        Write-Log "  Found $($poweredOnVms.Count) powered-on VM(s) of $($vms.Count) total" -Level INFO
                        if ($script:Config.VmFilter.Count -gt 0) {
                            $poweredOnVms = @($poweredOnVms | Where-Object { $script:Config.VmFilter -contains $_.name })
                            Write-Log "  After VM filter: $($poweredOnVms.Count) VM(s) match filter" -Level INFO
                            if ($poweredOnVms.Count -eq 0) {
                                Write-Log "  No powered-on VMs match filter '$($script:Config.VmFilter -join ', ')' - check VM names" -Level WARN
                            }
                        }
                        foreach ($vm in $poweredOnVms) {
                            Write-Log "    VM: $($vm.name) ($($vm.extId))" -Level VERBOSE
                            $vStats = Get-VmStats -Headers $pcHeaders -Session $pcSession -ApiVer $script:NegotiatedApiVersion -VmExtId $vm.extId
                            if ($vStats) {
                                $vMetrics = Convert-VmStatsToMetrics -VmStats $vStats -VmName $vm.name -VmExtId $vm.extId -ClusterName $clusterName -ClusterUuid $clusterUuid
                                $allMetrics += $vMetrics
                                Write-Log "    VM $($vm.name): $($vMetrics.Count) metrics" -Level DEBUG
                            } else {
                                Write-Log "    VM $($vm.name): no stats returned (VM may be too new or a management appliance)" -Level INFO
                            }
                            # Brief pause between VM stats calls to avoid PC v4 API rate limiting
                            Start-Sleep -Milliseconds 500
                        }
                    }
                }
            }

            Write-Log "  Total metrics collected: $($allMetrics.Count)"

            # UPLOAD
            if ($DryRun) {
                Write-Log "  DRY RUN - would upload $($allMetrics.Count) metrics" -Level WARN
                $byUnit = $allMetrics | Group-Object { $_.unit }
                foreach ($g in $byUnit) { Write-Log "    [$($g.Name)] $($g.Count) metrics" -Level WARN }
            } else {
                if ($allMetrics.Count -gt 0) {
                    $uploadOk = Send-ToLEPlatformMetrics -Metrics $allMetrics
                    if ($uploadOk) { $totalMetricsSent += $allMetrics.Count }
                    else           { $script:FailedIterations += $iteration }
                }
            }

        } catch {
            Write-Log "Error in iteration $iteration" -Level ERROR
            Write-ErrorDetails -ErrorRecord $_
            $script:FailedIterations += $iteration
        }

        $iterTime = ((Get-Date) - $iterStart).TotalSeconds
        Write-Log "  Iteration $iteration completed in $([math]::Round($iterTime,1))s" -Level VERBOSE

        if ($RunOnce)                                     { Write-Log "Run-once mode - exiting"; break }
        if ($Iterations -gt 0 -and $iteration -ge $Iterations) { Write-Log "Completed $Iterations iterations - exiting"; break }

        $iterElapsed   = ((Get-Date) - $iterStart).TotalSeconds
        $remainingSec  = $script:Config.PollingIntervalSec - $iterElapsed
        if ($remainingSec -le 0) {
            Write-Log "Iteration took $([math]::Round($iterElapsed,1))s which exceeds polling interval ($($script:Config.PollingIntervalSec)s) - starting next iteration immediately" -Level WARN
        } else {
            Write-Log "Next poll in $([math]::Round($remainingSec,0))s..."
            $sleepEnd = (Get-Date).AddSeconds($remainingSec)
            while ((Get-Date) -lt $sleepEnd) {
                if ($script:Interrupted) { break }
                Start-Sleep -Milliseconds 500
            }
        }
        if ($script:Interrupted) { break }
    }

} catch {
    if ($_.Exception.Message -ne "Pre-flight validation failed") {
        Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
        Write-ErrorDetails -ErrorRecord $_
    }
    $script:ExitCode = 1
} finally {
    $runtime = (Get-Date) - $script:StartTime
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Log "SUMMARY:"
    Write-Log "  Runtime:           $($runtime.ToString('hh\:mm\:ss'))"
    Write-Log "  Iterations:        $iteration"
    Write-Log "  Failed:            $($script:FailedIterations.Count)"
    if ($script:FailedIterations.Count -gt 0) { Write-Log "  Failed iters:      $($script:FailedIterations -join ', ')" -Level WARN }
    Write-Log "  Metrics uploaded:  $totalMetricsSent"
    Write-Log "  Errors logged:     $($script:ErrorCount)"
    if ($DryRun)                { Write-Log "  Mode:              DRY RUN (nothing uploaded)" -Level WARN }
    if ($script:Interrupted)    { Write-Log "  Status:            Interrupted by user" -Level WARN }
    Write-Host "========================================================================" -ForegroundColor Cyan

    try { Stop-Transcript | Out-Null } catch {}

    if ($Error.Count -gt 0) { Write-Log "PS error buffer: $($Error.Count) entr$(if ($Error.Count -eq 1) {'y'} else {'ies'}) (expected on PS5 - all handled internally, check Errors logged above for real issues)" -Level VERBOSE }
}

exit $script:ExitCode
