Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
scriptPath = scriptDir & "\AudioSwitch.ps1"

If WScript.Arguments.Named.Exists("selftest") Then
    exitCode = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptPath & """ -SelfTest", 0, True)
    WScript.Quit exitCode
Else
    extraArgs = ""
    If WScript.Arguments.Named.Exists("minimized") Then extraArgs = " -Minimized"
    shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptPath & """" & extraArgs, 0, False
End If
