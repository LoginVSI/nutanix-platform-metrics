<#
.SYNOPSIS
    Login Enterprise Platform Metrics Retrieval Tool
    
.DESCRIPTION
    Retrieves Platform Metrics data from Login Enterprise API.
    Exports to CSV and JSON for analysis or verification.
    
.PARAMETER LEApiToken
    REQUIRED. Login Enterprise API token.

.PARAMETER ImportServerCert
    Import Login Enterprise appliance certificate into CurrentUser\Root store (for self-signed certs)

.PARAMETER KeepCert
    Keep imported certificate after script completes (default: remove on exit)

.EXAMPLE
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -LastHours 1

.EXAMPLE
    .\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -ImportServerCert -EnvironmentIdPercent "env-id" -LastHours 1

.NOTES
    Version: 1.3.0 | Author: Login VSI | January 2026
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
    [Parameter(Mandatory = $false)][string]$OutputDir,
    [Parameter(Mandatory = $false)][switch]$ImportServerCert,
    [Parameter(Mandatory = $false)][switch]$KeepCert
)

$Version = "1.3.0"
if (-not $OutputDir) { $OutputDir = $PSScriptRoot }
$Timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$CsvPath = Join-Path $OutputDir "PlatformMetrics_$Timestamp.csv"
$JsonPath = Join-Path $OutputDir "PlatformMetrics_$Timestamp.json"
$script:ImportedCertThumbs = @()

$EnvironmentIds = @()
if ($EnvironmentId) {
    $EnvironmentIds = @($EnvironmentId)
} elseif ($EnvironmentIdPercent -or $EnvironmentIdIops -or $EnvironmentIdMs -or $EnvironmentIdKBps) {
    if ($EnvironmentIdPercent) { $EnvironmentIds += $EnvironmentIdPercent }
    if ($EnvironmentIdIops) { $EnvironmentIds += $EnvironmentIdIops }
    if ($EnvironmentIdMs) { $EnvironmentIds += $EnvironmentIdMs }
    if ($EnvironmentIdKBps) { $EnvironmentIds += $EnvironmentIdKBps }
} else {
    $EnvironmentIds = @(
        "00000000-0000-0000-0000-000000000001",
        "00000000-0000-0000-0000-000000000002",
        "00000000-0000-0000-0000-000000000003",
        "00000000-0000-0000-0000-000000000004"
    )
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host "  Login Enterprise Platform Metrics Retrieval Tool v$Version" -ForegroundColor Cyan
Write-Host "========================================================================`n" -ForegroundColor Cyan

if ($LastHours -gt 0 -and -not $StartTime) {
    $EndTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $StartTime = (Get-Date).AddHours(-$LastHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

Write-Host "Time range: $StartTime to $EndTime" -ForegroundColor Cyan
Write-Host "Base URL: $BaseUrl" -ForegroundColor Cyan

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
        $client = $null; $ssl = $null
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($ServerHost, $ServerPort)
        $stream = $client.GetStream()
        $ssl = New-Object System.Net.Security.SslStream($stream, $false, ({ $true }))
        $ssl.AuthenticateAsClient($ServerHost)
        $remote = $ssl.RemoteCertificate
        if ($remote) {
            $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($remote)
            Add-ChainFromLeaf -leaf $leaf
            try { $ssl.Close() } catch {}
            try { $client.Close() } catch {}
            return ,($certList.ToArray())
        }
    } catch {
        try { if ($ssl) { $ssl.Dispose() } } catch {}
        try { if ($client) { $client.Close() } } catch {}
    }
    try {
        $oldCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($s,$c,$ch,$e) return $true }
        try {
            $uri = "https://$ServerHost/"
            $req = [System.Net.HttpWebRequest]::Create($uri)
            $req.Method = 'HEAD'
            $req.Timeout = 15000
            try {
                $resp = $req.GetResponse()
                try { $resp.Close() } catch {}
            } catch [System.Net.WebException] {
                if ($_.Exception.Response) { try { $_.Exception.Response.Close() } catch {} }
            }
            $svcCert = $req.ServicePoint.Certificate
            if ($svcCert) {
                $leaf2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($svcCert)
                Add-ChainFromLeaf -leaf $leaf2
            } else { throw "No certificate available" }
        } finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback
        }
    } catch { throw $_ }
    return ,($certList.ToArray())
}

function Import-ServerCertificates {
    param([Parameter(Mandatory=$true)][string]$ServerHost, [int]$ServerPort = 443)
    Write-Host "Fetching certificate from ${ServerHost}:${ServerPort}..."
    $importedThumbs = @()
    try { $certs = Get-RemoteCertificates -ServerHost $ServerHost -ServerPort $ServerPort }
    catch {
        Write-Host "Failed to obtain certificate: $($_.Exception.Message)" -ForegroundColor Red
        return ,@()
    }
    if (-not $certs -or $certs.Length -eq 0) {
        Write-Host "No certificates found" -ForegroundColor Red
        return ,@()
    }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root","CurrentUser")
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        foreach ($c in $certs) {
            $x2 = if ($c -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) { $c } else { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($c) }
            $thumb = $x2.Thumbprint
            $exists = $false
            foreach ($ec in $store.Certificates) { if ($ec.Thumbprint -eq $thumb) { $exists = $true; break } }
            if (-not $exists) {
                $store.Add($x2)
                $importedThumbs += $thumb
                Write-Host "Imported cert $thumb" -ForegroundColor Green
            }
        }
    } catch { Write-Host "Import error: $($_.Exception.Message)" -ForegroundColor Red }
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
            if ($match) {
                $store.Remove($match)
                Write-Host "Removed cert $thumb" -ForegroundColor Green
            }
        }
    } finally { $store.Close() }
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    if ($ImportServerCert) {
        try {
            $leUri = [uri]$BaseUrl
            $lePort = if ($leUri.Port -ne -1 -and $leUri.Port -ne 0) { $leUri.Port } else { 443 }
            Write-Host "Importing Login Enterprise certificate..." -ForegroundColor Cyan
            $script:ImportedCertThumbs = Import-ServerCertificates -ServerHost $leUri.Host -ServerPort $lePort
            if ($script:ImportedCertThumbs.Length -gt 0) {
                Write-Host "Imported $($script:ImportedCertThumbs.Length) certificate(s)" -ForegroundColor Green
            }
        } catch {
            Write-Host "Certificate import failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
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

    if ($AllResults.Count -gt 0) {
        $AllResults | ConvertTo-Json -Depth 10 | Out-File $JsonPath -Encoding UTF8
        Write-Host "JSON saved: $JsonPath" -ForegroundColor Green
    }

    if ($AllDataRows.Count -gt 0) {
        $AllDataRows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8
        Write-Host "CSV saved: $CsvPath" -ForegroundColor Green
    }

    Write-Host "`n========================================================================" -ForegroundColor Cyan
} finally {
    if ($ImportServerCert -and -not $KeepCert -and $script:ImportedCertThumbs.Length -gt 0) {
        try {
            Write-Host "Removing imported certificates..." -ForegroundColor Cyan
            Remove-ImportedCertificates -Thumbprints $script:ImportedCertThumbs
        } catch {
            Write-Host "Failed to remove certs: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
