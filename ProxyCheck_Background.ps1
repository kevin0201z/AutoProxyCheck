$proxyHost = "192.168.1.100"
$proxyPort = 8080
$checkIntervalSeconds = 10
$proxyBypass = "<local>;localhost;127.0.0.1;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*"

$sharedRoot = Join-Path $env:ProgramData "AutoProxyCheck"
$stopFile = Join-Path $sharedRoot "stop_proxy_checker.flag"
$statusFile = Join-Path $sharedRoot "proxy_status.json"
$logFile = Join-Path $sharedRoot "AutoProxyCheck.log"
$maxLogBytes = 1048576
$policyPath = "HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings"
$machineInternetSettingsPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$winHttpProxy = "$proxyHost`:$proxyPort"
$mutexName = "Global\AutoProxyCheck.Background"
$script:mutexAcquired = $false
$script:instanceMutex = $null

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WinInetProxyRefresh {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@

function Get-ProxyEnabled {
    try {
        return [int](Get-ItemProperty -Path $machineInternetSettingsPath -Name ProxyEnable -ErrorAction Stop).ProxyEnable
    } catch {
        return 0
    }
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
        Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "$timestamp [$Level] [Background] $Message"
    } catch {
    }
}

function Test-Configuration {
    if ([string]::IsNullOrWhiteSpace($proxyHost)) {
        throw "proxyHost must not be empty."
    }

    if (($proxyPort -lt 1) -or ($proxyPort -gt 65535)) {
        throw "proxyPort must be between 1 and 65535."
    }

    if ($checkIntervalSeconds -lt 1) {
        throw "checkIntervalSeconds must be at least 1 second."
    }
}

function Enter-SingleInstanceLock {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, $mutexName)

    try {
        $script:mutexAcquired = $script:instanceMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $script:mutexAcquired = $true
    }

    if (-not $script:mutexAcquired) {
        Write-Log -Level "WARN" -Message "Another background instance is already running; exiting."
        throw "Another background instance is already running."
    }
}

function Exit-SingleInstanceLock {
    if ($null -ne $script:instanceMutex) {
        try {
            if ($script:mutexAcquired) {
                $script:instanceMutex.ReleaseMutex()
            }
        } catch {
        } finally {
            $script:instanceMutex.Dispose()
            $script:instanceMutex = $null
            $script:mutexAcquired = $false
        }
    }
}

function Set-SharedRootAcl {
    $acl = Get-Acl -Path $sharedRoot
    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $accessRules = @(
        @{
            Identity = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
            Rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        },
        @{
            Identity = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            Rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        },
        @{
            Identity = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")
            Rights = [System.Security.AccessControl.FileSystemRights]::Modify
        }
    )

    foreach ($entry in $accessRules) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $entry.Identity,
            $entry.Rights,
            $inheritanceFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.SetAccessRule($rule)
    }

    Set-Acl -Path $sharedRoot -AclObject $acl
}

function Clear-StaleStopSignal {
    if (Test-Path -LiteralPath $stopFile) {
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction Stop
        Write-Log -Message "Stale stop signal cleared during startup."
    }
}

function Initialize-Environment {
    if (-not (Test-Path -LiteralPath $sharedRoot)) {
        New-Item -Path $sharedRoot -ItemType Directory -Force | Out-Null
    }

    Set-SharedRootAcl
    Clear-StaleStopSignal

    if (-not (Test-Path -LiteralPath $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $machineInternetSettingsPath)) {
        New-Item -Path $machineInternetSettingsPath -Force | Out-Null
    }

    # Make proxy settings machine-wide so they apply before interactive logon.
    Set-ItemProperty -Path $policyPath -Name ProxySettingsPerUser -Type DWord -Value 0
    Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyServer -Value $winHttpProxy
    Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyOverride -Value $proxyBypass
    Write-Log -Message "Environment initialized. Proxy=$winHttpProxy"
}

function Invoke-ProxyRefresh {
    [void][WinInetProxyRefresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][WinInetProxyRefresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Set-ProxyEnabled {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1)]
        [int]$Enabled
    )

    try {
        Write-Log -Message "Setting proxy enabled state to $Enabled."
        Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyEnable -Value $Enabled
        Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyServer -Value $winHttpProxy
        Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyOverride -Value $proxyBypass
        Set-ItemProperty -Path $machineInternetSettingsPath -Name MigrateProxy -Value 1 -ErrorAction SilentlyContinue
        Sync-WinHttpProxy -Enabled $Enabled
        Invoke-ProxyRefresh
        Assert-ProxyState -Enabled $Enabled
        Write-Log -Message "Proxy enabled state verified as $Enabled."
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to set proxy enabled state to $Enabled. $($_.Exception.Message)"
        if ($Enabled -eq 1) {
            try {
                Set-ProxyDirect
            } catch {
            }
        }

        throw
    }
}

function Set-ProxyDirect {
    Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyEnable -Value 0
    Sync-WinHttpProxy -Enabled 0
    Invoke-ProxyRefresh
    Write-Log -Message "Proxy rolled back to direct mode."
}

function Restore-PerUserProxySettings {
    Set-ItemProperty -Path $policyPath -Name ProxySettingsPerUser -Type DWord -Value 1
    Invoke-ProxyRefresh
    Write-Log -Message "Per-user proxy settings restored."
}

function Invoke-Netsh {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [bool]$AllowNonZeroExit = $false
    )

    $output = & netsh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $combinedOutput = ($output | Out-String).Trim()

    if (($exitCode -ne 0) -and (-not $AllowNonZeroExit)) {
        throw "netsh failed with exit code $exitCode. Output: $combinedOutput"
    }

    return $combinedOutput
}

function Sync-WinHttpProxy {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1)]
        [int]$Enabled
    )

    if ($Enabled -eq 1) {
        $settings = '{"Proxy":"' + $winHttpProxy + '","ProxyBypass":"' + $proxyBypass + '","AutoconfigUrl":"","AutoDetect":false}'
        [void](Invoke-Netsh -Arguments @("winhttp", "set", "advproxy", "setting-scope=machine", "settings=$settings") -AllowNonZeroExit $true)
    } else {
        $settings = '{"Proxy":"","ProxyBypass":"","AutoconfigUrl":"","AutoDetect":false}'
        [void](Invoke-Netsh -Arguments @("winhttp", "set", "advproxy", "setting-scope=machine", "settings=$settings") -AllowNonZeroExit $true)
    }
}

function Assert-ProxyState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1)]
        [int]$Enabled
    )

    $actualProxyEnabled = Get-ProxyEnabled
    if ($actualProxyEnabled -ne $Enabled) {
        throw "ProxyEnable verification failed. Expected $Enabled but found $actualProxyEnabled."
    }

    $currentSettings = Get-ItemProperty -Path $machineInternetSettingsPath -ErrorAction Stop

    if ($Enabled -eq 1) {
        if ($currentSettings.ProxyServer -ne $winHttpProxy) {
            throw "ProxyServer verification failed. Expected '$winHttpProxy' but found '$($currentSettings.ProxyServer)'."
        }

        if ($currentSettings.ProxyOverride -ne $proxyBypass) {
            throw "ProxyOverride verification failed. Expected '$proxyBypass' but found '$($currentSettings.ProxyOverride)'."
        }

        $winHttpOutput = Invoke-Netsh -Arguments @("winhttp", "show", "advproxy")
        if (($winHttpOutput -notmatch [regex]::Escape($winHttpProxy)) -or ($winHttpOutput -notmatch [regex]::Escape($proxyBypass))) {
            throw "WinHTTP verification failed for enabled state. Output: $winHttpOutput"
        }
    } else {
        $winHttpOutput = Invoke-Netsh -Arguments @("winhttp", "show", "advproxy")
        if ($winHttpOutput -match '"ProxyIsEnabled"\s*:\s*true') {
            throw "WinHTTP verification failed for disabled state. Output: $winHttpOutput"
        }
    }
}

function Test-ProxyReachable {
    try {
        return (Test-NetConnection -ComputerName $proxyHost -Port $proxyPort -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop)
    } catch {
        return $false
    }
}

function Write-StatusFile {
    param(
        [bool]$ProxyReachable,
        [int]$ProxyEnabled,
        [bool]$BackgroundRunning,
        [string]$Message
    )

    $status = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        backgroundRunning = $BackgroundRunning
        proxyEnabled = ($ProxyEnabled -eq 1)
        proxyReachable = $ProxyReachable
        message = $Message
        proxyHost = $proxyHost
        proxyPort = $proxyPort
        proxyBypass = $proxyBypass
        checkIntervalSeconds = $checkIntervalSeconds
        sharedRoot = $sharedRoot
        mode = "machine-wide"
    }

    $status | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
    Write-Log -Message $Message
}

try {
    Test-Configuration
    Enter-SingleInstanceLock
    Initialize-Environment
    Write-Log -Message "Background started."
    Write-StatusFile -ProxyReachable $false -ProxyEnabled (Get-ProxyEnabled) -BackgroundRunning $true -Message "Background started (machine-wide proxy mode)"

    while ($true) {
        if (Test-Path -LiteralPath $stopFile) {
            Write-Log -Message "Stop signal detected."
            Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
            Set-ProxyEnabled -Enabled 0
            Restore-PerUserProxySettings
            $currentProxyEnabled = 0
            Write-StatusFile -ProxyReachable $false -ProxyEnabled $currentProxyEnabled -BackgroundRunning $false -Message "Background stopped, proxy disabled, per-user proxy settings restored"
            break
        }

        $currentProxyEnabled = Get-ProxyEnabled
        $proxyReachable = Test-ProxyReachable
        $message = "No state change"

        if (($currentProxyEnabled -eq 1) -and (-not $proxyReachable)) {
            Set-ProxyEnabled -Enabled 0
            $currentProxyEnabled = 0
            $message = "Proxy unreachable, switched to direct connection"
        } elseif (($currentProxyEnabled -eq 0) -and $proxyReachable) {
            Set-ProxyEnabled -Enabled 1
            $currentProxyEnabled = 1
            $message = "Proxy reachable again, proxy re-enabled"
        } elseif ($proxyReachable) {
            $message = "Proxy reachable"
        } else {
            $message = "Proxy unreachable, staying direct"
        }

        Write-StatusFile -ProxyReachable $proxyReachable -ProxyEnabled $currentProxyEnabled -BackgroundRunning $true -Message $message
        Start-Sleep -Seconds $checkIntervalSeconds
    }
} catch {
    Write-Log -Level "ERROR" -Message ("Background error: " + $_.Exception.Message)
    if (Test-Path -LiteralPath $sharedRoot) {
        try {
            Write-StatusFile -ProxyReachable $false -ProxyEnabled (Get-ProxyEnabled) -BackgroundRunning $false -Message ("Error: " + $_.Exception.Message)
        } catch {
        }
    }
    throw
} finally {
    Exit-SingleInstanceLock
}
