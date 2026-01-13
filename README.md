# Nutanix to Login Enterprise Platform Metrics Integration

Collects performance metrics from Nutanix clusters and uploads them to Login Enterprise Platform Metrics for visualization and analysis.

## Overview

This integration polls Nutanix Prism Element API for cluster-level performance statistics and sends them to Login Enterprise's Platform Metrics feature. Metrics are organized by unit type (percent, iops, ms, kBps) into separate environments for proper Y-axis scaling in the UI.

## Metrics Collected (Cluster Level)

| Category | Metrics | Unit |
|----------|---------|------|
| **CPU** | Cluster CPU Usage | percent |
| **Memory** | Cluster Memory Usage | percent |
| **Storage IOPS** | Total, Read, Write | iops |
| **Storage Latency** | Average, Read, Write | ms |
| **IO Bandwidth** | Total, Read, Write | kBps |

## Requirements

- **PowerShell**: 5.1 or 7.x (no admin privileges required)
- **Nutanix**: Prism Element with API access (v2 API)
- **Login Enterprise**: Appliance with Platform Metrics enabled (preview feature)
- **Network**: Connectivity to both Nutanix (port 9440) and Login Enterprise (port 443)

## How It Works

```
[Data Flow]
Nutanix Prism Element --> PowerShell Collector --> Login Enterprise API --> Platform Metrics UI
      (Port 9440)           (Converts metrics)      (v8-preview endpoint)    (4 Environments)
                                                                               
Metrics by Unit:
- percent: CPU Usage, Memory Usage
- iops: Storage IOPS (Total, Read, Write)  
- ms: Storage Latency (Avg, Read, Write)
- kBps: IO Bandwidth (Total, Read, Write)
```

### Why 4 Environments?

Login Enterprise Platform Metrics displays one Y-axis unit at a time. To visualize all metrics simultaneously, we split them by unit type into separate environments, each linked to its own continuous test.

**Future versions may support multi-unit visualization in a single environment.**

## Prerequisites

### Login Enterprise Setup

Before using these scripts, configure Login Enterprise Platform Metrics:

1. **Enable Platform Metrics Feature** (LE 6.4.3+)
   - Open browser DevTools console (F12)
   - Run: `leSetFeatureFlag('platformMetrics', 1)`
   - Refresh page
   - **Note:** This feature flag requirement may change in future LE versions. Check release notes if using LE 6.5+

2. **Create Environments** (one per unit type)
   - [Configure Environments Guide](https://docs.loginvsi.com/login-enterprise/6.4/configuring-environments-optional)
   - Create 4 environments: percent, iops, ms, kBps
   - Copy each environment ID from browser URL when viewing the environment

3. **Create Continuous Tests** (one per environment)
   - [Configure Continuous Testing Guide](https://docs.loginvsi.com/login-enterprise/6.4/configuring-continuous-testing)
   - Link each continuous test to its corresponding environment
   - [View Results Guide](https://docs.loginvsi.com/login-enterprise/6.4/viewing-continuous-testing-results)

**Alternative:** You can also use Load Tests instead of Continuous Tests
   - [Configure Load Testing Guide](https://docs.loginvsi.com/login-enterprise/6.4/configuring-load-testing)
   - [View Load Test Results Guide](https://docs.loginvsi.com/login-enterprise/6.4/viewing-load-testing-results)

## Quick Start

### 1. Enable Platform Metrics in Login Enterprise

**Note:** As of Login Enterprise 6.4.3 (current production release), Platform Metrics is a preview feature that requires manual enablement. If you're using a newer version of Login Enterprise, check the release notes as this feature flag may no longer be required.

In your browser's DevTools console (F12):
```javascript
leSetFeatureFlag('platformMetrics', 1)
```
Refresh the page after running this command.

### 2. Create Environments

Create 4 environments in Login Enterprise (Configuration → Environments):
- One for `percent` metrics (CPU, Memory)
- One for `iops` metrics (Storage IOPS)
- One for `ms` metrics (Storage Latency)
- One for `kBps` metrics (IO Bandwidth)

Note the UUID of each environment.

### 3. Create API Token

In Login Enterprise:
1. Go to Configuration → System Access Tokens
2. Create a new token with **Configuration** access level
3. Copy the token (you won't see it again)

### 4. Configure and Run

#### Option A: Using Config File

1. Edit `nutanix-config.json` with your environment IDs:
```json
{
    "NutanixHost": "your-nutanix-prism.example.com",
    "NutanixUser": "admin",
    "LEApplianceUrl": "https://your-le-appliance.example.com",
    "EnvironmentIds": {
        "percent": "your-percent-env-uuid",
        "iops": "your-iops-env-uuid",
        "ms": "your-ms-env-uuid",
        "kBps": "your-kbps-env-uuid"
    },
    "PollingIntervalSec": 30,
    "MaxRetries": 3,
    "SkipTimeSync": false
}
```

2. Run the collector:
```powershell
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "YourPass" -LEApiToken "YourToken" -ConfigFile ".\nutanix-config.json"
```

#### Option B: Command Line Only

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "YourPass" `
    -LEApiToken "YourToken" `
    -NutanixHost "your-nutanix-prism.example.com" `
    -LEApplianceUrl "https://your-le-appliance.example.com"
```

### 5. View Results

1. Open Login Enterprise web UI
2. Navigate to your continuous test linked to one of the environments
3. Click on Platform Metrics tab
4. View the graphs (open multiple tabs for different unit types)

## Usage Examples

```powershell
# Run once (for testing)
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -RunOnce

# Override all values from command line (no JSON config needed)
.\Nutanix-LE-PlatformMetrics.ps1 `
    -NutanixPassword "pass" `
    -LEApiToken "token" `
    -NutanixHost "10.0.0.1" `
    -LEApplianceUrl "https://le.example.com" `
    -EnvironmentIdPercent "env-id-1" `
    -EnvironmentIdIops "env-id-2" `
    -EnvironmentIdMs "env-id-3" `
    -EnvironmentIdKBps "env-id-4" `
    -RunOnce

# Dry run (fetch but don't upload)
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -DryRun -RunOnce

# Run 10 iterations then stop
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -Iterations 10

# Custom polling interval (60 seconds)
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -PollingIntervalSec 60

# Continuous polling (Ctrl+C to stop)
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token"
```

## Retrieving Metrics

Use the retrieval script to export Platform Metrics data:

```powershell
# Get last hour from all 4 environments
.\Get-LEPlatformMetrics.ps1 `
    -LEApiToken "token" `
    -BaseUrl "https://le.example.com" `
    -EnvironmentIdPercent "env-id-1" `
    -EnvironmentIdIops "env-id-2" `
    -EnvironmentIdMs "env-id-3" `
    -EnvironmentIdKBps "env-id-4" `
    -LastHours 1

# Get last 24 hours (uses generic placeholder IDs if not specified)
.\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -LastHours 24

# Query single environment only
.\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -EnvironmentId "specific-env-id" -LastHours 1

# Filter by metric group
.\Get-LEPlatformMetrics.ps1 -LEApiToken "token" -LastHours 24 -MetricGroups @("Nutanix")
```

Outputs:
- `PlatformMetrics_YYYYMMDD_HHMMSS.json` - Raw API response
- `PlatformMetrics_YYYYMMDD_HHMMSS.csv` - Flattened data for analysis

## Configuration System

### How Configuration Works

The script uses a **3-tier priority system** for configuration:

```
1. Built-in Defaults (in script)
   ↓ overridden by
2. JSON Config File (if provided)
   ↓ overridden by
3. Command Line Parameters (highest priority)
```

**Examples:**

```powershell
# Uses all defaults from script
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -RunOnce

# Uses JSON config, overrides defaults
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -ConfigFile "config.json" -RunOnce

# Uses JSON config BUT command line overrides the host
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -ConfigFile "config.json" -NutanixHost "other-nutanix.example.com" -RunOnce
```

### Why This Design?

- **Flexibility**: Run without any config files for quick tests
- **Convenience**: Use JSON for repeated runs with same settings
- **Security**: Sensitive data (passwords, tokens) always from command line only
- **Override Power**: Change one setting without editing JSON

---

## Configuration Options

### JSON Config File (`nutanix-config.json`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `NutanixHost` | string | (example.com) | Nutanix Prism Element IP or hostname |
| `NutanixUser` | string | admin | Nutanix admin username |
| `LEApplianceUrl` | string | (example.com) | Login Enterprise appliance URL |
| `LEApiVersion` | string | v8-preview | Login Enterprise API version |
| `EnvironmentIds.percent` | string | (see setup) | LE environment UUID for percent metrics |
| `EnvironmentIds.iops` | string | (see setup) | LE environment UUID for IOPS metrics |
| `EnvironmentIds.ms` | string | (see setup) | LE environment UUID for latency metrics |
| `EnvironmentIds.kBps` | string | (see setup) | LE environment UUID for bandwidth metrics |
| `PollingIntervalSec` | int | 30 | Seconds between each poll |
| `MaxRetries` | int | 3 | Max retry attempts on upload failure |
| `SkipTimeSync` | bool | false | Skip server time synchronization |

### Command Line Parameters (Override JSON)

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-NutanixPassword` | **YES** | Nutanix admin password (never stored) |
| `-LEApiToken` | **YES** | Login Enterprise API token (never stored) |
| `-ConfigFile` | No | Path to JSON config file |
| `-NutanixHost` | No | Override Nutanix host |
| `-LEApplianceUrl` | No | Override LE appliance URL |
| `-LEApiVersion` | No | LE API version (default: v8-preview) |
| `-EnvironmentIdPercent` | No | Override environment ID for percent metrics |
| `-EnvironmentIdIops` | No | Override environment ID for IOPS metrics |
| `-EnvironmentIdMs` | No | Override environment ID for latency metrics |
| `-EnvironmentIdKBps` | No | Override environment ID for bandwidth metrics |
| `-PollingIntervalSec` | No | Override polling interval |
| `-RunOnce` | No | Run once and exit |
| `-Iterations` | No | Run N times and exit |
| `-DryRun` | No | Fetch but don't upload |
| `-SkipTimeSync` | No | Skip time synchronization |
| `-SaveRawResponse` | No | Save Nutanix API response to JSON |
| `-Verbose` | No | Enable detailed logging for debugging |

## Files

| File | Description |
|------|-------------|
| `Nutanix-LE-PlatformMetrics.ps1` | Main collector script |
| `Get-LEPlatformMetrics.ps1` | Metrics retrieval/export script |
| `nutanix-config.json` | Configuration file (non-sensitive settings) |
| `README.md` | This file |

## Security Notes

- **Passwords and API tokens are NEVER stored in config files or scripts**
- Sensitive credentials must be passed via command line parameters
- Collector script uses API token authentication (no certificate handling needed)
- Retrieval script handles self-signed certificates automatically
- No admin privileges required

## Logs

Each run creates:
- `Nutanix-LE-Metrics_YYYYMMDD_HHMMSS.log` - Structured log file
- `Nutanix-LE-Metrics_YYYYMMDD_HHMMSS_transcript.log` - Full PowerShell transcript

## Troubleshooting

### Debugging with Verbose Mode

For detailed diagnostic information, use the `-Verbose` flag:

```powershell
.\Nutanix-LE-PlatformMetrics.ps1 -NutanixPassword "pass" -LEApiToken "token" -Verbose -RunOnce
```

This shows:
- URL validation results
- API request/response timing
- Detailed upload progress
- Configuration validation steps

### Common Issues

### 500 Internal Server Error
- The environment ID may be invalid or broken
- Try creating a new environment in Login Enterprise

### Connection refused to Nutanix
- Verify Nutanix host is reachable on port 9440
- Check VPN connectivity if required

### No data in Platform Metrics UI
- Ensure the feature flag is enabled
- Verify the environment is linked to a continuous test
- Check that the test is in the correct time range

## Version History

- **1.4.0** - Enhanced error handling, verbose mode, rate limit detection, graceful Ctrl+C, exit codes
- **1.3.0** - Required command line params for sensitive data, config file support
- **1.2.0** - Multi-environment support, time sync, retry logic
- **1.0.0** - Initial release

## License

MIT License

Copyright (c) 2026 Login VSI

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Disclaimer

This is a community-supported prototype integration. Use at your own risk. 

For Login Enterprise product support, contact: support@loginvsi.com

## Contributing

Contributions welcome! Please submit issues and pull requests to the GitHub repository.
