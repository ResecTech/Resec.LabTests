' This script can change the Windows XP Theme by Drag and Drop and with the DOS Command Line (START "" /WAIT "Windows XP Theme Changer.vbs" "Folder\File.theme").

Dim Act :Set Act = CreateObject("Wscript.Shell")
Dim Shl :Set Shl = CreateObject("Shell.Application")

   If Wscript.Arguments.Count = 0 Then
    msgbox vbtab & "Error No Drag And Drop" & vbCrLf & _
    "Please Drag And Drop A Theme File On This Script" ,4128,"Error No Drag Drop"
   Else
   Dim Obj
    For Each Obj In WScript.Arguments
     If Right(InStr(LCase(Obj),Lcase(".Theme")),6) Then 
     ApplyTheme()
     End If 
    Next 
   End If
  
   Function ApplyTheme()
    Shl.ControlPanelItem cstr("desk.cpl desk,@Themes /Action:OpenTheme /file:" & """" + Obj + """")
    While Act.AppActivate ("Display Properties") = False
     Wscript.Sleep 1000
    Wend
    While Act.AppActivate ("Display Properties") = TRUE
     Act.AppActivate "Display Properties"
     Wscript.Sleep 200
     Act.sendkeys "{ENTER}"
    Wend
   End Function

WScript.Quit
