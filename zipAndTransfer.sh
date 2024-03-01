#!/bin/bash

# Variables
directoryPath="/path/to/directory"
logFilePath="/path/to/log.txt"
fileNameChangeIndex="/path/to/fileNameChangeIndex.txt"
maxFilesPerZip=10000
sanitizeFileName="Y"
completedFoldersList="/path/to/completedFoldersList.txt"
completedFoldersFilePath="/path/to/completedFoldersFilePath.txt"
failedFoldersFilePath="/path/to/failedFoldersFilePath.txt"

# Function to process directories
zipAndTransfer() {
    local dirPath="$1"

    echo "Processing directory: $dirPath" | tee -a "$logFilePath"
    
    # Check if the folder has already been processed
    if grep -Fxq "$dirPath" "$completedFoldersList"; then
        echo "....Skipping already processed folder...."
        return
    fi

    # Sanitize and zip files in the directory
    if [ "$sanitizeFileName" = "Y" ]; then
        echo "Sanitizing the file names and zipping..."

        # Create a temporary directory for sanitized files
        tempDir=$(mktemp -d)

        # Find all files and sanitize names
        find "$dirPath" -type f | while read -r file; do
            filename=$(basename -- "$file")
            sanitizedFileName=$(echo "$filename" | sed 's/[^a-zA-Z0-9.-]/_/g')
            cp "$file" "$tempDir/$sanitizedFileName"
            echo "$file -> $tempDir/$sanitizedFileName" >> "$fileNameChangeIndex"
        done

        # Zip the sanitized files
        zipFilePath="$dirPath.zip"
        (cd "$tempDir" && zip -r "$zipFilePath" .)

        # Transfer the zip file to AWS Snowball Edge
        awsKey="wbtx-archived-scientific-data/${zipFilePath#*/}" # Adjust path as needed
        aws s3 cp "$zipFilePath" "s3://$awsKey" --endpoint-url "http://192.168.16.67:8080"

        # Cleanup
        rm -rf "$tempDir"
        rm -f "$zipFilePath"
    fi

    # Check for subdirectories and process them
    find "$dirPath" -mindepth 1 -type d | while read -r subdir; do
        zipAndTransfer "$subdir"
    done
}

# Start processing
zipAndTransfer "$directoryPath"
