Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
trayScript = fso.BuildPath(scriptDir, "ProxyTray_UI.ps1")
command = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & trayScript & Chr(34)

Sub WriteLaunchLog(message)
    On Error Resume Next
    programData = shell.ExpandEnvironmentStrings("%ProgramData%")
    logDir = fso.BuildPath(programData, "AutoProxyCheck")
    If Not fso.FolderExists(logDir) Then
        fso.CreateFolder(logDir)
    End If
    logFile = fso.BuildPath(logDir, "AutoProxyCheck.log")
    Set log = fso.OpenTextFile(logFile, 8, True)
    log.WriteLine Now & " [INFO] [TrayLauncher] " & message
    log.Close
End Sub

WriteLaunchLog "Launching tray script: " & trayScript
WriteLaunchLog "Command: " & command

shell.Run command, 0, False
