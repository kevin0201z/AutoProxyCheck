$proxy = "192.168.1.100"
$port = 8080

# 相对路径：脚本所在目录
$base = $PSScriptRoot
$stopFile = Join-Path $base "stop_proxy_checker.flag"

while ($true) {

    # 检查是否收到停止信号
    if (Test-Path $stopFile) {
        Remove-Item $stopFile -Force
        break
    }

    $ok = (Test-NetConnection -ComputerName $proxy -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded

    if (-not $ok) {
        Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" ProxyEnable 0
    }

    Start-Sleep -Seconds 10
}