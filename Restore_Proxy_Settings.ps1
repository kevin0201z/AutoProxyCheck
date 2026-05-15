$policyPath = "HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings"
$machineInternetSettingsPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

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

if (-not (Test-Path -LiteralPath $policyPath)) {
    New-Item -Path $policyPath -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $machineInternetSettingsPath)) {
    New-Item -Path $machineInternetSettingsPath -Force | Out-Null
}

Set-ItemProperty -Path $machineInternetSettingsPath -Name ProxyEnable -Value 0
Set-ItemProperty -Path $policyPath -Name ProxySettingsPerUser -Type DWord -Value 1
[void](Invoke-Netsh -Arguments @("winhttp", "reset", "proxy"))

Write-Host "Proxy settings restored. Machine proxy disabled, per-user proxy settings enabled, WinHTTP proxy reset."
