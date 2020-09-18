$Global:Connection = New-Object System.Data.SqlClient.SqlConnection
$Global:Datatable = New-Object System.Data.DataTable
$Global:SQLCommand = New-Object System.Data.SqlClient.SqlCommand

#[string]$Global:Server #Does not need to be Global
[string]$Global:SqlFileName
[string]$Global:FileExt
[string]$Global:filePathErr = "There was either no value entered for the directory path or the path is invalid"
[string]$Global:DBInputText = "Please enter the name of the database(s) you wish to move seperated by commas"
Function Main {
    #[int32]$SqlFileType
    $DataTypeChoice = @(
        'Move SQL Data Files',
        'Move SQL Log Files',
        'Exit'
    )
    $ValideChoices = 1..($DataTypeChoice.Count)
    #$i = 0
    Write-Host ("=========== Menu ===========") -foregroundcolor red
    Write-Host ("")
    While ([string]::IsNullOrEmpty($SqlFileType)) {
        Foreach ($ItemChoice in $DataTypeChoice) {
            $i++
            Write-Host ("$($i) - $($ItemChoice)")
        }   
        Write-Host ("")
        $SqlFileType = Read-Host -Prompt 'Enter Selection'
        If (!$SqlFileType) {
            $i = 0 
            Write-Host ("")
            Write-Host ("No selection was made. Please try again...")
        }
        ElseIf ($SqlFileType -in $ValideChoices) {
            Switch ($SqlFileType) {
                1 { 
                    $FileExt = 'mdf'
                    Get-SQLConnection ($SqlFileType)
                }
                2 { 
                    $FileExt = 'ldf'
                    Get-SQLConnection ($SqlFileType) 
                }
                3 { Exit }
            }
        }
    }
}
Function Move-SQLDataFiles {
    Write-Host ("")
    $DBInput = Read-Host -Prompt $DBInputText
    Write-Host ("")
    $SqlDatabase = @()
    If ($DBInput -ne 0) {
        ForEach ($Input in $DBInput.Split(",")) {           
            $SqlDatabase += $Input -replace " ", ""
        }     
        $newFilePath = Get-FileLocation

        While ($Connection.State -eq 'Open') {
            ForEach ($DB in $SqlDatabase) {
                Start-SQLCalls -newFilePath $newFilePath -DatabaseName $DB
            }
            $Connection.Close()
        }
    }
    Else { <# Error handling for if $DBInput is null or empty #> }  
}
Function Move-SQLLogFiles {
    Write-Host ("")
    $DBInput = Read-Host -Prompt $DBInputText
    Write-Host ("")
    $SqlDatabase = @()
    If ($DBInput -ne 0) {
        ForEach ($Input in $DBInput.Split(",")) {           
            $SqlDatabase += $Input -replace " ", ""
        }       
        $newFilePath = Get-FileLocation

        While ($Connection.State -eq 'Open') {
            ForEach ($DB in $SqlDatabase) {
                Start-SQLCalls -newFilePath $newFilePath -DatabaseName $DB
            }
            $Connection.Close()           
        }
    }
}
Function Get-SQLConnection {
    Param (
        [int32]$Selection
    )
    $Server = Read-Host -Prompt "Please enter the FQDN of the SQL Server Instance"
    $Connection.ConnectionString = "server = '$Server'; trusted_connection = true;"
    Try {
        $Connection.Open()
        If ($Connection.State -eq "Open") {
            Write-Host $("Connection to $Server was Successful")
        }
    }
    Catch [System.Data.SqlClient.SqlException] {
        Write-Error -Message 'Connection Unsuccessful. Please verify the correct Server/Instance name was provided.'
        Return (Get-SQLConnection)
    }
    Finally {
        Switch ($Selection) {
            1 { Move-SQLDataFiles }
            2 { Move-SQLLogFiles }
        }
    }
}
Function Get-FileLocation {
    [CmdletBinding()]
    Param (
        [ValidateScript( { Test-Path $_ })]
        [string]$newFilePath 
    )
    While ([string]::IsNullOrEmpty($newFilePath)) {
        $newFilePath = Read-Host -Prompt 'Enter the path of the new directory'
        If (!$newFilePath) { Write-Host $filePathErr }
    }
    Return ($newFilePath)
}
Function Start-SQLCalls {
    [CmdletBinding()]
    Param(
        $newFilePath,
        $DatabaseName
    )
    $TypeDesc
    If ($FileExt -eq 'mdf') {
        $TypeDesc = 'ROWS'
    }
    Else {
        $TypeDesc = 'LOG'
    }
    $SQLQueryFileInfo = $("SELECT DB_NAME(database_id) AS [DatabaseName], [name] AS [filename], [physical_name] FROM sys.master_files WHERE [type_desc] = '$TypeDesc' AND DB_NAME(database_id) = '$DatabaseName' GROUP BY [database_id], [name], [file_id],[physical_name] ORDER BY [file_id] ASC") 
    [string]$DBState = 'Offline'

    $SQLCommand.Connection = $Connection
    $SQLCommand.CommandText = $("SELECT COUNT([name]) AS [FileCnt] FROM sys.master_files WHERE [type_desc] = 'LOG' AND DB_NAME(database_id) = '$DatabaseName' GROUP BY [file_id] ORDER BY [file_id] ASC")
    $Rdr = $SQLCommand.ExecuteReader()
    $Datatable.Load($Rdr)

    If ($Datatable.Rows[0].FileCnt -eq 1) {
        $Datatable.Clear()
        $Counter = 4                  
        For ($i = 0; $i -lt $Counter; $i++) {
            $SQLQueryAlter1 = $("ALTER DATABASE $DatabaseName SET $DBState")
            Switch ($i) {
                0 { 
                    $SQLCommand.CommandText = $SQLQueryFileInfo 
                    $Rdr = $SQLCommand.ExecuteReader()
                    $Datatable.Load($Rdr)
                    $SqlFileName = $Datatable.Rows[0].Filename
                    $SQLQueryAlter2 = $("ALTER DATABASE $DatabaseName MODIFY FILE ( NAME = $SqlFileName, FILENAME = '$newFilePath\$SqlFileName.$FileExt')")
                    Set-Permissions -checkNewPath $newFilePath -checkOldPath $Datatable.Rows[0].physical_name
                }
                1 { 
                    $SQLCommand.CommandText = $SQLQueryAlter2
                    $SQLCommand.ExecuteNonQuery()
                }
                2 {
                    #Offline
                    $SQLCommand.CommandText = $("$SQLQueryAlter1 WITH ROLLBACK IMMEDIATE")
                    $SQLCommand.ExecuteNonQuery()
                    Copy-SQLFiles ($Datatable.Rows[0].Physical_name)
                    $DBState = 'Online'
                }
                3 { 
                    #Online
                    $SQLCommand.CommandText = $SQLQueryAlter1
                    $SQLCommand.ExecuteNonQuery()
                }
            }
        }
    }
    Else {}#Need conditions for multiple files
}
Function Set-Permissions {
    [CmdletBinding()]
    Param(
        [string]$checkNewPath,
        [string]$checkOldPath
    )
    Get-Acl -Path $checkOldPath | Set-Acl -Path $checkNewPath

    #Need error handling and checks in order to make sure that permissions were set properly.
    #There is also a need in the beginning of this function to check new file path for inheritance and if enabled then disable 
}
Function Copy-SQLFiles {
    Param (
        [ValidateScript( { Test-Path $_ })]
        [string]$oldFilePath  
    )
    If ($newFilePath -eq $oldFilePath) {
        Write-Error 'Error: Both file paths cannot be the same.' -Category InvalidData
        Write-Host 'Please Try Again...'
        $newFilePath = Get-FileLocation #Validate what happens after this
    }
    Else {
        Copy-Item $oldFilePath -Destination $newFilePath
        If (Test-Path $("$newFilePath\$SqlFileName.$FileExt")) {
            $newFilePath = $("$newFilePath\$SqlFileName.$FileExt")
            Set-Permissions -checkNewPath $newFilePath -checkOldPath $oldFilePath
            Write-Host ("File was copied over successfully")
        }
        Else {
            Write-Host $("There was an error copying over file $SqlFileName.$FileExt to new directory")
        }
    }
}
Main