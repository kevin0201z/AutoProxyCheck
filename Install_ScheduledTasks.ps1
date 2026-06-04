[CmdletBinding()]
param(
    [switch]$NoStart,

    [string]$TrayUser
)

$ErrorActionPreference = "Stop"

$backgroundTaskName = "AutoProxyCheck_Background"
$trayTaskName = "AutoProxyCheck_Tray"
$taskPath = "\AutoProxyCheck\"
$scriptRoot = $PSScriptRoot
$backgroundScript = Join-Path $scriptRoot "ProxyCheck_Background.ps1"
$trayLauncher = Join-Path $scriptRoot "Start_ProxyTray_Hidden.vbs"
$sharedRoot = Join-Path $env:ProgramData "AutoProxyCheck"
$logFile = Join-Path $sharedRoot "AutoProxyCheck.log"
$script:EffectiveTrayUser = $TrayUser

function Write-InstallLog {
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

        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "$timestamp [$Level] [Install] $Message"
    } catch {
    }
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    if ([string]::IsNullOrWhiteSpace($TrayUser)) {
        $TrayUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$PSCommandPath`"",
        "-TrayUser",
        "`"$TrayUser`""
    )

    if ($NoStart) {
        $arguments += "-NoStart"
    }

    Write-Host "Requesting administrator permission..."
    Write-InstallLog -Message "Requesting administrator permission for tray user '$TrayUser'."
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Assert-RequiredFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Register-BackgroundTask {
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$backgroundScript`"" `
        -WorkingDirectory $scriptRoot

    $triggers = @(
        New-ScheduledTaskTrigger -AtStartup
        New-ScheduledTaskTrigger -AtLogOn
    )
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    $task = New-ScheduledTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskPath $taskPath -TaskName $backgroundTaskName -InputObject $task -Force | Out-Null
}

function Register-TrayTask {
    $action = New-ScheduledTaskAction `
        -Execute "wscript.exe" `
        -Argument "`"$trayLauncher`"" `
        -WorkingDirectory $scriptRoot

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $script:EffectiveTrayUser
    $principal = New-ScheduledTaskPrincipal -UserId $script:EffectiveTrayUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskPath $taskPath -TaskName $trayTaskName -InputObject $task -Force | Out-Null
}

function Remove-LegacyRootTasks {
    foreach ($taskName in @($backgroundTaskName, $trayTaskName)) {
        $legacyTask = Get-ScheduledTask -TaskPath "\" -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $legacyTask) {
            Unregister-ScheduledTask -TaskPath "\" -TaskName $taskName -Confirm:$false
            Write-Host "Removed legacy root task: $taskName"
        }
    }
}

function Start-InstalledTasks {
    Start-ScheduledTask -TaskPath $taskPath -TaskName $backgroundTaskName
    Start-ScheduledTask -TaskPath $taskPath -TaskName $trayTaskName
}

function Assert-InstalledTasks {
    foreach ($taskName in @($backgroundTaskName, $trayTaskName)) {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
        Write-InstallLog -Message "Verified scheduled task '$($task.TaskPath)$($task.TaskName)' with state '$($task.State)'."
    }
}

try {
    Write-InstallLog -Message "Install script started from '$scriptRoot'."

    if (-not (Test-IsAdministrator)) {
        Restart-AsAdministrator
    }

    if ([string]::IsNullOrWhiteSpace($TrayUser)) {
        $script:EffectiveTrayUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    } else {
        $script:EffectiveTrayUser = $TrayUser
    }

    Assert-RequiredFile -Path $backgroundScript
    Assert-RequiredFile -Path $trayLauncher

    Write-Host "Installing scheduled tasks from: $scriptRoot"
    Write-InstallLog -Message "Installing scheduled tasks from '$scriptRoot' for tray user '$script:EffectiveTrayUser'."
    Remove-LegacyRootTasks
    Register-BackgroundTask
    Register-TrayTask
    Assert-InstalledTasks
    Write-Host "Scheduled tasks registered or updated."
    Write-InstallLog -Message "Scheduled tasks registered or updated."

    if (-not $NoStart) {
        Start-InstalledTasks
        Write-Host "Scheduled tasks started."
        Write-InstallLog -Message "Scheduled tasks started."
    } else {
        Write-Host "Scheduled tasks were not started because -NoStart was specified."
        Write-InstallLog -Message "Scheduled tasks were not started because -NoStart was specified."
    }

    Write-Host "Done."
    Write-InstallLog -Message "Install script completed."
} catch {
    Write-InstallLog -Level "ERROR" -Message ("Install script failed. " + $_.Exception.Message)
    throw
}
