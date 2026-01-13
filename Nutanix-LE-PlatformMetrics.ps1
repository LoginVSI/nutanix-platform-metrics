<#
.SYNOPSIS
    Nutanix to Login Enterprise Platform Metrics Collector
    
.DESCRIPTION
    Polls Nutanix cluster statistics from Prism Element API and uploads 
    them to Login Enterprise Platform Metrics API.
    
    Cluster-Level Metrics:
    - CPU Usage (%), Memory Usage (%)
    - Storage IOPS (total, read, write)
    - Storage Latency (avg, read, write) in ms
    - IO Bandwidth (total, read, write) in kBps
    
.PARAMETER NutanixPassword
    REQUIRED. Nutanix admin password.
    
.PARAMETER LEApiToken
    REQUIRED. Login Enterprise API token with Configuration access.
    
.PARAMETER ConfigFile
    Optional JSON config file for non-sensitive settings.

.PARAMETER LEApiVersion
    Login Enterprise API version to use. Default: v8-preview

.EXAMPLE
    .\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -RunOnce

.NOTES
    Version: 1.4.0 | Author: Login VSI | January 2026
    PowerShell 5.1+ compatible, no admin required
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$NutanixPassword,
    [Parameter(Mandatory = $true)][string]$LEApiToken,
    [Parameter(Mandatory = $false)][string]$NutanixHost,
    [Parameter(Mandatory = $false)][string]$NutanixUser,
    [Parameter(Mandatory = $false)][string]$LEApplianceUrl,
    [Parameter(Mandatory = $false)][string]$LEApiVersion,
    [Parameter(Mandatory = $false)][string]$ConfigFile,
    [Parameter(Mandatory = $false)][int]$PollingIntervalSec,
    [Parameter(Mandatory = $false)][string]$LogDir,
    [Parameter(Mandatory = $false)][switch]$SaveRawResponse,
    [Parameter(Mandatory = $false)][switch]$DryRun,
    [Parameter(Mandatory = $false)][switch]$RunOnce,
    [Parameter(Mandatory = $false)][int]$Iterations = 0,
    [Parameter(Mandatory = $false)][int]$MaxRetries = 3,
    [Parameter(Mandatory = $false)][switch]$SkipTimeSync,
    [Parameter(Mandatory = $false)][switch]$Verbose
)

$script:Config = @{
    NutanixHost     = "your-nutanix-prism.example.com"
    NutanixUser     = "admin"
    LEApplianceUrl  = "https://your-le-appliance.example.com"
    LEApiVersion    = "v8-preview"
    EnvironmentIds  = @{
        "percent" = "00000000-0000-0000-0000-000000000001"
        "iops"    = "00000000-0000-0000-0000-000000000002"
        "ms"      = "00000000-0000-0000-0000-000000000003"
        "kBps"    = "00000000-0000-0000-0000-000000000004"
    }
    PollingIntervalSec = 30
    MaxRetries      = 3
    RetryBaseDelaySec = 2
    SanityMaxHours  = 168
    LogDir          = $PSScriptRoot
    SaveRawResponse = $false
    SkipTimeSync    = $false
}
# WARNING: These are Joshua's test values. Before public release, replace with generic placeholders!

# Load config file if provided
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    try {
        $fc = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($fc.NutanixHost) { $script:Config.NutanixHost = $fc.NutanixHost }
        if ($fc.NutanixUser) { $script:Config.NutanixUser = $fc.NutanixUser }
        if ($fc.LEApplianceUrl) { $script:Config.LEApplianceUrl = $fc.LEApplianceUrl }
        if ($fc.LEApiVersion) { $script:Config.LEApiVersion = $fc.LEApiVersion }
        if ($fc.PollingIntervalSec) { $script:Config.PollingIntervalSec = $fc.PollingIntervalSec }
        if ($fc.MaxRetries) { $script:Config.MaxRetries = $fc.MaxRetries }
        if ($null -ne $fc.SkipTimeSync) { $script:Config.SkipTimeSync = $fc.SkipTimeSync }
        if ($fc.EnvironmentIds) {
            if ($fc.EnvironmentIds.percent) { $script:Config.EnvironmentIds["percent"] = $fc.EnvironmentIds.percent }
            if ($fc.EnvironmentIds.iops) { $script:Config.EnvironmentIds["iops"] = $fc.EnvironmentIds.iops }
            if ($fc.EnvironmentIds.ms) { $script:Config.EnvironmentIds["ms"] = $fc.EnvironmentIds.ms }
            if ($fc.EnvironmentIds.kBps) { $script:Config.EnvironmentIds["kBps"] = $fc.EnvironmentIds.kBps }
        }
        Write-Host "Loaded config from: $ConfigFile" -ForegroundColor Cyan
    } catch { Write-Host "Warning: Failed to load config: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Command line overrides
if ($NutanixHost) { $script:Config.NutanixHost = $NutanixHost }
if ($NutanixUser) { $script:Config.NutanixUser = $NutanixUser }
if ($LEApplianceUrl) { $script:Config.LEApplianceUrl = $LEApplianceUrl }
if ($LEApiVersion) { $script:Config.LEApiVersion = $LEApiVersion }
if ($PollingIntervalSec -gt 0) { $script:Config.PollingIntervalSec = $PollingIntervalSec }
if ($LogDir) { $script:Config.LogDir = $LogDir }
if ($SaveRawResponse) { $script:Config.SaveRawResponse = $true }
if ($MaxRetries -gt 0) { $script:Config.MaxRetries = $MaxRetries }
$script:Config.NutanixPassword = $NutanixPassword
$script:Config.LEApiToken = $LEApiToken

$script:Metrics = @(
    @{ Enabled=$true; NutanixStat="hypervisor_cpu_usage_ppm"; MetricId="nutanix.cluster.cpu.usage"; DisplayName="Cluster CPU Usage"; Unit="percent"; Group="Nutanix"; ComponentType="cluster"; Conversion="ppm_to_percent" },
    @{ Enabled=$true; NutanixStat="hypervisor_memory_usage_ppm"; MetricId="nutanix.cluster.memory.usage"; DisplayName="Cluster Memory Usage"; Unit="percent"; Group="Nutanix"; ComponentType="cluster"; Conversion="ppm_to_percent" },
    @{ Enabled=$true; NutanixStat="controller_num_iops"; MetricId="nutanix.cluster.storage.iops.total"; DisplayName="Storage IOPS (Total)"; Unit="iops"; Group="Nutanix"; ComponentType="cluster"; Conversion="none" },
    @{ Enabled=$true; NutanixStat="controller_num_read_iops"; MetricId="nutanix.cluster.storage.iops.read"; DisplayName="Storage IOPS (Read)"; Unit="iops"; Group="Nutanix"; ComponentType="cluster"; Conversion="none" },
    @{ Enabled=$true; NutanixStat="controller_num_write_iops"; MetricId="nutanix.cluster.storage.iops.write"; DisplayName="Storage IOPS (Write)"; Unit="iops"; Group="Nutanix"; ComponentType="cluster"; Conversion="none" },
    @{ Enabled=$true; NutanixStat="controller_avg_io_latency_usecs"; MetricId="nutanix.cluster.storage.latency.avg"; DisplayName="Storage Latency (Avg)"; Unit="ms"; Group="Nutanix"; ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ Enabled=$true; NutanixStat="controller_avg_read_io_latency_usecs"; MetricId="nutanix.cluster.storage.latency.read"; DisplayName="Storage Latency (Read)"; Unit="ms"; Group="Nutanix"; ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ Enabled=$true; NutanixStat="controller_avg_write_io_latency_usecs"; MetricId="nutanix.cluster.storage.latency.write"; DisplayName="Storage Latency (Write)"; Unit="ms"; Group="Nutanix"; ComponentType="cluster"; Conversion="usecs_to_ms" },
    @{ Enabled=$true; NutanixStat="controller_io_bandwidth_kBps"; MetricId="nutanix.cluster.storage.bandwidth.total"; DisplayName="IO Bandwidth (Total)"; Unit="kBps"; Group="Nutanix"; ComponentType="cluster"; Conversion="none" },
    @{ Enabled=$true; NutanixStat="controller_read_io_bandwidth_kBps"; MetricId="nutanix.cluster.storage.bandwidth.read"; DisplayName="IO Bandwidth (Read)"; Unit="kBps"; Group="Nutanix"; ComponentType="cluster"; Conversion="none" },
    @{ Enabled=$true; NutanixStat="controller_write_io_bandwidth_kBps"; MetricId="nutanix.cluster.storage.bandwidth.write"; DisplayName="IO Bandwidth (Write)"; Unit="kBps"; Group="Nutanix"; ComponentType="cluster"; Conversion="none" }
)

$script:Version = "1.4.0"
$script:StartTime = Get-Date
$script:Timestamp = $script:StartTime.ToString('yyyyMMdd_HHmmss')
$script:LogFile = Join-Path $script:Config.LogDir "Nutanix-LE-Metrics_$($script:Timestamp).log"
$script:TranscriptFile = Join-Path $script:Config.LogDir "Nutanix-LE-Metrics_$($script:Timestamp)_transcript.log"
$script:TimeAdjustment = [TimeSpan]::Zero
$script:ErrorCount = 0
$script:SuccessCount = 0
$script:FailedIterations = @()
$script:VerboseLogging = $Verbose

function Write-Log { param([string]$Message, [ValidateSet("INFO","WARN","ERROR","DEBUG","SUCCESS","VERBOSE")][string]$Level="INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; $e = "[$ts] [$Level] $Message"
    
    # Skip VERBOSE messages unless -Verbose is enabled
    if ($Level -eq "VERBOSE" -and -not $script:VerboseLogging) { return }
    
    switch ($Level) { 
        "ERROR" { Write-Host $e -ForegroundColor Red; $script:ErrorCount++ } 
        "WARN" { Write-Host $e -ForegroundColor Yellow } 
        "DEBUG" { Write-Host $e -ForegroundColor Gray } 
        "SUCCESS" { Write-Host $e -ForegroundColor Green; $script:SuccessCount++ } 
        "VERBOSE" { Write-Host $e -ForegroundColor DarkGray }
        default { Write-Host $e } 
    }
    try { Add-Content -Path $script:LogFile -Value $e -ErrorAction SilentlyContinue } catch {}
}

function Write-ErrorDetails { param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    Write-Log "ERROR DETAILS:" -Level ERROR
    Write-Log "  Message: $($ErrorRecord.Exception.Message)" -Level ERROR
    Write-Log "  Type: $($ErrorRecord.Exception.GetType().FullName)" -Level ERROR
    if ($ErrorRecord.ScriptStackTrace) { Write-Log "  Stack: $($ErrorRecord.ScriptStackTrace)" -Level ERROR }
    if ($ErrorRecord.InvocationInfo) { Write-Log "  Line: $($ErrorRecord.InvocationInfo.ScriptLineNumber)" -Level ERROR }
}

function Test-EnvironmentId { param([string]$EnvId, [string]$Unit)
    if ($EnvId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        Write-Log "Invalid UUID format for $Unit environment: $EnvId" -Level WARN
        return $false
    }
    return $true
}

function Test-UrlFormat { param([string]$Url, [string]$Name)
    try {
        $uri = [System.Uri]$Url
        if ($uri.Scheme -notin @('http', 'https')) { throw "Invalid scheme" }
        Write-Log "  ✓ $Name URL format valid" -Level VERBOSE
        return $true
    } catch {
        Write-Log "Invalid URL format for ${Name}: $Url" -Level ERROR
        return $false
    }
}

function Test-Connectivity { param([hashtable]$Headers)
    Write-Log "Validating configuration..." -Level INFO
    
    # Test Nutanix URL format
    if (-not (Test-UrlFormat -Url "https://$($script:Config.NutanixHost):9440" -Name "Nutanix")) { return $false }
    
    # Test LE URL format  
    if (-not (Test-UrlFormat -Url $script:Config.LEApplianceUrl -Name "Login Enterprise")) { return $false }
    
    # Test environment IDs
    $validEnvs = 0
    foreach ($unit in $script:Config.EnvironmentIds.Keys) {
        if (Test-EnvironmentId -EnvId $script:Config.EnvironmentIds[$unit] -Unit $unit) { $validEnvs++ }
    }
    Write-Log "  ✓ $validEnvs of $($script:Config.EnvironmentIds.Count) environment IDs valid" -Level VERBOSE
    
    # Test Nutanix connectivity
    Write-Log "Testing Nutanix connectivity..." -Level INFO
    $testData = Get-NutanixClusterStats -Headers $Headers
    if (-not $testData) { 
        Write-Log "Failed to connect to Nutanix at $($script:Config.NutanixHost)" -Level ERROR
        Write-Log "Check: Network connectivity, credentials, firewall (port 9440)" -Level ERROR
        return $false 
    }
    Write-Log "  ✓ Connected to cluster: $($testData.ClusterName)" -Level SUCCESS
    
    return $true
}

function Initialize-CertificateBypass {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
            Add-Type @"
using System.Net;using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
}

function Get-ServerTimeAdjustment { param([string]$BaseUrl, [string]$Token)
    try {
        $localBefore = [DateTimeOffset]::UtcNow
        $params = @{ Uri = "$($BaseUrl.TrimEnd('/'))/publicApi/$($script:Config.LEApiVersion)/tests"; Method = "GET"; Headers = @{ "Authorization" = "Bearer $Token"; "Accept" = "application/json" }; TimeoutSec = 10 }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipCertificateCheck = $true }
        $response = Invoke-WebRequest @params -UseBasicParsing
        $localAfter = [DateTimeOffset]::UtcNow
        $dateHeader = $response.Headers['Date']; if ($dateHeader -is [array]) { $dateHeader = $dateHeader[0] }
        if (-not $dateHeader) { return [TimeSpan]::Zero }
        $serverTime = [DateTimeOffset]::Parse($dateHeader)
        $localMidpoint = $localBefore.AddTicks(($localAfter - $localBefore).Ticks / 2)
        $adjustment = $serverTime - $localMidpoint
        if ([Math]::Abs($adjustment.TotalHours) -gt $script:Config.SanityMaxHours) { return [TimeSpan]::Zero }
        return $adjustment
    } catch { Write-Log "Time sync failed: $($_.Exception.Message)" -Level WARN; return [TimeSpan]::Zero }
}

function Get-AdjustedTimestamp { return ([DateTimeOffset]::UtcNow.Add($script:TimeAdjustment)).ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function Get-NutanixClusterStats { param([hashtable]$Headers)
    try {
        $uri = "https://$($script:Config.NutanixHost):9440/PrismGateway/services/rest/v2.0/cluster/"
        Write-Log "  Fetching from: $uri" -Level VERBOSE
        $fetchStart = Get-Date
        $params = @{ Uri = $uri; Method = "GET"; Headers = $Headers; ContentType = "application/json"; TimeoutSec = 30 }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipCertificateCheck = $true }
        $response = Invoke-RestMethod @params
        $fetchTime = ((Get-Date) - $fetchStart).TotalSeconds
        Write-Log "  Fetch completed in ${fetchTime}s" -Level VERBOSE
        if ($response -and $response.stats) { return @{ ClusterName = $response.name; ClusterUuid = $response.uuid; Stats = $response.stats; RawResponse = $response } }
        Write-Log "No stats in Nutanix response" -Level WARN
        return $null
    } catch {
        Write-Log "Failed to get cluster stats from Nutanix" -Level ERROR
        Write-ErrorDetails -ErrorRecord $_
        return $null
    }
}

function Convert-MetricValue { param([object]$RawValue, [string]$ConversionType)
    if ($null -eq $RawValue -or $RawValue -eq "" -or $RawValue -eq "-1") { return $null }
    $value = [double]$RawValue
    switch ($ConversionType) { "ppm_to_percent" { return [math]::Round($value / 10000, 2) } "usecs_to_ms" { return [math]::Round($value / 1000, 2) } "none" { return [math]::Round($value, 2) } default { return $value } }
}

function Convert-ToLEMetrics { param([hashtable]$ClusterData)
    $metricsByUnit = @{}; $timestamp = Get-AdjustedTimestamp
    foreach ($m in $script:Metrics) {
        if (-not $m.Enabled) { continue }
        $rawValue = $ClusterData.Stats.($m.NutanixStat); $unit = $m.Unit
        $convertedValue = Convert-MetricValue -RawValue $rawValue -ConversionType $m.Conversion
        if ($null -ne $convertedValue) {
            $envId = $script:Config.EnvironmentIds[$unit]
            if (-not $envId) { Write-Log "No environment ID for unit: $unit" -Level WARN; continue }
            if (-not $metricsByUnit.ContainsKey($unit)) { $metricsByUnit[$unit] = @{ EnvironmentId = $envId; Metrics = @() } }
            $metricsByUnit[$unit].Metrics += @{ metricId = $m.MetricId; environmentKey = $envId; timestamp = $timestamp; displayName = $m.DisplayName; unit = $unit; instance = $ClusterData.ClusterName; value = $convertedValue; group = $m.Group; componentType = $m.ComponentType; customTags = @{ cluster_uuid = $ClusterData.ClusterUuid; cluster_name = $ClusterData.ClusterName } }
            Write-Log "  $($m.DisplayName): $convertedValue $unit" -Level DEBUG
        }
    }
    return $metricsByUnit
}

function Send-ToLEPlatformMetrics { param([array]$Metrics, [string]$Unit)
    if ($Metrics.Count -eq 0) { return $true }
    $uri = "$($script:Config.LEApplianceUrl.TrimEnd('/'))/publicApi/$($script:Config.LEApiVersion)/platform-metrics"
    $headers = @{ "Authorization" = "Bearer $($script:Config.LEApiToken)"; "Content-Type" = "application/json" }
    $body = $Metrics | ConvertTo-Json -Depth 10; if (-not $body.TrimStart().StartsWith("[")) { $body = "[$body]" }
    Write-Log "  [$Unit] Uploading $($Metrics.Count) metrics..." -Level VERBOSE
    $attempt = 0; $success = $false
    while ($attempt -lt $script:Config.MaxRetries -and -not $success) {
        $attempt++
        try {
            $uploadStart = Get-Date
            $params = @{ Uri = $uri; Method = "POST"; Headers = $headers; Body = $body; ContentType = "application/json"; TimeoutSec = 30 }
            if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipCertificateCheck = $true }
            $response = Invoke-RestMethod @params
            $uploadTime = ((Get-Date) - $uploadStart).TotalSeconds
            Write-Log "[$Unit] Upload successful: $($response.successfullyAddedCount) metrics in ${uploadTime}s (attempt $attempt)" -Level SUCCESS
            $success = $true
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $delay = $script:Config.RetryBaseDelaySec * [Math]::Pow(2, $attempt - 1)
            
            # Check for rate limiting (429)
            if ($statusCode -eq 429) {
                $retryAfter = $_.Exception.Response.Headers["Retry-After"]
                if ($retryAfter) { $delay = [int]$retryAfter }
                Write-Log "[$Unit] Rate limited (429). Waiting ${delay}s before retry..." -Level WARN
            }
            
            if ($attempt -lt $script:Config.MaxRetries) { 
                Write-Log "[$Unit] Upload failed (attempt $attempt/$($script:Config.MaxRetries)): $($_.Exception.Message). Retrying in ${delay}s..." -Level WARN
                Start-Sleep -Seconds $delay 
            } else { 
                Write-Log "[$Unit] Upload failed after $($script:Config.MaxRetries) attempts" -Level ERROR
                Write-ErrorDetails -ErrorRecord $_
            }
        }
    }
    return $success
}

# MAIN
$ErrorActionPreference = "Stop"
$script:ExitCode = 0

# Ctrl+C handler
$script:Interrupted = $false
[Console]::TreatControlCAsInput = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $script:Interrupted = $true
}

try {
    # Start transcript
    try { Start-Transcript -Path $script:TranscriptFile -Append | Out-Null } catch { Write-Log "Failed to start transcript: $($_.Exception.Message)" -Level WARN }
    
    Initialize-CertificateBypass
    
    Write-Host "`n========================================================================" -ForegroundColor Cyan
    Write-Host "  Nutanix to Login Enterprise Platform Metrics Collector v$($script:Version)" -ForegroundColor Cyan
    Write-Host "========================================================================`n" -ForegroundColor Cyan
    
    Write-Log "Starting collector..."
    Write-Log "  Nutanix Host:   $($script:Config.NutanixHost)"
    Write-Log "  LE Appliance:   $($script:Config.LEApplianceUrl)"
    Write-Log "  Environments:"; foreach ($u in $script:Config.EnvironmentIds.Keys) { Write-Log "    $u -> $($script:Config.EnvironmentIds[$u])" }
    Write-Log "  Polling:        $($script:Config.PollingIntervalSec)s"
    Write-Log "  Dry Run:        $DryRun"
    Write-Log "  Run Once:       $RunOnce"
    Write-Log "  Verbose:        $($script:VerboseLogging)"
    Write-Host ""
    
    # Build auth headers
    $nutanixAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($script:Config.NutanixUser):$($script:Config.NutanixPassword)"))
    $nutanixHeaders = @{ "Authorization" = "Basic $nutanixAuth"; "Accept" = "application/json" }
    
    # Validate configuration and connectivity
    if (-not (Test-Connectivity -Headers $nutanixHeaders)) {
        Write-Log "Pre-flight checks failed. Exiting." -Level ERROR
        $script:ExitCode = 1
        throw "Configuration validation failed"
    }
    
    # Time synchronization
    if (-not $SkipTimeSync -and -not $script:Config.SkipTimeSync) {
        Write-Log "Synchronizing time..."
        $script:TimeAdjustment = Get-ServerTimeAdjustment -BaseUrl $script:Config.LEApplianceUrl -Token $script:Config.LEApiToken
        if ($script:TimeAdjustment -ne [TimeSpan]::Zero) { 
            Write-Log "  ✓ Time adjustment: $([math]::Round($script:TimeAdjustment.TotalMilliseconds))ms" -Level VERBOSE
        }
    } else {
        Write-Log "Time sync skipped (disabled in config or command line)"
    }
    Write-Host ""
    
    # Main collection loop
    $iteration = 0; $totalMetricsSent = 0
    while ($true) {
        # Check for Ctrl+C
        if ($script:Interrupted) {
            Write-Log "Interrupt detected - finishing current operation..." -Level WARN
            break
        }
        
        $iteration++
        $iterationStart = Get-Date
        Write-Log "--- Iteration $iteration ---"
        
        try {
            $clusterData = Get-NutanixClusterStats -Headers $nutanixHeaders
            if ($clusterData) {
                # Save raw response if requested
                if ($script:Config.SaveRawResponse -or $SaveRawResponse) { 
                    $rawFile = Join-Path $script:Config.LogDir "NutanixResponse_$($script:Timestamp)_$($iteration.ToString('D4')).json"
                    $clusterData.RawResponse | ConvertTo-Json -Depth 10 | Out-File $rawFile -Encoding UTF8
                    Write-Log "  Saved raw response to: $rawFile" -Level VERBOSE
                }
                
                # Convert metrics
                $metricsByUnit = Convert-ToLEMetrics -ClusterData $clusterData
                $iterationTotal = 0
                foreach ($u in $metricsByUnit.Keys) { $iterationTotal += $metricsByUnit[$u].Metrics.Count }
                Write-Log "Collected $iterationTotal metrics across $($metricsByUnit.Keys.Count) units"
                
                # Upload or dry-run
                if ($DryRun) { 
                    Write-Log "DRY RUN - Would upload:" -Level WARN
                    foreach ($u in $metricsByUnit.Keys) { Write-Log "  [$u] $($metricsByUnit[$u].Metrics.Count) metrics" -Level WARN }
                } else { 
                    $uploadSuccess = $true
                    foreach ($u in $metricsByUnit.Keys) { 
                        if (Send-ToLEPlatformMetrics -Metrics $metricsByUnit[$u].Metrics -Unit $u) { 
                            $totalMetricsSent += $metricsByUnit[$u].Metrics.Count 
                        } else {
                            $uploadSuccess = $false
                        }
                    }
                    if (-not $uploadSuccess) { $script:FailedIterations += $iteration }
                }
                
                $iterationTime = ((Get-Date) - $iterationStart).TotalSeconds
                Write-Log "  Iteration completed in ${iterationTime}s" -Level VERBOSE
            } else {
                Write-Log "Failed to retrieve cluster data" -Level ERROR
                $script:FailedIterations += $iteration
            }
        } catch {
            Write-Log "Error in iteration $iteration" -Level ERROR
            Write-ErrorDetails -ErrorRecord $_
            $script:FailedIterations += $iteration
        }
        
        # Check exit conditions
        if ($RunOnce) { Write-Log "Run-once mode - exiting"; break }
        if ($Iterations -gt 0 -and $iteration -ge $Iterations) { Write-Log "Completed $Iterations iterations - exiting"; break }
        
        # Sleep with interrupt check
        Write-Log "Next poll in $($script:Config.PollingIntervalSec)s... (Ctrl+C to stop)"
        $sleepEnd = (Get-Date).AddSeconds($script:Config.PollingIntervalSec)
        while ((Get-Date) -lt $sleepEnd) {
            if ($script:Interrupted) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($script:Interrupted) { break }
    }
    
} catch {
    Write-Log "FATAL ERROR - Script terminated unexpectedly" -Level ERROR
    Write-ErrorDetails -ErrorRecord $_
    $script:ExitCode = 1
} finally {
    # Always execute cleanup
    $runtime = (Get-Date) - $script:StartTime
    
    Write-Host "`n========================================================================" -ForegroundColor Cyan
    Write-Log "SUMMARY:"
    Write-Log "  Runtime:           $($runtime.ToString('hh\:mm\:ss'))"
    Write-Log "  Iterations:        $iteration"
    Write-Log "  Successful:        $($iteration - $script:FailedIterations.Count)"
    Write-Log "  Failed:            $($script:FailedIterations.Count)"
    if ($script:FailedIterations.Count -gt 0) { Write-Log "  Failed iterations: $($script:FailedIterations -join ', ')" -Level WARN }
    Write-Log "  Metrics sent:      $totalMetricsSent"
    Write-Log "  Errors logged:     $($script:ErrorCount)"
    if ($script:Interrupted) { Write-Log "  Status:            Interrupted by user" -Level WARN }
    Write-Host "========================================================================" -ForegroundColor Cyan
    
    # Stop transcript
    try { Stop-Transcript | Out-Null } catch {}
    
    # Capture any remaining PowerShell errors
    if ($Error.Count -gt 0) {
        Write-Log "PowerShell error buffer contains $($Error.Count) error(s)" -Level WARN
        foreach ($err in $Error | Select-Object -First 5) {
            Write-Log "  - $($err.Exception.Message)" -Level WARN
        }
    }
}

exit $script:ExitCode
