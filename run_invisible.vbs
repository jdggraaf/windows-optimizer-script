' Starts the DebloatKit GUI without a console window.
' No elevation here: the GUI is a front end and asks for administrator rights (UAC) only
' when you apply or undo something. /check = print the command, start nothing (used by the tests).

Dim fso, scriptDir, gui, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
gui = scriptDir & "\DebloatKit\DebloatKit-GUI.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & gui & Chr(34)

If WScript.Arguments.Named.Exists("check") Then
    WScript.Echo "would run: " & cmd
    WScript.Quit 0
End If

If Not fso.FileExists(gui) Then
    MsgBox "DebloatKit\DebloatKit-GUI.ps1 was not found next to this file.", 16, "DebloatKit"
    WScript.Quit 1
End If

CreateObject("WScript.Shell").Run cmd, 0, False
