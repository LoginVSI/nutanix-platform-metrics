<#
.SYNOPSIS
    Login Enterprise Platform Metrics Retrieval Tool - Nutanix Integration

.DESCRIPTION
    Retrieves Nutanix Platform Metrics data from the Login Enterprise API.
    Supports single environment ID, per-unit environment IDs, or an array of IDs.
    Exports results to timestamped CSV and JSON files for analysis or verification.

.PARAMETER LEApiToken
    REQUIRED. Login Enterprise API token (Configuration access level).

.PARAMETER EnvironmentId
    Single environment UUID. Use for Power BI / single-environment mode.
    Mutually exclusive with per-unit params and -EnvironmentIds.

.PARAMETER EnvironmentIds
    Array of environment UUIDs. Use this OR -EnvironmentId, not both.
    Example: -EnvironmentIds @("uuid-1","uuid-2")

.PARAMETER EnvironmentIdPercent
    Environment UUID for percent-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdIops
    Environment UUID for iops-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdMs
    Environment UUID for ms-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdKBps
    Environment UUID for kBps-unit metrics (multi-environment mode).

.PARAMETER EnvironmentIdBytesPerSec
    Environment UUID for bytesPerSec-unit metrics (VM network, multi-environment mode).

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

.PARAMETER ImportServerCert
    Import the LE appliance certificate into CurrentUser\Root before the request.
    Use for appliances with self-signed or private CA certificates.

.PARAMETER KeepCert
    Used with -ImportServerCert. Keeps imported certs after the run.
    If omitted, any newly imported certs are removed on exit.

.EXAMPLE
    # Last 1 hour, single environment (Power BI mode)
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -EnvironmentId "uuid" -BaseUrl "https://my.le.com"

.EXAMPLE
    # Last 2 hours, multi-environment mode
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -BaseUrl "https://my.le.com" -LastHours 2 `
        -EnvironmentIdPercent "uuid-1" -EnvironmentIdIops "uuid-2" -EnvironmentIdMs "uuid-3" -EnvironmentIdKBps "uuid-4"

.EXAMPLE
    # Specific time range, all 5 environments
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -BaseUrl "https://my.le.com" `
        -StartTime "2026-04-08T10:00:00.000Z" -EndTime "2026-04-08T11:00:00.000Z" `
        -EnvironmentIdPercent "uuid-1" -EnvironmentIdIops "uuid-2" `
        -EnvironmentIdMs "uuid-3" -EnvironmentIdKBps "uuid-4" -EnvironmentIdBytesPerSec "uuid-5"

.NOTES
    Version: 2.0.0 | Author: Login VSI | April 2026
    PowerShell 5.1+ compatible. Tested on PS 5.1. PS7 supported.
    Companion retrieval script for Nutanix-LE-PlatformMetrics.ps1 v2.0.0
#>

param(
    [Parameter(Mandatory = $true)][string]$LEApiToken,

    # Environment ID modes - single, array, or per-unit
    [Parameter(Mandatory = $false)][string]$EnvironmentId,
    [Parameter(Mandatory = $false)][string[]]$EnvironmentIds,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdPercent,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdIops,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdMs,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdKBps,
    [Parameter(Mandatory = $false)][string]$EnvironmentIdBytesPerSec,

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
    [Parameter(Mandatory = $false)][switch]$ImportServerCert,
    [Parameter(Mandatory = $false)][switch]$KeepCert
)

# =====================================================
# Version and output setup
# =====================================================
$ScriptVersion = "2.0.0"
$Timestamp     = (Get-Date).ToString("yyyyMMdd_HHmmss")

if (-not $OutputDir) { $OutputDir = $PSScriptRoot }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$CsvPath  = Join-Path $OutputDir "Get-LEPlatformMetrics_$Timestamp.csv"
$JsonPath = Join-Path $OutputDir "Get-LEPlatformMetrics_$Timestamp.json"
if (-not $LogFilePath) { $LogFilePath = Join-Path $OutputDir "Get-LEPlatformMetrics_Log_$Timestamp.txt" }

$script:ImportedCertThumbs = @()

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
} else {
    # Per-unit mode
    if ($EnvironmentIdPercent)    { $ResolvedEnvironmentIds += $EnvironmentIdPercent }
    if ($EnvironmentIdIops)       { $ResolvedEnvironmentIds += $EnvironmentIdIops }
    if ($EnvironmentIdMs)         { $ResolvedEnvironmentIds += $EnvironmentIdMs }
    if ($EnvironmentIdKBps)       { $ResolvedEnvironmentIds += $EnvironmentIdKBps }
    if ($EnvironmentIdBytesPerSec){ $ResolvedEnvironmentIds += $EnvironmentIdBytesPerSec }
}

if ($ResolvedEnvironmentIds.Count -eq 0) {
    Write-Log "No environment IDs provided. Supply -EnvironmentId, -EnvironmentIds, or per-unit params." -IsError
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
# Certificate functions
# =====================================================
function Get-RemoteCertificates {
    param([Parameter(Mandatory=$true)][string]$ServerHost, [int]$ServerPort = 443)
    $certList = New-Object System.Collections.ArrayList
    function Add-ChainFromLeaf([System.Security.Cryptography.X509Certificates.X509Certificate2]$leaf) {
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $null = $chain.Build($leaf)
        foreach ($elem in $chain.ChainElements) {
            $certObj = if ($elem.Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) { $elem.Certificate } else { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($elem.Certificate) }
            [void]$certList.Add($certObj)
        }
    }
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($ServerHost, $ServerPort)
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($ServerHost)
        $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        Add-ChainFromLeaf -leaf $leaf
        try { $ssl.Close(); $client.Close() } catch {}
        return ,($certList.ToArray())
    } catch {
        try { if ($ssl) { $ssl.Dispose() } } catch {}
        try { if ($client) { $client.Close() } } catch {}
    }
    try {
        $oldCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($s,$c,$ch,$e) return $true }
        try {
            $req = [System.Net.HttpWebRequest]::Create("https://$ServerHost/")
            $req.Method = "HEAD"; $req.Timeout = 15000
            try { $resp = $req.GetResponse(); try { $resp.Close() } catch {} } catch [System.Net.WebException] { if ($_.Exception.Response) { try { $_.Exception.Response.Close() } catch {} } }
            $svcCert = $req.ServicePoint.Certificate
            if ($svcCert) { Add-ChainFromLeaf -leaf (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($svcCert)) }
            else { throw "No certificate from ServicePoint for $ServerHost" }
        } finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
    } catch { throw $_ }
    return ,($certList.ToArray())
}

function Import-ServerCertificates {
    param([Parameter(Mandatory=$true)][string]$ServerHost, [int]$ServerPort = 443)
    Write-Log "Fetching certificate from ${ServerHost}:${ServerPort}..."
    $importedThumbs = @()
    try { $certs = Get-RemoteCertificates -ServerHost $ServerHost -ServerPort $ServerPort }
    catch { Write-Log "Failed to obtain certificate: $($_.Exception.Message)" -IsError; return ,@() }
    if (-not $certs -or $certs.Length -eq 0) { Write-Log "No certificates found." -IsError; return ,@() }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root","CurrentUser")
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        foreach ($c in $certs) {
            $x2    = if ($c -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) { $c } else { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($c) }
            $thumb = $x2.Thumbprint
            $exists = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumb }
            if (-not $exists) { $store.Add($x2); $importedThumbs += $thumb; Write-Log "Imported cert $thumb into CurrentUser\Root" }
            else { Write-Log "Cert $thumb already present." }
        }
    } catch { Write-Log "Import error: $($_.Exception.Message)" -IsError }
    finally { try { $store.Close() } catch {} }
    return ,$importedThumbs
}

function Remove-ImportedCertificates {
    param([string[]]$Thumbprints)
    if (-not $Thumbprints -or $Thumbprints.Length -eq 0) { return }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root","CurrentUser")
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        foreach ($thumb in $Thumbprints) {
            $match = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumb }
            if ($match) { $store.Remove($match); Write-Log "Removed cert $thumb from CurrentUser\Root" }
        }
    } finally { $store.Close() }
}

# =====================================================
# Main
# =====================================================
try {

    # Import cert if requested
    if ($ImportServerCert) {
        try {
            $leUri  = [uri]$BaseUrl
            $lePort = if ($leUri.Port -ne -1 -and $leUri.Port -ne 0) { $leUri.Port } else { 443 }
            Write-Log "Importing LE appliance certificate..."
            $script:ImportedCertThumbs = Import-ServerCertificates -ServerHost $leUri.Host -ServerPort $lePort
            if ($script:ImportedCertThumbs.Length -gt 0) { Write-Log "Imported $($script:ImportedCertThumbs.Length) certificate(s)." }
        } catch {
            Write-Log "Certificate import failed: $($_.Exception.Message)" -IsWarning
        }
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
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $jsonResult = Invoke-RestMethod -Uri $FullUrl -Method GET -Headers $headers -SkipCertificateCheck -ErrorAction Stop
            } else {
                $request = [System.Net.HttpWebRequest]::Create($FullUrl)
                $request.Method = "GET"
                $request.Headers.Add("Authorization", "Bearer $LEApiToken")
                $request.Accept  = "application/json"
                $request.Timeout = 60000
                $response = $request.GetResponse()
                $stream   = $response.GetResponseStream()
                $reader   = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $rawJson  = $reader.ReadToEnd()
                $reader.Close(); $response.Close()
                $jsonResult = $rawJson | ConvertFrom-Json
            }
            Write-Log "GET succeeded for env $envId."
        } catch {
            Write-Log "GET failed for env $envId : $($_.Exception.Message)" -IsError
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
    if ($ImportServerCert -and -not $KeepCert -and $script:ImportedCertThumbs.Length -gt 0) {
        try { Remove-ImportedCertificates -Thumbprints $script:ImportedCertThumbs }
        catch { Write-Log "Failed to remove imported cert(s): $($_.Exception.Message)" -IsWarning }
    }
}
