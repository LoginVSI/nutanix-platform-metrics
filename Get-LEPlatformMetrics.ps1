<#
.SYNOPSIS
    Login Enterprise Platform Metrics Retrieval Tool
    
.DESCRIPTION
    Retrieves Platform Metrics data from Login Enterprise API.
    Exports to CSV and JSON for analysis or verification.
    
.PARAMETER LEApiToken
    REQUIRED. Login Enterprise API token.

.PARAMETER EnvironmentId
    Single environment ID to query (queries one environment only)

.PARAMETER EnvironmentIdPercent
    Environment ID for percent metrics (can combine with other -EnvironmentId* params)

.PARAMETER EnvironmentIdIops
    Environment ID for IOPS metrics (can combine with other -EnvironmentId* params)

.PARAMETER EnvironmentIdMs
    Environment ID for latency metrics (can combine with other -EnvironmentId* params)

.PARAMETER EnvironmentIdKBps
    Environment ID for bandwidth metrics (can combine with other -EnvironmentId* params)
    
.PARAMETER LastHours
    Retrieve metrics from last N hours. Default: 1

.PARAMETER LEApiVersion
    Login Enterprise API version. Default: v8-preview

.EXAMPLE
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -LastHours 1

.EXAMPLE
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -BaseUrl "https://le.example.com" -EnvironmentIdPercent "env-id-1" -EnvironmentIdIops "env-id-2" -EnvironmentIdMs "env-id-3" -EnvironmentIdKBps "env-id-4" -LastHours 1

.NOTES
    Version: 1.2.0 | Author: Login VSI | January 2026
#>

param(
    [Parameter(Mandatory = $true)][string]$LEApiToken,
    [Parameter(Mandatory = $false)][string]$StartTime,
    [Parameter(Mandatory = $false)][string]$EndTime,
    [Parameter(Mandatory = $false)][string]$EnvironmentId,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdPercent,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdIops,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdMs,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdKBps,
    [Parameter(Mandatory = $false)][string]$BaseUrl = "https://your-le-appliance.example.com",
    [Parameter(Mandatory = $false)][string]$LEApiVersion = "v8-preview",
    [Parameter(Mandatory = $false)][int]$LastHours = 1,
    [Parameter(Mandatory = $false)][string[]]$MetricGroups,
    [Parameter(Mandatory = $false)][string]$OutputDir
)

$Version = "1.2.0"
if (-not $OutputDir) { $OutputDir = $PSScriptRoot }
$Timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$CsvPath = Join-Path $OutputDir "PlatformMetrics_$Timestamp.csv"
$JsonPath = Join-Path $OutputDir "PlatformMetrics_$Timestamp.json"

# Build environment ID list from parameters
$EnvironmentIds = @()
if ($EnvironmentId) {
    # Single environment specified
    $EnvironmentIds = @($EnvironmentId)
} elseif ($EnvironmentIdPercent -or $EnvironmentIdIops -or $EnvironmentIdMs -or $EnvironmentIdKBps) {
    # Individual environment IDs specified
    if ($EnvironmentIdPercent) { $EnvironmentIds += $EnvironmentIdPercent }
    if ($EnvironmentIdIops) { $EnvironmentIds += $EnvironmentIdIops }
    if ($EnvironmentIdMs) { $EnvironmentIds += $EnvironmentIdMs }
    if ($EnvironmentIdKBps) { $EnvironmentIds += $EnvironmentIdKBps }
} else {
    # Use defaults
    $EnvironmentIds = @(
        "00000000-0000-0000-0000-000000000001",  # percent
        "00000000-0000-0000-0000-000000000002",  # iops
        "00000000-0000-0000-0000-000000000003",  # ms
        "00000000-0000-0000-0000-000000000004"   # kBps
    )
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host "  Login Enterprise Platform Metrics Retrieval Tool v$Version" -ForegroundColor Cyan
Write-Host "========================================================================`n" -ForegroundColor Cyan

# Handle time range
if ($LastHours -gt 0 -and -not $StartTime) {
    $EndTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $StartTime = (Get-Date).AddHours(-$LastHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

Write-Host "Time range: $StartTime to $EndTime" -ForegroundColor Cyan
Write-Host "Base URL: $BaseUrl" -ForegroundColor Cyan

# TLS setup
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

$AllResults = @()
$AllDataRows = @()

foreach ($envId in $EnvironmentIds) {
    Write-Host "`nQuerying environment: $envId" -ForegroundColor Yellow
    
    $queryParams = @(
        "from=$([uri]::EscapeDataString($StartTime))",
        "to=$([uri]::EscapeDataString($EndTime))",
        "environmentIds=$([uri]::EscapeDataString($envId))"
    )
    if ($MetricGroups) { foreach ($g in $MetricGroups) { $queryParams += "metricGroups=$([uri]::EscapeDataString($g))" } }
    
    $uri = "$($BaseUrl.TrimEnd('/'))/publicApi/$LEApiVersion/platform-metrics?" + ($queryParams -join "&")
    $headers = @{ "Authorization" = "Bearer $LEApiToken"; "Accept" = "application/json" }
    
    try {
        $params = @{ Uri = $uri; Method = "GET"; Headers = $headers }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipCertificateCheck = $true }
        $response = Invoke-RestMethod @params
        
        if ($response) {
            $AllResults += $response
            foreach ($metric in $response) {
                if ($metric.dataPoints) {
                    foreach ($dp in $metric.dataPoints) {
                        $AllDataRows += [PSCustomObject]@{
                            timestamp = $dp.timestamp
                            value = $dp.value
                            metricId = $metric.metricId
                            displayName = $metric.displayName
                            unit = $metric.unit
                            instance = $metric.instance
                            group = $metric.group
                            environmentKey = $metric.environmentKey
                        }
                    }
                }
            }
            Write-Host "  Retrieved $($response.Count) metric series" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Summary
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
$metricSummary = $AllDataRows | Group-Object -Property metricId | ForEach-Object {
    $sample = $_.Group | Select-Object -First 1
    [PSCustomObject]@{
        MetricId = $_.Name
        DisplayName = $sample.displayName
        Unit = $sample.unit
        DataPoints = $_.Count
    }
}

if ($metricSummary) {
    $metricSummary | ForEach-Object {
        Write-Host "  $($_.DisplayName) [$($_.Unit)] - $($_.DataPoints) data points" -ForegroundColor White
    }
} else {
    Write-Host "  No metrics found for the specified time range" -ForegroundColor Yellow
}

Write-Host "`nTotal data points: $($AllDataRows.Count)" -ForegroundColor Cyan

# Save outputs
if ($AllResults.Count -gt 0) {
    $AllResults | ConvertTo-Json -Depth 10 | Out-File $JsonPath -Encoding UTF8
    Write-Host "JSON saved: $JsonPath" -ForegroundColor Green
}

if ($AllDataRows.Count -gt 0) {
    $AllDataRows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8
    Write-Host "CSV saved: $CsvPath" -ForegroundColor Green
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
