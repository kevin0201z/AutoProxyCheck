Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$sharedRoot = Join-Path $env:ProgramData "AutoProxyCheck"
$stopFile = Join-Path $sharedRoot "stop_proxy_checker.flag"
$statusFile = Join-Path $sharedRoot "proxy_status.json"
$internetSettingsPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true

$enabledIcon = [System.Drawing.SystemIcons]::Information
$disabledIcon = [System.Drawing.SystemIcons]::Error

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add("Loading status...")
$statusItem.Enabled = $false
[void]$menu.Items.Add("-")
$exitItem = $menu.Items.Add("Exit")

function Get-ProxyEnabled {
    try {
        return [int](Get-ItemProperty -Path $internetSettingsPath -Name ProxyEnable -ErrorAction Stop).ProxyEnable
    } catch {
        return 0
    }
}

function Get-StatusData {
    if (Test-Path -LiteralPath $statusFile) {
        try {
            return Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
        }
    }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        backgroundRunning = $null
        proxyEnabled = (Get-ProxyEnabled -eq 1)
        proxyReachable = $null
        message = "Status file unavailable"
        mode = "machine-wide"
    }
}

function Update-Icon {
    $status = Get-StatusData
    $proxyEnabled = [bool]$status.proxyEnabled

    if ($proxyEnabled) {
        $notifyIcon.Icon = $enabledIcon
        $modeText = "Proxy enabled"
    } else {
        $notifyIcon.Icon = $disabledIcon
        $modeText = "Direct mode"
    }

    if ($null -eq $status.proxyReachable) {
        $reachabilityText = "Last check unknown"
    } elseif ([bool]$status.proxyReachable) {
        $reachabilityText = "Last check succeeded"
    } else {
        $reachabilityText = "Last check failed"
    }

    $tooltip = "$modeText / $reachabilityText"
    if ($tooltip.Length -gt 63) {
        $tooltip = $tooltip.Substring(0, 63)
    }

    $notifyIcon.Text = $tooltip
    $statusItem.Text = "$tooltip / machine-wide"
}

$exitItem.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $sharedRoot)) {
            New-Item -Path $sharedRoot -ItemType Directory -Force | Out-Null
        }
        New-Item -Path $stopFile -ItemType File -Force | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to write the stop signal. " + $_.Exception.Message,
            "AutoProxyCheck",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Icon })
$timer.Start()

Update-Icon
[System.Windows.Forms.Application]::Run()
