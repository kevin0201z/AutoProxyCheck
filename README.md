# 自动代理守护部署说明

## 1. 文件说明

正式运行文件位于项目根目录：

- `ProxyCheck_Background.ps1`：后台检测与自动切换脚本
- `ProxyTray_UI.ps1`：托盘脚本
- `Start_ProxyTray_Hidden.vbs`：隐藏启动托盘脚本的计划任务入口
- `Restore_Proxy_Settings.ps1`：异常情况下手动恢复系统代理设置的脚本

## 2. 部署前准备

1. 先在 Windows 系统中手动配置好代理服务器地址和端口。
2. 根据实际环境修改 `ProxyCheck_Background.ps1` 中的以下配置：
   - `$proxyHost`
   - `$proxyPort`
   - `$proxyBypass`
   - `$checkIntervalSeconds`
3. 使用管理员权限创建计划任务。

默认 `$proxyBypass` 已排除以下目标：

- `<local>`
- `localhost`
- `127.0.0.1`
- `10.x.x.x`
- `172.16.x.x` 到 `172.31.x.x`
- `192.168.x.x`

如果你的内网还包含其他固定域名或地址规则，可以继续在该变量中追加。

## 3. 共享文件目录

共享文件固定放在：

- `C:\ProgramData\AutoProxyCheck\stop_proxy_checker.flag`
- `C:\ProgramData\AutoProxyCheck\proxy_status.json`

后台脚本首次启动时会自动创建该目录。  
后台脚本会自动为该目录设置共享访问权限，使 `SYSTEM`、管理员和普通登录用户都能完成状态读写与停止信号写入。

本工具按单用户电脑场景设计：当前登录用户被视为可信用户。共享目录允许普通用户写入停止信号，因此不适合直接部署到多用户共用、需要隔离普通用户权限的机器上。

## 4. 计划任务方案

### 4.1 后台任务

- 任务名称建议：`AutoProxyCheck_Background`
- 触发器：系统启动时
- 运行账户：`SYSTEM`
- 运行方式：不要求用户登录
- 建议勾选“使用最高权限运行”

该任务负责：

- 启用机器级代理策略 `ProxySettingsPerUser=0`
- 写入机器级 WinINet 代理设置
- 同步机器级 WinHTTP 代理设置
- 对代理写入结果执行回读校验
- 在代理不可达时切到直连
- 保证后台仅运行一个实例

动作示例：

```text
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\实际部署目录\ProxyCheck_Background.ps1"
```

### 4.2 托盘任务

- 任务名称建议：`AutoProxyCheck_Tray`
- 触发器：用户登录时
- 运行账户：当前登录用户
- 建议勾选“仅当用户登录时运行”

该任务只负责托盘显示和退出联动，不负责写系统级代理。
托盘脚本带有单实例锁；如果已有托盘实例在运行，新的托盘进程会直接退出，不会重复生成托盘图标。

当用户通过托盘退出时，后台脚本会在收到停止信号后自动关闭机器级代理，恢复用户级代理设置，再结束后台检测。

动作示例：

```text
wscript.exe "C:\实际部署目录\Start_ProxyTray_Hidden.vbs"
```

建议通过 `Start_ProxyTray_Hidden.vbs` 启动托盘，避免计划任务启动后残留 PowerShell 终端窗口。托盘进程依赖启动它的 PowerShell 进程运行，如果手动关闭该终端窗口，托盘也会随之退出。

## 5. 重要说明

1. 后台脚本运行后会把代理切换为机器级设置，对整台机器生效。
2. 后台脚本会写 `HKLM` 和 WinHTTP，因此必须以管理员权限或 `SYSTEM` 运行。
3. 后台脚本带有单实例锁；如果已有实例在运行，新的后台进程会直接退出。
4. 托盘脚本带有单实例锁；如果已有实例在运行，新的托盘进程会直接退出。
5. 计划任务中的 `-File` 路径不会自动跟随脚本移动。
6. 如果脚本目录发生变更，必须同步更新计划任务中的实际路径。
7. 若浏览器或应用仅使用用户私有代理设置而不遵循机器级代理策略，则其表现可能与系统级状态不同；本方案默认依赖 Windows 机器级代理策略。
8. 代理绕过规则依赖 Windows 代理匹配机制，不同应用对 IP 通配符的遵循程度可能略有差异。
9. 本方案默认用于单用户可信环境；多用户环境需要重新收紧 `C:\ProgramData\AutoProxyCheck` 的 ACL 和停止信号机制。

## 6. 验证建议

部署完成后建议按以下顺序验证：

1. 手动以管理员权限运行后台脚本，确认会生成或更新 `C:\ProgramData\AutoProxyCheck\proxy_status.json`。
2. 用 `netsh winhttp show advproxy` 确认 WinHTTP 代理会随状态变化。
3. 在代理可达和不可达两种场景下观察机器级代理是否会自动切换。
4. 登录系统后确认托盘是否出现，并且图标状态正确。
5. 点击托盘退出，确认后台会先关闭机器级代理、恢复用户级代理设置，再在一个轮询周期内退出。

## 7. 手动测试脚本

### 7.1 手动运行后台脚本

使用“以管理员身份运行”的 PowerShell，进入项目目录：

```powershell
cd "C:\Users\ABC\Documents\Apps\Git\AutoProxyCheck"
```

执行后台脚本：

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\ProxyCheck_Background.ps1"
```

后台脚本启动后会持续运行，并按轮询周期执行代理检测和切换。

### 7.2 查看后台状态

在另一个 PowerShell 窗口中查看状态文件：

```powershell
Get-Content "C:\ProgramData\AutoProxyCheck\proxy_status.json"
```

查看 WinHTTP 当前代理：

```powershell
netsh winhttp show advproxy
```

### 7.3 手动运行托盘脚本

使用当前登录用户的普通 PowerShell 窗口，进入项目目录后执行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\ProxyTray_UI.ps1"
```

托盘启动后应显示当前机器级代理状态和最近一次检测结果。

### 7.4 停止后台脚本

可以通过以下两种方式停止后台脚本：

1. 在托盘图标的右键菜单中点击“退出”。
2. 手动创建停止信号文件：

```powershell
New-Item -Path "C:\ProgramData\AutoProxyCheck\stop_proxy_checker.flag" -ItemType File -Force
```

后台脚本会在下一轮检测时读取到停止信号并退出。  
在退出前，后台脚本会自动关闭机器级代理、恢复用户级代理设置，并切换到直连。

### 7.5 手动恢复直连

如果后台脚本异常退出后机器级代理仍处于开启状态，且 Windows 系统设置中无法关闭代理，可以使用管理员权限 PowerShell 执行恢复脚本：

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Restore_Proxy_Settings.ps1"
```
