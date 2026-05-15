Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 相对路径：脚本所在目录
$base = $PSScriptRoot
$stopFile = Join-Path $base "stop_proxy_checker.flag"

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true

$greenIcon = [System.Drawing.SystemIcons]::Information
$redIcon = [System.Drawing.SystemIcons]::Error

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$exitItem = $menu.Items.Add("退出")

$exitItem.Add_Click({
    # 发送停止信号
    New-Item -Path $stopFile -ItemType File -Force | Out-Null

    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu

function Update-Icon {
    $enabled = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings").ProxyEnable

    if ($enabled -eq 1) {
        $notifyIcon.Icon = $greenIcon
        $notifyIcon.Text = "代理启用"
    } else {
        $notifyIcon.Icon = $redIcon
        $notifyIcon.Text = "直连模式"
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 10000
$timer.Add_Tick({ Update-Icon })
$timer.Start()

Update-Icon
[System.Windows.Forms.Application]::Run()