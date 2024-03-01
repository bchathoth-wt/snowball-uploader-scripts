<#
.SYNOPSIS
Zips directories and their contents recursively, sanitizes file names, and transfers the zip files to AWS Snowball Edge.

.DESCRIPTION
The ZipDirectoryAndTransfer function processes a specified directory by zipping all files within it, optionally renaming files with non-alphanumeric characters, and then transferring the resulting zip files to AWS Snowball Edge. It handles each file and subdirectory recursively, ensuring all nested files are processed. The function logs its activities, including file name changes.

.PARAMETERS
- directoryPath: The path of the directory to process.
- logFilePath: Path to the file where the function logs its operations.
- FileNameChangeIndex: Path to the file where changes to file names are logged.
- maxFilesPerZip: Maximum number of files to include in a single zip archive. Default is 10000.

.EXAMPLE
ZipDirectoryAndTransfer -directoryPath "Z:/a-Synuclein/Cells/2021/2021_06_10_asyn exp" -logFilePath "Z:\scripts\logs\log.txt" -FileNameChangeIndex "Z:\scripts\List_of_file_name_change\changes.txt" -maxFilesPerZip 2500

This example processes the directory at "Z:/a-Synuclein/Cells/2021/2021_06_10_asyn exp", logs activities to "Z:\scripts\logs\log.txt", records file name changes to "Z:\scripts\List_of_file_name_change\changes.txt", and sets a maximum of 2500 files per zip archive.

.NOTES
- Ensure that 7-Zip is installed and accessible at 'C:\Program Files\7-Zip\7z.exe'.
- AWS CLI needs to be configured correctly for transferring files to AWS Snowball Edge.
- The function requires read and write permissions in the specified directories for file operations and logging.
- Special characters in file names are replaced with underscores to ensure compatibility across different file systems.

#>

function ZipDirectoryAndTransfer {
    param (
        [string]$directoryPath,
        [string]$logFilePath,
        [string]$FileNameChangeIndex,
        [int]$maxFilesPerZip,
        [string]$sanitizeFileName,
        [string[]]$completedFoldersList,
        [string]$completedFoldersFilePath,
        [string]$failedFoldersFilePath
    )

    # Log the directory being processed
    "Processing directory: $directoryPath" | Out-File -Append -FilePath $logFilePath
    Write-Host "Processing directory: `"$directoryPath`" ..."

    # Check the folder has already processed
    # Get the full, normalized path of the current directory
    $currentFolderPath = (Get-Item -Path $directoryPath).FullName

    # Check if the current folder has already been processed
    if ($currentFolderPath -in $completedFoldersList) {
        Write-Host "....Skipping already processed folder...."
        Write-Host "======================================================================================="
        return  # Skip this folder and return from the function
    }

    # Get all files in the directory if any
    $files = Get-ChildItem -Path $directoryPath -File 
    $fileChanged = 0
    if ($files.Count -gt 0) {
        Write-Host "Sanitize Flag: $sanitizeFileName"
        if ($sanitizeFileName -eq "Y") {
            Write-Host "Sanitizing the file names ............. "
            foreach ($file in $files) {
                # Check if the file name contains non-alphanumeric characters
                if ($file.Name -match '[^a-zA-Z0-9.-_]') {
                    # Create a sanitized file name by replacing non-alphanumeric characters with '_'
                    $sanitizedFileName = $file.Name -replace '[^a-zA-Z0-9.-]', '_'
                    # Construct the full path for the new file name in the same directory
                    $sanitizedFilePath = Join-Path -Path $file.DirectoryName -ChildPath $sanitizedFileName
                    $sanitizedFilePath = "\\?\$sanitizedFileName"
                    # Log the file name change
                    "$($file.FullName) -> $sanitizedFilePath" | Out-File -Append -FilePath $FileNameChangeIndex                  
                    
                    $ErrorActionPreference = 'Stop'
                    try {
                        # Use Command Prompt 'ren' command to rename the file ( using UNC path format)
                        # cmd /c ren "`"$($file.FullName)`"" "`"$sanitizedFileName`""  
                        Rename-Item -LiteralPath "\\?\$($file.FullName)" -NewName $sanitizedFileName
                    }
                    catch {
                        <#Do this if a terminating exception happens#>
                        $directoryPath | Out-File -FilePath $failedFoldersFilePath -Append -Encoding UTF8
                        Write-Host "Failed rename files in the folder.  Error: $_"
                        # Skip further processing of this folder and continue with the next one
                        "Failed directory: $directoryPath" | Out-File -Append -FilePath $logFilePath
                        "Error: $_" | Out-File -Append -FilePath $logFilePath
                        Write-Host "======================================================================================="
                        return
                    }
                    $ErrorActionPreference = 'Continue'
                    $fileChanged++
                }
            }        
        } 
        Write-Host "Renamed $fileChanged files."
        # Recalculate files if any file name changed
        if ($fileChanged -gt 0) {
            $files = Get-ChildItem -Path $directoryPath -File
        }

        # Get the name of the current directory
        $currentDirName = Split-Path -Path $directoryPath -Leaf
        # Sanitize the current directory name by replacing non-alphanumeric characters with '_'
        $sanitizedCurrentDirName = $currentDirName -replace '[^a-zA-Z0-9.-_]', '_'
        Write-Host "Zipping the files to `"$currentDirName`" ....."    
    } else {
        Write-Host "No files found in this subfolder ....."
    }

    Write-Host ".... $($files.Count) files to be transferred... "
    if ($files.Count -gt 0) {
        # Calculate the number of zip files needed
        $numberOfZips = [Math]::Ceiling($files.Count / $maxFilesPerZip)
        Write-Host ".... Number of zip files to be created: $numberOfZips "
        for ($i = 0; $i -lt $numberOfZips; $i++) {
            # Determine the range of files for the current zip
            # $fileBatch = $files | Select-Object -Skip ($i * $maxFilesPerZip) -First $maxFilesPerZip

            # Set the name for the zip file, including a batch number if there are multiple zips
            $zipFileName = if ($numberOfZips -gt 1) { "$sanitizedCurrentDirName`_part$($i+1).zip" } else { "$sanitizedCurrentDirName.zip" }

            # Specify the path for the zip file
            $zipFilePath = Join-Path -Path $directoryPath -ChildPath $zipFileName

            # Create a temporary directory to copy the current batch of files
            $tempDir = Join-Path -Path $directoryPath -ChildPath "temp_zip_$([System.IO.Path]::GetRandomFileName())"
            
            Write-Host "Creating FileList `"$($tempDir)`" ..........."

            $ErrorActionPreference = 'Stop'
            try {
                New-Item -ItemType Directory -Path "\\?\$tempDir" | Out-Null
                Write-Host "Created FileList `"$($tempDir)`" ..........."
            }
            catch {
                "$directoryPath" | Out-File -FilePath $failedFoldersFilePath -Append
                Write-Host "Copy failed.  Error: $_"
                # Skip further processing of this folder and continue with the next one
                "Failed directory: $directoryPath" | Out-File -Append -FilePath $logFilePath
                "Error: $_" | Out-File -Append -FilePath $logFilePath
                Write-Host "======================================================================================="
                return
            }
            $ErrorActionPreference = 'Continue'
            
            # Write the files names to the temp file in the batch to the temporary directory
            $destination = Join-Path -Path $tempDir -ChildPath "fileList.txt"

            $ErrorActionPreference = 'Stop'
            try {
                # copy to temp folder the file ( using UNC path format)
                $files | Select-Object -ExpandProperty FullName -Skip ($i * $maxFilesPerZip) -First $maxFilesPerZip | Out-File -FilePath $destination -Append -Encoding UTF8
            }
            catch {
        
                Write-Host "Create ListFile failed.  Error: $_"
                # Skip further processing of this folder and continue with the next one
                Write-Host "======================================================================================="
               return
            } 
            $ErrorActionPreference = 'Continue'            
            
            Write-Host "Zip file path `"$zipFilePath`" ....."   
            # Use 7z to create a zip archive of the file batch directly, no need for a temporary directory
            # & 'C:\Program Files\7-Zip\7z.exe' a -tzip "\\?\$zipFilePath" "\\?\$tempDir\*"
            & 'C:\Program Files\7-Zip\7z.exe' a -tzip "\\?\$zipFilePath" "@$destination"

            # Transfer the zip file to AWS Snowball Edge
            $fileKey = $zipFilePath.Substring($zipFilePath.IndexOf(':') + 2).Replace('\', '/')
            $awsKey = "wbtx-archived-scientific-data/$fileKey"  # Adjust this path as needed
            aws s3 cp $zipFilePath s3://$awsKey --endpoint-url http://192.168.16.67:8080

            # Optionally, remove the zip file after transfer
            Remove-Item -Path "\\?\$tempDir" -Recurse -Force
            Remove-Item -Path "\\?\$zipFilePath" -Force
            Write-Host "File uploaded to Snowball successfully ....." 
            Write-Host "............................................" 
        }
    }
    # After successfully processing a folder add to     # Only log leaf folders
    # Check for subdirectories
    $subdirectories = Get-ChildItem -Path $directoryPath -Directory
    if ($subdirectories.Count -eq 0) {
        # It's a leaf folder, append its path to the completed folders file
        "$directoryPath" | Out-File -FilePath $completedFoldersFilePath -Append
        Write-Host "Added leaf folder to completed list..."
    }

    Write-Host "======================================================================================="
    Write-Host "Started archiving at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host " "

    # Recursively process each subdirectory    
    # $subdirectories = Get-ChildItem -Path $directoryPath -Directory
    foreach ($subdir in $subdirectories) {        
        ZipDirectoryAndTransfer `
            -directoryPath $subdir.FullName `
            -logFilePath $logFilePath `
            -FileNameChangeIndex $FileNameChangeIndex `
            -maxFilesPerZip $maxFilesPerZip `
            -sanitizeFileName $sanitizeFileName `
            -completedFoldersList $completedFoldersList `
            -completedFoldersFilePath $completedFoldersFilePath `
            -failedFoldersFilePath $failedFoldersFilePath
    }
}
