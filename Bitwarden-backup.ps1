#	Bitwarden-Attachment-Exporter
#	Marviins, edited by justincswong, edited by taffit

    # Initialization Step
    # Point $server to the correct URL, e. g.:
    #    Bitwarden (default) : https://bitwarden.com
    #    Bitwarden EU        : https://vault.bitwarden.eu
    #    Self-hosted instance: e. g. https://my_bitwarden.selfhosted.com
    $server              = "https://bitwarden.com"
    $username            = "username"         # keep the quotes, your username
    $organizationID      = "organizationid"   # If an organizationid is provided, the organization vault is backed up
                                              # Leave it as is or empty to backup your personal vault
    # We encrypt by default, everything else is insecure
    $sevenZip            = $true              # $true or $false, true = ZIP files into an encrypted ZIP-file using a password (NOT the master password)
    $sevenZipPath = "$env:ProgramFiles\7-Zip\7z.exe" # The command for, and eventually the whole path to, the 7zip-executable
    $deleteFilesAfterZIP = $true              # Should the files be deleted once zipped?
    $gpg                 = $false             # $true or $false, true = gpg encrypt     false = skip gpg encrypt
    $keyname             = "keyName"          # gpg recipient, only required if gpg encrypting
    $securedlt           = $false             # $true or $false, true = secure delete   false = skip secure delete

    $backup_date_format  = get-date -Format "yyyy-MM-dd_hhmmss"
    
    # Nothing to change below this line --------------------------------------------------------------------------------------------------
    $key                 = $null              # don't change this

    # We have to verify that we are on the correct server
    $currentServer = bw config server
    Write-Host "Currently configured server: $currentServer"
    if ($currentServer -ne $server) {
      bw config server $server | Out-Null
      Write-Host "Set server to: $server"
    }

    # Master Password Prompt
    $masterPass = Read-Host -assecurestring -join("Please enter your master password for user ``$username``", $(if ($organizationID.ToLower() -notmatch "organizationid" -And -Not ([string]::IsNullOrEmpty($organizationid))) {" (organization: $($organizationID))"}))
    $masterPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($masterPass))

    # Attempt Login
    while ($key -eq $null) {
        try {
            $key = bw login $username $masterPass --raw
            if ($key -eq $null) {
                throw "InvalidPasswordException"
            }
        }
        catch {
            $masterPass = Read-Host -assecurestring "`nPlease re-enter your master password"
            $masterPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($masterPass))
        }
    }

    Write-Host "Successfully logged in." -ForegroundColor Green
    $env:BW_SESSION="$key"

    # Encryption Password Prompt used for encrypting the export and 7zip-file
    $encPass = Read-Host -assecurestring "Please enter the encryption password used for encrypting the backup"
    $encPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($encPass))

    # Specify directory and filenames
    $backupFolder = ".\Backup"
    if (!(test-path -PathType container $backupFolder)) {
      New-Item -ItemType Directory -Path $backupFolder | Out-Null
    }
    $backupPath = (Convert-Path -LiteralPath $backupFolder)
    $backupFile = "$($backup_date_format)_Bitwarden_backup"
    if ($organizationID.ToLower() -notmatch "organizationid" -And -Not ([string]::IsNullOrEmpty($organizationid))) {
      $backupFile = $($backupFile + "-org")
    }
    $attachmentsPath = "$backupPath\$($backup_date_format)_Attachments"

    # Backup Vault
    Write-Host "`nExporting Bitwarden Vault"
    bw sync
    Write-Host "`n"
    if ($organizationID.ToLower() -notmatch "organizationid" -And -Not ([string]::IsNullOrEmpty($organizationid))) {
      bw export --output "$backupPath\$backupFile.enc.json" --format encrypted_json --organizationid $organizationID --password '$encPass'
    } else {
      bw export --output "$backupPath\$backupFile.enc.json" --format encrypted_json --password '$encPass'
    }
    Write-Host "`n"

    # Backup Attachments
    if ($organizationID.ToLower() -notmatch "organizationid" -And -Not ([string]::IsNullOrEmpty($organizationid))) {
      $vault = bw list items --organizationid $organizationID | ConvertFrom-Json
    } else {
      $vault = bw list items | ConvertFrom-Json
    }

    foreach ($item in $vault){
        if($item.PSobject.Properties.Name -contains "Attachments"){
           foreach ($attachment in $item.attachments){
            $exportName = '[' + $item.name + ']-' + $attachment.fileName
            bw get attachment $attachment.id --itemid $item.id --output "$attachmentsPath\$exportName"
	    	Write-Host "`n"
	     }
      }
    }

    if ($sevenZip) {
      if (-not (Test-Path -Path $sevenZipPath -PathType Leaf)) {
        throw "7-zip executable '$sevenZipPath' not found"
      }

      Set-Alias 7z $sevenZipPath
      $7zArgs = 'a', "`"$backupPath\$($backupFile).zip`"", '-mx9', '-tzip', '-bb0', $(if ($deleteFilesAfterZIP) {'-sdel'} else {"`b"}), "-p`"$encPass`"", "`"$backupPath\$backupFile.enc.json`"", "`"$attachmentsPath`""
      #DEBUG: Write-Host "`n`"$sevenZipPath`" $7zArgs"
      7z $7zArgs | Out-Null
      if ( $? ) { # Status of last command executed was successful
        Write-Host "`nGenerated encrypted ZIP-file."
      } else {
        Write-Host "`nThere were some warnings during zipping (path too long?).`nCheck the output-folder at $backupPath"
      }
      Write-Host "`n"
    }

    # Logging Out/Termination Prep
    Write-Host "The $(if ($organizationID.ToLower() -notmatch 'organizationid' -And -Not ([string]::IsNullOrEmpty($organizationid))) {'organization'} else {'personal'}) vault has been backed up."
    bw logout
    "`n"

    # Terminate if not GPG encrypting
    if (!$gpg) {
        pause
        exit
    } else {
    # GPG Encryption Prep
    $cdir = $backupPath
    Set-Location $cdir

    # GPG Encryption Step
    Write-Host "Your backup file is now being encrypted with key: " -NoNewline
    Write-Host $keyname -ForegroundColor Yellow -NoNewline
    Write-Host "."

    try {
        gpg --output "$backupFile.gpg" --encrypt --recipient $keyname $backupFile
        
        if (!(Test-Path -path "$backupFile.gpg")) {
            throw "InvalidRecipientException"
        }

        Write-Host "Your backup file has been successfully encrypted!" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Please open the script and review your recipient.`n" -ForegroundColor DarkRed
    }
    finally {
        # File Cleanup
        Write-Host "`nCleaning up the Backup folder. " -NoNewline
        Remove-Item -Path "$cdir\$backupFile" -Force
    
        # Secure File Cleanup
        if ($securedlt) {
            Write-Host "This will take some time."
            cipher /w:$cdir
        }
   
    }
    }
    Write-Host "`nFile cleanup completed." -ForegroundColor Green
    pause 
    exit
