<#
.SYNOPSIS
    Login Enterprise Platform Metrics Retrieval Tool - Nutanix Integration

.DESCRIPTION
    Retrieves Nutanix Platform Metrics data from the Login Enterprise API.
    Supports a single environment ID or an array of IDs.
    Exports results to timestamped CSV and JSON files for analysis or verification.

.PARAMETER LEApiToken
    REQUIRED. Login Enterprise API token (Configuration access level).

.PARAMETER EnvironmentId
    Single environment UUID. Use when all metrics are in one environment.
    Mutually exclusive with -EnvironmentIds.

.PARAMETER EnvironmentIds
    Array of environment UUIDs to retrieve from multiple environments in one run.
    Use this OR -EnvironmentId, not both.
    Example: -EnvironmentIds @("uuid-1","uuid-2")

.PARAMETER StartTime
    Start of time range in ISO 8601 Zulu format. e.g. 2026-04-08T00:00:00.000Z
    If omitted, -LastHours is used instead.

.PARAMETER EndTime
    End of time range in ISO 8601 Zulu format. e.g. 2026-04-08T23:59:59.999Z
    If omitted, -LastHours is used instead.

.PARAMETER LastHours
    Retrieve metrics from the last N hours. Default: 1.
    Ignored if -StartTime and -EndTime are both provided.

.PARAMETER BaseUrl
    Base URL of the Login Enterprise appliance.
    Example: https://bpleva02.southcentralus.cloudapp.azure.com

.PARAMETER ApiVersion
    API version segment. Default: v8-preview.

.PARAMETER MetricGroups
    Optional array of metric group filters to narrow results.

.PARAMETER OutputDir
    Directory for CSV, JSON, and log output files. Defaults to script directory.

.PARAMETER LogFilePath
    Path for script log file. Defaults to OutputDir\Get-LEPlatformMetrics_Log_<timestamp>.txt

.PARAMETER IgnoreCertificateErrors
    Bypass TLS certificate validation for the Login Enterprise appliance connection.
    Use this if the LE appliance is using its default self-signed certificate and
    the machine running this script does not have that certificate in its trust store.
    This bypasses certificate validation entirely. Review your organization's security
    policies before using this in your environment.

.EXAMPLE
    # Last 1 hour, single environment
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -EnvironmentId "uuid" -BaseUrl "https://my.le.com"

.EXAMPLE
    # Last 2 hours, multiple environments
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -BaseUrl "https://my.le.com" -LastHours 2 `
        -EnvironmentIds @("uuid-1","uuid-2")

.EXAMPLE
    # Specific time range, single environment
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -BaseUrl "https://my.le.com" `
        -EnvironmentId "uuid-1" `
        -StartTime "2026-04-08T10:00:00.000Z" -EndTime "2026-04-08T11:00:00.000Z"

.NOTES
    Version: 2.2.0 | Author: Login VSI | May 2026
    PowerShell 5.1+ compatible. Tested on PS 5.1. PS7 supported.
    Companion retrieval script for Nutanix-LE-PlatformMetrics.ps1 v2.2.0
#>

param(
    [Parameter(Mandatory = $true)][string]$LEApiToken,

    # Environment ID - single or array
    [Parameter(Mandatory = $false)][string]$EnvironmentId,
    [Parameter(Mandatory = $false)][string[]]$EnvironmentIds,

    # Time range
    [Parameter(Mandatory = $false)][string]$StartTime,
    [Parameter(Mandatory = $false)][string]$EndTime,
    [Parameter(Mandatory = $false)][int]$LastHours = 1,

    # Connection
    [Parameter(Mandatory = $false)][string]$BaseUrl = "https://your-le-appliance.example.com",
    [Parameter(Mandatory = $false)][string]$ApiVersion = "v8-preview",
    [Parameter(Mandatory = $false)][string[]]$MetricGroups,

    # Output
    [Parameter(Mandatory = $false)][string]$OutputDir,
    [Parameter(Mandatory = $false)][string]$LogFilePath,

    # Cert
    [Parameter(Mandatory = $false)][switch]$IgnoreCertificateErrors
)

# =====================================================
# Version and output setup
# =====================================================
$ScriptVersion = "2.2.0"
$Timestamp     = (Get-Date).ToString("yyyyMMdd_HHmmss")

if (-not $OutputDir) { $OutputDir = $PSScriptRoot }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$CsvPath  = Join-Path $OutputDir "Get-LEPlatformMetrics_$Timestamp.csv"
$JsonPath = Join-Path $OutputDir "Get-LEPlatformMetrics_$Timestamp.json"
if (-not $LogFilePath) { $LogFilePath = Join-Path $OutputDir "Get-LEPlatformMetrics_Log_$Timestamp.txt" }

# =====================================================
# Logging
# =====================================================
function Write-Log {
    param([string]$Message, [switch]$IsError, [switch]$IsWarning)
    $ts        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formatted = "$ts - $Message"
    try {
        $logDir = Split-Path -Parent $LogFilePath
        if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $LogFilePath -Value $formatted -ErrorAction SilentlyContinue
    } catch {}
    if ($IsError)        { Write-Host $formatted -ForegroundColor Red }
    elseif ($IsWarning)  { Write-Host $formatted -ForegroundColor Yellow }
    else                 { Write-Host $formatted }
}

# =====================================================
# Banner
# =====================================================
Write-Host ""
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host "  Login Enterprise Platform Metrics Retrieval Tool v$ScriptVersion" -ForegroundColor Cyan
Write-Host "  Nutanix Integration" -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "==== Script started. Version $ScriptVersion ===="
Write-Log "PowerShell version: $($PSVersionTable.PSVersion.ToString())"

# =====================================================
# Resolve environment IDs
# =====================================================
$ResolvedEnvironmentIds = @()

if ($EnvironmentId -and $EnvironmentIds) {
    Write-Log "Both -EnvironmentId and -EnvironmentIds provided. Using -EnvironmentIds." -IsWarning
    if ($EnvironmentIds.Count -eq 1 -and $EnvironmentIds[0] -match ',') {
        $ResolvedEnvironmentIds = $EnvironmentIds[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $ResolvedEnvironmentIds = $EnvironmentIds
    }
} elseif ($EnvironmentIds) {
    if ($EnvironmentIds.Count -eq 1 -and $EnvironmentIds[0] -match ',') {
        $ResolvedEnvironmentIds = $EnvironmentIds[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $ResolvedEnvironmentIds = $EnvironmentIds
    }
} elseif ($EnvironmentId) {
    if ($EnvironmentId -match ',') {
        $ResolvedEnvironmentIds = $EnvironmentId -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $ResolvedEnvironmentIds = @($EnvironmentId)
    }
}

if ($ResolvedEnvironmentIds.Count -eq 0) {
    Write-Log "No environment IDs provided. Supply -EnvironmentId or -EnvironmentIds." -IsError
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host "  .\Get-LEPlatformMetrics.ps1 -LEApiToken `"token`" -EnvironmentId `"your-env-uuid`" -BaseUrl `"https://my.le.com`"" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Skip placeholder env IDs
$ResolvedEnvironmentIds = @($ResolvedEnvironmentIds | Where-Object { $_ -notmatch "^0{8}-" })
if ($ResolvedEnvironmentIds.Count -eq 0) {
    Write-Log "All provided environment IDs are placeholders (all zeros). Nothing to query." -IsError
    exit 1
}

Write-Log "Resolved $($ResolvedEnvironmentIds.Count) environment ID(s) to query."

# =====================================================
# Resolve time range
# =====================================================
if ($StartTime -and $EndTime) {
    Write-Log "Using provided time range: $StartTime to $EndTime"
} else {
    $EndTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $StartTime = (Get-Date).AddHours(-$LastHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    Write-Log "Using last $LastHours hour(s). Range: $StartTime to $EndTime"
}

Write-Host "Time range   : $StartTime to $EndTime" -ForegroundColor Cyan
Write-Host "Base URL     : $BaseUrl" -ForegroundColor Cyan
Write-Host "API version  : $ApiVersion" -ForegroundColor Cyan
Write-Host "Environments : $($ResolvedEnvironmentIds.Count)" -ForegroundColor Cyan
Write-Host "Output dir   : $OutputDir" -ForegroundColor Cyan
Write-Host ""

# =====================================================
# TLS
# =====================================================
try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Write-Log "Forced TLS 1.2 (PS5)."
    }
} catch {
    Write-Log "Could not set TLS 1.2: $($_.Exception.Message)" -IsWarning
}

# =====================================================
# Certificate handling
#
# Login Enterprise appliance connections use normal certificate validation
# by default. If the machine running this script trusts the LE appliance
# certificate (via your organization's CA, GPO-pushed root, or manual
# install), connections will work without any additional flags.
#
# If you receive an SSL/TLS error, see:
# https://docs.loginvsi.com/login-enterprise/6.6/nutanix-platform-metrics-integration
#
# To install a trusted certificate manually on this machine:
# https://learn.microsoft.com/windows-hardware/drivers/install/trusted-root-certification-authorities-certificate-store
# =====================================================
function Write-LeCertGuidance {
    Write-Log "  If the LE appliance is using a certificate from your organization's CA:" -IsWarning
    Write-Log "    Export the root CA certificate from the appliance and install it to" -IsWarning
    Write-Log "    Trusted Root Certification Authorities on this machine." -IsWarning
    Write-Log "    See: https://learn.microsoft.com/windows-hardware/drivers/install/trusted-root-certification-authorities-certificate-store" -IsWarning
    Write-Log "  If the LE appliance is using its default self-signed certificate:" -IsWarning
    Write-Log "    Re-run with -IgnoreCertificateErrors to bypass certificate validation." -IsWarning
    Write-Log "    See: https://docs.loginvsi.com/login-enterprise/6.6/nutanix-platform-metrics-integration" -IsWarning
}

function Invoke-LERequest {
    param([string]$Url, [hashtable]$Headers)
    # Routes LE API calls through normal cert validation unless -IgnoreCertificateErrors is set.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $params = @{ Uri = $Url; Method = "GET"; Headers = $Headers; ErrorAction = "Stop" }
        if ($IgnoreCertificateErrors) { $params.SkipCertificateCheck = $true }
        return Invoke-RestMethod @params
    } else {
        if ($IgnoreCertificateErrors) {
            # PS5: temporarily install a full bypass policy for this call only
            $saved = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            try {
                $request          = [System.Net.HttpWebRequest]::Create($Url)
                $request.Method   = "GET"
                $request.Headers.Add("Authorization", $Headers["Authorization"])
                $request.Accept   = "application/json"
                $request.Timeout  = 60000
                $response         = $request.GetResponse()
                $stream           = $response.GetResponseStream()
                $reader           = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $rawJson          = $reader.ReadToEnd()
                $reader.Close(); $response.Close()
                return $rawJson | ConvertFrom-Json
            } finally {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $saved
            }
        } else {
            $request          = [System.Net.HttpWebRequest]::Create($Url)
            $request.Method   = "GET"
            $request.Headers.Add("Authorization", $Headers["Authorization"])
            $request.Accept   = "application/json"
            $request.Timeout  = 60000
            $response         = $request.GetResponse()
            $stream           = $response.GetResponseStream()
            $reader           = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $rawJson          = $reader.ReadToEnd()
            $reader.Close(); $response.Close()
            return $rawJson | ConvertFrom-Json
        }
    }
}

# =====================================================
# Main
# =====================================================
try {

    if ($IgnoreCertificateErrors) {
        Write-Host ""
        Write-Host "  [WARN] -IgnoreCertificateErrors is active." -ForegroundColor Yellow
        Write-Host "  Certificate validation for the Login Enterprise appliance is bypassed." -ForegroundColor Yellow
        Write-Host "  Review your organization's security policies before using this in your environment." -ForegroundColor Yellow
        Write-Host "  See: https://docs.loginvsi.com/login-enterprise/6.6/nutanix-platform-metrics-integration" -ForegroundColor Yellow
        Write-Host ""
    }

    $AllResults  = @()
    $AllDataRows = @()

    foreach ($envId in $ResolvedEnvironmentIds) {
        Write-Host "Querying environment: $envId" -ForegroundColor Yellow
        Write-Log "Querying environment ID: $envId"

        # Build URL
        try {
            $ub = New-Object System.UriBuilder($BaseUrl.TrimEnd("/"))
            $ub.Path = ($ub.Path.TrimEnd("/") + "/publicApi/$ApiVersion/platform-metrics").TrimStart("/")
            $queryParts = @(
                "from=$([uri]::EscapeDataString($StartTime))",
                "to=$([uri]::EscapeDataString($EndTime))",
                "environmentIds=$([uri]::EscapeDataString($envId))"
            )
            if ($MetricGroups) { foreach ($g in $MetricGroups) { $queryParts += "metricGroups=$([uri]::EscapeDataString($g))" } }
            $ub.Query = $queryParts -join "&"
            $FullUrl  = $ub.Uri.AbsoluteUri
            Write-Log "URL: $FullUrl"
        } catch {
            Write-Log "Failed to construct URL for env $envId : $($_.Exception.Message)" -IsError
            continue
        }

        $headers    = @{ "Authorization" = "Bearer $LEApiToken"; "Accept" = "application/json" }
        $jsonResult = $null

        try {
            $jsonResult = Invoke-LERequest -Url $FullUrl -Headers $headers
            Write-Log "GET succeeded for env $envId."
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "SSL|TLS|trust|certificate|secure channel") {
                Write-Log "SSL/TLS error connecting to LE appliance: $msg" -IsError
                Write-LeCertGuidance
            } else {
                Write-Log "GET failed for env $envId : $msg" -IsError
            }
            continue
        }

        if ($jsonResult) {
            $AllResults += $jsonResult
            $seriesCount = 0
            foreach ($metric in $jsonResult) {
                $seriesCount++
                if ($metric.dataPoints) {
                    foreach ($dp in $metric.dataPoints) {
                        $AllDataRows += [PSCustomObject]@{
                            timestamp      = [string]$dp.timestamp
                            value          = $dp.value
                            metricId       = $metric.metricId
                            environmentKey = $metric.environmentKey
                            displayName    = $metric.displayName
                            unit           = $metric.unit
                            instance       = $metric.instance
                            componentType  = $metric.componentType
                            group          = $metric.group
                            customTags     = if ($metric.customTags) { ($metric.customTags | ConvertTo-Json -Compress) } else { "" }
                        }
                    }
                }
            }
            Write-Host "  Retrieved $seriesCount metric series" -ForegroundColor Green
            Write-Log "Retrieved $seriesCount metric series for env $envId."
        } else {
            Write-Log "No data returned for env $envId." -IsWarning
        }
    }

    # =====================================================
    # Summary
    # =====================================================
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "  SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan

    if ($AllDataRows.Count -gt 0) {
        $AllDataRows | Group-Object -Property metricId | ForEach-Object {
            $sample = $_.Group | Select-Object -First 1
            Write-Host "  $($sample.displayName) [$($sample.unit)] instance=$($sample.instance) - $($_.Count) data points" -ForegroundColor White
        }
    } else {
        Write-Host "  No metrics found for the specified time range and environment(s)." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Total data points    : $($AllDataRows.Count)" -ForegroundColor Cyan
    Write-Host "  Environments queried : $($ResolvedEnvironmentIds.Count)" -ForegroundColor Cyan

    # Save outputs
    if ($AllResults.Count -gt 0) {
        try {
            $AllResults | ConvertTo-Json -Depth 10 | Out-File $JsonPath -Encoding UTF8
            Write-Host "  JSON saved : $JsonPath" -ForegroundColor Green
            Write-Log "JSON saved to: $JsonPath"
        } catch { Write-Log "Failed to write JSON: $($_.Exception.Message)" -IsError }
    }

    if ($AllDataRows.Count -gt 0) {
        try {
            $AllDataRows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8
            Write-Host "  CSV saved  : $CsvPath" -ForegroundColor Green
            Write-Log "CSV saved to: $CsvPath"
        } catch { Write-Log "Failed to write CSV: $($_.Exception.Message)" -IsError }
    }

    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host ""

    if ($AllDataRows.Count -gt 0) { Write-Log "Script completed successfully." }
    else { Write-Log "Script completed - no data for specified time range and environment(s)." -IsWarning }

} finally {
    # nothing to clean up
}
