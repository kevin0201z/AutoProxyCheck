$sharedRoot = Join-Path $env:ProgramData "AutoProxyCheck"
$logFile = Join-Path $sharedRoot "AutoProxyCheck.log"
$maxLogBytes = 1048576
$policyPath = "HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings"
$machineInternetSettingsPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WinInetProxyRefresh {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@

function Invoke-Netsh {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & netsh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $combinedOutput = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        throw "netsh failed with exit code $exitCode. Output: $combinedOutput"
    }

    return $combinedOutput
}

function Invoke-ProxyRefresh {
    [void][WinInetProxyRefresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][WinInetProxyRefresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    try {
        if (-not (Test-Path -LiteralPath $sharedRoot)) {
            New-Item -Path $sharedRoot -ItemType Directory -Force | Out-Null
        }

        if ((Test-Path -LiteralPath $logFile) -and ((Get-Item -LiteralPath $logFile).Length -ge $maxLogBytes)) {
            Move-Item -LiteralPath $logFile -Destination "$logFile.old" -Force
        }

        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "$timestamp [$Level] [Restore] $Message"
    } catch {
    }
}

try {
    Write-Log -Message "Restore started."

    if (-not (Test-Path -LiteralPath $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $machineInternetSettingsPath)) {
        New-Item -Path $machineInternetSettingsPath -Force | Out-Null
    }

    Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyEnable -Value 0
    Set-ItemProperty -Path $policyPath -Name ProxySettingsPerUser -Type DWord -Value 1
    [void](Invoke-Netsh -Arguments @("winhttp", "reset", "proxy"))
    Invoke-ProxyRefresh
    Write-Log -Message "Restore completed. Machine proxy disabled, per-user proxy settings enabled, WinHTTP proxy reset."
} catch {
    Write-Log -Level "ERROR" -Message ("Restore failed. " + $_.Exception.Message)
    throw
}

Write-Host "Proxy settings restored. Machine proxy disabled, per-user proxy settings enabled, WinHTTP proxy reset."
