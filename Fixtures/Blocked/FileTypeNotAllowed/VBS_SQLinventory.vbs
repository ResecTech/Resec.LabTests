strComputer = "."
Set objWMIService = GetObject("winmgmts:\\" & strComputer)
Set colComputer = objWMIService.ExecQuery _
    ("Select * from Win32_ComputerSystem")
For Each objComputer in colComputer
'    Wscript.Echo "ComputerName: " & objComputer.Name
    ComputerName = objComputer.Name
'    Wscript.Echo "Manufacturer: " & objComputer.Manufacturer
    Manufacturer = objComputer.Manufacturer
'    Wscript.Echo "Model: " & objComputer.Model
    Model = objComputer.Model
Next

Set colBIOS = objWMIService.ExecQuery _
    ("Select * from Win32_BIOS")
For Each objBIOS in colBIOS
'    Wscript.Echo "SerialNumber: " & objBIOS.SerialNumber
    SerialNumber = objBIOS.SerialNumber
Next

Set objNetworkAdapters = objWMIService.ExecQuery("select * from Win32_NetworkAdapterConfiguration where IPEnabled = 1")
For Each objAdapter In objNetworkAdapters
   'wscript.echo objAdapter.MacAddress 
    If Not IsNull(objAdapter.IPAddress) Then 
        For i=LBound(objAdapter.IPAddress) to UBound(objAdapter.IPAddress)
            'WScript.Echo objAdapter.IPAddress(i)
	    LocalIPaddr = objAdapter.IPAddress(i)
	    'wscript.echo "IP:" & LocalIPaddr & vbcrlf
        Next
    End If
   'wscript.echo objAdapter.Caption
Next

wscript.echo "Insert into tblInventory(ComputerName,IPaddress,IsActive,Make,Model,Serial) Values ('" & _
	ComputerName & "','" & LocalIPaddr & "',0,'" & Manufacturer & "','" & Model & "','" & SerialNumber & "')" & vbcrlf

'get the filesystemobject
Dim oFSO
Set oFSO = CreateObject("Scripting.FileSystemObject")
'open an output file
Dim oOutput
Set oOutput = oFSO.CreateTextFile("InsertSQL.txt")
oOutput.Write "Insert into tblInventory(ComputerName,IPaddress,IsActive,Make,Model,Serial) Values ('" & _
	ComputerName & "','" & LocalIPaddr & "',0,'" & Manufacturer & "','" & Model & "','" & SerialNumber & "')" & vbcrlf
oOutput.close

wscript.echo "Written to file InsertSQL.txt"

